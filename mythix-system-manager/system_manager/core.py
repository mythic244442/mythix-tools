#!/usr/bin/env python3
"""
Mythix System Manager — GTK3 system manager for Linux Mint and Debian.
v1.2: Overview dashboard + command palette.
  HOME:     Overview (stat cards, security score, live CPU/RAM sparkline)
  MAINTAIN: Updates (apt + flatpak) | Packages (incl. apt-mark hold) | Cleanup | History
  SYSTEM:   Kernels | Repos | Startup | Upgrade
  PROTECT:  Security | Antivirus
  OBSERVE:  Logs | System
Ctrl+K opens the command palette. Settings: check interval, Timeshift snapshot,
flatpak toggle, accent color (live), notifications, history retention.
"""

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GLib", "2.0")
try:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3
    HAS_APPINDICATOR = True
except (ValueError, ImportError):
    HAS_APPINDICATOR = False

from gi.repository import Gtk, GLib, Gdk, Pango
import subprocess, threading, os, sys, apt, re, json, glob, platform, time, shutil, tempfile
from datetime import datetime
from pathlib import Path

APP_NAME    = "Mythix System Manager"
APP_VERSION = "1.2.0"
APP_ID      = "com.mythix.system-manager"
DATA_DIR    = Path.home() / ".local" / "share" / "mythix-system-manager"
HISTORY_FILE = DATA_DIR / "history.json"
SETTINGS_FILE = DATA_DIR / "settings.json"

DEFAULT_SETTINGS = {
    "check_interval_min": 60,         # background update-check interval
    "snapshot_before_install": False, # Timeshift snapshot before installing updates
    "include_flatpak_updates": True,  # show flatpak updates in the Updates page
    "accent": "Mythix Cyan",          # UI accent color (see SystemManager.ACCENTS)
    "notify_updates": True,           # desktop notification when updates appear
    "notify_security_only": False,    # …but only when security updates are among them
    "history_keep": 200,              # install events kept in history.json
}

def load_settings():
    s = dict(DEFAULT_SETTINGS)
    try:
        if SETTINGS_FILE.exists():
            s.update({k: v for k, v in json.loads(SETTINGS_FILE.read_text()).items()
                      if k in DEFAULT_SETTINGS})
    except Exception:
        pass
    return s

def save_settings(s):
    try:
        atomic_write_text(SETTINGS_FILE, json.dumps(s, indent=2))
    except Exception:
        pass
BACKUP_ROOT = Path("/var/backups/mythix-system-manager")
# Migrate old data dir if it exists
_OLD_DATA_DIR = Path.home() / ".local" / "share" / "looni-system-manager"
if _OLD_DATA_DIR.exists() and not DATA_DIR.exists():
    _OLD_DATA_DIR.rename(DATA_DIR)
DATA_DIR.mkdir(parents=True, exist_ok=True)

# ── Column constants ───────────────────────────────────────
# Updates
COL_SELECTED=0; COL_PACKAGE=1; COL_OLD_VER=2; COL_NEW_VER=3
COL_SIZE=4; COL_ORIGIN=5; COL_DESC=6; COL_RAW_SIZE=7; COL_IS_SECURITY=8
# Kernels
COL_K_RUNNING=0; COL_K_PACKAGE=1; COL_K_VERSION=2; COL_K_STATUS=3; COL_K_SIZE=4; COL_K_RAW_SIZE=5
# Repos
COL_R_ENABLED=0; COL_R_TYPE=1; COL_R_URL=2; COL_R_SUITE=3; COL_R_COMPS=4; COL_R_FILE=5; COL_R_LINE_NUM=6
# Packages
COL_P_MARK=0; COL_P_NAME=1; COL_P_INST=2; COL_P_AVAIL=3; COL_P_DESC=4; COL_P_SIZE=5; COL_P_RAW=6; COL_P_STATUS=7
# Antivirus
COL_AV_FILE=0; COL_AV_THREAT=1
# Startup
COL_ST_ENABLED=0; COL_ST_NAME=1; COL_ST_TYPE=2; COL_ST_DESC=3; COL_ST_FILE=4


def human_size(n):
    for u in ("B","KB","MB","GB"):
        if abs(n) < 1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"


def atomic_write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except Exception:
            pass


def safe_expand_path(path):
    return Path(path).expanduser()


