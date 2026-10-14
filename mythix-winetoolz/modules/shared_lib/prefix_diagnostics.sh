#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  prefix_diagnostics.sh — Prefix Health & Diagnostics
#  winetoolz v2.0
#
#  Shows a detailed report on a prefix:
#    arch / Windows version / Wine build / disk usage / DLL overrides count
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

# --- Arch ---
ARCH="unknown"
if [[ -f "$PFX/system.reg" ]]; then
    grep -qi '#arch=win64' "$PFX/system.reg" && ARCH="win64" || ARCH="win32"
fi

# --- Windows version from user.reg ---
WIN_VER="unknown"
if [[ -f "$PFX/user.reg" ]]; then
    WIN_VER="$(grep -i '"Version"' "$PFX/user.reg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)"[^"]*$/\1/' | tr -d '"' || echo "unknown")"
fi
# Also check system.reg for CSDVersion / ProductName
WIN_PRODUCT="unknown"
if [[ -f "$PFX/system.reg" ]]; then
    WIN_PRODUCT="$(grep -i '"ProductName"' "$PFX/system.reg" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/' | tr -d '"' || echo "unknown")"
fi

# --- Disk usage ---
DISK_USAGE="$(du -sh "$PFX" 2>/dev/null | cut -f1 || echo "?")"

# --- Drive C size ---
DRIVE_C_SIZE="?"
[[ -d "$PFX/drive_c" ]] && DRIVE_C_SIZE="$(du -sh "$PFX/drive_c" 2>/dev/null | cut -f1 || echo "?")"

# --- DLL overrides count ---
OVERRIDE_COUNT=0
if [[ -f "$PFX/user.reg" ]]; then
    OVERRIDE_COUNT="$(grep -c '".*"=".*"' <(grep -A9999 'DllOverrides' "$PFX/user.reg" 2>/dev/null | head -200) 2>/dev/null || echo 0)"
fi

# --- Last modified ---
LAST_MOD="?"
[[ -f "$PFX/system.reg" ]] && LAST_MOD="$(date -r "$PFX/system.reg" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")"

# --- Key directory presence checks ---
check_exists() { [[ -e "$1" ]] && echo "✔" || echo "✘ MISSING"; }

SYS32_STATUS="$(check_exists "$PFX/drive_c/windows/system32")"
SYSWOW64_STATUS="$([ "$ARCH" = "win64" ] && check_exists "$PFX/drive_c/windows/syswow64" || echo "n/a (win32)")"
WINEBOOT_STATUS="$(check_exists "$PFX/drive_c/windows/system32/wineboot.exe")"
EXPLORER_STATUS="$(check_exists "$PFX/drive_c/windows/explorer.exe")"
SYSTEM_REG_STATUS="$(check_exists "$PFX/system.reg")"
USER_REG_STATUS="$(check_exists "$PFX/user.reg")"

# --- DXVK presence ---
DXVK_STATUS="not installed"
if [[ -f "$PFX/drive_c/windows/system32/dxgi.dll" ]]; then
    # Check if it's actually DXVK by looking at file size (Wine's builtin dxgi is much smaller)
    DXGI_SIZE="$(stat -c%s "$PFX/drive_c/windows/system32/dxgi.dll" 2>/dev/null || echo 0)"
    (( DXGI_SIZE > 500000 )) && DXVK_STATUS="likely installed" || DXVK_STATUS="builtin (not DXVK)"
fi

# --- VKD3D presence ---
VKD3D_STATUS="not installed"
[[ -f "$PFX/drive_c/windows/system32/d3d12.dll" ]] && VKD3D_STATUS="likely installed"

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

if [[ -n "$ISSUES" ]]; then
    HEALTH="⚠  Issues detected"
fi

# =============================================================================
#  4. Display report
# =============================================================================

REPORT="$(printf \
'Prefix        :  %s
─────────────────────────────────────
Architecture  :  %s
Windows ver   :  %s  (%s)
Last modified :  %s
Disk usage    :  %s  total  (drive_c: %s)
DLL overrides :  %s
─────────────────────────────────────
Filesystem checks
  system.reg  :  %s
  user.reg    :  %s
  system32    :  %s
  syswow64    :  %s
  wineboot    :  %s
  explorer    :  %s
─────────────────────────────────────
Translation layers
  DXVK        :  %s
  VKD3D       :  %s
─────────────────────────────────────
Health        :  %s
%s' \
    "$PFX" \
    "$ARCH" \
    "$WIN_VER" "$WIN_PRODUCT" \
    "$LAST_MOD" \
    "$DISK_USAGE" "$DRIVE_C_SIZE" \
    "$OVERRIDE_COUNT" \
    "$SYSTEM_REG_STATUS" \
    "$USER_REG_STATUS" \
    "$SYS32_STATUS" \
    "$SYSWOW64_STATUS" \
    "$WINEBOOT_STATUS" \
    "$EXPLORER_STATUS" \
    "$DXVK_STATUS" \
    "$VKD3D_STATUS" \
    "$HEALTH" \
    "$ISSUES")"

wt_info "$MODULE" "$REPORT"
