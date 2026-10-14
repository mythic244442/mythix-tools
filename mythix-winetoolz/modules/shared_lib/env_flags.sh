#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  env_flags.sh — Launch Environment / Flags Manager
#  winetoolz v2.0
#
#  Toggle common Wine/DXVK/VKD3D env vars, save them as named profiles,
#  and export a profile for use when launching apps.
#
#  Profiles stored as ~/.config/winetoolz/env_profiles/<name>.env
#  (KEY=value lines, sourced directly before wine launches)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Env Flags"
PROFILE_DIR="${HOME}/.config/winetoolz/env_profiles"

wt_require_cmds zenity
mkdir -p "$PROFILE_DIR"

# =============================================================================
#  Known flags — TAG  VAR_NAME  DEFAULT_VALUE  DESCRIPTION
# =============================================================================

declare -A FLAG_VAR FLAG_DEFAULT FLAG_DESC

FLAG_VAR[dxvk_hud]="DXVK_HUD"
FLAG_DEFAULT[dxvk_hud]="1"
FLAG_DESC[dxvk_hud]="DXVK overlay — fps, frametimes, device info"

FLAG_VAR[dxvk_hud_full]="DXVK_HUD"
FLAG_DEFAULT[dxvk_hud_full]="full"
FLAG_DESC[dxvk_hud_full]="DXVK overlay — all stats"

FLAG_VAR[dxvk_async]="DXVK_ASYNC"
FLAG_DEFAULT[dxvk_async]="1"
FLAG_DESC[dxvk_async]="DXVK async shader compilation (reduces stutter)"

FLAG_VAR[dxvk_frame_rate]="DXVK_FRAME_RATE"
FLAG_DEFAULT[dxvk_frame_rate]="60"
FLAG_DESC[dxvk_frame_rate]="DXVK framerate cap"

FLAG_VAR[vkd3d_debug]="VKD3D_DEBUG"
FLAG_DEFAULT[vkd3d_debug]="none"
FLAG_DESC[vkd3d_debug]="VKD3D debug level (none/warn/info/debug/trace)"

FLAG_VAR[vkd3d_shader_debug]="VKD3D_SHADER_DEBUG"
FLAG_DEFAULT[vkd3d_shader_debug]="none"
FLAG_DESC[vkd3d_shader_debug]="VKD3D shader debug level"

FLAG_VAR[winedebug_off]="WINEDEBUG"
FLAG_DEFAULT[winedebug_off]="-all"
FLAG_DESC[winedebug_off]="Suppress all Wine debug output"

FLAG_VAR[winedebug_err]="WINEDEBUG"
FLAG_DEFAULT[winedebug_err]="err+all"
FLAG_DESC[winedebug_err]="Show only Wine error messages"

FLAG_VAR[mesa_glthread]="mesa_glthread"
FLAG_DEFAULT[mesa_glthread]="true"
FLAG_DESC[mesa_glthread]="Mesa GL threading (reduces CPU bottleneck on OpenGL)"

FLAG_VAR[radv_perftest]="RADV_PERFTEST"
FLAG_DEFAULT[radv_perftest]="aco"
FLAG_DESC[radv_perftest]="RADV perf test flags (e.g. aco)"

FLAG_VAR[vk_icd_amd]="VK_ICD_FILENAMES"
FLAG_DEFAULT[vk_icd_amd]="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
FLAG_DESC[vk_icd_amd]="Force AMD Vulkan ICD"

FLAG_VAR[vk_icd_nvidia]="VK_ICD_FILENAMES"
FLAG_DEFAULT[vk_icd_nvidia]="/usr/share/vulkan/icd.d/nvidia_icd.json"
FLAG_DESC[vk_icd_nvidia]="Force NVIDIA Vulkan ICD"

FLAG_VAR[staging_shared_mem]="STAGING_SHARED_MEMORY"
FLAG_DEFAULT[staging_shared_mem]="1"
FLAG_DESC[staging_shared_mem]="Wine Staging shared memory (performance)"

FLAG_VAR[esync]="WINEESYNC"
FLAG_DEFAULT[esync]="1"
FLAG_DESC[esync]="Enable esync (event-based sync, reduces CPU overhead)"

FLAG_VAR[fsync]="WINEFSYNC"
FLAG_DEFAULT[fsync]="1"
FLAG_DESC[fsync]="Enable fsync (futex-based sync, requires patched kernel)"

FLAG_ORDER=(dxvk_hud dxvk_hud_full dxvk_async dxvk_frame_rate \
            vkd3d_debug vkd3d_shader_debug \
            winedebug_off winedebug_err \
            mesa_glthread radv_perftest \
            vk_icd_amd vk_icd_nvidia \
            staging_shared_mem esync fsync)

# =============================================================================
#  Helpers
# =============================================================================

_safe_name() { printf '%s' "$1" | tr -cd '[:alnum:]_-' | tr ' ' '_'; }

