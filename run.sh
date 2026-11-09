#!/usr/bin/env bash
# 编译并启动 TVBox。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$ROOT/build.sh"
echo "==> 启动 TVBox.app"
open "$ROOT/build/TVBox.app"
