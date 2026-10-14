#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  install_nvapi.sh — DXVK-NVAPI Installer
#  winetoolz v2.0
#  Installs DXVK-NVAPI DLLs + layer into a Wine prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DXVK-NVAPI Installer"

wt_require_cmds zenity

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix "$MODULE" || exit 0

# =============================================================================
#  3. Ensure DXVK-NVAPI release is present (auto-download if needed)
# =============================================================================

wt_ensure_release \
    "dxvk-nvapi" \
    "jp7677/dxvk-nvapi" \
    "dxvk-nvapi-v[0-9]" || exit 0

DLL_ROOT="$WT_DLL_ROOT"

# --- Auto-detect 64-bit dir ---
NVAPI_LIB64=""
if   [[ -d "$DLL_ROOT/x64" ]];   then NVAPI_LIB64="$DLL_ROOT/x64"
elif [[ -d "$DLL_ROOT/bin64" ]]; then NVAPI_LIB64="$DLL_ROOT/bin64"
fi

[[ -n "$NVAPI_LIB64" ]] || wt_error "$(printf 'Could not find a 64-bit NVAPI DLL directory under:\n  %s\n\nExpected a subfolder named  x64  or  bin64.' "$DLL_ROOT")"

# --- Auto-detect 32-bit dir (optional) ---
NVAPI_LIB32=""
if   [[ -d "$DLL_ROOT/x86" ]];   then NVAPI_LIB32="$DLL_ROOT/x86"
elif [[ -d "$DLL_ROOT/x32" ]];   then NVAPI_LIB32="$DLL_ROOT/x32"
elif [[ -d "$DLL_ROOT/32bit" ]]; then NVAPI_LIB32="$DLL_ROOT/32bit"
fi

# --- Auto-detect Vulkan layer dir ---
LAYER_DIR=""
if   [[ -d "$DLL_ROOT/layer" ]];       then LAYER_DIR="$DLL_ROOT/layer"
elif [[ -d "$DLL_ROOT/nvapi-layer" ]]; then LAYER_DIR="$DLL_ROOT/nvapi-layer"
fi

[[ -n "$LAYER_DIR" ]] || wt_error "$(printf 'Could not find an NVAPI layer directory under:\n  %s\n\nExpected a subfolder named  layer  or  nvapi-layer.\n\nThis release may not include a Vulkan layer.\nCheck the contents of:\n  %s' "$DLL_ROOT" "$DLL_ROOT")"

# =============================================================================
#  4. Generate + run helper script in terminal
# =============================================================================

TMP=$(mktemp --suffix=.sh)
trap 'rm -f "$TMP"' EXIT

cat <<EOF > "$TMP"
#!/usr/bin/env bash
set +e
source "$(printf '%s' "$SCRIPT_DIR/../winetoolz-lib.sh")"

export WINEPREFIX="$WINEPREFIX"
export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml="

INNER_WINE="$WT_INNER_WINE"
WRAPPER="$WT_WRAPPER"
NVAPI_LIB64="$NVAPI_LIB64"
NVAPI_LIB32="$NVAPI_LIB32"
LAYER_DIR="$LAYER_DIR"

wt_section "DXVK-NVAPI  ›  install"
wt_log_info "Prefix  : \$WINEPREFIX"
wt_log_info "Wine    : \$INNER_WINE"
wt_log_info "Wrapper : \${WRAPPER:-none}"
wt_log_info "x64 dir : \$NVAPI_LIB64"
wt_log_info "x32 dir : \${NVAPI_LIB32:-none}"
wt_log_info "Layer   : \$LAYER_DIR"
printf '\n'

wt_log "Initialising prefix..."
"\$INNER_WINE" wineboot -u && wt_log_ok "wineboot done." || wt_log_err "wineboot reported an error (may be harmless)."

WIN64_SYS=\$("\$INNER_WINE" winepath -u 'C:\\windows\\system32' 2>/dev/null)
WIN64_SYS=\${WIN64_SYS%$'\r'}
WIN32_SYS=\$("\$INNER_WINE" winepath -u 'C:\\windows\\syswow64' 2>/dev/null)
WIN32_SYS=\${WIN32_SYS%$'\r'}

if [[ -z "\$WIN64_SYS" ]]; then
    wt_log_err "Failed to resolve C:\\windows\\system32 — aborting."
    read -rp "Press Enter to close..." < /dev/tty
    exit 1
fi

WOW64=false
if [[ -n "\$WIN32_SYS" && -d "\$WINEPREFIX/drive_c/windows/syswow64" ]]; then
    WOW64=true
    wt_log_info "64-bit prefix — will also install 32-bit DLLs into syswow64."
else
    wt_log_info "32-bit or pure 64-bit prefix — skipping syswow64 DLLs."
fi

# --- Install all DLLs from a directory ---
install_dir() {
    local dst_dir="\$1"
    local src_dir="\$2"
    local label="\$3"

    [[ -d "\$dst_dir" ]] || { wt_log_err "Destination missing: \$dst_dir"; return 1; }
    [[ -d "\$src_dir" ]] || { wt_log_err "Source missing: \$src_dir";      return 1; }

    for dll in "\$src_dir"/*.dll; do
        [[ -f "\$dll" ]] || continue
        local name
        name=\$(basename "\$dll")
        cp "\$dll" "\$dst_dir/"
        wt_log_ok "\$name  →  \$label"
    done
}

wt_section "Installing NVAPI DLLs..."

install_dir "\$WIN64_SYS" "\$NVAPI_LIB64" "system32"

if \$WOW64 && [[ -n "\$NVAPI_LIB32" ]]; then
    install_dir "\$WIN32_SYS" "\$NVAPI_LIB32" "syswow64"
fi

wt_section "Installing Vulkan Layer..."

LAYER_DEST="\$WINEPREFIX/dxvk-nvapi-layer"
mkdir -p "\$LAYER_DEST"
cp -r "\$LAYER_DIR/"* "\$LAYER_DEST/"
wt_log_ok "Layer files copied to: \$LAYER_DEST"

wt_section "Applying DLL Overrides..."

REG_FILE=\$(mktemp --suffix=.reg)
cat <<REGEOF > "\$REG_FILE"
REGEDIT4

[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]
"nvapi"="native,builtin"
"nvapi64"="native,builtin"
REGEOF

"\$INNER_WINE" regedit "\$REG_FILE" && wt_log_ok "DLL overrides applied." || wt_log_err "regedit returned an error."
rm -f "\$REG_FILE"

wt_section "DXVK-NVAPI installation complete."
read -rp "  Press Enter to close..." < /dev/tty
EOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
