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
 * Mythix launcher (e.g. -dx11) reach it. Everything after "--" goes to the game
 * as-is, so a game can still be handed its own --debug.
 *
 * v1.5: more ini keys: LogFile (the log also goes to a file), SingleInstance
 *       (a second launch waits for the running game instead of starting
 *       another copy), Priority and Affinity, RunBefore/RunAfter commands,
 *       %VARS% in values (plus MYTHIX_PROFILE_DIR / MYTHIX_GAME_DIR), paths
 *       relative to the ini's folder, and -NAME in EnvVars to remove a
 *       variable. Crash exit codes are named in the log. Command-line keys
 *       keep their quotes, and an EnvVars ';' only splits before NAME=.
 * v1.4: Persist waits for every process the game starts, not just the exe the
 *       ini names, so games that start through a small launcher exe are
 *       waited for properly. WaitForChildren=0 restores the exe-only wait.
 * v1.3: Unicode throughout. The ini is read as UTF-8 (what mythix-loader writes;
 *       a BOM, a UTF-16 ini saved by Notepad or a legacy ANSI ini work too) and
 *       the game is started with the wide Windows APIs, so paths with non-ASCII
 *       characters launch. Without ExeRunDir the game now starts in its own
 *       folder ("/"-style paths included) instead of wherever the loader was
 *       started. AppId=0 is no longer exported as SteamAppId.
 *       No longer points its DLL search at a copied steamclient folder. The
 *       loader never loads steamclient itself, and the game's steam_api finds
 *       the running Steam's own steamclient; with the "/home/..." paths profiles
 *       use under Wine the SetDllDirectory call never even ran. The
 *       SteamClient*Dll/So, ForceArch and NoInject keys are now ignored.
 * v1.2: no longer copies steamclient dll/so files into the run directory at
 *       launch (nothing used those copies); forwards extra arguments to the game.
 *
 * Cross-compile on Linux (or just run make):
 *   x86_64-w64-mingw32-gcc -O2 -municode -s -o mythix_loader.exe mythix_loader.c
 *   i686-w64-mingw32-gcc -O2 -municode -s -o mythix_loader_32.exe mythix_loader.c
 *
 * Part of the Mythix toolkit.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <versionhelpers.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#define MAX_PATH_W   4096
#define MAX_CMD_LINE 32768          /* CreateProcessW's limit, terminator included */
#define MAX_INI_SIZE (1 << 20)
#define INI_NAME     L"mythix_loader.ini"

/* ── Logging ───────────────────────────────────────────────────────────── */

static int g_debug = 0;

/* LogFile: lines logged before the file is open are kept in memory and
 * written first, so the file has the whole run. */
static HANDLE g_log = INVALID_HANDLE_VALUE;
static int g_log_pending = 1;
static wchar_t *g_early;
static size_t g_early_len, g_early_cap;

static void write_utf8(HANDLE h, const wchar_t *s) {
    DWORD n;
    int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, NULL, 0, NULL, NULL);
    if (len <= 1) return;
    char *buf = malloc((size_t)len);
    if (!buf) return;
    WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, len, NULL, NULL);
    WriteFile(h, buf, (DWORD)(len - 1), &n, NULL);
    free(buf);
}

/* Write to stderr: WriteConsoleW on a real console, UTF-8 bytes otherwise
 * (pipes, and the unix stderr Wine hands through). */
static void put_err(const wchar_t *s) {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD mode, n;
    if (h == NULL || h == INVALID_HANDLE_VALUE) return;
    if (GetConsoleMode(h, &mode)) {
        WriteConsoleW(h, s, (DWORD)wcslen(s), &n, NULL);
        return;
    }
    write_utf8(h, s);
}

/* The log file gets each line with a time stamp. */
static void put_log(const wchar_t *s) {
    wchar_t line[64];
    SYSTEMTIME t;
    if (g_log == INVALID_HANDLE_VALUE && !g_log_pending) return;
    GetLocalTime(&t);
    _snwprintf(line, ARRAYSIZE(line), L"%02u:%02u:%02u.%03u ",
               t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    line[ARRAYSIZE(line) - 1] = L'\0';
    if (g_log != INVALID_HANDLE_VALUE) {
        write_utf8(g_log, line);
        write_utf8(g_log, s);
        return;
    }
    size_t need = g_early_len + wcslen(line) + wcslen(s) + 1;
    if (need > g_early_cap) {
        size_t cap = need * 2;
        wchar_t *grown = realloc(g_early, cap * sizeof(wchar_t));
        if (!grown) return;
        g_early = grown;
        g_early_cap = cap;
    }
    wcscpy(g_early + g_early_len, line);
    wcscat(g_early + g_early_len, s);
    g_early_len = wcslen(g_early);
}

/* Formats use the wide printf rules: %ls for wide strings. */
static void vlog(const wchar_t *tag, const wchar_t *fmt, va_list ap) {
    static wchar_t msg[MAX_CMD_LINE + 512];     /* fits a full command line */
    const size_t cap = ARRAYSIZE(msg);
    size_t len = (size_t)_snwprintf(msg, cap, L"[%ls] ", tag);
    size_t room = cap - len - 2;                /* keep space for "\n" + NUL */
    _vsnwprintf(msg + len, room, fmt, ap);
    msg[len + room] = L'\0';                    /* terminate even if truncated */
    len = wcslen(msg);
    msg[len++] = L'\n';
    msg[len] = L'\0';
    put_err(msg);
    put_log(msg);
}

static void mlog(const wchar_t *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vlog(L"mythix-loader", fmt, ap);
    va_end(ap);
}

static void dbg(const wchar_t *fmt, ...) {
    if (!g_debug) return;
    va_list ap;
    va_start(ap, fmt);
    vlog(L"mythix-loader:dbg", fmt, ap);
    va_end(ap);
}

/* "error 2: The system cannot find the file specified" */
static const wchar_t *err_text(DWORD code) {
    static wchar_t buf[600];
    wchar_t sys[512];
    DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, code, 0, sys, ARRAYSIZE(sys), NULL);
    while (n > 0 && (sys[n - 1] == L'\r' || sys[n - 1] == L'\n' ||
                     sys[n - 1] == L' ' || sys[n - 1] == L'.'))
        sys[--n] = L'\0';
    if (n > 0) _snwprintf(buf, ARRAYSIZE(buf), L"error %lu: %ls", code, sys);
    else       _snwprintf(buf, ARRAYSIZE(buf), L"error %lu", code);
    buf[ARRAYSIZE(buf) - 1] = L'\0';
    return buf;
}

/* ── Config ────────────────────────────────────────────────────────────── */

typedef struct {
    wchar_t exe[MAX_PATH_W];
    wchar_t exe_run_dir[MAX_PATH_W];
    wchar_t exe_cmd_line[MAX_PATH_W];
    wchar_t app_id[64];
    wchar_t extra_dlls[MAX_PATH_W];
    wchar_t env_vars[MAX_PATH_W * 4];
    wchar_t run_before[MAX_PATH_W];
    wchar_t run_after[MAX_PATH_W];
    wchar_t log_file[MAX_PATH_W];
    wchar_t priority[32];
    wchar_t affinity[256];
    int     persist;
    int     wait_children;
    int     single_instance;
    int     debug;
} Config;

