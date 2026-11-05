#import "ApplePlatformShims.h"

@implementation NSURLSessionConfiguration
@end

/*
 * sharedRecorder's initializer is the only caller. The tests are
 * single-threaded; the block must run exactly once.
 */
void dispatch_once(dispatch_once_t *predicate, void (^block)(void)) {
    if (__sync_bool_compare_and_swap(predicate, 0, 1)) {
        block();
        *predicate = 2;
    } else {
        while (*predicate != 2) {
        }
    }
}

NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";
NSString * const NSFileProtectionKey = @"NSFileProtectionKey";

CFAllocatorRef kCFAllocatorDefault = 0;
const char *kCFHTTPVersion1_1 = "HTTP/1.1";

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, long code, CFTypeRef desc, const void *version) {
    (void)alloc;
    (void)code;
    (void)desc;
    (void)version;
    return (CFHTTPMessageRef)1;
}

CFTypeRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message) {
    (void)message;
    return 0;
}

void CFRelease(CFTypeRef obj) {
    (void)obj;
}
