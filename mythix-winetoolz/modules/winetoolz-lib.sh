#!/usr/bin/env bash
# shellcheck disable=SC2034  # WT_* result variables are read by the modules
# =============================================================================
#  winetoolz-lib.sh — Shared Library
#  Source this file at the top of every winetoolz module:
#    source "$(dirname "$0")/../winetoolz-lib.sh"
#
#  Safe to source under `set -euo pipefail` (the modules) and under `set +e`
#  (the generated terminal scripts): sourcing only assigns variables and
#  defines functions — no traps, no dialogs, no subprocess side effects.
# =============================================================================

# --- BRANDING ---
WT_TITLE="winetoolz"
WT_VERSION="3.0"
WT_WIDTH="${WT_WIDTH:-560}"

# Where this library lives. Exported so the generated terminal scripts can
# `source "$WT_LIB_PATH"` however winetoolz was installed.
if [[ -z "${WT_LIB_PATH:-}" || ! -f "${WT_LIB_PATH:-}" ]]; then
    WT_LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fi
export WT_LIB_PATH

# Per-user state: download cache and managed data.
WT_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/mythix-winetoolz"
WT_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-winetoolz"

_wt_have() { command -v "$1" >/dev/null 2>&1; }

# zenity <args...>
#   Every dialog goes through here. Under a C/POSIX (non-UTF-8) locale GTK
#   rejects non-ASCII arguments — the ⚠ ─ › ✔ in winetoolz's dialogs — and
#   zenity just prints "This option is not available" and shows nothing, so
#   dialogs then run under C.UTF-8. UTF-8 locales are left alone.
zenity() {
    local lc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "${lc,,}" in
        *.utf-8|*.utf8|*.utf-8@*|*.utf8@*) command zenity "$@" ;;
        *) LC_ALL=C.UTF-8 command zenity "$@" ;;
    esac
}

# =============================================================================
#  DIALOG HELPERS
# =============================================================================

# wt_title <module_name>
#   Returns a formatted window title string.
wt_title() {
    printf '[ %s :: %s ]' "$WT_TITLE" "$1"
}

# wt_markup_escape <text>
#   Escapes text for zenity's Pango markup (--text). A path, game name or error
#   message containing & < or > otherwise makes zenity throw the whole message
#   away and show its generic default text instead. The & in the replacements
#   is backslash-quoted: bash 5.2's patsub_replacement would expand a bare &
#   to the matched character.
wt_markup_escape() {
    local s="${1-}"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    printf '%s' "$s"
}

# _wt_box <message>
#   The house style for dialog text: the escaped message in monospace.
_wt_box() {
    printf '<tt>%s</tt>' "$(wt_markup_escape "$1")"
}

# wt_error <message>
#   Show a zenity error dialog and exit 1.
wt_error() {
    local msg="$1"
    printf '[  ERR   ] %s\n' "$msg" >&2
    zenity --error \
        --title="$(wt_title "Error")" \
        --width="$WT_WIDTH" \
        --text="$(_wt_box "$(printf '⚠  ERROR\n─────────────────────────────────────\n%s' "$msg")")" || true
    exit 1
}

# wt_error_return <message>
#   Show a zenity error dialog but return instead of exiting (use inside loops).
#   Always returns 0, so closing the dialog with Esc can't trip `set -e`.
wt_error_return() {
    local msg="$1"
    printf '[  ERR   ] %s\n' "$msg" >&2
    zenity --error \
        --title="$(wt_title "Error")" \
        --width="$WT_WIDTH" \
        --text="$(_wt_box "$(printf '⚠  ERROR\n─────────────────────────────────────\n%s' "$msg")")" || true
}

# wt_warn <title_suffix> <message>
#   Show a zenity warning dialog. Always returns 0.
wt_warn() {
    local suffix="$1"
    local msg="$2"
    zenity --warning \
        --title="$(wt_title "$suffix")" \
        --width="$WT_WIDTH" \
        --text="$(_wt_box "$msg")" || true
}

# wt_info <title_suffix> <message>
#   Show a zenity info dialog. Always returns 0.
wt_info() {
    local suffix="$1"
    local msg="$2"
    zenity --info \
        --title="$(wt_title "$suffix")" \
        --width="$WT_WIDTH" \
        --text="$(_wt_box "$msg")" || true
}

# wt_confirm <title_suffix> <message>
#   Show a yes/no confirmation dialog. Returns 0 for yes, 1 for no.
wt_confirm() {
    local suffix="$1"
    local msg="$2"
    zenity --question \
        --title="$(wt_title "$suffix")" \
        --width="$WT_WIDTH" \
        --text="$(_wt_box "$msg")"
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
        --text="$(_wt_box "$label")" \
        --width="$WT_WIDTH" \
        --pulsate \
        --auto-close \
        --no-cancel
}

# _wt_gui
#   True when dialogs can be shown (a display, or WT_ASSUME_GUI=1 for tests).
_wt_gui() {
    [[ "${WT_ASSUME_GUI:-0}" == 1 ]] && return 0
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && _wt_have zenity
}

# wt_pulse_start <title_suffix> <label>  /  wt_pulse_stop
#   A "working..." bar around a step that runs in the foreground, so the step
#   can still set variables (unlike piping it into wt_progress_pulse).
wt_pulse_start() {
    _WT_PULSE_FLAG=""
    _WT_PULSE_PID=""
    _wt_gui || return 0
    _WT_PULSE_FLAG="$(mktemp -u "${TMPDIR:-/tmp}/wt-pulse.XXXXXX")"
    local flag="$_WT_PULSE_FLAG" label="$2"
    {
        while [[ ! -e "$flag" ]]; do
            printf '# %s\n' "$label"
            sleep 0.3
        done
    } | wt_progress_pulse "$1" "$label" >/dev/null 2>&1 &
    _WT_PULSE_PID=$!
}

wt_pulse_stop() {
    [[ -n "${_WT_PULSE_FLAG:-}" ]] || return 0
    : > "$_WT_PULSE_FLAG"
    [[ -n "${_WT_PULSE_PID:-}" ]] && { wait "$_WT_PULSE_PID" 2>/dev/null || true; }
    rm -f "$_WT_PULSE_FLAG"
    _WT_PULSE_FLAG=""
    _WT_PULSE_PID=""
}

# =============================================================================
#  TERMINAL OUTPUT FORMATTING
# =============================================================================

wt_log()      { printf '\n[  ....  ] %s\n' "$*"; }
wt_log_ok()   { printf '[   OK   ] %s\n' "$*"; }
wt_log_err()  { printf '[  ERR   ] %s\n' "$*" >&2; }
wt_log_warn() { printf '[  WARN  ] %s\n' "$*" >&2; }
wt_log_info() { printf '[  INFO  ] %s\n' "$*"; }

wt_section() {
    printf '\n'
    printf '══════════════════════════════════════════════════\n'
    printf '  %s\n' "$*"
    printf '══════════════════════════════════════════════════\n'
}

# wt_pause
#   "Press Enter to close" at the end of a terminal script. Never blocks when
#   there is no terminal to read from.
wt_pause() {
    local msg="${1:-  Press Enter to close...}"
    if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
        read -rp "$msg" _ </dev/tty || true
    fi
    return 0
}

# wt_human_size <bytes>
wt_human_size() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || { printf '%s' "$b"; return 0; }
    if   (( b >= 1073741824 )); then printf '%d.%d GiB' $(( b / 1073741824 )) $(( b % 1073741824 * 10 / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%d.%d MiB' $(( b / 1048576 )) $(( b % 1048576 * 10 / 1048576 ))
    elif (( b >= 1024 ));       then printf '%d KiB' $(( b / 1024 ))
    else printf '%d B' "$b"
    fi
}

# wt_q <value>
#   Shell-quote a value for embedding in a generated script.
wt_q() { printf '%q' "$1"; }

# =============================================================================
#  DEPENDENCY CHECK
# =============================================================================

# _wt_pkg_manager
#   apt | dnf | pacman | zypper | "" — from /etc/os-release, then from what
#   package tool is installed.
_wt_pkg_manager() {
    local ids="" line
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line; do
            case "$line" in
                ID=*|ID_LIKE=*) line="${line#*=}"; line="${line//\"/}"; ids+=" ${line,,}" ;;
            esac
        done < /etc/os-release
    fi
    case " $ids " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" elementary "*|*" zorin "*|*" kali "*|*" neon "*|*" raspbian "*)
            echo apt; return 0 ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" nobara "*|*" bazzite "*)
            echo dnf; return 0 ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*|*" cachyos "*|*" garuda "*|*" steamos "*)
            echo pacman; return 0 ;;
        *" opensuse "*|*" suse "*|*" opensuse-tumbleweed "*|*" opensuse-leap "*|*" sles "*)
            echo zypper; return 0 ;;
    esac
    local pm
    for pm in apt dnf pacman zypper; do
        if _wt_have "$pm"; then echo "$pm"; return 0; fi
    done
    echo ""
}

# _wt_pkg_for <command> <package_manager>
#   The package that provides <command> on that distro family.
_wt_pkg_for() {
    local cmd="$1" pm="$2"
    case "$pm:$cmd" in
        apt:7z|apt:7za)            echo p7zip-full ;;
        dnf:7z|dnf:7za)            echo p7zip-plugins ;;
        pacman:7z|zypper:7z)       echo 7zip ;;
        apt:xz|apt:unxz)           echo xz-utils ;;
        apt:bsdtar)                echo libarchive-tools ;;
        pacman:bsdtar)             echo libarchive ;;
        *:sha256sum|*:stat|*:realpath|*:timeout|*:mktemp) echo coreutils ;;
        *:flock|*:mountpoint)      echo util-linux ;;
        *:vulkaninfo)              echo vulkan-tools ;;
        apt:glxinfo|pacman:glxinfo) echo mesa-utils ;;
        dnf:glxinfo)               echo glx-utils ;;
        zypper:glxinfo)            echo Mesa-demo-x ;;
        *:lspci)                   echo pciutils ;;
        *:wrestool|*:icotool)      echo icoutils ;;
        *:msiextract)              echo msitools ;;
        *:xdg-open)                echo xdg-utils ;;
        apt:notify-send)           echo libnotify-bin ;;
        zypper:notify-send)        echo libnotify-tools ;;
        *:notify-send)             echo libnotify ;;
        apt:wine64)                echo wine64 ;;
        *:wine64|*:wineserver)     echo wine ;;
        *)                         echo "$cmd" ;;
    esac
}

# _wt_install_hint <package_manager> <package...>
_wt_install_hint() {
    local pm="$1"; shift
    case "$pm" in
        apt)    printf 'sudo apt install %s' "$*" ;;
        dnf)    printf 'sudo dnf install %s' "$*" ;;
        pacman) printf 'sudo pacman -S --needed %s' "$*" ;;
        zypper) printf 'sudo zypper install %s' "$*" ;;
        *)      printf "your distribution's package manager:  %s" "$*" ;;
    esac
}

# wt_missing_cmds <cmd1> <cmd2> ...
#   Prints the commands that are not installed, one per line.
wt_missing_cmds() {
    local cmd
    for cmd in "$@"; do
        _wt_have "$cmd" || printf '%s\n' "$cmd"
    done
    return 0
}

