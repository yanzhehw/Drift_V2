#import "DriftV2ScreenSaverView.h"
#import "drift_v2_screensaver.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static NSString *const kDriftModuleName = @"com.local.DriftV2ScreenSaver";
static NSString *const kPresetKey       = @"DriftPreset";

#define DLOG(fmt, ...) NSLog(@"[Drift_V2] " fmt, ##__VA_ARGS__)

@interface DriftV2ScreenSaverView () {
    DriftHandle *_drift;
    BOOL _isPreview;
    BOOL _isOccluded;       // Set via explicit occlusion-change notification only.
    uint32_t _currentPreset; // Last preset applied to _drift.
    NSInteger _pollCounter;  // Frame counter for periodic defaults re-check.
}
@property (nonatomic, strong) NSWindow *configSheet;
@property (nonatomic, strong) NSPopUpButton *presetPopup;
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

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    DLOG(@"makeBackingLayer: %@ device=%@", layer, layer.device);
    return layer;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    DLOG(@"initWithFrame: %@ isPreview:%d", NSStringFromRect(frame), isPreview);
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _isPreview = isPreview;
        // Thumbnails/previews animate at 20 Hz — plenty smooth, ~3x less work.
        [self setAnimationTimeInterval:(isPreview ? (1.0 / 20.0) : (1.0 / 60.0))];
        [self setWantsLayer:YES];
        DLOG(@"init done, layer=%@ class=%@", self.layer, [self.layer class]);
    }
    return self;
}

- (void)dealloc {
    DLOG(@"dealloc");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_drift) {
        drift_destroy(_drift);
        _drift = NULL;
    }
}

#pragma mark - Preferences

- (uint32_t)savedPreset {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:kDriftModuleName];
    [defaults registerDefaults:@{ kPresetKey: @(DriftPresetOriginal) }];
    return (uint32_t)[defaults integerForKey:kPresetKey];
}

- (void)savePreset:(uint32_t)preset {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:kDriftModuleName];
    [defaults setInteger:preset forKey:kPresetKey];
    [defaults synchronize];
}

#pragma mark - ScreenSaverView

- (void)startAnimation {
    DLOG(@"startAnimation, bounds=%@, layer=%@ class=%@",
         NSStringFromRect(self.bounds), self.layer, [self.layer class]);
    [super startAnimation];

    // Preview mode shows the static thumbnail — no engine, no animation.
    if (_isPreview) return;

    if (!_drift) {
        NSSize px = [self convertSizeToBacking:self.bounds.size];
        CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;

        CALayer *layer = self.layer;
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            CAMetalLayer *metalLayer = (CAMetalLayer *)layer;
            metalLayer.contentsScale = scale;
            metalLayer.drawableSize = CGSizeMake(px.width, px.height);
            DLOG(@"Metal layer drawableSize=%.0fx%.0f", px.width, px.height);
        } else {
            DLOG(@"WARNING: layer is NOT CAMetalLayer: %@", [layer class]);
        }

        uint32_t preset = [self savedPreset];
        _currentPreset = preset;
        DLOG(@"drift_create: px=%.0fx%.0f scale=%.1f preset=%u preview=%d",
             px.width, px.height, scale, preset, _isPreview);
        _drift = drift_create((__bridge void *)self,
                              (uint32_t)px.width,
                              (uint32_t)px.height,
                              (float)scale,
                              preset,
                              _isPreview ? 1u : 0u);
        DLOG(@"drift_create returned: %p", _drift);
    }
}

- (void)stopAnimation {
    DLOG(@"stopAnimation");
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
    if (_isPreview) return;  // preview shows the static thumbnail
    if (!_drift) return;

    // Periodically (~every 1s at 60 Hz) re-read the saved preset from
    // ScreenSaverDefaults and apply it if it changed. This is the simplest
    // reliable way to propagate preset changes from the Settings sheet
    // (different process) to the wallpaper renderer — no IPC, no Darwin
    // notifications, just polling. Cost is one defaults-read per second.
    if (++_pollCounter >= 60) {
        _pollCounter = 0;
        ScreenSaverDefaults *defaults =
            [ScreenSaverDefaults defaultsForModuleWithName:kDriftModuleName];
        [defaults synchronize];
        uint32_t newPreset = (uint32_t)[defaults integerForKey:kPresetKey];
        if (newPreset != _currentPreset) {
            DLOG(@"poll: preset changed %u → %u, applying",
                 _currentPreset, newPreset);
            _currentPreset = newPreset;
            drift_set_preset(_drift, newPreset);
            // Skip rendering this tick — give the GPU a clean breath after
            // rebuilding the engine. Next tick (~16ms later) will render with
            // the new preset's textures fully resident.
            return;
        }
    }

    // In wallpaper mode, skip rendering when we've been explicitly told the
    // window is occluded. Only act on a *positive* occlusion signal — a
    // transiently-zero occlusionState during window setup/teardown should NOT
    // cause us to stop rendering (that was the cause of the black-screen bug).
    if (_isOccluded) return;

    drift_animate(_drift);
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
}

