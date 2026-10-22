#!/usr/bin/env bash
# Tool module tests: Wine Tools, DLL Override Manager, Env Flags, App
# Launcher, Log Viewer, About, Runtime Downloads, Winecfg, and the main menu
# and command line. Each module runs as the menu runs it (its own bash
# process) with scripted zenity answers, the mock terminal, a fake Wine that
# logs its calls and, for downloads, a fake curl serving fixture files.
#
#   bash tests/test_tools.sh [filter]
#
# Optional real-Wine check of the override manager against Wine's own reg.exe
# (the prefix is copied, never modified):
#   WT_TEST_REAL_PREFIX64=/path/to/win64-prefix   or
#   WT_TEST_REAL_PREFIX32=/path/to/win32-prefix
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FILTER="${1:-}"
# shellcheck source=kit/testlib.sh
source "$TESTS_DIR/kit/testlib.sh"

# text_count <ERE> — how many dialog texts match
text_count() { grep -cE "^TEXT .*$1" "$ZMOCK_LOG" || true; }

# =============================================================================
#  Wine Tools
# =============================================================================

test_wine_tools_run_in_the_prefix() {
    fixture_wine
    local pfx="$HOME/prefixes/game"
    fake_prefix "$pfx" win64
    fake_cmd xdg-open
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 regedit
    wt_kit_answer 0 wineboot
    wt_kit_answer 0 cmd
    wt_kit_answer 0 drivec
    wt_kit_answer 0 wineserver
    run_module wine_tools.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"

    assert_contains "$(wine_argv)" "[regedit]"
    assert_contains "$(wine_argv)" "[wineboot][--update]"
    assert_contains "$(wine_argv)" "[cmd]"
    grep -qx "WINEPREFIX=$pfx" "$KIT_TMP/wine-env.last" || fail "Wine did not run in the chosen prefix"
    assert_contains "$(wt_kit_terminal_log)" "Registry Editor closed."
    log_has "No Wine processes are running in this prefix."
    local _
    for _ in $(seq 20); do [[ -s "$KIT_TMP/fake-cmds.log" ]] && break; sleep 0.1; done
    assert_contains "$(cat "$KIT_TMP/fake-cmds.log" 2>/dev/null)" "xdg-open $pfx/drive_c"
}

# =============================================================================
#  DLL Override Manager
# =============================================================================

OVR_KEY='HKEY_CURRENT_USER\Software\Wine\DllOverrides'
APPS_KEY='HKEY_CURRENT_USER\Software\Wine\AppDefaults'

fixture_reg_prefix() {  # <prefix> — a fake Wine with a working reg.exe and
                        # four overrides already set (two keys made by hand,
                        # in their own letter case)
    local w="$HOME/$FAKE_WINE_REL"
    fake_wine_reg "$w"
    fake_prefix "$1" win64
    WINEPREFIX="$1" "$w" reg add "$OVR_KEY" /v d3d9 /d native,builtin /f
    WINEPREFIX="$1" "$w" reg add "$OVR_KEY" /v xinput1_3 /d "" /f
    WINEPREFIX="$1" "$w" reg add "$APPS_KEY\\Game.exe\\DllOverrides" /v dinput8 /d native /f
    WINEPREFIX="$1" "$w" reg add "$APPS_KEY\\other.exe\\dlloverrides" /v d3dx9_43 /d native /f
    : > "$KIT_TMP/wine-calls.log"
}

