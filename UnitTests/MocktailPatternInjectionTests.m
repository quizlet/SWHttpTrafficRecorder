#import "SWHttpTrafficRecorder.h"

#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/*
 * Security expectations for the default Mocktail writer.
 *
 * The parser below follows Mocktail's registerFileAtURL: and the match
 * loop in mockResponseForURL:method: (objc-mocktail Mocktail.m). Default
 * Mocktail leaves additionalQueryParameters unset and the pasteboard
 * empty, so those branches do not change the URL string.
 */

static int gFailures = 0;
static NSString *gArgv0 = nil;

#define FAIL(fmt, ...) do { \
    fprintf(stderr, "FAIL %s: " fmt "\n", __func__, ##__VA_ARGS__); \
    gFailures++; \
} while (0)

CFAllocatorRef kCFAllocatorDefault = 0;
CFStringRef kCFHTTPVersion1_1 = 0;

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, int statusCode, CFStringRef desc, CFStringRef version) {
    (void)alloc; (void)statusCode; (void)desc; (void)version;
    return (CFHTTPMessageRef)1;
}
CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message) {
    (void)message;
    return 0;
}
void CFRelease(CFTypeRef cf) { (void)cf; }

@interface SWRecordingProtocol : NSURLProtocol
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response;
@end

@interface ScriptedConnection : NSURLConnection {
    NSURLRequest *_scriptedCurrentRequest;
}
- (void)setScriptedCurrentRequest:(NSURLRequest *)request;
@end

@implementation ScriptedConnection
- (NSURLRequest *)currentRequest {
    return _scriptedCurrentRequest;
}
- (void)setScriptedCurrentRequest:(NSURLRequest *)request {
    _scriptedCurrentRequest = request;
}
@end

@interface FixedResponse : NSHTTPURLResponse {
    NSInteger _scriptedStatus;
    NSString *_scriptedMIME;
}
- (void)setScriptedStatus:(NSInteger)status;
- (void)setScriptedMIME:(NSString *)mime;
@end

@implementation FixedResponse
- (NSInteger)statusCode { return _scriptedStatus; }
- (NSString *)MIMEType { return _scriptedMIME; }
- (void)setScriptedStatus:(NSInteger)status { _scriptedStatus = status; }
- (void)setScriptedMIME:(NSString *)mime { _scriptedMIME = mime; }
@end

/*
 * GNUstep Base 1.29's NSBlockOperation messages a block as if it were a GCC
 * block. These binaries are built with Clang blocks, which that call faults
 * on. Running the block here uses Clang's own block call. The block body is
 * still the recorder's createFileAt: implementation.
 */
@interface NSBlockOperation (ClangBlockInline)
@end

@implementation NSBlockOperation (ClangBlockInline)
+ (id)blockOperationWithBlock:(void (^)(void))block {
    if (block != nil) {
        block();
    }
    return [[NSBlockOperation alloc] init];
}
@end

@interface NSOperation (ClangBlockInline)
@end

@implementation NSOperation (ClangBlockInline)
- (void)setCompletionBlock:(void (^)(void))block {
    if (block != nil) {
        block();
    }
}
@end

@interface NSOperationQueue (ClangBlockInline)
@end

@implementation NSOperationQueue (ClangBlockInline)
- (void)addOperation:(NSOperation *)operation {
    (void)operation;
}
@end

@interface DummyProtocolClient : NSObject <NSURLProtocolClient>
@end

@implementation DummyProtocolClient
- (void)URLProtocol:(NSURLProtocol *)protocol cachedResponseIsValid:(NSCachedURLResponse *)cachedResponse {}
- (void)URLProtocol:(NSURLProtocol *)protocol didFailWithError:(NSError *)error {}
- (void)URLProtocol:(NSURLProtocol *)protocol didLoadData:(NSData *)data {}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveResponse:(NSURLResponse *)response cacheStoragePolicy:(NSURLCacheStoragePolicy)policy {}
- (void)URLProtocol:(NSURLProtocol *)protocol wasRedirectedToRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse {}
- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol {}
- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
@end

typedef struct {
    BOOL parsed;
    NSString *methodPattern;
    NSString *urlPattern;
    NSInteger status;
    NSString *body;
    NSString *raw;
} ParsedTail;

