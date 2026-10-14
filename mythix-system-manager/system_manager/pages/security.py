"""Security feature toggles and scoring."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class SecurityMixin:
    # ────────────────────────────────────────────────────────
    def _refresh_security_status(self):
        threading.Thread(target=self._security_check_worker,daemon=True).start()

    def _security_check_worker(self):
        checks={"ufw":self._check_ufw,"auto_security_updates":self._check_unattended_upgrades,
                "fail2ban":self._check_fail2ban,"ssh_root":self._check_ssh_root,
                "ssh_password":self._check_ssh_password,"usb_storage":self._check_usb_storage,
                "core_dumps":self._check_core_dumps,"sysrq":self._check_sysrq}
        for key,fn in checks.items():
            try: result=fn()
            except Exception as e: result={"status":"error","active":False}
            GLib.idle_add(self._update_security_row,key,result)

    def _update_security_row(self,key,result):
        w=self._security_widgets.get(key)
        if not w: return
        sw=w["switch"]; lbl=w["status_label"]
        status=result.get("status","unknown"); active=result.get("active",False)
        self._security_updating=True; sw.set_state(active); sw.set_active(active); self._security_updating=False
        for cls in ("status-active","status-inactive","status-notinstalled","status-unknown"):
            lbl.get_style_context().remove_class(cls)
        mapping={"active":("Active","status-active"),"inactive":("Inactive","status-inactive"),
                 "not_installed":("Not Installed","status-notinstalled")}
        txt,cls=mapping.get(status,("Unknown","status-unknown"))
        lbl.set_text(txt); lbl.get_style_context().add_class(cls)
        sw.set_sensitive(status!="not_installed")

    def _check_ufw(self):
        if subprocess.run(["which","ufw"],capture_output=True).returncode!=0: return {"status":"not_installed","active":False}
        r=subprocess.run(["ufw","status"],capture_output=True,text=True,timeout=10)
        a="Status: active" in r.stdout; return {"status":"active" if a else "inactive","active":a}

    def _check_unattended_upgrades(self):
        if subprocess.run(["dpkg","-s","unattended-upgrades"],capture_output=True).returncode!=0:
            return {"status":"not_installed","active":False}
        conf=Path("/etc/apt/apt.conf.d/20auto-upgrades")
        if conf.exists() and 'Unattended-Upgrade "1"' in conf.read_text():
            return {"status":"active","active":True}
        return {"status":"inactive","active":False}

    def _check_fail2ban(self):
        if subprocess.run(["which","fail2ban-client"],capture_output=True).returncode!=0: return {"status":"not_installed","active":False}
        r=subprocess.run(["systemctl","is-active","fail2ban"],capture_output=True,text=True,timeout=10)
        a=r.stdout.strip()=="active"; return {"status":"active" if a else "inactive","active":a}

    def _check_ssh_root(self):
        sshd=Path("/etc/ssh/sshd_config")
        if not sshd.exists(): return {"status":"not_installed","active":False}
        for line in sshd.read_text().splitlines():
            line=line.strip()
            if line.startswith("#") or not line.lower().startswith("permitrootlogin"): continue
            v=line.split(None,1)[1].strip().lower()
            b=v in ("no","prohibit-password","forced-commands-only")
            return {"status":"active" if b else "inactive","active":b}
        return {"status":"active","active":True}

    def _check_ssh_password(self):
        sshd=Path("/etc/ssh/sshd_config")
        if not sshd.exists(): return {"status":"not_installed","active":False}
        for line in sshd.read_text().splitlines():
            line=line.strip()
            if line.startswith("#") or not line.lower().startswith("passwordauthentication"): continue
            k=line.split(None,1)[1].strip().lower()=="no"
            return {"status":"active" if k else "inactive","active":k}
        return {"status":"inactive","active":False}

    def _check_usb_storage(self):
        b=Path("/etc/modprobe.d/blacklist-usb-storage.conf")
        if b.exists() and "blacklist usb-storage" in b.read_text(): return {"status":"active","active":True}
        return {"status":"inactive","active":False}

    def _check_core_dumps(self):
        lf=Path("/etc/security/limits.conf")
        if lf.exists():
            for line in lf.read_text().splitlines():
                line=line.strip()
                if not line.startswith("#") and "hard" in line and "core" in line and "0" in line:
                    return {"status":"active","active":True}
        try:
            r=subprocess.run(["sysctl","-n","kernel.core_pattern"],capture_output=True,text=True,timeout=5)
            if r.stdout.strip()=="/dev/null": return {"status":"active","active":True}
        except Exception: pass
        return {"status":"inactive","active":False}

    def _check_sysrq(self):
        try:
            v=int(Path("/proc/sys/kernel/sysrq").read_text().strip())
            r=v in (0,176); return {"status":"active" if r else "inactive","active":r}
        except Exception: return {"status":"unknown","active":False}

    def _on_security_toggle(self,switch,state,key):
        if self._security_updating: return True
        toggles={"ufw":self._toggle_ufw,"auto_security_updates":self._toggle_unattended_upgrades,
                 "fail2ban":self._toggle_fail2ban,"ssh_root":self._toggle_ssh_root,
                 "ssh_password":self._toggle_ssh_password,"usb_storage":self._toggle_usb_storage,
                 "core_dumps":self._toggle_core_dumps,"sysrq":self._toggle_sysrq}
        fn=toggles.get(key)
        if not fn: return True
        switch.set_sensitive(False); self._security_widgets[key]["status_label"].set_text("Applying…")
        checks={"ufw":self._check_ufw,"auto_security_updates":self._check_unattended_upgrades,
                "fail2ban":self._check_fail2ban,"ssh_root":self._check_ssh_root,
                "ssh_password":self._check_ssh_password,"usb_storage":self._check_usb_storage,
                "core_dumps":self._check_core_dumps,"sysrq":self._check_sysrq}
        def _do():
            try: fn(state)
            except Exception as e: GLib.idle_add(self._show_error,f"Failed to toggle {key}",str(e))
            finally:
                try: result=checks[key]()
                except Exception: result={"status":"unknown","active":False}
                GLib.idle_add(self._update_security_row,key,result)
                GLib.idle_add(switch.set_sensitive,True)
        threading.Thread(target=_do,daemon=True).start(); return True

    def _toggle_ufw(self,e):
        subprocess.run(["ufw","--force","enable"] if e else ["ufw","disable"],timeout=30,check=True)

    def _toggle_unattended_upgrades(self,e):
        if subprocess.run(["dpkg","-s","unattended-upgrades"],capture_output=True).returncode!=0:
            subprocess.run(["apt","install","-y","unattended-upgrades"],timeout=120,check=True)
        write_text_with_backup(Path("/etc/apt/apt.conf.d/20auto-upgrades"),
            'APT::Periodic::Update-Package-Lists "1";\n'
            f'APT::Periodic::Unattended-Upgrade "{"1" if e else "0"}";\n', label="apt-config")

    def _toggle_fail2ban(self,e):
        if subprocess.run(["which","fail2ban-client"],capture_output=True).returncode!=0:
            subprocess.run(["apt","install","-y","fail2ban"],timeout=120,check=True)
        subprocess.run(["systemctl","enable" if e else "disable","--now","fail2ban"],timeout=30,check=True)

    def _edit_sshd(self,key,val):
        sshd=Path("/etc/ssh/sshd_config")
        original=sshd.read_text()
        lines=original.splitlines(); found=False; out=[]
        for line in lines:
            s=line.strip()
            if s.lower().startswith(key.lower()) or s.lower().startswith(f"#{key.lower()}"):
                out.append(f"{key} {val}"); found=True
            else: out.append(line)
        if not found: out.append(f"{key} {val}")
        backup = write_text_with_backup(sshd, "\n".join(out)+"\n", label="sshd")
        try:
            subprocess.run(["sshd","-t"], capture_output=True, text=True, timeout=10, check=True)
        except Exception as e:
            atomic_write_text(sshd, original)
            raise RuntimeError(f"sshd validation failed; restored original config (backup: {backup}): {e}")
        subprocess.run(["systemctl","restart","sshd"],timeout=30)

    def _toggle_ssh_root(self,e): self._edit_sshd("PermitRootLogin","no" if e else "yes")
    def _toggle_ssh_password(self,e): self._edit_sshd("PasswordAuthentication","no" if e else "yes")

    def _toggle_usb_storage(self,e):
        b=Path("/etc/modprobe.d/blacklist-usb-storage.conf")
        if e:
            write_text_with_backup(b, "# Mythix System Manager\nblacklist usb-storage\n", label="modprobe")
            subprocess.run(["modprobe","-r","usb-storage"],capture_output=True,timeout=10)
        else:
            remove_file_with_backup(b, label="modprobe")
            subprocess.run(["modprobe","usb-storage"],capture_output=True,timeout=10)

    def _toggle_core_dumps(self,e):
        lf=Path("/etc/security/limits.conf"); sc=Path("/etc/sysctl.d/99-mythix-no-coredump.conf")
        if e:
            text=lf.read_text() if lf.exists() else ""
            if "* hard core 0" not in text:
                with open(lf,"a") as f: f.write("\n# Mythix System Manager\n* hard core 0\n")
            write_text_with_backup(sc, "# Mythix System Manager\nkernel.core_pattern=/dev/null\n", label="sysctl")
            subprocess.run(["sysctl","-p",str(sc)],timeout=10)
        else:
            if lf.exists():
                lines=[l for l in lf.read_text().splitlines() if "Mythix System Manager" not in l and l.strip()!="* hard core 0"]
                write_text_with_backup(lf, "\n".join(lines)+"\n", label="limits")
            remove_file_with_backup(sc, label="sysctl")
            subprocess.run(["sysctl","-w","kernel.core_pattern=|/usr/share/apport/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -- %E"],capture_output=True,timeout=10)

    def _toggle_sysrq(self,e):
        sc=Path("/etc/sysctl.d/99-mythix-sysrq.conf")
        if e:
            write_text_with_backup(sc, "# Mythix System Manager\nkernel.sysrq=176\n", label="sysctl")
            subprocess.run(["sysctl","-p",str(sc)],timeout=10)
        else:
            remove_file_with_backup(sc, label="sysctl")
            subprocess.run(["sysctl","-w","kernel.sysrq=1"],capture_output=True,timeout=10)

