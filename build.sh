#!/bin/zsh
# Собирает build/BigIsland.app. Запуск: ./build.sh && open build/BigIsland.app
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/BigIsland.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BigIsland "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BigIsland</string>
    <key>CFBundleIdentifier</key><string>com.nurma.bigisland</string>
    <key>CFBundleExecutable</key><string>BigIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDocumentsFolderUsageDescription</key><string>Чтобы показывать новые скриншоты на острове.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Чтобы показывать новые скриншоты на острове.</string>
</dict>
</plist>
EOF

# Требование по bundle id, а не по хэшу: macOS не будет заново спрашивать доступ к папкам после каждой пересборки.
codesign --force --sign - --identifier com.nurma.bigisland -r='designated => identifier "com.nurma.bigisland"' "$APP"
echo "Готово: $APP"
