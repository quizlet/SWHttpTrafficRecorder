#!/bin/bash
# Fails while progressDelegate is an assign (dangling) property.
# Passes once that property is weak and the callbacks no longer message it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${GNUSTEP_PREFIX:-/opt/gnustep}"
if [[ ! -x "$PREFIX/bin/gnustep-config" ]]; then
  echo "gnustep-config not found at $PREFIX. Install GNUstep Base built with libobjc2, or set GNUSTEP_PREFIX." >&2
  exit 2
fi
# GNUstep.sh reads ZSH_VERSION and is not safe under `set -u`.
set +u
# shellcheck disable=SC1091
source "$PREFIX/share/GNUstep/Makefiles/GNUstep.sh"
set -u
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
OUT="${TMPDIR:-/tmp}/progress_delegate_lifetime_tests"
clang -fobjc-arc \
  $("$PREFIX/bin/gnustep-config" --objc-flags) \
  -I"$ROOT/SWHttpTrafficRecorder" \
  -include "$ROOT/UnitTests/GNUstepTestShims.h" \
  -o "$OUT" \
  "$ROOT/SWHttpTrafficRecorder/SWHttpTrafficRecorder.m" \
  "$ROOT/UnitTests/GNUstepTestShims.m" \
  "$ROOT/UnitTests/ProgressDelegateLifetimeTests.m" \
  $("$PREFIX/bin/gnustep-config" --base-libs)
status=0
tests=(
  pointer_cleared_after_dealloc
  can_init_received
  can_init_skipped
  start_loading
  did_fail_to_load
  finish_body_only
  finish_mocktail
  finish_http_message
  finish_failed_to_record
  in_flight_response_after_dealloc
  session_configuration
)
for name in "${tests[@]}"; do
  echo "---- $name ----"
  if ! "$OUT" "$name"; then
    echo "RESULT $name FAILED"
    status=1
  else
    echo "RESULT $name PASSED"
  fi
done
exit "$status"
