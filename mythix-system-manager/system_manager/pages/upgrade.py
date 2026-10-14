"""Distro upgrade (Mint via mintupgrade, Debian via sources swap)."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class UpgradeMixin:
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
            idx = mint_release_index(info["version"])
            if idx is not None and idx >= len(MINT_RELEASES) - 1:
                status_text = (
                    f"You are on the latest known Mint release ({MINT_LATEST[0]} "
                    f"{MINT_LATEST[1].capitalize()}). Nothing to upgrade to.")
            elif idx is not None:
                nv, ncn = MINT_RELEASES[idx + 1]
                status_text = (
                    f"Next release for you: Mint {nv} {ncn.capitalize()}. "
                    + ("Click Check to confirm with mintupgrade." if has_tool else
                       "mintupgrade is not installed. Click Check to install it and look for upgrades."))
            elif has_tool:
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

    def _stream_mintupgrade(self, args, collect=None):
        """Run mintupgrade <args>, stream output to uplog. Returns exit code.
        If collect is a list, each output line is also appended to it."""
        cmd = ["mintupgrade"] + args
        self._uplog(f"Running: {' '.join(cmd)}")
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
        for line in proc.stdout:
            line = line.rstrip()
            if line:
                self._uplog(line)
                if collect is not None:
                    collect.append(line)
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

        info = detect_distro()
        idx = mint_release_index(info["version"])
        if idx is not None and idx >= len(MINT_RELEASES) - 1:
            self._uplog(f"You are already on the latest known Mint release "
                        f"({MINT_LATEST[0]} {MINT_LATEST[1].capitalize()}).")
            self._uplog("mintupgrade's metadata can go stale and offer older "
                        "releases (e.g. Wilma) — ignoring it.")
            self._upg_set_buttons()
            GLib.idle_add(self.upg_status_lbl.set_text,
                          f"Up to date — Mint {MINT_LATEST[0]} is the latest release.")
            return

        if not self._ensure_mintupgrade():
            self._upg_set_buttons(); return
        output = []
        rc = self._stream_mintupgrade(["check"], collect=output)
        if rc == 0 and self._mintupgrade_offer_is_stale(info, output):
            self._uplog("⚠ mintupgrade offered a release that is not newer than "
                        "your current version — its metadata is stale. Ignoring.")
            self._upg_set_buttons()
            GLib.idle_add(self.upg_status_lbl.set_text,
                          "Up to date (mintupgrade's offer was stale and was ignored).")
        elif rc == 0:
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

    def _mintupgrade_offer_is_stale(self, info, output_lines):
        """True if mintupgrade's offered target is not newer than the current
        Mint release according to MINT_RELEASES (i.e. stale metadata)."""
        cur_idx = mint_release_index(info["version"])
        if cur_idx is None:
            return False
        text = " ".join(output_lines).lower()
        for i, (v, cn) in enumerate(MINT_RELEASES):
            if cn in text and i <= cur_idx:
                return True
        return False

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


