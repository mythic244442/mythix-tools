#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  install_components-x86_64.sh — Generic DLL / System Component Installer
#  winetoolz v2.0
#  Extracts an archive, classifies DLLs by arch, lets you pick which to
#  install, copies them into the prefix and sets DLL overrides.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="System Component Installer"

wt_require_cmds zenity wget unzip file find xargs cabextract 7z

# =============================================================================
#  1. Select Wine / Proton binary
# =============================================================================

wt_select_wine_bin "$MODULE" || exit 0

# =============================================================================
#  2. Select WINEPREFIX
# =============================================================================

wt_select_prefix "$MODULE" || exit 0

# =============================================================================
#  3. Detect prefix bitness
# =============================================================================

PATH_SYS32="$WINEPREFIX/drive_c/windows/system32"
PATH_SYSWOW="$WINEPREFIX/drive_c/windows/syswow64"

IS_WIN64=false
wt_is_win64 "$WINEPREFIX" && IS_WIN64=true

# =============================================================================
#  4. Select component source
# =============================================================================

SOURCE_TYPE=$(zenity --list \
    --title="$(wt_title "$MODULE  ›  Select Source")" \
    --text="<tt>Where are the DLL / component files coming from?</tt>" \
    --radiolist \
    --column="" --column="Option" --column="Details" \
    TRUE  "Download from URL"   "Paste a direct link — archive will be fetched via wget" \
    FALSE "Select Local Archive" "Browse for a local .zip / .exe / .cab / .7z file" \
    --width="$WT_WIDTH" --height=220) || exit 0

ARCHIVE_URL=""
LOCAL_ARCHIVE=""

if [[ "$SOURCE_TYPE" == "Download from URL" ]]; then
    ARCHIVE_URL=$(zenity --entry \
        --title="$(wt_title "$MODULE  ›  Enter URL")" \
        --text="<tt>Paste the direct download link to the archive:</tt>" \
        --width="$WT_WIDTH") || exit 0
    [[ -z "$ARCHIVE_URL" ]] && wt_error "No URL was provided."
else
    LOCAL_ARCHIVE=$(zenity --file-selection \
        --title="$(wt_title "$MODULE  ›  Select Archive")" \
        --text="<tt>Select the archive containing your DLLs / components.</tt>" \
        --file-filter="Supported archives | *.zip *.exe *.cab *.7z" \
        --width="$WT_WIDTH") || exit 0
fi

# =============================================================================
#  5. Extract archive
# =============================================================================

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_FILE=""
ARCHIVE_EXT=""

if [[ "$SOURCE_TYPE" == "Download from URL" ]]; then
    ARCHIVE_FILE="$TMP_DIR/downloaded_archive"
    (
        echo "10"
        echo "# Downloading archive..."
        wget -q --show-progress -O "$ARCHIVE_FILE" "$ARCHIVE_URL" 2>&1
        echo "100"
    ) | wt_progress_pulse "$MODULE" "Downloading archive from URL..." \
        || wt_error "$(printf 'Download failed.\n\nURL: %s\n\nCheck the URL and your internet connection.' "$ARCHIVE_URL")"

    # Strip query string before extension detection
    ARCHIVE_NAME_CLEAN="$(echo "$ARCHIVE_URL" | sed 's/\?.*//' | xargs basename)"
    ARCHIVE_EXT="${ARCHIVE_NAME_CLEAN##*.}"
    [[ "$ARCHIVE_NAME_CLEAN" != *.* ]] && ARCHIVE_EXT="exe"
else
    ARCHIVE_FILE="$LOCAL_ARCHIVE"
    ARCHIVE_EXT="${ARCHIVE_FILE##*.}"
fi

ARCHIVE_EXT_LOWER="$(echo "$ARCHIVE_EXT" | tr '[:upper:]' '[:lower:]')"

echo "Extracting ($ARCHIVE_EXT_LOWER)..."
case "$ARCHIVE_EXT_LOWER" in
    exe|cab) cabextract -q -d "$TMP_DIR" "$ARCHIVE_FILE" ;;
    zip)     unzip -o -qq "$ARCHIVE_FILE" -d "$TMP_DIR"  ;;
    7z|rar)  7z x -o"$TMP_DIR" "$ARCHIVE_FILE" -y >/dev/null ;;
    *)       wt_error "$(printf 'Unsupported archive format:  .%s\n\nSupported formats:  .exe  .cab  .zip  .7z' "$ARCHIVE_EXT_LOWER")" ;;
esac

# =============================================================================
#  6. Classify DLLs by architecture
# =============================================================================

mapfile -d '' ALL_DLLS < <(find "$TMP_DIR" -type f \
    \( -name "*.dll" -o -name "*.ocx" -o -name "*.cpl" -o -name "*.ax" \) \
    -print0)

declare -a DLLS_64=()
declare -a DLLS_32=()

for fpath in "${ALL_DLLS[@]}"; do
    finfo="$(file "$fpath" 2>/dev/null || true)"
    if   echo "$finfo" | grep -q "PE32+"; then DLLS_64+=("$fpath")
    elif echo "$finfo" | grep -q "PE32";  then DLLS_32+=("$fpath")
    fi
