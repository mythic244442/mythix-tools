#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  vcruntime_installer-gui.sh — Visual C++ Runtime Installer
#  winetoolz v2.0
#
#  Installs one or both of:
#    •  VC++ 2015–2022  (vc14 — the classic unified redist)
#    •  VC++ 2017–2026  (vc17 — latest MSVC toolset redist)
#  Each installs x86 + x64 redistributables into the selected prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="VC++ Runtime Installer"

# --- Download URLs ---
# vc14: 2015–2022 unified (covers VS2015, 2017, 2019, 2022)
URL_VC14_X86="https://aka.ms/vc14/vc_redist.x86.exe"
URL_VC14_X64="https://aka.ms/vc14/vc_redist.x64.exe"

# vc17: latest MSVC 2017–2026 redist (rolling latest from Microsoft)
URL_VC17_X86="https://aka.ms/vs/17/release/vc_redist.x86.exe"
URL_VC17_X64="https://aka.ms/vs/17/release/vc_redist.x64.exe"

wt_require_cmds zenity wget

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix "$MODULE" || exit 0

# =============================================================================
#  3. Export shared vars for helper scripts
# =============================================================================

export WT_INNER_WINE
export WT_WRAPPER
export WINEPREFIX
export URL_VC14_X86 URL_VC14_X64
export URL_VC17_X86 URL_VC17_X64
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

# =============================================================================
#  Helper: generate + run a terminal installer for a given vc version
# =============================================================================

run_vc_install() {
    local ver_label="$1"   # e.g. "VC++ 2015-2022  (vc14)"
    local url_x86="$2"
    local url_x64="$3"

    export WT_VC_LABEL="$ver_label"
    export WT_VC_URL_X86="$url_x86"
    export WT_VC_URL_X64="$url_x64"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

TMP_DIR="$(mktemp -d)"
SELF="$0"
trap 'rm -rf "$TMP_DIR"; rm -f "$SELF"' EXIT
cd "$TMP_DIR"

wt_section "$WT_VC_LABEL"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'

# --- Download ---
wt_log "Downloading x86 redistributable..."
wget -q --show-progress -O vc_redist.x86.exe "$WT_VC_URL_X86" \
    && wt_log_ok "x86 download complete." \
    || { wt_log_err "x86 download failed."; read -rp "Press Enter to close..." < /dev/tty; exit 1; }

printf '\n'
wt_log "Downloading x64 redistributable..."
wget -q --show-progress -O vc_redist.x64.exe "$WT_VC_URL_X64" \
    && wt_log_ok "x64 download complete." \
    || { wt_log_err "x64 download failed."; read -rp "Press Enter to close..." < /dev/tty; exit 1; }

printf '\n'
wt_section "Running x86 (32-bit) Installer"
wt_log_info "Click  Install  or  Repair  in the window that appears."
"$WT_INNER_WINE" vc_redist.x86.exe /install /quiet /norestart \
    && wt_log_ok "x86 installed." \
    || wt_log_err "x86 installer exited with an error (may still have installed)."

printf '\n'
wt_section "Running x64 (64-bit) Installer"
wt_log_info "Click  Install  or  Repair  in the window that appears."
"$WT_INNER_WINE" vc_redist.x64.exe /install /quiet /norestart \
    && wt_log_ok "x64 installed." \
    || wt_log_err "x64 installer exited with an error (may still have installed)."

wt_section "$WT_VC_LABEL  ›  Complete"
wt_log_info "Prefix : $WINEPREFIX"
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
}

# =============================================================================
#  4. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nSelect a VC++ version to install.</tt>' \
            "$WT_INNER_WINE" "$WINEPREFIX")" \
        --column="Tag" --column="Version" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=680 --height=320 \
        "vc14"  "VC++ 2015–2022  (vc14)"  "Unified redist — covers VS2015, 2017, 2019, 2022" \
        "vc17"  "VC++ 2017–2026  (vc17)"  "Latest MSVC rolling redist — covers VS2017 through 2026" \
        "both"  "Install Both"             "Install vc14 then vc17 in sequence" \
        "exit"  "Back to Main Menu"        "") || break

    case "$CHOICE" in
        vc14)
            run_vc_install \
                "VC++ 2015-2022  (vc14)" \
                "$URL_VC14_X86" "$URL_VC14_X64"
            ;;
        vc17)
            run_vc_install \
                "VC++ 2017-2026  (vc17)" \
                "$URL_VC17_X86" "$URL_VC17_X64"
            ;;
        both)
            run_vc_install \
                "VC++ 2015-2022  (vc14)" \
                "$URL_VC14_X86" "$URL_VC14_X64"
            run_vc_install \
                "VC++ 2017-2026  (vc17)" \
                "$URL_VC17_X86" "$URL_VC17_X64"
            ;;
        exit|*)
            break
            ;;
    esac
done
