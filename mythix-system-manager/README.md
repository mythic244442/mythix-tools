# mythix-system-manager

A GTK3 desktop system manager for **Linux Mint** and **Debian** — updates,
packages, kernels, security, and logs in one window. v1.2.

## Requirements

- Python 3 with GTK bindings: `python3-gi`, `gir1.2-gtk-3.0`, `python3-apt`
- Optional: `gir1.2-ayatanaappindicator3-0.1` (tray indicator), `flatpak`,
  `timeshift` (snapshot-before-update), `notify-send`

## Usage

```sh
python3 mythix-system-manager.py
```

`Ctrl+K` opens the command palette — every page is reachable from there.

## Pages

| Group | Pages |
|-------|-------|
| **HOME** | Overview — stat cards, security score, live CPU/RAM sparkline |
| **MAINTAIN** | Updates (apt + flatpak), Packages (incl. `apt-mark hold`), Cleanup, History |
| **SYSTEM** | Kernels, Repos, Startup, Upgrade |
| **PROTECT** | Security, Antivirus |
| **OBSERVE** | Logs, System |

## Behavior & data

- Background update checks every `check_interval_min` minutes (default 60),
  with desktop notifications (optionally security-only).
- Optional Timeshift snapshot before installing updates.
- Settings: `~/.local/share/mythix-system-manager/settings.json`
  (check interval, flatpak toggle, accent color — applied live, notifications,
  history retention).
- History: `~/.local/share/mythix-system-manager/history.json` (install events,
  capped by `history_keep`, default 200).
- Config backups before writes land in `/var/backups/mythix-system-manager/`.

All config writes are atomic and backed up first (`write_text_with_backup`),
so a bad edit never leaves a half-written system file.

## Layout

```
mythix-system-manager/
  mythix-system-manager.py   thin launcher (re-execs via pkexec if not root)
  system_manager/
    core.py                  constants, settings, atomic-write helpers,
                             distro detection, Mint/Debian release maps
    app.py                   AppBase (window skeleton, CSS, tray, palette
                             wiring) + SystemManager composing all mixins
    pages/
      palette.py             Ctrl+K command palette
      overview.py            HOME dashboard (stat cards, sparkline)
      updates.py             apt + flatpak updates
      packages.py            installed package browser, apt-mark hold
      cleanup.py             disk cleanup
      history.py             install history
      kernels.py             kernel manager
      repos.py               APT repository manager
      startup.py             startup entry manager
      upgrade.py             distro upgrade (mintupgrade / Debian codename swap)
      security.py            security toggles + score
      antivirus.py           ClamAV scanning
      logs.py                journald viewer
      sysinfo.py             system info with live refresh
```

Each page is a mixin class; `SystemManager` in `app.py` composes them all over
`AppBase`. Shared imports and constants come from `core.py`.