done

COUNT_64=${#DLLS_64[@]}
COUNT_32=${#DLLS_32[@]}

zenity --info \
    --title="$(wt_title "$MODULE  ›  Components Found")" \
    --width="$WT_WIDTH" \
    --text="$(printf '<tt>Archive scanned.\n\n  64-bit DLL / OCX / CPL / AX :  %d\n  32-bit DLL / OCX / CPL / AX :  %d\n\nClick OK to select which files to install.</tt>' "$COUNT_64" "$COUNT_32")"

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

# --- 64-bit ---
if (( COUNT_64 > 0 )); then
    MODE_64="$(select_mode "64-bit")" || MODE_64="Skip 64-bit"
    case "$MODE_64" in
        "Install ALL 64-bit")
            FINAL_64=("${DLLS_64[@]}")
            ;;
        "Pick 64-bit files")
            CHECKBOX=()
            for f in "${DLLS_64[@]}"; do
                CHECKBOX+=(FALSE "$f" "$(basename "$f")")
            done
            SELECTED=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  64-bit DLL Selection")" \
                --text="<tt>Check each 64-bit file you want to install.</tt>" \
                --checklist \
                --column="Install" --column="Full Path" --column="Filename" \
                --width=820 --height=560 \
                "${CHECKBOX[@]}") || SELECTED=""
            [[ -n "$SELECTED" ]] && IFS="|" read -ra FINAL_64 <<< "$SELECTED"
            ;;
        *) FINAL_64=() ;;
    esac
fi

# --- 32-bit ---
if (( COUNT_32 > 0 )); then
    MODE_32="$(select_mode "32-bit")" || MODE_32="Skip 32-bit"
    case "$MODE_32" in
        "Install ALL 32-bit")
            FINAL_32=("${DLLS_32[@]}")
            ;;
        "Pick 32-bit files")
            CHECKBOX=()
            for f in "${DLLS_32[@]}"; do
                CHECKBOX+=(FALSE "$f" "$(basename "$f")")
            done
            SELECTED=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  32-bit DLL Selection")" \
                --text="<tt>Check each 32-bit file you want to install.</tt>" \
                --checklist \
                --column="Install" --column="Full Path" --column="Filename" \
                --width=820 --height=560 \
                "${CHECKBOX[@]}") || SELECTED=""
            [[ -n "$SELECTED" ]] && IFS="|" read -ra FINAL_32 <<< "$SELECTED"
            ;;
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

install_dll_batch() {
    local -n _files=$1
    local target_dir="$2"
    local regsvr_bin="$3"
    local arch_label="$4"

    echo ""
    echo "  ── $arch_label  →  $(basename "$target_dir") ──"

    if (( ${#_files[@]} == 0 )); then
        echo "  (no $arch_label files selected)"
        return
    fi

    for fpath in "${_files[@]}"; do
        local base
        base="$(basename "$fpath")"
        mv -f "$fpath" "$target_dir/$base"
        echo "  [   OK   ] $base"
    done

    echo ""
    echo "  Registering DLLs..."
    for fpath in "${_files[@]}"; do
        local base ext
        base="$(basename "$fpath")"
        ext="${base##*.}"
        if [[ "$ext" =~ ^(dll|ocx)$ ]]; then
            (
                cd "$target_dir"
                env WINEPREFIX="$WINEPREFIX" "$WT_INNER_WINE" "$regsvr_bin" /s "$base" >/dev/null 2>&1 || true
            )
        fi
    done

    echo ""
    echo "  Applying DLL overrides..."
    local OVERRIDE_BLOCK=""
    for fpath in "${_files[@]}"; do
        local base dll_name
        base="$(basename "$fpath")"
        dll_name="${base%.*}"
        dll_name="${dll_name,,}"   # lowercase
        OVERRIDE_BLOCK+="\"$dll_name\"=\"native,builtin\"\n"
    done

    local TEMP_REG
    TEMP_REG="$(mktemp --suffix=.reg)"
    printf '[Software\\Wine\\DllOverrides]\n%b\n' "$OVERRIDE_BLOCK" > "$TEMP_REG"
    cat "$TEMP_REG" >> "$WINEPREFIX/user.reg"
    rm -f "$TEMP_REG"
    echo "  [   OK   ] Overrides written to user.reg"
}

(
    install_dll_batch FINAL_64 "$PATH_SYS32" "$PATH_SYS32/regsvr32.exe" "64-bit"

    if $IS_WIN64; then
        install_dll_batch FINAL_32 "$PATH_SYSWOW" "$PATH_SYSWOW/regsvr32.exe" "32-bit"
    else
        install_dll_batch FINAL_32 "$PATH_SYS32" "$PATH_SYS32/regsvr32.exe" "32-bit"
    fi
) | wt_progress_pulse "$MODULE" "Installing components into prefix..."

wt_info "$MODULE" "$(printf '✔  COMPLETE\n─────────────────────────────────────\nInstalled %d file(s) into:\n  %s' "$TOTAL_FILES" "$WINEPREFIX")"
