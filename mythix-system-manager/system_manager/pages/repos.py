"""APT repository manager."""
from ..core import *  # shared imports (Gtk, GLib, subprocess, …) and constants

class ReposMixin:
    # ────────────────────────────────────────────────────────
    def _refresh_repos(self):
        self._set_status("Reading repositories…")
        threading.Thread(target=self._repo_refresh_worker,daemon=True).start()

    def _repo_refresh_worker(self):
        try:
            repos=[]
            list_files=["/etc/apt/sources.list"]+sorted(glob.glob("/etc/apt/sources.list.d/*.list"))
            for fp in list_files:
                try: lines=Path(fp).read_text().splitlines()
                except Exception: continue
                for ln,line in enumerate(lines,1):
                    p=self._parse_repo_line(line,fp,ln)
                    if p: repos.append(p)
            # deb822 .sources files (Debian 12+ default, Trixie default)
            for fp in sorted(glob.glob("/etc/apt/sources.list.d/*.sources")):
                repos.extend(self._parse_deb822_file(fp))
            self._repos=repos; GLib.idle_add(self._populate_repo_store)
        except Exception: pass
        finally: self._repos_loaded=True; self._set_status("Ready")

    def _parse_repo_line(self,line,fp,ln):
        s=line.strip(); enabled=True
        if not s: return None
        if s.startswith('#'):
            inner=s[1:].strip()
            if not inner.startswith('deb'): return None
            enabled=False; s=inner
        if not s.startswith('deb'): return None
        if ' #' in s: s=s[:s.index(' #')].strip()
        parts=s.split()
        if len(parts)<3: return None
        idx=0; rtype=parts[idx]; idx+=1
        if idx<len(parts) and parts[idx].startswith('['):
            while idx<len(parts) and not parts[idx].endswith(']'): idx+=1
            idx+=1
        if idx+1>=len(parts): return None
        url=parts[idx]; idx+=1
        suite=parts[idx] if idx<len(parts) else ""; idx+=1
        comps=" ".join(parts[idx:]) if idx<len(parts) else ""
        return {"enabled":enabled,"type":rtype,"url":url,"suite":suite,"comps":comps,
                "file":fp,"line_num":ln,"fmt":"list"}

    def _parse_deb822_file(self,fp):
        """Parse a deb822 .sources file. Each stanza becomes one repo row;
        multi-URI / multi-Suite stanzas are shown collapsed (with a +N marker
        on URL) since enable/disable/remove operate on the whole stanza."""
        try: lines=Path(fp).read_text().splitlines()
        except Exception: return []
        stanzas=[]; cur={}; cur_start=None

        def flush(end_line):
            if cur and cur_start is not None:
                uris=cur.get("uris","").split()
                suites=cur.get("suites","").split()
                comps=cur.get("components","").split()
                types=cur.get("types","").split()
                en=cur.get("enabled","").strip().lower() not in ("no","false","0")
                # A stanza with no uris is malformed — skip
                if uris:
                    url=uris[0]+(f"  (+{len(uris)-1} more)" if len(uris)>1 else "")
                    stanzas.append({
                        "enabled":en,"type":" ".join(types) or "deb",
                        "url":url,"suite":" ".join(suites),"comps":" ".join(comps),
                        "file":fp,"line_num":cur_start,
                        "fmt":"sources","stanza_start":cur_start,"stanza_end":end_line})
            cur.clear()

        last_nonblank=0
        for i,line in enumerate(lines,1):
            stripped=line.strip()
            if not stripped:
                flush(last_nonblank); cur_start=None; continue
            if stripped.startswith('#'): continue
            if ':' in line:
                k,_,v=line.partition(':')
                cur[k.strip().lower()]=v.strip()
                if cur_start is None: cur_start=i
            last_nonblank=i
        flush(last_nonblank)
        return stanzas

    def _populate_repo_store(self):
        self.repo_store.clear()
        for r in self._repos:
            self.repo_store.append([r["enabled"],r["type"],r["url"],r["suite"],r["comps"],Path(r["file"]).name,r["line_num"]])

    def _on_repo_toggle(self,widget,path):
        row=self.repo_store[path]; enabled=row[COL_R_ENABLED]
        fname=row[COL_R_FILE]; lnum=row[COL_R_LINE_NUM]
        repo=next((r for r in self._repos if Path(r["file"]).name==fname and r["line_num"]==lnum),None)
        if not repo: return
        try:
            if repo.get("fmt")=="sources":
                self._deb822_set_enabled(repo, enable=enabled)  # enabled=current, flipping to !enabled
                self._repos_loaded=False; self._refresh_repos(); return
            lines=Path(repo["file"]).read_text().splitlines()
            i=repo["line_num"]-1
            if i>=len(lines): return
            new_line = ("# " + lines[i]) if enabled else lines[i].lstrip('#').lstrip()
            if new_line == lines[i]:
                self._plog(f"No repo change needed for {repo['file']}:{repo['line_num']}")
                return
            lines[i] = new_line
            backup = write_text_with_backup(repo["file"], "\n".join(lines)+"\n", label="apt-source")
            self._plog(f"Updated repo line in {repo['file']}:{repo['line_num']} (backup: {backup})")
            row[COL_R_ENABLED]=not enabled; repo["enabled"]=not enabled
        except Exception as e: self._show_error("Failed",str(e))

    def _deb822_set_enabled(self, repo, enable):
        """Flip stanza enabled state. enable=True means the stanza was previously
        enabled and we want to disable it (insert 'Enabled: no'); enable=False
        means it was disabled and we want to enable it (drop any Enabled: line)."""
        fp=Path(repo["file"])
        lines=fp.read_text().splitlines()
        s=repo["stanza_start"]-1; e=repo["stanza_end"]-1
        if s<0 or e>=len(lines) or s>e: return
        stanza=[l for l in lines[s:e+1]
                if not l.strip().lower().startswith("enabled:")]
        if enable:  # currently enabled → disable
            stanza.append("Enabled: no")
        new_text = "\n".join(lines[:s] + stanza + lines[e+1:]) + "\n"
        if new_text == fp.read_text():
            self._plog(f"No deb822 repo change needed for {fp}")
            return
        backup = write_text_with_backup(fp, new_text, label="apt-source")
        self._plog(f"Updated deb822 repo stanza in {fp} (backup: {backup})")

    def _on_repo_add(self,*_):
        d=Gtk.Dialog(title="Add Repository",transient_for=self,flags=0)
        d.add_buttons(Gtk.STOCK_CANCEL,Gtk.ResponseType.CANCEL,Gtk.STOCK_ADD,Gtk.ResponseType.OK)
        d.set_default_size(560,-1)
        box=d.get_content_area(); box.set_spacing(8); box.set_margin_start(12); box.set_margin_end(12)
        box.set_margin_top(12); box.set_margin_bottom(12)
        box.pack_start(Gtk.Label(label="Enter a full sources.list line:"),False,False,0)
        entry=Gtk.Entry()
        placeholder = ("deb http://deb.debian.org/debian trixie main contrib non-free-firmware"
                       if detect_distro()["id"]=="debian"
                       else "deb https://example.com/ubuntu focal main")
        entry.set_placeholder_text(placeholder)
        entry.set_width_chars(60); box.pack_start(entry,False,False,0)
        hint=Gtk.Label(label="Saved to /etc/apt/sources.list.d/mythix-custom.list")
        hint.get_style_context().add_class("security-desc"); hint.set_halign(Gtk.Align.START)
        box.pack_start(hint,False,False,0); d.show_all()
        resp=d.run(); text=entry.get_text().strip(); d.destroy()
        if resp!=Gtk.ResponseType.OK or not text: return
        if not text.startswith('deb'): self._show_error("Invalid","Line must start with 'deb'."); return
        custom=Path("/etc/apt/sources.list.d/mythix-custom.list")
        try:
            existing=custom.read_text() if custom.exists() else ""
            if text in existing: self._show_error("Exists","Already configured."); return
            backup = make_backup(custom, label="apt-source")
            with open(custom,"a") as f:
                if existing and not existing.endswith("\n"): f.write("\n")
                f.write(text+"\n")
            self._repos_loaded=False; self._refresh_repos()
        except Exception as e: self._show_error("Failed",str(e))

    def _on_repo_remove(self,*_):
        model,it=self.repo_tree.get_selection().get_selected()
        if it is None: self._show_error("No selection","Select a repo."); return
        fname=model.get_value(it,COL_R_FILE); lnum=model.get_value(it,COL_R_LINE_NUM)
        repo=next((r for r in self._repos if Path(r["file"]).name==fname and r["line_num"]==lnum),None)
        if not repo: return
        d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.WARNING,
                             buttons=Gtk.ButtonsType.YES_NO,text="Remove this repository?")
        d.format_secondary_text(f"URL: {repo['url']}\nFile: {repo['file']}")
        resp=d.run(); d.destroy()
        if resp!=Gtk.ResponseType.YES: return
        try:
            lines=Path(repo["file"]).read_text().splitlines()
            if repo.get("fmt")=="sources":
                s=repo["stanza_start"]-1; e=repo["stanza_end"]-1
                if 0<=s<=e<len(lines): del lines[s:e+1]
                # collapse consecutive blank lines left behind
                while s<len(lines) and not lines[s].strip(): del lines[s]
            else:
                i=repo["line_num"]-1
                if 0<=i<len(lines): del lines[i]
            write_text_with_backup(repo["file"], "\n".join(lines)+"\n", label="apt-source")
            self._repos_loaded=False; self._refresh_repos()
        except Exception as e: self._show_error("Failed",str(e))

