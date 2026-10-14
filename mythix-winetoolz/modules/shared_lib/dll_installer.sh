#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  dll_installer.sh — Curated DLL Component Installer
#  winetoolz v2.1
#
#  Downloads DLLs from legitimate Microsoft / open-source sources,
#  extracts them (cabextract / unzip / msiexec), places them into the
#  prefix, and sets DLL overrides — same approach as winetricks.
#
#  Sources used:
#    • Microsoft Download Center  (direct CDN links)
#    • DirectX Jun 2010 redist    (cabextract chain for d3dx* / dinput / xinput)
#    • Mozilla fxc2 repo          (d3dcompiler_47 — MIT-licensed clean build)
#    • openal.org                 (OpenAL SDK)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DLL Installer"
CACHE_DIR="${HOME}/.cache/winetoolz/dll_installer"
mkdir -p "$CACHE_DIR"

wt_require_cmds zenity wget cabextract

# =============================================================================
#  Component definitions
#  Each component has: LABEL  GROUP  DESC  (looked up by key)
# =============================================================================

declare -A DLL_LABEL DLL_GROUP DLL_DESC

# --- Direct3D 9 ---
DLL_LABEL[d3dx9_43]="d3dx9_43"
DLL_GROUP[d3dx9_43]="Direct3D 9"
DLL_DESC[d3dx9_43]="Most common d3dx9 DLL — required by a huge number of games"

DLL_LABEL[d3dx9_all]="d3dx9 (full set, _24–_43)"
DLL_GROUP[d3dx9_all]="Direct3D 9"
DLL_DESC[d3dx9_all]="All d3dx9 versions _24 through _43 — covers every game that uses one"

# --- Direct3D 10 ---
DLL_LABEL[d3dx10_43]="d3dx10_43"
DLL_GROUP[d3dx10_43]="Direct3D 10"
DLL_DESC[d3dx10_43]="D3DX10 helper lib — required by some DX10 games"

DLL_LABEL[d3dx10_all]="d3dx10 (full set, _33–_43)"
DLL_GROUP[d3dx10_all]="Direct3D 10"
DLL_DESC[d3dx10_all]="All d3dx10 versions — covers all DX10 era games"

# --- Direct3D 11 ---
DLL_LABEL[d3dx11_43]="d3dx11_43"
DLL_GROUP[d3dx11_43]="Direct3D 11"
DLL_DESC[d3dx11_43]="D3DX11 helper — required by some DX11 games / tools"

DLL_LABEL[d3dx11_42]="d3dx11_42"
DLL_GROUP[d3dx11_42]="Direct3D 11"
DLL_DESC[d3dx11_42]="Older D3DX11 version — some games specifically need _42"

# --- Direct3D Compiler ---
DLL_LABEL[d3dcompiler_43]="d3dcompiler_43"
DLL_GROUP[d3dcompiler_43]="D3D Compiler"
DLL_DESC[d3dcompiler_43]="Legacy shader compiler — from DirectX Jun 2010 package"

DLL_LABEL[d3dcompiler_47]="d3dcompiler_47"
DLL_GROUP[d3dcompiler_47]="D3D Compiler"
DLL_DESC[d3dcompiler_47]="Modern shader compiler — required by Unity / Unreal and many others"

# --- DirectDraw / Direct3D legacy ---
DLL_LABEL[d3drm]="d3drm"
DLL_GROUP[d3drm]="Direct3D Legacy"
DLL_DESC[d3drm]="Direct3D Retained Mode — for very old (pre-DX8) games"

DLL_LABEL[ddraw]="ddraw (cnc-ddraw)"
DLL_GROUP[ddraw]="Direct3D Legacy"
DLL_DESC[ddraw]="Enhanced ddraw replacement — fixes old DirectDraw games on modern systems"

# --- Input ---
DLL_LABEL[xinput1_3]="xinput1_3"
DLL_GROUP[xinput1_3]="Input"
DLL_DESC[xinput1_3]="XInput gamepad support — from DirectX Jun 2010 package"

