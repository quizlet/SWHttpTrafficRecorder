#import "support/GNUstepCompatibility.h"
#import "SWHttpTrafficRecorder.h"

#import <stdio.h>
#import <string.h>

/*
 * These tests describe the behavior stopRecording is supposed to have.
 * They fail while a prior NSURLProtocol registration, or an earlier session
 * configuration, keeps saving responses after recording has been turned off.
 *
 * UIWebView is not executed here. NSURLConnection is the loader the global
 * registration feeds, which is the same registration UIWebView used.
 */

static int gFailures = 0;
static int gHarnessFailures = 0;

@interface SWNonRecordingProtocol : NSURLProtocol
@end

@implementation SWNonRecordingProtocol
+ (BOOL) canInitWithRequest: (NSURLRequest *)request
{
  NSString *scheme = [[request URL] scheme];
  return [scheme isEqualToString: @"http"] || [scheme isEqualToString: @"https"];
}
+ (NSURLRequest *) canonicalRequestForRequest: (NSURLRequest *)request
{
  return request;
}
- (void) startLoading {}
- (void) stopLoading {}
@end

@interface RecordingSpy : NSObject <SWHttpTrafficRecordingProgressDelegate>
{
  NSMutableArray *_urls;
}
@end

@implementation RecordingSpy
- (id) init
{
  self = [super init];
  if (self != nil) {
    _urls = [[NSMutableArray alloc] init];
  }
  return self;
}
- (void) dealloc
{
  [_urls release];
  [super dealloc];
}
- (void) updateRecordingProgress: (SWHTTPTrafficRecordingProgressKind)currentProgress
                        userInfo: (NSDictionary *)info
{
  NSURLRequest *request = [info objectForKey: SWHTTPTrafficRecordingProgressRequestKey];
  NSString *url = [[request URL] absoluteString];
  if (url != nil) {
    [_urls addObject: url];
  }
}
- (BOOL) receivedURLContaining: (NSString *)needle
{
  NSUInteger i;
  for (i = 0; i < [_urls count]; i++) {
    if ([[_urls objectAtIndex: i] rangeOfString: needle].location != NSNotFound) {
      return YES;
    }
  }
  return NO;
}
- (NSString *) joinedURLs
{
  return [_urls componentsJoinedByString: @" "];
}
@end

@interface LoadClient : NSObject <NSURLProtocolClient>
{
  BOOL _done;
}
- (BOOL) isDone;
@end

@implementation LoadClient
- (BOOL) isDone { return _done; }
- (void) URLProtocol: (NSURLProtocol *)protocol
  cachedResponseIsValid: (NSCachedURLResponse *)cachedResponse {}
- (void) URLProtocol: (NSURLProtocol *)protocol
    didFailWithError: (NSError *)error
{
  _done = YES;
}
- (void) URLProtocol: (NSURLProtocol *)protocol didLoadData: (NSData *)data {}
- (void) URLProtocol: (NSURLProtocol *)protocol
  didReceiveAuthenticationChallenge: (NSURLAuthenticationChallenge *)challenge {}
- (void) URLProtocol: (NSURLProtocol *)protocol
  didReceiveResponse: (NSURLResponse *)response
  cacheStoragePolicy: (NSURLCacheStoragePolicy)policy {}
- (void) URLProtocol: (NSURLProtocol *)protocol
  wasRedirectedToRequest: (NSURLRequest *)request
  redirectResponse: (NSURLResponse *)redirectResponse {}
- (void) URLProtocolDidFinishLoading: (NSURLProtocol *)protocol
{
  _done = YES;
}
- (void) URLProtocol: (NSURLProtocol *)protocol
  didCancelAuthenticationChallenge: (NSURLAuthenticationChallenge *)challenge {}
@end

static void prepareRecorder(void)
{
  Class recorded = objc_getClass("SWRecordingProtocol");
  SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];

  if (recorded != Nil) {
    [NSURLProtocol unregisterClass: recorded];
  }
  [recorder stopRecording];
  if (recorded != Nil) {
    [NSURLProtocol unregisterClass: recorded];
  }
  recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
  recorder.recordingTestBlock = nil;
  recorder.base64TestBlock = nil;
  recorder.fileNamingBlock = nil;
  recorder.urlRegexPatternBlock = nil;
  recorder.createFileInCustomFormatBlock = nil;
  recorder.progressDelegate = nil;
  recorder.replacementDict = nil;
}