# wt_require_cmds <cmd1> <cmd2> ...
#   Checks that all listed commands exist. Calls wt_error if any are missing,
#   naming the packages to install for this distro.
wt_require_cmds() {
    local -a missing=() pkgs=()
    local cmd pm p
    for cmd in "$@"; do
        _wt_have "$cmd" || missing+=("$cmd")
    done
    (( ${#missing[@]} )) || return 0

    pm="$(_wt_pkg_manager)"
    for cmd in "${missing[@]}"; do
        p="$(_wt_pkg_for "$cmd" "$pm")"
        [[ " ${pkgs[*]-} " == *" $p "* ]] || pkgs+=("$p")
    done
    wt_error "$(printf 'The following required tools are missing:\n\n%s\nInstall them with:\n  %s' \
        "$(printf '  •  %s\n' "${missing[@]}")" \
        "$(_wt_install_hint "$pm" "${pkgs[@]}")")"
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

# _wt_cfg_expand <value>
#   $HOME / ${HOME} / $XDG_*_HOME and a leading ~ (also after a ':' in path
#   lists) — the expansions a hand-edited config can reasonably expect,
#   without ever evaluating it as shell code.
_wt_cfg_expand() {
    local v="$1" xc="${XDG_CONFIG_HOME:-${HOME}/.config}" xd="${XDG_DATA_HOME:-${HOME}/.local/share}"
    local xk="${XDG_CACHE_HOME:-${HOME}/.cache}"
    v="${v//\$\{HOME\}/$HOME}";                       v="${v//\$HOME/$HOME}"
    v="${v//\$\{XDG_CONFIG_HOME\}/$xc}";              v="${v//\$XDG_CONFIG_HOME/$xc}"
    v="${v//\$\{XDG_DATA_HOME\}/$xd}";                v="${v//\$XDG_DATA_HOME/$xd}"
    v="${v//\$\{XDG_CACHE_HOME\}/$xk}";               v="${v//\$XDG_CACHE_HOME/$xk}"
    [[ "$v" == \~ || "$v" == \~/* ]] && v="${HOME}${v#\~}"
    v="${v//:\~\//:$HOME/}"
    printf '%s' "$v"
}

# _wt_cfg_value <raw>
#   Value side of KEY=VALUE as the old `source`-based loader would have read
#   it: "double quotes" (with \" \\ \$ \` escapes and $HOME expansion),
#   'single quotes' (literal), or bare (expanded, trailing comment dropped).
_wt_cfg_value() {
    local raw="$1" sentinel=$'\x01'
    if [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
        raw="${raw//\\\$/$sentinel}"
        raw="$(_wt_cfg_expand "$raw")"
        raw="${raw//$sentinel/\$}"
        raw="${raw//\\\"/\"}"
        raw="${raw//\\\`/\`}"
        raw="${raw//\\\\/\\}"
    elif [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
    else
        raw="${raw%%[[:space:]]#*}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        raw="$(_wt_cfg_expand "$raw")"
    fi
    printf '%s' "$raw"
}

# wt_kv_load <file> <key_regex> [export]
#   Reads KEY=VALUE lines — the format wt_kv_save and wt_config_set write,
#   and older hand-written files — WITHOUT executing anything, and sets every
#   key matching <key_regex> (exported with "export"). Returns 1 when the
#   file cannot be read.
wt_kv_load() {
    local file="$1" keyre="$2" exp="${3:-}" line key val
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        [[ "$key" =~ $keyre ]] || continue
        printf -v "$key" '%s' "$(_wt_cfg_value "$val")"
        [[ "$exp" == export ]] && export "${key?}"
    done < "$file"
    return 0
}

# _wt_kv_escape <value>  — escapes a value for KEY="value" (newlines → space).
_wt_kv_escape() {
    local v="$1"
    v="${v//$'\n'/ }"
    v="${v//$'\r'/ }"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '%s' "$v"
}

# wt_kv_save <file> <var_name...>
#   Writes the named variables as KEY="value" lines, atomically. Read them
#   back with wt_kv_load (older winetoolz versions `source` the same format).
wt_kv_save() {
    local file="$1"; shift
    local tmp key
    mkdir -p "$(dirname "$file")" || return 1
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    for key in "$@"; do
        printf '%s="%s"\n' "$key" "$(_wt_kv_escape "${!key-}")"
    done > "$tmp"
    mv -f -- "$tmp" "$file"
}

# wt_load_config
#   Reads the config file (creating it with defaults if missing), then fills
#   in any missing keys with defaults. The file is parsed, never executed:
#   only KEY=VALUE lines whose key starts with WT_ are taken. Safe to call
#   multiple times.
wt_load_config() {
    # Create config with defaults if missing
    if [[ ! -f "$WT_CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$WT_CONFIG_FILE")" 2>/dev/null || true
        { printf '# winetoolz configuration\n'; printf '%s\n' "${WT_CFG_DEFAULTS[@]}"; } \
            > "$WT_CONFIG_FILE" 2>/dev/null || true
    fi

    local key kv
    wt_kv_load "$WT_CONFIG_FILE" '^WT_' export || true

    # Fill in any missing keys with defaults
    for kv in "${WT_CFG_DEFAULTS[@]}"; do
        key="${kv%%=*}"
        if [[ -z "${!key:-}" ]]; then
            printf -v "$key" '%s' "${kv#*=}"
            export "${key?}"
        fi
    done
}

# wt_config_set <key> <value>
#   Writes or updates a key in the config file (atomically; the value is
#   stored double-quoted so older winetoolz versions can still read it).
wt_config_set() {
    local key="$1"
    local val="$2"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        wt_log_err "wt_config_set: invalid key: $key"
        return 1
    fi
    if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
        wt_log_err "wt_config_set: refusing a multi-line value for $key"
        return 1
    fi
    mkdir -p "$(dirname "$WT_CONFIG_FILE")"

    local newline
    newline="${key}=\"$(_wt_kv_escape "$val")\""

    local tmp line done_=0
    tmp="$(mktemp "${WT_CONFIG_FILE}.XXXXXX")" || return 1
    if [[ -f "$WT_CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
                (( done_ )) || printf '%s\n' "$newline"
                done_=1
            else
                printf '%s\n' "$line"
            fi
        done < "$WT_CONFIG_FILE" > "$tmp"
    fi
    (( done_ )) || printf '%s\n' "$newline" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$WT_CONFIG_FILE"

    printf -v "$key" '%s' "$val"
    export "${key?}"
}

# =============================================================================
#  SAFETY HELPERS
# =============================================================================

# wt_safe_rmrf <path> [marker ...]
#   rm -rf with guard rails, for every "delete this prefix / build / release"
#   action. Refuses (returns 1, reason in WT_RMRF_ERROR) when <path> is empty,
#   relative, a symlink, /, $HOME or one of its ancestors, inside a system
#   directory, a mount point, fewer than three levels deep, or — when markers
#   are given — contains none of them (e.g. "system.reg" proves it is a Wine
#   prefix). Without markers the path must lie inside a directory winetoolz
#   manages itself. Never crosses into another filesystem. A missing path is
#   not an error.
wt_safe_rmrf() {
    local target="${1:-}"
    (( $# )) && shift
    WT_RMRF_ERROR=""

    if [[ -z "$target" ]]; then
        WT_RMRF_ERROR="Refusing to delete: no path given."; return 1
    fi
    if [[ "$target" != /* ]]; then
        WT_RMRF_ERROR="Refusing to delete a relative path: $target"; return 1
    fi
    if [[ -L "$target" ]]; then
        WT_RMRF_ERROR="Refusing to delete through a symlink: $target"; return 1
    fi

    local real home
    real="$(realpath -m -- "$target" 2>/dev/null)" || {
        WT_RMRF_ERROR="Cannot resolve the path: $target"; return 1; }
    home="$(realpath -m -- "$HOME" 2>/dev/null || printf '%s' "${HOME%/}")"

    if [[ "$real" == / || "$home/" == "$real/"* ]]; then
        WT_RMRF_ERROR="Refusing to delete $real — it is / or contains your home folder."; return 1
    fi
    case "$real" in
        /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|\
        /lib64|/lib64/*|/libx32|/libx32/*|/proc|/proc/*|/sbin|/sbin/*|/sys|/sys/*|\
        /usr|/usr/*|/var/lib|/var/lib/*|/snap|/snap/*)
            WT_RMRF_ERROR="Refusing to delete inside a system directory: $real"; return 1 ;;
    esac
    local rest="${real#/}" depth=1
    while [[ "$rest" == */* ]]; do rest="${rest#*/}"; depth=$((depth + 1)); done
    if (( depth < 3 )); then
        WT_RMRF_ERROR="Refusing to delete a top-level folder: $real"; return 1
    fi
    [[ -e "$real" ]] || return 0
    if _wt_have mountpoint && mountpoint -q -- "$real" 2>/dev/null; then
        WT_RMRF_ERROR="Refusing to delete a mount point: $real"; return 1
    fi

    if (( $# )); then
        local m ok=0
        for m in "$@"; do
            if [[ -e "$real/$m" ]]; then ok=1; break; fi
        done
        if (( ! ok )); then
            WT_RMRF_ERROR="$(printf 'Refusing to delete %s:\nit does not look like what it should be (none of: %s).' "$real" "$*")"
            return 1
        fi
    else
        local root inside=0
        for root in "${WT_RELEASE_BASE:-}" "${WT_BACKUP_DIR:-}" "$WT_CACHE_DIR" "$WT_DATA_DIR" \
                    "${HOME}/.local/share/mythix-wine-installs"; do
            [[ -n "$root" ]] || continue
            root="$(realpath -m -- "$root" 2>/dev/null || printf '%s' "$root")"
            if [[ "$real" == "$root"/* ]]; then inside=1; break; fi
        done
        if (( ! inside )); then
            WT_RMRF_ERROR="Refusing to delete $real: it is outside the folders winetoolz manages."
            return 1
        fi
    fi

    if ! rm -rf --one-file-system -- "$real"; then
        WT_RMRF_ERROR="Could not delete everything in $real (permissions?)."
        return 1
    fi
}

# =============================================================================
#  DOWNLOADS
# =============================================================================

# _wt_magic_hex <file> <bytes>
#   The first <bytes> bytes of a file as lowercase hex.
_wt_magic_hex() {
    LC_ALL=C od -An -tx1 -N "$2" -- "$1" 2>/dev/null | tr -d ' \n'
}

# wt_file_is <file> <kind>
#   Sniff a file's type from its magic bytes: pe (exe/dll), zip, cab, msi,
#   gzip, xz, zstd, 7z. Catches an HTML error page saved under an .exe name.
wt_file_is() {
    local f="$1" kind="$2" hex
    [[ -s "$f" ]] || return 1
    hex="$(_wt_magic_hex "$f" 8)"
    case "$kind" in
        pe|exe|dll) [[ "$hex" == 4d5a* ]] ;;
        zip)        [[ "$hex" == 504b0304* || "$hex" == 504b0506* ]] ;;
        cab)        [[ "$hex" == 4d534346* ]] ;;
        msi)        [[ "$hex" == d0cf11e0a1b11ae1* ]] ;;
        gzip|tgz)   [[ "$hex" == 1f8b* ]] ;;
        xz|txz)     [[ "$hex" == fd377a585a00* ]] ;;
        zstd|tzst)  [[ "$hex" == 28b52ffd* ]] ;;
        7z)         [[ "$hex" == 377abcaf271c* ]] ;;
        *)          return 1 ;;
    esac
}

# wt_fetch <url> <output_file> [sha256] [label] [expected_size]
#   Download a file the careful way: HTTPS only (set WT_ALLOW_HTTP=1 to allow
#   plain http), timeouts and retries, into a temporary file that only
#   replaces <output_file> once it is complete and — when a sha256 is given —
#   verified. Shows a cancellable progress dialog when a display is available
#   (a real percentage when the size is known), a progress bar in a terminal.
#   Returns 0 on success; on failure returns non-zero and leaves the reason in
#   WT_FETCH_ERROR (130 = cancelled, 3 = checksum mismatch).
wt_fetch() {
    local url="$1" out="$2" sha="${3:-}" label="${4:-}" size="${5:-}"
    WT_FETCH_ERROR=""
    [[ -n "$label" ]] || label="$(basename "$out")"
    sha="${sha#sha256:}"
    sha="${sha,,}"

    case "$url" in
        https://*) ;;
        http://*)
            if [[ "${WT_ALLOW_HTTP:-0}" != 1 ]]; then
                WT_FETCH_ERROR="Refusing a plain-http download (set WT_ALLOW_HTTP=1 to allow): $url"
                return 2
            fi ;;
        *)  WT_FETCH_ERROR="Not a download URL: $url"; return 2 ;;
    esac

    local outdir
    outdir="$(dirname "$out")"
    if ! mkdir -p "$outdir"; then
        WT_FETCH_ERROR="Cannot create the download folder: $outdir"; return 1
    fi
    rm -f "$out".part.* 2>/dev/null || true
    local tmp errf
    tmp="$(mktemp "$out.part.XXXXXX")" || { WT_FETCH_ERROR="Cannot write to $outdir"; return 1; }
    errf="$(mktemp "${TMPDIR:-/tmp}/wt-fetch-err.XXXXXX")" || errf=/dev/null

    local protos="=https"
    [[ "${WT_ALLOW_HTTP:-0}" == 1 ]] && protos="=http,https"
    local -a cmd=()
    if _wt_have curl; then
        cmd=(curl --fail --location --show-error
             --proto "$protos" --proto-redir "$protos"
             --connect-timeout 20 --retry 3 --retry-delay 2
             --speed-limit 1024 --speed-time 60
             --user-agent "winetoolz/${WT_VERSION}"
             --output "$tmp")
        if _wt_fetch_in_tty; then cmd+=(--progress-bar); else cmd+=(--silent); fi
        cmd+=(-- "$url")
    elif _wt_have wget; then
        cmd=(wget --tries=3 --timeout=30 --user-agent="winetoolz/${WT_VERSION}" -O "$tmp")
        [[ "${WT_ALLOW_HTTP:-0}" == 1 ]] || cmd+=(--https-only)
        if _wt_fetch_in_tty; then cmd+=(--progress=bar:force); else cmd+=(--quiet); fi
        cmd+=(-- "$url")
    else
        rm -f "$tmp"
        WT_FETCH_ERROR="Neither curl nor wget is installed."
        return 1
    fi

    local rc=0 cancelled=0
    if _wt_fetch_in_tty; then
        "${cmd[@]}" || rc=$?
    elif _wt_gui; then
        "${cmd[@]}" 2>"$errf" &
        local pid=$!
        local -a zargs=(--progress --title="$(wt_title "Downloading")" --width="$WT_WIDTH"
                        --auto-close --text="$(_wt_box "Downloading  $label")")
        [[ "$size" =~ ^[1-9][0-9]*$ ]] || { size=""; zargs+=(--pulsate); }
        local zrc=0
        {
            local cur pct
            while kill -0 "$pid" 2>/dev/null; do
                cur="$(stat -c %s -- "$tmp" 2>/dev/null || echo 0)"
                if [[ -n "$size" ]]; then
                    pct=$(( cur * 100 / size ))
                    (( pct > 99 )) && pct=99
                    printf '%d\n# Downloading  %s\n# %s of %s\n' "$pct" "$label" \
                        "$(wt_human_size "$cur")" "$(wt_human_size "$size")"
                else
                    printf '# Downloading  %s  —  %s\n' "$label" "$(wt_human_size "$cur")"
                fi
                sleep 0.5
            done
            printf '100\n'
        } | zenity "${zargs[@]}" >/dev/null 2>&1 || zrc=$?
        if (( zrc != 0 )) && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            cancelled=1
        fi
        wait "$pid" || rc=$?
    else
        "${cmd[@]}" 2>"$errf" || rc=$?
        [[ -t 2 && "$errf" != /dev/null ]] && cat "$errf" >&2
    fi

    if (( cancelled )); then
        rm -f "$tmp" "$errf"
        WT_FETCH_ERROR="Download cancelled."
        return 130
    fi
    if (( rc != 0 )) || [[ ! -s "$tmp" ]]; then
        local why=""
        [[ "$errf" != /dev/null ]] && why="$(tail -n 3 "$errf" 2>/dev/null || true)"
        rm -f "$tmp"
        [[ "$errf" != /dev/null ]] && rm -f "$errf"
        WT_FETCH_ERROR="$(printf 'Download failed (exit %s):\n  %s%s' "$rc" "$url" "${why:+$'\n\n'$why}")"
        return 1
    fi
    [[ "$errf" != /dev/null ]] && rm -f "$errf"

    if [[ -n "$sha" ]]; then
        local got
        got="$(sha256sum -- "$tmp" 2>/dev/null)" || got=""
        got="${got%% *}"
        if [[ "$got" != "$sha" ]]; then
            rm -f "$tmp"
            WT_FETCH_ERROR="$(printf 'Checksum mismatch — the download was discarded.\n\n  File     : %s\n  Expected : %s\n  Got      : %s' \
                "$label" "$sha" "${got:-(unreadable)}")"
            return 3
        fi
    fi

    if ! mv -f -- "$tmp" "$out"; then
        rm -f "$tmp"
        WT_FETCH_ERROR="Cannot move the download into place: $out"
        return 1
    fi
}

# _wt_fetch_in_tty — inside a winetoolz terminal window: show the progress
# right there (curl's bar) rather than in a dialog on top of it.
_wt_fetch_in_tty() {
    [[ "${WT_IN_TERMINAL:-0}" == 1 && -t 2 ]]
}

# =============================================================================
#  DOWNLOAD CATALOG  (modules/downloads.tsv)
# =============================================================================

# Every redistributable the installers fetch, with its sha256, in one file:
# when Microsoft moves a download, that file is the one place to update.
WT_DOWNLOADS_LIST="${WT_DOWNLOADS_LIST:-$(dirname "$WT_LIB_PATH")/downloads.tsv}"
WT_DL_CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/winetoolz/downloads"

# _wt_catalog <key>  — sets WT_ITEM_SHA, WT_ITEM_NAME, WT_ITEM_URLS (array).
_wt_catalog() {
    local key="$1" k sha name rest
    WT_ITEM_SHA="" WT_ITEM_NAME="" WT_ITEM_URLS=()
    [[ -r "$WT_DOWNLOADS_LIST" ]] || return 1
    while read -r k sha name rest; do
        [[ -z "$k" || "$k" == \#* || "$k" != "$key" ]] && continue
        [[ "$sha" == - ]] && sha=""
        WT_ITEM_SHA="${sha,,}" WT_ITEM_NAME="$name"
        read -r -a WT_ITEM_URLS <<< "$rest"
        return 0
    done < "$WT_DOWNLOADS_LIST"
    return 1
}

# _wt_item_kind <file name>  — the magic-byte check for a catalog file.
_wt_item_kind() {
    case "${1,,}" in
        *.exe|*.dll) echo pe ;;
        *.msi)       echo msi ;;
        *.zip)       echo zip ;;
        *.cab)       echo cab ;;
        *)           echo "" ;;
    esac
}

# _wt_verify <file> <sha256|""> <kind|"">
_wt_verify() {
    local f="$1" sha="$2" kind="$3" got
    [[ -s "$f" ]] || return 1
    if [[ -n "$sha" ]]; then
        got="$(sha256sum -- "$f" 2>/dev/null)" || return 1
        [[ "${got%% *}" == "$sha" ]] || return 1
    fi
    if [[ -n "$kind" ]]; then wt_file_is "$f" "$kind" || return 1; fi
    return 0
}

# wt_fetch_item <key> [label]
#   Gets a redistributable listed in downloads.tsv into the download cache —
#   reusing a cached copy only while it still verifies — and sets
#   WT_FETCHED to its path. Pinned items must match their sha256; unpinned
#   ones (links Microsoft updates in place) must still be a real installer
#   and are fetched again after 30 days. Copies cached by winetoolz 2.x's
#   DLL Installer are reused when they verify. Mirrors are tried in order.
#   Returns 1 (reason logged) when no source works, 130 when cancelled.
wt_fetch_item() {
    local key="$1" label="${2:-$1}" kind f url rc
    WT_FETCHED=""
    if ! _wt_catalog "$key"; then
        wt_log_err "Unknown download \"$key\" (not in $WT_DOWNLOADS_LIST)"
        return 1
    fi
    kind="$(_wt_item_kind "$WT_ITEM_NAME")"
    local out="$WT_DL_CACHE/$WT_ITEM_NAME"
    local legacy="${XDG_CACHE_HOME:-${HOME}/.cache}/winetoolz/dll_installer/$WT_ITEM_NAME"
    mkdir -p "$WT_DL_CACHE" || return 1

    for f in "$out" "$legacy"; do
        [[ -s "$f" ]] || continue
        if [[ -z "$WT_ITEM_SHA" && -n "$(find "$f" -mtime +30 2>/dev/null)" ]]; then
            continue    # unpinned and a month old: refresh it
        fi
        if _wt_verify "$f" "$WT_ITEM_SHA" "$kind"; then
            [[ "$f" == "$out" ]] || cp -f -- "$f" "$out"
            WT_FETCHED="$out"
            wt_log_info "Cached:  $label"
            return 0
        fi
        wt_log_warn "The cached $label failed verification — downloading it again."
    done
    rm -f -- "$out"

    # A mirror is only trusted with a checksum to hold it to.
    local -a sources=("${WT_ITEM_URLS[@]}")
    [[ -n "$WT_ITEM_SHA" ]] || sources=("${WT_ITEM_URLS[@]:0:1}")
    for url in "${sources[@]}"; do
        wt_log "Downloading $label..."
        rc=0
        wt_fetch "$url" "$out" "$WT_ITEM_SHA" "$label" || rc=$?
        if (( rc == 130 )); then return 130; fi
        if (( rc != 0 )); then
            wt_log_err "$WT_FETCH_ERROR"
            continue
        fi
        if [[ -n "$kind" ]] && ! wt_file_is "$out" "$kind"; then
            wt_log_err "$label from $url is not a valid file (an error page?) — discarded."
            rm -f -- "$out"
            continue
        fi
        WT_FETCHED="$out"
        wt_log_ok "Downloaded: $label"
        return 0
    done
    wt_log_err "Could not download $label from any source."
    return 1
}

# wt_github_latest <owner/repo> <asset_pattern> [--scan]
#   Looks up the latest GitHub release and the first asset whose name matches
#   <asset_pattern> (a case-insensitive regex; checksum/signature files are
#   skipped). With --scan, the newest of the last 30 releases (drafts and
#   pre-releases skipped) that has a matching asset — for repos that publish
#   several build families under separate releases. Sets WT_GH_TAG, WT_GH_ASSET, WT_GH_URL, WT_GH_SHA256 (from the
#   API's digest field, may be empty) and WT_GH_SIZE. Uses jq or python3 when
#   available, a grep fallback otherwise. Honours GITHUB_TOKEN / GH_TOKEN
#   (passed to curl on stdin, never on the command line). Returns non-zero
#   with WT_GH_ERROR on failure.
wt_github_latest() {
    local repo="$1" pattern="$2" scan="${3:-}"
    WT_GH_TAG="" WT_GH_ASSET="" WT_GH_URL="" WT_GH_SHA256="" WT_GH_SIZE="" WT_GH_ERROR=""

    if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        WT_GH_ERROR="Not a GitHub owner/repo: $repo"; return 2
    fi
    if ! _wt_have curl; then
        WT_GH_ERROR="curl is required to query GitHub."; return 1
    fi

    local api="https://api.github.com/repos/${repo}/releases/latest"
    [[ "$scan" == --scan ]] && api="https://api.github.com/repos/${repo}/releases?per_page=30"
    local json token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    local -a curl_args=(--fail --silent --show-error --location --proto "=https"
                        --connect-timeout 20 --max-time 60 --retry 2
                        --header "Accept: application/vnd.github+json"
                        --user-agent "winetoolz/${WT_VERSION}")
    if [[ -n "$token" ]]; then
        json="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
            | curl "${curl_args[@]}" --config - -- "$api" 2>&1)" || {
            WT_GH_ERROR="$(printf 'GitHub API request failed:\n  %s\n\n%s' "$api" "$json")"; return 1; }
    else
        json="$(curl "${curl_args[@]}" -- "$api" 2>&1)" || {
            WT_GH_ERROR="$(printf 'GitHub API request failed:\n  %s\n\n%s\n\nPossible causes:\n  •  No internet connection\n  •  GitHub rate limit reached (try again later,\n     or export GITHUB_TOKEN)' "$api" "$json")"; return 1; }
    fi

    local row=""
    if _wt_have jq; then
        row="$(printf '%s' "$json" | jq -r --arg pat "$pattern" '
            first(
                (if type == "array" then .[] else . end)
                | select((.draft // false) | not) | select((.prerelease // false) | not)
                | .tag_name as $t
                | .assets[]?
                | select(.name | test($pat; "i"))
                | select(.name | test("\\.(sha256|sha256sum|sha512|sha512sum|sig|asc|minisig)$"; "i") | not)
                | [ $t, .name, .browser_download_url, (.digest // ""), ((.size // "") | tostring) ] | @tsv
            ) // ""' 2>/dev/null)" || row=""
    elif _wt_have python3; then
        row="$(printf '%s' "$json" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
    pat = re.compile(sys.argv[1], re.I)
except Exception:
    sys.exit(0)
skip = re.compile(r"\.(sha256|sha256sum|sha512|sha512sum|sig|asc|minisig)$", re.I)
def rows():
    for r in (d if isinstance(d, list) else [d]):
        if r.get("draft") or r.get("prerelease"):
            continue
        for a in r.get("assets") or []:
            n = a.get("name") or ""
            if pat.search(n) and not skip.search(n):
                yield [r.get("tag_name") or "", n, a.get("browser_download_url") or "",
                       a.get("digest") or "", str(a.get("size") or "")]
for row in rows():
    print("\t".join(row))
    break
' "$pattern" 2>/dev/null)" || row=""
    else
        # No JSON parser: take the first matching download URL; the tag is
        # the path segment before the file name (.../releases/download/<tag>/<file>).
        # This fallback cannot tell pre-releases apart (the API never shows
        # drafts to anonymous requests).
        local tag url
        url="$(printf '%s\n' "$json" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
            | while IFS= read -r u; do
                if [[ "${u##*/}" =~ $pattern ]] || grep -qi -- "$pattern" <<< "${u##*/}"; then printf '%s\n' "$u"; fi
            done | grep -viE '\.(sha256|sha256sum|sha512|sha512sum|sig|asc|minisig)$' | sed -n 1p)" || url=""
        tag="${url%/*}"
        tag="${tag##*/}"
        [[ -n "$tag" && -n "$url" ]] && row="$(printf '%s\t%s\t%s\t\t' "$tag" "${url##*/}" "$url")"
    fi

    if [[ -n "$row" ]]; then
        IFS=$'\t' read -r WT_GH_TAG WT_GH_ASSET WT_GH_URL WT_GH_SHA256 WT_GH_SIZE <<< "$row" || true
    fi
    WT_GH_SHA256="${WT_GH_SHA256#sha256:}"
    if [[ -z "$WT_GH_TAG" || -z "$WT_GH_URL" ]]; then
        WT_GH_ERROR="$(printf 'Could not find a release asset matching  %s  in the latest %s release.\n\nTag found    : %s\nAsset found  : %s' \
            "$pattern" "$repo" "${WT_GH_TAG:-(none)}" "${WT_GH_ASSET:-(none)}")"
        return 1
    fi
    if [[ "$WT_GH_URL" != https://* ]]; then
        WT_GH_ERROR="Unexpected download URL from GitHub: $WT_GH_URL"; return 1
    fi
}

# =============================================================================
#  ARCHIVES
# =============================================================================

# _wt_archive_kind <file>
#   tgz | txz | tzst | tbz2 | tar | zip | 7z | cab | exe | unknown (by name).
#   An .exe is a self-extracting installer: a cabinet, or anything 7z opens.
_wt_archive_kind() {
    local n="${1,,}"
    case "$n" in
        *.tar.gz|*.tgz)                echo tgz ;;
        *.tar.xz|*.txz)                echo txz ;;
        *.tar.zst|*.tar.zstd|*.tzst)   echo tzst ;;
        *.tar.bz2|*.tbz2|*.tbz)        echo tbz2 ;;
        *.tar)                         echo tar ;;
        *.zip)                         echo zip ;;
        *.7z)                          echo 7z ;;
        *.cab)                         echo cab ;;
        *.exe)                         echo exe ;;
        *)                             echo unknown ;;
    esac
}

