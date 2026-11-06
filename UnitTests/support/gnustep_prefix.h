/*
 * Compile shims so SWHttpTrafficRecorder.m can be built against GNUstep
 * Base 1.29, which this environment has instead of Apple Foundation.
 * They supply symbols the Mocktail writer does not use. Included only
 * by UnitTests/run_mocktail_pattern_tests.sh.
 */
#import <Foundation/Foundation.h>

static NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";
static NSString * const NSFileProtectionKey = @"NSFileProtectionKey";

typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);
static inline void dispatch_once(dispatch_once_t *token, dispatch_block_t block) {
    if (*token == 0) {
        *token = 1;
        block();
    }
}

@interface NSURLSessionConfiguration : NSObject <NSCopying>
@property(nonatomic, copy) NSArray *protocolClasses;
@end

typedef void *CFTypeRef;
typedef const void *CFAllocatorRef;
typedef const void *CFStringRef;
typedef struct __CFHTTPMessage *CFHTTPMessageRef;
extern CFAllocatorRef kCFAllocatorDefault;
extern CFStringRef kCFHTTPVersion1_1;
CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc, int statusCode, CFStringRef desc, CFStringRef version);
CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message);
void CFRelease(CFTypeRef cf);

/*
 * GNU libobjc defines YES as (BOOL)1, which rejects Clang's @YES literal.
 * @1 boxes the same flag the recorder stores on the handled-request key.
 */
#ifdef YES
#undef YES
#endif
#ifdef NO
#undef NO
#endif
#define YES 1
#define NO 0

@interface NSURLConnection (SWTestCurrentRequest)
- (NSURLRequest *)currentRequest;
@end
