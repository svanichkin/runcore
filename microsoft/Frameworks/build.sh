#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTROOT="$ROOT/microsoft/Frameworks"

export GOCACHE="${GOCACHE:-$ROOT/.gocache}"
mkdir -p "$GOCACHE"

mkdir -p "$OUTROOT"

header_src() {
  if [ -f "$ROOT/apple/Frameworks/iOS/runcore.h" ]; then
    echo "$ROOT/apple/Frameworks/iOS/runcore.h"
  elif [ -f "$ROOT/apple/Frameworks/runcore.h" ]; then
    echo "$ROOT/apple/Frameworks/runcore.h"
  else
    echo "";
  fi
}

build_windows_gnu() {
  if ! command -v zig >/dev/null 2>&1; then
    echo "zig not found. Install zig (https://ziglang.org/) or build on Windows with MinGW/MSVC." >&2
    exit 1
  fi

  local hs
  hs="$(header_src)"
  if [ -z "$hs" ]; then
    echo "runcore.h not found (expected under apple/Frameworks)" >&2
    exit 1
  fi

  cp "$hs" "$OUTROOT/runcore.h"

  local out
  out="$OUTROOT/windows"
  mkdir -p "$out/amd64" "$out/arm64"
  cp "$hs" "$out/amd64/runcore.h"
  cp "$hs" "$out/arm64/runcore.h"

  echo "Building Windows (amd64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=windows
    export GOARCH=amd64
    export CC="zig cc -target x86_64-windows-gnu"
    export CXX="zig c++ -target x86_64-windows-gnu"
    go build -buildmode=c-archive -o "$out/amd64/libruncore.a" ./ffi/runcorec
  )

  echo "Building Windows (arm64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=windows
    export GOARCH=arm64
    export CC="zig cc -target aarch64-windows-gnu"
    export CXX="zig c++ -target aarch64-windows-gnu"
    go build -buildmode=c-archive -o "$out/arm64/libruncore.a" ./ffi/runcorec
  )

  echo "OK: $out/*/libruncore.a"
  echo "Note: this produces Windows GNU toolchain archives; for MSVC .lib build on Windows with cl.exe." >&2
}

cmd="${1:-windows}"
case "$cmd" in
  windows)
    build_windows_gnu
    ;;
  *)
    echo "Usage: $0 {windows}" >&2
    exit 2
    ;;
esac
