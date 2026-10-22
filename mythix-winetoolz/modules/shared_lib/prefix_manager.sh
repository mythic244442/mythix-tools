#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  prefix_manager.sh — Wine Prefix Manager
#  winetoolz v3.0
#  Manage Wine prefixes: browse, delete, backup, restore, regedit,
#  kill wineserver, manage Wine builds.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../winetoolz-lib.sh"

MODULE="Prefix Manager"
BUILDZ="$HOME/wine-custom/buildz"

wt_require_cmds zenity
wt_load_config

# =============================================================================
#  HELPERS
# =============================================================================

# Given a prefix path, return a short summary string for display
prefix_summary() {
    local p="$1" arch winver size
    arch="$(wt_prefix_arch "$p")"
    winver="$(wt_reg_value "$p/user.reg" 'Software\Wine' Version)"
    [[ -n "$winver" ]] || winver="$(wt_reg_value "$p/system.reg" 'Software\Microsoft\Windows NT\CurrentVersion' ProductName)"
    size="$(du -sh "$p" 2>/dev/null | cut -f1 || echo "?")"
    printf '%s  [%s / %s / %s]' "$(basename "$p")" "$arch" "${winver:-?}" "${size:-?}"
}

# pick_prefix <title_extra>
#   Every known prefix (configured paths, Mythix and Steam games, Bottles,
#   Heroic, the last one used) plus Browse.... On success, sets CHOSEN_PREFIX.
pick_prefix() {
    wt_select_prefix_from_config "$MODULE${1:+  ›  $1}" || return 1
    CHOSEN_PREFIX="$WINEPREFIX"
}

# _managed_note — a warning line for prefixes Steam or the launcher own.
_managed_note() {
    case "${WT_PREFIX_SOURCE:-}" in
        Steam)  printf '\n\n⚠  This is a Steam game prefix. Saves kept inside it\n   (Documents, AppData) are lost unless Steam Cloud has them.\n   Steam / Proton create a fresh prefix at the next launch.' ;;
        Mythix) printf '\n\n⚠  This prefix belongs to a Mythix launcher game. Saves kept\n   inside it (Documents, AppData) are lost with it.' ;;
    esac
}

# =============================================================================
#  ACTION: Configure prefix search paths
# =============================================================================

action_configure_paths() {
    local current="${WT_PREFIX_PATHS//:/$'\n'}"
    local new_paths
    new_paths=$(zenity --text-info \
        --title="$(wt_title "$MODULE  ›  Configure Prefix Paths  (one folder per line)")" \
        --editable \
        --filename=<(printf '%s\n' "$current") \
        --width=600 --height=320) || return 0

    # One folder per line → colon-separated, blanks dropped, ~ expanded
    local line collapsed=""
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        line="$(_wt_cfg_expand "$line")"
        collapsed+="${collapsed:+:}$line"
    done <<< "$new_paths"
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
        '⚠  PERMANENTLY DELETE this prefix?\n\n  %s\n\n%s%s\n\nThis cannot be undone.' \
        "$CHOSEN_PREFIX" "$(prefix_summary "$CHOSEN_PREFIX")" "$(_managed_note)")" || return 0

    wt_kill_prefix "$CHOSEN_PREFIX" || true
    if wt_safe_rmrf "$CHOSEN_PREFIX" system.reg; then
        wt_info "$MODULE" "$(printf '✔  Prefix deleted:\n  %s' "$CHOSEN_PREFIX")"
        if [[ "${WT_LAST_PREFIX:-}" == "$CHOSEN_PREFIX" ]]; then
            wt_config_set WT_LAST_PREFIX "" 2>/dev/null || true
        fi
    else
        wt_error_return "$WT_RMRF_ERROR"
    fi
}

# =============================================================================
#  ACTION: Backup prefix
# =============================================================================

