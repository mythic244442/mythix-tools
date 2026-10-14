#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  dll_override_manager.sh — DLL Override Manager
#  winetoolz v2.0
#
#  View, add (with presets), and remove DLL overrides in a prefix registry.
#  Override modes: native,builtin | builtin,native | native | builtin | disabled
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DLL Override Manager"

wt_require_cmds zenity

# =============================================================================
#  Common DLL presets — label, dll names (space-separated), mode, description
# =============================================================================

# Format per entry: TAG  DLLS  MODE  LABEL  DESCRIPTION
declare -A PRESET_DLLS PRESET_MODE PRESET_LABEL PRESET_DESC

PRESET_DLLS[dxvk]="d3d9 d3d10core d3d11 dxgi"
PRESET_MODE[dxvk]="native,builtin"
PRESET_LABEL[dxvk]="DXVK (D3D9/10/11)"
PRESET_DESC[dxvk]="Force DXVK's native d3d9/10/11/dxgi — use after DXVK install"

PRESET_DLLS[vkd3d]="d3d12 d3d12core"
PRESET_MODE[vkd3d]="native,builtin"
PRESET_LABEL[vkd3d]="VKD3D-Proton (D3D12)"
PRESET_DESC[vkd3d]="Force VKD3D-Proton's native d3d12 — use after vkd3d install"

PRESET_DLLS[nvapi]="nvapi nvapi64 nvcuda nvcuvid"
PRESET_MODE[nvapi]="native,builtin"
PRESET_LABEL[nvapi]="DXVK-NVAPI (DLSS/NvAPI)"
PRESET_DESC[nvapi]="Force nvapi/nvcuda native overrides for DLSS support"

PRESET_DLLS[dinput8]="dinput8"
PRESET_MODE[dinput8]="native,builtin"
PRESET_LABEL[dinput8]="dinput8 native"
PRESET_DESC[dinput8]="Force native dinput8 — fixes some game controller issues"

PRESET_DLLS[directplay]="dplayx dpnet dpnhpast dpnlobby"
PRESET_MODE[directplay]="native,builtin"
PRESET_LABEL[directplay]="DirectPlay"
PRESET_DESC[directplay]="Enable DirectPlay DLL overrides for legacy multiplayer"

PRESET_DLLS[d3dcompiler]="d3dcompiler_47"
PRESET_MODE[d3dcompiler]="native,builtin"
PRESET_LABEL[d3dcompiler]="d3dcompiler_47 native"
PRESET_DESC[d3dcompiler]="Force native d3dcompiler_47 — needed by some DX11 games"

PRESET_DLLS[physx]="physxloader nvphysxginit"
PRESET_MODE[physx]="native,builtin"
PRESET_LABEL[physx]="PhysX"
PRESET_DESC[physx]="Force native PhysX DLLs for older PhysX-enabled games"

PRESET_DLLS[msvcrt]="msvcrt msvcp140 vcruntime140"
PRESET_MODE[msvcrt]="native,builtin"
PRESET_LABEL[msvcrt]="VC++ runtime DLLs native"
PRESET_DESC[msvcrt]="Force native VC++ runtime — use after vcredist install"

PRESET_ORDER=(dxvk vkd3d nvapi dinput8 directplay d3dcompiler physx msvcrt)

# Override mode options for manual entry
OVERRIDE_MODES=("native,builtin" "builtin,native" "native" "builtin" "disabled")

REGISTRY_KEY='HKEY_CURRENT_USER\Software\Wine\DllOverrides'

# =============================================================================
#  1. Select Wine binary + prefix
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

export WT_INNER_WINE WINEPREFIX WT_WRAPPER
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
export REGISTRY_KEY

# =============================================================================
#  Helper: read current overrides from registry
# =============================================================================

_read_overrides() {
    WINEPREFIX="$WINEPREFIX" "$WT_INNER_WINE" reg query "$REGISTRY_KEY" 2>/dev/null \
        | grep -v '^HKEY\|^$' \
        | sed 's/^[[:space:]]*//' \
        | grep -v '^$' || true
}

