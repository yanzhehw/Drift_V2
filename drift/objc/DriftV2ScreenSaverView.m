#import "DriftV2ScreenSaverView.h"
#import "drift_v2_screensaver.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static NSString *const kDriftModuleName = @"com.local.DriftV2ScreenSaver";
static NSString *const kPresetKey       = @"DriftPreset";

#define DLOG(fmt, ...) NSLog(@"[Drift_V2] " fmt, ##__VA_ARGS__)

@interface DriftV2ScreenSaverView () {
    DriftHandle *_drift;
}
@property (nonatomic, strong) NSWindow *configSheet;
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@end

@implementation DriftV2ScreenSaverView

#pragma mark - Layer setup

- (CALayer *)makeBackingLayer {
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
        [self setAnimationTimeInterval:1.0 / 60.0];
        [self setWantsLayer:YES];
        DLOG(@"init done, layer=%@ class=%@", self.layer, [self.layer class]);
    }
    return self;
}

- (void)dealloc {
    DLOG(@"dealloc");
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
        DLOG(@"drift_create: px=%.0fx%.0f scale=%.1f preset=%u",
             px.width, px.height, scale, preset);
        _drift = drift_create((__bridge void *)self,
                              (uint32_t)px.width,
                              (uint32_t)px.height,
                              (float)scale,
                              preset);
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
    if (_drift) {
        drift_animate(_drift);
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
        [_presetPopup selectItemAtIndex:[self savedPreset]];
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
    [_presetPopup addItemsWithTitles:@[
        @"Original",
        @"Plasma",
        @"Poolside",
        @"Gumdrop",
        @"Silver",
        @"Freedom"
    ]];
    [_presetPopup selectItemAtIndex:[self savedPreset]];
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
    uint32_t preset = (uint32_t)_presetPopup.indexOfSelectedItem;
    [self savePreset:preset];

    if (_drift) {
        drift_set_preset(_drift, preset);
    }

    [self dismissSheet];
}

- (IBAction)configCancel:(id)sender {
    [self dismissSheet];
}

@end
