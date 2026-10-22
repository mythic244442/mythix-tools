#!/usr/bin/env bash
# Module flow tests: each module runs as the menu runs it (its own bash
# process), with scripted zenity answers, the mock terminal, a fake Wine that
# logs its calls, and fake prefixes / releases.
#
#   bash tests/test_modules.sh [filter]
#
# Optional real-Wine checks: point these at real prefixes (they are copied,
# never modified) and have Wine installed:
#   WT_TEST_REAL_PREFIX64=/path/to/win64-prefix
#   WT_TEST_REAL_PREFIX32=/path/to/win32-prefix
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FILTER="${1:-}"
# shellcheck source=kit/testlib.sh
source "$TESTS_DIR/kit/testlib.sh"

# --- fixtures -----------------------------------------------------------------

fixture_release() {  # <tool_key> <release_dir_name> <x64 dir> <x86 dir> <dll...>
    local key="$1" rel="$2" d64="$3" d32="$4"; shift 4
    local root="$HOME/winetoolz/dxvk-vkd3d_proton-files/$key/$rel" n
    mkdir -p "$root/$d64" "$root/$d32"
    for n in "$@"; do
        fake_pe "$root/$d64/$n.dll" x64
        printf '%s-64' "$n" >> "$root/$d64/$n.dll"
        fake_pe "$root/$d32/$n.dll" x86
        printf '%s-32' "$n" >> "$root/$d32/$n.dll"
    done
    printf '%s\n' "$root"
}

fixture_builtin_prefix() {  # <dir> <arch> <dll...> — Wine's own DLLs in place
    local dir="$1" arch="$2"; shift 2
    local n
    fake_prefix "$dir" "$arch"
    for n in "$@"; do
        builtin_dll "$dir/drive_c/windows/system32/$n.dll"
        [[ "$arch" == win64 ]] && builtin_dll "$dir/drive_c/windows/syswow64/$n.dll"
    done
    return 0
}

# =============================================================================
#  Graphics: DXVK / VKD3D-Proton / DXVK-NVAPI
# =============================================================================

DXVK_DLLS=(dxgi d3d11 d3d10core d3d9 d3d8)

test_dxvk_install_uninstall_win64() {
    fixture_wine; fixture_vulkan
    local pfx="$HOME/prefixes/game" rel
    fixture_builtin_prefix "$pfx" win64 "${DXVK_DLLS[@]}"
    rel="$(fixture_release dxvk dxvk-9.9 x64 x32 "${DXVK_DLLS[@]}")"

    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    run_module dxvk_setup-gui.sh || fail "install exited $? — $(tail -5 "$KIT_TMP/module.out")"

    local n sys="$pfx/drive_c/windows/system32" wow="$pfx/drive_c/windows/syswow64"
    for n in "${DXVK_DLLS[@]}"; do
        cmp -s "$rel/x64/$n.dll" "$sys/$n.dll" || fail "$n: 64-bit DLL not in system32"
        cmp -s "$rel/x32/$n.dll" "$wow/$n.dll" || fail "$n: 32-bit DLL not in syswow64"
        wt_dll_is_wine_builtin "$sys/$n.dll.wt_bak" || fail "$n: builtin backup missing"
        assert_contains "$(wine_calls)" "reg add HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides /v $n /d native,builtin /f"
    done
    log_has "DXVK install finished successfully."

    # Reinstall must keep the original backups.
    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    run_module dxvk_setup-gui.sh || fail "reinstall failed"
    wt_dll_is_wine_builtin "$sys/d3d11.dll.wt_bak" || fail "reinstall clobbered the backup"

    : > "$KIT_TMP/wine-calls.log"
    wt_kit_answer 0 uninstall
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    run_module dxvk_setup-gui.sh || fail "uninstall failed"
    for n in "${DXVK_DLLS[@]}"; do
        wt_dll_is_wine_builtin "$sys/$n.dll" || fail "$n: builtin not restored in system32"
        wt_dll_is_wine_builtin "$wow/$n.dll" || fail "$n: builtin not restored in syswow64"
        [[ ! -e "$sys/$n.dll.wt_bak" ]] || fail "$n: backup left behind"
        assert_contains "$(wine_calls)" "reg delete HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides /v $n /f"
    done
    assert_not_contains "$(wine_calls)" "wineboot" "no wineboot needed when backups exist"
}

test_dxvk_win32_prefix_gets_32bit_dlls() {
    fixture_wine; fixture_vulkan
    local pfx="$HOME/prefixes/old32" rel
    fixture_builtin_prefix "$pfx" win32 "${DXVK_DLLS[@]}"
    rel="$(fixture_release dxvk dxvk-9.9 x64 x32 "${DXVK_DLLS[@]}")"
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    run_module dxvk_setup-gui.sh || fail "install failed"
    local n
    for n in "${DXVK_DLLS[@]}"; do
        cmp -s "$rel/x32/$n.dll" "$pfx/drive_c/windows/system32/$n.dll" \
            || fail "$n: a win32 prefix must get the 32-bit DLL in system32"
    done
    [[ ! -d "$pfx/drive_c/windows/syswow64" ]] || fail "syswow64 created in a win32 prefix"
}

test_dxvk_old_release_without_d3d8() {
    fixture_wine; fixture_vulkan
    local pfx="$HOME/prefixes/game"
    fixture_builtin_prefix "$pfx" win64 "${DXVK_DLLS[@]}"
    fixture_release dxvk dxvk-2.3 x64 x32 dxgi d3d11 d3d10core d3d9 >/dev/null
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    run_module dxvk_setup-gui.sh || fail "install failed"
    log_has "DXVK install finished successfully."
    assert_contains "$(wt_kit_terminal_log)" "d3d8.dll is not part of this release"
    wt_dll_is_wine_builtin "$pfx/drive_c/windows/system32/d3d8.dll" || fail "d3d8 touched"
}

