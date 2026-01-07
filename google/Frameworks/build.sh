#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTROOT="$ROOT/google/Frameworks"

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

host_tag() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin)
      case "$arch" in
        arm64) echo "darwin-arm64" ;;
        x86_64) echo "darwin-x86_64" ;;
        *) echo "darwin-x86_64" ;;
      esac
      ;;
    linux)
      case "$arch" in
        x86_64) echo "linux-x86_64" ;;
        aarch64|arm64) echo "linux-aarch64" ;;
        *) echo "linux-x86_64" ;;
      esac
      ;;
    msys*|mingw*|cygwin*)
      echo "windows-x86_64"
      ;;
    *)
      echo "darwin-x86_64"
      ;;
  esac
}

build_android() {
  local ndk api toolchain hs

  ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [ -z "$ndk" ]; then
    echo "ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) must be set" >&2
    exit 1
  fi
  api="${ANDROID_API:-24}"

  toolchain="$ndk/toolchains/llvm/prebuilt/$(host_tag)"
  if [ ! -d "$toolchain" ]; then
    echo "NDK toolchain not found: $toolchain" >&2
    echo "Check ANDROID_NDK_HOME and host tag (darwin-arm64 vs darwin-x86_64).\n" >&2
    exit 1
  fi

  hs="$(header_src)"
  if [ -z "$hs" ]; then
    echo "runcore.h not found (expected under apple/Frameworks)" >&2
    exit 1
  fi
  cp "$hs" "$OUTROOT/runcore.h"

  local tmp out abi goarch cc cxx cflags ldflags goarm
  tmp="$OUTROOT/.tmp_android"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  out="$OUTROOT/android"
  mkdir -p "$out"

  build_one() {
    abi="$1"
    goarch="$2"
    cc="$3"
    cxx="$4"
    cflags="$5"
    ldflags="$6"
    goarm="${7:-}"

    mkdir -p "$out/$abi"
    cp "$hs" "$out/$abi/runcore.h"

    echo "Building Android $abi..."
    (
      cd "$ROOT"
      export CGO_ENABLED=1
      export GOOS=android
      export GOARCH="$goarch"
      if [ -n "$goarm" ]; then
        export GOARM="$goarm"
      fi
      export CC="$cc"
      export CXX="$cxx"
      export CGO_CFLAGS="$cflags"
      export CGO_LDFLAGS="$ldflags"
      go build -buildmode=c-archive -o "$out/$abi/libruncore.a" ./ffi/runcorec
    )
  }

  build_one "arm64-v8a" "arm64" \
    "$toolchain/bin/aarch64-linux-android${api}-clang" \
    "$toolchain/bin/aarch64-linux-android${api}-clang++" \
    "-D__ANDROID_API__=${api}" \
    "-D__ANDROID_API__=${api}"

  build_one "armeabi-v7a" "arm" \
    "$toolchain/bin/armv7a-linux-androideabi${api}-clang" \
    "$toolchain/bin/armv7a-linux-androideabi${api}-clang++" \
    "-D__ANDROID_API__=${api}" \
    "-D__ANDROID_API__=${api}" \
    "7"

  build_one "x86_64" "amd64" \
    "$toolchain/bin/x86_64-linux-android${api}-clang" \
    "$toolchain/bin/x86_64-linux-android${api}-clang++" \
    "-D__ANDROID_API__=${api}" \
    "-D__ANDROID_API__=${api}"

  build_one "x86" "386" \
    "$toolchain/bin/i686-linux-android${api}-clang" \
    "$toolchain/bin/i686-linux-android${api}-clang++" \
    "-D__ANDROID_API__=${api}" \
    "-D__ANDROID_API__=${api}"

  echo "OK: $out/*/libruncore.a"
}

cmd="${1:-android}"
case "$cmd" in
  android)
    build_android
    ;;
  *)
    echo "Usage: $0 {android}" >&2
    printf "\nRequired env: ANDROID_NDK_HOME (or ANDROID_NDK_ROOT). Optional: ANDROID_API (default 24).\n" >&2
    exit 2
    ;;
esac