def make_backup(path, label="config"):
    src = Path(path)
    if not src.exists():
        return None
    BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest_dir = BACKUP_ROOT / stamp
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{src.name}.{label}"
    shutil.copy2(src, dest)
    return dest


def write_text_with_backup(path, text, label="config"):
    backup = make_backup(path, label=label)
    atomic_write_text(path, text)
    return backup


def remove_file_with_backup(path, label="config"):
    backup = make_backup(path, label=label)
    Path(path).unlink(missing_ok=True)
    return backup


# Debian stable release progression. Used to map current codename → next
# stable codename for the distro-upgrade tab on Debian systems.
DEBIAN_NEXT_CODENAME = {
    "buster":   "bullseye",
    "bullseye": "bookworm",
    "bookworm": "trixie",
    "trixie":   "forky",
}

# Linux Mint release progression (version → codename), in release order.
# Mint point releases are sequential; mintupgrade itself has shipped stale
# metadata (offering Wilma to Zena users), so we keep our own map and treat
# mintupgrade's output as advisory only.
MINT_RELEASES = [
    ("21",    "vanessa"),
    ("21.1",  "vera"),
    ("21.2",  "victoria"),
    ("21.3",  "virginia"),
    ("22",    "wilma"),
    ("22.1",  "xia"),
    ("22.2",  "zara"),
    ("22.3",  "zena"),
]
MINT_LATEST = MINT_RELEASES[-1]


def mint_release_index(version):
    """Index of version in MINT_RELEASES, or None if unknown."""
    for i, (v, _cn) in enumerate(MINT_RELEASES):
        if v == version:
            return i
    return None


def detect_distro():
    """Identify the running distribution.

    Returns a dict with keys: id, version, codename, pretty.
    id is normalised to one of: 'linuxmint', 'debian', 'ubuntu', or the raw
    ID= value from /etc/os-release (lower-case) if it's something else.
    """
    info = {"id": "unknown", "version": "", "codename": "", "pretty": ""}
    try:
        mint_info = Path("/etc/linuxmint/info")
        if mint_info.exists():
            info["id"] = "linuxmint"
            for line in mint_info.read_text().splitlines():
                if line.startswith("RELEASE="):
                    info["version"] = line.split("=", 1)[1].strip()
                elif line.startswith("CODENAME="):
                    info["codename"] = line.split("=", 1)[1].strip()
            cn = f' "{info["codename"].capitalize()}"' if info["codename"] else ""
            info["pretty"] = f"Linux Mint {info['version']}{cn}".strip()
            return info

        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" not in line: continue
            k, v = line.split("=", 1)
            v = v.strip().strip('"')
            if   k == "ID":               info["id"] = v.lower()
            elif k == "VERSION_ID":       info["version"] = v
            elif k == "VERSION_CODENAME": info["codename"] = v
            elif k == "PRETTY_NAME":      info["pretty"] = v
        if not info["pretty"]:
            info["pretty"] = f"{info['id'].capitalize()} {info['version']}".strip()
    except Exception:
        pass
    return info


SECURITY_FEATURES = [
    {"key":"ufw",                 "title":"Firewall (UFW)",               "desc":"Block unauthorized incoming connections",                           "icon":"security-high-symbolic"},
    {"key":"auto_security_updates","title":"Automatic Security Updates",   "desc":"Install critical patches via unattended-upgrades",                 "icon":"system-software-update-symbolic"},
    {"key":"fail2ban",            "title":"Fail2ban",                      "desc":"Ban IPs showing brute-force / repeated auth failures",              "icon":"changes-prevent-symbolic"},
    {"key":"ssh_root",            "title":"Block Root SSH Login",          "desc":"Prevent direct root login over SSH",                               "icon":"dialog-password-symbolic"},
    {"key":"ssh_password",        "title":"SSH Key-Only Auth",             "desc":"Disable SSH password login — require keys",                        "icon":"dialog-password-symbolic"},
    {"key":"usb_storage",         "title":"Block USB Storage",             "desc":"Prevent USB drive auto-mount — stops exfiltration",                "icon":"drive-removable-media-symbolic"},
    {"key":"core_dumps",          "title":"Disable Core Dumps",            "desc":"Prevent memory dumps on crash",                                    "icon":"document-properties-symbolic"},
    {"key":"sysrq",               "title":"Restrict Magic SysRq",          "desc":"Limit kernel debug key combos",                                    "icon":"preferences-system-symbolic"},
]


