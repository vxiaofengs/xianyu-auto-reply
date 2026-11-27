#!/bin/bash
# 作者：huangxiaofeng
# 创建日期：2026-11-25
# 编译闲鱼助手.app（Apple 芯片 + Intel 通用），并打包成可分发的 zip
#
# 用法：./build.sh            产物在 build/
#       ./build.sh --install  另外安装到 /Applications 并启动

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="闲鱼助手"
EXEC="XianyuKeeper"
VERSION="1.0.0"
OUT="$DIR/build"
APP="$OUT/$NAME.app"

echo "==> 编译"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12.0" "$DIR/main.swift" "$DIR/Shared/FishShape.swift" -o "$OUT/$EXEC-$arch" \
    -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
done
lipo -create "$OUT/$EXEC-arm64" "$OUT/$EXEC-x86_64" -output "$APP/Contents/MacOS/$EXEC"
rm -f "$OUT/$EXEC-arm64" "$OUT/$EXEC-x86_64"

echo "==> 生成图标"
swiftc -O "$DIR/IconTool/main.swift" "$DIR/Shared/FishShape.swift" -o "$OUT/icontool"
"$OUT/icontool" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$OUT/icontool" "$OUT/AppIcon.iconset"

cp "$DIR/Resources/setup.sh" "$DIR/Resources/data.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.local.xianyu-keeper</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>仅供个人使用</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo "==> 打包"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME-$VERSION.zip"
echo "产物：$APP"
echo "分发：$OUT/$NAME-$VERSION.zip"

if [ "${1:-}" = "--install" ]; then
  echo "==> 安装到 /Applications"
  osascript -e "quit app \"$NAME\"" 2>/dev/null || true
  pkill -x "$EXEC" 2>/dev/null || true
  sleep 2
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$NAME.app"
  echo "已启动 /Applications/$NAME.app"
fi