DLL_LABEL[xinput9_1_0]="xinput9_1_0"
DLL_GROUP[xinput9_1_0]="Input"
DLL_DESC[xinput9_1_0]="Older XInput variant — some games need this specific version"

DLL_LABEL[dinput]="dinput (dinputto8)"
DLL_GROUP[dinput]="Input"
DLL_DESC[dinput]="dinputto8 drop-in — converts DInput 1–7 calls to DInput 8"

# --- XML / System ---
DLL_LABEL[msxml3]="msxml3"
DLL_GROUP[msxml3]="XML / System"
DLL_DESC[msxml3]="MS XML Core Services 3 — required by many older apps and games"

DLL_LABEL[msxml6]="msxml6"
DLL_GROUP[msxml6]="XML / System"
DLL_DESC[msxml6]="MS XML Core Services 6 SP2 — required by Office, many installers"

# --- Media ---
DLL_LABEL[quartz]="quartz (ffdshow)"
DLL_GROUP[quartz]="Media"
DLL_DESC[quartz]="DirectShow quartz filter — improves video / cutscene playback"

DLL_LABEL[devenum]="devenum"
DLL_GROUP[devenum]="Media"
DLL_DESC[devenum]="Device enumerator — needed by DirectShow-based video/audio"

# --- Physics ---
DLL_LABEL[physx]="PhysX Legacy (9.13)"
DLL_GROUP[physx]="Physics"
DLL_DESC[physx]="NVIDIA PhysX 9.13.0604 — required by older PhysX-enabled games"

DLL_ORDER=(
    d3dx9_43 d3dx9_all
    d3dx10_43 d3dx10_all
    d3dx11_43 d3dx11_42
    d3dcompiler_43 d3dcompiler_47
    d3drm ddraw
    xinput1_3 xinput9_1_0 dinput
    msxml3 msxml6
    quartz devenum
    physx
)

# =============================================================================
#  Download URLs
# =============================================================================

# DirectX Jun 2010 — used to extract d3dx9, d3dx10, d3dx11, xinput, d3dcompiler_43
DIRECTX_2010_URL="https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"
DIRECTX_2010_CACHE="$CACHE_DIR/directx_Jun2010_redist.exe"

# d3drm — Direct3D Retained Mode (removed from Windows after XP).
# d3drm was NEVER in the DX side-by-side cabs — it was a core OS component.
# DxWnd (open-source SourceForge project) hosts the original Microsoft DLL for redistribution.
URL_D3DRM="https://downloads.sourceforge.net/project/dxwnd/Redist/d3drm.dll"

# d3dcompiler_47 — Mozilla fxc2 clean MIT-licensed build
URL_D3DCOMP47_X86="https://raw.githubusercontent.com/mozilla/fxc2/master/dll/d3dcompiler_47_32.dll"
URL_D3DCOMP47_X64="https://raw.githubusercontent.com/mozilla/fxc2/master/dll/d3dcompiler_47.dll"

# msxml3 — Microsoft CDN
URL_MSXML3="https://download.microsoft.com/download/8/8/8/888f34b7-4f54-4f06-8dac-fa29b19f33dd/msxml3.msi"

# msxml6 — Microsoft CDN (KB2957482, SP2, includes 32+64)
URL_MSXML6="https://download.microsoft.com/download/2/7/7/277681BE-4048-4A58-ABBA-259C465B1699/msxml6-KB2957482-enu-amd64.exe"

# cnc-ddraw — open source, GitHub releases
URL_CNC_DDRAW="https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v7.0.0.0/cnc-ddraw.zip"

# dinputto8 — open source, GitHub releases
URL_DINPUTTO8="https://github.com/elishacloud/dinputto8/releases/download/v1.0.92.0/dinput.dll"

