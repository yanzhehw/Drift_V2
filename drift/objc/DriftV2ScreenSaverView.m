#import "DriftV2ScreenSaverView.h"
#import "drift_v2_screensaver.h"
#import <QuartzCore/CAMetalLayer.h>

static NSString *const kDriftModuleName = @"com.local.DriftV2ScreenSaver";
static NSString *const kPresetKey       = @"DriftPreset";
static NSString *const kFrameRateKey    = @"DriftFrameRate";

// Posted by the system when the screen saver is dismissed.
static NSString *const kScreenSaverWillStopNotification = @"com.apple.screensaver.willstop";

// Bundle identifier prefix of the process that hosts third-party screen savers
// on modern macOS (an arm64 and an x86-64 variant exist).
static NSString *const kLegacyScreenSaverHostPrefix = @"com.apple.ScreenSaver.Engine.legacyScreenSaver";

// Animation timer intervals. ScreenSaverView applies a new interval to the
// running timer immediately, so these switch cleanly between states.
static const NSTimeInterval kActiveFrameInterval  = 1.0 / 60.0;
static const NSTimeInterval kReducedFrameInterval = 1.0 / 30.0;
static const NSTimeInterval kHiddenTickInterval   = 1.0;   // nothing to draw; just stay alive
static const NSTimeInterval kPreviewTickInterval  = 60.0;  // preview is a static image

// How often to re-read preferences (preset, frame rate) and power state.
static const CFTimeInterval kSettingsPollInterval = 2.0;
static const CFTimeInterval kEngineRetryInterval = 2.0;

// Delay between the screen saver stopping and the host process exiting.
static const NSTimeInterval kHostExitDelay = 1.0;

// Line size, line spacing and flow features are tuned for 110 pixels per inch
// (a 27-inch 1440p display). The engine is told how many device pixels make
// up one such reference pixel on the current screen, so everything comes out
// the same physical size on every display.
static const CGFloat kReferencePixelsPerMM = 110.0 / 25.4;

typedef NS_ENUM(NSInteger, DriftFrameRate) {
    DriftFrameRateAuto = 0,  // 60 fps; 30 fps in Low Power Mode or under thermal pressure
    DriftFrameRate60   = 1,
    DriftFrameRate30   = 2,
};

#define DLOG(fmt, ...) NSLog(@"[Drift_V2] " fmt, ##__VA_ARGS__)

// Bumped by every startAnimation; a pending host exit only fires if no
// screen saver started in this process since it was scheduled.
static NSUInteger gHostExitGeneration;
// Preview views currently animating in this process (System Settings).
static NSInteger gAnimatingPreviewCount;

static BOOL DriftHostIsLegacyScreenSaver(void) {
    return [NSBundle.mainBundle.bundleIdentifier hasPrefix:kLegacyScreenSaverHostPrefix];
}

@interface DriftV2ScreenSaverView () {
    DriftHandle *_drift;
    BOOL _isPreview;
    BOOL _countedAsAnimatingPreview;  // Included in gAnimatingPreviewCount.
    uint32_t _currentPreset;    // Last preset applied to _drift.
    DriftFrameRate _frameRate;  // Saved frame-rate preference.

    // Workspace signals apply to the entire session. Window visibility is
    // checked live instead of latching a notification until another arrives.
    BOOL _screensAsleep;
    BOOL _sessionInactive;
    BOOL _wasRendering;

    NSScreen *_sizingScreen;
    CGFloat _sizingBackingScale;
    NSSize _sizingScreenSize;
    CGFloat _cachedEngineScale;

    CFTimeInterval _nextSettingsPoll;
    CFTimeInterval _nextEngineAttempt;
}
@property (nonatomic, strong) NSWindow *configSheet;
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSPopUpButton *frameRatePopup;
@end

@implementation DriftV2ScreenSaverView

#pragma mark - Layer setup

