//! macOS screen saver FFI wrapper for Drift_V2.
//!
//! Exposes a small C ABI that an Objective-C `ScreenSaverView` subclass
//! can drive. The view hands us an `NSView*` backed by a `CAMetalLayer`
//! and we render into it via wgpu's Metal backend.

use std::ffi::c_void;
use std::io::Write;
use std::ptr::NonNull;
use std::sync::Arc;
use std::time::Instant;

use flux::render::color::Context as ColorContext;
use flux::settings::{ColorMode, ColorPreset};
use flux::{Flux, Settings};
use raw_window_handle::{
    AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle,
};

fn log_msg(msg: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/drift-v2-screensaver.log")
    {
        let _ = writeln!(f, "[{}] {}", chrono_simple(), msg);
    }
}

fn chrono_simple() -> String {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", d.as_secs(), d.subsec_millis())
}

// Embedded color palette PNGs. Baked into the static library so the
// sandboxed screen saver needs no disk access.
static GUMDROP_PNG: &[u8] = include_bytes!("../colors/gumdrop.png");
static SILVER_PNG: &[u8] = include_bytes!("../colors/silver.png");
static FREEDOM_PNG: &[u8] = include_bytes!("../colors/freedom.png");

// Note: we previously shared a single `wgpu::Instance` across all DriftHandles
// via OnceLock. That caused intermittent multi-display rendering failures
// (one monitor going black for certain presets). Each handle now owns its
// own Instance — small extra cost, but reliable.

/// Preset identifiers. Must stay in sync with the Objective-C side.
#[repr(u32)]
#[derive(Copy, Clone, Debug)]
pub enum DriftPreset {
    Original = 0,
    Plasma = 1,
    Poolside = 2,
    Gumdrop = 3,
    Silver = 4,
    Freedom = 5,
}

impl DriftPreset {
    fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::Plasma,
            2 => Self::Poolside,
            3 => Self::Gumdrop,
            4 => Self::Silver,
            5 => Self::Freedom,
            _ => Self::Original,
        }
    }

    fn color_mode(self) -> ColorMode {
        match self {
            Self::Original => ColorMode::Preset(ColorPreset::Original),
            Self::Plasma => ColorMode::Preset(ColorPreset::Plasma),
            Self::Poolside => ColorMode::Preset(ColorPreset::Poolside),
            Self::Gumdrop | Self::Silver | Self::Freedom => ColorMode::EmbeddedImage,
        }
    }

    fn image_bytes(self) -> Option<&'static [u8]> {
        match self {
            Self::Gumdrop => Some(GUMDROP_PNG),
            Self::Silver => Some(SILVER_PNG),
            Self::Freedom => Some(FREEDOM_PNG),
            _ => None,
        }
    }
}

pub struct DriftHandle {
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,

    flux: Flux,
    start: Instant,
    scale_factor: f32,
    is_preview: bool,
}

impl DriftHandle {
    fn new(
        ns_view: NonNull<c_void>,
        physical_width: u32,
        physical_height: u32,
        scale_factor: f32,
        preset: DriftPreset,
        is_preview: bool,
    ) -> Result<Self, String> {
        log_msg(&format!("DriftHandle::new size={}x{} scale={} preset={:?} preview={}",
                         physical_width, physical_height, scale_factor, preset, is_preview));
        let instance = wgpu::Instance::default();

        let display_handle = RawDisplayHandle::AppKit(AppKitDisplayHandle::new());
        let window_handle = RawWindowHandle::AppKit(AppKitWindowHandle::new(ns_view));

        let surface_target = wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: display_handle,
            raw_window_handle: window_handle,
        };

        let surface = unsafe {
            instance
                .create_surface_unsafe(surface_target)
                .map_err(|e| format!("create_surface_unsafe: {e}"))?
        };