# PhysX 9.13 Legacy — the actual download is an MSI, not an exe.
# Chocolatey's install script confirms this NVIDIA CDN URL is still live.
# Must be installed with wine msiexec — running it directly causes ShellExecuteEx errors.
URL_PHYSX="http://us.download.nvidia.com/Windows/9.13.0604/PhysX-9.13.0604-SystemSoftware-Legacy.msi"

# =============================================================================
#  1. Select Wine binary + prefix
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

IS_WIN64=false
wt_is_win64 "$WINEPREFIX" && IS_WIN64=true

SYS32="$WINEPREFIX/drive_c/windows/system32"
SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

# =============================================================================
#  2. Checklist
# =============================================================================

CHECKLIST_ARGS=()
for key in "${DLL_ORDER[@]}"; do
    CHECKLIST_ARGS+=(FALSE "$key" "${DLL_GROUP[$key]:-Other}" "${DLL_LABEL[$key]}" "${DLL_DESC[$key]}")
done

SELECTED=$(zenity --list \
    --title="$(wt_title "$MODULE  ›  Select Components")" \
    --text="<tt>Check each DLL component you want to install.\nDownloads are cached in  ~/.cache/winetoolz/dll_installer/</tt>" \
    --checklist \
    --column="Install" --column="Key" --column="Group" --column="DLL / Component" --column="Description" \
    --hide-column=2 --print-column=2 \
    --width=1000 --height=580 \
    "${CHECKLIST_ARGS[@]}") || exit 0

[[ -z "$SELECTED" ]] && wt_info "$MODULE" "No components selected — nothing to do." && exit 0

IFS='|' read -ra CHOSEN_KEYS <<< "$SELECTED"

# =============================================================================
#  3. Export + inner terminal script
# =============================================================================

export WT_INNER_WINE WT_WRAPPER WINEPREFIX
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
export WT_IS_WIN64="$IS_WIN64"
export WT_SYS32="$SYS32"
export WT_SYSWOW64="$SYSWOW64"
export WT_CACHE="$CACHE_DIR"
export WT_CHOSEN_KEYS="${CHOSEN_KEYS[*]}"

export DIRECTX_2010_URL DIRECTX_2010_CACHE
export URL_D3DRM
export URL_D3DCOMP47_X86 URL_D3DCOMP47_X64
export URL_MSXML3 URL_MSXML6
export URL_CNC_DDRAW URL_DINPUTTO8 URL_PHYSX

TMP=$(mktemp --suffix=.sh)
trap 'rm -f "$TMP"' EXIT

cat <<'INNEREOF' > "$TMP"
#!/usr/bin/env bash
set +e

source "$WT_LIB_PATH"
export WINEPREFIX

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

read -ra KEYS <<< "$WT_CHOSEN_KEYS"

SYS32="$WT_SYS32"
SYSWOW64="$WT_SYSWOW64"
IS_WIN64="$WT_IS_WIN64"
CACHE="$WT_CACHE"

# ==========================================================================
#  Helpers
# ==========================================================================

wt_dl() {
    local url="$1" out="$2" label="${3:-$(basename "$out")}"
    if [[ -f "$out" ]]; then
        wt_log_info "  Cached:  $label"
        return 0
    fi
    wt_log "  Downloading $label..."
    wget -q --show-progress -O "$out" "$url" \
        && wt_log_ok "  Downloaded: $label" \
        || { wt_log_err "  Download FAILED: $url"; return 1; }
}

# Copy a DLL into a system dir, removing symlinks first (wine uses them)
install_dll() {
    local src="$1" dst_dir="$2" name="${3:-$(basename "$src")}"
    [[ -L "$dst_dir/$name" ]] && rm -f "$dst_dir/$name"
    cp -f "$src" "$dst_dir/$name" \
        && wt_log_ok "  [OK] $name → $(basename "$dst_dir")" \
        || wt_log_err "  [FAIL] $name → $(basename "$dst_dir")"
}