static int is_space(wchar_t c) {
    return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n';
}

/* Trims trailing whitespace in place; returns the first non-space character. */
static wchar_t *trim(wchar_t *s) {
    while (is_space(*s)) s++;
    size_t n = wcslen(s);
    while (n > 0 && is_space(s[n - 1])) s[--n] = L'\0';
    return s;
}

/* "value" -> value, but only for one quoted value: "a" "b" stays as it is. */
static void strip_quotes(wchar_t *s) {
    size_t len = wcslen(s);
    if (len >= 2 && s[0] == L'"' && s[len - 1] == L'"' && !wmemchr(s + 1, L'"', len - 2)) {
        memmove(s, s + 1, (len - 2) * sizeof(wchar_t));
        s[len - 2] = L'\0';
    }
}

/* 1/true/yes/on or 0/false/no/off; anything else keeps the default (with a
 * warning), so a typo can't silently flip a default-on key off. */
static int parse_bool(const wchar_t *key, const wchar_t *v, int dflt) {
    static const wchar_t *const on[] = { L"1", L"true", L"yes", L"on" };
    static const wchar_t *const off[] = { L"0", L"false", L"no", L"off" };
    for (size_t i = 0; i < ARRAYSIZE(on); i++) {
        if (_wcsicmp(v, on[i]) == 0) return 1;
        if (_wcsicmp(v, off[i]) == 0) return 0;
    }
    if (v[0]) mlog(L"Warning: %ls=%ls isn't 1/0 (true/false, yes/no, on/off); using %d", key, v, dflt);
    return dflt;
}

/* Copy a value into a fixed buffer, warning instead of silently cutting it. */
static void set_value(wchar_t *dst, size_t cap, const wchar_t *key, const wchar_t *val) {
    size_t len = wcslen(val);
    if (len >= cap) {
        mlog(L"Warning: %ls is too long (%u characters, max %u), truncated",
             key, (unsigned)len, (unsigned)(cap - 1));
        len = cap - 1;
    }
    memcpy(dst, val, len * sizeof(wchar_t));
    dst[len] = L'\0';
}

/* Read a whole text file as a NUL-terminated wide string (caller frees).
 * mythix-loader writes UTF-8; a UTF-8 BOM, UTF-16LE (Notepad's "Unicode") and
 * a legacy ANSI file from a Windows editor are read correctly too. */
