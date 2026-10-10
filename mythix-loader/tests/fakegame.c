/* Stand-in for a game in the loader tests: prints its working directory,
 * arguments and Steam-related environment as UTF-8, then exits with 7.
 *
 * Launcher mode, for the Persist tests: with FAKE_SPAWN=1 it starts a copy
 * of itself as the "real game" and exits at once with 3, like a launcher exe.
 * FAKE_CHILD_JOB=1 puts that child in a job of its own (as Chromium/CEF do),
 * FAKE_BREAKAWAY=1 starts it with CREATE_BREAKAWAY_FROM_JOB. The child sleeps
 * FAKE_SLEEP_MS, then creates the file named by FAKE_MARKER and exits with 7. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void put(const char *label, const wchar_t *w) {
    char u8[16384];
    WideCharToMultiByte(CP_UTF8, 0, w, -1, u8, sizeof(u8), NULL, NULL);
    printf("%s=%s\n", label, u8);
}

static int env_on(const wchar_t *name) {
    wchar_t v[8];
    return GetEnvironmentVariableW(name, v, 8) && v[0] == L'1';
}

static int spawn_real_game(void) {
    wchar_t self[4096];
    GetModuleFileNameW(NULL, self, 4096);
    SetEnvironmentVariableW(L"FAKE_SPAWN", NULL);     /* the child is the game */

    DWORD flags = env_on(L"FAKE_BREAKAWAY") ? CREATE_BREAKAWAY_FROM_JOB : 0;
    int own_job = env_on(L"FAKE_CHILD_JOB");
    if (own_job) flags |= CREATE_SUSPENDED;

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessW(self, NULL, NULL, NULL, FALSE, flags, NULL, NULL, &si, &pi)) {
        printf("SPAWN=failed %lu\n", GetLastError());
        return 1;
    }
    if (own_job) {
        HANDLE job = CreateJobObjectW(NULL, NULL);
        BOOL ok = job && AssignProcessToJobObject(job, pi.hProcess);
        printf("CHILD_JOB=%s\n", ok ? "ok" : "failed");
        ResumeThread(pi.hThread);
    }
    printf("SPAWN=ok\n");
    fflush(stdout);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 3;
}

int wmain(int argc, wchar_t **argv) {
    wchar_t buf[4096];
    GetCurrentDirectoryW(4096, buf);
    put("CWD", buf);
    for (int i = 1; i < argc; i++) {
        char label[32];
        snprintf(label, sizeof(label), "ARG%d", i);
        put(label, argv[i]);
    }
    const wchar_t *vars[] = { L"SteamAppId", L"SteamGameId", L"MYTHIX_TEST" };
    for (int i = 0; i < 3; i++) {
        char label[64];
        WideCharToMultiByte(CP_UTF8, 0, vars[i], -1, label, sizeof(label), NULL, NULL);
        if (GetEnvironmentVariableW(vars[i], buf, 4096)) put(label, buf);
        else printf("%s=<unset>\n", label);
    }
    fflush(stdout);

    if (env_on(L"FAKE_SPAWN")) return spawn_real_game();

    if (GetEnvironmentVariableW(L"FAKE_SLEEP_MS", buf, 4096)) Sleep((DWORD)_wtoi(buf));
    if (GetEnvironmentVariableW(L"FAKE_MARKER", buf, 4096)) {
        HANDLE h = CreateFileW(buf, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    }
    return 7;
}