test_dxvk_uninstall_without_backups_runs_wineboot() {
    # DXVK put there by another tool: removed, then wineboot -u restores Wine's.
    fixture_wine
    local pfx="$HOME/prefixes/game" n
    fake_prefix "$pfx" win64
    for n in "${DXVK_DLLS[@]}"; do
        fake_pe "$pfx/drive_c/windows/system32/$n.dll" x64
        fake_pe "$pfx/drive_c/windows/syswow64/$n.dll" x86
    done
    wt_kit_answer 0 uninstall
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    run_module dxvk_setup-gui.sh || fail "uninstall failed"
    [[ ! -e "$pfx/drive_c/windows/system32/d3d11.dll" ]] || fail "foreign d3d11 kept"
    assert_contains "$(wine_calls)" "ran wineboot -u"
}

test_dxvk_steam_prefix_warns_first() {
    fixture_wine; fixture_vulkan
    local lib="$HOME/.local/share/Steam" pfx
    pfx="$lib/steamapps/compatdata/570/pfx"
    fixture_builtin_prefix "$pfx" win64 "${DXVK_DLLS[@]}"
    fixture_release dxvk dxvk-9.9 x64 x32 "${DXVK_DLLS[@]}" >/dev/null
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 1            # "Continue anyway?" — no
    run_module dxvk_setup-gui.sh || true
    log_has "Proton or Neutron"
    wt_dll_is_wine_builtin "$pfx/drive_c/windows/system32/d3d11.dll" || fail "changed a prefix after No"
}

test_vkd3d_install_win64() {
    fixture_wine; fixture_vulkan
    local pfx="$HOME/prefixes/game" rel
    fixture_builtin_prefix "$pfx" win64 d3d12 d3d12core
    rel="$(fixture_release vkd3d-proton vkd3d-proton-2.99 x64 x86 d3d12 d3d12core)"
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    run_module setup_vkd3d_proton-gui.sh || fail "install failed: $(tail -5 "$KIT_TMP/module.out")"
    cmp -s "$rel/x64/d3d12.dll" "$pfx/drive_c/windows/system32/d3d12.dll" || fail "d3d12 x64"
    cmp -s "$rel/x86/d3d12core.dll" "$pfx/drive_c/windows/syswow64/d3d12core.dll" || fail "d3d12core x86"
    log_has "VKD3D-Proton install finished successfully."
}

test_nvapi_install_and_profile() {
    fixture_wine
    local pfx="$HOME/prefixes/game" root
    fake_prefix "$pfx" win64
    root="$HOME/winetoolz/dxvk-vkd3d_proton-files/dxvk-nvapi/dxvk-nvapi-v0.9.0"
    mkdir -p "$root/x64" "$root/x32" "$root/layer"
    fake_pe "$root/x64/nvapi64.dll" x64
    fake_pe "$root/x64/nvofapi64.dll" x64
    fake_pe "$root/x32/nvapi.dll" x86
    printf '{}' > "$root/layer/VkLayer_dxvk_nvapi.json"
    wt_kit_answer 0 install
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    wt_kit_answer 0            # create the dxvk-nvapi env profile
    run_module install_nvapi.sh || fail "install failed: $(tail -5 "$KIT_TMP/module.out")"
    [[ -f "$pfx/drive_c/windows/system32/nvapi64.dll" ]] || fail "nvapi64 missing"
    [[ -f "$pfx/drive_c/windows/system32/nvofapi64.dll" ]] || fail "nvofapi64 missing"
    [[ -f "$pfx/drive_c/windows/syswow64/nvapi.dll" ]] || fail "nvapi (32-bit) missing"
    [[ -f "$pfx/dxvk-nvapi-layer/VkLayer_dxvk_nvapi.json" ]] || fail "layer not copied"
    grep -q 'DXVK_ENABLE_NVAPI="1"' "$HOME/.config/winetoolz/env_profiles/dxvk-nvapi.env" || fail "profile"
    assert_contains "$(wine_calls)" "/v nvapi64 /d native,builtin"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 uninstall
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    run_module install_nvapi.sh || fail "uninstall failed"
    [[ ! -e "$pfx/drive_c/windows/system32/nvapi64.dll" ]] || fail "nvapi64 left"
    [[ ! -d "$pfx/dxvk-nvapi-layer" ]] || fail "layer folder left"
}

# =============================================================================
#  Prefix Creator
# =============================================================================

test_maker_never_touches_a_full_folder() {
    # G3 MAKER-1: $HOME holding a stray drive_c used to be wiped.
    fixture_wine
    mkdir -p "$HOME/Documents" "$HOME/.ssh" "$HOME/drive_c"
    printf 'precious' > "$HOME/Documents/precious.txt"
    printf 'key' > "$HOME/.ssh/id_ed25519"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME"                 # pick $HOME itself
    wt_kit_answer 0 "my-prefix"            # → subfolder name
    wt_kit_answer 0 "win64|win10|No"
    wt_kit_answer 1                        # Proceed? No
    run_module winetoolz-prefix-maker.sh || true
    [[ -f "$HOME/Documents/precious.txt" && -f "$HOME/.ssh/id_ed25519" && -d "$HOME/drive_c" ]] \
        || fail "files in the chosen folder were touched"
    [[ ! -e "$HOME/my-prefix/system.reg" ]] || fail "prefix created after No"
}