static wchar_t *read_text_file(const wchar_t *path) {
    HANDLE h = CreateFileW(path, GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;

    LARGE_INTEGER size;
    char *raw = NULL;
    DWORD got = 0;
    if (GetFileSizeEx(h, &size) && size.QuadPart <= MAX_INI_SIZE)
        raw = malloc((size_t)size.QuadPart + 1);
    if (raw && !ReadFile(h, raw, (DWORD)size.QuadPart, &got, NULL)) {
        free(raw);
        raw = NULL;
    }
    CloseHandle(h);
    if (!raw) return NULL;

    const char *p = raw;
    int len = (int)got;
    wchar_t *text;
    if (len >= 2 && (unsigned char)p[0] == 0xFF && (unsigned char)p[1] == 0xFE) {
        int wlen = (len - 2) / 2;
        text = malloc(((size_t)wlen + 1) * sizeof(wchar_t));
        if (text) {
            memcpy(text, p + 2, (size_t)wlen * sizeof(wchar_t));
            text[wlen] = L'\0';
        }
    } else {
        if (len >= 3 && memcmp(p, "\xEF\xBB\xBF", 3) == 0) {
            p += 3;
            len -= 3;
        }
        UINT cp = CP_UTF8;
        DWORD flags = MB_ERR_INVALID_CHARS;
        int wlen = len ? MultiByteToWideChar(cp, flags, p, len, NULL, 0) : 0;
        if (len && !wlen) {                     /* not UTF-8: ANSI code page */
            cp = CP_ACP;
            flags = 0;
            wlen = MultiByteToWideChar(cp, flags, p, len, NULL, 0);
        }
        text = malloc(((size_t)wlen + 1) * sizeof(wchar_t));
        if (text) {
            if (wlen) MultiByteToWideChar(cp, flags, p, len, text, wlen);
            text[wlen] = L'\0';
        }
    }
    free(raw);
    return text;
}

/* Returns -1 if the file can't be read, 0 if it has no Exe=, 1 if usable. */
static int read_ini(const wchar_t *path, Config *cfg) {
    wchar_t *text = read_text_file(path);
    if (!text) return -1;

    memset(cfg, 0, sizeof(*cfg));
    cfg->wait_children = 1;
    int in_section = 0;
    wchar_t *next = text;
    while (next) {
        wchar_t *line = next;
        wchar_t *nl = wcschr(line, L'\n');
        if (nl) {
            *nl = L'\0';
            next = nl + 1;
        } else {
            next = NULL;
        }

        line = trim(line);
        if (!line[0] || line[0] == L'#' || line[0] == L';') continue;

        if (line[0] == L'[') {
            in_section = (_wcsicmp(line, L"[MythixLoader]") == 0);
            continue;
        }
        if (!in_section) continue;

        wchar_t *eq = wcschr(line, L'=');
        if (!eq) continue;
        *eq = L'\0';
        wchar_t *key = trim(line);
        wchar_t *val = trim(eq + 1);
        /* Command lines keep their quotes: they go to CreateProcess as written. */
        if (_wcsicmp(key, L"ExeCommandLine") && _wcsicmp(key, L"RunBefore") &&
            _wcsicmp(key, L"RunAfter"))
            strip_quotes(val);

#define SET(field) set_value(cfg->field, ARRAYSIZE(cfg->field), key, val)
        if      (_wcsicmp(key, L"Exe") == 0)            SET(exe);
        else if (_wcsicmp(key, L"ExeRunDir") == 0)      SET(exe_run_dir);
        else if (_wcsicmp(key, L"ExeCommandLine") == 0) SET(exe_cmd_line);
        else if (_wcsicmp(key, L"AppId") == 0)          SET(app_id);
        else if (_wcsicmp(key, L"ExtraDlls") == 0)      SET(extra_dlls);
        else if (_wcsicmp(key, L"EnvVars") == 0)        SET(env_vars);
        else if (_wcsicmp(key, L"RunBefore") == 0)      SET(run_before);
        else if (_wcsicmp(key, L"RunAfter") == 0)       SET(run_after);
        else if (_wcsicmp(key, L"LogFile") == 0)        SET(log_file);
        else if (_wcsicmp(key, L"Priority") == 0)       SET(priority);
        else if (_wcsicmp(key, L"Affinity") == 0)       SET(affinity);
        else if (_wcsicmp(key, L"SingleInstance") == 0) cfg->single_instance = parse_bool(key, val, 0);
        else if (_wcsicmp(key, L"Persist") == 0)        cfg->persist = parse_bool(key, val, 0);
        else if (_wcsicmp(key, L"WaitForChildren") == 0) cfg->wait_children = parse_bool(key, val, 1);
        else if (_wcsicmp(key, L"Debug") == 0)          cfg->debug = parse_bool(key, val, 0);
        /* SteamClientDll/SteamClient64Dll/SteamClientSo/SteamClient64So, ForceArch
         * and NoInject (written by older profiles) are ignored. */
#undef SET
    }
    free(text);
    return cfg->exe[0] != L'\0';
}

/* Cut a path down to its folder. Accepts "\" and "/" separators: profiles
 * written on Linux use "/home/..." paths, which Wine maps through Z:. */
static void parent_dir(wchar_t *path) {
    wchar_t *sep = NULL;
    for (wchar_t *p = path; *p; p++)
        if (*p == L'\\' || *p == L'/') sep = p;
    if (!sep)
        path[0] = L'\0';
    else if (sep == path || (sep == path + 2 && path[1] == L':'))
        sep[1] = L'\0';                         /* keep the root: "/" or "C:\" */
    else
        *sep = L'\0';
}

/* ── Values: %VARS% and relative paths ─────────────────────────────────── */

/* Expand %VARS% in place, Windows style: names that aren't set stay as they
 * are, so a lone % in a path is harmless. */
static void expand_vars(wchar_t *s, size_t cap, const wchar_t *key) {
    if (!wcschr(s, L'%')) return;
    wchar_t *out = malloc(cap * sizeof(wchar_t));
    if (!out) return;
    DWORD n = ExpandEnvironmentStringsW(s, out, (DWORD)cap);
    if (n == 0 || n > cap)
        mlog(L"Warning: %ls is too long once %%VARS%% are expanded; using it as written", key);
    else
        wcscpy(s, out);
    free(out);
}

static int is_relative(const wchar_t *p) {
    return p[0] && p[0] != L'\\' && p[0] != L'/' && p[1] != L':';
}

/* A relative path in the ini means relative to the ini's own folder. */
static void resolve_path(wchar_t *p, size_t cap, const wchar_t *base, const wchar_t *key) {
    wchar_t joined[MAX_PATH_W];
    if (!is_relative(p)) return;
    int n = _snwprintf(joined, ARRAYSIZE(joined), L"%ls\\%ls", base, p);
    if (n < 0 || (size_t)n >= cap || (size_t)n >= ARRAYSIZE(joined)) {
        mlog(L"Warning: %ls is too long with the ini's folder in front; using it as written", key);
        return;
    }
    for (wchar_t *c = joined + wcslen(base); *c; c++)
        if (*c == L'/') *c = L'\\';
    wcscpy(p, joined);
}

/* A "/home/..." path in its Windows form ("Z:\home\..."), via Wine's own
 * conversion; other paths are copied as they are. */
static void dos_path(const wchar_t *path, wchar_t *out, size_t cap) {
    typedef WCHAR *(CDECL *wine_get_dos_file_name_fn)(LPCSTR);
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    wine_get_dos_file_name_fn to_dos = k32
        ? (wine_get_dos_file_name_fn)(void (*)(void))GetProcAddress(k32, "wine_get_dos_file_name")
        : NULL;
    set_value(out, cap, L"path", path);
    if (path[0] != L'/' || !to_dos) return;
    int len = WideCharToMultiByte(CP_UTF8, 0, path, -1, NULL, 0, NULL, NULL);
    char *unix_path = len > 0 ? malloc((size_t)len) : NULL;
    if (!unix_path) return;
    WideCharToMultiByte(CP_UTF8, 0, path, -1, unix_path, len, NULL, NULL);
    WCHAR *dos = to_dos(unix_path);
    free(unix_path);
    if (dos) {
        if (wcslen(dos) < cap) wcscpy(out, dos);
        HeapFree(GetProcessHeap(), 0, dos);
    }
}

/* ── Priority and affinity ─────────────────────────────────────────────── */

/* idle, belownormal, normal, abovenormal, high (spaces, - and _ ignored). */
static DWORD priority_class(const wchar_t *v) {
    static const struct { const wchar_t *name; DWORD cls; } map[] = {
        { L"idle", IDLE_PRIORITY_CLASS }, { L"belownormal", BELOW_NORMAL_PRIORITY_CLASS },
        { L"normal", NORMAL_PRIORITY_CLASS }, { L"abovenormal", ABOVE_NORMAL_PRIORITY_CLASS },
        { L"high", HIGH_PRIORITY_CLASS },
    };
    wchar_t name[32];
    size_t n = 0;
    if (!v[0]) return 0;
    for (const wchar_t *p = v; *p && n < ARRAYSIZE(name) - 1; p++)
        if (*p != L' ' && *p != L'-' && *p != L'_') name[n++] = *p;
    name[n] = L'\0';
    for (size_t i = 0; i < ARRAYSIZE(map); i++)
        if (_wcsicmp(name, map[i].name) == 0) return map[i].cls;
    mlog(L"Warning: Priority=%ls isn't idle/belownormal/normal/abovenormal/high; ignored", v);
    return 0;
}

/* "0", "0,2-3" (CPU numbers) or "0x5" (a mask). 0 = not set or invalid. */
static DWORD_PTR affinity_mask(const wchar_t *v) {
    const unsigned bits = (unsigned)(sizeof(DWORD_PTR) * 8);
    DWORD_PTR mask = 0;
    wchar_t *end;
    if (!v[0]) return 0;
    if (v[0] == L'0' && (v[1] == L'x' || v[1] == L'X')) {
        const wchar_t *digits = v + 2;
        if (!iswxdigit(*digits)) goto bad;
        unsigned long long m = 0;
        for (; iswxdigit(*digits); digits++) {
            unsigned d = (unsigned)(iswdigit(*digits) ? *digits - L'0' : (towlower(*digits) - L'a' + 10));
            if (m >> (bits - 4)) {               /* another digit wouldn't fit */
                mlog(L"Warning: Affinity=%ls is wider than this build's %u CPUs; ignored", v, bits);
                goto bad_quiet;
            }
            m = (m << 4) | d;
        }
        if (*digits || !m) goto bad;
        return (DWORD_PTR)m;
    }
    if (!iswdigit(v[0])) goto bad;              /* no "-1" or "+3" */
    for (const wchar_t *p = v; *p; ) {
        while (*p == L' ' || *p == L',') p++;
        if (!*p) break;
        unsigned long lo = wcstoul(p, &end, 10), hi = lo;
        if (end == p) goto bad;
        p = end;
        while (*p == L' ') p++;
        if (*p == L'-') {
            const wchar_t *q = p + 1;
            hi = wcstoul(q, &end, 10);
            if (end == q || hi < lo) goto bad;
            p = end;
        }
        if (hi >= bits) {
            mlog(L"Warning: Affinity=%ls names CPU %lu; this build only handles 0-%u", v, hi, bits - 1);
            goto bad_quiet;
        }
        for (unsigned long c = lo; c <= hi; c++) mask |= (DWORD_PTR)1 << c;
        while (*p == L' ') p++;
        if (*p && *p != L',') goto bad;
    }
    if (mask) return mask;
bad:
    mlog(L"Warning: Affinity=%ls isn't a CPU list like 0,2-3 or a mask like 0x5; ignored", v);
bad_quiet:
    return 0;
}

/* ── Exit codes ────────────────────────────────────────────────────────── */

/* What a crash-style exit code means, or NULL. */
static const wchar_t *exit_meaning(DWORD code) {
    switch (code) {
    case 0xC0000005: return L"access violation: the game crashed";
    case 0xC00000FD: return L"stack overflow: the game crashed";
    case 0xC0000374: return L"heap corruption: the game crashed";
    case 0xC0000409: return L"fail-fast exit: the game stopped itself after an error";
    case 0xC000001D: return L"illegal instruction: the CPU lacks something the game needs, or it crashed";
    case 0xC0000094: return L"integer divide by zero: the game crashed";
    case 0xC0000096: return L"privileged instruction: the game crashed";
    case 0xC0000135: return L"a DLL the game needs is missing";
    case 0xC0000139: return L"a DLL the game needs has the wrong version (entry point not found)";
    case 0xC0000142: return L"a DLL failed to initialise";
    case 0xC000007B: return L"bad image: a 32/64-bit mismatch or a damaged DLL";
    case 0xC0000017: return L"out of memory";
    case 0xC000013A: return L"stopped with Ctrl+C or closed";
    case 0xC0000420: return L"assertion failure: the game stopped itself";
    case 0x80000003: return L"breakpoint: the game hit a debug break";
    case 0xE06D7363: return L"unhandled C++ exception: the game crashed";
    case 0x40000015: return L"fatal application exit (abort)";
    default:         return NULL;
    }
}

/* "3", or "0xC0000005 (access violation: the game crashed)". */
static const wchar_t *exit_text(DWORD code) {
    static wchar_t buf[160];
    const wchar_t *meaning = exit_meaning(code);
    if (meaning)
        _snwprintf(buf, ARRAYSIZE(buf), L"0x%08lX (%ls)", code, meaning);
    else if (code >= 0x80000000UL)
        _snwprintf(buf, ARRAYSIZE(buf), L"0x%08lX", code);
    else
        _snwprintf(buf, ARRAYSIZE(buf), L"%lu", code);
    buf[ARRAYSIZE(buf) - 1] = L'\0';
    return buf;
}

/* ── Log file, single instance, extra commands ─────────────────────────── */

/* Open LogFile and write what was logged so far: emptied first, unless
 * append is set (a second launch waiting for the running one adds to that
 * one's log). Writes always go to the end, so both can share the file.
 * An empty path just drops the buffered lines. */
static void open_log_file(const wchar_t *path, int append) {
    const DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    if (path[0]) {
        if (!append) {
            HANDLE h = CreateFileW(path, GENERIC_WRITE, share, NULL, CREATE_ALWAYS,
                                   FILE_ATTRIBUTE_NORMAL, NULL);
            if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
        }
        g_log = CreateFileW(path, FILE_APPEND_DATA | SYNCHRONIZE, share, NULL, OPEN_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_log != INVALID_HANDLE_VALUE && g_early) write_utf8(g_log, g_early);
    }
    g_log_pending = 0;
    free(g_early);
    g_early = NULL;
    g_early_len = g_early_cap = 0;
    if (path[0] && g_log == INVALID_HANDLE_VALUE)
        mlog(L"Warning: can't write the log file %ls (%ls)", path, err_text(GetLastError()));
}

/* SingleInstance: one loader per profile at a time. If another one is
 * already running (its game still going), wait for it and return 1 so this
 * one exits without starting a second copy. Waiting instead of exiting keeps
 * wrappers that treat the loader's exit as the game's end (neutron cleans up
 * the prefix 30 s after a direct launch exits) from acting while the first
 * copy runs. The mutex is held until this loader exits. */
static void open_log_file(const wchar_t *path, int append);

static int wait_for_running_instance(const wchar_t *ini_full, const wchar_t *log_path) {
    unsigned long h1 = 2166136261UL, h2 = 5381;
    wchar_t name[64];
    for (const wchar_t *p = ini_full; *p; p++) {
        unsigned long c = (unsigned long)towlower(*p);
        h1 = ((h1 ^ c) * 16777619UL) & 0xFFFFFFFFUL;
        h2 = ((h2 * 33) ^ c) & 0xFFFFFFFFUL;
    }
    _snwprintf(name, ARRAYSIZE(name), L"Local\\MythixLoader-%08lx%08lx", h1, h2);
    name[ARRAYSIZE(name) - 1] = L'\0';
    HANDLE m = CreateMutexW(NULL, TRUE, name);
    if (!m) {
        mlog(L"Warning: SingleInstance check failed (%ls); starting anyway", err_text(GetLastError()));
        return 0;
    }
    if (GetLastError() != ERROR_ALREADY_EXISTS) return 0;   /* ours now, until we exit */
    open_log_file(log_path, 1);                 /* add to the running copy's log */
    mlog(L"This profile's game is already running; not starting a second copy");
    mlog(L"Waiting for the running one to exit...");
    WaitForSingleObject(m, INFINITE);                       /* or abandoned: same */
    ReleaseMutex(m);
    CloseHandle(m);
    mlog(L"The running copy has exited");
    return 1;
}

/* RunBefore/RunAfter: run a command line and wait for it. */
static void run_command(const wchar_t *what, const wchar_t *cmd, const wchar_t *dir) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    if (!cmd[0]) return;
    wchar_t *line = _wcsdup(cmd);           /* CreateProcessW may write to it */
    if (!line) return;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    mlog(L"%ls: %ls", what, cmd);
    if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, 0, NULL, dir[0] ? dir : NULL, &si, &pi)) {
        mlog(L"Warning: %ls couldn't start (%ls)", what, err_text(GetLastError()));
    } else if (!pi.hProcess) {
        /* Wine runs a Linux program or script as a Unix process and hands
         * back no handle, so there's nothing to wait on. */
        mlog(L"%ls started a Linux program; the loader can't wait for it or see its exit code", what);
    } else {
        DWORD code = 0;
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &code);
        if (code) mlog(L"%ls exited with code %ls", what, exit_text(code));
        else dbg(L"%ls finished", what);
        CloseHandle(pi.hProcess);
        if (pi.hThread) CloseHandle(pi.hThread);
    }
    free(line);
}

