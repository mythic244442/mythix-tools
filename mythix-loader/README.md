# mythix-loader

Launches Steam games you own from a profile kept outside the game folder.
A profile is a copy of the small `mythix_loader.exe` stub plus a
`mythix_loader.ini`. The stub sets `SteamAppId` (the same variable Steam sets
when it starts a game) and starts the game's exe. The game's own steam_api
then talks to your running Steam client, and Steam does the ownership check.
Nothing in the game folder is changed or copied.

The Steam client has to be running: the native Linux one. Under neutron (or
Proton) the game reaches it through the prefix's `steam.exe` shim and
lsteamclient, which neutron uses when `SteamAppId`/`SteamGameId` is a real app
id and Steam is up. Without Steam, or for a game the account doesn't own, the
game's Steam init fails just as it would anywhere else.

## Layout

```
mythix-loader/
  mythix-loader          profile manager (Python 3, no dependencies)
  mythix_loader.exe      64-bit loader stub
  mythix_loader_32.exe   32-bit loader stub (for 32-bit-only prefixes)
  src/                   loader source + Makefile
  tests/                 unit tests, plus loader tests run under Wine
```

## Usage

```sh
mythix-loader --games                      # installed titles in your Steam libraries
mythix-loader "<install dir>"              # create/refresh a profile
mythix-loader "<install dir>" --dry-run    # show the plan, write nothing
mythix-loader "<install dir>" --exe bin/Game.exe --name mygame
mythix-loader --launch-info appid          # Steam's launch entries for an appid
mythix-loader --list                       # existing profiles
mythix-loader --saves <profile>            # symlink the game's saves into the profile
mythix-loader --saves <profile> --copy     # ...snapshot a copy instead
mythix-loader --setup                      # check loader exes + Steam install
```

`--json` prints a single result object on stdout (human output goes to
stderr). The Mythix launcher uses it for profile creation. `--require-appid`
makes it fail, writing nothing, when the game's appid can't be found, instead
of creating a profile with `AppId=0`.

Profiles live in `~/.mythix/loader_profiles/<name>/`. The Mythix launcher
launches them itself. By hand:

```sh
SteamAppId=<appid> <compat_tool>/neutron waitforexitandrun "<profile>/<stub>.exe" [game args...]
```

`SteamAppId` matters here: without it neutron skips its `steam.exe` shim,
which is what registers the Steam client for the game.

## Profile folder

```
<name>/
  <stub>.exe           the loader (a copy of mythix_loader.exe)
  mythix_loader.ini    the settings below
  last_run.ini         the most recent launch's result (LastRun)
  logs/                recent launch logs (LogHistory)
  saves/               the game's save folders (filled by --saves)
  scripts/             RunBefore/RunAfter helpers, with a commented example.bat
  README.txt           a plain-text summary of this profile
```

The loader itself only needs the stub and the ini; the rest is written by
`mythix-loader` and filled in as the game runs, and all of it is safe to
delete. Re-running `mythix-loader` on the game recreates the folders and
`README.txt` and leaves `scripts/example.bat` alone once you've edited it.

## Saves

`mythix-loader --saves <profile>` finds where the game keeps its saves and
drops them into the profile's `saves/` folder, so they're one click away (and
easy to back up). It never changes or deletes your real saves.

Save locations come from Steam itself: each game's cloud-save (UFS) config in
`appinfo.vdf` lists the folders it saves to (`WinMyDocuments`,
`WinAppDataRoaming`, `WinSavedGames`, the install dir, …), which the manager
resolves against the game's Proton prefix
(`steamapps/compatdata/<appid>/pfx`). A game with no cloud config falls back to
a careful name match in the prefix's user folders. The game has to have run at
least once (so the prefix and saves exist).

- By default each save folder is **symlinked** into `saves/<name>` — live, no
  duplication, and editing through it edits the real saves.
- `--copy` instead writes a **snapshot** into `saves/backups/<timestamp>/` — a
  real, separate backup you can keep or restore by hand.
- It's safe to re-run: a symlink that already points at the right place is left
  alone, and a real folder you've put in `saves/` yourself is never overwritten.
- `--json` prints the result (used by the launcher).

## mythix_loader.ini

```ini
[MythixLoader]
Exe=/path/to/Game.exe
ExeRunDir=/path/to/workdir
ExeCommandLine=
AppId=480
EnvVars=DXVK_HUD=fps;-SOME_VAR
Persist=1
WaitForChildren=1
SingleInstance=1
Priority=
Affinity=
RunBefore=
RunAfter=
LogFile=mythix_loader.log
LogHistory=10
LastRun=1
ShowConsole=0
Debug=0
ExtraDlls=
```

