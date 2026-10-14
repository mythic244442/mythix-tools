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


class SystemManager(Gtk.Window):
    def __init__(self):
        super().__init__(title=APP_NAME)
        self.set_default_size(1060, 700)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name("preferences-system")

        self._updates=[]; self._kernels=[]; self._repos=[]; self._pkgs=[]
        self._busy=False; self._last_update_count=-1
        self._security_widgets={}; self._security_updating=False
        self._kernels_loaded=False; self._repos_loaded=False
        self._pkgs_loaded=False; self._startup_loaded=False
        self._sysinfo_timer=None; self._pkg_search_pending=None
        self._settings=load_settings()
        self._bg_timer=None

        self._apply_css()
        self._build_ui()
        self._init_tray()
        self._bind_keys()
        GLib.idle_add(self._on_refresh)
        self._arm_background_timer()

    def _arm_background_timer(self):
        if self._bg_timer:
            GLib.source_remove(self._bg_timer); self._bg_timer=None
        mins=max(5,int(self._settings.get("check_interval_min",60)))
        self._bg_timer=GLib.timeout_add_seconds(mins*60, self._background_check)

    def _bind_keys(self):
        accel = Gtk.AccelGroup()
        self.add_accel_group(accel)
        accel.connect(Gdk.keyval_from_name("r"), Gdk.ModifierType.CONTROL_MASK, 0,
                      lambda *_: self._on_refresh_dispatch())
        accel.connect(Gdk.keyval_from_name("q"), Gdk.ModifierType.CONTROL_MASK, 0,
                      lambda *_: Gtk.main_quit())
        accel.connect(Gdk.keyval_from_name("F5"), 0, 0,
                      lambda *_: self._on_refresh_dispatch())
        accel.connect(Gdk.keyval_from_name("k"), Gdk.ModifierType.CONTROL_MASK, 0,
                      lambda *_: self._show_palette())

    def _show_about(self, *_):
        d = Gtk.AboutDialog(transient_for=self)
        d.set_program_name(APP_NAME)
        d.set_version(APP_VERSION)
        d.set_comments("System manager for Linux Mint and Debian-based distributions")
        d.set_copyright("© 2026 Mythix")
        d.set_license_type(Gtk.License.GPL_3_0)
        d.set_logo_icon_name("preferences-system")
        d.run(); d.destroy()

    def _show_settings(self, *_):
        d = Gtk.Dialog(title="Settings", transient_for=self, flags=0)
        d.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Save", Gtk.ResponseType.OK)
        grid = Gtk.Grid(row_spacing=12, column_spacing=18,
                        margin_top=16, margin_bottom=16, margin_start=16, margin_end=16)

        def _row(y, title, desc, widget):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            t = Gtk.Label(label=title, xalign=0); t.get_style_context().add_class("security-title")
            s = Gtk.Label(label=desc,  xalign=0); s.get_style_context().add_class("security-desc")
            box.pack_start(t, False, False, 0); box.pack_start(s, False, False, 0)
            grid.attach(box, 0, y, 1, 1)
            widget.set_halign(Gtk.Align.END); widget.set_valign(Gtk.Align.CENTER)
            grid.attach(widget, 1, y, 1, 1)

        spin = Gtk.SpinButton.new_with_range(5, 1440, 5)
        spin.set_value(self._settings.get("check_interval_min", 60))
        _row(0, "Background check interval", "Minutes between update checks", spin)

        sw_fp = Gtk.Switch(); sw_fp.set_active(self._settings.get("include_flatpak_updates", True))
        _row(1, "Include Flatpak updates", "Show flatpak app updates on the Updates page", sw_fp)

        sw_ts = Gtk.Switch(); sw_ts.set_active(self._settings.get("snapshot_before_install", False))
        has_ts = shutil.which("timeshift") is not None
        sw_ts.set_sensitive(has_ts)
        _row(2, "Snapshot before install",
             "Create a Timeshift snapshot before installing updates" if has_ts
             else "Timeshift is not installed", sw_ts)

        combo = Gtk.ComboBoxText()
        for name in self.ACCENTS: combo.append_text(name)
        names = list(self.ACCENTS)
        cur = self._settings.get("accent", "Mythix Cyan")
        combo.set_active(names.index(cur) if cur in names else 0)
        _row(3, "Accent color", "Applied instantly — no restart needed", combo)

        sw_nt = Gtk.Switch(); sw_nt.set_active(self._settings.get("notify_updates", True))
        _row(4, "Update notifications", "Desktop notification when new updates appear", sw_nt)

        sw_ns = Gtk.Switch(); sw_ns.set_active(self._settings.get("notify_security_only", False))
        _row(5, "Security updates only", "Only notify when security updates are available", sw_ns)
        sw_ns.set_sensitive(sw_nt.get_active())
        sw_nt.connect("state-set", lambda _w, st: (sw_ns.set_sensitive(st), False)[1])

        spin_h = Gtk.SpinButton.new_with_range(50, 1000, 50)
        spin_h.set_value(self._settings.get("history_keep", 200))
        _row(6, "History retention", "Install events kept on the History page", spin_h)

        d.get_content_area().add(grid); d.show_all()
        if d.run() == Gtk.ResponseType.OK:
            self._settings["check_interval_min"]      = int(spin.get_value())
            self._settings["include_flatpak_updates"] = sw_fp.get_active()
            self._settings["snapshot_before_install"] = sw_ts.get_active()
            self._settings["notify_updates"]          = sw_nt.get_active()
            self._settings["notify_security_only"]    = sw_ns.get_active()
            self._settings["history_keep"]            = int(spin_h.get_value())
            new_accent = combo.get_active_text() or "Mythix Cyan"
            accent_changed = new_accent != self._settings.get("accent")
            self._settings["accent"] = new_accent
            save_settings(self._settings)
            self._arm_background_timer()
            if accent_changed: self._apply_css()
        d.destroy()

    # ────────────────────────────────────────────────────────
    # COMMAND PALETTE (Ctrl+K)
    # ────────────────────────────────────────────────────────
    def _show_palette(self, *_):
        d = Gtk.Dialog(title="", transient_for=self, flags=Gtk.DialogFlags.MODAL)
        d.set_decorated(False)
        d.set_default_size(460, 380)
        d.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
        box = d.get_content_area()
        entry = Gtk.SearchEntry()
        entry.set_placeholder_text("Type a command…")
        box.pack_start(entry, False, False, 0)
        sw = Gtk.ScrolledWindow(); sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        lb = Gtk.ListBox(); lb.get_style_context().add_class("sidebar")
        sw.add(lb); box.pack_start(sw, True, True, 0)

        actions = [(f"Go to {label}",
                    (lambda p=pid: self.sidebar.select_row(self._nav_rows[p])), icon)
                   for _sec, pages in self.PAGES for pid, label, icon in pages]
        actions += [
            ("Refresh current page",      self._on_refresh_dispatch, "view-refresh-symbolic"),
            ("Check for updates",         self._on_refresh,          "software-update-available-symbolic"),
            ("Install selected updates",  self._on_install,          "system-software-install-symbolic"),
            ("Fix broken dependencies",   self._on_fix_broken,       "dialog-warning-symbolic"),
            ("Settings",                  self._show_settings,       "preferences-system-symbolic"),
            ("Quit",                      lambda *_: Gtk.main_quit(),"application-exit-symbolic"),
        ]
        rows = []
        for label, cb, icon in actions:
            row = Gtk.ListBoxRow(); row.cb = cb; row.txt = label.lower()
            hb = Gtk.Box(spacing=9)
            hb.set_margin_top(3); hb.set_margin_bottom(3)
            hb.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU), False, False, 8)
            hb.pack_start(Gtk.Label(label=label, xalign=0), True, True, 0)
            row.add(hb); lb.add(row); rows.append(row)

        def refilter(*_):
            t = entry.get_text().lower().strip()
            first = None
            for r in rows:
                vis = all(word in r.txt for word in t.split()) if t else True
                r.set_visible(vis)
                if vis and first is None: first = r
            lb.select_row(first)

        def run_row(row):
            d.destroy()
            if row is not None: GLib.idle_add(row.cb)

        entry.connect("search-changed", refilter)
        entry.connect("activate", lambda *_: run_row(lb.get_selected_row()))
        lb.connect("row-activated", lambda _l, r: run_row(r))
        d.connect("key-press-event",
                  lambda _w, e: (d.destroy() or True) if e.keyval == Gdk.KEY_Escape else False)
        d.show_all(); refilter(); entry.grab_focus()

    # ────────────────────────────────────────────────────────
    # CSS
    # ────────────────────────────────────────────────────────
    ACCENTS = {
        "Mythix Cyan": "#4dd0e1",
        "Amethyst":    "#b39ddb",
        "Viridian":    "#6fe3a5",
        "Ember":       "#ffab70",
        "Rose":        "#ff8fab",
    }

    def _accent(self):
        return self.ACCENTS.get(self._settings.get("accent", "Mythix Cyan"), "#4dd0e1")

    def _apply_css(self):
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
        a  = self._accent()
        ar = ",".join(str(int(a[i:i+2], 16)) for i in (1, 3, 5))
        css_t = """
        /* -- Mythix theme ---------------------------------- */
        window { background-color: #12121a; }
        headerbar {
            background: linear-gradient(180deg, #1c1c2a, #16161f);
            border-bottom: 1px solid #2a2a3d;
            min-height: 44px;
        }
        headerbar .title    { font-weight: bold; color: #e6e3f0; }
        headerbar .subtitle { font-size: 11px; color: #8f8fa8; }

        /* Sidebar - the signature: accent rail + live badge */
        .sidebar {
            background-color: #16161f;
            border-right: 1px solid #2a2a3d;
        }
        .sidebar row {
            padding: 7px 12px 7px 9px;
            border-left: 3px solid transparent;
            color: #b8b6c8;
        }
        .sidebar row:hover {
            background-color: rgba(179,157,219,0.06);
            color: #e6e3f0;
        }
        .sidebar row:selected {
            background: linear-gradient(90deg, rgba(@AR@,0.14), rgba(@AR@,0.02));
            border-left: 3px solid @A@;
            color: @A@;
        }
        .sidebar row:selected label { color: #e6e3f0; }
        .sidebar row:selected .nav-icon { color: @A@; }
        .nav-label { font-size: 13px; }
        .nav-section {
            font-size: 10px; font-weight: bold; letter-spacing: 2px;
            color: #5c5c78; padding: 12px 12px 3px 12px;
        }
        .nav-badge {
            background-color: #b39ddb; color: #12121a;
            border-radius: 9px; padding: 1px 7px;
            font-size: 10px; font-weight: bold;
        }
        .nav-badge-sec { background-color: #ef5350; color: #fff; }

        /* Content */
        .page-pad { padding: 4px; }
        .toolbar-btn { padding: 4px 10px; border-radius: 6px; }
        .tab-action-bar {
            padding: 6px 8px;
            background-color: #1a1a26;
            border-bottom: 1px solid #2a2a3d;
        }
        .count-label  { font-size:13px; font-weight:bold; color:#b39ddb; }
        .section-label{ font-weight:bold; font-size:13px; color:@A@; }
        .log-view {
            font-family: monospace; font-size: 11px;
            background-color: #0e0e15; color: #c9c6da;
        }
        .log-view text { background-color: #0e0e15; color: #c9c6da; }
        treeview { background-color: #1a1a26; }
        treeview:selected { background-color: rgba(@AR@,0.18); }
        treeview header button {
            background: #1c1c2a; border-bottom: 1px solid #2a2a3d;
            color: #8f8fa8; font-size: 11px; font-weight: bold;
        }
        statusbar, .status-bar { background-color: #16161f; }
        progressbar progress { background-color: @A@; }

        /* Overview dashboard */
        .dash-card {
            background-color: #1a1a26; background-image: none;
            box-shadow: none; text-shadow: none;
            border: 1px solid #262636; border-radius: 10px;
            padding: 14px 16px; margin: 6px;
        }
        .dash-card:hover { border-color: @A@; background-color: #1d1d2b; }
        .dash-eyebrow { font-size: 10px; font-weight: bold; letter-spacing: 2px; color: #5c5c78; }
        .dash-value   { font-size: 25px; font-weight: bold; color: #e6e3f0; }
        .dash-sub     { font-size: 11px; color: #8f8fa8; }
        .dash-warn .dash-value { color: #ffb74d; }
        .dash-bad  .dash-value { color: #ef5350; }
        .spark-frame {
            background-color: #14141d;
            border: 1px solid #262636; border-radius: 10px; margin: 6px;
        }

        /* Security cards */
        .security-row {
            padding: 10px 12px; margin: 3px 6px;
            background-color: #1a1a26;
            border: 1px solid #262636; border-radius: 8px;
        }
        .security-row:hover { border-color: #3a3a52; background-color: #1d1d2b; }
        .security-title { font-weight:bold; font-size:13px; color:#e6e3f0; }
        .security-desc  { font-size:11px; color:#8f8fa8; }

        /* Status pills */
        .status-active, .status-inactive, .status-notinstalled, .status-unknown {
            font-size: 11px; font-weight: bold;
            border-radius: 10px; padding: 2px 9px;
        }
        .status-active      { color:@A@; background-color: rgba(@AR@,0.12); }
        .status-inactive    { color:#ef5350; background-color: rgba(239,83,80,0.12); }
        .status-notinstalled{ color:#757575; background-color: rgba(117,117,117,0.10); font-style: italic; }
        .status-unknown     { color:#ffb74d; background-color: rgba(255,183,77,0.12); }

        .kernel-running  { color:@A@; font-weight:bold; }
        .kernel-installed{ color:#b39ddb; }
        .repo-disabled   { color:#666680; font-style:italic; }
        .btn-warn  { color:#ffb74d; }
        .btn-danger{ color:#ef5350; }
        .sysinfo-val  { font-size:13px; font-weight:bold; color:#e0d7f5; }
        .sysinfo-key  { font-size:12px; color:#9e9eb8; }
        .cleanup-size { font-size:12px; color:#b39ddb; font-weight:bold; }
        .pkg-installed { color:#b39ddb; }
        .pkg-upgradable{ color:@A@; }
        .pkg-available { color:#9e9eb8; }
        """
        css = css_t.replace("@A@", a).replace("@AR@", ar).encode("utf-8")
        if getattr(self, "_css_provider", None):
            Gtk.StyleContext.remove_provider_for_screen(Gdk.Screen.get_default(), self._css_provider)
        self._css_provider = Gtk.CssProvider()
        self._css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self._css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ────────────────────────────────────────────────────────
    # UI SKELETON
    # ────────────────────────────────────────────────────────
    # (section, [(page_id, label, icon), …]) — sidebar structure
    PAGES = [
        ("HOME", [
            ("overview", "Overview", "go-home-symbolic"),
        ]),
        ("MAINTAIN", [
            ("updates",  "Updates",  "software-update-available-symbolic"),
            ("packages", "Packages", "package-x-generic-symbolic"),
            ("cleanup",  "Cleanup",  "user-trash-symbolic"),
            ("history",  "History",  "document-open-recent-symbolic"),
        ]),
        ("SYSTEM", [
            ("kernels",  "Kernels",  "applications-engineering-symbolic"),
            ("repos",    "Repos",    "network-server-symbolic"),
            ("startup",  "Startup",  "media-playback-start-symbolic"),
            ("upgrade",  "Upgrade",  "go-up-symbolic"),
        ]),
        ("PROTECT", [
            ("security",  "Security",  "security-high-symbolic"),
            ("antivirus", "Antivirus", "security-medium-symbolic"),
        ]),
        ("OBSERVE", [
            ("logs",   "Logs",   "utilities-terminal-symbolic"),
            ("system", "System", "computer-symbolic"),
        ]),
    ]

    def _build_ui(self):
        # header bar
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.props.title = APP_NAME
        try:
            pretty = detect_distro().get("pretty", "")
            if pretty: hb.props.subtitle = pretty
        except Exception: pass
        self.btn_refresh = Gtk.Button.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.BUTTON)
        self.btn_refresh.set_tooltip_text("Refresh current page (F5)")
        self.btn_refresh.connect("clicked", self._on_refresh_dispatch)
        hb.pack_start(self.btn_refresh)
        menu_btn = Gtk.MenuButton()
        menu_btn.set_image(Gtk.Image.new_from_icon_name("open-menu-symbolic", Gtk.IconSize.BUTTON))
        m = Gtk.Menu()
        for lbl, cb in [("Settings…", self._show_settings), (None, None),
                        ("About", self._show_about), ("Quit", lambda *_: Gtk.main_quit())]:
            if lbl is None: m.append(Gtk.SeparatorMenuItem())
            else:
                it = Gtk.MenuItem(label=lbl); it.connect("activate", cb); m.append(it)
        m.show_all(); menu_btn.set_popup(m)
        hb.pack_end(menu_btn)
        self.set_titlebar(hb)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(vbox)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        vbox.pack_start(body, True, True, 0)

        # sidebar
        self.sidebar = Gtk.ListBox()
        self.sidebar.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.sidebar.get_style_context().add_class("sidebar")
        self.sidebar.set_size_request(185, -1)
        self.sidebar.connect("row-selected", self._on_page_changed)
        self._nav_rows = {}
        for section, pages in self.PAGES:
            hdr = Gtk.ListBoxRow(); hdr.set_selectable(False); hdr.set_activatable(False)
            hlbl = Gtk.Label(label=section, xalign=0)
            hlbl.get_style_context().add_class("nav-section")
            hdr.add(hlbl); self.sidebar.add(hdr)
            for pid, label, icon in pages:
                row = Gtk.ListBoxRow(); row.page_id = pid
                rb = Gtk.Box(spacing=9)
                img = Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU)
                img.get_style_context().add_class("nav-icon")
                lb = Gtk.Label(label=label, xalign=0)
                lb.get_style_context().add_class("nav-label")
                rb.pack_start(img, False, False, 0)
                rb.pack_start(lb, True, True, 0)
                if pid == "updates":
                    self._nav_badge = Gtk.Label(label="")
                    self._nav_badge.get_style_context().add_class("nav-badge")
                    self._nav_badge.set_no_show_all(True)
                    rb.pack_end(self._nav_badge, False, False, 0)
                row.add(rb)
                self.sidebar.add(row)
                self._nav_rows[pid] = row
        sidebar_sw = Gtk.ScrolledWindow()
        sidebar_sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sidebar_sw.add(self.sidebar)
        body.pack_start(sidebar_sw, False, False, 0)

        # stack
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(120)
        builders = {
            "overview":  self._build_overview_tab,
            "updates":   self._build_updates_tab,   "packages": self._build_packages_tab,
            "cleanup":   self._build_cleanup_tab,   "history":  self._build_history_tab,
            "kernels":   self._build_kernels_tab,   "repos":    self._build_repos_tab,
            "startup":   self._build_startup_tab,   "upgrade":  self._build_upgrade_tab,
            "security":  self._build_security_tab,  "antivirus":self._build_antivirus_tab,
            "logs":      self._build_logs_tab,      "system":   self._build_sysinfo_tab,
        }
        for _, pages in self.PAGES:
            for pid, label, _icon in pages:
                w = builders[pid]()
                w.get_style_context().add_class("page-pad")
                self.stack.add_named(w, pid)
        body.pack_start(self.stack, True, True, 0)

        self.sidebar.select_row(self._nav_rows["overview"])

        vbox.pack_start(Gtk.Separator(), False, False, 0)
        sb = Gtk.Box()
        self.status_label = Gtk.Label(label="Ready")
        self.status_label.set_halign(Gtk.Align.START)
        self.status_label.set_margin_start(12)
        self.count_label = Gtk.Label(label="")
        self.count_label.set_halign(Gtk.Align.END)
        self.count_label.set_margin_end(12)
        self.count_label.get_style_context().add_class("count-label")
        sb.pack_start(self.status_label, True, True, 0)
        sb.pack_end(self.count_label, False, False, 0)
        sb.set_margin_top(4); sb.set_margin_bottom(4)
        vbox.pack_start(sb, False, False, 0)
        self.progress = Gtk.ProgressBar()
        self.progress.set_no_show_all(True)
        vbox.pack_start(self.progress, False, False, 0)

    # ────────────────────────────────────────────────────────
    # TAB BUILDERS
    # ────────────────────────────────────────────────────────
    def _build_updates_tab(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=6)
        bar.get_style_context().add_class("tab-action-bar")
        self.btn_select_all = self._mkbtn("edit-select-all-symbolic", "Select All",      self._on_select_all)
        self.btn_deselect   = self._mkbtn("edit-clear-symbolic",      "Deselect All",    self._on_deselect_all)
        self.btn_fix_broken = self._mkbtn("dialog-warning-symbolic",  "Fix Broken Deps", self._on_fix_broken)
        self.btn_fix_broken.get_style_context().add_class("btn-warn")
        self.btn_install    = self._mkbtn("system-software-install-symbolic", "Install Updates", self._on_install)
        self.btn_install.get_style_context().add_class("suggested-action")
        for b in (self.btn_select_all, self.btn_deselect, self.btn_fix_broken):
            bar.pack_start(b, False, False, 0)
        bar.pack_end(self.btn_install, False, False, 0)
        outer.pack_start(bar, False, False, 0)

        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        paned.set_position(360)
        sw = Gtk.ScrolledWindow()
        self.store = Gtk.ListStore(bool,str,str,str,str,str,str,int,bool)
        self.tree  = Gtk.TreeView(model=self.store)
        self.tree.set_headers_clickable(True)
        self.tree.set_enable_search(True)
        self.tree.set_search_column(COL_PACKAGE)
        self.tree.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        self.tree.connect("row-activated", self._on_row_activated)
        tog = Gtk.CellRendererToggle(); tog.connect("toggled", self._on_toggle)
        c = Gtk.TreeViewColumn("", tog, active=COL_SELECTED); c.set_fixed_width(40)
        self.tree.append_column(c)
        for lbl,idx,w,exp in [("Package",COL_PACKAGE,220,True),("Installed",COL_OLD_VER,130,False),
                               ("Available",COL_NEW_VER,130,False),("Size",COL_SIZE,80,False),("Origin",COL_ORIGIN,120,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.END)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_resizable(True); c.set_fixed_width(w)
            c.set_sort_column_id(idx)
            if exp: c.set_expand(True)
            c.set_cell_data_func(r, self._cell_sec_color)
            self.tree.append_column(c)
        self.store.set_sort_func(COL_SIZE, self._sort_by_size, None)
        sw.add(self.tree); paned.pack1(sw, resize=True, shrink=False)
        sw2 = Gtk.ScrolledWindow()
        self.log_buf  = Gtk.TextBuffer()
        self.log_view = Gtk.TextView(buffer=self.log_buf)
        self.log_view.set_editable(False); self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.get_style_context().add_class("log-view")
        sw2.add(self.log_view); paned.pack2(sw2, resize=False, shrink=True)
        outer.pack_start(paned, True, True, 0)
        return outer

    def _build_packages_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        # search + filter bar
        bar = Gtk.Box(spacing=8)
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(4)
        self.pkg_search = Gtk.SearchEntry()
        self.pkg_search.set_placeholder_text("Search packages…")
        self.pkg_search.set_hexpand(True)
        self.pkg_search.connect("search-changed", self._on_pkg_search_changed)
        bar.pack_start(self.pkg_search, True, True, 0)
        self.pkg_filter_combo = Gtk.ComboBoxText()
        for opt in ("Installed","Upgradable","Held","Available","Flatpak","All Installed"):
            self.pkg_filter_combo.append_text(opt)
        self.pkg_filter_combo.set_active(0)
        self.pkg_filter_combo.connect("changed", self._on_pkg_filter_changed)
        bar.pack_start(self.pkg_filter_combo, False, False, 0)
        self.btn_pkg_install = self._mkbtn("system-software-install-symbolic","Install",self._on_pkg_install)
        self.btn_pkg_hold    = self._mkbtn("media-playback-pause-symbolic","Hold",self._on_pkg_hold)
        self.btn_pkg_hold.set_tooltip_text("Pin the selected package at its current version (apt-mark hold)")
        self.btn_pkg_remove  = self._mkbtn("edit-delete-symbolic","Remove",self._on_pkg_remove)
        self.btn_pkg_remove.get_style_context().add_class("btn-danger")
        bar.pack_start(self.btn_pkg_install, False, False, 0)
        bar.pack_start(self.btn_pkg_hold,    False, False, 0)
        bar.pack_start(self.btn_pkg_remove,  False, False, 0)
        vbox.pack_start(bar, False, False, 0)
        vbox.pack_start(Gtk.Separator(), False, False, 0)

        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL)
        paned.set_position(420)
        sw = Gtk.ScrolledWindow()
        # mark, name, installed, available, desc, size_str, raw_size, status
        self.pkg_store = Gtk.ListStore(str,str,str,str,str,str,int,str)
        self.pkg_tree  = Gtk.TreeView(model=self.pkg_store)
        self.pkg_tree.set_headers_clickable(True)
        self.pkg_tree.set_enable_search(True); self.pkg_tree.set_search_column(COL_P_NAME)
        self.pkg_tree.get_selection().connect("changed", self._on_pkg_selected)
        for lbl,idx,w,exp in [("",COL_P_MARK,28,False),("Package",COL_P_NAME,240,True),
                               ("Installed",COL_P_INST,130,False),("Available",COL_P_AVAIL,130,False),("Size",COL_P_SIZE,80,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.END)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_fixed_width(w); c.set_resizable(True)
            if exp: c.set_expand(True)
            c.set_sort_column_id(idx)
            c.set_cell_data_func(r, self._cell_pkg_color)
            self.pkg_tree.append_column(c)
        sw.add(self.pkg_tree); paned.pack1(sw, resize=True, shrink=False)
        # description pane
        sw2 = Gtk.ScrolledWindow()
        self.pkg_desc_buf  = Gtk.TextBuffer()
        self.pkg_desc_view = Gtk.TextView(buffer=self.pkg_desc_buf)
        self.pkg_desc_view.set_editable(False); self.pkg_desc_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.pkg_desc_view.set_margin_start(8); self.pkg_desc_view.set_margin_top(4)
        sw2.add(self.pkg_desc_view); paned.pack2(sw2, resize=False, shrink=True)
        vbox.pack_start(paned, True, True, 0)
        # pkg log
        vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw3 = Gtk.ScrolledWindow(); sw3.set_min_content_height(80)
        self.pkg_log_buf  = Gtk.TextBuffer()
        pkg_log_view = Gtk.TextView(buffer=self.pkg_log_buf)
        pkg_log_view.set_editable(False); pkg_log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        pkg_log_view.get_style_context().add_class("log-view")
        sw3.add(pkg_log_view); vbox.pack_start(sw3, False, False, 0)
        return vbox

    def _build_kernels_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=6); bar.get_style_context().add_class("tab-action-bar")
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(6)
        self.btn_kernel_install = self._mkbtn("system-software-install-symbolic","Install",self._on_kernel_install)
        self.btn_kernel_remove  = self._mkbtn("edit-delete-symbolic","Remove",self._on_kernel_remove)
        self.btn_kernel_default = self._mkbtn("starred-symbolic","Set as Default Boot",self._on_kernel_set_default)
        self.btn_kernel_remove.get_style_context().add_class("btn-danger")
        self.btn_kernel_default.get_style_context().add_class("accent-cyan")
        bar.pack_start(self.btn_kernel_install,  False, False, 0)
        bar.pack_start(self.btn_kernel_remove,   False, False, 0)
        bar.pack_start(self.btn_kernel_default,  False, False, 0)
        vbox.pack_start(bar, False, False, 0); vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw = Gtk.ScrolledWindow()
        self.kernel_store = Gtk.ListStore(bool,str,str,str,str,int)
        self.kernel_tree  = Gtk.TreeView(model=self.kernel_store)
        self.kernel_tree.set_headers_clickable(True)
        self.kernel_tree.get_selection().set_mode(Gtk.SelectionMode.SINGLE)
        r_star = Gtk.CellRendererText()
        cs = Gtk.TreeViewColumn("",r_star); cs.set_fixed_width(28)
        cs.set_cell_data_func(r_star, self._cell_kernel_star); self.kernel_tree.append_column(cs)
        for lbl,idx,w,exp in [("Package",COL_K_PACKAGE,280,True),("Version",COL_K_VERSION,160,False),
                               ("Status",COL_K_STATUS,100,False),("Size",COL_K_SIZE,80,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.END)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_fixed_width(w); c.set_resizable(True)
            if exp: c.set_expand(True)
            c.set_sort_column_id(idx); c.set_cell_data_func(r,self._cell_kernel_color)
            self.kernel_tree.append_column(c)
        sw.add(self.kernel_tree); vbox.pack_start(sw, True, True, 0)
        vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw2 = Gtk.ScrolledWindow(); sw2.set_min_content_height(90)
        self.kernel_log_buf = Gtk.TextBuffer()
        klv = Gtk.TextView(buffer=self.kernel_log_buf)
        klv.set_editable(False); klv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        klv.get_style_context().add_class("log-view")
        sw2.add(klv); vbox.pack_start(sw2, False, False, 0)
        return vbox

    def _build_repos_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=6); bar.get_style_context().add_class("tab-action-bar")
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(6)
        self.btn_repo_add    = self._mkbtn("list-add-symbolic","Add Repository",self._on_repo_add)
        self.btn_repo_remove = self._mkbtn("list-remove-symbolic","Remove",self._on_repo_remove)
        self.btn_repo_remove.get_style_context().add_class("btn-danger")
        hint = Gtk.Label(label="Toggle switch to enable/disable")
        hint.get_style_context().add_class("security-desc")
        bar.pack_start(self.btn_repo_add, False, False, 0)
        bar.pack_start(self.btn_repo_remove, False, False, 0)
        bar.pack_end(hint, False, False, 0)
        vbox.pack_start(bar, False, False, 0); vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw = Gtk.ScrolledWindow()
        self.repo_store = Gtk.ListStore(bool,str,str,str,str,str,int)
        self.repo_tree  = Gtk.TreeView(model=self.repo_store)
        self.repo_tree.set_headers_clickable(True)
        self.repo_tree.get_selection().set_mode(Gtk.SelectionMode.SINGLE)
        tog = Gtk.CellRendererToggle(); tog.connect("toggled",self._on_repo_toggle)
        ct = Gtk.TreeViewColumn("On",tog,active=COL_R_ENABLED); ct.set_fixed_width(45)
        self.repo_tree.append_column(ct)
        for lbl,idx,w,exp in [("Type",COL_R_TYPE,70,False),("URL",COL_R_URL,300,True),
                               ("Suite",COL_R_SUITE,120,False),("Components",COL_R_COMPS,150,False),("File",COL_R_FILE,160,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.END)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_fixed_width(w); c.set_resizable(True)
            if exp: c.set_expand(True)
            c.set_sort_column_id(idx); c.set_cell_data_func(r,self._cell_repo_color)
            self.repo_tree.append_column(c)
        sw.add(self.repo_tree); vbox.pack_start(sw, True, True, 0)
        return vbox

    def _build_security_tab(self):
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        lb = Gtk.ListBox(); lb.set_selection_mode(Gtk.SelectionMode.NONE)
        sw.add(lb)
        for feat in SECURITY_FEATURES:
            row = Gtk.ListBoxRow(); row.get_style_context().add_class("security-row")
            hbox = Gtk.Box(spacing=12)
            hbox.set_margin_start(8); hbox.set_margin_end(8); hbox.set_margin_top(6); hbox.set_margin_bottom(6)
            hbox.pack_start(Gtk.Image.new_from_icon_name(feat["icon"],Gtk.IconSize.DIALOG), False, False, 0)
            tb2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            t = Gtk.Label(label=feat["title"]); t.set_halign(Gtk.Align.START); t.get_style_context().add_class("security-title")
            d = Gtk.Label(label=feat["desc"]);  d.set_halign(Gtk.Align.START); d.set_line_wrap(True)
            d.set_max_width_chars(55); d.get_style_context().add_class("security-desc")
            tb2.pack_start(t,False,False,0); tb2.pack_start(d,False,False,0)
            hbox.pack_start(tb2, True, True, 0)
            sl = Gtk.Label(label="Checking…"); sl.get_style_context().add_class("status-unknown"); sl.set_width_chars(14)
            hbox.pack_start(sl, False, False, 0)
            sw2 = Gtk.Switch(); sw2.set_valign(Gtk.Align.CENTER)
            sw2.connect("state-set", lambda s,state,k=feat["key"]: self._on_security_toggle(s,state,k))
            hbox.pack_start(sw2, False, False, 0)
            row.add(hbox); lb.add(row)
            self._security_widgets[feat["key"]] = {"switch":sw2,"status_label":sl}
        return sw

    def _build_cleanup_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        inner.set_margin_start(16); inner.set_margin_end(16)
        inner.set_margin_top(12);   inner.set_margin_bottom(12)

        self._cleanup_rows = {}
        items = [
            ("apt_cache",   "APT Package Cache",    "/var/cache/apt/archives/",    "Clean cached .deb files — safe to delete",          self._do_apt_clean),
            ("apt_orphans", "Orphaned Packages",     None,                          "Packages no longer needed by any dependency",        self._do_apt_autoremove),
            ("old_kernels", "Old Kernel Packages",   None,                          "Installed kernels not currently running",            self._do_remove_old_kernels),
            ("thumbnails",  "Thumbnail Cache",       "~/.cache/thumbnails/",        "Cached image previews — regenerated automatically",  self._do_clean_thumbnails),
            ("trash",       "Trash",                 "~/.local/share/Trash/",       "Files in your trash bin",                            self._do_empty_trash),
        ]
        for key, title, path, desc, cb in items:
            row = Gtk.Box(spacing=12)
            row.set_margin_top(4); row.set_margin_bottom(4)
            lbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            tl = Gtk.Label(label=title); tl.set_halign(Gtk.Align.START)
            tl.get_style_context().add_class("security-title")
            dl = Gtk.Label(label=desc);  dl.set_halign(Gtk.Align.START)
            dl.get_style_context().add_class("security-desc")
            lbox.pack_start(tl, False, False, 0); lbox.pack_start(dl, False, False, 0)
            row.pack_start(lbox, True, True, 0)
            size_lbl = Gtk.Label(label="…"); size_lbl.set_width_chars(10)
            size_lbl.get_style_context().add_class("cleanup-size")
            row.pack_start(size_lbl, False, False, 0)
            btn = Gtk.Button(label="Clean"); btn.connect("clicked", lambda _,f=cb: f())
            btn.get_style_context().add_class("toolbar-btn")
            row.pack_start(btn, False, False, 0)
            inner.pack_start(row, False, False, 0)
            inner.pack_start(Gtk.Separator(), False, False, 0)
            self._cleanup_rows[key] = {"size_lbl": size_lbl, "btn": btn}

        scroll.add(inner); vbox.pack_start(scroll, True, True, 0)
        vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw3 = Gtk.ScrolledWindow(); sw3.set_min_content_height(120)
        self.cleanup_log_buf  = Gtk.TextBuffer()
        clv = Gtk.TextView(buffer=self.cleanup_log_buf)
        clv.set_editable(False); clv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        clv.get_style_context().add_class("log-view")
        sw3.add(clv); vbox.pack_start(sw3, False, False, 0)
        return vbox

    def _build_antivirus_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        # toolbar
        bar = Gtk.Box(spacing=6); bar.get_style_context().add_class("tab-action-bar")
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(6)
        self.btn_av_scan   = self._mkbtn("folder-saved-search-symbolic","Scan",self._on_av_scan)
        self.btn_av_update = self._mkbtn("system-software-update-symbolic","Update Definitions",self._on_av_update)
        self.btn_av_path   = Gtk.Button(label="/home")
        self.btn_av_path.connect("clicked", self._on_av_pick_path)
        self.btn_av_path.get_style_context().add_class("toolbar-btn")
        self._av_scan_path = Path.home()
        self.av_status_lbl = Gtk.Label(label="ClamAV status: checking…")
        self.av_status_lbl.set_halign(Gtk.Align.END)
        bar.pack_start(self.btn_av_scan,   False, False, 0)
        bar.pack_start(self.btn_av_update, False, False, 0)
        bar.pack_start(Gtk.Label(label="Path:"), False, False, 0)
        bar.pack_start(self.btn_av_path,   False, False, 0)
        bar.pack_end(self.av_status_lbl,   False, False, 0)
        vbox.pack_start(bar, False, False, 0); vbox.pack_start(Gtk.Separator(), False, False, 0)

        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL); paned.set_position(300)
        sw = Gtk.ScrolledWindow()
        self.av_store = Gtk.ListStore(str, str)
        self.av_tree  = Gtk.TreeView(model=self.av_store)
        self.av_tree.set_headers_clickable(True)
        for lbl,idx,w,exp in [("File",COL_AV_FILE,400,True),("Threat",COL_AV_THREAT,200,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.START)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_fixed_width(w); c.set_resizable(True)
            if exp: c.set_expand(True)
            self.av_tree.append_column(c)
        sw.add(self.av_tree); paned.pack1(sw, resize=True, shrink=False)
        sw2 = Gtk.ScrolledWindow()
        self.av_log_buf  = Gtk.TextBuffer()
        alv = Gtk.TextView(buffer=self.av_log_buf)
        alv.set_editable(False); alv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        alv.get_style_context().add_class("log-view")
        sw2.add(alv); paned.pack2(sw2, resize=True, shrink=True)
        vbox.pack_start(paned, True, True, 0)
        GLib.idle_add(self._av_check_installed)
        return vbox

    def _build_startup_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=6); bar.get_style_context().add_class("tab-action-bar")
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(6)
        hint = Gtk.Label(label="Toggle to enable/disable — systemd user services and XDG autostart entries")
        hint.get_style_context().add_class("security-desc")
        bar.pack_start(hint, False, False, 0)
        vbox.pack_start(bar, False, False, 0); vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw = Gtk.ScrolledWindow()
        # enabled, name, type, desc, file
        self.startup_store = Gtk.ListStore(bool,str,str,str,str)
        self.startup_tree  = Gtk.TreeView(model=self.startup_store)
        self.startup_tree.set_headers_clickable(True)
        tog = Gtk.CellRendererToggle(); tog.connect("toggled",self._on_startup_toggle)
        ct = Gtk.TreeViewColumn("On",tog,active=COL_ST_ENABLED); ct.set_fixed_width(45)
        self.startup_tree.append_column(ct)
        for lbl,idx,w,exp in [("Name",COL_ST_NAME,200,False),("Type",COL_ST_TYPE,100,False),
                               ("Description",COL_ST_DESC,300,True),("File",COL_ST_FILE,220,False)]:
            r=Gtk.CellRendererText(); r.set_property("ellipsize",Pango.EllipsizeMode.END)
            c=Gtk.TreeViewColumn(lbl,r,text=idx); c.set_fixed_width(w); c.set_resizable(True)
            if exp: c.set_expand(True)
            c.set_sort_column_id(idx)
            self.startup_tree.append_column(c)
        sw.add(self.startup_tree); vbox.pack_start(sw, True, True, 0)
        return vbox

    def _build_logs_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=6)
        bar.set_margin_start(8); bar.set_margin_end(8); bar.set_margin_top(6); bar.set_margin_bottom(6)
        self.log_unit_entry = Gtk.Entry()
        self.log_unit_entry.set_placeholder_text("Unit/service (blank = system)")
        self.log_unit_entry.set_width_chars(24)
        self.log_sev_combo = Gtk.ComboBoxText()
        for s in ("All","emergency","alert","crit","err","warning","notice","info","debug"):
            self.log_sev_combo.append_text(s)
        self.log_sev_combo.set_active(0)
        self.log_lines_combo = Gtk.ComboBoxText()
        for n in ("100","200","500","1000"):
            self.log_lines_combo.append_text(n)
        self.log_lines_combo.set_active(1)
        self.log_auto_chk = Gtk.CheckButton(label="Auto")
        self.log_auto_chk.connect("toggled",self._on_log_auto_toggle)
        self._log_auto_timer = None
        btn_fetch = self._mkbtn("view-refresh-symbolic","Fetch",self._on_log_fetch)
        bar.pack_start(Gtk.Label(label="Unit:"),      False, False, 0)
        bar.pack_start(self.log_unit_entry,            False, False, 0)
        bar.pack_start(Gtk.Label(label="Priority:"),  False, False, 0)
        bar.pack_start(self.log_sev_combo,             False, False, 0)
        bar.pack_start(Gtk.Label(label="Lines:"),     False, False, 0)
        bar.pack_start(self.log_lines_combo,           False, False, 0)
        btn_export = self._mkbtn("document-save-symbolic","Export",self._on_log_export)
        bar.pack_start(btn_fetch,                      False, False, 0)
        bar.pack_start(self.log_auto_chk,              False, False, 0)
        bar.pack_end(btn_export,                       False, False, 0)
        vbox.pack_start(bar, False, False, 0); vbox.pack_start(Gtk.Separator(), False, False, 0)
        sw = Gtk.ScrolledWindow()
        self.jlog_buf  = Gtk.TextBuffer()
        self.jlog_view = Gtk.TextView(buffer=self.jlog_buf)
        self.jlog_view.set_editable(False); self.jlog_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.jlog_view.get_style_context().add_class("log-view")
        sw.add(self.jlog_view); vbox.pack_start(sw, True, True, 0)
        return vbox

    def _build_sysinfo_tab(self):
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self._si_grid = Gtk.Grid()
        self._si_grid.set_column_spacing(16); self._si_grid.set_row_spacing(10)
        self._si_grid.set_margin_start(20); self._si_grid.set_margin_end(20)
        self._si_grid.set_margin_top(16);   self._si_grid.set_margin_bottom(16)
        self._si_labels = {}
        fields = [
            ("hostname","Hostname"),("distro","Distro"),("kernel","Kernel"),
            ("uptime","Uptime"),("cpu_model","CPU"),("cpu_cores","Cores"),
            ("cpu_usage","CPU Usage"),("gpu","GPU"),("ram","RAM"),
            ("swap","Swap"),("load","Load Avg"),("processes","Processes"),
        ]
        for i,(key,lbl) in enumerate(fields):
            kl = Gtk.Label(label=lbl+":"); kl.set_halign(Gtk.Align.END)
            kl.get_style_context().add_class("sysinfo-key")
            vl = Gtk.Label(label="…"); vl.set_halign(Gtk.Align.START)
            vl.set_selectable(True); vl.get_style_context().add_class("sysinfo-val")
            col = (i%2)*2
            self._si_grid.attach(kl, col,   i//2, 1, 1)
            self._si_grid.attach(vl, col+1, i//2, 1, 1)
            self._si_labels[key] = vl

        # disks section
        sep = Gtk.Separator(); sep.set_margin_top(8); sep.set_margin_bottom(4)
        self._si_grid.attach(sep, 0, len(fields)//2+2, 4, 1)
        disk_hdr = Gtk.Label(label="Disk Usage"); disk_hdr.set_halign(Gtk.Align.START)
        disk_hdr.get_style_context().add_class("section-label")
        self._si_grid.attach(disk_hdr, 0, len(fields)//2+3, 4, 1)
        self._si_disk_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self._si_grid.attach(self._si_disk_box, 0, len(fields)//2+4, 4, 1)

        scroll.add(self._si_grid)
        return scroll

    # ────────────────────────────────────────────────────────
    # CELL RENDERERS
    # ────────────────────────────────────────────────────────
    def _cell_sec_color(self, col, cell, model, it, data=None):
        is_sec = model.get_value(it, COL_IS_SECURITY)
        cell.set_property("background", "#3b1212" if is_sec else None)
        cell.set_property("foreground", "#ff8a80" if is_sec else None)

    def _cell_kernel_star(self, col, cell, model, it, data=None):
        running = model.get_value(it, COL_K_RUNNING)
        status  = model.get_value(it, COL_K_STATUS)
        is_def  = "default" in status.lower()
        if running and is_def:
            cell.set_property("text", "●★"); cell.set_property("foreground", "#4dd0e1")
        elif running:
            cell.set_property("text", "●");  cell.set_property("foreground", "#4dd0e1")
        elif is_def:
            cell.set_property("text", "★");  cell.set_property("foreground", "#b39ddb")
        else:
            cell.set_property("text", "");   cell.set_property("foreground", None)

    def _cell_kernel_color(self, col, cell, model, it, data=None):
        s = model.get_value(it, COL_K_STATUS)
        if "Running" in s:   cell.set_property("foreground", "#4dd0e1")
        elif "Installed" in s: cell.set_property("foreground", "#b39ddb")
        else:                cell.set_property("foreground", "#9e9eb8")

    def _cell_repo_color(self, col, cell, model, it, data=None):
        cell.set_property("foreground", None if model.get_value(it,COL_R_ENABLED) else "#666680")

    def _cell_pkg_color(self, col, cell, model, it, data=None):
        s = model.get_value(it, COL_P_STATUS)
        cell.set_property("foreground", {"installed":"#b39ddb","upgradable":"#4dd0e1",
                                         "held":"#ffb74d"}.get(s,"#9e9eb8"))

    def _mkbtn(self, icon, label, cb):
        btn = Gtk.Button()
        box = Gtk.Box(spacing=4)
        box.pack_start(Gtk.Image.new_from_icon_name(icon,Gtk.IconSize.SMALL_TOOLBAR),False,False,0)
        lbl = Gtk.Label(label=label)
        box.pack_start(lbl,False,False,0)
        btn.add(box); btn.connect("clicked",cb)
        btn.get_style_context().add_class("toolbar-btn")
        btn._label = lbl
        return btn

    # ────────────────────────────────────────────────────────
    # TAB SWITCH
    # ────────────────────────────────────────────────────────
    def _current_page(self):
        return self.stack.get_visible_child_name() or "updates"

    def _on_page_changed(self, listbox, row):
        if row is None or not hasattr(row, "page_id"): return
        pid = row.page_id
        self.stack.set_visible_child_name(pid)
        if   pid == "overview": self._refresh_overview(); self._start_dash_timer()
        elif pid == "packages" and not self._pkgs_loaded:    self._load_installed_pkgs()
        elif pid == "kernels"  and not self._kernels_loaded: self._on_refresh_kernels()
        elif pid == "repos"    and not self._repos_loaded:   self._refresh_repos()
        elif pid == "startup"  and not self._startup_loaded: self._refresh_startup()
        elif pid == "security": self._refresh_security_status()
        elif pid == "cleanup":  GLib.idle_add(self._refresh_cleanup_sizes)
        elif pid == "history":  self._refresh_history()
        elif pid == "system":   self._start_sysinfo_timer()
        elif pid == "upgrade":  self._upgrade_check_version()
        if pid != "system":   self._stop_sysinfo_timer()
        if pid != "overview": self._stop_dash_timer()

    def _on_refresh_dispatch(self, *_):
        fns = {"updates": self._on_refresh,        "packages": self._load_installed_pkgs,
               "kernels": self._on_refresh_kernels,"repos":    self._refresh_repos,
               "security":self._refresh_security_status, "cleanup": self._refresh_cleanup_sizes,
               "startup": self._refresh_startup,   "logs":     self._on_log_fetch,
               "system":  self._refresh_sysinfo,   "upgrade":  self._upgrade_check_version,
               "history": self._refresh_history,   "overview": self._refresh_overview}
        fn = fns.get(self._current_page())
        if fn: fn()

    # ────────────────────────────────────────────────────────
    # TRAY
    # ────────────────────────────────────────────────────────
    def _init_tray(self):
        self._tray = None
        if HAS_APPINDICATOR:
            self._tray = AppIndicator3.Indicator.new(APP_ID,"system-software-update-symbolic",
                AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
            self._tray.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            self._tray.set_menu(self._build_tray_menu()); self._tray.set_title(APP_NAME)
        else:
            self._tray = Gtk.StatusIcon()
            self._tray.set_from_icon_name("system-software-update-symbolic")
            self._tray.set_tooltip_text(APP_NAME)
            self._tray.connect("activate",self._on_tray_activate)
            self._tray.connect("popup-menu",self._on_tray_popup)
        self.connect("delete-event", self._on_delete_event)

    def _build_tray_menu(self):
        menu = Gtk.Menu()
        for lbl,cb in [("Show",lambda *_:self._show_window()),
                       ("Check for Updates",lambda *_:(self._show_window(),self._on_refresh())),
                       (None,None),("About",lambda *_:self._show_about()),
                       ("Quit",lambda *_:Gtk.main_quit())]:
            if lbl is None: menu.append(Gtk.SeparatorMenuItem())
            else:
                it = Gtk.MenuItem(label=lbl); it.connect("activate",cb); menu.append(it)
        menu.show_all(); return menu

    def _on_tray_activate(self,*_): self._show_window()
    def _on_tray_popup(self,icon,btn,t):
        self._build_tray_menu().popup(None,None,Gtk.StatusIcon.position_menu,icon,btn,t)
    def _show_window(self): self.present(); self.show_all(); self.progress.hide()
    def _on_delete_event(self,w,e): self.hide(); return True

    def _update_tray_count(self, count):
        tt = f"{APP_NAME} — {count} update(s)" if count else f"{APP_NAME} — up to date"
        ico = "system-software-update" if count else "system-software-update-symbolic"
        if HAS_APPINDICATOR and self._tray: self._tray.set_icon_full(ico,tt)
        elif self._tray:
            self._tray.set_from_icon_name(ico); self._tray.set_tooltip_text(tt)

    def _send_notification(self, title, body):
        try: subprocess.run(["notify-send",title,body,"--icon=system-software-update",
                              f"--app-name={APP_NAME}"],timeout=10,capture_output=True)
        except Exception: pass

    def _background_check(self):
        if not self._busy:
            threading.Thread(target=self._background_check_worker,daemon=True).start()
        return True

    def _background_check_worker(self):
        try:
            cache=apt.Cache(); cache.open(None); cache.upgrade(dist_upgrade=False)
            count=0; sec=0
            for p in cache.get_changes():
                if not (p.is_upgradable or p.marked_install): continue
                count+=1
                c=p.candidate
                if c and c.origins and any("security" in (getattr(o,at,"") or "").lower()
                                           for o in c.origins for at in ("archive","label","site")):
                    sec+=1
            cache.close(); GLib.idle_add(self._update_tray_count,count)
            if (count>0 and count!=self._last_update_count
                    and self._settings.get("notify_updates",True)
                    and (sec>0 or not self._settings.get("notify_security_only",False))):
                body=f"{count} update(s) available"+(f" — {sec} security" if sec else "")
                self._send_notification(APP_NAME,body)
            self._last_update_count=count
        except Exception: pass

    # ────────────────────────────────────────────────────────
    # HELPERS
    # ────────────────────────────────────────────────────────
    def _sort_by_size(self,model,a,b,_):
        va=model.get_value(a,COL_RAW_SIZE); vb=model.get_value(b,COL_RAW_SIZE)
        return (va>vb)-(va<vb)

    def _log(self,text): GLib.idle_add(self._log_append,text)
    def _log_append(self,text):
        end=self.log_buf.get_end_iter()
        self.log_buf.insert(end,f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")
        self.log_view.scroll_to_iter(self.log_buf.get_end_iter(),0,False,0,0)

    def _klog(self,text): GLib.idle_add(self._klog_append,text)
    def _klog_append(self,text):
        end=self.kernel_log_buf.get_end_iter()
        self.kernel_log_buf.insert(end,f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")

    def _plog(self,text): GLib.idle_add(self._plog_append,text)
    def _plog_append(self,text):
        end=self.pkg_log_buf.get_end_iter()
        self.pkg_log_buf.insert(end,f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")

    def _clog(self,text): GLib.idle_add(self._clog_append,text)
    def _clog_append(self,text):
        end=self.cleanup_log_buf.get_end_iter()
        self.cleanup_log_buf.insert(end,f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")

    def _avlog(self,text): GLib.idle_add(self._avlog_append,text)
    def _avlog_append(self,text):
        end=self.av_log_buf.get_end_iter()
        self.av_log_buf.insert(end,f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")

    def _set_status(self,text):
        if hasattr(self,'status_label'): GLib.idle_add(self.status_label.set_text,text)

    def _set_busy(self,busy):
        self._busy=busy; GLib.idle_add(self._update_sensitivity)

    def _update_sensitivity(self):
        s=not self._busy
        self.btn_refresh.set_sensitive(s)
        self.btn_install.set_sensitive(s and self._has_selected())
        self.btn_select_all.set_sensitive(s); self.btn_deselect.set_sensitive(s)
        self.btn_fix_broken.set_sensitive(s)

    def _update_counts(self):
        total=len(self.store); sel=sum(1 for r in self.store if r[COL_SELECTED])
        ssz=sum(r[COL_RAW_SIZE] for r in self.store if r[COL_SELECTED])
        sec=sum(1 for r in self.store if r[COL_IS_SECURITY])
        self.count_label.set_text(f"{sel}/{total} selected ({human_size(ssz)})" + (f"  ({sec} security)" if sec else ""))
        self.btn_install.set_sensitive(not self._busy and sel>0)

    def _has_selected(self): return any(r[COL_SELECTED] for r in self.store)

    def _show_error(self,title,msg):
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.ERROR,
                             buttons=Gtk.ButtonsType.OK,text=title)
        d.format_secondary_text(msg); d.run(); d.destroy()

    # ────────────────────────────────────────────────────────
    # UPDATES
    # ────────────────────────────────────────────────────────
    def _on_toggle(self,w,path): self.store[path][COL_SELECTED]=not self.store[path][COL_SELECTED]; self._update_counts()
    def _on_row_activated(self,t,path,col): self.store[path][COL_SELECTED]=not self.store[path][COL_SELECTED]; self._update_counts()
    def _on_select_all(self,*_): [r.__setitem__(COL_SELECTED,True) for r in self.store]; self._update_counts()
    def _on_deselect_all(self,*_): [r.__setitem__(COL_SELECTED,False) for r in self.store]; self._update_counts()

    def _on_refresh(self,*_):
        if self._busy: return
        self._set_busy(True); self._set_status("Refreshing package lists…")
        self._log("Running apt update…"); self.progress.show(); self.progress.pulse()
        def _pulse():
            if self._busy: self.progress.pulse(); return True
            return False
        GLib.timeout_add(200,_pulse)
        threading.Thread(target=self._refresh_worker,daemon=True).start()

    def _refresh_worker(self):
        try:
            r=subprocess.run(["apt","update"],capture_output=True,text=True,timeout=120)
            self._log("Package lists refreshed." if r.returncode==0 else f"apt update warning: {r.stderr.strip()}")
            cache=apt.Cache(); cache.open(None); cache.upgrade(dist_upgrade=False)
            updates=[]
            for pkg in cache.get_changes():
                if pkg.is_upgradable or pkg.marked_install:
                    cand=pkg.candidate; inst=pkg.installed
                    origin=""; is_sec=False
                    if cand and cand.origins:
                        for o in cand.origins:
                            origin=o.origin or o.archive or ""
                            if any("security" in (getattr(o,a,"") or "").lower() for a in ("archive","label","site")):
                                is_sec=True; break
                        if not origin and cand.origins: origin=cand.origins[0].origin or cand.origins[0].archive or ""
                    updates.append({"name":pkg.name,"old_ver":inst.version if inst else "(new)",
                                    "new_ver":cand.version if cand else "?","size":cand.size if cand else 0,
                                    "origin":origin,"desc":cand.summary if cand else "","is_security":is_sec})
            cache.close()
            if self._settings.get("include_flatpak_updates") and shutil.which("flatpak"):
                try:
                    inst={}
                    ri=subprocess.run(["flatpak","list","--app","--columns=application,version"],
                                      capture_output=True,text=True,timeout=60)
                    for ln in ri.stdout.splitlines():
                        p=ln.split("\t")
                        if p and p[0].strip(): inst[p[0].strip()]=p[1].strip() if len(p)>1 else ""
                    ru=subprocess.run(["flatpak","remote-ls","--updates","--app",
                                       "--columns=application,version"],
                                      capture_output=True,text=True,timeout=60)
                    for ln in ru.stdout.splitlines():
                        p=ln.split("\t")
                        if not p or not p[0].strip(): continue
                        app=p[0].strip(); ver=p[1].strip() if len(p)>1 else ""
                        updates.append({"name":app,"old_ver":inst.get(app,"?"),
                                        "new_ver":ver or "latest","size":0,"origin":"Flatpak",
                                        "desc":"Flatpak application update","is_security":False})
                except Exception as e: self._log(f"Flatpak check skipped: {e}")
            self._updates=updates
            sec=sum(1 for u in updates if u["is_security"])
            fp=sum(1 for u in updates if u["origin"]=="Flatpak")
            self._log(f"Found {len(updates)} update(s) ({sec} security"+(f", {fp} flatpak" if fp else "")+").")
            GLib.idle_add(self._populate_store); GLib.idle_add(self._update_tray_count,len(updates))
            self._last_update_count=len(updates)
        except Exception as e: self._log(f"Error: {e}")
        finally: GLib.idle_add(self.progress.hide); self._set_busy(False); self._set_status("Ready")

    def _populate_store(self):
        self.store.clear()
        for u in sorted(self._updates,key=lambda x:(not x["is_security"],x["name"])):
            self.store.append([True,u["name"],u["old_ver"],u["new_ver"],human_size(u["size"]),
                               u["origin"],u["desc"],u["size"],u["is_security"]])
        self._update_counts()
        self._update_nav_badge()

    def _update_nav_badge(self):
        n = len(self._updates)
        sec = sum(1 for u in self._updates if u.get("is_security"))
        ctx = self._nav_badge.get_style_context()
        if sec: ctx.add_class("nav-badge-sec")
        else:   ctx.remove_class("nav-badge-sec")
        self._nav_badge.set_text(str(n))
        self._nav_badge.set_visible(n > 0)
        self._update_dash_updates()

    def _on_install(self,*_):
        if self._busy: return
        selected=[(r[COL_PACKAGE],r[COL_ORIGIN]) for r in self.store if r[COL_SELECTED]]
        if not selected: return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Install {len(selected)} update(s)?")
        d.format_secondary_text("Selected packages will be upgraded.")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        self._set_busy(True); self._set_status(f"Installing {len(selected)} update(s)…")
        names=[n for n,_ in selected]
        self._log("Installing: "+", ".join(names[:10])+(f" (+{len(names)-10} more)" if len(names)>10 else ""))
        self.progress.show(); self.progress.set_fraction(0)
        threading.Thread(target=self._install_worker,args=(selected,),daemon=True).start()

    def _install_worker(self,selected):
        apt_pkgs=[n for n,o in selected if o!="Flatpak"]
        fp_pkgs =[n for n,o in selected if o=="Flatpak"]
        ok=True
        try:
            if self._settings.get("snapshot_before_install") and shutil.which("timeshift"):
                self._log("Creating Timeshift snapshot…")
                r=subprocess.run(["timeshift","--create","--comments",f"{APP_NAME} pre-update","--scripted"],
                                 capture_output=True,text=True,timeout=900)
                self._log("✓ Snapshot created." if r.returncode==0
                          else f"Snapshot failed (exit {r.returncode}) — continuing anyway.")
            if apt_pkgs:
                proc=subprocess.Popen(["apt","install","-y","--only-upgrade"]+apt_pkgs,
                    stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                for line in proc.stdout:
                    line=line.rstrip()
                    if line: self._log(line)
                    m=re.search(r"Progress:\s*\[\s*(\d+)%\]",line)
                    if m: GLib.idle_add(self.progress.set_fraction,int(m.group(1))/100.0)
                proc.wait()
                if proc.returncode!=0:
                    ok=False; self._log(f"apt finished with errors (exit {proc.returncode}).")
            if fp_pkgs:
                self._log(f"Updating {len(fp_pkgs)} flatpak(s)…")
                proc=subprocess.Popen(["flatpak","update","-y","--noninteractive"]+fp_pkgs,
                    stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                for line in proc.stdout:
                    if line.rstrip(): self._log(line.rstrip())
                proc.wait()
                if proc.returncode!=0:
                    ok=False; self._log(f"flatpak finished with errors (exit {proc.returncode}).")
            if ok:
                self._log("Installation complete!")
                self._save_history([n for n,_ in selected]); self._refresh_worker()
        except Exception as e: self._log(f"Error: {e}")
        finally: GLib.idle_add(self.progress.hide); self._set_busy(False); self._set_status("Ready")

    def _save_history(self,packages):
        try:
            h=json.loads(HISTORY_FILE.read_text()) if HISTORY_FILE.exists() else []
            h.append({"date":datetime.now().isoformat(),"packages":packages,"count":len(packages)})
            keep=max(50,int(self._settings.get("history_keep",200)))
            HISTORY_FILE.write_text(json.dumps(h[-keep:],indent=2))
        except Exception: pass

    def _on_fix_broken(self,*_):
        if self._busy: return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text="Fix broken dependencies?")
        d.format_secondary_text("Runs dpkg --configure -a and apt --fix-broken install.")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        self._set_busy(True); self._set_status("Fixing broken deps…"); self.progress.show()
        threading.Thread(target=self._fix_broken_worker,daemon=True).start()

    def _fix_broken_worker(self):
        try:
            self._log("Running dpkg --configure -a…")
            r=subprocess.run(["dpkg","--configure","-a"],capture_output=True,text=True,timeout=120)
            for line in r.stdout.splitlines():
                if line.strip(): self._log(line)
            self._log("Running apt --fix-broken install…")
            proc=subprocess.Popen(["apt","--fix-broken","install","-y"],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._log(line.rstrip())
            proc.wait()
            self._log("Done." if proc.returncode==0 else f"Finished with errors (exit {proc.returncode}).")
        except Exception as e: self._log(f"Error: {e}")
        finally: GLib.idle_add(self.progress.hide); self._set_busy(False); self._set_status("Ready")

    # ────────────────────────────────────────────────────────
    # OVERVIEW DASHBOARD
    # ────────────────────────────────────────────────────────
    def _build_overview_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        grid = Gtk.Grid(column_homogeneous=True)
        grid.set_margin_top(6); grid.set_margin_start(6); grid.set_margin_end(6)
        self._dash = {}
        cards = [("updates",  "UPDATES",          "checking…"),
                 ("security", "SECURITY SCORE",   "running checks…"),
                 ("cleanup",  "RECLAIMABLE",      "estimating…"),
                 ("system",   "SYSTEM",           "")]
        for i, (pid, eyebrow, sub) in enumerate(cards):
            btn = Gtk.Button(relief=Gtk.ReliefStyle.NONE)
            btn.get_style_context().add_class("dash-card")
            bb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            e = Gtk.Label(label=eyebrow, xalign=0); e.get_style_context().add_class("dash-eyebrow")
            v = Gtk.Label(label="–", xalign=0);     v.get_style_context().add_class("dash-value")
            v.set_ellipsize(Pango.EllipsizeMode.END)
            s = Gtk.Label(label=sub, xalign=0);     s.get_style_context().add_class("dash-sub")
            s.set_ellipsize(Pango.EllipsizeMode.END)
            for w in (e, v, s): bb.pack_start(w, False, False, 0)
            btn.add(bb)
            btn.connect("clicked", lambda _b, p=pid: self.sidebar.select_row(self._nav_rows[p]))
            grid.attach(btn, i % 2, i // 2, 1, 1)
            self._dash[pid] = {"value": v, "sub": s, "btn": btn}
        vbox.pack_start(grid, False, False, 0)

        frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        frame.get_style_context().add_class("spark-frame")
        frame.set_margin_start(12); frame.set_margin_end(12); frame.set_margin_bottom(6)
        hdr = Gtk.Box(spacing=12)
        hdr.set_margin_top(10); hdr.set_margin_start(14); hdr.set_margin_end(14)
        t = Gtk.Label(label="LIVE — CPU / RAM", xalign=0)
        t.get_style_context().add_class("dash-eyebrow")
        self.spark_lbl = Gtk.Label(label="")
        self.spark_lbl.get_style_context().add_class("dash-sub")
        hdr.pack_start(t, False, False, 0)
        hdr.pack_end(self.spark_lbl, False, False, 0)
        frame.pack_start(hdr, False, False, 0)
        self.spark = Gtk.DrawingArea()
        self.spark.set_size_request(-1, 120)
        self.spark.connect("draw", self._draw_sparkline)
        frame.pack_start(self.spark, True, True, 0)
        vbox.pack_start(frame, True, True, 0)

        self._cpu_hist = []; self._ram_hist = []
        self._cpu_prev = None; self._dash_timer = None
        return vbox

    def _refresh_overview(self, *_):
        self._update_dash_updates()
        self._dash["system"]["value"].set_text(platform.release())
        try:
            secs = float(Path("/proc/uptime").read_text().split()[0])
            d, h, m = int(secs // 86400), int(secs % 86400 // 3600), int(secs % 3600 // 60)
            self._dash["system"]["sub"].set_text("uptime " + (f"{d}d {h}h" if d else f"{h}h {m}m"))
        except Exception:
            self._dash["system"]["sub"].set_text("kernel")
        threading.Thread(target=self._dash_security_worker, daemon=True).start()
        threading.Thread(target=self._dash_cleanup_worker, daemon=True).start()

    def _update_dash_updates(self):
        if not hasattr(self, "_dash"): return
        n = len(self._updates)
        sec = sum(1 for u in self._updates if u.get("is_security"))
        d = self._dash["updates"]
        d["value"].set_text(str(n))
        d["sub"].set_text("all up to date" if n == 0 else
                          (f"{sec} security update(s)" if sec else "no security updates"))
        ctx = d["btn"].get_style_context()
        ctx.remove_class("dash-warn"); ctx.remove_class("dash-bad")
        if sec:  ctx.add_class("dash-bad")
        elif n:  ctx.add_class("dash-warn")

    def _dash_security_worker(self):
        checks = [self._check_ufw, self._check_unattended_upgrades, self._check_fail2ban,
                  self._check_ssh_root, self._check_ssh_password, self._check_usb_storage,
                  self._check_core_dumps, self._check_sysrq]
        good = total = 0
        for fn in checks:
            try: r = fn()
            except Exception: r = {"status": "unknown", "active": False}
            if r.get("status") == "not_installed": continue
            total += 1
            if r.get("active"): good += 1
        def apply():
            d = self._dash["security"]
            d["value"].set_text(f"{good}/{total}")
            d["sub"].set_text("fully hardened" if total and good == total
                              else f"{total-good} check(s) to review")
            ctx = d["btn"].get_style_context()
            ctx.remove_class("dash-warn"); ctx.remove_class("dash-bad")
            if total and good / total < 0.5: ctx.add_class("dash-bad")
            elif good < total:               ctx.add_class("dash-warn")
        GLib.idle_add(apply)

    def _dash_cleanup_worker(self):
        total = 0
        for p in ("/var/cache/apt/archives",
                  str(Path.home() / ".cache" / "thumbnails"),
                  str(Path.home() / ".local" / "share" / "Trash")):
            try:
                r = subprocess.run(["du", "-sb", p], capture_output=True, text=True, timeout=30)
                if r.returncode == 0: total += int(r.stdout.split()[0])
            except Exception: pass
        def apply():
            self._dash["cleanup"]["value"].set_text(human_size(total))
            self._dash["cleanup"]["sub"].set_text("apt cache · thumbnails · trash")
        GLib.idle_add(apply)

    def _start_dash_timer(self):
        if getattr(self, "_dash_timer", None): return
        self._cpu_prev = None
        self._dash_timer = GLib.timeout_add(2000, self._dash_tick)
        self._dash_tick()

    def _stop_dash_timer(self):
        if getattr(self, "_dash_timer", None):
            GLib.source_remove(self._dash_timer); self._dash_timer = None

    def _dash_tick(self):
        try:
            vals = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:]))
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
            tot = sum(vals)
            if self._cpu_prev:
                dt = tot - self._cpu_prev[0]; di = idle - self._cpu_prev[1]
                if dt > 0:
                    self._cpu_hist.append(max(0.0, min(100.0, 100.0 * (dt - di) / dt)))
                    self._cpu_hist[:] = self._cpu_hist[-90:]
            self._cpu_prev = (tot, idle)
            mem = {}
            for ln in Path("/proc/meminfo").read_text().splitlines():
                k, v = ln.split(":", 1); mem[k] = int(v.split()[0])
            ram = 100.0 * (mem["MemTotal"] - mem["MemAvailable"]) / mem["MemTotal"]
            self._ram_hist.append(ram); self._ram_hist[:] = self._ram_hist[-90:]
            if self._cpu_hist:
                self.spark_lbl.set_text(f"CPU {self._cpu_hist[-1]:.0f}%    RAM {ram:.0f}%")
            self.spark.queue_draw()
        except Exception: pass
        return True

    def _draw_sparkline(self, area, cr):
        w = area.get_allocated_width(); h = area.get_allocated_height()
        a = self._accent()
        ac = tuple(int(a[i:i+2], 16) / 255 for i in (1, 3, 5))
        step = w / 89.0
        def plot(hist, rgb, fill):
            if len(hist) < 2: return
            n = len(hist); x0 = w - (n - 1) * step
            cr.set_line_width(1.6)
            cr.set_source_rgba(rgb[0], rgb[1], rgb[2], 0.9)
            for i, v in enumerate(hist):
                x = x0 + i * step
                y = (h - 6) - (h - 16) * (v / 100.0)
                (cr.move_to if i == 0 else cr.line_to)(x, y)
            if fill:
                cr.stroke_preserve()
                cr.line_to(x0 + (n - 1) * step, h); cr.line_to(x0, h); cr.close_path()
                cr.set_source_rgba(rgb[0], rgb[1], rgb[2], 0.12); cr.fill()
            else:
                cr.stroke()
        plot(self._ram_hist, (0.70, 0.62, 0.86), False)  # amethyst = RAM
        plot(self._cpu_hist, ac, True)                   # accent   = CPU
        return False

    # ────────────────────────────────────────────────────────
    # HISTORY
    # ────────────────────────────────────────────────────────
    def _build_history_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        bar = Gtk.Box(spacing=8); bar.get_style_context().add_class("tab-action-bar")
        lbl = Gtk.Label(label="Install History", xalign=0)
        lbl.get_style_context().add_class("section-label")
        self.hist_count_lbl = Gtk.Label(label="")
        self.hist_count_lbl.get_style_context().add_class("security-desc")
        bar.pack_start(lbl, False, False, 0)
        bar.pack_end(self.hist_count_lbl, False, False, 0)
        vbox.pack_start(bar, False, False, 0)
        sw = Gtk.ScrolledWindow()
        self.hist_store = Gtk.TreeStore(str, str)
        tree = Gtk.TreeView(model=self.hist_store)
        for title, idx, exp in [("When / Package", 0, True), ("Details", 1, False)]:
            r = Gtk.CellRendererText(); r.set_property("ellipsize", Pango.EllipsizeMode.END)
            c = Gtk.TreeViewColumn(title, r, text=idx)
            c.set_resizable(True)
            if exp: c.set_expand(True)
            tree.append_column(c)
        sw.add(tree)
        vbox.pack_start(sw, True, True, 0)
        return vbox

    def _refresh_history(self, *_):
        try:
            events = json.loads(HISTORY_FILE.read_text()) if HISTORY_FILE.exists() else []
        except Exception:
            events = []
        self.hist_store.clear()
        for ev in reversed(events):
            try:
                when = datetime.fromisoformat(ev.get("date", "")).strftime("%Y-%m-%d  %H:%M")
            except Exception:
                when = ev.get("date", "?")
            pkgs = ev.get("packages", [])
            parent = self.hist_store.append(None, [when, f"{len(pkgs)} package(s)"])
            for p in pkgs:
                self.hist_store.append(parent, [p, ""])
        self.hist_count_lbl.set_text(f"{len(events)} install event(s)")

    # ────────────────────────────────────────────────────────
    # PACKAGES
    # ────────────────────────────────────────────────────────
    def _load_installed_pkgs(self,*_):
        self._set_status("Loading packages…")
        threading.Thread(target=self._load_installed_worker,daemon=True).start()

    def _load_installed_worker(self):
        try:
            cache=apt.Cache(); cache.open(None); cache.upgrade(dist_upgrade=False)
            upgradable={p.name for p in cache.get_changes() if p.is_upgradable}
            held=set()
            try:
                held=set(subprocess.run(["apt-mark","showhold"],capture_output=True,
                                        text=True,timeout=15).stdout.split())
            except Exception: pass
            pkgs=[]
            for name in sorted(cache.keys()):
                pkg=cache[name]
                if not pkg.installed: continue
                inst=pkg.installed; cand=pkg.candidate
                if name in held:                 status="held";       mark="⏸"
                elif name in upgradable:         status="upgradable"; mark="▲"
                else:                            status="installed";  mark="●"
                pkgs.append([mark,name,inst.version,cand.version if cand else "",
                              inst.summary or "",human_size(inst.installed_size),
                              inst.installed_size,status])
            cache.close(); self._pkgs=pkgs
            GLib.idle_add(self._populate_pkg_store,pkgs)
        except Exception as e: self._plog(f"Error loading packages: {e}")
        finally: self._pkgs_loaded=True; self._set_status("Ready")

    def _populate_pkg_store(self,rows):
        self.pkg_store.clear()
        for r in rows: self.pkg_store.append(r)

    def _on_pkg_search_changed(self,entry):
        term=entry.get_text().strip()
        if self._pkg_search_pending:
            GLib.source_remove(self._pkg_search_pending)
        self._pkg_search_pending=GLib.timeout_add(300,self._do_pkg_search,term)

    def _do_pkg_search(self,term):
        self._pkg_search_pending=None
        if not term:
            filt=self.pkg_filter_combo.get_active_text() or "Installed"
            if filt in ("Installed","All Installed"):
                GLib.idle_add(self._populate_pkg_store,self._pkgs)
            return False
        threading.Thread(target=self._pkg_search_worker,args=(term,),daemon=True).start()
        return False

    def _pkg_search_worker(self,term):
        try:
            cache=apt.Cache(); cache.open(None)
            cache.upgrade(dist_upgrade=False)
            upgradable={p.name for p in cache.get_changes() if p.is_upgradable}
            results=[]
            for name in sorted(cache.keys()):
                if term.lower() not in name.lower(): continue
                pkg=cache[name]
                inst=pkg.installed; cand=pkg.candidate
                if inst:
                    status="upgradable" if name in upgradable else "installed"
                    mark="▲" if status=="upgradable" else "●"
                    results.append([mark,name,inst.version,cand.version if cand else "",
                                    inst.summary or "",human_size(inst.installed_size),inst.installed_size,status])
                elif cand:
                    results.append(["○",name,"",cand.version,cand.summary or "",
                                    human_size(cand.size),cand.size,"available"])
                if len(results)>=400: break
            cache.close(); GLib.idle_add(self._populate_pkg_store,results)
        except Exception as e: self._plog(f"Search error: {e}")

    def _on_pkg_filter_changed(self,combo):
        filt=combo.get_active_text()
        if not self.pkg_search.get_text().strip():
            if filt=="Upgradable":
                rows=[r for r in self._pkgs if r[COL_P_STATUS]=="upgradable"]
            elif filt=="Held":
                rows=[r for r in self._pkgs if r[COL_P_STATUS]=="held"]
            elif filt=="Available":
                self._plog("Type a search term to browse available packages.")
                return
            elif filt=="Flatpak":
                threading.Thread(target=self._load_flatpak_pkgs,daemon=True).start()
                return
            else:
                rows=self._pkgs
            GLib.idle_add(self._populate_pkg_store,rows)

    def _load_flatpak_pkgs(self):
        if shutil.which("flatpak") is None:
            self._plog("Flatpak is not installed.")
            GLib.idle_add(self._populate_pkg_store,[])
            return
        try:
            r=subprocess.run(["flatpak","list","--columns=application,version,size,description"],
                capture_output=True,text=True,timeout=30)
            rows=[]
            for line in r.stdout.splitlines():
                parts=line.split("\t")
                if len(parts)<4: continue
                name,ver,size,desc=parts[0],parts[1],parts[2],parts[3]
                rows.append(["◆",name,ver,"",desc,size,0,"installed"])
            self._plog(f"Found {len(rows)} flatpak(s).")
            GLib.idle_add(self._populate_pkg_store,rows)
        except Exception as e: self._plog(f"Flatpak error: {e}")

    def _on_pkg_selected(self,sel):
        model,it=sel.get_selected()
        if it is None: return
        name=model.get_value(it,COL_P_NAME)
        desc=model.get_value(it,COL_P_DESC)
        status=model.get_value(it,COL_P_STATUS)
        if hasattr(self,"btn_pkg_hold"):
            self.btn_pkg_hold._label.set_text("Unhold" if status=="held" else "Hold")
        self.pkg_desc_buf.set_text(f"{name}\n\n{desc}")

    def _on_pkg_hold(self,*_):
        name,status=self._get_selected_pkg()
        if not name: return
        if status=="held": act="unhold"
        elif status in ("installed","upgradable"): act="hold"
        else: self._show_error("Not installed",f"{name} is not installed via apt."); return
        threading.Thread(target=self._pkg_mark_worker,args=(act,name),daemon=True).start()

    def _pkg_mark_worker(self,act,name):
        self._plog(f"apt-mark {act} {name}…")
        try:
            r=subprocess.run(["apt-mark",act,name],capture_output=True,text=True,timeout=30)
            out=(r.stdout or r.stderr).strip()
            if out: self._plog(out)
            if r.returncode==0:
                self._pkgs_loaded=False; GLib.idle_add(self._load_installed_pkgs)
            else: self._plog(f"apt-mark failed (exit {r.returncode}).")
        except Exception as e: self._plog(f"Error: {e}")

    def _get_selected_pkg(self):
        model,it=self.pkg_tree.get_selection().get_selected()
        if it is None: return None,None
        return model.get_value(it,COL_P_NAME), model.get_value(it,COL_P_STATUS)

    def _on_pkg_install(self,*_):
        name,status=self._get_selected_pkg()
        if not name: return
        if status=="installed": self._show_error("Already installed",f"{name} is already installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Install {name}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._pkg_action_worker,args=("install",name),daemon=True).start()

    def _on_pkg_remove(self,*_):
        name,status=self._get_selected_pkg()
        if not name: return
        if status not in ("installed","upgradable"):
            self._show_error("Not installed",f"{name} is not installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Remove {name}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._pkg_action_worker,args=("remove",name),daemon=True).start()

    def _pkg_action_worker(self,action,name):
        self._plog(f"Running apt {action} {name}…")
        try:
            proc=subprocess.Popen(["apt",action,"-y",name],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._plog(line.rstrip())
            proc.wait()
            if proc.returncode==0:
                self._plog(f"{action.capitalize()} complete.")
                self._pkgs_loaded=False; GLib.idle_add(self._load_installed_pkgs)
            else: self._plog(f"Failed (exit {proc.returncode}).")
        except Exception as e: self._plog(f"Error: {e}")

    # ────────────────────────────────────────────────────────
    # KERNELS
    # ────────────────────────────────────────────────────────
    def _on_refresh_kernels(self,*_):
        self._set_status("Scanning kernels…")
        threading.Thread(target=self._kernel_refresh_worker,daemon=True).start()

    def _kernel_get_grub_default(self):
        """Return the kernel version string that is saved as the GRUB default, or None."""
        saved_entry = None
        try:
            r = subprocess.run(["grub-editenv","list"], capture_output=True, text=True, timeout=5)
            for line in r.stdout.splitlines():
                if line.startswith("saved_entry="):
                    saved_entry = line.split("=",1)[1].strip(); break
        except Exception:
            pass
        if not saved_entry:
            try:
                for line in Path("/boot/grub/grubenv").read_text().splitlines():
                    if line.startswith("saved_entry="):
                        saved_entry = line.split("=",1)[1].strip(); break
            except Exception:
                pass
        if not saved_entry:
            return None
        # Entry looks like: gnulinux-advanced-UUID>gnulinux-6.8.0-49-generic-advanced-UUID
        # or just a plain kernel version string on some systems
        right = saved_entry.split(">")[-1]
        m = re.search(r'gnulinux-(.+?)-(?:advanced|recovery)-[0-9a-f-]+$', right)
        if m:
            return m.group(1)   # e.g. "6.8.0-49-generic"
        # Fallback: entry might just be the version string directly
        return right if right else None

    def _kernel_refresh_worker(self):
        try:
            cache=apt.Cache(); cache.open(None)
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            grub_default=self._kernel_get_grub_default()   # e.g. "6.8.0-49-generic"
            kernels=[]
            for name in sorted(cache.keys()):
                if not re.match(r'^linux-image-\d',name): continue
                pkg=cache[name]
                if not pkg.installed: continue
                inst=pkg.installed; is_run=(name==running_pkg)
                # Check if this is the GRUB default
                is_def = bool(grub_default and grub_default in name)
                if is_run and is_def:   status="Running (default)"
                elif is_run:            status="Running"
                elif is_def:            status="Installed (default)"
                else:                   status="Installed"
                kernels.append({"name":name,"version":inst.version,"status":status,
                                 "size":inst.installed_size,"is_running":is_run})
            seen={k["name"] for k in kernels}
            for name in sorted(cache.keys()):
                if name in seen: continue
                if not any(re.match(p,name) for p in [r'^linux-image-generic',r'^linux-image-lowlatency',
                                                        r'^linux-image-oem',r'^linux-image-virtual',r'^linux-image-hwe']): continue
                pkg=cache[name]
                if not pkg.candidate: continue
                kernels.append({"name":name,"version":pkg.candidate.version,"status":"Available",
                                 "size":pkg.candidate.size,"is_running":False})
            cache.close(); self._kernels=kernels; GLib.idle_add(self._populate_kernel_store)
        except Exception as e: self._klog(f"Error: {e}")
        finally: self._kernels_loaded=True; self._set_status("Ready")

    def _populate_kernel_store(self):
        self.kernel_store.clear()
        def _sort_key(k):
            s = k["status"]
            if "Running" in s:   return (0, k["name"])
            if "default" in s:   return (1, k["name"])
            if "Installed" in s: return (2, k["name"])
            return (3, k["name"])
        for k in sorted(self._kernels, key=_sort_key):
            self.kernel_store.append([k["is_running"],k["name"],k["version"],k["status"],human_size(k["size"]),k["size"]])

    def _get_selected_kernel(self):
        model,it=self.kernel_tree.get_selection().get_selected()
        if it is None: return None,None
        return model.get_value(it,COL_K_PACKAGE), model.get_value(it,COL_K_STATUS)

    def _on_kernel_install(self,*_):
        pkg,status=self._get_selected_kernel()
        if not pkg: self._show_error("No selection","Select a kernel package."); return
        if "Running" in status or "Installed" in status: self._show_error("Already installed",f"{pkg} is installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Install {pkg}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_op_worker,args=("install",pkg),daemon=True).start()

    def _on_kernel_remove(self,*_):
        pkg,status=self._get_selected_kernel()
        if not pkg: self._show_error("No selection","Select an installed kernel."); return
        if "Running" in status: self._show_error("Cannot remove","Cannot remove the running kernel."); return
        if "Installed" not in status: self._show_error("Not installed",f"{pkg} is not installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Remove {pkg}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_op_worker,args=("remove",pkg),daemon=True).start()

    def _kernel_op_worker(self,action,pkg):
        self._klog(f"apt {action} {pkg}…")
        try:
            proc=subprocess.Popen(["apt",action,"-y",pkg],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._klog(line.rstrip())
            proc.wait()
            if proc.returncode==0:
                self._klog("Done."); self._kernels_loaded=False; GLib.idle_add(self._on_refresh_kernels)
            else: self._klog(f"Failed (exit {proc.returncode}).")
        except Exception as e: self._klog(f"Error: {e}")

    def _on_kernel_set_default(self, *_):
        pkg, status = self._get_selected_kernel()
        if not pkg:
            self._show_error("No selection", "Select an installed kernel to set as default."); return
        if "Installed" not in status and "Running" not in status:
            self._show_error("Not installed", f"{pkg} is not installed — install it first."); return
        d = Gtk.MessageDialog(transient_for=self, flags=0,
            message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.YES_NO,
            text=f"Set default boot kernel?")
        d.format_secondary_text(
            f"Package: {pkg}\n\n"
            "GRUB will be updated to boot this kernel by default.\n"
            "The change takes effect on next reboot.")
        resp = d.run(); d.destroy()
        if resp != Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_set_default_worker, args=(pkg,), daemon=True).start()

    def _kernel_find_grub_entry(self, pkg_name):
        """Parse /boot/grub/grub.cfg and return the full GRUB entry ID for pkg_name."""
        m = re.match(r'^linux-image-(.+)$', pkg_name)
        if not m: return None
        kver = m.group(1)   # e.g. "6.8.0-49-generic"
        try:
            cfg = Path("/boot/grub/grub.cfg").read_text()
            # Find the advanced submenu ID
            sm = re.search(
                r"submenu\s+'[^']*'\s+\$menuentry_id_option\s+'(gnulinux-advanced-[^']+)'", cfg)
            if not sm:
                sm = re.search(
                    r"submenu\s+'[^']*Advanced[^']*'\s+\$menuentry_id_option\s+'([^']+)'",
                    cfg, re.IGNORECASE)
            submenu_id = sm.group(1) if sm else None
            # Find the specific kernel entry
            em = re.search(
                rf"menuentry\s+'[^']*{re.escape(kver)}[^']*'\s+\$menuentry_id_option\s+'([^']+)'",
                cfg)
            if not em: return None
            entry_id = em.group(1)
            return f"{submenu_id}>{entry_id}" if submenu_id else entry_id
        except Exception as e:
            self._klog(f"grub.cfg parse error: {e}"); return None

    def _kernel_set_default_worker(self, pkg_name):
        self._klog(f"Setting {pkg_name} as default boot kernel…")
        # 1. Ensure GRUB_DEFAULT=saved
        grub_def_file = Path("/etc/default/grub")
        try:
            text = grub_def_file.read_text()
            if "GRUB_DEFAULT=saved" not in text:
                new_text = re.sub(r'^GRUB_DEFAULT=.*$', 'GRUB_DEFAULT=saved',
                                  text, flags=re.MULTILINE)
                if new_text == text:
                    new_text += '\nGRUB_DEFAULT=saved\n'
                backup = write_text_with_backup(grub_def_file, new_text, label="grub-default")
                self._klog("Set GRUB_DEFAULT=saved in /etc/default/grub")
                if backup:
                    self._klog(f"Backup saved: {backup}")
                    self._klog(f"If update-grub fails, restore /etc/default/grub from: {backup}")
        except Exception as e:
            self._klog(f"Warning: could not update /etc/default/grub: {e}")
        # 2. Find and set the GRUB entry
        entry = self._kernel_find_grub_entry(pkg_name)
        if entry:
            self._klog(f"GRUB entry: {entry}")
            r = subprocess.run(["grub-set-default", entry],
                                capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                self._klog("grub-set-default: OK")
            else:
                self._klog(f"grub-set-default error: {r.stderr.strip()}")
        else:
            self._klog("Could not find GRUB menu entry in grub.cfg.")
            self._klog("Tip: run 'update-grub' manually first, then retry.")
        # 3. Always run update-grub to regenerate config
        self._klog("Running update-grub…")
        proc = subprocess.Popen(["update-grub"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in proc.stdout:
            if line.rstrip(): self._klog(line.rstrip())
        proc.wait()
        if proc.returncode == 0:
            self._klog("Done. New default will take effect on next reboot.")
        else:
            self._klog(f"update-grub exited {proc.returncode} — check output above.")
        # 4. Refresh the list to show updated (default) marker
        self._kernels_loaded = False
        GLib.idle_add(self._on_refresh_kernels)

    # ────────────────────────────────────────────────────────
    # REPOS
    # ────────────────────────────────────────────────────────
    def _refresh_repos(self):
        self._set_status("Reading repositories…")
        threading.Thread(target=self._repo_refresh_worker,daemon=True).start()

    def _repo_refresh_worker(self):
        try:
            repos=[]
            list_files=["/etc/apt/sources.list"]+sorted(glob.glob("/etc/apt/sources.list.d/*.list"))
            for fp in list_files:
                try: lines=Path(fp).read_text().splitlines()
                except Exception: continue
                for ln,line in enumerate(lines,1):
                    p=self._parse_repo_line(line,fp,ln)
                    if p: repos.append(p)
            # deb822 .sources files (Debian 12+ default, Trixie default)
            for fp in sorted(glob.glob("/etc/apt/sources.list.d/*.sources")):
                repos.extend(self._parse_deb822_file(fp))
            self._repos=repos; GLib.idle_add(self._populate_repo_store)
        except Exception: pass
        finally: self._repos_loaded=True; self._set_status("Ready")

    def _parse_repo_line(self,line,fp,ln):
        s=line.strip(); enabled=True
        if not s: return None
        if s.startswith('#'):
            inner=s[1:].strip()
            if not inner.startswith('deb'): return None
            enabled=False; s=inner
        if not s.startswith('deb'): return None
        if ' #' in s: s=s[:s.index(' #')].strip()
        parts=s.split()
        if len(parts)<3: return None
        idx=0; rtype=parts[idx]; idx+=1
        if idx<len(parts) and parts[idx].startswith('['):
            while idx<len(parts) and not parts[idx].endswith(']'): idx+=1
            idx+=1
        if idx+1>=len(parts): return None
        url=parts[idx]; idx+=1
        suite=parts[idx] if idx<len(parts) else ""; idx+=1
        comps=" ".join(parts[idx:]) if idx<len(parts) else ""
        return {"enabled":enabled,"type":rtype,"url":url,"suite":suite,"comps":comps,
                "file":fp,"line_num":ln,"fmt":"list"}

    def _parse_deb822_file(self,fp):
        """Parse a deb822 .sources file. Each stanza becomes one repo row;
        multi-URI / multi-Suite stanzas are shown collapsed (with a +N marker
        on URL) since enable/disable/remove operate on the whole stanza."""
        try: lines=Path(fp).read_text().splitlines()
        except Exception: return []
        stanzas=[]; cur={}; cur_start=None

        def flush(end_line):
            if cur and cur_start is not None:
                uris=cur.get("uris","").split()
                suites=cur.get("suites","").split()
                comps=cur.get("components","").split()
                types=cur.get("types","").split()
                en=cur.get("enabled","").strip().lower() not in ("no","false","0")
                # A stanza with no uris is malformed — skip
                if uris:
                    url=uris[0]+(f"  (+{len(uris)-1} more)" if len(uris)>1 else "")
                    stanzas.append({
                        "enabled":en,"type":" ".join(types) or "deb",
                        "url":url,"suite":" ".join(suites),"comps":" ".join(comps),
                        "file":fp,"line_num":cur_start,
                        "fmt":"sources","stanza_start":cur_start,"stanza_end":end_line})
            cur.clear()

        last_nonblank=0
        for i,line in enumerate(lines,1):
            stripped=line.strip()
            if not stripped:
                flush(last_nonblank); cur_start=None; continue
            if stripped.startswith('#'): continue
            if ':' in line:
                k,_,v=line.partition(':')
                cur[k.strip().lower()]=v.strip()
                if cur_start is None: cur_start=i
            last_nonblank=i
        flush(last_nonblank)
        return stanzas

    def _populate_repo_store(self):
        self.repo_store.clear()
        for r in self._repos:
            self.repo_store.append([r["enabled"],r["type"],r["url"],r["suite"],r["comps"],Path(r["file"]).name,r["line_num"]])

    def _on_repo_toggle(self,widget,path):
        row=self.repo_store[path]; enabled=row[COL_R_ENABLED]
        fname=row[COL_R_FILE]; lnum=row[COL_R_LINE_NUM]
        repo=next((r for r in self._repos if Path(r["file"]).name==fname and r["line_num"]==lnum),None)
        if not repo: return
        try:
            if repo.get("fmt")=="sources":
                self._deb822_set_enabled(repo, enable=enabled)  # enabled=current, flipping to !enabled
                self._repos_loaded=False; self._refresh_repos(); return
            lines=Path(repo["file"]).read_text().splitlines()
            i=repo["line_num"]-1
            if i>=len(lines): return
            new_line = ("# " + lines[i]) if enabled else lines[i].lstrip('#').lstrip()
            if new_line == lines[i]:
                self._plog(f"No repo change needed for {repo['file']}:{repo['line_num']}")
                return
            lines[i] = new_line
            backup = write_text_with_backup(repo["file"], "\n".join(lines)+"\n", label="apt-source")
            self._plog(f"Updated repo line in {repo['file']}:{repo['line_num']} (backup: {backup})")
            row[COL_R_ENABLED]=not enabled; repo["enabled"]=not enabled
        except Exception as e: self._show_error("Failed",str(e))

    def _deb822_set_enabled(self, repo, enable):
        """Flip stanza enabled state. enable=True means the stanza was previously
        enabled and we want to disable it (insert 'Enabled: no'); enable=False
        means it was disabled and we want to enable it (drop any Enabled: line)."""
        fp=Path(repo["file"])
        lines=fp.read_text().splitlines()
        s=repo["stanza_start"]-1; e=repo["stanza_end"]-1
        if s<0 or e>=len(lines) or s>e: return
        stanza=[l for l in lines[s:e+1]
                if not l.strip().lower().startswith("enabled:")]
        if enable:  # currently enabled → disable
            stanza.append("Enabled: no")
        new_text = "\n".join(lines[:s] + stanza + lines[e+1:]) + "\n"
        if new_text == fp.read_text():
            self._plog(f"No deb822 repo change needed for {fp}")
            return
        backup = write_text_with_backup(fp, new_text, label="apt-source")
        self._plog(f"Updated deb822 repo stanza in {fp} (backup: {backup})")

    def _on_repo_add(self,*_):
        d=Gtk.Dialog(title="Add Repository",transient_for=self,flags=0)
        d.add_buttons(Gtk.STOCK_CANCEL,Gtk.ResponseType.CANCEL,Gtk.STOCK_ADD,Gtk.ResponseType.OK)
        d.set_default_size(560,-1)
        box=d.get_content_area(); box.set_spacing(8); box.set_margin_start(12); box.set_margin_end(12)
        box.set_margin_top(12); box.set_margin_bottom(12)
        box.pack_start(Gtk.Label(label="Enter a full sources.list line:"),False,False,0)
        entry=Gtk.Entry()
        placeholder = ("deb http://deb.debian.org/debian trixie main contrib non-free-firmware"
                       if detect_distro()["id"]=="debian"
                       else "deb https://example.com/ubuntu focal main")
        entry.set_placeholder_text(placeholder)
        entry.set_width_chars(60); box.pack_start(entry,False,False,0)
        hint=Gtk.Label(label="Saved to /etc/apt/sources.list.d/mythix-custom.list")
        hint.get_style_context().add_class("security-desc"); hint.set_halign(Gtk.Align.START)
        box.pack_start(hint,False,False,0); d.show_all()
        resp=d.run(); text=entry.get_text().strip(); d.destroy()
        if resp!=Gtk.ResponseType.OK or not text: return
        if not text.startswith('deb'): self._show_error("Invalid","Line must start with 'deb'."); return
        custom=Path("/etc/apt/sources.list.d/mythix-custom.list")
        try:
            existing=custom.read_text() if custom.exists() else ""
            if text in existing: self._show_error("Exists","Already configured."); return
            backup = make_backup(custom, label="apt-source")
            with open(custom,"a") as f:
                if existing and not existing.endswith("\n"): f.write("\n")
                f.write(text+"\n")
            self._repos_loaded=False; self._refresh_repos()
        except Exception as e: self._show_error("Failed",str(e))

    def _on_repo_remove(self,*_):
        model,it=self.repo_tree.get_selection().get_selected()
        if it is None: self._show_error("No selection","Select a repo."); return
        fname=model.get_value(it,COL_R_FILE); lnum=model.get_value(it,COL_R_LINE_NUM)
        repo=next((r for r in self._repos if Path(r["file"]).name==fname and r["line_num"]==lnum),None)
        if not repo: return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text="Remove this repository?")
        d.format_secondary_text(f"URL: {repo['url']}\nFile: {repo['file']}")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        try:
            lines=Path(repo["file"]).read_text().splitlines()
            if repo.get("fmt")=="sources":
                s=repo["stanza_start"]-1; e=repo["stanza_end"]-1
                if 0<=s<=e<len(lines): del lines[s:e+1]
                # collapse consecutive blank lines left behind
                while s<len(lines) and not lines[s].strip(): del lines[s]
            else:
                i=repo["line_num"]-1
                if 0<=i<len(lines): del lines[i]
            write_text_with_backup(repo["file"], "\n".join(lines)+"\n", label="apt-source")
            self._repos_loaded=False; self._refresh_repos()
        except Exception as e: self._show_error("Failed",str(e))

    # ────────────────────────────────────────────────────────
    # SECURITY
    # ────────────────────────────────────────────────────────
    def _refresh_security_status(self):
        threading.Thread(target=self._security_check_worker,daemon=True).start()

    def _security_check_worker(self):
        checks={"ufw":self._check_ufw,"auto_security_updates":self._check_unattended_upgrades,
                "fail2ban":self._check_fail2ban,"ssh_root":self._check_ssh_root,
                "ssh_password":self._check_ssh_password,"usb_storage":self._check_usb_storage,
                "core_dumps":self._check_core_dumps,"sysrq":self._check_sysrq}
        for key,fn in checks.items():
            try: result=fn()
            except Exception as e: result={"status":"error","active":False}
            GLib.idle_add(self._update_security_row,key,result)

    def _update_security_row(self,key,result):
        w=self._security_widgets.get(key)
        if not w: return
        sw=w["switch"]; lbl=w["status_label"]
        status=result.get("status","unknown"); active=result.get("active",False)
        self._security_updating=True; sw.set_state(active); sw.set_active(active); self._security_updating=False
        for cls in ("status-active","status-inactive","status-notinstalled","status-unknown"):
            lbl.get_style_context().remove_class(cls)
        mapping={"active":("Active","status-active"),"inactive":("Inactive","status-inactive"),
                 "not_installed":("Not Installed","status-notinstalled")}
        txt,cls=mapping.get(status,("Unknown","status-unknown"))
        lbl.set_text(txt); lbl.get_style_context().add_class(cls)
        sw.set_sensitive(status!="not_installed")

    def _check_ufw(self):
        if subprocess.run(["which","ufw"],capture_output=True).returncode!=0: return {"status":"not_installed","active":False}
        r=subprocess.run(["ufw","status"],capture_output=True,text=True,timeout=10)
        a="Status: active" in r.stdout; return {"status":"active" if a else "inactive","active":a}

    def _check_unattended_upgrades(self):
        if subprocess.run(["dpkg","-s","unattended-upgrades"],capture_output=True).returncode!=0:
            return {"status":"not_installed","active":False}
        conf=Path("/etc/apt/apt.conf.d/20auto-upgrades")
        if conf.exists() and 'Unattended-Upgrade "1"' in conf.read_text():
            return {"status":"active","active":True}
        return {"status":"inactive","active":False}

    def _check_fail2ban(self):
        if subprocess.run(["which","fail2ban-client"],capture_output=True).returncode!=0: return {"status":"not_installed","active":False}
        r=subprocess.run(["systemctl","is-active","fail2ban"],capture_output=True,text=True,timeout=10)
        a=r.stdout.strip()=="active"; return {"status":"active" if a else "inactive","active":a}

    def _check_ssh_root(self):
        sshd=Path("/etc/ssh/sshd_config")
        if not sshd.exists(): return {"status":"not_installed","active":False}
        for line in sshd.read_text().splitlines():
            line=line.strip()
            if line.startswith("#") or not line.lower().startswith("permitrootlogin"): continue
            v=line.split(None,1)[1].strip().lower()
            b=v in ("no","prohibit-password","forced-commands-only")
            return {"status":"active" if b else "inactive","active":b}
        return {"status":"active","active":True}

    def _check_ssh_password(self):
        sshd=Path("/etc/ssh/sshd_config")
        if not sshd.exists(): return {"status":"not_installed","active":False}
        for line in sshd.read_text().splitlines():
            line=line.strip()
            if line.startswith("#") or not line.lower().startswith("passwordauthentication"): continue
            k=line.split(None,1)[1].strip().lower()=="no"
            return {"status":"active" if k else "inactive","active":k}
        return {"status":"inactive","active":False}

    def _check_usb_storage(self):
        b=Path("/etc/modprobe.d/blacklist-usb-storage.conf")
        if b.exists() and "blacklist usb-storage" in b.read_text(): return {"status":"active","active":True}
        return {"status":"inactive","active":False}

    def _check_core_dumps(self):
        lf=Path("/etc/security/limits.conf")
        if lf.exists():
            for line in lf.read_text().splitlines():
                line=line.strip()
                if not line.startswith("#") and "hard" in line and "core" in line and "0" in line:
                    return {"status":"active","active":True}
        try:
            r=subprocess.run(["sysctl","-n","kernel.core_pattern"],capture_output=True,text=True,timeout=5)
            if r.stdout.strip()=="/dev/null": return {"status":"active","active":True}
        except Exception: pass
        return {"status":"inactive","active":False}

    def _check_sysrq(self):
        try:
            v=int(Path("/proc/sys/kernel/sysrq").read_text().strip())
            r=v in (0,176); return {"status":"active" if r else "inactive","active":r}
        except Exception: return {"status":"unknown","active":False}

    def _on_security_toggle(self,switch,state,key):
        if self._security_updating: return True
        toggles={"ufw":self._toggle_ufw,"auto_security_updates":self._toggle_unattended_upgrades,
                 "fail2ban":self._toggle_fail2ban,"ssh_root":self._toggle_ssh_root,
                 "ssh_password":self._toggle_ssh_password,"usb_storage":self._toggle_usb_storage,
                 "core_dumps":self._toggle_core_dumps,"sysrq":self._toggle_sysrq}
        fn=toggles.get(key)
        if not fn: return True
        switch.set_sensitive(False); self._security_widgets[key]["status_label"].set_text("Applying…")
        checks={"ufw":self._check_ufw,"auto_security_updates":self._check_unattended_upgrades,
                "fail2ban":self._check_fail2ban,"ssh_root":self._check_ssh_root,
                "ssh_password":self._check_ssh_password,"usb_storage":self._check_usb_storage,
                "core_dumps":self._check_core_dumps,"sysrq":self._check_sysrq}
        def _do():
            try: fn(state)
            except Exception as e: GLib.idle_add(self._show_error,f"Failed to toggle {key}",str(e))
            finally:
                try: result=checks[key]()
                except Exception: result={"status":"unknown","active":False}
                GLib.idle_add(self._update_security_row,key,result)
                GLib.idle_add(switch.set_sensitive,True)
        threading.Thread(target=_do,daemon=True).start(); return True

    def _toggle_ufw(self,e):
        subprocess.run(["ufw","--force","enable"] if e else ["ufw","disable"],timeout=30,check=True)

    def _toggle_unattended_upgrades(self,e):
        if subprocess.run(["dpkg","-s","unattended-upgrades"],capture_output=True).returncode!=0:
            subprocess.run(["apt","install","-y","unattended-upgrades"],timeout=120,check=True)
        write_text_with_backup(Path("/etc/apt/apt.conf.d/20auto-upgrades"),
            'APT::Periodic::Update-Package-Lists "1";\n'
            f'APT::Periodic::Unattended-Upgrade "{"1" if e else "0"}";\n', label="apt-config")

    def _toggle_fail2ban(self,e):
        if subprocess.run(["which","fail2ban-client"],capture_output=True).returncode!=0:
            subprocess.run(["apt","install","-y","fail2ban"],timeout=120,check=True)
        subprocess.run(["systemctl","enable" if e else "disable","--now","fail2ban"],timeout=30,check=True)

    def _edit_sshd(self,key,val):
        sshd=Path("/etc/ssh/sshd_config")
        original=sshd.read_text()
        lines=original.splitlines(); found=False; out=[]
        for line in lines:
            s=line.strip()
            if s.lower().startswith(key.lower()) or s.lower().startswith(f"#{key.lower()}"):
                out.append(f"{key} {val}"); found=True
            else: out.append(line)
        if not found: out.append(f"{key} {val}")
        backup = write_text_with_backup(sshd, "\n".join(out)+"\n", label="sshd")
        try:
            subprocess.run(["sshd","-t"], capture_output=True, text=True, timeout=10, check=True)
        except Exception as e:
            atomic_write_text(sshd, original)
            raise RuntimeError(f"sshd validation failed; restored original config (backup: {backup}): {e}")
        subprocess.run(["systemctl","restart","sshd"],timeout=30)

    def _toggle_ssh_root(self,e): self._edit_sshd("PermitRootLogin","no" if e else "yes")
    def _toggle_ssh_password(self,e): self._edit_sshd("PasswordAuthentication","no" if e else "yes")

    def _toggle_usb_storage(self,e):
        b=Path("/etc/modprobe.d/blacklist-usb-storage.conf")
        if e:
            write_text_with_backup(b, "# Mythix System Manager\nblacklist usb-storage\n", label="modprobe")
            subprocess.run(["modprobe","-r","usb-storage"],capture_output=True,timeout=10)
        else:
            remove_file_with_backup(b, label="modprobe")
            subprocess.run(["modprobe","usb-storage"],capture_output=True,timeout=10)

    def _toggle_core_dumps(self,e):
        lf=Path("/etc/security/limits.conf"); sc=Path("/etc/sysctl.d/99-mythix-no-coredump.conf")
        if e:
            text=lf.read_text() if lf.exists() else ""
            if "* hard core 0" not in text:
                with open(lf,"a") as f: f.write("\n# Mythix System Manager\n* hard core 0\n")
            write_text_with_backup(sc, "# Mythix System Manager\nkernel.core_pattern=/dev/null\n", label="sysctl")
            subprocess.run(["sysctl","-p",str(sc)],timeout=10)
        else:
            if lf.exists():
                lines=[l for l in lf.read_text().splitlines() if "Mythix System Manager" not in l and l.strip()!="* hard core 0"]
                write_text_with_backup(lf, "\n".join(lines)+"\n", label="limits")
            remove_file_with_backup(sc, label="sysctl")
            subprocess.run(["sysctl","-w","kernel.core_pattern=|/usr/share/apport/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -- %E"],capture_output=True,timeout=10)

    def _toggle_sysrq(self,e):
        sc=Path("/etc/sysctl.d/99-mythix-sysrq.conf")
        if e:
            write_text_with_backup(sc, "# Mythix System Manager\nkernel.sysrq=176\n", label="sysctl")
            subprocess.run(["sysctl","-p",str(sc)],timeout=10)
        else:
            remove_file_with_backup(sc, label="sysctl")
            subprocess.run(["sysctl","-w","kernel.sysrq=1"],capture_output=True,timeout=10)

    # ────────────────────────────────────────────────────────
    # CLEANUP
    # ────────────────────────────────────────────────────────
    def _refresh_cleanup_sizes(self,*_):
        threading.Thread(target=self._cleanup_size_worker,daemon=True).start()

    def _dir_size(self,path):
        try:
            p=safe_expand_path(path)
            if not p.exists(): return 0
            total=0
            for f in p.rglob("*"):
                try: total+=f.stat().st_size
                except Exception: pass
            return total
        except Exception: return 0

    def _cleanup_size_worker(self):
        sizes={}
        sizes["apt_cache"]=self._dir_size("/var/cache/apt/archives/")
        try:
            r=subprocess.run(["apt","autoremove","--dry-run"],capture_output=True,text=True,timeout=30)
            count=len([l for l in r.stdout.splitlines() if l.startswith("  ") and not l.startswith("   ")])
            sizes["apt_orphans"]=count
        except Exception: sizes["apt_orphans"]=-1
        try:
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            cache=apt.Cache(); cache.open(None)
            old=[n for n in cache.keys() if re.match(r'^linux-image-\d',n) and cache[n].installed and n!=running_pkg]
            sizes["old_kernels"]=len(old); cache.close()
        except Exception: sizes["old_kernels"]=0
        sizes["thumbnails"]=self._dir_size("~/.cache/thumbnails/")
        sizes["trash"]=self._dir_size("~/.local/share/Trash/")
        GLib.idle_add(self._update_cleanup_sizes,sizes)

    def _update_cleanup_sizes(self,sizes):
        fmt={"apt_cache":human_size(sizes.get("apt_cache",0)),
             "apt_orphans":f"{sizes.get('apt_orphans',0)} pkgs",
             "old_kernels":f"{sizes.get('old_kernels',0)} kernels",
             "thumbnails":human_size(sizes.get("thumbnails",0)),
             "trash":human_size(sizes.get("trash",0))}
        for key,val in fmt.items():
            if key in self._cleanup_rows:
                self._cleanup_rows[key]["size_lbl"].set_text(val)

    def _do_apt_clean(self):
        threading.Thread(target=self._run_cleanup_cmd,
            args=(["apt","clean"],["apt","autoclean"],"APT cache cleared."),daemon=True).start()

    def _do_apt_autoremove(self):
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text="Remove orphaned packages?")
        d.format_secondary_text("Runs apt autoremove -y")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._run_cleanup_cmd,args=(["apt","autoremove","-y"],None,"Orphaned packages removed."),daemon=True).start()

    def _do_remove_old_kernels(self):
        try:
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            cache=apt.Cache(); cache.open(None)
            old=[n for n in cache.keys() if re.match(r'^linux-image-\d',n) and cache[n].installed and n!=running_pkg]
            cache.close()
        except Exception as e: self._clog(f"Error scanning kernels: {e}"); return
        if not old: self._clog("No old kernels to remove."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Remove {len(old)} old kernel(s)?")
        d.format_secondary_text("\n".join(old[:10])+(f"\n+{len(old)-10} more" if len(old)>10 else ""))
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._run_cleanup_cmd,args=(["apt","remove","-y"]+old,None,"Old kernels removed."),daemon=True).start()

    def _do_clean_thumbnails(self):
        try:
            p=Path.home()/".cache"/"thumbnails"
            if p.exists():
                shutil.rmtree(p)
                p.mkdir(parents=True,exist_ok=True)
                self._clog(f"Thumbnail cache cleared: {p}")
            else:
                self._clog(f"Thumbnail cache not present: {p}")
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

    def _do_empty_trash(self):
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text="Empty trash?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        try:
            p=Path.home()/".local"/"share"/"Trash"
            removed=[]
            for sub in ("files","info","expunged"):
                sp=p/sub
                if sp.exists():
                    shutil.rmtree(sp)
                    sp.mkdir(exist_ok=True)
                    removed.append(str(sp))
            if removed:
                self._clog("Trash emptied: " + ", ".join(removed))
            else:
                self._clog(f"Trash already empty or missing: {p}")
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

    def _run_cleanup_cmd(self,cmd1,cmd2,msg):
        self._clog(f"Running {' '.join(cmd1)}…")
        try:
            proc=subprocess.Popen(cmd1,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._clog(line.rstrip())
            proc.wait()
            if cmd2:
                self._clog(f"Running {' '.join(cmd2)}…")
                proc2=subprocess.Popen(cmd2,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                for line in proc2.stdout:
                    if line.rstrip(): self._clog(line.rstrip())
                proc2.wait()
            self._clog(msg)
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

    # ────────────────────────────────────────────────────────
    # ANTIVIRUS
    # ────────────────────────────────────────────────────────
    def _av_check_installed(self):
        has=subprocess.run(["which","clamscan"],capture_output=True).returncode==0
        self.av_status_lbl.set_text("ClamAV: ready" if has else "ClamAV: not installed — click Scan to install")
        self.btn_av_scan.set_sensitive(True)

    def _on_av_pick_path(self,*_):
        d=Gtk.FileChooserDialog(title="Select Scan Path",transient_for=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER)
        d.add_buttons(Gtk.STOCK_CANCEL,Gtk.ResponseType.CANCEL,Gtk.STOCK_OPEN,Gtk.ResponseType.OK)
        if d.run()==Gtk.ResponseType.OK:
            self._av_scan_path=Path(d.get_filename())
            self.btn_av_path.set_label(str(self._av_scan_path))
        d.destroy()

    def _on_av_update(self,*_):
        threading.Thread(target=self._av_update_worker,daemon=True).start()

    def _av_update_worker(self):
        self._avlog("Updating virus definitions (freshclam)…")
        if subprocess.run(["which","freshclam"],capture_output=True).returncode!=0:
            self._avlog("Installing clamav…")
            subprocess.run(["apt","install","-y","clamav","clamav-daemon"],timeout=120)
        proc=subprocess.Popen(["freshclam"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        for line in proc.stdout:
            if line.rstrip(): self._avlog(line.rstrip())
        proc.wait()
        self._avlog("Definitions updated." if proc.returncode==0 else f"freshclam exited {proc.returncode}.")
        GLib.idle_add(self._av_check_installed)

    def _on_av_scan(self,*_):
        if subprocess.run(["which","clamscan"],capture_output=True).returncode!=0:
            d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                                 buttons=Gtk.ButtonsType.YES_NO,text="ClamAV not installed. Install it now?")
            resp=d.run(); d.destroy()
            if resp!=Gtk.ResponseType.YES: return
            threading.Thread(target=self._av_install_then_scan,daemon=True).start()
            return
        threading.Thread(target=self._av_scan_worker,daemon=True).start()

    def _av_install_then_scan(self):
        self._avlog("Installing clamav…")
        r=subprocess.run(["apt","install","-y","clamav","clamav-daemon"],timeout=120,capture_output=True,text=True)
        if r.returncode==0:
            self._avlog("ClamAV installed.")
            GLib.idle_add(self._av_check_installed)
            self._av_scan_worker()
        else: self._avlog(f"Install failed: {r.stderr.strip()}")

    def _av_scan_worker(self):
        GLib.idle_add(self.av_store.clear)
        path=str(self._av_scan_path)
        self._avlog(f"Scanning {path}…")
        GLib.idle_add(self.av_status_lbl.set_text,"ClamAV: scanning…")
        infected=0
        try:
            proc=subprocess.Popen(
                ["clamscan","--recursive","--infected","--no-summary",path],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                line=line.rstrip()
                if not line: continue
                self._avlog(line)
                m=re.match(r'^(.+):\s+(.+)\s+FOUND$',line)
                if m: infected+=1; GLib.idle_add(self.av_store.append,[m.group(1),m.group(2)])
            proc.wait()
            summary=f"Scan complete — {infected} threat(s) found." if infected else "Scan complete — no threats found."
            self._avlog(summary); GLib.idle_add(self.av_status_lbl.set_text,f"ClamAV: {summary}")
        except Exception as e:
            self._avlog(f"Error: {e}"); GLib.idle_add(self.av_status_lbl.set_text,"ClamAV: error")

    # ────────────────────────────────────────────────────────
    # STARTUP MANAGER
    # ────────────────────────────────────────────────────────
    def _refresh_startup(self):
        threading.Thread(target=self._startup_worker,daemon=True).start()

    def _startup_worker(self):
        entries=[]
        # systemd user services
        try:
            r=subprocess.run(["systemctl","--user","list-unit-files","--type=service","--no-pager","--no-legend"],
                capture_output=True,text=True,timeout=15)
            for line in r.stdout.splitlines():
                parts=line.split(); name=parts[0] if parts else ""; state=parts[1] if len(parts)>1 else ""
                if not name.endswith(".service"): continue
                enabled=state in ("enabled","enabled-runtime","static")
                r2=subprocess.run(["systemctl","--user","show",name,"--property=Description"],
                    capture_output=True,text=True,timeout=5)
                desc=r2.stdout.strip().replace("Description=","") if r2.returncode==0 else ""
                entries.append([enabled,name.replace(".service",""),"systemd user",desc,name])
        except Exception: pass
        # XDG autostart
        dirs=[Path.home()/".config"/"autostart",Path("/etc/xdg/autostart")]
        for d in dirs:
            if not d.exists(): continue
            for desktop in d.glob("*.desktop"):
                try:
                    text=desktop.read_text(); hidden=False; name=""; desc=""
                    for line in text.splitlines():
                        if line.startswith("Hidden=true"): hidden=True
                        elif line.startswith("Name=") and not name: name=line[5:]
                        elif line.startswith("Comment=") and not desc: desc=line[8:]
                    enabled=not hidden
                    entries.append([enabled,name or desktop.stem,"XDG autostart",desc,str(desktop)])
                except Exception: pass
        GLib.idle_add(self._populate_startup_store,entries)
        self._startup_loaded=True

    def _populate_startup_store(self,entries):
        self.startup_store.clear()
        for e in sorted(entries,key=lambda x:(x[COL_ST_TYPE],x[COL_ST_NAME])):
            self.startup_store.append(e)

    def _on_startup_toggle(self,widget,path):
        row=self.startup_store[path]; enabled=row[COL_ST_ENABLED]
        name=row[COL_ST_NAME]; stype=row[COL_ST_TYPE]; fpath=row[COL_ST_FILE]
        def _do():
            try:
                if stype=="systemd user":
                    cmd="disable" if enabled else "enable"
                    subprocess.run(["systemctl","--user",cmd,name+".service"],timeout=15,check=True)
                else:
                    p=Path(fpath)
                    if not p.exists(): return
                    text=p.read_text(); lines=text.splitlines(); out=[]
                    found=False
                    for line in lines:
                        if line.startswith("Hidden="):
                            new_line = "Hidden=true" if enabled else "Hidden=false"
                            if line != new_line:
                                out.append(new_line)
                                found=True
                            else:
                                out.append(line)
                                found=True
                        else: out.append(line)
                    if not found:
                        out.append("Hidden=true" if enabled else "Hidden=false")
                    new_text = "\n".join(out)+"\n"
                    if new_text != text:
                        backup = write_text_with_backup(p, new_text, label="autostart")
                        self._plog(f"Updated autostart entry {p} (backup: {backup})")
                    else:
                        self._plog(f"No autostart change needed for {p}")
                GLib.idle_add(lambda: row.__setitem__(COL_ST_ENABLED, not enabled))
            except Exception as e: GLib.idle_add(self._show_error,"Toggle failed",str(e))
        threading.Thread(target=_do,daemon=True).start()

    # ────────────────────────────────────────────────────────
    # LOGS
    # ────────────────────────────────────────────────────────
    def _on_log_fetch(self,*_):
        threading.Thread(target=self._log_fetch_worker,daemon=True).start()

    def _log_fetch_worker(self):
        unit=self.log_unit_entry.get_text().strip()
        sev=self.log_sev_combo.get_active_text()
        lines=self.log_lines_combo.get_active_text() or "200"
        cmd=["journalctl","--no-pager","-n",lines,"--output=short"]
        if unit: cmd+=["-u",unit]
        if sev and sev!="All": cmd+=["-p",sev]
        try:
            r=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
            GLib.idle_add(self.jlog_buf.set_text,r.stdout if r.returncode==0 else r.stderr)
            GLib.idle_add(self.jlog_view.scroll_to_iter,self.jlog_buf.get_end_iter(),0,False,0,0)
        except Exception as e: GLib.idle_add(self.jlog_buf.set_text,f"Error: {e}")

    def _on_log_export(self,*_):
        text=self.jlog_buf.get_text(self.jlog_buf.get_start_iter(),self.jlog_buf.get_end_iter(),True)
        if not text.strip(): return
        d=Gtk.FileChooserDialog(title="Export Log",transient_for=self,action=Gtk.FileChooserAction.SAVE)
        d.add_buttons(Gtk.STOCK_CANCEL,Gtk.ResponseType.CANCEL,Gtk.STOCK_SAVE,Gtk.ResponseType.OK)
        d.set_current_name(f"journal-{datetime.now():%Y%m%d-%H%M%S}.log")
        d.set_do_overwrite_confirmation(True)
        if d.run()==Gtk.ResponseType.OK:
            Path(d.get_filename()).write_text(text)
        d.destroy()

    def _on_log_auto_toggle(self,chk):
        if chk.get_active():
            self._on_log_fetch()
            self._log_auto_timer=GLib.timeout_add_seconds(5,self._log_auto_tick)
        else:
            if self._log_auto_timer: GLib.source_remove(self._log_auto_timer); self._log_auto_timer=None

    def _log_auto_tick(self):
        self._on_log_fetch()
        return True

    # ────────────────────────────────────────────────────────
    # SYSTEM INFO
    # ────────────────────────────────────────────────────────
    def _start_sysinfo_timer(self):
        if self._sysinfo_timer is None:
            self._refresh_sysinfo()
            self._sysinfo_timer=GLib.timeout_add_seconds(5,self._refresh_sysinfo)

    def _stop_sysinfo_timer(self):
        if self._sysinfo_timer:
            GLib.source_remove(self._sysinfo_timer); self._sysinfo_timer=None

    def _refresh_sysinfo(self,*_):
        threading.Thread(target=self._sysinfo_worker,daemon=True).start()
        return True

    def _sysinfo_worker(self):
        info={}
        try:
            u=platform.uname()
            info["hostname"]=u.node
            info["kernel"]=u.release
            try:
                distro=Path("/etc/os-release").read_text()
                for line in distro.splitlines():
                    if line.startswith("PRETTY_NAME="):
                        info["distro"]=line[12:].strip().strip('"'); break
            except Exception: info["distro"]=platform.system()
            try:
                uptime_s=float(Path("/proc/uptime").read_text().split()[0])
                d,r=divmod(int(uptime_s),86400); h,r=divmod(r,3600); m=r//60
                info["uptime"]={"d":d,"h":h,"m":m}
                info["uptime"]=f"{d}d {h}h {m}m" if d else f"{h}h {m}m"
            except Exception: info["uptime"]="?"
            try:
                cpu_lines=[l for l in Path("/proc/cpuinfo").read_text().splitlines() if "model name" in l]
                info["cpu_model"]=cpu_lines[0].split(":")[1].strip() if cpu_lines else "?"
                cores=len([l for l in Path("/proc/cpuinfo").read_text().splitlines() if l.startswith("processor")])
                info["cpu_cores"]=str(cores)
            except Exception: info["cpu_model"]="?"; info["cpu_cores"]="?"
            try:
                gpus=[]
                for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
                    prod = card / "device" / "product_name"
                    label = card / "device" / "label"
                    uevent = card / "device" / "uevent"
                    name = None
                    if prod.exists(): name = prod.read_text().strip()
                    elif label.exists(): name = label.read_text().strip()
                    if not name and uevent.exists():
                        for line in uevent.read_text().splitlines():
                            if line.startswith("PCI_NAME="): name = line.split("=",1)[1]; break
                    if not name:
                        r = subprocess.run(["lspci","-mm"], capture_output=True, text=True, timeout=5)
                        for line in r.stdout.splitlines():
                            if "VGA" in line or "3D" in line or "Display" in line:
                                parts = line.split('"')
                                if len(parts) >= 6: name = f"{parts[3]} {parts[5]}"; break
                    if name and name not in gpus: gpus.append(name)
                info["gpu"] = " | ".join(gpus) if gpus else "?"
            except Exception: info["gpu"] = "?"
            try:
                la = Path("/proc/loadavg").read_text().split()[:3]
                info["load"] = "  ".join(la)
            except Exception: info["load"] = "?"
            try:
                procs = len([d for d in Path("/proc").iterdir() if d.name.isdigit()])
                info["processes"] = str(procs)
            except Exception: info["processes"] = "?"
            try:
                s1=Path("/proc/stat").read_text().splitlines()[0].split()[1:]
                time.sleep(0.2)
                s2=Path("/proc/stat").read_text().splitlines()[0].split()[1:]
                d=[int(b)-int(a) for a,b in zip(s1,s2)]
                idle=d[3]; total=sum(d)
                pct=100*(total-idle)/total if total else 0
                info["cpu_usage"]=f"{pct:.1f}%"
            except Exception: info["cpu_usage"]="?"
            try:
                mem={}
                for line in Path("/proc/meminfo").read_text().splitlines():
                    k,v=line.split(":"); mem[k.strip()]=int(v.strip().split()[0])
                total_mb=mem["MemTotal"]/1024; avail_mb=mem.get("MemAvailable",mem.get("MemFree",0))/1024
                used_mb=total_mb-avail_mb
                info["ram"]=f"{used_mb:.0f} MB / {total_mb:.0f} MB ({100*used_mb/total_mb:.0f}%)"
                if "SwapTotal" in mem and mem["SwapTotal"]>0:
                    stotal=mem["SwapTotal"]/1024; sused=(mem["SwapTotal"]-mem.get("SwapFree",0))/1024
                    info["swap"]=f"{sused:.0f} MB / {stotal:.0f} MB"
                else: info["swap"]="None"
            except Exception: info["ram"]="?"; info["swap"]="?"
            try:
                r=subprocess.run(["df","-h","--output=target,size,used,avail,pcent","-x","tmpfs","-x","devtmpfs"],
                    capture_output=True,text=True,timeout=5)
                disks=[line.split() for line in r.stdout.splitlines()[1:] if line]
                info["_disks"]=disks
            except Exception: info["_disks"]=[]
        except Exception as e: info["_error"]=str(e)
        GLib.idle_add(self._update_sysinfo,info)

    def _update_sysinfo(self,info):
        for key,lbl in self._si_labels.items():
            lbl.set_text(info.get(key,"—"))
        # rebuild disk box
        for child in self._si_disk_box.get_children():
            self._si_disk_box.remove(child)
        for disk in info.get("_disks",[]):
            if len(disk)<5: continue
            mnt,size,used,avail,pct=disk[0],disk[1],disk[2],disk[3],disk[4]
            row=Gtk.Box(spacing=12)
            ml=Gtk.Label(label=mnt); ml.set_width_chars(20); ml.set_halign(Gtk.Align.START)
            ml.get_style_context().add_class("sysinfo-key")
            bar=Gtk.ProgressBar()
            try: bar.set_fraction(min(1.0,int(pct.rstrip("%"))/100))
            except Exception: bar.set_fraction(0)
            bar.set_show_text(True); bar.set_text(f"{used} / {size} ({pct})")
            bar.set_hexpand(True)
            row.pack_start(ml,False,False,0); row.pack_start(bar,True,True,0)
            self._si_disk_box.pack_start(row,False,False,0)
        self._si_disk_box.show_all()

    # ────────────────────────────────────────────────────────
    # DISTRO UPGRADE
    # ────────────────────────────────────────────────────────
    def _build_upgrade_tab(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        # ── Version banner ────────────────────────────────────
        banner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        banner.set_margin_start(20); banner.set_margin_end(20)
        banner.set_margin_top(16);   banner.set_margin_bottom(12)

        self.upg_version_lbl = Gtk.Label(label="Checking…")
        self.upg_version_lbl.get_style_context().add_class("sysinfo-val")
        attr = Pango.AttrList()
        attr.insert(Pango.attr_scale_new(1.6))
        attr.insert(Pango.attr_weight_new(Pango.Weight.BOLD))
        self.upg_version_lbl.set_attributes(attr)
        self.upg_version_lbl.set_halign(Gtk.Align.START)

        self.upg_status_lbl = Gtk.Label(label="")
        self.upg_status_lbl.set_halign(Gtk.Align.START)
        self.upg_status_lbl.get_style_context().add_class("security-desc")
        self.upg_status_lbl.set_line_wrap(True)

        banner.pack_start(self.upg_version_lbl, False, False, 0)
        banner.pack_start(self.upg_status_lbl,  False, False, 0)
        vbox.pack_start(banner, False, False, 0)
        vbox.pack_start(Gtk.Separator(), False, False, 0)

        # ── Warning box ───────────────────────────────────────
        warn_box = Gtk.Box(spacing=10)
        warn_box.set_margin_start(20); warn_box.set_margin_end(20)
        warn_box.set_margin_top(10);   warn_box.set_margin_bottom(4)
        warn_icon = Gtk.Image.new_from_icon_name("dialog-warning-symbolic", Gtk.IconSize.LARGE_TOOLBAR)
        warn_lbl  = Gtk.Label()
        warn_lbl.set_markup(
            "<b>Before upgrading:</b> create a system snapshot (Timeshift), ensure all current "
            "updates are installed, and close other applications. A major upgrade cannot be interrupted.")
        warn_lbl.set_line_wrap(True); warn_lbl.set_halign(Gtk.Align.START)
        warn_lbl.get_style_context().add_class("security-desc")
        warn_box.pack_start(warn_icon, False, False, 0)
        warn_box.pack_start(warn_lbl,  True,  True,  0)
        vbox.pack_start(warn_box, False, False, 0)

        # ── Action buttons ────────────────────────────────────
        btn_bar = Gtk.Box(spacing=8)
        btn_bar.set_margin_start(20); btn_bar.set_margin_end(20)
        btn_bar.set_margin_top(12);   btn_bar.set_margin_bottom(8)

        self.btn_upg_check    = self._mkbtn("view-refresh-symbolic",
                                            "Check for Upgrade", self._on_upg_check)
        self.btn_upg_download = self._mkbtn("folder-download-symbolic",
                                            "Download Upgrade",  self._on_upg_download)
        self.btn_upg_go       = self._mkbtn("system-run-symbolic",
                                            "Start Upgrade",     self._on_upg_go)
        self.btn_upg_simulate = self._mkbtn("document-edit-symbolic",
                                            "Simulate (dry run)", self._on_upg_simulate)

        self.btn_upg_download.set_sensitive(False)
        self.btn_upg_go.set_sensitive(False)
        self.btn_upg_go.get_style_context().add_class("btn-warn")

        for b in (self.btn_upg_check, self.btn_upg_simulate,
                  self.btn_upg_download, self.btn_upg_go):
            btn_bar.pack_start(b, False, False, 0)

        # mintupgrade availability label
        self.upg_tool_lbl = Gtk.Label(label="")
        self.upg_tool_lbl.get_style_context().add_class("cleanup-size")
        self.upg_tool_lbl.set_halign(Gtk.Align.END)
        btn_bar.pack_end(self.upg_tool_lbl, False, False, 0)
        vbox.pack_start(btn_bar, False, False, 0)
        vbox.pack_start(Gtk.Separator(), False, False, 0)

        # ── Log output ────────────────────────────────────────
        sw = Gtk.ScrolledWindow()
        self.upg_log_buf  = Gtk.TextBuffer()
        self.upg_log_view = Gtk.TextView(buffer=self.upg_log_buf)
        self.upg_log_view.set_editable(False)
        self.upg_log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.upg_log_view.get_style_context().add_class("log-view")
        sw.add(self.upg_log_view)
        vbox.pack_start(sw, True, True, 0)

        return vbox

    # ── version detection ─────────────────────────────────────
    def _upgrade_check_version(self, *_):
        threading.Thread(target=self._upg_version_worker, daemon=True).start()

    def _upg_version_worker(self):
        info = detect_distro()
        pretty = info["pretty"] or "Unknown distro"

        if info["id"] == "linuxmint":
            has_tool = subprocess.run(
                ["which", "mintupgrade"], capture_output=True).returncode == 0
            tool_text = "mintupgrade: available" if has_tool else "mintupgrade: not installed"
            if has_tool:
                status_text = (
                    "mintupgrade is installed. Use Check to see if a new release is available.")
            else:
                status_text = (
                    "mintupgrade is not installed. Click Check to install it and look for upgrades.")

        elif info["id"] == "debian":
            nxt = DEBIAN_NEXT_CODENAME.get(info["codename"])
            if nxt:
                tool_text = f"upgrade target: {nxt}"
                status_text = (
                    f"You can upgrade from {info['codename']} to {nxt}. "
                    f"Click Check to review which sources files would be modified.")
            else:
                tool_text = "no known upgrade target"
                status_text = (
                    f"No mapped upgrade path from '{info['codename'] or 'unknown'}'. "
                    f"You may already be on the latest stable release.")

        else:
            tool_text = ""
            status_text = (
                f"Distro upgrade is not supported on this system "
                f"(detected: {info['id'] or 'unknown'}).")

        GLib.idle_add(self._upg_update_banner, pretty, tool_text, status_text)

    def _upg_update_banner(self, pretty, tool_text, status_text):
        self.upg_version_lbl.set_text(pretty)
        self.upg_tool_lbl.set_text(tool_text)
        self.upg_status_lbl.set_text(status_text)

    # ── uplog helper ──────────────────────────────────────────
    def _uplog(self, text):
        GLib.idle_add(self._uplog_append, text)

    def _uplog_append(self, text):
        end = self.upg_log_buf.get_end_iter()
        self.upg_log_buf.insert(end, f"[{datetime.now().strftime('%H:%M:%S')}] {text}\n")
        self.upg_log_view.scroll_to_iter(self.upg_log_buf.get_end_iter(), 0, False, 0, 0)

    def _upg_set_buttons(self, check=True, download=False, go=False, simulate=True):
        GLib.idle_add(self.btn_upg_check.set_sensitive,    check)
        GLib.idle_add(self.btn_upg_download.set_sensitive, download)
        GLib.idle_add(self.btn_upg_go.set_sensitive,       go)
        GLib.idle_add(self.btn_upg_simulate.set_sensitive, simulate)

    def _ensure_mintupgrade(self):
        """Install mintupgrade if missing. Returns True if available."""
        if subprocess.run(["which", "mintupgrade"], capture_output=True).returncode == 0:
            return True
        self._uplog("mintupgrade not found — installing…")
        r = subprocess.run(["apt", "install", "-y", "mintupgrade"],
                            capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            self._uplog("mintupgrade installed.")
            return True
        self._uplog(f"Failed to install mintupgrade:\n{r.stderr.strip()}")
        return False

    def _stream_mintupgrade(self, args):
        """Run mintupgrade <args>, stream output to uplog. Returns exit code."""
        cmd = ["mintupgrade"] + args
        self._uplog(f"Running: {' '.join(cmd)}")
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                self._uplog(line)
        proc.wait()
        return proc.returncode

    # ── Debian backend ────────────────────────────────────────
    def _stream_apt(self, args):
        """Run apt-get <args>, stream output to uplog. Returns exit code."""
        cmd = ["apt-get"] + args
        self._uplog(f"Running: {' '.join(cmd)}")
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                self._uplog(line)
        proc.wait()
        return proc.returncode

    def _debian_sources_files(self):
        """Return list of (Path, kind) for apt source files. kind ∈ {'list','sources'}."""
        files = []
        main = Path("/etc/apt/sources.list")
        if main.exists() and main.read_text().strip():
            files.append((main, "list"))
        sld = Path("/etc/apt/sources.list.d")
        if sld.is_dir():
            for p in sorted(sld.glob("*.list")):    files.append((p, "list"))
            for p in sorted(sld.glob("*.sources")): files.append((p, "sources"))
        return files

    def _debian_swap_codename(self, from_cn, to_cn, dry_run=False):
        """Replace from_cn → to_cn in all apt source files (word-boundary match
        so that e.g. 'bookworm-updates' becomes 'trixie-updates' cleanly).

        If dry_run is False, backups are written to /var/backups/mythix-upgrade-<ts>/.
        Returns (changed_paths, log_lines).
        """
        pattern = re.compile(rf"\b{re.escape(from_cn)}\b")
        changed = []
        log = []
        backup_dir = Path(f"/var/backups/mythix-upgrade-{datetime.now():%Y%m%d-%H%M%S}")
        if not dry_run:
            try:
                backup_dir.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                log.append(f"Could not create backup dir {backup_dir}: {e}")
                return changed, log

        for path, _kind in self._debian_sources_files():
            try:
                content = path.read_text()
            except Exception as e:
                log.append(f"  {path}: read error — {e}")
                continue
            if not pattern.search(content):
                continue
            new_content = pattern.sub(to_cn, content)
            if new_content == content:
                continue
            changed.append(path)
            log.append(f"  {path}: {from_cn} → {to_cn}")
            if not dry_run:
                try:
                    (backup_dir / path.name).write_text(content)
                    write_text_with_backup(path, new_content, label="apt-upgrade")
                    log.append(f"  {path}: backup saved to {backup_dir / path.name}")
                except Exception as e:
                    log.append(f"  {path}: write error — {e}")
        if not dry_run and changed:
            log.insert(0, f"Backups saved to {backup_dir}")
        return changed, log

    def _debian_check_worker(self):
        self._uplog("─" * 50)
        info = detect_distro()
        cur = info["codename"]
        nxt = DEBIAN_NEXT_CODENAME.get(cur)
        if not nxt:
            self._uplog(f"No mapped upgrade target for '{cur or 'unknown'}'.")
            self._upg_set_buttons(); return
        self._uplog(f"Current release: {info['pretty']}")
        self._uplog(f"Next release:    {nxt}")
        self._uplog(f"Scanning apt sources for '{cur}' references…")
        changed, log = self._debian_swap_codename(cur, nxt, dry_run=True)
        for line in log: self._uplog(line)
        if changed:
            self._uplog(f"✓ {len(changed)} sources file(s) would be modified.")
            self._uplog("Note: check is based on a static release map — this does "
                        "not verify the new release is live on your mirror yet.")
            self._upg_set_buttons(check=True, download=True, go=False, simulate=True)
            GLib.idle_add(self.upg_status_lbl.set_text,
                          f"Upgrade path {cur} → {nxt} ready. Download when ready.")
        else:
            self._uplog("No sources files reference the current codename — "
                        "perhaps sources are already pointing at the target.")
            self._upg_set_buttons()

    def _debian_simulate_worker(self):
        self._uplog("─" * 50)
        self._uplog("Simulating Debian distro upgrade (no changes will be made)…")
        info = detect_distro()
        cur = info["codename"]; nxt = DEBIAN_NEXT_CODENAME.get(cur)
        if not nxt:
            self._uplog(f"No upgrade target for '{cur or 'unknown'}'.")
            self._upg_set_buttons(); return
        self._uplog(f"Would swap codename '{cur}' → '{nxt}' in:")
        _changed, log = self._debian_swap_codename(cur, nxt, dry_run=True)
        for line in log: self._uplog(line)
        self._uplog("Would then run:")
        self._uplog("  apt-get update")
        self._uplog("  apt-get upgrade --without-new-pkgs -y")
        self._uplog("  apt-get full-upgrade -y")
        self._uplog("Reminder: a real apt-level simulation requires the sources "
                    "to actually be swapped, so dependency details aren't shown here.")
        self._upg_set_buttons()

    def _debian_download_worker(self):
        self._uplog("─" * 50)
        info = detect_distro()
        cur = info["codename"]; nxt = DEBIAN_NEXT_CODENAME.get(cur)
        if not nxt:
            self._uplog(f"No upgrade target for '{cur or 'unknown'}'.")
            self._upg_set_buttons(); return
        self._uplog(f"Swapping apt sources: {cur} → {nxt}")
        changed, log = self._debian_swap_codename(cur, nxt, dry_run=False)
        for line in log: self._uplog(line)
        if not changed:
            self._uplog("No sources modified — aborting download.")
            self._upg_set_buttons(); return
        self._uplog("Refreshing package lists…")
        rc = self._stream_apt(["update"])
        if rc != 0:
            self._uplog(f"apt-get update failed (exit {rc}). "
                        f"The backup in /var/backups/ can be restored manually.")
            self._upg_set_buttons(); return
        self._uplog("Downloading upgrade packages (no install)…")
        rc = self._stream_apt(["full-upgrade", "-d", "-y"])
        if rc == 0:
            self._uplog("✓ Download complete. Ready to upgrade.")
            self._upg_set_buttons(check=True, download=False, go=True, simulate=True)
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Download complete — click Start Upgrade when ready.")
        else:
            self._uplog(f"Download failed (exit {rc}).")
            self._upg_set_buttons()

    def _debian_upgrade_worker(self):
        self._uplog("─" * 50)
        self._uplog("Starting Debian distro upgrade — DO NOT interrupt.")
        GLib.idle_add(self.upg_status_lbl.set_text, "Upgrade in progress…")
        self._uplog("Step 1/3: apt-get update")
        rc = self._stream_apt(["update"])
        if rc != 0:
            self._uplog(f"apt-get update failed (exit {rc})."); self._upg_set_buttons(); return
        self._uplog("Step 2/3: apt-get upgrade --without-new-pkgs")
        rc = self._stream_apt(["upgrade", "--without-new-pkgs", "-y"])
        if rc != 0:
            self._uplog(f"apt-get upgrade failed (exit {rc})."); self._upg_set_buttons(); return
        self._uplog("Step 3/3: apt-get full-upgrade")
        rc = self._stream_apt(["full-upgrade", "-y"])
        if rc == 0:
            self._uplog("✓ Upgrade complete! A reboot is recommended.")
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Upgrade complete — please reboot your system.")
            self._upg_set_buttons(check=True, download=False, go=False, simulate=False)
            GLib.idle_add(self._upgrade_check_version)
        else:
            self._uplog(f"Upgrade finished with errors (exit {rc}). Check the log above.")
            self._upg_set_buttons()
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Upgrade encountered errors — review the log.")

    # ── Check ─────────────────────────────────────────────────
    def _on_upg_check(self, *_):
        self._upg_set_buttons(check=False, download=False, go=False, simulate=False)
        target = (self._debian_check_worker
                  if detect_distro()["id"] == "debian"
                  else self._upg_check_worker)
        threading.Thread(target=target, daemon=True).start()

    def _upg_check_worker(self):
        self._uplog("─" * 50)
        self._uplog("Checking for available upgrades…")
        if not self._ensure_mintupgrade():
            self._upg_set_buttons(); return
        rc = self._stream_mintupgrade(["check"])
        if rc == 0:
            self._uplog("✓ An upgrade is available. You can proceed with Download.")
            self._upg_set_buttons(check=True, download=True, go=False, simulate=True)
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Upgrade available — download it when ready.")
        elif rc == 1:
            self._uplog("✓ Your system is up to date — no upgrade available.")
            self._upg_set_buttons()
            GLib.idle_add(self.upg_status_lbl.set_text, "System is up to date.")
        else:
            self._uplog(f"mintupgrade check exited {rc} — see output above.")
            self._upg_set_buttons()

    # ── Simulate ──────────────────────────────────────────────
    def _on_upg_simulate(self, *_):
        self._upg_set_buttons(check=False, download=False, go=False, simulate=False)
        target = (self._debian_simulate_worker
                  if detect_distro()["id"] == "debian"
                  else self._upg_simulate_worker)
        threading.Thread(target=target, daemon=True).start()

    def _upg_simulate_worker(self):
        self._uplog("─" * 50)
        self._uplog("Simulating upgrade (dry run — no changes will be made)…")
        if not self._ensure_mintupgrade():
            self._upg_set_buttons(); return
        rc = self._stream_mintupgrade(["upgrade", "--dry-run"])
        self._uplog(f"Simulation complete (exit {rc}).")
        self._upg_set_buttons()

    # ── Download ──────────────────────────────────────────────
    def _on_upg_download(self, *_):
        self._upg_set_buttons(check=False, download=False, go=False, simulate=False)
        target = (self._debian_download_worker
                  if detect_distro()["id"] == "debian"
                  else self._upg_download_worker)
        threading.Thread(target=target, daemon=True).start()

    def _upg_download_worker(self):
        self._uplog("─" * 50)
        self._uplog("Downloading upgrade packages…")
        if not self._ensure_mintupgrade():
            self._upg_set_buttons(); return
        rc = self._stream_mintupgrade(["download"])
        if rc == 0:
            self._uplog("✓ Download complete. Ready to upgrade.")
            self._upg_set_buttons(check=True, download=False, go=True, simulate=True)
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Download complete — click Start Upgrade when ready.")
        else:
            self._uplog(f"Download failed (exit {rc}).")
            self._upg_set_buttons()

    # ── Upgrade ───────────────────────────────────────────────
    def _on_upg_go(self, *_):
        info = detect_distro()
        is_debian = info["id"] == "debian"
        release_word = "Debian" if is_debian else "Linux Mint"
        snapshot_hint = ("Make sure you have a recent system backup."
                         if is_debian else
                         "Make sure you have a Timeshift snapshot.")
        d = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.YES_NO,
            text="Start the distro upgrade now?")
        d.format_secondary_text(
            f"This will upgrade your system to the next {release_word} release.\n\n"
            f"• Do NOT interrupt the process once started.\n"
            f"• {snapshot_hint}\n"
            f"• The system may reboot when complete.")
        resp = d.run(); d.destroy()
        if resp != Gtk.ResponseType.YES:
            return
        self._upg_set_buttons(check=False, download=False, go=False, simulate=False)
        target = self._debian_upgrade_worker if is_debian else self._upg_go_worker
        threading.Thread(target=target, daemon=True).start()

    def _upg_go_worker(self):
        self._uplog("─" * 50)
        self._uplog("Starting upgrade — DO NOT close this window or interrupt the process.")
        GLib.idle_add(self.upg_status_lbl.set_text, "Upgrade in progress…")
        rc = self._stream_mintupgrade(["upgrade"])
        if rc == 0:
            self._uplog("✓ Upgrade complete! A reboot is recommended.")
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Upgrade complete — please reboot your system.")
            self._upg_set_buttons(check=True, download=False, go=False, simulate=False)
            GLib.idle_add(self._upgrade_check_version)
        else:
            self._uplog(f"Upgrade finished with errors (exit {rc}). Check the log above.")
            self._upg_set_buttons()
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Upgrade encountered errors — review the log.")


# ────────────────────────────────────────────────────────────
# ENTRY POINT
# ────────────────────────────────────────────────────────────
def main():
    if os.geteuid()!=0:
        env_args=[]
        for var in ("DISPLAY","XAUTHORITY","WAYLAND_DISPLAY","XDG_RUNTIME_DIR","DBUS_SESSION_BUS_ADDRESS"):
            val=os.environ.get(var)
            if val: env_args+=[f"{var}={val}"]
        try: os.execvp("pkexec",["pkexec","env"]+env_args+[sys.executable]+sys.argv)
        except Exception: print("Error: run as root. Try: sudo -E ./mythix-system-manager.py"); sys.exit(1)
    win=SystemManager(); win.show_all(); win.progress.hide(); Gtk.main()

if __name__=="__main__":
    main()
