"""Overview dashboard: stat cards, security score, sparkline."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class OverviewMixin:
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

