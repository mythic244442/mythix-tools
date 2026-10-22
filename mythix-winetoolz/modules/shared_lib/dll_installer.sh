#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  dll_installer.sh — Curated DLL Component Installer
#  winetoolz v3.0
#
#  Downloads DLLs from legitimate Microsoft / open-source sources,
#  extracts them (cabextract / unzip / msiexec), places them into the
#  prefix, and sets DLL overrides — same approach as winetricks.
#  Every download is checked against the sha256 in ../downloads.tsv.
#
#  Sources used:
#    • Microsoft Download Center  (direct CDN links)
#    • DirectX Jun 2010 redist    (cabextract chain for d3dx* / xinput)
#    • Mozilla fxc2 repo          (d3dcompiler_47, pinned commit)
#    • cnc-ddraw / dinputto8 / DxWnd redist (pinned releases)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="DLL Installer"

wt_require_cmds zenity cabextract
_wt_have curl || _wt_have wget || wt_require_cmds curl

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
DLL_LABEL[quartz]="quartz (game's own copy)"
DLL_GROUP[quartz]="Media"
DLL_DESC[quartz]="Override only — lets a game that ships its own quartz.dll use it for videos"

DLL_LABEL[devenum]="devenum (game's own copy)"
DLL_GROUP[devenum]="Media"
DLL_DESC[devenum]="Override only — lets a game that ships its own devenum.dll use it"

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
#  1. Select Wine binary + prefix
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  2. Checklist
# =============================================================================

CHECKLIST_ARGS=()
for key in "${DLL_ORDER[@]}"; do
    CHECKLIST_ARGS+=(FALSE "$key" "${DLL_GROUP[$key]:-Other}" "${DLL_LABEL[$key]}" "${DLL_DESC[$key]}")
done

SELECTED=$(zenity --list \
    --title="$(wt_title "$MODULE  ›  Select Components")" \
    --text="$(_wt_box "$(printf 'Check each DLL component you want to install.\nDownloads are verified and cached in  %s' "$WT_DL_CACHE")")" \
    --checklist \
    --column="Install" --column="Key" --column="Group" --column="DLL / Component" --column="Description" \
    --hide-column=2 --print-column=2 \
    --width=1000 --height=580 \
    "${CHECKLIST_ARGS[@]}") || exit 0

if [[ -z "$SELECTED" ]]; then
    wt_info "$MODULE" "No components selected — nothing to do."
    exit 0
fi

IFS='|' read -ra CHOSEN_KEYS <<< "$SELECTED"

# =============================================================================
#  3. Export + inner terminal script
# =============================================================================

export WT_INNER_WINE WT_WRAPPER WINEPREFIX
export WT_CHOSEN_KEYS="${CHOSEN_KEYS[*]}"

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

read -ra KEYS <<< "$WT_CHOSEN_KEYS"

# Where each architecture's DLLs belong in this prefix: 32-bit DLLs go to
# syswow64 in a 64-bit prefix but to system32 in a 32-bit one.
wt_prefix_dll_dirs "$WINEPREFIX"
DIR32="$WT_DLLDIR_32"
DIR64="$WT_DLLDIR_64"

# ==========================================================================
#  Helpers
# ==========================================================================

# fetch <catalog key> <label> — sets FETCHED (verified, cached download)
fetch() {
    FETCHED=""
    wt_fetch_item "$1" "$2" || return 1
    FETCHED="$WT_FETCHED"
}

# put <dll file> <dest dir> <dest name> — copy into the prefix (keeps Wine's
# original as a backup, never writes through a Proton symlink)
put() {
    local src="$1" dir="$2" name="$3"
    if [[ -z "$dir" ]]; then
        wt_log_info "  (this prefix has no folder for that architecture — $name skipped)"
        return 0
    fi
    if wt_dll_put "$src" "$dir" "$name"; then
        wt_log_ok "  $name → $(basename "$dir")"
        return 0
    fi
    return 1
}

# override <dll> [mode]
override() {
    local mode="${2:-native,builtin}"
    if wt_dll_override "$1" "$mode"; then
        wt_log_ok "  override: $1 = $mode"
        return 0
    fi
    wt_log_err "  override failed: $1"
    return 1
}

# regsvr <dll name> <dir> — register a COM DLL with the matching regsvr32
regsvr() {
    local dll="$1" dir="$2"
    [[ -n "$dir" && -f "$dir/regsvr32.exe" ]] || return 0
    ( cd "$dir" && "$WT_INNER_WINE" "$dir/regsvr32.exe" /s "$dll" >/dev/null 2>&1 ) \
        && wt_log_ok "  registered $dll" \
        || wt_log_info "  $dll registration returned an error (often harmless)"
    return 0
}

