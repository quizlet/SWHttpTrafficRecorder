#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SWHttpTrafficRecorder.h"

/*
 * Spec for the progressDelegate lifetime bug.
 *
 * progressDelegate is assign. After the delegate object is deallocated the
 * pointer is still stored, and every recording callback messages it.
 * These tests fail while that is true. They pass when the property is weak
 * (or otherwise zeroed on dealloc) so the existing nil check observes nil
 * and does not send updateRecordingProgress.
 *
 * A fix that only keeps, removes, or repeats the nil / respondsToSelector
 * check still fails: the tests read the property after dealloc and before
 * the callback, and they fail if that read is non-nil or if the freed
 * object is messaged.
 */

@interface SWRecordingProtocol : NSURLProtocol
@end

@interface SWRecordingProtocol (LifetimeTestAccess)
- (void)startLoading;
- (void)stopLoading;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
@end

/* Keeps startLoading from opening a socket after it has already reported Started. */
@interface NSURLConnection (NoLiveLoad)
@end
@implementation NSURLConnection (NoLiveLoad)
+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate
{
    (void)request;
    (void)delegate;
    return nil;
}
@end

static volatile int gDeallocs = 0;
static volatile int gCallbacks = 0;
static volatile int gLastProgress = 0;
static int gFailures = 0;

@interface ProgressProbe : NSObject <SWHttpTrafficRecordingProgressDelegate>
@end
@implementation ProgressProbe
- (void)dealloc
{
    gDeallocs++;
}
- (void)updateRecordingProgress:(SWHTTPTrafficRecordingProgressKind)currentProgress userInfo:(NSDictionary *)info
{
    (void)info;
    gCallbacks++;
    gLastProgress = (int)currentProgress;
}
@end

static void expect(BOOL condition, NSString *message)
{
    if (condition) {
        printf("ok: %s\n", message.UTF8String);
    } else {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        gFailures++;
    }
}

static void resetRecorder(void)
{
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.progressDelegate = nil;
    recorder.recordingTestBlock = nil;
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
    [recorder stopRecording];
    gDeallocs = 0;
    gCallbacks = 0;
    gLastProgress = 0;
}

static NSString *makeRecordingDirectory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSError *error = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
    expect(created, [NSString stringWithFormat:@"recording directory %@", error]);
    return dir;
}

static NSURLRequest *httpRequest(void)
{
    return [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/item?x=1"]];
}

static void installAndReleaseProbe(void)
{
    @autoreleasepool {
        ProgressProbe *probe = [[ProgressProbe alloc] init];
        [SWHttpTrafficRecorder sharedRecorder].progressDelegate = probe;
    }
}

static id delegatePointer(void)
{
    return [SWHttpTrafficRecorder sharedRecorder].progressDelegate;
}

static void expectDead(NSString *where)
{
    expect(gDeallocs == 1, [NSString stringWithFormat:@"%@: delegate deallocated (count %d)", where, gDeallocs]);
}

static void expectQuiet(NSString *where)
{
    expect(gCallbacks == 0, [NSString stringWithFormat:@"%@: freed delegate was not messaged (callbacks %d last %d)", where, gCallbacks, gLastProgress]);
    id pointer = delegatePointer();
    expect(pointer == nil, [NSString stringWithFormat:@"%@: progressDelegate is nil after dealloc, got %p", where, pointer]);
}

static SWRecordingProtocol *protocolForRequest(NSURLRequest *request)
{
    return [[SWRecordingProtocol alloc] initWithRequest:request cachedResponse:nil client:nil];
}

static void prepareResponse(SWRecordingProtocol *loader)
{
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:httpRequest().URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    [loader setValue:response forKey:@"response"];
    [loader setValue:[NSMutableData dataWithBytes:"{}" length:2] forKey:@"mutableData"];
}

static void waitForRecordingFiles(void)
{
    NSOperationQueue *queue = [[SWHttpTrafficRecorder sharedRecorder] valueForKey:@"fileCreationQueue"];
    [queue waitUntilAllOperationsAreFinished];
}

static void testPointerClearedAfterDealloc(void)
{
    resetRecorder();
    installAndReleaseProbe();
    objc_property_t property = class_getProperty([SWHttpTrafficRecorder class], "progressDelegate");
    const char *attributes = property ? property_getAttributes(property) : "(missing)";
    fprintf(stderr, "progressDelegate attributes: %s\n", attributes);
    expectDead(@"pointer");
    id pointer = delegatePointer();
    expect(pointer == nil, [NSString stringWithFormat:@"pointer: progressDelegate is nil after dealloc, got %p", pointer]);
}

static void testCanInitReceived(void)
{
    resetRecorder();
    [ [SWHttpTrafficRecorder sharedRecorder] startRecordingAtPath:makeRecordingDirectory() error:nil];
    installAndReleaseProbe();
    expectDead(@"canInit received");
    @try {
        (void)[SWRecordingProtocol canInitWithRequest:httpRequest()];
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"canInit received raised %@", exception]);
    }
    expectQuiet(@"canInit received");
}