// Called by AppKit when the window's occlusion state changes. We subscribe in
// -viewDidMoveToWindow.
- (void)windowOcclusionStateDidChange:(NSNotification *)note {
    NSWindow *w = self.window;
    if (!w) { _isOccluded = NO; return; }
    BOOL visible = (w.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _isOccluded = !visible;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Always start as visible; rely on notifications to tell us otherwise.
    _isOccluded = NO;

    NSWindow *w = self.window;
    if (w) {
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(windowOcclusionStateDidChange:)
                   name:NSWindowDidChangeOcclusionStateNotification
                 object:w];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];

    CALayer *layer = self.layer;
    if ([layer isKindOfClass:[CAMetalLayer class]]) {
        NSSize px = [self convertSizeToBacking:newSize];
        CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
        CAMetalLayer *metalLayer = (CAMetalLayer *)layer;
        metalLayer.contentsScale = scale;
        metalLayer.drawableSize = CGSizeMake(px.width, px.height);
    }

    if (_drift) {
        NSSize px = [self convertSizeToBacking:newSize];
        CGFloat scale = self.window ? self.window.backingScaleFactor : 2.0;
        drift_resize(_drift,
                     (uint32_t)px.width,
                     (uint32_t)px.height,
                     (float)scale);
    }
}

- (BOOL)isOpaque {
    return YES;
}

#pragma mark - Configuration Sheet

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    if (_configSheet) {
        NSInteger idx = [_presetPopup indexOfItemWithTag:(NSInteger)[self savedPreset]];
        if (idx < 0) idx = 0;
        [_presetPopup selectItemAtIndex:idx];
        return _configSheet;
    }

    NSRect sheetFrame = NSMakeRect(0, 0, 320, 130);
    _configSheet = [[NSWindow alloc] initWithContentRect:sheetFrame
                                               styleMask:NSWindowStyleMaskTitled
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
    _configSheet.title = @"Drift_V2 Settings";

    NSView *content = _configSheet.contentView;

    NSTextField *label = [NSTextField labelWithString:@"Color Scheme:"];
    label.frame = NSMakeRect(20, 80, 100, 20);
    [content addSubview:label];

    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 78, 170, 24)
                                              pullsDown:NO];
    // Only expose the three image-based presets — these are the ones that
    // ship with PNG palettes in colors/ and are reliably rendered. Each item
    // carries its DriftPreset enum value as its tag so reordering the menu
    // doesn't break the index→enum mapping.
    NSArray<NSDictionary *> *presets = @[
        @{ @"title": @"Gumdrop", @"tag": @(DriftPresetGumdrop) },
        @{ @"title": @"Silver",  @"tag": @(DriftPresetSilver)  },
        @{ @"title": @"Freedom", @"tag": @(DriftPresetFreedom) },
    ];
    for (NSDictionary *p in presets) {
        [_presetPopup addItemWithTitle:p[@"title"]];
        [[_presetPopup lastItem] setTag:[p[@"tag"] integerValue]];
    }
    // Select the menu item whose tag matches the saved preset (fall back to
    // the first item if the saved preset is no longer in the menu).
    uint32_t saved = [self savedPreset];
    NSInteger initialIndex = [_presetPopup indexOfItemWithTag:(NSInteger)saved];
    if (initialIndex < 0) initialIndex = 0;
    [_presetPopup selectItemAtIndex:initialIndex];
    [content addSubview:_presetPopup];

    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 20, 80, 32)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r";
    okButton.target = self;
    okButton.action = @selector(configOK:);
    [content addSubview:okButton];

    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(130, 20, 80, 32)];
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
    NSInteger selectedIndex = _presetPopup.indexOfSelectedItem;
    // Map the popup index → DriftPreset enum value via the title's tag.
    uint32_t preset = (uint32_t)[_presetPopup itemAtIndex:selectedIndex].tag;
    [self savePreset:preset];

    if (_drift) {
        _currentPreset = preset;
        drift_set_preset(_drift, preset);
    }
    // Other processes' DriftV2 views (each display in wallpaper mode) will
    // detect the change within ~1 second via the polling loop in
    // -animateOneFrame and apply it themselves.

    [self dismissSheet];
}

- (IBAction)configCancel:(id)sender {
    [self dismissSheet];
}

@end
