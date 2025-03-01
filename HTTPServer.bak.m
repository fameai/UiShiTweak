//  HTTPServer.m
//  UiShi Tweak
//  Extended CFStream-based HTTP server to bridge HTTP requests to Swift BBEvent methods.
#import "HTTPServer.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// SBApplicationController interface for app deletion
@interface SBApplicationController : NSObject
+ (instancetype)sharedInstanceIfExists;
- (void)requestUninstallApplicationWithBundleIdentifier:(NSString *)bundleID
                                              options:(NSUInteger)options
                                        withCompletion:(void(^)(void))completion;
@end

#pragma mark - Swift BBEvent bridging

#define SWIFT_BB_EVENT @"HandleURLScheme.BBEvent"

// Global request tracking
static NSMutableDictionary<NSNumber *, NSValue *> *s_pendingRequests;
static dispatch_queue_t s_requestQueue;
static NSUInteger s_boundPort = 0; // Track which port we're bound to

// Forward declare some BBEvent methods
@interface BBEvent : NSObject

// Already existing
+ (void)tapOnViewWithLabel:(NSString *)label;
+ (void)tapAt:(CGFloat)x y:(CGFloat)y;
+ (void)slideFromX:(CGFloat)startX y:(CGFloat)startY toX:(CGFloat)endX y:(CGFloat)endY duration:(NSTimeInterval)duration;
+ (void)enterText:(NSString *)text;
+ (void)waitUntilHittable:(NSString *)identifier timeout:(NSTimeInterval)timeout;
+ (void)waitUntilVisible:(NSString *)identifier timeout:(NSTimeInterval)timeout;

// Asynchronous wrappers from your Swift code
+ (void)asyncClickOnLabel:(NSString *)labelText
               exactMatch:(BOOL)exactMatch
               stopLabels:(NSArray<NSString *> *)stopLabels
                  timeout:(int)timeout
                 interval:(int)interval
              maxReclicks:(int)maxReclicks
   usePointerBasedReclick:(BOOL)usePointerBasedReclick
               completion:(void (^)(BOOL success, NSInteger reclickCount, NSString * _Nullable failReason))completion;

+ (void)asyncInputText:(NSString *)inputText
             intoLabel:(NSString *)labelText
            exactMatch:(BOOL)exactMatch
            stopLabels:(NSArray<NSString *> *)stopLabels
               timeout:(int)timeout
              interval:(int)interval;

// Add the new method declaration
+ (void)asyncSetText:(NSString *)inputText
           intoLabel:(NSString *)labelText
          exactMatch:(BOOL)exactMatch
          stopLabels:(NSArray<NSString *> *)stopLabels
             timeout:(int)timeout
            interval:(int)interval
          completion:(void (^)(BOOL success, NSString * _Nullable failReason))completion;

// Updated method name to match new Swift implementation
+ (void)asyncSetTextInCellWithText:(NSString *)searchText
                         inputText:(NSString *)inputText
                        exactMatch:(BOOL)exactMatch
                        stopLabels:(NSArray<NSString *> *)stopLabels
                           timeout:(int)timeout
                          interval:(int)interval
                        completion:(void (^)(BOOL success, NSString * _Nullable failReason))completion;

// Add the new method declaration
+ (void)tapAlertButtonWithTitle:(NSString *)title exactMatch:(BOOL)exactMatch;

// Add the new async alert button method
+ (void)asyncTapAlertButton:(NSString *)title
                 exactMatch:(BOOL)exactMatch
                    timeout:(int)timeout
                   interval:(int)interval
                maxReclicks:(int)maxReclicks
                 completion:(void (^)(BOOL success, NSInteger reclickCount, NSString *_Nullable failReason))completion;

@end

#pragma mark - HTTPServer Implementation

@implementation HTTPServer

static CFSocketRef _listeningSocket = NULL;
static CFRunLoopSourceRef _runLoopSource = NULL;

+ (void)startServerOnPort:(NSUInteger)port {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_pendingRequests = [NSMutableDictionary dictionary];
        s_requestQueue = dispatch_queue_create("com.example.HTTPRequestQueue", DISPATCH_QUEUE_SERIAL);
    });

    if (_listeningSocket != NULL) {
        NSLog(@"[UiShi] HTTPServer: already started!");
        return;
    }
    NSLog(@"[UiShi] HTTPServer: starting on port %lu...", (unsigned long)port);

    // Create the socket context
    CFSocketContext socketCtxt = {0, NULL, NULL, NULL, NULL};

    // Create a TCP IPv4 listening socket
    _listeningSocket = CFSocketCreate(kCFAllocatorDefault,
                                      PF_INET,
                                      SOCK_STREAM,
                                      IPPROTO_TCP,
                                      kCFSocketAcceptCallBack,
                                      &AcceptCallback,
                                      &socketCtxt);

    if (!_listeningSocket) {
        NSLog(@"[UiShi] HTTPServer: Failed to create CFSocket");
        return;
    }

    // Reuse port
    int yes = 1;
    setsockopt(CFSocketGetNative(_listeningSocket),
               SOL_SOCKET, SO_REUSEADDR,
               (void *)&yes, sizeof(yes));

    // Bind the socket
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len         = sizeof(addr);
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    CFDataRef addressData = CFDataCreate(kCFAllocatorDefault, (UInt8 *)&addr, sizeof(addr));
    if (CFSocketSetAddress(_listeningSocket, addressData) != kCFSocketSuccess) {
        NSLog(@"[UiShi] HTTPServer: Failed to bind port %lu", (unsigned long)port);
    CFRelease(addressData);
        CFRelease(_listeningSocket);
        _listeningSocket = NULL;
        return;
    }
    CFRelease(addressData);

    // Store the bound port
    s_boundPort = port;

    // Create run loop source
    _runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _listeningSocket, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);

    NSLog(@"[UiShi] HTTPServer: Listening on port %lu", (unsigned long)port);
}

#pragma mark - Socket accept callback

