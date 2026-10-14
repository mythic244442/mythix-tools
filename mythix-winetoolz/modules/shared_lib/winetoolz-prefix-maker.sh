#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  winetoolz-prefix-maker.sh — Wine / Proton Prefix Creator
#  winetoolz v2.0
#  Bootstraps a new Wine/Proton prefix: wineboot, version registry key,
#  then opens winecfg for a final check.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Prefix Creator"

wt_require_cmds zenity

# =============================================================================
#  1. Select Wine / Proton binary  (auto-detected radio-list)
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select prefix location via directory picker
# =============================================================================

PREFIX=$(zenity --file-selection \
    --directory \
    --title="$(wt_title "$MODULE  ›  Select Prefix Location")" \
    --text="<tt>Select the folder where the new prefix will be created.\nYou can select an existing folder or navigate to a new one.\n\nNote: if a prefix already exists here you will be asked\nwhether to delete it and start fresh.</tt>" \
    --width="$WT_WIDTH") || exit 0

[[ -z "$PREFIX" ]] && wt_error "No prefix directory was selected."

# =============================================================================
#  3. Prefix configuration — arch, Windows version, winecfg toggle
# =============================================================================

CONFIG=$(zenity --forms \
    --title="$(wt_title "$MODULE  ›  Prefix Configuration")" \
    --text="<tt>Configure the new prefix.\n─────────────────────────────────────────────────</tt>" \
    --add-combo="Architecture" \
        --combo-values="win64|win32" \
    --add-combo="Windows version" \
        --combo-values="win11|win10|win81|win8|win7|winxp" \
    --add-combo="Open winecfg after creation?" \
        --combo-values="Yes|No" \
    --separator="|" \
    --width=480) || exit 0

ARCH="$(   echo "$CONFIG" | cut -d'|' -f1 | xargs)"
WINVER="$( echo "$CONFIG" | cut -d'|' -f2 | xargs)"
OPEN_CFG="$(echo "$CONFIG" | cut -d'|' -f3 | xargs)"

# Fallbacks in case the combo returned empty
[[ -z "$ARCH"   ]] && ARCH="win64"
[[ -z "$WINVER" ]] && WINVER="win11"
[[ -z "$OPEN_CFG" ]] && OPEN_CFG="Yes"

# =============================================================================
#  4. Handle existing prefix
# =============================================================================

if [[ -d "$PREFIX/drive_c" ]]; then
    wt_confirm "$MODULE" "$(printf \
        'A prefix already exists at:\n  %s\n\n─────────────────────────────────────\nDelete it and start fresh?\n\n⚠  WARNING: This cannot be undone.' \
        "$PREFIX")" || exit 0
    rm -rf "$PREFIX"
fi

mkdir -p "$PREFIX"

# =============================================================================
#  5. Confirm summary before proceeding
# =============================================================================

wt_confirm "$MODULE" "$(printf \
    'Ready to create prefix.\n\n  Wine    :  %s\n  Wrapper :  %s\n  Prefix  :  %s\n  Arch    :  %s\n  Version :  %s\n  Winecfg :  %s\n\n─────────────────────────────────────\nProceed?' \
    "$WT_INNER_WINE" \
    "${WT_WRAPPER:-none}" \
    "$PREFIX" \
    "$ARCH" \
    "$WINVER" \
    "$OPEN_CFG")" || exit 0

# =============================================================================
#  6. Export variables for helper script
# =============================================================================

export WT_INNER_WINE
export WT_WRAPPER
export WINEPREFIX="$PREFIX"
export WINEARCH="$ARCH"
export WT_WINVER="$WINVER"
export WT_OPEN_CFG="$OPEN_CFG"
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

# =============================================================================
#  7. Generate + run helper script in terminal
# =============================================================================

TMP=$(mktemp --suffix=.sh)
trap 'rm -f "$TMP"' EXIT

cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e

source "$WT_LIB_PATH"

wt_section "Prefix Creator"
wt_log_info "Prefix  : $WINEPREFIX"
wt_log_info "Arch    : $WINEARCH"
wt_log_info "Version : $WT_WINVER"
wt_log_info "Wine    : $WT_INNER_WINE"
wt_log_info "Wrapper : ${WT_WRAPPER:-none}"
printf '\n'

# --- Initialise prefix ---
wt_log "Running wineboot -u..."
"$WT_INNER_WINE" wineboot -u \
    && wt_log_ok "wineboot complete." \
    || wt_log_err "wineboot reported an error (often harmless on first run)."

# --- Set Windows version registry key ---
printf '\n'
wt_log "Setting Windows version: $WT_WINVER"
"$WT_INNER_WINE" reg add 'HKEY_CURRENT_USER\Software\Wine' \
    /v Version /d "$WT_WINVER" /f >/dev/null 2>&1 \
    && wt_log_ok "Version key written." \
    || wt_log_err "reg add returned an error."

# --- Optionally launch winecfg ---
if [[ "$WT_OPEN_CFG" == "Yes" ]]; then
    printf '\n'
    wt_log "Launching winecfg for final review..."
    if [[ -n "$WT_WRAPPER" ]]; then
        "$WT_WRAPPER" run winecfg \
            && wt_log_ok "winecfg closed." \
            || wt_log_err "winecfg exited with an error."
    else
        "$WT_INNER_WINE" winecfg \
            && wt_log_ok "winecfg closed." \
            || wt_log_err "winecfg exited with an error."
    fi
fi

wt_section "Prefix creation complete."
wt_log_info "Prefix ready at: $WINEPREFIX"
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
