#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  env_flags.sh — Launch Environment / Flags Manager
#  winetoolz v3.0
#
#  Toggle common Wine/DXVK/VKD3D env vars, save them as named profiles,
#  and export a profile for use when launching apps.
#
#  Profiles stored as ~/.config/winetoolz/env_profiles/<name>.env
#  (export KEY="value" lines, sourced before wine launches — checked for
#  syntax errors first)
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
FLAG_DESC[dxvk_async]="Async shader compilation — only dxvk-async / gplasync builds (e.g. GE-Proton)"

FLAG_VAR[dxvk_nvapi]="DXVK_ENABLE_NVAPI"
FLAG_DEFAULT[dxvk_nvapi]="1"
FLAG_DESC[dxvk_nvapi]="Let DXVK expose NVAPI (DLSS, Reflex) — needs DXVK-NVAPI installed"

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

FLAG_VAR[mangohud]="MANGOHUD"
FLAG_DEFAULT[mangohud]="1"
FLAG_DESC[mangohud]="MangoHud overlay (Vulkan) — needs the mangohud package"

FLAG_VAR[fsr]="WINE_FULLSCREEN_FSR"
FLAG_DEFAULT[fsr]="1"
FLAG_DESC[fsr]="AMD FSR 1 upscaling for fullscreen games — Proton / GE / Wine-TKG builds"

FLAG_VAR[laa]="WINE_LARGE_ADDRESS_AWARE"
FLAG_DEFAULT[laa]="1"
FLAG_DESC[laa]="Give 32-bit games 4 GB of address space — Proton / GE / Staging builds"

FLAG_VAR[nv_cache]="__GL_SHADER_DISK_CACHE_SKIP_CLEANUP"
FLAG_DEFAULT[nv_cache]="1"
FLAG_DESC[nv_cache]="NVIDIA: keep the shader cache past its default size limit"

FLAG_VAR[vk_icd_amd]="VK_DRIVER_FILES"
FLAG_DEFAULT[vk_icd_amd]="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
FLAG_DESC[vk_icd_amd]="Force AMD Vulkan ICD"

FLAG_VAR[vk_icd_nvidia]="VK_DRIVER_FILES"
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
FLAG_DESC[fsync]="Enable fsync (futex-based sync) — Linux 5.16+ and an fsync-enabled Wine/Proton"

FLAG_ORDER=(dxvk_hud dxvk_hud_full dxvk_async dxvk_frame_rate dxvk_nvapi \
            vkd3d_debug vkd3d_shader_debug \
            winedebug_off winedebug_err \
            mesa_glthread mangohud fsr laa nv_cache \
            vk_icd_amd vk_icd_nvidia \
            staging_shared_mem esync fsync)

# =============================================================================
#  Helpers
# =============================================================================

# Spaces become underscores; anything but letters, digits, _ and - is dropped.
_safe_name() { local n="${1// /_}"; printf '%s' "${n//[^[:alnum:]_-]/}"; }

_list_profiles() {
    local f
    for f in "$PROFILE_DIR"/*.env; do
        if [[ -f "$f" ]]; then basename "$f" .env; fi
    done
    return 0
}

# _pick_profile <title> — prints the chosen profile name (non-zero on cancel)
_pick_profile() {
    local -a names=() args=()
    local n
    mapfile -t names < <(_list_profiles)
    if (( ${#names[@]} == 0 )); then
        wt_info "$MODULE" "No profiles saved yet."
        return 1
    fi
    for n in "${names[@]}"; do args+=("$n" "$n"); done
    zenity --list \
        --title="$(wt_title "$MODULE  ›  $1")" \
        --column="Key" --column="Profile" \
        --hide-column=1 --print-column=1 \
        --width=400 --height=300 \
        "${args[@]}" | sed 's/|.*//'
    (( PIPESTATUS[0] == 0 ))
}