action_backup() {
    pick_prefix "Backup" || return 0

    local pname
    pname="$(basename "$CHOSEN_PREFIX")"
    # A Steam/Mythix prefix is called "pfx": name the backup after the game.
    if [[ "$pname" == pfx ]]; then
        pname="$(_wt_safe_name "${WT_PREFIX_LABEL:-$(basename "$(dirname "$CHOSEN_PREFIX")")}")"
    fi
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local archive_name="${pname}_${timestamp}.tar.zst"
    local archive_path="$WT_BACKUP_DIR/$archive_name"

    wt_require_cmds zstd

    local running=""
    wt_prefix_running "$CHOSEN_PREFIX" && running=$'\n\n⚠  Wine is running in this prefix — close the game first\n   for a consistent backup.'
    wt_confirm "$MODULE  ›  Backup" "$(printf \
        'Back up prefix to:\n\n  Source : %s\n  Archive: %s\n\nThis may take a while for large prefixes.%s' \
        "$CHOSEN_PREFIX" "$archive_path" "$running")" || return 0

    mkdir -p "$WT_BACKUP_DIR"

    export WT_CHOSEN_PREFIX="$CHOSEN_PREFIX"
    export WT_ARCHIVE_PATH="$archive_path"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Prefix Backup"
wt_log_info "Source  : $WT_CHOSEN_PREFIX"
wt_log_info "Archive : $WT_ARCHIVE_PATH"
printf '\n'

# Written as .partial and only renamed once the archive reads back — a
# full disk or a crash never leaves a truncated file that looks like a backup.
PART="$WT_ARCHIVE_PATH.partial"
wt_log "Creating backup — this may take a moment..."
if tar --use-compress-program=zstd -cf "$PART" \
        -C "$(dirname "$WT_CHOSEN_PREFIX")" "$(basename "$WT_CHOSEN_PREFIX")" \
   && wt_log "Verifying the archive..." \
   && tar --use-compress-program=zstd -tf "$PART" >/dev/null \
   && mv -f "$PART" "$WT_ARCHIVE_PATH"; then
    wt_log_ok "Backup complete: $WT_ARCHIVE_PATH"
    wt_log_info "Archive size: $(du -sh "$WT_ARCHIVE_PATH" 2>/dev/null | cut -f1)"
    rc=0
else
    rm -f "$PART"
    wt_log_err "Backup failed (disk full or unreadable files?) — nothing was kept."
    rc=1
fi
wt_pause
exit "$rc"
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"

    if [[ "$WT_TERMINAL_RC" == 0 && -f "$archive_path" ]]; then
        wt_ok "$MODULE" "$(printf 'Backup to %s' "$archive_path")"
    else
        wt_error_return "$(printf 'The backup did not complete.\n\n  %s' "$CHOSEN_PREFIX")"
    fi
}

# =============================================================================
#  ACTION: Restore prefix from backup
# =============================================================================

