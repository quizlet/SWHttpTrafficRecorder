#import "GNUstepCompatibility.h"

#if !defined(__APPLE__)

#import <objc/runtime.h>

/* Clang emits this for blocks that capture nothing. GNUstep Base 1.29 does not define it. */
struct { void *isa; int flags; int reserved; } _NSConcreteGlobalBlock;
#import <stdlib.h>
#import <string.h>

NSString * const NSFileProtectionKey = @"NSFileProtectionKey";
NSString * const NSFileProtectionComplete = @"NSFileProtectionComplete";

CFAllocatorRef kCFAllocatorDefault = NULL;
CFStringRef kCFHTTPVersion1_1 = NULL;

typedef struct {
  int statusCode;
} SWTestHTTPMessage;

CFHTTPMessageRef CFHTTPMessageCreateResponse(CFAllocatorRef alloc,
                                             CFIndex statusCode,
                                             CFStringRef statusDescription,
                                             CFStringRef httpVersion)
{
  SWTestHTTPMessage *message = calloc(1, sizeof(SWTestHTTPMessage));
  message->statusCode = (int)statusCode;
  return (CFHTTPMessageRef)message;
}

CFStringRef CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageRef message)
{
  SWTestHTTPMessage *parsed = (SWTestHTTPMessage *)message;
  NSString *line = [NSString stringWithFormat: @"HTTP/1.1 %d",
                     parsed ? parsed->statusCode : 0];
  return (CFStringRef)[line retain];
}

void CFRelease(CFTypeRef cf)
{
  free((void *)cf);
}

void dispatch_once(dispatch_once_t *predicate, void (^block)(void))
{
  if (predicate != NULL && *predicate == 0) {
    *predicate = 1;
    if (block != NULL) {
      block();
    }
  }
}

#if !GS_HAVE_NSURLSESSION
@implementation NSURLSessionConfiguration
@synthesize protocolClasses = _protocolClasses;

- (id) init
{
  self = [super init];
  if (self != nil) {
    _protocolClasses = [[NSArray alloc] init];
  }
  return self;
}

- (void) dealloc
{
  [_protocolClasses release];
  [super dealloc];
}
@end
#endif

static NSMutableDictionary *SWCurrentRequests;
static id (*SWOriginalConnectionInit)(id, SEL, NSURLRequest *, id, BOOL);

static id SWConnectionInit(id self, SEL _cmd, NSURLRequest *request,
                           id delegate, BOOL startImmediately)
{
  id connection = SWOriginalConnectionInit(self, _cmd, request, delegate,
                                           startImmediately);
  if (connection != nil && request != nil) {
    [SWCurrentRequests setObject: request
                          forKey: [NSValue valueWithPointer: connection]];
  }
  return connection;
}

@implementation NSURLConnection (CurrentRequestShim)

- (NSURLRequest *) currentRequest
{
  return [SWCurrentRequests objectForKey:
           [NSValue valueWithPointer: (void *)self]];
}

@end

/*
 * GNUstep Base 1.29 copies a block only when its flags include
 * BLOCK_HAS_DESCRIPTOR (1 << 29). See Source/ObjectiveC2/blocks_runtime.m
 * _Block_copy. Clang 18 stores 0xc2000000 instead, so NSBlockOperation's
 * addObject: of the uncopied block crashes in objc_msg_lookup. The recorder's
 * block body is the createFileAtPath: call. Run that body, and the completion
 * handler that follows it, on the calling thread.
 */
static NSMutableSet *SWInlineFileOperations;
static id (*SWOriginalSetCompletionBlock)(id, SEL, id);

static id SWBlockOperationWithBlock(id self, SEL _cmd, id block)
{
  NSOperation *operation;

  if (block != nil) {
    ((void (^)(void))block)();
  }
  operation = [[NSOperation alloc] init];
  [SWInlineFileOperations addObject: operation];
  return operation;
}

static id SWSetCompletionBlock(id self, SEL _cmd, id block)
{
  if ([SWInlineFileOperations containsObject: self]) {
    if (block != nil) {
      ((void (^)(void))block)();
    }
    return nil;
  }
  return SWOriginalSetCompletionBlock(self, _cmd, block);
}

static void SWSetCustomFormatBlock(id self, SEL _cmd, id block)
{
  Ivar ivar = class_getInstanceVariable(object_getClass(self),
               "_createFileInCustomFormatBlock");
  if (ivar != NULL) {
    *(id *)((char *)self + ivar_getOffset(ivar)) = block;
  }
}

static void SWInstallFileWriteShim(void)
{
  Method method;
  Class blockOperation = objc_getClass("NSBlockOperation");

  SWInlineFileOperations = [[NSMutableSet alloc] init];
  method = class_getClassMethod(blockOperation,
           @selector(blockOperationWithBlock:));
  method_setImplementation(method, (IMP)SWBlockOperationWithBlock);
  method = class_getInstanceMethod([NSOperation class],
           @selector(setCompletionBlock:));
  SWOriginalSetCompletionBlock = (id (*)(id, SEL, id))
    method_setImplementation(method, (IMP)SWSetCompletionBlock);
  method = class_getInstanceMethod(objc_getClass("SWHttpTrafficRecorder"),
           @selector(setCreateFileInCustomFormatBlock:));
  method_setImplementation(method, (IMP)SWSetCustomFormatBlock);
}

void SWInstallCurrentRequestShim(void)
{
  Method method;

  if (SWCurrentRequests != nil) {
    return;
  }
  SWCurrentRequests = [[NSMutableDictionary alloc] init];
  method = class_getInstanceMethod([NSURLConnection class],
           @selector(initWithRequest:delegate:startImmediately:));
  SWOriginalConnectionInit = (id (*)(id, SEL, NSURLRequest *, id, BOOL))
    method_setImplementation(method, (IMP)SWConnectionInit);
  SWInstallFileWriteShim();
}

#endif
