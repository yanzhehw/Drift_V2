#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

@interface ScreenSaverView (DriftSignals)
- (void)screensDidSleep:(NSNotification *)notification;
- (void)screensDidWake:(NSNotification *)notification;
@end

// A local host for the actual .saver bundle. The probe reads occasional
// completed Metal frames, so verification needs no screen recording access.
@interface ProbeLayer : CAMetalLayer
@property NSUInteger acquired;
@property NSUInteger presented;
@property NSUInteger samples;
@property NSUInteger changedSamples;
@property NSUInteger mismatchedDrawables;
@property NSUInteger disabledTimeouts;
@property uint64_t previousHash;
@property double minimumQuadrantCoverage;
@property double lastQuadrantCoverage;
@property double bestTotalCoverage;
@property double lastTotalCoverage;
@property (strong) id<MTLCommandQueue> readbackQueue;
@property (copy) NSString *capturePath;
@end

@implementation ProbeLayer
- (id<CAMetalDrawable>)nextDrawable {
    if (!self.allowsNextDrawableTimeout) self.disabledTimeouts++;
    // Only the verification host needs CPU readback. The production view
    // remains framebuffer-only; this flag does not affect its render shader.
    self.framebufferOnly = NO;
    id<CAMetalDrawable> drawable = [super nextDrawable];
    if (!drawable) return nil;
    self.acquired++;
    CGSize expected = self.drawableSize;
    if (drawable.texture.width != (NSUInteger)llround(expected.width)
        || drawable.texture.height != (NSUInteger)llround(expected.height)) self.mismatchedDrawables++;
    BOOL sample = self.acquired % 30 == 0;
    BOOL saveCapture = self.acquired % 120 == 0;
    // CAMetalDrawable.texture may no longer be queried after presentation;
    // retain the texture while the drawable is still acquired.
    id<MTLTexture> sampledTexture = sample ? drawable.texture : nil;
    __weak ProbeLayer *weakSelf = self;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        ProbeLayer *layer = weakSelf;
        if (!layer) return;
        @synchronized (layer) { layer.presented++; }
        if (!sample) return;
        @autoreleasepool {
            id<MTLTexture> texture = sampledTexture;
            NSUInteger width = texture.width, height = texture.height;
            NSUInteger rowBytes = (width * 4 + 255) & ~255UL;
            id<MTLBuffer> pixels = [layer.device newBufferWithLength:rowBytes * height
                                                           options:MTLResourceStorageModeShared];
            if (!pixels) return;
            @synchronized (layer) {
                if (!layer.readbackQueue) layer.readbackQueue = [layer.device newCommandQueue];
            }
            id<MTLCommandBuffer> commands = [layer.readbackQueue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                         toBuffer:pixels destinationOffset:0 destinationBytesPerRow:rowBytes
                destinationBytesPerImage:rowBytes * height];
            [blit endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            if (commands.status != MTLCommandBufferStatusCompleted) return;
            uint8_t *bytes = pixels.contents;
            if (layer.capturePath && saveCapture) {
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, rowBytes, space,
                    kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                CGImageRef image = CGBitmapContextCreateImage(context);
                NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:layer.capturePath atomically:YES];
                CGImageRelease(image);
                CGContextRelease(context);
                CGColorSpaceRelease(space);
            }
            uint64_t hash = 1469598103934665603ULL;
            NSUInteger bright[4] = {0}, total[4] = {0};
            for (NSUInteger y = 0; y < height; y += 3) {
                for (NSUInteger x = 0; x < width; x += 3) {
                    uint8_t *pixel = bytes + y * rowBytes + x * 4;
                    NSUInteger quadrant = (y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0);
                    total[quadrant]++;
                    if ((NSUInteger)pixel[0] + pixel[1] + pixel[2] > 30) bright[quadrant]++;
                    for (NSUInteger c = 0; c < 3; c++) hash = (hash ^ pixel[c]) * 1099511628211ULL;
                }
            }
            double coverage = 1.0;
            NSUInteger totalBright = 0, totalPixels = 0;
            for (NSUInteger q = 0; q < 4; q++) {
                coverage = fmin(coverage, (double)bright[q] / total[q]);
                totalBright += bright[q];
                totalPixels += total[q];
            }
            double totalCoverage = (double)totalBright / totalPixels;
            @synchronized (layer) {
                if (layer.samples && hash != layer.previousHash) layer.changedSamples++;
                layer.samples++;
                layer.previousHash = hash;
                // Record the best established coverage, avoiding the initial
                // simulation warmup before its lines reach full brightness.
                layer.minimumQuadrantCoverage = fmax(layer.minimumQuadrantCoverage, coverage);
                layer.lastQuadrantCoverage = coverage;
                layer.bestTotalCoverage = fmax(layer.bestTotalCoverage, totalCoverage);
                layer.lastTotalCoverage = totalCoverage;
            }
        }
    }];
    return drawable;
}
@end

