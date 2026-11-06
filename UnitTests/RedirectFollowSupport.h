/*
 * Declarations the recorder source references from Apple frameworks that
 * GNUstep Base 1.29 does not ship. These are satisfied by
 * RedirectFollowShims.m when the redirect tests are compiled on this host.
 * They are not part of the product.
 */
#ifndef REDIRECT_FOLLOW_SUPPORT_H
#define REDIRECT_FOLLOW_SUPPORT_H

#import <Foundation/Foundation.h>

#if !__has_feature(objc_arc)
#define strong retain
#define __bridge_transfer
#endif

/*
 * This host's GNUstep Base was built with GS_HAVE_NSURLSESSION 0, so the
 * session configuration type does not exist. The recorder's session entry
 * point names it. The redirect tests drive NSURLConnection, not this type.
 */
#if !GS_HAVE_NSURLSESSION
@interface NSURLSessionConfiguration : NSObject
{
    NSArray *protocolClasses;
}
@property(nonatomic, copy) NSArray *protocolClasses;
@end
#endif

typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef struct __CFAllocator *CFAllocatorRef;
typedef struct __CFHTTPMessage *CFHTTPMessageRef;

extern CFAllocatorRef kCFAllocatorDefault;
extern CFStringRef kCFHTTPVersion1_1;

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc,
                                              long statusCode,
                                              CFStringRef statusDescription,
                                              CFStringRef httpVersion);
CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message);
void CFRelease(CFTypeRef cf);

typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);
void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block);

FOUNDATION_EXPORT NSString * const NSFileProtectionKey;
FOUNDATION_EXPORT NSString * const NSFileProtectionComplete;

/*
 * GNUstep Base 1.29's NSURLConnection has no -currentRequest. The recorder
 * reads it only after a load finishes, to name the recording file. The shim
 * returns a stable placeholder so that path can run; it does not choose the
 * URL that is fetched.
 */
@interface NSURLConnection (RedirectFollowCurrentRequest)
@property (nonatomic, readonly, copy) NSURLRequest *currentRequest;
@end

#endif
