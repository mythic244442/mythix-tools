#!/usr/bin/env bash
# Unit tests for modules/winetoolz-lib.sh.
#
#   bash tests/test_lib.sh            run everything
#   bash tests/test_lib.sh fetch      run only tests whose name contains "fetch"
#
# Each test runs in its own subshell under `set -euo pipefail` — the way the
# modules source the library — with an isolated HOME, the mock zenity and the
# mock terminal from tests/kit.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FILTER="${1:-}"
# shellcheck source=kit/testlib.sh
source "$TESTS_DIR/kit/testlib.sh"

# =============================================================================
#  Dialogs
# =============================================================================

test_zenity_locale_shim() {
    export LANG=C LC_ALL="" LC_CTYPE=""
    unset LC_ALL LC_CTYPE
    mkdir -p "$KIT_TMP/lbin"
    printf '#!/bin/sh\necho "LC_ALL=$LC_ALL" >> "%s/lc.log"\n' "$KIT_TMP" > "$KIT_TMP/lbin/zenity"
    chmod +x "$KIT_TMP/lbin/zenity"
    export PATH="$KIT_TMP/lbin:$PATH"
    wt_info "x" "y"
    LANG=en_US.UTF-8 wt_info "x" "y"
    assert_eq $'LC_ALL=C.UTF-8\nLC_ALL=' "$(cat "$KIT_TMP/lc.log")"
}

test_markup_escape() {
    assert_eq 'a&amp;b&lt;c&gt;d &amp;&amp;' "$(wt_markup_escape 'a&b<c>d &&')"
    assert_eq '' "$(wt_markup_escape '')"
}

test_dialogs_escape_paths() {
    wt_info "Info" 'Saved to /home/u/Rock & Roll <Beta>/save'
    wt_error_return 'Bad prefix: /games/Tom & Jerry'
    wt_warn "Warn" '<not a tag>'
    wt_kit_answer 0
    wt_confirm "Q" 'Delete "A&B"?'
    wt_kit_answer 1
    if wt_confirm "Q" 'Again?'; then fail "confirm should return 1 on No"; fi
    wt_ok "Mod" 'Install of R&D tools'
    log_has 'Rock &amp; Roll &lt;Beta&gt;'
}

test_info_returns_zero_on_esc() {
    # A dialog closed with Esc must not abort a set -e module.
    export ZMOCK_STRICT=1
    wt_kit_answer 1
    wt_info "Info" "closed with Esc"
    wt_kit_answer 1
    wt_error_return "closed with Esc"
}

test_error_exits_one() {
    local rc=0
    ( wt_error "boom & bust" ) || rc=$?
    assert_eq 1 "$rc" "wt_error exit code"
}

# =============================================================================
#  Config
# =============================================================================

test_config_created_with_defaults() {
    wt_load_config
    [[ -f "$WT_CONFIG_FILE" ]] || fail "config file not created"
    assert_eq "$HOME/.wine:$HOME/prefixes" "$WT_PREFIX_PATHS"
    assert_contains "$WT_BACKUP_DIR" "mythix-winetoolz/backups"
}

test_config_is_parsed_not_executed() {
    mkdir -p "$(dirname "$WT_CONFIG_FILE")"
    cat > "$WT_CONFIG_FILE" <<EOF
# hand edited
WT_PREFIX_PATHS="\$HOME/games:~/more"
WT_BACKUP_DIR=~/bk   # trailing comment
export WT_TERMINAL='kitty'
WT_EVIL=\$(touch $KIT_TMP/pwned)
WT_EVIL2="\`touch $KIT_TMP/pwned2\`"
PATH=/nonexistent
  WT_SPACED="has spaces"
EOF
    wt_load_config
    assert_eq "$HOME/games:$HOME/more" "$WT_PREFIX_PATHS" "WT_PREFIX_PATHS"
    assert_eq "$HOME/bk" "$WT_BACKUP_DIR" "WT_BACKUP_DIR"
    assert_eq "kitty" "$WT_TERMINAL" "WT_TERMINAL"
    assert_eq "has spaces" "$WT_SPACED" "WT_SPACED"
    [[ ! -e "$KIT_TMP/pwned" && ! -e "$KIT_TMP/pwned2" ]] || fail "config line was executed"
    [[ "$PATH" != /nonexistent ]] || fail "non-WT key was applied"
}

test_config_set_roundtrip() {
    wt_load_config
    wt_config_set WT_LAST_PREFIX '/games/A "quoted" $dollar `tick` \back'
    wt_config_set WT_LAST_PREFIX '/games/B & C'
    wt_config_set WT_OTHER 'x'
    local n
    n="$(grep -c '^WT_LAST_PREFIX=' "$WT_CONFIG_FILE")"
    assert_eq 1 "$n" "WT_LAST_PREFIX lines"
    unset WT_LAST_PREFIX
    wt_load_config
    assert_eq '/games/B & C' "$WT_LAST_PREFIX"
    wt_config_set WT_ODD '/a "q" $HOME `t` \b'
    unset WT_ODD
    wt_load_config
    assert_eq '/a "q" $HOME `t` \b' "$WT_ODD" "special characters survive"
    # The file must still be valid shell for older winetoolz versions.
    # shellcheck disable=SC1090
    ( set +u; source "$WT_CONFIG_FILE"; [[ "$WT_ODD" == '/a "q" $HOME `t` \b' ]] ) || fail "config not sourceable"
    if wt_config_set WT_BAD $'two\nlines' 2>/dev/null; then fail "multi-line value accepted"; fi
    if wt_config_set 'BAD KEY' x 2>/dev/null; then fail "bad key accepted"; fi
}