static void AcceptCallback(CFSocketRef s,
                           CFSocketCallBackType type,
                           CFDataRef address,
                           const void *data,
                           void *info)
{
    @autoreleasepool {
        if (type != kCFSocketAcceptCallBack) {
            return;
        }

        // Native socket
        CFSocketNativeHandle clientHandle = *(CFSocketNativeHandle *)data;
        NSLog(@"[UiShi] HTTPServer: Client connected!");

        // Create read/write streams
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreatePairWithSocket(kCFAllocatorDefault,
                                     clientHandle,
                                     &readStream,
                                     &writeStream);

        if (!readStream || !writeStream) {
            NSLog(@"[UiShi] Failed to create read/write streams");
            close(clientHandle);
            if (readStream) CFRelease(readStream);
            if (writeStream) CFRelease(writeStream);
            return;
        }

        if (!CFReadStreamOpen(readStream) || !CFWriteStreamOpen(writeStream)) {
            NSLog(@"[UiShi] Failed to open streams");
            CFRelease(readStream);
            CFRelease(writeStream);
            close(clientHandle);
            return;
        }

        // Continuously read until there is no more data or an error.
        // We store the entire request in requestData.
        NSMutableData *requestData = [NSMutableData data];
        uint8_t buffer[2048];

        while (true) {
            CFIndex bytesRead = CFReadStreamRead(readStream,
                                                 buffer,
                                                 sizeof(buffer));
            if (bytesRead < 0) {
                NSLog(@"[UiShi] Error reading from client");
                // On error, close everything
                CFWriteStreamClose(writeStream);
                CFReadStreamClose(readStream);
                CFRelease(writeStream);
                CFRelease(readStream);
                close(clientHandle);
                return;
            }
            else if (bytesRead == 0) {
                // 0 => end of stream (client closed or no more data)
                break;
            }
            else {
                [requestData appendBytes:buffer length:bytesRead];
                // For HTTP requests, we can break after finding the end of headers
                if ([requestData length] >= 4) {
                    char *bytes = (char *)[requestData bytes];
                    if (memcmp(bytes + [requestData length] - 4, "\r\n\r\n", 4) == 0) {
                        // Found end of headers
                        break;
                    }
                }
            }
        }

        // Convert to NSString for convenience (assumes UTF8).
        NSString *fullRequest = [[NSString alloc] initWithData:requestData
                                                      encoding:NSUTF8StringEncoding];
        if (!fullRequest) {
            NSLog(@"[UiShi] Could not decode request data as UTF8, ignoring.");
            // We can still keep the streams, or close them:
            CFWriteStreamClose(writeStream);
            CFReadStreamClose(readStream);
            CFRelease(writeStream);
            CFRelease(readStream);
            close(clientHandle);
            return;
        }

        NSLog(@"[UiShi] HTTPServer: Full request:\n%@", fullRequest);

        // Create a request context
        static int gRequestID = 0;
        int localID = ++gRequestID;

        PendingRequestContext ctx;
        memset(&ctx, 0, sizeof(PendingRequestContext));
        ctx.clientSocket  = clientHandle;
        ctx.readStream    = readStream;
        ctx.writeStream   = writeStream;
        ctx.requestID     = localID;
        ctx.requestInProgress = YES;

        NSValue *wrapped = [NSValue valueWithBytes:&ctx objCType:@encode(PendingRequestContext)];

        dispatch_async(s_requestQueue, ^{
            s_pendingRequests[@(localID)] = wrapped;
        });

        // Finally, handle the request, passing in the localID
        [HTTPServer handleRequest:fullRequest requestID:@(localID)];
    }
}

#pragma mark - Request Handling

+ (void)handleRequest:(NSString *)request requestID:(NSNumber *)requestID {
    // We only care about GET lines for simplicity:
    if (![request hasPrefix:@"GET "]) {
        [self writeResponse:[self notFoundResponse] toRequestID:requestID closeWhenDone:YES];
        return;
    }

    // Extract the path segment
    NSString *path = [self extractPathFromRequest:request];
    if (!path) {
        [self writeResponse:[self notFoundResponse] toRequestID:requestID closeWhenDone:YES];
        return;
    }

    // Try to load the library again just in case it's not loaded
    void *handle = dlopen("/Library/MobileSubstrate/DynamicLibraries/libHandleURLScheme.dylib", RTLD_NOW);
    if (!handle) {
        NSLog(@"[UiShi] HTTPServer: Primary dlopen failed: %s", dlerror());
        // Still try @rpath as a last resort
        handle = dlopen("@rpath/libHandleURLScheme.dylib", RTLD_NOW);
        if (!handle) {
            NSLog(@"[UiShi] HTTPServer: Fallback dlopen failed: %s", dlerror());
            [self writeResponse:[self errorResponse:@"Failed to load libHandleURLScheme.dylib"]
                    toRequestID:requestID
                  closeWhenDone:YES];
            return;
        }
    }

    // Handle whoami request first since it doesn't need BBEvent
    if ([path hasPrefix:@"/whoami"]) {
        NSString *response = [self handleWhoAmIRequest];
        [self writeResponse:response toRequestID:requestID closeWhenDone:YES];
        return;
    }

    Class bbEvent = NSClassFromString(SWIFT_BB_EVENT);
    if (!bbEvent) {
        NSLog(@"[UiShi] HTTPServer: BBEvent class not found!");
        [self writeResponse:[self errorResponse:@"No BBEvent class found!"] toRequestID:requestID closeWhenDone:YES];
        return;
    }

    // Route by prefix
    if ([path hasPrefix:@"/asyncClick?"]) {
        [self handleAsyncClickRequest:path withBBEventClass:bbEvent requestID:requestID];
        return; // Don't close the connection yet
    }
    else if ([path hasPrefix:@"/asyncSetText?"]) {
        [self handleasyncSetTextRequest:path withBBEventClass:bbEvent requestID:requestID];
        return; // Don't close the connection yet
    }
    else if ([path hasPrefix:@"/asyncSetTextClass?"]) {
        [self handleAsyncSetTextClassRequest:path withBBEventClass:bbEvent requestID:requestID];
        return; // Don't close the connection yet
    }
    else if ([path hasPrefix:@"/viewHierarchy"]) {
        NSString *response = [self handleViewHierarchyRequest];
        [self writeResponse:response toRequestID:requestID closeWhenDone:YES];
        return;
    }
    else if ([path hasPrefix:@"/asyncSetTextInCell?"]) {  // Updated route name
        [self handleAsyncSetTextInCellRequest:path withBBEventClass:bbEvent requestID:requestID];
        return;
    }
    else if ([path hasPrefix:@"/hasElement?"]) {
        NSString *response = [self handleHasElementRequest:path withBBEventClass:bbEvent];
        [self writeResponse:response toRequestID:requestID closeWhenDone:YES];
        return;
    }
    else if ([path hasPrefix:@"/asyncInput?"]) {
        [self handleAsyncInputRequest:path withBBEventClass:bbEvent requestID:requestID];
        return; // Don't close the connection yet
    }
    else if ([path hasPrefix:@"/tapAlert?"]) {
        NSDictionary *params = [self queryParamsFromPath:path];
        NSString *labelText = params[@"label"] ?: @"";
        BOOL exactMatch = [params[@"exactMatch"] boolValue];

        // New parameters:
        int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;   // default 5s
        int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500; // default 0.5s
        int maxReclicks = params[@"maxReclicks"] ? [params[@"maxReclicks"] intValue] : 0; // default 0

        NSLog(@"[UiShi] Tapping alert button with label=\"%@\", exactMatch=%d, timeout=%d, interval=%d, maxReclicks=%d",
              labelText, exactMatch, timeoutMs, intervalMs, maxReclicks);

        // Call the new asynchronous BFS-based method
        if ([bbEvent respondsToSelector:@selector(asyncTapAlertButton:exactMatch:timeout:interval:maxReclicks:completion:)]) {
            [bbEvent asyncTapAlertButton:labelText
                             exactMatch:exactMatch
                                timeout:timeoutMs
                               interval:intervalMs
                            maxReclicks:maxReclicks
                             completion:^(BOOL success, NSInteger reclickCount, NSString * _Nullable failReason)
            {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                dict[@"success"] = @(success);
                dict[@"succeeded"] = @(success);  // as requested
                dict[@"error"] = failReason ?: [NSNull null];
                dict[@"title"] = labelText;
                dict[@"exactMatch"] = @(exactMatch);
                dict[@"maxReclicks"] = @(maxReclicks);
                dict[@"reclickCount"] = @(reclickCount);

                if (success) {
                    dict[@"details"] = [NSString stringWithFormat:
                                        @"Alert button \"%@\" was tapped successfully with %ld re-clicks",
                                        labelText, (long)reclickCount];
                } else {
                    dict[@"details"] = [NSString stringWithFormat:
                                        @"Failed to tap alert button \"%@\": %@", labelText, failReason];
                }

                [self finishAsyncJsonResponseWithRequestID:requestID
                                              didSucceed:success
                                                jsonDict:dict];
            }];
        }
        else {
            // Fallback if method not found
            [self writeResponse:[self errorResponse:@"BBEvent asyncTapAlertButton method not found"]
                    toRequestID:requestID
                  closeWhenDone:YES];
        }
        return;
    }
    else if ([path hasPrefix:@"/asyncClickClass?"]) {
        [self handleAsyncClickClassRequest:path withBBEventClass:bbEvent requestID:requestID];
        return;
    }
    else if ([path hasPrefix:@"/asyncClickAdvanced?"]) {
        [self handleAsyncClickAdvancedRequest:path withBBEventClass:bbEvent requestID:requestID];
        return;
    }
    else if ([path hasPrefix:@"/hasElementAdvanced?"]) {
        [self handleHasElementAdvancedRequest:path withBBEventClass:bbEvent requestID:requestID];
        return;
    }
    else if ([path hasPrefix:@"/pasteboard"]) {
        [self handlePasteboardRequest:path requestID:requestID];
        return; // do not close; we'll finalize asynchronously
    }
    else if ([path hasPrefix:@"/deleteApp?"]) {
        [self handleDeleteAppRequest:path requestID:requestID];
        return; // don't close connection immediately
    }
    else if ([path hasPrefix:@"/downloadImage?"]) {
        [self handleDownloadImageRequest:path requestID:requestID];
        return; // don't close connection immediately - we'll handle it asynchronously
    }
    
    // For all other routes, handle synchronously and close
    NSString *response = [self handleSynchronousRoute:path withBBEventClass:bbEvent];
    [self writeResponse:response toRequestID:requestID closeWhenDone:YES];
}

