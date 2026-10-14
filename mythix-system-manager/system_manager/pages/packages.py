"""Installed packages browser incl. apt-mark hold."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class PackagesMixin:
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

