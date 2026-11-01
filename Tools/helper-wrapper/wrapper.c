/* Stands in for an executable that was renamed to <name>_real.exe. It starts the real program with the
   original arguments plus extra switches read from "<own path>.wrapargs" (one line). Child processes the
   real program starts use its own path, so only the first process goes through this wrapper. Used to
   work around CEF 126 painting black windows under Wine on macOS. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static wchar_t *read_extra(const wchar_t *self) {
    wchar_t path[MAX_PATH + 16];
    swprintf(path, MAX_PATH + 16, L"%ls.wrapargs", self);
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return NULL;
    char buf[1024]; DWORD n = 0;
    ReadFile(f, buf, sizeof buf - 1, &n, NULL);
    CloseHandle(f);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) n--;
    buf[n] = 0;
    wchar_t *w = malloc((n + 1) * sizeof(wchar_t));
    for (DWORD i = 0; i <= n; i++) w[i] = (unsigned char)buf[i];
    return w;
}

int wmain(void) {
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t dir[MAX_PATH], real[MAX_PATH];
    wcscpy(dir, self);
    wchar_t *slash = wcsrchr(dir, L'\\');
    if (slash) *slash = 0;
    wcscpy(real, self);
    wchar_t *dot = wcsrchr(real, L'.');
    if (dot) *dot = 0;
    wcscat(real, L"_real.exe");

    const wchar_t *cl = GetCommandLineW();
    if (*cl == L'"') { cl++; while (*cl && *cl != L'"') cl++; if (*cl) cl++; }
    else while (*cl && *cl != L' ') cl++;

    wchar_t *extra = read_extra(self);
    int is_child = wcsstr(cl, L"--type=") != NULL;
    size_t cap = wcslen(cl) + MAX_PATH + (extra ? wcslen(extra) : 0) + 32;
    wchar_t *cmd = malloc(cap * sizeof(wchar_t));
    swprintf(cmd, cap, L"\"%ls\"%ls %ls", real, cl, (extra && !is_child) ? extra : L"");

    STARTUPINFOW si = { sizeof si };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, dir, &si, &pi)) return 127;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