test_overrides_view_add_preset_remove() {
    local pfx="$HOME/prefixes/game"
    fixture_reg_prefix "$pfx"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 view
    # per-program: a full Windows path is cut down to the .exe name, and
    # "game.exe" finds the existing "Game.exe" key (keys ignore case)
    wt_kit_answer 0 add;    wt_kit_answer 0 "D3D11.dll"; wt_kit_answer 0 native;   wt_kit_answer 0 'C:\\Games\\game.exe'
    wt_kit_answer 0 add;    wt_kit_answer 0 "dxgi";      wt_kit_answer 0 disabled; wt_kit_answer 0 ""
    wt_kit_answer 0 preset; wt_kit_answer 0 "nvapi|vkd3d"
    wt_kit_answer 0 remove; wt_kit_answer 0 '*\x1fxinput1_3\x1eGame.exe\x1fdinput8'
    wt_kit_answer 0 view
    run_module dll_override_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"

    local app="$APPS_KEY\\game.exe\\DllOverrides"
    assert_eq "native,builtin" "$(fake_reg_get "$pfx" "$OVR_KEY" d3d9)" "untouched d3d9"
    assert_eq "<unset>" "$(fake_reg_get "$pfx" "$OVR_KEY" xinput1_3)" "removed xinput1_3"
    assert_eq "" "$(fake_reg_get "$pfx" "$OVR_KEY" dxgi)" "disabled dxgi (empty value, like winecfg)"
    local d
    for d in nvapi nvapi64 d3d12 d3d12core; do
        assert_eq "native,builtin" "$(fake_reg_get "$pfx" "$OVR_KEY" "$d")" "preset $d"
    done
    assert_eq "native" "$(fake_reg_get "$pfx" "$app" d3d11)" "per-program d3d11"
    assert_eq "<unset>" "$(fake_reg_get "$pfx" "$app" dinput8)" "removed per-program dinput8"

    # the first view, then the last one
    assert_eq 1 "$(text_count 'xinput1_3 +disabled +all programs')" "first view: disabled override"
    assert_eq 1 "$(text_count 'dinput8 +native +Game\.exe only')" "first view: per-program override"
    assert_eq 1 "$(text_count 'd3d11 +native +Game\.exe only')" "last view: new per-program override"
    assert_eq 1 "$(text_count 'dxgi +disabled +all programs')" "last view: disabled dxgi"
    assert_eq 2 "$(text_count 'd3d9 +native,builtin +all programs')" "d3d9 in both views"
    assert_eq 2 "$(text_count 'd3dx9_43 +native +other\.exe only')" "override under a lower-case dlloverrides key"
    log_has "Override set:"
}

test_overrides_reject_bad_names() {
    local pfx="$HOME/prefixes/game"
    fixture_reg_prefix "$pfx"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 add; wt_kit_answer 0 'foo$bar'
    wt_kit_answer 0 add; wt_kit_answer 0 dinput8; wt_kit_answer 0 native; wt_kit_answer 0 "notanexe"
    run_module dll_override_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    log_has 'Not a DLL name:  foo$bar'
    log_has "Enter a program name ending in .exe"
    assert_not_contains "$(wine_calls)" "reg add"
}

test_real_wine_overrides() {
    local src="${WT_TEST_REAL_PREFIX32:-}" loader=/usr/lib/wine/wine
    if [[ -z "$src" ]]; then src="${WT_TEST_REAL_PREFIX64:-}" loader=/usr/lib/wine/wine64; fi
    [[ -n "$src" && -x "$loader" ]] || { echo "  (skipped: no real prefix)"; return 0; }
    local pfx="$HOME/prefixes/real"
    real_prefix_copy "$src" "$pfx"
    wt_kit_answer 0 "$loader"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 add; wt_kit_answer 0 d3d11; wt_kit_answer 0 native; wt_kit_answer 0 "wt_test.exe"
    wt_kit_answer 0 add; wt_kit_answer 0 wt_test_dll; wt_kit_answer 0 disabled; wt_kit_answer 0 ""
    wt_kit_answer 0 view
    wt_kit_answer 0 remove; wt_kit_answer 0 '*\x1fwt_test_dll\x1ewt_test.exe\x1fd3d11'
    wt_kit_answer 0 view
    KIT_TIMEOUT=600 run_module dll_override_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    WINEPREFIX="$pfx" "$(dirname "$loader")/wineserver" -w 2>/dev/null || true
    assert_eq 1 "$(text_count 'd3d11 +native +wt_test\.exe only')" "Wine's reg.exe output: per-program override"
    assert_eq 1 "$(text_count 'wt_test_dll +disabled +all programs')" "Wine's reg.exe output: disabled override"
    if grep -q '"wt_test_dll"=' "$pfx/user.reg"; then fail "wt_test_dll left in user.reg"; fi
    if grep -A3 -i 'AppDefaults\\\\wt_test.exe\\\\DllOverrides' "$pfx/user.reg" | grep -q '"d3d11"'; then
        fail "per-program d3d11 left in user.reg"
    fi
}

# =============================================================================
#  Env Flags
# =============================================================================