action_restore() {
    wt_require_cmds zstd

    # Pick backup archive
    local archive
    archive=$(zenity --file-selection \
        --title="$(wt_title "$MODULE  ›  Select a prefix backup (.tar.zst)")" \
        --file-filter="Prefix backups | *.tar.zst *.tar.gz *.tar.xz" \
        --filename="$WT_BACKUP_DIR/" \
        --width="$WT_WIDTH") || return 0

    [[ -f "$archive" ]] || { wt_error_return "$(printf 'File not found:\n  %s' "$archive")"; return 0; }

    # The prefix folder name comes from inside the archive (its first entry),
    # not from the file name — a renamed backup still restores what it holds.
    local kind flags first prefix_name
    kind="$(_wt_archive_kind "$archive")"
    flags="$(_wt_tar_flags "$kind")"
    # shellcheck disable=SC2086
    first="$(tar $flags -tf "$archive" 2>/dev/null | head -n 1)" || true
    prefix_name="${first%%/*}"
    if [[ -z "$prefix_name" || "$prefix_name" == "." || "$prefix_name" == ".." ]]; then
        wt_error_return "$(printf 'This does not look like a winetoolz prefix backup:\n  %s' "$archive")"
        return 0
    fi

    # Pick restore destination
    local dest
    dest=$(zenity --file-selection \
        --directory \
        --title="$(wt_title "$MODULE  ›  Folder to restore  $prefix_name  into")" \
        --width="$WT_WIDTH") || return 0
    dest="${dest%/}"

    local restore_path="$dest/$prefix_name"
    local replace_note=""
    if [[ -e "$restore_path" ]]; then
        if [[ ! -f "$restore_path/system.reg" ]]; then
            wt_error_return "$(printf '%s already exists and is not a Wine prefix.\nChoose another folder.' "$restore_path")"
            return 0
        fi
        replace_note=$'\n\n⚠  The existing prefix there is REPLACED. It is kept until\n   the backup has been fully extracted, then deleted.'
    fi

    wt_confirm "$MODULE  ›  Restore" "$(printf \
        'Restore prefix from backup?\n\n  Archive : %s\n  Prefix  : %s%s' \
        "$archive" "$restore_path" "$replace_note")" || return 0

    if [[ -e "$restore_path" ]]; then
        wt_kill_prefix "$restore_path" || true
    fi

    export WT_ARCHIVE="$archive"
    export WT_RESTORE_DEST="$dest"
    export WT_RESTORE_NAME="$prefix_name"

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Prefix Restore"
wt_log_info "Archive : $WT_ARCHIVE"
wt_log_info "Prefix  : $WT_RESTORE_DEST/$WT_RESTORE_NAME"
printf '\n'

TARGET="$WT_RESTORE_DEST/$WT_RESTORE_NAME"
STAGE="$(mktemp -d "$WT_RESTORE_DEST/.wt-restore.XXXXXX")" || { wt_log_err "Cannot write to $WT_RESTORE_DEST"; wt_pause; exit 1; }

wt_log "Extracting — this may take a moment..."
# Straight GNU tar into a fresh staging folder: it already drops leading /
# and refuses .. members, and prefixes legitimately hold links of their own
# (dosdevices/c: → ../drive_c, z: → /). One pass, however big the backup.
FLAGS="$(_wt_tar_flags "$(_wt_archive_kind "$WT_ARCHIVE")")"
# shellcheck disable=SC2086
if ! tar $FLAGS -xf "$WT_ARCHIVE" -C "$STAGE" --no-same-owner; then
    wt_log_err "Extraction failed. The archive may be corrupted. Nothing was changed."
    rm -rf -- "$STAGE"
    wt_pause
    exit 1
fi
if [[ ! -f "$STAGE/$WT_RESTORE_NAME/system.reg" ]]; then
    wt_log_err "The archive does not contain a Wine prefix ($WT_RESTORE_NAME/system.reg). Nothing was changed."
    rm -rf -- "$STAGE"
    wt_pause
    exit 1
fi

OLD=""
if [[ -e "$TARGET" ]]; then
    OLD="$STAGE/previous"
    mv -- "$TARGET" "$OLD" || { wt_log_err "Could not move the existing prefix aside."; rm -rf -- "$STAGE"; wt_pause; exit 1; }
fi
if ! mv -- "$STAGE/$WT_RESTORE_NAME" "$TARGET"; then
    wt_log_err "Could not move the restored prefix into place."
    [[ -n "$OLD" ]] && mv -- "$OLD" "$TARGET" && wt_log_info "The previous prefix was put back."
    rm -rf -- "$STAGE"
    wt_pause
    exit 1
fi
rm -rf -- "$STAGE"
wt_log_ok "Restore complete: $TARGET"
wt_pause
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"

    if [[ "$WT_TERMINAL_RC" == 0 ]]; then
        wt_config_set WT_LAST_PREFIX "$restore_path" 2>/dev/null || true
        wt_ok "$MODULE" "$(printf 'Restore to %s' "$restore_path")"
    else
        wt_error_return "$(printf 'The restore did not complete — see the terminal output.\nAny existing prefix was left as it was.')"
    fi
}

# =============================================================================
#  ACTION: Open regedit in prefix
# =============================================================================

action_regedit() {
    pick_prefix "Regedit" || return 0
    wt_select_wine_bin "$MODULE  ›  Regedit" || return 0
    export WINEPREFIX="$CHOSEN_PREFIX" WT_INNER_WINE

    local TMP
    TMP=$(mktemp --suffix=.sh)

    cat <<'EOF' > "$TMP"
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"

wt_section "Registry Editor"
wt_log_info "Wine   : $WT_INNER_WINE"
wt_log_info "Prefix : $WINEPREFIX"
wt_log "Launching regedit..."
"$WT_INNER_WINE" regedit \
    && wt_log_ok "regedit closed." \
    || wt_log_err "regedit exited with an error."
wt_pause
EOF
    chmod +x "$TMP"
    wt_run_in_terminal "$TMP"
    rm -f "$TMP"
}

# =============================================================================
#  ACTION: Kill Wine processes for a prefix
# =============================================================================

action_kill_wine() {
    pick_prefix "Kill Wine Processes" || return 0

    if ! wt_prefix_running "$CHOSEN_PREFIX"; then
        wt_info "$MODULE" "$(printf 'No Wine processes are running in:\n  %s' "$CHOSEN_PREFIX")"
        return 0
    fi

    wt_confirm "$MODULE  ›  Kill Wine" "$(printf \
        'Kill all Wine processes for:\n  %s\n\n⚠  Any running Wine apps will be terminated immediately.' \
        "$CHOSEN_PREFIX")" || return 0

    wt_kill_prefix "$CHOSEN_PREFIX" || true
    if wt_prefix_running "$CHOSEN_PREFIX"; then
        wt_error_return "$(printf 'Wine is still running in:\n  %s' "$CHOSEN_PREFIX")"
    else
        wt_info "$MODULE" "$(printf '✔  Wine processes killed for:\n  %s' "$CHOSEN_PREFIX")"
    fi
}