@interface PreviewDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSMutableArray<NSWindow *> *windows;
@property (strong) NSMutableArray<ScreenSaverView *> *savers;
@property (strong) NSTimer *timer;
@property BOOL verify;
@property (copy) NSString *bundlePath;
@property (copy) NSString *resultPath;
@property BOOL geometryPassed;
@property NSUInteger framesBeforeSleep;
@property BOOL sleepPassed;
@property (strong) NSMutableArray<NSDictionary *> *phases;
@property (strong) NSArray<NSDictionary *> *phaseStart;
@property (strong) NSMutableArray<NSDictionary *> *displays;
@end

static ScreenSaverDefaults *VerificationDefaults(id self, SEL command) {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"com.local.DriftV2Preview"];
    [defaults registerDefaults:@{@"DriftPreset": @4, @"DriftFrameRate": @1}];
    return defaults;
}

@implementation PreviewDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSBundle *bundle = [NSBundle bundleWithPath:self.bundlePath];
    NSError *error = nil;
    if (![bundle loadAndReturnError:&error] || !bundle.principalClass) {
        NSLog(@"Cannot load %@: %@", self.bundlePath, error);
        exit(1);
    }
    self.windows = [NSMutableArray array];
    self.savers = [NSMutableArray array];
    self.geometryPassed = YES;
    self.sleepPassed = YES;
    self.phases = [NSMutableArray array];
    self.displays = [NSMutableArray array];
    Class viewClass = objc_allocateClassPair(bundle.principalClass, "DriftVerificationView", 0);
    class_addMethod(viewClass, @selector(defaults), (IMP)VerificationDefaults, "@@:");
    objc_registerClassPair(viewClass);
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens)
        if (candidate.visibleFrame.size.width > screen.visibleFrame.size.width) screen = candidate;
    NSRect available = screen.visibleFrame;
    CGFloat usableWidth = available.size.width - 100;
    CGFloat landscapeWidth = fmin(760, usableWidth * 0.67);
    CGFloat portraitWidth = fmin(350, usableWidth * 0.33);
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    if (self.verify) {
        // Use each attached display's real dimensions and production scale.
        // Tiny windows choose a different simulation grid and cannot verify
        // the full-screen workload shown in the reported crop/stall bug.
        NSArray<NSScreen *> *screens = [NSScreen.screens sortedArrayUsingComparator:
            ^NSComparisonResult(NSScreen *a, NSScreen *b) {
                if (a.frame.size.width == b.frame.size.width) return NSOrderedSame;
                return a.frame.size.width > b.frame.size.width ? NSOrderedAscending : NSOrderedDescending;
            }];
        for (NSScreen *display in screens) {
            [frames addObject:[NSValue valueWithRect:display.visibleFrame]];
            [titles addObject:[@"Drift verification — " stringByAppendingString:display.localizedName]];
            [self.displays addObject:@{@"name": display.localizedName,
                @"frame_points": NSStringFromRect(display.visibleFrame),
                @"backing_scale": @(display.backingScaleFactor)}];
        }
    } else {
        NSArray<NSValue *> *sizes = @[[NSValue valueWithSize:NSMakeSize(landscapeWidth, fmin(450, available.size.height - 120))],
                                     [NSValue valueWithSize:NSMakeSize(portraitWidth, fmin(620, available.size.height - 120))]];
        CGFloat x = available.origin.x + 30;
        for (NSValue *value in sizes) {
            NSSize size = value.sizeValue;
            [frames addObject:[NSValue valueWithRect:NSMakeRect(x, NSMaxY(available) - size.height - 50,
                size.width, size.height)]];
            x += size.width + 20;
        }
        [titles addObjectsFromArray:@[@"Drift preview — landscape", @"Drift preview — portrait"]];
    }
    if (frames.count == 0) { NSLog(@"No attached display available for verification"); exit(1); }
    for (NSUInteger index = 0; index < frames.count; index++) {
        NSRect frame = frames[index].rectValue;
        NSSize size = frame.size;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
            styleMask:self.verify ? NSWindowStyleMaskBorderless
                : NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = titles[index];
        if (self.verify) {
            // Keep the short, announced display-sized test visible even if
            // another app becomes active while verification is running.
            window.level = NSFloatingWindowLevel;
            window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
        }
        ScreenSaverView *saver = [[viewClass alloc]
            initWithFrame:NSMakeRect(0, 0, size.width, size.height) isPreview:NO];
        if (self.verify) {
            ProbeLayer *probe = [ProbeLayer layer];
            probe.pixelFormat = MTLPixelFormatBGRA8Unorm;
            probe.capturePath = [self.resultPath.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:[NSString stringWithFormat:@"window-%lu.png", (unsigned long)index]];
            saver.layer = probe;
        }
        saver.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        window.contentView = saver;
        // NSWindow initialization can constrain a rect to the main screen;
        // place display-sized hosts using the actual global screen rect.
        if (self.verify) [window setFrame:frame display:NO];
        [self.windows addObject:window];
        [self.savers addObject:saver];
        [window makeKeyAndOrderFront:nil];
        [saver startAnimation];
    }
    [NSApp activateIgnoringOtherApps:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 repeats:YES
        block:^(NSTimer *timer) {
            for (ScreenSaverView *view in self.savers) [view animateOneFrame];
        }];
    if (!self.verify) return;
    self.phaseStart = [self snapshot];
    NSString *resultPath = self.resultPath;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [@"{\"passed\":false,\"error\":\"verification watchdog timed out\"}"
            writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        _Exit(2);
    });

    // Exercise a resize in each orientation, a power transition, and a
    // restart in the same view while the actual Metal renderer is running.
    [self performSelector:@selector(resizeWindows) withObject:nil afterDelay:5.0];
    [self performSelector:@selector(disturbDrawables) withObject:nil afterDelay:6.0];
    [self performSelector:@selector(sleepViews) withObject:nil afterDelay:8.0];
    [self performSelector:@selector(wakeViews) withObject:nil afterDelay:8.7];
    [self performSelector:@selector(restartViews) withObject:nil afterDelay:11.0];
    [self performSelector:@selector(finishVerification) withObject:nil afterDelay:16.0];
}
- (NSArray<NSDictionary *> *)snapshot {
    NSMutableArray *values = [NSMutableArray array];
    for (ScreenSaverView *view in self.savers) {
        ProbeLayer *layer = (ProbeLayer *)view.layer;
        @synchronized (layer) {
            [values addObject:@{@"frames": @(layer.acquired), @"changes": @(layer.changedSamples)}];
        }
    }
    return values;
}
- (void)finishPhase:(NSString *)name {
    NSArray *current = [self snapshot];
    BOOL passed = YES;
    NSMutableArray *details = [NSMutableArray array];
    for (NSUInteger i = 0; i < current.count; i++) {
        NSUInteger frames = [current[i][@"frames"] unsignedIntegerValue] - [self.phaseStart[i][@"frames"] unsignedIntegerValue];
        NSUInteger changes = [current[i][@"changes"] unsignedIntegerValue] - [self.phaseStart[i][@"changes"] unsignedIntegerValue];
        ProbeLayer *layer = (ProbeLayer *)self.savers[i].layer;
        @synchronized (layer) {
            // Flow can legitimately leave a quadrant dark. Require visible
            // content overall; verify crop through exact surface geometry.
            passed &= frames > 30 && changes > 0 && layer.lastTotalCoverage > 0.001;
            [details addObject:@{@"frames": @(frames), @"changing_samples": @(changes),
                @"minimum_quadrant_coverage": @(layer.lastQuadrantCoverage),
                @"total_nonblack_coverage": @(layer.lastTotalCoverage)}];
        }
    }
    [self.phases addObject:@{@"phase": name, @"moving_and_covered": @(passed), @"windows": details}];
    self.phaseStart = current;
}
- (BOOL)checkGeometry {
    BOOL passed = YES;
    for (ScreenSaverView *view in self.savers) {
        NSSize expected = [view convertSizeToBacking:view.bounds.size];
        CGSize actual = ((CAMetalLayer *)view.layer).drawableSize;
        BOOL matches = actual.width == llround(expected.width) && actual.height == llround(expected.height)
            && NSEqualRects(view.layer.bounds, view.bounds)
            && NSEqualSizes(view.layer.frame.size, view.frame.size)
            && NSEqualSizes(view.frame.size, view.window.contentView.bounds.size);
        passed &= matches;
        NSLog(@"geometry: match=%d viewFrame=%@ viewBounds=%@ layerFrame=%@ layerBounds=%@ backing=%@ drawable=%@ window=%@ visible=%d occlusion=%lu",
            matches, NSStringFromRect(view.frame), NSStringFromRect(view.bounds), NSStringFromRect(view.layer.frame),
            NSStringFromRect(view.layer.bounds), NSStringFromSize(expected), NSStringFromSize(actual),
            NSStringFromRect(view.window.frame), view.window.isVisible, (unsigned long)view.window.occlusionState);
    }
    return passed;
}
- (void)resizeWindows {
    [self finishPhase:@"initial display-sized surfaces"];
    self.geometryPassed &= [self checkGeometry];
    for (NSUInteger index = 0; index < self.windows.count; index++) {
        NSSize size = self.savers[index].bounds.size;
        [self.windows[index] setContentSize:NSMakeSize(round(size.width * 0.96), round(size.height * 0.96))];
    }
}
- (void)disturbDrawables {
    for (ScreenSaverView *view in self.savers) {
        CAMetalLayer *layer = (CAMetalLayer *)view.layer;
        CGSize size = layer.drawableSize;
        layer.drawableSize = CGSizeMake(size.width * 2, size.height * 2);
    }
}
- (NSUInteger)acquiredFrames {
    NSUInteger frames = 0;
    for (ScreenSaverView *view in self.savers) frames += ((ProbeLayer *)view.layer).acquired;
    return frames;
}
- (void)sleepViews {
    [self finishPhase:@"resize and external drawable drift"];
    self.geometryPassed &= [self checkGeometry];
    for (ScreenSaverView *view in self.savers) [view screensDidSleep:nil];
    self.framesBeforeSleep = [self acquiredFrames];
}
- (void)wakeViews {
    self.sleepPassed = [self acquiredFrames] == self.framesBeforeSleep;
    for (ScreenSaverView *view in self.savers) [view screensDidWake:nil];
    self.phaseStart = [self snapshot];
}
- (void)restartViews {
    [self finishPhase:@"wake"];
    for (ScreenSaverView *view in self.savers) { [view stopAnimation]; [view startAnimation]; }
    self.phaseStart = [self snapshot];
}
- (void)finishVerification {
    [self.timer invalidate];
    [self finishPhase:@"restart"];
    self.geometryPassed &= [self checkGeometry];
    NSMutableArray *results = [NSMutableArray array];
    BOOL passed = self.geometryPassed && self.sleepPassed;
    for (NSDictionary *phase in self.phases) passed &= [phase[@"moving_and_covered"] boolValue];
    for (ScreenSaverView *view in self.savers) {
        ProbeLayer *layer = (ProbeLayer *)view.layer;
        @synchronized (layer) {
            BOOL moving = layer.presented > 120 && layer.samples >= 4 && layer.changedSamples >= 3;
            BOOL coverage = layer.bestTotalCoverage > 0.001;
            BOOL matches = layer.mismatchedDrawables == 0 && layer.disabledTimeouts == 0;
            passed &= moving && coverage && matches;
            [results addObject:@{@"presented_frames": @(layer.presented), @"samples": @(layer.samples),
                @"changing_samples": @(layer.changedSamples), @"minimum_quadrant_coverage": @(layer.minimumQuadrantCoverage),
                @"total_nonblack_coverage": @(layer.bestTotalCoverage),
                @"mismatched_drawables": @(layer.mismatchedDrawables), @"moving": @(moving),
                @"disabled_timeouts": @(layer.disabledTimeouts),
                @"coverage_passed": @(coverage)}];
        }
        [view stopAnimation];
    }
    NSDictionary *report = @{@"passed": @(passed), @"geometry_passed": @(self.geometryPassed),
        @"sleep_paused": @(self.sleepPassed), @"windows": results, @"phases": self.phases,
        @"display_sized": @YES, @"displays": self.displays};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:self.resultPath atomically:YES];
    printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
    exit(passed ? 0 : 1);
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    for (ScreenSaverView *view in self.savers) [view stopAnimation];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        PreviewDelegate *delegate = [PreviewDelegate new];
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        delegate.verify = [args containsObject:@"--verify"];
        NSString *contents = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
        delegate.bundlePath = [contents stringByAppendingPathComponent:@"../saver-build/Drift_V2.saver"];
        delegate.resultPath = [contents stringByAppendingPathComponent:@"verification.json"];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
