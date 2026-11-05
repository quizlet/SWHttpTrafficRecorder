/*
 * Spec for the unbounded-response-body recording bug.
 *
 * A response body larger than kSpecMaximumRecordedBodyBytes must not be
 * retained by the recording protocol, queued on the file-creation queue, or
 * written to disk. Crossing the ceiling must fail the recording and drop the
 * partial buffer. Bytes already handed to the URL client stay delivered, so
 * the application can keep streaming. A 128-byte body must still be recorded.
 * A ceiling lower than kSpecMaximumRecordedBodyBytes (and at least 128) is
 * acceptable.
 *
 * These tests fail while SWRecordingProtocol appends every chunk and queues
 * another full copy for the file write.
 *
 * Not covered here:
 * - TLS. https takes the same canInitWithRequest: branch as http and the same
 *   -connection:didReceiveData: path.
 * - NSURLSession task delivery. GNUstep Base 1.29 keeps the last protocol
 *   class whose canInitWithRequest: returns YES (NSURLSession.m), while
 *   -startRecordingAtPath:forSessionConfiguration:error: inserts
 *   SWRecordingProtocol at index 0. The session therefore does not instantiate
 *   the recorder on this runtime. The methods under test are the same ones
 *   exercised through NSURLConnection, which is the global registration path
 *   used by -startRecording.
 * - Gzip expansion inside the URL loader. This host's GNUstep Base compiles
 *   that path out (USE_ZLIB 0 in NSURLProtocol.m). The tests instead deliver
 *   the already-decoded body, including a body larger than the Content-Length
 *   the response advertises.
 */
#import <Foundation/Foundation.h>
@class NSURLSessionConfiguration;
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <pthread.h>
#import <poll.h>
#import <errno.h>
#import <signal.h>
#import <sys/socket.h>
#import <netinet/in.h>

#import "SWHttpTrafficRecorder.h"

static const NSUInteger kSpecMaximumRecordedBodyBytes = 64 * 1024;
static const NSUInteger kSmallBodyBytes = 128;
static const NSUInteger kOversizedBodyBytes = 256 * 1024;

static const char *gTestName = "";
static BOOL gTestFailed = NO;
static int gFailures = 0;
static int gTests = 0;

static volatile int gGrewPastCeiling = 0;
static volatile int gAppendCalls = 0;
static volatile NSUInteger gMaxBuffered = 0;
static volatile NSUInteger gFinalBuffered = 0;
static volatile int gCreateFileCalled = 0;
static volatile NSUInteger gQueuedLength = 0;
static volatile int gQueuedOversized = 0;
static volatile int gFileWriteCalled = 0;
static volatile NSUInteger gFileWriteLength = 0;
static volatile int gFileWriteOversized = 0;
static volatile int gSawRecorded = 0;
static volatile int gSawFailed = 0;
static volatile int gProgressOversized = 0;
static volatile NSUInteger gMaxProgressBody = 0;
static volatile NSUInteger gForwardedBytes = 0;
static volatile int gWatch = 0;
static NSUInteger gCustomBodyLength = 0;
static int gCustomCalled = 0;
static id gActiveProtocol = nil;

static NSMutableDictionary *gConnectionRequests = nil;
static id gProbe = nil;

static void (*gOrigAppend)(id, SEL, id) = NULL;
static void (*gOrigDidReceive)(id, SEL, id, id) = NULL;
static void (*gOrigDidResponse)(id, SEL, id, id) = NULL;
static void (*gOrigFinish)(id, SEL, id) = NULL;
static void (*gOrigCreateFile)(id, SEL, id, id, id) = NULL;
static BOOL (*gOrigCreateAtPath)(id, SEL, id, id, id) = NULL;
static id (*gOrigConnect)(id, SEL, id, id) = NULL;

#define EXPECT(cond, fmt, ...)                                                 \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "  FAIL %s: " fmt "\n", gTestName, ##__VA_ARGS__);      \
      gTestFailed = YES;                                                       \
    }                                                                          \
  } while (0)

@interface SWRecordingProtocol : NSURLProtocol
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (void)createFileAt:(NSString *)filePath
           usingData:(NSData *)data
   completionHandler:(void (^)(BOOL created))completionHandler;
@end

@interface SWFakeConnection : NSObject {
  NSURLRequest *_currentRequest;
}
@property(nonatomic, retain) NSURLRequest *currentRequest;
@end
@implementation SWFakeConnection
@synthesize currentRequest = _currentRequest;
@end

