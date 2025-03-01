#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "HTTPServer.h"

// Debug logging macro
#ifdef DEBUG
    #define HBLogDebug(fmt, ...) NSLog((@"[UiShi] " fmt), ##__VA_ARGS__)
#else
    #define HBLogDebug(fmt, ...)
#endif

#define HBLog(fmt, ...) NSLog((@"[UiShi] " fmt), ##__VA_ARGS__)
#define SWIFT_BB_EVENT @"HandleURLScheme.BBEvent"

// Port mapping for different apps
static NSDictionary<NSString*, NSNumber*> *s_portMapping;

// Forward declare BBEvent class and its methods
@interface BBEvent : NSObject
+ (void)startSwift:(UIApplication *)application;
@end

%ctor {
    // Initialize port mapping
    s_portMapping = @{
        @"com.burbn.instagram": @(7777),
        @"com.nssurge.inc.surge-ios": @(8888),
        @"com.apple.springboard": @(9999)
    };

    HBLog(@"constructor: Setting up environment + starting HTTP server");
    
    // Get bundle ID and determine port
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    HBLog(@"App bundleID detected: %@", bundleID);
    
    // Decide which port to use
    NSNumber *portNum = [s_portMapping objectForKey:bundleID];
    NSUInteger chosenPort = 0;
    if (portNum) {
        chosenPort = portNum.unsignedIntegerValue;
        HBLog(@"Found custom port mapping for %@ => %lu", bundleID, (unsigned long)chosenPort);
    } else {
        // Fallback to 8080 if not in dictionary
        chosenPort = 8080;
        HBLog(@"No custom port for %@; defaulting to %lu", bundleID, (unsigned long)chosenPort);
    }

    // Start server on chosen port
    [HTTPServer startServerOnPort:chosenPort];
    
    // Always use rootful paths
    NSString *frameworksPath = @"/Library/Frameworks";
    NSString *swiftPath = @"/usr/lib/swift";
    NSString *dylibPath = @"/Library/MobileSubstrate/DynamicLibraries/libHandleURLScheme.dylib";
    
    setenv("DYLD_FRAMEWORK_PATH", [frameworksPath UTF8String], 1);
    setenv("DYLD_LIBRARY_PATH", [swiftPath UTF8String], 1);
    
    HBLogDebug(@"Environment variables set: DYLD_FRAMEWORK_PATH=%s, DYLD_LIBRARY_PATH=%s", 
        getenv("DYLD_FRAMEWORK_PATH"), getenv("DYLD_LIBRARY_PATH"));
    
    HBLog(@"Attempting to dlopen libHandleURLScheme");
    void *handle = dlopen([dylibPath UTF8String], RTLD_NOW);
    
    if (!handle) {
        HBLog(@"Primary dlopen failed: %s", dlerror());
        // Try alternate path
        handle = dlopen("@rpath/libHandleURLScheme.dylib", RTLD_NOW);
        if (!handle) {
            HBLog(@"Fallback dlopen also failed: %s", dlerror());
            return;
        }
    }
    
    HBLog(@"Successfully loaded libHandleURLScheme!");
    HBLogDebug(@"Library handle: %p", handle);
}

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    HBLog(@"Inside didFinishLaunching hook!");
    
    Class BBEvent = NSClassFromString(SWIFT_BB_EVENT);
    if (BBEvent && [BBEvent respondsToSelector:@selector(startSwift:)]) {
        HBLog(@"Calling [BBEvent startSwift:]");
        [BBEvent startSwift:application];
        HBLogDebug(@"BBEvent startSwift: called successfully");
    } else {
        HBLog(@"Warning: BBEvent class or startSwift: method not found");
        HBLogDebug(@"BBEvent class exists: %d, responds to startSwift: %d", 
            (BBEvent != nil), 
            (BBEvent ? [BBEvent respondsToSelector:@selector(startSwift:)] : NO));
    }

    return %orig(application, options);
}

%end 