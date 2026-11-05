#!/bin/bash
# Build the recorder with ARC and run the replacementDict lifetime tests.
# The tests fail while replacementDict is assign / unsafe_unretained.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="${SWHTTP_DEPS_PREFIX:-/tmp/swhttp-recorder-uaf-deps}"
OBJC_PREFIX="$DEPS/install"
BASE_SRC="$DEPS/libs-base"
BASE_LIB="$BASE_SRC/Source/obj"

if ! command -v gnustep-config >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y \
    clang ninja-build cmake g++ libstdc++-14-dev \
    gnustep-make libffi-dev libxml2-dev libicu-dev \
    libgnutls28-dev libxslt1-dev libblocksruntime-dev libgmp-dev
fi

if [[ -f /usr/share/GNUstep/Makefiles/GNUstep.sh ]]; then
  set +u
  # shellcheck disable=SC1091
  . /usr/share/GNUstep/Makefiles/GNUstep.sh
  set -u
fi

GCC_LIBDIR="$(dirname "$(clang -print-file-name=libstdc++.so)")"
export LIBRARY_PATH="${GCC_LIBDIR}${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
export LIBRARY_COMBO=ng-gnu-gnu
export RUNTIME_VERSION=gnustep-2.0

if [[ ! -e "$OBJC_PREFIX/lib/libobjc.so" || ! -e "$BASE_LIB/libgnustep-base.so.1.29.0" ]]; then
  mkdir -p "$DEPS"
  if [[ ! -d "$DEPS/libobjc2/.git" ]]; then
    git clone --depth 1 --branch v2.2.1 https://github.com/gnustep/libobjc2.git "$DEPS/libobjc2"
  fi
  # libobjc2 2.2.1's feature test defines this macro as 1 when the noexcept
  # probe fails, which does not parse. Force the specifier Clang accepts.
  sed -i 's/^add_compile_definitions(.*CXA_ALLOCATE_EXCEPTION_SPECIFIER.*$/add_compile_definitions(CXA_ALLOCATE_EXCEPTION_SPECIFIER=noexcept)/' \
    "$DEPS/libobjc2/CMakeLists.txt"
  cmake -S "$DEPS/libobjc2" -B "$DEPS/libobjc2/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$OBJC_PREFIX" \
    -DGNUSTEP_INSTALL_TYPE=NONE \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++
  ninja -C "$DEPS/libobjc2/build"
  ninja -C "$DEPS/libobjc2/build" install

  if [[ ! -d "$BASE_SRC/.git" ]]; then
    git clone --depth 1 --branch base-1_29_0 https://github.com/gnustep/libs-base.git "$BASE_SRC"
  fi
  (
    cd "$BASE_SRC"
    export CPPFLAGS="-I$OBJC_PREFIX/include"
    export LDFLAGS="-L$OBJC_PREFIX/lib -Wl,-rpath,$OBJC_PREFIX/lib -L$GCC_LIBDIR"
    ./configure --prefix="$OBJC_PREFIX"
    make -j"$(nproc)"
  )
fi

OBJCFLAGS=(
  -fobjc-runtime=gnustep-2.0
  -fblocks
  -fconstant-string-class=NSConstantString
  -fobjc-arc
  -DGNUSTEP
  -DGNUSTEP_BASE_LIBRARY=1
  -DGNUSTEP_RUNTIME=1
  -D_NONFRAGILE_ABI=1
  -D_NATIVE_OBJC_EXCEPTIONS
  -fobjc-exceptions
  -fexceptions
  -pthread
  -g
  -O0
)
INCLUDES=(
  -I"$BASE_SRC/Headers"
  -I"$OBJC_PREFIX/include"
  -I"$ROOT/SWHttpTrafficRecorder"
  -I"$ROOT/UnitTests"
)
LIBS=(
  -L"$BASE_LIB" -lgnustep-base
  -L"$OBJC_PREFIX/lib" -lobjc
  -lgmp -lgnutls -lxslt -lxml2 -lffi -lz -lrt -ldl -lpthread
  -licui18n -licuuc -licudata -lm
)
RPATH=(
  -Wl,-rpath,"$BASE_LIB"
  -Wl,-rpath,"$OBJC_PREFIX/lib"
)

BUILD="$DEPS/test-build"
mkdir -p "$BUILD"
clang "${OBJCFLAGS[@]}" "${INCLUDES[@]}" -include "$ROOT/UnitTests/ApplePlatformShims.h" \
  -c "$ROOT/SWHttpTrafficRecorder/SWHttpTrafficRecorder.m" -o "$BUILD/recorder.o"
clang "${OBJCFLAGS[@]}" "${INCLUDES[@]}" \
  -c "$ROOT/UnitTests/ApplePlatformShims.m" -o "$BUILD/shims.o"
clang "${OBJCFLAGS[@]}" "${INCLUDES[@]}" \
  -c "$ROOT/UnitTests/ReplacementDictLifetimeTests.m" -o "$BUILD/tests.o"
clang "${OBJCFLAGS[@]}" "$BUILD/recorder.o" "$BUILD/shims.o" "$BUILD/tests.o" \
  "${LIBS[@]}" "${RPATH[@]}" -o "$BUILD/replacement-dict-tests"

export LD_LIBRARY_PATH="$BASE_LIB:$OBJC_PREFIX/lib"
status=0
for test_name in owned autoreleased local; do
  if ! "$BUILD/replacement-dict-tests" "$test_name"; then
    status=1
  fi
done
exit "$status"
