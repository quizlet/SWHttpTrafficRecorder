#!/bin/sh
# Compile and run the redirect tests against this tree.
# The tests fail while the recorder follows redirects itself.
set -eu
cd "$(dirname "$0")/.."
set +u
. /usr/share/GNUstep/Makefiles/GNUstep.sh
set -u

OUT="${TMPDIR:-/tmp}/swhttp-redirect-tests"
BUILD="${OUT}.src"
OBJC_INCLUDE="/usr/lib/gcc/x86_64-linux-gnu/13/include"
OBJC_LIB="/usr/lib/x86_64-linux-gnu/libobjc.so.4"
BASE_LIBS="$(gnustep-config --base-libs | sed 's/-lobjc//')"
COMMON_FLAGS="$(gnustep-config --objc-flags) -fobjc-runtime=gcc -D_GNU_SOURCE -I UnitTests/runtime-headers -I $OBJC_INCLUDE -fblocks"
python3 UnitTests/prepare-redirect-build.py . "$BUILD"
clang \
  $COMMON_FLAGS \
  -I "$BUILD" \
  -include UnitTests/RedirectFollowSupport.h \
  -c "$BUILD/SWHttpTrafficRecorder.m" \
  -o "$OUT.recorder.o"
clang \
  $COMMON_FLAGS \
  -I UnitTests \
  -c UnitTests/RedirectFollowShims.m \
  -o "$OUT.shims.o"
clang \
  $COMMON_FLAGS \
  -I SWHttpTrafficRecorder \
  -include UnitTests/RedirectFollowSupport.h \
  -c UnitTests/RedirectFollowTests.m \
  -o "$OUT.tests.o"
clang \
  "$OUT.recorder.o" "$OUT.shims.o" "$OUT.tests.o" \
  $BASE_LIBS "$OBJC_LIB" \
  -o "$OUT"
"$OUT"
