#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <LinkPresentation/LinkPresentation.h>

#include <stddef.h>
#include <stdint.h>
#include <dispatch/dispatch.h>

typedef void (*zigui_page_capture_callback)(
    void *context,
    const uint8_t *bytes,
    size_t bytes_length,
    size_t width,
    size_t height,
    const char *error_description);
typedef void (*zigui_page_capture_context_retain)(void *context);
typedef void (*zigui_page_capture_context_release)(void *context);

@class ZigUIPageCaptureOperation;

@interface ZigUIPageCaptureCallbackOwner : NSObject {
    ZigUIPageCaptureOperation *_operation;
}
- (instancetype)initWithOperation:(ZigUIPageCaptureOperation *)operation;
- (void)setOperation:(ZigUIPageCaptureOperation *)operation;
- (void)metadata:(LPLinkMetadata *)metadata error:(NSError *)error;
@end

@interface ZigUIPageCaptureOperation : NSObject {
    void *_callbackContext;
    zigui_page_capture_callback _callback;
    zigui_page_capture_context_retain _retainContext;
    zigui_page_capture_context_release _releaseContext;
    double _width;
    double _height;
    double _timeout;
    NSString *_urlString;
    LPMetadataProvider *_provider;
    NSOperationQueue *_privateQueue;
    ZigUIPageCaptureCallbackOwner *_owner;
    BOOL _cancelled;
    BOOL _completed;
}
- (instancetype)initWithWidth:(double)width
                         height:(double)height
                        timeout:(double)timeout
                        context:(void *)context
                       callback:(zigui_page_capture_callback)callback
                 retainContext:(zigui_page_capture_context_retain)retainContext
                releaseContext:(zigui_page_capture_context_release)releaseContext;
- (void)start;
- (void)setURLString:(NSString *)urlString;
- (void)cancelAndDrain;
- (void)startProvider;
- (void)receiveMetadata:(LPLinkMetadata *)metadata error:(NSError *)error;
- (void)renderMetadata:(LPLinkMetadata *)metadata;
- (void)detachProvider;
@end

static const char *zigui_page_capture_error_string(NSError *error) {
    if (error == nil) return "The page could not be captured.";
    NSString *description = [error localizedDescription];
    const char *value = [description UTF8String];
    return value != NULL && value[0] != '\0' ? value : "The page could not be captured.";
}

@implementation ZigUIPageCaptureCallbackOwner

- (instancetype)initWithOperation:(ZigUIPageCaptureOperation *)operation {
    self = [super init];
    if (self != nil) _operation = [operation retain];
    return self;
}

- (void)setOperation:(ZigUIPageCaptureOperation *)operation {
    @synchronized(self) {
        if (_operation == operation) return;
        [_operation release];
        _operation = [operation retain];
    }
}

- (void)metadata:(LPLinkMetadata *)metadata error:(NSError *)error {
    ZigUIPageCaptureOperation *operation = nil;
    @synchronized(self) {
        operation = [_operation retain];
    }
    if (operation != nil) {
        [operation receiveMetadata:metadata error:error];
        [operation release];
    }
}

- (void)dealloc {
    @synchronized(self) {
        [_operation release];
        _operation = nil;
    }
    [super dealloc];
}

@end

@implementation ZigUIPageCaptureOperation

- (instancetype)initWithWidth:(double)width
                         height:(double)height
                        timeout:(double)timeout
                        context:(void *)context
                       callback:(zigui_page_capture_callback)callback
                 retainContext:(zigui_page_capture_context_retain)retainContext
                releaseContext:(zigui_page_capture_context_release)releaseContext {
    self = [super init];
    if (self == nil) return nil;
    if (context == NULL || callback == NULL || retainContext == NULL || releaseContext == NULL) {
        [self release];
        return nil;
    }
    _callbackContext = context;
    _callback = callback;
    _retainContext = retainContext;
    _releaseContext = releaseContext;
    _retainContext(_callbackContext);
    _width = width;
    _height = height;
    _timeout = timeout;
    _privateQueue = [[NSOperationQueue alloc] init];
    if (_privateQueue == nil) {
        _releaseContext(_callbackContext);
        _callbackContext = NULL;
        [self release];
        return nil;
    }
    [_privateQueue setMaxConcurrentOperationCount:1];
    _owner = [[ZigUIPageCaptureCallbackOwner alloc] initWithOperation:self];
    if (_owner == nil) {
        [_privateQueue release];
        _privateQueue = nil;
        _releaseContext(_callbackContext);
        _callbackContext = NULL;
        [self release];
        return nil;
    }
    return self;
}

