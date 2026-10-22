#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  runtimes_installer.sh — Runtime Library Installer
#  winetoolz v3.0
#  Installs selected runtime libraries into a Wine prefix:
#    • .NET Framework 4.5.2 / 4.6.2 / 4.7.2 / 4.8
#    • .NET 6 / 8 / 9 / 10 Desktop Runtime
#    • XNA Framework 4.0 Refresh
#    • XACT / XAudio
#    • DirectPlay
#    • OpenAL
#    • Visual C++ 2005 / 2008 / 2010 / 2012 / 2013
#    • Visual C++ 2015-2022 (vc14) / 2017-2026 (vc17)
#  Downloads come from ../downloads.tsv (sha256-verified, cached); x64
#  installers only run in 64-bit prefixes.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Runtimes Installer"

wt_require_cmds zenity
_wt_have curl || _wt_have wget || wt_require_cmds curl

# =============================================================================
#  Runtime definitions
# =============================================================================

declare -A RT_LABEL RT_DESC RT_GROUP

# --- .NET Framework (classic) ---
RT_LABEL[dotnet452]=".NET Framework 4.5.2"
RT_DESC[dotnet452]="Offline installer — required by many older Windows apps"
RT_GROUP[dotnet452]=".NET Framework"

RT_LABEL[dotnet462]=".NET Framework 4.6.2"
RT_DESC[dotnet462]="Offline installer — good baseline for most .NET 4.x apps"
RT_GROUP[dotnet462]=".NET Framework"

RT_LABEL[dotnet472]=".NET Framework 4.7.2"
RT_DESC[dotnet472]="Offline installer — newer .NET 4.x apps often target this"
RT_GROUP[dotnet472]=".NET Framework"

RT_LABEL[dotnet48]=".NET Framework 4.8"
RT_DESC[dotnet48]="Latest classic .NET — required by many modern Windows apps"
RT_GROUP[dotnet48]=".NET Framework"

# --- .NET (modern) ---
RT_LABEL[dotnet6]=".NET 6 Desktop Runtime"
RT_DESC[dotnet6]="WinForms/WPF-capable — needed by most .NET 6 GUI apps"
RT_GROUP[dotnet6]=".NET Modern"

RT_LABEL[dotnet8]=".NET 8 Desktop Runtime"
RT_DESC[dotnet8]="WinForms/WPF-capable — LTS release"
RT_GROUP[dotnet8]=".NET Modern"

RT_LABEL[dotnet9]=".NET 9 Desktop Runtime"
RT_DESC[dotnet9]="WinForms/WPF-capable — standard-term release"
RT_GROUP[dotnet9]=".NET Modern"

RT_LABEL[dotnet10]=".NET 10 Desktop Runtime"
RT_DESC[dotnet10]="WinForms/WPF-capable — latest LTS release"
RT_GROUP[dotnet10]=".NET Modern"

# --- Visual C++ legacy ---
RT_LABEL[vcredist2005]="Visual C++ 2005 SP1"
RT_DESC[vcredist2005]="VC++ 2005 x86 + x64 — required by some very old games"
RT_GROUP[vcredist2005]="Visual C++"

RT_LABEL[vcredist2008]="Visual C++ 2008 SP1"
RT_DESC[vcredist2008]="VC++ 2008 x86 + x64 — required by many older games"
RT_GROUP[vcredist2008]="Visual C++"

RT_LABEL[vcredist2010]="Visual C++ 2010 SP1"
RT_DESC[vcredist2010]="VC++ 2010 x86 + x64 — widely required by older titles"
RT_GROUP[vcredist2010]="Visual C++"

RT_LABEL[vcredist2012]="Visual C++ 2012 Update 4"
RT_DESC[vcredist2012]="VC++ 2012 x86 + x64 — required by many mid-era games"
RT_GROUP[vcredist2012]="Visual C++"

RT_LABEL[vcredist2013]="Visual C++ 2013 Update 5"
RT_DESC[vcredist2013]="VC++ 2013 x86 + x64 — still widely required"
RT_GROUP[vcredist2013]="Visual C++"