# _wt_tar_flags <kind>  — prints the decompression option for GNU tar.
_wt_tar_flags() {
    case "$1" in
        tgz)  echo "-z" ;;
        txz)  echo "-J" ;;
        tbz2) echo "-j" ;;
        tzst) echo "--use-compress-program=zstd" ;;
        *)    echo "" ;;
    esac
}

# _wt_bad_member <name>  — true for absolute paths and ".." components.
_wt_bad_member() {
    local n="$1"
    [[ "$n" == /* || "/$n/" == */../* ]]
}

# _wt_exe_kind <installer.exe>  — cab | 7z | "" (how to unpack it)
_wt_exe_kind() {
    if _wt_have cabextract && cabextract -l -- "$1" >/dev/null 2>&1; then echo cab
    elif _wt_have 7z && 7z l -- "$1" >/dev/null 2>&1; then echo 7z
    else echo ""
    fi
}

# wt_archive_check <archive> [--allow-links]
#   Lists the archive and refuses members that would land outside the
#   extraction folder: absolute paths and ".." components, plus (unless
#   --allow-links — Wine builds legitimately ship links) symlinks and hard
#   links. Returns non-zero with the offenders in WT_ARCHIVE_ERROR.
wt_archive_check() {
    local archive="$1" allow_links=0
    [[ "${2:-}" == --allow-links ]] && allow_links=1
    WT_ARCHIVE_ERROR=""

    local kind flags listing="" links="" name
    kind="$(_wt_archive_kind "$archive")"
    if [[ "$kind" == exe ]]; then
        kind="$(_wt_exe_kind "$archive")"
        [[ -n "$kind" ]] || { WT_ARCHIVE_ERROR="Not an installer cabextract or 7z can unpack: $archive"; return 1; }
    fi
    case "$kind" in
        tgz|txz|tzst|tbz2|tar)
            [[ "$kind" == tzst ]] && ! _wt_have zstd && { WT_ARCHIVE_ERROR="zstd is required for $archive"; return 1; }
            flags="$(_wt_tar_flags "$kind")"
            # shellcheck disable=SC2086
            listing="$(tar $flags -tf "$archive" 2>/dev/null)" || {
                WT_ARCHIVE_ERROR="Not a readable archive: $archive"; return 1; }
            if (( ! allow_links )); then
                # shellcheck disable=SC2086
                links="$(tar $flags -tvf "$archive" 2>/dev/null | grep -E '^[lh]' || true)"
            fi ;;
        zip)
            _wt_have unzip || { WT_ARCHIVE_ERROR="unzip is required for $archive"; return 1; }
            listing="$(unzip -Z1 -- "$archive" 2>/dev/null)" || {
                WT_ARCHIVE_ERROR="Not a readable zip archive: $archive"; return 1; }
            if (( ! allow_links )); then
                links="$(unzip -Z -- "$archive" 2>/dev/null | grep -E '^l' || true)"
            fi ;;
        7z)
            _wt_have 7z || { WT_ARCHIVE_ERROR="7z is required for $archive"; return 1; }
            listing="$(7z l -slt -- "$archive" 2>/dev/null | sed -n '/^----------$/,$ s/^Path = //p')" || {
                WT_ARCHIVE_ERROR="Not a readable 7z archive: $archive"; return 1; } ;;
        cab)
            _wt_have cabextract || { WT_ARCHIVE_ERROR="cabextract is required for $archive"; return 1; }
            listing="$(cabextract -l -- "$archive" 2>/dev/null | sed -n 's/^.* | .* | //p')" || {
                WT_ARCHIVE_ERROR="Not a readable cab archive: $archive"; return 1; } ;;
        *)
            WT_ARCHIVE_ERROR="Unsupported archive type: $archive"; return 1 ;;
    esac

    if [[ -z "$listing" ]]; then
        WT_ARCHIVE_ERROR="The archive is empty or unreadable: $archive"; return 1
    fi
    local -a bad=()
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        _wt_bad_member "$name" && bad+=("$name")
    done <<< "$listing"
    if [[ -n "$links" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && bad+=("link: ${name##* }")
        done <<< "$links"
    fi
    if (( ${#bad[@]} )); then
        WT_ARCHIVE_ERROR="$(printf 'Refusing to extract %s — it contains entries that could\nwrite outside the target folder:\n%s' \
            "$(basename "$archive")" "$(printf '  %s\n' "${bad[@]:0:8}")")"
        return 1
    fi
}

# wt_extract <archive> <dest_dir> [--allow-links]
#   wt_archive_check, then extract into <dest_dir> (created if needed).
wt_extract() {
    local archive="$1" dest="$2" opt="${3:-}"
    wt_archive_check "$archive" "$opt" || return 1
    mkdir -p "$dest" || { WT_ARCHIVE_ERROR="Cannot create $dest"; return 1; }

    local kind flags
    kind="$(_wt_archive_kind "$archive")"
    [[ "$kind" == exe ]] && kind="$(_wt_exe_kind "$archive")"
    case "$kind" in
        tgz|txz|tzst|tbz2|tar)
            flags="$(_wt_tar_flags "$kind")"
            # shellcheck disable=SC2086
            tar $flags -xf "$archive" -C "$dest" --no-same-owner 2>/dev/null ;;
        zip) unzip -qq -o -- "$archive" -d "$dest" ;;
        7z)  7z x -y -bd -o"$dest" -- "$archive" >/dev/null ;;
        cab) cabextract -q -d "$dest" -- "$archive" >/dev/null ;;
    esac || { WT_ARCHIVE_ERROR="Extraction failed: $(basename "$archive")"; return 1; }
}

# wt_extract_nested_cabs <dir>
#   Expands the cabinets found inside an extracted installer — the DirectX
#   redistributable keeps its DLLs one cabinet deeper — each into
#   <name>.cab.d/ next to it, checked like any other archive.
wt_extract_nested_cabs() {
    local dir="$1" cab n=0
    _wt_have cabextract || return 0
    while IFS= read -r -d '' cab; do
        n=$((n + 1))
        (( n > 400 )) && break
        wt_extract "$cab" "$cab.d" >/dev/null 2>&1 \
            || wt_log_warn "Skipped an unreadable cabinet: $(basename "$cab")"
    done < <(find "$dir" -maxdepth 4 -type f -iname '*.cab' -print0 2>/dev/null)
    return 0
}

# wt_extract_tree <archive> <dest> [--allow-links]
#   Extracts into a temporary folder next to <dest>, drops a single top-level
#   folder if the archive has one, and moves the result into place as <dest>
#   in one step — an interrupted extraction never leaves a half-filled
#   <dest>. <dest> must not exist yet.
wt_extract_tree() {
    local archive="$1" dest="${2%/}" opt="${3:-}"
    WT_ARCHIVE_ERROR=""
    if [[ -e "$dest" || -L "$dest" ]]; then
        WT_ARCHIVE_ERROR="Already exists: $dest"; return 1
    fi
    mkdir -p "$(dirname "$dest")" || { WT_ARCHIVE_ERROR="Cannot create $(dirname "$dest")"; return 1; }
    local stage
    stage="$(mktemp -d "${dest}.extract.XXXXXX")" || { WT_ARCHIVE_ERROR="Cannot create a temporary folder next to $dest"; return 1; }
    if ! wt_extract "$archive" "$stage" "$opt"; then
        rm -rf -- "$stage"
        return 1
    fi
    local -a top=()
    shopt -s nullglob dotglob
    top=("$stage"/*)
    shopt -u nullglob dotglob
    local src="$stage"
    if (( ${#top[@]} == 1 )) && [[ -d "${top[0]}" && ! -L "${top[0]}" ]]; then
        src="${top[0]}"
    fi
    if ! mv -T -- "$src" "$dest"; then
        rm -rf -- "$stage"
        WT_ARCHIVE_ERROR="Cannot move the extracted files to $dest"; return 1
    fi
    [[ -d "$stage" ]] && rm -rf -- "$stage"
    return 0
}

# =============================================================================
#  GITHUB RELEASE AUTO-DOWNLOADER
# =============================================================================

# Base directory where DXVK / VKD3D-Proton / DXVK-NVAPI releases are stored.
WT_RELEASE_BASE="${HOME}/winetoolz/dxvk-vkd3d_proton-files"

# _wt_release_ok <dir>  — a usable extracted release: has DLLs in x64/ x32/ x86/.
_wt_release_ok() {
    local d="$1" sub
    [[ -d "$d" && ! -L "$d" ]] || return 1
    for sub in x64 x32 x86; do
        if compgen -G "$d/$sub/*.dll" >/dev/null; then return 0; fi
    done
    return 1
}

# _wt_safe_name <string>  — a string made safe to use as one path component.
_wt_safe_name() {
    local s="${1//[^A-Za-z0-9._+-]/_}"
    s="${s#"${s%%[!.]*}"}"     # no leading dots: never ".", ".." or hidden
    printf '%s' "${s:-unnamed}"
}

# wt_ensure_release <tool_key> <github_repo> <asset_pattern>
#
#   Ensures a release for <tool_key> is present under $WT_RELEASE_BASE/<tool_key>/.
#   If a release directory already exists, asks the user whether to reuse it or
#   re-download the latest.  On success, exports WT_DLL_ROOT pointing at the
#   extracted release directory (the folder that contains x64/ x32/ etc.).
#
#   Downloads are verified against the sha256 GitHub publishes for the asset,
#   archives are checked before extraction, and a release only appears in the
#   store once it extracted completely.
#
#   Arguments:
#     tool_key       — short name used as the subdirectory  (e.g. "dxvk")
#     github_repo    — owner/repo on GitHub                 (e.g. "doitsujin/dxvk")
#     asset_pattern  — regex matching the tarball name      (e.g. "dxvk-[0-9]")
#
#   Requires: curl, tar, zenity
#
wt_ensure_release() {
    local tool_key="$1"
    local github_repo="$2"
    local asset_pattern="$3"

    local store_dir="$WT_RELEASE_BASE/$tool_key"
    wt_require_cmds curl tar
    mkdir -p "$store_dir"

    # --- Existing extracted releases (newest first) ---
    local -a existing=()
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] && _wt_release_ok "$d" && existing+=("$d")
    done < <(find "$store_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | sort -rV)

    if (( ${#existing[@]} )); then
        local existing_name
        existing_name="$(basename "${existing[0]}")"

        local choice
        choice=$(zenity --list \
            --title="$(wt_title "${tool_key}  ›  Existing Release Found")" \
            --text="$(_wt_box "$(printf 'An existing release was found:\n\n  %s\n\n─────────────────────────────────────\nWould you like to use it, or fetch the\nlatest release from GitHub?' "$existing_name")")" \
            --radiolist \
            --column="" --column="Option" --column="Details" \
            TRUE  "Use existing"     "$(printf 'Use:  %s' "$existing_name")" \
            FALSE "Download latest"  "Fetch the newest release from GitHub" \
            --width="$WT_WIDTH" --height=240) || return 1

        if [[ "$choice" == "Use existing" ]]; then
            export WT_DLL_ROOT="${existing[0]}"
            return 0
        fi
    fi

    # --- Fetch latest release metadata from GitHub API ---
    wt_pulse_start "${tool_key}  ›  Fetching Release Info" "Asking GitHub for the latest ${tool_key} release..."
    local gh_rc=0
    wt_github_latest "$github_repo" "$asset_pattern" || gh_rc=$?
    wt_pulse_stop
    if (( gh_rc != 0 )); then
        if (( ${#existing[@]} )) && wt_confirm "${tool_key}  ›  Offline" \
            "$(printf '%s\n\n─────────────────────────────────────\nUse the release you already have instead?\n\n  %s' "$WT_GH_ERROR" "$(basename "${existing[0]}")")"; then
            export WT_DLL_ROOT="${existing[0]}"
            return 0
        fi
        wt_error "$WT_GH_ERROR"
    fi

    local tag_name asset_url asset_name
    tag_name="$WT_GH_TAG"
    asset_url="$WT_GH_URL"
    asset_name="$(_wt_safe_name "$WT_GH_ASSET")"
    local extract_dir
    extract_dir="$store_dir/$(_wt_safe_name "${tool_key}-${tag_name}")"

    if _wt_release_ok "$extract_dir"; then
        wt_info "${tool_key}  ›  Up to Date" \
            "$(printf 'You already have the latest release:\n\n  %s  %s\n\nStored at:\n  %s' "$tool_key" "$tag_name" "$extract_dir")"
        export WT_DLL_ROOT="$extract_dir"
        return 0
    fi

    # --- Confirm download with user ---
    wt_confirm "${tool_key}  ›  Download Latest" \
        "$(printf 'Latest release found:\n\n  Tool    :  %s\n  Version :  %s\n  Asset   :  %s%s\n\n─────────────────────────────────────\nDownload and extract to:\n  %s' \
            "$tool_key" "$tag_name" "$asset_name" \
            "${WT_GH_SIZE:+$(printf '\n  Size    :  %s' "$(wt_human_size "$WT_GH_SIZE")")}" \
            "$extract_dir")" || return 1

    case "$(_wt_archive_kind "$asset_name")" in
        tzst)                  wt_require_cmds zstd ;;
        txz)                   wt_require_cmds xz ;;
        tgz|tbz2|tar)          ;;
        zip)                   wt_require_cmds unzip ;;
        *) wt_error "$(printf 'Unsupported release archive:\n  %s' "$asset_name")" ;;
    esac

    # --- Download (verified when GitHub publishes a digest) ---
    local archive="$store_dir/.downloads/$asset_name"
    local fetch_rc=0
    wt_fetch "$asset_url" "$archive" "$WT_GH_SHA256" "$tool_key $tag_name" "$WT_GH_SIZE" || fetch_rc=$?
    if (( fetch_rc == 130 )); then
        return 1
    elif (( fetch_rc != 0 )); then
        wt_error "$WT_FETCH_ERROR"
    fi

    # --- Extract into the store directory ---
    if ! wt_extract_tree "$archive" "$extract_dir"; then
        rm -f "$archive"
        wt_error "$(printf 'Failed to extract the %s release.\n\n%s' "$tool_key" "$WT_ARCHIVE_ERROR")"
    fi
    rm -f "$archive"
    rmdir "$store_dir/.downloads" 2>/dev/null || true

    if ! _wt_release_ok "$extract_dir"; then
        wt_error "$(printf 'The %s %s archive does not have the expected\nx64/ x32/ x86/ DLL folders:\n  %s' "$tool_key" "$tag_name" "$extract_dir")"
    fi

    wt_info "${tool_key}  ›  Download Complete" \
        "$(printf '✔  Downloaded and extracted:\n\n  %s  %s%s\n\nStored at:\n  %s' "$tool_key" "$tag_name" \
            "${WT_GH_SHA256:+$'\n  sha256 verified'}" "$extract_dir")"

    export WT_DLL_ROOT="$extract_dir"
}

# =============================================================================
#  WINE / PROTON BINARY RESOLUTION
# =============================================================================

# _wt_find_inner_wine <build_root>
#   The real wine binary inside a Proton / Neutron / Wine build folder.
#   Covers: Proton 5.13+ and GE-Proton (files/bin/), older Proton (dist/bin/)
#   and plain Wine builds (bin/). wine64 is tried after wine for each.
_wt_find_inner_wine() {
    local root="$1" c
    for c in files/bin/wine files/bin/wine64 dist/bin/wine dist/bin/wine64 bin/wine bin/wine64; do
        if [[ -f "$root/$c" && -x "$root/$c" ]]; then
            printf '%s\n' "$root/$c"
            return 0
        fi
    done
    return 1
}

# _wt_wrapper_in <build_root>
#   The Proton / Neutron wrapper script of a compatibility tool, if any.
_wt_wrapper_in() {
    local root="$1" w
    for w in proton neutron neutron.py; do
        if [[ -f "$root/$w" && -x "$root/$w" ]]; then
            printf '%s\n' "$root/$w"
            return 0
        fi
    done
    return 1
}

# _wt_find_wineserver <wine_binary>
_wt_find_wineserver() {
    local d c
    d="$(dirname "$1")"
    for c in "$d/wineserver" "$d/wineserver64"; do
        if [[ -f "$c" && -x "$c" ]]; then printf '%s\n' "$c"; return 0; fi
    done
    c="$(command -v wineserver 2>/dev/null || true)"
    if [[ -z "$c" ]]; then
        for c in /usr/lib/wine/wineserver /usr/lib/wine/wineserver64 /usr/lib64/wine/wineserver /opt/wine-stable/bin/wineserver; do
            [[ -x "$c" ]] && break
            c=""
        done
    fi
    printf '%s\n' "${c:-wineserver}"
}

# wt_wine_version <wine_binary> [build_root]
#   A short version string. Proton / Neutron builds report the version file
#   of the tool; anything else answers `wine --version`. Never runs a wrapper.
wt_wine_version() {
    local bin="$1" root="${2:-}" v=""
    if [[ -n "$root" && -f "$root/version" ]]; then
        v="$(sed -n '1{s/^[0-9]\{6,\} //;p}' "$root/version" 2>/dev/null)" || v=""
    fi
    if [[ -z "$v" && -x "$bin" ]]; then
        v="$(timeout 10 "$bin" --version 2>/dev/null </dev/null | sed -n 1p)" || v=""
    fi
    printf '%s' "${v:-version unknown}"
}

# _wt_resolve_wine_quiet <path>
#   wt_resolve_wine without the dialog: returns non-zero with the reason in
#   WT_RESOLVE_ERROR.
_wt_resolve_wine_quiet() {
    local raw="${1:-}" root="" inner="" wrapper=""
    WT_RESOLVE_ERROR=""

    if [[ -z "$raw" ]]; then
        WT_RESOLVE_ERROR="No Wine binary was selected."; return 1
    fi
    [[ "$raw" == \~/* ]] && raw="$HOME/${raw#\~/}"

    if [[ -d "$raw" ]]; then
        # A build folder: a Proton/Neutron tool or a plain Wine build.
        root="${raw%/}"
        wrapper="$(_wt_wrapper_in "$root" || true)"
        inner="$(_wt_find_inner_wine "$root" || true)"
        if [[ -z "$inner" ]]; then
            WT_RESOLVE_ERROR="$(printf 'No wine binary found inside:\n  %s\n\nSearched:\n  files/bin/wine[64]  dist/bin/wine[64]  bin/wine[64]' "$root")"
            return 1
        fi
    elif [[ ! -f "$raw" || ! -x "$raw" ]]; then
        WT_RESOLVE_ERROR="$(printf 'Binary is not executable or does not exist:\n  %s\n\nMake sure you selected the correct file.' "$raw")"
        return 1
    else
        case "$(basename "$raw")" in
            proton|neutron|neutron.py)
                # --- Proton / Neutron wrapper ---
                wrapper="$raw"
                root="$(dirname "$raw")"
                inner="$(_wt_find_inner_wine "$root" || true)"
                if [[ -z "$inner" ]]; then
                    WT_RESOLVE_ERROR="$(printf 'Found a %s wrapper at:\n  %s\n\nBut could not locate the inner wine binary.\nSearched:\n  files/bin/wine[64]  dist/bin/wine[64]  bin/wine[64]' "$(basename "$raw")" "$raw")"
                    return 1
                fi ;;
            *)
                # --- Inner wine of a Proton/Neutron tool, or a plain Wine ---
                inner="$raw"
                local up
                up="$(dirname "$(dirname "$raw")")"
                if wrapper="$(_wt_wrapper_in "$up")"; then
                    root="$up"
                elif [[ "$(basename "$up")" == files || "$(basename "$up")" == dist ]] \
                    && wrapper="$(_wt_wrapper_in "$(dirname "$up")")"; then
                    root="$(dirname "$up")"
                else
                    wrapper=""
                    root="$up"
                fi ;;
        esac
    fi

    WT_INNER_WINE="$inner"
    WT_WRAPPER="$wrapper"
    WT_WRAPPER_KIND=""
    if [[ -n "$wrapper" ]]; then
        WT_WRAPPER_KIND="$(basename "$wrapper")"
        WT_WRAPPER_KIND="${WT_WRAPPER_KIND%.py}"
    fi
    WT_WINE_ROOT="$root"
    WT_WINESERVER="$(_wt_find_wineserver "$inner")"
    export WT_INNER_WINE WT_WRAPPER WT_WRAPPER_KIND WT_WINE_ROOT WT_WINESERVER
}

# wt_resolve_wine <raw_bin_path>
#   Resolves a Proton/Neutron wrapper, a compatibility-tool or Wine build
#   folder, a Proton inner wine, or a plain Wine binary.
#   On success, exports:
#     WT_INNER_WINE   — the actual wine executable (what modules run)
#     WT_WRAPPER      — the proton/neutron wrapper (empty if plain Wine)
#     WT_WRAPPER_KIND — "proton", "neutron" or empty
#     WT_WINE_ROOT    — the build folder
#     WT_WINESERVER   — the wineserver that belongs to WT_INNER_WINE
#   On failure, calls wt_error and exits.
wt_resolve_wine() {
    if ! _wt_resolve_wine_quiet "${1:-}"; then
        wt_error "$WT_RESOLVE_ERROR"
    fi
}

# _wt_steam_roots — Steam installs (native, Debian, Flatpak, Snap), one per line.
_wt_steam_roots() {
    local r
    for r in "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.local/share/Steam" \
             "$HOME/.steam/debian-installation" \
             "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
             "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
             "$HOME/snap/steam/common/.local/share/Steam"; do
        if [[ -d "$r" ]]; then printf '%s\n' "$r"; fi
    done | _wt_dedupe_paths
}

# _wt_steam_libraries — every Steam library folder (has steamapps/).
_wt_steam_libraries() {
    local root vdf lib
    {
        while IFS= read -r root; do
            printf '%s\n' "$root"
            for vdf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
                if [[ -f "$vdf" ]]; then
                    sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf" \
                        | sed 's/\\\\/\\/g'
                fi
            done
        done < <(_wt_steam_roots)
    } | while IFS= read -r lib; do
        if [[ -n "$lib" && -d "$lib/steamapps" ]]; then printf '%s\n' "$lib"; fi
    done | _wt_dedupe_paths
}

# _wt_dedupe_paths — stdin paths, first spelling of each real path kept.
_wt_dedupe_paths() {
    local -A seen=()
    local line rp
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        rp="$(realpath -e -- "$line" 2>/dev/null || printf '%s' "$line")"
        [[ -n "${seen[$rp]:-}" ]] && continue
        seen[$rp]=1
        printf '%s\n' "$line"
    done
    return 0
}

# _wt_build_label <wine_binary>  — the build folder name for a bin/wine path.
_wt_build_label() {
    local d
    d="$(dirname "$(dirname "$1")")"
    case "$(basename "$d")" in files|dist) d="$(dirname "$d")" ;; esac
    basename "$d"
}

# _wt_wine_candidates
#   Every place a Wine / Proton / Neutron build is known to live, as
#   "<path>\t<description>" lines (unfiltered; wt_find_wine_builds checks them).
_wt_wine_candidates() {
    local p d root lib
    shopt -s nullglob

    # Custom Wine builds under ~/wine-custom/buildz/ and the mythix builder:
    # Proton-style tools (GE-Proton installed by the Runtime Manager lives in
    # buildz/<name>/files/bin) and plain builds.
    local buildz w
    for buildz in "$HOME/wine-custom/buildz" "$HOME/.local/share/mythix-wine_builder/buildz/install"; do
        [[ -d "$buildz" ]] || continue
        for d in "$buildz"/*/; do
            d="${d%/}"
            if w="$(_wt_wrapper_in "$d")"; then
                printf '%s\tCustom build  %s\n' "$w" "$(basename "$d")"
            fi
        done
        while IFS= read -r p; do
            printf '%s\tCustom build  %s\n' "$p" "$(_wt_build_label "$p")"
        done < <(find "$buildz" -mindepth 2 -maxdepth 4 -name wine -path '*/bin/wine' 2>/dev/null | sort -rV)
    done

    # Builds installed with the Wine Install Manager.
    for p in "$HOME"/.local/share/mythix-wine-installs/*/bin/wine; do
        printf '%s\tManaged  %s\n' "$p" "$(basename "$(dirname "$(dirname "$p")")")"
    done

    # Steam compatibility tools (GE-Proton, Neutron, ...), every Steam root,
    # system-wide tool folders and the Mythix launcher's own folder.
    {
        while IFS= read -r root; do printf '%s\n' "$root/compatibilitytools.d"; done < <(_wt_steam_roots)
        printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/mythix-launcher/compatibilitytools.d" \
            /usr/share/steam/compatibilitytools.d /usr/local/share/steam/compatibilitytools.d
    } | _wt_dedupe_paths | while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        for p in "$d"/*/; do
            p="${p%/}"
            local w
            if w="$(_wt_wrapper_in "$p")"; then
                printf '%s\t%s  %s\n' "$w" "$( [[ "$w" == */neutron* ]] && echo Neutron || echo Proton )" "$(basename "$p")"
            fi
        done | sort -t$'\t' -k2,2rV
    done

    # Valve's own Proton builds inside Steam libraries.
    while IFS= read -r lib; do
        for p in "$lib"/steamapps/common/Proton*/proton; do
            printf '%s\tSteam  %s\n' "$p" "$(basename "$(dirname "$p")")"
        done
    done < <(_wt_steam_libraries)

    # Other launchers' runners: Lutris, Heroic, Bottles (native and Flatpak).
    for p in "$HOME"/.local/share/lutris/runners/wine/*/bin/wine \
             "$HOME"/.var/app/net.lutris.Lutris/data/lutris/runners/wine/*/bin/wine; do
        printf '%s\tLutris  %s\n' "$p" "$(basename "$(dirname "$(dirname "$p")")")"
    done
    for p in "$HOME"/.local/share/lutris/runners/proton/*/proton \
             "$HOME"/.config/heroic/tools/proton/*/proton \
             "$HOME"/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton/*/proton; do
        printf '%s\tProton  %s\n' "$p" "$(basename "$(dirname "$p")")"
    done
    for p in "$HOME"/.config/heroic/tools/wine/*/bin/wine \
             "$HOME"/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/wine/*/bin/wine; do
        printf '%s\tHeroic  %s\n' "$p" "$(basename "$(dirname "$(dirname "$p")")")"
    done
    for p in "$HOME"/.local/share/bottles/runners/*/bin/wine \
             "$HOME"/.var/app/com.usebottles.bottles/data/bottles/runners/*/bin/wine; do
        printf '%s\tBottles  %s\n' "$p" "$(basename "$(dirname "$(dirname "$p")")")"
    done

    # WineHQ packages, then the distro's Wine.
    for p in /opt/wine-staging/bin/wine /opt/wine-devel/bin/wine /opt/wine-stable/bin/wine; do
        printf '%s\tWineHQ  %s\n' "$p" "$(basename "$(dirname "$(dirname "$p")")")"
    done
    for w in wine wine64; do
        p="$(command -v "$w" 2>/dev/null || true)"
        [[ -n "$p" ]] && printf '%s\tSystem  %s\n' "$p" "$w"
    done
    for p in /usr/lib/wine/wine64 /usr/lib/wine/wine /usr/lib64/wine/wine64; do
        printf '%s\tSystem  %s\n' "$p" "$p"
    done
    shopt -u nullglob
    return 0
}

# wt_find_wine_builds
#   The Wine / Proton / Neutron builds installed on this machine, one per
#   line: "<path>\t<description>\t<version>". A build reached through two
#   paths (two Steam roots, or a tool's wrapper and its inner wine) is
#   listed once.
wt_find_wine_builds() {
    local -A seen=()
    local path desc rp root
    while IFS=$'\t' read -r path desc; do
        [[ -n "$path" && -f "$path" && -x "$path" ]] || continue
        _wt_resolve_wine_quiet "$path" 2>/dev/null || continue
        rp="$(realpath -e -- "$WT_INNER_WINE" 2>/dev/null || printf '%s' "$WT_INNER_WINE")"
        [[ -n "${seen[$rp]:-}" ]] && continue
        seen[$rp]=1
        root=""
        [[ -n "$WT_WRAPPER" ]] && root="$WT_WINE_ROOT"
        printf '%s\t%s\t%s\n' "$path" "$desc" "$(wt_wine_version "$WT_INNER_WINE" "$root")"
    done < <(_wt_wine_candidates)
    WT_INNER_WINE="" WT_WRAPPER="" WT_WRAPPER_KIND="" WT_WINE_ROOT="" WT_WINESERVER=""
    return 0
}

# wt_select_wine_bin <module_name>
#   Scans well-known locations for Wine / Proton / Neutron builds, builds a
#   radio-list, pre-selects the build used last (or the first found), and
#   offers a "Custom..." browse fallback.
#   Exports WT_INNER_WINE and WT_WRAPPER (see wt_resolve_wine) on success.
#
#   Searched: ~/wine-custom/buildz and mythix builder output, Wine Install
#   Manager builds, Steam compatibilitytools.d (native, Flatpak, Snap,
#   system-wide, Mythix launcher), Steam's own Proton, Lutris / Heroic /
#   Bottles runners, /opt/wine-*, and wine / wine64 on $PATH.
wt_select_wine_bin() {
    local module="${1:-Wine Binary}"
    wt_load_config

    local -a rows=()
    local path desc ver pick default_set=""
    local last="${WT_LAST_WINE:-}"
    local -a builds=()
    mapfile -t builds < <(wt_find_wine_builds)

    if [[ -n "$last" ]]; then
        local b
        for b in "${builds[@]}"; do
            if [[ "${b%%$'\t'*}" == "$last" ]]; then default_set=1; break; fi
        done
    fi
    local b
    for b in "${builds[@]}"; do
        IFS=$'\t' read -r path desc ver <<< "$b"
        pick="FALSE"
        if [[ -n "$default_set" ]]; then
            [[ "$path" == "$last" ]] && pick="TRUE"
        elif [[ -z "${rows[*]-}" ]]; then
            pick="TRUE"
        fi
        rows+=("$pick" "$path" "$desc  —  $ver")
    done

    local custom_pick="FALSE"
    (( ${#rows[@]} )) || custom_pick="TRUE"
    rows+=("$custom_pick" "Custom..." "Browse for a Wine / Proton binary or build folder")

    local chosen
    while :; do
        chosen=$(zenity --list \
            --title="$(wt_title "$module  ›  Select Wine / Proton Binary")" \
            --text="$(_wt_box "$(printf 'Choose a Wine or Proton binary.\nDetected installs are listed below — select  Custom...  to browse.')")" \
            --radiolist \
            --column="" --column="Path" --column="Details" \
            --width=780 --height=380 \
            "${rows[@]}") || return 1
        chosen="${chosen%%|*}"

        if [[ "$chosen" == "Custom..." ]]; then
            chosen=$(zenity --file-selection \
                --title="$(wt_title "$module  ›  Browse for Wine / Proton Binary")" \
                --width="$WT_WIDTH") || continue
        fi
        [[ -n "$chosen" ]] || continue

        if _wt_resolve_wine_quiet "$chosen"; then
            break
        fi
        wt_error_return "$WT_RESOLVE_ERROR"
    done

    if [[ "$chosen" != "${WT_LAST_WINE:-}" ]]; then
        wt_config_set WT_LAST_WINE "$chosen" 2>/dev/null || true
    fi
}

# =============================================================================
#  PREFIX HELPERS
# =============================================================================

# wt_prefix_arch <prefix>  — win64 | win32, from system.reg's #arch= line.
wt_prefix_arch() {
    local p="$1" line=""
    line="$(grep -m1 -a '^#arch=' "$p/system.reg" 2>/dev/null)" || line=""
    line="${line#\#arch=}"
    line="${line%$'\r'}"
    case "$line" in
        win64|win32) printf '%s' "$line" ;;
        *) if [[ -d "$p/drive_c/windows/syswow64" ]]; then printf 'win64'; else printf 'win32'; fi ;;
    esac
}

# wt_is_win64 <prefix_path>
#   Returns 0 (true) if the prefix is 64-bit, 1 otherwise.
wt_is_win64() {
    [[ -d "$1/drive_c/windows/syswow64" ]]
}

# wt_prefix_resolve <path>
#   Prints the prefix a picked folder stands for: the folder itself, or its
#   pfx/ subfolder when it is a Steam/Proton compatdata folder.
wt_prefix_resolve() {
    local p="${1%/}"
    [[ -z "$p" ]] && p="/"
    if [[ ! -f "$p/system.reg" && -f "$p/pfx/system.reg" ]]; then
        p="$p/pfx"
    fi
    printf '%s' "$p"
}

# _wt_prefix_problem <prefix>
#   Prints why a folder is not a usable Wine prefix (nothing when it is).
_wt_prefix_problem() {
    local p="$1"
    if [[ ! -d "$p" ]]; then
        printf 'Not a folder:\n  %s' "$p"
    elif [[ ! -f "$p/system.reg" ]]; then
        printf 'Not a valid Wine prefix:\n  %s\n\nA valid prefix must contain a system.reg file.\nCreate one first via:  [ winetoolz :: Prefix :: Create Prefix ]' "$p"
    elif [[ ! -f "$p/drive_c/windows/system32/wineboot.exe" ]]; then
        printf 'Prefix appears uninitialised or broken:\n  %s\n\nwineboot.exe is missing from system32.\nThis prefix was likely never properly created.\n\nPlease create a fresh prefix via:\n  [ winetoolz :: Prefix :: Create Prefix ]' "$p"
    fi
    return 0
}

# _wt_steam_app_name <library> <appid>
_wt_steam_app_name() {
    local acf="$1/steamapps/appmanifest_$2.acf" n=""
    if [[ -f "$acf" ]]; then
        n="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" 2>/dev/null | sed -n 1p)" || n=""
    fi
    if [[ -z "$n" ]]; then
        if (( ${#2} >= 10 )); then n="Non-Steam game $2"; else n="Steam app $2"; fi
    fi
    printf '%s' "$n"
}

# _wt_mythix_games
#   Mythix launcher games as "<compat dir>\t<name>" lines (library.json).
_wt_mythix_games() {
    local lib="${XDG_DATA_HOME:-$HOME/.local/share}/mythix/library.json"
    [[ -f "$lib" ]] || return 0
    if _wt_have python3; then
        python3 -I - "$lib" "$HOME/.mythix/gamedata" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        games = json.load(f).get("games") or []
except Exception:
    sys.exit(0)
for g in games:
    cfg = g.get("config") or {}
    pfx = cfg.get("prefix_path") or os.path.join(sys.argv[2], str(g.get("id") or ""))
    name = (g.get("name") or "").replace("\t", " ").replace("\n", " ")
    if pfx and name:
        print(f"{pfx}\t{name}")
PY
    elif _wt_have jq; then
        jq -r --arg base "$HOME/.mythix/gamedata" \
            '.games[]? | [(.config.prefix_path // ($base + "/" + (.id|tostring))), .name] | @tsv' \
            "$lib" 2>/dev/null || true
    fi
    return 0
}

# wt_find_prefixes
#   Every Wine prefix winetoolz knows about, one per line:
#   "<prefix>\t<arch>\t<source>\t<label>". Sources: the folders in
#   WT_PREFIX_PATHS (and one level below), Mythix launcher games, Steam
#   (Proton) compatdata, Bottles and Heroic. Each prefix is listed once.
wt_find_prefixes() {
    wt_load_config
    local -A seen=() names=()
    local line p rp dir lib id label src

    # Mythix launcher game names, keyed by compat dir.
    while IFS=$'\t' read -r p label; do
        [[ -n "$p" ]] && names["$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"]="$label"
    done < <(_wt_mythix_games)

    _wt_emit_prefix() {   # <prefix> <source> <label>
        local pp="${1%/}" r
        [[ -f "$pp/system.reg" ]] || return 0
        r="$(realpath -e -- "$pp" 2>/dev/null || printf '%s' "$pp")"
        [[ -n "${seen[$r]:-}" ]] && return 0
        seen[$r]=1
        printf '%s\t%s\t%s\t%s\n' "$pp" "$(wt_prefix_arch "$pp")" "$2" "$3"
    }

    shopt -s nullglob
    local -a search_dirs=()
    IFS=':' read -r -a search_dirs <<< "${WT_PREFIX_PATHS:-}"
    for dir in "${search_dirs[@]}"; do
        dir="$(_wt_cfg_expand "$dir")"
        dir="${dir%/}"
        [[ -n "$dir" && -d "$dir" ]] || continue
        _wt_emit_prefix "$dir" "Configured" "$(basename "$dir")"
        for p in "$dir"/*/; do
            p="${p%/}"
            if [[ -f "$p/system.reg" ]]; then
                _wt_emit_prefix "$p" "Configured" "$(basename "$p")"
            elif [[ -f "$p/pfx/system.reg" ]]; then
                _wt_emit_prefix "$p/pfx" "Configured" "$(basename "$p")"
            fi
        done
    done

    # Mythix launcher: ~/.mythix/gamedata/<id>/pfx and custom prefix paths.
    for p in "$HOME"/.mythix/gamedata/*/; do
        p="${p%/}"
        rp="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
        _wt_emit_prefix "$p/pfx" "Mythix" "${names[$rp]:-$(basename "$p")}"
    done
    for rp in "${!names[@]}"; do
        _wt_emit_prefix "$rp/pfx" "Mythix" "${names[$rp]}"
    done

    # Steam / Proton compatdata, labelled with the game's name.
    while IFS= read -r lib; do
        for p in "$lib"/steamapps/compatdata/*/; do
            p="${p%/}"
            id="$(basename "$p")"
            [[ "$id" =~ ^[0-9]+$ && "$id" != 0 ]] || continue
            [[ -f "$p/pfx/system.reg" ]] || continue
            _wt_emit_prefix "$p/pfx" "Steam" "$(_wt_steam_app_name "$lib" "$id")"
        done
    done < <(_wt_steam_libraries)

    # The prefix used last, wherever it lives (a browsed-to folder).
    if [[ -n "${WT_LAST_PREFIX:-}" ]]; then
        _wt_emit_prefix "$WT_LAST_PREFIX" "Recent" "$(basename "$WT_LAST_PREFIX")"
    fi

    # Bottles and Heroic.
    for p in "$HOME"/.local/share/bottles/bottles/*/ \
             "$HOME"/.var/app/com.usebottles.bottles/data/bottles/bottles/*/; do
        _wt_emit_prefix "${p%/}" "Bottles" "$(basename "$p")"
    done
    for p in "$HOME"/Games/Heroic/Prefixes/default/*/; do
        p="${p%/}"
        if [[ -f "$p/pfx/system.reg" ]]; then
            _wt_emit_prefix "$p/pfx" "Heroic" "$(basename "$p")"
        else
            _wt_emit_prefix "$p" "Heroic" "$(basename "$p")"
        fi
    done
    shopt -u nullglob
    unset -f _wt_emit_prefix
    return 0
}

# wt_select_prefix <module_name>
#   Opens a directory-picker for WINEPREFIX selection. A Steam/Proton
#   compatdata folder is accepted too (its pfx/ is used). Validates the
#   prefix and asks again when the pick is not a usable prefix.
#   On success, exports WINEPREFIX.
wt_select_prefix() {
    local module="${1:-Select Prefix}"
    local path problem

    while :; do
        path=$(zenity --file-selection \
            --directory \
            --title="$(wt_title "$module  ›  Select WINEPREFIX")" \
            --width="$WT_WIDTH") || return 1
        path="$(wt_prefix_resolve "$path")"
        problem="$(_wt_prefix_problem "$path")"
        [[ -z "$problem" ]] && break
        wt_error_return "$problem"
    done

    export WINEPREFIX="$path"
    wt_config_set WT_LAST_PREFIX "$path" 2>/dev/null || true
}

# wt_select_prefix_from_config <module_name>
#   Lists every known prefix (see wt_find_prefixes) — the one used last on
#   top — and offers a directory picker for anything else. Falls back to the
#   picker straight away when nothing is found. Asks again when the pick is
#   not a usable prefix.
#   Exports WINEPREFIX on success (plus WT_PREFIX_SOURCE / WT_PREFIX_LABEL).
wt_select_prefix_from_config() {
    local module="${1:-Select Prefix}"
    wt_load_config

    local -a known=() rows=()
    mapfile -t known < <(wt_find_prefixes)

    local p arch src label last="${WT_LAST_PREFIX:-}" f
    local -a last_row=() other_rows=()
    for f in "${known[@]}"; do
        IFS=$'\t' read -r p arch src label <<< "$f"
        if [[ -n "$last" && "$p" == "$last" ]]; then
            last_row=("$p" "★ $label" "$arch" "$src" "$p")
        else
            other_rows+=("$p" "$label" "$arch" "$src" "$p")
        fi
    done
    rows=("${last_row[@]}" "${other_rows[@]}")

    local chosen="" problem
    while :; do
        chosen=""
        if (( ${#rows[@]} )); then
            chosen=$(zenity --list \
                --title="$(wt_title "$module  ›  Select Prefix")" \
                --text="$(_wt_box "$(printf 'Choose a Wine prefix.\nSelect  Browse...  to pick a folder not listed here.')")" \
                --column="Path" --column="Prefix" --column="Arch" --column="Source" --column="Location" \
                --hide-column=1 --print-column=1 \
                --width=860 --height=440 \
                "${rows[@]}" \
                "Browse..." "Browse for a prefix not listed above..." "" "" "") || return 1
            chosen="${chosen%%|*}"
        fi

        if [[ -z "$chosen" || "$chosen" == "Browse..." ]]; then
            chosen=$(zenity --file-selection \
                --directory \
                --title="$(wt_title "$module  ›  Browse for WINEPREFIX")" \
                --width="$WT_WIDTH") || { (( ${#rows[@]} )) && continue; return 1; }
        fi

        chosen="$(wt_prefix_resolve "$chosen")"
        problem="$(_wt_prefix_problem "$chosen")"
        [[ -z "$problem" ]] && break
        wt_error_return "$problem"
    done

    WT_PREFIX_SOURCE="" WT_PREFIX_LABEL="$(basename "$chosen")"
    for f in "${known[@]}"; do
        IFS=$'\t' read -r p arch src label <<< "$f"
        if [[ "$p" == "$chosen" ]]; then WT_PREFIX_SOURCE="$src" WT_PREFIX_LABEL="$label"; break; fi
    done
    export WINEPREFIX="$chosen" WT_PREFIX_SOURCE WT_PREFIX_LABEL
    if [[ "$chosen" != "${WT_LAST_PREFIX:-}" ]]; then
        wt_config_set WT_LAST_PREFIX "$chosen" 2>/dev/null || true
    fi
}

# wt_prefix_server_pids <prefix>
#   PIDs of the wineserver running for a prefix. wineserver works inside a
#   folder named server-<device>-<inode> after the prefix it serves, so it is
#   found by its working directory — whichever Wine or Proton started it.
wt_prefix_server_pids() {
    local pfx="$1" dev ino want p c
    dev="$(stat -c %d -- "$pfx" 2>/dev/null)" || return 0
    ino="$(stat -c %i -- "$pfx" 2>/dev/null)" || return 0
    want="$(printf 'server-%x-%x' "$dev" "$ino")"
    for p in /proc/[0-9]*; do
        c="$(readlink "$p/cwd" 2>/dev/null)" || continue
        if [[ "${c##*/}" == "$want" ]]; then printf '%s\n' "${p#/proc/}"; fi
    done
    return 0
}

# wt_prefix_running <prefix>  — true while Wine is running in the prefix.
wt_prefix_running() {
    [[ -n "$(wt_prefix_server_pids "$1")" ]]
}

# wt_kill_prefix [prefix]
#   Stops every Wine process of a prefix: `wineserver -k` with the very
#   wineserver binary that is serving it (so the protocol versions always
#   match), then makes sure the server is gone. Returns 0 when Wine was
#   stopped, 3 when nothing was running.
wt_kill_prefix() {
    local pfx="${1:-${WINEPREFIX:-}}" pid exe i
    [[ -n "$pfx" ]] || return 1
    local -a pids=()
    mapfile -t pids < <(wt_prefix_server_pids "$pfx")
    (( ${#pids[@]} )) || return 3
    for pid in "${pids[@]}"; do
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || exe=""
        exe="${exe% (deleted)}"
        if [[ -n "$exe" && -x "$exe" ]]; then
            WINEPREFIX="$pfx" "$exe" -k >/dev/null 2>&1 || true
        fi
    done
    for i in 1 2 3 4 5 6 7 8 9 10; do
        mapfile -t pids < <(wt_prefix_server_pids "$pfx")
        (( ${#pids[@]} )) || return 0
        sleep 0.3
    done
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
    return 0
}

# wt_reg_section <file.reg> <key>
#   The "name"="value" lines of one key in a Wine registry file (system.reg,
#   user.reg), read without starting Wine. <key> as in regedit, with single
#   backslashes: 'Software\Wine\DllOverrides'. Values are printed as
#   name<TAB>value (string values unescaped; others as stored).
wt_reg_section() {
    [[ -f "$1" ]] || return 0
    awk -v want="$2" '
        BEGIN { want = tolower(want) }
        /^\[/ {
            sec = $0; sub(/^\[/, "", sec); sub(/\][^]]*$/, "", sec)
            gsub(/\\\\/, "\\", sec)
            insec = (tolower(sec) == want)
            next
        }
        insec && /^"/ {
            line = $0
            if (match(line, /^"([^"\\]|\\.)*"=/)) {
                name = substr(line, 2, RLENGTH - 3)
                val = substr(line, RLENGTH + 1)
                if (val ~ /^"/) { sub(/^"/, "", val); sub(/"[[:space:]]*\r?$/, "", val)
                                  gsub(/\\"/, "\"", val); gsub(/\\\\/, "\\", val) }
                gsub(/\\\\/, "\\", name)
                printf "%s\t%s\n", name, val
            }
        }' "$1"
}

# wt_reg_value <file.reg> <key> <value_name>
#   One string value from a Wine registry file (empty when not set).
wt_reg_value() {
    local name val
    while IFS=$'\t' read -r name val; do
        if [[ "${name,,}" == "${3,,}" ]]; then printf '%s' "$val"; return 0; fi
    done < <(wt_reg_section "$1" "$2")
    return 0
}

# wt_wrapper_run <command...>
#   Runs a command through the selected Proton/Neutron wrapper the way Steam
#   does — `<wrapper> run <command>` with STEAM_COMPAT_DATA_PATH set to the
#   compatdata folder that holds $WINEPREFIX. Without that variable Proton
#   exits ("No compat data path?") and Neutron silently uses its own
#   ~/.wine-neutron-pfx instead of the selected prefix. Prefixes that are not
#   in compatdata layout (…/pfx) and plain Wine run the inner wine directly.
wt_wrapper_run() {
    if [[ -z "${WT_WRAPPER:-}" || "$(basename "${WINEPREFIX:-}")" != pfx ]]; then
        "$WT_INNER_WINE" "$@"
        return
    fi
    local steam=""
    steam="$(_wt_steam_roots | sed -n 1p)" || steam=""
    STEAM_COMPAT_DATA_PATH="$(dirname "$WINEPREFIX")" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$steam}" \
        "$WT_WRAPPER" run "$@"
}

# =============================================================================
#  DLL HELPERS  (for the modules and the scripts they run in a terminal)
# =============================================================================

# wt_pe_arch <file>
#   x64 | x86 | arm64 for a Windows PE file, from its COFF machine field;
#   returns 1 for anything else. Needs no `file` command.
wt_pe_arch() {
    local f="$1" hex off sig
    [[ "$(_wt_magic_hex "$f" 2)" == 4d5a ]] || return 1
    hex="$(LC_ALL=C od -An -tx1 -j 60 -N 4 -- "$f" 2>/dev/null | tr -d ' \n')"
    [[ ${#hex} -eq 8 ]] || return 1
    off=$(( 16#${hex:6:2}${hex:4:2}${hex:2:2}${hex:0:2} ))
    sig="$(LC_ALL=C od -An -tx1 -j "$off" -N 6 -- "$f" 2>/dev/null | tr -d ' \n')"
    [[ "${sig:0:8}" == 50450000 ]] || return 1
    case "${sig:10:2}${sig:8:2}" in
        8664) echo x64 ;;
        014c) echo x86 ;;
        aa64) echo arm64 ;;
        *)    return 1 ;;
    esac
}

# wt_dll_is_wine_builtin <file>
#   True for Wine's own DLLs: winebuild stamps "Wine builtin DLL" (wineboot
#   "Wine placeholder DLL") right after the DOS header.
wt_dll_is_wine_builtin() {
    [[ -f "$1" ]] || return 1
    grep -aq -e 'Wine builtin DLL' -e 'Wine placeholder DLL' < <(head -c 512 -- "$1" 2>/dev/null)
}

# wt_prefix_dll_dirs [prefix]
#   Sets WT_DLLDIR_64 / WT_DLLDIR_32 — where 64-bit and 32-bit DLLs belong:
#   system32 / syswow64 in a 64-bit prefix, "" / system32 in a 32-bit one.
#   (Asking `wine winepath C:\windows\system32` instead answers syswow64
#   whenever the 32-bit loader is the selected Wine.)
wt_prefix_dll_dirs() {
    local p="${1:-${WINEPREFIX:-}}"
    WT_DLLDIR_64="" WT_DLLDIR_32=""
    if [[ "$(wt_prefix_arch "$p")" == win64 ]]; then
        WT_DLLDIR_64="$p/drive_c/windows/system32"
        if [[ -d "$p/drive_c/windows/syswow64" ]]; then WT_DLLDIR_32="$p/drive_c/windows/syswow64"; fi
    else
        WT_DLLDIR_32="$p/drive_c/windows/system32"
    fi
    return 0
}

# wt_dll_put <source.dll> <dest_dir> [dest_name]
#   Copies a DLL into a prefix folder. The file it replaces is kept as
#   <name>.wt_bak the first time (a reinstall never overwrites that backup;
#   <name>.wt_bak_none records that there was nothing). A symlink in its place
#   — Proton links its own DLLs into prefixes — is replaced, never written
#   through. Returns 1 (reason logged) on failure.
wt_dll_put() {
    local src="$1" dir="$2"
    local name="${3:-$(basename "$1")}"
    local dst="$dir/$name"
    if [[ ! -f "$src" ]]; then wt_log_err "Not found: $src"; return 1; fi
    if [[ ! -d "$dir" ]]; then wt_log_err "Folder missing: $dir"; return 1; fi
    if [[ ! -e "$dst.wt_bak" && ! -L "$dst.wt_bak" && ! -e "$dst.wt_bak_none" ]]; then
        if [[ -L "$dst" || -f "$dst" ]]; then
            cp -P -p -- "$dst" "$dst.wt_bak" || { wt_log_err "Could not back up $dst"; return 1; }
        else
            : > "$dst.wt_bak_none"
        fi
    fi
    rm -f -- "$dst"
    cp -- "$src" "$dst" || { wt_log_err "Could not copy $name into $dir"; return 1; }
}

# wt_dll_restore <dest_dir> <name>
#   Undoes wt_dll_put. Wine's original (or Proton's symlink) goes back in
#   place; anything else in the backup — an earlier winetoolz overwrote its
#   backup on reinstall — is dropped. Returns 0 when Wine's own file is in
#   place, 2 when the DLL was removed and `wineboot -u` should bring Wine's
#   builtin copy back.
wt_dll_restore() {
    local dir="$1" name="$2"
    local dst="$dir/$name"
    if [[ -e "$dst.wt_bak" || -L "$dst.wt_bak" ]]; then
        if [[ -L "$dst.wt_bak" ]] || wt_dll_is_wine_builtin "$dst.wt_bak"; then
            rm -f -- "$dst"
            mv -f -- "$dst.wt_bak" "$dst"
            rm -f -- "$dst.wt_bak_none"
            return 0
        fi
        rm -f -- "$dst" "$dst.wt_bak" "$dst.wt_bak_none"
        return 2
    fi
    if [[ -e "$dst.wt_bak_none" ]]; then
        rm -f -- "$dst" "$dst.wt_bak_none"
        return 2
    fi
    if [[ -L "$dst" || ! -e "$dst" ]] || wt_dll_is_wine_builtin "$dst"; then
        return 0
    fi
    rm -f -- "$dst"
    return 2
}

# wt_dll_override <dll> <mode>
#   Sets HKCU\Software\Wine\DllOverrides\<dll> to <mode> (native,builtin |
#   builtin,native | native | builtin | disabled), or removes the override
#   when <mode> is "delete". Runs the selected Wine on $WINEPREFIX.
wt_dll_override() {
    local dll="$1" mode="$2" key='HKEY_CURRENT_USER\Software\Wine\DllOverrides'
    if [[ "$mode" == delete ]]; then
        "$WT_INNER_WINE" reg delete "$key" /v "$dll" /f >/dev/null 2>&1
    else
        "$WT_INNER_WINE" reg add "$key" /v "$dll" /d "$mode" /f >/dev/null 2>&1
    fi
}

# wt_vulkan_ok — true when a Vulkan driver (ICD) is installed.
wt_vulkan_ok() {
    local d
    for d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d /usr/local/share/vulkan/icd.d \
             "${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/icd.d"; do
        if compgen -G "$d/*.json" >/dev/null; then return 0; fi
    done
    return 1
}

# wt_dll_layer_apply
#   The install / uninstall step of the DXVK, VKD3D-Proton and DXVK-NVAPI
#   modules, run inside their terminal script. The job comes from the
#   environment:
#     WT_LAYER_NAME    display name ("DXVK")
#     WT_LAYER_ACTION  install | uninstall
#     WT_LAYER_DLLS64  DLL names (no .dll) for the 64-bit side
#     WT_LAYER_DLLS32  DLL names for the 32-bit side
#     WT_LAYER_SRC64   the release's 64-bit DLL folder (install)
#     WT_LAYER_SRC32   the release's 32-bit DLL folder (install)
#   plus WT_INNER_WINE and WINEPREFIX. Uses the prefix's own layout (32-bit
#   DLLs go to system32 in a 32-bit prefix), keeps Wine's originals as
#   backups, sets or removes the DLL overrides, and runs `wineboot -u` when
#   an uninstall needs Wine's builtin copies back. Returns 0 when every step
#   worked, 1 otherwise.
wt_dll_layer_apply() {
    local name="${WT_LAYER_NAME:-DLLs}" action="${WT_LAYER_ACTION:-install}"
    local -a d64=() d32=() side_dlls=()
    read -r -a d64 <<< "${WT_LAYER_DLLS64:-}"
    read -r -a d32 <<< "${WT_LAYER_DLLS32:-}"
    local fails=0 count=0 skipped=0 need_wineboot=0 n rc side dir src label
    local -A placed=()
    export WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="mscoree,mshtml="

    wt_prefix_dll_dirs "$WINEPREFIX"
    wt_section "$name  ›  $action"
    wt_log_info "Prefix   : $WINEPREFIX  ($(wt_prefix_arch "$WINEPREFIX"))"
    wt_log_info "Wine     : $WT_INNER_WINE"
    if [[ "$action" == install ]]; then
        wt_log_info "64-bit   : ${WT_LAYER_SRC64:-none}"
        wt_log_info "32-bit   : ${WT_LAYER_SRC32:-none}"
    fi
    printf '\n'

    for side in 64 32; do
        if [[ "$side" == 64 ]]; then
            dir="$WT_DLLDIR_64" src="${WT_LAYER_SRC64:-}" label="64-bit"
            side_dlls=("${d64[@]}")
        else
            dir="$WT_DLLDIR_32" src="${WT_LAYER_SRC32:-}" label="32-bit"
            side_dlls=("${d32[@]}")
        fi
        (( ${#side_dlls[@]} )) || continue
        if [[ -z "$dir" ]]; then
            wt_log_info "No $label system folder in this prefix — $label DLLs skipped."
            continue
        fi
        label="$label  $(basename "$dir")"
        for n in "${side_dlls[@]}"; do
            if [[ "$action" == install ]]; then
                if [[ -z "$src" || ! -f "$src/$n.dll" ]]; then
                    wt_log_info "$n.dll is not part of this release — skipped ($label)"
                    skipped=$((skipped + 1))
                    continue
                fi
                if wt_dll_put "$src/$n.dll" "$dir" "$n.dll"; then
                    wt_log_ok "$n  →  $label"
                    placed[$n]=1
                    count=$((count + 1))
                else
                    fails=$((fails + 1))
                fi
            else
                rc=0
                wt_dll_restore "$dir" "$n.dll" || rc=$?
                (( rc == 2 )) && need_wineboot=1
                wt_log_ok "restored  $n  in  $label"
                placed[$n]=1
                count=$((count + 1))
            fi
        done
    done

    if (( ${#placed[@]} )); then
        printf '\n'
        wt_log "DLL overrides..."
        for n in "${!placed[@]}"; do
            if [[ "$action" == install ]]; then
                if wt_dll_override "$n" native,builtin; then
                    wt_log_ok "$n = native,builtin"
                else
                    wt_log_err "Could not set the override for $n"
                    fails=$((fails + 1))
                fi
            else
                wt_dll_override "$n" delete || true
                wt_log_ok "$n override removed"
            fi
        done
    fi

    if (( need_wineboot )); then
        printf '\n'
        wt_log "Restoring Wine's own DLLs (wineboot -u)..."
        if "$WT_INNER_WINE" wineboot -u >/dev/null 2>&1; then
            wt_log_ok "wineboot -u done."
        else
            wt_log_err "wineboot -u reported an error — run Wine Tools › Update Prefix."
            fails=$((fails + 1))
        fi
    fi

    printf '\n'
    if (( fails )); then
        wt_section "$name $action: $count done, $fails failed${skipped:+, $skipped skipped}"
        return 1
    fi
    if (( count == 0 )); then
        wt_section "$name $action: nothing to do"
        [[ "$action" == install ]] && return 1
        return 0
    fi
    wt_section "$name $action complete: $count DLL(s)"
    return 0
}

# wt_dll_layer_run <module_name>
#   Runs wt_dll_layer_apply in a terminal (the WT_LAYER_* job must be set)
#   and reports the outcome in a dialog. Returns the step's result.
wt_dll_layer_run() {
    local module="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/wt-layer.XXXXXX.sh")" || return 1
    cat > "$tmp" <<'INNEREOF'
#!/usr/bin/env bash
set +e
source "$WT_LIB_PATH"
wt_dll_layer_apply
rc=$?
wt_pause
exit "$rc"
INNEREOF
    export WT_LAYER_NAME WT_LAYER_ACTION WT_LAYER_DLLS64 WT_LAYER_DLLS32 \
           WT_LAYER_SRC64 WT_LAYER_SRC32 WT_INNER_WINE WINEPREFIX
    wt_run_in_terminal "$tmp"
    rm -f "$tmp"
    if [[ "$WT_TERMINAL_RC" == 0 ]]; then
        wt_ok "$module" "$WT_LAYER_NAME $WT_LAYER_ACTION"
        return 0
    fi
    wt_warn "$module" "$(printf '%s %s did not complete.\n\nThe terminal output shows which step failed.\n\n  Prefix : %s' \
        "$WT_LAYER_NAME" "$WT_LAYER_ACTION" "$WINEPREFIX")"
    return 1
}

# wt_warn_managed_prefix <module_name> <what>
#   Proton and Neutron keep their own DXVK / VKD3D-Proton in the prefixes
#   they run and put them back every time the game starts. When the selected
#   prefix belongs to Steam or the Mythix launcher, say so and ask before
#   going on. Returns 1 when the user backs out.
wt_warn_managed_prefix() {
    local module="$1" what="$2"
    case "${WT_PREFIX_SOURCE:-}" in
        Steam|Mythix) ;;
        *) return 0 ;;
    esac
    wt_confirm "$module  ›  Managed Prefix" "$(printf 'This prefix belongs to a %s game:\n  %s\n\nIf the game runs through Proton or Neutron, they install\ntheir own %s into the prefix at every launch and will\nreplace what you install here. To change it for those\ngames, use the launch options (e.g. PROTON_USE_WINED3D=1)\nor pick a different compatibility tool instead.\n\n─────────────────────────────────────\nContinue anyway?' \
        "$WT_PREFIX_SOURCE" "${WT_PREFIX_LABEL:-$WINEPREFIX}" "$what")"
}

# =============================================================================
#  LAUNCH HELPERS
# =============================================================================

# wt_split_args <string>
#   Splits a command line into arguments, NUL-separated (mapfile -d ''):
#   "double" and 'single' quotes group, backslashes stay literal (Windows
#   paths), nothing is expanded or globbed.
wt_split_args() {
    [[ -n "${1:-}" ]] || return 0
    if _wt_have python3; then
        python3 -I -c '
import shlex, sys
lex = shlex.shlex(sys.argv[1], posix=True)
lex.whitespace_split = True
lex.escape = ""
lex.commenters = ""
try:
    args = list(lex)
except ValueError:
    args = sys.argv[1].split()
sys.stdout.write("".join(a + "\0" for a in args))' "$1"
    else
        local -a a=()
        read -r -a a <<< "$1"
        (( ${#a[@]} )) && printf '%s\0' "${a[@]}"
    fi
    return 0
}

# wt_env_apply <"VAR=value VAR2=value2">
#   Exports inline variables typed in a shortcut ("DXVK_HUD=fps
#   WINEDLLOVERRIDES='d3d11=n,b'"); anything that is not NAME=value is
#   skipped with a warning.
wt_env_apply() {
    local kv
    local -a pairs=()
    mapfile -d '' -t pairs < <(wt_split_args "${1:-}")
    for kv in "${pairs[@]}"; do
        if [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            export "${kv?}"
        else
            wt_log_warn "Ignoring \"$kv\" — not NAME=value"
        fi
    done
    return 0
}

# wt_source_env_profile <file>
#   Loads an Env Flags profile (shell syntax, normally `export NAME="value"`
#   lines) with every variable it sets exported. A profile with a syntax
#   error is reported and skipped instead of half-applied.
wt_source_env_profile() {
    local f="$1"
    if [[ ! -f "$f" ]]; then wt_log_err "Env profile not found: $f"; return 1; fi
    if ! bash -n "$f" 2>/dev/null; then wt_log_err "Env profile has a syntax error, skipped: $f"; return 1; fi
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
}

# wt_windows_cmd <file>
#   Sets the array WT_WINCMD to the wine arguments that run <file>: an .exe
#   directly; .bat .cmd .msi .lnk through `start /wait /unix` (cmd, msiexec
#   or the shortcut's target, waiting for it like a direct start).
wt_windows_cmd() {
    local f="$1"
    case "${f,,}" in
        *.bat|*.cmd|*.msi|*.lnk) WT_WINCMD=(start /wait /unix "$f") ;;
        *)                       WT_WINCMD=("$f") ;;
    esac
}

# =============================================================================
#  TERMINAL LAUNCHER
# =============================================================================

# _wt_terminal_order
#   Terminal emulators to try, best first: $WT_TERMINAL / $TERMINAL, the
#   desktop's own terminal, then everything else winetoolz knows.
_wt_terminal_order() {
    local -a order=()
    [[ -n "${WT_TERMINAL:-}" ]] && order+=("$WT_TERMINAL")
    [[ -n "${TERMINAL:-}" ]] && order+=("$TERMINAL")
    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*)              order+=(konsole) ;;
        *XFCE*)             order+=(xfce4-terminal) ;;
        *MATE*)             order+=(mate-terminal) ;;
        *LXQt*)             order+=(qterminal) ;;
        *LXDE*)             order+=(lxterminal) ;;
        *COSMIC*)           order+=(cosmic-term) ;;
        *Cinnamon*|*Budgie*|*Pantheon*) order+=(gnome-terminal) ;;
        *GNOME*|*Unity*)    order+=(ptyxis kgx gnome-terminal) ;;
    esac
    order+=(x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal ptyxis kgx
            tilix terminator kitty alacritty wezterm foot lxterminal qterminal cosmic-term xterm)
    printf '%s\n' "${order[@]}" | awk '!seen[$0]++'
}

# _wt_terminal_argv <terminal> <wrapper_script>
#   Prints the argv (one per line) that opens <terminal> running the script.
_wt_terminal_argv() {
    local t="$1" s="$2" name
    name="$(basename "$t")"
    case "$name" in
        gnome-terminal)  printf '%s\n' "$t" --wait -- bash "$s" ;;
        ptyxis)          printf '%s\n' "$t" --new-window -- bash "$s" ;;
        kgx)             printf '%s\n' "$t" -- bash "$s" ;;
        konsole)         printf '%s\n' "$t" --nofork -e bash "$s" ;;
        xfce4-terminal)  printf '%s\n' "$t" --disable-server -x bash "$s" ;;
        mate-terminal)   printf '%s\n' "$t" --disable-factory -x bash "$s" ;;
        terminator)      printf '%s\n' "$t" -x bash "$s" ;;
        tilix|lxterminal|qterminal)
                         printf '%s\n' "$t" -e "bash $(printf '%q' "$s")" ;;
        kitty|foot)      printf '%s\n' "$t" bash "$s" ;;
        wezterm)         printf '%s\n' "$t" start --always-new-process -- bash "$s" ;;
        *)               printf '%s\n' "$t" -e bash "$s" ;;
    esac
}

