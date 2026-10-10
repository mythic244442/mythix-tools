/*
 * mythix_loader.exe — Mythix Steamclient Loader
 *
 * Custom game launcher for games you own. Reads mythix_loader.ini, sets the
 * Steam app id in the environment (the same mechanism Steam itself uses) and
 * launches the target game exe. The real steamclient — talking to a running
 * Steam client — does the ownership check; this loader does not bypass anything
 * and does not touch game files.
 *
 * Arguments given to the loader itself (other than --ini <path> and --debug) are
 * passed on to the game after ExeCommandLine, so per-game launch args set in the
 * Mythix launcher (e.g. -dx11) reach it.
 *
 * v1.3: no longer points its DLL search at a copied steamclient folder. The
 *       loader never loads steamclient itself, and the game's steam_api finds
 *       the running Steam's own steamclient; with the "/home/..." paths profiles
 *       use under Wine the SetDllDirectory call never even ran. The
 *       SteamClient*Dll/So, ForceArch and NoInject keys are now ignored.
 * v1.2: no longer copies steamclient dll/so files into the run directory at
 *       launch (nothing used those copies); forwards extra arguments to the game.
 *
 * Cross-compile on Linux:
 *   x86_64-w64-mingw32-gcc -O2 -o mythix_loader.exe mythix_loader.c -lshlwapi
 *   i686-w64-mingw32-gcc -O2 -o mythix_loader_32.exe mythix_loader.c -lshlwapi
 *
 * Part of the Mythix toolkit.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LINE   4096
#define MAX_PATH_W 4096
#define INI_NAME   "mythix_loader.ini"

/* ── Config ────────────────────────────────────────────────────────────── */

typedef struct {
    char exe[MAX_PATH_W];
    char exe_run_dir[MAX_PATH_W];
    char exe_cmd_line[MAX_PATH_W];
    char app_id[64];
    char extra_dlls[MAX_PATH_W];
    char env_vars[MAX_PATH_W * 4];
    int  persist;
    int  debug;
} Config;

static void trim(char *s) {
    char *end;
    while (*s == ' ' || *s == '\t') memmove(s, s + 1, strlen(s));
    end = s + strlen(s) - 1;
    while (end > s && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n'))
        *end-- = '\0';
}

static void strip_quotes(char *s) {
    size_t len = strlen(s);
    if (len >= 2 && s[0] == '"' && s[len - 1] == '"') {
        memmove(s, s + 1, len - 2);
        s[len - 2] = '\0';
    }
}

static int read_ini(const char *path, Config *cfg) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[MAX_LINE];
    int in_section = 0;

    memset(cfg, 0, sizeof(*cfg));

    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (!line[0] || line[0] == '#' || line[0] == ';') continue;

        if (line[0] == '[') {
            in_section = (_stricmp(line, "[MythixLoader]") == 0);
            continue;
        }
        if (!in_section) continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *val = eq + 1;
        trim(key);
        trim(val);
        strip_quotes(val);

        if      (_stricmp(key, "Exe") == 0)              strncpy(cfg->exe, val, sizeof(cfg->exe) - 1);
        else if (_stricmp(key, "ExeRunDir") == 0)        strncpy(cfg->exe_run_dir, val, sizeof(cfg->exe_run_dir) - 1);
        else if (_stricmp(key, "ExeCommandLine") == 0)   strncpy(cfg->exe_cmd_line, val, sizeof(cfg->exe_cmd_line) - 1);
        else if (_stricmp(key, "AppId") == 0)            strncpy(cfg->app_id, val, sizeof(cfg->app_id) - 1);
        else if (_stricmp(key, "ExtraDlls") == 0)        strncpy(cfg->extra_dlls, val, sizeof(cfg->extra_dlls) - 1);
        else if (_stricmp(key, "EnvVars") == 0)          strncpy(cfg->env_vars, val, sizeof(cfg->env_vars) - 1);
        else if (_stricmp(key, "Persist") == 0)          cfg->persist = (val[0] == '1' || _stricmp(val, "true") == 0);
        else if (_stricmp(key, "Debug") == 0)            cfg->debug = (val[0] == '1' || _stricmp(val, "true") == 0);
        /* SteamClientDll/SteamClient64Dll/SteamClientSo/SteamClient64So, ForceArch
         * and NoInject (written by older profiles) are ignored. */
    }
    fclose(f);
    return cfg->exe[0] != '\0';
}

