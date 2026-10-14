#!/usr/bin/env bash
# =============================================================================
#  winetoolz-lib.sh — Shared Library
#  Source this file at the top of every winetoolz module:
#    source "$(dirname "$0")/../winetoolz-lib.sh"
# =============================================================================

# --- BRANDING ---
WT_TITLE="winetoolz"
WT_VERSION="2.1"
WT_WIDTH=560

# =============================================================================
#  DIALOG HELPERS
# =============================================================================

# wt_title <module_name>
#   Returns a formatted window title string.
wt_title() {
    printf '[ %s :: %s ]' "$WT_TITLE" "$1"
}

# wt_error <message>
#   Show a zenity error dialog and exit 1.
wt_error() {
    local msg="$1"
    zenity --error \
        --title="$(wt_title "Error")" \
        --width="$WT_WIDTH" \
        --text="$(printf '<tt>⚠  ERROR\n─────────────────────────────────────\n%s</tt>' "$msg")"
    exit 1
}

# wt_error_return <message>
#   Show a zenity error dialog but return instead of exiting (use inside loops).
wt_error_return() {
    local msg="$1"
    zenity --error \
        --title="$(wt_title "Error")" \
        --width="$WT_WIDTH" \
        --text="$(printf '<tt>⚠  ERROR\n─────────────────────────────────────\n%s</tt>' "$msg")"
}

# wt_info <title_suffix> <message>
#   Show a zenity info dialog.
wt_info() {
    local suffix="$1"
    local msg="$2"
    zenity --info \
        --title="$(wt_title "$suffix")" \
        --width="$WT_WIDTH" \
        --text="$(printf '<tt>%s</tt>' "$msg")"
}

# wt_confirm <title_suffix> <message>
#   Show a yes/no confirmation dialog. Returns 0 for yes, 1 for no.
wt_confirm() {
    local suffix="$1"
    local msg="$2"
    zenity --question \
        --title="$(wt_title "$suffix")" \
        --width="$WT_WIDTH" \
        --text="$(printf '<tt>%s</tt>' "$msg")"
}

# wt_ok <module_name> <operation>
#   Show a standardised success dialog.
wt_ok() {
    local module="$1"
    local op="$2"
    wt_info "$module" "$(printf '✔  COMPLETE\n─────────────────────────────────────\n%s finished successfully.' "$op")"
}

# wt_progress_pulse <title_suffix> <label>
#   Open a pulsing progress bar. Feed it lines on stdin; it closes on EOF.
wt_progress_pulse() {
    local suffix="$1"
    local label="$2"
    zenity --progress \
        --title="$(wt_title "$suffix")" \
        --text="<tt>$label</tt>" \
        --width="$WT_WIDTH" \
        --pulsate \
        --auto-close \
        --no-cancel
}

# =============================================================================
#  WINE / PROTON BINARY RESOLUTION
# =============================================================================

