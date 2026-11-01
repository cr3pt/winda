# WinDA

A native macOS app (Apple Silicon) that makes running Windows programs and games easier than configuring Wine by hand.
Drop a `.exe`, and WinDA picks an engine, builds a bottle and applies a community recipe for you.

**Status: early prototype.** It runs a DirectX 11 test program through Wine + DXVK and through Wine + D3DMetal.
It has not been tested on real games yet, is not signed or notarized, and its engine packaging is not portable.

## How it works

- **Engines** are described by JSON manifests (a pinned URL, SHA-256 and size). WinDA verifies them before use. Supported kinds: a Wine build, a graphics layer (DXVK), and tools (winetricks).
- **Recipes** are declarative JSON files (environment variables, winetricks verbs, registry values, hash-pinned downloads). They contain no scripts. A recipe is matched by file hash or file name.
- **Bottles** are Wine prefixes created per recipe and hidden from the user.
- **D3DMetal** is Apple's and is not included. You download the Game Porting Toolkit from Apple yourself, and WinDA imports it after you accept Apple's license. A derived engine is registered only if it passes a DirectX 11 smoke test.

## Layout

| Path | What |
| --- | --- |
| `Sources/WinDACore` | Library: recipes, engines, bottles, launcher, importer |
| `Sources/WinDA` | SwiftUI app |
| `Sources/winda-*` | Command line tools (`recipe`, `engine`, `bottle`, `shortcut`, `gptk`, `spike`) |
| `Examples` | Sample recipes and engine manifests |
| `Tools/dx11test` | Source of the DirectX 11 smoke-test program |
| `Scripts/make-app.sh` | Builds `dist/WinDA.app` |

## Build

Needs macOS 15+ on Apple Silicon and Xcode (for the test suite).

```sh
swift build
swift test
Scripts/make-app.sh
```

The app reads its data from `WINDA_HOME` (default `~/Library/Application Support/WinDA`) with `engines/`, `manifests/`, `recipes/`, `bottles/`.

## Not included

WinDA does not bundle Wine, DXVK, MoltenVK or D3DMetal. D3DMetal's license (Apple Game Porting Toolkit) restricts use and allows only non-commercial redistribution; read it before you use or share it.

## License

GPL-3.0, see `LICENSE`.
