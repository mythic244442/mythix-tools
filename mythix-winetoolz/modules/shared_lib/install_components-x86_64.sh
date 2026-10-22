#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  install_components-x86_64.sh — Generic DLL / System Component Installer
#  winetoolz v3.0
#  Extracts an archive, classifies DLLs by arch, lets you pick which to
#  install, copies them into the prefix and sets DLL overrides.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="System Component Installer"

wt_require_cmds zenity

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix_from_config "$MODULE" || exit 0

# =============================================================================
#  3. Detect prefix bitness
# =============================================================================

wt_prefix_dll_dirs "$WINEPREFIX"
DIR64="$WT_DLLDIR_64"
DIR32="$WT_DLLDIR_32"

# =============================================================================
#  4. Select component source
# =============================================================================

SOURCE_TYPE=$(zenity --list \
    --title="$(wt_title "$MODULE  ›  Select Source")" \
    --text="<tt>Where are the DLL / component files coming from?</tt>" \
    --radiolist \
    --column="" --column="Option" --column="Details" \
    TRUE  "Download from URL"   "Paste a direct https link to the archive" \
    FALSE "Select Local Archive" "Browse for a local .zip / .exe / .cab / .7z file" \
    --width="$WT_WIDTH" --height=220) || exit 0

ARCHIVE_URL=""
LOCAL_ARCHIVE=""

if [[ "$SOURCE_TYPE" == "Download from URL" ]]; then
    ARCHIVE_URL=$(zenity --entry \
        --title="$(wt_title "$MODULE  ›  Enter URL")" \
        --text="<tt>Paste the direct download link to the archive:</tt>" \
        --width="$WT_WIDTH") || exit 0
    ARCHIVE_URL="${ARCHIVE_URL#"${ARCHIVE_URL%%[![:space:]]*}"}"
    ARCHIVE_URL="${ARCHIVE_URL%"${ARCHIVE_URL##*[![:space:]]}"}"
    [[ -z "$ARCHIVE_URL" ]] && wt_error "No URL was provided."
else
    LOCAL_ARCHIVE=$(zenity --file-selection \
        --title="$(wt_title "$MODULE  ›  Select the archive with your DLLs")" \
        --file-filter="Supported archives | *.zip *.ZIP *.exe *.EXE *.cab *.CAB *.7z *.rar" \
        --width="$WT_WIDTH") || exit 0
fi

# =============================================================================
#  5. Extract archive
# =============================================================================

TMP_DIR="$(mktemp -d)"
trap 'wt_pulse_stop; rm -rf "$TMP_DIR"' EXIT

if [[ -n "$ARCHIVE_URL" ]]; then
    # Name the download after the URL's file name (query string dropped);
    # no extension → assume a self-extracting .exe.
    ARCHIVE_NAME_CLEAN="${ARCHIVE_URL%%[?#]*}"
    ARCHIVE_NAME_CLEAN="$(_wt_safe_name "${ARCHIVE_NAME_CLEAN##*/}")"
    [[ "$ARCHIVE_NAME_CLEAN" == *.* ]] || ARCHIVE_NAME_CLEAN+=".exe"
    ARCHIVE_FILE="$TMP_DIR/$ARCHIVE_NAME_CLEAN"
    if ! wt_fetch "$ARCHIVE_URL" "$ARCHIVE_FILE" "" "$ARCHIVE_NAME_CLEAN"; then
        wt_error "$(printf 'Download failed.\n\n%s' "$WT_FETCH_ERROR")"
    fi
else
    ARCHIVE_FILE="$LOCAL_ARCHIVE"
fi

case "$(_wt_archive_kind "$ARCHIVE_FILE")" in
    exe|cab) _wt_have cabextract || _wt_have 7z || wt_require_cmds cabextract ;;
    zip)     wt_require_cmds unzip ;;
    7z)      wt_require_cmds 7z ;;       # .7z and .rar
    *)       wt_error "$(printf 'Unsupported archive format:\n  %s\n\nSupported formats:  .exe  .cab  .zip  .7z  .rar' "$(basename "$ARCHIVE_FILE")")" ;;
esac

