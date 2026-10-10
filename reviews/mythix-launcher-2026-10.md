# Mythix launcher review (2026-10-10)

A review of the launcher's Rust core (`src/`, 16 files, from `src.zip`), read
alongside neutron's Python launcher for context. No `Cargo.toml` came with it,
so nothing was compiled or run here: every finding comes from reading the code,
plus small experiments where a bug could be shown outside the app (Rust
snippets, Python mirrors, the Wine and Proton sources).

**How it was done.** Five reviewers each took one area: Steam import, the
loader and launch path, the runtime and container, gamepad and input, and
state and security. Every finding then went to a separate skeptic whose job
was to refute it from the code. 96 findings came in. 80 survived, and since
several were reported from two areas, that leaves about 60 distinct issues
below. File and line numbers refer to the zip as uploaded.

**One correction up front.** The first reviewers were told that Steam runs
inside the game's prefix. It doesn't: it's the native Linux client, which
neutron reaches through the prefix's `steam.exe` shim. Findings that rested on
the wrong model, such as "exit detection never ends" or "Stop kills Steam",
were refuted and are listed at the end.

---

## Fix first

### 1. Importing a Steam prefix can delete other games' prefixes, or all of them
`steam_import.rs:203-212`, called from `commands.rs:352-363` and `:581`

The clone goes to `~/.mythix/gamedata/<cleaned display name>`, and whatever
is already there is removed with `remove_dir_all` first.
- A title that is only symbols or emoji ("!!!", "?", "🎮") cleans to `""`.
  `gamedata.join("")` is `gamedata/` itself, so **every prefix is deleted**,
  saves included.
- Different games can clean to the same name. Prey (2006) and Prey (2017)
  both become `prey`, and "X: Remastered" and "X Remastered" both become
  `x_remastered`. Importing one then deletes the other's prefix. The
  "user confirmed overwrite" comment can't cover this, because nothing checks
  whether another library entry owns the folder.
- The order is delete, then copy, then check `cp`, with no cleanup. A failed
  or out-of-space copy leaves a half prefix behind. The caller swallows the
  error and gives the entry a fresh empty prefix, and the only sign is a
  status line.

**Fix:** name the folder after the app id. `paths::default_prefix_dir("mythix-<appid>")`
is already where loader entries and the fresh-prefix fallback put it. Reject
an empty, `.` or `..` name. Copy into a temp sibling
(`gamedata/.clone-<uuid>`) and rename it into place only once `cp` has
succeeded; never `remove_dir_all` the destination in the backend. Refuse if
another entry's `prefix_path` is that folder. Pass the error to the UI
instead of silently falling back.

### 2. A prefix clone never finishes: `dir_size` walks the whole filesystem in a loop
`steam_import.rs:242, 250-263`

After `cp -a`, `dir_size` recurses with `Path::is_dir()`, which follows
symlinks. Every Wine/Proton prefix has `pfx/dosdevices/z: -> /`, so it walks
`/`, finds the clone's own `z:` again, and goes round until paths hit
PATH_MAX. Reproduced with a copy of the function on a folder holding only
that link: still running after 6-8 s, about 20,000 directories in.

