#!/bin/zsh
# Régénère l'icône depuis les sources SVG de Support/Icon/ :
#   Fil.svg       → Fil-1024.png et les tailles 64 à 1024 de Fil.icns
#   Fil-small.svg → les tailles 16 et 32 (trait épaissi, sans détail)
#   Fil-iOS.svg   → AppIcon iOS 1024, opaque (iOS applique lui-même le masque)
# Quick Look (qlmanage) rend les SVG avec leurs filtres (ombre portée), ce que NSImage ne fait pas ;
# Tools/render-icon.swift réduit ensuite chaque PNG et retire l'alpha pour iOS.
set -euo pipefail
ROOT="${0:A:h:h}"
ICON="$ROOT/Support/Icon"
WORK="$(mktemp -d)"
SET="$WORK/Fil.iconset"
mkdir -p "$SET"
trap 'rm -rf "$WORK"' EXIT

for name in Fil Fil-small Fil-iOS; do
    qlmanage -t -s 1024 -o "$WORK" "$ICON/$name.svg" >/dev/null
done
render() { swift "$ROOT/Tools/render-icon.swift" "$@"; }

render "$WORK/Fil-small.svg.png" "$SET/icon_16x16.png" 16
render "$WORK/Fil-small.svg.png" "$SET/icon_16x16@2x.png" 32
render "$WORK/Fil-small.svg.png" "$SET/icon_32x32.png" 32
render "$WORK/Fil.svg.png" "$SET/icon_32x32@2x.png" 64
for px in 128 256 512; do
    render "$WORK/Fil.svg.png" "$SET/icon_${px}x${px}.png" $px
    render "$WORK/Fil.svg.png" "$SET/icon_${px}x${px}@2x.png" $((px * 2))
done
iconutil -c icns "$SET" -o "$ICON/Fil.icns"
cp "$SET/icon_512x512@2x.png" "$ICON/Fil-1024.png"
render "$WORK/Fil-iOS.svg.png" "$ROOT/iOS/Fil/Assets.xcassets/AppIcon.appiconset/Fil-iOS-1024.png" 1024 opaque
echo "$ICON/Fil.icns"
