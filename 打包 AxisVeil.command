#!/bin/zsh

set -euo pipefail

APP_NAME="AxisVeil"
APP_VERSION="1.7"
BUILD_NUMBER="8"
BUNDLE_IDENTIFIER="io.axisveil.mac"

SCRIPT_DIR="${0:A:h}"
PROJECT_PATH="$SCRIPT_DIR/AxisVeil.xcodeproj"
SOURCE_DIR="$SCRIPT_DIR/AxisVeil"
OUTPUT_DIR="$SCRIPT_DIR/dist"
OUTPUT_APP="$OUTPUT_DIR/$APP_NAME.app"
OUTPUT_ZIP="$OUTPUT_DIR/$APP_NAME-$APP_VERSION.zip"
PACKAGE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/axisveil-package.XXXXXX")"

finish() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "${PACKAGE_TMP_DIR:-}" && -d "$PACKAGE_TMP_DIR" ]]; then
        rm -rf -- "$PACKAGE_TMP_DIR"
    fi

    if (( exit_code != 0 )); then
        print ""
        print "❌ 打包失败，请查看上方错误信息。"
    fi
    if [[ -t 0 ]]; then
        print ""
        read -k 1 "?按任意键关闭窗口…"
        print ""
    fi
    exit "$exit_code"
}
trap finish EXIT

mkdir -p "$OUTPUT_DIR"

XCODE_DEVELOPER_DIR=""
ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$ACTIVE_DEVELOPER_DIR" == *"Xcode.app/Contents/Developer"* ]]; then
    XCODE_DEVELOPER_DIR="$ACTIVE_DEVELOPER_DIR"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SOURCE_APP=""
if [[ -n "$XCODE_DEVELOPER_DIR" ]] \
    && DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild -version >/dev/null 2>&1; then
    print "🔨 正在使用 Xcode 构建 $APP_NAME Release…"
    DERIVED_DATA_DIR="$PACKAGE_TMP_DIR/DerivedData"
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        build
    SOURCE_APP="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
else
    print "🔨 未检测到完整 Xcode，正在使用 Swift 编译器构建 $APP_NAME…"
    SOURCE_APP="$PACKAGE_TMP_DIR/$APP_NAME.app"
    CONTENTS_DIR="$SOURCE_APP/Contents"
    EXECUTABLE_DIR="$CONTENTS_DIR/MacOS"
    mkdir -p "$EXECUTABLE_DIR"

    PACKAGE_ARCH="$(uname -m)"
    xcrun swiftc \
        -O \
        -whole-module-optimization \
        -target "$PACKAGE_ARCH-apple-macosx14.0" \
        "$SOURCE_DIR"/*.swift \
        -o "$EXECUTABLE_DIR/$APP_NAME" \
        -framework AppKit \
        -framework QuartzCore \
        -framework CoreMotion \
        -framework AVFoundation

    cp "$SOURCE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleExecutable -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleName -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleDisplayName -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
    plutil -replace LSMinimumSystemVersion -string "14.0" "$CONTENTS_DIR/Info.plist"
    codesign --force --deep --sign - "$SOURCE_APP"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "找不到构建产物：$SOURCE_APP"
    exit 1
fi

print "📦 正在整理发布文件…"
if [[ -e "$OUTPUT_APP" ]]; then
    rm -rf -- "$OUTPUT_APP"
fi
rm -f -- "$OUTPUT_ZIP"
ditto "$SOURCE_APP" "$OUTPUT_APP"
codesign --verify --deep --strict "$OUTPUT_APP"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_APP" "$OUTPUT_ZIP"

print ""
print "✅ AxisVeil 打包完成"
print "   App：$OUTPUT_APP"
print "   Zip：$OUTPUT_ZIP"

if [[ "${AXISVEIL_NO_REVEAL:-0}" != "1" ]]; then
    open -R "$OUTPUT_APP"
fi