static void testCanInitSkipped(void)
{
    resetRecorder();
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    [recorder startRecordingAtPath:makeRecordingDirectory() error:nil];
    /* Received is reported before the test block, Skipped after it.
     * Drop the delegate inside the block so Skipped is the call that
     * observes the freed object. */
    __block ProgressProbe *probe = [[ProgressProbe alloc] init];
    recorder.progressDelegate = probe;
    recorder.recordingTestBlock = ^BOOL(NSURLRequest *request) {
        (void)request;
        gCallbacks = 0;
        gLastProgress = 0;
        probe = nil;
        return NO;
    };
    @try {
        (void)[SWRecordingProtocol canInitWithRequest:httpRequest()];
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"canInit skipped raised %@", exception]);
    }
    expectDead(@"canInit skipped");
    expectQuiet(@"canInit skipped");
}

static void testStartLoading(void)
{
    resetRecorder();
    [[SWHttpTrafficRecorder sharedRecorder] startRecordingAtPath:makeRecordingDirectory() error:nil];
    installAndReleaseProbe();
    expectDead(@"startLoading");
    SWRecordingProtocol *loader = protocolForRequest(httpRequest());
    @try {
        [loader startLoading];
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"startLoading raised %@", exception]);
    }
    [loader stopLoading];
    expectQuiet(@"startLoading");
}

static void testDidFailToLoad(void)
{
    resetRecorder();
    [[SWHttpTrafficRecorder sharedRecorder] startRecordingAtPath:makeRecordingDirectory() error:nil];
    installAndReleaseProbe();
    expectDead(@"didFail");
    SWRecordingProtocol *loader = protocolForRequest(httpRequest());
    NSError *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
    @try {
        [loader connection:nil didFailWithError:error];
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"didFail raised %@", exception]);
    }
    expectQuiet(@"didFail");
}

static void finishWithFormat(SWHTTPTrafficRecordingFormat format, NSString *label, NSString *path)
{
    resetRecorder();
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.recordingFormat = format;
    NSError *error = nil;
    BOOL started = [recorder startRecordingAtPath:path error:&error];
    expect(started, [NSString stringWithFormat:@"%@ startRecording %@", label, error]);
    /* Loaded runs before the file callback. Suspend the file queue so the
     * Recorded / FailedToRecord message is the one that observes the freed
     * delegate, instead of dying on Loaded. */
    NSOperationQueue *queue = [recorder valueForKey:@"fileCreationQueue"];
    [queue setSuspended:YES];
    @autoreleasepool {
        ProgressProbe *probe = [[ProgressProbe alloc] init];
        recorder.progressDelegate = probe;
        SWRecordingProtocol *loader = protocolForRequest(httpRequest());
        prepareResponse(loader);
        [loader connectionDidFinishLoading:nil];
        gCallbacks = 0;
        gLastProgress = 0;
    }
    expectDead(label);
    [queue setSuspended:NO];
    @try {
        waitForRecordingFiles();
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"%@ raised %@", label, exception]);
    }
    expectQuiet(label);
}

static void testFinishBodyOnly(void)
{
    finishWithFormat(SWHTTPTrafficRecordingFormatBodyOnly, @"bodyOnly", makeRecordingDirectory());
}

static void testFinishMocktail(void)
{
    finishWithFormat(SWHTTPTrafficRecordingFormatMocktail, @"mocktail", makeRecordingDirectory());
}

static void testFinishHTTPMessage(void)
{
    finishWithFormat(SWHTTPTrafficRecordingFormatHTTPMessage, @"httpMessage", makeRecordingDirectory());
}

