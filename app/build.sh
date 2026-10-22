#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=ProKlik.app
TOOLDIR="$APP/Contents/MacOS/tools"

# ---- regenerate icon if not present (needs only swift + sips + iconutil) ----
if [ ! -f AppIcon.icns ]; then
    swift make_icon.swift icon_1024.png
    rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
    for s in 16 32 64 128 256 512 1024; do
        sips -z $s $s icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    done
    for s in 16 32 128 256 512; do
        cp "AppIcon.iconset/icon_${s}x${s}.png" "AppIcon.iconset/icon_${s}x${s}@2x.png"
    done
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

# ---- bundle pkcs11-tool + its libraries (Homebrew OpenSC) ----
BREW_OPENS_C_LIB=$(brew --prefix opensc)/lib
BREW_CRYPTO=$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl)/lib
rm -rf "$TOOLDIR"
mkdir -p "$TOOLDIR"
cp /opt/homebrew/bin/pkcs11-tool "$TOOLDIR/"
cp "$BREW_OPENS_C_LIB/libopensc.13.dylib" "$TOOLDIR/"
cp "$BREW_CRYPTO/libcrypto.4.dylib" "$TOOLDIR/"
# Re-point the copies at @loader_path so the bundle is self-contained.
install_name_tool -change /opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib \
    @loader_path/libcrypto.4.dylib "$TOOLDIR/libopensc.13.dylib"
install_name_tool -change /opt/homebrew/Cellar/opensc/*/lib/libopensc.13.dylib \
    @loader_path/libopensc.13.dylib "$TOOLDIR/pkcs11-tool" 2>/dev/null || true
install_name_tool -change "$BREW_OPENS_C_LIB/libopensc.13.dylib" \
    @loader_path/libopensc.13.dylib "$TOOLDIR/pkcs11-tool"
install_name_tool -change /opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib \
    @loader_path/libcrypto.4.dylib "$TOOLDIR/pkcs11-tool"
install_name_tool -id @loader_path/libopensc.13.dylib "$TOOLDIR/libopensc.13.dylib"
install_name_tool -id @loader_path/libcrypto.4.dylib "$TOOLDIR/libcrypto.4.dylib"
# install_name_tool invalidates embedded signatures — re-sign each modified file.
codesign -s - --force "$TOOLDIR/libcrypto.4.dylib"
codesign -s - --force "$TOOLDIR/libopensc.13.dylib"
codesign -s - --force "$TOOLDIR/pkcs11-tool"

# ---- build ----
rm -rf "$APP/Contents/MacOS/ProKlik"   # fresh compile
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
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
swiftc -O -o "$APP/Contents/MacOS/ProKlik" main.swift \
    -framework AppKit -framework WebKit
swiftc -O -o "$APP/Contents/MacOS/proklik-cert" proklik-cert.swift
codesign -s - --force "$APP"

# ---- package: installs ProKlik.app into /Applications ----
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/ProKlik.app"
mkdir -p "$(pwd)/dist"
pkgbuild --root "$STAGE" \
         --install-location /Applications \
         --identifier local.proklik.nlb-helper \
         --version 1.1 \
         --no-relocate \
         dist/ProKlik-1.1.pkg 2>&1 | tail -2

# ---- also build a drag-and-drop DMG (no installer, no admin password) ----
DMGSTAGE=$(mktemp -d)
ln -s /Applications "$DMGSTAGE/Applications"
cp -R "$APP" "$DMGSTAGE/ProKlik.app"
hdiutil create -volname "ProKlik" -srcfolder "$DMGSTAGE" -ov -quiet \
    dist/ProKlik-1.1.dmg

echo "Built $APP (self-contained) + dist/ProKlik-1.1.pkg + dist/ProKlik-1.1.dmg"
echo "Other users still need SafeNet Authentication Client for macOS (token middleware)."
