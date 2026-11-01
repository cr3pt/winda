/* Makes an HTTPS request through WinHTTP (schannel -> gnutls under Wine) and prints the status code. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv) {
    const wchar_t *host = argc > 1 ? argv[1] : L"client-update.steamstatic.com";
    HINTERNET s = WinHttpOpen(L"winda-tlscheck", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    HINTERNET c = s ? WinHttpConnect(s, host, INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", L"/", NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    if (!r || !WinHttpSendRequest(r, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(r, NULL)) {
        wprintf(L"FAIL %ls error=%lu\n", host, GetLastError());
        return 1;
    }
    DWORD code = 0, size = sizeof code;
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &code, &size, NULL);
    wprintf(L"OK %ls status=%lu\n", host, code);
    return 0;
}
