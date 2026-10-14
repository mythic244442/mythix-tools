"""Startup entry manager."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class StartupMixin:
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