RT_LABEL[vcredist_vc14]="Visual C++ 2015–2022  (vc14)"
RT_DESC[vcredist_vc14]="Unified redist x86 + x64 — covers VS2015, 2017, 2019, 2022"
RT_GROUP[vcredist_vc14]="Visual C++"

RT_LABEL[vcredist_vc17]="Visual C++ 2017–2026  (vc17)"
RT_DESC[vcredist_vc17]="Latest MSVC rolling redist x86 + x64 — covers VS2017 through 2026"
RT_GROUP[vcredist_vc17]="Visual C++"

# --- Audio / Multimedia ---
RT_LABEL[xna40]="XNA Framework 4.0 Refresh"
RT_DESC[xna40]="Required by many indie/XNA games (needs .NET Framework 4.x installed)"
RT_GROUP[xna40]="Audio / Multimedia"

RT_LABEL[xact]="XACT / XAudio 2.0–2.7 (32-bit)"
RT_DESC[xact]="Microsoft's xactengine / xaudio2 / x3daudio DLLs from DirectX Jun 2010"
RT_GROUP[xact]="Audio / Multimedia"

RT_LABEL[openal]="OpenAL"
RT_DESC[openal]="Open Audio Library — required by many games for 3D audio"
RT_GROUP[openal]="Audio / Multimedia"

# --- Networking / Legacy ---
RT_LABEL[directplay]="DirectPlay"
RT_DESC[directplay]="Microsoft's DirectPlay DLLs (DirectX Feb 2010) — older multiplayer games"
RT_GROUP[directplay]="Networking"

RT_ORDER=(
    dotnet452 dotnet462 dotnet472 dotnet48
    dotnet6 dotnet8 dotnet9 dotnet10
    vcredist2005 vcredist2008 vcredist2010 vcredist2012 vcredist2013
    vcredist_vc14 vcredist_vc17
    xna40 xact openal directplay
)

# =============================================================================
#  1. Select Wine binary + prefix
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0
wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  2. Checklist — grouped display
# =============================================================================

CHECKLIST_ARGS=()
for key in "${RT_ORDER[@]}"; do
    CHECKLIST_ARGS+=(FALSE "$key" "${RT_GROUP[$key]:-Other}" "${RT_LABEL[$key]}" "${RT_DESC[$key]}")
done

SELECTED=$(zenity --list \
    --title="$(wt_title "$MODULE  ›  Select Runtimes")" \
    --text="<tt>Check each runtime you want to install.\nThey will be installed in sequence.</tt>" \
    --checklist \
    --column="Install" --column="Key" --column="Group" --column="Runtime" --column="Description" \
    --hide-column=2 --print-column=2 \
    --width=920 --height=560 \
    "${CHECKLIST_ARGS[@]}") || exit 0

if [[ -z "$SELECTED" ]]; then
    wt_info "$MODULE" "No runtimes selected — nothing to do."
    exit 0
fi

IFS='|' read -ra CHOSEN_KEYS <<< "$SELECTED"
for key in "${CHOSEN_KEYS[@]}"; do
    case "$key" in xact|directplay) wt_require_cmds cabextract ;; openal) wt_require_cmds unzip ;; esac
done

# =============================================================================
#  3. Export for inner script
# =============================================================================

export WT_INNER_WINE WT_WRAPPER WINEPREFIX
export WT_CHOSEN_KEYS="${CHOSEN_KEYS[*]}"

# =============================================================================
#  4. Inner terminal script
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

read -ra KEYS <<< "$WT_CHOSEN_KEYS"

WIN64=false
[[ "$(wt_prefix_arch "$WINEPREFIX")" == win64 ]] && WIN64=true
wt_prefix_dll_dirs "$WINEPREFIX"
DIR32="$WT_DLLDIR_32"

wt_section "Runtimes Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX  ($(wt_prefix_arch "$WINEPREFIX"))"
wt_log_info "Queue  : ${KEYS[*]}"
printf '\n'

# --- Download helper: catalog key → FETCHED (verified, cached) ---
fetch() {
    FETCHED=""
    wt_fetch_item "$1" "$2" || return 1
    FETCHED="$WT_FETCHED"
}

