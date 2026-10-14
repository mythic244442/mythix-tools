"""ClamAV scan page."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class AntivirusMixin:
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

