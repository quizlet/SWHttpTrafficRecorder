#!/bin/sh
# Runs the Mocktail pattern tests against this tree.
# The tests fail while the unescaped-pattern vulnerability is present.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OBJC_INC="$(gcc -print-file-name=include)"
OUT="${TMPDIR:-/tmp}/mocktail-pattern-tests"
mkdir -p "$OUT"

# GCC libobjc, which GNUstep Base 1.29 links, has no property autosynthesis
# and no object subscripting. The copies below add ivars and @synthesize, and
# rewrite three subscripts that are not in the Mocktail writer. The pattern
# builder and the .tail writer are not modified.
python3 - "$ROOT" "$OUT" << 'PY'
import sys
root, out = sys.argv[1], sys.argv[2]
header = open(root + "/SWHttpTrafficRecorder/SWHttpTrafficRecorder.h").read()
source = open(root + "/SWHttpTrafficRecorder/SWHttpTrafficRecorder.m").read()
header = header.replace(
"""@interface SWHttpTrafficRecorder : NSObject
""",
"""@interface SWHttpTrafficRecorder : NSObject
{
    BOOL isRecording;
    NSString *recordingPath;
    int fileNo;
    NSOperationQueue *fileCreationQueue;
    NSURLSessionConfiguration *sessionConfig;
    NSUInteger runTimeStamp;
    NSDictionary *_fileExtensionMapping;
    SWHTTPTrafficRecordingFormat recordingFormat;
    NSMutableDictionary *replacementDict;
    id progressDelegate;
    BOOL (^recordingTestBlock)(NSURLRequest *request);
    BOOL (^base64TestBlock)(NSURLRequest *request, NSURLResponse *response);
    NSString *(^fileNamingBlock)(NSURLRequest *request, NSURLResponse *response, NSString *defaultName);
    NSString *(^urlRegexPatternBlock)(NSURLRequest *request, NSString *defaultPattern);
    NSString *(^createFileInCustomFormatBlock)(NSURLRequest *request, NSURLResponse *response, NSData *bodyData, NSString *filePath);
}
""",
1)
source = source.replace(
"@interface SWRecordingProtocol : NSURLProtocol @end",
"""@interface SWRecordingProtocol : NSURLProtocol
{
    NSURLConnection *connection;
    NSMutableData *mutableData;
    NSURLResponse *response;
}
@end""",
1)
source = source.replace(
"""@implementation SWHttpTrafficRecorder
""",
"""@implementation SWHttpTrafficRecorder
@synthesize isRecording, recordingPath, fileNo, fileCreationQueue, sessionConfig, runTimeStamp;
@synthesize fileExtensionMapping = _fileExtensionMapping;
@synthesize recordingFormat, replacementDict, progressDelegate, recordingTestBlock, base64TestBlock;
@synthesize fileNamingBlock, urlRegexPatternBlock, createFileInCustomFormatBlock;
""",
1)
source = source.replace(
"""@implementation SWRecordingProtocol
""",
"""@implementation SWRecordingProtocol
@synthesize connection, mutableData, response;
""",
1)
source = source.replace(
    "NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]",
    "[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]",
)
source = source.replace(
    "[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping[response.MIMEType]",
    "[[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping objectForKey:response.MIMEType]",
)
source = source.replace("headers[key]", "[headers objectForKey:key]")
open(out + "/SWHttpTrafficRecorder.h", "w").write(header)
open(out + "/SWHttpTrafficRecorder.m", "w").write(source)
PY

CFLAGS="$(gnustep-config --objc-flags) -fblocks -fobjc-runtime=gcc -I${OBJC_INC} -I${ROOT}/UnitTests/support"
LIBS="$(gnustep-config --base-libs) -L${OBJC_INC%/include} -lBlocksRuntime"

clang ${CFLAGS} -I"${OUT}" -include "${ROOT}/UnitTests/support/gnustep_prefix.h" \
  -c "${OUT}/SWHttpTrafficRecorder.m" -o "${OUT}/recorder.o"
clang ${CFLAGS} -I"${ROOT}/SWHttpTrafficRecorder" -include "${ROOT}/UnitTests/support/gnustep_prefix.h" \
  -c "${ROOT}/UnitTests/MocktailPatternInjectionTests.m" -o "${OUT}/tests.o"
clang ${CFLAGS} ${LIBS} -o "${OUT}/mocktail-pattern-tests" "${OUT}/recorder.o" "${OUT}/tests.o"
"${OUT}/mocktail-pattern-tests"
