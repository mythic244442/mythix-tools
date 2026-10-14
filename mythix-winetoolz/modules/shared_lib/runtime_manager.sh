#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  runtime_manager.sh — Wine / Proton Runtime Manager
#  winetoolz v2.1
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
#  • Kron4ek Staging  (Kron4ek/Wine-Builds  —  staging x86_64)
#  • Kron4ek Vanilla  (Kron4ek/Wine-Builds  —  plain   x86_64)
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
#   Searches a runtime directory for its wine binary using the same candidate
#   list as wt_resolve_wine.  Prints the path and returns 0 on success,
#   prints nothing and returns 1 if not found.
_rtm_find_wine_bin() {
    local root="$1"
    local candidate
    for candidate in \
        dist/bin/wine  dist/bin/wine64 \
        bin/wine       bin/wine64      \
        files/bin/wine files/bin/wine64
    do
        if [[ -x "$root/$candidate" ]]; then
            printf '%s' "$root/$candidate"
            return 0
        fi
    done
    return 1
}

# _rtm_wine_version <wine_bin>
#   Returns the version string from a wine binary, or "unknown".
_rtm_wine_version() {
    "$1" --version 2>/dev/null | head -1 || echo "unknown"
}

# _rtm_runtime_type <runtime_root>
#   Heuristically labels a runtime as Proton, Wine, or Unknown.
_rtm_runtime_type() {
    local root="$1"
    [[ -x "$root/proton"           ]] && echo "Proton" && return
    [[ -x "$root/dist/bin/wine"    ]] && echo "Proton" && return
    [[ -x "$root/files/bin/wine"   ]] && echo "Proton" && return
    [[ -x "$root/bin/wine"         ]] && echo "Wine"   && return
    [[ -x "$root/bin/wine64"       ]] && echo "Wine"   && return
    echo "Unknown"
}

