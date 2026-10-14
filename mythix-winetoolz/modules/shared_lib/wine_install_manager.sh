#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  wine_install_manager.sh — Wine Install Manager
#  winetoolz v2.1
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

# _set_active <install_name>
#   Points ~/.local/bin/wine, wineserver, wine64, wineboot, winecfg → install
_set_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name"

    local bins=(wine wineserver wine64 wineboot winecfg msiexec notepad regedit regsvr32)
    for b in "${bins[@]}"; do
        # Remove existing symlink if it points into our managed installs
        if [[ -L "$SYMLINK_DIR/$b" ]]; then
            local target
            target="$(readlink -f "$SYMLINK_DIR/$b" 2>/dev/null || true)"
            if [[ "$target" == "$INSTALL_BASE"/* ]] || [[ "$target" == "$dir"/* ]]; then
                rm -f "$SYMLINK_DIR/$b"
            fi
        fi
        # Create new symlink if the binary exists
        if [[ -x "$dir/bin/$b" ]]; then
            ln -sf "$dir/bin/$b" "$SYMLINK_DIR/$b"
        fi
    done
}

# _clear_active <install_name>
#   Removes symlinks that point to the given install
_clear_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name"

    local bins=(wine wineserver wine64 wineboot winecfg msiexec notepad regedit regsvr32)
    for b in "${bins[@]}"; do
        if [[ -L "$SYMLINK_DIR/$b" ]]; then
            local target
            target="$(readlink -f "$SYMLINK_DIR/$b" 2>/dev/null || true)"
            if [[ "$target" == "$dir"/* ]] || [[ "$target" == "$INSTALL_BASE/$name"/* ]]; then
                rm -f "$SYMLINK_DIR/$b"
            fi
        fi
    done
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

    # --- Pick install name ---
    local default_name=""
    if [[ "$src_type" == "tarball" ]]; then
        default_name="$(basename "$source_path" | sed 's/\.tar\.\(gz\|xz\|zst\|bz2\)$//')"
    else
        default_name="$(basename "$source_path")"
    fi

    local install_name
    install_name=$(zenity --entry \
        --title="$(wt_title "$MODULE  >  Install Name")" \
        --text="$(printf '<tt>Choose a name for this Wine installation.\n\nIt will be installed to:\n  %s/&lt;name&gt;/\n\nUse something short and descriptive\n(e.g. wine-10.5-staging, wine-tkg-custom).</tt>' "$INSTALL_BASE")" \
        --entry-text="$default_name" \
        --width="$WT_WIDTH") || return 0

    # Sanitise name
    install_name="${install_name//[^a-zA-Z0-9._-]/_}"

    if [[ -z "$install_name" ]]; then
        wt_error_return "Install name cannot be empty."
        return 0
    fi

    local dest="$INSTALL_BASE/$install_name"

    if [[ -d "$dest" ]]; then
        wt_confirm "$MODULE  >  Overwrite?" \
            "$(printf 'An install named  %s  already exists.\n\nOverwrite it?' "$install_name")" || return 0
        _clear_active "$install_name"
        rm -rf "$dest"
    fi

    # --- Actually install (in terminal for progress) ---
    local TMP
    TMP=$(mktemp --suffix=.sh)
    trap 'rm -f "$TMP"' RETURN

    cat > "$TMP" <<SCRIPT
#!/usr/bin/env bash
set +e
source "$SCRIPT_DIR/../winetoolz-lib.sh"

wt_section "Wine Install Manager  >  Installing"
wt_log_info "Source : $source_path"
wt_log_info "Dest   : $dest"
wt_log_info "Type   : $src_type"
printf '\n'

mkdir -p "$dest"

case "$src_type" in
    builder|directory)
        wt_log "Copying Wine build..."
        if command -v rsync &>/dev/null; then
            rsync -aH --info=progress2 "$source_path/" "$dest/"
        else
            cp -a "$source_path/." "$dest/"
        fi
        ;;
    tarball)
        wt_log "Extracting archive..."
        _tar_log="\$(mktemp)"
        _tar_ok=false

        _try_extract() {
            # Try with --strip-components=1 first (tarballs with a top-level dir),
            # fall back to plain extraction if that fails.
            if tar "\$@" "$source_path" -C "$dest" --strip-components=1 2>"\$_tar_log"; then
                _tar_ok=true
            elif tar "\$@" "$source_path" -C "$dest" 2>"\$_tar_log"; then
                _tar_ok=true
            fi
        }

        case "$source_path" in
            *.tar.zst)
                if ! command -v zstd &>/dev/null; then
                    wt_log_err "zstd is required for .tar.zst archives."
                    wt_log_err "Install it:  sudo apt install zstd"
                    read -rp "  Press Enter to close..." < /dev/tty
                    exit 1
                fi
                _try_extract --use-compress-program=zstd -xf
                ;;
            *.tar.xz)  _try_extract -xJf ;;
            *.tar.bz2) _try_extract -xjf ;;
            *)         _try_extract -xzf ;;
        esac

        if ! \$_tar_ok; then
            wt_log_err "Failed to extract archive:"
            cat "\$_tar_log" >&2
            rm -f "\$_tar_log"
            read -rp "  Press Enter to close..." < /dev/tty
            exit 1
        fi
        rm -f "\$_tar_log"
        ;;
esac

# Fix permissions and ensure binaries are executable
chmod -R u+w,a+rX "$dest"
[[ -d "$dest/bin" ]] && chmod +x "$dest/bin"/* 2>/dev/null || true
chown -R "\$(id -u):\$(id -g)" "$dest" 2>/dev/null || true

# Validate
if [[ ! -x "$dest/bin/wine" && ! -x "$dest/bin/wine64" ]]; then
    wt_log_err "Installation failed — no wine binary found in $dest/bin/"
    wt_log_err "The archive may have an unexpected structure."
    if [[ -d "$dest/bin" ]]; then
        wt_log_err "Contents of bin/:"
        ls -la "$dest/bin/" 2>/dev/null || true
    else
        wt_log_err "No bin/ directory found. Top-level contents:"
        ls -la "$dest/" 2>/dev/null || true
    fi
    read -rp "  Press Enter to close..." < /dev/tty
    exit 1
fi

wt_log_ok "Wine build installed to: $dest"

# Write metadata
version="unknown"
[[ -x "$dest/bin/wine" ]] && version="\$("$dest/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
cat > "$dest/$META_FILE" <<META
name=$install_name
version=\$version
source=$source_desc
installed=\$(date '+%Y-%m-%d %H:%M')
META

wt_log_ok "Metadata written."

# Offer to set as active
printf '\n'
wt_log_info "Version: \$version"
wt_log_info "Location: $dest"

wt_section "Done!"
read -rp "  Press Enter to close..." < /dev/tty
SCRIPT
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"

    # After install, offer to set as active
    if [[ -d "$dest" && ( -x "$dest/bin/wine" || -x "$dest/bin/wine64" ) ]]; then
        _write_meta "$dest" "$source_desc"
        wt_confirm "$MODULE  >  Set Active?" \
            "$(printf 'Set  %s  as the active Wine?\n\nThis will create symlinks in:\n  %s\n\nSo that running \"wine\" uses this build.' "$install_name" "$SYMLINK_DIR")" \
            && _set_active "$install_name"
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
        --text="<tt>Managed Wine installations in:\n  $INSTALL_BASE</tt>" \
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
        --text="<tt>Select which Wine build to set as the default.\nSymlinks in  $SYMLINK_DIR  will be updated.</tt>" \
        --radiolist \
        --column="" --column="Name" --column="Version" --column="Installed" --column="Active" \
        --width=720 --height=380 \
        "${rows[@]}") || return 0

    [[ -n "$chosen" ]] || return 0

    _set_active "$chosen"
    wt_ok "$MODULE" "$(printf 'Switched active Wine to:  %s\n\nSymlinks updated in:\n  %s' "$chosen" "$SYMLINK_DIR")"
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

    for sel in "${selections[@]}"; do
        local dir="$INSTALL_BASE/$sel"
        if [[ -d "$dir" ]]; then
            _clear_active "$sel"
            rm -rf "$dir"
        fi
    done

    wt_ok "$MODULE" "$(printf 'Uninstalled %d Wine build(s).\n\nRemoved:\n%b' "${#selections[@]}" "$names_list")"
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
        --text="<tt>Manage custom Wine installations.\n\nInstall directory:  $INSTALL_BASE\nSymlink directory:  $SYMLINK_DIR</tt>" \
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
