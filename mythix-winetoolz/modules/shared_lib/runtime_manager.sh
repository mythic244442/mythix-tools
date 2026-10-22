#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  runtime_manager.sh — Wine / Proton Runtime Manager
#  winetoolz v3.0
#
#  Download, inspect, and remove Wine / Proton runtimes from well-known
#  GitHub sources.  All runtimes are stored under:
#
#    ~/wine-custom/buildz/<runtime-name>/
#
#  This directory is already scanned by wt_select_wine_bin, so any runtime
#  installed here appears automatically in every other winetoolz module.
#
#  Supported sources
#  ─────────────────
#  • GE-Proton        (GloriousEggroll/proton-ge-custom)
#  • Kron4ek Staging  (Kron4ek/Wine-Builds  —  staging amd64, also WoW64)
#  • Kron4ek Vanilla  (Kron4ek/Wine-Builds  —  plain   amd64, also WoW64)
#  • Custom URL       (tar.gz / tar.xz / tar.zst — direct link)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Runtime Manager"
RUNTIME_DIR="${HOME}/wine-custom/buildz"

wt_require_cmds zenity curl tar
mkdir -p "$RUNTIME_DIR"

# =============================================================================
#  Internal helpers
# =============================================================================

# _rtm_find_wine_bin <runtime_root>
#   The runtime's wine binary (same search as wt_resolve_wine): prints the
#   path and returns 0, or prints nothing and returns 1.
_rtm_find_wine_bin() {
    _wt_find_inner_wine "$1"
}

# _rtm_wine_version <runtime_root>
#   Returns the version string of a runtime ("version unknown" if none).
_rtm_wine_version() {
    local bin
    bin="$(_rtm_find_wine_bin "$1" || true)"
    wt_wine_version "$bin" "$1"
}

# _rtm_runtime_type <runtime_root>
#   Labels a runtime as Proton, Wine, or Unknown.
_rtm_runtime_type() {
    local root="$1"
    if _wt_wrapper_in "$root" >/dev/null || [[ -x "$root/files/bin/wine" || -x "$root/dist/bin/wine" ]]; then
        echo "Proton"
    elif [[ -x "$root/bin/wine" || -x "$root/bin/wine64" ]]; then
        echo "Wine"
    else
        echo "Unknown"
    fi
}

