#import "ApplePlatformShims.h"
#import "SWHttpTrafficRecorder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * replacementDict is documented as the map applied to a Mocktail response
 * body. These tests require that map to still be applied after the caller
 * has dropped its own reference. That is the behavior of a strong or copy
 * property. An assign / unsafe_unretained property frees the map first, and
 * the next intercepted response then messages the dangling pointer.
 *
 * Formats that never read replacementDict (body-only, HTTP message, custom)
 * are not covered. The only reader is replaceRegexWithTokensInData:, called
 * from createMocktailFileWithRequest:, which connectionDidFinishLoading:
 * uses for the Mocktail format.
 */

@interface SWRecordingProtocol : NSURLProtocol
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;
- (NSData *)replaceRegexWithTokensInData:(NSData *)data;
@end

@interface ResponseConnection : NSURLConnection
@property(nonatomic, strong) NSURLRequest *currentRequest;
@end

@implementation ResponseConnection
@end

@interface NSHTTPURLResponse (StatusInit)
- (id)initWithURL:(NSURL *)URL
       statusCode:(NSInteger)statusCode
      HTTPVersion:(NSString *)HTTPVersion
     headerFields:(NSDictionary<NSString *, NSString *> *)headerFields;
@end

static NSString *const kRewrittenBody = @"hello REDACTED_USER REDACTED_TOKEN end";

static int g_failures = 0;

static void fail(const char *name, NSString *detail) {
    fprintf(stderr, "FAIL %s: %s\n", name, detail.UTF8String);
    g_failures++;
}

static void pass(const char *name) {
    printf("PASS %s\n", name);
}

static NSMutableDictionary *replacementMap(void) {
    NSError *error = nil;
    NSRegularExpression *user =
        [NSRegularExpression regularExpressionWithPattern:@"user-[0-9]+"
                                                   options:0
                                                     error:&error];
    NSRegularExpression *token =
        [NSRegularExpression regularExpressionWithPattern:@"token-[0-9]+"
                                                   options:0
                                                     error:&error];
    if (user == nil || token == nil || error != nil) {
        fprintf(stderr, "failed to build replacement expressions\n");
        exit(2);
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:user forKey:@"REDACTED_USER"];
    [dict setObject:token forKey:@"REDACTED_TOKEN"];
    return dict;
}

static NSData *responseBody(void) {
    return [@"hello user-12345 token-99 end" dataUsingEncoding:NSUTF8StringEncoding];
}

static void occupyFreedMemory(void) {
    NSMutableArray *occupants = [NSMutableArray array];
    for (int i = 0; i < 40000; i++) {
        [occupants addObject:[NSMutableData dataWithLength:48]];
        [occupants addObject:[NSString stringWithFormat:@"occupant-%d", i]];
    }
    /* Keep the occupants alive until the recorder has used the map. */
    static NSMutableArray *keepAlive = nil;
    keepAlive = occupants;
}

static NSString *recordMocktailResponse(const char *name, BOOL releaseMapFirst) {
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    [recorder stopRecording];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
    recorder.replacementDict = nil;

    char directoryTemplate[] = "/tmp/swhttp-uaf-XXXXXX";
    char *directory = mkdtemp(directoryTemplate);
    if (directory == NULL) {
        fail(name, @"mkdtemp failed");
        return nil;
    }
    NSString *recordingPath = [NSString stringWithUTF8String:directory];

    NSURL *url = [NSURL URLWithString:@"http://example.test/api"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:url
                                    statusCode:200
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{ @"Content-Type": @"text/plain" }];
    NSMutableData *body = [responseBody() mutableCopy];

    /* Held for the whole recording when releaseMapFirst is NO. */
    NSMutableDictionary *ownedMap = nil;
    @autoreleasepool {
        NSMutableDictionary *map = replacementMap();
        recorder.replacementDict = map;
        NSError *error = nil;
        BOOL started = [recorder startRecordingAtPath:recordingPath error:&error];
        if (!started) {
            fail(name, error.localizedDescription ?: @"startRecording failed");
            return nil;
        }
        if (!releaseMapFirst) {
            ownedMap = map;
        }
    }
    if (releaseMapFirst) {
        /* Caller's autoreleased map is gone. Later responses must still
         * see the same replacements if the recorder owns the dictionary. */
        occupyFreedMemory();
    } else if (ownedMap == nil) {
        fail(name, @"caller lost the dictionary before the response");
        return nil;
    }

    SWRecordingProtocol *protocol =
        [[SWRecordingProtocol alloc] initWithRequest:request
                                      cachedResponse:nil
                                              client:nil];
    [protocol setValue:response forKey:@"response"];
    [protocol setValue:body forKey:@"mutableData"];
    ResponseConnection *connection = [ResponseConnection new];
    connection.currentRequest = request;

    @try {
        [protocol connectionDidFinishLoading:connection];
    } @catch (NSException *exception) {
        fail(name, [NSString stringWithFormat:@"recording the response raised %@: %@",
                                              exception.name, exception.reason]);
        [recorder stopRecording];
        return nil;
    }

    NSOperationQueue *queue = [recorder valueForKey:@"fileCreationQueue"];
    [queue waitUntilAllOperationsAreFinished];
    [recorder stopRecording];

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:recordingPath error:nil];
    NSString *recorded = nil;
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"tail"]) {
            recorded = [recordingPath stringByAppendingPathComponent:file];
            break;
        }
    }
    if (recorded == nil) {
        fail(name, @"no Mocktail file was written");
        return nil;
    }
    NSError *readError = nil;
    NSString *contents = [NSString stringWithContentsOfFile:recorded
                                                   encoding:NSUTF8StringEncoding
                                                      error:&readError];
    if (contents == nil) {
        fail(name, readError.localizedDescription ?: @"could not read recording");
        return nil;
    }
    /* Named use after the response so ARC keeps the caller's map alive
     * through connectionDidFinishLoading: when this run still owns it. */
    if (ownedMap != nil && [ownedMap count] != 2) {
        fail(name, @"caller map was not intact");
        return nil;
    }
    return contents;
}