# _copy_to_clipboard <file> — Wayland or X11
_copy_to_clipboard() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && _wt_have wl-copy; then wl-copy < "$1"
    elif _wt_have xclip; then xclip -selection clipboard < "$1"
    elif _wt_have xsel;  then xsel --clipboard --input < "$1"
    else return 1
    fi
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
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in

        # ------------------------------------------------------------------
        create)
            PROF_NAME=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  New Profile")" \
                --text="<tt>Profile name (e.g. dxvk-game, debug, performance):</tt>" \
                --width="$WT_WIDTH") || continue
            [[ -z "$PROF_NAME" ]] && continue
            SAFE_NAME="$(_safe_name "$PROF_NAME")"
            if [[ -z "$SAFE_NAME" ]]; then
                wt_error_return "Use letters, digits, - or _ in the profile name."
                continue
            fi
            prof_file="$PROFILE_DIR/${SAFE_NAME}.env"
            if [[ -f "$prof_file" ]]; then
                wt_confirm "$MODULE" "$(printf 'A profile named  %s  already exists.\n\nReplace it?' "$SAFE_NAME")" || continue
            fi

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

            # One line per variable: when two picks set the same one (two
            # DXVK_HUD styles, two WINEDEBUG levels) the later pick wins.
            declare -A PICKED=()
            ORDER=()
            for tag in "${CHOSEN_TAGS[@]}"; do
                var="${FLAG_VAR[$tag]:-}"
                [[ -n "$var" ]] || continue
                [[ -n "${PICKED[$var]:-}" ]] || ORDER+=("$var")
                PICKED[$var]="${FLAG_DEFAULT[$tag]}"
            done
            {
                printf '# winetoolz env profile: %s\n' "$PROF_NAME"
                for var in "${ORDER[@]}"; do
                    printf 'export %s="%s"\n' "$var" "${PICKED[$var]}"
                done
            } > "$prof_file"
            unset PICKED

            wt_info "$MODULE" "$(printf '✔  Profile saved:  %s\n\n  File : %s\n\nContents:\n%s' \
                "$SAFE_NAME" "$prof_file" "$(cat "$prof_file")")"
            ;;

        # ------------------------------------------------------------------
        view)
            SELECTED_PROF="$(_pick_profile "View Profile")" || continue
            [[ -n "$SELECTED_PROF" ]] || continue
            pfile="$PROFILE_DIR/${SELECTED_PROF}.env"
            wt_info "$MODULE  ›  $SELECTED_PROF" "$(cat "$pfile")"
            ;;

        # ------------------------------------------------------------------
        edit)
            SELECTED_PROF="$(_pick_profile "Edit Profile")" || continue
            [[ -n "$SELECTED_PROF" ]] || continue
            pfile="$PROFILE_DIR/${SELECTED_PROF}.env"

            # Open in zenity text editor (text-info with editable)
            EDITED=$(zenity --text-info \
                --title="$(wt_title "$MODULE  ›  Edit  —  $SELECTED_PROF")" \
                --filename="$pfile" \
                --editable \
                --width=600 --height=400) || continue

            # Profiles are shell code run before launches: refuse a broken one.
            if ! bash -n <(printf '%s\n' "$EDITED") 2>/dev/null; then
                wt_error_return "$(printf 'That profile has a shell syntax error (an unclosed quote?)\nand was not saved:\n\n%s' \
                    "$(bash -n <(printf '%s\n' "$EDITED") 2>&1 | sed 's/^[^:]*: //' | head -3)")"
                continue
            fi
            printf '%s\n' "$EDITED" > "$pfile"
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
            wt_confirm "$MODULE" "$(printf 'Delete these profiles?\n\n  %s' "${TO_DEL//|/$'\n'  }")" || continue

            IFS='|' read -ra DEL_PROFILES <<< "$TO_DEL"
            for p in "${DEL_PROFILES[@]}"; do
                rm -f "$PROFILE_DIR/${p}.env"
            done
            wt_info "$MODULE" "$(printf '✔  Deleted %d profile(s).' "${#DEL_PROFILES[@]}")"
            ;;

        # ------------------------------------------------------------------
        export)
            SELECTED_PROF="$(_pick_profile "Export to Clipboard")" || continue
            [[ -n "$SELECTED_PROF" ]] || continue
            pfile="$PROFILE_DIR/${SELECTED_PROF}.env"
            if ! _copy_to_clipboard "$pfile" 2>/dev/null; then
                wt_info "$MODULE" "$(printf 'Could not find wl-copy, xclip or xsel.\n\nProfile contents:\n\n%s' "$(cat "$pfile")")"
                continue
            fi

            wt_info "$MODULE" "$(printf '✔  Copied to clipboard:  %s' "$SELECTED_PROF")"
            ;;

        exit|*) break ;;
    esac
done
