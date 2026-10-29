#!/bin/zsh
# Construit Fil.app en release, la signe avec une identité Developer ID (runtime renforcé), la fait
# notariser par Apple, agrafe le ticket, puis produit Fil-<version>.zip prêt à distribuer.
#
#   FIL_SIGN_IDENTITY="Developer ID Application: Nom (ABCDE12345)" \
#   FIL_NOTARY_PROFILE=fil-notary \
#   Tools/release.sh
#
# Une fois, pour enregistrer les identifiants de notarisation dans le trousseau (rien n'est écrit ici) :
#   xcrun notarytool store-credentials fil-notary --apple-id <identifiant Apple> --team-id <ABCDE12345>
#
# Variables :
#   FIL_SIGN_IDENTITY   identité de signature (voir `security find-identity -v -p codesigning`)
#   FIL_NOTARY_PROFILE  profil `notarytool` du trousseau
#   FIL_RELEASE_DIR     dossier de sortie, hors de tout dossier synchronisé (défaut : ~/Builds)
#
# Rien n'est envoyé à Apple tant que la signature et le contrôle local ne sont pas passés.
# Voir Support/DISTRIBUTION.md.
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${FIL_RELEASE_DIR:-$HOME/Builds}"

fail() { echo "release.sh : $*" >&2; exit 1; }

[[ -n "${FIL_SIGN_IDENTITY:-}" ]] || fail "FIL_SIGN_IDENTITY manque. Identités disponibles :
$(security find-identity -v -p codesigning | sed 's/^/  /')
Il faut une « Developer ID Application » : une identité « Apple Development » ne se notarise pas."
[[ "$FIL_SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || fail "« $FIL_SIGN_IDENTITY » n'est pas une identité « Developer ID Application »."
[[ -n "${FIL_NOTARY_PROFILE:-}" ]] || fail "FIL_NOTARY_PROFILE manque (profil créé avec \`xcrun notarytool store-credentials\`)."

# Les attributs étendus qu'ajoutent iCloud Drive ou Dropbox cassent la signature.
case "${OUTPUT:A}" in
    *"/Library/Mobile Documents/"*|*"/iCloud"*|*"/Dropbox"*|*"/Documents"*|*"/Desktop"*)
        fail "$OUTPUT est peut-être synchronisé. Choisis un dossier local avec FIL_RELEASE_DIR (défaut : ~/Builds)." ;;
esac
mkdir -p "$OUTPUT"

echo "→ Construction"
FIL_APP_DIR="$OUTPUT" "$ROOT/Tools/bundle.sh" release
APP="$OUTPUT/Fil.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT/Fil-$VERSION.zip"
SUBMISSION="$OUTPUT/Fil-$VERSION-notarisation.zip"

echo "→ Signature (runtime renforcé)"
xattr -cr "$APP"
codesign --force --options runtime --timestamp --sign "$FIL_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" || fail "le runtime renforcé n'est pas actif."

echo "→ Notarisation (peut durer quelques minutes)"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$SUBMISSION"
RESULT="$(xcrun notarytool submit "$SUBMISSION" --keychain-profile "$FIL_NOTARY_PROFILE" --wait --output-format plist)"
STATUS="$(print -r -- "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
    SUBMISSION_ID="$(print -r -- "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || true)"
    [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$FIL_NOTARY_PROFILE" >&2 || true
    fail "Apple n'a pas accepté l'envoi (état : ${STATUS:-inconnu})."
fi
rm -f "$SUBMISSION"

echo "→ Agrafage et contrôle Gatekeeper"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "→ Archive"
rm -f "$ARCHIVE"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$ARCHIVE"
echo "$ARCHIVE"
