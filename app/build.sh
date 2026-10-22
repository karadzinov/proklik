#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.3
BUILD=6
APP=ProKlik.app
TOOLDIR="$APP/Contents/MacOS/tools"

# ---- regenerate icon if not present (needs only swift + sips + iconutil) ----
if [ ! -f AppIcon.icns ]; then
    swift make_icon.swift icon_1024.png
    rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
    for s in 16 32 64 128 256 512 1024; do
        sips -z "$s" "$s" icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    done
    for s in 16 32 128 256 512; do
        cp "AppIcon.iconset/icon_${s}x${s}.png" "AppIcon.iconset/icon_${s}x${s}@2x.png"
    done
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

# ---- bundle pkcs11-tool + its libraries for both Apple Silicon and Intel ----
BREW_OPENS_C_LIB=$(brew --prefix opensc)/lib
BREW_CRYPTO=$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl)/lib
rm -rf "$TOOLDIR"
mkdir -p "$TOOLDIR/arm64" "$TOOLDIR/x86_64"

# Apple Silicon runtime from the local Homebrew installation.
cp /opt/homebrew/bin/pkcs11-tool "$TOOLDIR/arm64/"
cp "$BREW_OPENS_C_LIB/libopensc.13.dylib" "$TOOLDIR/arm64/"
cp "$BREW_CRYPTO/libcrypto.4.dylib" "$TOOLDIR/arm64/"
install_name_tool -change /opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib \
    @loader_path/libcrypto.4.dylib "$TOOLDIR/arm64/libopensc.13.dylib"
install_name_tool -change /opt/homebrew/Cellar/opensc/*/lib/libopensc.13.dylib \
    @loader_path/libopensc.13.dylib "$TOOLDIR/arm64/pkcs11-tool" 2>/dev/null || true
install_name_tool -change "$BREW_OPENS_C_LIB/libopensc.13.dylib" \
    @loader_path/libopensc.13.dylib "$TOOLDIR/arm64/pkcs11-tool"
install_name_tool -change /opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib \
    @loader_path/libcrypto.4.dylib "$TOOLDIR/arm64/pkcs11-tool"
install_name_tool -id @loader_path/libopensc.13.dylib "$TOOLDIR/arm64/libopensc.13.dylib"
install_name_tool -id @loader_path/libcrypto.4.dylib "$TOOLDIR/arm64/libcrypto.4.dylib"

# Intel runtime, vendored from Homebrew bottles and patched to use @loader_path.
cp vendor/x86_64/pkcs11-tool "$TOOLDIR/x86_64/"
cp vendor/x86_64/libopensc.8.dylib "$TOOLDIR/x86_64/"
cp vendor/x86_64/libcrypto.3.dylib "$TOOLDIR/x86_64/"

# install_name_tool invalidates signatures — re-sign every bundled binary.
for arch in arm64 x86_64; do
    for file in "$TOOLDIR/$arch"/*; do
        codesign -s - --force "$file"
    done
done

# ---- universal application build ----
rm -rf "$APP/Contents/MacOS/ProKlik" "$APP/Contents/MacOS/proklik-cert"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ProKlik</string>
    <key>CFBundleIdentifier</key><string>local.proklik.nlb-helper</string>
    <key>CFBundleName</key><string>ProKlik</string>
    <key>CFBundleDisplayName</key><string>ProKlik Helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
BUILDROOT=$(mktemp -d)
swiftc -O -target arm64-apple-macos13.0 \
    -o "$BUILDROOT/ProKlik.arm64" main.swift -framework AppKit -framework WebKit
swiftc -O -target x86_64-apple-macos13.0 \
    -o "$BUILDROOT/ProKlik.x86_64" main.swift -framework AppKit -framework WebKit
lipo -create -output "$APP/Contents/MacOS/ProKlik" \
    "$BUILDROOT/ProKlik.arm64" "$BUILDROOT/ProKlik.x86_64"

swiftc -O -target arm64-apple-macos13.0 \
    -o "$BUILDROOT/proklik-cert.arm64" proklik-cert.swift
swiftc -O -target x86_64-apple-macos13.0 \
    -o "$BUILDROOT/proklik-cert.x86_64" proklik-cert.swift
lipo -create -output "$APP/Contents/MacOS/proklik-cert" \
    "$BUILDROOT/proklik-cert.arm64" "$BUILDROOT/proklik-cert.x86_64"
codesign -s - --force "$APP/Contents/MacOS/proklik-cert"
codesign -s - --force "$APP/Contents/MacOS/ProKlik"
codesign -s - --force "$APP"

# ---- package: installs the universal ProKlik.app into /Applications ----
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/ProKlik.app"
mkdir -p "$(pwd)/dist"
pkgbuild --root "$STAGE" \
         --install-location /Applications \
         --identifier local.proklik.nlb-helper \
         --version "$VERSION" \
         --no-relocate \
         "dist/ProKlik-$VERSION.pkg" 2>&1 | tail -2

# ---- also build a drag-and-drop DMG (no installer, no admin password) ----
DMGSTAGE=$(mktemp -d)
ln -s /Applications "$DMGSTAGE/Applications"
cp -R "$APP" "$DMGSTAGE/ProKlik.app"
cp support/* "$DMGSTAGE/"
chmod +x "$DMGSTAGE/Install SafeNet Authentication Client.command"
hdiutil create -volname "ProKlik" -srcfolder "$DMGSTAGE" -ov -quiet \
    "dist/ProKlik-$VERSION.dmg"

echo "Built universal $APP + dist/ProKlik-$VERSION.pkg + dist/ProKlik-$VERSION.dmg"
echo "Other users still need SafeNet Authentication Client for macOS (token middleware)."
