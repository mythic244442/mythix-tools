#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  wine_install_manager.sh — Wine Install Manager
#  winetoolz v3.0
#  Install, list, switch, uninstall, and inspect custom Wine builds.
#  Managed installs live in ~/.local/share/mythix-wine-installs/<name>/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Wine Install Manager"
INSTALL_BASE="${HOME}/.local/share/mythix-wine-installs"
SYMLINK_DIR="${HOME}/.local/bin"
META_FILE=".mythix-meta"

mkdir -p "$INSTALL_BASE" "$SYMLINK_DIR"

wt_require_cmds zenity

# =============================================================================
#  Helpers
# =============================================================================

# _list_installs
#   Prints one line per managed install: <name>\t<version>\t<date>\t<active>
_list_installs() {
    local active_target=""
    if [[ -L "$SYMLINK_DIR/wine" ]]; then
        active_target="$(readlink -f "$SYMLINK_DIR/wine" 2>/dev/null || true)"
    fi

    for dir in "$INSTALL_BASE"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        local version="unknown" date="unknown"

        if [[ -f "$dir/$META_FILE" ]]; then
            version="$(grep '^version=' "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || echo "unknown")"
            date="$(grep '^installed=' "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        fi

        # Try to get version from the binary if metadata is missing
        if [[ "$version" == "unknown" && -x "$dir/bin/wine" ]]; then
            version="$("$dir/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
        fi

        local active="no"
        if [[ -n "$active_target" ]]; then
            local this_wine
            this_wine="$(readlink -f "$dir/bin/wine" 2>/dev/null || true)"
            [[ "$active_target" == "$this_wine" ]] && active="YES"
        fi

        printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$date" "$active"
    done
}

# _write_meta <install_dir> <source_desc>
_write_meta() {
    local dir="$1"
    local source_desc="$2"
    local version="unknown"
    [[ -x "$dir/bin/wine" ]] && version="$("$dir/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
    cat > "$dir/$META_FILE" <<EOF
name=$(basename "$dir")
version=$version
source=$source_desc
installed=$(date '+%Y-%m-%d %H:%M')
EOF
}

BINS=(wine wineserver wine64 wineboot winecfg msiexec notepad regedit regsvr32)