static void testFinishFailedToRecord(void)
{
    resetRecorder();
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatBodyOnly;
    NSError *error = nil;
    expect([recorder startRecordingAtPath:makeRecordingDirectory() error:&error], @"failedToRecord armed recording");
    /* Parent directory does not exist, so createFileAtPath fails and the
     * completion reports FailedToRecord. */
    [recorder setValue:@"/tmp/swhttp-missing-parent/nope" forKey:@"recordingPath"];
    NSOperationQueue *queue = [recorder valueForKey:@"fileCreationQueue"];
    [queue setSuspended:YES];
    @autoreleasepool {
        ProgressProbe *probe = [[ProgressProbe alloc] init];
        recorder.progressDelegate = probe;
        SWRecordingProtocol *loader = protocolForRequest(httpRequest());
        prepareResponse(loader);
        [loader connectionDidFinishLoading:nil];
        gCallbacks = 0;
        gLastProgress = 0;
    }
    expectDead(@"failedToRecord");
    [queue setSuspended:NO];
    @try {
        waitForRecordingFiles();
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"failedToRecord raised %@", exception]);
    }
    expectQuiet(@"failedToRecord");
}

static void testInFlightResponseAfterDealloc(void)
{
    resetRecorder();
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
    [recorder startRecordingAtPath:makeRecordingDirectory() error:nil];
    SWRecordingProtocol *loader = nil;
    @autoreleasepool {
        ProgressProbe *probe = [[ProgressProbe alloc] init];
        recorder.progressDelegate = probe;
        loader = protocolForRequest(httpRequest());
        [loader startLoading];
        gCallbacks = 0;
        gLastProgress = 0;
    }
    expectDead(@"in-flight");
    prepareResponse(loader);
    @try {
        [loader connectionDidFinishLoading:nil];
        waitForRecordingFiles();
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"in-flight raised %@", exception]);
    }
    expectQuiet(@"in-flight");
    [loader stopLoading];
}

static void testSessionConfigurationDoesNotKeepDelegate(void)
{
    resetRecorder();
    NSURLSessionConfiguration *configuration = [[NSURLSessionConfiguration alloc] init];
    configuration.protocolClasses = @[];
    NSError *error = nil;
    BOOL started = [[SWHttpTrafficRecorder sharedRecorder] startRecordingAtPath:makeRecordingDirectory() forSessionConfiguration:configuration error:&error];
    expect(started, [NSString stringWithFormat:@"session start %@", error]);
    expect([configuration.protocolClasses containsObject:[SWRecordingProtocol class]], @"session configuration registers the recorder protocol");
    installAndReleaseProbe();
    expectDead(@"session");
    @try {
        (void)[SWRecordingProtocol canInitWithRequest:httpRequest()];
    } @catch (NSException *exception) {
        expect(NO, [NSString stringWithFormat:@"session canInit raised %@", exception]);
    }
    expectQuiet(@"session");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *name = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"all";
        NSDictionary *tests = @{
            @"pointer_cleared_after_dealloc": ^{ testPointerClearedAfterDealloc(); },
            @"can_init_received": ^{ testCanInitReceived(); },
            @"can_init_skipped": ^{ testCanInitSkipped(); },
            @"start_loading": ^{ testStartLoading(); },
            @"did_fail_to_load": ^{ testDidFailToLoad(); },
            @"finish_body_only": ^{ testFinishBodyOnly(); },
            @"finish_mocktail": ^{ testFinishMocktail(); },
            @"finish_http_message": ^{ testFinishHTTPMessage(); },
            @"finish_failed_to_record": ^{ testFinishFailedToRecord(); },
            @"in_flight_response_after_dealloc": ^{ testInFlightResponseAfterDealloc(); },
            @"session_configuration": ^{ testSessionConfigurationDoesNotKeepDelegate(); },
        };
        if ([name isEqualToString:@"all"]) {
            for (NSString *key in [[tests allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                printf("== %s\n", key.UTF8String);
                void (^test)(void) = tests[key];
                test();
            }
        } else {
            void (^test)(void) = tests[name];
            expect(test != nil, [NSString stringWithFormat:@"known test %@", name]);
            if (test) {
                test();
            }
        }
        resetRecorder();
    }
    return gFailures == 0 ? 0 : 1;
}
