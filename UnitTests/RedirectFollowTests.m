/*
 * Exercises SWRecordingProtocol's redirect callback through the public
 * recorder and GNUstep Base 1.29 NSURLConnection.
 *
 * The fixed behavior is: after the recorder tells its client about a
 * redirect, the recorder's own connection must not send the Location
 * request. The client's redirect policy decides whether that URL is loaded.
 * These tests fail while the recorder returns the redirect request and the
 * inner connection therefore loads it anyway.
 */
#import "SWHttpTrafficRecorder.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <pthread.h>
#import <setjmp.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static const char *kSecretBody = "SECRET-INTERNAL-BODY";
static const char *kHarmlessBody = "HARMLESS-BODY";
static const char *kPostBody = "action=state-change";
static NSString * const kCookieName = @"session";
static NSString * const kCookieValue = @"shared-store-marker";

typedef struct {
    char method[16];
    char target[256];
    char cookie[512];
    char body[1024];
} CapturedRequest;

static sigjmp_buf gCrashJump;
static volatile sig_atomic_t gCrashArmed = 0;

static void on_crash(int sig)
{
    (void)sig;
    if (gCrashArmed) {
        gCrashArmed = 0;
        siglongjmp(gCrashJump, 1);
    }
    _exit(139);
}

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static CapturedRequest gCaptured[32];
static int gCapturedCount = 0;
static int gServerFD = -1;
static int gPort = 0;
static volatile int gServerStop = 0;

static void reset_captured(void)
{
    pthread_mutex_lock(&gLock);
    gCapturedCount = 0;
    memset(gCaptured, 0, sizeof(gCaptured));
    pthread_mutex_unlock(&gLock);
}

static int captured_count_for_path(const char *path)
{
    int count = 0;
    int i;
    pthread_mutex_lock(&gLock);
    for (i = 0; i < gCapturedCount; i++) {
        if (strcmp(gCaptured[i].target, path) == 0) {
            count++;
        }
    }
    pthread_mutex_unlock(&gLock);
    return count;
}