static NSString *urlForPort(int port, NSString *path)
{
  return [NSString stringWithFormat: @"http://127.0.0.1:%d%@", port, path];
}

static NSURLRequest *requestForURL(NSString *absolute)
{
  return [NSURLRequest requestWithURL: [NSURL URLWithString: absolute]
                           cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                       timeoutInterval: 5.0];
}

static BOOL directoryContains(NSString *directory, NSString *needle, NSMutableString *dump)
{
  NSFileManager *files = [NSFileManager defaultManager];
  NSArray *names = [files contentsOfDirectoryAtPath: directory error: NULL];
  NSUInteger i;
  BOOL found = NO;

  for (i = 0; i < [names count]; i++) {
    NSString *path = [directory stringByAppendingPathComponent: [names objectAtIndex: i]];
    NSData *data = [NSData dataWithContentsOfFile: path];
    NSString *text = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
    if (text != nil && [text rangeOfString: needle].location != NSNotFound) {
      found = YES;
    }
    if (dump != nil) {
      [dump appendFormat: @"%@\n%@\n", path, text != nil ? (id)text : (id)data];
    }
    [text release];
  }
  return found;
}

static BOOL waitForNeedle(NSString *directory, NSString *needle)
{
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 2.0];
  do {
    if (directoryContains(directory, needle, nil)) {
      return YES;
    }
    [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                              beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
  } while ([limit timeIntervalSinceNow] > 0.0);
  return directoryContains(directory, needle, nil);
}

static NSData *loadWithConnection(NSString *absolute, NSError **error)
{
  NSURLResponse *response = nil;
  return [NSURLConnection sendSynchronousRequest: requestForURL(absolute)
                               returningResponse: &response
                                           error: error];
}

/*
 * Session configurations are consulted from the front of protocolClasses.
 * swift-corelibs-foundation swift-5.10.1 URLProtocol.getProtocolClass iterates
 * the array forward and returns the first class whose canInitWithRequest:
 * returns true. The recorder inserts itself at index 0 for that reason.
 * This host's packaged GNUstep Base 1.29.0 was built with NSURLSession off, so
 * the test runs that selection and then the real protocol's startLoading.
 */
static void loadWithConfiguration(NSURLSessionConfiguration *configuration, NSString *absolute)
{
  NSURLRequest *request = requestForURL(absolute);
  NSArray *classes = [configuration protocolClasses];
  NSUInteger i;
  Class chosen = Nil;

  for (i = 0; i < [classes count]; i++) {
    Class protocolClass = [classes objectAtIndex: i];
    if ([protocolClass canInitWithRequest: request]) {
      chosen = protocolClass;
      break;
    }
  }
  if (chosen == Nil || chosen == [SWNonRecordingProtocol class]) {
    return;
  }

  LoadClient *client = [[LoadClient alloc] init];
  NSURLProtocol *protocol = [[chosen alloc] initWithRequest: request
                                             cachedResponse: nil
                                                     client: client];
  [protocol startLoading];
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 5.0];
  while ([client isDone] == NO && [limit timeIntervalSinceNow] > 0.0) {
    [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: limit];
  }
  [protocol release];
  [client release];
}

static int failLeaked(const char *name, NSString *directory, RecordingSpy *spy)
{
  NSMutableString *dump = [NSMutableString string];
  directoryContains(directory, @"", dump);
  fprintf(stderr,
          "FAIL %s: after stopRecording a later request was still observed\n"
          "  delegate URLs: %s\n%s\n",
          name,
          [[spy joinedURLs] UTF8String],
          [dump UTF8String]);
  gFailures++;
  return 1;
}

static int harness(const char *name, const char *detail)
{
  fprintf(stderr, "HARNESS %s: %s\n", name, detail);
  gHarnessFailures++;
  return 2;
}

static int pass(const char *name)
{
  fprintf(stderr, "PASS %s\n", name);
  return 0;
}