# --- Run installer helper: run_installer <file> [arg ...] ---
#   The arguments travel as an array, quoting intact. Microsoft installers
#   report "done, reboot wanted" (3010, 1641) and "already installed" (1638)
#   — all fine under Wine.
run_installer() {
    local file="$1"; shift
    local rc=0
    wt_log "Running: $(basename "$file")${*:+ $*}"
    "$WT_INNER_WINE" "$file" "$@" || rc=$?
    case "$rc" in
        0)         wt_log_ok "$(basename "$file") complete." ;;
        3010|1641) wt_log_ok "$(basename "$file") complete (reboot not needed under Wine)." ;;
        1638)      wt_log_ok "$(basename "$file"): this or a newer version is already installed." ;;
        *)         wt_log_err "$(basename "$file") exited with code $rc."; return 1 ;;
    esac
}

# --- VC++ pair helper: x86 always, x64 in a 64-bit prefix ---
install_vcpair() {
    local label="$1" key="$2"; shift 2
    local rc=0
    fetch "${key}_x86" "$label x86" || return 1
    run_installer "$FETCHED" "$@" || rc=1
    if $WIN64; then
        fetch "${key}_x64" "$label x64" || return 1
        run_installer "$FETCHED" "$@" || rc=1
    fi
    return "$rc"
}

# --- .NET Framework 4.x the way winetricks does it: Wine Mono out, Windows 7
# reported during setup, fusion builtin while it runs, native mscoree after. ---
remove_wine_mono() {
    local line guid
    while IFS= read -r line; do
        [[ "$line" == *[Mm]ono* ]] || continue
        guid="${line%%|*}"
        [[ "$guid" == \{*\} ]] || continue
        wt_log "Removing Wine Mono ($guid)..."
        "$WT_INNER_WINE" uninstaller --remove "$guid" >/dev/null 2>&1
    done < <("$WT_INNER_WINE" uninstaller --list 2>/dev/null | tr -d '\r')
    return 0
}

install_netfx() {
    local label="$1" key="$2"; shift 2
    fetch "$key" "$label" || return 1
    remove_wine_mono
    local prev rc=0
    "${WT_WINESERVER:-wineserver}" -w 2>/dev/null
    prev="$(wt_reg_value "$WINEPREFIX/user.reg" 'Software\Wine' Version)"
    "$WT_INNER_WINE" winecfg -v win7 >/dev/null 2>&1
    WINEDLLOVERRIDES="fusion=b" run_installer "$FETCHED" "$@" || rc=1
    "$WT_INNER_WINE" winecfg -v "${prev:-win10}" >/dev/null 2>&1
    if (( rc == 0 )); then
        wt_dll_override mscoree native && wt_log_ok "mscoree = native (use Microsoft's .NET, not Wine Mono)"
    else
        wt_log_info "If this keeps failing, install .NET 4.0 first (e.g. winetricks dotnet40) and retry."
    fi
    return "$rc"
}

# --- .NET Desktop Runtime: x86 + x64 in a 64-bit prefix, x86 in a 32-bit one ---
install_dotnet_desktop() {
    local label="$1" key="$2" rc=0
    fetch "${key}_x86" "$label x86" || return 1
    run_installer "$FETCHED" /install /quiet /norestart || rc=1
    if $WIN64; then
        fetch "${key}_x64" "$label x64" || return 1
        run_installer "$FETCHED" /install /quiet /norestart || rc=1
    fi
    return "$rc"
}