- (void)startProvider {
    @autoreleasepool {
        LPMetadataProvider *provider = [[LPMetadataProvider alloc] init];
        if (provider == nil) {
            [self receiveMetadata:nil error:nil];
            return;
        }
        [provider setShouldFetchSubresources:YES];
        [provider setTimeout:_timeout];
        ZigUIPageCaptureCallbackOwner *owner = nil;
        @synchronized(self) {
            if (!_cancelled && !_completed && _provider == nil) {
                _provider = provider;
                owner = [_owner retain];
            }
        }
        if (owner == nil) {
            [provider cancel];
            [provider release];
            return;
        }
        NSURL *url = [NSURL URLWithString:_urlString];
        if (url == nil) {
            [owner release];
            [self receiveMetadata:nil error:nil];
            return;
        }
        void (^completion)(LPLinkMetadata *, NSError *) = ^(LPLinkMetadata *metadata, NSError *error) {
            [owner metadata:metadata error:error];
        };
        [provider startFetchingMetadataForURL:url completionHandler:completion];
        [owner release];
    }
}

- (void)start {
    ZigUIPageCaptureOperation *operation = [self retain];
    [_privateQueue addOperationWithBlock:^{
        [operation startProvider];
        [operation release];
    }];
}

- (void)setURLString:(NSString *)urlString {
    [_urlString release];
    _urlString = [urlString retain];
}

- (void)receiveMetadata:(LPLinkMetadata *)metadata error:(NSError *)error {
    @synchronized(self) {
        if (_cancelled || _completed) return;
        _completed = YES;
    }

    LPLinkMetadata *retainedMetadata = [metadata retain];
    NSString *message = nil;
    if (metadata == nil) message = [[NSString alloc] initWithUTF8String:zigui_page_capture_error_string(error)];
    [self detachProvider];

    ZigUIPageCaptureOperation *operation = [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (retainedMetadata == nil) {
            const char *description = [message UTF8String];
            _callback(_callbackContext, NULL, 0, 0, 0, description);
        } else {
            [operation renderMetadata:retainedMetadata];
        }
        [retainedMetadata release];
        [message release];
        [operation release];
    });
}

- (void)renderMetadata:(LPLinkMetadata *)metadata {
    @autoreleasepool {
        @synchronized(self) {
            if (_cancelled) return;
        }
        LPLinkView *view = [[LPLinkView alloc] initWithMetadata:metadata];
        if (view == nil) {
            _callback(_callbackContext, NULL, 0, 0, 0, "LinkPresentation could not render the link metadata.");
            return;
        }
        [view setFrame:NSMakeRect(0.0, 0.0, _width, _height)];
        [view setWantsLayer:YES];
        [view layoutSubtreeIfNeeded];
        NSRect bounds = [view bounds];
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:bounds];
        if (bitmap == nil) {
            [view release];
            _callback(_callbackContext, NULL, 0, 0, 0, "AppKit could not allocate the native link preview bitmap.");
            return;
        }
        [view cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (png == nil || [png length] == 0) {
            [view release];
            _callback(_callbackContext, NULL, 0, 0, 0, "AppKit could not encode the native link preview as PNG.");
            return;
        }
        _callback(
            _callbackContext,
            (const uint8_t *)[png bytes],
            [png length],
            (size_t)[bitmap pixelsWide],
            (size_t)[bitmap pixelsHigh],
            NULL);
        [view release];
    }
}

- (void)detachProvider {
    ZigUIPageCaptureCallbackOwner *owner = nil;
    LPMetadataProvider *provider = nil;
    @synchronized(self) {
        owner = _owner;
        _owner = nil;
        provider = _provider;
        _provider = nil;
    }
    [owner setOperation:nil];
    [owner release];
    [provider cancel];
    [provider release];
}

- (void)cancelAndDrain {
    @synchronized(self) {
        _cancelled = YES;
    }
    LPMetadataProvider *provider = nil;
    @synchronized(self) {
        provider = [_provider retain];
    }
    [provider cancel];
    [provider release];
    [_privateQueue cancelAllOperations];
    [_privateQueue waitUntilAllOperationsAreFinished];
    [self detachProvider];
}

- (void)dealloc {
    [self cancelAndDrain];
    [_privateQueue release];
    [_urlString release];
    if (_callbackContext != NULL) {
        _releaseContext(_callbackContext);
        _callbackContext = NULL;
    }
    [super dealloc];
}

@end

void *zigui_page_capture_start(
    const uint8_t *url,
    size_t url_length,
    double width,
    double height,
    double timeout_seconds,
    void *context,
    zigui_page_capture_callback callback,
    zigui_page_capture_context_retain retain_context,
    zigui_page_capture_context_release release_context) {
    if (url == NULL || url_length == 0) return NULL;
    NSString *urlString = [[NSString alloc] initWithBytes:url length:url_length encoding:NSUTF8StringEncoding];
    if (urlString == nil) return NULL;
    ZigUIPageCaptureOperation *operation = [[ZigUIPageCaptureOperation alloc]
        initWithWidth:width
               height:height
              timeout:timeout_seconds
              context:context
             callback:callback
       retainContext:retain_context
      releaseContext:release_context];
    if (operation == nil) {
        [urlString release];
        return NULL;
    }
    [operation setURLString:urlString];
    [urlString release];
    [operation start];
    return operation;
}

void zigui_page_capture_cancel(void *native) {
    if (native != NULL) [(ZigUIPageCaptureOperation *)native cancelAndDrain];
}

void zigui_page_capture_destroy(void *native) {
    if (native != NULL) [(ZigUIPageCaptureOperation *)native release];
}
