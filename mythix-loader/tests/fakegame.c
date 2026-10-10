/* Stand-in for a game in the loader tests: prints its working directory,
 * arguments and Steam-related environment as UTF-8, then exits with 7. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

static void put(const char *label, const wchar_t *w) {
    char u8[16384];
    WideCharToMultiByte(CP_UTF8, 0, w, -1, u8, sizeof(u8), NULL, NULL);
    printf("%s=%s\n", label, u8);
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
    return 7;
}
