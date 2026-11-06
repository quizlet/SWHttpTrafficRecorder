/*
 * Link shims for compiling the ARC recorder sources against GNUstep Base
 * 1.29 and the GCC Objective-C runtime. None of these functions decide
 * whether a redirect is followed. Redirect policy is the unmodified
 * recorder and GNUstep NSURLConnection.
 */
#import "RedirectFollowSupport.h"
#import <objc/runtime.h>
#import <string.h>

CFAllocatorRef kCFAllocatorDefault = (CFAllocatorRef)0x1;
static const char kHTTPVersion[] = "HTTP/1.1";
CFStringRef kCFHTTPVersion1_1 = (CFStringRef)kHTTPVersion;

NSString * const NSFileProtectionKey = @"NSFileProtectionKey";
NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc,
                                              long statusCode,
                                              CFStringRef statusDescription,
                                              CFStringRef httpVersion)
{
    (void)alloc;
    (void)statusCode;
    (void)statusDescription;
    (void)httpVersion;
    return (CFHTTPMessageRef)0x1;
}

CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message)
{
    (void)message;
    /* HTTPMessage recording is not executed by these tests. */
    return (CFStringRef)0;
}

void CFRelease(CFTypeRef cf)
{
    (void)cf;
}

void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block)
{
    if (predicate != NULL && *predicate == 0) {
        *predicate = ~0L;
        if (block != NULL) {
            block();
        }
    }
}

/*
 * Clang ARC emits objc_retain/objc_release. libobjc 4 on this host does
 * not export them; the methods themselves are the GNU runtime retain
 * implementation inside GNUstep Base.
 */
id objc_retain(id obj)
{
    return [obj retain];
}

void objc_release(id obj)
{
    [obj release];
}

id objc_autorelease(id obj)
{
    return [obj autorelease];
}

id objc_retainAutorelease(id obj)
{
    return [[obj retain] autorelease];
}

id objc_retainAutoreleaseReturnValue(id obj)
{
    return [[obj retain] autorelease];
}

id objc_autoreleaseReturnValue(id obj)
{
    return [obj autorelease];
}

id objc_retainAutoreleasedReturnValue(id obj)
{
    return obj;
}

id objc_storeStrong(id *location, id obj)
{
    id prev = *location;
    *location = [obj retain];
    [prev release];
    return obj;
}

void objc_storeWeak(id *location, id obj)
{
    *location = obj;
}

id objc_loadWeakRetained(id *location)
{
    return [*location retain];
}

id objc_loadWeak(id *location)
{
    return [[*location retain] autorelease];
}

void objc_destroyWeak(id *location)
{
    *location = nil;
}

void objc_copyWeak(id *dest, id *src)
{
    *dest = *src;
}

void objc_moveWeak(id *dest, id *src)
{
    *dest = *src;
    *src = nil;
}

void objc_initWeak(id *location, id obj)
{
    *location = obj;
}

void objc_releaseAutoreleasedReturnValue(void)
{
}

#if !GS_HAVE_NSURLSESSION
@implementation NSURLSessionConfiguration
@synthesize protocolClasses;
@end
#endif

@implementation NSURLConnection (RedirectFollowCurrentRequest)

- (NSURLRequest *) currentRequest
{
  return [NSURLRequest requestWithURL:
    [NSURL URLWithString: @"http://127.0.0.1/recorded"]];
}

@end
