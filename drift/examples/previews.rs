//! Render a still of every color scheme for the README gallery.
//!
//! Runs the engine offscreen with the screen saver's full-screen settings on
//! a 1440x900 Retina view, lets each scheme flow for a few seconds from the
//! same seed, then scales the last frame down into drift/previews/.
//!
//! Usage:
//!     cargo run -p drift-v2-screensaver --example previews --release
//!     cargo run -p drift-v2-screensaver --example previews --release -- aurora

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;
use std::sync::Arc;

use flux::render::color::Context as ColorContext;
use flux::settings::{ColorMode, ColorPreset};
use flux::{Flux, Settings};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;

const LOGICAL_WIDTH: u32 = 1440;
const LOGICAL_HEIGHT: u32 = 900;
const SCALE_FACTOR: u32 = 2;
const OUTPUT_WIDTH: u32 = 720;
const OUTPUT_HEIGHT: u32 = 450;
const SECONDS: u32 = 20;
const FPS: u32 = 60;
const JPEG_QUALITY: u8 = 85;
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

// Same order as the Options menu.
static PRESETS: &[(&str, ColorMode, Option<&[u8]>)] = &[
    ("original", ColorMode::Preset(ColorPreset::Original), None),
    ("plasma", ColorMode::Preset(ColorPreset::Plasma), None),
    ("poolside", ColorMode::Preset(ColorPreset::Poolside), None),
    ("gumdrop", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/gumdrop.png"))),
    ("silver", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/silver.png"))),
    ("freedom", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/freedom.png"))),
    ("space_gray", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/space_gray.png"))),
    ("aurora", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/aurora.png"))),
    ("atlas", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/atlas.png"))),
    ("emerald", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/emerald.png"))),
    ("glacier", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/glacier.png"))),
    ("ember", ColorMode::EmbeddedImage, Some(include_bytes!("../colors/ember.png"))),
];

fn main() {
    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
        .expect("request_adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("drift-v2:previews"),
        required_features: wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
            | wgpu::Features::FLOAT32_FILTERABLE,
        required_limits: wgpu::Limits::default().using_resolution(adapter.limits()),
        memory_hints: wgpu::MemoryHints::Performance,
        trace: wgpu::Trace::Off,
        experimental_features: wgpu::ExperimentalFeatures::disabled(),
    }))
    .expect("request_device");

    let width = LOGICAL_WIDTH * SCALE_FACTOR;
    let height = LOGICAL_HEIGHT * SCALE_FACTOR;
    let size = wgpu::Extent3d { width, height, depth_or_array_layers: 1 };

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("drift-v2:previews:frame"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    let row_bytes = width * 4;
    let padded_row_bytes = row_bytes.next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT);
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("drift-v2:previews:readback"),
        size: (padded_row_bytes * height) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    let out_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("previews");
    std::fs::create_dir_all(&out_dir).expect("create previews dir");

    let names: Vec<String> = std::env::args().skip(1).collect();
    for name in &names {
        if !PRESETS.iter().any(|(preset, ..)| preset == name) {
            panic!("unknown color scheme {name:?}");
        }
    }

    for (name, color_mode, palette) in PRESETS {
        if !names.is_empty() && !names.iter().any(|n| n == name) {
            continue;
        }
        // Matches build_settings() in src/lib.rs for full-screen views.
        let settings = Arc::new(Settings {
            seed: Some("1337".into()),
            color_mode: color_mode.clone(),
            fluid_size: 128,
            view_scale: 1.6,
            ..Default::default()
        });
        let mut flux = Flux::new(
            &device, &queue, FORMAT,
            LOGICAL_WIDTH, LOGICAL_HEIGHT,
            width, height,
            &settings,
        )
        .expect("Flux::new");
        if let Some(png_bytes) = palette {
            let rgba = ColorContext::decode_color_texture(png_bytes)
                .unwrap_or_else(|e| panic!("decode {name} palette: {e}"));
            flux.sample_colors_from_image(&device, &queue, &rgba);
        }

        // Start one frame in, like the screen saver's first tick.
        for frame in 1..=SECONDS * FPS {
            let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("drift-v2:previews:encoder"),
            });
            let timestamp_ms = frame as f64 * 1000.0 / FPS as f64;
            flux.animate(&device, &queue, &mut encoder, &view, None, timestamp_ms);
            queue.submit(Some(encoder.finish()));
            device.poll(wgpu::PollType::wait_indefinitely()).expect("poll");
        }

        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("drift-v2:previews:copy"),
        });
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_row_bytes),
                    rows_per_image: None,
                },
            },
            size,
        );
        queue.submit(Some(encoder.finish()));

        let slice = readback.slice(..);
        slice.map_async(wgpu::MapMode::Read, |result| result.expect("map readback"));
        device.poll(wgpu::PollType::wait_indefinitely()).expect("poll");
        let pixels: Vec<u8> = slice
            .get_mapped_range()
            .chunks(padded_row_bytes as usize)
            .flat_map(|row| &row[..row_bytes as usize])
            .copied()
            .collect();
        readback.unmap();

        // Lines are blended additively, so alpha is meaningless: drop it.
        let frame = image::RgbaImage::from_raw(width, height, pixels).expect("frame size");
        let still = image::imageops::resize(&frame, OUTPUT_WIDTH, OUTPUT_HEIGHT, FilterType::Lanczos3);
        let still = image::DynamicImage::ImageRgba8(still).into_rgb8();

        let path = out_dir.join(format!("{name}.jpg"));
        let file = BufWriter::new(File::create(&path).expect("create preview"));
        JpegEncoder::new_with_quality(file, JPEG_QUALITY)
            .encode_image(&still)
            .expect("encode preview");
        println!("wrote {}", path.display());
    }
}
