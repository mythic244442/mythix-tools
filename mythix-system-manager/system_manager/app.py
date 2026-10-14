"""Main window: skeleton, CSS, tray, helpers, and the composed SystemManager."""
from .core import *
from .pages.palette   import CommandPaletteMixin
from .pages.updates   import UpdatesMixin
from .pages.overview  import OverviewMixin
from .pages.history   import HistoryMixin
from .pages.packages  import PackagesMixin
from .pages.kernels   import KernelsMixin
from .pages.repos     import ReposMixin
from .pages.security  import SecurityMixin
from .pages.cleanup   import CleanupMixin
from .pages.antivirus import AntivirusMixin
from .pages.startup   import StartupMixin
from .pages.logs      import LogsMixin
from .pages.sysinfo   import SysInfoMixin
from .pages.upgrade   import UpgradeMixin


class AppBase(Gtk.Window):
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



class SystemManager(
    CommandPaletteMixin, UpdatesMixin, OverviewMixin, HistoryMixin,
    PackagesMixin, KernelsMixin, ReposMixin, SecurityMixin, CleanupMixin,
    AntivirusMixin, StartupMixin, LogsMixin, SysInfoMixin, UpgradeMixin,
    AppBase,
):
    """The full window: all page mixins composed over the AppBase skeleton."""


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
