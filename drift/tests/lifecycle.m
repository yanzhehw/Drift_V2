#import "DriftV2ScreenSaverView.h"
#import "drift_v2_screensaver.h"
#import <QuartzCore/CAMetalLayer.h>

// Compile the real view against a recording engine. This exercises AppKit's
// lifecycle and geometry callbacks without requiring a display/GPU transition.
struct DriftHandle { uint32_t width, height; void *view; };
static DriftHandle *activeHandle;
static NSUInteger creates, destroys, frames, failures, failedCreatesRemaining;

DriftHandle *drift_create(void *view, uint32_t width, uint32_t height,
                         float scale, uint32_t preset, uint32_t preview) {
    creates++;
    if (failedCreatesRemaining) { failedCreatesRemaining--; return NULL; }
    activeHandle = calloc(1, sizeof(DriftHandle));
    activeHandle->width = width;
    activeHandle->height = height;
    activeHandle->view = view;
    ((CAMetalLayer *)((__bridge NSView *)view).layer).allowsNextDrawableTimeout = NO;
    return activeHandle;
}
void drift_resize(DriftHandle *handle, uint32_t width, uint32_t height, float scale) {
    handle->width = width;
    handle->height = height;
    ((CAMetalLayer *)((__bridge NSView *)handle->view).layer).allowsNextDrawableTimeout = NO;
}
void drift_animate(DriftHandle *handle) {
    frames++;
    if (!((CAMetalLayer *)((__bridge NSView *)handle->view).layer).allowsNextDrawableTimeout) {
        printf("FAIL drawable acquisition must have a timeout before every frame\n");
        failures++;
    }
}
void drift_set_preset(DriftHandle *handle, uint32_t preset) {}
void drift_destroy(DriftHandle *handle) {
    destroys++;
    free(handle);
    if (activeHandle == handle) activeHandle = NULL;
}

@interface DriftV2ScreenSaverView (TestSignals)
- (void)screensDidSleep:(NSNotification *)note;
- (void)screensDidWake:(NSNotification *)note;
- (void)sessionDidResignActive:(NSNotification *)note;
- (void)sessionDidBecomeActive:(NSNotification *)note;
- (void)windowOcclusionStateDidChange:(NSNotification *)note;
@end

@interface TestWindow : NSWindow
@property CGFloat testScale;
@property BOOL testVisible;
@end
@implementation TestWindow
- (CGFloat)backingScaleFactor { return self.testScale ?: 1.0; }
- (NSWindowOcclusionState)occlusionState {
    return self.testVisible ? NSWindowOcclusionStateVisible : 0;
}
@end

@interface TestSaver : DriftV2ScreenSaverView
@property CGFloat testScale;
@end
@implementation TestSaver
- (NSSize)convertSizeToBacking:(NSSize)size {
    CGFloat scale = self.testScale ?: 1.0;
    return NSMakeSize(size.width * scale, size.height * scale);
}
- (NSRect)convertRectToBacking:(NSRect)rect {
    CGFloat scale = self.testScale ?: 1.0;
    return NSMakeRect(rect.origin.x * scale, rect.origin.y * scale,
                      rect.size.width * scale, rect.size.height * scale);
}
@end

static void Check(BOOL passed, const char *message) {
    printf("%s %s\n", passed ? "PASS" : "FAIL", message);
    if (!passed) failures++;
}

static void CheckSize(TestSaver *view, uint32_t width, uint32_t height, const char *message) {
    CGSize actual = ((CAMetalLayer *)view.layer).drawableSize;
    BOOL passed = activeHandle && activeHandle->width == width && activeHandle->height == height
        && actual.width == width && actual.height == height;
    Check(passed, message);
    if (!passed) printf("  engine=%ux%u drawable=%.0fx%.0f expected=%ux%u\n",
        activeHandle ? activeHandle->width : 0, activeHandle ? activeHandle->height : 0,
        actual.width, actual.height, width, height);
}