# =============================================================================
#  2. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nManage DLL overrides in this prefix registry.</tt>' \
            "$WT_INNER_WINE" "$WINEPREFIX")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=680 --height=360 \
        "view"    "View Current Overrides"    "List all DLL overrides currently set in this prefix" \
        "preset"  "Apply Preset"              "Choose from common presets (DXVK, VKD3D, dinput8...)" \
        "add"     "Add / Edit Override"       "Manually set a DLL name and override mode" \
        "remove"  "Remove Override"           "Delete one or more existing overrides" \
        "exit"    "Back to Main Menu"         "") || break

    case "$CHOICE" in

        # ------------------------------------------------------------------
        view)
            local raw
            raw="$(_read_overrides)"
            if [[ -z "$raw" ]]; then
                wt_info "$MODULE  ›  Current Overrides" \
                    "No DLL overrides are currently set in this prefix."
            else
                # Format nicely: align columns
                local formatted
                formatted="$(printf '%s' "$raw" | awk '{printf "  %-28s  %s\n", $1, $NF}')"
                wt_info "$MODULE  ›  Current Overrides" \
                    "$(printf 'DLL overrides in:\n  %s\n\n─────────────────────────────────────\n%s' \
                        "$WINEPREFIX" "$formatted")"
            fi
            ;;

        # ------------------------------------------------------------------
        preset)
            PRESET_ARGS=()
            for key in "${PRESET_ORDER[@]}"; do
                PRESET_ARGS+=(
                    "FALSE"
                    "$key"
                    "${PRESET_LABEL[$key]}"
                    "${PRESET_DLLS[$key]}"
                    "${PRESET_MODE[$key]}"
                    "${PRESET_DESC[$key]}"
                )
            done

            SELECTED=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Apply Preset")" \
                --text="<tt>Select one or more presets to apply.</tt>" \
                --checklist \
                --column="Apply" --column="Key" --column="Preset" \
                --column="DLLs" --column="Mode" --column="Description" \
                --hide-column=2 --print-column=2 \
                --width=840 --height=400 \
                "${PRESET_ARGS[@]}") || continue

            [[ -z "$SELECTED" ]] && continue

            IFS='|' read -ra CHOSEN_PRESETS <<< "$SELECTED"

            export WT_CHOSEN_PRESETS="${CHOSEN_PRESETS[*]}"
            # Build a flat key=dlls:mode string for each chosen preset
            PRESET_MAP=""
            for pk in "${CHOSEN_PRESETS[@]}"; do
                PRESET_MAP+="${pk}=${PRESET_DLLS[$pk]}:${PRESET_MODE[$pk]} "
            done
            export WT_PRESET_MAP="$PRESET_MAP"

            local TMP
            TMP=$(mktemp --suffix=.sh)
            cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX

wt_section "DLL Override Manager  ›  Apply Presets"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'

for entry in $WT_PRESET_MAP; do
    preset_key="${entry%%=*}"
    rest="${entry#*=}"
    dlls="${rest%%:*}"
    mode="${rest#*:}"
    wt_log "Applying preset: $preset_key  (mode: $mode)"
    for dll in $dlls; do
        "$WT_INNER_WINE" reg add \
            "$REGISTRY_KEY" \
            /v "$dll" /d "$mode" /f >/dev/null 2>&1 \
            && wt_log_ok "  $dll  →  $mode" \
            || wt_log_err "  Failed to set override: $dll"
    done
    printf '\n'
done

wt_section "Done."
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF
            chmod +x "$TMP"
            wt_run_in_terminal "$TMP"
            ;;

        # ------------------------------------------------------------------
        add)
            DLL_NAME=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Add Override")" \
                --text="<tt>Enter the DLL name (without .dll extension):\n\nExamples:  d3d9   dinput8   msvcr100</tt>" \
                --width="$WT_WIDTH") || continue

            DLL_NAME="${DLL_NAME// /}"
            [[ -z "$DLL_NAME" ]] && continue

            DLL_MODE=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Add Override")" \
                --text="$(printf '<tt>DLL: %s\n\nSelect override mode:</tt>' "$DLL_NAME")" \
                --column="Mode" --column="Meaning" \
                --width=500 --height=300 \
                "native,builtin"  "Try native .dll first, fall back to Wine builtin" \
                "builtin,native"  "Try Wine builtin first, fall back to native .dll" \
                "native"          "Use native .dll only" \
                "builtin"         "Use Wine builtin only" \
                "disabled"        "Disable this DLL entirely") || continue

            WINEPREFIX="$WINEPREFIX" "$WT_INNER_WINE" reg add \
                "$REGISTRY_KEY" /v "$DLL_NAME" /d "$DLL_MODE" /f >/dev/null 2>&1 \
                && wt_info "$MODULE" "$(printf '✔  Override set:\n\n  DLL   :  %s\n  Mode  :  %s\n  Prefix:  %s' \
                    "$DLL_NAME" "$DLL_MODE" "$WINEPREFIX")" \
                || wt_error_return "Failed to set override for: $DLL_NAME"
            ;;

        # ------------------------------------------------------------------
        remove)
            local raw
            raw="$(_read_overrides)"
            if [[ -z "$raw" ]]; then
                wt_info "$MODULE" "No DLL overrides are set — nothing to remove."
                continue
            fi

            # Build checklist rows from current overrides
            REMOVE_ARGS=()
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local dll mode
                dll="$(echo "$line" | awk '{print $1}')"
                mode="$(echo "$line" | awk '{print $NF}')"
                REMOVE_ARGS+=("FALSE" "$dll" "$mode")
            done <<< "$raw"

            TO_REMOVE=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Remove Overrides")" \
                --text="<tt>Select overrides to remove:</tt>" \
                --checklist \
                --column="Remove" --column="DLL" --column="Mode" \
                --print-column=2 \
                --width=500 --height=400 \
                "${REMOVE_ARGS[@]}") || continue

            [[ -z "$TO_REMOVE" ]] && continue

            IFS='|' read -ra DLLS_TO_REMOVE <<< "$TO_REMOVE"
            local failed=() succeeded=()
            for dll in "${DLLS_TO_REMOVE[@]}"; do
                WINEPREFIX="$WINEPREFIX" "$WT_INNER_WINE" reg delete \
                    "$REGISTRY_KEY" /v "$dll" /f >/dev/null 2>&1 \
                    && succeeded+=("$dll") \
                    || failed+=("$dll")
            done

            wt_info "$MODULE  ›  Remove Complete" \
                "$(printf 'Removed : %s\nFailed  : %s' \
                    "${succeeded[*]:-(none)}" "${failed[*]:-(none)}")"
            ;;

        exit|*) break ;;
    esac
done
