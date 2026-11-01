/* Downloads an HTTPS URL with WinHTTP in N parallel threads (one session, like Steam's updater) and prints the result.
   usage: httpget host path [max-megabytes] [threads] */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <stdlib.h>

static HINTERNET session;
static const wchar_t *host, *path;
static unsigned long long limit, grand;
static volatile LONG failures;
static CRITICAL_SECTION lock;

static DWORD WINAPI worker(LPVOID arg) {
    HINTERNET c = WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", path, NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    if (!r || !WinHttpSendRequest(r, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(r, NULL)) {
        InterlockedIncrement(&failures); return 1;
    }
    static __thread char buf[1 << 16];
    unsigned long long total = 0; DWORD n;
    while (total < limit && WinHttpReadData(r, buf, sizeof buf, &n) && n) total += n;
    EnterCriticalSection(&lock); grand += total; LeaveCriticalSection(&lock);
    if (total == 0) InterlockedIncrement(&failures);
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 3) { printf("usage: httpget host path [max-megabytes] [threads]\n"); return 2; }
    host = argv[1]; path = argv[2];
    limit = (argc > 3 ? _wtoi(argv[3]) : 50) * 1024ULL * 1024ULL;
    int threads = argc > 4 ? _wtoi(argv[4]) : 1;
    if (threads < 1 || threads > 32) threads = 1;
    InitializeCriticalSection(&lock);
    session = WinHttpOpen(L"winda-httpget", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    HANDLE h[32];
    DWORD t0 = GetTickCount();
    for (int i = 0; i < threads; i++) h[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    WaitForMultipleObjects(threads, h, TRUE, 150000);
    double secs = (GetTickCount() - t0) / 1000.0;
    printf("threads=%d failures=%ld bytes=%llu seconds=%.2f MB/s=%.1f\n", threads, (long)failures, grand, secs, secs > 0 ? grand / 1048576.0 / secs : 0.0);
    fflush(stdout);
    return failures ? 1 : 0;
}
