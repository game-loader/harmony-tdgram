#!/usr/bin/env bash
# Cross-compile libogg, libopus, opusfile (decode) and libopusenc (encode) as
# static libraries for OpenHarmony arm64-v8a. Telegram voice notes are
# Ogg/Opus, which the system player is not guaranteed to handle, so the app
# decodes and encodes them itself.
# Usage: NDK=/path/to/ohos-sdk/12/native SRC=<dir with extracted tarballs> OUT=<prefix> ./build-audio-ohos.sh
set -euo pipefail
: "${NDK:?}" "${SRC:?}" "${OUT:?}"
CMAKE=$NDK/build-tools/cmake/bin/cmake
NINJA=$NDK/build-tools/cmake/bin/ninja
JOBS=${JOBS:-8}
COMMON=(-G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/ohos.toolchain.cmake
  -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_INSTALL_PREFIX=$OUT)

build_cmake() { # dir extra-args...
  local dir=$1; shift
  rm -rf "$SRC/$dir/build-ohos"
  $CMAKE -S "$SRC/$dir" -B "$SRC/$dir/build-ohos" "${COMMON[@]}" "$@"
  $NINJA -C "$SRC/$dir/build-ohos" -j"$JOBS" install
}

build_cmake libogg-1.3.6 -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
build_cmake opus-1.5.2 -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF

# opusfile and libopusenc only ship autotools; compile their sources directly.
CC="$NDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$NDK/sysroot -fPIC -O2"
AR=$NDK/llvm/bin/llvm-ar
INC="-I$OUT/include -I$OUT/include/opus"
tmp=$(mktemp -d)

OF=$SRC/opusfile-0.12
for f in info internal opusfile stream; do
  $CC $INC -I$OF/include -DOP_DISABLE_HTTP -DOP_DISABLE_FLOAT_API=0 -c $OF/src/$f.c -o $tmp/of_$f.o
done
$AR rcs $OUT/lib/libopusfile.a $tmp/of_*.o
cp $OF/include/opusfile.h $OUT/include/opus/

OE=$SRC/libopusenc-0.3
cat > $tmp/config.h <<'EOF'
#define PACKAGE_NAME "libopusenc"
#define PACKAGE_VERSION "0.3"
#define OUTSIDE_SPEEX 1
#define RANDOM_PREFIX libopusenc
#define FLOATING_POINT 1
EOF
for f in ogg_packer opus_header opusenc picture resample unicode_support; do
  $CC $INC -I$OE/include -I$tmp -DHAVE_CONFIG_H -c $OE/src/$f.c -o $tmp/oe_$f.o
done
$AR rcs $OUT/lib/libopusenc.a $tmp/oe_*.o
cp $OE/include/opusenc.h $OUT/include/opus/
rm -rf "$tmp"
ls -la $OUT/lib/*.a
