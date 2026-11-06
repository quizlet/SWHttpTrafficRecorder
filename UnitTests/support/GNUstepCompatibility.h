/*
 * Declarations the recorder source uses and this host's Foundation does not
 * provide. Included only when compiling the tests. Production sources are
 * unchanged.
 */
#import <Foundation/Foundation.h>

#if !GS_HAVE_NSURLSESSION
@interface NSURLSessionConfiguration : NSObject
{
  NSArray *_protocolClasses;
}
@property (nonatomic, copy) NSArray *protocolClasses;
@end
#endif

#ifndef __APPLE__
@interface NSURLConnection (CurrentRequestShim)
@property (readonly, copy) NSURLRequest *currentRequest;
@end

#define __bridge_transfer

typedef const void *CFTypeRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef struct __CFHTTPMessage *CFHTTPMessageRef;
typedef const struct __CFString *CFStringRef;
typedef signed long CFIndex;

extern CFAllocatorRef kCFAllocatorDefault;
extern CFStringRef kCFHTTPVersion1_1;

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc,
                                             CFIndex statusCode,
                                             CFStringRef statusDescription,
                                             CFStringRef httpVersion);
CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message);
void CFRelease(CFTypeRef cf);

extern NSString * const NSFileProtectionKey;
extern NSString * const NSFileProtectionComplete;

typedef long dispatch_once_t;
void dispatch_once(dispatch_once_t *predicate, void (^block)(void));
void SWInstallCurrentRequestShim(void);
#endif