- (CALayer *)makeBackingLayer {
    // In preview mode (the tiny System Settings thumbnail), skip Metal entirely
    // and just display the static thumbnail PNG. This cuts GPU/CPU cost to
    // essentially zero for the preview and avoids the "zoomed in" live render.
    if (_isPreview) {
        CALayer *layer = [CALayer layer];
        layer.contentsGravity = kCAGravityResizeAspectFill;
        layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

        NSString *path = [[NSBundle bundleForClass:[self class]]
                          pathForResource:@"thumbnail" ofType:@"png"];
        if (path) {
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
            if (image) {
                layer.contents = image;
            } else {
                DLOG(@"preview: failed to load thumbnail at %@", path);
            }
        } else {
            DLOG(@"preview: thumbnail.png not found in bundle resources");
        }
        return layer;
    }

    // No device here: wgpu assigns the one it picked (the low-power GPU)
    // when it configures the surface. MTLCreateSystemDefaultDevice() would
    // power up the discrete GPU on dual-GPU Macs.
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    DLOG(@"makeBackingLayer: %@", layer);
    return layer;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    DLOG(@"initWithFrame: %@ isPreview:%d", NSStringFromRect(frame), isPreview);
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _isPreview = isPreview;
        _frameRate = [self savedFrameRate];
        [self setAnimationTimeInterval:(isPreview ? kPreviewTickInterval : kActiveFrameInterval)];
        [self setWantsLayer:YES];
        if (!isPreview) {
            [self registerForSystemNotifications];
        }
        DLOG(@"init done, layer=%@ class=%@", self.layer, [self.layer class]);
    }
    return self;
}

- (void)dealloc {
    DLOG(@"dealloc");
    [self setCountedAsAnimatingPreview:NO];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
    if (_drift) {
        drift_destroy(_drift);
        _drift = NULL;
    }
}

- (void)registerForSystemNotifications {
    // On macOS 14+ the host frequently never calls -stopAnimation when the
    // screen saver is dismissed, so the view (and its 60 Hz render loop)
    // lives on in the background. This notification is the reliable signal.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenSaverWillStop:)
               name:kScreenSaverWillStopNotification
             object:nil];

    NSNotificationCenter *workspace = [NSWorkspace sharedWorkspace].notificationCenter;
    [workspace addObserver:self selector:@selector(screensDidSleep:)
                      name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(screensDidWake:)
                      name:NSWorkspaceScreensDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionDidResignActive:)
                      name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionDidBecomeActive:)
                      name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
}

- (void)setCountedAsAnimatingPreview:(BOOL)counted {
    if (counted == _countedAsAnimatingPreview) return;
    _countedAsAnimatingPreview = counted;
    gAnimatingPreviewCount += counted ? 1 : -1;
}

#pragma mark - Preferences

- (ScreenSaverDefaults *)defaults {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:kDriftModuleName];
    [defaults registerDefaults:@{
        kPresetKey: @(DriftPresetOriginal),
        kFrameRateKey: @(DriftFrameRateAuto),
    }];
    return defaults;
}

- (uint32_t)savedPreset {
    return (uint32_t)[[self defaults] integerForKey:kPresetKey];
}

- (DriftFrameRate)savedFrameRate {
    return (DriftFrameRate)[[self defaults] integerForKey:kFrameRateKey];
}

- (void)savePreset:(uint32_t)preset frameRate:(DriftFrameRate)frameRate {
    ScreenSaverDefaults *defaults = [self defaults];
    [defaults setInteger:preset forKey:kPresetKey];
    [defaults setInteger:frameRate forKey:kFrameRateKey];
    [defaults synchronize];
}

#pragma mark - Render state