# wt_resolve_wine <raw_bin_path>
#   Resolves a Proton wrapper, Proton inner wine, or plain Wine binary.
#   On success, exports:
#     WT_INNER_WINE  — the actual wine executable
#     WT_WRAPPER     — the proton wrapper (empty if plain Wine)
#   On failure, calls wt_error and exits.
wt_resolve_wine() {
    local raw="$1"
    WT_INNER_WINE=""
    WT_WRAPPER=""

    if [[ ! -x "$raw" ]]; then
        wt_error "$(printf 'Binary is not executable or does not exist:\n  %s\n\nMake sure you selected the correct file.' "$raw")"
    fi

    # --- Proton wrapper (file named 'proton') ---
    if [[ "$(basename "$raw")" == "proton" ]]; then
        WT_WRAPPER="$raw"
        local root
        root="$(dirname "$raw")"

        # Search common Proton layout variants for the inner wine binary.
        # Covers: standard GE-Proton (dist/bin/), minimal builds (bin/),
        # and newer hotfix/bleeding-edge forks (files/bin/).
        # wine64 variants are tried after wine for each prefix.
        local inner_wine_found=""
        local candidate
        for candidate in \
            dist/bin/wine  dist/bin/wine64 \
            bin/wine       bin/wine64      \
            files/bin/wine files/bin/wine64
        do
            if [[ -x "$root/$candidate" ]]; then
                inner_wine_found="$root/$candidate"
                break
            fi
        done

        if [[ -n "$inner_wine_found" ]]; then
            WT_INNER_WINE="$inner_wine_found"
        else
            wt_error "$(printf 'Found Proton wrapper at:\n  %s\n\nBut could not locate the inner wine binary.\nSearched:\n  dist/bin/wine[64]  bin/wine[64]  files/bin/wine[64]' "$raw")"
        fi

    # --- Proton inner wine (already pointing at the wine binary inside a Proton dir) ---
    # Matches: .../dist/bin/wine[64]  .../bin/wine[64]  .../files/bin/wine[64]
    elif [[ "$raw" =~ /(dist|bin|files)/bin/wine(64)?$ ]]; then
        WT_INNER_WINE="$raw"
        local root
        # Walk up to the Proton root (two levels above the wine binary's bin dir,
        # or three for files/bin — use the dirname that contains 'proton').
        root="$(dirname "$(dirname "$raw")")"
        [[ -x "$root/proton" ]] || root="$(dirname "$root")"
        [[ -x "$root/proton" ]] && WT_WRAPPER="$root/proton"

    # --- Plain Wine binary ---
    else
        WT_INNER_WINE="$raw"
    fi

    if [[ ! -x "$WT_INNER_WINE" ]]; then
        wt_error "$(printf 'Resolved wine binary is not executable:\n  %s' "$WT_INNER_WINE")"
    fi

    export WT_INNER_WINE WT_WRAPPER
}

# wt_select_wine_bin <module_name>
#   Scans well-known locations for Wine / Proton builds, builds a radio-list,
#   pre-selects the first found, and offers a "Custom..." browse fallback.
#   Exports WT_INNER_WINE and WT_WRAPPER on success.
#
#   Search order:
#     1. ~/wine-custom/buildz/*/bin/wine       (custom Wine builds)
#     2. ~/.steam/debian-installation/         (Proton-GE / compat tools)
#            compatibilitytools.d/*/proton
#     3. wine / wine64 on $PATH               (system / distro Wine)
#     4. Custom...                             (manual browse)
wt_select_wine_bin() {
    local module="${1:-Wine Binary}"

    local -a rows=()
    local default_set=""

    # Deduplication: track paths already added
    local -a seen_paths=()

    _wt_seen() {
        local p="$1"
        local s
        for s in "${seen_paths[@]:-}"; do
            [[ "$s" == "$p" ]] && return 0
        done
        return 1
    }

    _wt_add_candidate() {
        local path="$1"
        local desc="$2"
        [[ -x "$path" ]] || return 0
        _wt_seen "$path" && return 0
        seen_paths+=("$path")
        local ver
        ver="$("$path" --version 2>/dev/null | head -1 || echo "version unknown")"
        local pick="FALSE"
        [[ -z "$default_set" ]] && pick="TRUE" && default_set=1
        rows+=("$pick" "$path" "$desc  —  $ver")
    }

    # ------------------------------------------------------------------
    # 1. Custom Wine builds under ~/wine-custom/buildz/
    # ------------------------------------------------------------------
    local buildz="$HOME/wine-custom/buildz"
    if [[ -d "$buildz" ]]; then
        # Sort by directory name descending (newest build name last alphabetically
        # tends to be newest; reverse so newest is first)
        while IFS= read -r wine_bin; do
            local build_name
            build_name="$(basename "$(dirname "$(dirname "$wine_bin")")")"
            _wt_add_candidate "$wine_bin" "Custom build  $build_name"
        done < <(find "$buildz" -maxdepth 3 -name "wine" -path "*/bin/wine" | sort -rV)
    fi

    # ------------------------------------------------------------------
    # 2. Steam compatibility tools (Proton-GE etc.)
    #    ~/.steam/debian-installation/compatibilitytools.d/*/proton
    # ------------------------------------------------------------------
    local compat_dir="$HOME/.steam/debian-installation/compatibilitytools.d"
    if [[ -d "$compat_dir" ]]; then
        while IFS= read -r proton_bin; do
            local tool_name
            tool_name="$(basename "$(dirname "$proton_bin")")"
            _wt_add_candidate "$proton_bin" "Proton  $tool_name"
        done < <(find "$compat_dir" -maxdepth 2 -name "proton" | sort -rV)
    fi

    # ------------------------------------------------------------------
    # 3. System wine / wine64 on $PATH
    # ------------------------------------------------------------------
    local w
    for w in wine wine64; do
        local found
        found="$(command -v "$w" 2>/dev/null || true)"
        [[ -n "$found" ]] && _wt_add_candidate "$found" "System  $w"
    done

    # ------------------------------------------------------------------
    # 4. Custom browse fallback
    # ------------------------------------------------------------------
    local custom_pick="FALSE"
    [[ -z "$default_set" ]] && custom_pick="TRUE"
    rows+=("$custom_pick" "Custom..." "Browse for a Wine / Proton binary")

    # ------------------------------------------------------------------
    # Show radio-list
    # ------------------------------------------------------------------
    local chosen
    chosen=$(zenity --list \
        --title="$(wt_title "$module  ›  Select Wine / Proton Binary")" \
        --text="<tt>Choose a Wine or Proton binary.\nDetected installs are listed below — select  Custom...  to browse.</tt>" \
        --radiolist \
        --column="" --column="Path" --column="Details" \
        --width=780 --height=340 \
        "${rows[@]}") || return 1

    if [[ "$chosen" == "Custom..." ]]; then
        chosen=$(zenity --file-selection \
            --title="$(wt_title "$module  ›  Browse for Wine / Proton Binary")" \
            --text="<tt>Select a Proton wrapper  ('proton'),\na Proton inner wine  ('.../dist/bin/wine'),\nor a standard Wine binary.</tt>" \
            --width="$WT_WIDTH") || return 1
    fi

    wt_resolve_wine "$chosen"
}



