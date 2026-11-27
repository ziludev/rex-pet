#!/bin/sh
# Builds a self-contained RexPet.app (ad-hoc signed, no Xcode project needed).
set -eu
cd "$(dirname "$0")"

APP="build/RexPet.app"
BIN="$APP/Contents/MacOS/RexPet"
# Host architecture by default; ARCHS="arm64 x86_64" builds a universal binary.
ARCHS="${ARCHS:-$(uname -m)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/RexPet.icns "$APP/Contents/Resources/RexPet.icns"

if [ -d Assets ]; then
  cp -R Assets "$APP/Contents/Resources/Assets"
fi

if [ -d Themes ]; then
  mkdir -p "$APP/Contents/Resources/Themes"
  for theme in Themes/*/; do
    [ -d "$theme" ] || continue
    name="$(basename "$theme")"
    mkdir -p "$APP/Contents/Resources/Themes/$name"
    for state in idle working blocked done error; do
      if [ -d "$theme/$state" ]; then
        cp -R "$theme/$state" "$APP/Contents/Resources/Themes/$name/$state"
      fi
    done
  done
fi

mkdir -p build/slices
SLICES=""
for arch in $ARCHS; do
  slice="build/slices/RexPet-$arch"
  # swiftc takes one -target, so a universal build means one compile per arch + lipo.
  swiftc -swift-version 5 -O -target "$arch-apple-macos14.0" \
    -o "$slice" Sources/*.swift
  SLICES="$SLICES $slice"
done

# shellcheck disable=SC2086
lipo -create $SLICES -output "$BIN"

# Ad-hoc signature: keeps TCC/Accessibility grants stable across rebuilds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed"

echo "built $APP ($(lipo -archs "$BIN"))"
echo "run:  open $APP"