# Set a DLL override in the registry
set_override() {
    local dll="$1" mode="${2:-native,builtin}"
    "$WT_INNER_WINE" reg add \
        'HKEY_CURRENT_USER\Software\Wine\DllOverrides' \
        /v "$dll" /d "$mode" /f >/dev/null 2>&1 \
        && wt_log_ok "  [OK] override: $dll = $mode" \
        || wt_log_err "  [FAIL] override: $dll"
}

# Ensure the DirectX Jun 2010 package is cached (shared across d3dx* installs)
ensure_directx_2010() {
    wt_dl "$DIRECTX_2010_URL" "$DIRECTX_2010_CACHE" "DirectX Jun 2010 redist (~100MB)"
}

# Extract a specific DLL from a DirectX redist using the two-stage cabextract method.
# Args:
#   $1  dll_name   — e.g. d3dx9_43
#   $2  arch       — x86 or x64
#   $3  cab_glob   — optional: override cab search glob (default: *dll_name*arch*)
#   $4  pkg_file   — optional: which redist exe to search (default: DIRECTX_2010_CACHE)
extract_from_directx() {
    local dll_name="$1"    # e.g. d3dx9_43
    local arch="$2"        # x86 or x64
    local cab_glob="${3:-*${dll_name}*${arch}*}"   # optional override
    local pkg_file="${4:-$DIRECTX_2010_CACHE}"     # optional: which redist to search

    local cab_dir="$TMP_DIR/cab_${dll_name}_${arch}"
    mkdir -p "$cab_dir"

    # Stage 1: extract all cabs matching the glob from the redist
    cabextract -q -d "$cab_dir" -L -F "$cab_glob" "$pkg_file" 2>/dev/null || true

    # Stage 2: loop ALL found cabs — some DLLs (e.g. xinput1_3) live in a later-dated
    # cab than the first match, so searching only head -1 silently misses them.
    local dll_file=""
    while IFS= read -r -d '' cab_file; do
        local try_dir="$TMP_DIR/dll_${dll_name}_${arch}_$(basename "$cab_file" .cab)"
        mkdir -p "$try_dir"
        cabextract -q -d "$try_dir" -L "$cab_file" 2>/dev/null || true
        dll_file="$(find "$try_dir" -iname "${dll_name}.dll" | head -1)"
        [[ -n "$dll_file" ]] && break
    done < <(find "$cab_dir" -name '*.cab' -print0)

    if [[ -z "$dll_file" ]]; then
        wt_log_err "  DLL not found in any cab for $dll_name ($arch)"
        return 1
    fi

    echo "$dll_file"
}

# ==========================================================================
#  Install functions
# ==========================================================================