# =============================================================================
#  Safe delete
# =============================================================================

test_safe_rmrf_refusals() {
    local d
    for d in "" "relative/path" "/" "$HOME" "$(dirname "$HOME")" "/usr/share/doc" "/etc/x" "/tmp/x"; do
        if wt_safe_rmrf "$d" system.reg; then fail "deleted [$d]"; fi
    done
    mkdir -p "$HOME/real/pfx"; fake_prefix "$HOME/real/pfx"
    ln -s "$HOME/real/pfx" "$HOME/link"
    if wt_safe_rmrf "$HOME/link" system.reg; then fail "followed a symlink"; fi
    assert_contains "$WT_RMRF_ERROR" "symlink"
    mkdir -p "$HOME/Documents/keep"
    if wt_safe_rmrf "$HOME/Documents" system.reg; then fail "deleted a non-prefix"; fi
    [[ -d "$HOME/Documents/keep" ]] || fail "Documents was touched"
    if wt_safe_rmrf "$HOME/Documents"; then fail "deleted outside managed roots"; fi
}

test_safe_rmrf_deletes() {
    fake_prefix "$HOME/prefixes/game one"
    wt_safe_rmrf "$HOME/prefixes/game one" system.reg || fail "$WT_RMRF_ERROR"
    [[ ! -e "$HOME/prefixes/game one" ]] || fail "prefix still there"
    mkdir -p "$WT_RELEASE_BASE/dxvk/dxvk-v1/x64"
    wt_safe_rmrf "$WT_RELEASE_BASE/dxvk/dxvk-v1" || fail "$WT_RMRF_ERROR"
    [[ ! -e "$WT_RELEASE_BASE/dxvk/dxvk-v1" ]] || fail "release still there"
    wt_safe_rmrf "$HOME/does/not/exist" system.reg || fail "missing path should be fine"
}

# =============================================================================
#  Downloads
# =============================================================================

start_http() {  # serves $1 on 127.0.0.1; sets HTTP_PORT
    HTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$1" >/dev/null 2>&1 &
    HTTP_PID=$!
    for _ in $(seq 50); do
        curl -s -o /dev/null "http://127.0.0.1:$HTTP_PORT/" && return 0
        sleep 0.1
    done
    fail "http server did not start"
}

test_fetch_refuses_insecure() {
    local rc=0
    wt_fetch "http://example.com/x.exe" "$HOME/x.exe" || rc=$?
    assert_eq 2 "$rc" "plain http refused"
    rc=0
    wt_fetch "file:///etc/passwd" "$HOME/p" || rc=$?
    assert_eq 2 "$rc" "file:// refused"
    [[ ! -e "$HOME/x.exe" && ! -e "$HOME/p" ]] || fail "file written"
}

test_fetch_verifies_checksum() {
    local srv="$KIT_TMP/srv"
    mkdir -p "$srv"
    head -c 300000 /dev/urandom > "$srv/blob.bin"
    local sum
    sum="$(sha256sum "$srv/blob.bin")"; sum="${sum%% *}"
    start_http "$srv"
    export WT_ALLOW_HTTP=1
    wt_fetch "http://127.0.0.1:$HTTP_PORT/blob.bin" "$HOME/dl/blob.bin" "sha256:${sum^^}" "blob" 300000 \
        || fail "good download failed: $WT_FETCH_ERROR"
    cmp -s "$srv/blob.bin" "$HOME/dl/blob.bin" || fail "content differs"

    local rc=0
    wt_fetch "http://127.0.0.1:$HTTP_PORT/blob.bin" "$HOME/dl/bad.bin" "$(printf '0%.0s' {1..64})" || rc=$?
    assert_eq 3 "$rc" "checksum mismatch code"
    [[ ! -e "$HOME/dl/bad.bin" ]] || fail "mismatched download kept"
    rc=0
    wt_fetch "http://127.0.0.1:$HTTP_PORT/missing.bin" "$HOME/dl/missing.bin" || rc=$?
    assert_eq 1 "$rc" "404 code"
    [[ ! -e "$HOME/dl/missing.bin" ]] || fail "404 left a file"
    compgen -G "$HOME/dl/*.part.*" >/dev/null && fail "partial files left behind"
    kill "$HTTP_PID" 2>/dev/null
    return 0
}

test_safe_name() {
    assert_eq "unnamed" "$(_wt_safe_name "..")"
    assert_eq "unnamed" "$(_wt_safe_name ".")"
    assert_eq "unnamed" "$(_wt_safe_name "")"
    assert_eq "hidden" "$(_wt_safe_name "...hidden")"
    assert_eq "_.._etc_passwd" "$(_wt_safe_name "/../etc/passwd")"
    assert_eq "GE-Proton10-20" "$(_wt_safe_name "GE-Proton10-20")"
}

