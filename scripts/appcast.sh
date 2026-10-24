#!/bin/bash
# Signs a release dmg with Sparkle's EdDSA key (from the keychain) and adds it
# to the appcast, newest first. Run it only once the dmg is uploaded to the
# GitHub release, so the feed never points at a file that is not there.
#
#   scripts/appcast.sh dist/ClipApp-0.3.0.dmg 0.3.0 5
#
# A version or build that is already in the appcast is left alone.
# APPCAST, DOWNLOAD_URL and NOTES_URL can be overridden, e.g. for a local test feed.
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 <dmg> <version> <build>" >&2; exit 64; }
DMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
VERSION=$2
BUILD=$3
cd "$(dirname "$0")/.."

APPCAST="${APPCAST:-docs/appcast.xml}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/ozturkmert1212/clip-app/releases/download/v$VERSION/ClipApp-$VERSION.dmg}"
NOTES_URL="${NOTES_URL:-https://github.com/ozturkmert1212/clip-app/releases/tag/v$VERSION}"

# Sparkle's tools come with the Swift package.
SIGN_UPDATE=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
if [[ ! -x $SIGN_UPDATE ]]; then
  xcodegen generate
  xcodebuild -resolvePackageDependencies -project ClipApp.xcodeproj -scheme ClipApp -derivedDataPath build
fi

mkdir -p "$(dirname "$APPCAST")"
if [[ ! -f $APPCAST ]]; then
  # GitHub Pages serves the folder as it is, without Jekyll.
  touch "$(dirname "$APPCAST")/.nojekyll"
  cat > "$APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClipApp</title>
    <link>https://github.com/ozturkmert1212/clip-app</link>
    <description>ClipApp updates</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

if grep -qF -e "<sparkle:version>$BUILD</sparkle:version>" -e "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
  echo "$VERSION ($BUILD) is already in $APPCAST, nothing to do."
  exit 0
fi

# Prints: sparkle:edSignature="…" length="…"
ATTRIBUTES=$("$SIGN_UPDATE" "$DMG")
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM=$(cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES_URL</sparkle:fullReleaseNotesLink>
      <enclosure url="$DOWNLOAD_URL" $ATTRIBUTES type="application/octet-stream"/>
    </item>
EOF
)

# Before the newest item, or at the end of an empty channel.
ITEM="$ITEM" python3 -I - "$APPCAST" <<'EOF'
import os, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
at = text.find("    <item>")
if at < 0:
    at = text.index("  </channel>")
open(path, "w", encoding="utf-8").write(text[:at] + os.environ["ITEM"] + "\n" + text[at:])
EOF
echo "Added $VERSION ($BUILD) to $APPCAST."
