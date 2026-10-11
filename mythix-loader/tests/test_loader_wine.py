"""End-to-end tests for mythix_loader.exe, run under Wine.

Builds the loader and a stand-in game (fakegame.c) with mingw-w64, then
launches through the loader and checks what the game saw. Runs once for the
64-bit build and once for the 32-bit one. A build is skipped when its
compiler or a matching Wine isn't installed (the 32-bit one also needs
32-bit Wine: wine32 on Debian/Ubuntu). Each class makes a throwaway Wine
prefix (slow once); set WINEPREFIX to reuse one instead.

    python3 -m unittest discover -s mythix-loader/tests
"""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src", "mythix_loader.c")


def _first_file(*paths):
    return next((p for p in paths if p and os.path.isfile(p)), None)


CC = {64: shutil.which("x86_64-w64-mingw32-gcc"), 32: shutil.which("i686-w64-mingw32-gcc")}
WINE = {
    64: _first_file(shutil.which("wine64"), "/usr/lib/wine/wine64", shutil.which("wine")),
    32: _first_file(shutil.which("wine"), "/usr/lib/wine/wine"),
}


class LoaderUnderWine:
    """The tests; LoaderUnderWine64/32 below run them for each build."""

    BITS = 64

    @classmethod
    def setUpClass(cls):
        cc, cls.wine = CC[cls.BITS], WINE[cls.BITS]
        if not cc or not cls.wine:
            raise unittest.SkipTest(f"needs a {cls.BITS}-bit mingw-w64 gcc and Wine")
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = os.path.realpath(cls._tmp.name)
        cls.env = dict(os.environ, WINEDEBUG="-all", LANG="C.UTF-8")
        cls.own_prefix = "WINEPREFIX" not in os.environ
        cls.env.setdefault("WINEPREFIX", os.path.join(cls.root, "prefix"))
        cls.wineserver = _first_file(os.path.join(os.path.dirname(cls.wine), "wineserver"),
                                     shutil.which("wineserver"))
        flags = ["-O2", "-Wall", "-Wextra", "-Werror", "-municode"]
        cls.stub = os.path.join(cls.root, "profile", "game.exe")
        os.makedirs(os.path.dirname(cls.stub))
        subprocess.run([cc, *flags, "-o", cls.stub, SRC], check=True)
        cls.fakegame = os.path.join(cls.root, "fakegame.exe")
        subprocess.run([cc, *flags, "-o", cls.fakegame, os.path.join(HERE, "fakegame.c")], check=True)
        probe = subprocess.run([cls.wine, cls.fakegame], env=cls.env, capture_output=True, timeout=300)
        if probe.returncode != 7:
            cls._tmp.cleanup()
            raise unittest.SkipTest(f"this Wine can't run {cls.BITS}-bit exes "
                                    f"(exit {probe.returncode}; 32-bit needs wine32)")

    @classmethod
    def tearDownClass(cls):
        # Wait for processes the tests left running, but only in our own
        # prefix: in a shared one, wineserver -w would wait for everything.
        if cls.own_prefix and cls.wineserver:
            try:
                subprocess.run([cls.wineserver, "-w"], env=cls.env, timeout=60,
                               stderr=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                subprocess.run([cls.wineserver, "-k"], env=cls.env, stderr=subprocess.DEVNULL)
        cls._tmp.cleanup()

    def setUp(self):
        self.dir = os.path.join(self.root, self._testMethodName)
        os.makedirs(self.dir, exist_ok=True)

    # ── helpers ─────────────────────────────────────────────────────────────

    def game_at(self, *parts):
        path = os.path.join(self.dir, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.copy(self.fakegame, path)
        return path

    def marker(self):
        return os.path.join(self.dir, f"{uuid.uuid4().hex}.done")

    @staticmethod
    def wait_for(path, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(path):
                return True
            time.sleep(0.1)
        return False

    @staticmethod
    def parse(out):
        return dict(line.split("=", 1) for line in out.splitlines()
                    if "=" in line and not line.startswith("["))

    def write_ini(self, ini_text=None, encoding="utf-8", raw=None):
        ini = os.path.join(os.path.dirname(self.stub), "mythix_loader.ini")
        with open(ini, "wb") as f:
            f.write(raw if raw is not None else ini_text.encode(encoding))

    def run_loader(self, ini_text, *args, encoding="utf-8", raw=None, env=None):
        """Returns (exit code, KEY=VALUE lines the game printed, full output, log path)."""
        if ini_text is not None or raw is not None:
            self.write_ini(ini_text, encoding, raw)
        # Output goes to a file, not a pipe: processes the game leaves running
        # inherit it, and reading a pipe to EOF would wait for them too.
        log = os.path.join(self.dir, f"{uuid.uuid4().hex}.log")
        with open(log, "wb") as f:
            try:
                r = subprocess.run([self.wine, self.stub, *args], env=dict(self.env, **(env or {})),
                                   stdout=f, stderr=subprocess.STDOUT, timeout=120)
                code = r.returncode
            except subprocess.TimeoutExpired:
                code = None
        out = self.read(log)
        if code is None:
            self.fail("loader timed out\n" + out)
        return code, self.parse(out), out, log

    @staticmethod
    def read(log):
        with open(log, "rb") as f:
            return f.read().decode("utf-8", "replace")

    def launcher_ini(self, marker, sleep_ms, extra_env="", extra_keys=""):
        exe = self.game_at("launcher", "game.exe")
        win_marker = "Z:" + marker.replace("/", "\\")
        return (f"[MythixLoader]\nExe={exe}\nPersist=1\n{extra_keys}"
                f"EnvVars=FAKE_SPAWN=1;FAKE_SLEEP_MS={sleep_ms};FAKE_MARKER={win_marker}{extra_env}\n")

    # ── basics ──────────────────────────────────────────────────────────────

    def test_non_ascii_path_env_and_args(self):
        exe = self.game_at("Café ゲーム", "bin", "game.exe")
        code, seen, out, _ = self.run_loader(
            f"[MythixLoader]\nExe={exe}\nAppId=480\nEnvVars=MYTHIX_TEST=héllo ; X=1\nPersist=1\n",
            "-dx11", "two words", "--", "--debug")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen.get("CWD", "").endswith("\\Café ゲーム\\bin"), out)
        self.assertEqual((seen.get("ARG1"), seen.get("ARG2"), seen.get("ARG3")),
                         ("-dx11", "two words", "--debug"), out)
        self.assertEqual((seen.get("SteamAppId"), seen.get("SteamGameId")), ("480", "480"), out)
        self.assertEqual(seen.get("MYTHIX_TEST"), "héllo", out)

    def test_bom_crlf_ini_and_appid_zero(self):
        exe = self.game_at("plain", "game.exe")
        ini = f"[MythixLoader]\r\nExe={exe}\r\nAppId=0\r\nPersist=1\r\n"
        code, seen, out, _ = self.run_loader(None, raw=b"\xef\xbb\xbf" + ini.encode())
        self.assertEqual(code, 7, out)
        self.assertEqual(seen.get("SteamAppId"), "<unset>", out)
        self.assertIn("AppId=0 is not a Steam app id", out)

    def test_utf16_and_ansi_inis(self):
        exe = self.game_at("Café", "game.exe")
        ini = f"[MythixLoader]\nExe={exe}\nPersist=1\n"
        code, seen, out, _ = self.run_loader(None, raw=b"\xff\xfe" + ini.encode("utf-16-le"))
        self.assertEqual(code, 7, out)
        code, seen, out, _ = self.run_loader(ini, encoding="cp1252")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen.get("CWD", "").endswith("\\Café"), out)

    def test_explicit_run_dir(self):
        exe = self.game_at("rd", "bin", "game.exe")
        run_dir = os.path.join(self.dir, "rd")
        code, seen, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nExeRunDir={run_dir}\nPersist=1\n")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen.get("CWD", "").endswith("\\rd"), out)

    def test_missing_exe_and_run_dir_errors(self):
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={self.dir}/nope/game.exe\n")
        self.assertEqual(code, 1, out)
        self.assertIn("Check Exe=", out)
        exe = self.game_at("plain", "game.exe")
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nExeRunDir={self.dir}/nodir\n")
        self.assertEqual(code, 1, out)
        self.assertIn("Check ExeRunDir=", out)

    def test_ini_without_exe(self):
        code, _, out, _ = self.run_loader("[Other]\nExe=x\n")
        self.assertEqual(code, 1, out)
        self.assertIn("has no Exe=", out)

    # ── Persist: the exe starts the "real game" and exits at once ──────────

    def test_persist_waits_for_processes_the_game_starts(self):
        marker = self.marker()
        code, seen, out, _ = self.run_loader(self.launcher_ini(marker, 2000))
        self.assertEqual(seen.get("SPAWN"), "ok", out)
        self.assertTrue(os.path.exists(marker), "loader returned before the real game finished\n" + out)
        self.assertEqual(code, 3, out)                  # the exe's own exit code
        self.assertIn("Game exe exited with code 3; still waiting for 1 process(es)", out)
        self.assertIn("launcher\\game.exe", out)        # names what it waits for
        self.assertIn("returning the exe's exit code, 3", out)
        self.assertNotIn("IN_JOB=0", out)               # launcher and game both counted

    def test_wait_for_children_off_waits_for_the_exe_only(self):
        marker = self.marker()
        start = time.monotonic()
        code, seen, out, _ = self.run_loader(self.launcher_ini(marker, 4000, extra_keys="WaitForChildren=0\n"))
        self.assertLess(time.monotonic() - start, 3.5, out)
        self.assertEqual(seen.get("SPAWN"), "ok", out)
        self.assertEqual(code, 3, out)
        self.assertFalse(os.path.exists(marker), out)
        self.assertTrue(self.wait_for(marker), "the real game didn't finish after the loader left")

    def test_unrecognised_boolean_keeps_the_default(self):
        for value in ("yes", "maybe"):
            marker = self.marker()
            code, seen, out, _ = self.run_loader(
                self.launcher_ini(marker, 1500, extra_keys=f"WaitForChildren={value}\n"))
            self.assertTrue(os.path.exists(marker), f"WaitForChildren={value} turned waiting off\n" + out)
            self.assertEqual(value == "maybe", "Warning: WaitForChildren=maybe" in out, out)

    def test_game_can_still_put_its_children_in_a_job_of_its_own(self):
        marker = self.marker()
        code, seen, out, _ = self.run_loader(self.launcher_ini(marker, 2000, ";FAKE_CHILD_JOB=1"))
        self.assertEqual(seen.get("CHILD_JOB"), "ok", out)  # nested jobs (Wine 6.9+/Windows 8+)
        self.assertTrue(os.path.exists(marker), out)

    def test_children_may_break_away(self):
        marker = self.marker()
        code, seen, out, log = self.run_loader(self.launcher_ini(marker, 4000, ";FAKE_BREAKAWAY=1"))
        self.assertEqual(seen.get("SPAWN"), "ok", out)  # would be "failed 5" without BREAKAWAY_OK
        self.assertEqual(code, 3, out)
        self.assertNotIn("Warning", out)
        self.assertNotIn("still waiting", out)
        self.assertFalse(os.path.exists(marker), out)   # it left the job, so not waited for
        self.assertTrue(self.wait_for(marker), out)
        in_job = [line for line in self.read(log).splitlines() if line.startswith("IN_JOB=")]
        self.assertEqual(in_job, ["IN_JOB=1", "IN_JOB=0"], self.read(log))  # launcher in, child out

    def test_relists_what_it_waits_for_when_that_changes(self):
        # launcher (exits at once) -> real game (1.5 s) -> helper it leaves behind (7 s)
        exe = self.game_at("chain", "game.exe")
        marker = self.marker()
        win_marker = "Z:" + marker.replace("/", "\\")
        code, seen, out, _ = self.run_loader(
            f"[MythixLoader]\nExe={exe}\nPersist=1\n"
            f"EnvVars=FAKE_CHAIN=0,1500,7000;FAKE_MARKER={win_marker}\n")
        self.assertEqual(code, 3, out)
        self.assertTrue(os.path.exists(marker), out)
        first = out.find("still waiting for 1 process(es)")
        again = out.find("Still waiting for 1 process(es) the game started:")
        self.assertTrue(0 <= first < again, out)        # the helper gets named after the game exits

    def test_game_survives_the_loader_being_killed(self):
        marker = self.marker()
        self.write_ini(self.launcher_ini(marker, 3000))
        log = os.path.join(self.dir, "killed.log")
        with open(log, "wb") as f:
            p = subprocess.Popen([self.wine, self.stub], env=self.env, stdout=f, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                while "still waiting" not in self.read(log) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertIn("still waiting", self.read(log))
            finally:
                p.kill()
                p.wait()
        self.assertFalse(os.path.exists(marker), self.read(log))
        self.assertTrue(self.wait_for(marker), "the game died with the loader\n" + self.read(log))

    def test_wine_helpers_left_running_dont_hold_the_wait(self):
        # A helper named like one of Wine's, in the prefix's Windows directory,
        # still running long after the game exe exits.
        drive_c = os.path.join(self.env["WINEPREFIX"], "drive_c")
        if not os.path.isdir(drive_c):
            subprocess.run([self.wine, "wineboot", "-i"], env=self.env, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sub = f"mythix-loader-test-{uuid.uuid4().hex[:8]}"
        helper_dir = os.path.join(drive_c, "windows", sub)
        os.makedirs(helper_dir)
        try:
            shutil.copy(self.fakegame, os.path.join(helper_dir, "mscorsvw.exe"))
            ini = self.launcher_ini(self.marker(), 8000, f";FAKE_SPAWN_EXE=C:\\windows\\{sub}\\mscorsvw.exe")
            start = time.monotonic()
            code, seen, out, _ = self.run_loader(ini)
            self.assertLess(time.monotonic() - start, 6, out)
            self.assertIn("Only Wine helper processes are left", out)
            self.assertEqual(code, 3, out)
        finally:
            shutil.rmtree(helper_dir, ignore_errors=True)

    def test_no_persist_returns_at_once(self):
        marker = self.marker()
        ini = self.launcher_ini(marker, 4000).replace("Persist=1", "Persist=0")
        start = time.monotonic()
        code, seen, out, _ = self.run_loader(ini)
        self.assertLess(time.monotonic() - start, 3.5, out)
        self.assertEqual(code, 0, out)
        self.assertNotIn("Warning", out)
        self.assertFalse(os.path.exists(marker), out)
        self.assertTrue(self.wait_for(marker), "the game never ran to completion")


    # ── v1.5 keys ───────────────────────────────────────────────────────────

    def profile_dir(self):
        return os.path.dirname(self.stub)

    def test_log_file_is_written_next_to_the_ini(self):
        exe = self.game_at("plain", "game.exe")
        log_name = f"{self._testMethodName}.log"
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nLogFile={log_name}\n")
        self.assertEqual(code, 7, out)
        with open(os.path.join(self.profile_dir(), log_name), encoding="utf-8") as f:
            logged = f.read()
        self.assertRegex(logged, r"^\d\d:\d\d:\d\d\.\d{3} \[mythix-loader\] Mythix Loader v1\.5")
        self.assertIn("Game exited with code 7", logged)

    def test_crash_codes_are_named(self):
        exe = self.game_at("plain", "game.exe")
        _, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nEnvVars=FAKE_EXIT=C0000005\n")
        self.assertIn("Game exited with code 0xC0000005 (access violation: the game crashed)", out)

    def test_vars_and_paths_relative_to_the_ini(self):
        # The ini sits in its own folder, away from the stub, and is given with --ini.
        ini_dir = os.path.join(self.dir, "elsewhere")
        os.makedirs(os.path.join(ini_dir, "rd"))
        shutil.copy(self.fakegame, os.path.join(ini_dir, "fg.exe"))
        ini = os.path.join(ini_dir, "my.ini")
        with open(ini, "w", encoding="utf-8") as f:
            f.write("[MythixLoader]\nExe=fg.exe\nExeRunDir=rd\nExeCommandLine=%MYTHIX_PROFILE_DIR%\n"
                    "AppId=480\nEnvVars=A=1;MYTHIX_TEST=%MYTHIX_GAME_DIR%|%A%|%SteamAppId%\nPersist=1\n")
        code, seen, out, _ = self.run_loader(None, "--ini", "Z:" + ini.replace("/", "\\"))
        self.assertEqual(code, 7, out)
        win_dir = "Z:" + ini_dir.replace("/", "\\")
        self.assertEqual(seen.get("ARG1"), win_dir, out)
        self.assertEqual(seen.get("MYTHIX_TEST"), f"{win_dir}|1|480", out)  # Windows-form game dir
        self.assertEqual(seen.get("CWD"), win_dir + "\\rd", out)

    def test_env_removal_and_empty_values(self):
        exe = self.game_at("plain", "game.exe")
        base = f"[MythixLoader]\nExe={exe}\nPersist=1\n"
        _, seen, out, _ = self.run_loader(base + "EnvVars=-MYTHIX_TEST\n", env={"MYTHIX_TEST": "outside"})
        self.assertEqual(seen.get("MYTHIX_TEST"), "<unset>", out)
        _, seen, out, _ = self.run_loader(base + "EnvVars=MYTHIX_TEST=x;-MYTHIX_TEST\n")
        self.assertEqual(seen.get("MYTHIX_TEST"), "<unset>", out)
        _, seen, out, _ = self.run_loader(base + "EnvVars=MYTHIX_TEST=\n", env={"MYTHIX_TEST": "outside"})
        self.assertEqual(seen.get("MYTHIX_TEST"), "", out)     # set to empty, not removed

    def test_semicolons_stay_in_env_values(self):
        exe = self.game_at("plain", "game.exe")
        _, seen, out, _ = self.run_loader(
            f"[MythixLoader]\nExe={exe}\nPersist=1\nEnvVars=B=x;MYTHIX_TEST=%B%;C:\\tools;D=1\n")
        self.assertEqual(seen.get("MYTHIX_TEST"), "x;C:\\tools", out)

    def test_log_file_can_use_the_game_dir(self):
        exe = self.game_at("logged", "game.exe")
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\n"
                                          "LogFile=%MYTHIX_GAME_DIR%\\%SteamAppId%-run.log\nAppId=480\n")
        self.assertEqual(code, 7, out)
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "logged", "480-run.log")), out)

    def test_priority_and_affinity_reach_the_game_and_its_children(self):
        marker = self.marker()
        code, seen, out, log = self.run_loader(self.launcher_ini(marker, 1000, extra_keys="Priority=high\nAffinity=0\n"))
        self.assertTrue(os.path.exists(marker), out)
        lines = self.read(log).splitlines()
        # launcher and its child: HIGH_PRIORITY_CLASS and CPU 0 for both
        self.assertEqual([l for l in lines if l.startswith("PRIORITY=")][0], "PRIORITY=0x80", out)
        # the child is set a moment after it starts, so check what it ends with
        self.assertEqual([l for l in lines if l.startswith("PRIORITY_END=")], ["PRIORITY_END=0x80"], out)
        self.assertEqual([l for l in lines if l.startswith("AFFINITY=")], ["AFFINITY=0x1"] * 2, out)

    def test_affinity_syntax(self):
        if (os.cpu_count() or 1) < 2:
            self.skipTest("needs at least 2 CPUs")
        exe = self.game_at("plain", "game.exe")
        for value, mask in (("1", "0x2"), ("0-1", "0x3"), ("0, 1", "0x3"), ("0x2", "0x2")):
            _, seen, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nAffinity={value}\n")
            self.assertEqual(seen.get("AFFINITY"), mask, f"Affinity={value}\n{out}")
        _, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nAffinity=0x1FFFFFFFFFFFFFFFF\n")
        self.assertIn("is wider than this build's", out)
        _, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nAffinity=-1\n")
        self.assertIn("Warning: Affinity=-1", out)

    def test_bad_priority_and_affinity_only_warn(self):
        exe = self.game_at("plain", "game.exe")
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nPriority=turbo\nAffinity=x\n")
        self.assertEqual(code, 7, out)
        self.assertIn("Warning: Priority=turbo", out)
        self.assertIn("Warning: Affinity=x", out)

    def test_run_before_and_after(self):
        exe = self.game_at("plain", "game.exe")
        ini = (f"[MythixLoader]\nExe={exe}\nPersist=1\nAppId=480\n"
               f'RunBefore="{self.fakegame}" before\nRunAfter="{self.fakegame}" after\n')
        code, _, out, _ = self.run_loader(ini)
        self.assertEqual(code, 7, out)
        order = [out.find(t) for t in ("ARG1=before", "Game launched", "Game exited", "ARG1=after")]
        self.assertTrue(-1 < order[0] < order[1] < order[2] < order[3], out)
        self.assertIn("RunBefore exited with code 7", out)
        before = out[:order[0]].splitlines()
        self.assertTrue(before[-1].endswith("\\plain"), out)   # CWD line: the game's working dir
        self.assertIn("SteamAppId=480", out[order[0]:order[1]])  # the game's environment
        _, _, out, _ = self.run_loader(ini.replace("Persist=1", "Persist=0"))
        self.assertIn("RunAfter needs Persist=1", out)
        self.assertNotIn("ARG1=after", out)
        _, _, out, _ = self.run_loader(ini.replace(f"Exe={exe}", f"Exe={self.dir}/missing.exe"))
        self.assertIn("The game didn't start; running RunAfter anyway", out)
        self.assertIn("ARG1=after", out)

    def test_run_command_with_quoted_program_and_argument(self):
        tool = os.path.join(self.dir, "tools dir", "tool.exe")
        os.makedirs(os.path.dirname(tool))
        shutil.copy(self.fakegame, tool)
        exe = self.game_at("plain", "game.exe")
        _, _, out, _ = self.run_loader(f'[MythixLoader]\nExe={exe}\nPersist=1\nRunBefore="{tool}" "arg one"\n')
        self.assertIn("ARG1=arg one", out)
        self.assertNotIn("couldn't start", out)

    def test_run_command_can_start_a_linux_program(self):
        exe = self.game_at("plain", "game.exe")
        code, _, out, _ = self.run_loader(f"[MythixLoader]\nExe={exe}\nPersist=1\nRunBefore=/bin/true\n")
        self.assertEqual(code, 7, out)
        self.assertIn("RunBefore started a Linux program", out)

    def test_single_instance_waits_for_the_running_copy(self):
        exe = self.game_at("plain", "game.exe")
        marker = self.marker()
        win_marker = "Z:" + marker.replace("/", "\\")
        log_name = f"{self._testMethodName}.log"
        self.write_ini(f"[MythixLoader]\nExe={exe}\nPersist=1\nSingleInstance=1\nLogFile={log_name}\n"
                       f"EnvVars=FAKE_SLEEP_MS=4000;FAKE_MARKER={win_marker}\n")
        first_log = os.path.join(self.dir, "first.log")
        with open(first_log, "wb") as f:
            first = subprocess.Popen([self.wine, self.stub], env=self.env, stdout=f, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                while "Game launched" not in self.read(first_log) and time.monotonic() < deadline:
                    time.sleep(0.1)
                code, _, out, _ = self.run_loader(None)         # same ini, second launch
                game_done_when_second_returned = os.path.exists(marker)
            finally:
                first.wait(timeout=120)
        self.assertEqual(code, 0, out)
        self.assertIn("already running; not starting a second copy", out)
        self.assertNotIn("Launching:", out)
        self.assertTrue(game_done_when_second_returned, "the second launch didn't wait for the first game")
        self.assertEqual(self.read(first_log).count("Game launched"), 1)
        with open(os.path.join(self.profile_dir(), log_name), encoding="utf-8") as f:
            shared = f.read()
        self.assertLess(shared.index("Game launched"), shared.index("already running"), shared)
        self.assertLess(shared.index("already running"), shared.index("Game exited"), shared)


class LoaderUnderWine64(LoaderUnderWine, unittest.TestCase):
    BITS = 64


class LoaderUnderWine32(LoaderUnderWine, unittest.TestCase):
    BITS = 32


if __name__ == "__main__":
    unittest.main()
