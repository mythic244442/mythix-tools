"""Ctrl+K command palette."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class CommandPaletteMixin:
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