test_maker_creates_in_subfolder() {
    fixture_wine
    mkdir -p "$HOME/Games"
    printf 'x' > "$HOME/Games/notes.txt"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME/Games"
    wt_kit_answer 0 "witcher"
    wt_kit_answer 0 "win32|win7|No"
    wt_kit_answer 0                        # Proceed
    run_module winetoolz-prefix-maker.sh || fail "maker failed: $(tail -5 "$KIT_TMP/module.out")"
    [[ -f "$HOME/Games/witcher/system.reg" ]] || fail "prefix not created in the subfolder"
    grep -q '^#arch=win32' "$HOME/Games/witcher/system.reg" || fail "WINEARCH not passed"
    assert_contains "$(wine_calls)" "ran winecfg -v win7"
    assert_not_contains "$(wine_calls)" "ran winecfg"$'\n' "winecfg GUI not opened when No"
    grep -q "WT_PREFIX_PATHS=.*$HOME/Games" "$WT_CONFIG_FILE" 2>/dev/null \
        || grep -q "WT_PREFIX_PATHS=.*$HOME/Games" "$HOME/.config/mythix-build/winetoolz.cfg" \
        || fail "parent folder not added to the prefix search paths"
}

test_maker_recreate_waits_for_final_ok() {
    fixture_wine
    local pfx="$HOME/prefixes/old"
    fake_prefix "$pfx" win64
    printf 'save' > "$pfx/drive_c/save.dat"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0                        # Delete it and start fresh? yes
    wt_kit_answer 0 "win64|win10|No"
    wt_kit_answer 1                        # Proceed? No
    run_module winetoolz-prefix-maker.sh || true
    [[ -f "$pfx/drive_c/save.dat" ]] || fail "old prefix deleted before the final confirmation"

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0
    wt_kit_answer 0 "win64|win10|No"
    wt_kit_answer 0                        # Proceed
    run_module winetoolz-prefix-maker.sh || fail "recreate failed"
    [[ ! -e "$pfx/drive_c/save.dat" && -f "$pfx/system.reg" ]] || fail "prefix not recreated"
}

# =============================================================================
#  Prefix Manager
# =============================================================================

test_pm_build_manager_never_offers_buildz_itself() {
    # G3 PM-1: a tarball unpacked straight into buildz made buildz a "build".
    local bz="$HOME/wine-custom/buildz"
    fake_wine "$bz/wine-10.0-staging/bin/wine" "wine-10.0 (Staging)"
    fake_wine "$bz/bin/wine" "stray"
    wt_kit_answer 0 builds
    wt_kit_answer 0 "$bz"                  # even if something returned the root…
    run_module prefix_manager.sh || true
    [[ -d "$bz/wine-10.0-staging" ]] || fail "builds were deleted"
    if grep -q -- "--radiolist" "$ZMOCK_LOG" && grep -- "--radiolist" "$ZMOCK_LOG" | grep -q " $bz "; then
        fail "buildz itself listed as a build"
    fi

    : > "$ZMOCK_QUEUE"; : > "$ZMOCK_LOG"
    wt_kit_answer 0 builds
    wt_kit_answer 0 "$bz/wine-10.0-staging"
    wt_kit_answer 0 "Delete build"
    wt_kit_answer 0                        # confirm
    run_module prefix_manager.sh || true
    [[ ! -e "$bz/wine-10.0-staging" ]] || fail "build not deleted"
    [[ -d "$bz" ]] || fail "buildz removed"
}

test_pm_backup_and_restore_cycle() {
    fake_zstd
    local pfx="$HOME/prefixes/games"
    fake_prefix "$pfx" win64
    printf 'v1' > "$pfx/drive_c/save.dat"

    wt_kit_answer 0 backup
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0                        # confirm backup
    run_module prefix_manager.sh || fail "backup failed: $(tail -5 "$KIT_TMP/module.out")"
    local backup
    backup="$(compgen -G "$HOME/.local/share/mythix-winetoolz/backups/games_*.tar.zst" | head -1)"
    [[ -n "$backup" ]] || fail "no backup written"
    compgen -G "$HOME/.local/share/mythix-winetoolz/backups/*.partial" >/dev/null && fail "partial left"

    # Newer state, then restore — cancelled first (G3 PM-2): nothing changes.
    printf 'v2' > "$pfx/drive_c/save.dat"
    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 restore
    wt_kit_answer 0 "$backup"
    wt_kit_answer 0 "$HOME/prefixes"
    wt_kit_answer 1                        # Restore? No
    run_module prefix_manager.sh || true
    assert_eq v2 "$(cat "$pfx/drive_c/save.dat")" "cancelled restore changed the prefix"

    # A renamed copy still restores into the folder it holds (G3 PM-4).
    cp "$backup" "$HOME/games-before-patch.tar.zst"
    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 restore
    wt_kit_answer 0 "$HOME/games-before-patch.tar.zst"
    wt_kit_answer 0 "$HOME/prefixes"
    wt_kit_answer 0                        # Restore? yes (replaces games/)
    run_module prefix_manager.sh || fail "restore failed: $(wt_kit_terminal_log | tail -5)"
    assert_eq v1 "$(cat "$pfx/drive_c/save.dat")" "backup not restored"
    [[ ! -e "$HOME/prefixes/games-before-patch" ]] || fail "restored under the file name"
    compgen -G "$HOME/prefixes/.wt-restore.*" >/dev/null && fail "staging folder left"
    log_has "REPLACED"
}

