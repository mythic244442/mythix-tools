"""Disk cleanup page."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class CleanupMixin:
    # ────────────────────────────────────────────────────────
    def _refresh_cleanup_sizes(self,*_):
        threading.Thread(target=self._cleanup_size_worker,daemon=True).start()

    def _dir_size(self,path):
        try:
            p=safe_expand_path(path)
            if not p.exists(): return 0
            total=0
            for f in p.rglob("*"):
                try: total+=f.stat().st_size
                except Exception: pass
            return total
        except Exception: return 0

    def _cleanup_size_worker(self):
        sizes={}
        sizes["apt_cache"]=self._dir_size("/var/cache/apt/archives/")
        try:
            r=subprocess.run(["apt","autoremove","--dry-run"],capture_output=True,text=True,timeout=30)
            count=len([l for l in r.stdout.splitlines() if l.startswith("  ") and not l.startswith("   ")])
            sizes["apt_orphans"]=count
        except Exception: sizes["apt_orphans"]=-1
        try:
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            cache=apt.Cache(); cache.open(None)
            old=[n for n in cache.keys() if re.match(r'^linux-image-\d',n) and cache[n].installed and n!=running_pkg]
            sizes["old_kernels"]=len(old); cache.close()
        except Exception: sizes["old_kernels"]=0
        sizes["thumbnails"]=self._dir_size("~/.cache/thumbnails/")
        sizes["trash"]=self._dir_size("~/.local/share/Trash/")
        GLib.idle_add(self._update_cleanup_sizes,sizes)

    def _update_cleanup_sizes(self,sizes):
        fmt={"apt_cache":human_size(sizes.get("apt_cache",0)),
             "apt_orphans":f"{sizes.get('apt_orphans',0)} pkgs",
             "old_kernels":f"{sizes.get('old_kernels',0)} kernels",
             "thumbnails":human_size(sizes.get("thumbnails",0)),
             "trash":human_size(sizes.get("trash",0))}
        for key,val in fmt.items():
            if key in self._cleanup_rows:
                self._cleanup_rows[key]["size_lbl"].set_text(val)

    def _do_apt_clean(self):
        threading.Thread(target=self._run_cleanup_cmd,
            args=(["apt","clean"],["apt","autoclean"],"APT cache cleared."),daemon=True).start()

    def _do_apt_autoremove(self):
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text="Remove orphaned packages?")
        d.format_secondary_text("Runs apt autoremove -y")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._run_cleanup_cmd,args=(["apt","autoremove","-y"],None,"Orphaned packages removed."),daemon=True).start()

    def _do_remove_old_kernels(self):
        try:
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            cache=apt.Cache(); cache.open(None)
            old=[n for n in cache.keys() if re.match(r'^linux-image-\d',n) and cache[n].installed and n!=running_pkg]
            cache.close()
        except Exception as e: self._clog(f"Error scanning kernels: {e}"); return
        if not old: self._clog("No old kernels to remove."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Remove {len(old)} old kernel(s)?")
        d.format_secondary_text("\n".join(old[:10])+(f"\n+{len(old)-10} more" if len(old)>10 else ""))
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._run_cleanup_cmd,args=(["apt","remove","-y"]+old,None,"Old kernels removed."),daemon=True).start()

    def _do_clean_thumbnails(self):
        try:
            p=Path.home()/".cache"/"thumbnails"
            if p.exists():
                shutil.rmtree(p)
                p.mkdir(parents=True,exist_ok=True)
                self._clog(f"Thumbnail cache cleared: {p}")
            else:
                self._clog(f"Thumbnail cache not present: {p}")
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

    def _do_empty_trash(self):
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text="Empty trash?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        try:
            p=Path.home()/".local"/"share"/"Trash"
            removed=[]
            for sub in ("files","info","expunged"):
                sp=p/sub
                if sp.exists():
                    shutil.rmtree(sp)
                    sp.mkdir(exist_ok=True)
                    removed.append(str(sp))
            if removed:
                self._clog("Trash emptied: " + ", ".join(removed))
            else:
                self._clog(f"Trash already empty or missing: {p}")
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

    def _run_cleanup_cmd(self,cmd1,cmd2,msg):
        self._clog(f"Running {' '.join(cmd1)}…")
        try:
            proc=subprocess.Popen(cmd1,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._clog(line.rstrip())
            proc.wait()
            if cmd2:
                self._clog(f"Running {' '.join(cmd2)}…")
                proc2=subprocess.Popen(cmd2,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                for line in proc2.stdout:
                    if line.rstrip(): self._clog(line.rstrip())
                proc2.wait()
            self._clog(msg)
            GLib.idle_add(self._refresh_cleanup_sizes)
        except Exception as e: self._clog(f"Error: {e}")