+ (NSString *)handleSynchronousRoute:(NSString *)path withBBEventClass:(Class)bbEvent {
    if ([path hasPrefix:@"/tap?"]) {
        return [self handleTapRequest:path withBBEventClass:bbEvent];
    }
    else if ([path hasPrefix:@"/tapAt?"]) {
        return [self handleTapAtRequest:path withBBEventClass:bbEvent];
    }
    else if ([path hasPrefix:@"/slide?"]) {
        return [self handleSlideRequest:path withBBEventClass:bbEvent];
    }
    else if ([path hasPrefix:@"/text?"]) {
        return [self handleTextRequest:path withBBEventClass:bbEvent];
    }
    else if ([path hasPrefix:@"/waitHittable?"]) {
        return [self handleWaitHittableRequest:path withBBEventClass:bbEvent];
    }
    else if ([path hasPrefix:@"/waitVisible?"]) {
        return [self handleWaitVisibleRequest:path withBBEventClass:bbEvent];
    }
    // else if ([path hasPrefix:@"/getPasteboard"]) {
    //     return [self handleGetPasteboardRequest];
    // }

    // If nothing matched:
    return [self notFoundResponse];
}

#pragma mark - Specific endpoint handlers

+ (NSString *)handleTapRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /tap?label=Blah
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *label = params[@"label"];
    if (!label.length) {
        return [self badRequestResponse:@"Missing label param"];
    }

    // call +[BBEvent tapOnViewWithLabel:]
    NSLog(@"[UiShi] HTTPServer: calling BBEvent tapOnViewWithLabel:%@", label);
    [bbEvent performSelector:@selector(tapOnViewWithLabel:) withObject:label];

    return [self okResponse:@"Tapped label."];
}

+ (NSString *)handleTapAtRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /tapAt?x=100&y=200
    NSDictionary *params = [self queryParamsFromPath:path];
    CGFloat x = [params[@"x"] floatValue];
    CGFloat y = [params[@"y"] floatValue];

    if (!params[@"x"] || !params[@"y"]) {
        return [self badRequestResponse:@"Missing x or y param"];
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent tapAt:%f y:%f", x, y);
    [bbEvent tapAt:x y:y];  // Direct method call instead of performSelector

    return [self okResponse:[NSString stringWithFormat:@"Tapped at (%f,%f).", x, y]];
}

+ (NSString *)handleSlideRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /slide?startX=10&startY=200&endX=300&endY=200&duration=0.8
    NSDictionary *params = [self queryParamsFromPath:path];
    CGFloat startX = [params[@"startX"] floatValue];
    CGFloat startY = [params[@"startY"] floatValue];
    CGFloat endX   = [params[@"endX"] floatValue];
    CGFloat endY   = [params[@"endY"] floatValue];
    NSTimeInterval duration = [params[@"duration"] doubleValue];

    if (!params[@"startX"] || !params[@"startY"] || !params[@"endX"] || !params[@"endY"]) {
        return [self badRequestResponse:@"Missing one of startX, startY, endX, endY"];
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent slideFromX:%f y:%f toX:%f y:%f duration:%f",
          startX, startY, endX, endY, duration);

    [(Class)bbEvent slideFromX:startX
                            y:startY
                          toX:endX
                            y:endY
                     duration:duration];

    return [self okResponse:@"Slide action dispatched."];
}

+ (NSString *)handleTextRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /text?input=Hello%20World
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *input = params[@"input"];
    if (!input.length) {
        return [self badRequestResponse:@"Missing 'input' param"];
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent enterText:%@", input);
    [bbEvent performSelector:@selector(enterText:) withObject:input];

    return [self okResponse:@"Entered text."];
}

+ (NSString *)handleWaitHittableRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /waitHittable?label=SomeIdentifier&timeout=5
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *identifier = params[@"label"];
    NSTimeInterval timeout = [params[@"timeout"] doubleValue];

    if (!identifier.length) {
        return [self badRequestResponse:@"Missing 'label' (identifier) param"];
    }
    if (!params[@"timeout"]) {
        // default to 5s if not provided
        timeout = 5.0;
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent waitUntilHittable:%@ timeout:%f",
          identifier, timeout);

    [bbEvent performSelector:@selector(waitUntilHittable:timeout:)
                  withObject:identifier
                  withObject:@(timeout)];

    return [self okResponse:@"waitUntilHittable called."];
}

+ (NSString *)handleWaitVisibleRequest:(NSString *)path withBBEventClass:(Class)bbEvent {
    // /waitVisible?label=Something&timeout=5
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *identifier = params[@"label"];
    NSTimeInterval timeout = [params[@"timeout"] doubleValue];

    if (!identifier.length) {
        return [self badRequestResponse:@"Missing 'label' (identifier) param"];
    }
    if (!params[@"timeout"]) {
        timeout = 5.0;
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent waitUntilVisible:%@ timeout:%f",
          identifier, timeout);

    [bbEvent performSelector:@selector(waitUntilVisible:timeout:)
                  withObject:identifier
                  withObject:@(timeout)];

    return [self okResponse:@"waitUntilVisible called."];
}

