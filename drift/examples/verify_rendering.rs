//! Exercise the real GPU simulation without locking the screen.
//!
//! cargo run -p drift-v2-screensaver --example verify_rendering --release
//!
//! Checks motion at both frame rates, after a long pause, and across the
//! simulation clock rollover. Checks all four screen quadrants at laptop,
//! landscape and portrait sizes. AppKit/Metal layer sizing is tested separately
//! by the native verification host; an offscreen target cannot exercise it.

use std::{path::Path, sync::Arc};

use flux::{render::color::Context as ColorContext, settings::ColorMode, Flux, Settings};

const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

struct Target {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    readback: wgpu::Buffer,
    row_bytes: u32,
    size: wgpu::Extent3d,
}

impl Target {
    fn new(device: &wgpu::Device, width: u32, height: u32) -> Self {
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("verification frame"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let row_bytes = (width * 4).next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT);
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("verification readback"),
            size: u64::from(row_bytes) * u64::from(height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        Self {
            texture,
            view,
            readback,
            row_bytes,
            size,
        }
    }

    fn pixels(&self, device: &wgpu::Device, queue: &wgpu::Queue) -> Vec<u8> {
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
        encoder.copy_texture_to_buffer(
            self.texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &self.readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(self.row_bytes),
                    rows_per_image: None,
                },
            },
            self.size,
        );
        queue.submit(Some(encoder.finish()));
        let slice = self.readback.slice(..);
        slice.map_async(wgpu::MapMode::Read, |result| result.expect("map GPU frame"));
        device
            .poll(wgpu::PollType::wait_indefinitely())
            .expect("wait for GPU frame");
        let pixels = slice
            .get_mapped_range()
            .chunks(self.row_bytes as usize)
            .flat_map(|row| &row[..self.size.width as usize * 4])
            .copied()
            .collect();
        self.readback.unmap();
        pixels
    }
}

fn animate(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    target: &Target,
    flux: &mut Flux,
    timestamp: f64,
) {
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
    flux.animate(device, queue, &mut encoder, &target.view, None, timestamp);
    queue.submit(Some(encoder.finish()));
}

fn assert_motion(label: &str, before: &[u8], after: &[u8]) {
    let changed = before
        .chunks_exact(4)
        .zip(after.chunks_exact(4))
        .filter(|(a, b)| (0..3).any(|c| a[c].abs_diff(b[c]) > 2))
        .count();
    let fraction = changed as f64 / (before.len() / 4) as f64;
    assert!(
        fraction > 0.001,
        "{label}: animation stalled ({fraction:.6} changed)"
    );
    println!("PASS {label}: {:.2}% pixels changed", fraction * 100.0);
}

fn assert_coverage(label: &str, pixels: &[u8], size: wgpu::Extent3d) {
    let mut lit = [0usize; 4];
    let mut total = [0usize; 4];
    let mut edge_lit = [0usize; 4];
    let mut edge_total = [0usize; 4];
    for (i, pixel) in pixels.chunks_exact(4).enumerate() {
        let x = i as u32 % size.width;
        let y = i as u32 / size.width;
        let quadrant = usize::from(x >= size.width / 2) + 2 * usize::from(y >= size.height / 2);
        total[quadrant] += 1;
        let visible = pixel[..3].iter().any(|&c| c > 8);
        if visible {
            lit[quadrant] += 1;
        }
        for (edge, inside) in [
            x < size.width / 10,
            x >= size.width * 9 / 10,
            y < size.height / 10,
            y >= size.height * 9 / 10,
        ]
        .into_iter()
        .enumerate()
        {
            if inside {
                edge_total[edge] += 1;
                if visible {
                    edge_lit[edge] += 1;
                }
            }
        }
    }
    let fractions: Vec<_> = lit
        .iter()
        .zip(total)
        .map(|(&n, d)| n as f64 / d as f64)
        .collect();
    assert!(
        fractions.iter().all(|&f| f > 0.001),
        "{label}: blank quadrant: {fractions:?}"
    );
    let edges: Vec<_> = edge_lit
        .iter()
        .zip(edge_total)
        .map(|(&n, d)| n as f64 / d as f64)
        .collect();
    assert!(
        edges.iter().all(|&f| f > 0.001),
        "{label}: blank edge band: {edges:?}"
    );
    println!("PASS {label}: lit pixels in all quadrants {fractions:.3?}, edges {edges:.3?}");
}

fn engine(device: &wgpu::Device, queue: &wgpu::Queue, target: &Target, scale: f32) -> Flux {
    let logical_width = (target.size.width as f32 / scale).round() as u32;
    let logical_height = (target.size.height as f32 / scale).round() as u32;
    // Match the native wrapper's small-view settings.
    let (fluid_size, view_scale) = if logical_width.min(logical_height) < 200 {
        (48, 0.7)
    } else if logical_width.min(logical_height) < 600 {
        (80, 1.1)
    } else {
        (128, 1.6)
    };
    let settings = Arc::new(Settings {
        fluid_size,
        view_scale,
        seed: Some("1337".into()),
        color_mode: ColorMode::EmbeddedImage,
        ..Default::default()
    });
    let mut flux = Flux::new(
        device,
        queue,
        FORMAT,
        logical_width,
        logical_height,
        target.size.width,
        target.size.height,
        &settings,
    )
    .expect("create Flux");
    let palette = ColorContext::decode_color_texture(include_bytes!("../colors/silver.png"))
        .unwrap_or_else(|error| panic!("decode Silver palette: {error}"));
    flux.sample_colors_from_image(device, queue, &palette);
    flux
}

