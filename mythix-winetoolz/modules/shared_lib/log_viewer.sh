#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  log_viewer.sh — Wine Log Capture & Viewer
#  winetoolz v2.0
#
#  Launches a Wine executable while capturing stderr to a timestamped log file.
#  Shows the log in a scrollable zenity text-info viewer after the run.
#
#  Logs stored at: ~/winetoolz/logs/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Log Viewer"
LOG_DIR="${HOME}/winetoolz/logs"

wt_require_cmds zenity
mkdir -p "$LOG_DIR"

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="<tt>Capture Wine output to a log file, or browse saved logs.</tt>" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=660 --height=300 \
        "run"     "Run & Capture Log"   "Launch an app and capture all Wine output to a log" \
        "view"    "View Saved Log"      "Browse and view a previously saved log file" \
        "delete"  "Delete Logs"         "Remove one or more saved log files" \
        "exit"    "Back to Main Menu"   "") || break

    case "$CHOICE" in

        # ------------------------------------------------------------------
        run)
            wt_select_wine_bin "$MODULE" || continue
            wt_select_prefix_from_config "$MODULE" || continue

            EXE=$(zenity --file-selection \
                --title="$(wt_title "$MODULE  ›  Select Executable")" \
                --filename="$WINEPREFIX/drive_c/" \
                --file-filter="Windows executables | *.exe *.EXE *.bat *.BAT" \
                --width=760) || continue

            EXTRA_ARGS=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Launch Arguments")" \
                --text="<tt>Optional launch arguments (leave blank for none):</tt>" \
                --width="$WT_WIDTH") || true

            # Optional: load an env profile
            mapfile -t PROFILE_NAMES < <(
                for f in "${HOME}/.config/winetoolz/env_profiles"/*.env; do
                    [[ -f "$f" ]] && basename "$f" .env
                done 2>/dev/null || true
            )

            ENV_PROFILE=""
            if [[ ${#PROFILE_NAMES[@]} -gt 0 ]]; then
                PROF_ARGS=("(none)" "(none)")
                for n in "${PROFILE_NAMES[@]}"; do PROF_ARGS+=("$n" "$n"); done

                ENV_PROFILE=$(zenity --list \
                    --title="$(wt_title "$MODULE  ›  Env Profile")" \
                    --text="<tt>Apply an env profile before launch? (optional)</tt>" \
                    --column="Key" --column="Profile" \
                    --hide-column=1 --print-column=1 \
                    --width=440 --height=300 \
                    "${PROF_ARGS[@]}") || true

                [[ "$ENV_PROFILE" == "(none)" ]] && ENV_PROFILE=""
            fi

            TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
            EXE_BASE="$(basename "$EXE" .exe)"
            LOG_FILE="$LOG_DIR/${EXE_BASE}_${TIMESTAMP}.log"

            export WT_INNER_WINE WINEPREFIX WT_WRAPPER
            export WT_LOG_EXE="$EXE"
            export WT_LOG_ARGS="${EXTRA_ARGS:-}"
            export WT_LOG_FILE="$LOG_FILE"
            export WT_LOG_ENV_PROFILE="${ENV_PROFILE:-}"
            export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
            export WT_ENV_PROFILE_DIR="${HOME}/.config/winetoolz/env_profiles"

            TMP=$(mktemp --suffix=.sh)
            cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

wt_section "Log Viewer  ›  Running"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
wt_log_info "Exe    : $WT_LOG_EXE"
wt_log_info "Log    : $WT_LOG_FILE"
[[ -n "$WT_LOG_ENV_PROFILE" ]] && wt_log_info "Profile: $WT_LOG_ENV_PROFILE"
printf '\n'

# Load env profile if set
if [[ -n "$WT_LOG_ENV_PROFILE" ]]; then
    pfile="$WT_ENV_PROFILE_DIR/${WT_LOG_ENV_PROFILE}.env"
    if [[ -f "$pfile" ]]; then
        wt_log "Loading env profile: $WT_LOG_ENV_PROFILE"
        # shellcheck source=/dev/null
        source "$pfile"
    fi
fi

wt_log "Launching (all output captured to log)..."
printf '\n'

{
    printf '# winetoolz log\n'
    printf '# Date    : %s\n' "$(date)"
    printf '# Exe     : %s\n' "$WT_LOG_EXE"
    printf '# Prefix  : %s\n' "$WINEPREFIX"
    printf '# Wine    : %s\n' "$WT_INNER_WINE"
    printf '#\n'
    "$WT_INNER_WINE" "$WT_LOG_EXE" $WT_LOG_ARGS 2>&1
} | tee "$WT_LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}
printf '\n'
wt_log_info "Exit code : $EXIT_CODE"
wt_log_info "Log saved : $WT_LOG_FILE"

if [[ $EXIT_CODE -eq 0 ]]; then
    wt_log_ok "Process exited cleanly."
else
    wt_log_err "Process exited with code $EXIT_CODE."
fi

read -rp "  Press Enter to view log in viewer, or Ctrl+C to skip..." < /dev/tty
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"

            # Show the log in zenity text-info after the terminal closes
            if [[ -f "$LOG_FILE" ]]; then
                zenity --text-info \
                    --title="$(wt_title "$MODULE  ›  $(basename "$EXE")")" \
                    --filename="$LOG_FILE" \
                    --width=900 --height=600 \
                    --font="monospace 10" || true
            fi
            ;;

        # ------------------------------------------------------------------
        view)
            shopt -s nullglob
            LOG_FILES=("$LOG_DIR"/*.log)
            shopt -u nullglob

            if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
                wt_info "$MODULE" "No log files saved yet.\nRun an app with  Run & Capture Log  first."
                continue
            fi

            VIEW_ARGS=()
            for f in "${LOG_FILES[@]}"; do
                local size
                size="$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")"
                VIEW_ARGS+=("$f" "$(basename "$f")" "$size" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo ?)")
            done

            SELECTED_LOG=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Select Log")" \
                --text="<tt>Select a log file to view:</tt>" \
                --column="Path" --column="File" --column="Size" --column="Date" \
                --hide-column=1 --print-column=1 \
                --width=720 --height=400 \
                "${VIEW_ARGS[@]}") || continue

            zenity --text-info \
                --title="$(wt_title "$MODULE  ›  $(basename "$SELECTED_LOG")")" \
                --filename="$SELECTED_LOG" \
                --width=900 --height=600 \
                --font="monospace 10" || true
            ;;

        # ------------------------------------------------------------------
        delete)
            shopt -s nullglob
            LOG_FILES=("$LOG_DIR"/*.log)
            shopt -u nullglob
            [[ ${#LOG_FILES[@]} -eq 0 ]] && wt_info "$MODULE" "No log files to delete." && continue

            DEL_ARGS=()
            for f in "${LOG_FILES[@]}"; do
                DEL_ARGS+=("FALSE" "$f" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1 || echo ?)")
            done

            TO_DEL=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Delete Logs")" \
                --checklist \
                --column="Del" --column="Path" --column="File" --column="Size" \
                --hide-column=2 --print-column=2 \
                --print-column=2 \
                --width=680 --height=400 \
                "${DEL_ARGS[@]}") || continue

            [[ -z "$TO_DEL" ]] && continue
            wt_confirm "$MODULE" "$(printf 'Delete these log files?\n\n%s' "$TO_DEL")" || continue

            IFS='|' read -ra DEL_FILES <<< "$TO_DEL"
            for f in "${DEL_FILES[@]}"; do rm -f "$f"; done
            wt_info "$MODULE" "$(printf '✔  Deleted %d log(s).' "${#DEL_FILES[@]}")"
            ;;

        exit|*) break ;;
    esac
done