+ (void)handleAsyncInputRequest:(NSString *)path
                withBBEventClass:(Class)bbEvent
                     requestID:(NSNumber *)requestID
{
    // /asyncInput?label=Email&input=some%40email.com&exactMatch=1&stopLabels=Error,Cancel&timeout=10000&interval=100
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *labelText = params[@"label"] ?: @"";
    NSString *inputText = params[@"input"] ?: @"";
    BOOL exactMatch = [params[@"exactMatch"] boolValue];
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;

    NSArray<NSString *> *stopLabels = @[];
    NSString *stopLabelsStr = params[@"stopLabels"];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    if (!labelText.length) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"Missing 'label' param",
            @"details": @"asyncInputText failed: Missing required label parameter"
        }];
        return;
    }
    if (!inputText.length) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"Missing 'input' param",
            @"details": @"asyncInputText failed: Missing required input parameter"
        }];
        return;
    }

    NSLog(@"[UiShi] HTTPServer: calling BBEvent asyncInputText:%@ intoLabel:%@ exactMatch:%d stopLabels:%@ timeout:%d interval:%d",
          inputText, labelText, exactMatch, stopLabels, timeoutMs, intervalMs);

    // Dispatch to main queue for UI operations
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL sel = @selector(asyncInputText:intoLabel:exactMatch:stopLabels:timeout:interval:completion:);
        if ([bbEvent respondsToSelector:sel]) {
            void (*func)(id, SEL, NSString*, NSString*, BOOL, NSArray*, int, int, void(^)(BOOL, NSString*)) 
                = (void*)[bbEvent methodForSelector:sel];

            func(bbEvent, sel, inputText, labelText, exactMatch, stopLabels, timeoutMs, intervalMs,
                 ^(BOOL success, NSString *failReason) {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                dict[@"success"] = @(success);
                dict[@"error"] = failReason ?: [NSNull null];
                dict[@"labelText"] = labelText;
                dict[@"inputText"] = inputText;
                dict[@"succeeded"] = @(success);  // Add the succeeded field as requested
                
                if (!success && failReason) {
                    dict[@"details"] = [NSString stringWithFormat:@"asyncInputText failed: %@", failReason];
                } else {
                    dict[@"details"] = [NSString stringWithFormat:@"asyncInputText succeeded for label '%@'", labelText];
                }
                
                [self finishAsyncJsonResponseWithRequestID:requestID
                                              didSucceed:success
                                                jsonDict:dict];
            });
        } else {
            NSLog(@"[UiShi] BBEvent missing asyncInputText method?");
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            dict[@"success"] = @NO;
            dict[@"error"] = @"Method not found in BBEvent";
            dict[@"details"] = @"asyncInputText failed: BBEvent method not found";
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                            jsonDict:dict];
        }
    });
}

#pragma mark - Async Click Implementation

+ (void)handleAsyncClickRequest:(NSString *)path
                withBBEventClass:(Class)bbEvent
                     requestID:(NSNumber *)requestID
{
    // -----------------------------------------------
    // 1) Parse query parameters from the URL
    // -----------------------------------------------
    NSDictionary *params = [self queryParamsFromPath:path];

    NSString *labelText  = params[@"label"]       ?: @"";
    BOOL exactMatch      = [params[@"exactMatch"] boolValue];
    int timeoutMs        = params[@"timeout"]     ? [params[@"timeout"] intValue] : 5000;
    int intervalMs       = params[@"interval"]    ? [params[@"interval"] intValue] : 500;
    int maxReclicks      = params[@"maxReclicks"] ? [params[@"maxReclicks"] intValue] : 0;
    BOOL usePointer      = [params[@"usePointerBasedReclick"] boolValue];
    NSString *windowsParam = params[@"windows"]   ?: @"key";

    // parse stopLabels (comma-separated)
    NSString *stopLabelsStr = params[@"stopLabels"];
    NSArray<NSString *> *stopLabels = @[];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    NSLog(@"[UiShi] BFS-based click => label=\"%@\", exactMatch=%d, timeout=%d, interval=%d, maxReclicks=%d, usePointer=%d, windowsParam='%@'",
          labelText, exactMatch, timeoutMs, intervalMs, maxReclicks, usePointer, windowsParam);

    // -----------------------------------------------
    // 2) Call the Swift method with enhanced completion block
    // -----------------------------------------------
    dispatch_async(dispatch_get_main_queue(), ^{
        // Construct the selector
        SEL sel = @selector(asyncClickOnLabel:exactMatch:stopLabels:timeout:interval:maxReclicks:usePointerBasedReclick:windowsParam:completion:);
        if ([bbEvent respondsToSelector:sel]) {
            // Cast the method to a function pointer
            void (*func)(id, SEL,
                NSString*, BOOL, NSArray*, int, int, int, BOOL, NSString*,
                void(^)(BOOL, NSInteger, NSString*, NSNumber*, NSString*)
            ) = (void*)[bbEvent methodForSelector:sel];

            func(bbEvent,
                 sel,
                 labelText,
                 exactMatch,
                 stopLabels,
                 timeoutMs,
                 intervalMs,
                 maxReclicks,
                 usePointer,
                 windowsParam,
                 ^(BOOL success, NSInteger reclickCount, NSString *failReason, NSNumber *foundWindowIndex, NSString *foundWindowClass)
            {
                // Build JSON response
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                dict[@"success"] = @(success);
                dict[@"error"] = failReason ?: [NSNull null];
                dict[@"labelText"] = labelText;
                dict[@"exactMatch"] = @(exactMatch);
                dict[@"maxReclicks"] = @(maxReclicks);
                dict[@"reclickCount"] = @(reclickCount);
                dict[@"windowsParam"] = windowsParam;

                // Include info about where it was found
                if (foundWindowIndex) {
                    dict[@"foundInWindowIndex"] = foundWindowIndex;
                }
                if (foundWindowClass) {
                    dict[@"foundInWindowClass"] = foundWindowClass;
                }

                if (!success && failReason) {
                    dict[@"details"] = [NSString stringWithFormat:@"Click operation failed: %@", failReason];
                } else {
                    dict[@"details"] = [NSString stringWithFormat:
                        @"Click operation succeeded with %ld re-clicks", (long)reclickCount];
                }

            [self finishAsyncJsonResponseWithRequestID:requestID
                                              didSucceed:success
                                                jsonDict:dict];
            });
        } else {
            // Fallback if the extended method doesn't exist
            [self writeResponse:[self errorResponse:@"BBEvent asyncClickOnLabel method not found"]
                    toRequestID:requestID
                  closeWhenDone:YES];
        }
    });
}

#pragma mark - Async Click Class Implementation

+ (void)handleAsyncClickClassRequest:(NSString *)path
                     withBBEventClass:(Class)bbEvent
                            requestID:(NSNumber *)requestID
{
    NSDictionary *params = [self queryParamsFromPath:path];

    // Extract all relevant params
    NSString *className = params[@"className"] ?: @""; // the name of the UI class, e.g. "IGMediaCaptureButton"
    BOOL exactMatch = [params[@"exactMatch"] boolValue]; // optional
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;
    int maxReclicks = params[@"maxReclicks"] ? [params[@"maxReclicks"] intValue] : 0;
    BOOL usePointer = [params[@"usePointerBasedReclick"] boolValue] ?: NO;

    // stopLabels
    NSArray<NSString *> *stopLabels = @[];
    NSString *stopLabelsStr = params[@"stopLabels"];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // Quick checks
    if (!className.length) {
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                             jsonDict:@{
                @"success": @NO,
            @"error": @"Missing 'className' param",
            @"details": @"asyncClickOnClassName failed: Missing required className"
            }];
            return;
        }

    NSLog(@"[UiShi] BFS-based re-click => className='%@', maxReclicks=%d", className, maxReclicks);

    // 2) Dispatch to main queue for UI operations
        dispatch_async(dispatch_get_main_queue(), ^{
        // Construct the selector
        SEL sel = @selector(asyncClickOnClassName:exactMatch:stopLabels:timeout:interval:maxReclicks:usePointerBasedReclick:completion:);
        if ([bbEvent respondsToSelector:sel]) {
            // Cast the method to the function pointer
            void (*func)(id, SEL,
                         NSString*, BOOL, NSArray*, int, int, int, BOOL,
                         void(^)(BOOL, NSInteger, NSString*)) 
                = (void*)[bbEvent methodForSelector:sel];

            func(bbEvent,
                 sel,
                 className,
                 exactMatch,
                 stopLabels,
                 timeoutMs,
                 intervalMs,
                 maxReclicks,
                 usePointer,
                 ^(BOOL success, NSInteger reclickCount, NSString *failReason) {
                     // Build JSON response
                     NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                     dict[@"success"] = @(success);
                     dict[@"error"] = failReason ?: [NSNull null];
                     dict[@"className"] = className;
                     dict[@"reclickCount"] = @(reclickCount);
                     dict[@"maxReclicks"] = @(maxReclicks);

                     if (!success && failReason) {
                         dict[@"details"] = [NSString stringWithFormat:
                            @"Click by className failed: %@", failReason];
                     } else {
                         dict[@"details"] = [NSString stringWithFormat:
                            @"Click by className succeeded with %ld re-clicks", (long)reclickCount];
                     }

                     [self finishAsyncJsonResponseWithRequestID:requestID
                                                   didSucceed:success
                                                     jsonDict:dict];
                 }
            );
        } else {
            // Fallback: method not found
            NSString *error = @"Missing asyncClickOnClassName:... method on BBEvent";
            NSLog(@"[UiShi] %@", error);
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
                @"error": error,
                @"details": @"Implementation not found on BBEvent"
            }];
        }
    });
}

