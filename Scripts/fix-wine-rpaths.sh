#!/bin/bash
# Makes a self-built Wine find the shared libraries copied into its lib/ folder.
# usage: fix-wine-rpaths.sh <engine-root>   (the folder that holds bin/ and lib/)
set -eu
E="$1"
n=0
for f in "$E"/lib/wine/x86_64-unix/*.so; do
  install_name_tool -add_rpath @loader_path/../../ "$f" 2>/dev/null && n=$((n+1)) || true
done
for f in "$E"/bin/wine "$E"/bin/wineserver; do
  install_name_tool -add_rpath @loader_path/../lib "$f" 2>/dev/null && n=$((n+1)) || true
done
echo "added rpaths to $n files"
