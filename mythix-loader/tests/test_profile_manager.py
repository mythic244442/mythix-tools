"""Tests for the mythix-loader profile manager script.

Each test builds a throwaway Steam install under a fake $HOME: library
folders, app manifests, small generated PE files and a binary appinfo.vdf.

    python3 -m unittest discover -s mythix-loader/tests
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "mythix-loader")


def load_script():
    loader = importlib.machinery.SourceFileLoader("mythix_loader_script", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    loader.exec_module(mod)
    return mod


ml = load_script()


# ── fixtures ────────────────────────────────────────────────────────────────

def make_pe(path, machine=0x8664, imports=("steam_api64.dll",), names_elsewhere=False, pad=0):
    """Write a minimal PE with an import table naming `imports`. With
    names_elsewhere the DLL names live in a second section."""
    pe32plus = machine == 0x8664
    opt_size = 240 if pe32plus else 224
    n_sections = 2 if names_elsewhere else 1
    hdr = bytearray(0x200)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x40)
    hdr[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", hdr, 0x44, machine, n_sections, 0, 0, 0, opt_size, 0)
    opt = 0x58
    struct.pack_into("<H", hdr, opt, 0x20B if pe32plus else 0x10B)
    struct.pack_into("<II", hdr, opt + (120 if pe32plus else 104), 0x1000, 20 * (len(imports) + 1))
    sec = opt + opt_size
    struct.pack_into("<8sIIII", hdr, sec, b".idata", 0x200, 0x1000, 0x200, 0x200)
    if names_elsewhere:
        struct.pack_into("<8sIIII", hdr, sec + 40, b".rdata", 0x200, 0x2000, 0x200, 0x400)

    idata = bytearray(0x200)
    names = bytearray(0x200)
    name_base, name_rva = (0x2000, 0) if names_elsewhere else (0x1000, 0x100)
    for i, dll in enumerate(imports):
        struct.pack_into("<I", idata, i * 20 + 12, name_base + name_rva)
        target = names if names_elsewhere else idata
        target[name_rva:name_rva + len(dll) + 1] = dll.encode() + b"\0"
        name_rva += len(dll) + 1
    data = bytes(hdr) + bytes(idata) + (bytes(names) if names_elsewhere else b"") + b"\0" * pad
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def kv_binary(d, strings):
    out = bytearray()
    for k, v in d.items():
        idx = strings.setdefault(k, len(strings))
        if isinstance(v, dict):
            out += b"\x00" + struct.pack("<I", idx) + kv_binary(v, strings)
        elif isinstance(v, int):
            out += b"\x02" + struct.pack("<Ii", idx, v)
        else:
            out += b"\x01" + struct.pack("<I", idx) + v.encode() + b"\0"
    return bytes(out + b"\x08")


def make_appinfo(path, apps):
    """apps: {appid: appinfo dict}. Writes a v29 (string table) appinfo.vdf."""
    strings = {}
    body = bytearray()
    for appid, info in apps.items():
        vdf = kv_binary({"appinfo": info}, strings)
        entry = struct.pack("<IIQ20sI20s", 2, 0, 0, b"\0" * 20, 1, b"\0" * 20) + vdf
        body += struct.pack("<II", appid, len(entry)) + entry
    body += struct.pack("<I", 0)
    table = struct.pack("<I", len(strings)) + b"".join(
        k.encode() + b"\0" for k, _ in sorted(strings.items(), key=lambda kv: kv[1]))
    header_len = 16
    with open(path, "wb") as f:
        f.write(struct.pack("<IIq", 0x07564429, 1, header_len + len(body)))
        f.write(body)
        f.write(table)


class FakeSteam:
    """A Steam install at ~/.local/share/Steam, with ~/.steam/steam linked to it."""

    def __init__(self, home):
        self.home = home
        self.root = os.path.join(home, ".local", "share", "Steam")
        self.apps = {}
        os.makedirs(os.path.join(self.root, "steamapps", "common"))
        os.makedirs(os.path.join(self.root, "appcache"))
        for n in ("steamclient.dll", "steamclient64.dll"):
            open(os.path.join(self.root, n), "wb").close()
        os.makedirs(os.path.join(home, ".steam"))
        os.symlink(self.root, os.path.join(home, ".steam", "steam"))

    def install(self, appid, name, installdir, launch=None):
        self.apps[appid] = (name, installdir, launch)
        with open(os.path.join(self.root, "steamapps", f"appmanifest_{appid}.acf"), "w") as f:
            f.write('"AppState"\n{\n\t"appid"\t\t"%d"\n\t"name"\t\t"%s"\n'
                    '\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' % (appid, name, installdir))
        self._write_indexes()
        return os.path.join(self.root, "steamapps", "common", installdir)

    def _write_indexes(self):
        apps = "".join('\t\t\t"%d"\t\t"1"\n' % a for a in self.apps)
        with open(os.path.join(self.root, "steamapps", "libraryfolders.vdf"), "w") as f:
            f.write('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n'
                    '\t\t"apps"\n\t\t{\n%s\t\t}\n\t}\n}\n' % (self.root, apps))
        info = {}
        for appid, (name, _, launch) in self.apps.items():
            entry = {"appid": appid, "common": {"name": name, "type": "Game"}}
            if launch:
                entry["config"] = {"launch": {str(i): l for i, l in enumerate(launch)}}
            info[appid] = entry
        make_appinfo(os.path.join(self.root, "appcache", "appinfo.vdf"), info)


class ProfileTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self._tmp.name)
        self._old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        self._old_profiles = ml.PROFILES_DIR
        ml.PROFILES_DIR = os.path.join(self.home, ".mythix", "loader_profiles")
        self.steam = FakeSteam(self.home)

    def tearDown(self):
        ml.PROFILES_DIR = self._old_profiles
        if self._old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._old_home
        self._tmp.cleanup()

    def create(self, game_dir, **kw):
        with contextlib.redirect_stdout(io.StringIO()):
            return ml.create_profile(game_dir, **kw)

    def read_ini(self, plan):
        with open(plan["ini_path"], encoding="utf-8") as f:
            return dict(line.split("=", 1) for line in f.read().splitlines()
                        if "=" in line and not line.startswith("#"))


# ── library matching ────────────────────────────────────────────────────────

class LibraryMatchTests(ProfileTestCase):
    def test_game_dir_through_symlinked_steam_path(self):
        self.steam.install(480, "Spacewar", "Spacewar")
        via_link = os.path.join(self.home, ".steam", "steam", "steamapps", "common", "Spacewar")
        os.makedirs(via_link, exist_ok=True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ml.resolve_appid_from_library(via_link), ("480", "Spacewar"))

    def test_library_listed_twice_via_symlink_is_scanned_once(self):
        self.steam.install(480, "Spacewar", "Spacewar")
        libs = ml.steam_libraries(os.path.join(self.home, ".steam", "steam"))
        self.assertEqual(len(libs), 1)

    def test_folder_above_several_installs_is_ambiguous(self):
        os.makedirs(self.steam.install(10, "Alpha", "Alpha"))
        os.makedirs(self.steam.install(20, "Beta", "Beta"))
        common = os.path.join(self.steam.root, "steamapps", "common")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ml.resolve_appid_from_library(common), (None, None))

    def test_folder_above_a_single_install_matches_it(self):
        os.makedirs(self.steam.install(10, "Alpha", "Alpha"))
        common = os.path.join(self.steam.root, "steamapps", "common")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ml.resolve_appid_from_library(common), ("10", "Alpha"))

    def test_exe_subfolder_matches_its_install(self):
        inst = self.steam.install(10, "Alpha", "Alpha")
        os.makedirs(os.path.join(inst, "bin"))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ml.resolve_appid_from_library(os.path.join(inst, "bin")), ("10", "Alpha"))


# ── profile creation ────────────────────────────────────────────────────────

class CreateProfileTests(ProfileTestCase):
    def test_run_dir_is_steams_workingdir(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar", launch=[
            {"executable": "Bin\\Win64\\Spacewar.exe", "workingdir": "bin", "type": "default",
             "arguments": "-dx12", "config": {"oslist": "windows"}},
        ])
        make_pe(os.path.join(inst, "bin", "win64", "Spacewar.exe"))
        plan = self.create(inst)
        self.assertEqual(plan["launch_source"], "appinfo")
        self.assertEqual(plan["run_dir"], os.path.join(inst, "bin"))
        self.assertEqual(plan["launch_options"], ["-dx12"])
        ini = self.read_ini(plan)
        self.assertEqual(ini["ExeRunDir"], os.path.join(inst, "bin"))
        self.assertEqual(ini["ExeCommandLine"], "")      # Steam's args are never baked in
        self.assertEqual(ini["AppId"], "480")

    def test_run_dir_defaults_to_exe_folder_not_profile_dir(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "game", "Spacewar.exe"))
        plan = self.create(inst)
        self.assertEqual(plan["run_dir"], os.path.join(inst, "game"))
        self.assertNotEqual(self.read_ini(plan)["ExeRunDir"], plan["profile_dir"])

    def test_manual_exe_gets_steams_workingdir_too(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar", launch=[
            {"executable": "Launcher.exe", "type": "default"},
            {"executable": "bin/Game.exe", "workingdir": "data", "type": "none"},
        ])
        make_pe(os.path.join(inst, "Launcher.exe"))
        make_pe(os.path.join(inst, "bin", "Game.exe"))
        os.makedirs(os.path.join(inst, "data"))
        plan = self.create(inst, target_exe="bin/Game.exe")    # relative to the game dir
        self.assertEqual(plan["launch_source"], "manual")
        self.assertEqual(plan["exe"], os.path.join(inst, "bin", "Game.exe"))
        self.assertEqual(plan["run_dir"], os.path.join(inst, "data"))

    def test_relative_exe_prefers_the_one_under_the_game_dir(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "a", "game.exe"))
        make_pe(os.path.join(inst, "b", "game.exe"))
        plan = self.create(inst, target_exe=os.path.join("b", "game.exe"))
        self.assertEqual(plan["exe"], os.path.join(inst, "b", "game.exe"))

    def test_non_ascii_title_falls_back_to_folder_then_appid(self):
        inst = self.steam.install(700, "ゲーム", "Gemu")
        make_pe(os.path.join(inst, "ゲーム.exe"))
        plan = self.create(inst)
        self.assertEqual(plan["profile_name"], "gemu")
        self.assertTrue(plan["stub_path"].endswith(os.sep + "game.exe"))

        inst2 = self.steam.install(701, "ゲーム・ツー", "ゲーム・ツー")
        make_pe(os.path.join(inst2, "run.exe"))
        self.assertEqual(self.create(inst2)["profile_name"], "app-701")

    def test_ini_is_utf8_with_non_ascii_paths(self):
        inst = self.steam.install(480, "Café", "Café Racer")
        make_pe(os.path.join(inst, "Café.exe"))
        plan = self.create(inst)
        with open(plan["ini_path"], "rb") as f:
            raw = f.read()
        self.assertIn(("Exe=" + os.path.join(inst, "Café.exe")).encode("utf-8"), raw)

    def test_old_steamclient_copies_are_removed(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        profile = os.path.join(ml.PROFILES_DIR, "spacewar")
        for rel in ("client/x86/steamclient.dll", "client/x86_64/steamclient64.dll",
                    "client/x86_64/steamclient.so", "steamclient64.dll"):
            os.makedirs(os.path.dirname(os.path.join(profile, rel)), exist_ok=True)
            open(os.path.join(profile, rel), "wb").close()
        plan = self.create(inst)
        self.assertEqual(sorted(os.listdir(profile)), ["mythix_loader.ini", "spacewar.exe"])
        ini = self.read_ini(plan)
        for retired in ("SteamClientDll", "SteamClient64Dll", "ForceArch", "NoInject"):
            self.assertNotIn(retired, ini)

    def test_symlinked_client_dir_is_left_alone(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        elsewhere = os.path.join(self.home, "elsewhere")
        os.makedirs(os.path.join(elsewhere, "x86"))
        keep = os.path.join(elsewhere, "x86", "steamclient.dll")
        open(keep, "wb").close()
        profile = os.path.join(ml.PROFILES_DIR, "spacewar")
        os.makedirs(profile)
        os.symlink(elsewhere, os.path.join(profile, "client"))
        self.create(inst)
        self.assertTrue(os.path.isfile(keep))

    def test_new_profile_has_the_v15_keys(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        ini = self.read_ini(self.create(inst))
        for k, v in {"SingleInstance": "1", "LogFile": "mythix_loader.log", "Priority": "",
                     "Affinity": "", "RunBefore": "", "RunAfter": "", "ExtraDlls": "",
                     "Persist": "1", "WaitForChildren": "1"}.items():
            self.assertEqual(ini.get(k), v, k)

    def test_refresh_keeps_user_settings(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        plan = self.create(inst)
        with open(plan["ini_path"], encoding="utf-8") as f:
            text = f.read()
        edits = {"Priority=": "Priority=high", "EnvVars=": "EnvVars=DXVK_HUD=fps;-FOO",
                 "RunBefore=": 'RunBefore="C:\\tools\\backup.exe" now', "Persist=1": "Persist=0",
                 "LogFile=mythix_loader.log": "LogFile=", "AppId=480": "AppId=999"}
        for a, b in edits.items():
            self.assertIn(a, text)
            text = text.replace(a, b, 1)
        text += "SteamClientDll=C:\\old\\steamclient.dll\nMyOwnKey=keep me\n"
        with open(plan["ini_path"], "w", encoding="utf-8") as f:
            f.write(text)

        plan = self.create(inst)
        ini = self.read_ini(plan)
        self.assertEqual(ini["Priority"], "high")
        self.assertEqual(ini["EnvVars"], "DXVK_HUD=fps;-FOO")
        self.assertEqual(ini["RunBefore"], '"C:\\tools\\backup.exe" now')
        self.assertEqual(ini["Persist"], "0")
        self.assertEqual(ini["LogFile"], "")                 # turned off on purpose: stays off
        self.assertEqual(ini["AppId"], "480")                # from the game, not kept
        self.assertEqual(ini["MyOwnKey"], "keep me")
        self.assertNotIn("SteamClientDll", ini)              # retired keys are dropped
        self.assertEqual(sorted(plan["kept_settings"]),
                         ["EnvVars", "LogFile", "Persist", "Priority", "RunBefore"])

    def test_refresh_regenerates_exe_and_run_dir(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        plan = self.create(inst)
        ini = self.read_ini(plan)
        with open(plan["ini_path"], encoding="utf-8") as f:
            text = f.read()
        text = text.replace(f"Exe={ini['Exe']}", "Exe=C:\\old\\game.exe")
        text = text.replace(f"ExeRunDir={ini['ExeRunDir']}", f"ExeRunDir={plan['profile_dir']}")
        with open(plan["ini_path"], "w", encoding="utf-8") as f:
            f.write(text)
        again = self.read_ini(self.create(inst))
        self.assertEqual(again["Exe"], ini["Exe"])
        self.assertEqual(again["ExeRunDir"], ini["ExeRunDir"])   # e.g. a v1.2 profile-dir run dir

    def test_refresh_reads_utf16_and_ansi_inis(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        plan = self.create(inst)
        body = "[MythixLoader]\nExe=x\nEnvVars=NAME=Café\nPriority=high\n"
        for raw in (b"\xff\xfe" + body.encode("utf-16-le"), body.encode("cp1252")):
            with open(plan["ini_path"], "wb") as f:
                f.write(raw)
            ini = self.read_ini(self.create(inst))
            self.assertEqual((ini["EnvVars"], ini["Priority"]), ("NAME=Café", "high"))

    def test_hand_set_appid_survives_when_the_library_doesnt_know_the_game(self):
        game = os.path.join(self.home, "Elsewhere", "Unknown Game")
        make_pe(os.path.join(game, "game.exe"))
        plan = self.create(game)
        self.assertEqual(plan["appid"], "0")
        with open(plan["ini_path"], encoding="utf-8") as f:
            text = f.read().replace("AppId=0", "AppId=4242")
        with open(plan["ini_path"], "w", encoding="utf-8") as f:
            f.write(text)
        self.assertEqual(self.read_ini(self.create(game))["AppId"], "4242")
        self.assertEqual(self.create(game, dry_run=True)["appid"], "4242")

    def test_dry_run_reports_what_it_would_keep(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        plan = self.create(inst)
        with open(plan["ini_path"], encoding="utf-8") as f:
            text = f.read().replace("ExeCommandLine=", "ExeCommandLine=-windowed")
        with open(plan["ini_path"], "w", encoding="utf-8") as f:
            f.write(text)
        dry = self.create(inst, dry_run=True)
        self.assertEqual(dry["kept_settings"], ["ExeCommandLine"])
        self.assertEqual(dry["args"], "-windowed")

    def test_dry_run_writes_nothing(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        plan = self.create(inst, dry_run=True)
        self.assertTrue(plan["dry_run"])
        self.assertFalse(os.path.exists(plan["profile_dir"]))


# ── PE parsing ──────────────────────────────────────────────────────────────

class PeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_arch_and_imports(self):
        p = os.path.join(self.dir, "a.exe")
        make_pe(p, machine=0x14C, imports=("KERNEL32.dll", "steam_api.dll"))
        self.assertEqual(ml.get_pe_arch(p), 32)
        self.assertEqual(ml.get_pe_imports(p), ["KERNEL32.dll", "steam_api.dll"])

    def test_import_names_in_another_section(self):
        p = os.path.join(self.dir, "b.exe")
        make_pe(p, imports=("steam_api64.dll", "USER32.dll"), names_elsewhere=True)
        self.assertEqual(ml.get_pe_imports(p), ["steam_api64.dll", "USER32.dll"])

    def test_truncated_exe_does_not_crash_the_scan(self):
        p = os.path.join(self.dir, "stub.exe")
        with open(p, "wb") as f:
            f.write(b"MZ\x90\x00")
        self.assertIsNone(ml.get_pe_arch(p))
        make_pe(os.path.join(self.dir, "real.exe"), pad=2 * 1024 * 1024)
        with contextlib.redirect_stdout(io.StringIO()):
            best = ml.pick_main_exe(ml.scan_game(self.dir), self.dir)
        self.assertEqual(best["name"], "real.exe")


# ── command line ────────────────────────────────────────────────────────────

class CliTests(ProfileTestCase):
    def run_cli(self, *args):
        env = dict(os.environ, HOME=self.home, PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True,
                              text=True, encoding="utf-8", env=env)

    def test_json_dry_run(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        r = self.run_cli(inst, "--json", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        plan = json.loads(r.stdout)
        self.assertEqual(plan["appid"], "480")
        self.assertEqual(plan["run_dir"], inst)

    def test_require_appid_refuses_and_writes_nothing(self):
        game = os.path.join(self.home, "Elsewhere", "Unknown Game")
        make_pe(os.path.join(game, "game.exe"))
        r = self.run_cli(game, "--json", "--require-appid")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("appid", json.loads(r.stdout)["error"])
        self.assertFalse(os.path.exists(os.path.join(ml.PROFILES_DIR, "unknown-game")))
        r = self.run_cli(game, "--json")                # without the flag: AppId=0 profile
        self.assertEqual(json.loads(r.stdout)["appid"], "0")

    def test_appid_must_be_numeric(self):
        inst = self.steam.install(480, "Spacewar", "Spacewar")
        make_pe(os.path.join(inst, "Spacewar.exe"))
        r = self.run_cli(inst, "--json", "--appid", "abc")
        self.assertEqual(r.returncode, 1)
        self.assertFalse(json.loads(r.stdout)["ok"])


if __name__ == "__main__":
    unittest.main()