// Add helper method for JSON responses
+ (void)finishAsyncJsonResponseWithRequestID:(NSNumber *)requestID
                                 didSucceed:(BOOL)didSucceed
                                   jsonDict:(NSDictionary *)dict
{
    @autoreleasepool {
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict
                                                          options:0
                                                            error:&error];
        if (!jsonData) {
            NSString *errorResp = [NSString stringWithFormat:
                                  @"HTTP/1.1 500 Internal Server Error\r\n"
                                  "Content-Type: text/plain\r\n"
                                  "Content-Length: %lu\r\n"
                                  "\r\n"
                                  "Failed to serialize JSON response: %@\r\n",
                                  (unsigned long)[error.localizedDescription lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                  error.localizedDescription];
            [self writeResponse:errorResp toRequestID:requestID closeWhenDone:YES];
            return;
        }

        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSString *resp = [NSString stringWithFormat:
                          @"HTTP/1.1 %d %@\r\n"
                          "Content-Type: application/json\r\n"
                          "Content-Length: %lu\r\n"
                          "\r\n"
                          "%@\r\n",
                          didSucceed ? 200 : 500,
                          didSucceed ? @"OK" : @"Internal Server Error",
                          (unsigned long)[jsonStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                          jsonStr];

        [self writeResponse:resp toRequestID:requestID closeWhenDone:YES];
    }
}

#pragma mark - Response Writing

+ (void)writeResponse:(NSString *)response
          toRequestID:(NSNumber *)requestID
        closeWhenDone:(BOOL)shouldClose
{
    dispatch_async(s_requestQueue, ^{
        @autoreleasepool {
            NSValue *wrappedCtx = s_pendingRequests[requestID];
            if (!wrappedCtx) {
                NSLog(@"[UiShi] No pending request found for ID=%@", requestID);
                return;
            }

            PendingRequestContext ctx;
            [wrappedCtx getValue:&ctx];

            CFWriteStreamRef ws = ctx.writeStream;
            if (ws) {
                // Convert to UTF8 data
                const char *utf8 = [response UTF8String];
                CFIndex totalLen = (CFIndex)strlen(utf8);
                CFIndex totalWritten = 0;

                while (totalWritten < totalLen) {
                    // Optional check: if !CFWriteStreamCanAcceptBytes(ws), wait briefly
                    if (!CFWriteStreamCanAcceptBytes(ws)) {
                        // Check status in case the stream is closed or errored
                        CFStreamStatus st = CFWriteStreamGetStatus(ws);
                        if (st == kCFStreamStatusNotOpen ||
                            st == kCFStreamStatusError    ||
                            st == kCFStreamStatusClosed) {
                            NSLog(@"[UiShi] Stream is closed/error; aborting write");
                            break;
                        }
                        // Otherwise, just wait 5 ms and try again
                        usleep(5 * 1000);
                        continue;
                    }

                    CFIndex bytesRemaining = totalLen - totalWritten;
                    CFIndex actuallyWritten =
                        CFWriteStreamWrite(ws,
                                           (const UInt8 *)(utf8 + totalWritten),
                                           bytesRemaining);
                    if (actuallyWritten < 0) {
                        CFStreamError err = CFWriteStreamGetError(ws);
                        NSLog(@"[UiShi] Error writing response (code=%ld)", (long)err.error);
                        break;
                    }
                    totalWritten += actuallyWritten;
                }

                // Log if we didn't write everything
                if (totalWritten < totalLen) {
                    NSLog(@"[UiShi] Warning: Only wrote %ld/%ld bytes",
                          (long)totalWritten, (long)totalLen);
                }
            }

            // Now optionally close & remove from dictionary
            if (shouldClose) {
                if (ws) {
                    CFWriteStreamClose(ws);
                    CFRelease(ws);
                }
                if (ctx.readStream) {
                    CFReadStreamClose(ctx.readStream);
                    CFRelease(ctx.readStream);
                }
                close(ctx.clientSocket);

                [s_pendingRequests removeObjectForKey:requestID];
            }
        }
    });
}

#pragma mark - Helpers

/// Extracts the "/something?key=val" piece from a raw HTTP GET request line.
+ (NSString *)extractPathFromRequest:(NSString *)request {
    // request might look like "GET /tap?label=Hi HTTP/1.1"
    NSRange firstSpace = [request rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return nil;
    NSRange secondSpace = [request rangeOfString:@" "
                                    options:0
                                           range:NSMakeRange(firstSpace.location+1,
                                                             request.length - (firstSpace.location+1))];
    if (secondSpace.location == NSNotFound) return nil;

    NSString *path = [request substringWithRange:NSMakeRange(firstSpace.location+1,
                                                             secondSpace.location - (firstSpace.location+1))];
    return path;
}

/// Parses the query string part of a path into an NSDictionary.
/// For example, "/tap?label=Something" => {label: "Something"}
+ (NSDictionary<NSString *, NSString *> *)queryParamsFromPath:(NSString *)path {
    // path might be "/tap?label=Blah&foo=bar"
    NSRange questionMarkRange = [path rangeOfString:@"?"];
    if (questionMarkRange.location == NSNotFound) {
        return @{};
    }

    NSString *queryString = [path substringFromIndex:questionMarkRange.location + 1];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];

    NSArray *pairs = [queryString componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            NSString *key = [kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *value = [[kv[1] stringByRemovingPercentEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (key.length && value.length) {
                params[key] = value;
            }
        }
    }
    return params;
}

#pragma mark - Response Builders

+ (NSString *)okResponse:(NSString *)body {
    NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: %lu\r\n"
            "\r\n"
            "%@\r\n",
                      (unsigned long)body.length, body];
    return resp;
}

+ (NSString *)badRequestResponse:(NSString *)reason {
    NSString *body = [NSString stringWithFormat:@"Bad Request: %@\n", reason];
    NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 400 Bad Request\r\n"
            "Content-Length: %lu\r\n"
            "\r\n"
            "%@\r\n",
                      (unsigned long)body.length, body];
    return resp;
}

+ (NSString *)errorResponse:(NSString *)msg {
    NSString *respMsg = [NSString stringWithFormat:@"Error: %@\n", msg];
    NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 500 Internal Server Error\r\n"
            "Content-Length: %lu\r\n"
            "\r\n"
            "%@\r\n",
                      (unsigned long)[respMsg lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                      respMsg];
    return resp;
}

+ (NSString *)notFoundResponse {
    NSString *body = @"Not Found\n";
    NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 404 Not Found\r\n"
            "Content-Length: %lu\r\n"
            "\r\n"
            "%@\r\n",
            (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
            body];
    return resp;
}

#pragma mark - New endpoint handlers

+ (void)handleasyncSetTextRequest:(NSString *)path
                          withBBEventClass:(Class)bbEvent
                                requestID:(NSNumber *)requestID
{
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *labelText = params[@"label"] ?: @"";
    NSString *inputText = params[@"input"] ?: @"";
    BOOL exactMatch = [params[@"exactMatch"] boolValue];
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;

    // Split comma-separated stop labels if provided
    NSArray<NSString *> *stopLabels = @[];
    NSString *stopLabelsStr = params[@"stopLabels"];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // Dispatch to main queue for UI operations
    dispatch_async(dispatch_get_main_queue(), ^{
        [bbEvent asyncSetText:inputText
                           intoLabel:labelText
                          exactMatch:exactMatch
                         stopLabels:stopLabels
                            timeout:timeoutMs
                           interval:intervalMs
                         completion:^(BOOL success, NSString * _Nullable failReason)
         {
             NSMutableDictionary *dict = [NSMutableDictionary dictionary];
             dict[@"success"] = @(success);
             dict[@"error"] = failReason ?: [NSNull null];
             dict[@"labelText"] = labelText;
             dict[@"inputText"] = inputText;
             
             if (!success && failReason) {
                 dict[@"details"] = [NSString stringWithFormat:@"Setting text operation failed: %@", failReason];
             } else {
                 dict[@"details"] = [NSString stringWithFormat:@"Setting text operation succeeded for label '%@'", labelText];
             }
             
             [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:success
                                             jsonDict:dict];
         }];
    });
}

+ (void)handleAsyncSetTextClassRequest:(NSString *)path
                          withBBEventClass:(Class)bbEvent
                                requestID:(NSNumber *)requestID
{
    // 1) Parse query string
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *className = params[@"className"] ?: @"";
    NSString *inputText = params[@"input"] ?: @"";
    BOOL exactMatch = [params[@"exactMatch"] boolValue];

    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;

    // parse stopLabels if provided (comma-separated)
    NSString *stopLabelsStr = params[@"stopLabels"];
    NSArray<NSString *> *stopLabels = @[];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // 2) Dispatch to main queue so we can call Swift
    dispatch_async(dispatch_get_main_queue(), ^{
        // Ensure BBEvent has the new method
        SEL sel = @selector(asyncSetTextByClassName:className:exactMatch:stopLabels:timeout:interval:completion:);
        if (![bbEvent respondsToSelector:sel]) {
            NSString *err = @"BBEvent.asyncSetTextByClassName not found";
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                             jsonDict:@{@"success":@NO,
                                                        @"error": err}];
            return;
        }

        // 3) Cast it to a function pointer so we can invoke
        void (*func)(id, SEL,
                 NSString*, NSString*, BOOL, NSArray*, int, int,
                 void(^)(BOOL, NSString*)) 
        = (void*)[bbEvent methodForSelector:sel];

        // 4) Call your Swift method
        func(bbEvent, sel,
             inputText,
             className,
             exactMatch,
             stopLabels,
             timeoutMs,
             intervalMs,
             ^(BOOL success, NSString *failReason) {
             // 5) Build JSON response
             NSMutableDictionary *dict = [NSMutableDictionary dictionary];
             dict[@"success"] = @(success);
             dict[@"error"] = failReason ?: [NSNull null];
             dict[@"className"] = className;
             dict[@"inputText"] = inputText;

             if (success) {
                 dict[@"details"] = [NSString stringWithFormat:@"Set text on first %@", className];
             } else {
                 dict[@"details"] = [NSString stringWithFormat:@"Failed to set text: %@", failReason];
             }

             [self finishAsyncJsonResponseWithRequestID:requestID
                                               didSucceed:success
                                                 jsonDict:dict];
         }
        );
    });
}

