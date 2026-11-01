# WinDA – plan

Nakładka na macOS (Apple Silicon) ułatwiająca uruchamianie aplikacji i gier Windows. Zastępuje ręczną konfigurację Wine. Punkty odniesienia: CrossOver, Whisky (archiwalny).

## Produkt
- Tylko nakładka na istniejące komponenty: Wine (buildy Gcenx/upstream), GPTK/D3DMetal, DXVK+MoltenVK, Rosetta 2. Bez własnej warstwy zgodności.
- Użytkownicy: zwykli ludzie; tryb zaawansowany za przełącznikiem.
- Priorytet: gry. Kategoria "Aplikacje" w schemacie od początku, pusta do po v1.
- Tylko Apple Silicon, macOS 15+. Rosetta 2 instalowana za zgodą użytkownika.
- Swift/SwiftUI, natywnie.

## Model działania
- Bottle ukryty. Użytkownik widzi aplikacje; każda gra/program to własny `.app`.
- Wejście: drag&drop `.exe` lub biblioteka Steam/GOG. Recepta po nazwie/hashu; bez dopasowania profil domyślny + komunikat "nie testowano".
- Launchery we wspólnym bottle'u; recepta może wymusić osobny.
- Brak `Z:` → `/`; foldery użytkownika mapowane jawnie. To nie jest sandbox i UI mówi to wprost.

## Silniki
- Paczki z manifestem, aktualizowane niezależnie od aplikacji. Własnego Wine nie budujemy. CI testuje gry referencyjne.
- D3DMetal w v1: użytkownik importuje GPTK z Apple, WinDA weryfikuje hash i instaluje. Równolegle pytanie licencyjne do Apple. Architektura zostawia furtkę na bundlowanie.
- Wybór silnika per recepta. Bez recepty: D3DMetal jeśli zaimportowany, inaczej DXVK. DX12 → "wymaga D3DMetal".

## Baza recept
- Publiczne repo, PR-y, walidacja schematu w CI, "zweryfikowana" po 3 niezależnych potwierdzeniach.
- Wyłącznie deklaratywne akcje z zamkniętej listy (winetricks verb, klucz rejestru, zmienna środowiskowa, pobranie z SHA-256). Zero skryptów.
- Anti-cheat kernelowy: "Niezgodne", bez obchodzenia.
- Telemetria: brak. Zgłoszenia jawne, z podglądem danych, bez danych osobowych.

## Projekt
- Open source, GPL-3, nowa baza kodu; otwarty format recept/silników; rozmowy z maintainerami forków Whisky (frankea/Whisky, Uncorked).
- Dystrybucja bez podpisu: GitHub Releases + własny tap Homebrew (`--no-quarantine`), ad-hoc signature, Sparkle (EdDSA). Developer ID/notaryzacja później.
- Org GitHub `winda-app`, dokument "jak przejąć projekt".
- Nazwa WinDA: rezerwacja nazw + sprawdzenie baz znaków przed logo. Bez "Windows" w nazwie/logo; zastrzeżenie o niezależności od Microsoftu, Apple, CodeWeavers.
- Repo/dokumentacja/recepty po angielsku; UI lokalizowany od v1.1 (polski pierwszy).

## Zakres v1
Drag&drop `.exe`, Steam jako launcher-recepta, DXVK + D3DMetal, 20–30 gier z receptami, skróty `.app`. Podstawowe opcje: logi, Metal HUD (`MTL_HUD_ENABLED`), eksport zgłoszenia. Kontrolery przez Wine/macOS, bez własnego mapowania. Bez Intela.

## Kolejność
1. Spike w Swift: jedna gra przez DXVK, jedna przez D3DMetal, bez UI
2. Format recept i silników (**start: `WinDACore`**)
3. Minimalne UI (drag&drop)
4. Steam jako recepta
5. 20–30 gier
6. Publiczna alfa

## Do sprawdzenia
- Aktualny tekst licencji GPTK/D3DMetal.
- Dostępność nazwy WinDA (USPTO/EUIPO/UPRP, GitHub).
- Stan Homebrew wobec niepodpisanych cask-ów.

## Stan (2026-11-01)

Zmiany względem założeń:
- **D3DMetal jest w v1** (Q17), przez import GPTK od użytkownika (Q19). Licencja Apple zezwala na niekomercyjną redystrybucję, ale tylko do "oceny gier"; zakres granie vs ocena wymaga odpowiedzi Apple.
- **D3DMetal wymaga osobnego Wine.** GPTK 4.0b3 działa na Wine 11 zbudowanym ze źródeł CrossOver 26.3 (nie działa na Wine 7.7 z Gcenx). Silniki pochodne rejestruje się dopiero po zdanym teście DX11.
- **DXVK-macOS 1.10.3** (Gcenx) działa na bundlowanym MoltenVK; DXVK 3.x nie.
- Zrobione: manifesty silników, instalator z hashem, bottle, recepty, skróty `.app`, aplikacja SwiftUI, winetricks, import GPTK. 70 testów.

Nie zrobione: przenośny build Wine (gnutls, SDL2, MoltenVK, rpath), Steam, prawdziwe gry, ikony skrótów, podpis i notaryzacja, hosting binariów silników.