- (BOOL)shouldRender {
    if (_screensAsleep || _sessionInactive || !self.window) return NO;
    if (NSIsEmptyRect(self.frame) || NSIsEmptyRect(self.bounds)) return NO;
    NSSize px = [self drawablePixelSize];
    if (px.width < 1 || px.height < 1) return NO;

    // legacyScreenSaver exports its view to another process. Its local
    // window's occlusion state does not describe the displayed remote layer.
    // The explicit stop/sleep/session signals still suspend that host.
    if (DriftHostIsLegacyScreenSaver()) return YES;
    return (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

- (BOOL)wantsReducedFrameRate {
    switch (_frameRate) {
        case DriftFrameRate60: return NO;
        case DriftFrameRate30: return YES;
        case DriftFrameRateAuto:
        default: {
            NSProcessInfo *info = [NSProcessInfo processInfo];
            if (@available(macOS 12.0, *)) {
                if (info.isLowPowerModeEnabled) return YES;
            }
            return info.thermalState >= NSProcessInfoThermalStateSerious;
        }
    }
}

// Match the timer to what's on screen: full rate while visible, a slow idle
// tick while hidden, so a paused saver doesn't wake the CPU 60 times a second.
- (void)updateAnimationInterval {
    if (_isPreview) return;

    _wasRendering = [self shouldRender];
    NSTimeInterval interval;
    if (!_wasRendering) {
        interval = kHiddenTickInterval;
    } else if ([self wantsReducedFrameRate]) {
        interval = kReducedFrameInterval;
    } else {
        interval = kActiveFrameInterval;
    }

    if (fabs(self.animationTimeInterval - interval) > 1e-6) {
        DLOG(@"animation interval %.4f -> %.4f", self.animationTimeInterval, interval);
        [self setAnimationTimeInterval:interval];
    }
}

// Re-reads preferences, which the Options sheet may have changed from another
// process (each display can be its own process). Returns YES if the engine
// was rebuilt for a new preset.
- (BOOL)pollSettings {
    ScreenSaverDefaults *defaults = [self defaults];
    [defaults synchronize];

    _frameRate = (DriftFrameRate)[defaults integerForKey:kFrameRateKey];
    [self updateAnimationInterval];

    uint32_t newPreset = (uint32_t)[defaults integerForKey:kPresetKey];
    if (newPreset != _currentPreset && _drift) {
        DLOG(@"poll: preset changed %u → %u, applying", _currentPreset, newPreset);
        _currentPreset = newPreset;
        drift_set_preset(_drift, newPreset);
        return YES;
    }
    return NO;
}

#pragma mark - ScreenSaverView

- (void)createEngineIfNeeded {
    if (_drift || ![self shouldRender]) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now < _nextEngineAttempt) return;

    [self syncDrawableSize];
    NSSize px = [self drawablePixelSize];
    if (px.width < 1 || px.height < 1) return;
    _nextEngineAttempt = now + kEngineRetryInterval;
    CGFloat scale = [self engineScaleFactor];

    uint32_t preset = [self savedPreset];
    _currentPreset = preset;
    DLOG(@"drift_create: px=%.0fx%.0f scale=%.3f preset=%u",
         px.width, px.height, scale, preset);
    _drift = drift_create((__bridge void *)self,
                          (uint32_t)px.width,
                          (uint32_t)px.height,
                          (float)scale,
                          preset,
                          0u);
    DLOG(@"drift_create returned: %p", _drift);
    // wgpu's Metal surface configuration disables drawable timeouts. Restore
    // them so a display transition cannot block the host's main thread forever.
    [self syncDrawableSize];
}

- (void)startAnimation {
    DLOG(@"startAnimation, bounds=%@, layer=%@ class=%@",
         NSStringFromRect(self.bounds), self.layer, [self.layer class]);
    // A screen saver is (re)starting in this process: cancel any pending exit.
    gHostExitGeneration++;
    if (_isPreview) [self setCountedAsAnimatingPreview:YES];

    [super startAnimation];

    // Preview mode shows the static thumbnail — no engine, no animation.
    if (_isPreview) return;

    _nextEngineAttempt = 0;
    [self createEngineIfNeeded];
    _nextSettingsPoll = CACurrentMediaTime() + kSettingsPollInterval;
    [self updateAnimationInterval];
}

- (void)stopAnimation {
    DLOG(@"stopAnimation");
    [self setCountedAsAnimatingPreview:NO];
    [super stopAnimation];
    if (_drift) {
        drift_destroy(_drift);
        _drift = NULL;
    }
}

- (void)drawRect:(NSRect)rect {
    // Metal rendering — nothing to draw via AppKit.
}

- (void)animateOneFrame {
    if (_isPreview || !self.isAnimating) return;
    // Also run this on idle ticks: a missed visibility notification must not
    // leave an otherwise visible screen saver permanently paused.
    BOOL render = [self shouldRender];
    if (render != _wasRendering) [self updateAnimationInterval];
    if (!render) return;

    [self createEngineIfNeeded];
    if (!_drift) return;
    // AppKit can change a backing layer after a frame/bounds callback. Reconcile
    // its drawable with the engine immediately before acquiring the next frame.
    [self syncDrawableSize];

    CFTimeInterval now = CACurrentMediaTime();
    if (now >= _nextSettingsPoll) {
        _nextSettingsPoll = now + kSettingsPollInterval;
        // Skip rendering on the tick that rebuilt the engine; the next one
        // renders with the new preset's resources in place.
        if ([self pollSettings]) return;
    }

    drift_animate(_drift);
}

#pragma mark - System signals

- (void)screenSaverWillStop:(NSNotification *)note {
    if (_isPreview) return;
    DLOG(@"screen saver will stop");

    // Stop the timer and free the GPU engine now, whether or not the host
    // follows up with -stopAnimation.
    if (self.isAnimating || _drift) [self stopAnimation];

    // On macOS 14+ legacyScreenSaver stays alive after the screen saver ends
    // and keeps every view it ever created. Exit so nothing lingers; the
    // system launches a fresh process next time. Skip it while System
    // Settings is showing a preview from this process.
    if (@available(macOS 14.0, *)) {
        if (!DriftHostIsLegacyScreenSaver() || gAnimatingPreviewCount > 0) return;

        NSUInteger generation = ++gHostExitGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHostExitDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation == gHostExitGeneration && gAnimatingPreviewCount == 0) {
                DLOG(@"exiting idle legacyScreenSaver host");
                exit(0);
            }
        });
    }
}