# =============================================================================
#  PREFIX HELPERS
# =============================================================================

# wt_select_prefix <module_name>
#   Opens a directory-picker for WINEPREFIX selection.
#   Validates that system.reg exists.
#   On success, exports WINEPREFIX.
wt_select_prefix() {
    local module="${1:-Select Prefix}"
    local path

    path=$(zenity --file-selection \
        --directory \
        --title="$(wt_title "$module  ›  Select WINEPREFIX")" \
        --text="<tt>Select the Wine prefix directory to use.\nA valid prefix contains a  system.reg  file.</tt>" \
        --width="$WT_WIDTH") || return 1

    if [[ ! -f "$path/system.reg" ]]; then
        wt_error "$(printf 'Not a valid Wine prefix:\n  %s\n\nA valid prefix must contain a system.reg file.\nCreate one first via:  [ winetoolz :: Prefix :: Create Prefix ]' "$path")"
    fi

    if [[ ! -f "$path/drive_c/windows/system32/wineboot.exe" ]]; then
        wt_error "$(printf 'Prefix appears uninitialised or broken:\n  %s\n\nwineboot.exe is missing from system32.\nThis prefix was likely never properly created.\n\nPlease create a fresh prefix via:\n  [ winetoolz :: Prefix :: Create Prefix ]' "$path")"
    fi

    export WINEPREFIX="$path"
}

# wt_is_win64 <prefix_path>
#   Returns 0 (true) if the prefix is 64-bit, 1 otherwise.
wt_is_win64() {
    [[ -d "$1/drive_c/windows/syswow64" ]]
}

# =============================================================================
#  TERMINAL LAUNCHER
# =============================================================================

# wt_run_in_terminal <script_path>
#   Launches a bash script in the best available terminal emulator.
wt_run_in_terminal() {
    local script="$1"

    if command -v konsole &>/dev/null; then
        konsole -e bash "$script"
    elif command -v gnome-terminal &>/dev/null; then
        # gnome-terminal forks and returns immediately — wait on it explicitly
        gnome-terminal --wait -- bash "$script"
    elif command -v xfce4-terminal &>/dev/null; then
        xfce4-terminal --hold -e "bash '$script'"
    elif command -v xterm &>/dev/null; then
        xterm -e bash "$script"
    else
        wt_error "$(printf 'No supported terminal emulator was found.\n\nPlease install one of the following:\n  konsole, gnome-terminal, xfce4-terminal, xterm\n\nOr run the script manually:\n  bash %s' "$script")"
    fi
}

