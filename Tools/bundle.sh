#!/bin/zsh
# Empaquette Fil en application macOS signée ad hoc, pour l'essayer comme une vraie app
# (Dock, nom dans la barre des menus, trousseau au nom de Fil).
#
#   Tools/bundle.sh            # build debug → .build/Fil.app
#   Tools/bundle.sh release    # build optimisé
#   FIL_APP_DIR=~/Applications Tools/bundle.sh release
#
# Pour une distribution : construire hors d'un dossier synchronisé, signer avec une identité
# Developer ID, puis recopier avec `ditto --noextattr --norsrc` (voir Support/DISTRIBUTION.md).
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-debug}"
OUTPUT="${FIL_APP_DIR:-$ROOT/.build}"
APP="$OUTPUT/Fil.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/Fil"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Fil"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/Icon/Fil.icns" "$APP/Contents/Resources/Fil.icns"
# La version vient du code (Sources/Fil/Model/AppVersion.swift) ; le numéro de build, du nombre de commits.
VERSION="$(sed -nE 's/.*static let current = "([^"]+)".*/\1/p' "$ROOT/Sources/Fil/Model/AppVersion.swift")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
[[ -n "$VERSION" ]] || { echo "Version introuvable dans AppVersion.swift" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"

echo "$APP ($VERSION, build $BUILD)"