test_env_flags_profiles() {
    fake_cmd xclip 'cat > "$KIT_TMP/clipboard"'
    local f="$HOME/.config/winetoolz/env_profiles/my_game.env"
    wt_kit_answer 0 create; wt_kit_answer 0 "my game"; wt_kit_answer 0 "dxvk_hud|dxvk_hud_full|esync"
    wt_kit_answer 0 view;   wt_kit_answer 0 my_game
    run_module env_flags.sh || fail "create/view died: $(tail -5 "$KIT_TMP/module.out")"
    # two DXVK_HUD styles picked: one line, the later pick wins
    assert_eq $'# winetoolz env profile: my game\nexport DXVK_HUD="full"\nexport WINEESYNC="1"' "$(cat "$f")" "profile"
    log_has 'export WINEESYNC="1"'

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 edit;   wt_kit_answer 0 my_game; wt_kit_answer 0 'export DXVK_HUD="fps\nexport X=1'
    run_module env_flags.sh || fail "edit died"
    log_has "shell syntax error"
    assert_contains "$(cat "$f")" 'DXVK_HUD="full"' "profile after a refused edit"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 edit;   wt_kit_answer 0 my_game; wt_kit_answer 0 'export DXVK_HUD="fps"\nexport WINEESYNC="1"'
    wt_kit_answer 0 export; wt_kit_answer 0 my_game
    wt_kit_answer 0 create; wt_kit_answer 0 "my game"; wt_kit_answer 1          # replace? no
    wt_kit_answer 0 create; wt_kit_answer 0 '!!!'
    run_module env_flags.sh || fail "edit/export died"
    assert_eq $'export DXVK_HUD="fps"\nexport WINEESYNC="1"' "$(cat "$f")" "edited profile"
    assert_eq "$(cat "$f")" "$(cat "$KIT_TMP/clipboard" 2>/dev/null)" "clipboard"
    log_has "Use letters, digits, - or _ in the profile name."

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 delete; wt_kit_answer 0 my_game; wt_kit_answer 0
    run_module env_flags.sh || fail "delete died"
    [[ ! -e "$f" ]] || fail "profile not deleted"
}

# =============================================================================
#  App Launcher
# =============================================================================

LAUNCHERS=".config/winetoolz/launchers"

fixture_game() {  # sets PFX and EXE: a prefix with a game in a folder with spaces
    PFX="$HOME/prefixes/game"
    fake_prefix "$PFX" win64
    mkdir -p "$PFX/drive_c/Games/My Game"
    EXE="$PFX/drive_c/Games/My Game/game.exe"
    fake_pe "$EXE" x64
}

sc_value() {  # <conf> <KEY> — a shortcut field, read the way the module reads it
    (
        unset SC_NAME SC_WINE SC_PREFIX SC_EXE SC_ARGS SC_ENV SC_ENV_PROFILE SC_WORKDIR SC_LAST_LAUNCH
        wt_kv_load "$1" '^SC_' >/dev/null 2>&1 || true
        printf '%s' "${!2:-}"
    )
}

