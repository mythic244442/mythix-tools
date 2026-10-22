#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  prefix_diagnostics.sh — Prefix Health & Diagnostics
#  winetoolz v3.0
#
#  Shows a detailed report on a prefix:
#    arch / Windows version / Wine build / disk usage / DLL overrides
#    translation layers (DXVK, VKD3D-Proton, DXVK-NVAPI — native or builtin)
#    broken state checks (missing system files, uninitialized prefix, etc.)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Prefix Diagnostics"

wt_require_cmds zenity

# =============================================================================
#  1. Select prefix
# =============================================================================

wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  2. Run diagnostics (no Wine needed — reads reg files and filesystem)
# =============================================================================

PFX="$WINEPREFIX"
SYS32="$PFX/drive_c/windows/system32"
SYSWOW="$PFX/drive_c/windows/syswow64"
NT_KEY='Software\Microsoft\Windows NT\CurrentVersion'

# --- Arch ---
ARCH="$(wt_prefix_arch "$PFX")"

# --- Windows version: Wine's setting (HKCU) and what Windows reports (HKLM) ---
WIN_VER="$(wt_reg_value "$PFX/user.reg" 'Software\Wine' Version)"
WIN_PRODUCT="$(wt_reg_value "$PFX/system.reg" "$NT_KEY" ProductName)"
WIN_BUILD="$(wt_reg_value "$PFX/system.reg" "$NT_KEY" CurrentBuildNumber)"
WIN_LINE="${WIN_PRODUCT:-unknown}${WIN_BUILD:+ (build $WIN_BUILD)}"
[[ -n "$WIN_VER" ]] && WIN_LINE="$WIN_VER  —  $WIN_LINE"

# --- Proton / launcher owner (compatdata layout) ---
OWNER="${WT_PREFIX_SOURCE:-}${WT_PREFIX_LABEL:+  —  $WT_PREFIX_LABEL}"
PROTON_VER=""
if [[ "$(basename "$PFX")" == pfx && -f "$(dirname "$PFX")/version" ]]; then
    PROTON_VER="$(sed -n 1p "$(dirname "$PFX")/version" 2>/dev/null || true)"
fi

# --- Disk usage ---
DISK_USAGE="$(du -sh "$PFX" 2>/dev/null | cut -f1 || echo "?")"

# --- Drive C size ---
DRIVE_C_SIZE="?"
[[ -d "$PFX/drive_c" ]] && DRIVE_C_SIZE="$(du -sh "$PFX/drive_c" 2>/dev/null | cut -f1 || echo "?")"

# --- DLL overrides (only the DllOverrides key itself) ---
OVERRIDES=""
OVERRIDE_COUNT=0
while IFS=$'\t' read -r name value; do
    [[ -n "$name" ]] || continue
    OVERRIDE_COUNT=$((OVERRIDE_COUNT + 1))
    if (( OVERRIDE_COUNT <= 12 )); then
        OVERRIDES+="$(printf '    %-24s %s' "$name" "${value:-(disabled)}")"$'\n'
    fi
done < <(wt_reg_section "$PFX/user.reg" 'Software\Wine\DllOverrides')
if (( OVERRIDE_COUNT > 12 )); then OVERRIDES+="    … and $((OVERRIDE_COUNT - 12)) more"$'\n'; fi

# --- Last modified ---
LAST_MOD="?"
[[ -f "$PFX/system.reg" ]] && LAST_MOD="$(date -r "$PFX/system.reg" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")"

# --- Running Wine ---
RUNNING="no"
if wt_prefix_running "$PFX"; then RUNNING="yes — a wineserver is serving this prefix"; fi

# --- Key directory presence checks ---
check_exists() { if [[ -e "$1" ]]; then echo "✔"; else echo "✘ MISSING"; fi; }

SYS32_STATUS="$(check_exists "$SYS32")"
if [[ "$ARCH" == "win64" ]]; then SYSWOW64_STATUS="$(check_exists "$SYSWOW")"; else SYSWOW64_STATUS="n/a (win32)"; fi
WINEBOOT_STATUS="$(check_exists "$SYS32/wineboot.exe")"
EXPLORER_STATUS="$(check_exists "$PFX/drive_c/windows/explorer.exe")"
SYSTEM_REG_STATUS="$(check_exists "$PFX/system.reg")"
USER_REG_STATUS="$(check_exists "$PFX/user.reg")"
DRIVE_LINK_STATUS="$(check_exists "$PFX/dosdevices/c:")"

