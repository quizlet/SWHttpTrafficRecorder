#!/bin/bash
# Compile SWHttpTrafficRecorder.m and the body-limit tests against GNUstep
# Base, then run them. The tests expect the secure behavior and fail while
# response bodies are retained and written without a size ceiling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f /usr/share/GNUstep/Makefiles/GNUstep.sh ]]; then
  # shellcheck disable=SC1091
  set +u
  . /usr/share/GNUstep/Makefiles/GNUstep.sh
  set -u
fi
if ! command -v gnustep-config >/dev/null 2>&1; then
  echo "gnustep-config was not found; install libgnustep-base-dev" >&2
  exit 1
fi

OUT="${TMPDIR:-/tmp}/sw-body-limit-tests"
mkdir -p "$OUT"

OBJCFLAGS="$(gnustep-config --objc-flags)"
BASELIBS="$(gnustep-config --base-libs)"
GCC_INCLUDE="$(gcc -print-file-name=include)"
GCC_LIB="$(dirname "$(gcc -print-file-name=libobjc.so)")"

# The legacy GNU runtime used by this GNUstep package does not accept object
# subscripts and does not auto-synthesize properties. Rewrite those two forms
# into the method calls and @synthesize directives Clang emits for Apple's
# runtime. No other statement is changed.
python3 - "$ROOT" "$OUT" <<'PY'
import sys
root, out = sys.argv[1], sys.argv[2]
header = open(root + "/SWHttpTrafficRecorder/SWHttpTrafficRecorder.h", encoding="utf-8").read()
ivars = """
{
  BOOL _isRecording;
  NSString *_recordingPath;
  int _fileNo;
  NSOperationQueue *_fileCreationQueue;
  NSURLSessionConfiguration *_sessionConfig;
  NSUInteger _runTimeStamp;
  NSDictionary *_fileExtensionMapping;
  SWHTTPTrafficRecordingFormat _recordingFormat;
  NSMutableDictionary *_replacementDict;
  id<SWHttpTrafficRecordingProgressDelegate> _progressDelegate;
  BOOL (^_recordingTestBlock)(NSURLRequest *request);
  BOOL (^_base64TestBlock)(NSURLRequest *request, NSURLResponse *response);
  NSString *(^_fileNamingBlock)(NSURLRequest *request, NSURLResponse *response, NSString *defaultName);
  NSString *(^_urlRegexPatternBlock)(NSURLRequest *request, NSString *defaultPattern);
  NSString *(^_createFileInCustomFormatBlock)(NSURLRequest *request, NSURLResponse *response, NSData *bodyData, NSString *filePath);
}
"""
header = header.replace("@interface SWHttpTrafficRecorder : NSObject\n",
                        "@interface SWHttpTrafficRecorder : NSObject\n" + ivars, 1)
open(out + "/SWHttpTrafficRecorder.h", "w", encoding="utf-8").write(header)

src = open(root + "/SWHttpTrafficRecorder/SWHttpTrafficRecorder.m", encoding="utf-8").read()
src = src.replace(
    "NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]",
    "[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]",
)
src = src.replace(
    "[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping[response.MIMEType]",
    "[[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping objectForKey:response.MIMEType]",
)
src = src.replace("headers[key]", "[headers objectForKey:key]")
src = src.replace(
    "@interface SWRecordingProtocol : NSURLProtocol @end",
    "@interface SWRecordingProtocol : NSURLProtocol {\n"
    "  NSURLConnection *_connection;\n"
    "  NSMutableData *_mutableData;\n"
    "  NSURLResponse *_response;\n"
    "}\n@end",
    1,
)
recorder = """
@synthesize isRecording = _isRecording;
@synthesize recordingPath = _recordingPath;
@synthesize fileNo = _fileNo;
@synthesize fileCreationQueue = _fileCreationQueue;
@synthesize sessionConfig = _sessionConfig;
@synthesize runTimeStamp = _runTimeStamp;
@synthesize fileExtensionMapping = _fileExtensionMapping;
@synthesize recordingFormat = _recordingFormat;
@synthesize replacementDict = _replacementDict;
@synthesize progressDelegate = _progressDelegate;
@synthesize recordingTestBlock = _recordingTestBlock;
@synthesize base64TestBlock = _base64TestBlock;
@synthesize fileNamingBlock = _fileNamingBlock;
@synthesize urlRegexPatternBlock = _urlRegexPatternBlock;
@synthesize createFileInCustomFormatBlock = _createFileInCustomFormatBlock;
"""
protocol = """
@synthesize connection = _connection;
@synthesize mutableData = _mutableData;
@synthesize response = _response;
"""
src = src.replace("@implementation SWHttpTrafficRecorder\n",
                  "@implementation SWHttpTrafficRecorder\n" + recorder, 1)
src = src.replace("@implementation SWRecordingProtocol\n",
                  "@implementation SWRecordingProtocol\n" + protocol, 1)
open(out + "/SWHttpTrafficRecorder.m", "w", encoding="utf-8").write(src)
PY

# shellcheck disable=SC2086
clang -fblocks ${OBJCFLAGS} \
  -I"$ROOT/UnitTests/support" \
  -I"$GCC_INCLUDE" \
  -I"$ROOT/SWHttpTrafficRecorder" \
  -include "$ROOT/UnitTests/GNUstepTestPrefix.h" \
  -c "$OUT/SWHttpTrafficRecorder.m" \
  -o "$OUT/SWHttpTrafficRecorder.o"

# shellcheck disable=SC2086
clang -fblocks ${OBJCFLAGS} \
  -I"$ROOT/UnitTests/support" \
  -I"$GCC_INCLUDE" \
  -I"$ROOT/SWHttpTrafficRecorder" \
  -c "$ROOT/UnitTests/SWHttpTrafficRecorderBodyLimitTests.m" \
  -o "$OUT/SWHttpTrafficRecorderBodyLimitTests.o"

# shellcheck disable=SC2086
clang -fblocks ${OBJCFLAGS} \
  -L"$GCC_LIB" \
  "$OUT/SWHttpTrafficRecorder.o" \
  "$OUT/SWHttpTrafficRecorderBodyLimitTests.o" \
  ${BASELIBS} -o "$OUT/body-limit-tests"

"$OUT/body-limit-tests"
