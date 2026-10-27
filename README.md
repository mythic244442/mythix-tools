# mythix-winetoolz

Standalone tool that powers your gaming stack on Linux — the toolkit that is made for work with Wine and Wine related customization/troubleshooting/debugging/etc.

A Zenity-menu Wine/Proton prefix toolkit — point-and-click control over the
fiddly parts of running Windows software on Linux. v3.0.

Run it and the Mythix banner appears in the terminal while the GUI menus take
over: categories on top, looping module submenus inside, Back to go up a
level.

## Requirements

- `bash` 4.4+, `zenity` (3.x or 4.x)
- A Wine or Proton/Neutron build — any you already have is found (custom
  builds, Steam's Proton and compatibility tools, Lutris, Heroic, Bottles,
  `/opt/wine-*`, system Wine), and you can download GE-Proton or Kron4ek
  builds from inside the toolkit
- `curl` (or `wget`), `tar`, `xz` for downloads; `cabextract` for the
  DirectX-based installers; optional: `7z`, `unzip`, `zstd`, `python3`, `jq`,
  `icoutils`, a clipboard tool (`wl-copy` / `xclip` / `xsel`)

The About module has a dependency checker that shows the install command for
your distro.

## Usage

```sh
./wine_toolz.sh                  # the menus
./wine_toolz.sh dxvk             # run one module directly
./wine_toolz.sh --list           # module names for the above
./wine_toolz.sh --version
```

Installed system-wide via `make install`-style layout, it also finds its
modules under `<prefix>/lib/mythix-winetoolz/modules/`.

## What's inside

| Category | Modules |
|----------|---------|
| 🎮 Graphics | Install / uninstall DXVK, VKD3D-Proton, DXVK-NVAPI (Wine's own DLLs are backed up and put back on uninstall) |
| 📦 Runtimes | .NET / XNA / XACT / VC++ / DirectPlay / OpenAL installer; Visual C++ 2015+ quick install; DirectX Jun 2010 offline package |
| 🍷 Wine | Wine Tools (uninstaller, control, taskmgr, regedit, explorer, cmd, drive C:, wineboot, stop Wine), DLL Override Manager (all programs or one `.exe`), Wine Install Manager, Runtime Downloads (GE-Proton, Kron4ek Wine) |
| 📁 Prefix | Prefix Creator, Winecfg, Prefix Manager (backup/restore/regedit/kill/build manager), Prefix Diagnostics (arch, Windows version, DXVK status, disk usage) |
| 🚀 Launch | App Launcher (saved shortcuts with env profiles), Env Flags, Log Viewer (capture Wine stderr) |
| 🔧 Components | DLL Installer (d3dx9/10/11, d3dcompiler, xinput, msxml, physx…), System File Installer (install the DLLs from any archive) |
| ℹ System | About / dependency checker / config paths |

Prefixes are picked from one list: your configured folders, Mythix Launcher
games, Steam (Proton) games, Bottles and Heroic, with the last one you used on
top.

## Safety

- **Downloads are verified.** Every redistributable comes from the catalog in
  `modules/downloads.tsv` (key, sha256, file name, URL, mirrors) and is
  checked before use; GitHub releases are checked against the digest GitHub
  publishes for them. Only `https` is used. Files are cached in
  `~/.cache/winetoolz/downloads`.
- **Nothing is deleted before the last "yes".** Recreating or deleting a
  prefix, restoring a backup and replacing a Wine build all wait for the
  final confirmation; a restored backup or a new build replaces the old copy
  only once it has unpacked and checked out. Deletes refuse your home folder,
  system folders, symlinks and anything that doesn't look like what it should
  be (a prefix, a Wine build).
- **Archives can't write outside their folder** (no absolute or `../` paths).
- **Proton/Neutron wrappers are never run as if they were Wine** — the tools
  use the build's own `wine`, so Steam's prefix layout is left alone.
- **Config and shortcut files are read as data**, never run as shell code.
  Env profiles are shell (`export NAME="value"`) and are syntax-checked before
  they are used.

## Files

| What | Where |
|------|-------|
| Config | `~/.config/mythix-build/winetoolz.cfg` — `WT_PREFIX_PATHS` (folders searched for prefixes, `:`-separated), `WT_BACKUP_DIR`, plus the last Wine build and prefix you picked |
| Shortcuts, env profiles, icons | `~/.config/winetoolz/{launchers,env_profiles,icons}/` |
| DXVK / VKD3D-Proton / NVAPI releases | `~/winetoolz/dxvk-vkd3d_proton-files/` |
| Downloaded Wine/Proton builds | `~/wine-custom/buildz/` (Runtime Downloads), `~/.local/share/mythix-wine-installs/` (Wine Install Manager) |
| Prefix backups | `~/.local/share/mythix-winetoolz/backups/` (`WT_BACKUP_DIR`) |
| Logs | `~/winetoolz/logs/` |

Environment overrides: `WT_TERMINAL` (terminal to open, e.g. `kitty`),
`GITHUB_TOKEN` (higher GitHub API rate limit), `WT_DOWNLOADS_LIST` (another
download catalog).

## Layout

```
mythix-winetoolz/
  wine_toolz.sh              entry point: category menu, module dispatcher,
                             command line
  modules/
    winetoolz-lib.sh         shared library: config, Wine/prefix discovery and
                             pickers, verified downloads, archive extraction,
                             DLL install/backup helpers, zenity helpers,
                             terminal runner
    downloads.tsv            the download catalog (pinned sha256 sums)
    shared_lib/*.sh          the 20 feature modules listed above
  tests/
    run_all.sh               all suites
    test_lib.sh              library tests
    test_modules.sh          graphics / installer / prefix module flows
    test_tools.sh            tools, launcher, downloads, menu and CLI
    kit/                     mock zenity + terminal, fake Wine, CAB writer
```

## Tests

```sh
bash tests/run_all.sh            # or one suite, optionally with a name filter:
bash tests/test_tools.sh launcher
```

The modules run exactly as the menu runs them, with scripted dialog answers,
a fake Wine that records how it was called, and fake download servers — no
network, no display, nothing outside a temporary home. To also run the
real-Wine tests, point them at prefixes to copy (never modified):
`WT_TEST_REAL_PREFIX64=/path/to/prefix` and/or `WT_TEST_REAL_PREFIX32=...`.

## License

GPL-2.0 — see [LICENSE](LICENSE).

Built by Mythix with steel, grit, and hard work beyond measure