test_pm_corrupt_backup_keeps_prefix() {
    # G3 PM-3: a corrupt archive used to destroy the existing prefix.
    fake_zstd
    local pfx="$HOME/prefixes/games"
    fake_prefix "$pfx" win64
    printf 'keep' > "$pfx/drive_c/save.dat"
    tar -cf - -C "$HOME/prefixes" games | gzip -c | head -c 300 > "$HOME/broken.tar.zst"
    wt_kit_answer 0 restore
    wt_kit_answer 0 "$HOME/broken.tar.zst"
    wt_kit_answer 0 "$HOME/prefixes"
    wt_kit_answer 0
    run_module prefix_manager.sh || true
    assert_eq keep "$(cat "$pfx/drive_c/save.dat" 2>/dev/null)" "existing prefix damaged by a corrupt backup"
}

test_pm_kill_when_nothing_runs() {
    local pfx="$HOME/prefixes/idle"
    fake_prefix "$pfx" win64
    wt_kit_answer 0 kill
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 exit
    run_module prefix_manager.sh || fail "module died (G3 PM-6)"
    log_has "No Wine processes are running"
}

test_pm_delete_needs_a_prefix() {
    local pfx="$HOME/prefixes/gone"
    fake_prefix "$pfx" win64
    wt_kit_answer 0 delete
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0
    run_module prefix_manager.sh || true
    [[ ! -e "$pfx" ]] || fail "prefix not deleted"
}

# =============================================================================
#  Prefix Diagnostics
# =============================================================================

test_diagnostics_layers_and_overrides() {
    local pfx="$HOME/prefixes/diag" n
    fake_prefix "$pfx" win64
    for n in dxgi d3d11 d3d9 d3d12 d3d12core; do builtin_dll "$pfx/drive_c/windows/system32/$n.dll"; done
    cat > "$pfx/user.reg" <<'REG'
WINE REGISTRY Version 2

[Software\\Wine] 1700000000
"Version"="win7"

[Software\\Wine\\DllOverrides] 1700000000
#time=1
"d3d8"=""
"dinput8"="native,builtin"

[Software\\Wine\\Fonts] 1700000000
"A"="b"
"C"="d"
REG
    wt_kit_answer 0 "$pfx"
    run_module prefix_diagnostics.sh || fail "diagnostics failed"
    log_has "DXVK        :  builtin (Wine's own)"
    log_has "VKD3D       :  builtin (Wine's own)"
    log_has "DLL overrides :  2"
    log_has "(disabled)"
    log_has "win7"

    # Real DXVK DLLs (native, with DXVK strings) are told apart.
    : > "$ZMOCK_LOG"
    for n in dxgi d3d11 d3d9; do fake_pe "$pfx/drive_c/windows/system32/$n.dll" x64; printf 'DXVK_HUD' >> "$pfx/drive_c/windows/system32/$n.dll"; done
    wt_kit_answer 0 "$pfx"
    run_module prefix_diagnostics.sh || fail "diagnostics failed"
    log_has "DXVK        :  installed (native)"
}

# =============================================================================
#  Wine Install Manager
# =============================================================================

wim_answers_install_dir() {  # <source dir> <name>
    wt_kit_answer 0 install
    wt_kit_answer 0 directory
    wt_kit_answer 0 "$1"
    wt_kit_answer 0 "$2"
}

test_wim_names_are_data_not_code() {
    # G3 WIM-1: $(...) in a folder name ran when the install script ran.
    local src="$HOME/src/wine-9.0\$(touch $KIT_TMP/PWNED)"
    fake_wine "$src/bin/wine" "wine-9.0"
    wim_answers_install_dir "$src" "wine-9.0"
    wt_kit_answer 1                        # Set Active? No
    wt_kit_answer 0 back
    run_module wine_install_manager.sh || fail "module failed (G3 WIM-5?): $(tail -3 "$KIT_TMP/module.out")"
    [[ ! -e "$KIT_TMP/PWNED" ]] || fail "a file name was executed"
    [[ -x "$HOME/.local/share/mythix-wine-installs/wine-9.0/bin/wine" ]] || fail "not installed"
    grep -q '^version=wine-9.0' "$HOME/.local/share/mythix-wine-installs/wine-9.0/.mythix-meta" || fail "meta"
}

test_wim_bad_archive_keeps_current_install() {
    # G3 WIM-2: overwrite deleted the working install before validating.
    local inst="$HOME/.local/share/mythix-wine-installs/wine-9.0"
    fake_wine "$inst/bin/wine" "wine-9.0 (old)"
    head -c 2000 /dev/urandom > "$HOME/wine-9.0.tar.xz"
    wt_kit_answer 0 install
    wt_kit_answer 0 tarball
    wt_kit_answer 0 "$HOME/wine-9.0.tar.xz"
    wt_kit_answer 0 "wine-9.0"
    wt_kit_answer 0                        # overwrite? yes
    wt_kit_answer 0 back
    run_module wine_install_manager.sh || true
    [[ -x "$inst/bin/wine" ]] || fail "working install destroyed by a bad archive"
    compgen -G "$HOME/.local/share/mythix-wine-installs/.staging.*" >/dev/null && fail "staging left"
    return 0
}