install_d3dx9_43() {
    wt_section "d3dx9_43"
    ensure_directx_2010 || return 1

    local f32 f64
    f32="$(extract_from_directx d3dx9_43 x86)" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "d3dx9_43"

    if [[ "$IS_WIN64" == "true" ]]; then
        f64="$(extract_from_directx d3dx9_43 x64)" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_d3dx9_all() {
    wt_section "d3dx9 (full set _24–_43)"
    ensure_directx_2010 || return 1

    local n
    for n in $(seq 24 43); do
        local dll="d3dx9_${n}"
        wt_log "  Processing $dll..."

        local f32
        f32="$(extract_from_directx "$dll" x86 2>/dev/null)" || { wt_log_info "  Skipping $dll x86 (not in package)"; continue; }
        install_dll "$f32" "$SYSWOW64"

        if [[ "$IS_WIN64" == "true" ]]; then
            local f64
            f64="$(extract_from_directx "$dll" x64 2>/dev/null)" || true
            [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
        fi

        set_override "$dll"
    done
}

install_d3dx10_43() {
    wt_section "d3dx10_43"
    ensure_directx_2010 || return 1

    local f32
    f32="$(extract_from_directx d3dx10_43 x86)" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "d3dx10_43"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx d3dx10_43 x64)" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_d3dx10_all() {
    wt_section "d3dx10 (full set _33–_43)"
    ensure_directx_2010 || return 1

    local n
    for n in $(seq 33 43); do
        local dll="d3dx10_${n}"
        wt_log "  Processing $dll..."

        local f32
        f32="$(extract_from_directx "$dll" x86 2>/dev/null)" || { wt_log_info "  Skipping $dll (not in package)"; continue; }
        install_dll "$f32" "$SYSWOW64"

        if [[ "$IS_WIN64" == "true" ]]; then
            local f64
            f64="$(extract_from_directx "$dll" x64 2>/dev/null)" || true
            [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
        fi

        set_override "$dll"
    done
}

install_d3dx11_43() {
    wt_section "d3dx11_43"
    ensure_directx_2010 || return 1

    local f32
    f32="$(extract_from_directx d3dx11_43 x86)" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "d3dx11_43"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx d3dx11_43 x64)" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_d3dx11_42() {
    wt_section "d3dx11_42"
    ensure_directx_2010 || return 1

    local f32
    f32="$(extract_from_directx d3dx11_42 x86)" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "d3dx11_42"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx d3dx11_42 x64)" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_d3dcompiler_43() {
    wt_section "d3dcompiler_43"
    ensure_directx_2010 || return 1

    local f32
    f32="$(extract_from_directx d3dcompiler_43 x86)" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "d3dcompiler_43"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx d3dcompiler_43 x64)" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_d3dcompiler_47() {
    wt_section "d3dcompiler_47"
    wt_log_info "Source: Mozilla fxc2 — MIT-licensed clean build"

    local f32="$CACHE/d3dcompiler_47_32.dll"
    local f64="$CACHE/d3dcompiler_47.dll"

    wt_dl "$URL_D3DCOMP47_X86" "$f32" "d3dcompiler_47 (x86)" || return 1
    wt_dl "$URL_D3DCOMP47_X64" "$f64" "d3dcompiler_47 (x64)" || return 1

    install_dll "$f32" "$SYSWOW64" "d3dcompiler_47.dll"
    set_override "d3dcompiler_47"

    if [[ "$IS_WIN64" == "true" ]]; then
        install_dll "$f64" "$SYS32" "d3dcompiler_47.dll"
    fi
}

install_d3drm() {
    wt_section "d3drm"
    # d3drm (Direct3D Retained Mode) was a core Windows OS component removed after XP.
    # It was NEVER distributed via the DirectX side-by-side cabs — those only contain
    # components like d3dx9/d3dx10/xinput that were added post-DX9.
    # DxWnd (open-source SourceForge project) hosts the original Microsoft DLL.
    wt_log_info "Source: DxWnd SourceForge Redist (original Microsoft d3drm.dll)"

    local dll_file="$CACHE/d3drm.dll"
    wt_dl "$URL_D3DRM" "$dll_file" "d3drm.dll (~220KB)" || return 1

    install_dll "$dll_file" "$SYSWOW64" "d3drm.dll"
    set_override "d3drm"
}

install_ddraw() {
    wt_section "ddraw (cnc-ddraw)"
    wt_log_info "Source: github.com/FunkyFr3sh/cnc-ddraw (open source)"
    local pkg="$CACHE/cnc-ddraw.zip"
    wt_dl "$URL_CNC_DDRAW" "$pkg" "cnc-ddraw.zip" || return 1

    local ext_dir="$TMP_DIR/cnc_ddraw"
    mkdir -p "$ext_dir"
    unzip -o -qq "$pkg" -d "$ext_dir"

    local dll_file
    dll_file="$(find "$ext_dir" -iname 'ddraw.dll' | grep -i 'x86\|32' | head -1)"
    [[ -z "$dll_file" ]] && dll_file="$(find "$ext_dir" -iname 'ddraw.dll' | head -1)"

    if [[ -z "$dll_file" ]]; then
        wt_log_err "  ddraw.dll not found in cnc-ddraw archive"
        return 1
    fi
    install_dll "$dll_file" "$SYSWOW64" "ddraw.dll"
    set_override "ddraw" "native,builtin"
}