# =============================================================================
#  ACTION: Wine build manager
# =============================================================================

# _list_builds — the builds directly inside ~/wine-custom/buildz (never the
# folder itself), one per line.
_list_builds() {
    local d
    shopt -s nullglob
    for d in "$BUILDZ"/*/; do
        d="${d%/}"
        if _wt_wrapper_in "$d" >/dev/null || _wt_find_inner_wine "$d" >/dev/null; then
            printf '%s\n' "$d"
        fi
    done | sort -rV
    shopt -u nullglob
}

action_build_manager() {
    if [[ ! -d "$BUILDZ" ]]; then
        wt_info "$MODULE" "$(printf 'Wine build directory not found:\n  %s\n\nThe Runtime Manager (Wine menu) downloads builds into it.' "$BUILDZ")"
        return 0
    fi

    # Scan builds
    local -a builds=()
    mapfile -t builds < <(_list_builds)

    if [[ ${#builds[@]} -eq 0 ]]; then
        wt_info "$MODULE" "$(printf 'No Wine builds found in:\n  %s' "$BUILDZ")"
        return 0
    fi

    # Build display rows
    local -a rows=()
    local b pick="TRUE" inner ver size
    for b in "${builds[@]}"; do
        inner="$(_wt_find_inner_wine "$b" || true)"
        ver="$(wt_wine_version "$inner" "$b")"
        size="$(du -sh "$b" 2>/dev/null | cut -f1 || echo "?")"
        rows+=("$pick" "$b" "$(basename "$b")" "$ver" "$size")
        pick="FALSE"
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
    chosen="${chosen%%|*}"
    [[ -n "$chosen" && "$chosen" == "$BUILDZ"/* ]] || return 0

    # Action on chosen build
    local build_action
    build_action=$(zenity --list \
        --title="$(wt_title "$MODULE  ›  Wine Build  ›  $(basename "$chosen")")" \
        --text="$(_wt_box "$(printf 'What would you like to do with this build?\n\n  %s\n  %s' "$(basename "$chosen")" "$chosen")")" \
        --radiolist \
        --column="" --column="Action" --column="Details" \
        TRUE  "Show info"   "Display version, size, and path info" \
        FALSE "Delete build" "Permanently remove this Wine build" \
        --width=580 --height=240) || return 0

    case "$build_action" in
        "Show info")
            inner="$(_wt_find_inner_wine "$chosen" || true)"
            size="$(du -sh "$chosen" 2>/dev/null | cut -f1 || echo "?")"
            wt_info "$MODULE  ›  Build Info" "$(printf \
                'Build    :  %s\nVersion  :  %s\nType     :  %s\nSize     :  %s\nPath     :  %s' \
                "$(basename "$chosen")" "$(wt_wine_version "$inner" "$chosen")" \
                "$(_wt_wrapper_in "$chosen" >/dev/null && echo "Proton-style tool" || echo "Wine build")" \
                "$size" "$chosen")"
            ;;
        "Delete build")
            wt_confirm "$MODULE  ›  Delete Build" "$(printf \
                '⚠  Permanently delete this Wine build?\n\n  %s\n\nThis cannot be undone.' \
                "$chosen")" || return 0
            if wt_safe_rmrf "$chosen" proton bin/wine bin/wine64 files/bin/wine dist/bin/wine; then
                wt_info "$MODULE" "$(printf '✔  Build deleted:\n  %s' "$chosen")"
            else
                wt_error_return "$WT_RMRF_ERROR"
            fi
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
        "backup"     "Backup Prefix"             "Archive a prefix as .tar.zst into the backups folder" \
        "restore"    "Restore Prefix"            "Extract a prefix from a backup archive" \
        "regedit"    "Open Regedit"              "Launch regedit in a chosen prefix" \
        "kill"       "Kill Wine Processes"       "Stop every Wine process of a chosen prefix" \
        "builds"     "Wine Build Manager"        "Inspect or delete builds in ~/wine-custom/buildz" \
        "exit"       "Back to Main Menu"         "") || break
    ACTION="${ACTION%%|*}"

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
