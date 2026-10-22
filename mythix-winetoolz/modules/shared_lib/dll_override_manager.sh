#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  dll_override_manager.sh — DLL Override Manager
#  winetoolz v3.0
#
#  View, add (with presets), and remove DLL overrides in a prefix registry —
#  for every program, or for one program only (AppDefaults\<name>.exe).
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

PRESET_DLLS[dxvk]="d3d8 d3d9 d3d10core d3d11 dxgi"
PRESET_MODE[dxvk]="native,builtin"
PRESET_LABEL[dxvk]="DXVK (D3D8/9/10/11)"
PRESET_DESC[dxvk]="Force DXVK's native d3d8/9/10/11/dxgi — use after DXVK install"

PRESET_DLLS[vkd3d]="d3d12 d3d12core"
PRESET_MODE[vkd3d]="native,builtin"
PRESET_LABEL[vkd3d]="VKD3D-Proton (D3D12)"
PRESET_DESC[vkd3d]="Force VKD3D-Proton's native d3d12 — use after vkd3d install"

PRESET_DLLS[nvapi]="nvapi nvapi64"
PRESET_MODE[nvapi]="native,builtin"
PRESET_LABEL[nvapi]="DXVK-NVAPI (DLSS/NvAPI)"
PRESET_DESC[nvapi]="Force DXVK-NVAPI's nvapi/nvapi64 — use after DXVK-NVAPI install"

PRESET_DLLS[dinput8]="dinput8"
PRESET_MODE[dinput8]="native,builtin"
PRESET_LABEL[dinput8]="dinput8 native"
PRESET_DESC[dinput8]="Use a game's own dinput8.dll — mod loaders, some controller fixes"

PRESET_DLLS[directplay]="dplayx dpnet dpnhpast dpnlobby"
PRESET_MODE[directplay]="native,builtin"
PRESET_LABEL[directplay]="DirectPlay"
PRESET_DESC[directplay]="Native DirectPlay — use after installing it (Runtimes)"

PRESET_DLLS[d3dcompiler]="d3dcompiler_47"
PRESET_MODE[d3dcompiler]="native,builtin"
PRESET_LABEL[d3dcompiler]="d3dcompiler_47 native"
PRESET_DESC[d3dcompiler]="Force native d3dcompiler_47 — needed by some DX11 games"

PRESET_DLLS[physx]="physxloader nvphysxginit"
PRESET_MODE[physx]="native,builtin"
PRESET_LABEL[physx]="PhysX"
PRESET_DESC[physx]="Native PhysX loader DLLs for older PhysX-enabled games"

PRESET_DLLS[msvcrt]="msvcp140 msvcp140_1 msvcp140_2 vcruntime140 vcruntime140_1 concrt140 vcomp140"
PRESET_MODE[msvcrt]="native,builtin"
PRESET_LABEL[msvcrt]="VC++ 2015+ runtime DLLs native"
PRESET_DESC[msvcrt]="Force the native VC++ 2015-2022 runtime — use after vcredist install"

PRESET_ORDER=(dxvk vkd3d nvapi dinput8 directplay d3dcompiler physx msvcrt)

GLOBAL_KEY='HKEY_CURRENT_USER\Software\Wine\DllOverrides'
APP_KEY='HKEY_CURRENT_USER\Software\Wine\AppDefaults'

# =============================================================================
#  1. Select Wine binary + prefix
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

export WT_INNER_WINE WINEPREFIX WT_WRAPPER

# =============================================================================
#  Helpers: registry access
# =============================================================================

# _key_for <scope>  — the override key for "*" (all programs) or <name>.exe
_key_for() {
    if [[ "$1" == "*" ]]; then printf '%s' "$GLOBAL_KEY"; else printf '%s\\%s\\DllOverrides' "$APP_KEY" "$1"; fi
}