Comments go on their own lines (`#` or `;` first). Anything after `=` is the
value, so don't put a comment at the end of a line.

| Key | Default when missing | What it does |
|---|---|---|
| `Exe` | (required) | The game exe |
| `ExeRunDir` | the exe's folder | The game's working directory |
| `ExeCommandLine` | | Arguments always passed to the game |
| `AppId` | | Exported as `SteamAppId`/`SteamGameId`/`SteamOverlayGameId` (0 = not set) |
| `EnvVars` | | `KEY=VAL;KEY2=VAL2` for the game; `-NAME` removes a variable |
| `Persist` | 0 | Wait for the game and return the exe's exit code |
| `WaitForChildren` | 1 | ...and for every process it starts (0 = the exe only) |
| `SingleInstance` | 0 | A second launch of this profile waits for the running game instead of starting another |
| `Priority` | | `idle`, `belownormal`, `normal`, `abovenormal` or `high` |
| `Affinity` | | CPU cores, e.g. `0` or `0,2-3`, or a mask like `0x5` |
| `RunBefore` | | Command run, and waited for, before the game |
| `RunAfter` | | Command run after the game exits (needs `Persist=1`) |
| `LogFile` | (none) | The loader's log, also written to this file |
| `LogHistory` | 10 | How many previous logs to keep in a `logs/` folder (0 = stop archiving) |
| `LastRun` | 1 | Write `last_run.ini` (time, duration, exit code) after each launch |
| `ShowConsole` | 0 | Open a console window with the game's output; waits for a key at the end |
| `Debug` | 0 | More detail in the log |
| `ExtraDlls` | | DLLs loaded into the loader process only, **not** the game |

New profiles get `Persist=1`, `SingleInstance=1` and
`LogFile=mythix_loader.log`. To turn something off, set it to 0 or leave it
empty: a key you delete comes back with its default when the profile is
refreshed.