- (void)screensDidSleep:(NSNotification *)note {
    _screensAsleep = YES;
    [self updateAnimationInterval];
}

- (void)screensDidWake:(NSNotification *)note {
    _screensAsleep = NO;
    [self updateAnimationInterval];
}

- (void)sessionDidResignActive:(NSNotification *)note {
    _sessionInactive = YES;
    [self updateAnimationInterval];
}

- (void)sessionDidBecomeActive:(NSNotification *)note {
    _sessionInactive = NO;
    [self updateAnimationInterval];
}

// Subscribed per window in -viewDidMoveToWindow.
- (void)windowOcclusionStateDidChange:(NSNotification *)note {
    [self updateAnimationInterval];
}

- (void)windowDidChangeScreen:(NSNotification *)note {
    // Screens can differ in pixel density without differing in backing scale.
    _sizingScreen = nil;
    [self syncDrawableSize];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (self.window) {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:self.window];
        [center removeObserver:self name:NSWindowDidChangeScreenNotification object:self.window];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    NSWindow *w = self.window;
    if (w) {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(windowOcclusionStateDidChange:)
                       name:NSWindowDidChangeOcclusionStateNotification
                     object:w];
        [center addObserver:self
                   selector:@selector(windowDidChangeScreen:)
                       name:NSWindowDidChangeScreenNotification
                     object:w];
    }
    _nextEngineAttempt = 0;
    [self syncDrawableSize];
    [self updateAnimationInterval];
}

#pragma mark - Sizing

