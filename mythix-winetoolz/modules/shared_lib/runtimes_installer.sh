#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  runtimes_installer.sh — Runtime Library Installer
#  winetoolz v2.1
#  Installs selected runtime libraries into a Wine prefix:
#    • .NET Framework 4.5.2 / 4.6.2 / 4.7.2 / 4.8
#    • .NET 6 / 8 / 9 Desktop Runtime
#    • XNA Framework 4.0 Refresh
#    • XACT / XAudio (DLL overrides)
#    • DirectPlay
#    • OpenAL
#    • Visual C++ 2005 / 2008 / 2010 / 2012 / 2013
#    • Visual C++ 2015-2022 (vc14) / 2017-2026 (vc17)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Runtimes Installer"

wt_require_cmds zenity wget

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
RT_LABEL[dotnet6]=".NET 6 Desktop Runtime (x64)"
RT_DESC[dotnet6]="WinForms/WPF-capable — needed by most .NET 6 GUI apps"
RT_GROUP[dotnet6]=".NET Modern"

RT_LABEL[dotnet8]=".NET 8 Desktop Runtime (x64)"
RT_DESC[dotnet8]="WinForms/WPF-capable — latest LTS release"
RT_GROUP[dotnet8]=".NET Modern"

RT_LABEL[dotnet9]=".NET 9 Desktop Runtime (x64)"
RT_DESC[dotnet9]="WinForms/WPF-capable — latest current release"
RT_GROUP[dotnet9]=".NET Modern"

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
RT_DESC[xna40]="Required by many indie/XNA games"
RT_GROUP[xna40]="Audio / Multimedia"

RT_LABEL[xact]="XACT / XAudio (DLL overrides)"
RT_DESC[xact]="Sets xactengine + xaudio DLL overrides — for games using XACT audio"
RT_GROUP[xact]="Audio / Multimedia"

RT_LABEL[openal]="OpenAL"
RT_DESC[openal]="Open Audio Library — required by many games for 3D audio"
RT_GROUP[openal]="Audio / Multimedia"

# --- Networking / Legacy ---
RT_LABEL[directplay]="DirectPlay"
RT_DESC[directplay]="Legacy DirectX networking — required by older multiplayer games"
RT_GROUP[directplay]="Networking"

RT_ORDER=(
    dotnet452 dotnet462 dotnet472 dotnet48
    dotnet6 dotnet8 dotnet9
    vcredist2005 vcredist2008 vcredist2010 vcredist2012 vcredist2013
    vcredist_vc14 vcredist_vc17
    xna40 xact openal directplay
)

# =============================================================================
#  Download URLs
# =============================================================================

# .NET Framework
URL_DOTNET452="https://download.microsoft.com/download/E/2/1/E21644B5-2DF2-47C2-91BD-63C560427900/NDP452-KB2901907-x86-x64-AllOS-ENU.exe"
URL_DOTNET462="https://download.microsoft.com/download/F/9/4/F942F07D-F26F-4F30-B4E3-EBD54FABA377/NDP462-KB3151800-x86-x64-AllOS-ENU.exe"
URL_DOTNET472="https://download.microsoft.com/download/0/5/C/05C1EC0E-D5EE-463B-BFE3-9311BD9C2CCE/NDP472-KB4054530-x86-x64-AllOS-ENU.exe"
URL_DOTNET48="https://go.microsoft.com/fwlink/?LinkId=2085155"

# .NET Modern Desktop Runtimes
URL_DOTNET6="https://aka.ms/dotnet/6.0/windowsdesktop-runtime-win-x64.exe"
URL_DOTNET8="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
URL_DOTNET9="https://aka.ms/dotnet/9.0/windowsdesktop-runtime-win-x64.exe"

# Visual C++ legacy
URL_VC2005_X86="https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.exe"
URL_VC2005_X64="https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.exe"
URL_VC2008_X86="https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe"
URL_VC2008_X64="https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe"
URL_VC2010_X86="https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe"
URL_VC2010_X64="https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe"
URL_VC2012_X86="https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe"
URL_VC2012_X64="https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe"
URL_VC2013_X86="https://aka.ms/highdpimfc2013x86enu"
URL_VC2013_X64="https://aka.ms/highdpimfc2013x64enu"

# Visual C++ modern (vc14 / vc17)
URL_VC14_X86="https://aka.ms/vc14/vc_redist.x86.exe"
URL_VC14_X64="https://aka.ms/vc14/vc_redist.x64.exe"
URL_VC17_X86="https://aka.ms/vs/17/release/vc_redist.x86.exe"
URL_VC17_X64="https://aka.ms/vs/17/release/vc_redist.x64.exe"

