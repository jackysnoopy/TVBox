#!/usr/bin/env bash
# 逻辑层单测：把模型/服务（不含 UI）与 tests 下的测试源文件分别编成 CLI 并运行。
#   * test_logic.swift —— 主用例
#   * test_edge.swift  —— 边界/异常输入用例（各自独立可执行，避免两个 @main 冲突）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
TARGET="$(uname -m)-apple-macos13.0"
OUT_DIR="$ROOT/build/tests"
mkdir -p "$OUT_DIR"

SOURCES=(
    "$ROOT/Sources/Models/Channel.swift"
    "$ROOT/Sources/Services/ChannelLogic.swift"
    "$ROOT/Sources/Services/M3UParser.swift"
    "$ROOT/Sources/Services/CatalogService.swift"
    "$ROOT/Sources/Services/ChannelStore.swift"
)

echo "==> 编译测试可执行文件"

"$SWIFTC" \
    -swift-version 5 \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$TARGET" \
    "${SOURCES[@]}" \
    "$ROOT/tests/test_logic.swift" \
    -o "$OUT_DIR/tvbox_logic_tests"

"$SWIFTC" \
    -swift-version 5 \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$TARGET" \
    "${SOURCES[@]}" \
    "$ROOT/tests/test_edge.swift" \
    -o "$OUT_DIR/tvbox_edge_tests"

echo "==> 运行主用例"
"$OUT_DIR/tvbox_logic_tests"

echo ""
echo "==> 运行边界用例"
"$OUT_DIR/tvbox_edge_tests"

echo ""
echo "==> 运行烘焙脚本单测（台标挑选/扩展名/台号区间）"
PYTHON_BIN="${PYTHON_BIN:-python3}"
if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    "$PYTHON_BIN" "$ROOT/tests/test_bake.py"
else
    echo "!! 未找到 python3，跳过 tests/test_bake.py（台标挑选逻辑未验证）" >&2
    exit 1
fi