test_wim_flat_tarball_layout() {
    # G3 WIM-4: an archive without a top folder was mangled by --strip-components.
    mkdir -p "$KIT_TMP/flat"
    fake_wine "$KIT_TMP/flat/bin/wine" "wine-10.5 (ci)"
    mkdir -p "$KIT_TMP/flat/lib/wine"
    tar -cJf "$HOME/wine-10.5-ci.tar.xz" -C "$KIT_TMP/flat" bin lib
    wt_kit_answer 0 install
    wt_kit_answer 0 tarball
    wt_kit_answer 0 "$HOME/wine-10.5-ci.tar.xz"
    wt_kit_answer 0 "wine-10.5-ci"
    wt_kit_answer 1
    wt_kit_answer 0 back
    run_module wine_install_manager.sh || fail "install failed"
    [[ -x "$HOME/.local/share/mythix-wine-installs/wine-10.5-ci/bin/wine" ]] || fail "flat layout broken"
    [[ -d "$HOME/.local/share/mythix-wine-installs/wine-10.5-ci/lib/wine" ]] || fail "lib/ lost"
}

test_wim_set_active_keeps_users_own_wrapper() {
    # G3 WIM-3: the user's own ~/.local/bin/wine was replaced silently.
    local src="$HOME/src/wine-10"
    fake_wine "$src/bin/wine" "wine-10"
    fake_wine "$src/bin/winecfg"
    mkdir -p "$HOME/.local/bin"
    printf '#!/bin/sh\n# my own wrapper\nexec /opt/wine/bin/wine "$@"\n' > "$HOME/.local/bin/wine"
    wim_answers_install_dir "$src" "wine-10"
    wt_kit_answer 0                        # Set Active? yes
    wt_kit_answer 1                        # replace your files? no
    wt_kit_answer 0 back
    run_module wine_install_manager.sh || fail "module failed"
    grep -q 'my own wrapper' "$HOME/.local/bin/wine" || fail "user's wrapper replaced"
    [[ -L "$HOME/.local/bin/winecfg" ]] || fail "free name not linked"
    log_has "Left as they were (yours)"
}

test_wim_dotdot_name_rejected() {
    local src="$HOME/src/w"
    fake_wine "$src/bin/wine"
    wim_answers_install_dir "$src" ".."
    wt_kit_answer 0 back
    run_module wine_install_manager.sh || fail "module died"
    [[ -d "$HOME/.local/share" ]] || fail "\$HOME/.local/share touched"
    log_has "Please enter a name"
}

# =============================================================================
#  Installers: DLL Installer, Runtimes, DirectX, VC++, System File Installer
# =============================================================================

# fixture_dx_redist <out.exe> <cab name> <dll>... — a DirectX-style
# redistributable: a cabinet holding one cabinet holding the DLLs.
fixture_dx_redist() {
    local out="$1" cab="$2" d; shift 2
    local work="$KIT_TMP/dx.$RANDOM"
    mkdir -p "$work"
    local -a members=()
    for d in "$@"; do
        case "$cab" in *x64*) fake_pe "$work/$d" x64 ;; *) fake_pe "$work/$d" x86 ;; esac
        printf '%s' "$cab/$d" >> "$work/$d"
        members+=("$d=$work/$d")
    done
    mkcab "$work/$cab" "${members[@]}"
    if [[ -f "$out" ]]; then
        # add to an existing redist: rebuild it with every inner cabinet
        printf '%s\n' "$cab=$work/$cab" >> "$out.members"
    else
        printf '%s\n' "$cab=$work/$cab" > "$out.members"
    fi
    mapfile -t members < "$out.members"
    mksfx "$out" "${members[@]}"
}

dllinst_answers() {  # <prefix> <keys|separated>
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$1"
    wt_kit_answer 0 "$2"
}

test_dll_installer_targets_by_prefix_arch() {
    # G1 DLL-2: 32-bit DLLs must go to system32 in a 32-bit prefix.
    fixture_wine; fake_catalog
    fake_pe "$KIT_TMP/d3drm.dll" x86
    fake_pe "$KIT_TMP/dinput.dll" x86
    fake_pe "$KIT_TMP/c47_32.dll" x86
    fake_pe "$KIT_TMP/c47_64.dll" x64
    catalog_seed d3drm "$KIT_TMP/d3drm.dll" d3drm.dll
    catalog_seed dinputto8 "$KIT_TMP/dinput.dll" dinput_dinputto8.dll
    catalog_seed d3dcompiler_47_x86 "$KIT_TMP/c47_32.dll" d3dcompiler_47_32.dll
    catalog_seed d3dcompiler_47_x64 "$KIT_TMP/c47_64.dll" d3dcompiler_47.dll

    fake_prefix "$HOME/prefixes/p32" win32
    dllinst_answers "$HOME/prefixes/p32" "d3drm|dinput|d3dcompiler_47"
    run_module dll_installer.sh || fail "win32 run failed: $(wt_kit_terminal_log | tail -5)"
    local s32="$HOME/prefixes/p32/drive_c/windows/system32"
    cmp -s "$KIT_TMP/d3drm.dll" "$s32/d3drm.dll" || fail "d3drm not in a win32 system32"
    cmp -s "$KIT_TMP/dinput.dll" "$s32/dinput.dll" || fail "dinput not in a win32 system32"
    cmp -s "$KIT_TMP/c47_32.dll" "$s32/d3dcompiler_47.dll" || fail "32-bit d3dcompiler_47 not in system32"
    log_has "d3dcompiler_47 finished successfully."

    : > "$ZMOCK_QUEUE"
    fake_prefix "$HOME/prefixes/p64" win64
    dllinst_answers "$HOME/prefixes/p64" "d3dcompiler_47|d3drm"
    run_module dll_installer.sh || fail "win64 run failed"
    cmp -s "$KIT_TMP/c47_64.dll" "$HOME/prefixes/p64/drive_c/windows/system32/d3dcompiler_47.dll" || fail "x64 → system32"
    cmp -s "$KIT_TMP/c47_32.dll" "$HOME/prefixes/p64/drive_c/windows/syswow64/d3dcompiler_47.dll" || fail "x86 → syswow64"
    cmp -s "$KIT_TMP/d3drm.dll" "$HOME/prefixes/p64/drive_c/windows/syswow64/d3drm.dll" || fail "d3drm → syswow64"
    assert_contains "$(wine_calls)" "/v d3dcompiler_47 /d native,builtin"
}

