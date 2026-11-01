/* Lists top-level windows and saves each visible one as a BMP, using PrintWindow and a screen BitBlt.
   usage: winshot.exe <output-dir> */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int idx = 0;
static BOOL CALLBACK each(HWND hwnd, LPARAM lp);
static BOOL CALLBACK each_child(HWND hwnd, LPARAM lp) {
    /* EnumChildWindows also visits grandchildren; only handle direct children here. */
    if (GetParent(hwnd) != GetAncestor(hwnd, GA_PARENT)) return TRUE;
    return each(hwnd, lp);
}
static const char *outdir;

static void save_bmp(const char *path, HDC dc, HBITMAP bm, int w, int h) {
    BITMAPINFOHEADER bi = {sizeof bi, w, -h, 1, 32, BI_RGB};
    size_t n = (size_t)w * h * 4;
    unsigned char *px = malloc(n);
    GetDIBits(dc, bm, 0, h, px, (BITMAPINFO *)&bi, DIB_RGB_COLORS);
    BITMAPFILEHEADER fh = {0x4D42, (DWORD)(sizeof fh + sizeof bi + n), 0, 0, sizeof fh + sizeof bi};
    BITMAPINFOHEADER top = bi; top.biHeight = -h;
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(&fh, sizeof fh, 1, f); fwrite(&top, sizeof top, 1, f); fwrite(px, 1, n, f); fclose(f); }
    long nonblack = 0;
    for (size_t i = 0; i < n; i += 4) if (px[i] | px[i+1] | px[i+2]) nonblack++;
    printf("  saved %s (%dx%d) non-black pixels: %ld of %d\n", path, w, h, nonblack, w * h);
    free(px);
}

static BOOL CALLBACK each(HWND hwnd, LPARAM lp) {
    if (!IsWindowVisible(hwnd)) return TRUE;
    int depth = (int)lp;
    RECT r; GetWindowRect(hwnd, &r);
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w < 50 || h < 50) return TRUE;
    char title[128] = "", cls[128] = "";
    GetWindowTextA(hwnd, title, sizeof title); GetClassNameA(hwnd, cls, sizeof cls);
    printf("%*swindow %p class=%s title=\"%s\" %dx%d at %ld,%ld style=%08lx ex=%08lx\n", depth * 2, "", (void *)hwnd, cls, title, w, h,
           r.left, r.top, (unsigned long)GetWindowLongA(hwnd, GWL_STYLE), (unsigned long)GetWindowLongA(hwnd, GWL_EXSTYLE));

    HDC screen = GetDC(NULL), mem = CreateCompatibleDC(screen);
    HBITMAP bm = CreateCompatibleBitmap(screen, w, h);
    SelectObject(mem, bm);
    char path[512];
    BOOL ok = PrintWindow(hwnd, mem, 2 /* PW_RENDERFULLCONTENT */);
    printf("  PrintWindow: %s\n", ok ? "ok" : "failed");
    snprintf(path, sizeof path, "%s/win%d-printwindow.bmp", outdir, idx);
    save_bmp(path, mem, bm, w, h);
    BitBlt(mem, 0, 0, w, h, screen, r.left, r.top, SRCCOPY);
    snprintf(path, sizeof path, "%s/win%d-screen.bmp", outdir, idx);
    save_bmp(path, mem, bm, w, h);
    idx++;
    DeleteObject(bm); DeleteDC(mem); ReleaseDC(NULL, screen);
    EnumChildWindows(hwnd, each_child, depth + 1);
    return TRUE;
}

int main(int argc, char **argv) {
    outdir = argc > 1 ? argv[1] : ".";
    EnumWindows(each, 0);
    printf("%d windows captured\n", idx);
    return 0;
}
