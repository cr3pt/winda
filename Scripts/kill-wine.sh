#!/bin/bash
# Stops every Wine/Steam process this project can start, then verifies none is left. Developer tool.
PATTERNS='C:\\|Wine Devel\.app|Game Porting Toolkit\.app|wine64-preloader|wineserver|winda-bottle|winedevice|steamwebhelper|cx-wine|wine-cx|cxtest|dx11test|winshot'
# Steam must quit cleanly: killing it mid-update makes it download its whole client again.
# Ask it to shut down through WinDA first (needs the built CLI); anything left is killed below.
STOP="$(dirname "$0")/../.build/debug/winda-bottle"
if [ -x "$STOP" ] && ps -axo command | grep -q "[s]team.exe"; then
  H=/Volumes/1TB/winda/home
  "$STOP" stop --recipe "$(dirname "$0")/../Examples/steam.json" --manifests "$(dirname "$0")/../Examples/engines" \
    --engine-root "$H/engines" --bottles "$H/bottles" 2>&1 | tail -1
fi
left() { ps -axo pid,command | grep -E "$PATTERNS" | grep -v -E "grep|ps -axo|kill-wine" | wc -l | tr -d ' '; }
for w in /Volumes/1TB/winda/home/engines/*/Wine\ Devel.app/Contents/Resources/wine/bin/wineserver; do
  [ -x "$w" ] && for p in /Volumes/1TB/winda/home/bottles/*/prefix; do WINEPREFIX="$p" "$w" -k 2>/dev/null; done
done
pkill -TERM -f "$PATTERNS" 2>/dev/null; sleep 2
[ "$(left)" != 0 ] && { pkill -KILL -f "$PATTERNS" 2>/dev/null; sleep 1; }
echo "wine processes left: $(left)"