# _read_overrides
#   Every override in the prefix, one per line: "<scope>\t<dll>\t<mode>",
#   scope "*" for all programs or the .exe name. Reads Wine's own answer
#   (reg query), so changes not yet saved to user.reg are included. Registry
#   keys keep the case they were made with ("Game.exe", "dlloverrides"), so
#   they are compared case-insensitively.
_read_overrides() {
    local line key="" lkey name type value app
    local gkey="${GLOBAL_KEY,,}" akey="${APP_KEY,,}"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == HKEY_* ]]; then
            key="$line" lkey="${line,,}"
            continue
        fi
        [[ "$line" =~ ^[[:space:]]+([^[:space:]]+)[[:space:]]+(REG_[A-Z_]+)[[:space:]]*(.*)$ ]] || continue
        name="${BASH_REMATCH[1]}" type="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
        [[ "$type" == REG_SZ ]] || continue
        if [[ "$lkey" == "$gkey" ]]; then
            printf '*\t%s\t%s\n' "$name" "$value"
        elif [[ "$lkey" == "$akey"\\*\\dlloverrides ]]; then
            app="${key:${#APP_KEY}+1}"
            app="${app:0:${#app}-13}"          # drop "\DllOverrides"
            [[ "$app" == *\\* ]] && continue    # deeper than AppDefaults\<exe>
            printf '%s\t%s\t%s\n' "$app" "$name" "$value"
        fi
    done < <(
        "$WT_INNER_WINE" reg query "$GLOBAL_KEY" 2>/dev/null
        "$WT_INNER_WINE" reg query "$APP_KEY" /s 2>/dev/null
    )
    return 0
}

# _set_override <scope> <dll> <mode>   (mode "delete" removes it)
_set_override() {
    local key
    key="$(_key_for "$1")"
    if [[ "$3" == delete ]]; then
        "$WT_INNER_WINE" reg delete "$key" /v "$2" /f >/dev/null 2>&1
    else
        local mode="$3"
        [[ "$mode" == disabled ]] && mode=""   # what winecfg writes for "Disabled"
        "$WT_INNER_WINE" reg add "$key" /v "$2" /d "$mode" /f >/dev/null 2>&1
    fi
}

_mode_label() { if [[ -z "$1" ]]; then echo "disabled"; else echo "$1"; fi; }
_scope_label() { if [[ "$1" == "*" ]]; then echo "all programs"; else echo "$1 only"; fi; }

# =============================================================================
#  Actions
# =============================================================================

action_view() {
    local raw scope dll mode formatted=""
    raw="$(_read_overrides)"
    if [[ -z "$raw" ]]; then
        wt_info "$MODULE  ›  Current Overrides" \
            "No DLL overrides are currently set in this prefix."
        return
    fi
    while IFS=$'\t' read -r scope dll mode; do
        formatted+="$(printf '  %-24s  %-16s  %s' "$dll" "$(_mode_label "$mode")" "$(_scope_label "$scope")")"$'\n'
    done <<< "$raw"
    wt_info "$MODULE  ›  Current Overrides" \
        "$(printf 'DLL overrides in:\n  %s\n\n─────────────────────────────────────\n%s' \
            "$WINEPREFIX" "$formatted")"
}

action_preset() {
    local -a args=() chosen=()
    local key selected pk dll ok=0 bad=""
    for key in "${PRESET_ORDER[@]}"; do
        args+=(FALSE "$key" "${PRESET_LABEL[$key]}" "${PRESET_DLLS[$key]}" "${PRESET_MODE[$key]}" "${PRESET_DESC[$key]}")
    done

    selected=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Apply Preset")" \
        --text="<tt>Select one or more presets to apply.</tt>" \
        --checklist \
        --column="Apply" --column="Key" --column="Preset" \
        --column="DLLs" --column="Mode" --column="Description" \
        --hide-column=2 --print-column=2 \
        --width=840 --height=400 \
        "${args[@]}") || return 0
    [[ -n "$selected" ]] || return 0
    IFS='|' read -ra chosen <<< "$selected"

    wt_pulse_start "$MODULE" "Applying DLL overrides..."
    for pk in "${chosen[@]}"; do
        [[ -n "${PRESET_DLLS[$pk]+set}" ]] || continue
        for dll in ${PRESET_DLLS[$pk]}; do
            if _set_override "*" "$dll" "${PRESET_MODE[$pk]}"; then ok=$((ok + 1)); else bad+=" $dll"; fi
        done
    done
    wt_pulse_stop

    if [[ -n "$bad" ]]; then
        wt_error_return "$(printf '%d override(s) set; these failed:\n %s' "$ok" "$bad")"
    else
        wt_info "$MODULE" "$(printf '✔  %d override(s) set for all programs:\n\n  %s' "$ok" "${chosen[*]}")"
    fi
}

