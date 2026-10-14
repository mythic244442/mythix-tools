"""Updates page: apt + flatpak update listing and install."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class UpdatesMixin:
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