# --- Translation layers: native DLLs vs Wine's builtin ones ---
# layer_status <grep marker> <dll paths...>
#   "builtin (Wine's own)", "<name> (native)" or "not present", judged by the
#   "Wine builtin DLL" stamp — not by file size, which says nothing.
layer_status() {
    local marker="$1" f found=0 layer=0 other=0 by=""
    shift
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        found=1
        wt_dll_is_wine_builtin "$f" && continue
        if [[ -e "$f.wt_bak" || -e "$f.wt_bak_none" ]]; then by=" — by winetoolz"; fi
        if grep -aqi -- "$marker" "$f" 2>/dev/null; then layer=1; else other=1; fi
    done
    if (( ! found )); then echo "not present"
    elif (( layer && ! other )); then echo "installed (native)$by"
    elif (( layer || other )); then echo "native DLLs of another kind$by"
    else echo "builtin (Wine's own)"
    fi
}

DXVK_STATUS="$(layer_status dxvk "$SYS32/dxgi.dll" "$SYS32/d3d11.dll" "$SYS32/d3d9.dll")"
VKD3D_STATUS="$(layer_status vkd3d-proton "$SYS32/d3d12.dll" "$SYS32/d3d12core.dll")"
NVAPI_STATUS="$(layer_status nvapi "$SYS32/nvapi64.dll" "$SYS32/nvapi.dll")"

# =============================================================================
#  3. Overall health verdict
# =============================================================================

HEALTH="✔  Healthy"
ISSUES=""

[[ "$SYSTEM_REG_STATUS" == *MISSING* ]]  && ISSUES+="  •  system.reg is missing — prefix may be corrupt\n"
[[ "$USER_REG_STATUS"   == *MISSING* ]]  && ISSUES+="  •  user.reg is missing\n"
[[ "$WINEBOOT_STATUS"   == *MISSING* ]]  && ISSUES+="  •  wineboot.exe missing — prefix not fully initialised\n"
[[ "$EXPLORER_STATUS"   == *MISSING* ]]  && ISSUES+="  •  explorer.exe missing — some tools may fail\n"
[[ "$SYS32_STATUS"      == *MISSING* ]]  && ISSUES+="  •  system32 directory missing\n"
[[ "$SYSWOW64_STATUS"   == *MISSING* ]]  && ISSUES+="  •  syswow64 missing — 32-bit programs will not run\n"
[[ "$DRIVE_LINK_STATUS" == *MISSING* ]]  && ISSUES+="  •  dosdevices/c: link missing — run Wine Tools › Update Prefix\n"

if [[ -n "$ISSUES" ]]; then
    HEALTH="⚠  Issues detected"
fi

# =============================================================================
#  4. Display report
# =============================================================================

REPORT="$(printf \
'Prefix        :  %s%s%s
─────────────────────────────────────
Architecture  :  %s
Windows ver   :  %s
Last modified :  %s
Disk usage    :  %s  total  (drive_c: %s)
Wine running  :  %s
DLL overrides :  %s
%s─────────────────────────────────────
Filesystem checks
  system.reg  :  %s
  user.reg    :  %s
  system32    :  %s
  syswow64    :  %s
  wineboot    :  %s
  explorer    :  %s
  C: drive    :  %s
─────────────────────────────────────
Translation layers
  DXVK        :  %s
  VKD3D       :  %s
  DXVK-NVAPI  :  %s
─────────────────────────────────────
Health        :  %s
%b' \
    "$PFX" \
    "${OWNER:+$'\n'Owner         :  $OWNER}" \
    "${PROTON_VER:+$'\n'Proton        :  $PROTON_VER}" \
    "$ARCH" \
    "$WIN_LINE" \
    "$LAST_MOD" \
    "$DISK_USAGE" "$DRIVE_C_SIZE" \
    "$RUNNING" \
    "$OVERRIDE_COUNT" \
    "$OVERRIDES" \
    "$SYSTEM_REG_STATUS" \
    "$USER_REG_STATUS" \
    "$SYS32_STATUS" \
    "$SYSWOW64_STATUS" \
    "$WINEBOOT_STATUS" \
    "$EXPLORER_STATUS" \
    "$DRIVE_LINK_STATUS" \
    "$DXVK_STATUS" \
    "$VKD3D_STATUS" \
    "$NVAPI_STATUS" \
    "$HEALTH" \
    "$ISSUES")"

wt_info "$MODULE" "$REPORT"