static NSString *escapeVisible(NSString *text) {
    if (!text) return @"(nil)";
    NSMutableString *out = [NSMutableString string];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = [data bytes];
    for (NSUInteger i = 0; i < [data length]; i++) {
        unsigned char c = bytes[i];
        if (c == '\n') [out appendString:@"\\n"];
        else if (c == '\r') [out appendString:@"\\r"];
        else if (c < 32 || c > 126) [out appendFormat:@"\\x%02x", c];
        else [out appendFormat:@"%c", c];
    }
    return out;
}

static ParsedTail parseMocktailFile(NSString *path) {
    ParsedTail parsed;
    memset(&parsed, 0, sizeof(parsed));
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    NSStringEncoding encoding = 0;
    NSString *contents = [NSString stringWithContentsOfURL:url usedEncoding:&encoding error:&error];
    parsed.raw = contents;
    if (!contents) {
        return parsed;
    }

    NSScanner *scanner = [NSScanner scannerWithString:contents];
    NSString *headerMatter = nil;
    [scanner scanUpToString:@"\n\n" intoString:&headerMatter];
    if (!headerMatter) {
        return parsed;
    }
    NSArray *lines = [headerMatter componentsSeparatedByString:@"\n"];
    if ([lines count] < 4) {
        return parsed;
    }

    parsed.methodPattern = [lines objectAtIndex:0];
    parsed.urlPattern = [lines objectAtIndex:1];
    parsed.status = [[lines objectAtIndex:2] integerValue];
    NSData *headerData = [headerMatter dataUsingEncoding:encoding];
    NSData *fileData = [NSData dataWithContentsOfFile:path];
    NSUInteger bodyOffset = [headerData length] + 2;
    if (fileData && [fileData length] >= bodyOffset) {
        NSData *bodyData = [fileData subdataWithRange:NSMakeRange(bodyOffset, [fileData length] - bodyOffset)];
        parsed.body = [[[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] autorelease];
    } else {
        parsed.body = @"";
    }
    parsed.parsed = YES;
    return parsed;
}

static BOOL patternMatches(NSString *methodPattern, NSString *urlPattern, NSString *method, NSURL *url) {
    NSError *error = nil;
    NSRegularExpression *methodRegex = [NSRegularExpression regularExpressionWithPattern:methodPattern
                                                                                 options:NSRegularExpressionCaseInsensitive
                                                                                   error:&error];
    NSRegularExpression *urlRegex = [NSRegularExpression regularExpressionWithPattern:urlPattern
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:&error];
    if (!methodRegex || !urlRegex || !url) {
        return NO;
    }
    NSString *absoluteURL = [url absoluteString];
    if ([urlRegex numberOfMatchesInString:absoluteURL options:0 range:NSMakeRange(0, [absoluteURL length])] == 0) {
        return NO;
    }
    return [methodRegex numberOfMatchesInString:method options:0 range:NSMakeRange(0, [method length])] > 0;
}

static NSString *recordFinalRequest(NSURLRequest *finalRequest, NSInteger status, NSString *mime, NSString *body, BOOL *wroteFile) {
    *wroteFile = NO;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        FAIL("could not create recording directory: %s", [[error description] UTF8String]);
        return nil;
    }

    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    [recorder stopRecording];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
    recorder.urlRegexPatternBlock = nil;
    recorder.base64TestBlock = nil;
    recorder.fileNamingBlock = nil;
    recorder.replacementDict = nil;
    if (![recorder startRecordingAtPath:dir error:&error]) {
        FAIL("startRecording failed: %s", [[error localizedDescription] UTF8String]);
        return nil;
    }

    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    FixedResponse *response = [[FixedResponse alloc] initWithURL:[finalRequest URL]
                                                        MIMEType:mime
                                           expectedContentLength:[bodyData length]
                                                textEncodingName:@"utf-8"];
    response.scriptedStatus = status;
    response.scriptedMIME = mime;

    DummyProtocolClient *client = [[DummyProtocolClient alloc] init];
    SWRecordingProtocol *protocol = [[SWRecordingProtocol alloc] initWithRequest:finalRequest cachedResponse:nil client:client];
    if (!protocol) {
        FAIL("SWRecordingProtocol init returned nil");
        [recorder stopRecording];
        return nil;
    }
    [protocol setValue:response forKey:@"response"];
    [protocol setValue:bodyData forKey:@"mutableData"];

    ScriptedConnection *connection = [[ScriptedConnection alloc] initWithRequest:finalRequest delegate:nil startImmediately:NO];
    connection.scriptedCurrentRequest = finalRequest;
    [protocol connectionDidFinishLoading:connection];

    NSOperationQueue *queue = [recorder valueForKey:@"fileCreationQueue"];
    [queue waitUntilAllOperationsAreFinished];
    [recorder stopRecording];

    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSString *found = nil;
    for (NSString *name in names) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir];
        if (!isDir) {
            found = full;
            break;
        }
    }
    if (found) {
        *wroteFile = YES;
    }
    return found;
}

