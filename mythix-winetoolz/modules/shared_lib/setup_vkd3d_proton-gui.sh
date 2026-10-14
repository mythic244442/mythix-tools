#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  setup_vkd3d_proton-gui.sh — VKD3D-Proton Installer / Uninstaller
#  winetoolz v2.0
#  Installs or removes vkd3d-proton DLLs (d3d12, d3d12core) into a Wine prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="VKD3D-Proton Installer"
DLLS_64=(d3d12 d3d12core)
DLLS_32=(d3d12 d3d12core)

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
    FALSE "uninstall" "Restore original DLLs and remove overrides" \
    --width="$WT_WIDTH" --height=220) || exit 0

# =============================================================================
#  2. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  3. Select WINEPREFIX
# =============================================================================

wt_select_prefix "$MODULE" || exit 0

# =============================================================================
#  4. Ensure VKD3D-Proton release is present (auto-download if needed)
# =============================================================================

DLL_ROOT=""
if [[ "$ACTION" == "install" ]]; then
    wt_ensure_release \
        "vkd3d-proton" \
        "HansKristian-Work/vkd3d-proton" \
        "vkd3d-proton-[0-9]" || exit 0
    DLL_ROOT="$WT_DLL_ROOT"
fi

# Auto-detect 64-bit dir
VKD3D_LIB64=""
if   [[ -d "$DLL_ROOT/x64" ]];   then VKD3D_LIB64="$DLL_ROOT/x64"
elif [[ -d "$DLL_ROOT/lib64" ]]; then VKD3D_LIB64="$DLL_ROOT/lib64"
fi

if [[ "$ACTION" == "install" ]] && [[ -z "$VKD3D_LIB64" ]]; then
    wt_error "$(printf 'Could not find a 64-bit DLL directory under:\n  %s\n\nExpected a subfolder named  x64  or  lib64.' "$DLL_ROOT")"
fi

# Auto-detect 32-bit dir (optional)
VKD3D_LIB32=""
if   [[ -d "$DLL_ROOT/x86" ]]; then VKD3D_LIB32="$DLL_ROOT/x86"
elif [[ -d "$DLL_ROOT/x32" ]]; then VKD3D_LIB32="$DLL_ROOT/x32"
elif [[ -d "$DLL_ROOT/lib" ]]; then VKD3D_LIB32="$DLL_ROOT/lib"
fi

# =============================================================================
#  5. Generate + run helper script in terminal
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
VKD3D_LIB64="$VKD3D_LIB64"
VKD3D_LIB32="$VKD3D_LIB32"
DLLS_64=(${DLLS_64[*]})
DLLS_32=(${DLLS_32[*]})
ACTION="$ACTION"

wt_section "VKD3D-Proton  ›  \$ACTION"
wt_log_info "Prefix  : \$WINEPREFIX"
wt_log_info "Wine    : \$INNER_WINE"
wt_log_info "Wrapper : \${WRAPPER:-none}"
wt_log_info "x64 dir : \$VKD3D_LIB64"
wt_log_info "x32 dir : \${VKD3D_LIB32:-none (64-bit prefix)}"
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

install_dll() {
    local dst_dir="\$1" src_dir="\$2" name="\$3" label="\${4:-$(basename "\$dst_dir")}"

    [[ -d "\$dst_dir" ]] || { wt_log_err "Dest dir missing: \$dst_dir"; return 1; }
    [[ -n "\$src_dir" && -d "\$src_dir" ]] || { wt_log_err "Source dir missing for \$name — skipping."; return 1; }

    local src="\$src_dir/\$name.dll"
    local dst="\$dst_dir/\$name.dll"

    [[ -f "\$src" ]] || { wt_log_err "DLL not found: \$src"; return 1; }

    if   [[ -f "\$dst" ]]; then  mv "\$dst" "\$dst.wt_bak"
    elif [[ -h "\$dst" ]]; then  rm "\$dst"
    else                         touch "\$dst.wt_bak_none"
    fi

    cp "\$src" "\$dst"
    "\$INNER_WINE" reg add \
        'HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides' \
        /v "\$name" /d "native,builtin" /f >/dev/null 2>&1

    wt_log_ok "\$name  →  \$label"
}

uninstall_dll() {
    local dst_dir="\$1" name="\$2" label="\${3:-$(basename "\$dst_dir")}"
    local dst="\$dst_dir/\$name.dll"

    if   [[ -f "\$dst.wt_bak" ]];      then rm "\$dst";  mv "\$dst.wt_bak" "\$dst"
    elif [[ -f "\$dst.wt_bak_none" ]]; then rm -f "\$dst.wt_bak_none" "\$dst"
    else [[ -f "\$dst" ]] && rm "\$dst"
    fi

    "\$INNER_WINE" reg delete \
        'HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides' \
        /v "\$name" /f >/dev/null 2>&1 || true

    wt_log_ok "restored  \$name  in  \$label"
}

wt_section "Processing DLLs..."

if [[ "\$ACTION" == "install" ]]; then
    for name in "\${DLLS_64[@]}"; do
        install_dll "\$WIN64_SYS" "\$VKD3D_LIB64" "\$name"  "system32  [64-bit]"
    done
    if \$WOW64 && [[ -n "\$VKD3D_LIB32" ]]; then
        for name in "\${DLLS_32[@]}"; do
            install_dll "\$WIN32_SYS" "\$VKD3D_LIB32" "\$name"  "syswow64  [32-bit]"
        done
    fi
else
    for name in "\${DLLS_64[@]}"; do
        uninstall_dll "\$WIN64_SYS" "\$name"  "system32  [64-bit]"
    done
    if \$WOW64; then
        for name in "\${DLLS_32[@]}"; do
            uninstall_dll "\$WIN32_SYS" "\$name"  "syswow64  [32-bit]"
        done
    fi
fi

wt_section "VKD3D-Proton \$ACTION complete."
read -rp "  Press Enter to close..." < /dev/tty
EOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
