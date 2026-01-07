#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTROOT="$ROOT/apple/Frameworks"
MACOS_OUTDIR="$OUTROOT/macOS"
IOS_OUTDIR="$OUTROOT/iOS"

export GOCACHE="${GOCACHE:-$ROOT/.gocache}"
mkdir -p "$GOCACHE"

mkdir -p "$MACOS_OUTDIR" "$IOS_OUTDIR"

build_macos() {
  echo "Building macOS libruncore.dylib..."
  (
    cd "$ROOT"
    go build -buildmode=c-shared -o "$MACOS_OUTDIR/libruncore.dylib" ./ffi/runcorec
  )

  echo "Patching install_name to @rpath..."
  install_name_tool -id "@rpath/libruncore.dylib" "$MACOS_OUTDIR/libruncore.dylib"

  echo "Copying header..."
  cp "$ROOT/apple/Frameworks/iOS/runcore.h" "$MACOS_OUTDIR/runcore.h" 2>/dev/null || true
  cp "$ROOT/apple/Frameworks/runcore.h" "$MACOS_OUTDIR/runcore.h" 2>/dev/null || true

  echo "OK: $MACOS_OUTDIR/libruncore.dylib"
}

build_ios_xcframework() {
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found; install Xcode / Command Line Tools." >&2
    exit 1
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found; install Xcode." >&2
    exit 1
  fi

  TMP="$IOS_OUTDIR/.tmp_ios"
  rm -rf "$TMP"
  mkdir -p "$TMP/headers" "$TMP/ios" "$TMP/sim_arm64" "$TMP/sim_amd64" "$TMP/sim" "$TMP/catalyst_arm64" "$TMP/catalyst_amd64" "$TMP/catalyst"

  echo "Building iOS (device) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=ios
    export GOARCH=arm64
    export CC="$(xcrun --sdk iphoneos --find clang)"
    export CXX="$(xcrun --sdk iphoneos --find clang++)"
    export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
    export CGO_CFLAGS="-isysroot $SDKROOT -miphoneos-version-min=16.0"
    export CGO_LDFLAGS="-isysroot $SDKROOT -miphoneos-version-min=16.0"
    go build -buildmode=c-archive -o "$TMP/ios/libruncore.a" ./ffi/runcorec
  )
  # We provide our own stable public header (runcore.h). Keep headers dir clean (no .DS_Store).
  HEADER_SRC=""
  if [ -f "$OUTROOT/macOS/runcore.h" ]; then
    HEADER_SRC="$OUTROOT/macOS/runcore.h"
  elif [ -f "$OUTROOT/iOS/runcore.h" ]; then
    HEADER_SRC="$OUTROOT/iOS/runcore.h"
  elif [ -f "$ROOT/apple/Frameworks/iOS/runcore.h" ]; then
    HEADER_SRC="$ROOT/apple/Frameworks/iOS/runcore.h"
  else
    echo "runcore.h not found" >&2
    exit 1
  fi
  cp "$HEADER_SRC" "$TMP/headers/runcore.h"
  cp "$HEADER_SRC" "$IOS_OUTDIR/runcore.h"

  echo "Building iOS (simulator arm64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=ios
    export GOARCH=arm64
    export CC="$(xcrun --sdk iphonesimulator --find clang)"
    export CXX="$(xcrun --sdk iphonesimulator --find clang++)"
    export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    export CGO_CFLAGS="-isysroot $SDKROOT -mios-simulator-version-min=16.0"
    export CGO_LDFLAGS="-isysroot $SDKROOT -mios-simulator-version-min=16.0"
    go build -buildmode=c-archive -o "$TMP/sim_arm64/libruncore.a" ./ffi/runcorec
  )
  # (intentionally no headers from libruncore.h; we use our stable C header)

  echo "Building iOS (simulator x86_64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=ios
    export GOARCH=amd64
    export CC="$(xcrun --sdk iphonesimulator --find clang)"
    export CXX="$(xcrun --sdk iphonesimulator --find clang++)"
    export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    export CGO_CFLAGS="-isysroot $SDKROOT -mios-simulator-version-min=16.0 -target x86_64-apple-ios16.0-simulator"
    export CGO_LDFLAGS="-isysroot $SDKROOT -mios-simulator-version-min=16.0 -target x86_64-apple-ios16.0-simulator"
    go build -buildmode=c-archive -o "$TMP/sim_amd64/libruncore.a" ./ffi/runcorec
  )

  echo "Creating iOS Simulator universal libruncore.a (arm64+x86_64)..."
  lipo -create     "$TMP/sim_arm64/libruncore.a"     "$TMP/sim_amd64/libruncore.a"     -output "$TMP/sim/libruncore.a"

  echo "Building Mac Catalyst (arm64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=ios
    export GOARCH=arm64
    export CC="$(xcrun --sdk macosx --find clang)"
    export CXX="$(xcrun --sdk macosx --find clang++)"
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export CGO_CFLAGS="-isysroot $SDKROOT -target arm64-apple-ios16.0-macabi"
    export CGO_LDFLAGS="-isysroot $SDKROOT -target arm64-apple-ios16.0-macabi"
    go build -buildmode=c-archive -o "$TMP/catalyst_arm64/libruncore.a" ./ffi/runcorec
  )

  echo "Building Mac Catalyst (x86_64) libruncore.a..."
  (
    cd "$ROOT"
    export CGO_ENABLED=1
    export GOOS=ios
    export GOARCH=amd64
    export CC="$(xcrun --sdk macosx --find clang)"
    export CXX="$(xcrun --sdk macosx --find clang++)"
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export CGO_CFLAGS="-isysroot $SDKROOT -target x86_64-apple-ios16.0-macabi"
    export CGO_LDFLAGS="-isysroot $SDKROOT -target x86_64-apple-ios16.0-macabi"
    go build -buildmode=c-archive -o "$TMP/catalyst_amd64/libruncore.a" ./ffi/runcorec
  )

  echo "Creating Mac Catalyst universal libruncore.a (arm64+x86_64)..."
  lipo -create \
    "$TMP/catalyst_arm64/libruncore.a" \
    "$TMP/catalyst_amd64/libruncore.a" \
    -output "$TMP/catalyst/libruncore.a"

  echo "Creating Runcore.xcframework..."
  rm -rf "$IOS_OUTDIR/Runcore.xcframework"
  xcodebuild -create-xcframework \
    -library "$TMP/ios/libruncore.a" -headers "$TMP/headers" \
    -library "$TMP/sim/libruncore.a" -headers "$TMP/headers" \
    -library "$TMP/catalyst/libruncore.a" -headers "$TMP/headers" \
    -output "$IOS_OUTDIR/Runcore.xcframework"

  echo "OK: $IOS_OUTDIR/Runcore.xcframework"
}

cmd="${1:-macos}"
case "$cmd" in
  macos)
    build_macos
    ;;
  ios)
    build_ios_xcframework
    ;;
  all)
    build_macos
    build_ios_xcframework
    ;;
  *)
    echo "Usage: $0 {macos|ios|all}" >&2
    exit 2
    ;;
esac