/* ── Environment setup ─────────────────────────────────────────────────── */

static int all_digits(const wchar_t *s) {
    if (!*s) return 0;
    for (; *s; s++)
        if (*s < L'0' || *s > L'9') return 0;
    return 1;
}

/* EnvVars entries are separated by ';', but only a ';' followed by another
 * NAME=... or -NAME starts a new one, so PATH=%PATH%;C:\tools keeps its ';'.
 * Returns the separating ';' or NULL. */
static int is_name_start(wchar_t c) {
    return (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') || c == L'_';
}

static wchar_t *next_env_entry(wchar_t *s) {
    for (wchar_t *p = wcschr(s, L';'); p; p = wcschr(p + 1, L';')) {
        const wchar_t *q = p + 1;
        while (*q == L' ' || *q == L'\t') q++;
        if (!*q) return p;                      /* trailing ';' */
        int removal = *q == L'-';
        if (removal) q++;
        if (!is_name_start(*q)) continue;
        while (*q && *q != L'=' && *q != L';' && *q != L' ' && *q != L'\t') q++;
        while (*q == L' ' || *q == L'\t') q++;
        if (removal ? (*q == L';' || !*q) : *q == L'=') return p;
    }
    return NULL;
}

static void set_env_vars(Config *cfg) {
    if (all_digits(cfg->app_id) && wcscmp(cfg->app_id, L"0") != 0) {
        SetEnvironmentVariableW(L"SteamAppId", cfg->app_id);
        SetEnvironmentVariableW(L"SteamGameId", cfg->app_id);
        SetEnvironmentVariableW(L"SteamOverlayGameId", cfg->app_id);
        dbg(L"Set SteamAppId=%ls", cfg->app_id);
    } else if (cfg->app_id[0]) {
        /* mythix-loader writes AppId=0 for games it couldn't find in the library. */
        mlog(L"Warning: AppId=%ls is not a Steam app id; SteamAppId not set", cfg->app_id);
    } else {
        dbg(L"No AppId in the ini; SteamAppId not set");
    }

    if (!cfg->env_vars[0]) return;
    wchar_t *vars = _wcsdup(cfg->env_vars);
    if (!vars) return;
    for (wchar_t *tok = vars, *end; tok; tok = end) {
        end = next_env_entry(tok);
        if (end) *end++ = L'\0';
        tok = trim(tok);
        if (tok[0] == L'-') {                   /* -NAME removes a variable */
            wchar_t *k = trim(tok + 1);
            if (!k[0] || wcschr(k, L'=')) continue;
            SetEnvironmentVariableW(k, NULL);
            dbg(L"Removed env: %ls", k);
            continue;
        }
        wchar_t *eq = wcschr(tok, L'=');
        if (!eq) continue;
        *eq = L'\0';
        wchar_t *k = trim(tok);
        wchar_t v[MAX_PATH_W * 4];
        set_value(v, ARRAYSIZE(v), k, trim(eq + 1));
        if (!k[0]) continue;
        expand_vars(v, ARRAYSIZE(v), k);        /* earlier entries count, too */
        SetEnvironmentVariableW(k, v);
        dbg(L"Set env: %ls=%ls", k, v);
    }
    free(vars);
}

/* ── Extra DLL loading ─────────────────────────────────────────────────── */

/* ExtraDlls load into the loader process only, never into the game, so they
 * don't change how the game runs. They're kept for troubleshooting the
 * loader itself (e.g. checking that a DLL loads in this prefix). */
static void load_extra_dlls(Config *cfg) {
    if (!cfg->extra_dlls[0]) return;
    mlog(L"Loading ExtraDlls into the loader process (not the game; troubleshooting only)");
    wchar_t *dlls = _wcsdup(cfg->extra_dlls);
    if (!dlls) return;
    for (wchar_t *tok = dlls, *end; tok; tok = end) {
        end = wcschr(tok, L';');
        if (end) *end++ = L'\0';
        wchar_t *path = trim(tok);
        if (!path[0]) continue;
        mlog(L"  %ls", path);
        if (LoadLibraryW(path)) {
            dbg(L"Loaded extra DLL: %ls", path);
        } else {
            mlog(L"Warning: failed to load extra DLL: %ls (%ls)", path, err_text(GetLastError()));
        }
    }
    free(dlls);
}

/* ── Process launch ────────────────────────────────────────────────────── */

/* Append one argument to a Windows command line, quoted so the game's runtime
 * (CommandLineToArgvW / the MSVC CRT rules) reads it back unchanged. Returns 0
 * and leaves the line untouched if it would not fit. */
static int append_arg(wchar_t *buf, size_t cap, const wchar_t *arg) {
    size_t len = wcslen(buf);
    const size_t start = len;
    int quote = (arg[0] == L'\0') || wcspbrk(arg, L" \t\n\v\"") != NULL;

#define PUT(c) do { if (len + 1 >= cap) { buf[start] = L'\0'; return 0; } buf[len++] = (c); } while (0)
    if (len > 0) PUT(L' ');
    if (!quote) {
        for (const wchar_t *p = arg; *p; p++) PUT(*p);
    } else {
        PUT(L'"');
        for (const wchar_t *p = arg; ; p++) {
            size_t slashes = 0;
            while (*p == L'\\') { slashes++; p++; }
            if (*p == L'\0') {
                /* Double trailing backslashes so they don't escape the closing quote. */
                for (size_t i = 0; i < slashes * 2; i++) PUT(L'\\');
                break;
            }
            if (*p == L'"') {
                for (size_t i = 0; i < slashes * 2 + 1; i++) PUT(L'\\');
            } else {
                for (size_t i = 0; i < slashes; i++) PUT(L'\\');
            }
            PUT(*p);
        }
        PUT(L'"');
    }
#undef PUT
    buf[len] = L'\0';
    return 1;
}

/* ── Waiting for the game ──────────────────────────────────────────────── */

/* Persist with WaitForChildren=1 waits for every process the game starts, not
 * just the exe the ini names: plenty of games start through a small launcher
 * exe that spawns the real game and exits at once. The game is created
 * suspended and put in a job object before it runs, so all its descendants
 * are counted, and the job's completion port reports when the last one is
 * gone. The job sets no limits and kills nothing (the game keeps running if
 * the loader goes away), and a process that asks to break away may. */
typedef struct {
    HANDLE job;
    HANDLE port;
    DWORD  pids[256];               /* live processes, from the job's messages */
    int    n_pids;
    int    pids_overflowed;         /* more than fit: the list is incomplete */
    DWORD  shown[256];              /* what the last "still waiting" list named */
    DWORD  blocking[256];           /* scratch for the current blocking set */
    DWORD  priority;                /* Priority=, applied to every new process */
} ProcessTree;

/* Jobs only nest on Windows 8+ and Wine 6.9+. Without that, a game that puts
 * its own children in a job (Chromium/CEF do, and kill the child if that
 * fails) would break inside ours. */
static int jobs_can_nest(void) {
    typedef const char *(CDECL *wine_get_version_fn)(void);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    wine_get_version_fn get_version = ntdll
        ? (wine_get_version_fn)(void (*)(void))GetProcAddress(ntdll, "wine_get_version")
        : NULL;
    if (!get_version) {
        if (IsWindows8OrGreater()) return 1;
        mlog(L"Windows 7 can't nest job objects, so the loader can't follow the processes "
             L"a game starts; waiting for the exe only");
        return 0;
    }
    const char *v = get_version();
    int major = 0, minor = 0;
    if (!v || sscanf(v, "%d.%d", &major, &minor) < 1) return 1;
    dbg(L"Running on Wine %hs", v);
    if (major > 6 || (major == 6 && minor >= 9)) return 1;
    mlog(L"Wine %hs can't follow the processes a game starts (needs 6.9 or newer); "
         L"waiting for the exe only", v);
    return 0;
}

static void tree_close(ProcessTree *t) {
    if (t->port) CloseHandle(t->port);
    if (t->job) CloseHandle(t->job);
    t->port = t->job = NULL;
}

static int tree_open(ProcessTree *t) {
    if (!jobs_can_nest()) return 0;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT acp;
    ZeroMemory(&limits, sizeof(limits));
    /* Without this, CreateProcess(CREATE_BREAKAWAY_FROM_JOB) in the game fails.
     * It is an extended limit: the basic information class rejects it. */
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    t->job = CreateJobObjectW(NULL, NULL);
    t->port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
    acp.CompletionKey = t->job;
    acp.CompletionPort = t->port;
    if (t->job && t->port &&
        SetInformationJobObject(t->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) &&
        SetInformationJobObject(t->job, JobObjectAssociateCompletionPortInformation, &acp, sizeof(acp)))
        return 1;
    mlog(L"Warning: can't follow the processes the game starts (%ls); waiting for the exe only",
         err_text(GetLastError()));
    tree_close(t);
    return 0;
}

/* Processes still in the job, or -1 if the job can't tell. Wine 2.7-5.10
 * answer with all zeros; a real count includes the game, so its total is at
 * least 1. */
static long tree_active(const ProcessTree *t) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
    if (!QueryInformationJobObject(t->job, JobObjectBasicAccountingInformation,
                                   &info, sizeof(info), NULL) || info.TotalProcesses == 0)
        return -1;
    return (long)info.ActiveProcesses;
}