// Device pixels per reference pixel (see kReferencePixelsPerMM) on the
// view's screen, from the screen's physical size. Falls back to the backing
// scale factor, i.e. sizing in points, if the screen's size is unknown.
- (CGFloat)engineScaleFactor {
    NSWindow *window = self.window;
    CGFloat backing = window ? window.backingScaleFactor : 2.0;
    NSScreen *screen = window.screen;
    if (!screen) return backing;

    NSSize points = screen.frame.size;
    if (screen == _sizingScreen && backing == _sizingBackingScale &&
        NSEqualSizes(points, _sizingScreenSize)) return _cachedEngineScale;
    _sizingScreen = screen;
    _sizingBackingScale = backing;
    _sizingScreenSize = points;
    _cachedEngineScale = backing;

    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGSize mm = CGDisplayScreenSize(display);
    if (mm.width <= 0 || mm.height <= 0) return backing;

    // Geometric mean over both axes, which doesn't depend on the rotation.
    CGFloat pixelsPerMM = sqrt((points.width * backing) * (points.height * backing)
                               / (mm.width * mm.height));
    // TVs and projectors sometimes report a made-up size.
    if (pixelsPerMM < 1.5 || pixelsPerMM > 20.0) return backing;

    _cachedEngineScale = pixelsPerMM / kReferencePixelsPerMM;
    return _cachedEngineScale;
}

// Keeps the Metal drawable (and the engine) at the view's backing resolution.
- (NSSize)drawablePixelSize {
    NSSize px = [self convertSizeToBacking:self.bounds.size];
    if (!isfinite(px.width) || !isfinite(px.height) ||
        px.width < 1 || px.height < 1 ||
        px.width > UINT32_MAX || px.height > UINT32_MAX) return NSZeroSize;
    return NSMakeSize(round(px.width), round(px.height));
}

- (void)syncDrawableSize {
    CALayer *layer = self.layer;
    if (!self.window || ![layer isKindOfClass:[CAMetalLayer class]]) return;

    NSSize px = [self drawablePixelSize];
    if (px.width < 1 || px.height < 1) return;
    CAMetalLayer *metalLayer = (CAMetalLayer *)layer;
    CGFloat backing = self.window.backingScaleFactor;
    if (metalLayer.contentsScale != backing) metalLayer.contentsScale = backing;
    if (!CGSizeEqualToSize(metalLayer.drawableSize, px)) metalLayer.drawableSize = px;

    if (_drift) {
        drift_resize(_drift, (uint32_t)px.width, (uint32_t)px.height, (float)[self engineScaleFactor]);
    }
    // Must follow drift_resize: surface.configure resets this to NO.
    metalLayer.allowsNextDrawableTimeout = YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self syncDrawableSize];
}

- (void)setBoundsSize:(NSSize)newSize {
    [super setBoundsSize:newSize];
    [self syncDrawableSize];
}