static int captured_field_contains(const char *path, const char *field, const char *needle)
{
    int found = 0;
    int i;
    pthread_mutex_lock(&gLock);
    for (i = 0; i < gCapturedCount; i++) {
        const char *value = NULL;
        if (strcmp(gCaptured[i].target, path) != 0) {
            continue;
        }
        if (strcmp(field, "method") == 0) {
            value = gCaptured[i].method;
        } else if (strcmp(field, "cookie") == 0) {
            value = gCaptured[i].cookie;
        } else if (strcmp(field, "body") == 0) {
            value = gCaptured[i].body;
        }
        if (value != NULL && strstr(value, needle) != NULL) {
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&gLock);
    return found;
}

static void record_request(const char *method, const char *target, const char *cookie, const char *body)
{
    pthread_mutex_lock(&gLock);
    if (gCapturedCount < (int)(sizeof(gCaptured) / sizeof(gCaptured[0]))) {
        CapturedRequest *slot = &gCaptured[gCapturedCount++];
        snprintf(slot->method, sizeof(slot->method), "%s", method ? method : "");
        snprintf(slot->target, sizeof(slot->target), "%s", target ? target : "");
        snprintf(slot->cookie, sizeof(slot->cookie), "%s", cookie ? cookie : "");
        snprintf(slot->body, sizeof(slot->body), "%s", body ? body : "");
        fprintf(stderr, "server saw %s %s cookie='%s' body='%s'\n",
                slot->method, slot->target, slot->cookie, slot->body);
    }
    pthread_mutex_unlock(&gLock);
}

static int read_request(int fd, char *buffer, size_t capacity)
{
    size_t used = 0;
    while (used + 1 < capacity) {
        ssize_t n = recv(fd, buffer + used, capacity - 1 - used, 0);
        char *headerEnd;
        int contentLength = 0;
        size_t headerLength;
        if (n < 0) {
            return -1;
        }
        if (n == 0) {
            break;
        }
        used += (size_t)n;
        buffer[used] = '\0';
        headerEnd = strstr(buffer, "\r\n\r\n");
        if (headerEnd == NULL) {
            continue;
        }
        headerLength = (size_t)(headerEnd - buffer) + 4;
        {
            const char *lengthHeader = strcasestr(buffer, "\r\nContent-Length:");
            if (lengthHeader != NULL && lengthHeader < headerEnd) {
                contentLength = atoi(lengthHeader + strlen("\r\nContent-Length:"));
            }
        }
        if (used >= headerLength + (size_t)contentLength) {
            return (int)used;
        }
    }
    buffer[used] = '\0';
    return used > 0 ? (int)used : -1;
}

static void header_value(const char *request, const char *name, char *out, size_t outSize)
{
    char pattern[64];
    const char *start;
    const char *end;
    size_t length;
    snprintf(pattern, sizeof(pattern), "\r\n%s:", name);
    start = strcasestr(request, pattern);
    if (start == NULL) {
        out[0] = '\0';
        return;
    }
    start += strlen(pattern);
    while (*start == ' ' || *start == '\t') {
        start++;
    }
    end = strstr(start, "\r\n");
    if (end == NULL) {
        end = start + strlen(start);
    }
    length = (size_t)(end - start);
    if (length >= outSize) {
        length = outSize - 1;
    }
    memcpy(out, start, length);
    out[length] = '\0';
}

static void respond(int fd, int status, const char *reason, const char *extraHeaders, const char *body)
{
    char message[2048];
    int bodyLength = body ? (int)strlen(body) : 0;
    int length = snprintf(message, sizeof(message),
                          "HTTP/1.0 %d %s\r\n"
                          "Content-Type: text/plain\r\n"
                          "Content-Length: %d\r\n"
                          "Connection: close\r\n"
                          "%s"
                          "\r\n"
                          "%s",
                          status, reason, bodyLength,
                          extraHeaders ? extraHeaders : "",
                          body ? body : "");
    if (length > 0) {
        send(fd, message, (size_t)length, 0);
    }
}

static void handle_client(int fd)
{
    char buffer[8192];
    char method[16];
    char target[256];
    char cookie[512];
    char *body;
    int received;
    memset(buffer, 0, sizeof(buffer));
    received = read_request(fd, buffer, sizeof(buffer));
    if (received < 0) {
        close(fd);
        return;
    }
    method[0] = '\0';
    target[0] = '\0';
    sscanf(buffer, "%15s %255s", method, target);
    header_value(buffer, "Cookie", cookie, sizeof(cookie));
    body = strstr(buffer, "\r\n\r\n");
    body = body ? body + 4 : "";
    record_request(method, target, cookie, body);

    if (strcmp(target, "/start") == 0) {
        char location[256];
        snprintf(location, sizeof(location),
                 "Location: http://127.0.0.1:%d/internal-admin\r\n", gPort);
        respond(fd, 302, "Found", location, "");
    } else if (strcmp(target, "/internal-admin") == 0) {
        respond(fd, 200, "OK", "", kSecretBody);
    } else if (strcmp(target, "/harmless") == 0) {
        respond(fd, 200, "OK", "", kHarmlessBody);
    } else {
        respond(fd, 404, "Not Found", "", "missing");
    }
    close(fd);
}

static void *server_main(void *unused)
{
    (void)unused;
    while (!gServerStop) {
        struct sockaddr_in peer;
        socklen_t peerLength = sizeof(peer);
        int fd = accept(gServerFD, (struct sockaddr *)&peer, &peerLength);
        if (fd < 0) {
            if (gServerStop) {
                break;
            }
            continue;
        }
        handle_client(fd);
    }
    return NULL;
}

static int start_server(void)
{
    struct sockaddr_in address;
    socklen_t length = sizeof(address);
    int yes = 1;
    pthread_t thread;
    gServerFD = socket(AF_INET, SOCK_STREAM, 0);
    if (gServerFD < 0) {
        return -1;
    }
    setsockopt(gServerFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(gServerFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        return -1;
    }
    if (getsockname(gServerFD, (struct sockaddr *)&address, &length) != 0) {
        return -1;
    }
    gPort = ntohs(address.sin_port);
    if (listen(gServerFD, 16) != 0) {
        return -1;
    }
    if (pthread_create(&thread, NULL, server_main, NULL) != 0) {
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

typedef enum {
    RedirectPolicyCancel = 0,
    RedirectPolicyAllow,
    RedirectPolicyRewrite
} RedirectPolicy;

@interface RedirectClient : NSObject
{
    RedirectPolicy policy;
    int redirectCallbacks;
    BOOL finished;
    NSMutableData *body;
    NSURL *rewrittenURL;
}
@property (nonatomic, assign) RedirectPolicy policy;
@property (nonatomic, assign) int redirectCallbacks;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSURL *rewrittenURL;
@end

@implementation RedirectClient

@synthesize policy, redirectCallbacks, finished, body, rewrittenURL;

- (instancetype)init
{
    self = [super init];
    if (self) {
        body = [NSMutableData data];
    }
    return self;
}

- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response
{
    (void)connection;
    if (response == nil) {
        return request;
    }
    self.redirectCallbacks += 1;
    if (self.policy == RedirectPolicyCancel) {
        return nil;
    }
    if (self.policy == RedirectPolicyRewrite) {
        NSMutableURLRequest *rewritten = [request mutableCopy];
        rewritten.URL = self.rewrittenURL;
        return rewritten;
    }
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    (void)connection;
    [self.body appendData:data];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    (void)connection;
    (void)response;
    [self.body setLength:0];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    self.finished = YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    (void)connection;
    (void)error;
    self.finished = YES;
}

@end

static int gFailures = 0;

static void expect_true(int condition, const char *name, NSString *detail)
{
    if (!condition) {
        gFailures++;
        fprintf(stderr, "FAIL %s: %s\n", name, detail.UTF8String);
    } else {
        fprintf(stderr, "PASS %s\n", name);
    }
}

static NSString *recording_text(NSString *directory)
{
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    NSMutableString *all = [NSMutableString string];
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (text) {
            [all appendString:text];
        }
    }
    return all;
}

static void pump(RedirectClient *client, NSTimeInterval seconds)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!client.finished && [limit timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    /* File creation is queued after the load finishes. */
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}

static void install_shared_cookie(void)
{
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [storage cookies]) {
        [storage deleteCookie:cookie];
    }
    NSDictionary *properties = @{
        NSHTTPCookieName: kCookieName,
        NSHTTPCookieValue: kCookieValue,
        NSHTTPCookieDomain: @"127.0.0.1",
        NSHTTPCookiePath: @"/",
    };
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    [storage setCookie:cookie];
}

static RedirectClient *perform_load(RedirectPolicy policy, NSString *recordingPath)
{
    NSError *error = nil;
    BOOL started;
    NSURL *url;
    NSMutableURLRequest *request;
    RedirectClient *client;
    NSURLConnection *connection;

    reset_captured();
    [[NSFileManager defaultManager] removeItemAtPath:recordingPath error:NULL];
    install_shared_cookie();

    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    [recorder stopRecording];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatBodyOnly;
    started = [recorder startRecordingAtPath:recordingPath error:&error];
    if (!started) {
        fprintf(stderr, "recorder failed to start: %s\n", error.localizedDescription.UTF8String);
        gFailures++;
        return nil;
    }

    url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/start", gPort]];
    request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [[NSString stringWithUTF8String:kPostBody] dataUsingEncoding:NSUTF8StringEncoding];
    request.HTTPShouldHandleCookies = YES;

    client = [[RedirectClient alloc] init];
    client.policy = policy;
    client.rewrittenURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:%d/harmless", gPort]];
    connection = [[NSURLConnection alloc] initWithRequest:request delegate:client];
    (void)connection;
    /*
     * GNUstep Base 1.29 copies blocks with a layout Clang does not emit
     * (ObjectiveC2/blocks_runtime.m). Recording the body reaches
     * NSBlockOperation and faults. The requests have already been sent.
     * Jump back so the assertions can see them.
     */
    if (sigsetjmp(gCrashJump, 1) == 0) {
        gCrashArmed = 1;
        pump(client, 4.0);
        gCrashArmed = 0;
    } else {
        fprintf(stderr, "continued after fault in the recording block path\n");
    }
    [recorder stopRecording];
    return client;
}

static void test_cancelled_redirect_is_not_loaded_or_recorded(void)
{
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"swhttp-redirect-cancel"];
    RedirectClient *client = perform_load(RedirectPolicyCancel, directory);
    int internalHits = captured_count_for_path("/internal-admin");
    int startHits = captured_count_for_path("/start");

    expect_true(client.redirectCallbacks == 1,
                "cancelled redirect notifies the client once",
                [NSString stringWithFormat:@"callbacks=%d", client.redirectCallbacks]);
    expect_true(startHits == 1,
                "cancelled redirect still sends the original request",
                [NSString stringWithFormat:@"start hits=%d", startHits]);
    expect_true(internalHits == 0,
                "cancelled redirect does not request Location",
                [NSString stringWithFormat:@"internal hits=%d", internalHits]);
    expect_true(!captured_field_contains("/internal-admin", "method", "POST"),
                "cancelled redirect does not resubmit the state-changing method",
                @"POST reached /internal-admin");
    expect_true(!captured_field_contains("/internal-admin", "body", kPostBody),
                "cancelled redirect does not resubmit the state-changing body",
                @"POST body reached /internal-admin");
    expect_true(!captured_field_contains("/internal-admin", "cookie", kCookieValue.UTF8String),
                "cancelled redirect does not attach the shared cookie to Location",
                @"shared cookie was sent to /internal-admin");
    expect_true([client.body rangeOfData:[NSData dataWithBytes:kSecretBody length:strlen(kSecretBody)]
                                 options:0
                                   range:NSMakeRange(0, client.body.length)].location == NSNotFound,
                "cancelled redirect does not deliver the Location body to the client",
                [[NSString alloc] initWithData:client.body encoding:NSUTF8StringEncoding]);
}

static void test_allowed_redirect_is_loaded_once(void)
{
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"swhttp-redirect-allow"];
    RedirectClient *client = perform_load(RedirectPolicyAllow, directory);
    int internalHits = captured_count_for_path("/internal-admin");

    expect_true(client.redirectCallbacks == 1,
                "allowed redirect notifies the client once",
                [NSString stringWithFormat:@"callbacks=%d", client.redirectCallbacks]);
    expect_true(internalHits == 1,
                "allowed redirect requests Location once",
                [NSString stringWithFormat:@"internal hits=%d", internalHits]);
    expect_true(client.finished &&
                [client.body rangeOfData:[NSData dataWithBytes:kSecretBody length:strlen(kSecretBody)]
                                 options:0
                                   range:NSMakeRange(0, client.body.length)].location != NSNotFound,
                "allowed redirect delivers the Location body once",
                [[NSString alloc] initWithData:client.body encoding:NSUTF8StringEncoding]);
}

