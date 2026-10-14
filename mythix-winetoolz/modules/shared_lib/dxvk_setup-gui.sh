#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  dxvk_setup-gui.sh — DXVK Installer / Uninstaller
#  winetoolz v2.0
#  Installs or removes DXVK DLLs (d3d8/9/10/11, dxgi) into a Wine prefix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DXVK Installer"
DLLS=(dxgi d3d11 d3d10core d3d9 d3d8)

wt_require_cmds zenity

# =============================================================================
#  1. Choose action
# =============================================================================

ACTION=$(zenity --list \
    --title="$(wt_title "$MODULE")" \
    --text="<tt>Choose an action to perform on the selected prefix.</tt>" \
    --radiolist \
    --column="" --column="Action" --column="Description" \
    TRUE  "install"   "Copy DXVK DLLs into prefix and set DLL overrides" \
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
#  4. Ensure DXVK release is present (auto-download if needed)
# =============================================================================

# wt_ensure_release exports WT_DLL_ROOT on success.
# Skipped for uninstall — we only need the prefix paths in that case.
DLL_ROOT=""
if [[ "$ACTION" == "install" ]]; then
    wt_ensure_release \
        "dxvk" \
        "doitsujin/dxvk" \
        "dxvk-[0-9]" || exit 0
    DLL_ROOT="$WT_DLL_ROOT"
fi

# Auto-detect 64-bit dir
DXVK_LIB64=""
if   [[ -d "$DLL_ROOT/x64" ]];   then DXVK_LIB64="$DLL_ROOT/x64"
elif [[ -d "$DLL_ROOT/lib64" ]]; then DXVK_LIB64="$DLL_ROOT/lib64"
fi

if [[ "$ACTION" == "install" ]] && [[ -z "$DXVK_LIB64" ]]; then
    wt_error "$(printf 'Could not find a 64-bit DLL directory under:\n  %s\n\nExpected a subfolder named  x64  or  lib64.' "$DLL_ROOT")"
fi

# Auto-detect 32-bit dir (optional)
DXVK_LIB32=""
if   [[ -d "$DLL_ROOT/x32" ]]; then DXVK_LIB32="$DLL_ROOT/x32"
elif [[ -d "$DLL_ROOT/x86" ]]; then DXVK_LIB32="$DLL_ROOT/x86"
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
DXVK_LIB64="$DXVK_LIB64"
DXVK_LIB32="$DXVK_LIB32"
DLLS=(${DLLS[*]})
ACTION="$ACTION"

wt_section "DXVK  ›  \$ACTION"
wt_log_info "Prefix  : \$WINEPREFIX"
wt_log_info "Wine    : \$INNER_WINE"
wt_log_info "Wrapper : \${WRAPPER:-none}"
wt_log_info "x64 dir : \$DXVK_LIB64"
wt_log_info "x32 dir : \${DXVK_LIB32:-none (64-bit prefix)}"
printf '\n'

# --- Ensure prefix is initialised ---
wt_log "Initialising prefix..."
"\$INNER_WINE" wineboot -u && wt_log_ok "wineboot done." || wt_log_err "wineboot reported an error (may be harmless)."

# --- Resolve system dirs via winepath ---
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
    wt_log_info "64-bit prefix detected — will install 32-bit DLLs into syswow64."
else
    wt_log_info "32-bit or pure 64-bit prefix — skipping syswow64 DLLs."
fi

# --- Install helper ---
install_dll() {
    local dst_dir="\$1" src_dir="\$2" name="\$3" label="\${4:-$(basename "\$dst_dir")}"

    if [[ ! -d "\$dst_dir" ]]; then
        wt_log_err "Destination directory missing, skipping: \$dst_dir"
        return 1
    fi
    if [[ -z "\$src_dir" || ! -d "\$src_dir" ]]; then
        wt_log_err "Source directory missing for \$name — skipping."
        return 1
    fi

    local src="\$src_dir/\$name.dll"
    local dst="\$dst_dir/\$name.dll"

    if [[ ! -f "\$src" ]]; then
        wt_log_err "DLL not found in source: \$src"
        return 1
    fi

    # Back up existing DLL
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

# --- Uninstall helper ---
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

# --- Main loop ---
wt_section "Processing DLLs: \${DLLS[*]}"

for name in "\${DLLS[@]}"; do
    if [[ "\$ACTION" == "install" ]]; then
        install_dll "\$WIN64_SYS"  "\$DXVK_LIB64"  "\$name"  "system32  [64-bit]"
        if \$WOW64 && [[ -n "\$DXVK_LIB32" ]]; then
            install_dll "\$WIN32_SYS" "\$DXVK_LIB32" "\$name"  "syswow64  [32-bit]"
        fi
    else
        uninstall_dll "\$WIN64_SYS" "\$name"  "system32  [64-bit]"
        \$WOW64 && uninstall_dll "\$WIN32_SYS" "\$name"  "syswow64  [32-bit]"
    fi
done

wt_section "DXVK \$ACTION complete."
read -rp "  Press Enter to close..." < /dev/tty
EOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