static const wchar_t *process_image(DWORD pid) {
    static wchar_t path[MAX_PATH_W];
    DWORD len = MAX_PATH_W;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    path[0] = L'\0';
    if (h) {
        if (!QueryFullProcessImageNameW(h, 0, path, &len)) path[0] = L'\0';
        CloseHandle(h);
    }
    return path[0] ? path : L"?";
}

static void tree_track(ProcessTree *t, DWORD pid, int alive) {
    for (int i = 0; i < t->n_pids; i++) {
        if (t->pids[i] == pid) {
            if (!alive) t->pids[i] = t->pids[--t->n_pids];
            return;
        }
    }
    if (!alive) return;
    if (t->n_pids < (int)ARRAYSIZE(t->pids)) t->pids[t->n_pids++] = pid;
    else t->pids_overflowed = 1;
}

/* Wine's own helpers, which a game can start without being part of it. Once
 * the game exe has exited, these (from the Windows directory) don't keep the
 * loader waiting: dllhost.exe, Wine's COM surrogate, never exits on its own.
 * They are left running, not killed. */
static const wchar_t *const WINE_HELPERS[] = {
    L"conhost.exe", L"dllhost.exe", L"explorer.exe", L"mscorsvw.exe",
    L"plugplay.exe", L"rpcss.exe", L"services.exe", L"svchost.exe",
    L"tabtip.exe", L"winebrowser.exe", L"wineboot.exe", L"winedbg.exe",
    L"winedevice.exe", L"winemenubuilder.exe",
};

