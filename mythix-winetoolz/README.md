# mythix-winetoolz

A Zenity-menu Wine/Proton prefix toolkit — point-and-click control over the
fiddly parts of running Windows software on Linux. v2.1.

Run it and a terminal banner appears (say hi to the wolf) while the GUI menus
take over: categories on top, looping module submenus inside, Back to go up a
level.

## Requirements

- `bash`, `zenity`
- A Wine or Proton/Neutron build (managed per-prefix — you can install custom
  builds from inside the toolkit)
- Individual modules may need `wget`/`curl`, `tar`, `wine`, `winetricks`-style
  downloads — the About module has a dependency checker

## Usage

```sh
./wine_toolz.sh
```

Installed system-wide via `make install`-style layout, it also finds its
modules under `<prefix>/lib/mythix-winetoolz/modules/`.

## What's inside

| Category | Modules |
|----------|---------|
| 🎮 Graphics | Install DXVK, VKD3D-Proton, DXVK-NVAPI |
| 📦 Runtimes | .NET / XNA / XACT / VC++ / DirectPlay / OpenAL installer; DirectX Jun 2010 offline package |
| 🍷 Wine | Wine Tools (uninstaller, control, taskmgr, regedit, explorer, wineboot), DLL Override Manager, Wine Install Manager |
| 📁 Prefix | Prefix Creator, Winecfg, Prefix Manager (backup/restore/regedit/kill), Prefix Diagnostics (arch, Windows version, DXVK status, disk usage) |
| 🚀 Launch | App Launcher (saved shortcuts with env profiles), Env Flags, Log Viewer (capture Wine stderr) |
| 🔧 Components | DLL Installer (d3dx9/10/11, d3dcompiler, xinput, msxml, physx…), System File Installer (extract DLLs from any archive) |
| ℹ System | About / dependency checker / config paths |

## Layout

```
mythix-winetoolz/
  wine_toolz.sh              entry point: category menu + module dispatcher
  modules/
    winetoolz-lib.sh         shared library: config, prefix/wine pickers,
                             logging, zenity helpers, terminal runner
    shared_lib/*.sh          the 19 feature modules listed above
```

Config lives at `~/.config/mythix-build/winetoolz.cfg` (created on first run;
see `wt_load_config` in `winetoolz-lib.sh`).