Values can use `%VARS%`, expanded the Windows way (a name that isn't set stays
as written, so a lone `%` in a path is fine). Besides the normal environment
there are `%MYTHIX_PROFILE_DIR%` (the ini's folder), `%MYTHIX_GAME_DIR%` (the
exe's folder), both in Windows form (`Z:\...`), and `%SteamAppId%`. `EnvVars`
entries can use the ones before them, and every other key can use the
`EnvVars` names, except `Exe`, which only gets the environment and
`%MYTHIX_PROFILE_DIR%`. In `EnvVars`, a `;` only starts a new entry when a
`NAME=` (or `-NAME`) follows, so `PATH=%PATH%;C:\tools` works. Relative paths in
`Exe`, `ExeRunDir` and `LogFile` are relative to the ini's folder, so a profile
can move.

- **LogFile** gets every loader line with a time stamp, and is emptied at each
  launch. It's useful under the Mythix launcher, which discards the loader's
  output unless `MYTHIX_CAPTURE_GAME_OUTPUT=1` is set. Exit codes that mean a
  crash are named, e.g. `0xC0000005 (access violation: the game crashed)`.
- **LogHistory** keeps the last few launches around: before a run empties
  `LogFile`, the previous one is moved into a `logs/` folder beside it, named
  with its own time stamp, and only the newest `LogHistory` are kept. The live
  log stays at `LogFile`; `logs/` holds the runs before it. `0` stops archiving
  (any logs already in `logs/` are left alone). Pruning goes by each file's
  own time, so a rapid relaunch never drops the newest.
- **LastRun** writes `last_run.ini` in the profile folder after each launch — a
  small machine-readable record (start and finish time, duration, and, when the
  loader waited, the exit code and what it means) for the Mythix launcher to
  read. It's overwritten each run and safe to delete; set `LastRun=0` to skip it.
- **ShowConsole** opens a console window the loader owns and hands the game its
  output, so the game's own stdout/stderr and Wine's debug channels show up live
  — under any compat tool, not only Proton. The loader's own lines appear there
  too, and after the game exits the window waits for a key so you can read it.
  To see Wine's debug channels, set them yourself, e.g.
  `EnvVars=WINEDEBUG=+warn,+seh`. It needs a real desktop console: where output
  is redirected or there's no display (a headless run), it does nothing and the
  launch is unchanged. Under neutron the window keeps the Steam session marked
  "running" until you close it (that's the point — it stays up for you to read).
- **SingleInstance** stops a second copy of the same profile while the game is
  still running. The second launch adds a note to the log, waits for the
  running one, and then exits without starting anything. Waiting (instead of
  exiting at once) keeps neutron from treating the second launch as finished
  and cleaning up the prefix 30 s later. Needs `Persist=1`.
- **Priority** and **Affinity** apply to the game exe and, while the loader
  follows the game's processes, to everything it starts. One core
  (`Affinity=0`) is a classic fix for old games that glitch on many cores.
  Under Wine the priority class is set (the game sees it), but it usually
  doesn't change real CPU scheduling.
- **RunBefore** / **RunAfter** run a Windows command line in the game's
  working directory, with the game's environment, and wait for it. A bare name
  (e.g. `backup.bat`) is looked up in the profile's own `scripts/` folder
  first, then next to the loader and on `PATH` — never in the game folder; or
  give a full path, or `%MYTHIX_GAME_DIR%\tool.exe`. `.bat` and `.cmd` scripts
  are run through the command processor, so they work too. Quote paths with
  spaces: `"C:\tools dir\backup.exe" "%MYTHIX_GAME_DIR%"`. Under Wine a Linux
  program or script can be started too, but the loader can't wait for it or see
  its exit code. `RunAfter` runs once the game has exited, or right away if it
  couldn't start. Avoid commands that leave something running: through
  neutron's `steam.exe` shim that keeps the session alive, and after a direct
  launch neutron kills it with the prefix.
- **ExtraDlls** loads DLLs into the loader process itself, never into the
  game, so it doesn't change how the game runs. It's there for troubleshooting
  the loader (for example, checking a DLL loads in that prefix), and the log
  names each one. A DLL that crashes or hangs while loading stops the launch.

With `Persist=1` the loader waits until the game exe and the processes it
starts (and theirs) have exited, so a launcher exe that starts the real game
and quits doesn't end the wait early. The game runs in a job object, which
only does the counting: it sets no limits, nothing gets killed, and if the
loader itself is killed the game keeps running. The game's own job objects
(CEF and the like) still work. Two kinds of process aren't waited for: a
child started with `CREATE_BREAKAWAY_FROM_JOB` (it starts fine but leaves the
job), and anything a program that was already running starts for the game,
such as an already-open launcher or a Windows service. Then the loader returns
once the game's own processes are gone. The exit code is always the exe's
own, so for a launcher exe it's the launcher's.

When the exe exits while its processes are still running, the loader lists
them, and lists them again if one it named exits while the wait goes on. If
one of them never exits, close it. Wine's own helpers that a game can start
(`dllhost.exe`, `conhost.exe`, `explorer.exe` and similar, from the Windows
directory) don't hold the wait once the game exe has exited; `dllhost.exe`
would otherwise never let it finish. They're left running, not killed.

Following the processes a game starts needs Wine 6.9 or newer (any current
Proton) or Windows 8 or newer; elsewhere the loader says so and waits for the
exe only. `WaitForChildren=0` asks for that on purpose; it defaults to 1, also
when the key is missing.

Under neutron the stub's wait doesn't decide when the session ends. Through
neutron's `steam.exe` shim (the normal case) the session lasts until every
process in the prefix has exited, whatever these keys say. In a direct launch
neutron kills whatever is left in the prefix (`wineserver -k`) 30 s after the
stub exits, so keep `WaitForChildren=1` there: with 0 and a launcher exe, the
real game would be killed.

The ini is UTF-8 (a BOM is fine; UTF-16 and legacy ANSI files also load).
`/home/...` paths work under Wine. Arguments given to the stub are added after
`ExeCommandLine`, apart from the loader's own `--ini <path>` and `--debug`.
Everything after `--` goes to the game unchanged.

The profile manager sets `ExeRunDir` to the working dir Steam's launch config
gives for that exe, or to the exe's own folder.

Keys from older profiles (`SteamClientDll`, `SteamClient64Dll`,
`SteamClientSo`, `SteamClient64So`, `ForceArch`, `NoInject`) are ignored.
Re-running `mythix-loader` on a game refreshes its profile: it rewrites `Exe`,
`ExeRunDir` and `AppId` from the game, keeps every other setting already in
the ini (and keys it doesn't know, at the end), copies in the current stub and
removes the old `client/` steamclient copies. That's how an existing profile
picks up a loader update; editing an old profile's ini doesn't update its
stub.

## Building and testing

```sh
cd src && make                                  # needs mingw-w64; writes ../*.exe
python3 -m unittest discover -s tests -v        # from mythix-loader/
```

The Wine tests build the loader and a stand-in game, then check the working
dir, arguments and environment the game receives, and how Persist behaves
with launcher-style games. They run for the 64-bit stub (needs
`x86_64-w64-mingw32-gcc` and Wine) and the 32-bit one (needs
`i686-w64-mingw32-gcc` and 32-bit Wine, e.g. the `wine32` package); each
skips itself when its tools are missing. Each makes a throwaway prefix; set
`WINEPREFIX` to reuse one.