static int assertStoppedAndQuiet(const char *name, int port, NSString *directory,
                                 SWHttpTrafficRecorder *recorder)
{
  RecordingSpy *spy;
  NSError *error = nil;
  BOOL wrote;
  BOOL sawURL;

  if ([recorder isRecording]) {
    return harness(name, "stopRecording left isRecording YES");
  }

  spy = [[RecordingSpy alloc] init];
  recorder.progressDelegate = spy;
  loadWithConnection(urlForPort(port, @"/login"), &error);
  {
    NSURLRequest *secure = [NSURLRequest requestWithURL:
      [NSURL URLWithString: [NSString stringWithFormat: @"https://127.0.0.1:%d/login", port]]
                                            cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                        timeoutInterval: 2.0];
    NSURLResponse *ignored = nil;
    [NSURLConnection sendSynchronousRequest: secure returningResponse: &ignored error: NULL];
  }
  wrote = waitForNeedle(directory, @"body-for:/login");
  sawURL = [spy receivedURLContaining: @"/login"];
  recorder.progressDelegate = nil;
  if (wrote || sawURL) {
    int status = failLeaked(name, directory, spy);
    [spy release];
    return status;
  }
  [spy release];
  return pass(name);
}

static BOOL recordControl(const char *name, int port, NSString *directory)
{
  NSError *error = nil;
  NSData *body = loadWithConnection(urlForPort(port, @"/health"), &error);
  if (waitForNeedle(directory, @"body-for:/health")) {
    return YES;
  }
  fprintf(stderr, "HARNESS %s: control request was not recorded (body length %lu, error %s)\n",
          name,
          (unsigned long)[body length],
          error != nil ? [[[error description] description] UTF8String] : "nil");
  gHarnessFailures++;
  return NO;
}

static int testGlobalThenSession(int port, SWHTTPTrafficRecordingFormat format, const char *name)
{
  NSString *directory = [NSTemporaryDirectory()
    stringByAppendingPathComponent: [NSString stringWithFormat: @"sw-recorder-%s", name]];
  NSURLSessionConfiguration *configuration;
  NSError *error = nil;
  SWHttpTrafficRecorder *recorder;
  int status;

  prepareRecorder();
  [[NSFileManager defaultManager] removeItemAtPath: directory error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: directory
                            withIntermediateDirectories: YES
                                             attributes: nil
                                                  error: NULL];
  recorder = [SWHttpTrafficRecorder sharedRecorder];
  recorder.recordingFormat = format;
  if (format == SWHTTPTrafficRecordingFormatCustom) {
    recorder.createFileInCustomFormatBlock = ^NSString *(NSURLRequest *request,
                                                        NSURLResponse *response,
                                                        NSData *bodyData,
                                                        NSString *filePath) {
      [[NSFileManager defaultManager] createFileAtPath: filePath
                                              contents: bodyData
                                            attributes: nil];
      return nil;
    };
  }
  if ([recorder startRecordingAtPath: directory error: &error] == NO) {
    return harness(name, "startRecordingAtPath failed");
  }
  if (recordControl(name, port, directory) == NO) {
    return 2;
  }

  configuration = [[NSURLSessionConfiguration alloc] init];
  configuration.protocolClasses = [NSArray arrayWithObject: [SWNonRecordingProtocol class]];
  if ([recorder startRecordingAtPath: directory
             forSessionConfiguration: configuration
                               error: &error] == NO) {
    [configuration release];
    return harness(name, "startRecordingAtPath:forSessionConfiguration: failed");
  }
  if ([[configuration protocolClasses] count] < 2) {
    [configuration release];
    return harness(name, "session configuration was not given the recording protocol");
  }
  [recorder stopRecording];
  status = assertStoppedAndQuiet(name, port, directory, recorder);
  [configuration release];
  return status;
}

static int testSessionThenGlobal(int port)
{
  const char *name = "testSessionThenGlobalRegistrationStillWritesLogin";
  NSString *directory = [NSTemporaryDirectory()
    stringByAppendingPathComponent: @"sw-recorder-session-then-global"];
  NSURLSessionConfiguration *configuration;
  NSError *error = nil;
  SWHttpTrafficRecorder *recorder;
  int status;

  prepareRecorder();
  [[NSFileManager defaultManager] removeItemAtPath: directory error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: directory
                            withIntermediateDirectories: YES
                                             attributes: nil
                                                  error: NULL];
  recorder = [SWHttpTrafficRecorder sharedRecorder];
  configuration = [[NSURLSessionConfiguration alloc] init];
  configuration.protocolClasses = [NSArray arrayWithObject: [SWNonRecordingProtocol class]];
  if ([recorder startRecordingAtPath: directory
             forSessionConfiguration: configuration
                               error: &error] == NO) {
    [configuration release];
    return harness(name, "session start failed");
  }
  if ([recorder startRecordingAtPath: directory error: &error] == NO) {
    [configuration release];
    return harness(name, "global start failed");
  }
  if (recordControl(name, port, directory) == NO) {
    [configuration release];
    return 2;
  }
  [recorder stopRecording];
  status = assertStoppedAndQuiet(name, port, directory, recorder);
  [configuration release];
  return status;
}

