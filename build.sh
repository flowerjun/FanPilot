#!/bin/zsh
# Builds build/FanPilot.app (with the daemon embedded) and build/FanPilot.dmg
set -euo pipefail
cd "${0:A:h}"
rm -rf build && mkdir -p build
# Universal: Apple Silicon and Intel Macs that run macOS 14+.
ARCHS=(arm64 x86_64)

# swiftc builds one architecture at a time; lipo joins them.
universal() {   # universal <output> <extra swiftc flags…> -- <sources…>
  local out=$1; shift
  local parts=()
  for a in $ARCHS; do
    swiftc -O -target $a-apple-macos14 -o $out.$a "$@"
    parts+=$out.$a
  done
  lipo -create $parts -output $out && rm -f $parts
}

universal build/fanpilotd Sources/Shared/*.swift Sources/Daemon/main.swift

APP=build/FanPilot.app
mkdir -p $APP/Contents/MacOS
universal $APP/Contents/MacOS/FanPilot -parse-as-library Sources/Shared/*.swift Sources/App/*.swift
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.flowerjun.fanpilot</string>
  <key>CFBundleName</key><string>FanPilot</string>
  <key>CFBundleExecutable</key><string>FanPilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
# App icon
ICON=build/icon
mkdir -p $ICON/AppIcon.iconset $APP/Contents/Resources
swift tools/make_icon.swift $ICON/icon.png
for sz in 16 32 128 256 512; do
  sips -z $sz $sz $ICON/icon.png --out $ICON/AppIcon.iconset/icon_${sz}x${sz}.png >/dev/null
  sips -z $((sz*2)) $((sz*2)) $ICON/icon.png --out $ICON/AppIcon.iconset/icon_${sz}x${sz}@2x.png >/dev/null
done
iconutil -c icns $ICON/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns

# The app installs the daemon itself, so ship it and the admin script inside the bundle.
codesign --force -s - build/fanpilotd
cp build/fanpilotd $APP/Contents/Resources/fanpilotd
cp scripts/fanpilot-admin.sh $APP/Contents/Resources/fanpilot-admin.sh
chmod 755 $APP/Contents/Resources/fanpilot-admin.sh
codesign --force -s - $APP

# Drag-to-Applications disk image
STAGE=build/dmg
mkdir -p $STAGE
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -quiet -volname FanPilot -srcfolder $STAGE -fs HFS+ -format UDZO -ov build/FanPilot.dmg
rm -rf $STAGE
echo "built: $APP, build/FanPilot.dmg"
