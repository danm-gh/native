const std = @import("std");
const code_model = @import("code.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_spans = @import("text_spans.zig");
const ui_model = @import("ui.zig");

const testing = std.testing;
const Ui = ui_model.Ui(enum { noop });

fn spanWithFragment(spans: []const canvas.TextSpan, fragment: []const u8) ?canvas.TextSpan {
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, fragment) != null) return span;
    }
    return null;
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, text)) |found| return found;
    }
    return null;
}

fn countByKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var count: usize = @intFromBool(widget.kind == kind);
    for (widget.children) |child| count += countByKind(child, kind);
    return count;
}

fn appendTextWidgets(widget: canvas.Widget, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (widget.kind == .text) try output.appendSlice(allocator, widget.text);
    for (widget.children) |child| try appendTextWidgets(child, output, allocator);
}

test "HTML and JSX highlighting distinguishes tags attributes expressions and strings" {
    const source =
        \\<Accordion defaultValue={["item-1"]}>
        \\  <AccordionTrigger disabled={true}>Accessible?</AccordionTrigger>
        \\</Accordion>
    ;
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, code_model.languageFromName("tsx"), &storage);

    try testing.expectEqual(code_model.Language.html, code_model.languageFromName("jsx"));
    try testing.expectEqual(canvas.TextSpanColor.info, spanWithFragment(spans, "Accordion").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.warning, spanWithFragment(spans, "defaultValue").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.success, spanWithFragment(spans, "\"item-1\"").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.warning, spanWithFragment(spans, "true").?.color.?);
    try testing.expect(spanWithFragment(spans, "Accessible?").?.color == null);
}

test "HTML and JSX lexer state survives logical line boundaries" {
    var state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("<Button variant=\"primary\"", .html, &first_storage, &state);
    try testing.expect(state.html_in_tag);

    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("  onPress={() => save()} disabled>", .html, &second_storage, &state);
    try testing.expectEqual(canvas.TextSpanColor.warning, spanWithFragment(second, "onPress").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.warning, spanWithFragment(second, "disabled").?.color.?);
    try testing.expect(!state.html_in_tag);
}

test "single-quoted escapes do not leak string state into the next line" {
    const source = "'\\''\nconst next = true;";
    const languages = [_]code_model.Language{
        .zig,
        .javascript,
        .typescript,
        .python,
        .rust,
        .c_like,
        .go,
    };
    for (languages) |language| {
        var state: code_model.HighlightState = .{};
        var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
        const spans = code_model.highlightWithState(source, language, &storage, &state);
        try testing.expect(state.string_quote == null);
        try testing.expect(spanWithFragment(spans, "next").?.color == null);
    }
}

test "HTML prose apostrophes stay prose and JSX content expressions highlight" {
    const source = "<p>It's {true}</p>";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .html, &storage);

    try testing.expect(spanWithFragment(spans, "It's ").?.color == null);
    try testing.expectEqual(canvas.TextSpanColor.warning, spanWithFragment(spans, "true").?.color.?);
}

test "token-dense logical line falls back without dropping source" {
    const source = "const a0=0; const a1=1; const a2=2; const a3=3; const a4=4; const a5=5; const a6=6; const a7=7; const a8=8;";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .zig, &storage);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (spans) |span| try joined.appendSlice(testing.allocator, span.text);
    try testing.expectEqualStrings(source, joined.items);
    try testing.expectEqual(text_spans.max_text_spans_per_paragraph, spans.len);
    try testing.expect(spans[spans.len - 1].color == null);
}

test "token-dense fallback still updates lexer state" {
    const source = "const a0=0; const a1=1; const a2=2; const a3=3; const a4=4; const a5=5; const a6=6; const a7=7; const a8=8; /*";
    var state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState(source, .zig, &first_storage, &state);
    try testing.expect(state.block_comment);

    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("closed */ const next = true;", .zig, &second_storage, &state);
    try testing.expect(!state.block_comment);
    try testing.expectEqual(canvas.TextSpanColor.info, spanWithFragment(second, "const").?.color.?);
}

test "code wraps by default and no-wrap composes one horizontal scroller" {
    var wrapped_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer wrapped_arena.deinit();
    var wrapped_ui = Ui.init(wrapped_arena.allocator());
    const wrapped = try wrapped_ui.finalize(wrapped_ui.code(.{ .language = .zig }, "const answer: u32 = 42;"));
    try testing.expectEqual(canvas.WidgetKind.panel, wrapped.root.kind);
    try testing.expect(findByKind(wrapped.root, .scroll_view) == null);
    const wrapped_text = findByKind(wrapped.root, .text).?;
    try testing.expect(!wrapped_text.text_no_wrap);
    try testing.expect(wrapped_text.spans.len > 1);

    var scroll_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer scroll_arena.deinit();
    var scroll_ui = Ui.init(scroll_arena.allocator());
    const unwrapped = try scroll_ui.finalize(scroll_ui.code(.{
        .language = .zig,
        .wrap = false,
        .width = 160,
    }, "const a_very_long_identifier_that_must_not_wrap: u32 = 42;"));
    const region = findByKind(unwrapped.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.horizontal, region.scroll_axes);
    try testing.expect(findByKind(region, .text).?.text_no_wrap);

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(unwrapped.root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var scroll_width: f32 = 0;
    var text_width: f32 = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .scroll_view) scroll_width = node.frame.width;
        if (node.widget.kind == .text) text_width = node.frame.width;
    }
    try testing.expect(text_width > scroll_width);
}

test "line numbers are opt-in and stay paired with logical source lines" {
    var plain_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer plain_arena.deinit();
    var plain_ui = Ui.init(plain_arena.allocator());
    const plain = try plain_ui.finalize(plain_ui.code(.{}, "alpha\nbeta"));
    try testing.expect(findByText(plain.root, "1") == null);
    try testing.expectEqual(@as(usize, 1), countByKind(plain.root, .text));
    try testing.expect(findByText(plain.root, "alpha\nbeta") != null);

    var numbered_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer numbered_arena.deinit();
    var numbered_ui = Ui.init(numbered_arena.allocator());
    const numbered = try numbered_ui.finalize(numbered_ui.code(.{
        .language = .plain,
        .line_numbers = true,
    }, "alpha\nbeta"));
    try testing.expect(findByText(numbered.root, "1") != null);
    try testing.expect(findByText(numbered.root, "2") != null);
    try testing.expect(findByText(numbered.root, "alpha") != null);
    try testing.expect(findByText(numbered.root, "beta") != null);
}

test "large code blocks split at the paragraph line capacity without hiding their tail" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..129) |_| try source.appendSlice(testing.allocator, "line\n");
    try source.appendSlice(testing.allocator, "tail");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .plain }, source.items));

    try testing.expectEqual(@as(usize, 3), countByKind(view.root, .text));
    try testing.expect(findByText(view.root, "line\ntail") != null);
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "unwrapped multiline intrinsic width is the widest logical line" {
    const spans = [_]canvas.TextSpan{
        .{ .text = "12345\n12", .monospace = true },
        .{ .text = "345", .monospace = true },
    };
    const options = canvas.TextSpanLayoutOptions{ .size = 10, .wrap = .none };
    const combined = [_]canvas.TextSpan{.{ .text = "12345", .monospace = true }};
    try testing.expectApproxEqAbs(
        text_spans.textSpansIntrinsicWidth(&combined, options),
        text_spans.textSpansIntrinsicWidth(&spans, options),
        0.001,
    );
}