# _rtm_list_runtimes
#   Populates RTM_RUNTIME_DIRS (array) with directories under RUNTIME_DIR
#   that contain a recognisable wine binary.
_rtm_list_runtimes() {
    RTM_RUNTIME_DIRS=()
    local d
    shopt -s nullglob
    for d in "$RUNTIME_DIR"/*/; do
        d="${d%/}"
        [[ "$(basename "$d")" == .* ]] && continue
        if _rtm_find_wine_bin "$d" >/dev/null 2>&1; then RTM_RUNTIME_DIRS+=("$d"); fi
    done
    shopt -u nullglob
}

# _rtm_install_archive <archive> <dest_dir> <label>
#   Extracts a runtime archive into <dest_dir> (one top-level folder is
#   unwrapped; links inside Wine builds are kept). An existing <dest_dir> is
#   only replaced once the new one extracted and has a wine binary.
_rtm_install_archive() {
    local archive="$1" dest="$2" label="$3" stage
    stage="$(mktemp -d "$RUNTIME_DIR/.install.XXXXXX")" || return 1
    wt_pulse_start "$MODULE" "Extracting  $label..."
    local ok=0
    wt_extract_tree "$archive" "$stage/new" --allow-links && ok=1
    wt_pulse_stop
    if (( ! ok )); then
        rm -rf -- "$stage"
        wt_error_return "$(printf 'Failed to extract  %s.\n\n%s' "$label" "$WT_ARCHIVE_ERROR")"
        return 1
    fi
    if ! _rtm_find_wine_bin "$stage/new" >/dev/null; then
        rm -rf -- "$stage"
        wt_error_return "$(printf 'The archive for  %s  has no wine binary\n(searched files/bin, dist/bin and bin) — nothing was installed.' "$label")"
        return 1
    fi
    if [[ -e "$dest" ]]; then
        mv -- "$dest" "$stage/previous" || { rm -rf -- "$stage"; return 1; }
    fi
    if ! mv -- "$stage/new" "$dest"; then
        [[ -e "$stage/previous" ]] && mv -- "$stage/previous" "$dest"
        rm -rf -- "$stage"
        return 1
    fi
    rm -rf -- "$stage"
}

# _rtm_download_github <tool_label> <github_repo> <asset_regex> <out_dir_var> [--scan]
#   Downloads the latest matching GitHub release asset (sha256-verified when
#   GitHub publishes a digest) into its own folder under RUNTIME_DIR, named
#   after the asset. On success, sets the variable named by <out_dir_var>.
_rtm_download_github() {
    local label="$1"
    local repo="$2"
    local pattern="$3"
    local -n _out_dir="$4"   # nameref — caller passes variable name as string
    local scan="${5:-}"

    wt_pulse_start "$MODULE  ›  $label" "Asking GitHub for the latest $label release..."
    local gh_rc=0
    wt_github_latest "$repo" "$pattern" $scan || gh_rc=$?
    wt_pulse_stop
    if (( gh_rc != 0 )); then
        wt_error_return "$WT_GH_ERROR"
        return 1
    fi

    local asset="$WT_GH_ASSET" name
    name="$(_wt_safe_name "${asset%.tar.*}")"
    local dest_dir="$RUNTIME_DIR/$name"

    # Check if this version already exists
    if [[ -d "$dest_dir" ]] && _rtm_find_wine_bin "$dest_dir" >/dev/null 2>&1; then
        local reuse
        reuse=$(zenity --list \
            --title="$(wt_title "$MODULE  ›  Already Installed")" \
            --text="$(_wt_box "$(printf '%s  %s  is already installed.\n\nWould you like to use it, or re-download it?' "$label" "$WT_GH_TAG")")" \
            --radiolist \
            --column="" --column="Option" --column="Details" \
            TRUE  "Use existing"  "$(printf 'Installed at:  %s' "$dest_dir")" \
            FALSE "Re-download"   "Fetch it again from GitHub and replace it" \
            --width="$WT_WIDTH" --height=220) || return 1

        if [[ "$reuse" == "Use existing" ]]; then
            _out_dir="$dest_dir"
            return 0
        fi
    fi

    # Confirm before downloading
    wt_confirm "$MODULE  ›  Download  $label" \
        "$(printf 'Ready to download:\n\n  Runtime  :  %s\n  Version  :  %s\n  Asset    :  %s%s\n\n─────────────────────────────────────\nWill be extracted to:\n  %s' \
            "$label" "$WT_GH_TAG" "$asset" \
            "${WT_GH_SIZE:+$(printf '\n  Size     :  %s' "$(wt_human_size "$WT_GH_SIZE")")}" \
            "$dest_dir")" || return 1

    case "$asset" in
        *.tar.zst) wt_require_cmds zstd ;;
        *.tar.xz)  wt_require_cmds xz ;;
    esac

    local archive
    archive="$RUNTIME_DIR/.downloads/$(_wt_safe_name "$asset")"
    local rc=0
    wt_fetch "$WT_GH_URL" "$archive" "$WT_GH_SHA256" "$label $WT_GH_TAG" "$WT_GH_SIZE" || rc=$?
    if (( rc == 130 )); then
        return 1
    elif (( rc != 0 )); then
        wt_error_return "$WT_FETCH_ERROR"
        return 1
    fi

    if ! _rtm_install_archive "$archive" "$dest_dir" "$label $WT_GH_TAG"; then
        rm -f -- "$archive"
        return 1
    fi
    rm -f -- "$archive"
    rmdir "$RUNTIME_DIR/.downloads" 2>/dev/null || true
    _out_dir="$dest_dir"
}

# =============================================================================
#  Action: List / inspect installed runtimes
# =============================================================================

_rtm_action_list() {
    _rtm_list_runtimes

    if [[ ${#RTM_RUNTIME_DIRS[@]} -eq 0 ]]; then
        wt_info "$MODULE  ›  Installed Runtimes" \
            "$(printf 'No runtimes installed yet.\n\nUse  Install Runtime  to download one.\n\nRuntimes are stored in:\n  %s' "$RUNTIME_DIR")"
        return
    fi

    local listing=""
    local d wine_bin ver rtype size
    for d in "${RTM_RUNTIME_DIRS[@]}"; do
        wine_bin="$(_rtm_find_wine_bin "$d" 2>/dev/null || echo "(not found)")"
        ver="$(_rtm_wine_version "$d")"
        rtype="$(_rtm_runtime_type "$d")"
        size="$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")"
        listing+="$(printf \
            '  %-32s  [%s]\n    Wine  : %s\n    Ver   : %s\n    Size  : %s\n    Path  : %s\n\n' \
            "$(basename "$d")" "$rtype" \
            "$(basename "$wine_bin")" "$ver" \
            "$size" "$d")"
    done

    wt_info "$MODULE  ›  Installed Runtimes  (${#RTM_RUNTIME_DIRS[@]})" "$listing"
}

# =============================================================================
#  Action: Install a runtime
# =============================================================================

_rtm_action_install() {
    local source
    source=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Install Runtime")" \
        --text="$(_wt_box "$(printf 'Select a runtime source to download from.\n\nAll runtimes are stored under:\n  %s' "$RUNTIME_DIR")")" \
        --column="Key" --column="Source" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=760 --height=380 \
        "ge-proton"             "GE-Proton"                      "GloriousEggroll custom Proton  —  best gaming compat" \
        "kron4ek-staging"       "Kron4ek  Staging Wine"          "Staging patches + upstream Wine  —  64-bit (needs 32-bit libs)" \
        "kron4ek-vanilla"       "Kron4ek  Vanilla Wine"          "Upstream Wine builds  —  64-bit, no patches" \
        "kron4ek-staging-wow64" "Kron4ek  Staging Wine (WoW64)"  "Staging — pure 64-bit WoW64 build, no 32-bit libs needed" \
        "kron4ek-vanilla-wow64" "Kron4ek  Vanilla Wine (WoW64)"  "Upstream — pure 64-bit WoW64 build, no 32-bit libs needed" \
        "custom-url"            "Custom URL…"                    "Provide a direct https .tar.gz / .tar.xz / .tar.zst link" \
        ) || return 0
    source="${source%%|*}"

    local extracted_dir="" v='[0-9]+\.[0-9]+(-rc[0-9]+)?'

    case "$source" in

        ge-proton)
            _rtm_download_github "GE-Proton" "GloriousEggroll/proton-ge-custom" \
                '^GE-Proton[0-9]+-[0-9]+\.tar\.gz$' extracted_dir || return 0 ;;
        # Kron4ek publishes one release per Wine version holding every
        # flavour (vanilla, staging, tkg, wow64, x86) — names end in amd64.
        kron4ek-staging)
            _rtm_download_github "Kron4ek Staging Wine" "Kron4ek/Wine-Builds" \
                "^wine-${v}-staging-amd64\.tar\.xz$" extracted_dir --scan || return 0 ;;
        kron4ek-vanilla)
            _rtm_download_github "Kron4ek Vanilla Wine" "Kron4ek/Wine-Builds" \
                "^wine-${v}-amd64\.tar\.xz$" extracted_dir --scan || return 0 ;;
        kron4ek-staging-wow64)
            _rtm_download_github "Kron4ek Staging Wine (WoW64)" "Kron4ek/Wine-Builds" \
                "^wine-${v}-staging-amd64-wow64\.tar\.xz$" extracted_dir --scan || return 0 ;;
        kron4ek-vanilla-wow64)
            _rtm_download_github "Kron4ek Vanilla Wine (WoW64)" "Kron4ek/Wine-Builds" \
                "^wine-${v}-amd64-wow64\.tar\.xz$" extracted_dir --scan || return 0 ;;

        custom-url)
            local custom_url
            custom_url=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Custom URL")" \
                --text="$(_wt_box "$(printf 'Enter a direct https download URL for a Wine or Proton runtime.\n\nSupported formats:  .tar.gz  .tar.xz  .tar.zst  .tar.bz2\n\nThe archive will be extracted into:\n  %s/<release-name>/' "$RUNTIME_DIR")")" \
                --width=640) || return 0
            [[ -z "$custom_url" ]] && return 0

            local guess="${custom_url%%[?#]*}"
            guess="${guess##*/}"
            guess="${guess%.tar.*}"
            local custom_name
            custom_name=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Runtime Name")" \
                --text="<tt>Enter a name for this runtime\n(used as the directory name):</tt>" \
                --entry-text="$guess" \
                --width="$WT_WIDTH") || return 0

            # Sanitise name — never empty, never . or .. (that would be the
            # runtimes folder itself or its parent)
            custom_name="$(_wt_safe_name "$custom_name")"
            if [[ -z "$custom_name" || "$custom_name" == unnamed ]]; then
                wt_error_return "Please enter a name made of letters, digits, dots, dashes or underscores."
                return 0
            fi
            local dest_dir="$RUNTIME_DIR/$custom_name"

            if [[ -d "$dest_dir" ]]; then
                wt_confirm "$MODULE  ›  Overwrite?" \
                    "$(printf 'Runtime already exists:\n  %s\n\nReplace it? The current one is kept until the\nnew one has been downloaded and checked.' "$dest_dir")" || return 0
            fi

            case "$custom_url" in
                *.tar.zst*) wt_require_cmds zstd ;;
                *.tar.xz*)  wt_require_cmds xz ;;
            esac
            local ext=".tar.gz"
            case "$custom_url" in
                *.tar.zst*) ext=".tar.zst" ;; *.tar.xz*) ext=".tar.xz" ;; *.tar.bz2*) ext=".tar.bz2" ;;
            esac
            local archive="$RUNTIME_DIR/.downloads/${custom_name}${ext}"
            if ! wt_fetch "$custom_url" "$archive" "" "$custom_name"; then
                [[ -n "$WT_FETCH_ERROR" && "$WT_FETCH_ERROR" != "Download cancelled." ]] && wt_error_return "$WT_FETCH_ERROR"
                return 0
            fi
            if ! _rtm_install_archive "$archive" "$dest_dir" "$custom_name"; then
                rm -f -- "$archive"
                return 0
            fi
            rm -f -- "$archive"
            rmdir "$RUNTIME_DIR/.downloads" 2>/dev/null || true
            extracted_dir="$dest_dir"
            ;;
        *) return 0 ;;
    esac

    # ---- Post-install verification ----
    if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
        wt_error_return "$(printf 'Extraction destination does not exist:\n  %s\n\nInstallation may have failed.' "${extracted_dir:-(empty)}")"
        return 0
    fi

    local wine_bin
    wine_bin="$(_rtm_find_wine_bin "$extracted_dir" 2>/dev/null || true)"

    wt_info "$MODULE  ›  Install Complete" \
        "$(printf '✔  Runtime installed and verified.\n\n  Name    :  %s\n  Type    :  %s\n  Wine    :  %s\n  Version :  %s\n  Path    :  %s\n\n─────────────────────────────────────\nThis runtime will now appear\nautomatically in all Wine / Proton\nbinary selection dialogs.' \
            "$(basename "$extracted_dir")" \
            "$(_rtm_runtime_type "$extracted_dir")" \
            "${wine_bin#"$extracted_dir"/}" \
            "$(_rtm_wine_version "$extracted_dir")" \
            "$extracted_dir")"
}