- (void)layout {
    [super layout];
    [self syncDrawableSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    // E.g. moved between a Retina and a non-Retina display.
    [self syncDrawableSize];
}

- (BOOL)isOpaque {
    return YES;
}

#pragma mark - Configuration Sheet

- (BOOL)hasConfigureSheet {
    return YES;
}

- (void)selectSavedValuesInSheet {
    NSInteger presetIndex = [_presetPopup indexOfItemWithTag:(NSInteger)[self savedPreset]];
    [_presetPopup selectItemAtIndex:(presetIndex < 0 ? 0 : presetIndex)];

    NSInteger rateIndex = [_frameRatePopup indexOfItemWithTag:[self savedFrameRate]];
    [_frameRatePopup selectItemAtIndex:(rateIndex < 0 ? 0 : rateIndex)];
}

- (NSPopUpButton *)popupWithFrame:(NSRect)frame items:(NSArray<NSDictionary *> *)items {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    // Each item carries its enum value as its tag so reordering the menu
    // doesn't break the index→enum mapping.
    for (NSDictionary *item in items) {
        [popup addItemWithTitle:item[@"title"]];
        [[popup lastItem] setTag:[item[@"tag"] integerValue]];
    }
    return popup;
}

- (NSWindow *)configureSheet {
    if (_configSheet) {
        [self selectSavedValuesInSheet];
        return _configSheet;
    }

    NSRect sheetFrame = NSMakeRect(0, 0, 340, 190);
    _configSheet = [[NSWindow alloc] initWithContentRect:sheetFrame
                                               styleMask:NSWindowStyleMaskTitled
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
    _configSheet.title = @"Drift_V2 Settings";

    NSView *content = _configSheet.contentView;

    NSTextField *presetLabel = [NSTextField labelWithString:@"Color Scheme:"];
    presetLabel.frame = NSMakeRect(20, 140, 100, 20);
    [content addSubview:presetLabel];

    // Only expose the image-based presets — these are the ones that ship
    // with PNG palettes in colors/ and are reliably rendered.
    _presetPopup = [self popupWithFrame:NSMakeRect(130, 138, 190, 24) items:@[
        @{ @"title": @"Gumdrop",    @"tag": @(DriftPresetGumdrop)   },
        @{ @"title": @"Silver",     @"tag": @(DriftPresetSilver)    },
        @{ @"title": @"Freedom",    @"tag": @(DriftPresetFreedom)   },
        @{ @"title": @"Space Gray", @"tag": @(DriftPresetSpaceGray) },
        @{ @"title": @"Aurora",     @"tag": @(DriftPresetAurora)    },
        @{ @"title": @"Atlas",      @"tag": @(DriftPresetAtlas)     },
        @{ @"title": @"Emerald",    @"tag": @(DriftPresetEmerald)   },
        @{ @"title": @"Glacier",    @"tag": @(DriftPresetGlacier)   },
        @{ @"title": @"Ember",      @"tag": @(DriftPresetEmber)     },
    ]];
    [content addSubview:_presetPopup];

    NSTextField *rateLabel = [NSTextField labelWithString:@"Frame Rate:"];
    rateLabel.frame = NSMakeRect(20, 106, 100, 20);
    [content addSubview:rateLabel];

    _frameRatePopup = [self popupWithFrame:NSMakeRect(130, 104, 190, 24) items:@[
        @{ @"title": @"Auto",                @"tag": @(DriftFrameRateAuto) },
        @{ @"title": @"60 fps",              @"tag": @(DriftFrameRate60)   },
        @{ @"title": @"30 fps (lighter)",    @"tag": @(DriftFrameRate30)   },
    ]];
    [content addSubview:_frameRatePopup];

    NSTextField *rateHint = [NSTextField wrappingLabelWithString:
        @"Auto uses 30 fps in Low Power Mode or when the Mac is running hot."];
    rateHint.frame = NSMakeRect(132, 62, 188, 36);
    rateHint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    rateHint.textColor = [NSColor secondaryLabelColor];
    [content addSubview:rateHint];

    [self selectSavedValuesInSheet];

    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(240, 16, 80, 32)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r";
    okButton.target = self;
    okButton.action = @selector(configOK:);
    [content addSubview:okButton];

    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 16, 80, 32)];
    cancelButton.title = @"Cancel";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\033";
    cancelButton.target = self;
    cancelButton.action = @selector(configCancel:);
    [content addSubview:cancelButton];

    return _configSheet;
}

- (void)dismissSheet {
    if (!_configSheet) return;
    NSWindow *parent = _configSheet.sheetParent;
    if (parent) {
        [parent endSheet:_configSheet];
    } else {
        [_configSheet close];
    }
    _configSheet = nil;
}

- (IBAction)configOK:(id)sender {
    uint32_t preset = (uint32_t)_presetPopup.selectedItem.tag;
    DriftFrameRate frameRate = (DriftFrameRate)_frameRatePopup.selectedItem.tag;
    [self savePreset:preset frameRate:frameRate];

    _frameRate = frameRate;
    [self updateAnimationInterval];
    if (_drift && preset != _currentPreset) {
        _currentPreset = preset;
        drift_set_preset(_drift, preset);
    }
    // Other processes' DriftV2 views (e.g. one per display) pick the change
    // up within a couple of seconds via -pollSettings.

    [self dismissSheet];
}

- (IBAction)configCancel:(id)sender {
    [self dismissSheet];
}

@end