static int testEarlierSessionConfigurationStillWrites(int port)
{
  const char *name = "testEarlierSessionConfigurationStillWritesLogin";
  NSString *directory = [NSTemporaryDirectory()
    stringByAppendingPathComponent: @"sw-recorder-two-sessions"];
  NSURLSessionConfiguration *first;
  NSURLSessionConfiguration *second;
  NSError *error = nil;
  SWHttpTrafficRecorder *recorder;
  RecordingSpy *spy;
  BOOL wrote;
  BOOL sawURL;

  prepareRecorder();
  [[NSFileManager defaultManager] removeItemAtPath: directory error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: directory
                            withIntermediateDirectories: YES
                                             attributes: nil
                                                  error: NULL];
  recorder = [SWHttpTrafficRecorder sharedRecorder];
  first = [[NSURLSessionConfiguration alloc] init];
  second = [[NSURLSessionConfiguration alloc] init];
  first.protocolClasses = [NSArray arrayWithObject: [SWNonRecordingProtocol class]];
  second.protocolClasses = [NSArray arrayWithObject: [SWNonRecordingProtocol class]];

  if ([recorder startRecordingAtPath: directory
             forSessionConfiguration: first
                               error: &error] == NO) {
    return harness(name, "first session start failed");
  }
  loadWithConfiguration(first, urlForPort(port, @"/health"));
  if (waitForNeedle(directory, @"body-for:/health") == NO) {
    [first release];
    [second release];
    return harness(name, "control load through the first configuration was not recorded");
  }

  if ([recorder startRecordingAtPath: directory
             forSessionConfiguration: second
                               error: &error] == NO) {
    [first release];
    [second release];
    return harness(name, "second session start failed");
  }
  [recorder stopRecording];
  if ([recorder isRecording]) {
    [first release];
    [second release];
    return harness(name, "stopRecording left isRecording YES");
  }

  spy = [[RecordingSpy alloc] init];
  recorder.progressDelegate = spy;
  loadWithConfiguration(first, urlForPort(port, @"/login"));
  wrote = waitForNeedle(directory, @"body-for:/login");
  sawURL = [spy receivedURLContaining: @"/login"];
  recorder.progressDelegate = nil;
  if (wrote || sawURL) {
    int status = failLeaked(name, directory, spy);
    [spy release];
    [first release];
    [second release];
    return status;
  }
  [spy release];
  [first release];
  [second release];
  return pass(name);
}

int main(int argc, char **argv)
{
  int port;
  int status = 0;

  if (argc != 2) {
    fprintf(stderr, "usage: %s <port>\n", argv[0]);
    return 2;
  }
  port = atoi(argv[1]);
  if (port <= 0) {
    fprintf(stderr, "invalid port\n");
    return 2;
  }

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  SWInstallCurrentRequestShim();
  status |= testGlobalThenSession(port, SWHTTPTrafficRecordingFormatMocktail,
                                  "testGlobalThenSessionMocktailStillWritesLogin");
  status |= testGlobalThenSession(port, SWHTTPTrafficRecordingFormatBodyOnly,
                                  "testGlobalThenSessionBodyOnlyStillWritesLogin");
  status |= testGlobalThenSession(port, SWHTTPTrafficRecordingFormatHTTPMessage,
                                  "testGlobalThenSessionHTTPMessageStillWritesLogin");
  status |= testGlobalThenSession(port, SWHTTPTrafficRecordingFormatCustom,
                                  "testGlobalThenSessionCustomFormatStillWritesLogin");
  status |= testSessionThenGlobal(port);
  status |= testEarlierSessionConfigurationStillWrites(port);
  [pool release];

  if (gHarnessFailures > 0) {
    return 2;
  }
  if (gFailures > 0) {
    return 1;
  }
  return status;
}