test_app_launcher_add_launch_edit_delete() {
    fixture_wine
    fixture_game
    mkdir -p "$HOME/.config/winetoolz/env_profiles"
    printf 'export DXVK_HUD="fps"\n' > "$HOME/.config/winetoolz/env_profiles/fast.env"
    local conf="$HOME/$LAUNCHERS/My_Game.conf"

    wt_kit_answer 0 add
    wt_kit_answer 0 "My Game!"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$PFX"
    wt_kit_answer 0 "$EXE"
    wt_kit_answer 0 fast
    wt_kit_answer 0 '-windowed "C:\\My Games\\save"\x1fFOO=bar NOTPAIR'
    run_module app_launcher.sh || fail "add died: $(tail -5 "$KIT_TMP/module.out")"
    [[ -f "$conf" ]] || fail "shortcut not saved as My_Game.conf: $(ls "$HOME/$LAUNCHERS")"
    assert_eq "My Game!" "$(sc_value "$conf" SC_NAME)" "name"
    assert_eq '-windowed "C:\My Games\save"' "$(sc_value "$conf" SC_ARGS)" "args"
    assert_eq "FOO=bar NOTPAIR" "$(sc_value "$conf" SC_ENV)" "inline env"
    assert_eq "fast" "$(sc_value "$conf" SC_ENV_PROFILE)" "profile"
    assert_eq "$(dirname "$EXE")" "$(sc_value "$conf" SC_WORKDIR)" "work dir"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 launch; wt_kit_answer 0 "$conf"
    run_module app_launcher.sh || fail "launch died: $(tail -5 "$KIT_TMP/module.out")"
    # the quoted argument stays one argument, backslashes and all
    assert_contains "$(wine_argv)" "[$EXE][-windowed][C:\\My Games\\save]"
    grep -qx 'DXVK_HUD=fps' "$KIT_TMP/wine-env.last" || fail "env profile not applied"
    grep -qx 'FOO=bar' "$KIT_TMP/wine-env.last" || fail "inline env var not applied"
    grep -qx "PWD=$(dirname "$EXE")" "$KIT_TMP/wine-env.last" || fail "not started in the game's folder"
    grep -qx "WINEPREFIX=$PFX" "$KIT_TMP/wine-env.last" || fail "wrong prefix"
    assert_contains "$(wt_kit_terminal_log)" 'Ignoring "NOTPAIR"'
    [[ "$(sc_value "$conf" SC_LAST_LAUNCH)" == 20* ]] || fail "last launch not stamped"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 edit;    wt_kit_answer 0 "$conf"
    wt_kit_answer 0 args;    wt_kit_answer 0 ""
    wt_kit_answer 0 profile; wt_kit_answer 0 "(none)"
    wt_kit_answer 0 name;    wt_kit_answer 0 'Renamed & "Co" $HOME `x`'
    wt_kit_answer 0 save
    wt_kit_answer 0 list
    run_module app_launcher.sh || fail "edit died: $(tail -5 "$KIT_TMP/module.out")"
    assert_eq "" "$(sc_value "$conf" SC_ARGS)" "cleared args"
    assert_eq "" "$(sc_value "$conf" SC_ENV_PROFILE)" "cleared profile"
    assert_eq 'Renamed & "Co" $HOME `x`' "$(sc_value "$conf" SC_NAME)" "new name (stored as data)"
    log_has 'Renamed & "Co" $HOME `x`'

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 delete; wt_kit_answer 0 "$conf"; wt_kit_answer 0
    run_module app_launcher.sh || fail "delete died"
    [[ ! -e "$conf" ]] || fail "shortcut not deleted"
}

test_app_launcher_shortcuts_are_data() {
    local dir="$HOME/$LAUNCHERS"
    mkdir -p "$dir"
    cat > "$dir/evil.conf" <<'EOF'
SC_NAME="$(touch "$HOME/pwned1")"
SC_EXE=`touch $HOME/pwned2`
SC_ARGS="x"; touch "$HOME/pwned3"
touch "$HOME/pwned4"
EOF
    wt_kit_answer 0 list
    wt_kit_answer 0 launch; wt_kit_answer 0 "$dir/evil.conf"; wt_kit_answer 1    # Wine missing: pick another? no
    run_module app_launcher.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    local n
    for n in 1 2 3 4; do [[ ! -e "$HOME/pwned$n" ]] || fail "shortcut file ran code (pwned$n)"; done
    log_has "The Wine build of this shortcut is gone"
    assert_eq "" "$(wine_calls)" "nothing launched"
}

test_app_launcher_missing_prefix() {
    fixture_wine
    fixture_game
    local conf="$HOME/$LAUNCHERS/gone.conf"
    mkdir -p "$HOME/$LAUNCHERS"
    printf 'SC_NAME="Gone"\nSC_WINE="%s"\nSC_PREFIX="%s"\nSC_EXE="%s"\n' \
        "$HOME/$FAKE_WINE_REL" "$HOME/prefixes/deleted" "$EXE" > "$conf"
    wt_kit_answer 0 launch; wt_kit_answer 0 "$conf"
    run_module app_launcher.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    log_has "The prefix of this shortcut is gone"
    [[ ! -e "$HOME/prefixes/deleted" ]] || fail "a new prefix was made in its place"
    assert_eq "" "$(wine_calls)" "nothing launched"
}

# =============================================================================
#  Log Viewer
# =============================================================================