# =============================================================================
#  Action: Remove installed runtimes
# =============================================================================

_rtm_action_remove() {
    _rtm_list_runtimes

    if [[ ${#RTM_RUNTIME_DIRS[@]} -eq 0 ]]; then
        wt_info "$MODULE  ›  Remove" "No runtimes installed yet."
        return
    fi

    local del_args=()
    local d wine_bin ver size
    for d in "${RTM_RUNTIME_DIRS[@]}"; do
        ver="$(_rtm_wine_version "$d")"
        size="$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")"
        del_args+=("FALSE" "$d" "$(basename "$d")" "$ver" "$size")
    done

    local to_delete
    to_delete=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Remove Runtimes")" \
        --text="<tt>Select runtimes to remove:  (this cannot be undone)</tt>" \
        --checklist \
        --column="Del" --column="Path" --column="Name" \
        --column="Wine Version" --column="Disk Usage" \
        --hide-column=2 --print-column=2 \
        --width=820 --height=400 \
        "${del_args[@]}") || return 0

    [[ -z "$to_delete" ]] && return 0

    # Build a readable list for the confirmation dialog
    local confirm_list=""
    local IFS_ORIG="$IFS"
    IFS='|' read -ra del_dirs <<< "$to_delete"
    IFS="$IFS_ORIG"
    for d in "${del_dirs[@]}"; do
        confirm_list+="$(printf '  •  %s\n' "$(basename "$d")")"
    done

    wt_confirm "$MODULE  ›  Confirm Delete" \
        "$(printf 'Permanently delete the following runtimes?\n\n%s\nThis will remove the directories entirely.' "$confirm_list")" || return 0

    # Only folders this dialog offered (a hand-made answer such as
    # "<runtimes>/../x" is not one of them).
    local -A offered=()
    for d in "${RTM_RUNTIME_DIRS[@]}"; do offered["$d"]=1; done

    local removed=0 failed=""
    for d in "${del_dirs[@]}"; do
        [[ -n "$d" && -n "${offered[$d]:-}" && -d "$d" ]] || continue
        if wt_safe_rmrf "$d" proton neutron bin/wine bin/wine64 files/bin/wine dist/bin/wine; then
            removed=$((removed + 1))
        else
            failed+="  $(basename "$d"): $WT_RMRF_ERROR"$'\n'
        fi
    done

    if [[ -n "$failed" ]]; then
        wt_error_return "$(printf 'Removed %d runtime(s); these could not be removed:\n\n%s' "$removed" "$failed")"
    else
        wt_info "$MODULE  ›  Remove" \
            "$(printf '✔  Removed  %d  runtime(s).' "$removed")"
    fi
}

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    _rtm_list_runtimes
    local_count="${#RTM_RUNTIME_DIRS[@]}"

    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(_wt_box "$(printf 'Manage Wine / Proton runtimes for use outside Steam.\nInstalled runtimes: %d  —  stored in:  %s' \
            "$local_count" "$RUNTIME_DIR")")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=720 --height=320 \
        "list"    "List Runtimes"     "Show all installed runtimes with version + size info" \
        "install" "Install Runtime"   "Download a runtime from GE-Proton, Kron4ek, or a custom URL" \
        "remove"  "Remove Runtime"    "Delete one or more installed runtimes" \
        "exit"    "Back to Main Menu" "") || break
    CHOICE="${CHOICE%%|*}"

    case "$CHOICE" in
        list)    _rtm_action_list    ;;
        install) _rtm_action_install ;;
        remove)  _rtm_action_remove  ;;
        exit|*)  break               ;;
    esac
done
