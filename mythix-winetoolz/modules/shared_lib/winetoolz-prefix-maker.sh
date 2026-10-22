#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  winetoolz-prefix-maker.sh — Wine / Proton Prefix Creator
#  winetoolz v3.0
#  Bootstraps a new Wine/Proton prefix: wineboot, Windows version, then
#  optionally opens winecfg for a final check.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Prefix Creator"

wt_require_cmds zenity
wt_load_config

# =============================================================================
#  1. Select Wine / Proton binary  (auto-detected radio-list)
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select prefix location via directory picker
# =============================================================================

# _folder_empty <dir>  — true for a folder with nothing in it (or no folder).
_folder_empty() {
    [[ ! -e "$1" ]] && return 0
    [[ -d "$1" ]] || return 1
    [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

RECREATE=false
while :; do
    PREFIX=$(zenity --file-selection \
        --directory \
        --title="$(wt_title "$MODULE  ›  Folder for the new prefix (an empty or new folder)")" \
        --width="$WT_WIDTH") || exit 0
    PREFIX="${PREFIX%/}"
    [[ -n "$PREFIX" ]] || continue

    if [[ -f "$PREFIX/system.reg" ]]; then
        # An existing prefix: recreate it (deleted only after the final OK).
        wt_confirm "$MODULE" "$(printf \
            'A prefix already exists at:\n  %s\n\n─────────────────────────────────────\nDelete it and start fresh?\n\n⚠  WARNING: This cannot be undone.' \
            "$PREFIX")" || continue
        RECREATE=true
        break
    fi

    if _folder_empty "$PREFIX"; then
        break
    fi

    # A folder with other things in it ($HOME, Documents, a games folder):
    # never mix a prefix into it — create a subfolder instead.
    NAME=$(zenity --entry \
        --title="$(wt_title "$MODULE  ›  New Prefix Folder")" \
        --text="$(_wt_box "$(printf 'This folder already contains other files:\n  %s\n\nThe prefix will be created in a new subfolder.\nName it:' "$PREFIX")")" \
        --entry-text="wine-prefix" \
        --width="$WT_WIDTH") || continue
    NAME="${NAME//[^A-Za-z0-9._ -]/_}"
    NAME="${NAME#"${NAME%%[! .]*}"}"
    if [[ -z "$NAME" || "$NAME" == "." || "$NAME" == ".." ]]; then
        wt_error_return "Please enter a folder name."
        continue
    fi
    if ! _folder_empty "$PREFIX/$NAME"; then
        if [[ -f "$PREFIX/$NAME/system.reg" ]]; then
            wt_error_return "$(printf 'A prefix named  %s  already exists there.\nPick it directly to recreate it, or choose another name.' "$NAME")"
        else
            wt_error_return "$(printf '%s/%s already exists and is not empty.\nChoose another name.' "$PREFIX" "$NAME")"
        fi
        continue
    fi
    PREFIX="$PREFIX/$NAME"
    break
done

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

IFS='|' read -r ARCH WINVER OPEN_CFG _ <<< "$CONFIG" || true

# Fallbacks in case the combo returned empty
case "${ARCH// /}" in win32) ARCH=win32 ;; *) ARCH=win64 ;; esac
WINVER="${WINVER// /}"
[[ "$WINVER" =~ ^(win11|win10|win81|win8|win7|winxp)$ ]] || WINVER="win11"
[[ "${OPEN_CFG// /}" == "No" ]] && OPEN_CFG="No" || OPEN_CFG="Yes"

# =============================================================================
#  4. Confirm summary before proceeding
# =============================================================================

RECREATE_NOTE=""
$RECREATE && RECREATE_NOTE=$'\n             (the existing prefix is deleted first)'
wt_confirm "$MODULE" "$(printf \
    'Ready to create prefix.\n\n  Wine    :  %s\n  Wrapper :  %s\n  Prefix  :  %s%s\n  Arch    :  %s\n  Version :  %s\n  Winecfg :  %s\n\n─────────────────────────────────────\nProceed?' \
    "$WT_INNER_WINE" \
    "${WT_WRAPPER:-none}" \
    "$PREFIX" \
    "$RECREATE_NOTE" \
    "$ARCH" \
    "$WINVER" \
    "$OPEN_CFG")" || exit 0

# =============================================================================
#  5. Handle existing prefix — only now, after the final confirmation
# =============================================================================

if $RECREATE; then
    wt_kill_prefix "$PREFIX" || true
    if ! wt_safe_rmrf "$PREFIX" system.reg; then
        wt_error "$(printf 'Could not delete the old prefix:\n\n%s' "$WT_RMRF_ERROR")"
    fi
fi

mkdir -p "$PREFIX"

# =============================================================================
#  6. Export variables for helper script
# =============================================================================

export WT_INNER_WINE
export WT_WRAPPER
export WINEPREFIX="$PREFIX"
export WINEARCH="$ARCH"
export WT_WINVER="$WINVER"
export WT_OPEN_CFG="$OPEN_CFG"

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
# The registry reaches system.reg when the wineserver exits.
"${WT_WINESERVER:-wineserver}" -w 2>/dev/null

if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
    wt_log_err "The prefix was not created (no system.reg)."
    [[ "$WINEARCH" == win32 ]] && wt_log_err "A 32-bit prefix needs a Wine build with 32-bit support (WoW64-only builds cannot make one)."
    wt_pause
    exit 1
fi

# --- Set the Windows version (winecfg -v updates every place Wine keeps it) ---
printf '\n'
wt_log "Setting Windows version: $WT_WINVER"
if "$WT_INNER_WINE" winecfg -v "$WT_WINVER" >/dev/null 2>&1; then
    wt_log_ok "Windows version set."
elif "$WT_INNER_WINE" reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /d "$WT_WINVER" /f >/dev/null 2>&1; then
    wt_log_ok "Version key written."
else
    wt_log_err "Could not set the Windows version."
fi

# --- Optionally launch winecfg (the inner wine: the wrapper would need Steam) ---
if [[ "$WT_OPEN_CFG" == "Yes" ]]; then
    printf '\n'
    wt_log "Launching winecfg for final review..."
    "$WT_INNER_WINE" winecfg \
        && wt_log_ok "winecfg closed." \
        || wt_log_err "winecfg exited with an error."
fi

wt_section "Prefix creation complete."
wt_log_info "Prefix ready at: $WINEPREFIX"
wt_pause
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"

# =============================================================================
#  8. Result — and make sure the new prefix shows up in every prefix list
# =============================================================================

if [[ ! -f "$PREFIX/system.reg" ]]; then
    wt_error "$(printf 'The prefix was not created:\n  %s\n\nThe terminal output shows what went wrong.' "$PREFIX")"
fi

wt_config_set WT_LAST_PREFIX "$PREFIX" 2>/dev/null || true
PARENT="$(dirname "$PREFIX")"
case ":${WT_PREFIX_PATHS:-}:" in
    *":$PARENT:"*|*":$PREFIX:"*) ;;
    *) wt_config_set WT_PREFIX_PATHS "${WT_PREFIX_PATHS:+$WT_PREFIX_PATHS:}$PARENT" 2>/dev/null || true ;;
esac

wt_ok "$MODULE" "$(printf 'Prefix creation at %s' "$PREFIX")"