+ (NSString *)handleViewHierarchyRequest {
    NSArray<UIWindow *> *allWindows = [UIApplication sharedApplication].windows;
    if (!allWindows.count) {
        return [self errorResponse:@"No UIWindows found!"];
    }

    NSMutableString *result = [NSMutableString string];
    [result appendFormat:@"Found %lu windows:\n", (unsigned long)allWindows.count];

    NSUInteger idx = 0;
    for (UIWindow *win in allWindows) {
        [result appendFormat:@"\n=== Window %lu ===\n", (unsigned long)idx];
        [result appendFormat:@"Class: %@\n", NSStringFromClass([win class])];
        [result appendFormat:@"IsKeyWindow: %@\n", (win.isKeyWindow ? @"YES" : @"NO")];
        [result appendFormat:@"Hidden: %@, Alpha=%.2f\n", (win.isHidden ? @"YES" : @"NO"), win.alpha];
        [result appendFormat:@"WindowLevel: %f\n", win.windowLevel];

        // Try to get its recursiveDescription
        @try {
            NSString *desc = [win performSelector:@selector(recursiveDescription)];
            [result appendString:desc];
        }
        @catch (NSException *ex) {
            [result appendFormat:@"(Error retrieving recursiveDescription: %@)\n", ex.reason];
        }
        idx++;
    }

    return [self okResponse:result];
}

+ (void)handleAsyncSetTextInCellRequest:(NSString *)path
                          withBBEventClass:(Class)bbEvent
                                 requestID:(NSNumber *)requestID
{
    // 1) Parse query parameters
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *searchText = params[@"text"] ?: @"";  // Updated param name from 'label' to 'text'
    NSString *inputText = params[@"input"] ?: @"";
    BOOL exactMatch = [params[@"exactMatch"] boolValue];
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;

    // parse stopLabels if provided
    NSArray<NSString *> *stopLabels = @[];
    NSString *stopLabelsStr = params[@"stopLabels"];
    if (stopLabelsStr.length) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // 2) Dispatch main queue so we can call Swift method
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL sel = NSSelectorFromString(@"asyncSetTextInCellWithText:inputText:exactMatch:stopLabels:timeout:interval:completion:");
        if ([bbEvent respondsToSelector:sel]) {
            void (*func)(id, SEL, NSString*, NSString*, BOOL, NSArray*, int, int, void(^)(BOOL, NSString*)) 
                = (void*)[bbEvent methodForSelector:sel];

            func(bbEvent, sel, searchText, inputText, exactMatch, stopLabels, timeoutMs, intervalMs,
                 ^(BOOL success, NSString *failReason) {
                     NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                     dict[@"success"] = @(success);
                     dict[@"error"] = failReason ?: [NSNull null];
                     dict[@"searchText"] = searchText;
                     dict[@"inputText"] = inputText;
                     
                     if (!success && failReason) {
                         dict[@"details"] = [NSString stringWithFormat:@"Setting text in cell operation failed: %@", failReason];
                     } else {
                         dict[@"details"] = [NSString stringWithFormat:@"Setting text in cell operation succeeded for cell with text '%@'", searchText];
                     }
                     
                     [self finishAsyncJsonResponseWithRequestID:requestID
                                                   didSucceed:success
                                                     jsonDict:dict];
                 });
        } else {
            NSLog(@"[UiShi] BBEvent missing asyncSetTextInCellWithText method?");
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            dict[@"success"] = @(NO);
            dict[@"error"] = @"Method not found in BBEvent";
            dict[@"details"] = @"Setting text in cell operation failed: BBEvent method not found";
            [self finishAsyncJsonResponseWithRequestID:requestID
                                          didSucceed:NO
                                            jsonDict:dict];
        }
    });
}