action_add() {
    local dll mode scope
    dll=$(zenity --entry \
        --title="$(wt_title "$MODULE  ›  Add Override")" \
        --text="<tt>Enter the DLL name (without .dll extension):\n\nExamples:  d3d9   dinput8   msvcr100</tt>" \
        --width="$WT_WIDTH") || return 0

    dll="${dll// /}"
    dll="${dll,,}"          # how winecfg writes them; Wine ignores the case
    dll="${dll%.dll}"
    [[ -z "$dll" ]] && return 0
    if [[ ! "$dll" =~ ^\*?[A-Za-z0-9_.+-]+$ ]]; then
        wt_error_return "$(printf 'Not a DLL name:  %s' "$dll")"
        return 0
    fi

    mode=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Add Override")" \
        --text="$(_wt_box "$(printf 'DLL: %s\n\nSelect override mode:' "$dll")")" \
        --column="Mode" --column="Meaning" \
        --width=500 --height=300 \
        "native,builtin"  "Try native .dll first, fall back to Wine builtin" \
        "builtin,native"  "Try Wine builtin first, fall back to native .dll" \
        "native"          "Use native .dll only" \
        "builtin"         "Use Wine builtin only" \
        "disabled"        "Disable this DLL entirely") || return 0
    mode="${mode%%|*}"
    [[ -n "$mode" ]] || return 0

    scope=$(zenity --entry \
        --title="$(wt_title "$MODULE  ›  Which Programs?")" \
        --text="$(_wt_box "$(printf 'Apply the override to every program in the prefix,\nor only to one (enter its .exe name, e.g. game.exe).\n\nLeave empty for all programs.')")" \
        --width="$WT_WIDTH") || return 0
    scope="${scope// /}"
    scope="${scope##*[\\/]}"
    if [[ -z "$scope" ]]; then
        scope="*"
    elif [[ ! "$scope" =~ ^[A-Za-z0-9_.+-]+\.[Ee][Xx][Ee]$ ]]; then
        wt_error_return "$(printf 'Enter a program name ending in .exe (e.g. game.exe), not:\n  %s' "$scope")"
        return 0
    fi

    if _set_override "$scope" "$dll" "$mode"; then
        wt_info "$MODULE" "$(printf '✔  Override set:\n\n  DLL     :  %s\n  Mode    :  %s\n  Applies :  %s\n  Prefix  :  %s' \
            "$dll" "$mode" "$(_scope_label "$scope")" "$WINEPREFIX")"
    else
        wt_error_return "Failed to set override for: $dll"
    fi
}

action_remove() {
    local raw scope dll mode selected item ok=() bad=()
    local -a rows=() items=()
    raw="$(_read_overrides)"
    if [[ -z "$raw" ]]; then
        wt_info "$MODULE" "No DLL overrides are set — nothing to remove."
        return
    fi

    # Build checklist rows from current overrides
    while IFS=$'\t' read -r scope dll mode; do
        [[ -n "$dll" ]] || continue
        rows+=(FALSE "$scope"$'\x1f'"$dll" "$dll" "$(_mode_label "$mode")" "$(_scope_label "$scope")")
    done <<< "$raw"

    selected=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Remove Overrides")" \
        --text="<tt>Select overrides to remove:</tt>" \
        --checklist \
        --column="Remove" --column="Id" --column="DLL" --column="Mode" --column="Applies to" \
        --hide-column=2 --print-column=2 --separator=$'\x1e' \
        --width=620 --height=400 \
        "${rows[@]}") || return 0
    [[ -n "$selected" ]] || return 0

    IFS=$'\x1e' read -ra items <<< "$selected"
    for item in "${items[@]}"; do
        scope="${item%%$'\x1f'*}"
        dll="${item#*$'\x1f'}"
        if _set_override "$scope" "$dll" delete; then ok+=("$dll"); else bad+=("$dll"); fi
    done

    wt_info "$MODULE  ›  Remove Complete" \
        "$(printf 'Removed : %s\nFailed  : %s' \
            "${ok[*]:-(none)}" "${bad[*]:-(none)}")"
}

# =============================================================================
#  2. Looping submenu
# =============================================================================

while true; do
    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(_wt_box "$(printf 'Wine   :  %s\nPrefix :  %s\n\n─────────────────────────────────────\nManage DLL overrides in this prefix registry.' \
            "$WT_INNER_WINE" "$WINEPREFIX")")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=680 --height=360 \
        "view"    "View Current Overrides"    "List all DLL overrides set in this prefix" \
        "preset"  "Apply Preset"              "Choose from common presets (DXVK, VKD3D, dinput8...)" \
        "add"     "Add / Edit Override"       "Set a DLL's mode — for all programs or just one" \
        "remove"  "Remove Override"           "Delete one or more existing overrides" \
        "exit"    "Back to Main Menu"         "") || break
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in
        view)   action_view   ;;
        preset) action_preset ;;
        add)    action_add    ;;
        remove) action_remove ;;
        exit|*) break ;;
    esac
done