static int is_wine_helper(const wchar_t *image) {
    wchar_t windir[MAX_PATH_W];
    UINT n = GetSystemWindowsDirectoryW(windir, MAX_PATH_W - 1);
    if (n == 0 || n >= MAX_PATH_W - 1) return 0;
    if (windir[n - 1] != L'\\') wcscpy(windir + n++, L"\\");
    if (_wcsnicmp(image, windir, n) != 0) return 0;
    const wchar_t *name = wcsrchr(image, L'\\');
    name = name ? name + 1 : image;
    for (size_t i = 0; i < ARRAYSIZE(WINE_HELPERS); i++)
        if (_wcsicmp(name, WINE_HELPERS[i]) == 0) return 1;
    return 0;
}

/* True when every process left in the job is a Wine helper. */
static int only_helpers_left(const ProcessTree *t) {
    if (t->pids_overflowed || t->n_pids == 0) return 0;
    for (int i = 0; i < t->n_pids; i++)
        if (!is_wine_helper(process_image(t->pids[i]))) return 0;
    return 1;
}

/* The job's processes that aren't Wine helpers, into out[] (sorted). */
static int blocking_pids(const ProcessTree *t, DWORD *out) {
    int n = 0;
    for (int i = 0; i < t->n_pids; i++) {
        if (is_wine_helper(process_image(t->pids[i]))) continue;
        int j = n++;
        while (j > 0 && out[j - 1] > t->pids[i]) { out[j] = out[j - 1]; j--; }
        out[j] = t->pids[i];
    }
    return n;
}

static void log_blocking(const DWORD *pids, int n, int incomplete) {
    for (int i = 0; i < n; i++) mlog(L"  PID %lu: %ls", pids[i], process_image(pids[i]));
    if (incomplete) mlog(L"  (and more; the list is incomplete)");
    mlog(L"(if one of these never exits, close it: the loader waits until it does)");
}

/* Returns once every process in the job has exited, or only Wine helpers
 * are left (for two seconds) after the game exe has gone. Returns 1 when
 * the game's processes outlived its exe. */