/* ── Logging ───────────────────────────────────────────────────────────── */

static int g_debug = 0;

static void mlog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[mythix-loader] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static void dbg(const char *fmt, ...) {
    if (!g_debug) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[mythix-loader:dbg] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/* ── Environment setup ─────────────────────────────────────────────────── */

static void set_env_vars(Config *cfg) {
    if (cfg->app_id[0]) {
        SetEnvironmentVariableA("SteamAppId", cfg->app_id);
        SetEnvironmentVariableA("SteamGameId", cfg->app_id);
        SetEnvironmentVariableA("SteamOverlayGameId", cfg->app_id);
        dbg("Set SteamAppId=%s", cfg->app_id);
    }

    if (cfg->env_vars[0]) {
        char vars[MAX_PATH_W * 4];
        strncpy(vars, cfg->env_vars, sizeof(vars) - 1);
        char *tok = strtok(vars, ";");
        while (tok) {
            trim(tok);
            char *eq = strchr(tok, '=');
            if (eq) {
                *eq = '\0';
                char *k = tok, *v = eq + 1;
                trim(k); trim(v);
                SetEnvironmentVariableA(k, v);
                dbg("Set env: %s=%s", k, v);
            }
            tok = strtok(NULL, ";");
        }
    }
}

/* ── Extra DLL loading ─────────────────────────────────────────────────── */

static void load_extra_dlls(Config *cfg) {
    if (!cfg->extra_dlls[0]) return;

    char dlls[MAX_PATH_W];
    strncpy(dlls, cfg->extra_dlls, sizeof(dlls) - 1);
    char *tok = strtok(dlls, ";");
    while (tok) {
        trim(tok);
        if (tok[0]) {
            HMODULE h = LoadLibraryA(tok);
            if (h) {
                dbg("Loaded extra DLL: %s", tok);
            } else {
                mlog("Warning: failed to load extra DLL: %s (error %lu)", tok, GetLastError());
            }
        }
        tok = strtok(NULL, ";");
    }
}

/* ── Process launch ────────────────────────────────────────────────────── */

/* Append one argument to a Windows command line, quoted so the game's runtime
 * (CommandLineToArgvW / the MSVC CRT rules) reads it back unchanged. Returns 0
 * and leaves the line untouched if it would not fit. */
static int append_arg(char *buf, size_t cap, const char *arg) {
    size_t len = strlen(buf);
    const size_t start = len;
    int quote = (arg[0] == '\0') || strpbrk(arg, " \t\n\v\"") != NULL;

#define PUT(c) do { if (len + 1 >= cap) { buf[start] = '\0'; return 0; } buf[len++] = (c); } while (0)
    if (len > 0) PUT(' ');
    if (!quote) {
        for (const char *p = arg; *p; p++) PUT(*p);
    } else {
        PUT('"');
        for (const char *p = arg; ; p++) {
            size_t slashes = 0;
            while (*p == '\\') { slashes++; p++; }
            if (*p == '\0') {
                /* Double trailing backslashes so they don't escape the closing quote. */
                for (size_t i = 0; i < slashes * 2; i++) PUT('\\');
                break;
            }
            if (*p == '"') {
                for (size_t i = 0; i < slashes * 2 + 1; i++) PUT('\\');
            } else {
                for (size_t i = 0; i < slashes; i++) PUT('\\');
            }
            PUT(*p);
        }
        PUT('"');
    }
#undef PUT
    buf[len] = '\0';
    return 1;
}

static DWORD launch_game(Config *cfg, int extra_argc, char **extra_argv) {
    char cmd_line[MAX_PATH_W * 4];
    if (cfg->exe_cmd_line[0]) {
        snprintf(cmd_line, sizeof(cmd_line), "\"%s\" %s", cfg->exe, cfg->exe_cmd_line);
    } else {
        snprintf(cmd_line, sizeof(cmd_line), "\"%s\"", cfg->exe);
    }

    /* The loader's own extra arguments go to the game, after ExeCommandLine. */
    for (int i = 0; i < extra_argc; i++) {
        if (!append_arg(cmd_line, sizeof(cmd_line), extra_argv[i])) {
            mlog("Warning: command line too long, dropped argument: %s", extra_argv[i]);
        }
    }
    if (extra_argc > 0) dbg("Forwarded %d extra argument(s) to the game", extra_argc);

    char run_dir[MAX_PATH_W];
    if (cfg->exe_run_dir[0]) {
        strncpy(run_dir, cfg->exe_run_dir, sizeof(run_dir) - 1);
    } else {
        strncpy(run_dir, cfg->exe, sizeof(run_dir) - 1);
        PathRemoveFileSpecA(run_dir);
    }
    run_dir[sizeof(run_dir) - 1] = '\0';

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    mlog("Launching: %s", cmd_line);
    mlog("Working dir: %s", run_dir);

    BOOL ok = CreateProcessA(
        NULL,
        cmd_line,
        NULL, NULL,
        FALSE,
        0,
        NULL,
        run_dir[0] ? run_dir : NULL,
        &si,
        &pi
    );

    if (!ok) {
        mlog("Error: CreateProcess failed (error %lu)", GetLastError());
        return 1;
    }

    mlog("Game launched (PID %lu)", pi.dwProcessId);

    if (cfg->persist) {
        dbg("Waiting for game to exit...");
        WaitForSingleObject(pi.hProcess, INFINITE);
        DWORD exit_code = 0;
        GetExitCodeProcess(pi.hProcess, &exit_code);
        mlog("Game exited (code %lu)", exit_code);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return exit_code;
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 0;
}

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    mlog("Mythix Loader v1.3");

    /* Find our own directory for the ini */
    char self_dir[MAX_PATH_W];
    GetModuleFileNameA(NULL, self_dir, sizeof(self_dir));
    PathRemoveFileSpecA(self_dir);

    char ini_path[MAX_PATH_W];

    /* Our own flags are --ini <path> and --debug; everything else is collected
     * and passed through to the game. */
    const char *ini_override = NULL;
    char **extra = (char **)calloc((size_t)argc, sizeof(char *));
    int n_extra = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--ini") == 0 && i + 1 < argc) {
            ini_override = argv[++i];
        } else if (strcmp(argv[i], "--debug") == 0) {
            g_debug = 1;
        } else if (extra) {
            extra[n_extra++] = argv[i];
        }
    }

    if (ini_override) {
        strncpy(ini_path, ini_override, sizeof(ini_path) - 1);
    } else {
        snprintf(ini_path, sizeof(ini_path), "%s\\" INI_NAME, self_dir);
    }

    Config cfg;
    if (!read_ini(ini_path, &cfg)) {
        mlog("Error: could not read config from %s", ini_path);
        mlog("Create %s\\" INI_NAME " with at least [MythixLoader] Exe=path", self_dir);
        return 1;
    }
    mlog("Config: %s", ini_path);

    g_debug = g_debug || cfg.debug;

    /* Set up environment */
    set_env_vars(&cfg);

    /* Load any extra DLLs */
    load_extra_dlls(&cfg);

    /* Launch the game */
    DWORD result = launch_game(&cfg, n_extra, extra);

    free(extra);
    return (int)result;
}