# =============================================================================
#  DEPENDENCY CHECK
# =============================================================================

# wt_require_cmds <cmd1> <cmd2> ...
#   Checks that all listed commands exist. Calls wt_error if any are missing.
wt_require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        wt_error "$(printf 'The following required tools are missing:\n\n  %s\n\nInstall them with:\n  sudo apt install %s' \
            "$(printf '  %s\n' "${missing[@]}")" \
            "${missing[*]}")"
    fi
}

# =============================================================================
#  TERMINAL OUTPUT FORMATTING
# =============================================================================

wt_log()     { printf '\n[  ....  ] %s\n' "$*"; }
wt_log_ok()  { printf '[   OK   ] %s\n' "$*"; }
wt_log_err() { printf '[  ERR   ] %s\n' "$*" >&2; }
wt_log_info(){ printf '[  INFO  ] %s\n' "$*"; }

wt_section() {
    printf '\n'
    printf '══════════════════════════════════════════════════\n'
    printf '  %s\n' "$*"
    printf '══════════════════════════════════════════════════\n'
}

# =============================================================================
#  GITHUB RELEASE AUTO-DOWNLOADER
# =============================================================================

# Base directory where DXVK / VKD3D-Proton / DXVK-NVAPI releases are stored.
WT_RELEASE_BASE="${HOME}/winetoolz/dxvk-vkd3d_proton-files"

