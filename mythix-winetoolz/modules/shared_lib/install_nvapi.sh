#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  install_nvapi.sh — DXVK-NVAPI Installer / Uninstaller
#  winetoolz v3.0
#  Installs or removes DXVK-NVAPI (nvapi, nvapi64, nvofapi64) in a Wine prefix,
#  plus its optional Vulkan Reflex layer files.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DXVK-NVAPI Installer"
DLLS_64=(nvapi64 nvofapi64)
DLLS_32=(nvapi)
PROFILE_DIR="${HOME}/.config/winetoolz/env_profiles"

wt_require_cmds zenity

# =============================================================================
#  1. Choose action
# =============================================================================

ACTION=$(zenity --list \
    --title="$(wt_title "$MODULE")" \
    --text="<tt>Choose an action to perform on the selected prefix.</tt>" \
    --radiolist \
    --column="" --column="Action" --column="Description" \
    TRUE  "install"   "Copy DXVK-NVAPI DLLs into prefix and set DLL overrides" \
    FALSE "uninstall" "Remove DXVK-NVAPI and its overrides" \
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
wt_warn_managed_prefix "$MODULE" "DXVK-NVAPI" || exit 0

LAYER_DEST="$WINEPREFIX/dxvk-nvapi-layer"

# =============================================================================
#  4. Ensure DXVK-NVAPI release is present (auto-download if needed)
# =============================================================================

SRC64="" SRC32="" LAYER_DIR=""
if [[ "$ACTION" == "install" ]]; then
    wt_ensure_release \
        "dxvk-nvapi" \
        "jp7677/dxvk-nvapi" \
        "^dxvk-nvapi-v[0-9]" || exit 0
    DLL_ROOT="$WT_DLL_ROOT"

    for d in x64 bin64; do
        if [[ -d "$DLL_ROOT/$d" ]]; then SRC64="$DLL_ROOT/$d"; break; fi
    done
    for d in x32 x86 32bit; do
        if [[ -d "$DLL_ROOT/$d" ]]; then SRC32="$DLL_ROOT/$d"; break; fi
    done
    if [[ -z "$SRC64" ]]; then
        wt_error "$(printf 'Could not find a 64-bit NVAPI DLL directory under:\n  %s\n\nExpected a subfolder named  x64  or  bin64.' "$DLL_ROOT")"
    fi
    # The Vulkan Reflex layer only ships with newer releases — optional.
    for d in layer nvapi-layer; do
        if [[ -d "$DLL_ROOT/$d" ]]; then LAYER_DIR="$DLL_ROOT/$d"; break; fi
    done
fi

# =============================================================================
#  5. Install / uninstall in a terminal
# =============================================================================

export WT_LAYER_NAME="DXVK-NVAPI" WT_LAYER_ACTION="$ACTION" \
       WT_LAYER_DLLS64="${DLLS_64[*]}" WT_LAYER_DLLS32="${DLLS_32[*]}" \
       WT_LAYER_SRC64="$SRC64" WT_LAYER_SRC32="$SRC32"
wt_dll_layer_run "$MODULE" || exit 0

# =============================================================================
#  6. Reflex layer files and the launch variable DXVK needs
# =============================================================================

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ -d "$LAYER_DEST" ]]; then
        rm -rf -- "$LAYER_DEST"
    fi
    exit 0
fi

LAYER_NOTE=""
if [[ -n "$LAYER_DIR" ]]; then
    mkdir -p "$LAYER_DEST"
    cp -r -- "$LAYER_DIR/." "$LAYER_DEST/"
    LAYER_NOTE="$(printf '\n\nThe Vulkan Reflex layer files were copied to:\n  %s\n(see the DXVK-NVAPI README for enabling Reflex)' "$LAYER_DEST")"
fi

# DXVK reports NVIDIA GPUs as AMD unless DXVK_ENABLE_NVAPI=1 is set, which
# makes NVAPI (DLSS, Reflex) invisible to games. Offer an Env Flags profile.
PROFILE_FILE="$PROFILE_DIR/dxvk-nvapi.env"
if [[ -f "$PROFILE_FILE" ]]; then
    wt_info "$MODULE" "$(printf 'Launch games with the  dxvk-nvapi  env profile\n(App Launcher › Env Profile) so DXVK exposes NVAPI:\n\n  DXVK_ENABLE_NVAPI=1%s' "$LAYER_NOTE")"
elif wt_confirm "$MODULE  ›  Launch Variable" "$(printf 'DXVK only exposes NVAPI (DLSS, Reflex) to games when\nthey are started with:\n\n  DXVK_ENABLE_NVAPI=1\n\nCreate the env profile  dxvk-nvapi  with it, for the\nApp Launcher and Log Viewer?%s' "$LAYER_NOTE")"; then
    mkdir -p "$PROFILE_DIR"
    printf '# winetoolz env profile: dxvk-nvapi\nexport DXVK_ENABLE_NVAPI="1"\n' > "$PROFILE_FILE"
    wt_info "$MODULE" "$(printf '✔  Env profile saved:  dxvk-nvapi\n\n  %s' "$PROFILE_FILE")"
fi