EXTRACT_DIR="$TMP_DIR/extracted"
wt_pulse_start "$MODULE" "Extracting $(basename "$ARCHIVE_FILE")..."
EXTRACT_OK=true
wt_extract "$ARCHIVE_FILE" "$EXTRACT_DIR" || EXTRACT_OK=false
# Installers often keep their DLLs one cabinet deeper (DirectX-style).
$EXTRACT_OK && wt_extract_nested_cabs "$EXTRACT_DIR"
wt_pulse_stop
$EXTRACT_OK || wt_error "$(printf 'Could not extract the archive:\n\n%s' "$WT_ARCHIVE_ERROR")"

# =============================================================================
#  6. Classify DLLs by architecture (from the PE header — no `file` needed)
# =============================================================================

declare -a DLLS_64=()
declare -a DLLS_32=()

while IFS= read -r -d '' fpath; do
    case "$(wt_pe_arch "$fpath" 2>/dev/null || true)" in
        x64) DLLS_64+=("$fpath") ;;
        x86) DLLS_32+=("$fpath") ;;
    esac
done < <(find "$EXTRACT_DIR" -type f \
    \( -iname "*.dll" -o -iname "*.ocx" -o -iname "*.cpl" -o -iname "*.ax" \) -print0 | sort -z)

COUNT_64=${#DLLS_64[@]}
COUNT_32=${#DLLS_32[@]}

if (( COUNT_64 + COUNT_32 == 0 )); then
    wt_info "$MODULE" "$(printf 'No Windows DLL / OCX / CPL / AX files were found in:\n  %s' "$(basename "$ARCHIVE_FILE")")"
    exit 0
fi

NOTE=""
[[ -z "$DIR64" && "$COUNT_64" -gt 0 ]] && NOTE=$'\n\n⚠  This is a 32-bit prefix — the 64-bit files cannot be used in it.'

wt_info "$MODULE  ›  Components Found" "$(printf 'Archive scanned.\n\n  64-bit DLL / OCX / CPL / AX :  %d\n  32-bit DLL / OCX / CPL / AX :  %d%s\n\nClick OK to select which files to install.' "$COUNT_64" "$COUNT_32" "$NOTE")"

# =============================================================================
#  7. Selection: ALL / SOME / NONE per architecture
# =============================================================================

declare -a FINAL_64=()
declare -a FINAL_32=()

select_mode() {
    local arch="$1"
    zenity --list \
        --title="$(wt_title "$MODULE  ›  Select $arch DLLs")" \
        --text="<tt>Choose how to select $arch DLLs to install.</tt>" \
        --radiolist \
        --column="" --column="Option" --column="Details" \
        TRUE  "Install ALL $arch"  "Copy every $arch file found in the archive" \
        FALSE "Pick $arch files"   "Check off individual files from a list" \
        FALSE "Skip $arch"         "Do not install any $arch files" \
        --width="$WT_WIDTH" --height=240
}

# pick_files <arch label> <result array name> <files...>
pick_files() {
    local arch="$1" result="$2"; shift 2
    local -a rows=()
    local f sel
    for f in "$@"; do
        rows+=(FALSE "$f" "${f#"$EXTRACT_DIR"/}")
    done
    sel=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  $arch DLL Selection")" \
        --text="<tt>Check each $arch file you want to install.</tt>" \
        --checklist \
        --column="Install" --column="Full Path" --column="File in the archive" \
        --hide-column=2 --print-column=2 --separator=$'\x1f' \
        --width=820 --height=560 \
        "${rows[@]}") || sel=""
    if [[ -n "$sel" ]]; then
        IFS=$'\x1f' read -r -a "${result?}" <<< "$sel"
    fi
}

# --- 64-bit ---
if (( COUNT_64 > 0 )) && [[ -n "$DIR64" ]]; then
    MODE_64="$(select_mode "64-bit")" || MODE_64="Skip 64-bit"
    case "$MODE_64" in
        "Install ALL 64-bit") FINAL_64=("${DLLS_64[@]}") ;;
        "Pick 64-bit files")  pick_files "64-bit" FINAL_64 "${DLLS_64[@]}" ;;
        *) FINAL_64=() ;;
    esac
fi

