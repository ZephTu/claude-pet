#!/bin/bash
# 编译（有改动才编）并运行 skin-frames.swift。参数原样转给它：
#   scripts/skin-frames.sh <皮肤> [videoDir] [sheetDir] [outDir]
set -euo pipefail
cd "$(dirname "$0")/.."
bin=.build/skin-frames
if [[ ! -x $bin || scripts/skin-frames.swift -nt $bin ]]; then
  mkdir -p .build
  swiftc -O scripts/skin-frames.swift -o "$bin"
fi
exec "$bin" "$@"
