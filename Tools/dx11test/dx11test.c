#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcA(h, m, w, l);
}

int main(void) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "dx11test"; wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("dx11test", "WinDA dx11test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 360, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 360;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    if (FAILED(hr)) { printf("FAIL: D3D11CreateDeviceAndSwapChain hr=0x%08lx\n", (unsigned long)hr); return 1; }

    IDXGIDevice *dxgi = NULL; IDXGIAdapter *ad = NULL; DXGI_ADAPTER_DESC desc = {0};
    ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi);
    IDXGIDevice_GetAdapter(dxgi, &ad);
    IDXGIAdapter_GetDesc(ad, &desc);
    char name[128]; WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof name, NULL, NULL);
    printf("feature_level=0x%x adapter=\"%s\" vram_mb=%llu\n", (unsigned)fl, name,
           (unsigned long long)(desc.DedicatedVideoMemory >> 20));
    char dll[MAX_PATH] = "?"; GetModuleFileNameA(GetModuleHandleA("d3d11.dll"), dll, sizeof dll);
    printf("d3d11=%s\n", dll);

    ID3D11Texture2D *bb = NULL; ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);

    DWORD t0 = GetTickCount(); int frames = 0;
    while (frames < 180) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        float t = frames / 180.0f; float c[4] = {t, 0.2f, 1.0f - t, 1.0f};
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        if (FAILED(IDXGISwapChain_Present(sc, 1, 0))) { printf("FAIL: Present\n"); return 2; }
        frames++;
    }
    DWORD ms = GetTickCount() - t0;
    printf("OK: %d frames in %lu ms (%.1f fps)\n", frames, (unsigned long)ms, frames * 1000.0 / ms);
    return 0;
}