+ (NSString *)handleHasElementRequest:(NSString *)path
                    withBBEventClass:(Class)bbEvent
{
    // 1) Parse query params
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *label = params[@"label"] ?: @"";  
    BOOL exactMatch = [params[@"exactMatch"] boolValue];

    // 2) Construct an NSDictionary that matches your new advanced fields
    NSMutableDictionary *attrDict = [NSMutableDictionary dictionary];
    if (label.length > 0) {
        attrDict[@"text"] = label;
    }
    attrDict[@"exactTextMatch"] = @(exactMatch);

    // 3) Confirm we have the new hasElement: method
    SEL sel = @selector(hasElement:);
    if (![bbEvent respondsToSelector:sel]) {
        return [self errorResponse:@"BBEvent does not implement hasElement:"];
    }

    // 4) Dynamically invoke hasElement: with the dictionary
    BOOL found = NO;
    NSMethodSignature *sig = [bbEvent methodSignatureForSelector:sel];
    if (sig) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:bbEvent];
        
        // The hasElement(_ attrDict:) method takes an NSDictionary as the single argument
        NSDictionary *dictArg = [attrDict copy];
        [inv setArgument:&dictArg atIndex:2]; // arguments start at index 2

        [inv invoke];

        // Now extract the BOOL return value
        [inv getReturnValue:&found];
    }

    // 5) Build response
    NSString *body = found ? @"true\n" : @"false\n";
    return [self okResponse:body];
}

// Add whoami handler
+ (NSString *)handleWhoAmIRequest {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)";
    NSString *procName = [[NSProcessInfo processInfo] processName] ?: @"(unknown)";

    NSString *json = [NSString stringWithFormat:
                      @"{\"bundle_id\":\"%@\",\"process_name\":\"%@\",\"port\":%lu}",
        bundleID, procName, (unsigned long)s_boundPort
    ];

    NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"\r\n"
        @"%@",
            (unsigned long)[json lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
            json];
    return resp;
}

+ (void)handleAsyncClickAdvancedRequest:(NSString *)path
                       withBBEventClass:(Class)bbEvent
                              requestID:(NSNumber *)requestID
{
    NSDictionary *params = [self queryParamsFromPath:path];

    // Extract all relevant params
    NSString *className   = params[@"className"];   // optional
    NSString *text        = params[@"text"];        // optional
    BOOL exactTextMatch   = [params[@"exactTextMatch"] boolValue];
    BOOL caseInsensitive  = [params[@"caseInsensitive"] boolValue];
    int instanceIndex     = params[@"instanceIndex"] ? [params[@"instanceIndex"] intValue] : 0;

    NSString *tintRaw     = params[@"checkTint"];   // e.g. "0.0,0.58,0.96,1"
    CGFloat widthVal      = params[@"checkWidth"] ? [params[@"checkWidth"] floatValue] : 0;
    CGFloat heightVal     = params[@"checkHeight"] ? [params[@"checkHeight"] floatValue] : 0;

    // Parse timeout, interval, maxReclicks
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;
    int maxReclicks = params[@"maxReclicks"] ? [params[@"maxReclicks"] intValue] : 0;

    // Build stopLabels array
    NSArray<NSString *> *stopLabels = @[];
    NSString *stopLabelsStr = params[@"stopLabels"];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // Build attributes dictionary
    NSMutableDictionary *attrDict = [NSMutableDictionary dictionary];
    if (className) attrDict[@"className"] = className;
    if (text)      attrDict[@"text"] = text;
    attrDict[@"exactTextMatch"] = @(exactTextMatch);
    attrDict[@"textCaseInsensitive"] = @(caseInsensitive);
    attrDict[@"instanceIndex"] = @(instanceIndex);

    if (tintRaw.length) {
        NSArray *rgba = [tintRaw componentsSeparatedByString:@","];
        if (rgba.count == 4) {
            CGFloat r = [rgba[0] floatValue];
            CGFloat g = [rgba[1] floatValue];
            CGFloat b = [rgba[2] floatValue];
            CGFloat a = [rgba[3] floatValue];
            attrDict[@"tintColor"] = @[ @(r), @(g), @(b), @(a) ];
        }
    }
    if (widthVal > 0)  attrDict[@"width"]  = @(widthVal);
    if (heightVal > 0) attrDict[@"height"] = @(heightVal);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Try the new method with instanceIndex first
        SEL advSelWithIndex = NSSelectorFromString(@"asyncClickAdvancedDict:stopLabels:timeoutMs:intervalMs:maxReclicks:instanceIndex:completion:");
        if ([bbEvent respondsToSelector:advSelWithIndex]) {
            void (*funcWithIndex)(id, SEL,
                NSDictionary*, NSArray*, int, int, int, int,
                void(^)(BOOL, NSInteger, NSString*)) 
                = (void*)[bbEvent methodForSelector:advSelWithIndex];

            funcWithIndex(bbEvent, advSelWithIndex, attrDict, stopLabels, timeoutMs, intervalMs, maxReclicks, instanceIndex,
                ^(BOOL success, NSInteger reclickCount, NSString *failReason) {
                    NSMutableDictionary *json = [NSMutableDictionary dictionary];
                    json[@"success"] = @(success);
                    json[@"error"] = failReason ?: [NSNull null];
                    json[@"reclickCount"] = @(reclickCount);
                    json[@"instanceIndex"] = @(instanceIndex);
                    
                    if (!success && failReason) {
                        json[@"details"] = [NSString stringWithFormat:@"Click operation failed: %@", failReason];
                    } else {
                        json[@"details"] = [NSString stringWithFormat:@"Click operation succeeded with %ld re-clicks", (long)reclickCount];
                    }

                    [self finishAsyncJsonResponseWithRequestID:requestID
                                                  didSucceed:success
                                                    jsonDict:json];
                }
            );
        } else {
            // Fallback to old method if instanceIndex not supported
            SEL advSel = NSSelectorFromString(@"asyncClickAdvanced:stopLabels:timeoutMs:intervalMs:maxReclicks:completion:");
            if ([bbEvent respondsToSelector:advSel]) {
                void (*func)(id, SEL,
                    NSDictionary*, NSArray*, int, int, int,
                    void(^)(BOOL, NSInteger, NSString*)) 
                    = (void*)[bbEvent methodForSelector:advSel];

                func(bbEvent, advSel, attrDict, stopLabels, timeoutMs, intervalMs, maxReclicks,
                    ^(BOOL success, NSInteger reclickCount, NSString *failReason) {
                        NSMutableDictionary *json = [NSMutableDictionary dictionary];
                        json[@"success"] = @(success);
                        json[@"error"] = failReason ?: [NSNull null];
                        json[@"reclickCount"] = @(reclickCount);
                        json[@"note"] = @"InstanceIndex param was ignored (legacy code path)";
                        [self finishAsyncJsonResponseWithRequestID:requestID
                                                      didSucceed:success
                                                        jsonDict:json];
                    }
                );
            } else {
                NSString *errResp = [self errorResponse:@"BBEvent does not implement advanced selector"];
                [self writeResponse:errResp toRequestID:requestID closeWhenDone:YES];
            }
        }
    });
}