test_archive_check_7z_links() {
    command -v 7z >/dev/null 2>&1 || { echo "  (skipped: no 7z)"; return 0; }
    local d="$KIT_TMP/7z"
    mkdir -p "$d/src"
    printf 'x' > "$d/src/a.dll"
    ln -s /etc "$d/src/escape"
    (cd "$d/src" && 7z a -snl "$d/links.7z" a.dll escape >/dev/null && 7z a "$d/plain.7z" a.dll >/dev/null)
    wt_archive_check "$d/plain.7z" || fail "plain 7z refused: $WT_ARCHIVE_ERROR"
    if wt_archive_check "$d/links.7z"; then fail "7z with a symlink accepted"; fi
    assert_contains "$WT_ARCHIVE_ERROR" "link: escape"
}

test_file_is() {
    printf 'MZ\x90\x00' > "$HOME/a.exe"
    printf '<html>nope</html>' > "$HOME/b.exe"
    wt_file_is "$HOME/a.exe" pe || fail "PE not detected"
    if wt_file_is "$HOME/b.exe" pe; then fail "HTML taken for PE"; fi
}

gh_json() {
    cat <<'JSON'
{"tag_name":"v2.7.1","assets":[
 {"name":"dxvk-2.7.1.tar.gz.sha256","browser_download_url":"https://github.com/doitsujin/dxvk/releases/download/v2.7.1/dxvk-2.7.1.tar.gz.sha256","size":90,"digest":"sha256:aaaa"},
 {"name":"dxvk-native-2.7.1-steamrt-sniper.tar.gz","browser_download_url":"https://github.com/doitsujin/dxvk/releases/download/v2.7.1/dxvk-native-2.7.1-steamrt-sniper.tar.gz","size":5,"digest":"sha256:bbbb"},
 {"name":"dxvk-2.7.1.tar.gz","browser_download_url":"https://github.com/doitsujin/dxvk/releases/download/v2.7.1/dxvk-2.7.1.tar.gz","size":10485760,"digest":"sha256:cccc"}]}
JSON
}

test_github_latest_parsers() {
    curl() { gh_json; }
    local mode
    for mode in jq python grep; do
        case "$mode" in
            jq)     _wt_have() { command -v "$1" >/dev/null 2>&1; } ;;
            python) _wt_have() { [[ "$1" != jq ]] && command -v "$1" >/dev/null 2>&1; } ;;
            grep)   _wt_have() { [[ "$1" != jq && "$1" != python3 ]] && command -v "$1" >/dev/null 2>&1; } ;;
        esac
        wt_github_latest "doitsujin/dxvk" "dxvk-[0-9]" || fail "$mode: $WT_GH_ERROR"
        assert_eq "v2.7.1" "$WT_GH_TAG" "$mode tag"
        assert_eq "dxvk-2.7.1.tar.gz" "$WT_GH_ASSET" "$mode asset"
        assert_eq "https://github.com/doitsujin/dxvk/releases/download/v2.7.1/dxvk-2.7.1.tar.gz" "$WT_GH_URL" "$mode url"
        if [[ "$mode" != grep ]]; then
            assert_eq "cccc" "$WT_GH_SHA256" "$mode sha"
            assert_eq "10485760" "$WT_GH_SIZE" "$mode size"
        fi
    done
    if wt_github_latest "not a repo" "x"; then fail "bad repo accepted"; fi
}

# =============================================================================
#  Archives
# =============================================================================

make_archives() {  # builds test archives with python's tarfile/zipfile into $1
    python3 -I - "$1" <<'PY'
import io, os, sys, tarfile, zipfile
d = sys.argv[1]
def add(t, name, data=b"x", kind=None, target=""):
    ti = tarfile.TarInfo(name)
    if kind == "sym":
        ti.type, ti.linkname = tarfile.SYMTYPE, target
        t.addfile(ti)
    elif kind == "dir":
        ti.type = tarfile.DIRTYPE; ti.mode = 0o755
        t.addfile(ti)
    else:
        ti.size = len(data); ti.mode = 0o644
        t.addfile(ti, io.BytesIO(data))
with tarfile.open(os.path.join(d, "good.tar.gz"), "w:gz") as t:
    add(t, "dxvk-9.9", kind="dir"); add(t, "dxvk-9.9/x64", kind="dir")
    add(t, "dxvk-9.9/x64/d3d11.dll", b"MZdll"); add(t, "dxvk-9.9/x32", kind="dir")
    add(t, "dxvk-9.9/x32/d3d11.dll", b"MZdll32")
with tarfile.open(os.path.join(d, "flat.tar.xz"), "w:xz") as t:
    add(t, "x64/d3d12.dll", b"MZ"); add(t, "x86/d3d12.dll", b"MZ")
with tarfile.open(os.path.join(d, "dotdot.tar.gz"), "w:gz") as t:
    add(t, "ok/file.txt"); add(t, "ok/../../outside.txt")
with tarfile.open(os.path.join(d, "absolute.tar.gz"), "w:gz") as t:
    add(t, "/tmp/abs.txt")
with tarfile.open(os.path.join(d, "link.tar.gz"), "w:gz") as t:
    add(t, "pkg/lib/real.so"); add(t, "pkg/lib/alias.so", kind="sym", target="real.so")
with zipfile.ZipFile(os.path.join(d, "good.zip"), "w") as z:
    z.writestr("x64/a.dll", "MZ")
with zipfile.ZipFile(os.path.join(d, "dotdot.zip"), "w") as z:
    z.writestr("../evil.dll", "MZ")
PY
}

