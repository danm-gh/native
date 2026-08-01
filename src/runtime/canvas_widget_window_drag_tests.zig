//! Window-drag region semantics through REAL dispatch: gpu-surface
//! pointer input enters `dispatchPlatformEvent`, the press walk resolves
//! drag-region vs control, and the null platform records every
//! `startWindowDrag` call the runtime hands it.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;

const DragTestApp = struct {
    pointer_down_count: u32 = 0,
    last_press_target_id: canvas.ObjectId = 0,
    command_count: u32 = 0,
    last_command: []const u8 = "",

    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-window-drag", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
    }

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .canvas_widget_pointer => |pointer_event| {
                if (pointer_event.pointer.phase != .down) return;
                self.pointer_down_count += 1;
                self.last_press_target_id = if (pointer_event.press_target) |target| target.id else 0;
            },
            .command => |command_event| {
                self.command_count += 1;
                self.last_command = command_event.name;
            },
            else => {},
        }
    }
};

/// A hidden-titlebar canvas: header row marked `window_drag` holding a
/// button and plain text, a content button below the header.
fn installDragLayout(harness: anytype) !void {
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    const header_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(8, 6, 80, 28), .text = "Open", .command = "app.open" },
        .{ .id = 4, .kind = .text, .frame = geometry.RectF.init(100, 10, 60, 18), .text = "Title" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 320, 40), .window_drag = true, .children = &header_children },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(10, 60, 96, 32), .text = "Body", .command = "app.body" },
    };
    const root = canvas.Widget{ .id = 1, .kind = .panel, .children = &children };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

fn pointerDown(harness: anytype, app: App, x: f32, y: f32, button: i32) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_down,
        .x = x,
        .y = y,
        .button = button,
    } });
}

fn pointerUp(harness: anytype, app: App, x: f32, y: f32) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .pointer_up,
        .x = x,
        .y = y,
        .button = 0,
    } });
}

test "press on a window-drag region's background starts a window drag, not a widget press" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try installDragLayout(harness);

    // Down on the header's empty background: the walk finds the drag
    // region, the platform records the drag, and NO widget is pressed.
    try pointerDown(harness, app, 240, 20, 0);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(platform.WindowId, 1), harness.null_platform.window_drag_starts[0]);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    // The app still sees the raw pointer event — with no press target,
    // exactly like a dead-space click.
    try std.testing.expectEqual(@as(u32, 1), app_state.pointer_down_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), app_state.last_press_target_id);
    try pointerUp(harness, app, 240, 20);
    try std.testing.expectEqual(@as(u32, 0), app_state.command_count);
}

test "a button inside a window-drag region stays a button" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try installDragLayout(harness);

    // Press fall-through keeps working: the down lands on the button
    // (claims the press) and never reaches the drag region.
    try pointerDown(harness, app, 20, 18, 0);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 3), app_state.last_press_target_id);
    try pointerUp(harness, app, 20, 18);
    try std.testing.expectEqual(@as(u32, 1), app_state.command_count);
    try std.testing.expectEqualStrings("app.open", app_state.last_command);

    // A control outside the region is untouched by any of this.
    try pointerDown(harness, app, 20, 70, 0);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_drag_start_count);
    try pointerUp(harness, app, 20, 70);
    try std.testing.expectEqualStrings("app.body", app_state.last_command);
}

test "plain text inside a window-drag region falls through to the drag" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try installDragLayout(harness);

    // Text does not claim presses, so a down on the header's title moves
    // the window (native titlebars do not select their text) and no
    // static-text selection starts.
    try pointerDown(harness, app, 110, 20, 0);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_pressed_id);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_selected_text_id);
}

test "double-click on a window-drag region reaches the platform as two drag starts" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try installDragLayout(harness);

    // The runtime forwards EVERY qualifying down; the host decides drag
    // vs zoom from the native event's click count (macOS honors the
    // user's titlebar double-click preference). Two downs = two calls.
    try pointerDown(harness, app, 240, 20, 0);
    try pointerUp(harness, app, 240, 20);
    try pointerDown(harness, app, 240, 20, 0);
    try pointerUp(harness, app, 240, 20);
    try std.testing.expectEqual(@as(usize, 2), harness.null_platform.window_drag_start_count);
}

