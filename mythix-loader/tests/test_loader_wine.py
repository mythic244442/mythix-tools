"""End-to-end tests for mythix_loader.exe, run under Wine.

Builds the 64-bit loader and a stand-in game (fakegame.c) with mingw-w64,
then launches through the loader and checks what the game saw. Skipped when
x86_64-w64-mingw32-gcc or a 64-bit Wine isn't installed. Set WINEPREFIX to
reuse an existing prefix; otherwise a throwaway one is created (slow once).

    python3 -m unittest discover -s mythix-loader/tests
"""

import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src", "mythix_loader.c")
CC = shutil.which("x86_64-w64-mingw32-gcc")
WINE = next((w for w in (shutil.which("wine64"), "/usr/lib/wine/wine64", shutil.which("wine"))
             if w and os.path.isfile(w)), None)


@unittest.skipUnless(CC and WINE, "needs x86_64-w64-mingw32-gcc and 64-bit wine")
class LoaderUnderWineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = os.path.realpath(cls._tmp.name)
        cls.env = dict(os.environ, WINEDEBUG="-all", LANG="C.UTF-8")
        cls.env.setdefault("WINEPREFIX", os.path.join(cls.root, "prefix"))
        cls.profile = os.path.join(cls.root, "profile")
        os.makedirs(cls.profile)
        cls.stub = os.path.join(cls.profile, "game.exe")
        flags = ["-O2", "-Wall", "-Wextra", "-Werror", "-municode"]
        subprocess.run([CC, *flags, "-o", cls.stub, SRC], check=True)
        cls.fakegame = os.path.join(cls.root, "fakegame.exe")
        subprocess.run([CC, *flags, "-o", cls.fakegame, os.path.join(HERE, "fakegame.c")], check=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run([os.path.join(os.path.dirname(WINE), "wineserver"), "-w"],
                       env=cls.env, check=False, stderr=subprocess.DEVNULL)
        cls._tmp.cleanup()

    def game_at(self, *parts):
        path = os.path.join(self.root, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.copy(self.fakegame, path)
        return path

    def run_loader(self, ini_text, *args, encoding="utf-8", raw=None):
        ini = os.path.join(self.profile, "mythix_loader.ini")
        with open(ini, "wb") as f:
            f.write(raw if raw is not None else ini_text.encode(encoding))
        # Output goes to a file, not a pipe: processes the game leaves running
        # inherit it, and reading a pipe to EOF would wait for them too.
        with tempfile.TemporaryFile() as log:
            r = subprocess.run([WINE, self.stub, *args], env=self.env, stdout=log,
                               stderr=subprocess.STDOUT, timeout=120)
            log.seek(0)
            out = log.read().decode("utf-8", "replace")
        seen = dict(line.split("=", 1) for line in out.splitlines() if "=" in line and not line.startswith("["))
        return r.returncode, seen, out

    def test_non_ascii_path_env_and_args(self):
        exe = self.game_at("Café ゲーム", "bin", "game.exe")
        code, seen, out = self.run_loader(
            f"[MythixLoader]\nExe={exe}\nAppId=480\nEnvVars=MYTHIX_TEST=héllo ; X=1\nPersist=1\n",
            "-dx11", "two words", "--", "--debug")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen["CWD"].endswith("\\Café ゲーム\\bin"), out)
        self.assertEqual((seen["ARG1"], seen["ARG2"], seen["ARG3"]), ("-dx11", "two words", "--debug"))
        self.assertEqual((seen["SteamAppId"], seen["SteamGameId"]), ("480", "480"))
        self.assertEqual(seen["MYTHIX_TEST"], "héllo")

    def test_bom_crlf_ini_and_appid_zero(self):
        exe = self.game_at("plain", "game.exe")
        ini = f"[MythixLoader]\r\nExe={exe}\r\nAppId=0\r\nPersist=1\r\n"
        code, seen, out = self.run_loader(None, raw=b"\xef\xbb\xbf" + ini.encode())
        self.assertEqual(code, 7, out)
        self.assertEqual(seen["SteamAppId"], "<unset>")
        self.assertIn("AppId=0 is not a Steam app id", out)

    def test_utf16_and_ansi_inis(self):
        exe = self.game_at("Café", "game.exe")
        ini = f"[MythixLoader]\nExe={exe}\nPersist=1\n"
        code, seen, out = self.run_loader(None, raw=b"\xff\xfe" + ini.encode("utf-16-le"))
        self.assertEqual(code, 7, out)
        code, seen, out = self.run_loader(ini, encoding="cp1252")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen["CWD"].endswith("\\Café"), out)

    def test_explicit_run_dir(self):
        exe = self.game_at("rd", "bin", "game.exe")
        run_dir = os.path.join(self.root, "rd")
        code, seen, out = self.run_loader(f"[MythixLoader]\nExe={exe}\nExeRunDir={run_dir}\nPersist=1\n")
        self.assertEqual(code, 7, out)
        self.assertTrue(seen["CWD"].endswith("\\rd"), out)

    def test_missing_exe_and_run_dir_errors(self):
        code, _, out = self.run_loader(f"[MythixLoader]\nExe={self.root}/nope/game.exe\n")
        self.assertEqual(code, 1)
        self.assertIn("Check Exe=", out)
        exe = self.game_at("plain", "game.exe")
        code, _, out = self.run_loader(f"[MythixLoader]\nExe={exe}\nExeRunDir={self.root}/nodir\n")
        self.assertEqual(code, 1)
        self.assertIn("Check ExeRunDir=", out)

    def test_ini_without_exe(self):
        code, _, out = self.run_loader("[Other]\nExe=x\n")
        self.assertEqual(code, 1)
        self.assertIn("has no Exe=", out)

    # ── Persist: the exe starts the "real game" and exits at once ──────────

    def launcher_ini(self, marker, sleep_ms, extra_env="", extra_keys=""):
        exe = self.game_at("launcher", "game.exe")
        win_marker = "Z:" + marker.replace("/", "\\")
        return (f"[MythixLoader]\nExe={exe}\nPersist=1\n{extra_keys}"
                f"EnvVars=FAKE_SPAWN=1;FAKE_SLEEP_MS={sleep_ms};FAKE_MARKER={win_marker}{extra_env}\n")

    def test_persist_waits_for_processes_the_game_starts(self):
        marker = os.path.join(self.root, "tree.done")
        code, seen, out = self.run_loader(self.launcher_ini(marker, 2000))
        self.assertEqual(seen["SPAWN"], "ok", out)
        self.assertTrue(os.path.exists(marker), "loader returned before the real game finished\n" + out)
        self.assertEqual(code, 3, out)                  # the exe's own exit code
        self.assertIn("still waiting for 1 process(es)", out)
        self.assertIn("launcher\\game.exe", out)        # names what it waits for

    def test_wait_for_children_off_waits_for_the_exe_only(self):
        marker = os.path.join(self.root, "exe-only.done")
        code, seen, out = self.run_loader(self.launcher_ini(marker, 4000, extra_keys="WaitForChildren=0\n"))
        self.assertEqual(seen["SPAWN"], "ok", out)
        self.assertEqual(code, 3, out)
        self.assertFalse(os.path.exists(marker), out)

    def test_game_can_still_put_its_children_in_a_job_of_its_own(self):
        marker = os.path.join(self.root, "nested.done")
        code, seen, out = self.run_loader(self.launcher_ini(marker, 2000, ";FAKE_CHILD_JOB=1"))
        self.assertEqual(seen["CHILD_JOB"], "ok", out)  # nested jobs, as Chromium/CEF use
        self.assertTrue(os.path.exists(marker), out)

    def test_children_may_break_away(self):
        marker = os.path.join(self.root, "breakaway.done")
        code, seen, out = self.run_loader(self.launcher_ini(marker, 4000, ";FAKE_BREAKAWAY=1"))
        self.assertEqual(seen["SPAWN"], "ok", out)      # would be "failed 5" without BREAKAWAY_OK
        self.assertEqual(code, 3, out)
        self.assertFalse(os.path.exists(marker), out)   # it left the job, so not waited for

    def test_no_persist_returns_at_once(self):
        marker = os.path.join(self.root, "nopersist.done")
        ini = self.launcher_ini(marker, 4000).replace("Persist=1", "Persist=0")
        code, seen, out = self.run_loader(ini)
        self.assertEqual(code, 0, out)
        self.assertNotIn("Warning", out)
        self.assertFalse(os.path.exists(marker), out)


if __name__ == "__main__":
    unittest.main()
