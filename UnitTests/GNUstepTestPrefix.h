/*
 * Test-build shims so SWHttpTrafficRecorder.m can be compiled against
 * GNUstep Base 1.29. Included only by UnitTests/run-body-limit-tests.sh.
 * These declarations are not part of the library.
 */
#import <Foundation/Foundation.h>
#import <stdlib.h>

/*
 * objc.h defines YES as (BOOL)1, which makes the literal @YES a syntax error.
 * Foundation itself uses YES as 1. Restore that so @YES boxes an NSNumber.
 */
#undef YES
#define YES 1

/* This test build compiles the library as manual reference counting. */
#ifndef __bridge_transfer
#define __bridge_transfer
#endif
#ifndef strong
#define strong retain
#endif

/*
 * iOS file-protection constants. GNUstep's NSFileManager ignores unknown
 * attribute keys (NSFileManager.m -changeFileAttributes:atPath:), then writes
 * the bytes (NSFileManager.m -createFileAtPath:contents:attributes:).
 */
static NSString * const NSFileProtectionKey = @"NSFileProtectionKey";
static NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";

/*
 * GNUstep 1.29's NSURLConnection has no -currentRequest. Apple's method
 * returns the request currently being loaded. The test runner supplies the
 * method and records the request passed to +connectionWithRequest:delegate:.
 */
@interface NSURLConnection (SWBodyLimitCurrentRequest)
- (NSURLRequest *)currentRequest;
@end

/*
 * This GNUstep Base build has GS_HAVE_NSURLSESSION 0, so the session classes
 * are not in the headers. The attack path calls -startRecording, which passes
 * a nil session configuration and never touches this type. The stand-in exists
 * so the other method compiles.
 */
#if !GS_HAVE_NSURLSESSION
@interface NSURLSessionConfiguration : NSObject {
  NSArray *_swProtocolClasses;
}
- (NSArray *)protocolClasses;
- (void)setProtocolClasses:(NSArray *)protocolClasses;
@end
@implementation NSURLSessionConfiguration
- (NSArray *)protocolClasses { return _swProtocolClasses; }
- (void)setProtocolClasses:(NSArray *)protocolClasses
{
  _swProtocolClasses = [protocolClasses copy];
}
@end
#endif

/*
 * libdispatch is not part of this GNUstep build. dispatch_once is used only
 * to create the recorder singleton. This runs that block once.
 */
typedef long dispatch_once_t;
static inline void dispatch_once(dispatch_once_t *token, void (^block)(void))
{
  if (__sync_bool_compare_and_swap(token, 0, 1)) {
    block();
    __sync_lock_test_and_set(token, 2);
  } else {
    while (__sync_add_and_fetch(token, 0) != 2) {
    }
  }
}

/*
 * CFHTTPMessage is CoreFoundation, which this test build does not link.
 * statusLineFromResponse uses it only to format the status line that is
 * prepended to an HTTP-message recording. The body bytes are appended
 * afterwards by the library itself.
 */
typedef struct SWCFHTTPMessage {
  long statusCode;
} *CFHTTPMessageRef;
typedef const void *CFTypeRef;

static const void *kCFAllocatorDefault = 0;
static const char SWCFHTTPVersion11[] = "HTTP/1.1";
static const void *kCFHTTPVersion1_1 = SWCFHTTPVersion11;

static inline CFHTTPMessageRef
CFHTTPMessageCreateResponse(const void *allocator, long statusCode,
                            const void *statusDescription, const void *version)
{
  CFHTTPMessageRef message = (CFHTTPMessageRef)calloc(1, sizeof(*message));
  if (message != NULL) {
    message->statusCode = statusCode;
  }
  (void)allocator;
  (void)statusDescription;
  (void)version;
  return message;
}

static inline const void *
CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message)
{
  long status = message ? message->statusCode : 0;
  NSString *line = [[NSString alloc] initWithFormat:@"HTTP/1.1 %ld OK", status];
  return (const void *)line;
}

static inline void CFRelease(CFTypeRef value)
{
  free((void *)value);
}
