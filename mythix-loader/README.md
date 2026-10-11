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

## mythix_loader.ini

```ini
[MythixLoader]
Exe=/path/to/Game.exe        ; required
ExeRunDir=/path/to/workdir   ; game's working dir (default: the exe's folder)
ExeCommandLine=              ; args always passed to the game
AppId=480                    ; exported as SteamAppId/SteamGameId (0 = not set)
EnvVars=KEY=VAL;-KEY2        ; extra environment for the game; -NAME removes one
Persist=1                    ; wait for the game and return the exe's exit code
WaitForChildren=1            ; ...and for every process it starts (0 = the exe only)
SingleInstance=1             ; a second launch waits for the running game instead
Priority=                    ; idle, belownormal, normal, abovenormal or high
Affinity=                    ; CPU cores, e.g. 0 or 0,2-3 (or a mask like 0x5)
RunBefore=                   ; command run (and waited for) before the game
RunAfter=                    ; command run after the game exits (needs Persist=1)
LogFile=mythix_loader.log    ; the loader's log, also written here; empty = none
Debug=0                      ; more detail in the log
ExtraDlls=                   ; DLLs loaded into the loader process only, NOT the game
```

Values can use `%VARS%`, expanded the Windows way (a name that isn't set
stays as written). Besides the normal environment there are
`%MYTHIX_PROFILE_DIR%` (the ini's folder), `%MYTHIX_GAME_DIR%` (the exe's
folder) and `%SteamAppId%`; `EnvVars` entries can use the ones before them.
Relative paths in `Exe`, `ExeRunDir` and `LogFile` are relative to the ini's
folder, so a profile can move.

- **LogFile** gets every loader line with a time stamp, overwritten each
  launch. Useful under the Mythix launcher, which discards the loader's
  output unless `MYTHIX_CAPTURE_GAME_OUTPUT=1` is set. Exit codes that mean a
  crash are named, e.g. `0xC0000005 (access violation: the game crashed)`.
- **SingleInstance** stops a second copy of the same profile while the game
  is still running. The second launch waits for the running one and then
  exits without starting anything. Waiting (instead of exiting at once) keeps
  neutron from treating the second launch as finished and cleaning up the
  prefix 30 s later. Needs `Persist=1`.
- **Priority** and **Affinity** apply to the game exe and, while the loader
  follows the game's processes, to everything it starts. One core
  (`Affinity=0`) is a classic fix for old games that glitch on many cores.
  Under Wine the priority class is set, but how much it changes real
  scheduling depends on your system.
- **RunBefore** / **RunAfter** run a Windows command line in the game's
  working directory, with the game's environment, and wait for it. To start
  something without waiting, use `cmd /c start "" thing.exe`. `RunAfter` only
  runs if the game launched and `Persist=1`.
- **ExtraDlls** loads DLLs into the loader process itself, never into the
  game, so it doesn't change how the game runs. It's only there for
  troubleshooting the loader (for example, checking a DLL loads in that
  prefix), and the log says so when it's used.

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