test_archive_checks() {
    local a="$KIT_TMP/arc"; mkdir -p "$a"; make_archives "$a"
    wt_archive_check "$a/good.tar.gz" || fail "good tar rejected: $WT_ARCHIVE_ERROR"
    wt_archive_check "$a/good.zip" || fail "good zip rejected: $WT_ARCHIVE_ERROR"
    if wt_archive_check "$a/dotdot.tar.gz"; then fail "../ member accepted"; fi
    assert_contains "$WT_ARCHIVE_ERROR" "outside.txt"
    if wt_archive_check "$a/absolute.tar.gz"; then fail "absolute member accepted"; fi
    if wt_archive_check "$a/dotdot.zip"; then fail "zip ../ member accepted"; fi
    if wt_archive_check "$a/link.tar.gz"; then fail "symlink accepted without --allow-links"; fi
    wt_archive_check "$a/link.tar.gz" --allow-links || fail "symlink refused with --allow-links"
}

test_extract_tree() {
    local a="$KIT_TMP/arc"; mkdir -p "$a"; make_archives "$a"
    wt_extract_tree "$a/good.tar.gz" "$HOME/store/dxvk-v9.9" || fail "$WT_ARCHIVE_ERROR"
    [[ -f "$HOME/store/dxvk-v9.9/x64/d3d11.dll" ]] || fail "top folder not stripped"
    _wt_release_ok "$HOME/store/dxvk-v9.9" || fail "release not recognised"
    wt_extract_tree "$a/flat.tar.xz" "$HOME/store/vkd3d" || fail "$WT_ARCHIVE_ERROR"
    [[ -f "$HOME/store/vkd3d/x86/d3d12.dll" ]] || fail "flat archive layout"
    if wt_extract_tree "$a/good.tar.gz" "$HOME/store/dxvk-v9.9"; then fail "overwrote existing dest"; fi
    if wt_extract_tree "$a/dotdot.tar.gz" "$HOME/store/bad"; then fail "unsafe archive extracted"; fi
    [[ ! -e "$HOME/store/bad" ]] || fail "unsafe archive left a folder"
    compgen -G "$HOME/store/*.extract.*" >/dev/null && fail "staging folder left behind"
    return 0
}

# =============================================================================
#  Wine resolution and discovery
# =============================================================================

test_resolve_proton_and_neutron() {
    local p="$HOME/.steam/steam/compatibilitytools.d/GE-Proton9-20"
    fake_wrapper "$p" proton
    _wt_resolve_wine_quiet "$p/proton" || fail "$WT_RESOLVE_ERROR"
    assert_eq "$p/files/bin/wine" "$WT_INNER_WINE" "proton inner"
    assert_eq "proton" "$WT_WRAPPER_KIND"
    _wt_resolve_wine_quiet "$p/files/bin/wine" || fail "$WT_RESOLVE_ERROR"
    assert_eq "$p/proton" "$WT_WRAPPER" "wrapper found from inner wine"
    _wt_resolve_wine_quiet "$p" || fail "$WT_RESOLVE_ERROR"
    assert_eq "$p/files/bin/wine" "$WT_INNER_WINE" "tool folder"
    local n="$HOME/.local/share/Steam/compatibilitytools.d/Neutron-1.0"
    fake_wrapper "$n" neutron
    _wt_resolve_wine_quiet "$n/neutron" || fail "$WT_RESOLVE_ERROR"
    assert_eq "neutron" "$WT_WRAPPER_KIND"
    assert_eq "$n/files/bin/wine" "$WT_INNER_WINE"
    if _wt_resolve_wine_quiet "$HOME/nope/wine"; then fail "missing binary accepted"; fi
    [[ ! -e "$KIT_TMP/wrapper-ran.log" ]] || fail "a wrapper was executed: $(cat "$KIT_TMP/wrapper-ran.log")"
}