fn main() {
    let instance = wgpu::Instance::default();
    let adapter =
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .expect("GPU adapter required for rendering verification");
    println!("GPU: {:?}", adapter.get_info());
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("Drift rendering verification"),
        required_features: wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
            | wgpu::Features::FLOAT32_FILTERABLE,
        required_limits: wgpu::Limits::default().using_resolution(adapter.limits()),
        ..Default::default()
    }))
    .expect("GPU device");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/verification");
    std::fs::create_dir_all(&out).expect("create verification directory");

    let args: Vec<String> = std::env::args().skip(1).collect();
    let clock_only = args.iter().any(|arg| arg == "--clock-only");
    let fps: u32 = args
        .windows(2)
        .find(|arg| arg[0] == "--fps")
        .map(|arg| arg[1].parse().expect("integer fps"))
        .unwrap_or(60);
    assert!(fps > 0, "--fps must be greater than zero");
    if !clock_only {
        for (label, width, height, scale) in [
            ("laptop-retina", 3024, 1964, 2.0),
            ("landscape", 2560, 1440, 1.0),
            ("portrait", 1440, 2560, 1.0),
        ] {
            let target = Target::new(&device, width, height);
            let mut flux = engine(&device, &queue, &target, scale);
            let mut timestamp = 0.0;
            for _ in 0..180 {
                timestamp += 1000.0 / 60.0;
                animate(&device, &queue, &target, &mut flux, timestamp);
            }
            let before = target.pixels(&device, &queue);
            assert_coverage(label, &before, target.size);
            for fps in [60.0, 30.0] {
                let previous = target.pixels(&device, &queue);
                for _ in 0..30 {
                    timestamp += 1000.0 / fps;
                    animate(&device, &queue, &target, &mut flux, timestamp);
                }
                let current = target.pixels(&device, &queue);
                assert_motion(&format!("{label} at {fps} fps"), &previous, &current);
            }
            let before_pause = target.pixels(&device, &queue);
            timestamp += 8.0 * 60.0 * 60.0 * 1000.0;
            for _ in 0..30 {
                timestamp += 1000.0 / 60.0;
                animate(&device, &queue, &target, &mut flux, timestamp);
            }
            let after_pause = target.pixels(&device, &queue);
            assert_motion(
                &format!("{label} after eight-hour pause"),
                &before_pause,
                &after_pause,
            );
            assert_coverage(label, &after_pause, target.size);
            image::save_buffer(
                out.join(format!("{label}.png")),
                &after_pause,
                width,
                height,
                image::ColorType::Rgba8,
            )
            .expect("save verification frame");
        }
    }
    if args.iter().any(|arg| arg == "--sizes-only") {
        return;
    }
    // Render a normal laptop simulation to a smaller physical target so that a
    // 17-minute simulated run is inexpensive without changing the physics.
    let target = Target::new(&device, 320, 200);
    let mut flux = engine(&device, &queue, &target, 0.25);
    let mut frame = 1;
    while frame <= 1010 * fps {
        animate(
            &device,
            &queue,
            &target,
            &mut flux,
            frame as f64 * 1000.0 / f64::from(fps),
        );
        if [10 * fps, 100 * fps, 500 * fps, 990 * fps, 1010 * fps].contains(&frame) {
            let before = target.pixels(&device, &queue);
            let seconds = frame / fps;
            let label = format!("clock stress {seconds}s at {fps} fps");
            let lit = before
                .chunks_exact(4)
                .filter(|pixel| pixel[..3].iter().any(|&c| c > 8))
                .count();
            assert!(lit > 10, "{label}: blank frame");
            // Natural low-velocity regions can be dark. Test continued movement
            // over the next 30 frames instead of requiring every edge to glow.
            for _ in 0..30 {
                frame += 1;
                animate(
                    &device,
                    &queue,
                    &target,
                    &mut flux,
                    frame as f64 * 1000.0 / f64::from(fps),
                );
            }
            let after = target.pixels(&device, &queue);
            assert_motion(&label, &before, &after);
            image::save_buffer(
                out.join(format!("clock-{fps}fps-{seconds}s.png")),
                &after,
                target.size.width,
                target.size.height,
                image::ColorType::Rgba8,
            )
            .expect("save stress frame");
        }
        // Bound the number of queued frames and their staging allocations.
        if frame % 100 == 0 {
            device
                .poll(wgpu::PollType::wait_indefinitely())
                .expect("wait for clock stress frames");
        }
        frame += 1;
    }
    println!("All GPU checks passed; frames saved to {}", out.display());
}
