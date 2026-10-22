#!/usr/bin/env bash
# winetoolz test harness — source it from a test script.
#
#   wt_kit_setup            isolated HOME/XDG dirs, mock zenity + terminal on
#                           PATH, the system Wine on PATH even when it lives
#                           outside it (Debian/Ubuntu: /usr/lib/wine)
#   wt_kit_answer C [OUT]   queue the next interactive zenity answer: exit
#                           code C (0 = OK/yes, 1 = cancel/no) and its stdout
#   wt_kit_run SCRIPT ...   run a winetoolz script non-interactively (timeout)
#   wt_kit_log              the mock's call log (CALL/ANSWER/TERMINAL/...)
#   wt_kit_terminal_log     what the scripts run "in a terminal" printed
#   wt_kit_markup_ok        fails if any dialog had broken Pango markup
#   wt_kit_teardown         remove everything the test made
#
# Example:
#   source tests/kit/harness.sh; wt_kit_setup
#   wt_kit_answer 0 "cat_exit"
#   wt_kit_run "$WT_ROOT/wine_toolz.sh"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
export WT_ROOT

wt_kit_setup() {
    KIT_TMP="$(mktemp -d)"
    export KIT_TMP
    export HOME="$KIT_TMP/home"
    mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" \
           XDG_CACHE_HOME="$HOME/.cache"
    export ZMOCK_LOG="$KIT_TMP/zenity.log" ZMOCK_QUEUE="$KIT_TMP/zenity.queue"
    export KIT_TERM_LOG="$KIT_TMP/terminal.log"
    : > "$ZMOCK_LOG"
    : > "$ZMOCK_QUEUE"
    : > "$KIT_TERM_LOG"

    # Wine: Debian/Ubuntu ship the real binaries in /usr/lib/wine without a
    # wine on PATH unless the wine/wine64 wrapper packages are installed.
    local shim="$KIT_TMP/bin"
    mkdir -p "$shim"
    if ! command -v wine >/dev/null 2>&1; then
        local d
        for d in /usr/lib/wine /usr/lib64/wine /opt/wine-stable/bin; do
            if [[ -x "$d/wine64" ]]; then
                ln -sf "$d/wine64" "$shim/wine"
                ln -sf "$d/wine64" "$shim/wine64"
                [[ -x "$d/wineserver" ]] && ln -sf "$d/wineserver" "$shim/wineserver"
                break
            fi
        done
    fi
    export PATH="$KIT_DIR/bin:$shim:$PATH"
    export WINEDEBUG=-all
    unset DISPLAY WAYLAND_DISPLAY
}

wt_kit_answer() { printf '%s\t%s\n' "$1" "${2:-}" >> "$ZMOCK_QUEUE"; }

wt_kit_run() { timeout "${KIT_TIMEOUT:-120}" bash "$@" </dev/null; }

wt_kit_log() { cat "$ZMOCK_LOG"; }

wt_kit_markup_ok() {
    if grep -q '^MARKUP_ERROR' "$ZMOCK_LOG"; then
        grep '^MARKUP_ERROR' "$ZMOCK_LOG" >&2
        return 1
    fi
    return 0
}

wt_kit_terminal_log() { cat "$KIT_TERM_LOG" 2>/dev/null || true; }

wt_kit_teardown() {
    if command -v wineserver >/dev/null 2>&1; then
        WINEPREFIX="${WINEPREFIX:-}" wineserver -k 2>/dev/null || true
    fi
    if [[ -n "${KIT_TMP:-}" && -d "$KIT_TMP" ]]; then rm -rf "$KIT_TMP"; fi
    return 0
}