test_find_wine_builds() {
    mkdir -p "$HOME/.local/share/Steam" "$HOME/.steam"
    ln -s "$HOME/.local/share/Steam" "$HOME/.steam/steam"
    fake_wrapper "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton9-20" proton
    fake_wrapper "$HOME/.local/share/Steam/compatibilitytools.d/Neutron-2" neutron
    mkdir -p "$HOME/.local/share/Steam/compatibilitytools.d/broken"
    fake_wine "$HOME/wine-custom/buildz/wine-10.1-custom/bin/wine" "wine-10.1 (custom)"
    fake_wine "$HOME/.local/share/mythix-wine-installs/staging-10/bin/wine" "wine-10.0 (Staging)"
    local out
    out="$(wt_find_wine_builds)"
    assert_contains "$out" "GE-Proton9-20/proton"
    assert_contains "$out" "Neutron-2/neutron"
    assert_contains "$out" "GE-Proton9-20"$'\t'
    assert_contains "$out" "wine-10.1 (custom)"
    assert_contains "$out" "Managed  staging-10"
    local n
    n="$(grep -c 'GE-Proton9-20/proton' <<< "$out")"
    assert_eq 1 "$n" "GE-Proton listed once through two Steam roots"
    [[ ! -e "$KIT_TMP/wrapper-ran.log" ]] || fail "a wrapper was executed while listing"
}

test_select_wine_remembers_choice() {
    fake_wine "$HOME/wine-custom/buildz/a/bin/wine" "wine-a"
    fake_wine "$HOME/wine-custom/buildz/b/bin/wine" "wine-b"
    wt_kit_answer 0 "$HOME/wine-custom/buildz/b/bin/wine"
    wt_select_wine_bin "Test"
    assert_eq "$HOME/wine-custom/buildz/b/bin/wine" "$WT_INNER_WINE"
    : > "$ZMOCK_LOG"
    wt_kit_answer 0 "$HOME/wine-custom/buildz/b/bin/wine"
    wt_select_wine_bin "Test"
    local call
    call="$(grep -m1 -- '--radiolist' "$ZMOCK_LOG")"
    assert_contains "$call" "TRUE ${HOME// /\\ }/wine-custom/buildz/b/bin/wine" "last build preselected"
}

test_select_wine_custom_retry() {
    fake_wine "$HOME/wine-custom/buildz/a/bin/wine"
    wt_kit_answer 0 "Custom..."
    wt_kit_answer 0 "$HOME/not-wine.txt"
    wt_kit_answer 0 "Custom..."
    wt_kit_answer 0 "$HOME/wine-custom/buildz/a/bin/wine"
    : > "$HOME/not-wine.txt"
    wt_select_wine_bin "Test"
    assert_eq "$HOME/wine-custom/buildz/a/bin/wine" "$WT_INNER_WINE"
}

# =============================================================================
#  Prefix discovery and selection
# =============================================================================

test_find_prefixes_sources() {
    fake_prefix "$HOME/.wine" win32
    fake_prefix "$HOME/prefixes/plain"
    fake_prefix "$HOME/prefixes/compat-style/pfx"
    local lib="$HOME/.local/share/Steam"
    fake_prefix "$lib/steamapps/compatdata/1144200/pfx"
    printf '"AppState"\n{\n\t"appid"\t\t"1144200"\n\t"name"\t\t"Ready & Not <Beta>"\n}\n' \
        > "$lib/steamapps/appmanifest_1144200.acf"
    fake_prefix "$lib/steamapps/compatdata/3123456789/pfx"
    fake_prefix "$HOME/.mythix/gamedata/game-abc/pfx"
    mkdir -p "$HOME/.local/share/mythix"
    printf '{"version":1,"games":[{"id":"game-abc","name":"Halo: Campaign","config":{"prefix_path":null}}]}\n' \
        > "$HOME/.local/share/mythix/library.json"
    mkdir -p "$(dirname "$WT_CONFIG_FILE")"
    printf 'WT_PREFIX_PATHS="%s/.wine:%s/prefixes:%s/.wine"\n' "$HOME" "$HOME" "$HOME" > "$WT_CONFIG_FILE"

    local out
    out="$(wt_find_prefixes)"
    assert_contains "$out" "$HOME/.wine"$'\twin32\tConfigured'
    assert_contains "$out" "$HOME/prefixes/plain"$'\twin64'
    assert_contains "$out" "$HOME/prefixes/compat-style/pfx"
    assert_contains "$out" $'\tSteam\tReady & Not <Beta>'
    assert_contains "$out" $'\tSteam\tNon-Steam game 3123456789'
    assert_contains "$out" $'\tMythix\tHalo: Campaign'
    assert_eq 1 "$(grep -c "^$HOME/.wine"$'\t' <<< "$out")" "home .wine prefix listed once"
}

test_select_prefix_from_list_and_browse() {
    fake_prefix "$HOME/.wine"
    local lib="$HOME/.local/share/Steam"
    fake_prefix "$lib/steamapps/compatdata/42/pfx"
    printf '"AppState"\n{\n\t"name"\t\t"Tom & Jerry"\n}\n' > "$lib/steamapps/appmanifest_42.acf"

    wt_kit_answer 0 "$lib/steamapps/compatdata/42/pfx"
    wt_select_prefix_from_config "Test"
    assert_eq "$lib/steamapps/compatdata/42/pfx" "$WINEPREFIX"
    assert_eq "Steam" "$WT_PREFIX_SOURCE"
    assert_eq "Tom & Jerry" "$WT_PREFIX_LABEL"

    # Browse to a compatdata folder: its pfx/ is used. An invalid pick asks again.
    mkdir -p "$HOME/empty"
    wt_kit_answer 0 "Browse..."
    wt_kit_answer 0 "$HOME/empty"
    wt_kit_answer 0 "Browse..."
    wt_kit_answer 0 "$lib/steamapps/compatdata/42"
    wt_select_prefix_from_config "Test"
    assert_eq "$lib/steamapps/compatdata/42/pfx" "$WINEPREFIX"
    log_has "Not a valid Wine prefix"
}

