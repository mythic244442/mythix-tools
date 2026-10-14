#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  wine_tools.sh — Wine Built-in Tools Launcher
#  winetoolz v2.0
#
#  Quick-launch menu for standard Wine/Windows tools:
#    uninstaller / control / taskmgr / regedit / explorer
#    winecfg / wineboot --update / wineserver -k
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Wine Tools"

wt_require_cmds zenity

# =============================================================================
#  1. Select Wine binary + prefix (once, reused for all launches)
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

export WT_INNER_WINE WINEPREFIX WT_WRAPPER

# =============================================================================
#  Helper: launch a wine tool in a terminal (for interactive GUI apps, inline)
# =============================================================================

_launch_wine_tool() {
    local label="$1"
    local tool="$2"       # passed to wine as the executable name
    local args="${3:-}"   # optional extra args

    export WT_TOOL_LABEL="$label"
    export WT_TOOL_CMD="$tool"
    export WT_TOOL_ARGS="$args"
    export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

wt_section "Wine Tools  ›  $WT_TOOL_LABEL"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'

wt_log "Launching: $WT_TOOL_CMD $WT_TOOL_ARGS"
"$WT_INNER_WINE" $WT_TOOL_CMD $WT_TOOL_ARGS
EXIT_CODE=$?
printf '\n'
if [[ $EXIT_CODE -eq 0 ]]; then
    wt_log_ok "$WT_TOOL_LABEL closed."
else
    wt_log_err "$WT_TOOL_LABEL exited with code $EXIT_CODE (may be normal)."
fi

read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
}

# =============================================================================
#  2. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nSelect a tool to launch.</tt>' \
            "$WT_INNER_WINE" "$WINEPREFIX")" \
        --column="Tag" --column="Tool" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=700 --height=460 \
        "uninstaller"  "Add/Remove Programs"    "wine uninstaller — manage installed Windows apps" \
        "control"      "Control Panel"           "wine control — Windows control panel applets" \
        "winecfg"      "Wine Configuration"      "winecfg — drives, audio, libraries, Windows version" \
        "taskmgr"      "Task Manager"            "wine taskmgr — view and kill running Wine processes" \
        "regedit"      "Registry Editor"         "wine regedit — browse and edit the prefix registry" \
        "explorer"     "Wine Explorer"           "wine explorer — file browser inside the prefix" \
        "wineboot"     "Update Prefix"           "wineboot --update — reinitialise prefix after Wine upgrade" \
        "wineserver"   "Kill Wine Processes"     "wineserver -k — terminate all Wine processes immediately" \
        "exit"         "Back to Main Menu"       "") || break

    case "$CHOICE" in
        uninstaller)  _launch_wine_tool "Add/Remove Programs" "uninstaller" ;;
        control)      _launch_wine_tool "Control Panel"       "control"     ;;
        winecfg)      _launch_wine_tool "Wine Configuration"  "winecfg"     ;;
        taskmgr)      _launch_wine_tool "Task Manager"        "taskmgr"     ;;
        regedit)      _launch_wine_tool "Registry Editor"     "regedit"     ;;
        explorer)     _launch_wine_tool "Wine Explorer"       "explorer"    ;;

        wineboot)
            export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
            local TMP
            TMP=$(mktemp --suffix=.sh)
            cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX
wt_section "Wine Tools  ›  Update Prefix"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'
wt_log "Running: wineboot --update ..."
"$WT_INNER_WINE" wineboot --update \
    && wt_log_ok "Prefix updated successfully." \
    || wt_log_err "wineboot --update exited with an error."
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"
            ;;

        wineserver)
            WINEPREFIX="$WINEPREFIX" wineserver -k \
                && wt_info "$MODULE" "$(printf '✔  wineserver -k\n\nAll Wine processes in this prefix have been terminated.\n\n  Prefix : %s' "$WINEPREFIX")" \
                || wt_error_return "wineserver -k failed."
            ;;

        exit|*) break ;;
    esac
done