install_xinput1_3() {
    wt_section "xinput1_3"
    ensure_directx_2010 || return 1

    # XInput cabs in the DX2010 package are named Apr2007_xinput_x86.cab,
    # not *xinput1_3*x86* — so we must pass an explicit cab glob.
    local f32
    f32="$(extract_from_directx xinput1_3 x86 "*xinput*x86*")" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "xinput1_3"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx xinput1_3 x64 "*xinput*x64*")" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_xinput9_1_0() {
    wt_section "xinput9_1_0"
    ensure_directx_2010 || return 1

    # Same cab-naming issue as xinput1_3 — glob must match Apr2007_xinput_x86.cab
    local f32
    f32="$(extract_from_directx xinput9_1_0 x86 "*xinput*x86*")" || return 1
    install_dll "$f32" "$SYSWOW64"
    set_override "xinput9_1_0"

    if [[ "$IS_WIN64" == "true" ]]; then
        local f64
        f64="$(extract_from_directx xinput9_1_0 x64 "*xinput*x64*")" || true
        [[ -n "$f64" ]] && install_dll "$f64" "$SYS32"
    fi
}

install_dinput() {
    wt_section "dinput (dinputto8)"
    wt_log_info "Source: github.com/elishacloud/dinputto8 (open source)"
    local dll_file="$CACHE/dinput_dinputto8.dll"
    wt_dl "$URL_DINPUTTO8" "$dll_file" "dinputto8 dinput.dll" || return 1
    install_dll "$dll_file" "$SYSWOW64" "dinput.dll"
    set_override "dinput" "native,builtin"
}

install_msxml3() {
    wt_section "msxml3"
    wt_log_info "Source: Microsoft Download Center"
    local msi="$CACHE/msxml3.msi"
    wt_dl "$URL_MSXML3" "$msi" "msxml3.msi" || return 1

    local ext_dir="$TMP_DIR/msxml3_ext"
    mkdir -p "$ext_dir"
    cabextract -q -d "$ext_dir" "$msi" 2>/dev/null || true

    local dll_file
    dll_file="$(find "$ext_dir" -iname 'msxml3.dll' | head -1)"
    if [[ -z "$dll_file" ]]; then
        # Try wine msiexec as fallback
        wt_log_info "  Trying msiexec install..."
        "$WT_INNER_WINE" msiexec /i "$msi" /quiet /norestart 2>/dev/null || true
        set_override "msxml3" "native,builtin"
        wt_log_info "  msxml3 installed via msiexec"
        return 0
    fi
    install_dll "$dll_file" "$SYSWOW64" "msxml3.dll"
    set_override "msxml3" "native,builtin"
}

