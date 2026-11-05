#import "GNUstepTestShims.h"

/*
 * dispatch_once contract, from swift-corelibs-libdispatch
 * src/once.c at swift-5.10.1-RELEASE: the block runs once, and a caller
 * that arrives while it is running waits until it has finished.
 * Lines 27-32 and 51-70.
 */
void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block)
{
    long state = __atomic_load_n(predicate, __ATOMIC_ACQUIRE);
    if (state == 2) {
        return;
    }
    long expected = 0;
    if (__atomic_compare_exchange_n(predicate, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        block();
        __atomic_store_n(predicate, 2, __ATOMIC_RELEASE);
        return;
    }
    while (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) != 2) {
    }
}

@implementation NSURLSessionConfiguration
@synthesize protocolClasses = _protocolClasses;
@end

@implementation NSURLConnection (SWTestCurrentRequest)
- (NSURLRequest *)currentRequest
{
    /* GNUstep Base 1.31.1 NSURLConnection has no currentRequest.
     * connectionDidFinishLoading reads it only to build the recorded file.
     * The progress callback uses NSURLProtocol's request, not this value.
     */
    return nil;
}
@end

NSString * const NSFileProtectionKey = @"NSFileProtectionKey";
NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";

CFAllocatorRef kCFAllocatorDefault = 0;
CFStringRef kCFHTTPVersion1_1 = 0;

struct SWTestHTTPMessage {
    long statusCode;
};

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, long statusCode, CFStringRef statusDescription, CFStringRef httpVersion)
{
    (void)alloc;
    (void)statusDescription;
    (void)httpVersion;
    struct SWTestHTTPMessage *message = calloc(1, sizeof(*message));
    message->statusCode = statusCode;
    return message;
}

CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message)
{
    return (__bridge_retained CFStringRef)[[NSString alloc] initWithFormat:@"HTTP/1.1 %ld", message->statusCode];
}

void CFRelease(CFHTTPMessageRef message)
{
    free(message);
}