static NSURLRequest *requestForURLString(NSString *urlString, NSString *method) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:method];
    return request;
}

static void assertSafeRecording(NSString *urlString, NSURL *literalURL, NSURL *unintendedURL, NSInteger realStatus, NSString *realBody) {
    NSURLRequest *request = requestForURLString(urlString, @"GET");
    if (!request) {
        FAIL("NSURL rejected %s", [urlString UTF8String]);
        return;
    }
    BOOL wrote = NO;
    NSString *path = recordFinalRequest(request, realStatus, @"text/plain", realBody, &wrote);
    if (!wrote) {
        FAIL("expected a .tail file for %s", [urlString UTF8String]);
        return;
    }
    ParsedTail parsed = parseMocktailFile(path);
    if (!parsed.parsed) {
        FAIL("Mocktail parser rejected file contents: %s", [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
    if (parsed.status != realStatus) {
        FAIL("status %ld, want %ld. file: %s", (long)parsed.status, (long)realStatus, [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
    if (![parsed.body isEqualToString:realBody]) {
        FAIL("body %s, want %s. file: %s", [escapeVisible(parsed.body) UTF8String], [realBody UTF8String], [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
    if ([parsed.urlPattern rangeOfString:@"\n"].location != NSNotFound ||
        [parsed.urlPattern rangeOfString:@"\r"].location != NSNotFound) {
        FAIL("pattern is not a single line: %s", [escapeVisible(parsed.urlPattern) UTF8String]);
        return;
    }
    if (!patternMatches(parsed.methodPattern, parsed.urlPattern, @"GET", literalURL)) {
        FAIL("escaped pattern %s did not match literal URL %s",
             [escapeVisible(parsed.urlPattern) UTF8String], [[literalURL absoluteString] UTF8String]);
        return;
    }
    if (patternMatches(parsed.methodPattern, parsed.urlPattern, @"GET", unintendedURL)) {
        FAIL("pattern %s matched unintended URL %s. file: %s",
             [escapeVisible(parsed.urlPattern) UTF8String], [[unintendedURL absoluteString] UTF8String],
             [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
}

static void testRedirectedWildcardPathIsLiteral(void) {
    NSString *malicious = @"http://example.test/.*";
    NSURLRequest *redirected = requestForURLString(malicious, @"GET");
    if (!redirected) {
        FAIL("NSURL rejected wildcard path");
        return;
    }
    DummyProtocolClient *client = [[DummyProtocolClient alloc] init];
    SWRecordingProtocol *protocol = [[SWRecordingProtocol alloc] initWithRequest:redirected cachedResponse:nil client:client];
    FixedResponse *redirectResponse = [[FixedResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.test/start"]
                                                                MIMEType:@"text/plain"
                                                   expectedContentLength:0
                                                        textEncodingName:nil];
    redirectResponse.scriptedStatus = 302;
    ScriptedConnection *connection = [[ScriptedConnection alloc] initWithRequest:redirected delegate:nil startImmediately:NO];
    NSURLRequest *continued = [protocol connection:connection willSendRequest:redirected redirectResponse:redirectResponse];
    if (continued != redirected) {
        FAIL("redirect was not passed through as the request the connection continues with");
        return;
    }

    BOOL wrote = NO;
    NSString *path = recordFinalRequest(continued, 201, @"text/plain", @"REAL-BODY", &wrote);
    if (!wrote) {
        FAIL("recording produced no file");
        return;
    }
    ParsedTail parsed = parseMocktailFile(path);
    if (!parsed.parsed) {
        FAIL("unparsed file %s", [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
    NSURL *literal = [NSURL URLWithString:@"http://example.test/.*"];
    NSURL *other = [NSURL URLWithString:@"http://example.test/other"];
    if (parsed.status != 201 || ![parsed.body isEqualToString:@"REAL-BODY"]) {
        FAIL("recording did not keep the real response. file: %s", [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
    if (!patternMatches(parsed.methodPattern, parsed.urlPattern, @"GET", literal) ||
        patternMatches(parsed.methodPattern, parsed.urlPattern, @"GET", other)) {
        FAIL("pattern %s is not a literal match for the recorded path. file: %s",
             [escapeVisible(parsed.urlPattern) UTF8String], [escapeVisible(parsed.raw) UTF8String]);
        return;
    }
}

static void testPercentDecodedPathIsNotAWildcard(void) {
    assertSafeRecording(@"http://example.test/%2E%2A",
                        [NSURL URLWithString:@"http://example.test/.*"],
                        [NSURL URLWithString:@"http://example.test/secret"],
                        200,
                        @"REAL-BODY");
}

static void testQueryNameMetacharactersAreLiteral(void) {
    assertSafeRecording(@"http://example.test/search?.*=1",
                        [NSURL URLWithString:@"http://example.test/search?.*=9"],
                        [NSURL URLWithString:@"http://example.test/search?zz=1"],
                        200,
                        @"REAL-BODY");
    assertSafeRecording(@"http://example.test/search?c+d=1",
                        [NSURL URLWithString:@"http://example.test/search?c+d=9"],
                        [NSURL URLWithString:@"http://example.test/search?ccd=1"],
                        200,
                        @"REAL-BODY");
}

static void testQueryPartWithoutEqualsIsLiteral(void) {
    assertSafeRecording(@"http://example.test/search?.*",
                        [NSURL URLWithString:@"http://example.test/search?.*"],
                        [NSURL URLWithString:@"http://example.test/search?safe"],
                        200,
                        @"REAL-BODY");
}

static void testNewlineAndCarriageReturnDoNotInjectFields(void) {
    NSArray *urls = [NSArray arrayWithObjects:
                     @"http://example.test/%2E%2A%0A500%0AContent-Type:%20text/plain%0A%0APWNED/leaf",
                     @"http://example.test/item%0Dname",
                     nil];
    for (NSString *urlString in urls) {
        NSURLRequest *request = requestForURLString(urlString, @"POST");
        if (!request) {
            FAIL("NSURL rejected %s", [urlString UTF8String]);
            continue;
        }
        BOOL wrote = NO;
        NSString *path = recordFinalRequest(request, 201, @"text/plain", @"REAL-BODY", &wrote);
        if (!wrote) {
            continue;
        }
        ParsedTail parsed = parseMocktailFile(path);
        if (!parsed.parsed ||
            parsed.status != 201 ||
            ![parsed.body isEqualToString:@"REAL-BODY"] ||
            [parsed.urlPattern rangeOfString:@"\r"].location != NSNotFound ||
            [parsed.urlPattern rangeOfString:@"\n"].location != NSNotFound ||
            patternMatches(parsed.methodPattern, parsed.urlPattern, @"POST", [NSURL URLWithString:@"http://example.test/secret"])) {
            FAIL("injected recording for %s file: %s", [urlString UTF8String], [escapeVisible(parsed.raw) UTF8String]);
        }
    }
}

static int matchChild(NSString *patternPath, NSString *textPath) {
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"GSRegularExpressionWorkLimit"];
    NSString *pattern = [NSString stringWithContentsOfFile:patternPath encoding:NSUTF8StringEncoding error:nil];
    NSString *text = [NSString stringWithContentsOfFile:textPath encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    if (!regex) {
        return 4;
    }
    NSUInteger matches = [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, [text length])];
    return matches > 0 ? 3 : 0;
}

static BOOL matchFinishedQuickly(NSString *pattern, NSString *text, int *childStatus) {
    NSString *dir = NSTemporaryDirectory();
    NSString *patternPath = [dir stringByAppendingPathComponent:@"mocktail-pattern.txt"];
    NSString *textPath = [dir stringByAppendingPathComponent:@"mocktail-text.txt"];
    [pattern writeToFile:patternPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [text writeToFile:textPath atomically:NO encoding:NSUTF8StringEncoding error:nil];

    pid_t pid = 0;
    char *argv[] = {
        (char *)[gArgv0 fileSystemRepresentation],
        "--match",
        (char *)[patternPath fileSystemRepresentation],
        (char *)[textPath fileSystemRepresentation],
        NULL
    };
    int spawnResult = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    if (spawnResult != 0) {
        FAIL("posix_spawn failed: %d", spawnResult);
        return NO;
    }
    int status = 0;
    BOOL finished = NO;
    for (int i = 0; i < 20; i++) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            finished = YES;
            break;
        }
        usleep(100000);
    }
    if (!finished) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        *childStatus = -1;
        return NO;
    }
    if (WIFEXITED(status)) {
        *childStatus = WEXITSTATUS(status);
    } else {
        *childStatus = -1;
    }
    return YES;
}

static void testNestedPathPatternDoesNotHang(void) {
    NSURLRequest *request = requestForURLString(@"http://example.test/(a+)+", @"GET");
    if (!request) {
        FAIL("NSURL rejected nested pattern path");
        return;
    }
    BOOL wrote = NO;
    NSString *path = recordFinalRequest(request, 200, @"text/plain", @"REAL-BODY", &wrote);
    if (!wrote) {
        FAIL("recording produced no file");
        return;
    }
    ParsedTail parsed = parseMocktailFile(path);
    if (!parsed.parsed) {
        FAIL("unparsed file %s", [escapeVisible(parsed.raw) UTF8String]);
        return;
    }

    NSMutableString *nearMiss = [NSMutableString stringWithString:@"http://example.test/"];
    for (int i = 0; i < 28; i++) {
        [nearMiss appendString:@"a"];
    }
    [nearMiss appendString:@"!"];
    int childStatus = 0;
    if (!matchFinishedQuickly(parsed.urlPattern, nearMiss, &childStatus)) {
        FAIL("matching pattern %s against a nested near-miss hung", [escapeVisible(parsed.urlPattern) UTF8String]);
        return;
    }
    if (childStatus != 0) {
        FAIL("near-miss match status %d for pattern %s", childStatus, [escapeVisible(parsed.urlPattern) UTF8String]);
        return;
    }
    NSURL *literal = [NSURL URLWithString:@"http://example.test/(a+)+"];
    if (!patternMatches(parsed.methodPattern, parsed.urlPattern, @"GET", literal)) {
        FAIL("pattern %s did not match the literal nested path", [escapeVisible(parsed.urlPattern) UTF8String]);
    }
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    gArgv0 = [[NSString alloc] initWithUTF8String:argv[0]];
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"GSRegularExpressionWorkLimit"];

    if (argc == 4 && strcmp(argv[1], "--match") == 0) {
        return matchChild([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
    }
    {
        void (*tests[])(void) = {
            testRedirectedWildcardPathIsLiteral,
            testPercentDecodedPathIsNotAWildcard,
            testQueryNameMetacharactersAreLiteral,
            testQueryPartWithoutEqualsIsLiteral,
            testNewlineAndCarriageReturnDoNotInjectFields,
            testNestedPathPatternDoesNotHang
        };
        const char *names[] = {
            "testRedirectedWildcardPathIsLiteral",
            "testPercentDecodedPathIsNotAWildcard",
            "testQueryNameMetacharactersAreLiteral",
            "testQueryPartWithoutEqualsIsLiteral",
            "testNewlineAndCarriageReturnDoNotInjectFields",
            "testNestedPathPatternDoesNotHang"
        };
        for (unsigned i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
            int before = gFailures;
            tests[i]();
            if (gFailures == before) {
                printf("PASS %s\n", names[i]);
            }
        }
    }
    if (gFailures != 0) {
        fprintf(stderr, "%d test failure(s)\n", gFailures);
        return 1;
    }
    printf("all mocktail pattern tests passed\n");
    [pool drain];
    return 0;
}
