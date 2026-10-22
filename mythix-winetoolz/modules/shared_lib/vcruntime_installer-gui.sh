#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  vcruntime_installer-gui.sh — Visual C++ Runtime Installer
#  winetoolz v3.0
#
#  Installs one or both of:
#    •  VC++ 2015–2022  (vc14 — the classic unified redist)
#    •  VC++ 2017–2026  (vc17 — latest MSVC toolset redist)
#  x86 + x64 in a 64-bit prefix, x86 only in a 32-bit one.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="VC++ Runtime Installer"

wt_require_cmds zenity
_wt_have curl || _wt_have wget || wt_require_cmds curl

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  3. Export shared vars for helper scripts
# =============================================================================

export WT_INNER_WINE
export WT_WRAPPER
export WINEPREFIX

# =============================================================================
#  Helper: generate + run a terminal installer for a given vc version
# =============================================================================

run_vc_install() {
    local ver_label="$1"   # e.g. "VC++ 2015-2022  (vc14)"
    local key="$2"         # catalog key stem: vc14 / vc17

    export WT_VC_LABEL="$ver_label"
    export WT_VC_KEY="$key"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

wt_section "$WT_VC_LABEL"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX  ($(wt_prefix_arch "$WINEPREFIX"))"
printf '\n'

# A 32-bit prefix cannot run the x64 installer — and has no use for it.
ARCHES=(x86)
[[ "$(wt_prefix_arch "$WINEPREFIX")" == win64 ]] && ARCHES+=(x64)

fails=0
for arch in "${ARCHES[@]}"; do
    printf '\n'
    if ! wt_fetch_item "${WT_VC_KEY}_${arch}" "$WT_VC_LABEL $arch"; then
        fails=$((fails + 1))
        continue
    fi
    wt_section "Running $arch Installer"
    rc=0
    "$WT_INNER_WINE" "$WT_FETCHED" /install /quiet /norestart || rc=$?
    case "$rc" in
        0)         wt_log_ok "$arch installed." ;;
        3010|1641) wt_log_ok "$arch installed (Windows would want a reboot — not needed under Wine)." ;;
        1638)      wt_log_ok "$arch: this or a newer version is already installed." ;;
        *)         wt_log_err "$arch installer exited with code $rc."; fails=$((fails + 1)) ;;
    esac
done

wt_section "$WT_VC_LABEL  ›  $( (( fails )) && echo "finished with errors" || echo "Complete")"
wt_log_info "Prefix : $WINEPREFIX"
wt_pause
(( fails == 0 ))
INNEREOF

    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"
    if [[ "$WT_TERMINAL_RC" == 0 ]]; then
        wt_ok "$MODULE" "$ver_label"
    else
        wt_warn "$MODULE" "$(printf '%s did not install completely —\nsee the terminal output.' "$ver_label")"
    fi
}

# =============================================================================
#  4. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(_wt_box "$(printf 'Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nSelect a VC++ version to install.' \
            "$WT_INNER_WINE" "$WINEPREFIX")")" \
        --column="Tag" --column="Version" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=680 --height=320 \
        "vc14"  "VC++ 2015–2022  (vc14)"  "Unified redist — covers VS2015, 2017, 2019, 2022" \
        "vc17"  "VC++ 2017–2026  (vc17)"  "Latest MSVC rolling redist — covers VS2017 through 2026" \
        "both"  "Install Both"             "Install vc14 then vc17 in sequence" \
        "exit"  "Back to Main Menu"        "") || break
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in
        vc14) run_vc_install "VC++ 2015-2022  (vc14)" vc14 ;;
        vc17) run_vc_install "VC++ 2017-2026  (vc17)" vc17 ;;
        both)
            run_vc_install "VC++ 2015-2022  (vc14)" vc14
            run_vc_install "VC++ 2017-2026  (vc17)" vc17
            ;;
        exit|*)
            break
            ;;
    esac
done