# Extract a specific DLL from a DirectX redist using the two-stage cabextract method.
# Args:
#   $1  dll_name   — e.g. d3dx9_43
#   $2  arch       — x86 or x64
#   $3  cab_glob   — optional: override cab search glob (default: *dll_name*arch*)
#   $4  pkg_file   — optional: which redist exe to search (default: the Jun 2010 one)
extract_from_directx() {
    local dll_name="$1"    # e.g. d3dx9_43
    local arch="$2"        # x86 or x64
    local cab_glob="${3:-*${1}*${2}*}"   # optional override
    local pkg_file="${4:-$DX2010}"       # optional: which redist to search

    local cab_dir="$TMP_DIR/cab_${dll_name}_${arch}"
    mkdir -p "$cab_dir"

    # Stage 1: extract all cabs matching the glob from the redist
    cabextract -q -d "$cab_dir" -L -F "$cab_glob" -- "$pkg_file" >/dev/null 2>&1

    # Stage 2: loop ALL found cabs — some DLLs (e.g. xinput1_3) live in a later-dated
    # cab than the first match, so searching only head -1 silently misses them.
    local dll_file="" cab_file try_dir
    while IFS= read -r -d '' cab_file; do
        try_dir="$TMP_DIR/dll_${dll_name}_${arch}_$(basename "$cab_file" .cab)"
        mkdir -p "$try_dir"
        cabextract -q -d "$try_dir" -L -F "${dll_name}.dll" -- "$cab_file" >/dev/null 2>&1
        dll_file="$(find "$try_dir" -iname "${dll_name}.dll" -print -quit)"
        [[ -n "$dll_file" ]] && break
    done < <(find "$cab_dir" -iname '*.cab' -print0 | sort -z)

    if [[ -z "$dll_file" ]] || ! wt_file_is "$dll_file" pe; then
        wt_log_err "  $dll_name ($arch) is not in the DirectX package"
        return 1
    fi

    echo "$dll_file"
}

DX2010=""
# Ensure the DirectX Jun 2010 package is cached (shared across d3dx* installs)
ensure_directx_2010() {
    [[ -n "$DX2010" ]] && return 0
    fetch dx_jun2010 "DirectX Jun 2010 redist (~95 MB)" || return 1
    DX2010="$FETCHED"
}

# dx_install <dll> [x86 cab glob] [x64 cab glob]
#   One DLL from the DirectX redist: the 32-bit build where 32-bit DLLs go,
#   the 64-bit build into system32 of a 64-bit prefix, then the override.
dx_install() {
    local dll="$1" g32="${2:-}" g64="${3:-}" f rc=0
    ensure_directx_2010 || return 1
    f="$(extract_from_directx "$dll" x86 ${g32:+"$g32"})" || return 1
    put "$f" "$DIR32" "$dll.dll" || rc=1
    if [[ -n "$DIR64" ]]; then
        if f="$(extract_from_directx "$dll" x64 ${g64:+"$g64"})"; then
            put "$f" "$DIR64" "$dll.dll" || rc=1
        else
            rc=1
        fi
    fi
    override "$dll" || rc=1
    return "$rc"
}

# dx_range <prefix> <from> <to> — e.g. d3dx9_ 24 43; fails if none installed
dx_range() {
    local stem="$1" from="$2" to="$3" n f done_=0 rc=0
    ensure_directx_2010 || return 1
    for n in $(seq "$from" "$to"); do
        local dll="${stem}${n}"
        f="$(extract_from_directx "$dll" x86 2>/dev/null)" || { wt_log_info "  $dll is not in the package — skipped"; continue; }
        put "$f" "$DIR32" "$dll.dll" || { rc=1; continue; }
        if [[ -n "$DIR64" ]] && f="$(extract_from_directx "$dll" x64 2>/dev/null)"; then
            put "$f" "$DIR64" "$dll.dll" || rc=1
        fi
        override "$dll" || rc=1
        done_=$((done_ + 1))
    done
    if (( done_ == 0 )); then
        wt_log_err "  none of ${stem}${from}…${to} could be installed"
        return 1
    fi
    wt_log_info "  $done_ DLL(s) installed"
    return "$rc"
}

# ==========================================================================
#  Install functions
# ==========================================================================

install_d3dx9_43()       { wt_section "d3dx9_43";                    dx_install d3dx9_43; }
install_d3dx9_all()      { wt_section "d3dx9 (full set _24–_43)";    dx_range d3dx9_ 24 43; }
install_d3dx10_43()      { wt_section "d3dx10_43";                   dx_install d3dx10_43; }
install_d3dx10_all()     { wt_section "d3dx10 (full set _33–_43)";   dx_range d3dx10_ 33 43; }
install_d3dx11_43()      { wt_section "d3dx11_43";                   dx_install d3dx11_43; }
install_d3dx11_42()      { wt_section "d3dx11_42";                   dx_install d3dx11_42; }
install_d3dcompiler_43() { wt_section "d3dcompiler_43";              dx_install d3dcompiler_43; }