test_select_prefix_cancel() {
    fake_prefix "$HOME/.wine"
    local rc=0
    wt_select_prefix_from_config "Test" || rc=$?
    assert_eq 1 "$rc" "cancel returns 1"
}

test_prefix_arch() {
    fake_prefix "$HOME/p64" win64
    fake_prefix "$HOME/p32" win32
    assert_eq win64 "$(wt_prefix_arch "$HOME/p64")"
    assert_eq win32 "$(wt_prefix_arch "$HOME/p32")"
}

# =============================================================================
#  Terminal runner
# =============================================================================

test_terminal_runs_and_reports_rc() {
    printf '#!/usr/bin/env bash\necho hi > "%s/ran"\nexit 7\n' "$KIT_TMP" > "$KIT_TMP/s.sh"
    wt_run_in_terminal "$KIT_TMP/s.sh"
    [[ -f "$KIT_TMP/ran" ]] || fail "script did not run"
    assert_eq 7 "$WT_TERMINAL_RC" "exit code passed back"
}

test_terminal_waits_for_detaching_terminal() {
    # A terminal that hands the command to a "server" and returns at once.
    mkdir -p "$KIT_TMP/tbin"
    cat > "$KIT_TMP/tbin/detachterm" <<'EOF'
#!/usr/bin/env bash
while (( $# )) && [[ "$1" != "-e" ]]; do shift; done; shift
( sleep 1; exec "$@" ) </dev/null >/dev/null 2>&1 &
exit 0
EOF
    chmod +x "$KIT_TMP/tbin/detachterm"
    export PATH="$KIT_TMP/tbin:$PATH" WT_TERMINAL=detachterm
    printf '#!/usr/bin/env bash\nsleep 1\necho done > "%s/done"\n' "$KIT_TMP" > "$KIT_TMP/s.sh"
    wt_run_in_terminal "$KIT_TMP/s.sh"
    [[ -f "$KIT_TMP/done" ]] || fail "returned before the script finished"
    assert_eq 0 "$WT_TERMINAL_RC"
}

test_terminal_none_available() {
    mkdir -p "$KIT_TMP/zonly"
    ln -s "$KIT_DIR/bin/zenity" "$KIT_TMP/zonly/zenity"
    export PATH="$KIT_TMP/zonly:/usr/bin:/bin" WT_TERMINAL=""
    printf 'exit 0\n' > "$KIT_TMP/s.sh"
    local rc=0
    ( wt_run_in_terminal "$KIT_TMP/s.sh" ) || rc=$?
    assert_eq 1 "$rc" "no terminal -> error"
}

# =============================================================================
#  Misc
# =============================================================================

test_require_cmds_names_packages() {
    local rc=0
    ( wt_require_cmds bash 7z-definitely-missing ) || rc=$?
    assert_eq 1 "$rc"
    log_has "7z-definitely-missing"
    _wt_have() { [[ "$1" != 7z ]] && command -v "$1" >/dev/null 2>&1; }
    rc=0
    ( wt_require_cmds 7z ) || rc=$?
    if grep -q '^ID_LIKE=.*debian\|^ID=debian\|^ID=ubuntu' /etc/os-release; then
        log_has "sudo apt install p7zip-full"
    fi
}

test_empty_machine_is_quiet() {
    # Nothing installed, nothing configured: every scan returns cleanly.
    wt_find_wine_builds >/dev/null
    wt_find_prefixes >/dev/null
    _wt_steam_libraries >/dev/null
    wt_pause
    wt_kill_prefix "$HOME/none" || true
}

# =============================================================================
#  DLL helpers
# =============================================================================

# Real Wine DLLs for the PE / builtin checks, when a Wine prefix is around.
REAL_PFX="${WT_TEST_REAL_PREFIX:-}"


test_pe_arch() {
    fake_pe "$HOME/a64.dll" x64
    fake_pe "$HOME/a32.dll" x86
    printf 'MZ but nothing else' > "$HOME/junk.dll"
    assert_eq x64 "$(wt_pe_arch "$HOME/a64.dll")"
    assert_eq x86 "$(wt_pe_arch "$HOME/a32.dll")"
    if wt_pe_arch "$HOME/junk.dll" >/dev/null; then fail "junk taken for PE"; fi
    if [[ -n "$REAL_PFX" ]]; then
        assert_eq x64 "$(wt_pe_arch "$REAL_PFX/drive_c/windows/system32/d3d11.dll")" "real 64-bit DLL"
        assert_eq x86 "$(wt_pe_arch "$REAL_PFX/drive_c/windows/syswow64/d3d9.dll")" "real 32-bit DLL"
        wt_dll_is_wine_builtin "$REAL_PFX/drive_c/windows/system32/d3d11.dll" || fail "real builtin not recognised"
    fi
    if wt_dll_is_wine_builtin "$HOME/a64.dll"; then fail "native taken for builtin"; fi
}

test_prefix_dll_dirs() {
    fake_prefix "$HOME/p64" win64
    fake_prefix "$HOME/p32" win32
    wt_prefix_dll_dirs "$HOME/p64"
    assert_eq "$HOME/p64/drive_c/windows/system32" "$WT_DLLDIR_64"
    assert_eq "$HOME/p64/drive_c/windows/syswow64" "$WT_DLLDIR_32"
    wt_prefix_dll_dirs "$HOME/p32"
    assert_eq "" "$WT_DLLDIR_64" "no 64-bit dir in a win32 prefix"
    assert_eq "$HOME/p32/drive_c/windows/system32" "$WT_DLLDIR_32"
}


test_dll_put_restore_cycle() {
    local sys="$HOME/p/drive_c/windows/system32"
    fake_prefix "$HOME/p"
    builtin_dll "$sys/d3d11.dll"
    fake_pe "$HOME/dxvk-1.dll" x64
    fake_pe "$HOME/dxvk-2.dll" x64
    printf 'second' >> "$HOME/dxvk-2.dll"
    wt_dll_put "$HOME/dxvk-1.dll" "$sys" d3d11.dll
    wt_dll_put "$HOME/dxvk-2.dll" "$sys" d3d11.dll        # reinstall
    cmp -s "$HOME/dxvk-2.dll" "$sys/d3d11.dll" || fail "new DLL not installed"
    wt_dll_is_wine_builtin "$sys/d3d11.dll.wt_bak" || fail "reinstall clobbered the original backup"
    local rc=0
    wt_dll_restore "$sys" d3d11.dll || rc=$?
    assert_eq 0 "$rc" "restore from builtin backup"
    wt_dll_is_wine_builtin "$sys/d3d11.dll" || fail "builtin not restored"
    [[ ! -e "$sys/d3d11.dll.wt_bak" ]] || fail "backup left behind"

    # Nothing there before: removed again, wineboot needed.
    wt_dll_put "$HOME/dxvk-1.dll" "$sys" d3d8.dll
    [[ -e "$sys/d3d8.dll.wt_bak_none" ]] || fail "no-original marker missing"
    rc=0; wt_dll_restore "$sys" d3d8.dll || rc=$?
    assert_eq 2 "$rc" "removed DLL asks for wineboot"
    [[ ! -e "$sys/d3d8.dll" ]] || fail "DLL not removed"

    # A foreign DLL with no backup (installed by another tool) is removed.
    fake_pe "$sys/dxgi.dll" x64
    rc=0; wt_dll_restore "$sys" dxgi.dll || rc=$?
    assert_eq 2 "$rc"
    [[ ! -e "$sys/dxgi.dll" ]] || fail "foreign DLL kept"
    # Wine's own DLL with no backup is left alone.
    builtin_dll "$sys/d3d9.dll"
    rc=0; wt_dll_restore "$sys" d3d9.dll || rc=$?
    assert_eq 0 "$rc"
    [[ -f "$sys/d3d9.dll" ]] || fail "builtin removed"
}

test_dll_put_never_writes_through_symlinks() {
    # Proton prefixes link their DLLs to the Proton install.
    local sys="$HOME/p/drive_c/windows/system32" runner="$HOME/proton/files/lib/wine/x86_64-windows"
    fake_prefix "$HOME/p"
    mkdir -p "$runner"
    builtin_dll "$runner/d3d11.dll"
    cp "$runner/d3d11.dll" "$KIT_TMP/runner-orig.dll"
    ln -s "$runner/d3d11.dll" "$sys/d3d11.dll"
    fake_pe "$HOME/dxvk.dll" x64
    wt_dll_put "$HOME/dxvk.dll" "$sys" d3d11.dll
    cmp -s "$runner/d3d11.dll" "$KIT_TMP/runner-orig.dll" || fail "wrote through the symlink into the runner"
    [[ -f "$sys/d3d11.dll" && ! -L "$sys/d3d11.dll" ]] || fail "symlink not replaced by a file"
    [[ -L "$sys/d3d11.dll.wt_bak" ]] || fail "symlink not kept as the backup"
    wt_dll_restore "$sys" d3d11.dll
    [[ -L "$sys/d3d11.dll" ]] || fail "symlink not restored"
}

test_split_args() {
    local -a args=()
    mapfile -d '' -t args < <(wt_split_args '-windowed  "C:\Program Files\Game" -lang='"'"'en us'"'"' *.cfg')
    assert_eq 4 "${#args[@]}" "argument count"
    assert_eq '-windowed' "${args[0]}"
    assert_eq 'C:\Program Files\Game' "${args[1]}" "quoted Windows path kept whole, backslashes literal"
    assert_eq '-lang=en us' "${args[2]}"
    assert_eq '*.cfg' "${args[3]}" "no globbing"
    mapfile -d '' -t args < <(wt_split_args '')
    assert_eq 0 "${#args[@]}" "empty string"
}

test_env_apply() {
    wt_env_apply "DXVK_HUD=fps WINEDLLOVERRIDES='d3d11=n,b;dxgi=n' not-a-var MY_PATH=\"/a b/c\""
    assert_eq fps "$DXVK_HUD"
    assert_eq 'd3d11=n,b;dxgi=n' "$WINEDLLOVERRIDES"
    assert_eq '/a b/c' "$MY_PATH"
    [[ "$(bash -c 'echo "$DXVK_HUD"')" == fps ]] || fail "not exported"
}

test_source_env_profile() {
    printf 'export DXVK_HUD="full"\nWINEESYNC=1\n' > "$HOME/good.env"
    printf 'export BROKEN="unterminated\n' > "$HOME/bad.env"
    wt_source_env_profile "$HOME/good.env"
    [[ "$(bash -c 'echo "$DXVK_HUD:$WINEESYNC"')" == full:1 ]] || fail "profile vars not exported"
    if wt_source_env_profile "$HOME/bad.env" 2>/dev/null; then fail "broken profile accepted"; fi
}

test_windows_cmd() {
    wt_windows_cmd "/g/Game.EXE";  assert_eq "/g/Game.EXE" "${WT_WINCMD[*]}"
    wt_windows_cmd "/g/run.BAT";   assert_eq "start /wait /unix /g/run.BAT" "${WT_WINCMD[*]}"
    wt_windows_cmd "/g/setup.msi"; assert_eq "start /wait /unix /g/setup.msi" "${WT_WINCMD[*]}"
}

test_github_scan_mode() {
    curl() {
        cat <<'JSON'
[{"tag_name":"11.21","draft":true,"assets":[{"name":"wine-11.21-staging-amd64.tar.xz","browser_download_url":"https://github.com/Kron4ek/Wine-Builds/releases/download/11.21/wine-11.21-staging-amd64.tar.xz"}]},
 {"tag_name":"proton-10.0-4","assets":[{"name":"wine-proton-10.0-4-amd64.tar.xz","browser_download_url":"https://github.com/Kron4ek/Wine-Builds/releases/download/proton-10.0-4/wine-proton-10.0-4-amd64.tar.xz"}]},
 {"tag_name":"11.20","assets":[{"name":"wine-11.20-staging-tkg-amd64.tar.xz","browser_download_url":"https://github.com/Kron4ek/Wine-Builds/releases/download/11.20/wine-11.20-staging-tkg-amd64.tar.xz","digest":"sha256:t"},
   {"name":"wine-11.20-staging-amd64.tar.xz","browser_download_url":"https://github.com/Kron4ek/Wine-Builds/releases/download/11.20/wine-11.20-staging-amd64.tar.xz","digest":"sha256:s","size":1}]}]
JSON
    }
    local mode
    for mode in jq python grep; do
        case "$mode" in
            jq)     _wt_have() { command -v "$1" >/dev/null 2>&1; } ;;
            python) _wt_have() { [[ "$1" != jq ]] && command -v "$1" >/dev/null 2>&1; } ;;
            grep)   _wt_have() { [[ "$1" != jq && "$1" != python3 ]] && command -v "$1" >/dev/null 2>&1; } ;;
        esac
        wt_github_latest Kron4ek/Wine-Builds '^wine-[0-9]+\.[0-9]+(-rc[0-9]+)?-staging-amd64\.tar\.xz$' --scan \
            || fail "$mode: $WT_GH_ERROR"
        if [[ "$mode" == grep ]]; then
            # No JSON parser: first matching asset, draft flags unseen.
            assert_contains "$WT_GH_ASSET" "-staging-amd64.tar.xz" "$mode asset"
            continue
        fi
        assert_eq "11.20" "$WT_GH_TAG" "$mode: draft skipped, proton release skipped"
        assert_eq "wine-11.20-staging-amd64.tar.xz" "$WT_GH_ASSET" "$mode asset"
        assert_eq "s" "$WT_GH_SHA256" "$mode digest"
    done
}