test_log_viewer_run_view_delete() {
    fixture_wine
    fixture_game
    local logs="$HOME/winetoolz/logs" log
    wt_kit_answer 0 run; wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"; wt_kit_answer 0 "$PFX"
    wt_kit_answer 0 "$EXE"; wt_kit_answer 0 ""
    run_module log_viewer.sh || fail "run died: $(tail -5 "$KIT_TMP/module.out")"
    assert_contains "$(wine_argv)" "[$EXE]"
    log="$(ls "$logs"/game_*.log 2>/dev/null | head -1)"
    [[ -n "$log" ]] || fail "no log written"
    grep -q "^# Exe     : $EXE" "$log" || fail "log header missing"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 view;   wt_kit_answer 0 "$log"
    wt_kit_answer 0 delete; wt_kit_answer 0 "$log"; wt_kit_answer 0
    run_module log_viewer.sh || fail "view/delete died: $(tail -5 "$KIT_TMP/module.out")"
    [[ ! -e "$log" ]] || fail "log not deleted"
    log_has "Deleted 1 log(s)."
}

# =============================================================================
#  About
# =============================================================================

test_about_sections() {
    wt_kit_answer 0 deps; wt_kit_answer 0 ""
    wt_kit_answer 0 modules
    wt_kit_answer 0 config
    run_module about.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    log_has "Dependency status for winetoolz v$WT_VERSION"
    grep -q '^CALL.*cabextract.*DLL\\ Installer' "$ZMOCK_LOG" || fail "dependency rows missing"
    log_has "Runtime Downloads"
    log_has "$HOME/.config/mythix-build/winetoolz.cfg"
    log_has "Download cache"
}

# =============================================================================
#  Runtime Downloads
# =============================================================================

RT_DIR="wine-custom/buildz"

make_runtime_tarball() {  # <out .tar.gz|.tar.xz> <top folder> <proton|wine>
    local out="$1" top="$2" src="$KIT_TMP/rt-src"
    rm -rf "$src"
    mkdir -p "$src/$top"
    if [[ "$3" == proton ]]; then
        printf '#!/bin/sh\nexit 1\n' > "$src/$top/proton"
        chmod +x "$src/$top/proton"
        fake_wine "$src/$top/files/bin/wine" "wine-10.0 (GE)"
        ln -s wine "$src/$top/files/bin/wine64"
        printf '1717000000 %s\n' "$top" > "$src/$top/version"
    else
        fake_wine "$src/$top/bin/wine" "wine-10.17 (Staging)"
        ln -s wine "$src/$top/bin/wine64"
    fi
    mkdir -p "$(dirname "$out")"
    case "$out" in
        *.tar.xz) tar -C "$src" -cJf "$out" "$top" ;;
        *)        tar -C "$src" -czf "$out" "$top" ;;
    esac
}

