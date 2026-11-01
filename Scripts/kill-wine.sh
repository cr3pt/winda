#!/bin/bash
# Stops every Wine/Steam process this project can start, then verifies none is left. Developer tool.
PATTERNS='C:\\|Wine Devel\.app|Game Porting Toolkit\.app|wine64-preloader|wineserver|winda-bottle|winedevice|steamwebhelper|cx-wine|wine-cx|cxtest|dx11test|winshot'
left() { ps -axo pid,command | grep -E "$PATTERNS" | grep -v -E "grep|ps -axo|kill-wine" | wc -l | tr -d ' '; }
for w in /Volumes/1TB/winda/home/engines/*/Wine\ Devel.app/Contents/Resources/wine/bin/wineserver; do
  [ -x "$w" ] && for p in /Volumes/1TB/winda/home/bottles/*/prefix; do WINEPREFIX="$p" "$w" -k 2>/dev/null; done
done
pkill -TERM -f "$PATTERNS" 2>/dev/null; sleep 2
[ "$(left)" != 0 ] && { pkill -KILL -f "$PATTERNS" 2>/dev/null; sleep 1; }
echo "wine processes left: $(left)"