# --- 32-bit ---
if (( COUNT_32 > 0 )); then
    MODE_32="$(select_mode "32-bit")" || MODE_32="Skip 32-bit"
    case "$MODE_32" in
        "Install ALL 32-bit") FINAL_32=("${DLLS_32[@]}") ;;
        "Pick 32-bit files")  pick_files "32-bit" FINAL_32 "${DLLS_32[@]}" ;;
        *) FINAL_32=() ;;
    esac
fi

TOTAL_FILES=$(( ${#FINAL_64[@]} + ${#FINAL_32[@]} ))

if (( TOTAL_FILES == 0 )); then
    wt_info "$MODULE" "$(printf 'No files were selected.\n\nNothing was installed.')"
    exit 0
fi

# =============================================================================
#  8. Install DLLs
# =============================================================================

REPORT=""
FAILURES=0
INSTALLED=0

# Wine's core DLLs only ever work as Wine's own builtins: a Windows copy of
# one of these makes every program in the prefix fail to start.
CORE_DLLS=" ntdll.dll kernel32.dll kernelbase.dll user32.dll gdi32.dll win32u.dll wow64.dll wow64cpu.dll wow64win.dll "

# install_dll_batch <files array name> <target dir> <arch label>
#   Copies the files in under lower-case names like the prefix's own (Wine's
#   originals kept as .wt_bak, never through a symlink), registers the COM
#   servers among them, and sets native,builtin overrides — through Wine's
#   registry, so a running wineserver can't overwrite them. An override is
#   named after the file without ".dll" (other extensions stay: foo.ocx).
install_dll_batch() {
    local -n _files=$1
    local target_dir="$2"
    local arch_label="$3"
    local fpath base name
    local -A seen=()

    (( ${#_files[@]} )) || return 0
    REPORT+="$(printf '%s  →  %s\n' "$arch_label" "$(basename "$target_dir")")"$'\n'

    for fpath in "${_files[@]}"; do
        base="$(basename "$fpath")"
        base="${base,,}"
        if [[ "$CORE_DLLS" == *" $base "* ]]; then
            REPORT+="  –  $base  (skipped: Wine's own core DLL)"$'\n'
            continue
        fi
        if [[ -n "${seen[$base]:-}" ]]; then
            REPORT+="  –  ${fpath#"$EXTRACT_DIR"/}  (skipped: another $base was installed)"$'\n'
            continue
        fi
        seen[$base]=1
        if wt_dll_put "$fpath" "$target_dir" "$base" 2>/dev/null; then
            name="${base%.dll}"
            if [[ "$base" == *.dll || "$base" == *.ocx ]] \
               && grep -aq DllRegisterServer "$target_dir/$base" 2>/dev/null; then
                ( cd "$target_dir" && "$WT_INNER_WINE" "$target_dir/regsvr32.exe" /s "$base" >/dev/null 2>&1 ) || true
            fi
            INSTALLED=$((INSTALLED + 1))
            if wt_dll_override "$name" native,builtin; then
                REPORT+="  ✔  $base"$'\n'
            else
                REPORT+="  ✔  $base  (override could not be set)"$'\n'
                FAILURES=$((FAILURES + 1))
            fi
        else
            REPORT+="  ✘  $base  (copy failed)"$'\n'
            FAILURES=$((FAILURES + 1))
        fi
    done
}

export WINEPREFIX WT_INNER_WINE
wt_pulse_start "$MODULE" "Installing components into prefix..."
install_dll_batch FINAL_64 "$DIR64" "64-bit"
install_dll_batch FINAL_32 "$DIR32" "32-bit"
wt_pulse_stop

if (( FAILURES )); then
    wt_warn "$MODULE" "$(printf '%d of %d file(s) had problems:\n\n%s\nPrefix:\n  %s' "$FAILURES" "$TOTAL_FILES" "$REPORT" "$WINEPREFIX")"
elif (( INSTALLED == 0 )); then
    wt_info "$MODULE" "$(printf 'Nothing was installed:\n\n%s' "$REPORT")"
else
    wt_info "$MODULE" "$(printf '✔  COMPLETE\n─────────────────────────────────────\nInstalled %d file(s) into:\n  %s\n\n%s\nWine'"'"'s originals were kept as <name>.wt_bak.' "$INSTALLED" "$WINEPREFIX" "$REPORT")"
fi