static TestWindow *Window(void) {
    TestWindow *window = [[TestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.testScale = 1;
    window.testVisible = YES;
    return window;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        BOOL remoteHost = [NSBundle.mainBundle.bundleIdentifier
            hasPrefix:@"com.apple.ScreenSaver.Engine.legacyScreenSaver"];
        printf("Testing %s host\n", remoteHost ? "remote screensaver" : "ordinary window");

        TestSaver *view = [[TestSaver alloc] initWithFrame:NSMakeRect(0, 0, 640, 360) isPreview:NO];
        view.testScale = 1;
        [view startAnimation];
        [view animateOneFrame];
        Check(creates == 0 && frames == 0, "start before attachment defers engine creation");

        TestWindow *window = Window();
        window.contentView = view;
        [view animateOneFrame];
        Check(creates == 1 && frames == 1, "late attachment creates engine and starts movement");
        Check(((CAMetalLayer *)view.layer).allowsNextDrawableTimeout,
              "engine initialization cannot disable drawable timeout");
        CheckSize(view, 800, 600, "engine and drawable fill attached window");

        // No backing-properties notification: the next tick must reconcile
        // sizes even when a remotely hosted screen saver misses the callback.
        window.testScale = 2;
        view.testScale = 2;
        [view animateOneFrame];
        CheckSize(view, 1600, 1200, "missed scale notification is repaired before rendering");

        [view setBoundsSize:NSMakeSize(480, 900)];
        [view animateOneFrame];
        CheckSize(view, 960, 1800, "bounds-only portrait change updates engine and drawable");

        ((CAMetalLayer *)view.layer).drawableSize = CGSizeMake(100, 100);
        [view animateOneFrame];
        CheckSize(view, 960, 1800, "external drawable-size change is repaired before rendering");

        NSUInteger before = frames;
        window.testVisible = NO;
        [view windowOcclusionStateDidChange:nil];
        [view animateOneFrame];
        Check(frames == before + (remoteHost ? 1 : 0), remoteHost
            ? "remote host keeps moving despite false occlusion"
            : "ordinary covered window pauses rendering");
        window.testVisible = YES;
        before = frames;
        [view animateOneFrame];
        Check(frames == before + 1, "missing visible notification cannot leave animation stalled");
        Check(view.animationTimeInterval < 0.1, "recovered visibility restores active frame rate");

        before = frames;
        [view screensDidSleep:nil];
        [view animateOneFrame];
        Check(frames == before, "display sleep pauses rendering");
        [view screensDidWake:nil];
        [view animateOneFrame];
        Check(frames == before + 1, "display wake resumes rendering");

        before = frames;
        [view sessionDidResignActive:nil];
        [view animateOneFrame];
        Check(frames == before, "inactive session pauses rendering");
        [view sessionDidBecomeActive:nil];
        [view animateOneFrame];
        Check(frames == before + 1, "active session resumes rendering");

        // AppKit ignores a zero bounds size on some transformed views; a
        // collapsed frame models the actual zero-area host transition.
        [view setFrameSize:NSZeroSize];
        before = frames;
        [view animateOneFrame];
        Check(frames == before, "zero-size transition does not render");
        [view setFrameSize:NSMakeSize(800, 500)];
        [view setBoundsSize:NSMakeSize(800, 500)];
        [view animateOneFrame];
        CheckSize(view, 1600, 1000, "drawable recovers after zero-size transition");
        Check(frames == before + 1, "movement resumes after zero-size transition");

        [view removeFromSuperview];
        window.contentView = nil;
        before = frames;
        [view animateOneFrame];
        Check(frames == before, "detached view does not render");
        window.contentView = view;
        [view animateOneFrame];
        Check(frames == before + 1, "reattached view resumes");

        [view stopAnimation];
        before = frames;
        [view animateOneFrame];
        Check(activeHandle == NULL && frames == before, "stopped view releases engine and stays stopped");

        failedCreatesRemaining = 1;
        NSUInteger createAttempts = creates;
        [view startAnimation];
        [view animateOneFrame];
        Check(creates == createAttempts + 1 && activeHandle == NULL,
              "failed initialization is throttled instead of retried every frame");
        [NSThread sleepForTimeInterval:2.1];
        [view animateOneFrame];
        Check(activeHandle != NULL && frames > before, "transient initialization failure retries and resumes");
        [view stopAnimation];

        TestSaver *preview = [[TestSaver alloc] initWithFrame:NSMakeRect(0, 0, 160, 90) isPreview:YES];
        createAttempts = creates;
        [preview startAnimation];
        [preview animateOneFrame];
        [preview stopAnimation];
        Check(creates == createAttempts, "thumbnail preview does not create a GPU engine");

        printf("%lu failure(s), %lu frames, %lu engine attempts, %lu releases\n",
               (unsigned long)failures, (unsigned long)frames,
               (unsigned long)creates, (unsigned long)destroys);
        return failures ? 1 : 0;
    }
}