        log_msg("surface created OK");

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: Some(&surface),
        }))
        .map_err(|e| format!("request_adapter: {e}"))?;

        let limits = wgpu::Limits::default().using_resolution(adapter.limits());
        let features = wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
            | wgpu::Features::FLOAT32_FILTERABLE;

        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("drift-v2:device"),
            required_features: features,
            required_limits: limits,
            memory_hints: wgpu::MemoryHints::Performance,
            trace: wgpu::Trace::Off,
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
        }))
        .map_err(|e| format!("request_device: {e}"))?;

        log_msg("device created OK");

        let caps = surface.get_capabilities(&adapter);
        let format = pick_format(&caps);
        log_msg(&format!("format={:?} present_modes={:?}", format, caps.present_modes));

        let width = physical_width.max(1);
        let height = physical_height.max(1);
        let sf = if scale_factor > 0.0 { scale_factor } else { 1.0 };

        // Prefer Fifo (vsync, battery/CPU friendly) for a screensaver workload.
        // Fall back to Mailbox/Immediate only if Fifo is unavailable.
        let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Fifo) {
            wgpu::PresentMode::Fifo
        } else if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) {
            wgpu::PresentMode::Mailbox
        } else {
            wgpu::PresentMode::Immediate
        };
        log_msg(&format!("present_mode={:?}", present_mode));

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width,
            height,
            present_mode,
            desired_maximum_frame_latency: 2,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&device, &config);
        log_msg("surface configured OK");

        let flux = Self::create_flux(&device, &queue, format, width, height, sf, preset, is_preview)?;
        log_msg("engine created OK");

        Ok(Self {
            device,
            queue,
            surface,
            config,
            flux,
            start: Instant::now(),
            scale_factor: sf,
            is_preview,
        })
    }

    fn create_flux(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        physical_width: u32,
        physical_height: u32,
        scale_factor: f32,
        preset: DriftPreset,
        is_preview: bool,
    ) -> Result<Flux, String> {
        let logical_width = ((physical_width as f32) / scale_factor).round().max(1.0) as u32;
        let logical_height = ((physical_height as f32) / scale_factor).round().max(1.0) as u32;

        let settings = Arc::new(build_settings(
            preset,
            logical_width,
            logical_height,
            is_preview,
        ));

        let mut flux = Flux::new(
            device, queue, format,
            logical_width, logical_height,
            physical_width, physical_height,
            &settings,
        )
        .map_err(|e| format!("Flux::new: {e}"))?;

        if let Some(png_bytes) = preset.image_bytes() {
            match ColorContext::decode_color_texture(png_bytes) {
                Ok(rgba) => {
                    flux.sample_colors_from_image(device, queue, &rgba);
                }
                Err(e) => {
                    eprintln!("drift-v2: failed to decode palette: {e}");
                }
            }
        }

        Ok(flux)
    }

    fn apply_preset(&mut self, preset: DriftPreset) {
        match Self::create_flux(
            &self.device, &self.queue,
            self.config.format,
            self.config.width, self.config.height,
            self.scale_factor, preset, self.is_preview,
        ) {
            Ok(flux) => {
                self.flux = flux;
                self.start = Instant::now();
                // Flush any queued texture/buffer writes (color texture upload,
                // color buffer fill, line uniforms) so the very next animate()
                // sees a fully-populated GPU state. Without this, the first
                // frame after a preset change can sample an empty texture and
                // the display gets stuck rendering nothing.
                self.queue.submit(std::iter::empty());
            }
            Err(e) => {
                eprintln!("drift-v2: apply_preset failed: {e}");
            }
        }
    }

    fn resize(&mut self, physical_width: u32, physical_height: u32, scale_factor: f32) {
        let width = physical_width.max(1);
        let height = physical_height.max(1);
        let sf = if scale_factor > 0.0 { scale_factor } else { 1.0 };
        self.scale_factor = sf;

        if width == self.config.width && height == self.config.height {
            return;
        }
        self.config.width = width;
        self.config.height = height;
        self.surface.configure(&self.device, &self.config);

        let logical_width = ((width as f32) / sf).round().max(1.0) as u32;
        let logical_height = ((height as f32) / sf).round().max(1.0) as u32;

        self.flux.resize(
            &self.device, &self.queue,
            logical_width, logical_height,
            width, height,
        );
    }

    fn animate(&mut self) {
        let frame = match self.surface.get_current_texture() {
            Ok(f) => f,
            Err(wgpu::SurfaceError::Outdated | wgpu::SurfaceError::Lost) => {
                log_msg("surface outdated/lost, reconfiguring");
                self.surface.configure(&self.device, &self.config);
                return;
            }
            Err(e) => {
                log_msg(&format!("surface error: {e:?}"));
                return;
            }
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("drift-v2:encoder"),
            });

        let timestamp_ms = self.start.elapsed().as_secs_f64() * 1000.0;
        self.flux.animate(
            &self.device, &self.queue, &mut encoder, &view, None, timestamp_ms,
        );

        self.queue.submit(Some(encoder.finish()));
        frame.present();
    }
}