# --- DLLs out of a DirectX redist's cabinets: cab_dlls <pkg> <cab glob> <dll glob> <dest> ---
cab_dlls() {
    local pkg="$1" cabs="$2" dlls="$3" dest="$4" stage cab n=0
    stage="$(mktemp -d "$TMP_DIR/cab.XXXXXX")"
    cabextract -q -L -d "$stage" -F "$cabs" -- "$pkg" >/dev/null 2>&1
    for cab in "$stage"/*.cab; do
        [[ -f "$cab" ]] || continue
        cabextract -q -L -d "$stage/out" -F "$dlls" -- "$cab" >/dev/null 2>&1
    done
    for f in "$stage"/out/*; do
        [[ -f "$f" ]] || continue
        if wt_dll_put "$f" "$dest" "$(basename "$f")"; then n=$((n + 1)); fi
    done
    echo "$n"
}

# ==========================================================================
#  Install functions
# ==========================================================================

install_dotnet452() { wt_section ".NET Framework 4.5.2"; install_netfx ".NET 4.5.2" dotnet452 /q /norestart; }
install_dotnet462() { wt_section ".NET Framework 4.6.2"; install_netfx ".NET 4.6.2" dotnet462 /q /norestart; }
install_dotnet472() { wt_section ".NET Framework 4.7.2"; install_netfx ".NET 4.7.2" dotnet472 /q /norestart; }
install_dotnet48()  { wt_section ".NET Framework 4.8";   install_netfx ".NET 4.8"   dotnet48  /q /norestart; }

install_dotnet6()   { wt_section ".NET 6 Desktop Runtime";  install_dotnet_desktop ".NET 6 Desktop Runtime"  dotnet6; }
install_dotnet8()   { wt_section ".NET 8 Desktop Runtime";  install_dotnet_desktop ".NET 8 Desktop Runtime"  dotnet8; }
install_dotnet9()   { wt_section ".NET 9 Desktop Runtime";  install_dotnet_desktop ".NET 9 Desktop Runtime"  dotnet9; }
install_dotnet10()  { wt_section ".NET 10 Desktop Runtime"; install_dotnet_desktop ".NET 10 Desktop Runtime" dotnet10; }

# VC++ 2005's IExpress wrapper takes just /q (as winetricks runs it).
install_vcredist2005()  { wt_section "Visual C++ 2005 SP1";        install_vcpair "VC++ 2005" vc2005 /q; }
install_vcredist2008()  { wt_section "Visual C++ 2008 SP1";        install_vcpair "VC++ 2008" vc2008 /q; }
install_vcredist2010()  { wt_section "Visual C++ 2010 SP1";        install_vcpair "VC++ 2010" vc2010 /q /norestart; }
install_vcredist2012()  { wt_section "Visual C++ 2012 Update 4";   install_vcpair "VC++ 2012" vc2012 /install /quiet /norestart; }
install_vcredist2013()  { wt_section "Visual C++ 2013 Update 5";   install_vcpair "VC++ 2013" vc2013 /install /quiet /norestart; }
install_vcredist_vc14() { wt_section "Visual C++ 2015-2022  (vc14)"; install_vcpair "VC++ 2015-2022" vc14 /install /quiet /norestart; }
install_vcredist_vc17() { wt_section "Visual C++ 2017-2026  (vc17)"; install_vcpair "VC++ 2017-2026" vc17 /install /quiet /norestart; }

install_xna40() {
    wt_section "XNA Framework 4.0 Refresh"
    fetch xna40 "XNA 4.0" || return 1
    run_installer msiexec /i "$FETCHED" /quiet /norestart
}

install_xact() {
    wt_section "XACT / XAudio"
    # As winetricks does: the 32-bit xactengine / xaudio2_0–2_7 / x3daudio /
    # xapofx DLLs from the DirectX June 2010 cabinets, registered, with
    # native overrides. Newer xaudio2_8+ stay Wine's own (FAudio-based).
    fetch dx_jun2010 "DirectX Jun 2010 redist (~95 MB)" || return 1
    local pkg="$FETCHED" n=0 dll rc=0
    n=$(( n + $(cab_dlls "$pkg" '*_xact_*x86*'     'xactengine*.dll' "$DIR32") ))
    n=$(( n + $(cab_dlls "$pkg" '*_xaudio_*x86*'   'xaudio2_[0-7].dll' "$DIR32") ))
    n=$(( n + $(cab_dlls "$pkg" '*_xaudio_*x86*'   'xapofx*.dll'     "$DIR32") ))
    n=$(( n + $(cab_dlls "$pkg" '*_x3daudio_*x86*' 'x3daudio*.dll'   "$DIR32") ))
    if (( n == 0 )); then
        wt_log_err "No XACT / XAudio DLLs found in the DirectX package."
        return 1
    fi
    wt_log_ok "$n DLL(s) installed into $(basename "$DIR32")"

    local ok=0 fail=0
    for f in "$DIR32"/xactengine*.dll "$DIR32"/xaudio2_[0-7].dll "$DIR32"/x3daudio*.dll "$DIR32"/xapofx*.dll; do
        [[ -f "$f" ]] || continue
        wt_dll_is_wine_builtin "$f" && continue
        dll="$(basename "$f" .dll)"
        if wt_dll_override "$dll" native,builtin; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
        case "$dll" in
            xactengine*|xaudio2_*)
                ( cd "$DIR32" && "$WT_INNER_WINE" "$DIR32/regsvr32.exe" /s "$dll.dll" >/dev/null 2>&1 ) ;;
        esac
    done
    if (( fail )); then
        wt_log_err "XACT/XAudio overrides: $ok set, $fail failed"
        rc=1
    else
        wt_log_ok "XACT/XAudio overrides set ($ok)"
    fi
    return "$rc"
}

install_openal() {
    wt_section "OpenAL"
    fetch openal "OpenAL" || return 1
    if ! wt_extract "$FETCHED" "$TMP_DIR/openal_extracted"; then
        wt_log_err "$WT_ARCHIVE_ERROR"
        return 1
    fi
    local installer
    installer="$(find "$TMP_DIR/openal_extracted" -iname 'oalinst.exe' -print -quit)"
    if [[ -z "$installer" ]]; then
        wt_log_err "oalinst.exe not found in OpenAL archive."
        return 1
    fi
    run_installer "$installer" /silent
}

install_directplay() {
    wt_section "DirectPlay"
    # As winetricks does: Microsoft's DirectPlay files from dxnt.cab in the
    # DirectX February 2010 redistributable (the June 2010 one no longer
    # carries them), registered, with native overrides.
    fetch dx_feb2010 "DirectX Feb 2010 redist (~100 MB)" || return 1
    local stage="$TMP_DIR/dplay" f n=0 rc=0
    mkdir -p "$stage"
    cabextract -q -L -d "$stage" -F dxnt.cab -- "$FETCHED" >/dev/null 2>&1
    if [[ ! -f "$stage/dxnt.cab" ]]; then
        wt_log_err "dxnt.cab not found in the DirectX package."
        return 1
    fi
    for f in dplaysvr.exe dplayx.dll dpmodemx.dll dpnet.dll dpnhpast.dll dpnhupnp.dll dpnsvr.exe dpwsockx.dll; do
        cabextract -q -L -d "$stage/out" -F "$f" -- "$stage/dxnt.cab" >/dev/null 2>&1
        if [[ -f "$stage/out/$f" ]] && wt_dll_put "$stage/out/$f" "$DIR32" "$f"; then
            n=$((n + 1))
        fi
    done
    if (( n == 0 )); then
        wt_log_err "No DirectPlay files found in dxnt.cab."
        return 1
    fi
    wt_log_ok "$n DirectPlay file(s) installed into $(basename "$DIR32")"
    for f in dplaysvr.exe dplayx dpmodemx dpnet dpnhpast dpnhupnp dpnsvr.exe dpwsockx; do
        wt_dll_override "$f" native || rc=1
    done
    for f in dplayx dpnet dpnhpast dpnhupnp; do
        ( cd "$DIR32" && "$WT_INNER_WINE" "$DIR32/regsvr32.exe" /s "$f.dll" >/dev/null 2>&1 )
    done
    (( rc == 0 )) && wt_log_ok "DirectPlay overrides set." || wt_log_err "Some DirectPlay overrides failed."
    return "$rc"
}

# ==========================================================================
#  Main
# ==========================================================================

FAILED=()
SUCCEEDED=()

for key in "${KEYS[@]}"; do
    if declare -f "install_${key}" > /dev/null; then
        if "install_${key}"; then
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

wt_section "Runtimes Installer — Summary"
wt_log_info "Succeeded : ${SUCCEEDED[*]:-(none)}"
wt_log_info "Failed    : ${FAILED[*]:-(none)}"
wt_log_info "Prefix    : $WINEPREFIX"

wt_pause
(( ${#FAILED[@]} == 0 ))
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"

if [[ "$WT_TERMINAL_RC" == 0 ]]; then
    wt_ok "$MODULE" "Installing ${CHOSEN_KEYS[*]}"
else
    wt_warn "$MODULE" "$(printf 'Some runtimes did not install — the terminal summary\nlists which ones.\n\n  Prefix : %s' "$WINEPREFIX")"
fi