# Audio / Multimedia
URL_XNA40="https://download.microsoft.com/download/A/C/2/AC2C903B-E6E8-42C2-9FD7-BEBAC362A930/xnafx40_redist.msi"
URL_OPENAL="https://www.openal.org/downloads/oalinst.zip"

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

[[ -z "$SELECTED" ]] && wt_info "$MODULE" "No runtimes selected — nothing to do." && exit 0

IFS='|' read -ra CHOSEN_KEYS <<< "$SELECTED"

# =============================================================================
#  3. Export for inner script
# =============================================================================

export WT_INNER_WINE WT_WRAPPER WINEPREFIX
export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"
export WT_CHOSEN_KEYS="${CHOSEN_KEYS[*]}"

export URL_DOTNET452 URL_DOTNET462 URL_DOTNET472 URL_DOTNET48
export URL_DOTNET6 URL_DOTNET8 URL_DOTNET9
export URL_VC2005_X86 URL_VC2005_X64
export URL_VC2008_X86 URL_VC2008_X64
export URL_VC2010_X86 URL_VC2010_X64
export URL_VC2012_X86 URL_VC2012_X64
export URL_VC2013_X86 URL_VC2013_X64
export URL_VC14_X86 URL_VC14_X64
export URL_VC17_X86 URL_VC17_X64
export URL_XNA40 URL_OPENAL

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
cd "$TMP_DIR"

read -ra KEYS <<< "$WT_CHOSEN_KEYS"

wt_section "Runtimes Installer"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
wt_log_info "Queue  : ${KEYS[*]}"
printf '\n'

# --- Download helper ---
wt_download() {
    local url="$1" out="$2" label="$3"
    wt_log "Downloading $label..."
    wget -q --show-progress -O "$out" "$url" \
        && wt_log_ok "$label downloaded." \
        || { wt_log_err "Download failed: $url"; return 1; }
}

# --- Run installer helper ---
wt_run_installer() {
    local file="$1" args="${2:-}"
    wt_log "Running: $(basename "$file")${args:+ $args}"
    "$WT_INNER_WINE" "$file" $args \
        && wt_log_ok "$(basename "$file") complete." \
        || wt_log_err "$(basename "$file") exited with an error (may still have installed)."
}

# --- VC++ pair helper (downloads x86 + x64, runs both) ---
install_vcpair() {
    local label="$1" url_x86="$2" url_x64="$3" args="${4:-/install /quiet /norestart}"
    wt_download "$url_x86" "vcredist_x86.exe" "$label x86" || return 1
    wt_download "$url_x64" "vcredist_x64.exe" "$label x64" || return 1
    wt_run_installer "vcredist_x86.exe" "$args"
    wt_run_installer "vcredist_x64.exe" "$args"
}

# ==========================================================================
#  Install functions
# ==========================================================================

install_dotnet452() {
    wt_section ".NET Framework 4.5.2"
    wt_download "$URL_DOTNET452" "dotnet452.exe" ".NET 4.5.2" || return 1
    wt_run_installer "dotnet452.exe" "/q /norestart"
}

install_dotnet462() {
    wt_section ".NET Framework 4.6.2"
    wt_download "$URL_DOTNET462" "dotnet462.exe" ".NET 4.6.2" || return 1
    wt_run_installer "dotnet462.exe" "/q /norestart"
}

install_dotnet472() {
    wt_section ".NET Framework 4.7.2"
    wt_download "$URL_DOTNET472" "dotnet472.exe" ".NET 4.7.2" || return 1
    wt_run_installer "dotnet472.exe" "/q /norestart"
}

install_dotnet48() {
    wt_section ".NET Framework 4.8"
    wt_download "$URL_DOTNET48" "dotnet48.exe" ".NET 4.8" || return 1
    wt_run_installer "dotnet48.exe" "/q /norestart"
}

install_dotnet6() {
    wt_section ".NET 6 Desktop Runtime"
    wt_download "$URL_DOTNET6" "dotnet6.exe" ".NET 6 Desktop Runtime" || return 1
    wt_run_installer "dotnet6.exe" "/install /quiet /norestart"
}

install_dotnet8() {
    wt_section ".NET 8 Desktop Runtime"
    wt_download "$URL_DOTNET8" "dotnet8.exe" ".NET 8 Desktop Runtime" || return 1
    wt_run_installer "dotnet8.exe" "/install /quiet /norestart"
}

install_dotnet9() {
    wt_section ".NET 9 Desktop Runtime"
    wt_download "$URL_DOTNET9" "dotnet9.exe" ".NET 9 Desktop Runtime" || return 1
    wt_run_installer "dotnet9.exe" "/install /quiet /norestart"
}

