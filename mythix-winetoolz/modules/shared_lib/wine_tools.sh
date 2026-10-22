#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  wine_tools.sh — Wine Built-in Tools Launcher
#  winetoolz v3.0
#
#  Quick-launch menu for standard Wine/Windows tools:
#    uninstaller / control / taskmgr / regedit / explorer / cmd
#    winecfg / wineboot --update / stop Wine / open drive C:
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
read -r -a ARGS <<< "$WT_TOOL_ARGS"
"$WT_INNER_WINE" "$WT_TOOL_CMD" "${ARGS[@]}"
EXIT_CODE=$?
printf '\n'
if [[ $EXIT_CODE -eq 0 ]]; then
    wt_log_ok "$WT_TOOL_LABEL closed."
else
    wt_log_err "$WT_TOOL_LABEL exited with code $EXIT_CODE (may be normal)."
fi

wt_pause
INNEREOF

    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"
}

# =============================================================================
#  2. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(_wt_box "$(printf 'Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nSelect a tool to launch.' \
            "$WT_INNER_WINE" "$WINEPREFIX")")" \
        --column="Tag" --column="Tool" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=700 --height=500 \
        "uninstaller"  "Add/Remove Programs"    "wine uninstaller — manage installed Windows apps" \
        "control"      "Control Panel"           "wine control — Windows control panel applets" \
        "winecfg"      "Wine Configuration"      "winecfg — drives, audio, libraries, Windows version" \
        "taskmgr"      "Task Manager"            "wine taskmgr — view and kill running Wine processes" \
        "regedit"      "Registry Editor"         "wine regedit — browse and edit the prefix registry" \
        "explorer"     "Wine Explorer"           "wine explorer — file browser inside the prefix" \
        "cmd"          "Command Prompt"          "wine cmd — a Windows command prompt in the terminal" \
        "drivec"       "Open Drive C:"           "Open the prefix's drive_c in your file manager" \
        "wineboot"     "Update Prefix"           "wineboot --update — reinitialise prefix after Wine upgrade" \
        "wineserver"   "Kill Wine Processes"     "Stop every Wine process running in this prefix" \
        "exit"         "Back to Main Menu"       "") || break
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in
        uninstaller)  _launch_wine_tool "Add/Remove Programs" "uninstaller" ;;
        control)      _launch_wine_tool "Control Panel"       "control"     ;;
        winecfg)      _launch_wine_tool "Wine Configuration"  "winecfg"     ;;
        taskmgr)      _launch_wine_tool "Task Manager"        "taskmgr"     ;;
        regedit)      _launch_wine_tool "Registry Editor"     "regedit"     ;;
        explorer)     _launch_wine_tool "Wine Explorer"       "explorer"    ;;
        cmd)          _launch_wine_tool "Command Prompt"      "cmd"         ;;
        wineboot)     _launch_wine_tool "Update Prefix"       "wineboot"    "--update" ;;

        drivec)
            if _wt_have xdg-open; then
                xdg-open "$WINEPREFIX/drive_c" >/dev/null 2>&1 &
            else
                wt_info "$MODULE" "$(printf 'xdg-open is not installed. Drive C: is at:\n  %s' "$WINEPREFIX/drive_c")"
            fi
            ;;

        wineserver)
            if ! wt_prefix_running "$WINEPREFIX"; then
                wt_info "$MODULE" "$(printf 'No Wine processes are running in this prefix.\n\n  Prefix : %s' "$WINEPREFIX")"
            else
                wt_kill_prefix "$WINEPREFIX" || true
                if wt_prefix_running "$WINEPREFIX"; then
                    wt_error_return "$(printf 'Wine is still running in:\n  %s' "$WINEPREFIX")"
                else
                    wt_info "$MODULE" "$(printf '✔  All Wine processes in this prefix have been terminated.\n\n  Prefix : %s' "$WINEPREFIX")"
                fi
            fi
            ;;

        exit|*) break ;;
    esac
done