# wt_ensure_release <tool_key> <github_repo> <asset_pattern>
#
#   Ensures a release for <tool_key> is present under $WT_RELEASE_BASE/<tool_key>/.
#   If a release directory already exists, asks the user whether to reuse it or
#   re-download the latest.  On success, exports WT_DLL_ROOT pointing at the
#   extracted release directory (the folder that contains x64/ x32/ etc.).
#
#   Arguments:
#     tool_key       — short name used as the subdirectory  (e.g. "dxvk")
#     github_repo    — owner/repo on GitHub                 (e.g. "doitsujin/dxvk")
#     asset_pattern  — grep pattern to match the tarball    (e.g. "dxvk-[0-9]")
#
#   Requires: curl, tar, zenity
#
wt_ensure_release() {
    local tool_key="$1"
    local github_repo="$2"
    local asset_pattern="$3"

    local store_dir="$WT_RELEASE_BASE/$tool_key"
    local api_url="https://api.github.com/repos/${github_repo}/releases/latest"

    wt_require_cmds curl tar

    mkdir -p "$store_dir"

    # --- Check for an existing extracted release ---
    local existing_dir=""
    existing_dir="$(find "$store_dir" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"

    if [[ -n "$existing_dir" ]]; then
        local existing_name
        existing_name="$(basename "$existing_dir")"

        local choice
        choice=$(zenity --list \
            --title="$(wt_title "${tool_key}  ›  Existing Release Found")" \
            --text="$(printf '<tt>An existing release was found:\n\n  %s\n\n─────────────────────────────────────\nWould you like to use it, or fetch the\nlatest release from GitHub?</tt>' "$existing_name")" \
            --radiolist \
            --column="" --column="Option" --column="Details" \
            TRUE  "Use existing"     "$(printf 'Use:  %s' "$existing_name")" \
            FALSE "Download latest"  "Fetch the newest release from GitHub" \
            --width="$WT_WIDTH" --height=240) || return 1

        if [[ "$choice" == "Use existing" ]]; then
            export WT_DLL_ROOT="$existing_dir"
            return 0
        fi
    fi

    # --- Fetch latest release metadata from GitHub API ---
    wt_info "${tool_key}  ›  Fetching Release Info" \
        "$(printf 'Querying GitHub for the latest %s release...\n\n  %s' "$tool_key" "$api_url")"

    local api_response
    if ! api_response="$(curl -fsSL "$api_url" 2>&1)"; then
        wt_error "$(printf 'Failed to query the GitHub API for %s.\n\nURL: %s\n\nPossible causes:\n  •  No internet connection\n  •  GitHub rate limit reached (try again in a minute)\n\nError:\n  %s' \
            "$tool_key" "$api_url" "$api_response")"
    fi

    # Parse tag name and asset download URL (no jq required)
    local tag_name
    tag_name="$(echo "$api_response" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"

    local asset_url
    asset_url="$(echo "$api_response" | grep '"browser_download_url"' \
        | grep -i "$asset_pattern" \
        | grep -v '\.sha256\|\.sig\|\.asc' \
        | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"

    if [[ -z "$tag_name" || -z "$asset_url" ]]; then
        wt_error "$(printf 'Could not parse the GitHub API response for %s.\n\nTag found    : %s\nAsset found  : %s\n\nTry running manually:\n  curl -fsSL %s' \
            "$tool_key" "${tag_name:-(none)}" "${asset_url:-(none)}" "$api_url")"
    fi

    # --- Confirm download with user ---
    wt_confirm "${tool_key}  ›  Download Latest" \
        "$(printf 'Latest release found:\n\n  Tool    :  %s\n  Version :  %s\n  Asset   :  %s\n\n─────────────────────────────────────\nDownload and extract to:\n  %s' \
            "$tool_key" "$tag_name" "$(basename "$asset_url")" "$store_dir")" || return 1

    # --- Download into a temp file ---
    # Detect archive extension from the URL to handle both .tar.gz and .tar.zst
    local asset_ext=""
    case "$asset_url" in
        *.tar.zst) asset_ext=".tar.zst" ;;
        *.tar.gz)  asset_ext=".tar.gz"  ;;
        *.tar.xz)  asset_ext=".tar.xz"  ;;
        *)         asset_ext=".tar.gz"  ;;  # fallback
    esac

    # For .tar.zst we need zstd — check early so we fail before downloading
    if [[ "$asset_ext" == ".tar.zst" ]]; then
        wt_require_cmds zstd
    fi

    local tmp_archive
    tmp_archive="$(mktemp --suffix="$asset_ext")"
    trap 'rm -f "$tmp_archive"' RETURN

    (
        curl -fL --progress-bar "$asset_url" -o "$tmp_archive" 2>&1
    ) | zenity --progress \
            --title="$(wt_title "${tool_key}  ›  Downloading")" \
            --text="$(printf '<tt>Downloading  %s  %s\n\nFrom:\n  %s</tt>' "$tool_key" "$tag_name" "$asset_url")" \
            --width="$WT_WIDTH" \
            --pulsate \
            --auto-close \
            --no-cancel || true

    if [[ ! -s "$tmp_archive" ]]; then
        wt_error "$(printf 'Download appears to have failed — archive is empty.\n\nURL: %s\n\nCheck your internet connection and try again.' "$asset_url")"
    fi

    # Extract into the store directory
    local extract_dir="$store_dir/${tool_key}-${tag_name}"
    mkdir -p "$extract_dir"

    # Extract into the store directory — call tar directly per format to avoid
    # word-splitting issues when passing flags as a string argument.
    _wt_try_extract() {
        # $@ = full tar invocation minus the archive/dest args
        if ! tar "$@" "$tmp_archive" -C "$extract_dir" --strip-components=1 2>/dev/null; then
            # Retry without --strip-components in case archive has no top-level dir
            tar "$@" "$tmp_archive" -C "$extract_dir"                 || wt_error "$(printf 'Failed to extract archive for %s.\n\nArchive : %s\nDest    : %s\nFormat  : %s' "$tool_key" "$tmp_archive" "$extract_dir" "$asset_ext")"
        fi
    }

    case "$asset_ext" in
        .tar.zst) _wt_try_extract --use-compress-program=zstd -xf ;;
        .tar.xz)  _wt_try_extract -xJf ;;
        *)        _wt_try_extract -xzf  ;;
    esac



    wt_info "${tool_key}  ›  Download Complete" \
        "$(printf '✔  Downloaded and extracted:\n\n  %s  %s\n\nStored at:\n  %s' "$tool_key" "$tag_name" "$extract_dir")"

    export WT_DLL_ROOT="$extract_dir"
}

# =============================================================================
#  CONFIG SYSTEM
# =============================================================================

WT_CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build/winetoolz.cfg"

# Default values — used if config key is missing
WT_CFG_DEFAULTS=(
    "WT_PREFIX_PATHS=${HOME}/.wine:${HOME}/prefixes"
    "WT_BACKUP_DIR=${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-winetoolz/backups"
)

