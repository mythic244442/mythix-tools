#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  directx_installer-local.sh — DirectX June 2010 Redistributable Installer
#  winetoolz v2.0
#
#  Downloads the DirectX June 2010 offline redistributable, runs the
#  self-extractor interactively so the user can choose an extraction path,
#  then finds and launches DXSETUP.exe from the extracted folder.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DirectX Jun 2010 Installer"

DX_REDIST_URL="https://download.microsoft.com/download/8/4/a/84a35bf1-dafe-4ae8-82af-ad2ae20b6b14/directx_Jun2010_redist.exe"

wt_require_cmds zenity wget cabextract

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0


# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix "$MODULE" || exit 0

# =============================================================================
#  3. Confirm
# =============================================================================

wt_confirm "$MODULE" "$(printf \
    'Ready to install DirectX June 2010 Redistributable.\n\n  Wine   :  %s\n  Prefix :  %s\n\n─────────────────────────────────────\nThe redistributable will be extracted\nautomatically, then DXSETUP.exe will\nbe launched in the selected prefix.' \
    "$WT_INNER_WINE" "$WINEPREFIX")" || exit 0

# =============================================================================
#  4. Export all variables for the helper script to inherit
# =============================================================================

export WT_INNER_WINE
export WINEPREFIX
export DX_REDIST_URL
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

# =============================================================================
#  5. Generate + run helper script in terminal
# =============================================================================

TMP=$(mktemp --suffix=.sh)
# No outer trap — inner script self-deletes after terminal closes

cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e

# Self-delete once we're running inside the terminal
SELF="$0"

source "$WT_LIB_PATH"
export WINEPREFIX

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; rm -f "$SELF"' EXIT
cd "$TMP_DIR"

wt_section "DirectX Jun 2010 Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
printf '\n'

# --- Download ---
wt_log "Downloading DirectX Jun 2010 redistributable..."
wget -q --show-progress -O directx_redist.exe "$DX_REDIST_URL" \
    && wt_log_ok "Download complete." \
    || { wt_log_err "Download failed. Check your internet connection."; read -rp "Press Enter to close..." < /dev/tty; exit 1; }

# --- Step 1: extract on the Linux side (no Wine GUI needed) ---
printf '\n'
wt_section "Step 1 of 2  ›  Extraction"
EXTRACT_DIR="$TMP_DIR/dx_extracted"
mkdir -p "$EXTRACT_DIR"

wt_log "Extracting DirectX redistributable (cabinet archive)..."

if command -v cabextract &>/dev/null; then
    cabextract -q -d "$EXTRACT_DIR" "$TMP_DIR/directx_redist.exe"         && wt_log_ok "Extracted with cabextract."         || { wt_log_err "cabextract extraction failed."; read -rp "Press Enter to close..." < /dev/tty; exit 1; }
elif command -v 7z &>/dev/null; then
    7z x "$TMP_DIR/directx_redist.exe" -o"$EXTRACT_DIR" -y >/dev/null         && wt_log_ok "Extracted with 7z."         || { wt_log_err "7z extraction failed."; read -rp "Press Enter to close..." < /dev/tty; exit 1; }
else
    wt_log_err "Neither cabextract nor 7z found. Install with:"
    wt_log_err "  sudo apt install cabextract"
    read -rp "Press Enter to close..." < /dev/tty
    exit 1
fi

# --- Step 2: find and run DXSETUP.exe ---
printf '\n'
wt_section "Step 2 of 2  ›  Run DXSETUP.exe"

DXSETUP_PATH="$(find "$EXTRACT_DIR" -maxdepth 3 -iname "dxsetup.exe" | head -1)"

if [[ -z "$DXSETUP_PATH" ]]; then
    wt_log_err "Could not find DXSETUP.exe in extracted files."
    wt_log_err "Contents of extraction dir:"
    ls -1 "$EXTRACT_DIR" >&2 || true
    read -rp "Press Enter to close..." < /dev/tty
    exit 1
fi

wt_log_ok "Found: $DXSETUP_PATH"
DXSETUP_DIR="$(dirname "$DXSETUP_PATH")"
cd "$DXSETUP_DIR"
printf '\n'

# --- Validate prefix has a working wineboot.exe ---
WINEBOOT_CHECK="$WINEPREFIX/drive_c/windows/system32/wineboot.exe"
if [[ ! -f "$WINEBOOT_CHECK" ]]; then
    wt_log_err "Prefix appears uninitialised or broken:"
    wt_log_err "  $WINEPREFIX"
    wt_log_err "Missing: $WINEBOOT_CHECK"
    wt_log_err ""
    wt_log_err "Please create a proper prefix first via:"
    wt_log_err "  winetoolz  ›  [ Prefix ]  ›  Create Prefix"
    wt_log_err "Then re-run this installer against that prefix."
    read -rp "  Press Enter to close..." < /dev/tty
    exit 1
fi

# Also check explorer.exe is present
EXPLORER_CHECK="$WINEPREFIX/drive_c/windows/explorer.exe"
if [[ ! -f "$EXPLORER_CHECK" ]]; then
    wt_log_err "explorer.exe missing from prefix — prefix may be incomplete."
    wt_log_err "  $WINEPREFIX"
    wt_log_err "Please recreate the prefix via Prefix Creator, then retry."
    read -rp "  Press Enter to close..." < /dev/tty
    exit 1
fi

wt_log_info "Prefix looks valid — wineboot.exe and explorer.exe present."
printf '\n'

# Run DXSETUP silently — no explorer window required
wt_log "Running DXSETUP.exe /silent ..."
"$WT_INNER_WINE" DXSETUP.exe /silent     && wt_log_ok "DirectX June 2010 installed successfully."     || wt_log_err "DXSETUP.exe exited with an error (DirectX may still have installed — check the prefix)."

wt_section "DirectX Jun 2010 installation complete."
read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