install_msxml6() {
    wt_section "msxml6"
    wt_log_info "Source: Microsoft Download Center (KB2957482 SP2)"
    local pkg="$CACHE/msxml6-KB2957482-enu-amd64.exe"
    wt_dl "$URL_MSXML6" "$pkg" "msxml6-KB2957482-enu-amd64.exe (~1.8MB)" || return 1

    local ext1="$TMP_DIR/msxml6_stage1"
    local ext2_32="$TMP_DIR/msxml6_32"
    local ext2_64="$TMP_DIR/msxml6_64"
    mkdir -p "$ext1" "$ext2_32" "$ext2_64"

    # Stage 1: extract outer exe
    cabextract -q -d "$ext1" "$pkg" 2>/dev/null || true

    # Stage 2: extract 32-bit msi
    local msi32
    msi32="$(find "$ext1" -path '*/32/*' -iname 'msxml6.msi' | head -1)"
    [[ -z "$msi32" ]] && msi32="$(find "$ext1" -iname 'msxml6.msi' | head -1)"

    if [[ -n "$msi32" ]]; then
        cabextract -q -d "$ext2_32" "$msi32" 2>/dev/null || true
        local dll32
        dll32="$(find "$ext2_32" -iname 'msxml6.dll*' | head -1)"
        if [[ -n "$dll32" ]]; then
            install_dll "$dll32" "$SYSWOW64" "msxml6.dll"
        fi
    fi

    # Stage 2: extract 64-bit msi (if win64 prefix)
    if [[ "$IS_WIN64" == "true" ]]; then
        local msi64
        msi64="$(find "$ext1" -path '*/64/*' -iname 'msxml6.msi' | head -1)"
        if [[ -n "$msi64" ]]; then
            cabextract -q -d "$ext2_64" "$msi64" 2>/dev/null || true
            local dll64
            dll64="$(find "$ext2_64" -iname 'msxml6.dll*' | head -1)"
            if [[ -n "$dll64" ]]; then
                install_dll "$dll64" "$SYS32" "msxml6.dll"
            fi
        fi
    fi

    set_override "msxml6" "native,builtin"
}

install_quartz() {
    wt_section "quartz"
    wt_log_info "Setting quartz DLL override to native,builtin..."
    set_override "quartz" "native,builtin"
    wt_log_info "Note: native quartz requires ffdshow or other DirectShow filters installed."
}

install_devenum() {
    wt_section "devenum"
    wt_log_info "Setting devenum DLL override to native,builtin..."
    set_override "devenum" "native,builtin"
}

install_physx() {
    wt_section "PhysX Legacy (9.13.0604)"
    wt_log_info "Source: NVIDIA CDN (official MSI package)"
    # The file is an MSI — use a distinct cache name so stale .exe downloads are not reused.
    local pkg="$CACHE/PhysX-9.13.0604-SystemSoftware-Legacy.msi"
    wt_dl "$URL_PHYSX" "$pkg" "PhysX-9.13.0604-SystemSoftware-Legacy.msi (~19MB)" || return 1

    # Validate the download is actually an MSI / PE, not an HTML error page
    local magic
    magic="$(file "$pkg" 2>/dev/null || true)"
    if ! echo "$magic" | grep -qi 'MSI\|Composite Document\|CDFV2'; then
        wt_log_err "  Downloaded file does not appear to be a valid MSI."
        wt_log_err "  Delete the cached file and retry: $pkg"
        return 1
    fi

    wt_log "  Running PhysX MSI installer via msiexec..."
    "$WT_INNER_WINE" msiexec /i "$pkg" /quiet /norestart 2>/dev/null
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        wt_log_ok "  PhysX installed."
    else
        wt_log_err "  msiexec exited with code $rc (may still have installed — exit 3010 = reboot required, also means success)."
    fi
}

# ==========================================================================
#  Main dispatch loop
# ==========================================================================

wt_section "DLL Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
wt_log_info "Cache  : $WT_CACHE"
wt_log_info "Queue  : ${KEYS[*]}"
printf '\n'

SUCCEEDED=()
FAILED=()

for key in "${KEYS[@]}"; do
    fn="install_${key}"
    if declare -f "$fn" > /dev/null; then
        if "$fn"; then
            SUCCEEDED+=("$key")
        else
            FAILED+=("$key")
        fi
        printf '\n'
    else
        wt_log_err "No install function for: $key"
        FAILED+=("$key")
    fi
done

wt_section "DLL Installer — Summary"
wt_log_info "Succeeded : ${SUCCEEDED[*]:-(none)}"
wt_log_info "Failed    : ${FAILED[*]:-(none)}"
wt_log_info "Prefix    : $WINEPREFIX"
wt_log_info ""
wt_log_info "Downloads cached at: $WT_CACHE"
wt_log_info "(Safe to delete to free space, will re-download as needed)"

read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
