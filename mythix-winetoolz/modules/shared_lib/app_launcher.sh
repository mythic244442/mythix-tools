#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  app_launcher.sh — Application Launcher / Shortcut Manager
#  winetoolz v3.0
#
#  Save named shortcuts (Wine binary + prefix + exe + args + env profile).
#  Features:
#    • Env profile integration (from env_flags.sh profiles)
#    • Last-launch timestamp tracking
#    • Icon extraction via wrestool/icotool (graceful fallback)
#  Shortcuts stored as ~/.config/winetoolz/launchers/<name>.conf
#  (KEY="value" lines — read as data, never run as shell code)
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

SC_KEYS=(SC_NAME SC_WINE SC_PREFIX SC_EXE SC_ARGS SC_ENV SC_ENV_PROFILE SC_WORKDIR SC_LAST_LAUNCH)

# File-name form of a shortcut name: spaces → _, other symbols dropped,
# no leading dots (hidden files). Empty when nothing usable is left.
_safe_name() {
    local n="${1// /_}"
    n="${n//[^[:alnum:]_.-]/}"
    n="${n#"${n%%[!.]*}"}"
    printf '%s' "$n"
}

_load_shortcut() {
    local file="$1"
    unset "${SC_KEYS[@]}"
    wt_kv_load "$file" '^SC_' || true
}

_save_shortcut() {
    wt_kv_save "$1" "${SC_KEYS[@]}"
}