# wt_load_config
#   Sources ~/winetoolz/.config if it exists, then fills in any missing keys
#   with defaults. Safe to call multiple times.
wt_load_config() {
    # Create config with defaults if missing
    if [[ ! -f "$WT_CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$WT_CONFIG_FILE")"
        printf '# winetoolz configuration\n' > "$WT_CONFIG_FILE"
        for kv in "${WT_CFG_DEFAULTS[@]}"; do
            printf '%s\n' "$kv" >> "$WT_CONFIG_FILE"
        done
    fi

    # Source it
    # shellcheck source=/dev/null
    source "$WT_CONFIG_FILE"

    # Fill in any missing keys with defaults
    for kv in "${WT_CFG_DEFAULTS[@]}"; do
        local key="${kv%%=*}"
        if [[ -z "${!key:-}" ]]; then
            export "$key"="${kv#*=}"
        fi
    done
}

# wt_config_set <key> <value>
#   Writes or updates a key in the config file.
wt_config_set() {
    local key="$1"
    local val="$2"
    mkdir -p "$(dirname "$WT_CONFIG_FILE")"

    if grep -q "^${key}=" "$WT_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$WT_CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$WT_CONFIG_FILE"
    fi
    export "$key"="$val"
}

# wt_select_prefix_from_config <module_name>
#   Scans all directories listed in WT_PREFIX_PATHS (colon-separated),
#   finds valid prefixes (containing system.reg), and presents a radio-list.
#   Falls back to a plain directory picker if none are found.
#   Exports WINEPREFIX on success.
wt_select_prefix_from_config() {
    local module="${1:-Select Prefix}"
    wt_load_config

    local -a rows=()
    local IFS_ORIG="$IFS"
    IFS=':'
    read -ra search_dirs <<< "$WT_PREFIX_PATHS"
    IFS="$IFS_ORIG"

    for dir in "${search_dirs[@]}"; do
        dir="${dir/#\~/$HOME}"
        [[ -d "$dir" ]] || continue
        # Direct prefix
        if [[ -f "$dir/system.reg" ]]; then
            local arch="unknown"
            grep -q 'win64\|#arch=win64' "$dir/system.reg" 2>/dev/null && arch="win64" || arch="win32"
            rows+=("$dir" "$(basename "$dir")  [$arch]  —  $dir")
        fi
        # Subdirectory prefixes
        while IFS= read -r reg; do
            local pdir
            pdir="$(dirname "$reg")"
            local arch="unknown"
            grep -q 'win64\|#arch=win64' "$reg" 2>/dev/null && arch="win64" || arch="win32"
            rows+=("$pdir" "$(basename "$pdir")  [$arch]  —  $pdir")
        done < <(find "$dir" -maxdepth 2 -name "system.reg" 2>/dev/null | sort)
    done

    local chosen=""

    if [[ ${#rows[@]} -gt 0 ]]; then
        # Build zenity args: value + display pairs
        local -a zenity_rows=()
        local i=0
        while (( i < ${#rows[@]} )); do
            zenity_rows+=("${rows[$i]}" "${rows[$((i+1))]}")
            (( i+=2 ))
        done

        zenity_rows+=("Browse..." "Browse for a prefix not listed above...")

        chosen=$(zenity --list \
            --title="$(wt_title "$module  ›  Select Prefix")" \
            --text="<tt>Choose a Wine prefix.\nSelect  Browse...  to pick a folder not listed here.</tt>" \
            --column="Path" --column="Details" \
            --hide-column=1 --print-column=1 \
            --width=700 --height=380 \
            "${zenity_rows[@]}") || return 1
    fi

    if [[ -z "$chosen" || "$chosen" == "Browse..." ]]; then
        chosen=$(zenity --file-selection \
            --directory \
            --title="$(wt_title "$module  ›  Browse for WINEPREFIX")" \
            --text="<tt>Select a Wine prefix directory.\nA valid prefix contains a  system.reg  file.</tt>" \
            --width="$WT_WIDTH") || return 1
    fi

    if [[ ! -f "$chosen/system.reg" ]]; then
        wt_error "$(printf 'Not a valid Wine prefix:\n  %s\n\nA valid prefix must contain a system.reg file.' "$chosen")"
    fi

    export WINEPREFIX="$chosen"
}
