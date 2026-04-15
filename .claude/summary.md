# Drift_V2 — Project Onboarding Summary

macOS screensaver built on the Flux fluid-simulation engine. Rust + Objective-C, rendered via wgpu/Metal. Compiles to a `.saver` bundle installed at `~/Library/Screen Savers/Drift_V2.saver`.

## Workspace Layout

Cargo workspace with 2 members: `flux` (engine, lib crate) and `drift` (FFI wrapper, staticlib crate).

```
Drift_V2/
├── Cargo.toml                   workspace root
├── install.sh                   one-liner installer (curl | bash capable)
├── drift/                       macOS screensaver wrapper
│   ├── Cargo.toml               crate: drift-v2-screensaver (staticlib)
│   ├── src/lib.rs               Rust FFI, DriftHandle lifecycle, preset dispatch
│   ├── objc/
│   │   ├── DriftV2ScreenSaverView.h
│   │   └── DriftV2ScreenSaverView.m   ScreenSaverView subclass, config sheet, prefs
│   ├── include/drift_v2_screensaver.h C header for FFI
│   ├── colors/{gumdrop,silver,freedom}.png  embedded via include_bytes!
│   ├── Info.plist               bundle metadata (CFBundleIdentifier: com.local.DriftV2ScreenSaver)
│   └── build.sh                 dev build + optional install
└── flux/
    ├── Cargo.toml               crate: flux (pub lib)
    ├── src/
    │   ├── lib.rs               module exports
    │   ├── flux.rs              Flux engine: init, animate, resize, update
    │   ├── settings.rs          Settings struct, ColorMode/ColorPreset enums, color wheels
    │   ├── grid.rs, rng.rs      helpers
    │   └── render/
    │       ├── fluid.rs         velocity/pressure/divergence compute
    │       ├── lines.rs         line rendering, color bindings, LineUniforms
    │       ├── color.rs         PNG decode + texture upload
    │       ├── noise.rs, texture.rs, view.rs
    │       └── mod.rs
    └── shader/                  WGSL compute + render shaders
        ├── place_lines.comp.wgsl   color_mode switch lives here
        ├── line.wgsl, endpoint.wgsl
        └── (fluid simulation shaders: advect, diffuse, pressure, etc.)
```

## How it runs

1. macOS loads `Drift_V2.saver` bundle. `NSPrincipalClass` = `DriftV2ScreenSaverView`.
2. `DriftV2ScreenSaverView` (Obj-C) creates a `CAMetalLayer`, then calls `drift_create()` (Rust FFI) with the saved preset.
3. `drift_create` → `DriftHandle::new` → builds wgpu device, surface, and `Flux` engine.
4. `animateOneFrame` (60 Hz) → `drift_animate` → `Flux::animate` → compute + render passes.
5. User clicks Options → `configureSheet` → popup menu → `drift_set_preset` → `DriftHandle::apply_preset` rebuilds Flux with new color mode.

## Key Files to Know

- **[drift/src/lib.rs](../drift/src/lib.rs)** — FFI entry points, `DriftPreset` → `ColorMode` mapping, preset dispatch. Start here when debugging preset/color issues.
- **[drift/objc/DriftV2ScreenSaverView.m](../drift/objc/DriftV2ScreenSaverView.m)** — Obj-C lifecycle, preferences storage (`ScreenSaverDefaults` under `com.local.DriftV2ScreenSaver`, key `DriftPreset`), config sheet UI.
- **[flux/src/settings.rs](../flux/src/settings.rs)** — `ColorMode` enum (`Preset` / `ImageFile` / `EmbeddedImage`), color wheel constants. `From<ColorMode> for u32` produces the shader uniform value.
- **[flux/src/render/lines.rs](../flux/src/render/lines.rs)** — `LineUniforms` (maps to `LineUniforms` in WGSL), `Context::update` (called on settings changes and resize), color buffer/texture binding setup.
- **[flux/shader/place_lines.comp.wgsl](../flux/shader/place_lines.comp.wgsl)** — the `switch uniforms.color_mode` (cases 0/1/2) that drives final line color.

## Color pipeline (for preset work)

- Shader `color_mode` uniform: `0` = velocity procedural, `1` = color wheel buffer, `2` = image texture.
- `DriftPreset` (6 variants) → `ColorMode` via `DriftPreset::color_mode()` in [drift/src/lib.rs](../drift/src/lib.rs).
- `ColorMode` → `u32` for the shader via `From<ColorMode> for u32` in [flux/src/settings.rs](../flux/src/settings.rs).
- Image-preset PNGs are embedded via `include_bytes!` in [drift/src/lib.rs](../drift/src/lib.rs) and decoded + uploaded by `Flux::sample_colors_from_image` → `lines::Context::update_color_bindings`.
- `lines::Context` holds `color_mode` (authoritative) and `line_uniforms.color_mode` (what the GPU sees). `Context::update` now syncs the two before writing.

## Build & install

- Dev: `./drift/build.sh install` (kills legacyScreenSaver/WallpaperAgent so the new bundle reloads).
- One-liner: `./install.sh` — auto-installs Rust if missing, builds, links with clang, code-signs ad-hoc, installs to `~/Library/Screen Savers/`, cleans up.
- Bundle is static-linked: Objective-C shim + Rust staticlib + Metal/ScreenSaver/AppKit frameworks.

## Runtime logs

Rust side writes to `/tmp/drift-v2-screensaver.log` (see `log_msg` in [drift/src/lib.rs](../drift/src/lib.rs)). Obj-C side uses `NSLog` with the `[Drift_V2]` prefix — view via Console.app filtering on `legacyScreenSaver` process.

## Gotchas

- Screensavers on modern macOS run inside `legacyScreenSaver` (or `WallpaperAgent`). After installing, kill those processes to force reload.
- `ScreenSaverDefaults` stores per-module prefs; the module name `com.local.DriftV2ScreenSaver` must match `CFBundleIdentifier` in `Info.plist`.
- `Flux::new` does not read `self.settings.color_mode` for texture bindings — image presets require a separate `sample_colors_from_image` call after construction (done in `DriftHandle::create_flux`).
- `lines::Context::update` is called on resize. It recreates `LineUniforms` from `settings.color_mode`, so keep `settings.color_mode` truthful (this is why `EmbeddedImage` exists — it correctly yields shader mode 2).
- Virtual-memory size for the screensaver process looks huge (hundreds of GB) — that's Metal/wgpu address-space reservation, not RAM. Use Real Memory Size instead.
