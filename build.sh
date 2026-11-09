#!/usr/bin/env bash
# 用 CommandLineTools 里的 swiftc 直接编译并组装 TVBox.app（无需 Xcode / SPM）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="TVBox"
APP_BUNDLE="$ROOT/build/$APP_NAME.app"
VERSION="${TVBOX_VERSION:-1.0.0}"
BUILD_NUMBER="${TVBOX_BUILD:-1}"
MIN_MACOS="${TVBOX_MIN_MACOS:-13.0}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${MIN_MACOS}"

SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

echo "==> 环境"
echo "    swiftc : $SWIFTC"
echo "    sdk    : $SDK"
echo "    target : $TARGET"

echo "==> 准备产物目录"
# 就地覆盖而不是清空整个 bundle：目录里文件多时 rm -rf 会触发宿主的安全删除限制，
# 而且增量覆盖更快。这里全程不删文件——可执行文件先写到临时路径再 mv 覆盖。
# 旧台标可能残留（catalog 不引用即无影响）。
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -type f | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "!! 没有找到任何 Swift 源文件（Sources/ 目录）" >&2
    exit 1
fi
echo "==> 编译 ${#SOURCES[@]} 个源文件"

# 先编到临时路径再 mv 覆盖：避免直接覆盖正在运行的可执行文件，也避免任何 rm。
"$SWIFTC" \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -module-name "$APP_NAME" \
    -sdk "$SDK" \
    -target "$TARGET" \
    "${SOURCES[@]}" \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME.new" \
    -framework SwiftUI \
    -framework AVKit \
    -framework AppKit
mv -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME.new" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> 写入 Info.plist"
sed -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@BUILD@/${BUILD_NUMBER}/g" \
    -e "s/@MINOS@/${MIN_MACOS}/g" \
    -e "s/@ARCH@/${ARCH}/g" \
    "$ROOT/Resources/Info.plist.in" > "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> 拷贝资源"
if [ -f "$ROOT/Resources/catalog.json" ]; then
    cp "$ROOT/Resources/catalog.json" "$APP_BUNDLE/Contents/Resources/catalog.json"
    echo "    catalog.json $(wc -c < "$ROOT/Resources/catalog.json" | tr -d ' ') 字节"
    # 台标随包分发（烘焙时下载，避免依赖 i.imgur.com 这类不可达图床）
    if [ -d "$ROOT/Resources/logos" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/logos"
        # 只增量拷贝（不 --delete），避免触发安全删除限制，也避免误删同名文件
        cp -R "$ROOT/Resources/logos/." "$APP_BUNDLE/Contents/Resources/logos/"
        echo "    logos/ $(ls "$APP_BUNDLE/Contents/Resources/logos" | wc -l | tr -d ' ') 个文件 / $(du -sh "$APP_BUNDLE/Contents/Resources/logos" | cut -f1)"
    fi
else
    echo "!! 缺少 Resources/catalog.json：" >&2
    echo "   请先运行 python3 tools/bake_catalog.py --probe" >&2
    exit 1
fi

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> 完成：$APP_BUNDLE"
echo "    可执行文件大小：$(du -h "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1)"
echo "    运行：open \"$APP_BUNDLE\""
