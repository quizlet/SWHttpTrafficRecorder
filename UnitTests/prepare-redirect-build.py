#!/usr/bin/env python3
"""Copy the recorder sources into a build directory and adapt them to the
legacy GNU Objective-C runtime used by GNUstep Base 1.29.

The adaptation adds the instance variables and @synthesize directives that
Apple Clang emits automatically, and rewrites three subscript expressions
and one boxed YES that this runtime rejects. The redirect callback is copied
unchanged.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)

header = (root / "SWHttpTrafficRecorder" / "SWHttpTrafficRecorder.h").read_text()
marker = "@interface SWHttpTrafficRecorder : NSObject"
ivars = """@interface SWHttpTrafficRecorder : NSObject
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
    id<SWHttpTrafficRecordingProgressDelegate> progressDelegate;
    BOOL (^recordingTestBlock)(NSURLRequest *request);
    BOOL (^base64TestBlock)(NSURLRequest *request, NSURLResponse *response);
    NSString *(^fileNamingBlock)(NSURLRequest *request, NSURLResponse *response, NSString *defaultName);
    NSString *(^urlRegexPatternBlock)(NSURLRequest *request, NSString *defaultPattern);
    NSString *(^createFileInCustomFormatBlock)(NSURLRequest *request, NSURLResponse *response, NSData *bodyData, NSString *filePath);
}
"""
if marker not in header:
    raise SystemExit("recorder interface not found")
header = header.replace(marker, ivars, 1)
(dest / "SWHttpTrafficRecorder.h").write_text(header)

source = (root / "SWHttpTrafficRecorder" / "SWHttpTrafficRecorder.m").read_text()
source = source.replace(
    "@interface SWRecordingProtocol : NSURLProtocol @end",
    """@interface SWRecordingProtocol : NSURLProtocol
{
    NSURLConnection *connection;
    NSMutableData *mutableData;
    NSURLResponse *response;
}
@end""",
    1,
)
source = source.replace(
    "@implementation SWHttpTrafficRecorder\n",
    """@implementation SWHttpTrafficRecorder
@synthesize isRecording, recordingPath, fileNo, fileCreationQueue, sessionConfig, runTimeStamp;
@synthesize recordingFormat, replacementDict, progressDelegate;
@synthesize recordingTestBlock, base64TestBlock, fileNamingBlock, urlRegexPatternBlock, createFileInCustomFormatBlock;

""",
    1,
)
source = source.replace(
    "@implementation SWRecordingProtocol\n",
    """@implementation SWRecordingProtocol
@synthesize connection, mutableData, response;

""",
    1,
)
source = source.replace(
    "NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]",
    "[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]",
    1,
)
source = source.replace(
    "[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping[response.MIMEType]",
    "[[SWHttpTrafficRecorder sharedRecorder].fileExtensionMapping objectForKey:response.MIMEType]",
    1,
)
source = source.replace(
    "headers[key]",
    "[headers objectForKey:key]",
    1,
)
source = source.replace(
    "@YES",
    "[NSNumber numberWithBool:YES]",
    1,
)
(dest / "SWHttpTrafficRecorder.m").write_text(source)

redirect = source.split(
    "- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {"
)[1].split("\n\n")[0]
original = (root / "SWHttpTrafficRecorder" / "SWHttpTrafficRecorder.m").read_text()
original_redirect = original.split(
    "- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {"
)[1].split("\n\n")[0]
if redirect != original_redirect:
    raise SystemExit("redirect callback changed during build adaptation")
