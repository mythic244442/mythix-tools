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
mythix-loader --launch-info 1091500        # Steam's launch entries for an appid
mythix-loader --list                       # existing profiles
mythix-loader --setup                      # check loader exes + Steam install
```

`--json` prints a single result object on stdout (human output goes to
stderr). The Mythix launcher uses it for profile creation.

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
EnvVars=KEY=VAL;KEY2=VAL2    ; extra environment for the game
ExtraDlls=                   ; DLLs loaded into the loader process (not the game)
Persist=1                    ; wait for the game and return the exe's exit code
WaitForChildren=1            ; ...and for every process it starts (0 = the exe only)
Debug=0
```

With `Persist=1` the loader waits until the game exe and everything it starts
have exited, so a launcher exe that starts the real game and quits doesn't end
the wait early. The game runs in a job object, which only does the counting:
it sets no limits, nothing gets killed, and the game's own job objects (CEF
and the like) and `CREATE_BREAKAWAY_FROM_JOB` children work as normal. When the
exe exits while other processes are still running, the loader lists them. If
one never exits (a tray helper, say), set `WaitForChildren=0`.

The ini is UTF-8 (a BOM is fine; UTF-16 and legacy ANSI files also load).
`/home/...` paths work under Wine. Arguments given to the stub are added after
`ExeCommandLine`, apart from the loader's own `--ini <path>` and `--debug`.
Everything after `--` goes to the game unchanged.

The profile manager sets `ExeRunDir` to the working dir Steam's launch config
gives for that exe, or to the exe's own folder.

Keys from older profiles (`SteamClientDll`, `SteamClient64Dll`,
`SteamClientSo`, `SteamClient64So`, `ForceArch`, `NoInject`) are ignored.
Re-running `mythix-loader` on a game refreshes its profile: it writes the new
ini and removes the old `client/` steamclient copies.

## Building and testing

```sh
cd src && make                                  # needs mingw-w64; writes ../*.exe
python3 -m unittest discover -s tests -v        # from mythix-loader/
```

The Wine tests build the loader and a stand-in game, then check the working
dir, arguments and environment the game receives. They need
`x86_64-w64-mingw32-gcc` and a 64-bit Wine, and skip themselves otherwise.
Set `WINEPREFIX` to reuse an existing prefix.