test_dll_installer_never_writes_into_the_runner() {
    # G1 DLL-1: a Proton prefix links its DLLs to the Proton install.
    fixture_wine; fake_catalog
    local runner="$HOME/proton/files/lib/wine/i386-windows"
    mkdir -p "$runner"
    builtin_dll "$runner/d3drm.dll"
    cp "$runner/d3drm.dll" "$KIT_TMP/runner-orig.dll"
    fake_prefix "$HOME/prefixes/proton" win64
    ln -s "$runner/d3drm.dll" "$HOME/prefixes/proton/drive_c/windows/syswow64/d3drm.dll"
    fake_pe "$KIT_TMP/d3drm.dll" x86
    catalog_seed d3drm "$KIT_TMP/d3drm.dll" d3drm.dll
    dllinst_answers "$HOME/prefixes/proton" "d3drm"
    run_module dll_installer.sh || fail "run failed"
    cmp -s "$runner/d3drm.dll" "$KIT_TMP/runner-orig.dll" || fail "the Proton install was overwritten"
    [[ -L "$HOME/prefixes/proton/drive_c/windows/syswow64/d3drm.dll.wt_bak" ]] || fail "link not kept as backup"
}

test_dll_installer_rejects_bad_cache_and_bad_download() {
    # G1 DLL-3: a 0-byte (or tampered) cached file must never be installed.
    fixture_wine; fake_catalog
    fake_pe "$KIT_TMP/d3drm.dll" x86
    catalog_add d3drm "$KIT_TMP/d3drm.dll" d3drm.dll     # pinned to the real file
    mkdir -p "$HOME/.cache/winetoolz/downloads" "$HOME/.cache/winetoolz/dll_installer"
    : > "$HOME/.cache/winetoolz/dll_installer/d3drm.dll"   # 2.x poisoned cache
    printf 'MZ tampered' > "$HOME/.cache/winetoolz/downloads/d3drm.dll"
    fake_prefix "$HOME/prefixes/p" win64
    dllinst_answers "$HOME/prefixes/p" "d3drm"
    run_module dll_installer.sh || true
    [[ ! -e "$HOME/prefixes/p/drive_c/windows/syswow64/d3drm.dll" ]] || fail "unverified file installed"
    log_has "Some components did not install"
    assert_contains "$(wt_kit_terminal_log)" "failed verification"
    assert_contains "$(wt_kit_terminal_log)" "Failed    : d3drm"

    # Served correctly over the network, it installs.
    local srv="$KIT_TMP/srv"; mkdir -p "$srv"; cp "$KIT_TMP/d3drm.dll" "$srv/d3drm.dll"
    local port pid
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$srv" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
    sed -i "s|https://fixture.invalid/d3drm.dll|http://127.0.0.1:$port/d3drm.dll|" "$WT_DOWNLOADS_LIST"
    export WT_ALLOW_HTTP=1
    : > "$ZMOCK_QUEUE"
    dllinst_answers "$HOME/prefixes/p" "d3drm"
    run_module dll_installer.sh || fail "run with a good server failed: $(wt_kit_terminal_log | tail -4)"
    kill "$pid" 2>/dev/null
    cmp -s "$KIT_TMP/d3drm.dll" "$HOME/prefixes/p/drive_c/windows/syswow64/d3drm.dll" || fail "good download not installed"
}

test_dll_installer_directx_cabinets() {
    fixture_wine; fake_catalog
    local redist="$KIT_TMP/directx_Jun2010_redist.exe"
    fixture_dx_redist "$redist" Jun2010_d3dx9_43_x86.cab d3dx9_43.dll
    fixture_dx_redist "$redist" Jun2010_d3dx9_43_x64.cab d3dx9_43.dll
    fixture_dx_redist "$redist" Apr2007_xinput_x86.cab xinput1_3.dll
    fixture_dx_redist "$redist" Apr2007_xinput_x64.cab xinput1_3.dll
    catalog_seed dx_jun2010 "$redist" directx_Jun2010_redist.exe
    fake_prefix "$HOME/prefixes/p" win64
    dllinst_answers "$HOME/prefixes/p" "d3dx9_43|xinput1_3|d3dx11_43"
    run_module dll_installer.sh || true
    local w="$HOME/prefixes/p/drive_c/windows"
    [[ "$(wt_pe_arch "$w/syswow64/d3dx9_43.dll")" == x86 ]] || fail "32-bit d3dx9_43 not in syswow64"
    [[ "$(wt_pe_arch "$w/system32/d3dx9_43.dll")" == x64 ]] || fail "64-bit d3dx9_43 not in system32"
    [[ "$(wt_pe_arch "$w/syswow64/xinput1_3.dll")" == x86 ]] || fail "xinput1_3 (x86)"
    assert_contains "$(wt_kit_terminal_log)" "Succeeded : d3dx9_43 xinput1_3"
    assert_contains "$(wt_kit_terminal_log)" "Failed    : d3dx11_43"
}