# XInput cabs in the DX2010 package are named Apr2007_xinput_x86.cab,
# not *xinput1_3*x86* — so we must pass an explicit cab glob.
install_xinput1_3()      { wt_section "xinput1_3";   dx_install xinput1_3   "*xinput*x86*" "*xinput*x64*"; }
install_xinput9_1_0()    { wt_section "xinput9_1_0"; dx_install xinput9_1_0 "*xinput*x86*" "*xinput*x64*"; }

install_d3dcompiler_47() {
    wt_section "d3dcompiler_47"
    wt_log_info "Source: Mozilla fxc2 (pinned commit, sha256-verified)"
    local rc=0
    fetch d3dcompiler_47_x86 "d3dcompiler_47 (x86)" || return 1
    put "$FETCHED" "$DIR32" "d3dcompiler_47.dll" || rc=1
    if [[ -n "$DIR64" ]]; then
        fetch d3dcompiler_47_x64 "d3dcompiler_47 (x64)" || return 1
        put "$FETCHED" "$DIR64" "d3dcompiler_47.dll" || rc=1
    fi
    override "d3dcompiler_47" || rc=1
    return "$rc"
}

install_d3drm() {
    wt_section "d3drm"
    # d3drm (Direct3D Retained Mode) was a core Windows OS component removed after XP.
    # It was NEVER distributed via the DirectX side-by-side cabs — those only contain
    # components like d3dx9/d3dx10/xinput that were added post-DX9.
    # DxWnd (open-source SourceForge project) hosts the original Microsoft DLL.
    wt_log_info "Source: DxWnd SourceForge Redist (original Microsoft d3drm.dll, sha256-verified)"
    fetch d3drm "d3drm.dll" || return 1
    put "$FETCHED" "$DIR32" "d3drm.dll" || return 1
    override "d3drm"
}

install_ddraw() {
    wt_section "ddraw (cnc-ddraw)"
    wt_log_info "Source: github.com/FunkyFr3sh/cnc-ddraw v7.0.0.0 (sha256-verified)"
    fetch cnc_ddraw "cnc-ddraw.zip" || return 1

    local ext_dir="$TMP_DIR/cnc_ddraw"
    if ! wt_extract "$FETCHED" "$ext_dir"; then
        wt_log_err "  $WT_ARCHIVE_ERROR"
        return 1
    fi
    local dll_file
    dll_file="$(find "$ext_dir" -maxdepth 2 -iname 'ddraw.dll' -print -quit)"
    if [[ -z "$dll_file" ]]; then
        wt_log_err "  ddraw.dll not found in cnc-ddraw archive"
        return 1
    fi
    put "$dll_file" "$DIR32" "ddraw.dll" || return 1
    # cnc-ddraw reads its settings from ddraw.ini next to the DLL; an
    # existing (customised) one is kept.
    local ini
    ini="$(find "$ext_dir" -maxdepth 2 -iname 'ddraw.ini' -print -quit)"
    if [[ -n "$ini" && -n "$DIR32" && ! -e "$DIR32/ddraw.ini" ]]; then
        cp -- "$ini" "$DIR32/ddraw.ini" && wt_log_ok "  ddraw.ini → $(basename "$DIR32")"
    fi
    override "ddraw" "native,builtin"
}

install_dinput() {
    wt_section "dinput (dinputto8)"
    wt_log_info "Source: github.com/elishacloud/dinputto8 v1.0.92.0 (sha256-verified)"
    fetch dinputto8 "dinputto8 dinput.dll" || return 1
    put "$FETCHED" "$DIR32" "dinput.dll" || return 1
    override "dinput" "native,builtin"
}

install_msxml3() {
    wt_section "msxml3"
    wt_log_info "Source: msxml3.msi (CodeWeavers mirror, sha256-verified)"
    fetch msxml3 "msxml3.msi" || return 1

    local ext_dir="$TMP_DIR/msxml3_ext"
    mkdir -p "$ext_dir"
    cabextract -q -d "$ext_dir" -- "$FETCHED" >/dev/null 2>&1

    local dll_file
    dll_file="$(find "$ext_dir" -iname 'msxml3.dll' -print -quit)"
    if [[ -z "$dll_file" ]]; then
        # Try wine msiexec as fallback
        wt_log_info "  Trying msiexec install..."
        local rc=0
        "$WT_INNER_WINE" msiexec /i "$FETCHED" /quiet /norestart >/dev/null 2>&1 || rc=$?
        if (( rc != 0 && rc != 3010 && rc != 1641 )); then
            wt_log_err "  msiexec failed (exit $rc)"
            return 1
        fi
        override "msxml3" "native,builtin"
        return
    fi
    put "$dll_file" "$DIR32" "msxml3.dll" || return 1
    override "msxml3" "native,builtin"
}

