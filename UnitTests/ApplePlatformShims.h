#ifndef APPLE_PLATFORM_SHIMS_H
#define APPLE_PLATFORM_SHIMS_H

/*
 * Declarations the recorder source references and this non-Apple test
 * build does not get from Foundation. None of these symbols are used by
 * the Mocktail replacement path the tests drive.
 */
#import <Foundation/Foundation.h>

@interface NSURLSessionConfiguration : NSObject
@property(nonatomic, copy) NSArray *protocolClasses;
@end

typedef unsigned long dispatch_once_t;
void dispatch_once(dispatch_once_t *predicate, void (^block)(void));

extern NSString * const NSFileProtectionComplete;
extern NSString * const NSFileProtectionKey;

@interface NSURLConnection (RecorderCurrentRequestShim)
@property(nonatomic, readonly) NSURLRequest *currentRequest;
@end

typedef void *CFTypeRef;
typedef CFTypeRef CFHTTPMessageRef;
typedef const void *CFAllocatorRef;
extern CFAllocatorRef kCFAllocatorDefault;
extern const char *kCFHTTPVersion1_1;
CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, long code, CFTypeRef desc, const void *version);
CFTypeRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message);
void CFRelease(CFTypeRef obj);

#endif
