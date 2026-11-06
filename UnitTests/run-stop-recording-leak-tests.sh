#!/bin/bash
# Runs the stopRecording leak tests against SWHttpTrafficRecorder.m.
# Exit 1 means a later request was still recorded after stopRecording.
# Exit 2 means the test harness itself could not exercise the recorder.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBJC_FLAGS="$(gnustep-config --objc-flags) -fblocks -I/usr/lib/gcc/x86_64-linux-gnu/13/include -I${ROOT}/UnitTests/support/include -I${ROOT} -I${ROOT}/SWHttpTrafficRecorder -I${ROOT}/UnitTests"
LIBS="$(gnustep-config --base-libs) -L/usr/lib/gcc/x86_64-linux-gnu/13"
OUT="${TMPDIR:-/tmp}/stop-recording-leak-tests"
RECORDER_SRC="${OUT}-recorder.m"
RECORDER_HDR="${OUT}-headers/SWHttpTrafficRecorder.h"
mkdir -p "${OUT}-headers"

# The legacy runtime does not default-synthesize properties or allow ivars in a
# class extension. A temporary header declares the ivars a non-fragile compiler
# would create, and a temporary source file synthesizes them. The repository
# sources are not modified.
python3 - "${ROOT}/SWHttpTrafficRecorder/SWHttpTrafficRecorder.h" "${RECORDER_HDR}" <<'PY'
import sys
source, dest = sys.argv[1:]
text = open(source).read()
old = "@interface SWHttpTrafficRecorder : NSObject\n"
new = """@interface SWHttpTrafficRecorder : NSObject
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
if text.count(old) != 1:
    raise SystemExit("header interface not found")
open(dest, "w").write(text.replace(old, new, 1))
PY
python3 - "${ROOT}/SWHttpTrafficRecorder/SWHttpTrafficRecorder.m" "${RECORDER_SRC}" <<'PY'
import re
import sys
source, dest = sys.argv[1:]
text = open(source).read()
replacements = {
"@implementation SWHttpTrafficRecorder\n": """@implementation SWHttpTrafficRecorder
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
""",
"""@interface SWRecordingProtocol : NSURLProtocol @end
""": """@interface SWRecordingProtocol : NSURLProtocol
{
  NSURLConnection *_connection;
  NSMutableData *_mutableData;
  NSURLResponse *_response;
}
@end
""",
"@implementation SWRecordingProtocol\n": """@implementation SWRecordingProtocol
@synthesize connection = _connection;
@synthesize mutableData = _mutableData;
@synthesize response = _response;
""",
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit("could not find %r" % old)
    text = text.replace(old, new, 1)
# The legacy runtime rejects object subscript syntax. These calls are the
# methods that syntax lowers to.
text = text.replace("@YES", "@(YES)")
text = text.replace(
    "NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]",
    "[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex: 0]",
)
text = text.replace(
    "[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping[response.MIMEType]",
    "[[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping objectForKeyedSubscript: response.MIMEType]",
)
text = text.replace("headers[key]", "[headers objectForKeyedSubscript: key]")
# The file is built without ARC. This strong ivar is assigned directly, which
# ARC would retain. Keep the dictionary alive after the run loop drains.
text2, count = re.subn(
    r"_fileExtensionMapping = @\{(.*?)\};",
    r"_fileExtensionMapping = [(@{\1}) retain];",
    text,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit("could not retain fileExtensionMapping")
text = text2
open(dest, "w").write(text)
PY
SERVER_PID=""

cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

clang -I"${OUT}-headers" ${OBJC_FLAGS} -include "${ROOT}/UnitTests/support/GNUstepCompatibility.h" \
  -c "${RECORDER_SRC}" -o "${OUT}-recorder.o"
clang ${OBJC_FLAGS} \
  -c "${ROOT}/UnitTests/support/GNUstepCompatibility.m" -o "${OUT}-compat.o"
clang ${OBJC_FLAGS} \
  -c "${ROOT}/UnitTests/StopRecordingLeakTests.m" -o "${OUT}-tests.o"
clang ${OBJC_FLAGS} ${LIBS} \
  "${OUT}-recorder.o" "${OUT}-compat.o" "${OUT}-tests.o" -o "${OUT}"

rm -f "${OUT}.port"
python3 "${ROOT}/UnitTests/support/local_http_server.py" "${OUT}.port" >"${OUT}.server" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -s "${OUT}.port" ]; then
    break
  fi
  sleep 0.1
done
PORT="$(cat "${OUT}.port" 2>/dev/null || true)"
if [ -z "${PORT}" ]; then
  echo "failed to start local http server pid=${SERVER_PID}" >&2
  echo "server log:" >&2
  cat "${OUT}.server" >&2 || true
  exit 2
fi

set +e
"${OUT}" "${PORT}"
STATUS=$?
set -e
exit "${STATUS}"