static int tree_wait(ProcessTree *t, const PROCESS_INFORMATION *pi) {
    long live = 0;                  /* processes in the job, from its messages */
    int exe_gone = 0, outlived = 0;
    DWORD helpers_since = 0;        /* tick count when only helpers were left */
    /* The last list printed, and when it went stale, so it can be printed
     * again once things settle. */
    DWORD *shown = t->shown, *now_pids = t->blocking;
    int n_shown = 0;
    DWORD stale_since = 0, last_relist = 0;
    for (;;) {
        DWORD msg = 0;
        ULONG_PTR key = 0;
        LPOVERLAPPED ov = NULL;
        if (!GetQueuedCompletionStatus(t->port, &msg, &key, &ov, 1000)) {
            /* Job messages aren't guaranteed to arrive, so once a second
             * also check the count directly. If the job can't tell us, fall
             * back to waiting for the exe. */
            long n = (GetLastError() == WAIT_TIMEOUT) ? tree_active(t) : -1;
            if (n == 0) return outlived;
            if (n < 0) {
                WaitForSingleObject(pi->hProcess, INFINITE);
                return outlived;
            }
            msg = 0;                    /* fall through to the helper check */
        } else if (key != (ULONG_PTR)t->job) {
            continue;
        }
        DWORD pid = (DWORD)(ULONG_PTR)ov;
        switch (msg) {
        case JOB_OBJECT_MSG_NEW_PROCESS:
            live++;
            tree_track(t, pid, 1);
            /* Windows doesn't pass high/abovenormal priority on to child
             * processes, so give the ones the game starts the same class. */
            if (t->priority && pid != pi->dwProcessId) {
                HANDLE h = OpenProcess(PROCESS_SET_INFORMATION, FALSE, pid);
                if (h) {
                    SetPriorityClass(h, t->priority);
                    CloseHandle(h);
                }
            }
            /* Too early to name it: the new process isn't fully set up yet. */
            if (pid != pi->dwProcessId) dbg(L"Game started process %lu", pid);
            break;
        case JOB_OBJECT_MSG_EXIT_PROCESS:
        case JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS:
            live--;
            tree_track(t, pid, 0);
            if (pid != pi->dwProcessId) {
                dbg(L"Process %lu exited: %ls", pid, process_image(pid));
                break;
            }
            exe_gone = 1;
            if (live > 0) {
                DWORD code = 0;
                WaitForSingleObject(pi->hProcess, 5000);
                GetExitCodeProcess(pi->hProcess, &code);
                n_shown = blocking_pids(t, shown);
                if (n_shown > 0) {
                    /* Say what is keeping the loader around, in case it never ends. */
                    outlived = 1;
                    mlog(L"Game exe exited with code %ls; still waiting for %d process(es) it started:",
                         exit_text(code), n_shown);
                    log_blocking(shown, n_shown, t->pids_overflowed);
                }
            }
            break;
        case JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO:
            return outlived;
        }

        if (!exe_gone) continue;
        DWORD now = GetTickCount();
        if (!only_helpers_left(t)) {
            helpers_since = 0;
        } else if (!helpers_since) {
            helpers_since = now | 1;
        } else if (now - helpers_since >= 2000) {
            for (int i = 0; i < t->n_pids; i++)
                dbg(L"Not waiting for Wine helper PID %lu: %ls",
                    t->pids[i], process_image(t->pids[i]));
            mlog(L"Only Wine helper processes are left; done waiting");
            return outlived;
        }

        /* Once a process the last list named has exited but the wait goes on,
         * that list is stale: print the current one after two quiet seconds
         * (and then not more than every 30 s), so the log names what the
         * loader is really waiting for, e.g. a helper the real game left
         * behind after a launcher exe handed over to it. */
        int n_now = blocking_pids(t, now_pids);
        if (n_now == 0) continue;
        outlived = 1;
        int stale = n_shown == 0;
        for (int i = 0; i < n_shown && !stale; i++) {
            int alive = 0;
            for (int j = 0; j < n_now && !alive; j++) alive = now_pids[j] == shown[i];
            stale = !alive;
        }
        if (!stale) {
            stale_since = 0;
        } else if (!stale_since) {
            stale_since = now | 1;
        } else if (now - stale_since >= 2000 && (!last_relist || now - last_relist >= 30000)) {
            memcpy(shown, now_pids, n_now * sizeof(DWORD));
            n_shown = n_now;
            stale_since = 0;
            last_relist = now;
            mlog(L"Still waiting for %d process(es) the game started:", n_shown);
            log_blocking(shown, n_shown, t->pids_overflowed);
        }
    }
}

static DWORD launch_game(Config *cfg, const wchar_t *run_dir, int extra_argc,
                         wchar_t **extra_argv, int *launched) {
    /* Exe and ExeCommandLine are each capped at MAX_PATH_W, so this always fits. */
    static wchar_t cmd_line[MAX_CMD_LINE];
    if (cfg->exe_cmd_line[0]) {
        _snwprintf(cmd_line, MAX_CMD_LINE, L"\"%ls\" %ls", cfg->exe, cfg->exe_cmd_line);
    } else {
        _snwprintf(cmd_line, MAX_CMD_LINE, L"\"%ls\"", cfg->exe);
    }
    cmd_line[MAX_CMD_LINE - 1] = L'\0';

    /* The loader's own extra arguments go to the game, after ExeCommandLine. */
    for (int i = 0; i < extra_argc; i++) {
        if (!append_arg(cmd_line, MAX_CMD_LINE, extra_argv[i])) {
            mlog(L"Warning: command line too long, dropped argument: %ls", extra_argv[i]);
        }
    }
    if (extra_argc > 0) dbg(L"Forwarded %d extra argument(s) to the game", extra_argc);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    mlog(L"Launching: %ls", cmd_line);
    mlog(L"Working dir: %ls", run_dir[0] ? run_dir : L"(inherited)");

    ProcessTree tree;
    ZeroMemory(&tree, sizeof(tree));
    int track = cfg->persist && cfg->wait_children && tree_open(&tree);
    DWORD prio = priority_class(cfg->priority);
    DWORD_PTR affinity = affinity_mask(cfg->affinity);
    tree.priority = prio;
    /* Start it suspended when something has to be set up before it runs.
     * Wine ignores CreateProcess's priority flag, so it's set again here. */
    int suspended = track || affinity || prio;

    *launched = 0;
    BOOL ok = CreateProcessW(
        NULL,
        cmd_line,
        NULL, NULL,
        FALSE,
        (suspended ? CREATE_SUSPENDED : 0) | prio,
        NULL,
        run_dir[0] ? run_dir : NULL,
        &si,
        &pi
    );

    if (!ok) {
        DWORD e = GetLastError();
        tree_close(&tree);
        mlog(L"Error: could not start the game (%ls)", err_text(e));
        if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND)
            mlog(L"Check Exe= in the ini: is the game still installed there?");
        else if (e == ERROR_DIRECTORY)
            mlog(L"Check ExeRunDir= in the ini: it must be an existing folder");
        return 1;
    }

    if (suspended) {
        if (prio) {
            if (SetPriorityClass(pi.hProcess, prio)) dbg(L"Priority: %ls", cfg->priority);
            else mlog(L"Warning: couldn't set Priority=%ls (%ls)", cfg->priority, err_text(GetLastError()));
        }
        /* Still suspended: put it in the job and pin its CPUs before it can
         * run or start anything (its children inherit the affinity). */
        if (track && !AssignProcessToJobObject(tree.job, pi.hProcess)) {
            mlog(L"Warning: can't follow the processes the game starts (%ls); waiting for the exe only",
                 err_text(GetLastError()));
            tree_close(&tree);
            track = 0;
        }
        if (affinity) {
            DWORD_PTR proc_mask = 0, sys_mask = 0;
            GetProcessAffinityMask(GetCurrentProcess(), &proc_mask, &sys_mask);
            DWORD_PTR use = affinity & (sys_mask ? sys_mask : affinity);
            if (!use)
                mlog(L"Warning: Affinity=%ls names no CPU this machine has; ignored", cfg->affinity);
            else if (!SetProcessAffinityMask(pi.hProcess, use))
                mlog(L"Warning: couldn't set Affinity=%ls (%ls)", cfg->affinity, err_text(GetLastError()));
            else
                dbg(L"Affinity: mask 0x%lx", (unsigned long)use);
        }
        if (ResumeThread(pi.hThread) == (DWORD)-1) {
            mlog(L"Error: could not start the game (%ls)", err_text(GetLastError()));
            TerminateProcess(pi.hProcess, 1);
            tree_close(&tree);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            return 1;
        }
    }

    mlog(L"Game launched (PID %lu)", pi.dwProcessId);
    *launched = 1;

    DWORD exit_code = 0;
    if (cfg->persist) {
        dbg(L"Waiting for the game%ls to exit...", track ? L" and the processes it starts" : L"");
        int outlived = track ? tree_wait(&tree, &pi) : 0;
        WaitForSingleObject(pi.hProcess, INFINITE);     /* already done when tracking */
        GetExitCodeProcess(pi.hProcess, &exit_code);
        if (outlived)
            mlog(L"All game processes have exited; returning the exe's exit code, %ls", exit_text(exit_code));
        else
            mlog(L"Game exited with code %ls", exit_text(exit_code));
    }
    tree_close(&tree);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return exit_code;
}