test_exe_archive_via_7z() {
    local a="$KIT_TMP/arc"; mkdir -p "$a"
    python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("x64/thing.dll","MZ"); z.close()' "$a/setup.exe"
    wt_extract "$a/setup.exe" "$HOME/out" || fail "$WT_ARCHIVE_ERROR"
    [[ -f "$HOME/out/x64/thing.dll" ]] || fail "exe not unpacked"
}

test_find_builds_ge_proton_in_buildz() {
    # The Runtime Manager installs GE-Proton as buildz/<name>/{proton,files/bin/wine}.
    fake_wrapper "$HOME/wine-custom/buildz/GE-Proton10-20" proton
    fake_wine "$HOME/wine-custom/buildz/wine-11.20-staging-amd64/bin/wine" "wine-11.20 (Staging)"
    local out
    out="$(wt_find_wine_builds)"
    assert_contains "$out" "buildz/GE-Proton10-20/proton"$'\t'"Custom build  GE-Proton10-20"
    assert_contains "$out" "wine-11.20 (Staging)"
    assert_eq 0 "$(grep -c 'GE-Proton10-20/files/bin/wine' <<< "$out" || true)" "inner wine not listed twice"
}

# --- run ----------------------------------------------------------------------
run_all_tests "winetoolz-lib tests"