gh_json() {  # <out.json> <latest|list> <"tag|prerelease|name=file|name=file...">...
             # GitHub release JSON; assets with a file get its size and digest
    python3 -I - "$@" <<'PY'
import hashlib, json, os, sys
out, mode, *specs = sys.argv[1:]
rels = []
for spec in specs:
    tag, pre, *assets = spec.split("|")
    al = []
    for a in assets:
        name, _, path = a.partition("=")
        e = {"name": name,
             "browser_download_url": "https://github.com/test/test/releases/download/%s/%s" % (tag, name)}
        if path:
            data = open(path, "rb").read()
            e["size"] = len(data)
            e["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
        al.append(e)
    rels.append({"tag_name": tag, "draft": False, "prerelease": pre == "true", "assets": al})
json.dump(rels if mode == "list" else rels[0], open(out, "w"))
PY
}

test_runtime_download_ge_proton() {
    fake_net
    local tb="$KIT_TMP/net/files/GE-Proton10-25.tar.gz" d="$HOME/$RT_DIR/GE-Proton10-25"
    make_runtime_tarball "$tb" GE-Proton10-25 proton
    gh_json "$KIT_TMP/net/api/GloriousEggroll_proton-ge-custom.json" latest \
        "GE-Proton10-25|false|GE-Proton10-25.sha512sum=|GE-Proton10-25.tar.gz=$tb"
    wt_kit_answer 0 install; wt_kit_answer 0 ge-proton; wt_kit_answer 0
    run_module runtime_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    [[ -x "$d/proton" && -x "$d/files/bin/wine" ]] || fail "GE-Proton not installed: $(ls -R "$HOME/$RT_DIR" | head)"
    [[ -L "$d/files/bin/wine64" ]] || fail "a link inside the build was dropped"
    [[ ! -e "$HOME/$RT_DIR/.downloads" ]] || fail "download folder left behind"
    log_has "Runtime installed and verified."
    assert_not_contains "$(cat "$KIT_TMP/curl-calls.log")" "sha512sum" "downloads"

    # again: offered as already installed, and reused
    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 install; wt_kit_answer 0 ge-proton; wt_kit_answer 0 "Use existing"
    run_module runtime_manager.sh || fail "second run died"
    log_has "is already installed."
    assert_eq 1 "$(grep -c 'GE-Proton10-25.tar.gz' "$KIT_TMP/curl-calls.log")" "downloads of the archive"
}

test_runtime_download_kron4ek_scans_releases() {
    fake_net
    local name="wine-10.17-staging-amd64-wow64"
    local tb="$KIT_TMP/net/files/$name.tar.xz"
    make_runtime_tarball "$tb" "$name" wine
    gh_json "$KIT_TMP/net/api/Kron4ek_Wine-Builds_list.json" list \
        "11.0-rc1|true|wine-11.0-rc1-staging-amd64-wow64.tar.xz=" \
        "10.17|false|wine-10.17-amd64.tar.xz=|wine-10.17-staging-tkg-amd64-wow64.tar.xz=|wine-10.17-staging-amd64.tar.xz=|$name.tar.xz=$tb|wine-10.17-x86.tar.xz="
    wt_kit_answer 0 install; wt_kit_answer 0 kron4ek-staging-wow64; wt_kit_answer 0
    run_module runtime_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    [[ -x "$HOME/$RT_DIR/$name/bin/wine" ]] || fail "Kron4ek build not installed: $(ls "$HOME/$RT_DIR")"
    grep -q 'releases?per_page=30' "$KIT_TMP/curl-calls.log" || fail "the release list was not scanned"
    if grep -q 'rc1' "$KIT_TMP/curl-calls.log"; then fail "a pre-release was downloaded"; fi
}

test_runtime_download_checksum_mismatch() {
    fake_net
    local tb="$KIT_TMP/net/files/GE-Proton10-26.tar.gz"
    make_runtime_tarball "$tb" GE-Proton10-26 proton
    gh_json "$KIT_TMP/net/api/GloriousEggroll_proton-ge-custom.json" latest \
        "GE-Proton10-26|false|GE-Proton10-26.tar.gz=$tb"
    printf 'tampered' >> "$tb"
    wt_kit_answer 0 install; wt_kit_answer 0 ge-proton; wt_kit_answer 0
    run_module runtime_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    [[ ! -e "$HOME/$RT_DIR/GE-Proton10-26" ]] || fail "installed despite the checksum mismatch"
    log_has "Checksum mismatch"
    assert_eq "" "$(find "$HOME/$RT_DIR" -name '*.part*' -o -name '*.tar.gz' | head -1)" "leftover download"
}

test_runtime_custom_url() {
    fake_net
    make_runtime_tarball "$KIT_TMP/net/files/my-wine.tar.gz" my-wine wine
    wt_kit_answer 0 install; wt_kit_answer 0 custom-url
    wt_kit_answer 0 "https://example.invalid/dl/my-wine.tar.gz"; wt_kit_answer 0 ".."
    wt_kit_answer 0 install; wt_kit_answer 0 custom-url
    wt_kit_answer 0 "http://example.invalid/dl/my-wine.tar.gz"; wt_kit_answer 0 "plain"
    wt_kit_answer 0 install; wt_kit_answer 0 custom-url
    wt_kit_answer 0 "https://example.invalid/dl/my-wine.tar.gz?token=1"; wt_kit_answer 0 "my wine"
    run_module runtime_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    log_has "Please enter a name made of letters"
    log_has "Refusing a plain-http download"
    [[ ! -e "$HOME/$RT_DIR/plain" ]] || fail "plain-http runtime installed"
    [[ -x "$HOME/$RT_DIR/my_wine/bin/wine" ]] || fail "custom runtime not installed: $(ls "$HOME/$RT_DIR")"
    [[ -d "$HOME/wine-custom" && -d "$HOME" ]] || fail "parent folders touched"
}

test_runtime_remove_only_offered() {
    local rt="$HOME/$RT_DIR"
    fake_wine "$rt/old-wine/bin/wine"
    fake_wrapper "$rt/GE-Proton9-1" proton
    fake_wine "$HOME/wine-custom/outside/bin/wine"
    wt_kit_answer 0 remove; wt_kit_answer 0 "$rt/old-wine||$rt/../outside"; wt_kit_answer 0
    run_module runtime_manager.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    [[ ! -e "$rt/old-wine" ]] || fail "selected runtime not removed"
    [[ -d "$rt/GE-Proton9-1" ]] || fail "unselected runtime removed"
    [[ -x "$HOME/wine-custom/outside/bin/wine" ]] || fail "a folder outside the runtimes was removed"
    log_has "Removed  1  runtime(s)."
}

# =============================================================================
#  Winecfg
# =============================================================================

test_winecfg_runs_inner_wine_of_proton() {
    local tool="$HOME/.steam/steam/compatibilitytools.d/GE-Proton9-1" pfx="$HOME/prefixes/game"
    fake_wrapper "$tool" proton
    fake_prefix "$pfx" win64
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "$tool/proton"
    run_module winecfg.sh || fail "module died: $(tail -5 "$KIT_TMP/module.out")"
    assert_contains "$(wine_argv)" "[winecfg]"
    [[ ! -e "$KIT_TMP/wrapper-ran.log" ]] || fail "the Proton wrapper was run: $(cat "$KIT_TMP/wrapper-ran.log")"
    grep -qx "WINEPREFIX=$pfx" "$KIT_TMP/wine-env.last" || fail "winecfg not run in the prefix"
}

# =============================================================================
#  Main menu and command line
# =============================================================================

run_entry() {  # [args] — wine_toolz.sh, output in $KIT_TMP/entry.out
    local rc=0
    wt_kit_run "$WT_ROOT/wine_toolz.sh" "$@" >"$KIT_TMP/entry.out" 2>&1 || rc=$?
    return "$rc"
}

test_entry_command_line() {
    run_entry --version || fail "--version failed"
    assert_eq "winetoolz $WT_VERSION" "$(cat "$KIT_TMP/entry.out")" "--version"
    run_entry --help || fail "--help failed"
    assert_contains "$(cat "$KIT_TMP/entry.out")" "Usage:"
    run_entry --list || fail "--list failed"
    local n names
    names="$(cat "$KIT_TMP/entry.out")"
    for n in dxvk vkd3d nvapi runtimes vcredist downloads winecfg overrides launcher about; do
        grep -qx -- "$n" <<< "$names" || fail "--list lacks $n"
    done
    local rc=0
    run_entry nosuch || rc=$?
    assert_eq 2 "$rc" "exit code for an unknown module"
    assert_contains "$(cat "$KIT_TMP/entry.out")" 'no module named "nosuch"'
}

test_entry_every_module_starts() {
    # Every module the menu offers opens and closes cleanly when the first
    # dialog is cancelled (no "unbound variable" or missing-file errors).
    local n names
    run_entry --list || fail "--list failed"
    names="$(cat "$KIT_TMP/entry.out")"
    for n in $names; do
        : > "$ZMOCK_LOG"
        run_entry "$n" || fail "$n: exit $?"
        if grep -E 'unbound variable|syntax error|command not found|No such file|Module not found' "$KIT_TMP/entry.out"; then
            fail "$n: errors while starting"
        fi
        grep -q '^CALL' "$ZMOCK_LOG" || fail "$n: no dialog opened"
        if grep -q '^CALL.*--error' "$ZMOCK_LOG"; then fail "$n: showed an error: $(grep '^TEXT' "$ZMOCK_LOG" | tail -1)"; fi
    done
}

test_entry_menu_dispatch() {
    wt_kit_answer 0 cat_system
    wt_kit_answer 0 opt_about
    wt_kit_answer 0 exit         # About → Close
    wt_kit_answer 0 back         # the System submenu → back
    wt_kit_answer 0 cat_exit
    run_entry || fail "menu exited $?"
    grep -q '^CALL.*About\\ winetoolz' "$ZMOCK_LOG" || fail "About was not opened from the menu"
    assert_contains "$(cat "$KIT_TMP/entry.out")" "winetoolz  v$WT_VERSION"
    assert_contains "$(cat "$KIT_TMP/entry.out")" "exiting"
}

# --- run ----------------------------------------------------------------------
run_all_tests "winetoolz tool module tests"