test "window drag requires the primary button and an enabled region" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 320, 40), .window_drag = true },
        .{ .id = 3, .kind = .row, .frame = geometry.RectF.init(0, 60, 320, 40), .window_drag = true, .state = .{ .disabled = true } },
    };
    const root = canvas.Widget{ .id = 1, .kind = .panel, .children = &children };
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Secondary-button downs never start a window drag.
    try pointerDown(harness, app, 160, 20, 1);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_drag_start_count);

    // A disabled drag region stands down like a disabled control.
    try pointerDown(harness, app, 160, 80, 0);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_drag_start_count);

    // The enabled region still drags.
    try pointerDown(harness, app, 160, 20, 0);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_start_count);
}

test "a widget with both a press handler and window_drag keeps its press" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .row,
            .frame = geometry.RectF.init(0, 0, 320, 40),
            .window_drag = true,
            .semantics = .{ .actions = .{ .press = true } },
        },
    };
    const root = canvas.Widget{ .id = 1, .kind = .panel, .children = &children };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Authored handlers outrank the drag surface: the press dispatches,
    // the platform is never asked to move the window.
    try pointerDown(harness, app, 160, 20, 0);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.window_drag_start_count);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), app_state.last_press_target_id);
}

test "layout installs mirror window-drag regions to hit-testing platforms" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    try installDragLayout(harness);

    // The install pushed the mirror the Windows host consults from
    // WM_NCHITTEST: the drag header's frame, then the press-claiming
    // button inside it as an exclusion. Plain text claims nothing and
    // the body button lives outside the region, so neither appears.
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_region_push_count);
    const regions = harness.null_platform.window_drag_regions[0..harness.null_platform.window_drag_region_count];
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    const layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(!regions[0].exclusion);
    try std.testing.expectEqual((layout.findById(2) orelse return error.TestUnexpectedResult).frame, regions[0].frame);
    try std.testing.expect(regions[1].exclusion);
    try std.testing.expectEqual((layout.findById(3) orelse return error.TestUnexpectedResult).frame, regions[1].frame);

    // Re-installing an identical layout pushes nothing: the mirror only
    // travels when it changed.
    const header_children = [_]canvas.Widget{
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(8, 6, 80, 28), .text = "Open", .command = "app.open" },
        .{ .id = 4, .kind = .text, .frame = geometry.RectF.init(100, 10, 60, 18), .text = "Title" },
    };
    const children = [_]canvas.Widget{
        .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 320, 40), .window_drag = true, .children = &header_children },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(10, 60, 96, 32), .text = "Body", .command = "app.body" },
    };
    const root = canvas.Widget{ .id = 1, .kind = .panel, .children = &children };
    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const same_layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", same_layout);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_region_push_count);
}

test "the null platform mirror holds the runtime's full per-view drag-region bound" {
    // The runtime collects up to
    // `canvas_limits.max_canvas_widget_window_drag_regions_per_view`
    // regions per push; a smaller test-platform mirror fails app
    // batteries the real platforms accept (a crumb-menu rebuild in a
    // drag-region-heavy app reached 17 and died here at capacity 16).
    const canvas_limits = @import("canvas_limits.zig");
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: DragTestApp = .{};
    const app = app_state.app();
    try harness.start(app);

    var regions: [canvas_limits.max_canvas_widget_window_drag_regions_per_view]platform.WindowDragRegion = undefined;
    for (&regions, 0..) |*region, index| {
        region.* = .{
            .frame = geometry.RectF.init(@floatFromInt(index * 10), 0, 8, 8),
            .exclusion = false,
        };
    }
    try harness.runtime.options.platform.services.setWindowDragRegions(1, "canvas", &regions);
    try std.testing.expectEqual(regions.len, harness.null_platform.window_drag_region_count);
}
