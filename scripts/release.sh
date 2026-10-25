#!/bin/bash
# Builds a Developer ID signed, notarized and stapled dmg, holding an app
# that is notarized and stapled itself, into dist/.
#
#   scripts/release.sh                 full release
#   scripts/release.sh --no-notarize   build, sign and package only
#
# Needs a "Developer ID Application" certificate in the keychain, dmgbuild
# (python3 -m pip install --user dmgbuild) and, once:
#   xcrun notarytool store-credentials ClipApp --apple-id <id> --team-id <team>
#
# IDENTITY, NOTARY_PROFILE and OUT_DIR can be overridden from the environment.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClipApp}"
OUT_DIR="${OUT_DIR:-dist}"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

VERSION=$(sed -n 's/.*MARKETING_VERSION: *"\(.*\)".*/\1/p' project.yml)
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM: *\(.*\)/\1/p' project.yml)
APP=build/Build/Products/Release/ClipApp.app
DMG="$OUT_DIR/ClipApp-$VERSION.dmg"

python3 -m dmgbuild --help >/dev/null 2>&1 || {
  echo "dmgbuild is missing: python3 -m pip install --user dmgbuild" >&2
  exit 1
}

# Notarization rejects a build without a secure timestamp or with
# get-task-allow, which Xcode injects unless told otherwise. Command line
# settings reach the package targets too, hence the explicit team.
xcodegen generate
xcodebuild -project ClipApp.xcodeproj -scheme ClipApp -configuration Release -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build

# Sparkle's helpers are signed inside out with the same identity, hardened
# runtime and a secure timestamp, then the app over them; --deep would give
# every piece the app's entitlements. Downloader.xpc keeps its own.
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for XPC in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
  [[ -e $XPC ]] || continue
  if [[ $(basename "$XPC") == Downloader.xpc ]]; then
    sign --preserve-metadata=entitlements "$XPC"
  else
    sign "$XPC"
  fi
done
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --preserve-metadata=entitlements "$APP"
codesign --verify --strict --deep "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# The app gets its own ticket before it goes into the dmg, so it passes
# Gatekeeper offline once copied out of it, not only the dmg.
if [[ $NOTARIZE == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/ClipApp.zip"
  xcrun notarytool submit "$STAGE/ClipApp.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$STAGE/ClipApp.zip"
  xcrun stapler staple "$APP"
fi

# The install window (background, icon positions, hidden bars) is written
# into the image's .DS_Store by dmgbuild, see scripts/dmg/settings.py.
mkdir -p "$OUT_DIR"
rm -f "$DMG"
python3 -m dmgbuild -s scripts/dmg/settings.py \
  -D app="$APP" -D background=scripts/dmg/background.tiff \
  ClipApp "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

shasum -a 256 "$DMG"
