"""Install history page."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class HistoryMixin:
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

