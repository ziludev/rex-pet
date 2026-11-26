#!/bin/sh
# Builds a universal, ad-hoc signed RexPet.app and zips it the way Finder would,
# so the download keeps its permissions and icon.
set -eu
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NAME="RexPet-$VERSION"
ZIP="build/$NAME.zip"

ARCHS="arm64 x86_64" ./build.sh
./build/RexPet.app/Contents/MacOS/RexPet --selftest

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/RexPet.app "$ZIP"
shasum -a 256 "$ZIP"

echo "release artifact: $ZIP"
echo "next: git tag v$VERSION && git push origin v$VERSION && gh release create v$VERSION $ZIP"
