# Native regression checks

Run `./drift/tests/run.sh` for deterministic AppKit lifecycle tests. These
compile the production Objective-C view with a recording engine and run it
under ordinary-window and remote-screen-saver host identities. They cover
late attachment, backing-scale changes without notifications, bounds-only
resizing, external drawable changes, occlusion, sleep/wake, session changes,
zero-size transitions, restart, failed initialization retry, and Metal drawable
timeouts. No Rust toolchain or installed screen saver is required.

Run `./script/build_and_run.sh --verify` to build and test the actual saver in
temporary borderless windows covering each attached display's usable area for
about 16 seconds. It uses the real display scale and production simulation
settings, samples completed Metal frames, and checks motion and visible content
before and after resize, drawable-size drift, sleep/wake, and restart. It checks
view/layer/drawable dimensions exactly and that acquisition timeouts remain
enabled. A legitimately dark quadrant does not fail the test. Results are
saved to `target/preview-host/verification.json`, with captured frames in
`window-0.png` and `window-1.png` beside it. A 35-second background watchdog
terminates a stalled test. Pixel readback is enabled only in this host.
These checks simulate transitions; they do not exercise physical monitor
hot-plugging or the macOS lock screen compositor.

Run `./script/build_and_run.sh` for an interactive local preview. Closing both
windows ends it. The preview uses Silver and never changes the installed saver
or its preferences. The Codex Run button invokes the same command.

To compare an older view implementation, set `DRIFT_VIEW_SOURCE` to its path
when running the lifecycle tests. Store temporary sources and logs under
`target/` so they remain untracked.