# wt_run_in_terminal <script_path>
#   Runs a bash script in a terminal window and waits until it has finished —
#   even with terminals that hand the window to an already-running instance
#   and return at once (gnome-terminal server, xfce4-terminal, tilix, ...) —
#   so callers can rely on the work being done (and on their EXIT trap not
#   deleting the script under it). The script's exit code is left in
#   WT_TERMINAL_RC; the function itself returns 0, or calls wt_error when no
#   terminal could be opened at all. Without any terminal emulator it runs
#   the script right here if winetoolz itself was started from a terminal.
#   Set WT_TERMINAL to pick the terminal explicitly.
wt_run_in_terminal() {
    local script="$1"
    WT_TERMINAL_RC=""

    local state
    state="$(mktemp -d "${TMPDIR:-/tmp}/wt-term.XXXXXX")" || wt_error "Cannot create a temporary folder."
    local wrapper="$state/run.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# winetoolz: runs %s and reports back when it is done\n' "$(printf '%q' "$script")"
        printf 'state=%q\n' "$state"
        printf 'export WT_IN_TERMINAL=1\n'
        printf 'if command -v flock >/dev/null 2>&1; then exec 9>"$state/lock"; flock -n 9 || true; fi\n'
        printf ': > "$state/started"\n'
        printf 'trap '\''printf "%%s\\n" 129 > "$state/status"; exit 129'\'' HUP TERM\n'
        printf 'bash %q 9>&-\n' "$script"
        printf 'rc=$?\n'
        printf 'printf "%%s\\n" "$rc" > "$state/status"\n'
        printf 'exit "$rc"\n'
    } > "$wrapper"
    chmod +x "$wrapper"

    local term tbin="" launched=0 t0 trc
    while IFS= read -r term; do
        [[ -n "$term" ]] || continue
        tbin="$(command -v "$term" 2>/dev/null || true)"
        [[ -n "$tbin" ]] || continue

        local -a argv=()
        mapfile -t argv < <(_wt_terminal_argv "$tbin" "$wrapper")
        "${argv[@]}" >/dev/null 2>&1 </dev/null &
        local tpid=$!
        t0=$SECONDS
        trc=""
        # Wait for the script to start (the terminal may need a moment, or
        # may fail to open at all), then for it to finish.
        while :; do
            [[ -s "$state/status" ]] && break
            if [[ -e "$state/started" ]]; then
                launched=1
                if _wt_have flock && flock -n "$state/lock" true 2>/dev/null; then
                    # Nobody holds the lock any more: the script is gone.
                    sleep 0.3
                    [[ -s "$state/status" ]] || printf '%s\n' 130 > "$state/status"
                    break
                fi
            else
                if [[ -z "$trc" ]] && ! kill -0 "$tpid" 2>/dev/null; then
                    trc=0
                    wait "$tpid" 2>/dev/null || trc=$?
                fi
                if [[ -n "$trc" && "$trc" != 0 ]] && (( SECONDS - t0 >= 2 )); then break; fi
                if (( SECONDS - t0 >= 30 )); then break; fi
            fi
            sleep 0.25
        done
        if [[ -e "$state/started" ]]; then launched=1; break; fi
        kill "$tpid" 2>/dev/null || true
    done < <(_wt_terminal_order)

    if (( ! launched )); then
        if [[ -t 0 && -t 1 ]]; then
            bash "$script" || WT_TERMINAL_RC=$?
            WT_TERMINAL_RC="${WT_TERMINAL_RC:-0}"
            rm -rf -- "$state"
            return 0
        fi
        rm -rf -- "$state"
        wt_error "$(printf 'No supported terminal emulator could be opened.\n\nPlease install one of the following:\n  gnome-terminal, konsole, xfce4-terminal, kitty, xterm\n\nor set WT_TERMINAL to your terminal, or run the script manually:\n  bash %s' "$script")"
    fi

    WT_TERMINAL_RC="$(sed -n 1p "$state/status" 2>/dev/null || true)"
    WT_TERMINAL_RC="${WT_TERMINAL_RC:-0}"
    rm -rf -- "$state"
    return 0
}
