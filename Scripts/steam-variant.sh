#!/bin/bash
# Restarts Steam in the WinDA "steam" bottle with a chosen rendering variant. Developer tool.
# usage: steam-variant.sh <variant>      variants: default | nogpu | noangle | retina | inproc | inproc32 | single | restore | transparent
set -u
H="${WINDA_HOME:-/Volumes/1TB/winda/home}"
W="$H/engines/wine-gcenx-11.21/Wine Devel.app/Contents/Resources/wine/bin"
export WINEPREFIX="$H/bottles/steam/prefix" WINEDEBUG=-all
OVERRIDES="mscoree,mshtml=;d3d11,d3d10core=n,b"      # DXVK layer on, as the recipe sets it
ARGS=(-no-cef-sandbox)
v="${1:-default}"

# Stop every Wine process first, not only this bottle's server.
"$(dirname "$0")/kill-wine.sh"

reg() { arch -x86_64 "$W/wine" reg "$@" >/dev/null 2>&1; }
# Reset the registry knobs these variants touch.
reg delete 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /f
reg delete 'HKCU\Software\Wine\Mac Driver' /v OpenGLSurfaceMode /f

HELPER_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
wrapper_on() {
  WRAPPER="$(dirname "$0")/../Tools/helper-wrapper/helper-wrapper.exe"
  [ -f "$WRAPPER" ] || { echo "wrapper binary missing: $WRAPPER"; exit 3; }
  [ -f "$HELPER_DIR/steamwebhelper_real.exe" ] || mv "$HELPER_DIR/steamwebhelper.exe" "$HELPER_DIR/steamwebhelper_real.exe"
  cp "$WRAPPER" "$HELPER_DIR/steamwebhelper.exe"
}
wrapper_off() {
  [ -f "$HELPER_DIR/steamwebhelper_real.exe" ] && mv -f "$HELPER_DIR/steamwebhelper_real.exe" "$HELPER_DIR/steamwebhelper.exe"
}
[ "$v" != single ] && wrapper_off

case "$v" in
  default)     ARGS=(-no-cef-sandbox) ;;
  nogpu)       ARGS=(-cef-disable-gpu -cef-disable-gpu-compositing -cef-disable-d3d11 -no-cef-sandbox) ;;
  noangle)     ARGS=(-cef-disable-gpu -no-cef-sandbox); OVERRIDES="mscoree,mshtml=;d3d11,d3d10core=b" ;;
  retina)      reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /d y /f; ARGS=(-cef-disable-gpu -no-cef-sandbox) ;;
  inproc)      ARGS=(-cef-disable-gpu -cef-in-process-gpu -no-cef-sandbox) ;;
  inproc32)    ARGS=(-cef-force-32bit -cef-in-process-gpu -no-cef-sandbox) ;;
  single)      wrapper_on; ARGS=(-noverifyfiles -norepairfiles -no-cef-sandbox) ;;
  restore)     ARGS=(-no-cef-sandbox) ;;
  transparent) reg add 'HKCU\Software\Wine\Mac Driver' /v OpenGLSurfaceMode /d transparent /f; ARGS=(-no-cef-sandbox) ;;
  *) echo "unknown variant $v"; exit 2 ;;
esac

echo "variant=$v args=${ARGS[*]} overrides=$OVERRIDES"
cd /tmp && WINEDLLOVERRIDES="$OVERRIDES" nohup arch -x86_64 "$W/wine" 'C:\Program Files (x86)\Steam\steam.exe' "${ARGS[@]}" > "$H/logs/steam-$v.log" 2>&1 &
echo "started pid $!"