/* ── Main ──────────────────────────────────────────────────────────────── */

int wmain(int argc, wchar_t *argv[]) {
    mlog(L"Mythix Loader v1.5");

    /* Find our own directory for the ini */
    wchar_t self_dir[MAX_PATH_W];
    DWORD n = GetModuleFileNameW(NULL, self_dir, MAX_PATH_W);
    if (n == 0 || n >= MAX_PATH_W) wcscpy(self_dir, L".");
    else parent_dir(self_dir);

    /* Our own flags are --ini <path> and --debug; everything else is collected
     * and passed through to the game. Everything after "--" is the game's. */
    const wchar_t *ini_override = NULL;
    wchar_t **extra = calloc((size_t)argc, sizeof(wchar_t *));
    int n_extra = 0;
    if (!extra) {
        mlog(L"Error: out of memory");
        return 1;
    }
    for (int i = 1; i < argc; i++) {
        if (wcscmp(argv[i], L"--") == 0) {
            while (++i < argc) extra[n_extra++] = argv[i];
        } else if (wcscmp(argv[i], L"--ini") == 0 && i + 1 < argc) {
            ini_override = argv[++i];
        } else if (wcscmp(argv[i], L"--debug") == 0) {
            g_debug = 1;
        } else {
            extra[n_extra++] = argv[i];
        }
    }

    wchar_t ini_path[MAX_PATH_W];
    if (ini_override) {
        set_value(ini_path, MAX_PATH_W, L"--ini", ini_override);
    } else {
        _snwprintf(ini_path, MAX_PATH_W, L"%ls\\" INI_NAME, self_dir);
        ini_path[MAX_PATH_W - 1] = L'\0';
    }

    static Config cfg;
    int r = read_ini(ini_path, &cfg);
    if (r < 0) {
        mlog(L"Error: could not read config from %ls", ini_path);
        mlog(L"Create %ls\\" INI_NAME L" with at least [MythixLoader] Exe=path", self_dir);
        free(extra);
        return 1;
    }
    if (r == 0) {
        mlog(L"Error: %ls has no Exe= under [MythixLoader]", ini_path);
        free(extra);
        return 1;
    }
    mlog(L"Config: %ls", ini_path);
    g_debug = g_debug || cfg.debug;

    /* The ini's folder: relative paths and %MYTHIX_PROFILE_DIR% refer to it. */
    wchar_t ini_full[MAX_PATH_W], ini_dir[MAX_PATH_W];
    DWORD full = GetFullPathNameW(ini_path, MAX_PATH_W, ini_full, NULL);
    if (full == 0 || full >= MAX_PATH_W) wcscpy(ini_full, ini_path);
    wcscpy(ini_dir, ini_full);
    parent_dir(ini_dir);
    SetEnvironmentVariableW(L"MYTHIX_PROFILE_DIR", ini_dir);

    /* Exe can use the inherited environment and %MYTHIX_PROFILE_DIR%. */
    expand_vars(cfg.exe, ARRAYSIZE(cfg.exe), L"Exe");
    resolve_path(cfg.exe, ARRAYSIZE(cfg.exe), ini_dir, L"Exe");
    wchar_t game_dir[MAX_PATH_W], game_dir_dos[MAX_PATH_W];
    wcscpy(game_dir, cfg.exe);
    parent_dir(game_dir);
    dos_path(game_dir, game_dir_dos, ARRAYSIZE(game_dir_dos));
    SetEnvironmentVariableW(L"MYTHIX_GAME_DIR", game_dir_dos);

    /* SteamAppId and EnvVars; everything after this can use them. */
    set_env_vars(&cfg);
    expand_vars(cfg.exe_run_dir, ARRAYSIZE(cfg.exe_run_dir), L"ExeRunDir");
    resolve_path(cfg.exe_run_dir, ARRAYSIZE(cfg.exe_run_dir), ini_dir, L"ExeRunDir");
    expand_vars(cfg.log_file, ARRAYSIZE(cfg.log_file), L"LogFile");
    resolve_path(cfg.log_file, ARRAYSIZE(cfg.log_file), ini_dir, L"LogFile");

    if (cfg.single_instance) {
        if (!cfg.persist) mlog(L"Note: SingleInstance only helps with Persist=1");
        if (wait_for_running_instance(ini_full, cfg.log_file)) {
            free(extra);
            return 0;
        }
    }
    open_log_file(cfg.log_file, 0);

    expand_vars(cfg.exe_cmd_line, ARRAYSIZE(cfg.exe_cmd_line), L"ExeCommandLine");
    expand_vars(cfg.run_before, ARRAYSIZE(cfg.run_before), L"RunBefore");
    expand_vars(cfg.run_after, ARRAYSIZE(cfg.run_after), L"RunAfter");
    expand_vars(cfg.extra_dlls, ARRAYSIZE(cfg.extra_dlls), L"ExtraDlls");

    /* Load any extra DLLs (into the loader only) */
    load_extra_dlls(&cfg);

    /* Default to the exe's own folder, like starting it from Explorer. */
    const wchar_t *run_dir = cfg.exe_run_dir[0] ? cfg.exe_run_dir : game_dir;
    run_command(L"RunBefore", cfg.run_before, run_dir);

    /* Launch the game */
    int launched = 0;
    DWORD result = launch_game(&cfg, run_dir, n_extra, extra, &launched);

    /* RunAfter: once the game has exited, or right away if it didn't start
     * (so a RunBefore/RunAfter pair still cleans up). */
    if (cfg.run_after[0]) {
        if (!launched) {
            mlog(L"The game didn't start; running RunAfter anyway");
            run_command(L"RunAfter", cfg.run_after, run_dir);
        } else if (cfg.persist) {
            run_command(L"RunAfter", cfg.run_after, run_dir);
        } else {
            mlog(L"Note: RunAfter needs Persist=1 (the loader doesn't wait for the game); skipped");
        }
    }

    free(extra);
    return (int)result;
}
