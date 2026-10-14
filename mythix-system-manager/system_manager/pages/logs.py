"""journald log viewer."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class LogsMixin:
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

