#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  prefix_manager.sh — Wine Prefix Manager
#  winetoolz v2.0
#  Manage Wine prefixes: browse, delete, backup, restore, regedit,
#  kill wineserver, manage Wine builds.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Prefix Manager"

wt_require_cmds zenity
wt_load_config

# =============================================================================
#  HELPERS
# =============================================================================

# Scan all configured prefix paths and return a list of valid prefixes.
# Each entry: path|arch|wine_version
scan_prefixes() {
    local -a found=()
    local IFS_ORIG="$IFS"
    IFS=':'
    read -ra search_dirs <<< "$WT_PREFIX_PATHS"
    IFS="$IFS_ORIG"

    for dir in "${search_dirs[@]}"; do
        dir="${dir/#\~/$HOME}"
        [[ -d "$dir" ]] || continue

        # Is the dir itself a prefix?
        if [[ -f "$dir/system.reg" ]]; then
            found+=("$dir")
        fi

        # Subdirectory prefixes (one level deep)
        while IFS= read -r reg; do
            found+=("$(dirname "$reg")")
        done < <(find "$dir" -mindepth 2 -maxdepth 2 -name "system.reg" 2>/dev/null | sort)
    done

    printf '%s\n' "${found[@]}"
}

# Given a prefix path, return a short summary string for display
prefix_summary() {
    local p="$1"
    local arch="?"
    local winver="?"

    if [[ -f "$p/system.reg" ]]; then
        grep -qi '#arch=win64' "$p/system.reg" 2>/dev/null && arch="win64" || arch="win32"
        local vline
        vline="$(grep -i '"Version"=' "$p/user.reg" 2>/dev/null | head -1 || true)"
        [[ -n "$vline" ]] && winver="$(echo "$vline" | sed 's/.*="\([^"]*\)".*/\1/')"
    fi

    local size
    size="$(du -sh "$p" 2>/dev/null | cut -f1 || echo "?")"
    printf '%s  [%s / %s / %s]' "$(basename "$p")" "$arch" "$winver" "$size"
}

# Build a zenity radio-list of all found prefixes.
# On success, sets CHOSEN_PREFIX.
pick_prefix() {
    local title_extra="${1:-}"
    local -a plist=()

    mapfile -t plist < <(scan_prefixes)

    if [[ ${#plist[@]} -eq 0 ]]; then
        wt_error "$(printf 'No Wine prefixes found in configured search paths:\n  %s\n\nAdd more paths via:\n  [ winetoolz :: Prefix Manager :: Configure Paths ]' \
            "${WT_PREFIX_PATHS//:/$'\n  '}")"
    fi

    local -a rows=()
    local first=true
    for p in "${plist[@]}"; do
        local pick="FALSE"
        $first && pick="TRUE" && first=false
        rows+=("$pick" "$p" "$(prefix_summary "$p")")
    done
    rows+=(FALSE "Browse..." "Select a prefix not listed above")

    CHOSEN_PREFIX=$(zenity --list \
        --title="$(wt_title "$MODULE${title_extra:+  ›  $title_extra}")" \
        --text="<tt>Select a Wine prefix to act on.</tt>" \
        --radiolist \
        --column="" --column="Path" --column="Details" \
        --hide-column=2 --print-column=2 \
        --width=760 --height=400 \
        "${rows[@]}") || return 1

    if [[ "$CHOSEN_PREFIX" == "Browse..." ]]; then
        CHOSEN_PREFIX=$(zenity --file-selection \
            --directory \
            --title="$(wt_title "$MODULE  ›  Browse for Prefix")" \
            --text="<tt>Select a Wine prefix directory (must contain system.reg).</tt>" \
            --width="$WT_WIDTH") || return 1
    fi

    [[ -f "$CHOSEN_PREFIX/system.reg" ]] || \
        wt_error "$(printf 'Not a valid Wine prefix:\n  %s' "$CHOSEN_PREFIX")"
}

# =============================================================================
#  ACTION: Configure prefix search paths
# =============================================================================

action_configure_paths() {
    local current="${WT_PREFIX_PATHS//:/$'\n'}"
    local new_paths
    new_paths=$(zenity --text-info \
        --title="$(wt_title "$MODULE  ›  Configure Prefix Paths")" \
        --editable \
        --filename=<(printf '%s' "$current") \
        --width=600 --height=320) || return 0

    # Collapse newlines back to colons, strip blanks
    local collapsed
    collapsed="$(echo "$new_paths" | tr '\n' ':' | sed 's/::/:/g; s/^://; s/:$//')"
    [[ -z "$collapsed" ]] && return 0

    wt_config_set "WT_PREFIX_PATHS" "$collapsed"
    wt_info "$MODULE" "$(printf '✔  Prefix search paths updated.\n\n  %s' "${collapsed//:/$'\n  '}")"
}

# =============================================================================
#  ACTION: Delete prefix
# =============================================================================

action_delete() {
    pick_prefix "Delete" || return 0

    wt_confirm "$MODULE  ›  Delete" "$(printf \
        '⚠  PERMANENTLY DELETE this prefix?\n\n  %s\n\n%s\n\nThis cannot be undone.' \
        "$CHOSEN_PREFIX" "$(prefix_summary "$CHOSEN_PREFIX")")" || return 0

    rm -rf "$CHOSEN_PREFIX"
    wt_info "$MODULE" "$(printf '✔  Prefix deleted:\n  %s' "$CHOSEN_PREFIX")"
}

# =============================================================================
#  ACTION: Backup prefix
# =============================================================================

action_backup() {
    pick_prefix "Backup" || return 0

    local pname
    pname="$(basename "$CHOSEN_PREFIX")"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local archive_name="${pname}_${timestamp}.tar.zst"
    local archive_path="$WT_BACKUP_DIR/$archive_name"

    wt_require_cmds zstd

    wt_confirm "$MODULE  ›  Backup" "$(printf \
        'Back up prefix to:\n\n  Source : %s\n  Archive: %s\n\nThis may take a while for large prefixes.' \
        "$CHOSEN_PREFIX" "$archive_path")" || return 0

    mkdir -p "$WT_BACKUP_DIR"

    export WT_CHOSEN_PREFIX="$CHOSEN_PREFIX"
    export WT_ARCHIVE_PATH="$archive_path"
    export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

    local TMP
    TMP=$(mktemp --suffix=.sh)
    trap 'rm -f "$TMP"' RETURN

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Prefix Backup"
wt_log_info "Source  : $WT_CHOSEN_PREFIX"
wt_log_info "Archive : $WT_ARCHIVE_PATH"
printf '\n'

wt_log "Creating backup — this may take a moment..."
tar --use-compress-program=zstd \
    -cf "$WT_ARCHIVE_PATH" \
    -C "$(dirname "$WT_CHOSEN_PREFIX")" \
    "$(basename "$WT_CHOSEN_PREFIX")" \
    && wt_log_ok "Backup complete: $WT_ARCHIVE_PATH" \
    || wt_log_err "Backup failed. Check disk space."

SIZE="$(du -sh "$WT_ARCHIVE_PATH" 2>/dev/null | cut -f1 || echo "?")"
wt_log_info "Archive size: $SIZE"
read -rp "  Press Enter to close..." < /dev/tty
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
}

# =============================================================================
#  ACTION: Restore prefix from backup
# =============================================================================

action_restore() {
    wt_require_cmds zstd

    # Pick backup archive
    local archive
    archive=$(zenity --file-selection \
        --title="$(wt_title "$MODULE  ›  Select Backup Archive")" \
        --text="<tt>Select a  .tar.zst  prefix backup archive.</tt>" \
        --file-filter="Prefix backups | *.tar.zst *.tar.gz" \
        --filename="$WT_BACKUP_DIR/" \
        --width="$WT_WIDTH") || return 0

    [[ -f "$archive" ]] || wt_error "$(printf 'File not found:\n  %s' "$archive")"

    # Pick restore destination
    local dest
    dest=$(zenity --file-selection \
        --directory \
        --title="$(wt_title "$MODULE  ›  Select Restore Destination")" \
        --text="<tt>Select the parent folder to restore the prefix into.\nThe prefix will be extracted as a subfolder here.</tt>" \
        --width="$WT_WIDTH") || return 0

    local archive_base
    archive_base="$(basename "$archive" .tar.zst)"
    archive_base="$(basename "$archive_base" .tar.gz)"
    # Strip timestamp suffix if present (name_YYYYMMDD_HHMMSS → name)
    local prefix_name
    prefix_name="$(echo "$archive_base" | sed 's/_[0-9]\{8\}_[0-9]\{6\}$//')"
    local restore_path="$dest/$prefix_name"

    if [[ -d "$restore_path/drive_c" ]]; then
        wt_confirm "$MODULE  ›  Restore" "$(printf \
            'A prefix already exists at:\n  %s\n\nOverwrite it?' "$restore_path")" || return 0
        rm -rf "$restore_path"
    fi

    wt_confirm "$MODULE  ›  Restore" "$(printf \
        'Restore prefix from backup?\n\n  Archive : %s\n  Dest    : %s' \
        "$archive" "$restore_path")" || return 0

    export WT_ARCHIVE="$archive"
    export WT_RESTORE_DEST="$dest"
    export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

    local TMP
    TMP=$(mktemp --suffix=.sh)
    trap 'rm -f "$TMP"' RETURN

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Prefix Restore"
wt_log_info "Archive : $WT_ARCHIVE"
wt_log_info "Dest    : $WT_RESTORE_DEST"
printf '\n'

wt_log "Extracting — this may take a moment..."

EXT="${WT_ARCHIVE##*.}"
case "$WT_ARCHIVE" in
    *.tar.zst) tar --use-compress-program=zstd -xf "$WT_ARCHIVE" -C "$WT_RESTORE_DEST" ;;
    *.tar.gz)  tar -xzf "$WT_ARCHIVE" -C "$WT_RESTORE_DEST" ;;
    *)         tar -xf  "$WT_ARCHIVE" -C "$WT_RESTORE_DEST" ;;
esac \
    && wt_log_ok "Restore complete." \
    || wt_log_err "Extraction failed. The archive may be corrupted."

read -rp "  Press Enter to close..." < /dev/tty
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
}

# =============================================================================
#  ACTION: Open regedit in prefix
# =============================================================================

action_regedit() {
    pick_prefix "Regedit" || return 0
    wt_select_wine_bin "$MODULE  ›  Regedit" || return 0
    export WINEPREFIX="$CHOSEN_PREFIX"

    export WT_CHOSEN_PREFIX="$CHOSEN_PREFIX"
    export WT_LIB_PATH="$SCRIPT_DIR/../winetoolz-lib.sh"

    local TMP
    TMP=$(mktemp --suffix=.sh)
    trap 'rm -f "$TMP"' RETURN

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
export WINEPREFIX="$WT_CHOSEN_PREFIX"

wt_section "Registry Editor"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
wt_log "Launching regedit..."
"$WT_INNER_WINE" regedit \
    && wt_log_ok "regedit closed." \
    || wt_log_err "regedit exited with an error."
read -rp "  Press Enter to close..." < /dev/tty
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
}

# =============================================================================
#  ACTION: Kill Wine processes for a prefix
# =============================================================================

action_kill_wine() {
    pick_prefix "Kill Wine Processes" || return 0

    wt_confirm "$MODULE  ›  Kill Wine" "$(printf \
        'Kill all Wine processes for:\n  %s\n\n⚠  Any running Wine apps will be terminated immediately.' \
        "$CHOSEN_PREFIX")" || return 0

    export WINEPREFIX="$CHOSEN_PREFIX"
    wineserver -k 2>/dev/null && \
        wt_info "$MODULE" "$(printf '✔  Wine processes killed for:\n  %s' "$CHOSEN_PREFIX")" || \
        wt_error "$(printf 'wineserver -k failed for:\n  %s\n\nIs wineserver in your PATH?' "$CHOSEN_PREFIX")"
}

# =============================================================================
#  ACTION: Wine build manager
# =============================================================================

action_build_manager() {
    local buildz="$HOME/wine-custom/buildz"

    if [[ ! -d "$buildz" ]]; then
        wt_error "$(printf 'Wine build directory not found:\n  %s' "$buildz")"
    fi

    # Scan builds
    local -a builds=()
    while IFS= read -r wine_bin; do
        builds+=("$(dirname "$(dirname "$wine_bin")")")
    done < <(find "$buildz" -maxdepth 3 -name "wine" -path "*/bin/wine" | sort -rV)

    if [[ ${#builds[@]} -eq 0 ]]; then
        wt_info "$MODULE" "$(printf 'No Wine builds found in:\n  %s' "$buildz")"
        return 0
    fi

    # Build display rows
    local -a rows=()
    local first=true
    for b in "${builds[@]}"; do
        local pick="FALSE"
        $first && pick="TRUE" && first=false
        local ver
        ver="$("$b/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
        local size
        size="$(du -sh "$b" 2>/dev/null | cut -f1 || echo "?")"
        rows+=("$pick" "$b" "$(basename "$b")" "$ver" "$size")
    done

    local chosen
    chosen=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Wine Build Manager")" \
        --text="<tt>Wine builds found in  ~/wine-custom/buildz.\nSelect a build to manage it.</tt>" \
        --radiolist \
        --column="" --column="Path" --column="Build Name" --column="Version" --column="Size" \
        --hide-column=2 --print-column=2 \
        --width=820 --height=400 \
        "${rows[@]}") || return 0

    # Action on chosen build
    local build_action
    build_action=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Wine Build  ›  $(basename "$chosen")")" \
        --text="<tt>What would you like to do with this build?\n\n  $(basename "$chosen")\n  $chosen</tt>" \
        --radiolist \
        --column="" --column="Action" --column="Details" \
        TRUE  "Show info"   "Display version, size, and path info" \
        FALSE "Delete build" "Permanently remove this Wine build" \
        --width=580 --height=240) || return 0

    case "$build_action" in
        "Show info")
            local ver
            ver="$("$chosen/bin/wine" --version 2>/dev/null || echo "unknown")"
            local size
            size="$(du -sh "$chosen" 2>/dev/null | cut -f1 || echo "?")"
            wt_info "$MODULE  ›  Build Info" "$(printf \
                'Build    :  %s\nVersion  :  %s\nSize     :  %s\nPath     :  %s' \
                "$(basename "$chosen")" "$ver" "$size" "$chosen")"
            ;;
        "Delete build")
            wt_confirm "$MODULE  ›  Delete Build" "$(printf \
                '⚠  Permanently delete this Wine build?\n\n  %s\n\nThis cannot be undone.' \
                "$chosen")" || return 0
            rm -rf "$chosen"
            wt_info "$MODULE" "$(printf '✔  Build deleted:\n  %s' "$chosen")"
            ;;
    esac
}

# =============================================================================
#  MAIN MENU LOOP
# =============================================================================

while true; do
    ACTION=$(zenity --list \
        --title="$(wt_title "$MODULE")" \
        --text="<tt>Select a prefix management action.</tt>" \
        --column="Tag" --column="Action" --column="Description" \
        --hide-column=1 --print-column=1 \
        --width=700 --height=420 \
        "configure"  "Configure Prefix Paths"   "Add or edit prefix search directories" \
        "delete"     "Delete Prefix"             "Permanently remove a prefix" \
        "backup"     "Backup Prefix"             "Archive a prefix to ~/winetoolz/backups/ as .tar.zst" \
        "restore"    "Restore Prefix"            "Extract a prefix from a backup archive" \
        "regedit"    "Open Regedit"              "Launch regedit in a chosen prefix" \
        "kill"       "Kill Wine Processes"       "Run wineserver -k for a chosen prefix" \
        "builds"     "Wine Build Manager"        "Inspect or delete builds in ~/wine-custom/buildz" \
        "exit"       "Back to Main Menu"         "") || break

    case "$ACTION" in
        configure) action_configure_paths ;;
        delete)    action_delete          ;;
        backup)    action_backup          ;;
        restore)   action_restore         ;;
        regedit)   action_regedit         ;;
        kill)      action_kill_wine       ;;
        builds)    action_build_manager   ;;
        exit|*)    break                  ;;
    esac
done
