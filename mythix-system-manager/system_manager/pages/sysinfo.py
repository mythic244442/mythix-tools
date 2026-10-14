"""System info page with 5s refresh timer."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class SysInfoMixin:
    # ────────────────────────────────────────────────────────
    def _start_sysinfo_timer(self):
        if self._sysinfo_timer is None:
            self._refresh_sysinfo()
            self._sysinfo_timer=GLib.timeout_add_seconds(5,self._refresh_sysinfo)

    def _stop_sysinfo_timer(self):
        if self._sysinfo_timer:
            GLib.source_remove(self._sysinfo_timer); self._sysinfo_timer=None

    def _refresh_sysinfo(self,*_):
        threading.Thread(target=self._sysinfo_worker,daemon=True).start()
        return True

    def _sysinfo_worker(self):
        info={}
        try:
            u=platform.uname()
            info["hostname"]=u.node
            info["kernel"]=u.release
            try:
                distro=Path("/etc/os-release").read_text()
                for line in distro.splitlines():
                    if line.startswith("PRETTY_NAME="):
                        info["distro"]=line[12:].strip().strip('"'); break
            except Exception: info["distro"]=platform.system()
            try:
                uptime_s=float(Path("/proc/uptime").read_text().split()[0])
                d,r=divmod(int(uptime_s),86400); h,r=divmod(r,3600); m=r//60
                info["uptime"]={"d":d,"h":h,"m":m}
                info["uptime"]=f"{d}d {h}h {m}m" if d else f"{h}h {m}m"
            except Exception: info["uptime"]="?"
            try:
                cpu_lines=[l for l in Path("/proc/cpuinfo").read_text().splitlines() if "model name" in l]
                info["cpu_model"]=cpu_lines[0].split(":")[1].strip() if cpu_lines else "?"
                cores=len([l for l in Path("/proc/cpuinfo").read_text().splitlines() if l.startswith("processor")])
                info["cpu_cores"]=str(cores)
            except Exception: info["cpu_model"]="?"; info["cpu_cores"]="?"
            try:
                gpus=[]
                for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
                    prod = card / "device" / "product_name"
                    label = card / "device" / "label"
                    uevent = card / "device" / "uevent"
                    name = None
                    if prod.exists(): name = prod.read_text().strip()
                    elif label.exists(): name = label.read_text().strip()
                    if not name and uevent.exists():
                        for line in uevent.read_text().splitlines():
                            if line.startswith("PCI_NAME="): name = line.split("=",1)[1]; break
                    if not name:
                        r = subprocess.run(["lspci","-mm"], capture_output=True, text=True, timeout=5)
                        for line in r.stdout.splitlines():
                            if "VGA" in line or "3D" in line or "Display" in line:
                                parts = line.split('"')
                                if len(parts) >= 6: name = f"{parts[3]} {parts[5]}"; break
                    if name and name not in gpus: gpus.append(name)
                info["gpu"] = " | ".join(gpus) if gpus else "?"
            except Exception: info["gpu"] = "?"
            try:
                la = Path("/proc/loadavg").read_text().split()[:3]
                info["load"] = "  ".join(la)
            except Exception: info["load"] = "?"
            try:
                procs = len([d for d in Path("/proc").iterdir() if d.name.isdigit()])
                info["processes"] = str(procs)
            except Exception: info["processes"] = "?"
            try:
                s1=Path("/proc/stat").read_text().splitlines()[0].split()[1:]
                time.sleep(0.2)
                s2=Path("/proc/stat").read_text().splitlines()[0].split()[1:]
                d=[int(b)-int(a) for a,b in zip(s1,s2)]
                idle=d[3]; total=sum(d)
                pct=100*(total-idle)/total if total else 0
                info["cpu_usage"]=f"{pct:.1f}%"
            except Exception: info["cpu_usage"]="?"
            try:
                mem={}
                for line in Path("/proc/meminfo").read_text().splitlines():
                    k,v=line.split(":"); mem[k.strip()]=int(v.strip().split()[0])
                total_mb=mem["MemTotal"]/1024; avail_mb=mem.get("MemAvailable",mem.get("MemFree",0))/1024
                used_mb=total_mb-avail_mb
                info["ram"]=f"{used_mb:.0f} MB / {total_mb:.0f} MB ({100*used_mb/total_mb:.0f}%)"
                if "SwapTotal" in mem and mem["SwapTotal"]>0:
                    stotal=mem["SwapTotal"]/1024; sused=(mem["SwapTotal"]-mem.get("SwapFree",0))/1024
                    info["swap"]=f"{sused:.0f} MB / {stotal:.0f} MB"
                else: info["swap"]="None"
            except Exception: info["ram"]="?"; info["swap"]="?"
            try:
                r=subprocess.run(["df","-h","--output=target,size,used,avail,pcent","-x","tmpfs","-x","devtmpfs"],
                    capture_output=True,text=True,timeout=5)
                disks=[line.split() for line in r.stdout.splitlines()[1:] if line]
                info["_disks"]=disks
            except Exception: info["_disks"]=[]
        except Exception as e: info["_error"]=str(e)
        GLib.idle_add(self._update_sysinfo,info)

    def _update_sysinfo(self,info):
        for key,lbl in self._si_labels.items():
            lbl.set_text(info.get(key,"—"))
        # rebuild disk box
        for child in self._si_disk_box.get_children():
            self._si_disk_box.remove(child)
        for disk in info.get("_disks",[]):
            if len(disk)<5: continue
            mnt,size,used,avail,pct=disk[0],disk[1],disk[2],disk[3],disk[4]
            row=Gtk.Box(spacing=12)
            ml=Gtk.Label(label=mnt); ml.set_width_chars(20); ml.set_halign(Gtk.Align.START)
            ml.get_style_context().add_class("sysinfo-key")
            bar=Gtk.ProgressBar()
            try: bar.set_fraction(min(1.0,int(pct.rstrip("%"))/100))
            except Exception: bar.set_fraction(0)
            bar.set_show_text(True); bar.set_text(f"{used} / {size} ({pct})")
            bar.set_hexpand(True)
            row.pack_start(ml,False,False,0); row.pack_start(bar,True,True,0)
            self._si_disk_box.pack_start(row,False,False,0)
        self._si_disk_box.show_all()

