#!/usr/bin/env bash
# Cross-compile OpenSSL and TDLib (libtdjson.so) for OpenHarmony arm64-v8a.
# Runs inside an ubuntu:22.04 container; the OHOS NDK is mounted at /ohos-native.
set -euo pipefail

NDK=/ohos-native
WORK=/work
OUT=$WORK/out/arm64-v8a
OPENSSL_VER=3.5.9
JOBS=${JOBS:-6}

CC=$NDK/llvm/bin/clang
CXX=$NDK/llvm/bin/clang++
TARGET=aarch64-linux-ohos
SYSROOT=$NDK/sysroot
CMAKE=$NDK/build-tools/cmake/bin/cmake
NINJA=$NDK/build-tools/cmake/bin/ninja

mkdir -p "$OUT"

# 1. OpenSSL (static, linked into libtdjson.so).
if [ ! -f "$OUT/openssl/lib/libssl.a" ]; then
  cd $WORK
  [ -d openssl-$OPENSSL_VER ] || { curl -sL https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz | tar xz; }
  cd openssl-$OPENSSL_VER
  make distclean >/dev/null 2>&1 || true
  CC="$CC --target=$TARGET --sysroot=$SYSROOT" AR=$NDK/llvm/bin/llvm-ar RANLIB=$NDK/llvm/bin/llvm-ranlib \
    ./Configure linux-aarch64 no-shared no-tests no-docs no-apps no-engine -fPIC -D__OHOS__ \
    --prefix="$OUT/openssl" --libdir=lib
  make -j"$JOBS" build_libs
  make install_dev
fi

# 2. TDLib: generate sources with a native host build, then cross-compile.
cd $WORK/td
if [ ! -f build-native/.prepared ]; then
  mkdir -p build-native && cd build-native
  cmake -DCMAKE_BUILD_TYPE=Release -DTD_GENERATE_SOURCE_FILES=ON ..
  cmake --build . --target prepare_cross_compiling -j"$JOBS"
  touch .prepared
  cd ..
fi

# OHOS musl has no pthread_{get,set}affinity_np; use TDLib's "Unsupported" path.
sed -i 's/^#if TD_LINUX || TD_FREEBSD$/#if (TD_LINUX || TD_FREEBSD) \&\& !defined(__OHOS__)/' \
  tdutils/td/utils/port/detail/ThreadPthread.cpp

mkdir -p build-ohos && cd build-ohos
$CMAKE -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DOPENSSL_ROOT_DIR="$OUT/openssl" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_INCLUDE_DIR="$OUT/openssl/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$OUT/openssl/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$OUT/openssl/lib/libssl.a" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DCMAKE_INSTALL_PREFIX="$OUT/td" \
  ..
$NINJA -j"$JOBS" tdjson
mkdir -p "$OUT/td/lib" "$OUT/td/include/td/telegram"
cp libtdjson.so* "$OUT/td/lib/" 2>/dev/null || cp $(find . -name 'libtdjson.so*' | head -1) "$OUT/td/lib/"
$NDK/llvm/bin/llvm-strip --strip-unneeded "$OUT/td/lib/libtdjson.so"
cp ../td/telegram/td_json_client.h "$OUT/td/include/td/telegram/"
cp td/telegram/tdjson_export.h "$OUT/td/include/td/telegram/"
ls -la "$OUT/td/lib"
