#!/usr/bin/env bash
# Builds the Rust networking core for every Android ABI and copies the shared
# libraries into android/app/src/main/jniLibs so Gradle can package them.
#
# Requirements:
#   - rustup with the Android targets installed (see README)
#   - ANDROID_NDK pointing at an NDK r26+ (tested with 28.2.13676358)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-}}"

if [[ -z "$NDK" ]]; then
  echo "Set ANDROID_NDK (or ANDROID_NDK_HOME) to an installed NDK directory." >&2
  exit 1
fi

HOST_TAG="linux-x86_64"
case "$(uname -s)" in
  Darwin*) HOST_TAG="darwin-x86_64" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
API=24
export PATH="$TOOLCHAIN:$PATH"

build() {
  local target="$1" libdir="$2" clang="$3" clangxx="$4"
  echo "==> $target"
  CC="${clang}" CXX="${clangxx}" \
  CC_"${target//-/_}"="$clang" AR_"${target//-/_}"="$TOOLCHAIN/llvm-ar" \
    cargo build --release --target "$target" --manifest-path "$ROOT/rust_core/Cargo.toml"
  mkdir -p "$ROOT/android/app/src/main/jniLibs/$libdir"
  cp "$ROOT/rust_core/target/$target/release/librustedproxy_core.so" \
     "$ROOT/android/app/src/main/jniLibs/$libdir/librustedproxy_core.so"
}

# armv7 needs the explicit thumb flags, otherwise ring's assembly fails.
CC_armv7_linux_androideabi="$TOOLCHAIN/armv7a-linux-androideabi$API-clang"
CXX_armv7_linux_androideabi="$TOOLCHAIN/armv7a-linux-androideabi$API-clang++"
CFLAGS_armv7_linux_androideabi="-march=armv7-a -mthumb"
export CC_armv7_linux_androideabi CXX_armv7_linux_androideabi CFLAGS_armv7_linux_androideabi

build aarch64-linux-android   arm64-v8a   "$TOOLCHAIN/aarch64-linux-android$API-clang"   "$TOOLCHAIN/aarch64-linux-android$API-clang++"
build armv7-linux-androideabi armeabi-v7a "$CC_armv7_linux_androideabi"                   "$CXX_armv7_linux_androideabi"
build x86_64-linux-android    x86_64      "$TOOLCHAIN/x86_64-linux-android$API-clang"    "$TOOLCHAIN/x86_64-linux-android$API-clang++"

echo "Done. Libraries copied to android/app/src/main/jniLibs."