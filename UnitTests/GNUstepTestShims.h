/*
 * Declarations required to compile SWHttpTrafficRecorder.m against
 * GNUstep Base 1.31.1 (libobjc2 2.3). That library does not provide
 * NSURLSession (GS_HAVE_NSURLSESSION is 0), libdispatch, the iOS file
 * protection constants, CFHTTPMessage, or NSURLConnection.currentRequest.
 * The test runner includes this header first. It is not part of the
 * recorder and is not used by the assertions.
 */
#import <Foundation/Foundation.h>

typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);
void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block);

/*
 * NSURLSessionConfiguration is compiled out of this GNUstep Base.
 * The recorder only reads and writes protocolClasses on it.
 */
@interface NSURLSessionConfiguration : NSObject
@property (nonatomic, copy) NSArray *protocolClasses;
@end

@interface NSURLConnection (SWTestCurrentRequest)
@property (readonly, copy) NSURLRequest *currentRequest;
@end

extern NSString * const NSFileProtectionKey;
extern NSString * const NSFileProtectionComplete;

typedef const void *CFAllocatorRef;
typedef const void *CFStringRef;
typedef struct SWTestHTTPMessage *CFHTTPMessageRef;
extern CFAllocatorRef kCFAllocatorDefault;
extern CFStringRef kCFHTTPVersion1_1;

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, long statusCode, CFStringRef statusDescription, CFStringRef httpVersion);
CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message);
void CFRelease(CFHTTPMessageRef message);