install_vcredist2005() {
    wt_section "Visual C++ 2005 SP1"
    install_vcpair "VC++ 2005" "$URL_VC2005_X86" "$URL_VC2005_X64" "/q:a /c:\"msiexec /i vcredist.msi /qn\""
}

install_vcredist2008() {
    wt_section "Visual C++ 2008 SP1"
    install_vcpair "VC++ 2008" "$URL_VC2008_X86" "$URL_VC2008_X64" "/q"
}

install_vcredist2010() {
    wt_section "Visual C++ 2010 SP1"
    install_vcpair "VC++ 2010" "$URL_VC2010_X86" "$URL_VC2010_X64" "/q /norestart"
}

install_vcredist2012() {
    wt_section "Visual C++ 2012 Update 4"
    install_vcpair "VC++ 2012" "$URL_VC2012_X86" "$URL_VC2012_X64" "/install /quiet /norestart"
}

install_vcredist2013() {
    wt_section "Visual C++ 2013 Update 5"
    install_vcpair "VC++ 2013" "$URL_VC2013_X86" "$URL_VC2013_X64" "/install /quiet /norestart"
}

install_vcredist_vc14() {
    wt_section "Visual C++ 2015-2022  (vc14)"
    install_vcpair "VC++ 2015-2022" "$URL_VC14_X86" "$URL_VC14_X64" "/install /quiet /norestart"
}

install_vcredist_vc17() {
    wt_section "Visual C++ 2017-2026  (vc17)"
    install_vcpair "VC++ 2017-2026" "$URL_VC17_X86" "$URL_VC17_X64" "/install /quiet /norestart"
}

install_xna40() {
    wt_section "XNA Framework 4.0 Refresh"
    wt_download "$URL_XNA40" "xna40.msi" "XNA 4.0" || return 1
    "$WT_INNER_WINE" msiexec /i xna40.msi /quiet /norestart \
        && wt_log_ok "XNA 4.0 complete." \
        || wt_log_err "XNA 4.0 msiexec exited with an error."
}

install_xact() {
    wt_section "XACT / XAudio (DLL overrides)"
    wt_log_info "Setting XACT engine + XAudio DLL overrides..."
    local dlls=(
        xactengine2_0 xactengine2_1 xactengine2_2 xactengine2_3
        xactengine2_4 xactengine2_5 xactengine2_6 xactengine2_7
        xactengine2_8 xactengine2_9 xactengine2_10
        xactengine3_0 xactengine3_1 xactengine3_2 xactengine3_3
        xactengine3_4 xactengine3_5 xactengine3_6 xactengine3_7
        xaudio2_0 xaudio2_1 xaudio2_2 xaudio2_3
        xaudio2_4 xaudio2_5 xaudio2_6 xaudio2_7
    )
    local ok=0 fail=0
    for dll in "${dlls[@]}"; do
        "$WT_INNER_WINE" reg add \
            'HKEY_CURRENT_USER\Software\Wine\DllOverrides' \
            /v "$dll" /d "native,builtin" /f >/dev/null 2>&1 \
            && (( ok++ )) || (( fail++ ))
    done
    wt_log_ok "XACT/XAudio overrides set  (ok: $ok  failed: $fail)"
}

install_openal() {
    wt_section "OpenAL"
    wt_download "$URL_OPENAL" "openal.zip" "OpenAL" || return 1
    unzip -o -qq openal.zip -d openal_extracted/
    local installer
    installer="$(find openal_extracted -iname 'oalinst.exe' | head -1)"
    if [[ -z "$installer" ]]; then
        wt_log_err "oalinst.exe not found in OpenAL archive."
        return 1
    fi
    wt_run_installer "$installer" "/s"
}

install_directplay() {
    wt_section "DirectPlay"
    wt_log_info "Enabling DirectPlay via Wine DLL overrides..."
    for dll in dplayx dpnet dpnhpast dpnlobby; do
        "$WT_INNER_WINE" reg add \
            'HKEY_CURRENT_USER\Software\Wine\DllOverrides' \
            /v "$dll" /d "native,builtin" /f >/dev/null 2>&1 \
            && wt_log_ok "$dll override set." \
            || wt_log_err "Failed to set $dll override."
    done
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
    else
        wt_log_err "No install function for: $key"
        FAILED+=("$key")
    fi
done

wt_section "Runtimes Installer — Summary"
wt_log_info "Succeeded : ${SUCCEEDED[*]:-(none)}"
wt_log_info "Failed    : ${FAILED[*]:-(none)}"
wt_log_info "Prefix    : $WINEPREFIX"

read -rp "  Press Enter to close..." < /dev/tty
INNEREOF

chmod +x "$TMP"
wt_run_in_terminal "$TMP"