# _set_active <install_name>
#   Points ~/.local/bin/wine, wineserver, wine64, wineboot, winecfg … at an
#   install. Only links winetoolz made (into the managed installs) are
#   replaced; anything else there — your own wrapper script, a link to
#   /opt/wine-staging — is left alone unless you agree to set it aside as
#   <name>.wt-backup. Sets WIM_MADE / WIM_KEPT for the report.
_set_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name" b link target
    local -a foreign=()
    WIM_MADE=() WIM_KEPT=()
    mkdir -p "$SYMLINK_DIR"

    for b in "${BINS[@]}"; do
        [[ -x "$dir/bin/$b" ]] || continue
        link="$SYMLINK_DIR/$b"
        if [[ -L "$link" ]]; then
            target="$(readlink -f "$link" 2>/dev/null || true)"
            if [[ -e "$link" && "$target" != "$INSTALL_BASE"/* ]]; then
                foreign+=("$b")
                continue
            fi
        elif [[ -e "$link" ]]; then
            foreign+=("$b")
            continue
        fi
        rm -f -- "$link"
        ln -s -- "$dir/bin/$b" "$link" && WIM_MADE+=("$b")
    done

    if (( ${#foreign[@]} )); then
        if wt_confirm "$MODULE  >  Replace Your Files?" "$(printf 'These are already in  %s  and were not made by winetoolz:\n\n  %s\n\nSet them aside (renamed to <name>.wt-backup) and link\n%s instead?  Choose No to leave them as they are.' \
            "$SYMLINK_DIR" "${foreign[*]}" "$name")"; then
            for b in "${foreign[@]}"; do
                link="$SYMLINK_DIR/$b"
                local backup="$link.wt-backup"
                [[ -e "$backup" || -L "$backup" ]] && backup="$link.wt-backup.$(date +%Y%m%d%H%M%S)"
                mv -- "$link" "$backup" && ln -s -- "$dir/bin/$b" "$link" && WIM_MADE+=("$b")
            done
        else
            WIM_KEPT=("${foreign[@]}")
        fi
    fi
}

# _clear_active <install_name>
#   Removes symlinks that point to the given install
_clear_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name" b target

    for b in "${BINS[@]}"; do
        if [[ -L "$SYMLINK_DIR/$b" ]]; then
            target="$(readlink -f "$SYMLINK_DIR/$b" 2>/dev/null || true)"
            if [[ "$target" == "$dir"/* ]]; then
                rm -f -- "$SYMLINK_DIR/$b"
            fi
        fi
    done
}

# _active_report — the dialog text after a switch
_active_report() {
    local name="$1" text
    text="$(printf 'Active Wine:  %s\n\nLinked in %s:\n  %s' "$name" "$SYMLINK_DIR" "${WIM_MADE[*]:-(nothing)}")"
    if (( ${#WIM_KEPT[@]} )); then
        text+="$(printf '\n\nLeft as they were (yours):\n  %s' "${WIM_KEPT[*]}")"
    fi
    case ":$PATH:" in
        *":$SYMLINK_DIR:"*) ;;
        *) text+="$(printf '\n\n⚠  %s is not on your PATH yet — log out and back in,\n   or add it in ~/.profile, for "wine" to pick this build.' "$SYMLINK_DIR")" ;;
    esac
    printf '%s' "$text"
}

# =============================================================================
#  Action: Install
# =============================================================================

_do_install() {
    # --- Pick source type ---
    local src_type
    src_type=$(zenity --list \
        --title="$(wt_title "$MODULE  >  Install")" \
        --text="<tt>Where is the Wine build you want to install?</tt>" \
        --radiolist \
        --column="" --column="Source" --column="Description" \
        TRUE  "builder"   "From mythix wine-builder output (buildz/install/)" \
        FALSE "directory" "From a local directory containing bin/wine" \
        FALSE "tarball"   "From a .tar.gz / .tar.xz / .tar.zst archive" \
        --width="$WT_WIDTH" --height=260) || return 0

    local source_path="" source_desc=""

    case "$src_type" in
        builder)
            # Scan wine-builder output directories
            local -a search_dirs=(
                "$HOME/.local/share/mythix-wine_builder/buildz/install"
                "$HOME/wine-custom/buildz"
            )
            local -a rows=()
            for sdir in "${search_dirs[@]}"; do
                [[ -d "$sdir" ]] || continue
                for bdir in "$sdir"/*/; do
                    [[ -d "$bdir" ]] || continue
                    [[ -x "$bdir/bin/wine" || -x "$bdir/bin/wine64" ]] || continue
                    local bname
                    bname="$(basename "$bdir")"
                    local bver="unknown"
                    [[ -x "$bdir/bin/wine" ]] && bver="$("$bdir/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
                    rows+=("$bdir" "$bname  —  $bver  ($sdir)")
                done
            done

            if [[ ${#rows[@]} -eq 0 ]]; then
                wt_error_return "No Wine builds found in known build directories.

Searched:
$(printf '  %s\n' "${search_dirs[@]}")

Build Wine first with wine-builder, or choose
'directory' or 'tarball' as source."
                return 0
            fi

            source_path=$(zenity --list \
                --title="$(wt_title "$MODULE  >  Select Build")" \
                --text="<tt>Select a completed Wine build to install.</tt>" \
                --column="Path" --column="Build" \
                --hide-column=1 --print-column=1 \
                --width=780 --height=380 \
                "${rows[@]}") || return 0
            source_desc="wine-builder: $source_path"
            ;;

        directory)
            source_path=$(zenity --file-selection \
                --directory \
                --title="$(wt_title "$MODULE  >  Select Directory")" \
                --width="$WT_WIDTH") || return 0

            if [[ ! -x "$source_path/bin/wine" && ! -x "$source_path/bin/wine64" ]]; then
                wt_error_return "Not a valid Wine build directory.

Expected bin/wine or bin/wine64 inside:
  $source_path"
                return 0
            fi
            source_desc="local directory: $source_path"
            ;;

        tarball)
            source_path=$(zenity --file-selection \
                --title="$(wt_title "$MODULE  >  Select Archive")" \
                --file-filter="Archives | *.tar.gz *.tar.xz *.tar.zst *.tar.bz2 *.tgz" \
                --width="$WT_WIDTH") || return 0
            source_desc="archive: $(basename "$source_path")"
            ;;
    esac

    [[ -n "$source_path" ]] || return 0
    source_path="${source_path%/}"

    # --- Pick install name ---
    local default_name=""
    if [[ "$src_type" == "tarball" ]]; then
        default_name="$(basename "$source_path" | sed 's/\.\(tar\.\(gz\|xz\|zst\|bz2\)\|tgz\)$//')"
    else
        default_name="$(basename "$source_path")"
    fi

    local install_name
    install_name=$(zenity --entry \
        --title="$(wt_title "$MODULE  >  Install Name")" \
        --text="$(_wt_box "$(printf 'Choose a name for this Wine installation.\n\nIt will be installed to:\n  %s/<name>/\n\nUse something short and descriptive\n(e.g. wine-10.5-staging, wine-tkg-custom).' "$INSTALL_BASE")")" \
        --entry-text="$default_name" \
        --width="$WT_WIDTH") || return 0

    # Sanitise name: no path tricks, no hidden or option-looking names
    install_name="${install_name//[^a-zA-Z0-9._-]/_}"
    install_name="${install_name#"${install_name%%[!.-]*}"}"

    if [[ -z "$install_name" ]]; then
        wt_error_return "Please enter a name made of letters, digits, dots, dashes or underscores."
        return 0
    fi

    local dest="$INSTALL_BASE/$install_name"

    # The source may not be (or be inside) the install it would replace.
    local src_real dest_real
    src_real="$(realpath -m -- "$source_path")"
    dest_real="$(realpath -m -- "$dest")"
    if [[ "$src_real" == "$dest_real" || "$src_real" == "$dest_real"/* || "$dest_real" == "$src_real"/* ]]; then
        wt_error_return "$(printf 'The source is the install itself:\n  %s\n\nPick a different name or source.' "$source_path")"
        return 0
    fi

    if [[ -d "$dest" ]]; then
        wt_confirm "$MODULE  >  Overwrite?" \
            "$(printf 'An install named  %s  already exists.\n\nReplace it? The current one is kept until the new\nbuild has been installed and checked.' "$install_name")" || return 0
    fi

    # --- Actually install (in terminal for progress) ---
    # Everything reaches the script through the environment, never pasted
    # into its text: a file or folder name is only ever data.
    export WIM_TYPE="$src_type" WIM_SOURCE="$source_path" WIM_DEST="$dest" \
           WIM_BASE="$INSTALL_BASE" WIM_NAME="$install_name" WIM_DESC="$source_desc" \
           WIM_META="$META_FILE"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat > "$TMP" <<'SCRIPT'
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Wine Install Manager  >  Installing"
wt_log_info "Source : $WIM_SOURCE"
wt_log_info "Dest   : $WIM_DEST"
wt_log_info "Type   : $WIM_TYPE"
printf '\n'

fail() { wt_log_err "$*"; [[ -n "${STAGE:-}" ]] && rm -rf -- "$STAGE"; wt_pause; exit 1; }

# Install into a staging folder next to the destination; the current install
# (if any) is only replaced once the new one checks out.
STAGE="$(mktemp -d "$WIM_BASE/.staging.XXXXXX")" || fail "Cannot write to $WIM_BASE"
BUILD="$STAGE/build"

case "$WIM_TYPE" in
    builder|directory)
        wt_log "Copying Wine build..."
        mkdir -p "$BUILD"
        if command -v rsync &>/dev/null; then
            rsync -aH --info=progress2 "$WIM_SOURCE/" "$BUILD/" || fail "Copy failed."
        else
            cp -a "$WIM_SOURCE/." "$BUILD/" || fail "Copy failed."
        fi
        ;;
    tarball)
        wt_log "Extracting archive..."
        case "$WIM_SOURCE" in
            *.tar.zst) command -v zstd &>/dev/null || fail "zstd is required for .tar.zst archives — install the zstd package." ;;
        esac
        # Wine builds ship symlinks of their own; one top-level folder in the
        # archive is unwrapped, a flat archive is taken as it is.
        wt_extract_tree "$WIM_SOURCE" "$BUILD" --allow-links || fail "Failed to extract archive: $WT_ARCHIVE_ERROR"
        ;;
esac

# Fix permissions and ensure binaries are executable
chmod -R u+w,a+rX "$BUILD"
[[ -d "$BUILD/bin" ]] && chmod +x "$BUILD/bin"/* 2>/dev/null

# Validate
if [[ ! -x "$BUILD/bin/wine" && ! -x "$BUILD/bin/wine64" ]]; then
    wt_log_err "No wine binary found in the new build's bin/ — the archive may have an unexpected structure."
    if [[ -d "$BUILD/bin" ]]; then ls -la "$BUILD/bin/" 2>/dev/null; else ls -la "$BUILD/" 2>/dev/null; fi
    fail "Nothing was installed or changed."
fi
WINE="$BUILD/bin/wine"; [[ -x "$WINE" ]] || WINE="$BUILD/bin/wine64"
version="$("$WINE" --version 2>/dev/null | head -1)"
[[ -n "$version" ]] || version="unknown"

# Swap it into place
if [[ -e "$WIM_DEST" ]]; then
    mv -- "$WIM_DEST" "$STAGE/previous" || fail "Could not move the current install aside."
fi
if ! mv -- "$BUILD" "$WIM_DEST"; then
    [[ -e "$STAGE/previous" ]] && mv -- "$STAGE/previous" "$WIM_DEST"
    fail "Could not move the new build into place; the previous install was kept."
fi
rm -rf -- "$STAGE"
STAGE=""

printf 'name=%s\nversion=%s\nsource=%s\ninstalled=%s\n' \
    "$WIM_NAME" "$version" "$WIM_DESC" "$(date '+%Y-%m-%d %H:%M')" > "$WIM_DEST/$WIM_META"

wt_log_ok "Wine build installed to: $WIM_DEST"
wt_log_info "Version: $version"
wt_section "Done!"
wt_pause
SCRIPT
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"

    # After install, offer to set as active
    if [[ "$WT_TERMINAL_RC" == 0 && -d "$dest" && ( -x "$dest/bin/wine" || -x "$dest/bin/wine64" ) ]]; then
        if wt_confirm "$MODULE  >  Set Active?" \
            "$(printf 'Set  %s  as the active Wine?\n\nThis will create symlinks in:\n  %s\n\nSo that running "wine" uses this build.' "$install_name" "$SYMLINK_DIR")"; then
            _set_active "$install_name"
            wt_ok "$MODULE" "$(_active_report "$install_name")"$'\n\n'"Switching"
        else
            wt_ok "$MODULE" "Installing $install_name"
        fi
    else
        wt_error_return "$(printf 'The install did not complete — see the terminal output.\n\n  %s' "$dest")"
    fi
}

# =============================================================================
#  Action: List
# =============================================================================

_do_list() {
    local listing
    listing="$(_list_installs)"

    if [[ -z "$listing" ]]; then
        wt_info "$MODULE  >  List" "No managed Wine installations found.

Install directory:
  $INSTALL_BASE

Use  Install  to add a Wine build."
        return 0
    fi

    # Build zenity list
    local -a rows=()
    while IFS=$'\t' read -r name version date active; do
        rows+=("$name" "$version" "$date" "$active")
    done <<< "$listing"

    zenity --list \
        --title="$(wt_title "$MODULE  >  Installed Builds")" \
        --text="$(_wt_box "$(printf 'Managed Wine installations in:\n  %s' "$INSTALL_BASE")")" \
        --column="Name" --column="Version" --column="Installed" --column="Active" \
        --width=720 --height=380 \
        "${rows[@]}" || true
}

# =============================================================================
#  Action: Switch active
# =============================================================================

_do_switch() {
    local listing
    listing="$(_list_installs)"

    if [[ -z "$listing" ]]; then
        wt_info "$MODULE  >  Switch" "No managed Wine installations found."
        return 0
    fi

    local -a rows=()
    local first=true
    while IFS=$'\t' read -r name version date active; do
        local pick="FALSE"
        if [[ "$active" == "YES" ]]; then
            pick="TRUE"
        elif $first; then
            pick="TRUE"
            first=false
        fi
        rows+=("$pick" "$name" "$version" "$date" "$active")
    done <<< "$listing"

    local chosen
    chosen=$(zenity --list \
        --title="$(wt_title "$MODULE  >  Switch Active Wine")" \
        --text="$(_wt_box "$(printf 'Select which Wine build to set as the default.\nSymlinks in  %s  will be updated.' "$SYMLINK_DIR")")" \
        --radiolist \
        --column="" --column="Name" --column="Version" --column="Installed" --column="Active" \
        --width=720 --height=380 \
        "${rows[@]}") || return 0

    [[ -n "$chosen" ]] || return 0

    chosen="${chosen%%|*}"
    _set_active "$chosen"
    wt_info "$MODULE" "$(_active_report "$chosen")"
}

# =============================================================================
#  Action: Uninstall
# =============================================================================

_do_uninstall() {
    local listing
    listing="$(_list_installs)"

    if [[ -z "$listing" ]]; then
        wt_info "$MODULE  >  Uninstall" "No managed Wine installations found."
        return 0
    fi

    local -a rows=()
    while IFS=$'\t' read -r name version date active; do
        rows+=("FALSE" "$name" "$version" "$date" "$active")
    done <<< "$listing"

    local chosen
    chosen=$(zenity --list \
        --title="$(wt_title "$MODULE  >  Uninstall")" \
        --text="<tt>Select a Wine build to remove.\nThis will delete the installation directory and any symlinks.</tt>" \
        --checklist \
        --column="" --column="Name" --column="Version" --column="Installed" --column="Active" \
        --width=720 --height=380 \
        "${rows[@]}") || return 0

    [[ -n "$chosen" ]] || return 0

    # chosen may be pipe-separated if multiple selected
    local IFS_ORIG="$IFS"
    IFS='|'
    read -ra selections <<< "$chosen"
    IFS="$IFS_ORIG"

    local names_list=""
    for sel in "${selections[@]}"; do
        names_list+="  $sel\n"
    done

    wt_confirm "$MODULE  >  Confirm Uninstall" \
        "$(printf 'The following Wine builds will be permanently removed:\n\n%b\nThis cannot be undone. Continue?' "$names_list")" || return 0

    local failed=""
    for sel in "${selections[@]}"; do
        local dir="$INSTALL_BASE/$sel"
        if [[ -d "$dir" ]]; then
            _clear_active "$sel"
            wt_safe_rmrf "$dir" bin/wine bin/wine64 "$META_FILE" || failed+="  $sel: $WT_RMRF_ERROR\n"
        fi
    done

    if [[ -n "$failed" ]]; then
        wt_error_return "$(printf 'Some builds could not be removed:\n\n%b' "$failed")"
        return 0
    fi
    wt_ok "$MODULE" "$(printf 'Uninstalling %d Wine build(s):\n%b' "${#selections[@]}" "$names_list")"
}

# =============================================================================
#  Action: Info
# =============================================================================

_do_info() {
    local listing
    listing="$(_list_installs)"

    if [[ -z "$listing" ]]; then
        wt_info "$MODULE  >  Info" "No managed Wine installations found."
        return 0
    fi

    local -a rows=()
    while IFS=$'\t' read -r name version date active; do
        rows+=("$name" "$version" "$date" "$active")
    done <<< "$listing"

    local chosen
    chosen=$(zenity --list \
        --title="$(wt_title "$MODULE  >  Info")" \
        --text="<tt>Select a Wine build to inspect.</tt>" \
        --column="Name" --column="Version" --column="Installed" --column="Active" \
        --print-column=1 \
        --width=720 --height=380 \
        "${rows[@]}") || return 0

    [[ -n "$chosen" ]] || return 0

    local dir="$INSTALL_BASE/$chosen"
    local info_text=""
    info_text+="Name     :  $chosen\n"
    info_text+="Location :  $dir\n"

    if [[ -f "$dir/$META_FILE" ]]; then
        local version date source_info
        version="$(grep '^version=' "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        date="$(grep '^installed=' "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        source_info="$(grep '^source=' "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || echo "unknown")"
        info_text+="Version  :  $version\n"
        info_text+="Installed:  $date\n"
        info_text+="Source   :  $source_info\n"
    fi

    # Disk usage
    local disk_usage
    disk_usage="$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "unknown")"
    info_text+="Disk     :  $disk_usage\n"

    # Active status
    local active_target=""
    if [[ -L "$SYMLINK_DIR/wine" ]]; then
        active_target="$(readlink -f "$SYMLINK_DIR/wine" 2>/dev/null || true)"
    fi
    local this_wine
    this_wine="$(readlink -f "$dir/bin/wine" 2>/dev/null || true)"
    if [[ -n "$active_target" && "$active_target" == "$this_wine" ]]; then
        info_text+="Active   :  YES (symlinked in $SYMLINK_DIR)\n"
    else
        info_text+="Active   :  no\n"
    fi

    info_text+="\n--- Contents ---\n"
    if [[ -d "$dir/bin" ]]; then
        local bin_count
        bin_count="$(find "$dir/bin" -maxdepth 1 -type f -executable 2>/dev/null | wc -l)"
        info_text+="Binaries :  $bin_count files in bin/\n"
    fi
    if [[ -d "$dir/lib" ]]; then
        info_text+="lib/     :  present\n"
    fi
    if [[ -d "$dir/lib64" ]]; then
        info_text+="lib64/   :  present\n"
    fi
    if [[ -d "$dir/share" ]]; then
        info_text+="share/   :  present\n"
    fi

    wt_info "$MODULE  >  $chosen" "$(printf '%b' "$info_text")"
}

# =============================================================================
#  Main menu loop
# =============================================================================

while true; do
    ACTION=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="$(_wt_box "$(printf 'Manage custom Wine installations.\n\nInstall directory:  %s\nSymlink directory:  %s' "$INSTALL_BASE" "$SYMLINK_DIR")")" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=660 --height=380 \
        "install"   "Install Wine Build"    "Install a Wine build from builder output, directory, or archive" \
        "list"      "List Installs"         "Show all managed Wine installations" \
        "switch"    "Switch Active Wine"    "Set which installed Wine is the default" \
        "uninstall" "Uninstall"             "Remove a managed Wine installation" \
        "info"      "Build Info"            "Show details about an installed Wine build" \
        "back"      "< Back"                "") || break

    ACTION="${ACTION%%|*}"
    ACTION="${ACTION//[[:space:]]/}"

    case "$ACTION" in
        install)   _do_install   ;;
        list)      _do_list      ;;
        switch)    _do_switch    ;;
        uninstall) _do_uninstall ;;
        info)      _do_info      ;;
        back|"")   break         ;;
    esac
done
