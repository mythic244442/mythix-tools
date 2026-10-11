/* Stand-in for a game in the loader tests: prints its working directory,
 * arguments, Steam-related environment, whether it runs in a job object
 * (IN_JOB=0/1), its priority class and CPU affinity mask as UTF-8, then exits
 * with 7 (or with FAKE_EXIT, a hex code like C0000005).
 *
 * Launcher mode, for the Persist tests: with FAKE_SPAWN=1 it starts a copy
 * of itself as the "real game" and exits at once with 3, like a launcher exe.
 * FAKE_CHILD_JOB=1 puts that child in a job of its own (as Chromium/CEF do),
 * FAKE_BREAKAWAY=1 starts it with CREATE_BREAKAWAY_FROM_JOB, FAKE_SPAWN_EXE
 * names a different exe to start instead of itself. The child sleeps
 * FAKE_SLEEP_MS, then creates the file named by FAKE_MARKER and exits with 7.
 *
 * Chain mode: FAKE_CHAIN="0,2000,6000" makes a chain of processes, each
 * starting the next and then sleeping its own number of milliseconds:
 * launcher (exits at once), real game (2 s), a helper it leaves behind (6 s).
 * The last one creates FAKE_MARKER. */
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

static int start_child(const wchar_t *exe, DWORD flags, int own_job) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (own_job) flags |= CREATE_SUSPENDED;
    if (!CreateProcessW(exe, NULL, NULL, NULL, FALSE, flags, NULL, NULL, &si, &pi)) {
        printf("SPAWN=failed %lu\n", GetLastError());
        return 0;
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
    return 1;
}

static void finish(void) {
    wchar_t buf[4096];
    printf("PRIORITY_END=0x%lx\n", GetPriorityClass(GetCurrentProcess()));
    fflush(stdout);
    if (GetEnvironmentVariableW(L"FAKE_MARKER", buf, 4096)) {
        HANDLE h = CreateFileW(buf, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    }
}

/* FAKE_CHAIN: start the next link (FAKE_LEVEL + 1), then sleep this link's time. */
static int run_chain(const wchar_t *chain) {
    wchar_t buf[64], self[4096];
    int level = GetEnvironmentVariableW(L"FAKE_LEVEL", buf, 64) ? _wtoi(buf) : 0;
    DWORD sleeps[16];
    int n = 0;
    for (const wchar_t *p = chain; *p && n < 16; ) {
        sleeps[n++] = (DWORD)_wtoi(p);
        while (*p && *p != L',') p++;
        if (*p == L',') p++;
    }
    if (level + 1 < n) {
        GetModuleFileNameW(NULL, self, 4096);
        _snwprintf(buf, 64, L"%d", level + 1);
        SetEnvironmentVariableW(L"FAKE_LEVEL", buf);
        start_child(self, 0, 0);
    }
    printf("LEVEL%d=started\n", level);
    fflush(stdout);
    if (level < n) Sleep(sleeps[level]);
    if (level + 1 >= n) finish();
    return level == 0 ? 3 : 7;
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
    const wchar_t *vars[] = { L"SteamAppId", L"SteamGameId", L"MYTHIX_TEST",
                              L"MYTHIX_PROFILE_DIR", L"MYTHIX_GAME_DIR" };
    for (int i = 0; i < 5; i++) {
        char label[64];
        WideCharToMultiByte(CP_UTF8, 0, vars[i], -1, label, sizeof(label), NULL, NULL);
        if (GetEnvironmentVariableW(vars[i], buf, 4096)) put(label, buf);
        else printf("%s=<unset>\n", label);
    }
    BOOL in_job = FALSE;
    IsProcessInJob(GetCurrentProcess(), NULL, &in_job);
    printf("IN_JOB=%d\n", in_job ? 1 : 0);
    DWORD_PTR proc_mask = 0, sys_mask = 0;
    GetProcessAffinityMask(GetCurrentProcess(), &proc_mask, &sys_mask);
    printf("PRIORITY=0x%lx\nAFFINITY=0x%lx\n", GetPriorityClass(GetCurrentProcess()),
           (unsigned long)proc_mask);
    fflush(stdout);

    if (GetEnvironmentVariableW(L"FAKE_CHAIN", buf, 4096)) return run_chain(buf);

    if (env_on(L"FAKE_SPAWN")) {
        wchar_t exe[4096];
        if (!GetEnvironmentVariableW(L"FAKE_SPAWN_EXE", exe, 4096))
            GetModuleFileNameW(NULL, exe, 4096);
        SetEnvironmentVariableW(L"FAKE_SPAWN", NULL);     /* the child is the game */
        return start_child(exe, env_on(L"FAKE_BREAKAWAY") ? CREATE_BREAKAWAY_FROM_JOB : 0,
                           env_on(L"FAKE_CHILD_JOB")) ? 3 : 1;
    }

    if (GetEnvironmentVariableW(L"FAKE_SLEEP_MS", buf, 4096)) Sleep((DWORD)_wtoi(buf));
    finish();
    if (GetEnvironmentVariableW(L"FAKE_EXIT", buf, 4096)) ExitProcess((UINT)wcstoul(buf, NULL, 16));
    return 7;
}