**Fix:** recurse on `entry.file_type()` (which doesn't follow links), and only
when it's a directory; count only regular files. Or drop the size, since it
only feeds a status line. `find_game_exe`'s `scan_dir` has the same
`is_dir()` pattern; a depth cap of 4 limits it, but it's worth switching too.

### 3. The looni→mythix migration leaves stale absolute paths behind
`paths.rs:30` (`migrate_one`)

The migration renames `~/.local/share/looni`, `~/.looni`, `~/Games/looni` and
`gamez-pfx_data`. But `library.json` stores absolute `prefix_path`,
`exe_path`, `cover_art` and `proton_path` values, and `settings.json` stores
`default_prefix_root`, `default_proton_path` and `custom_tools_dir`. Nothing
rewrites them. After an upgrade, each game points at a folder that no longer
exists, so it starts with a fresh empty prefix and its saves seem to be gone.

**Fix:** during the migration, before anything loads, rewrite the old roots to
the new ones in both files, including `.../gamez-pfx_data` → `.../gamedata`,
using an atomic write. As a fallback, leave compatibility symlinks at the old
paths. Add a test with a pre-rebrand `library.json`. If you're the only user
and already migrated by hand, this only matters for anyone else upgrading.

### 4. Launching fails (panics) when an environment value has non-ASCII text past byte 100/120
`launcher.rs:623, 631, 636` (`debug_launch_dump`)

`format!("{}…", &v[..120])` slices by bytes and panics if byte 120 falls
inside a multi-byte character. `spawn_game` always builds this dump before it
spawns, so a game whose paths contain é, ü, ™ or Japanese text far enough in
can't launch at all. Values over 120 bytes are routine:
`STEAM_RUNTIME_LIBRARY_PATH`, for example, always is.

**Fix:** one char-safe helper used at all three places:
```rust
fn trunc(s: &str, n: usize) -> String {
    match s.char_indices().nth(n) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}
```

### 5. After a Guide press, pad input can reach the launcher while you're in the game
`gamepad.rs:835` (`bring_to_front`)

`WINDOW_FOCUSED` is forced to `true` after a Guide restore. The comment says
this is deliberate, for when KDE/Wayland refuses to give the launcher focus.
But in exactly that case the launcher never gains focus, so it never gets a
focus-out, and the flag stays `true`. The pause logic (`set_action`, line 466)
is then off for the rest of the session, and in-game presses drive the
launcher UI. A reviewer found a public v1.1.0 copy of the frontend in which X/Y
while a game runs call kill (I haven't checked that copy myself).

**Fix:** don't force it. After `set_focus`/`activate_window`, set
`WINDOW_FOCUSED` from `window.is_focused()` 300-500 ms later. Or accept
non-Guide presses only until a short deadline, unless a real `Focused(true)`
arrives first.

---

## Changes for today's mythix-loader work

The loader changed a lot today (v1.3 and v1.4 in `mythix-tools`). The
launcher's JSON parsing already copes: `LoaderPlan` ignores the new
`run_dir` field, and nothing reads the retired ini keys or the `client/`
folders. What's left to do on the launcher side:

- **Re-vendor the loader.** Copy `mythix-loader`, `mythix_loader.exe` and
  `mythix_loader_32.exe` from mythix-tools into the launcher's `loader/`,
  since `include_bytes!` bakes them in. Extend `embedded_loader_is_present`
  to check the exes contain the UTF-16LE string `Mythix Loader v1.4`, and that
  the script contains `"run_dir"`, so a stale copy fails the test.
- **Put `--` before per-game launch args for loader stubs.** `launcher.rs:428`
  appends `config.launch_args` straight after the stub path. The stub treats
  `--debug` and `--ini <x>` as its own options, so a game can't be given
  those. The stub forwards everything after `--` untouched. Fix: when
  `loader::is_loader_stub(&game.exe_path)` and there are launch args, push
  `"--"` first.
- **Existing profiles keep their old stub.** Each profile has its own copy of
  the stub, and only re-running the script refreshes it. Flag a profile as
  stale when its stub bytes differ from `LOADER_EXE_64/32`, or its ini still
  has `SteamClientDll` or `ExeRunDir=<profile dir>`, and offer a one-click
  rebuild.
- **App id checked too late.** `import_loader_game` (`commands.rs:636`)
  rejects a missing app id *after* the script has written an `AppId=0`
  profile. The script now has `--require-appid`: pass it in `run_loader`'s
  real (non-dry-run) call and the script fails before writing anything.
- **A missing game fails silently.** `validate_config` only checks that the
  stub exists. Read `Exe=` from the profile's ini before launching, and say
  "the game isn't at <path> any more — rebuild the loader profile" if it's
  gone.
- **Container launches:** once `STEAM_COMPAT_INSTALL_PATH` is overridden, the
  profile folder is only shared into the container through home sharing. Add
  it to `STEAM_COMPAT_MOUNTS`, in the atom-mode rewrite too
  (`launcher.rs:310-331`).
- **Optional:** before launching a loader entry, check `~/.steam/steam.pid`
  (the same test as neutron's `steam_client_running`) and warn that Steam has
  to be running.

---

## Neutron notes

Things noticed while reading neutron to understand the launch path. They
aren't launcher findings, but they decide how games end.

- **30 seconds after the launched process exits, neutron kills the prefix.**
  `Session.run` waits for the process, then runs `wineserver -w` with
  `timeout=30` and `wineserver -k` on timeout. In a direct launch (no
  `steam.exe` shim), a launcher-style exe that starts the real game and exits
  gets the real game **killed about 30 s later**. The same goes for the
  `start /wait` mode used for exe names containing "launcher", because
  `start /wait` only waits for that one process. Loader stubs at v1.4 avoid
  this, because the stub now waits for the game's whole process tree.
  Options: wait without a timeout and log what's still running; make the
  timeout a knob (`NEUTRON_WAIT_TIMEOUT`, 0 = forever); or only `-k` when
  nothing but Wine's own processes are left.
- **Through the `steam.exe` shim, the session lasts until every process in the
  prefix has exited.** For game launches, Proton's `steam.exe` calls
  `NtSetInformationProcess(ProcessWineMakeProcessSystem, &wait_handle)`, and
  Wine replaces `wait_handle` with the wineserver's shutdown event (Proton
  `steam.c` around line 895; Wine `ntdll/unix/process.c`). That's usually what
  you want. One edge case: a game that uses an out-of-process COM object
  makes Wine start `dllhost.exe`, which never exits under Wine, so such a
  session would never end. I haven't reproduced this through the shim; I
  only saw `dllhost.exe` linger in the loader's own tests.
- `waitforexitandrun` doesn't wait for a previous wineserver before launching,
  unlike Valve's Proton script. That's fine here, since nothing else runs in
  a game's prefix.

---

## Worth fixing

### Library and settings files
- **`library.json` writes are neither atomic nor locked.**
  `game_library.rs:159` (`save_library` is a plain `fs::write`) and the
  load-modify-save callers.
  - The playtime thread, async imports and a second instance can each load,
    change and save, so updates get lost.
  - A crash mid-write leaves a truncated file. `load_library` treats an empty
    file as a first run (`:141-146`), so the next save makes the loss
    permanent. `settings.json` has the same problem (`settings.rs:66`), and a
    parse error silently resets every setting.
  - **Fix:** one `with_library(|lib| …)` helper with a process-wide `Mutex`
    (plus an flock for a second instance). Write `*.tmp`, `sync_all`, keep a
    `.bak`, rename into place, then fsync the folder. Treat an empty or
    unparsable file as an error (offer the `.bak`); only a missing file means
    first run. `runtime.rs:493` already writes to a temp file and renames it.

### Steam import
- **The VDF parser reads UTF-8 as Latin-1.** `vdf.rs:130, 137`
  (`s.push(c as char)` per byte).
  - Mangles every ™/® title, accented names and non-ASCII library paths:
    `/run/media/josé/Jeux` becomes `josÃ©`. A mangled library path then fails
    `is_dir`, and the library is dropped.
  - A BOM gives an empty document, and `read_to_string` drops a whole file
    with invalid UTF-8.
  - **Fix:** collect bytes and decode once with `String::from_utf8_lossy`,
    and strip a leading U+FEFF.
  - The same parser reads `compatibilitytool.vdf`, where it also takes a
    random tool entry (`map.values().next()` on a HashMap). Use an
    order-preserving map.
- **Steam discovery misses common setups.** `steam_import.rs:54`. It only
  tries `debian-installation` and `~/.steam/steam`, so it misses
  `~/.steam/root`, `~/.local/share/Steam` without the symlink, Flatpak
  (`~/.var/app/com.valvesoftware.Steam/...`) and Snap. `launcher.rs:153`
  also hard-codes `STEAM_COMPAT_CLIENT_INSTALL_PATH` to `~/.steam/steam`.
  Use one ordered list (shared with the script's), deduplicated with
  `canonicalize`, and reuse the chosen root everywhere.
- **A failed exe detection saves `"<install>/game.exe"`, which doesn't
  exist.** `commands.rs:347`. The entry then fails only at launch.
  `import_custom_game` returns an error here instead. The heuristic is also
  weak: no folder skip list, and a 0.8 MB `oalinst.exe` in the root beats a
  40 MB `Bin/Game.exe`. Prefer the loader's dry-run `plan.exe` for Steam
  games, or return an error.
- **Question:** a clone copies only `pfx/`, keeping Proton's absolute symlinks
  into Steam's Proton install, and drops `version`, `config_info` and
  `tracked_files` (`steam_import.rs:217-239`). Does neutron re-link builtin
  DLLs in a prefix that has no `version` file? If not, cloned prefixes keep
  loading Steam's Proton DLLs.

### Runtime and container
- **Update detection never works.** `runtime.rs:185` (`current_build_id`).
  - It looks for a `build-id=` line, but Valve's `VERSIONS.txt` is a
    tab-separated table with no such line, so it always returns `""`.
  - Every Install or Update re-downloads, and update checks always say an
    update is available.
  - **Fix:** read the `.mythix-installed` marker, falling back to the
    `VERSIONS.txt` row for the codename (column 2).
- **Install always fails when `~/.cache` and `~/.local/share` are on
  different filesystems.** `runtime.rs:356, 378-384`. It extracts in the
  cache, then `rename`s into the data dir, which fails with EXDEV after the
  full download. Extract into a temp folder next to the target instead (umu
  does this).
- **The runtime swap isn't atomic.** `runtime.rs:378`. The old runtime is
  moved to `.old` (the result is ignored) before the new tree is checked, and
  it's never moved back if the second rename fails. Check the new tree, then
  swap with `renameat2(RENAME_EXCHANGE)`, or roll back on error.
- **No HTTP timeouts.** `runtime.rs:231, 422`. A stalled download or update
  check hangs forever. Add `connect_timeout`/`read_timeout` (or wrap
  `stream.next()` in `tokio::time::timeout`), and retry with `Range`.

### Gamepad and input
- **`activate_window` can freeze a pad's input.** `gamepad.rs:885`.
  - It runs on the pad's read thread, and `xdotool windowactivate --sync`
    waits about 15 s per match when activation is refused.
  - `search --name mythix` also matches terminals and editors with "mythix"
    in the title, and the KWin D-Bus method it calls doesn't exist.
  - **Fix:** activate on a detached thread, drop `--sync`, and match the
    launcher's own window (`xdotool search --pid <own pid>`).
- **Wheels and flight sticks pass the gamepad filter.** `gamepad.rs:355`. An
  axis resting at its end (pedals, throttles) then holds a direction forever.
  Require real gamepad buttons (`BTN_GAMEPAD` 0x130–0x13e), and treat each
  axis's initial value as its neutral point.
- **The Cyberpunk-style JSON patch can change an unrelated setting.**
  `input_config.rs:107`. The search for `"index"` runs to the end of the file,
  starting from an offset into the wrong string. Parse with `serde_json` and
  change only the `GamepadLayout` option.
- **`MYTHIX_DS4_GLYPHS=1` is set from the app id alone.** `launcher.rs:261`.
  It ignores the pad type and whether Wine can open the pad's hidraw node, so
  with an Xbox pad, or a Sony pad without access, input depends on neutron's
  fallback. Set it only for a PlayStation pad whose `/dev/hidrawN` passes
  `access(R_OK|W_OK)`.
- **`check_hidraw_access` says OK if any hidraw node looks readable.**
  `commands.rs:857`. A FIDO key or an RGB device can make it pass while the
  controller's own node isn't accessible. Check only controller nodes (by
  VID/PID), with `access()`.
- **The udev rules don't work over Bluetooth.** `commands.rs:881` and the
  rules file. `ATTRS{idVendor}` only exists on USB devices. Add
  `KERNELS=="*054C:0CE6*"`-style rules, as Steam's do.

---

## Smaller issues

### Launch, stop and tracking
- **Stop signals a PID that has already exited.** `commands.rs:158-181,
  249-257`. `LaunchResult.pid` is the `setsid --fork` parent, which exits at
  once. Once that PID is reused, Stop signals an unrelated process (and its
  group); a PID of 0 or 1 would hit everything. Kill by prefix, or keep a
  process you own (`pre_exec(libc::setsid)` instead of `--fork`).
- **Entries without `prefix_path` run in the default prefix but are never
  tracked or stoppable.** `launcher.rs:771`, `commands.rs:185`. Add an
  `effective_prefix()` helper, use it everywhere, and always emit
  `game:exited`.
- **The prefix path is spliced into a `bash -c` grep command.**
  `launcher.rs:782-786`, plus the kill sweep. A path containing `'` breaks
  tracking and Stop, and a crafted path runs shell code. Scan `/proc` in Rust
  and compare `WINEPREFIX=`/`STEAM_COMPAT_DATA_PATH=` exactly, or set a
  `MYTHIX_GAME_ID` and match on that.
- **The playtime clock starts too early.** `launcher.rs:763-777` starts it
  before 3 s + 5 s of sleeps, so `elapsed_secs > 5` can never filter out a
  failed start. Start it at the first poll that finds the prefix alive.
- **`MYTHIX_BLOCK_HIDRAW=1` can never take effect.** `launcher.rs:271` checks
  it before the global and per-game env are merged in. Also, an
  `LD_PRELOAD` override replaces the host value instead of adding to it.
- **Fixed, predictable `/tmp` paths** for the launch log and Proton crash
  reports (`commands.rs:88`, `launcher.rs:158`). Use `$XDG_STATE_HOME` and
  `$XDG_RUNTIME_DIR`, with mode 0600.
- `launch_game`, `dry_run_launch`, `scan_steam`, `find_exe`,
  `check_hidraw_access` and `install_udev_rules` are sync commands, so they
  block the UI thread. Make them `#[tauri::command(async)]` or use
  `spawn_blocking`.

### Import
- **Imports don't re-check the library after the long clone.**
  `commands.rs:386, 589`. Running Loader or a second Prefix meanwhile gives
  duplicate entries or overwrites a prefix that just appeared. Re-check under
  the library lock, and keep a per-appid in-flight set.
- **Clones are made before the library is known to load and save**, which can
  orphan multi-GB copies (`commands.rs:339`).
- **No check that Steam's prefix is in use before copying it**
  (`steam_import.rs:218`).
- **Duplicate appids across libraries:** the first library found wins. An
  empty `installdir` makes the install path `steamapps/common`
  (`steam_import.rs:128`). Rank duplicates the way the script does.
- **Steam imports ignore the default prefix root, tool and verb** from
  settings (`steam_import.rs:203`).
- **`SKIP_APPIDS` has wrong labels and gaps,** so Proton 9/10 and the
  BattlEye/EAC runtimes are offered as games (`steam_import.rs:39`). Skip any
  app with a `toolmanifest.vdf`.
- **Cover fetch saves any 200 response over 1000 bytes as `.jpg`,** and one
  body error ends the mirror fallback (`coverart.rs:46`).

### Runtime
- **Nothing stops two installs running at once,** or a launch during an
  install. They share one `.parts` file (`runtime.rs:220`). Take an flock for
  the whole install.
- **A resumed download is corrupted when the server ignores `Range`**
  (status 200). The three files also come from a moving `latest` alias
  (`runtime.rs:287`).
- **`fetch_text` ignores the HTTP status,** so an error page is taken as a
  build id (`runtime.rs:442`). Call `error_for_status()` and validate the id.
- **The bridge checks dependencies by soname only** (not symbol versions), and
  `tool_provided_names` isn't per-architecture (`runtime_bridge.rs:552,
  591`).
- **Atom mode ignores the Atom Proton's required runtime** once a container
  has already been chosen (`launcher.rs:319`).
- **The shim and bridge folders reach the container only through home
  sharing** (`launcher.rs:229`). Add them to `STEAM_COMPAT_MOUNTS`.
- **Download progress events flood the UI.** Send one only when the percent
  changes.

### Gamepad and input
- **Releases are lost after a joydev buffer overflow.** The `INIT` snapshot
  joydev sends is ignored, so actions stay held (`gamepad.rs:723`).
- **Press/release events are emitted outside the `HOLDS` lock,** so a release
  can arrive before its press (`gamepad.rs:479`).
- **The "current" controller depends on discovery order.** Steam's virtual
  pad or a third-party PS pad can set the wrong type (`gamepad.rs:536`).
  Prefer physical devices and VID/PID matches.
- **`window_show` doesn't clear `WINDOW_HIDDEN`** (`commands.rs:837`).
- **A `/dev/input/js*` node that can't be opened is retried and logged every
  3 s, forever** (`gamepad.rs:629`).
- **`SDL_GAMECONTROLLERTYPE` is set to a bare type name, which SDL ignores**
  (`gamepad.rs:127`). SDL wants `0xVID/0xPID=Type`.
- **Glyph patching** (`input_config.rs`):
  - it overwrites the player's own in-game choice on every launch and never
    switches back (`:51`)
  - Switch pads get index 4, outside the documented range for Cyberpunk and
    Witcher 3 (`:76`)
  - the RDR2 patch can hit the wrong XML element (`:173`)
  - the Witcher 3 patch matches the key as a substring (`:253`)
  - files are rewritten in place with no backup (`:144`)
- **`install_udev_rules` blocks the UI while pkexec runs** and retriggers
  every device on the system (`commands.rs:880`).

### Security and state
- **Question: Tauri plugins.** The shell, fs and process plugins are
  registered but unused from Rust, and every custom command can be called
  from the webview (`lib.rs:25`). Worth checking the capabilities file and
  CSP: drop what isn't used, and narrow the fs/asset scope to the covers
  folder.
- **Question: whole-object updates.** `update_game_config`/`update_game_meta`
  replace whole objects, so a stale frontend copy can undo background changes
  such as a new loader stub or a cloned prefix (`game_library.rs:224`).
  Field-level patches or a revision number would prevent that.
- **`library.json`'s `version` is never checked,** so an older build silently
  drops fields a newer one added (`game_library.rs:118`). `#[serde(flatten)]
  extra` would round-trip unknown fields.

---

## Checked and not a problem

These were reported and refuted on verification:
- **"Exit detection never ends while Steam runs in the prefix"**,
  **"`waitforexitandrun` waits forever for Steam"**, **"Stop kills the Steam
  client"** and **"which Steam does the loader talk to?"**: all assumed a
  Windows Steam inside the prefix. With native Steam, the `/proc` scan ends a
  few seconds after the game, and Stop only hits the game's own prefix.
- **"`dry_run_launch` has side effects":** true, but they're idempotent, and
  the next real launch does the same thing (glyph writes for four app ids,
  the bridge prepare).
- **"`install_loader` can hand a half-written stub to a concurrent import":**
  it only rewrites on the first call after an upgrade, and each call finishes
  installing before it runs the script.
- **"`clear_cover` path traversal":** only callers that can already run any
  command could pass such an id.
- **Smaller VDF edge cases** (legacy format, `[$WIN32]` conditionals, deep
  nesting) and **literal `~` fallbacks**: real in the code, but they can't
  happen with the inputs it actually gets. The BOM part matters through
  `compatibilitytool.vdf`; it's covered above.
- **"The bridge needs neutron to keep `LD_LIBRARY_PATH`":** neutron does keep
  it, as its source shows.