@interface SWProbe : NSObject <NSURLProtocolClient, SWHttpTrafficRecordingProgressDelegate>
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response;
@end

static volatile int gLoadFinished = 0;

@implementation SWProbe

- (void)URLProtocol:(NSURLProtocol *)protocol
    didLoadData:(NSData *)data
{
  gForwardedBytes += [data length];
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    didFailWithError:(NSError *)error
{
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    didReceiveResponse:(NSURLResponse *)response
    cacheStoragePolicy:(NSURLCacheStoragePolicy)policy
{
  (void)protocol;
  (void)response;
  (void)policy;
}

- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol
{
  (void)protocol;
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    wasRedirectedToRequest:(NSURLRequest *)request
    redirectResponse:(NSURLResponse *)redirectResponse
{
  (void)protocol;
  (void)request;
  (void)redirectResponse;
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
  (void)protocol;
  (void)challenge;
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
  (void)protocol;
  (void)challenge;
}

- (void)URLProtocol:(NSURLProtocol *)protocol
    cachedResponseIsValid:(NSCachedURLResponse *)cachedResponse
{
  (void)protocol;
  (void)cachedResponse;
}

- (void)updateRecordingProgress:(SWHTTPTrafficRecordingProgressKind)currentProgress
                       userInfo:(NSDictionary *)info
{
  NSData *body = [info objectForKey:SWHTTPTrafficRecordingProgressBodyDataKey];
  NSUInteger length = [body length];
  if (length > gMaxProgressBody) {
    gMaxProgressBody = length;
  }
  if (length > kSpecMaximumRecordedBodyBytes) {
    gProgressOversized = 1;
  }
  if (currentProgress == SWHTTPTrafficRecordingProgressRecorded) {
    gSawRecorded = 1;
  }
  if (currentProgress == SWHTTPTrafficRecordingProgressFailedToRecord ||
      currentProgress == SWHTTPTrafficRecordingProgressFailedToLoad) {
    gSawFailed = 1;
  }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
  gForwardedBytes += [data length];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
  (void)connection;
  (void)response;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
  (void)connection;
  gLoadFinished = 1;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
  (void)connection;
  (void)error;
  gLoadFinished = 1;
}

- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response
{
  (void)connection;
  (void)response;
  return request;
}

@end

@implementation NSURLConnection (SWBodyLimitCurrentRequest)
- (NSURLRequest *)currentRequest
{
  return [gConnectionRequests objectForKey:[NSValue valueWithPointer:(void *)self]];
}
@end

static void swz_append(id self, SEL _cmd, id data)
{
  gAppendCalls++;
  gOrigAppend(self, _cmd, data);
  NSMutableData *buffer = [gActiveProtocol valueForKey:@"mutableData"];
  if (gWatch && buffer == self && [buffer length] > kSpecMaximumRecordedBodyBytes) {
    gGrewPastCeiling = 1;
  }
}

static void swz_didReceive(id self, SEL _cmd,
                           id connection,
                           id data)
{
  gActiveProtocol = self;
  gOrigDidReceive(self, _cmd, connection, data);
  NSData *buffer = [self valueForKey:@"mutableData"];
  NSUInteger length = [buffer length];
  if (length > gMaxBuffered) {
    gMaxBuffered = length;
  }
  gActiveProtocol = nil;
}

static void swz_finish(id self, SEL _cmd, id connection)
{
  gOrigFinish(self, _cmd, connection);
  NSData *buffer = [self valueForKey:@"mutableData"];
  gFinalBuffered = [buffer length];
}

static void swz_createFile(id self, SEL _cmd,
id path,
id data,
id handler)
{
  if (gWatch) {
    gCreateFileCalled = 1;
    NSUInteger length = [data length];
    if (length > gQueuedLength) {
      gQueuedLength = length;
    }
    if (length > kSpecMaximumRecordedBodyBytes) {
      gQueuedOversized = 1;
    }
  }
  gOrigCreateFile(self, _cmd, path, data, handler);
}

static BOOL swz_createAtPath(id self, SEL _cmd,
id path,
id data,
id attributes)
{
  if (gWatch) {
    gFileWriteCalled = 1;
    NSUInteger length = [data length];
    if (length > gFileWriteLength) {
      gFileWriteLength = length;
    }
    if (length > kSpecMaximumRecordedBodyBytes) {
      gFileWriteOversized = 1;
    }
  }
  return gOrigCreateAtPath(self, _cmd, path, data, attributes);
}

static id swz_connect(id self, SEL _cmd,
id request,
id delegate)
{
  id connection = gOrigConnect(self, _cmd, request, delegate);
  if (connection != nil && request != nil) {
    [gConnectionRequests setObject:request
                            forKey:[NSValue valueWithPointer:(void *)connection]];
  }
  return connection;
}

/*
 * GNUstep Base 1.29 _Block_copy (Source/ObjectiveC2/blocks_runtime.m) only
 * copies a block when flags include bit 29. Clang uses that bit for
 * BLOCK_HAS_STRET and always emits a descriptor, so Block_copy returns the
 * stack block unchanged. NSBlockOperation then retains it and crashes.
 * Run the recorder's blocks on the calling thread instead. The blocks
 * themselves are still the ones createFileAt: builds, including the
 * createFileAtPath:contents:attributes: of the captured body.
 */
static id swz_blockOperation(id self, SEL _cmd, id block)
{
  (void)self;
  (void)_cmd;
  if (block != nil) {
    void (^run)(void) = (void (^)(void))block;
    run();
  }
  return [[[NSOperation alloc] init] autorelease];
}

static void swz_setCompletionBlock(id self, SEL _cmd, id block)
{
  (void)self;
  (void)_cmd;
  if (block != nil) {
    void (^run)(void) = (void (^)(void))block;
    run();
  }
}

static id gCustomBlockStore = nil;
static id gBase64BlockStore = nil;
static BOOL gForceBase64 = NO;
static void swz_setCustomBlock(id self, SEL _cmd, id block);
static id swz_getCustomBlock(id self, SEL _cmd);
static void swz_setBase64Block(id self, SEL _cmd, id block);
static id swz_getBase64Block(id self, SEL _cmd);
static void swz_didResponse(id self, SEL _cmd, id connection, id response);

static void installSwizzles(void)
{
  Method append = class_getInstanceMethod([NSMutableData class], @selector(appendData:));
  gOrigAppend = (void *)method_getImplementation(append);

  Class protocolClass = NSClassFromString(@"SWRecordingProtocol");
  Method did = class_getInstanceMethod(protocolClass, @selector(connection:didReceiveData:));
  gOrigDidReceive = (void *)method_getImplementation(did);
  method_setImplementation(did, (IMP)swz_didReceive);
  Method didResponse = class_getInstanceMethod(protocolClass, @selector(connection:didReceiveResponse:));
  gOrigDidResponse = (void *)method_getImplementation(didResponse);
  method_setImplementation(didResponse, (IMP)swz_didResponse);

  Method finish = class_getInstanceMethod(protocolClass, @selector(connectionDidFinishLoading:));
  gOrigFinish = (void *)method_getImplementation(finish);
  method_setImplementation(finish, (IMP)swz_finish);

  Method create = class_getInstanceMethod(protocolClass,
                                          @selector(createFileAt:usingData:completionHandler:));
  gOrigCreateFile = (void *)method_getImplementation(create);
  method_setImplementation(create, (IMP)swz_createFile);

  Method write = class_getInstanceMethod([NSFileManager class],
                                         @selector(createFileAtPath:contents:attributes:));
  gOrigCreateAtPath = (void *)method_getImplementation(write);
  method_setImplementation(write, (IMP)swz_createAtPath);

  Method connect = class_getClassMethod([NSURLConnection class],
                                        @selector(connectionWithRequest:delegate:));
  gOrigConnect = (void *)method_getImplementation(connect);
  method_setImplementation(connect, (IMP)swz_connect);

  Method blockOp = class_getClassMethod([NSBlockOperation class],
                                        @selector(blockOperationWithBlock:));
  method_setImplementation(blockOp, (IMP)swz_blockOperation);
  Method completion = class_getInstanceMethod([NSOperation class],
                                              @selector(setCompletionBlock:));
  method_setImplementation(completion, (IMP)swz_setCompletionBlock);

  Class recorderClass = [SWHttpTrafficRecorder class];
  Method setCustom = class_getInstanceMethod(recorderClass,
                                              @selector(setCreateFileInCustomFormatBlock:));
  Method getCustom = class_getInstanceMethod(recorderClass,
                                              @selector(createFileInCustomFormatBlock));
  method_setImplementation(setCustom, (IMP)swz_setCustomBlock);
  method_setImplementation(getCustom, (IMP)swz_getCustomBlock);
  Method setBase64 = class_getInstanceMethod(recorderClass, @selector(setBase64TestBlock:));
  Method getBase64 = class_getInstanceMethod(recorderClass, @selector(base64TestBlock));
  method_setImplementation(setBase64, (IMP)swz_setBase64Block);
  method_setImplementation(getBase64, (IMP)swz_getBase64Block);
}

static BOOL gAppendHooked = NO;

static void swz_didResponse(id self, SEL _cmd, id connection, id response)
{
  gOrigDidResponse(self, _cmd, connection, response);
  if (gAppendHooked) {
    return;
  }
  id buffer = [self valueForKey:@"mutableData"];
  if (buffer == nil) {
    return;
  }
  /* NSMutableDataMalloc copies its dispatch table when behavior methods
     are added, so replacing NSMutableData's appendData: does not change
     the concrete class. Adding the method to that class does. */
  gAppendHooked = class_addMethod([buffer class], @selector(appendData:),
                                  (IMP)swz_append, "v@:@");
}

static void swz_setBase64Block(id self, SEL _cmd, id block)
{
  (void)self;
  (void)_cmd;
  gBase64BlockStore = block;
}

static id swz_getBase64Block(id self, SEL _cmd)
{
  (void)self;
  (void)_cmd;
  return gBase64BlockStore;
}

static void swz_setCustomBlock(id self, SEL _cmd, id block)
{
  (void)self;
  (void)_cmd;
  gCustomBlockStore = block;
}

static id swz_getCustomBlock(id self, SEL _cmd)
{
  (void)self;
  (void)_cmd;
  return gCustomBlockStore;
}

static void resetObservations(void)
{
  gGrewPastCeiling = 0;
  gAppendCalls = 0;
  gMaxBuffered = 0;
  gFinalBuffered = 0;
  gCreateFileCalled = 0;
  gQueuedLength = 0;
  gQueuedOversized = 0;
  gFileWriteCalled = 0;
  gFileWriteLength = 0;
  gFileWriteOversized = 0;
  gSawRecorded = 0;
  gSawFailed = 0;
  gProgressOversized = 0;
  gMaxProgressBody = 0;
  gForwardedBytes = 0;
  gCustomBodyLength = 0;
  gCustomCalled = 0;
  gLoadFinished = 0;
  gWatch = 1;
}

static void resetRecorderAtPath(NSString *path)
{
  SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
  [recorder stopRecording];
  recorder.progressDelegate = gProbe;
  recorder.recordingTestBlock = nil;
  recorder.base64TestBlock = nil;
  recorder.fileNamingBlock = nil;
  recorder.urlRegexPatternBlock = nil;
  recorder.createFileInCustomFormatBlock = nil;
  recorder.replacementDict = nil;
  recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
  NSError *error = nil;
  BOOL started = NO;
  if (path != nil) {
    started = [recorder startRecordingAtPath:path error:&error];
  } else {
    started = [recorder startRecording];
  }
  EXPECT(started, "startRecording failed: %s",
         error ? [[error description] UTF8String] : "nil");
}

static NSString *makeTempDir(void)
{
  static int sequence = 0;
  NSString *path = [NSString stringWithFormat:@"%@/sw-body-limit-%d-%d",
                                              NSTemporaryDirectory(), getpid(), sequence++];
  NSError *error = nil;
  BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:&error];
  EXPECT(created, "temp directory %s", [[error description] UTF8String]);
  return path;
}

static NSData *bodyOfLength(NSUInteger length)
{
  NSMutableData *data = [NSMutableData dataWithLength:length];
  memset([data mutableBytes], 'A', length);
  return data;
}

static void drainFileQueue(void)
{
  NSOperationQueue *queue = [[SWHttpTrafficRecorder sharedRecorder] valueForKey:@"fileCreationQueue"];
  [queue waitUntilAllOperationsAreFinished];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while ([deadline timeIntervalSinceNow] > 0 && !gSawRecorded && !gSawFailed) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
}

static void assertOversizedRefused(NSUInteger delivered)
{
  EXPECT(gForwardedBytes == delivered,
         "URL client received %lu bytes, expected %lu",
         (unsigned long)gForwardedBytes, (unsigned long)delivered);
  EXPECT(!gGrewPastCeiling,
         "recording buffer grew past %lu (max seen %lu, final %lu)",
         (unsigned long)kSpecMaximumRecordedBodyBytes,
         (unsigned long)gMaxBuffered, (unsigned long)gFinalBuffered);
  EXPECT(gMaxBuffered <= kSpecMaximumRecordedBodyBytes,
         "max buffered %lu exceeds ceiling %lu",
         (unsigned long)gMaxBuffered, (unsigned long)kSpecMaximumRecordedBodyBytes);
  EXPECT(gFinalBuffered == 0,
         "partial buffer was kept (%lu bytes) after the ceiling was crossed",
         (unsigned long)gFinalBuffered);
  EXPECT(!gProgressOversized,
         "progress callback carried %lu body bytes",
         (unsigned long)gMaxProgressBody);
  EXPECT(!gCreateFileCalled,
         "file queue accepted %lu bytes", (unsigned long)gQueuedLength);
  EXPECT(!gQueuedOversized, "file queue retained an oversized copy");
  EXPECT(!gFileWriteCalled,
         "createFileAtPath wrote %lu bytes", (unsigned long)gFileWriteLength);
  EXPECT(!gFileWriteOversized, "a recording file larger than the ceiling was created");
  EXPECT(!gSawRecorded, "recording was reported successful");
  EXPECT(gSawFailed, "recording did not report failure");
  fprintf(stdout,
          "  observed forwarded=%lu maxBuffered=%lu finalBuffered=%lu queued=%lu wrote=%lu "
          "grew=%d appends=%d recorded=%d failed=%d progressMax=%d\n",
          (unsigned long)gForwardedBytes, (unsigned long)gMaxBuffered,
          (unsigned long)gFinalBuffered, (unsigned long)gQueuedLength,
          (unsigned long)gFileWriteLength, gGrewPastCeiling, gAppendCalls, gSawRecorded,
          gSawFailed, (int)gMaxProgressBody);
}

static NSHTTPURLResponse *responseForURL(NSURL *url, NSString *mime, NSString *contentLength)
{
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  [headers setObject:mime forKey:@"Content-Type"];
  if (contentLength != nil) {
    [headers setObject:contentLength forKey:@"Content-Length"];
  }
  return [[NSHTTPURLResponse alloc] initWithURL:url
                                      statusCode:200
                                     HTTPVersion:@"HTTP/1.1"
                                    headerFields:headers];
}

static void feedBody(NSData *body, NSString *mime, NSString *contentLength,
                     NSUInteger chunkSize, SWHTTPTrafficRecordingFormat format, NSString *path)
{
  resetRecorderAtPath(path);
  SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
  recorder.recordingFormat = format;
  if (gForceBase64) {
    BOOL force = YES;
    recorder.base64TestBlock = ^BOOL(NSURLRequest *request, NSURLResponse *response) {
      (void)request;
      (void)response;
      return force;
    };
  }
  NSURL *url = [NSURL URLWithString:@"http://127.0.0.1/recorded-body"];
  SWFakeConnection *connection = [SWFakeConnection new];
  connection.currentRequest = [NSURLRequest requestWithURL:url];
  SWRecordingProtocol *protocol = [[NSClassFromString(@"SWRecordingProtocol") alloc]
      initWithRequest:connection.currentRequest
      cachedResponse:nil
              client:(id<NSURLProtocolClient>)gProbe];
  NSHTTPURLResponse *response = responseForURL(url, mime, contentLength);
  [protocol connection:(NSURLConnection *)connection didReceiveResponse:response];
  NSUInteger offset = 0;
  while (offset < [body length]) {
    NSUInteger count = chunkSize;
    if (count == 0 || offset + count > [body length]) {
      count = [body length] - offset;
    }
    NSData *chunk = [body subdataWithRange:NSMakeRange(offset, count)];
    [protocol connection:(NSURLConnection *)connection didReceiveData:chunk];
    offset += count;
  }
  [protocol connectionDidFinishLoading:(NSURLConnection *)connection];
  drainFileQueue();
}

static NSArray *namesInDirectory(NSString *path)
{
  return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL] ?: @[];
}

typedef struct {
  int listenFd;
  NSData *body;
  int chunked;
  char contentType[64];
} SWServer;

static void writeAll(int fd, const void *bytes, size_t length)
{
  const char *cursor = bytes;
  while (length > 0) {
    ssize_t wrote = write(fd, cursor, length);
    if (wrote < 0) {
      if (errno == EINTR) {
        continue;
      }
      return;
    }
    cursor += wrote;
    length -= (size_t)wrote;
  }
}

static void *serverMain(void *argument)
{
  @autoreleasepool {
    SWServer *server = argument;
    struct pollfd pollFd;
    pollFd.fd = server->listenFd;
    pollFd.events = POLLIN;
    if (poll(&pollFd, 1, 5000) <= 0) {
      return NULL;
    }
    int fd = accept(server->listenFd, NULL, NULL);
    if (fd < 0) {
      return NULL;
    }
    char buffer[2048];
    NSMutableData *request = [NSMutableData data];
    while ([request rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                         options:0
                           range:NSMakeRange(0, [request length])].location == NSNotFound) {
      struct pollfd readFd;
      readFd.fd = fd;
      readFd.events = POLLIN;
      if (poll(&readFd, 1, 5000) <= 0) {
        break;
      }
      ssize_t count = read(fd, buffer, sizeof(buffer));
      if (count <= 0) {
        break;
      }
      [request appendBytes:buffer length:(NSUInteger)count];
      if ([request length] > 1024 * 1024) {
        break;
      }
    }

    NSMutableData *response = [NSMutableData data];
    if (server->chunked) {
      NSString *header = [NSString stringWithFormat:
          @"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
          server->contentType];
      [response appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
      NSUInteger offset = 0;
      const NSUInteger chunkSize = 1024;
      const uint8_t *bytes = [server->body bytes];
      while (offset < [server->body length]) {
        NSUInteger count = chunkSize;
        if (offset + count > [server->body length]) {
          count = [server->body length] - offset;
        }
        NSString *sizeLine = [NSString stringWithFormat:@"%lx\r\n", (unsigned long)count];
        [response appendData:[sizeLine dataUsingEncoding:NSUTF8StringEncoding]];
        [response appendBytes:bytes + offset length:count];
        [response appendBytes:"\r\n" length:2];
        offset += count;
      }
      [response appendBytes:"0\r\n\r\n" length:5];
    } else {
      NSString *header = [NSString stringWithFormat:
          @"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
          server->contentType, (unsigned long)[server->body length]];
      [response appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
      [response appendData:server->body];
    }
    writeAll(fd, [response bytes], [response length]);
    close(fd);
  }
  return NULL;
}

static BOOL loadURLThroughRecorder(NSURL *url, NSTimeInterval timeout)
{
  gLoadFinished = 0;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setTimeoutInterval:timeout];
  [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
  NSURLConnection *connection = [NSURLConnection connectionWithRequest:request delegate:gProbe];
  EXPECT(connection != nil, "NSURLConnection was not created");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout + 1.0];
  while (!gLoadFinished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return gLoadFinished == 1;
}

static void runServerAndLoad(NSData *body, const char *contentType, int chunked,
                             SWHTTPTrafficRecordingFormat format, NSString *path)
{
  resetRecorderAtPath(path);
  [SWHttpTrafficRecorder sharedRecorder].recordingFormat = format;

  SWServer server;
  memset(&server, 0, sizeof(server));
  server.body = body;
  server.chunked = chunked;
  strncpy(server.contentType, contentType, sizeof(server.contentType) - 1);
  server.listenFd = socket(AF_INET, SOCK_STREAM, 0);
  EXPECT(server.listenFd >= 0, "socket failed");
  int yes = 1;
  setsockopt(server.listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  EXPECT(bind(server.listenFd, (struct sockaddr *)&address, sizeof(address)) == 0, "bind failed");
  EXPECT(listen(server.listenFd, 1) == 0, "listen failed");
  socklen_t length = sizeof(address);
  EXPECT(getsockname(server.listenFd, (struct sockaddr *)&address, &length) == 0, "getsockname failed");
  int port = ntohs(address.sin_port);

  pthread_t thread;
  EXPECT(pthread_create(&thread, NULL, serverMain, &server) == 0, "pthread_create failed");
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/recorded-body", port]];
  BOOL finished = loadURLThroughRecorder(url, 8.0);
  pthread_join(thread, NULL);
  close(server.listenFd);
  drainFileQueue();
  EXPECT(finished, "load did not finish (forwarded %lu)", (unsigned long)gForwardedBytes);
}

static void beginTest(const char *name)
{
  gTestName = name;
  gTestFailed = NO;
  gTests++;
  resetObservations();
  printf("== %s\n", name);
  fflush(stdout);
}

static void endTest(void)
{
  [[SWHttpTrafficRecorder sharedRecorder] stopRecording];
  if (gTestFailed) {
    gFailures++;
    printf("FAIL %s\n", gTestName);
  } else {
    printf("PASS %s\n", gTestName);
  }
  fflush(stdout);
}

static void testSmallBodyIsRecorded(void)
{
  beginTest("testSmallBodyIsRecorded");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kSmallBodyBytes);
    NSArray *before = namesInDirectory(path);
    feedBody(body, @"text/plain", @"128", 32, SWHTTPTrafficRecordingFormatBodyOnly, path);
    NSArray *after = namesInDirectory(path);
    EXPECT(gForwardedBytes == kSmallBodyBytes, "forwarded %lu", (unsigned long)gForwardedBytes);
    EXPECT(gSawRecorded, "small body was not recorded");
    EXPECT(!gSawFailed, "small body failed");
    EXPECT(gCreateFileCalled, "small body was not queued for disk");
    EXPECT(gFileWriteCalled, "small body was not written");
    EXPECT([after count] > [before count], "recording directory did not gain a file");
    EXPECT(gFinalBuffered == kSmallBodyBytes, "final buffer %lu", (unsigned long)gFinalBuffered);
    EXPECT(!gGrewPastCeiling, "small body crossed the ceiling");
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testRunningSizeIsCheckedOnEveryChunk(void)
{
  beginTest("testRunningSizeIsCheckedOnEveryChunk");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    feedBody(body, @"text/plain", @"10", 1024, SWHTTPTrafficRecordingFormatBodyOnly, path);
    assertOversizedRefused(kOversizedBodyBytes);
    EXPECT([[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL].count == 0,
           "a recording file appeared in %s", [path UTF8String]);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testSingleOversizedChunkIsDropped(void)
{
  beginTest("testSingleOversizedChunkIsDropped");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    feedBody(body, @"text/plain", nil, 0, SWHTTPTrafficRecordingFormatBodyOnly, path);
    assertOversizedRefused(kOversizedBodyBytes);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testMocktailQueuesNoOversizedCopy(void)
{
  beginTest("testMocktailQueuesNoOversizedCopy");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    feedBody(body, @"text/plain",
             [NSString stringWithFormat:@"%lu", (unsigned long)kOversizedBodyBytes],
             4096, SWHTTPTrafficRecordingFormatMocktail, path);
    assertOversizedRefused(kOversizedBodyBytes);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testHTTPMessageQueuesNoOversizedCopy(void)
{
  beginTest("testHTTPMessageQueuesNoOversizedCopy");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    feedBody(body, @"application/octet-stream",
             [NSString stringWithFormat:@"%lu", (unsigned long)kOversizedBodyBytes],
             8192, SWHTTPTrafficRecordingFormatHTTPMessage, path);
    assertOversizedRefused(kOversizedBodyBytes);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testCustomFormatIsNotGivenOversizedBody(void)
{
  beginTest("testCustomFormatIsNotGivenOversizedBody");
  @try {
    NSString *path = makeTempDir();
    resetRecorderAtPath(path);
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatCustom;
    NSString *capturedPath = path;
    recorder.createFileInCustomFormatBlock = ^NSString *(NSURLRequest *request, NSURLResponse *response,
                                                          NSData *bodyData, NSString *filePath) {
      (void)request;
      (void)response;
      (void)filePath;
      (void)capturedPath;
      gCustomCalled = 1;
      gCustomBodyLength = [bodyData length];
      if ([bodyData length] > 0) {
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:bodyData attributes:nil];
      }
      return nil;
    };
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1/recorded-body"];
    SWFakeConnection *connection = [SWFakeConnection new];
    connection.currentRequest = [NSURLRequest requestWithURL:url];
    SWRecordingProtocol *protocol = [[NSClassFromString(@"SWRecordingProtocol") alloc]
        initWithRequest:connection.currentRequest
        cachedResponse:nil
                client:(id<NSURLProtocolClient>)gProbe];
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    NSHTTPURLResponse *response = responseForURL(url, @"text/plain", @"10");
    [protocol connection:(NSURLConnection *)connection didReceiveResponse:response];
    [protocol connection:(NSURLConnection *)connection didReceiveData:body];
    [protocol connectionDidFinishLoading:(NSURLConnection *)connection];
    drainFileQueue();
    assertOversizedRefused(kOversizedBodyBytes);
    EXPECT(gCustomBodyLength <= kSpecMaximumRecordedBodyBytes,
           "custom block received %lu bytes", (unsigned long)gCustomBodyLength);
    EXPECT(!(gCustomCalled && gCustomBodyLength > 0),
           "custom block was handed a partial or full body");
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testJSONPrettyPrintPathDropsOversizedBody(void)
{
  beginTest("testJSONPrettyPrintPathDropsOversizedBody");
  @try {
    NSString *path = makeTempDir();
    NSMutableData *body = [NSMutableData dataWithCapacity:kOversizedBodyBytes];
    [body appendBytes:"\"" length:1];
    NSUInteger fill = kOversizedBodyBytes - 2;
    void *bytes = malloc(fill);
    memset(bytes, 'B', fill);
    [body appendBytes:bytes length:fill];
    free(bytes);
    [body appendBytes:"\"" length:1];
    feedBody(body, @"application/json",
             [NSString stringWithFormat:@"%lu", (unsigned long)[body length]],
             2048, SWHTTPTrafficRecordingFormatBodyOnly, path);
    assertOversizedRefused([body length]);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testBase64PathDropsOversizedBody(void)
{
  beginTest("testBase64PathDropsOversizedBody");
  gForceBase64 = YES;
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    feedBody(body, @"image/png",
             [NSString stringWithFormat:@"%lu", (unsigned long)kOversizedBodyBytes],
             4096, SWHTTPTrafficRecordingFormatMocktail, path);
    assertOversizedRefused(kOversizedBodyBytes);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  gForceBase64 = NO;
  endTest();
}

static void testChunkedNetworkBodyIsNotStored(void)
{
  beginTest("testChunkedNetworkBodyIsNotStored");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    runServerAndLoad(body, "text/plain", 1, SWHTTPTrafficRecordingFormatBodyOnly, path);
    assertOversizedRefused(kOversizedBodyBytes);
    EXPECT([[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL].count == 0,
           "chunked response left a file in %s", [path UTF8String]);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testContentLengthNetworkBodyIsNotStored(void)
{
  beginTest("testContentLengthNetworkBodyIsNotStored");
  @try {
    NSString *path = makeTempDir();
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    runServerAndLoad(body, "text/plain", 0, SWHTTPTrafficRecordingFormatMocktail, path);
    assertOversizedRefused(kOversizedBodyBytes);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

static void testDefaultStartRecordingPathIsNotStored(void)
{
  beginTest("testDefaultStartRecordingPathIsNotStored");
  @try {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *before = namesInDirectory(caches);
    NSData *body = bodyOfLength(kOversizedBodyBytes);
    runServerAndLoad(body, "text/plain", 0, SWHTTPTrafficRecordingFormatMocktail, nil);
    assertOversizedRefused(kOversizedBodyBytes);
    NSArray *after = namesInDirectory(caches);
    NSMutableArray *created = [NSMutableArray array];
    for (NSString *name in after) {
      if (![before containsObject:name]) {
        [created addObject:name];
        NSString *full = [caches stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:full error:NULL];
      }
    }
    EXPECT([created count] == 0, "default caches directory gained %s",
           [[created description] UTF8String]);
  } @catch (NSException *exception) {
    EXPECT(NO, "exception %s", [[exception description] UTF8String]);
  }
  endTest();
}

int main(void)
{
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    gConnectionRequests = [NSMutableDictionary dictionary];
    gProbe = [SWProbe new];
    installSwizzles();

    testSmallBodyIsRecorded();
    testRunningSizeIsCheckedOnEveryChunk();
    testSingleOversizedChunkIsDropped();
    testMocktailQueuesNoOversizedCopy();
    testHTTPMessageQueuesNoOversizedCopy();
    testCustomFormatIsNotGivenOversizedBody();
    testJSONPrettyPrintPathDropsOversizedBody();
    testBase64PathDropsOversizedBody();
    testChunkedNetworkBodyIsNotStored();
    testContentLengthNetworkBodyIsNotStored();
    testDefaultStartRecordingPathIsNotStored();

    printf("RESULT tests=%d failures=%d\n", gTests, gFailures);
    return gFailures == 0 ? 0 : 1;
  }
}
