#!/bin/zsh
# Empaquette Fil en application macOS signée, pour l'essayer comme une vraie app
# (Dock, nom dans la barre des menus, trousseau au nom de Fil).
#
#   Tools/bundle.sh            # build debug → .build/Fil.app
#   Tools/bundle.sh release    # build optimisé
#   FIL_APP_DIR=~/Applications Tools/bundle.sh release
#
# Signature : FIL_SIGN_IDENTITY si défini, sinon la première identité « Apple Development »
# du trousseau, sinon ad hoc. Une identité stable garde la même exigence désignée d'un build
# à l'autre : « Toujours autoriser » sur un mot de passe du trousseau tient alors entre les
# recompilations. En ad hoc, l'exigence est l'empreinte du binaire et macOS redemande à chaque build.
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
# En release, les symboles locaux partent : le binaire pèse deux fois moins (3,7 → 1,8 Mo).
[[ "$CONFIGURATION" == release ]] && strip -x "$APP/Contents/MacOS/Fil"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/Icon/Fil.icns" "$APP/Contents/Resources/Fil.icns"
# La version vient du code (Sources/Fil/Model/AppVersion.swift) ; le numéro de build, du nombre de commits.
VERSION="$(sed -nE 's/.*static let current = "([^"]+)".*/\1/p' "$ROOT/Sources/Fil/Model/AppVersion.swift")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
[[ -n "$VERSION" ]] || { echo "Version introuvable dans AppVersion.swift" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
IDENTITY="${FIL_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Apple Development: .*/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "Aucune identité Apple Development : signature ad hoc, le trousseau redemandera l'accès après chaque build." >&2
    codesign --force --sign - --timestamp=none "$APP"
fi

echo "$APP ($VERSION, build $BUILD)"
