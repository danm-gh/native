//! The `terminal_vt` seam's ENABLED half: re-exports libghostty-vt
//! (Ghostty's extracted terminal-state core, the `ghostty-vt` Zig
//! module) for the runtime's terminal-session store. The build graph
//! wires this wrapper only where the dependency is safe to traverse:
//!
//! - The framework's own root build (tests, tools) resolves a lazy
//!   `ghostty` pin — gated on being the ROOT package, so a consumer
//!   running this build script through `b.dependency("native_sdk")`
//!   never touches it.
//! - An app build opts in by pinning ghostty in its OWN build.zig.zon
//!   and passing `ghostty.module("ghostty-vt")` through
//!   `addAppArtifacts(.{ .ghostty_vt = ... })` — the examples/terminal
//!   consumption shape, proven in consumer package stores.
//!
//! Everything else (scaffolded apps, the wasm docs preview) gets
//! `terminal_vt_stub.zig` and never traverses ghostty's graph.

pub const enabled = true;
pub const vt = @import("ghostty-vt");
