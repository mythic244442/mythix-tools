#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  app_launcher.sh — Application Launcher / Shortcut Manager
#  winetoolz v2.1
#
#  Save named shortcuts (Wine binary + prefix + exe + args + env profile).
#  Features:
#    • Env profile integration (from env_flags.sh profiles)
#    • Last-launch timestamp tracking
#    • Icon extraction via wrestool/icotool (graceful fallback)
#  Shortcuts stored as ~/.config/winetoolz/launchers/<name>.conf
#  Icons cached at    ~/.config/winetoolz/icons/<name>.png
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="App Launcher"
LAUNCHER_DIR="${HOME}/.config/winetoolz/launchers"
ICON_DIR="${HOME}/.config/winetoolz/icons"
PROFILE_DIR="${HOME}/.config/winetoolz/env_profiles"

wt_require_cmds zenity
mkdir -p "$LAUNCHER_DIR" "$ICON_DIR" "$PROFILE_DIR"

# =============================================================================
#  Helpers
# =============================================================================

_safe_name() {
    printf '%s' "$1" | tr -cd '[:alnum:]_. -' | tr ' ' '_'
}

_load_shortcut() {
    local file="$1"
    unset SC_NAME SC_WINE SC_PREFIX SC_EXE SC_ARGS SC_ENV SC_ENV_PROFILE SC_WORKDIR SC_LAST_LAUNCH
    # shellcheck source=/dev/null
    source "$file"
}

_save_shortcut() {
    local file="$1"
    cat > "$file" << CONFEOF
SC_NAME="${SC_NAME:-}"
SC_WINE="${SC_WINE:-}"
SC_PREFIX="${SC_PREFIX:-}"
SC_EXE="${SC_EXE:-}"
SC_ARGS="${SC_ARGS:-}"
SC_ENV="${SC_ENV:-}"
SC_ENV_PROFILE="${SC_ENV_PROFILE:-}"
SC_WORKDIR="${SC_WORKDIR:-}"
SC_LAST_LAUNCH="${SC_LAST_LAUNCH:-}"
CONFEOF
}

# Extract icon from a Windows .exe into the icon cache
# Requires: wrestool + icotool (icoutils package)
# Silently skips if tools are unavailable or extraction fails
_extract_icon() {
    local exe="$1"
    local name="$2"
    local out="$ICON_DIR/$(_safe_name "$name").png"

    [[ -f "$out" ]] && echo "$out" && return 0  # already cached

    command -v wrestool >/dev/null 2>&1 || return 1
    command -v icotool  >/dev/null 2>&1 || return 1

    local tmp_ico
    tmp_ico="$(mktemp --suffix=.ico)"
    trap 'rm -f "$tmp_ico"' RETURN

    # Extract largest icon group from exe
    wrestool -x -t 14 "$exe" -o "$tmp_ico" 2>/dev/null || return 1
    [[ -s "$tmp_ico" ]] || return 1

    # Convert to PNG, pick the largest size available
    icotool -x -o "$ICON_DIR" "$tmp_ico" 2>/dev/null || return 1

    # icotool writes files like name_NxN.png — grab the largest
    local best
    best="$(ls -S "$ICON_DIR"/$(basename "$tmp_ico" .ico)_*.png 2>/dev/null | head -1 || true)"
    if [[ -n "$best" ]]; then
        mv "$best" "$out"
        # Clean up any other sizes icotool extracted
        rm -f "$ICON_DIR"/$(basename "$tmp_ico" .ico)_*.png 2>/dev/null || true
        echo "$out"
    fi
}

