#!/bin/bash
# Starts the Paradox Launcher (Electron) in the Steam bottle with the given Chromium switches and reports
# whether its window appears and whether the GPU process or main window failed. Developer tool.
# usage: paradox-variant.sh <switch>...
H="${WINDA_HOME:-/Volumes/1TB/winda/home}"
E="$H/engines/wine-cx-26.3-tls-d3dm-4.0b3"
P="$H/bottles/steam/prefix"
LOG="$P/drive_c/users/crossover/AppData/Local/Paradox Interactive/launcher-v2/logs/launcher-$(date -u +%Y-%m-%d).log"
EXE=$(ls -d "$P/drive_c/Program Files/Paradox Interactive/launcher"/launcher-v2.*/ | sort -V | tail -1)
WIN="C:\\Program Files\\Paradox Interactive\\launcher\\$(basename "$EXE")\\Paradox Launcher.exe"

pkill -f "Paradox Launcher" ; pkill -f "cpatch.exe"; pkill -f "winedbg"; sleep 3
before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
cd /tmp && WINEPREFIX=$P WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=" CX_APPLEGPTK_LIBD3DSHARED_PATH=$E/lib/external/libd3dshared.dylib \
  nohup arch -x86_64 $E/bin/wine "$WIN" "$@" > "$H/logs/paradox-variant.log" 2>&1 &
n=0; until /tmp/winlist | awk -F'|' '$4 ~ /true/ && $6 ~ /\(1[0-9][0-9][0-9],[0-9]+ 12[0-9][0-9]x6[0-9][0-9]\)/' | grep -q . || [ $n -gt 18 ]; do sleep 3; n=$((n+1)); done
sleep 8
new=$(tail -n +$((before+1)) "$LOG" 2>/dev/null)
gpu=$(echo "$new" | grep -c "GPU process crash")
init=$(echo "$new" | grep -c "did not initialize properly")
win=$(/tmp/winlist | awk -F'|' '$4 ~ /true/ && $6 ~ /12[0-9][0-9]x6[0-9][0-9]\)/' | wc -l | tr -d ' ')
alive=$(ps -axo command | grep -c '[P]aradox Launcher.exe')
echo "flags: $* | launcher window on screen: $win | gpu crashes: $gpu | main-window-init failures: $init | processes: $alive"
