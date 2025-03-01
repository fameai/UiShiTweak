//  HTTPServer.h
//  UiShi Tweak
//  Extended CFNetwork-based HTTP server for local API
//  Provides multiple endpoints for bridging to Swift BBEvent methods.
//  For example:
//     GET /tap?label=My+Button
//     GET /slide?startX=10&startY=200&endX=300&endY=200&duration=0.8
//     GET /text?input=Hello%20World
//     GET /waitHittable?label=Submit&timeout=5
//     GET /asyncClick?label=Log+In&timeout=5000&interval=500&stopLabels=Error,Cancel
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Request tracking struct
typedef struct {
    CFSocketNativeHandle clientSocket;
    CFReadStreamRef _Nullable readStream;
    CFWriteStreamRef _Nullable writeStream;
    BOOL requestInProgress;
    int requestID;
} PendingRequestContext;

NS_ASSUME_NONNULL_BEGIN

@interface HTTPServer : NSObject

/**
 Starts a simple HTTP server on the specified port.
 
 After starting, you can send GET requests like:
   http://127.0.0.1:8080/tap?label=Create%20new%20account
   http://127.0.0.1:8080/slide?startX=10&startY=200&endX=300&endY=200&duration=0.8
   http://127.0.0.1:8080/text?input=Hello%20World
   ... etc.
 
 @param port The TCP port to listen on, e.g. 8080
 */
+ (void)startServerOnPort:(NSUInteger)port;

// New methods for async support
+ (void)writeResponse:(NSString *)response 
          toRequestID:(NSNumber *)requestID 
        closeWhenDone:(BOOL)shouldClose;

+ (void)finishAsyncJsonResponseWithRequestID:(NSNumber *)requestID
                                 didSucceed:(BOOL)didSucceed
                                   jsonDict:(NSDictionary *)dict;

@end

NS_ASSUME_NONNULL_END