# List available env profile names
_list_profiles() {
    local f
    for f in "$PROFILE_DIR"/*.env; do
        [[ -f "$f" ]] && basename "$f" .env
    done 2>/dev/null || true
}

# Format last-launch timestamp for display
_fmt_launch() {
    local ts="${1:-}"
    [[ -z "$ts" ]] && echo "never" && return
    echo "$ts"
}

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    # Build dynamic subtitle showing shortcut count
    shopt -s nullglob
    ALL_CONFS=("$LAUNCHER_DIR"/*.conf)
    shopt -u nullglob
    SC_COUNT="${#ALL_CONFS[@]}"

    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>Manage and launch saved Wine application shortcuts.\nSaved shortcuts: %d</tt>' "$SC_COUNT")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=680 --height=340 \
        "launch"  "Launch Shortcut"    "Pick a saved shortcut and run it" \
        "add"     "New Shortcut"       "Create a new launcher entry" \
        "edit"    "Edit Shortcut"      "Modify an existing shortcut" \
        "delete"  "Delete Shortcut"    "Remove a saved shortcut" \
        "list"    "List All"           "View all saved shortcuts with details" \
        "exit"    "Back to Main Menu"  "") || break

    case "$CHOICE" in

        # ------------------------------------------------------------------
        launch)
            shopt -s nullglob
            CONF_FILES=("$LAUNCHER_DIR"/*.conf)
            shopt -u nullglob

            if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
                wt_info "$MODULE" "No shortcuts saved yet.\nUse  New Shortcut  to create one."
                continue
            fi

            LAUNCH_ARGS=()
            for f in "${CONF_FILES[@]}"; do
                _load_shortcut "$f"
                LAUNCH_ARGS+=("$f"
                    "${SC_NAME:-$(basename "$f" .conf)}"
                    "$(basename "${SC_EXE:-?}")"
                    "${SC_ENV_PROFILE:-(none)}"
                    "$(_fmt_launch "${SC_LAST_LAUNCH:-}")")
            done

            SELECTED_FILE=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Launch")" \
                --text="<tt>Select a shortcut to launch:</tt>" \
                --column="File" --column="Name" --column="Executable" \
                --column="Env Profile" --column="Last Launch" \
                --hide-column=1 --print-column=1 \
                --width=860 --height=420 \
                "${LAUNCH_ARGS[@]}") || continue

            _load_shortcut "$SELECTED_FILE"

            # Stamp last-launch time back into the conf
            SC_LAST_LAUNCH="$(date '+%Y-%m-%d %H:%M')"
            _save_shortcut "$SELECTED_FILE"

            export WT_INNER_WINE="$SC_WINE"
            export WINEPREFIX="$SC_PREFIX"
            export WT_SC_EXE="$SC_EXE"
            export WT_SC_ARGS="${SC_ARGS:-}"
            export WT_SC_NAME="$SC_NAME"
            export WT_SC_ENV="${SC_ENV:-}"
            export WT_SC_ENV_PROFILE="${SC_ENV_PROFILE:-}"
            export WT_SC_WORKDIR="${SC_WORKDIR:-$(dirname "$SC_EXE")}"
            export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
            export WT_PROFILE_DIR="$PROFILE_DIR"

            TMP=$(mktemp --suffix=.sh)
            cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

wt_section "App Launcher  ›  $WT_SC_NAME"
wt_log_info "Wine    : $WT_INNER_WINE"
wt_log_info "Prefix  : $WINEPREFIX"
wt_log_info "Exe     : $WT_SC_EXE"
[[ -n "$WT_SC_ARGS" ]]        && wt_log_info "Args    : $WT_SC_ARGS"
[[ -n "$WT_SC_ENV" ]]         && wt_log_info "Env     : $WT_SC_ENV"
[[ -n "$WT_SC_ENV_PROFILE" ]] && wt_log_info "Profile : $WT_SC_ENV_PROFILE"
printf '\n'

# Load named env profile first
if [[ -n "$WT_SC_ENV_PROFILE" ]]; then
    pfile="$WT_PROFILE_DIR/${WT_SC_ENV_PROFILE}.env"
    if [[ -f "$pfile" ]]; then
        wt_log "Loading env profile: $WT_SC_ENV_PROFILE"
        # shellcheck source=/dev/null
        source "$pfile"
    else
        wt_log_err "Env profile not found: $pfile  (continuing anyway)"
    fi
fi

# Apply any inline env vars on top
if [[ -n "$WT_SC_ENV" ]]; then
    export $WT_SC_ENV
fi

cd "$WT_SC_WORKDIR" 2>/dev/null || true

wt_log "Launching..."
"$WT_INNER_WINE" "$WT_SC_EXE" $WT_SC_ARGS
EXIT_CODE=$?
printf '\n'
if [[ $EXIT_CODE -eq 0 ]]; then
    wt_log_ok "$WT_SC_NAME exited cleanly."
else
    wt_log_err "$WT_SC_NAME exited with code $EXIT_CODE."
fi
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"
            ;;

        # ------------------------------------------------------------------
        add)
            SC_NAME=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  New Shortcut")" \
                --text="<tt>Shortcut name (shown in the launcher list):</tt>" \
                --width="$WT_WIDTH") || continue
            [[ -z "$SC_NAME" ]] && continue

            wt_select_wine_bin "$MODULE  ›  New Shortcut" || continue
            SC_WINE="$WT_INNER_WINE"

            wt_select_prefix_from_config "$MODULE  ›  New Shortcut" || continue
            SC_PREFIX="$WINEPREFIX"

            SC_EXE=$(zenity --file-selection \
                --title="$(wt_title "$MODULE  ›  Select Executable")" \
                --filename="$SC_PREFIX/drive_c/" \
                --file-filter="Windows executables | *.exe *.EXE *.bat *.BAT" \
                --width=760) || continue

            # Optional: attach an env profile
            SC_ENV_PROFILE=""
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            if [[ ${#PROFILE_NAMES[@]} -gt 0 ]]; then
                PROF_ARGS=("(none)" "(none) — no env profile")
                for n in "${PROFILE_NAMES[@]}"; do
                    PROF_ARGS+=("$n" "$n")
                done
                SC_ENV_PROFILE=$(zenity --list \
                    --title="$(wt_title "$MODULE  ›  Env Profile")" \
                    --text="<tt>Attach an env profile to this shortcut? (optional)\nThe profile will be loaded automatically on launch.</tt>" \
                    --column="Key" --column="Profile" \
                    --hide-column=1 --print-column=1 \
                    --width=500 --height=320 \
                    "${PROF_ARGS[@]}") || true
                [[ "$SC_ENV_PROFILE" == "(none)" ]] && SC_ENV_PROFILE=""
            fi

            # Optional: extra inline args + env
            EXTRA=$(zenity --forms \
                --title="$(wt_title "$MODULE  ›  New Shortcut  —  Optional")" \
                --text="$(printf '<tt>Optional settings for:  %s</tt>' "$SC_NAME")" \
                --add-entry="Launch arguments (optional)" \
                --add-entry="Extra inline env vars  e.g: DXVK_HUD=1" \
                --width=580) || true

            SC_ARGS=""
            SC_ENV=""
            if [[ -n "$EXTRA" ]]; then
                SC_ARGS="$(echo "$EXTRA" | cut -d'|' -f1)"
                SC_ENV="$(echo  "$EXTRA" | cut -d'|' -f2)"
            fi

            SC_WORKDIR="$(dirname "$SC_EXE")"
            SC_LAST_LAUNCH=""

            safe=""
            conf=""
            safe="$(_safe_name "$SC_NAME")"
            conf="$LAUNCHER_DIR/${safe}.conf"
            _save_shortcut "$conf"

            # Try icon extraction in background — non-blocking, silent on failure
            _extract_icon "$SC_EXE" "$SC_NAME" >/dev/null 2>&1 &

            wt_info "$MODULE" "$(printf '✔  Shortcut saved:\n\n  Name    : %s\n  Wine    : %s\n  Prefix  : %s\n  Exe     : %s\n  Profile : %s' \
                "$SC_NAME" "$SC_WINE" "$SC_PREFIX" "$SC_EXE" "${SC_ENV_PROFILE:-(none)}")"
            ;;

        # ------------------------------------------------------------------
        edit)
            shopt -s nullglob
            CONF_FILES=("$LAUNCHER_DIR"/*.conf)
            shopt -u nullglob
            [[ ${#CONF_FILES[@]} -eq 0 ]] && wt_info "$MODULE" "No shortcuts saved yet." && continue

            EDIT_ARGS=()
            for f in "${CONF_FILES[@]}"; do
                _load_shortcut "$f"
                EDIT_ARGS+=("$f" "${SC_NAME:-$(basename "$f" .conf)}" "${SC_EXE:-?}" "${SC_ENV_PROFILE:-(none)}")
            done

            SELECTED_FILE=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Edit")" \
                --text="<tt>Select a shortcut to edit:</tt>" \
                --column="File" --column="Name" --column="Executable" --column="Profile" \
                --hide-column=1 --print-column=1 \
                --width=780 --height=380 \
                "${EDIT_ARGS[@]}") || continue

            _load_shortcut "$SELECTED_FILE"

            # --- Edit env profile ---
            NEW_ENV_PROFILE="${SC_ENV_PROFILE:-}"
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            if [[ ${#PROFILE_NAMES[@]} -gt 0 ]]; then
                PROF_ARGS=("(none)" "(none) — remove env profile")
                for n in "${PROFILE_NAMES[@]}"; do PROF_ARGS+=("$n" "$n"); done
                NEW_ENV_PROFILE=$(zenity --list \
                    --title="$(wt_title "$MODULE  ›  Env Profile  —  $SC_NAME")" \
                    --text="$(printf '<tt>Current profile:  %s\n\nSelect a new profile or (none):</tt>' "${SC_ENV_PROFILE:-(none)}")" \
                    --column="Key" --column="Profile" \
                    --hide-column=1 --print-column=1 \
                    --width=500 --height=320 \
                    "${PROF_ARGS[@]}") || NEW_ENV_PROFILE="${SC_ENV_PROFILE:-}"
                [[ "$NEW_ENV_PROFILE" == "(none)" ]] && NEW_ENV_PROFILE=""
            fi
            SC_ENV_PROFILE="$NEW_ENV_PROFILE"

            # --- Edit name/args/env ---
            EXTRA=$(zenity --forms \
                --title="$(wt_title "$MODULE  ›  Edit  —  $SC_NAME")" \
                --text="<tt>Edit fields (leave blank to keep current value):\n\nCurrent args    : ${SC_ARGS:-}\nCurrent env     : ${SC_ENV:-}</tt>" \
                --add-entry="Shortcut name" \
                --add-entry="Launch arguments" \
                --add-entry="Extra inline env vars" \
                --width=600) || continue

            new_name="" new_args="" new_env=""
            new_name="$(echo "$EXTRA" | cut -d'|' -f1)"
            new_args="$(echo "$EXTRA" | cut -d'|' -f2)"
            new_env="$(echo  "$EXTRA" | cut -d'|' -f3)"

            [[ -n "$new_name" ]] && SC_NAME="$new_name"
            [[ -n "$new_args" ]] && SC_ARGS="$new_args"
            [[ -n "$new_env"  ]] && SC_ENV="$new_env"

            _save_shortcut "$SELECTED_FILE"
            wt_info "$MODULE" "$(printf '✔  Shortcut updated:\n\n  Name    : %s\n  Profile : %s\n  Args    : %s' \
                "$SC_NAME" "${SC_ENV_PROFILE:-(none)}" "${SC_ARGS:-}")"
            ;;

        # ------------------------------------------------------------------
        delete)
            shopt -s nullglob
            CONF_FILES=("$LAUNCHER_DIR"/*.conf)
            shopt -u nullglob
            [[ ${#CONF_FILES[@]} -eq 0 ]] && wt_info "$MODULE" "No shortcuts saved yet." && continue

            DEL_ARGS=()
            for f in "${CONF_FILES[@]}"; do
                _load_shortcut "$f"
                DEL_ARGS+=("FALSE" "$f" "${SC_NAME:-$(basename "$f" .conf)}" "${SC_EXE:-?}")
            done

            TO_DELETE=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Delete")" \
                --text="<tt>Select shortcuts to delete:</tt>" \
                --checklist \
                --column="Del" --column="File" --column="Name" --column="Executable" \
                --hide-column=2 --print-column=2 \
                --width=700 --height=380 \
                "${DEL_ARGS[@]}") || continue

            [[ -z "$TO_DELETE" ]] && continue

            wt_confirm "$MODULE  ›  Delete" \
                "$(printf 'Delete the following shortcuts?\n\n%s' "$TO_DELETE")" || continue

            IFS='|' read -ra DEL_FILES <<< "$TO_DELETE"
            for f in "${DEL_FILES[@]}"; do
                _load_shortcut "$f"
                rm -f "$f"
                # Also remove cached icon if present
                rm -f "$ICON_DIR/$(_safe_name "${SC_NAME:-}").png" 2>/dev/null || true
            done
            wt_info "$MODULE" "$(printf '✔  Deleted %d shortcut(s).' "${#DEL_FILES[@]}")"
            ;;

        # ------------------------------------------------------------------
        list)
            shopt -s nullglob
            CONF_FILES=("$LAUNCHER_DIR"/*.conf)
            shopt -u nullglob
            if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
                wt_info "$MODULE" "No shortcuts saved yet."
                continue
            fi
            listing=""
            for f in "${CONF_FILES[@]}"; do
                _load_shortcut "$f"
                icon_status="no icon"
                [[ -f "$ICON_DIR/$(_safe_name "${SC_NAME:-}").png" ]] && icon_status="icon cached"
                listing+="$(printf \
                    '  %-22s  %s\n    Wine    : %s\n    Prefix  : %s\n    Args    : %s\n    Profile : %s\n    Launched: %s\n    Icon    : %s\n\n' \
                    "${SC_NAME:-?}" "$(basename "${SC_EXE:-?}")" \
                    "${SC_WINE:-?}" "${SC_PREFIX:-?}" \
                    "${SC_ARGS:-(none)}" "${SC_ENV_PROFILE:-(none)}" \
                    "$(_fmt_launch "${SC_LAST_LAUNCH:-}")" "$icon_status")"
            done
            wt_info "$MODULE  ›  All Shortcuts" "$listing"
            ;;

        exit|*) break ;;
    esac
done