_list_profiles() {
    local -a names=()
    local f
    for f in "$PROFILE_DIR"/*.env; do
        [[ -f "$f" ]] && names+=("$(basename "$f" .env)")
    done
    printf '%s\n' "${names[@]}"
}

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="<tt>Manage launch environment variable profiles.\nProfiles are loaded when launching apps.</tt>" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=660 --height=340 \
        "create"  "Create Profile"      "Pick flags from a list and save as a named profile" \
        "view"    "View Profile"        "Show the contents of a saved profile" \
        "edit"    "Edit Profile"        "Add or remove flags from an existing profile" \
        "delete"  "Delete Profile"      "Remove a saved profile" \
        "export"  "Export to Clipboard" "Copy a profile's export commands to clipboard" \
        "exit"    "Back to Main Menu"   "") || break

    case "$CHOICE" in

        # ------------------------------------------------------------------
        create)
            PROF_NAME=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  New Profile")" \
                --text="<tt>Profile name (e.g. dxvk-game, debug, performance):</tt>" \
                --width="$WT_WIDTH") || continue
            [[ -z "$PROF_NAME" ]] && continue

            FLAG_ARGS=()
            for tag in "${FLAG_ORDER[@]}"; do
                FLAG_ARGS+=(
                    "FALSE"
                    "$tag"
                    "${FLAG_VAR[$tag]}=${FLAG_DEFAULT[$tag]}"
                    "${FLAG_DESC[$tag]}"
                )
            done

            SELECTED=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Select Flags  —  $PROF_NAME")" \
                --text="<tt>Check the flags to include in this profile.\nDefault values shown — you can edit them after creation.</tt>" \
                --checklist \
                --column="On" --column="Tag" --column="Variable=Value" --column="Description" \
                --hide-column=2 --print-column=2 \
                --width=860 --height=500 \
                "${FLAG_ARGS[@]}") || continue

            [[ -z "$SELECTED" ]] && continue

            IFS='|' read -ra CHOSEN_TAGS <<< "$SELECTED"

            local prof_file="$PROFILE_DIR/$(_safe_name "$PROF_NAME").env"
            printf '# winetoolz env profile: %s\n' "$PROF_NAME" > "$prof_file"
            for tag in "${CHOSEN_TAGS[@]}"; do
                printf 'export %s="%s"\n' "${FLAG_VAR[$tag]}" "${FLAG_DEFAULT[$tag]}" >> "$prof_file"
            done

            wt_info "$MODULE" "$(printf '✔  Profile saved:  %s\n\n  File : %s\n\nContents:\n%s' \
                "$PROF_NAME" "$prof_file" "$(cat "$prof_file")")"
            ;;

        # ------------------------------------------------------------------
        view)
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            if [[ ${#PROFILE_NAMES[@]} -eq 0 ]]; then
                wt_info "$MODULE" "No profiles saved yet."
                continue
            fi

            VIEW_ARGS=()
            for n in "${PROFILE_NAMES[@]}"; do
                VIEW_ARGS+=("$n" "$n")
            done

            SELECTED_PROF=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  View Profile")" \
                --text="<tt>Select a profile to view:</tt>" \
                --column="Key" --column="Profile" \
                --hide-column=1 --print-column=1 \
                --width=400 --height=300 \
                "${VIEW_ARGS[@]}") || continue

            local pfile="$PROFILE_DIR/${SELECTED_PROF}.env"
            wt_info "$MODULE  ›  $SELECTED_PROF" "$(cat "$pfile")"
            ;;

        # ------------------------------------------------------------------
        edit)
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && wt_info "$MODULE" "No profiles saved yet." && continue

            EDIT_ARGS=()
            for n in "${PROFILE_NAMES[@]}"; do EDIT_ARGS+=("$n" "$n"); done

            SELECTED_PROF=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Edit Profile")" \
                --column="Key" --column="Profile" \
                --hide-column=1 --print-column=1 \
                --width=400 --height=300 \
                "${EDIT_ARGS[@]}") || continue

            local pfile="$PROFILE_DIR/${SELECTED_PROF}.env"

            # Open in zenity text editor (text-info with editable)
            EDITED=$(zenity --text-info \
                --title="$(wt_title "$MODULE  ›  Edit  —  $SELECTED_PROF")" \
                --filename="$pfile" \
                --editable \
                --width=600 --height=400) || continue

            printf '%s' "$EDITED" > "$pfile"
            wt_info "$MODULE" "$(printf '✔  Profile updated:  %s' "$SELECTED_PROF")"
            ;;

        # ------------------------------------------------------------------
        delete)
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && wt_info "$MODULE" "No profiles saved yet." && continue

            DEL_ARGS=()
            for n in "${PROFILE_NAMES[@]}"; do DEL_ARGS+=("FALSE" "$n"); done

            TO_DEL=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Delete")" \
                --checklist --column="Del" --column="Profile" \
                --print-column=2 \
                --width=400 --height=300 \
                "${DEL_ARGS[@]}") || continue

            [[ -z "$TO_DEL" ]] && continue
            wt_confirm "$MODULE" "$(printf 'Delete these profiles?\n\n%s' "$TO_DEL")" || continue

            IFS='|' read -ra DEL_PROFILES <<< "$TO_DEL"
            for p in "${DEL_PROFILES[@]}"; do
                rm -f "$PROFILE_DIR/${p}.env"
            done
            wt_info "$MODULE" "$(printf '✔  Deleted %d profile(s).' "${#DEL_PROFILES[@]}")"
            ;;

        # ------------------------------------------------------------------
        export)
            mapfile -t PROFILE_NAMES < <(_list_profiles)
            [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && wt_info "$MODULE" "No profiles saved yet." && continue

            EXP_ARGS=()
            for n in "${PROFILE_NAMES[@]}"; do EXP_ARGS+=("$n" "$n"); done

            SELECTED_PROF=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Export to Clipboard")" \
                --column="Key" --column="Profile" \
                --hide-column=1 --print-column=1 \
                --width=400 --height=300 \
                "${EXP_ARGS[@]}") || continue

            local pfile="$PROFILE_DIR/${SELECTED_PROF}.env"
            cat "$pfile" | xclip -selection clipboard 2>/dev/null \
                || cat "$pfile" | xsel --clipboard 2>/dev/null \
                || { wt_info "$MODULE" "$(printf 'Could not find xclip or xsel.\n\nProfile contents:\n\n%s' "$(cat "$pfile")")"; continue; }

            wt_info "$MODULE" "$(printf '✔  Copied to clipboard:  %s' "$SELECTED_PROF")"
            ;;

        exit|*) break ;;
    esac
done