install_msxml6() {
    wt_section "msxml6"
    wt_log_info "Source: Microsoft Download Center (KB2957482 SP2, sha256-verified)"
    fetch msxml6 "msxml6-KB2957482-enu-amd64.exe (~1.8MB)" || return 1

    local ext1="$TMP_DIR/msxml6_stage1"
    local ext2_32="$TMP_DIR/msxml6_32"
    local ext2_64="$TMP_DIR/msxml6_64"
    mkdir -p "$ext1" "$ext2_32" "$ext2_64"
    local rc=0 done_=0

    # Stage 1: extract outer exe
    cabextract -q -d "$ext1" -- "$FETCHED" >/dev/null 2>&1

    # Stage 2: extract 32-bit msi
    local msi32 dll32
    msi32="$(find "$ext1" -path '*/32/*' -iname 'msxml6.msi' -print -quit)"
    [[ -z "$msi32" ]] && msi32="$(find "$ext1" -iname 'msxml6.msi' -print -quit)"
    if [[ -n "$msi32" ]]; then
        cabextract -q -d "$ext2_32" -- "$msi32" >/dev/null 2>&1
        dll32="$(find "$ext2_32" -iname 'msxml6.dll*' -print -quit)"
        if [[ -n "$dll32" ]]; then put "$dll32" "$DIR32" "msxml6.dll" && done_=1 || rc=1; fi
    fi

    # Stage 2: extract 64-bit msi (if win64 prefix)
    if [[ -n "$DIR64" ]]; then
        local msi64 dll64
        msi64="$(find "$ext1" -path '*/64/*' -iname 'msxml6.msi' -print -quit)"
        if [[ -n "$msi64" ]]; then
            cabextract -q -d "$ext2_64" -- "$msi64" >/dev/null 2>&1
            dll64="$(find "$ext2_64" -iname 'msxml6.dll*' -print -quit)"
            if [[ -n "$dll64" ]]; then put "$dll64" "$DIR64" "msxml6.dll" && done_=1 || rc=1; fi
        fi
    fi

    if (( ! done_ )); then
        wt_log_err "  msxml6.dll not found in the package"
        return 1
    fi
    override "msxml6" "native,builtin" || rc=1
    return "$rc"
}

install_quartz() {
    wt_section "quartz"
    wt_log_info "Setting quartz DLL override to native,builtin..."
    wt_log_info "Wine then uses a quartz.dll the game ships next to its .exe (and its own otherwise)."
    override "quartz" "native,builtin"
}

install_devenum() {
    wt_section "devenum"
    wt_log_info "Setting devenum DLL override to native,builtin..."
    wt_log_info "Wine then uses a devenum.dll the game ships next to its .exe (and its own otherwise)."
    override "devenum" "native,builtin"
}

install_physx() {
    wt_section "PhysX Legacy (9.13.0604)"
    wt_log_info "Source: NVIDIA CDN (official MSI package)"
    # The file is an MSI — use a distinct cache name so stale .exe downloads are not reused.
    fetch physx_legacy "PhysX-9.13.0604-SystemSoftware-Legacy.msi (~19MB)" || return 1

    wt_log "  Running PhysX MSI installer via msiexec..."
    local rc=0
    "$WT_INNER_WINE" msiexec /i "$FETCHED" /quiet /norestart >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)         wt_log_ok "  PhysX installed." ;;
        3010|1641) wt_log_ok "  PhysX installed (Windows would want a reboot — not needed under Wine)." ;;
        *)         wt_log_err "  msiexec exited with code $rc."; return 1 ;;
    esac
}

# ==========================================================================
#  Main dispatch loop
# ==========================================================================

wt_section "DLL Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX  ($(wt_prefix_arch "$WINEPREFIX"))"
wt_log_info "Cache  : $WT_DL_CACHE"
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
wt_log_info "Downloads cached at: $WT_DL_CACHE"
wt_log_info "(verified on every use — safe to delete to free space)"

wt_pause
(( ${#FAILED[@]} == 0 ))
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"

if [[ "$WT_TERMINAL_RC" == 0 ]]; then
    wt_ok "$MODULE" "Installing ${CHOSEN_KEYS[*]}"
else
    wt_warn "$MODULE" "$(printf 'Some components did not install — the terminal summary\nlists which ones and why.\n\n  Prefix : %s' "$WINEPREFIX")"
fi
