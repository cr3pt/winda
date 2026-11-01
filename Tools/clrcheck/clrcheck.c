/* Asks mscoree to start the .NET runtime. Succeeds only if Wine Mono (or .NET) is available. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/* Declared by hand: not every MinGW ships metahost.h. */
typedef HRESULT (WINAPI *CorBindToRuntimeEx_t)(LPCWSTR version, LPCWSTR flavor, DWORD flags, REFCLSID clsid, REFIID iid, LPVOID *out);
static const GUID CLSID_CorRuntimeHost_ = {0xcb2f6723, 0xab3a, 0x11d2, {0x9c, 0x40, 0x00, 0xc0, 0x4f, 0xa3, 0x0a, 0x3e}};
static const GUID IID_ICorRuntimeHost_ = {0xcb2f6722, 0xab3a, 0x11d2, {0x9c, 0x40, 0x00, 0xc0, 0x4f, 0xa3, 0x0a, 0x3e}};
typedef struct ICorRuntimeHostVtbl {
    HRESULT (WINAPI *QueryInterface)(void *, REFIID, void **);
    ULONG (WINAPI *AddRef)(void *);
    ULONG (WINAPI *Release)(void *);
    HRESULT (WINAPI *CreateLogicalThreadState)(void *);
    HRESULT (WINAPI *DeleteLogicalThreadState)(void *);
    HRESULT (WINAPI *SwitchInLogicalThreadState)(void *, DWORD *);
    HRESULT (WINAPI *SwitchOutLogicalThreadState)(void *, DWORD **);
    HRESULT (WINAPI *LocksHeldByLogicalThread)(void *, DWORD *);
    HRESULT (WINAPI *MapFile)(void *, HANDLE, HMODULE *);
    HRESULT (WINAPI *GetConfiguration)(void *, void **);
    HRESULT (WINAPI *Start)(void *);
} ICorRuntimeHostVtbl;
typedef struct { const ICorRuntimeHostVtbl *lpVtbl; } ICorRuntimeHost_;

int main(void) {
    HMODULE m = LoadLibraryW(L"mscoree.dll");
    if (!m) { printf("FAIL mscoree.dll not loadable (error %lu)\n", GetLastError()); return 1; }
    CorBindToRuntimeEx_t bind = (CorBindToRuntimeEx_t)GetProcAddress(m, "CorBindToRuntimeEx");
    if (!bind) { printf("FAIL no CorBindToRuntimeEx\n"); return 1; }
    ICorRuntimeHost_ *host = NULL;
    HRESULT hr = bind(L"v4.0.30319", L"wks", 0, &CLSID_CorRuntimeHost_, &IID_ICorRuntimeHost_, (void **)&host);
    if (FAILED(hr) || !host) { printf("FAIL CorBindToRuntimeEx hr=0x%08lx\n", (unsigned long)hr); return 1; }
    hr = host->lpVtbl->Start(host);
    printf(SUCCEEDED(hr) ? "OK runtime started\n" : "FAIL Start hr=0x%08lx\n", (unsigned long)hr);
    return FAILED(hr);
}
