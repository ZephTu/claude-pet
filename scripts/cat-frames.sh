#!/bin/bash
# 编译（有改动才编）并运行 cat-frames.swift。参数原样转给它。
set -euo pipefail
cd "$(dirname "$0")/.."
bin=.build/cat-frames
if [[ ! -x $bin || scripts/cat-frames.swift -nt $bin ]]; then
  mkdir -p .build
  swiftc -O scripts/cat-frames.swift -o "$bin"
fi
exec "$bin" "$@"
