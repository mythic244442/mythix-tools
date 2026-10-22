#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  setup_vkd3d_proton-gui.sh — VKD3D-Proton Installer / Uninstaller
#  winetoolz v3.0
#  Installs or removes vkd3d-proton DLLs (d3d12, d3d12core) into a Wine prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="VKD3D-Proton Installer"
DLLS=(d3d12 d3d12core)

wt_require_cmds zenity

# =============================================================================
#  1. Choose action
# =============================================================================

ACTION=$(zenity --list \
    --title="$(wt_title "$MODULE")" \
    --text="<tt>Choose an action to perform on the selected prefix.</tt>" \
    --radiolist \
    --column="" --column="Action" --column="Description" \
    TRUE  "install"   "Copy vkd3d-proton DLLs into prefix and set DLL overrides" \
    FALSE "uninstall" "Restore Wine's own DLLs and remove the overrides" \
    --width="$WT_WIDTH" --height=220) || exit 0
ACTION="${ACTION%%|*}"
[[ "$ACTION" == install || "$ACTION" == uninstall ]] || exit 0

# =============================================================================
#  2. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  3. Select WINEPREFIX
# =============================================================================

wt_select_prefix_from_config "$MODULE" || exit 0
wt_warn_managed_prefix "$MODULE" "VKD3D-Proton" || exit 0

# =============================================================================
#  4. Ensure VKD3D-Proton release is present (auto-download if needed)
# =============================================================================

SRC64="" SRC32=""
if [[ "$ACTION" == "install" ]]; then
    wt_ensure_release \
        "vkd3d-proton" \
        "HansKristian-Work/vkd3d-proton" \
        "^vkd3d-proton-[0-9]" || exit 0
    DLL_ROOT="$WT_DLL_ROOT"

    for d in x64 lib64; do
        if [[ -d "$DLL_ROOT/$d" ]]; then SRC64="$DLL_ROOT/$d"; break; fi
    done
    for d in x86 x32 lib; do
        if [[ -d "$DLL_ROOT/$d" ]]; then SRC32="$DLL_ROOT/$d"; break; fi
    done
    if [[ -z "$SRC64" && -z "$SRC32" ]]; then
        wt_error "$(printf 'Could not find the DLL folders under:\n  %s\n\nExpected subfolders named  x64  and  x86.' "$DLL_ROOT")"
    fi

    if ! wt_vulkan_ok; then
        wt_confirm "$MODULE  ›  No Vulkan Driver" "$(printf 'No Vulkan driver (ICD) was found on this system.\n\nVKD3D-Proton translates Direct3D 12 to Vulkan, so games\nwill fail to start until a Vulkan driver is installed.\n\n─────────────────────────────────────\nInstall VKD3D-Proton anyway?')" || exit 0
    fi
fi

# =============================================================================
#  5. Install / uninstall in a terminal
# =============================================================================

export WT_LAYER_NAME="VKD3D-Proton" WT_LAYER_ACTION="$ACTION" \
       WT_LAYER_DLLS64="${DLLS[*]}" WT_LAYER_DLLS32="${DLLS[*]}" \
       WT_LAYER_SRC64="$SRC64" WT_LAYER_SRC32="$SRC32"
wt_dll_layer_run "$MODULE" || true