test_runtimes_exit_codes_and_arches() {
    # G1 RT-1 / RT-2 / RT-5: real exit codes, /q for 2005, x86 only on win32.
    fixture_wine; fake_catalog
    local k
    for k in vc2005_x86 vc2005_x64 vc2010_x86 vc2010_x64; do
        fake_pe "$KIT_TMP/$k.exe" x86; printf '%s' "$k" >> "$KIT_TMP/$k.exe"
        catalog_seed "$k" "$KIT_TMP/$k.exe" "$k.exe"
    done
    fake_prefix "$HOME/prefixes/p32" win32
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME/prefixes/p32"
    wt_kit_answer 0 "vcredist2005|vcredist2010"
    export FAKE_WINE_FAIL="vc2010_x86.exe"
    run_module runtimes_installer.sh || true
    assert_contains "$(wine_calls)" "vc2005_x86.exe /q"$'\n'
    assert_not_contains "$(wine_calls)" "vc2005_x64.exe" "x64 installer run in a win32 prefix"
    assert_contains "$(wt_kit_terminal_log)" "Succeeded : vcredist2005"
    assert_contains "$(wt_kit_terminal_log)" "Failed    : vcredist2010"
    log_has "Some runtimes did not install"
}

test_runtimes_xact_installs_real_dlls() {
    fixture_wine; fake_catalog
    local redist="$KIT_TMP/directx_Jun2010_redist.exe"
    fixture_dx_redist "$redist" Jun2010_xact_x86.cab xactengine3_7.dll
    fixture_dx_redist "$redist" Jun2010_xaudio_x86.cab xaudio2_7.dll xapofx1_5.dll xaudio2_8.dll
    fixture_dx_redist "$redist" Jun2010_x3daudio_x86.cab x3daudio1_7.dll
    catalog_seed dx_jun2010 "$redist" directx_Jun2010_redist.exe
    fake_prefix "$HOME/prefixes/p" win64
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME/prefixes/p"
    wt_kit_answer 0 "xact"
    run_module runtimes_installer.sh || fail "xact failed: $(wt_kit_terminal_log | tail -6)"
    local wow="$HOME/prefixes/p/drive_c/windows/syswow64" n
    for n in xactengine3_7 xaudio2_7 xapofx1_5 x3daudio1_7; do
        [[ -f "$wow/$n.dll" ]] || fail "$n.dll not installed"
        assert_contains "$(wine_calls)" "/v $n /d native,builtin"
    done
    [[ ! -e "$wow/xaudio2_8.dll" ]] || fail "xaudio2_8 must stay Wine's own"
    assert_contains "$(wine_calls)" "regsvr32.exe /s xaudio2_7.dll"
}

test_runtimes_directplay_from_dxnt() {
    fixture_wine; fake_catalog
    local work="$KIT_TMP/dp" f
    mkdir -p "$work"
    for f in dplayx.dll dpnet.dll dpnhpast.dll dpnsvr.exe; do fake_pe "$work/$f" x86; done
    mkcab "$work/dxnt.cab" dplayx.dll="$work/dplayx.dll" dpnet.dll="$work/dpnet.dll" \
        dpnhpast.dll="$work/dpnhpast.dll" dpnsvr.exe="$work/dpnsvr.exe"
    mksfx "$KIT_TMP/directx_feb2010_redist.exe" dxnt.cab="$work/dxnt.cab"
    catalog_seed dx_feb2010 "$KIT_TMP/directx_feb2010_redist.exe"
    fake_prefix "$HOME/prefixes/p" win32
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME/prefixes/p"
    wt_kit_answer 0 "directplay"
    run_module runtimes_installer.sh || fail "directplay failed: $(wt_kit_terminal_log | tail -6)"
    [[ -f "$HOME/prefixes/p/drive_c/windows/system32/dplayx.dll" ]] || fail "dplayx.dll not installed"
    assert_contains "$(wine_calls)" "/v dplayx /d native"
}

test_directx_overrides_follow_native_dlls() {
    fixture_wine; fake_catalog
    local work="$KIT_TMP/dxs"
    mkdir -p "$work"
    fake_pe "$work/DXSETUP.exe" x86
    mksfx "$KIT_TMP/directx_Jun2010_redist.exe" DXSETUP.exe="$work/DXSETUP.exe"
    catalog_seed dx_jun2010 "$KIT_TMP/directx_Jun2010_redist.exe"
    local pfx="$HOME/prefixes/p"
    fake_prefix "$pfx" win64
    : > "$pfx/drive_c/windows/explorer.exe"
    fake_pe "$pfx/drive_c/windows/syswow64/d3dx9_43.dll" x86     # as DXSETUP leaves it
    builtin_dll "$pfx/drive_c/windows/system32/d3dx9_42.dll"     # Wine's own: no override
    fake_pe "$pfx/drive_c/windows/syswow64/xaudio2_7.dll" x86    # audio: left alone
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0
    run_module directx_installer-local.sh || fail "run failed: $(wt_kit_terminal_log | tail -5)"
    assert_contains "$(wine_calls)" "ran DXSETUP.exe /silent"
    assert_contains "$(wine_calls)" "/v d3dx9_43 /d native,builtin"
    assert_not_contains "$(wine_calls)" "/v d3dx9_42 " "builtin DLL got an override"
    assert_not_contains "$(wine_calls)" "/v xaudio2_7 " "audio DLL got an override"
}

