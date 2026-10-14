"""Kernel listing, removal, default selection."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class KernelsMixin:
    # ────────────────────────────────────────────────────────
    def _on_refresh_kernels(self,*_):
        self._set_status("Scanning kernels…")
        threading.Thread(target=self._kernel_refresh_worker,daemon=True).start()

    def _kernel_get_grub_default(self):
        """Return the kernel version string that is saved as the GRUB default, or None."""
        saved_entry = None
        try:
            r = subprocess.run(["grub-editenv","list"], capture_output=True, text=True, timeout=5)
            for line in r.stdout.splitlines():
                if line.startswith("saved_entry="):
                    saved_entry = line.split("=",1)[1].strip(); break
        except Exception:
            pass
        if not saved_entry:
            try:
                for line in Path("/boot/grub/grubenv").read_text().splitlines():
                    if line.startswith("saved_entry="):
                        saved_entry = line.split("=",1)[1].strip(); break
            except Exception:
                pass
        if not saved_entry:
            return None
        # Entry looks like: gnulinux-advanced-UUID>gnulinux-6.8.0-49-generic-advanced-UUID
        # or just a plain kernel version string on some systems
        right = saved_entry.split(">")[-1]
        m = re.search(r'gnulinux-(.+?)-(?:advanced|recovery)-[0-9a-f-]+$', right)
        if m:
            return m.group(1)   # e.g. "6.8.0-49-generic"
        # Fallback: entry might just be the version string directly
        return right if right else None

    def _kernel_refresh_worker(self):
        try:
            cache=apt.Cache(); cache.open(None)
            running=platform.uname().release; running_pkg=f"linux-image-{running}"
            grub_default=self._kernel_get_grub_default()   # e.g. "6.8.0-49-generic"
            kernels=[]
            for name in sorted(cache.keys()):
                if not re.match(r'^linux-image-\d',name): continue
                pkg=cache[name]
                if not pkg.installed: continue
                inst=pkg.installed; is_run=(name==running_pkg)
                # Check if this is the GRUB default
                is_def = bool(grub_default and grub_default in name)
                if is_run and is_def:   status="Running (default)"
                elif is_run:            status="Running"
                elif is_def:            status="Installed (default)"
                else:                   status="Installed"
                kernels.append({"name":name,"version":inst.version,"status":status,
                                 "size":inst.installed_size,"is_running":is_run})
            seen={k["name"] for k in kernels}
            for name in sorted(cache.keys()):
                if name in seen: continue
                if not any(re.match(p,name) for p in [r'^linux-image-generic',r'^linux-image-lowlatency',
                                                        r'^linux-image-oem',r'^linux-image-virtual',r'^linux-image-hwe']): continue
                pkg=cache[name]
                if not pkg.candidate: continue
                kernels.append({"name":name,"version":pkg.candidate.version,"status":"Available",
                                 "size":pkg.candidate.size,"is_running":False})
            cache.close(); self._kernels=kernels; GLib.idle_add(self._populate_kernel_store)
        except Exception as e: self._klog(f"Error: {e}")
        finally: self._kernels_loaded=True; self._set_status("Ready")

    def _populate_kernel_store(self):
        self.kernel_store.clear()
        def _sort_key(k):
            s = k["status"]
            if "Running" in s:   return (0, k["name"])
            if "default" in s:   return (1, k["name"])
            if "Installed" in s: return (2, k["name"])
            return (3, k["name"])
        for k in sorted(self._kernels, key=_sort_key):
            self.kernel_store.append([k["is_running"],k["name"],k["version"],k["status"],human_size(k["size"]),k["size"]])

    def _get_selected_kernel(self):
        model,it=self.kernel_tree.get_selection().get_selected()
        if it is None: return None,None
        return model.get_value(it,COL_K_PACKAGE), model.get_value(it,COL_K_STATUS)

    def _on_kernel_install(self,*_):
        pkg,status=self._get_selected_kernel()
        if not pkg: self._show_error("No selection","Select a kernel package."); return
        if "Running" in status or "Installed" in status: self._show_error("Already installed",f"{pkg} is installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Install {pkg}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_op_worker,args=("install",pkg),daemon=True).start()

    def _on_kernel_remove(self,*_):
        pkg,status=self._get_selected_kernel()
        if not pkg: self._show_error("No selection","Select an installed kernel."); return
        if "Running" in status: self._show_error("Cannot remove","Cannot remove the running kernel."); return
        if "Installed" not in status: self._show_error("Not installed",f"{pkg} is not installed."); return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text=f"Remove {pkg}?")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_op_worker,args=("remove",pkg),daemon=True).start()

    def _kernel_op_worker(self,action,pkg):
        self._klog(f"apt {action} {pkg}…")
        try:
            proc=subprocess.Popen(["apt",action,"-y",pkg],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in proc.stdout:
                if line.rstrip(): self._klog(line.rstrip())
            proc.wait()
            if proc.returncode==0:
                self._klog("Done."); self._kernels_loaded=False; GLib.idle_add(self._on_refresh_kernels)
            else: self._klog(f"Failed (exit {proc.returncode}).")
        except Exception as e: self._klog(f"Error: {e}")

    def _on_kernel_set_default(self, *_):
        pkg, status = self._get_selected_kernel()
        if not pkg:
            self._show_error("No selection", "Select an installed kernel to set as default."); return
        if "Installed" not in status and "Running" not in status:
            self._show_error("Not installed", f"{pkg} is not installed — install it first."); return
        d = Gtk.MessageDialog(transient_for=self, flags=0,
            message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.YES_NO,
            text=f"Set default boot kernel?")
        d.format_secondary_text(
            f"Package: {pkg}\n\n"
            "GRUB will be updated to boot this kernel by default.\n"
            "The change takes effect on next reboot.")
        resp = d.run(); d.destroy()
        if resp != Gtk.ResponseType.YES: return
        threading.Thread(target=self._kernel_set_default_worker, args=(pkg,), daemon=True).start()

    def _kernel_find_grub_entry(self, pkg_name):
        """Parse /boot/grub/grub.cfg and return the full GRUB entry ID for pkg_name."""
        m = re.match(r'^linux-image-(.+)$', pkg_name)
        if not m: return None
        kver = m.group(1)   # e.g. "6.8.0-49-generic"
        try:
            cfg = Path("/boot/grub/grub.cfg").read_text()
            # Find the advanced submenu ID
            sm = re.search(
                r"submenu\s+'[^']*'\s+\$menuentry_id_option\s+'(gnulinux-advanced-[^']+)'", cfg)
            if not sm:
                sm = re.search(
                    r"submenu\s+'[^']*Advanced[^']*'\s+\$menuentry_id_option\s+'([^']+)'",
                    cfg, re.IGNORECASE)
            submenu_id = sm.group(1) if sm else None
            # Find the specific kernel entry
            em = re.search(
                rf"menuentry\s+'[^']*{re.escape(kver)}[^']*'\s+\$menuentry_id_option\s+'([^']+)'",
                cfg)
            if not em: return None
            entry_id = em.group(1)
            return f"{submenu_id}>{entry_id}" if submenu_id else entry_id
        except Exception as e:
            self._klog(f"grub.cfg parse error: {e}"); return None

    def _kernel_set_default_worker(self, pkg_name):
        self._klog(f"Setting {pkg_name} as default boot kernel…")
        # 1. Ensure GRUB_DEFAULT=saved
        grub_def_file = Path("/etc/default/grub")
        try:
            text = grub_def_file.read_text()
            if "GRUB_DEFAULT=saved" not in text:
                new_text = re.sub(r'^GRUB_DEFAULT=.*$', 'GRUB_DEFAULT=saved',
                                  text, flags=re.MULTILINE)
                if new_text == text:
                    new_text += '\nGRUB_DEFAULT=saved\n'
                backup = write_text_with_backup(grub_def_file, new_text, label="grub-default")
                self._klog("Set GRUB_DEFAULT=saved in /etc/default/grub")
                if backup:
                    self._klog(f"Backup saved: {backup}")
                    self._klog(f"If update-grub fails, restore /etc/default/grub from: {backup}")
        except Exception as e:
            self._klog(f"Warning: could not update /etc/default/grub: {e}")
        # 2. Find and set the GRUB entry
        entry = self._kernel_find_grub_entry(pkg_name)
        if entry:
            self._klog(f"GRUB entry: {entry}")
            r = subprocess.run(["grub-set-default", entry],
                                capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                self._klog("grub-set-default: OK")
            else:
                self._klog(f"grub-set-default error: {r.stderr.strip()}")
        else:
            self._klog("Could not find GRUB menu entry in grub.cfg.")
            self._klog("Tip: run 'update-grub' manually first, then retry.")
        # 3. Always run update-grub to regenerate config
        self._klog("Running update-grub…")
        proc = subprocess.Popen(["update-grub"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in proc.stdout:
            if line.rstrip(): self._klog(line.rstrip())
        proc.wait()
        if proc.returncode == 0:
            self._klog("Done. New default will take effect on next reboot.")
        else:
            self._klog(f"update-grub exited {proc.returncode} — check output above.")
        # 4. Refresh the list to show updated (default) marker
        self._kernels_loaded = False
        GLib.idle_add(self._on_refresh_kernels)

