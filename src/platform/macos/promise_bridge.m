#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Block.h>

typedef void (*zigui_promise_reader_callback)(void *context, NSURL *url, NSError *error);
typedef void (*zigui_promise_context_retain)(void *context);
typedef void (*zigui_promise_context_release)(void *context);

@interface ZigUIPromiseContextOwner : NSObject
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) zigui_promise_context_release releaseContext;
@end

@implementation ZigUIPromiseContextOwner
- (void)dealloc {
    if (self.releaseContext != NULL) self.releaseContext(self.context);
    [super dealloc];
}
@end

void *zigui_promise_make_reader(void *context,
                                zigui_promise_reader_callback callback,
                                zigui_promise_context_retain retain_context,
                                zigui_promise_context_release release_context) {
    if (context == NULL || callback == NULL || retain_context == NULL || release_context == NULL) return NULL;
    retain_context(context);
    ZigUIPromiseContextOwner *owner = [[ZigUIPromiseContextOwner alloc] init];
    if (owner == nil) {
        release_context(context);
        return NULL;
    }
    owner.context = context;
    owner.releaseContext = release_context;
    void (^reader)(NSURL *, NSError *) = ^(NSURL *url, NSError *error) {
        callback(owner.context, url, error);
    };
    void *copied = Block_copy(reader);
    [owner release];
    return copied;
}

void zigui_promise_release_reader(void *reader) {
    if (reader != NULL) Block_release(reader);
}

void zigui_promise_receive(NSFilePromiseReceiver *receiver, NSURL *destination, NSOperationQueue *queue, void *reader) {
    [receiver receivePromisedFilesAtDestination:destination
                                        options:@{}
                                  operationQueue:queue
                                          reader:(void (^)(NSURL *, NSError *))reader];
}

// Kept private to the framework's macOS conformance target.  Calling a
// retained reader through its real Objective-C block type makes the ABI test
// exercise the same representation passed to NSFilePromiseReceiver; no block
// or Foundation object is exposed through ZigUI's public API.
void zigui_promise_test_invoke_reader(void *reader) {
    if (reader == nil) return;
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/zigui-promised-file"];
    ((void (^)(NSURL *, NSError *))reader)(url, nil);
}

void zigui_promise_test_invoke_failure(void *reader) {
    if (reader == nil) return;
    NSError *error = [NSError errorWithDomain:@"ZigUI.PromiseTest" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"synthetic promised-file failure",
    }];
    ((void (^)(NSURL *, NSError *))reader)(nil, error);
}