/// Scale fluid grid resolution to the view size.
///
/// The default fluid_size=128 is tuned for full-screen rendering. For the
/// System Settings thumbnail (~143x80) or other small views, a 128x128
/// compute texture is wasted work — the simulation can't visibly use that
/// much detail on so few pixels. Keep grid_spacing and view_scale at their
/// defaults so the visual composition (line density and size) looks the
/// same across scales.
fn build_settings(
    preset: DriftPreset,
    logical_width: u32,
    logical_height: u32,
    is_preview: bool,
) -> Settings {
    let min_dim = logical_width.min(logical_height);

    // fluid_size: simulation resolution. Cheaper on small views.
    // view_scale: counteracts get_line_scale_factor() producing a large factor
    //   on tiny views — without this, lines look over-sized ("zoomed in") on
    //   the thumbnail. A smaller view_scale shrinks line_width + line_length
    //   back toward the proportions seen at full-screen.
    let (fluid_size, view_scale) = if is_preview || min_dim < 200 {
        (48u32, 0.7f32) // thumbnail / tiny preview
    } else if min_dim < 600 {
        (80u32, 1.1f32) // small window preview
    } else {
        (128u32, 1.6f32) // default — full-screen / wallpaper mode
    };

    Settings {
        seed: Some("1337".into()),
        color_mode: preset.color_mode(),
        fluid_size,
        view_scale,
        ..Default::default()
    }
}

fn pick_format(caps: &wgpu::SurfaceCapabilities) -> wgpu::TextureFormat {
    let preferred = [
        wgpu::TextureFormat::Bgra8Unorm,
        wgpu::TextureFormat::Rgba8Unorm,
        wgpu::TextureFormat::Bgra8UnormSrgb,
        wgpu::TextureFormat::Rgba8UnormSrgb,
    ];
    for f in &preferred {
        if caps.formats.contains(f) {
            return *f;
        }
    }
    caps.formats[0]
}

// ---------- C ABI ----------

#[no_mangle]
pub unsafe extern "C" fn drift_create(
    ns_view: *mut c_void,
    physical_width: u32,
    physical_height: u32,
    scale_factor: f32,
    preset: u32,
    is_preview: u32,
) -> *mut DriftHandle {
    log_msg(&format!("drift_create called: view={:?} {}x{} scale={} preset={} preview={}",
                     ns_view, physical_width, physical_height, scale_factor, preset, is_preview));
    let Some(view) = NonNull::new(ns_view) else {
        log_msg("drift_create: NULL view!");
        return std::ptr::null_mut();
    };
    match DriftHandle::new(view, physical_width, physical_height, scale_factor, DriftPreset::from_u32(preset), is_preview != 0) {
        Ok(h) => {
            log_msg("drift_create: success");
            Box::into_raw(Box::new(h))
        }
        Err(e) => {
            log_msg(&format!("drift_create FAILED: {e}"));
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn drift_animate(handle: *mut DriftHandle) {
    if let Some(h) = handle.as_mut() { h.animate(); }
}

#[no_mangle]
pub unsafe extern "C" fn drift_resize(handle: *mut DriftHandle, physical_width: u32, physical_height: u32, scale_factor: f32) {
    if let Some(h) = handle.as_mut() { h.resize(physical_width, physical_height, scale_factor); }
}

#[no_mangle]
pub unsafe extern "C" fn drift_set_preset(handle: *mut DriftHandle, preset: u32) {
    if let Some(h) = handle.as_mut() { h.apply_preset(DriftPreset::from_u32(preset)); }
}

#[no_mangle]
pub unsafe extern "C" fn drift_destroy(handle: *mut DriftHandle) {
    if !handle.is_null() { drop(Box::from_raw(handle)); }
}