static void test_rewritten_redirect_does_not_load_original_location(void)
{
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"swhttp-redirect-rewrite"];
    RedirectClient *client = perform_load(RedirectPolicyRewrite, directory);
    NSString *recorded = recording_text(directory);
    int internalHits = captured_count_for_path("/internal-admin");
    int harmlessHits = captured_count_for_path("/harmless");

    expect_true(client.redirectCallbacks == 1,
                "rewritten redirect notifies the client once",
                [NSString stringWithFormat:@"callbacks=%d", client.redirectCallbacks]);
    expect_true(internalHits == 0,
                "rewritten redirect does not request the original Location",
                [NSString stringWithFormat:@"internal hits=%d", internalHits]);
    expect_true(harmlessHits == 1,
                "rewritten redirect requests the client-supplied URL once",
                [NSString stringWithFormat:@"harmless hits=%d", harmlessHits]);
    expect_true([recorded rangeOfString:[NSString stringWithUTF8String:kSecretBody]].location == NSNotFound,
                "rewritten redirect does not record the original Location body",
                recorded);
    expect_true([client.body rangeOfData:[NSData dataWithBytes:kHarmlessBody length:strlen(kHarmlessBody)]
                                 options:0
                                   range:NSMakeRange(0, client.body.length)].location != NSNotFound,
                "rewritten redirect delivers the rewritten body",
                [[NSString alloc] initWithData:client.body encoding:NSUTF8StringEncoding]);
}

int main(void)
{
    @autoreleasepool {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = on_crash;
        sigemptyset(&action.sa_mask);
        sigaction(SIGSEGV, &action, NULL);
        sigaction(SIGBUS, &action, NULL);
        if (start_server() != 0) {
            fprintf(stderr, "failed to start local HTTP server\n");
            return 2;
        }
        fprintf(stderr, "listening on 127.0.0.1:%d\n", gPort);
        test_cancelled_redirect_is_not_loaded_or_recorded();
        test_allowed_redirect_is_loaded_once();
        test_rewritten_redirect_does_not_load_original_location();
        gServerStop = 1;
        shutdown(gServerFD, SHUT_RDWR);
        close(gServerFD);
    }
    fprintf(stderr, "%s (%d failure%s)\n", gFailures ? "FAILED" : "OK", gFailures, gFailures == 1 ? "" : "s");
    return gFailures ? 1 : 0;
}
