#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  directx_installer-local.sh — DirectX June 2010 Redistributable Installer
#  winetoolz v3.0
#
#  Downloads the DirectX June 2010 offline redistributable (sha256-verified,
#  cached), extracts it on the Linux side, runs DXSETUP.exe silently in the
#  selected prefix, then points Wine at the Microsoft DLLs it installed.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DirectX Jun 2010 Installer"

wt_require_cmds zenity
_wt_have cabextract || _wt_have 7z || wt_require_cmds cabextract
_wt_have curl || _wt_have wget || wt_require_cmds curl

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  3. Confirm
# =============================================================================

wt_confirm "$MODULE" "$(printf \
    'Ready to install DirectX June 2010 Redistributable.\n\n  Wine   :  %s\n  Prefix :  %s\n\n─────────────────────────────────────\nThe redistributable will be extracted\nautomatically, then DXSETUP.exe will\nbe run in the selected prefix.' \
    "$WT_INNER_WINE" "$WINEPREFIX")" || exit 0

# =============================================================================
#  4. Export all variables for the helper script to inherit
# =============================================================================

export WT_INNER_WINE
export WINEPREFIX

# =============================================================================
#  5. Generate + run helper script in terminal
# =============================================================================

TMP=$(mktemp --suffix=.sh)
trap 'rm -f "$TMP"' EXIT

cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e

source "$WT_LIB_PATH"
export WINEPREFIX

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR" || exit 1

fail() { wt_log_err "$*"; wt_pause; exit 1; }

wt_section "DirectX Jun 2010 Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'

# --- Download (shared, verified cache) ---
wt_fetch_item dx_jun2010 "DirectX Jun 2010 redistributable (~95 MB)" \
    || fail "Download failed. Check your internet connection."
REDIST="$WT_FETCHED"

# --- Step 1: extract on the Linux side (no Wine GUI needed) ---
printf '\n'
wt_section "Step 1 of 3  ›  Extraction"
EXTRACT_DIR="$TMP_DIR/dx_extracted"
mkdir -p "$EXTRACT_DIR"

wt_log "Extracting DirectX redistributable (cabinet archive)..."

if command -v cabextract &>/dev/null; then
    cabextract -q -d "$EXTRACT_DIR" -- "$REDIST" >/dev/null 2>&1 \
        && wt_log_ok "Extracted with cabextract." \
        || fail "cabextract extraction failed."
else
    7z x "$REDIST" -o"$EXTRACT_DIR" -y >/dev/null \
        && wt_log_ok "Extracted with 7z." \
        || fail "7z extraction failed."
fi

# --- Step 2: find and run DXSETUP.exe ---
printf '\n'
wt_section "Step 2 of 3  ›  Run DXSETUP.exe"

DXSETUP_PATH="$(find "$EXTRACT_DIR" -maxdepth 3 -iname "dxsetup.exe" -print -quit)"

if [[ -z "$DXSETUP_PATH" ]]; then
    wt_log_err "Contents of extraction dir:"
    ls -1 "$EXTRACT_DIR" >&2
    fail "Could not find DXSETUP.exe in extracted files."
fi

wt_log_ok "Found: $DXSETUP_PATH"
cd "$(dirname "$DXSETUP_PATH")" || fail "Cannot enter $(dirname "$DXSETUP_PATH")"
printf '\n'

# --- Validate prefix has a working wineboot.exe ---
if [[ ! -f "$WINEPREFIX/drive_c/windows/system32/wineboot.exe" ]]; then
    fail "Prefix appears uninitialised or broken (no system32/wineboot.exe) — create a proper prefix first via  winetoolz › Prefix › Create Prefix."
fi
if [[ ! -f "$WINEPREFIX/drive_c/windows/explorer.exe" ]]; then
    fail "explorer.exe missing from prefix — prefix may be incomplete. Please recreate it via Prefix Creator, then retry."
fi

wt_log_info "Prefix looks valid — wineboot.exe and explorer.exe present."
printf '\n'

# Run DXSETUP silently — no explorer window required
wt_log "Running DXSETUP.exe /silent ..."
rc=0
"$WT_INNER_WINE" DXSETUP.exe /silent || rc=$?
case "$rc" in
    0)         wt_log_ok "DXSETUP.exe finished." ;;
    3010|1641) wt_log_ok "DXSETUP.exe finished (Windows would want a reboot — not needed under Wine)." ;;
    *)         fail "DXSETUP.exe exited with code $rc." ;;
esac

# --- Step 3: Wine keeps using its own builtin d3dx9 / d3dcompiler / xinput
# unless told otherwise: point it at the Microsoft DLLs DXSETUP installed.
# (Audio — XAudio2, XACT — stays on Wine's own, which works better.) ---
printf '\n'
wt_section "Step 3 of 3  ›  DLL overrides"
"${WT_WINESERVER:-wineserver}" -w 2>/dev/null
wt_prefix_dll_dirs "$WINEPREFIX"
declare -A NATIVE=()
for dir in "$WT_DLLDIR_32" "$WT_DLLDIR_64"; do
    [[ -n "$dir" ]] || continue
    for f in "$dir"/d3dx9_*.dll "$dir"/d3dx10*.dll "$dir"/d3dx11_*.dll \
             "$dir"/d3dcompiler_[34]*.dll "$dir"/xinput1_*.dll "$dir"/xinput9_1_0.dll; do
        [[ -f "$f" ]] || continue
        wt_dll_is_wine_builtin "$f" && continue
        n="$(basename "$f")"
        NATIVE["${n%.*}"]=1
    done
done
set_fail=0
for n in "${!NATIVE[@]}"; do
    wt_dll_override "$n" native,builtin || set_fail=$((set_fail + 1))
done
wt_log_ok "${#NATIVE[@]} DLL override(s) set to native,builtin."
(( set_fail )) && wt_log_err "$set_fail override(s) could not be set."

wt_section "DirectX Jun 2010 installation complete."
wt_pause
(( set_fail == 0 ))
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"

if [[ "$WT_TERMINAL_RC" == 0 ]]; then
    wt_ok "$MODULE" "DirectX June 2010 installation"
else
    wt_warn "$MODULE" "$(printf 'The DirectX installation did not complete —\nthe terminal output shows which step failed.')"
fi