+ (void)handleHasElementAdvancedRequest:(NSString *)path
                       withBBEventClass:(Class)bbEvent
                              requestID:(NSNumber *)requestID
{
    NSDictionary *params = [self queryParamsFromPath:path];

    // Extract parameters similar to asyncClickAdvanced
    NSString *className   = params[@"className"];   // optional
    NSString *text        = params[@"text"];        // optional
    BOOL exactTextMatch   = [params[@"exactTextMatch"] boolValue];
    BOOL caseInsensitive  = [params[@"caseInsensitive"] boolValue];
    NSString *tintRaw     = params[@"checkTint"];   // e.g. "0.0,0.584314,0.964706,1"
    CGFloat widthVal      = params[@"checkWidth"] ? [params[@"checkWidth"] floatValue] : 0;
    CGFloat heightVal     = params[@"checkHeight"] ? [params[@"checkHeight"] floatValue] : 0;

    // Timeout + interval
    int timeoutMs = params[@"timeout"] ? [params[@"timeout"] intValue] : 5000;
    int intervalMs = params[@"interval"] ? [params[@"interval"] intValue] : 500;

    // stopLabels
    NSString *stopLabelsStr = params[@"stopLabels"];
    NSArray<NSString *> *stopLabels = @[];
    if (stopLabelsStr.length > 0) {
        stopLabels = [stopLabelsStr componentsSeparatedByString:@","];
    }

    // Build attributes dictionary
    NSMutableDictionary *attrDict = [NSMutableDictionary dictionary];
    if (className) attrDict[@"className"] = className;
    if (text)      attrDict[@"text"] = text;
    attrDict[@"exactTextMatch"] = @(exactTextMatch);
    attrDict[@"textCaseInsensitive"] = @(caseInsensitive);

    if (tintRaw.length) {
        NSArray *rgba = [tintRaw componentsSeparatedByString:@","];
        if (rgba.count == 4) {
            CGFloat r = [rgba[0] floatValue];
            CGFloat g = [rgba[1] floatValue];
            CGFloat b = [rgba[2] floatValue];
            CGFloat a = [rgba[3] floatValue];
            attrDict[@"tintColor"] = @[ @(r), @(g), @(b), @(a) ];
        }
    }
    if (widthVal > 0)  attrDict[@"width"]  = @(widthVal);
    if (heightVal > 0) attrDict[@"height"] = @(heightVal);

    // Dispatch to main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL sel = NSSelectorFromString(@"asyncHasElementAdvanced:stopLabels:timeoutMs:intervalMs:completion:");
        if ([bbEvent respondsToSelector:sel]) {
            // Cast the method to a function pointer
            void (*func)(id, SEL,
                         NSDictionary*, NSArray*, int, int,
                         void(^)(BOOL, NSString*)) 
                = (void*)[bbEvent methodForSelector:sel];

            func(bbEvent, sel, attrDict, stopLabels, timeoutMs, intervalMs,
                 ^(BOOL found, NSString *failReason) {
                     NSMutableDictionary *json = [NSMutableDictionary dictionary];
                     json[@"success"] = @(found);
                     if (failReason) {
                         json[@"error"] = failReason;
                     } else {
                         json[@"error"] = [NSNull null];
                     }

                     [self finishAsyncJsonResponseWithRequestID:requestID
                                                     didSucceed:found
                                                       jsonDict:json];
                 }
            );
        } else {
            NSString *errResp = [self errorResponse:@"BBEvent does not implement asyncHasElementAdvanced!"];
            [self writeResponse:errResp toRequestID:requestID closeWhenDone:YES];
        }
    });
}

#pragma mark - Pasteboard Handler

+ (void)handlePasteboardRequest:(NSString *)path requestID:(NSNumber *)requestID
{
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *op = params[@"op"] ?: @"read";  // default to read if not specified
    NSString *content = params[@"content"] ?: @""; // for op=write

    // We'll do everything on the main thread to be consistent with UI/pasteboard access:
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *json = [NSMutableDictionary dictionary];
        BOOL success = YES;
        NSString *failReason = nil;

        @try {
            UIPasteboard *pb = [UIPasteboard generalPasteboard];

            if ([op.lowercaseString isEqualToString:@"write"]) {
                // Write operation
                pb.string = content;
                [json setObject:@"Wrote new content to pasteboard" forKey:@"details"];
                [json setObject:pb.string ?: @"" forKey:@"pasteboard"];
            } else {
                // Default: read operation
                NSString *current = pb.string ?: @"";
                [json setObject:@"Read pasteboard content successfully" forKey:@"details"];
                [json setObject:current forKey:@"pasteboard"];
            }
        }
        @catch (NSException *ex) {
            success = NO;
            failReason = [NSString stringWithFormat:@"Exception: %@", ex.reason ?: @"Unknown"];
        }

        // success/fail
        [json setObject:@(success) forKey:@"success"];
        [json setObject:success ? [NSNull null] : failReason forKey:@"error"];

        // Return JSON
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:success
                                         jsonDict:json];
    });
}

#pragma mark - Delete App Handler

+ (void)handleDeleteAppRequest:(NSString *)path
                    requestID:(NSNumber *)requestID
{
    // You generally only want to do this in SpringBoard
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
           @"success": @NO,
           @"error": @"Not running inside SpringBoard process; cannot uninstall apps."
        }];
        return;
    }

    // Parse query params to get ?bundleID=com.foo.bar
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *bundleID = params[@"bundleID"];
    if (!bundleID.length) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
           @"success": @NO,
           @"error": @"Missing 'bundleID' parameter"
        }];
        return;
    }

    NSLog(@"[UiShi] Attempting to uninstall app with bundleID=%@", bundleID);

    // Get the shared SBApplicationController instance
    Class sbAppControllerClass = NSClassFromString(@"SBApplicationController");
    if (!sbAppControllerClass) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"SBApplicationController class not found"
        }];
        return;
    }

    SBApplicationController *appController = [sbAppControllerClass sharedInstanceIfExists];
    if (!appController) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"SBApplicationController not available"
        }];
        return;
    }

    // Fire off the uninstall request but do not wait around
    [appController requestUninstallApplicationWithBundleIdentifier:bundleID
                                                         options:0
                                                  withCompletion:nil];
    // Immediately return success to the client
    [self finishAsyncJsonResponseWithRequestID:requestID
                                   didSucceed:YES
                                     jsonDict:@{
        @"success": @YES,
        @"details": [NSString stringWithFormat:
             @"Uninstall request triggered for %@", bundleID]
    }];
}

#pragma mark - Download Image Handler

+ (void)handleDownloadImageRequest:(NSString *)path requestID:(NSNumber *)requestID
{
    // Parse query params to get ?url=...
    NSDictionary *params = [self queryParamsFromPath:path];
    NSString *urlString = params[@"url"];
    if (!urlString.length) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"Missing 'url' parameter"
        }];
        return;
    }

    // Validate URL
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": @"Invalid URL format"
        }];
        return;
    }

    NSLog(@"[UiShi] Attempting to download image from URL: %@", urlString);

    // Create download task
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url 
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                             jsonDict:@{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription]
            }];
            return;
        }

        // Validate response
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                             jsonDict:@{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"HTTP error: %ld", (long)httpResponse.statusCode]
            }];
            return;
        }

        // Create image from data
        UIImage *image = [UIImage imageWithData:data];
        if (!image) {
            [self finishAsyncJsonResponseWithRequestID:requestID
                                           didSucceed:NO
                                             jsonDict:@{
                @"success": @NO,
                @"error": @"Downloaded data is not a valid image"
            }];
            return;
        }

        // Save to camera roll on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageWriteToSavedPhotosAlbum(image, 
                                         (id)self, 
                                         @selector(image:didFinishSavingWithError:contextInfo:), 
                                         (__bridge_retained void *)requestID);
        });
    }];

    [task resume];
}

// Callback for UIImageWriteToSavedPhotosAlbum
+ (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    NSNumber *requestID = (__bridge_transfer NSNumber *)contextInfo;
    
    if (error) {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:NO
                                         jsonDict:@{
            @"success": @NO,
            @"error": [NSString stringWithFormat:@"Failed to save to camera roll: %@", error.localizedDescription]
        }];
    } else {
        [self finishAsyncJsonResponseWithRequestID:requestID
                                       didSucceed:YES
                                         jsonDict:@{
            @"success": @YES,
            @"details": @"Image successfully downloaded and saved to camera roll"
        }];
    }
}

@end