test_vcruntime_win32_runs_x86_only() {
    fixture_wine; fake_catalog
    fake_pe "$KIT_TMP/x86.exe" x86; fake_pe "$KIT_TMP/x64.exe" x64
    catalog_seed vc14_x86 "$KIT_TMP/x86.exe" vc14_vc_redist.x86.exe
    catalog_seed vc14_x64 "$KIT_TMP/x64.exe" vc14_vc_redist.x64.exe
    fake_prefix "$HOME/prefixes/p32" win32
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$HOME/prefixes/p32"
    wt_kit_answer 0 vc14
    wt_kit_answer 0 exit
    run_module vcruntime_installer-gui.sh || fail "run failed"
    assert_contains "$(wine_calls)" "vc14_vc_redist.x86.exe /install /quiet /norestart"
    assert_not_contains "$(wine_calls)" "vc_redist.x64" "x64 installer run in a win32 prefix"
}

test_system_file_installer_from_zip() {
    fixture_wine
    local work="$KIT_TMP/zipsrc"
    mkdir -p "$work/x64" "$work/x86"
    fake_pe "$work/x64/foo.dll" x64
    fake_pe "$work/x86/foo.dll" x86
    printf 'DllRegisterServer' >> "$work/x86/foo.dll"
    (cd "$work" && python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); [z.write(p) for p in sys.argv[2:]]' "$KIT_TMP/pack.zip" x64/foo.dll x86/foo.dll)
    local pfx="$HOME/prefixes/p"
    fake_prefix "$pfx" win64
    builtin_dll "$pfx/drive_c/windows/system32/foo.dll"
    wt_kit_answer 0 "$HOME/$FAKE_WINE_REL"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Select Local Archive"
    wt_kit_answer 0 "$KIT_TMP/pack.zip"
    wt_kit_answer 0 "Install ALL 64-bit"
    wt_kit_answer 0 "Install ALL 32-bit"
    run_module install_components-x86_64.sh || fail "run failed: $(tail -5 "$KIT_TMP/module.out")"
    [[ "$(wt_pe_arch "$pfx/drive_c/windows/system32/foo.dll")" == x64 ]] || fail "x64 foo.dll"
    [[ "$(wt_pe_arch "$pfx/drive_c/windows/syswow64/foo.dll")" == x86 ]] || fail "x86 foo.dll"
    wt_dll_is_wine_builtin "$pfx/drive_c/windows/system32/foo.dll.wt_bak" || fail "builtin not backed up"
    assert_contains "$(wine_calls)" "reg add HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides /v foo /d native,builtin"
    assert_contains "$(wine_calls)" "regsvr32.exe /s foo.dll"
    grep -q DllOverrides "$pfx/user.reg" 2>/dev/null && fail "user.reg written directly"
    log_has "Installed 2 file(s)"
}

# --- real Wine -----------------------------------------------------------------

real_wine_dxvk_cycle() {  # <arch> <source prefix> <loader>
    local arch="$1" src="$2" loader="$3"
    local pfx="$HOME/prefixes/real-$arch" rel n sys
    real_prefix_copy "$src" "$pfx"
    fixture_vulkan
    rel="$(fixture_release dxvk dxvk-9.9 x64 x32 "${DXVK_DLLS[@]}")"
    wt_kit_answer 0 install
    wt_kit_answer 0 "$loader"
    wt_kit_answer 0 "$pfx"
    wt_kit_answer 0 "Use existing"
    KIT_TIMEOUT=600 run_module dxvk_setup-gui.sh || fail "install failed: $(tail -8 "$KIT_TMP/module.out")"
    WINEPREFIX="$pfx" "$(dirname "$loader")/wineserver" -w 2>/dev/null || true
    sys="$pfx/drive_c/windows/system32"
    for n in "${DXVK_DLLS[@]}"; do
        grep -q "^\"$n\"=\"native,builtin\"" "$pfx/user.reg" || fail "$n override not in user.reg"
    done
    if [[ "$arch" == win64 ]]; then
        cmp -s "$rel/x64/d3d11.dll" "$sys/d3d11.dll" || fail "x64 d3d11 not installed"
        cmp -s "$rel/x32/d3d11.dll" "$pfx/drive_c/windows/syswow64/d3d11.dll" || fail "x32 d3d11 not installed"
    else
        cmp -s "$rel/x32/d3d11.dll" "$sys/d3d11.dll" || fail "x32 d3d11 not installed in win32 system32"
    fi

    : > "$ZMOCK_QUEUE"
    wt_kit_answer 0 uninstall
    wt_kit_answer 0 "$loader"
    wt_kit_answer 0 "$pfx"
    KIT_TIMEOUT=600 run_module dxvk_setup-gui.sh || fail "uninstall failed"
    WINEPREFIX="$pfx" "$(dirname "$loader")/wineserver" -w 2>/dev/null || true
    for n in "${DXVK_DLLS[@]}"; do
        wt_dll_is_wine_builtin "$sys/$n.dll" || fail "$n builtin not restored"
        if grep -q "^\"$n\"=" "$pfx/user.reg"; then fail "$n override left in user.reg"; fi
    done
}

test_real_wine_dxvk_win64() {
    [[ -n "${WT_TEST_REAL_PREFIX64:-}" && -x /usr/lib/wine/wine64 ]] || { echo "  (skipped: no real win64 prefix)"; return 0; }
    real_wine_dxvk_cycle win64 "$WT_TEST_REAL_PREFIX64" /usr/lib/wine/wine64
}

test_real_wine_dxvk_win32() {
    [[ -n "${WT_TEST_REAL_PREFIX32:-}" && -x /usr/lib/wine/wine ]] || { echo "  (skipped: no real win32 prefix)"; return 0; }
    real_wine_dxvk_cycle win32 "$WT_TEST_REAL_PREFIX32" /usr/lib/wine/wine
}

# --- run ----------------------------------------------------------------------
run_all_tests "winetoolz module tests"