# _rtm_list_runtimes
#   Populates RTM_RUNTIME_DIRS (array) with directories under RUNTIME_DIR
#   that contain a recognisable wine binary.
_rtm_list_runtimes() {
    RTM_RUNTIME_DIRS=()
    local d
    shopt -s nullglob
    for d in "$RUNTIME_DIR"/*/; do
        [[ -d "$d" ]] || continue
        _rtm_find_wine_bin "$d" >/dev/null 2>&1 && RTM_RUNTIME_DIRS+=("${d%/}")
    done
    shopt -u nullglob
}

# _rtm_download_github <tool_label> <github_repo> <asset_grep_pattern> <out_dir_var>
#   Downloads the latest matching GitHub release asset into a new subdirectory
#   of RUNTIME_DIR.  On success, sets the variable named by <out_dir_var> to
#   the extracted directory path.
_rtm_download_github() {
    local label="$1"
    local repo="$2"
    local pattern="$3"
    local -n _out_dir="$4"   # nameref — caller passes variable name as string

    local api_url="https://api.github.com/repos/${repo}/releases/latest"

    wt_info "$MODULE  ›  $label" \
        "$(printf '<tt>Querying GitHub for the latest  %s  release…\n\n  %s</tt>' "$label" "$api_url")"

    local api_response
    if ! api_response="$(curl -fsSL "$api_url" 2>&1)"; then
        wt_error "$(printf 'Failed to query the GitHub API for %s.\n\nURL: %s\n\nPossible causes:\n  •  No internet connection\n  •  GitHub rate limit (try again in ~60 s)\n\nError:\n  %s' \
            "$label" "$api_url" "$api_response")"
    fi

    local tag_name
    tag_name="$(echo "$api_response" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"

    local asset_url
    asset_url="$(echo "$api_response" \
        | grep '"browser_download_url"' \
        | grep -i "$pattern" \
        | grep -v '\.sha256\|\.sha512\|\.sig\|\.asc\|\.txt' \
        | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"

    if [[ -z "$tag_name" || -z "$asset_url" ]]; then
        wt_error "$(printf 'Could not parse GitHub API response for  %s.\n\nTag   : %s\nAsset : %s\n\nPattern used: %s\n\nTry manually:\n  curl -fsSL %s' \
            "$label" "${tag_name:-(none)}" "${asset_url:-(none)}" "$pattern" "$api_url")"
    fi

    # Check if this version already exists
    local dest_dir="$RUNTIME_DIR/${tag_name}"
    if [[ -d "$dest_dir" ]]; then
        local existing_wine
        existing_wine="$(_rtm_find_wine_bin "$dest_dir" 2>/dev/null || true)"
        if [[ -n "$existing_wine" ]]; then
            local reuse
            reuse=$(zenity --list \
                --title="$(wt_title "$MODULE  ›  Already Installed")" \
                --text="$(printf '<tt>%s  %s  is already installed.\n\nWould you like to use it, or re-download it?</tt>' "$label" "$tag_name")" \
                --radiolist \
                --column="" --column="Option" --column="Details" \
                TRUE  "Use existing"  "$(printf 'Installed at:  %s' "$dest_dir")" \
                FALSE "Re-download"   "Remove and re-fetch from GitHub" \
                --width="$WT_WIDTH" --height=220) || return 1

            if [[ "$reuse" == "Use existing" ]]; then
                _out_dir="$dest_dir"
                return 0
            fi

            rm -rf "$dest_dir"
        fi
    fi

    # Confirm before downloading
    wt_confirm "$MODULE  ›  Download  $label" \
        "$(printf 'Ready to download:\n\n  Runtime  :  %s\n  Version  :  %s\n  Asset    :  %s\n\n─────────────────────────────────────\nWill be extracted to:\n  %s' \
            "$label" "$tag_name" "$(basename "$asset_url")" "$dest_dir")" || return 1

    # Detect archive format
    local asset_ext
    case "$asset_url" in
        *.tar.zst) asset_ext=".tar.zst" ;;
        *.tar.xz)  asset_ext=".tar.xz"  ;;
        *.tar.bz2) asset_ext=".tar.bz2" ;;
        *.tar.gz)  asset_ext=".tar.gz"  ;;
        *)         asset_ext=".tar.gz"  ;;
    esac

    [[ "$asset_ext" == ".tar.zst" ]] && wt_require_cmds zstd

    local tmp_archive
    tmp_archive="$(mktemp --suffix="$asset_ext")"
    trap 'rm -f "$tmp_archive"' RETURN

    # Download with pulsing progress
    (
        curl -fL --progress-bar "$asset_url" -o "$tmp_archive" 2>&1
    ) | zenity --progress \
            --title="$(wt_title "$MODULE  ›  Downloading  $label  $tag_name")" \
            --text="$(printf '<tt>Downloading  %s  %s\n\nFrom:\n  %s</tt>' "$label" "$tag_name" "$asset_url")" \
            --width="$WT_WIDTH" \
            --pulsate \
            --auto-close \
            --no-cancel || true

    if [[ ! -s "$tmp_archive" ]]; then
        wt_error "$(printf 'Download failed — archive is empty.\n\nURL: %s\n\nCheck your internet connection and try again.' "$asset_url")"
    fi

    mkdir -p "$dest_dir"

    # Extract — try with --strip-components=1 first (single top-level dir),
    # fall back to plain extraction if that fails.
    _do_extract() {
        if ! tar "$@" "$tmp_archive" -C "$dest_dir" --strip-components=1 2>/dev/null; then
            tar "$@" "$tmp_archive" -C "$dest_dir" \
                || wt_error "$(printf 'Failed to extract archive for  %s.\n\nArchive : %s\nFormat  : %s\nDest    : %s' \
                    "$label" "$tmp_archive" "$asset_ext" "$dest_dir")"
        fi
    }

    case "$asset_ext" in
        .tar.zst) _do_extract --use-compress-program=zstd -xf ;;
        .tar.xz)  _do_extract -xJf ;;
        .tar.bz2) _do_extract -xjf ;;
        *)        _do_extract -xzf ;;
    esac

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
        ver="$(_rtm_wine_version "$wine_bin" 2>/dev/null)"
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
        --text="$(printf '<tt>Select a runtime source to download from.\n\nAll runtimes are stored under:\n  %s</tt>' "$RUNTIME_DIR")" \
        --column="Key" --column="Source" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=740 --height=340 \
        "ge-proton"       "GE-Proton"              "GloriousEggroll custom Proton  —  best gaming compat" \
        "kron4ek-staging" "Kron4ek  Staging Wine"  "Staging patches + upstream Wine  —  x86_64"           \
        "kron4ek-vanilla" "Kron4ek  Vanilla Wine"  "Upstream Wine builds  —  x86_64, no patches"          \
        "custom-url"      "Custom URL…"            "Provide a direct .tar.gz / .tar.xz / .tar.zst link"   \
        ) || return 0

    local extracted_dir=""

    case "$source" in

        ge-proton)
            _rtm_download_github \
                "GE-Proton" \
                "GloriousEggroll/proton-ge-custom" \
                "GE-Proton.*\.tar\.gz" \
                extracted_dir || return 0
            ;;

        kron4ek-staging)
            _rtm_download_github \
                "Kron4ek Staging Wine" \
                "Kron4ek/Wine-Builds" \
                "wine-.*-staging-.*-x86_64\.tar" \
                extracted_dir || return 0
            ;;

        kron4ek-vanilla)
            # Vanilla builds don't have "staging" or "tkg" in the filename;
            # they're the plain amd64 tarball.
            _rtm_download_github \
                "Kron4ek Vanilla Wine" \
                "Kron4ek/Wine-Builds" \
                "wine-[0-9].*-amd64\.tar" \
                extracted_dir || return 0
            ;;

        custom-url)
            local custom_url
            custom_url=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Custom URL")" \
                --text="$(printf '<tt>Enter a direct download URL for a Wine or Proton runtime.\n\nSupported formats:  .tar.gz  .tar.xz  .tar.zst  .tar.bz2\n\nThe archive will be extracted into:\n  %s/&lt;release-name&gt;/</tt>' "$RUNTIME_DIR")" \
                --width=640) || return 0
            [[ -z "$custom_url" ]] && return 0

            local custom_name
            custom_name=$(zenity --entry \
                --title="$(wt_title "$MODULE  ›  Runtime Name")" \
                --text="<tt>Enter a name for this runtime\n(used as the directory name):</tt>" \
                --entry-text="$(basename "$custom_url" | sed 's/\.tar\..*//')" \
                --width="$WT_WIDTH") || return 0
            [[ -z "$custom_name" ]] && return 0

            # Sanitise name
            custom_name="$(printf '%s' "$custom_name" | tr -cd '[:alnum:]._-')"
            local dest_dir="$RUNTIME_DIR/$custom_name"

            if [[ -d "$dest_dir" ]]; then
                wt_confirm "$MODULE  ›  Overwrite?" \
                    "$(printf 'Directory already exists:\n  %s\n\nOverwrite it?' "$dest_dir")" || return 0
                rm -rf "$dest_dir"
            fi

            local asset_ext
            case "$custom_url" in
                *.tar.zst) asset_ext=".tar.zst" ;;
                *.tar.xz)  asset_ext=".tar.xz"  ;;
                *.tar.bz2) asset_ext=".tar.bz2" ;;
                *)         asset_ext=".tar.gz"  ;;
            esac
            [[ "$asset_ext" == ".tar.zst" ]] && wt_require_cmds zstd

            local tmp_archive
            tmp_archive="$(mktemp --suffix="$asset_ext")"
            trap 'rm -f "$tmp_archive"' RETURN

            (
                curl -fL --progress-bar "$custom_url" -o "$tmp_archive" 2>&1
            ) | zenity --progress \
                    --title="$(wt_title "$MODULE  ›  Downloading  $custom_name")" \
                    --text="$(printf '<tt>Downloading:\n  %s</tt>' "$custom_url")" \
                    --width="$WT_WIDTH" \
                    --pulsate \
                    --auto-close \
                    --no-cancel || true

            [[ -s "$tmp_archive" ]] || wt_error "$(printf 'Download failed — archive is empty.\nURL: %s' "$custom_url")"

            mkdir -p "$dest_dir"
            case "$asset_ext" in
                .tar.zst) tar --use-compress-program=zstd -xf "$tmp_archive" -C "$dest_dir" --strip-components=1 2>/dev/null \
                              || tar --use-compress-program=zstd -xf "$tmp_archive" -C "$dest_dir" ;;
                .tar.xz)  tar -xJf "$tmp_archive" -C "$dest_dir" --strip-components=1 2>/dev/null \
                              || tar -xJf "$tmp_archive" -C "$dest_dir" ;;
                .tar.bz2) tar -xjf "$tmp_archive" -C "$dest_dir" --strip-components=1 2>/dev/null \
                              || tar -xjf "$tmp_archive" -C "$dest_dir" ;;
                *)        tar -xzf "$tmp_archive" -C "$dest_dir" --strip-components=1 2>/dev/null \
                              || tar -xzf "$tmp_archive" -C "$dest_dir" ;;
            esac

            extracted_dir="$dest_dir"
            ;;
    esac

    # ---- Post-install verification ----
    if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
        wt_error "$(printf 'Extraction destination does not exist:\n  %s\n\nInstallation may have failed.' "${extracted_dir:-(empty)}")"
    fi

    local wine_bin
    wine_bin="$(_rtm_find_wine_bin "$extracted_dir" 2>/dev/null || true)"

    if [[ -z "$wine_bin" ]]; then
        wt_error "$(printf 'Runtime was extracted but no wine binary was found inside.\n\nDirectory : %s\n\nSearched  :\n  dist/bin/wine[64]  bin/wine[64]  files/bin/wine[64]\n\nThe archive layout may be unsupported.\nYou can inspect it manually at the path above.' "$extracted_dir")"
    fi

    local ver
    ver="$(_rtm_wine_version "$wine_bin")"

    wt_info "$MODULE  ›  Install Complete" \
        "$(printf '✔  Runtime installed and verified.\n\n  Name    :  %s\n  Type    :  %s\n  Wine    :  %s\n  Version :  %s\n  Path    :  %s\n\n─────────────────────────────────────\nThis runtime will now appear\nautomatically in all Wine / Proton\nbinary selection dialogs.' \
            "$(basename "$extracted_dir")" \
            "$(_rtm_runtime_type "$extracted_dir")" \
            "$(basename "$wine_bin")" \
            "$ver" \
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
        wine_bin="$(_rtm_find_wine_bin "$d" 2>/dev/null || echo "?")"
        ver="$(_rtm_wine_version "$wine_bin" 2>/dev/null)"
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

    local removed=0
    for d in "${del_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d" && (( removed++ )) || true
    done

    wt_info "$MODULE  ›  Remove" \
        "$(printf '✔  Removed  %d  runtime(s).' "$removed")"
}

# =============================================================================
#  Main loop
# =============================================================================

while true; do
    _rtm_list_runtimes
    local_count="${#RTM_RUNTIME_DIRS[@]}"

    CHOICE=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(printf '<tt>Manage Wine / Proton runtimes for use outside Steam.\nInstalled runtimes: %d  —  stored in:  %s</tt>' \
            "$local_count" "$RUNTIME_DIR")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=720 --height=320 \
        "list"    "List Runtimes"     "Show all installed runtimes with version + size info" \
        "install" "Install Runtime"   "Download a runtime from GE-Proton, Kron4ek, or a custom URL" \
        "remove"  "Remove Runtime"    "Delete one or more installed runtimes" \
        "exit"    "Back to Main Menu" "") || break

    case "$CHOICE" in
        list)    _rtm_action_list    ;;
        install) _rtm_action_install ;;
        remove)  _rtm_action_remove  ;;
        exit|*)  break               ;;
    esac
done