# Extract icon from a Windows .exe into the icon cache
# Requires: wrestool + icotool (icoutils package)
# Silently skips if tools are unavailable or extraction fails
_extract_icon() {
    local exe="$1"
    local name="$2"
    local out base
    base="$(_safe_name "$name")"
    [[ -n "$base" ]] || return 1
    out="$ICON_DIR/$base.png"

    [[ -f "$out" ]] && echo "$out" && return 0  # already cached

    command -v wrestool >/dev/null 2>&1 || return 1
    command -v icotool  >/dev/null 2>&1 || return 1

    local work
    work="$(mktemp -d)" || return 1

    # Extract largest icon group from exe, convert to PNG, keep the largest
    if wrestool -x -t 14 "$exe" -o "$work/icon.ico" 2>/dev/null && [[ -s "$work/icon.ico" ]] \
       && icotool -x -o "$work" "$work/icon.ico" 2>/dev/null; then
        local best
        best="$(find "$work" -maxdepth 1 -name '*.png' -printf '%s\t%p\n' | sort -rn | sed -n '1s/^[0-9]*\t//p')"
        if [[ -n "$best" ]]; then
            mv -f -- "$best" "$out"
            echo "$out"
        fi
    fi
    rm -rf -- "$work"
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
    CHOICE="${CHOICE%%|*}"

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

            # The Wine build may have been updated or removed since.
            if [[ ! -x "${SC_WINE:-}" ]]; then
                wt_confirm "$MODULE  ›  Wine Missing" "$(printf 'The Wine build of this shortcut is gone:\n  %s\n\nPick another one for it?' "${SC_WINE:-(none)}")" || continue
                wt_select_wine_bin "$MODULE  ›  ${SC_NAME:-Shortcut}" || continue
                SC_WINE="$WT_INNER_WINE"
            fi
            if [[ ! -f "${SC_EXE:-}" ]]; then
                wt_error_return "$(printf 'The program of this shortcut is gone:\n  %s\n\nUse  Edit Shortcut  to pick it again.' "${SC_EXE:-(none)}")"
                continue
            fi
            # Wine would quietly make a fresh, empty prefix in its place.
            if [[ -z "${SC_PREFIX:-}" || ! -f "$SC_PREFIX/system.reg" ]]; then
                wt_error_return "$(printf 'The prefix of this shortcut is gone:\n  %s\n\nUse  Edit Shortcut  to pick it again.' "${SC_PREFIX:-(none)}")"
                continue
            fi
            SC_NAME="${SC_NAME:-$(basename "$SELECTED_FILE" .conf)}"

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

# Load named env profile first (checked for syntax errors first)
if [[ -n "$WT_SC_ENV_PROFILE" ]]; then
    wt_log "Loading env profile: $WT_SC_ENV_PROFILE"
    wt_source_env_profile "$WT_PROFILE_DIR/${WT_SC_ENV_PROFILE}.env" || wt_log_err "(continuing without it)"
fi

# Apply any inline env vars on top (NAME=value pairs only)
wt_env_apply "$WT_SC_ENV"

cd "$WT_SC_WORKDIR" 2>/dev/null || true

# Arguments keep their quoting ("C:\My Games\x" stays one argument);
# .bat / .msi / .lnk files start the way Windows would start them.
mapfile -d '' -t ARGS < <(wt_split_args "$WT_SC_ARGS")
wt_windows_cmd "$WT_SC_EXE"

wt_log "Launching..."
"$WT_INNER_WINE" "${WT_WINCMD[@]}" "${ARGS[@]}"
EXIT_CODE=$?
printf '\n'
if [[ $EXIT_CODE -eq 0 ]]; then
    wt_log_ok "$WT_SC_NAME exited cleanly."
else
    wt_log_err "$WT_SC_NAME exited with code $EXIT_CODE."
fi
wt_pause
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"
            rm -f "$TMP"
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
                --file-filter="Windows programs | *.exe *.EXE *.bat *.BAT *.cmd *.msi *.MSI *.lnk" \
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
                --text="$(_wt_box "$(printf 'Optional settings for:  %s' "$SC_NAME")")" \
                --add-entry="Launch arguments (optional)" \
                --add-entry="Extra inline env vars  e.g: DXVK_HUD=1" \
                --separator=$'\x1f' \
                --width=580) || true

            SC_ARGS=""
            SC_ENV=""
            if [[ -n "$EXTRA" ]]; then
                IFS=$'\x1f' read -r SC_ARGS SC_ENV _ <<< "$EXTRA" || true
            fi

            SC_WORKDIR="$(dirname "$SC_EXE")"
            SC_LAST_LAUNCH=""

            safe="$(_safe_name "$SC_NAME")"
            [[ -n "$safe" ]] || safe="shortcut-$(date +%Y%m%d%H%M%S)"
            conf="$LAUNCHER_DIR/${safe}.conf"
            if [[ -f "$conf" ]]; then
                wt_confirm "$MODULE" "$(printf 'A shortcut saved as  %s  already exists.\n\nReplace it?' "$safe")" || continue
            fi
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

            # --- Edit: one field at a time until Save ---
            while :; do
                FIELD=$(zenity --list \
                    --title="$(wt_title "$MODULE  ›  Edit  —  ${SC_NAME:-}")" \
                    --text="$(_wt_box "Pick what to change, then Save.")" \
                    --column="Key" --column="Field" --column="Current value" \
                    --hide-column=1 --print-column=1 \
                    --width=820 --height=420 \
                    "name"    "Name"             "${SC_NAME:-}" \
                    "wine"    "Wine build"       "${SC_WINE:-}" \
                    "prefix"  "Prefix"           "${SC_PREFIX:-}" \
                    "exe"     "Program"          "${SC_EXE:-}" \
                    "args"    "Launch arguments" "${SC_ARGS:-(none)}" \
                    "env"     "Inline env vars"  "${SC_ENV:-(none)}" \
                    "profile" "Env profile"      "${SC_ENV_PROFILE:-(none)}" \
                    "save"    "✔  Save"           "") || continue 2
                FIELD="${FIELD%%|*}"

                case "$FIELD" in
                    name|args|env)
                        case "$FIELD" in
                            name) cur="${SC_NAME:-}" ;; args) cur="${SC_ARGS:-}" ;; env) cur="${SC_ENV:-}" ;;
                        esac
                        val=$(zenity --entry \
                            --title="$(wt_title "$MODULE  ›  Edit")" \
                            --text="$(_wt_box "New value (empty clears it):")" \
                            --entry-text="$cur" \
                            --width=600) || continue
                        case "$FIELD" in
                            name) [[ -n "$val" ]] && SC_NAME="$val" ;;
                            args) SC_ARGS="$val" ;;
                            env)  SC_ENV="$val" ;;
                        esac
                        ;;
                    wine)
                        wt_select_wine_bin "$MODULE  ›  Edit" && SC_WINE="$WT_INNER_WINE" ;;
                    prefix)
                        wt_select_prefix_from_config "$MODULE  ›  Edit" && SC_PREFIX="$WINEPREFIX" ;;
                    exe)
                        val=$(zenity --file-selection \
                            --title="$(wt_title "$MODULE  ›  Select Executable")" \
                            --filename="${SC_PREFIX:-$HOME}/drive_c/" \
                            --file-filter="Windows programs | *.exe *.EXE *.bat *.BAT *.cmd *.msi *.MSI *.lnk" \
                            --width=760) && { SC_EXE="$val"; SC_WORKDIR="$(dirname "$val")"; }
                        ;;
                    profile)
                        mapfile -t PROFILE_NAMES < <(_list_profiles)
                        PROF_ARGS=("(none)" "(none) — no env profile")
                        for n in "${PROFILE_NAMES[@]}"; do PROF_ARGS+=("$n" "$n"); done
                        val=$(zenity --list \
                            --title="$(wt_title "$MODULE  ›  Env Profile")" \
                            --column="Key" --column="Profile" \
                            --hide-column=1 --print-column=1 \
                            --width=500 --height=320 \
                            "${PROF_ARGS[@]}") || continue
                        val="${val%%|*}"
                        [[ "$val" == "(none)" ]] && val=""
                        SC_ENV_PROFILE="$val"
                        ;;
                    save|*) break ;;
                esac
            done

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

            IFS='|' read -ra DEL_FILES <<< "$TO_DELETE"
            DEL_NAMES=""
            for f in "${DEL_FILES[@]}"; do
                _load_shortcut "$f"
                DEL_NAMES+="  •  ${SC_NAME:-$(basename "$f" .conf)}"$'\n'
            done
            wt_confirm "$MODULE  ›  Delete" \
                "$(printf 'Delete the following shortcuts?\n\n%s' "$DEL_NAMES")" || continue

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