static void expectRewritten(const char *name, BOOL releaseMapFirst) {
    NSString *contents = recordMocktailResponse(name, releaseMapFirst);
    if (contents == nil) {
        return;
    }
    if ([contents rangeOfString:kRewrittenBody].location == NSNotFound) {
        fail(name, [NSString stringWithFormat:@"recorded body was not rewritten:\n%@", contents]);
        return;
    }
    if ([contents rangeOfString:@"user-12345"].location != NSNotFound ||
        [contents rangeOfString:@"token-99"].location != NSNotFound) {
        fail(name, [NSString stringWithFormat:@"raw response bytes survived:\n%@", contents]);
        return;
    }
    pass(name);
}

static void testMocktailRewritesBodyWhileCallerOwnsDictionary(void) {
    expectRewritten("testMocktailRewritesBodyWhileCallerOwnsDictionary", NO);
}

static void testMocktailRewritesBodyAfterAutoreleasedDictionary(void) {
    expectRewritten("testMocktailRewritesBodyAfterAutoreleasedDictionary", YES);
}

static void testReplaceRegexAfterLocalDictionaryEnds(void) {
    const char *name = "testReplaceRegexAfterLocalDictionaryEnds";
    SWHttpTrafficRecorder *recorder = [SWHttpTrafficRecorder sharedRecorder];
    recorder.recordingFormat = SWHTTPTrafficRecordingFormatMocktail;
    recorder.replacementDict = nil;
    {
        NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
        NSError *error = nil;
        NSRegularExpression *user =
            [NSRegularExpression regularExpressionWithPattern:@"user-[0-9]+"
                                                       options:0
                                                         error:&error];
        NSRegularExpression *token =
            [NSRegularExpression regularExpressionWithPattern:@"token-[0-9]+"
                                                       options:0
                                                         error:&error];
        [map setObject:user forKey:@"REDACTED_USER"];
        [map setObject:token forKey:@"REDACTED_TOKEN"];
        recorder.replacementDict = map;
    }
    occupyFreedMemory();

    SWRecordingProtocol *protocol = [SWRecordingProtocol new];
    NSData *rewritten = nil;
    @try {
        rewritten = [protocol replaceRegexWithTokensInData:responseBody()];
    } @catch (NSException *exception) {
        fail(name, [NSString stringWithFormat:@"replaceRegexWithTokensInData: raised %@: %@",
                                              exception.name, exception.reason]);
        return;
    }
    NSString *text = [[NSString alloc] initWithData:rewritten encoding:NSUTF8StringEncoding];
    if (![text isEqualToString:kRewrittenBody]) {
        fail(name, [NSString stringWithFormat:@"body was '%@'", text]);
        return;
    }
    pass(name);
}

int main(int argc, char **argv) {
    const char *selected = argc > 1 ? argv[1] : "all";
    @autoreleasepool {
        if (strcmp(selected, "all") == 0 || strcmp(selected, "owned") == 0) {
            testMocktailRewritesBodyWhileCallerOwnsDictionary();
        }
        if (strcmp(selected, "all") == 0 || strcmp(selected, "autoreleased") == 0) {
            testMocktailRewritesBodyAfterAutoreleasedDictionary();
        }
        if (strcmp(selected, "all") == 0 || strcmp(selected, "local") == 0) {
            testReplaceRegexAfterLocalDictionaryEnds();
        }
        if (strcmp(selected, "owned") != 0 &&
            strcmp(selected, "autoreleased") != 0 &&
            strcmp(selected, "local") != 0 &&
            strcmp(selected, "all") != 0) {
            fprintf(stderr, "unknown test '%s'\n", selected);
            return 2;
        }
    }
    return g_failures == 0 ? 0 : 1;
}
