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

fn countTextSpans(widget: canvas.Widget) usize {
    var count = widget.spans.len;
    for (widget.children) |child| count += countTextSpans(child);
    return count;
}

fn appendTextWidgets(widget: canvas.Widget, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (widget.kind == .text) try output.appendSlice(allocator, widget.text);
    for (widget.children) |child| try appendTextWidgets(child, output, allocator);
}

fn displayListTextBytes(display_list: canvas.DisplayList) usize {
    var count: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |draw| count += draw.text.len,
            else => {},
        }
    }
    return count;
}

fn expectCompleteSpanLayouts(widget: canvas.Widget) !void {
    if (widget.kind == .text and widget.spans.len > 0) {
        var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
        const layout = text_spans.layoutTextSpans(
            widget.spans,
            .{ .size = 14, .max_width = 1 },
            &runs,
        );
        try testing.expect(!layout.truncated);
        try testing.expect(layout.line_count <= text_spans.max_text_span_lines_per_paragraph);
    }
    for (widget.children) |child| try expectCompleteSpanLayouts(child);
}

fn allTextSpansHaveColor(widget: canvas.Widget, color: canvas.TextSpanColor) bool {
    if (widget.kind == .text and widget.spans.len > 0) {
        for (widget.spans) |span| {
            if (span.color != color) return false;
        }
    }
    for (widget.children) |child| {
        if (!allTextSpansHaveColor(child, color)) return false;
    }
    return true;
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
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "Accordion").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "defaultValue").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "\"item-1\"").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "Accessible?").?.color.?);
}

test "JSX relational less-than preserves expression state and nested tags" {
    const source = "<span>{count<limit ? <Low/> : <High/>}</span>";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .html, &storage, &state);

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "limit").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "Low").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "High").?.color.?);
    try testing.expectEqual(@as(usize, 0), state.html_expression_depth);
    try testing.expect(!state.html_in_tag);

    var chunked_state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("<span>{count", .html, &first_storage, &chunked_state);
    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("<limit ? <Low/> : <High/>}</span>", .html, &second_storage, &chunked_state);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(second, "limit").?.color.?);
    try testing.expectEqual(@as(usize, 0), chunked_state.html_expression_depth);
    try testing.expect(!chunked_state.html_in_tag);
}

test "nested JSX attribute tags restore the enclosing opening tag" {
    const source = "<Comp render={<Inner />} disabled=\"yes\">";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .html, &storage, &state);

    try testing.expectEqual(
        canvas.TextSpanColor.syntax_literal,
        spanWithFragment(spans, "Inner").?.color.?,
    );
    try testing.expectEqual(
        canvas.TextSpanColor.syntax_function,
        spanWithFragment(spans, "disabled").?.color.?,
    );
    try testing.expectEqual(
        canvas.TextSpanColor.syntax_literal,
        spanWithFragment(spans, "\"yes\"").?.color.?,
    );
    try testing.expectEqual(@as(usize, 0), state.html_tag_context_len);
    try testing.expect(!state.html_in_tag);
}

test "HTML and JSX lexer state survives logical line boundaries" {
    var state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("<Button variant=\"primary\"", .html, &first_storage, &state);
    try testing.expect(state.html_in_tag);

    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("  onPress={() => save()} disabled>", .html, &second_storage, &state);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(second, "onPress").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(second, "disabled").?.color.?);
    try testing.expect(!state.html_in_tag);
}

test "plain HTML attribute quotes close literally after backslashes" {
    const sources = [_][]const u8{
        "<div title=\"value\\\" disabled>",
        "<div title='value\\' disabled>",
    };
    for (sources) |source| {
        var state: code_model.HighlightState = .{};
        var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
        const spans = code_model.highlightWithState(source, .html, &storage, &state);
        try testing.expect(state.string_quote == null);
        try testing.expect(!state.html_in_tag);
        try testing.expectEqual(
            canvas.TextSpanColor.syntax_function,
            spanWithFragment(spans, "disabled").?.color.?,
        );
    }

    var jsx_state: code_model.HighlightState = .{};
    var jsx_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState(
        "<div value={{ text: \"value\\\" still\" }} disabled>",
        .html,
        &jsx_storage,
        &jsx_state,
    );
    try testing.expect(jsx_state.string_quote == null);
    try testing.expect(!jsx_state.html_in_tag);
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
        try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "next").?.color.?);
    }
}

test "Python literals keep their case-sensitive syntax role" {
    const source = "enabled = True\nmissing = None\ndisabled = False";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .python, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "True").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "None").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "False").?.color.?);
}

test "Rust lifetimes do not open string state and character literals still highlight" {
    const lifetime_source = "fn borrow<'a>(value: &'a str) -> &'a str { value }\nconst next = true;";
    var lifetime_state: code_model.HighlightState = .{};
    var lifetime_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const lifetimes = code_model.highlightWithState(
        lifetime_source,
        .rust,
        &lifetime_storage,
        &lifetime_state,
    );
    try testing.expect(lifetime_state.string_quote == null);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(lifetimes, "'a").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(lifetimes, "const").?.color.?);

    const character_source = "let escaped: char = '\\n'; let unicode: char = '🦀';";
    var character_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const characters = code_model.highlight(character_source, .rust, &character_storage);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(characters, "'\\n'").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(characters, "'🦀'").?.color.?);
}

test "HTML prose apostrophes stay prose and JSX content expressions highlight" {
    const source = "<p>It's {true}</p>";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .html, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "It's ").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
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
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spans[spans.len - 1].color.?);
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
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(second, "const").?.color.?);
}

test "callables and object properties use Geist syntax roles" {
    const source = "function render() { return { color: true }; }";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .javascript, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "function").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "render").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_property, spanWithFragment(spans, "color").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
}

test "both built-in packs use the Geist Code Block syntax palette" {
    for ([_]canvas.ThemePack{ .house, .geist }) |pack| {
        const light = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = .light }).colors;
        try testing.expectEqual(canvas.Color.rgb8(23, 23, 23), light.syntax_plain);
        try testing.expectEqual(canvas.Color.rgb8(77, 77, 77), light.syntax_comment);
        try testing.expectEqual(canvas.Color.rgb8(189, 40, 100), light.syntax_keyword);
        try testing.expectEqual(canvas.Color.rgb8(41, 122, 58), light.syntax_literal);
        try testing.expectEqual(canvas.Color.rgb8(120, 32, 188), light.syntax_function);
        try testing.expectEqual(canvas.Color.rgb8(203, 42, 47), light.syntax_property);
        try testing.expectEqual(canvas.Color.rgb8(0, 104, 214), light.syntax_constant);

        const dark = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = .dark }).colors;
        try testing.expectEqual(canvas.Color.rgb8(237, 237, 237), dark.syntax_plain);
        try testing.expectEqual(canvas.Color.rgb8(161, 161, 161), dark.syntax_comment);
        try testing.expectEqual(canvas.Color.rgb8(247, 95, 143), dark.syntax_keyword);
        try testing.expectEqual(canvas.Color.rgb8(98, 192, 115), dark.syntax_literal);
        try testing.expectEqual(canvas.Color.rgb8(191, 122, 240), dark.syntax_function);
        try testing.expectEqual(canvas.Color.rgb8(255, 97, 102), dark.syntax_property);
        try testing.expectEqual(canvas.Color.rgb8(82, 168, 255), dark.syntax_constant);
    }
}

test "omitted custom syntax colors inherit readable text roles" {
    const colors = canvas.ColorTokens{
        .background = canvas.Color.rgb8(12, 10, 9),
        .surface_subtle = canvas.Color.rgb8(41, 37, 36),
        .text = canvas.Color.rgb8(250, 250, 249),
        .text_muted = canvas.Color.rgb8(166, 160, 155),
    };

    try testing.expectEqual(colors.text, text_spans.textSpanColorValue(colors, .syntax_plain));
    try testing.expectEqual(colors.text, text_spans.textSpanColorValue(colors, .syntax_keyword));
    try testing.expectEqual(colors.text_muted, text_spans.textSpanColorValue(colors, .syntax_comment));

    var explicit = colors;
    explicit.syntax_keyword = canvas.Color.rgb8(247, 95, 143);
    try testing.expectEqual(explicit.syntax_keyword, text_spans.textSpanColorValue(explicit, .syntax_keyword));
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

test "unwrapped multiline code hugs the height of every logical line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.column(.{}, .{
        ui.code(.{ .wrap = false }, "one\ntwo\nthree\nfour"),
        ui.text(.{}, "after"),
    }));

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        view.root,
        geometry.RectF.init(0, 0, 320, 400),
        &nodes,
    );
    var scroll_height: f32 = 0;
    var code_height: f32 = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .scroll_view) scroll_height = node.frame.height;
        if (std.mem.eql(u8, node.widget.text, "one\ntwo\nthree\nfour")) {
            code_height = node.frame.height;
        }
    }
    try testing.expect(code_height > 0);
    try testing.expect(scroll_height >= code_height);
}

test "fixed-height code surfaces scroll every overflowing axis" {
    const multiline =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
    ;
    var wrapped_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer wrapped_arena.deinit();
    var wrapped_ui = Ui.init(wrapped_arena.allocator());
    const wrapped = try wrapped_ui.finalize(wrapped_ui.code(.{
        .width = 160,
        .height = 60,
    }, multiline));
    const wrapped_region = findByKind(wrapped.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.vertical, wrapped_region.scroll_axes);

    var wrapped_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const wrapped_layout = try canvas.layoutWidgetTree(
        wrapped.root,
        geometry.RectF.init(0, 0, 160, 60),
        &wrapped_nodes,
    );
    var wrapped_scroll_index: usize = 0;
    for (wrapped_layout.nodes, 0..) |node, index| {
        if (node.widget.kind == .scroll_view) wrapped_scroll_index = index;
    }
    const wrapped_scroll = wrapped_layout.nodes[wrapped_scroll_index];
    const wrapped_viewport = wrapped_scroll.frame.inset(wrapped_scroll.widget.layout.padding).normalized();
    const wrapped_vertical = canvas.widgetScrollAxisMetrics(
        wrapped_layout,
        wrapped_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .vertical,
        wrapped_viewport,
    );
    try testing.expect(wrapped_vertical.content_extent > wrapped_vertical.viewport_extent);

    var both_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer both_arena.deinit();
    var both_ui = Ui.init(both_arena.allocator());
    const both = try both_ui.finalize(both_ui.code(.{
        .wrap = false,
        .width = 160,
        .height = 60,
    }, "a_very_long_identifier_that_overflows_horizontally\nsecond\nthird\nfourth"));
    const both_region = findByKind(both.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.both, both_region.scroll_axes);

    var both_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const both_layout = try canvas.layoutWidgetTree(
        both.root,
        geometry.RectF.init(0, 0, 160, 60),
        &both_nodes,
    );
    var both_scroll_index: usize = 0;
    for (both_layout.nodes, 0..) |node, index| {
        if (node.widget.kind == .scroll_view) both_scroll_index = index;
    }
    const both_scroll = both_layout.nodes[both_scroll_index];
    const both_viewport = both_scroll.frame.inset(both_scroll.widget.layout.padding).normalized();
    const both_vertical = canvas.widgetScrollAxisMetrics(
        both_layout,
        both_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .vertical,
        both_viewport,
    );
    const both_horizontal = canvas.widgetScrollAxisMetrics(
        both_layout,
        both_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .horizontal,
        both_viewport,
    );
    try testing.expect(both_vertical.content_extent > both_vertical.viewport_extent);
    try testing.expect(both_horizontal.content_extent > both_horizontal.viewport_extent);
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
    try testing.expectEqual(@as(usize, 1), countByKind(numbered.root, .text));
    const numbered_text = findByText(numbered.root, "alpha\nbeta").?;
    try testing.expectEqual(@as(u8, 1), numbered_text.code_line_number_digits);

    var numbered_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const numbered_layout = try canvas.layoutWidgetTree(
        numbered.root,
        geometry.RectF.init(0, 0, 160, 80),
        &numbered_nodes,
    );
    var numbered_commands: [32]canvas.CanvasCommand = undefined;
    var numbered_builder = canvas.Builder.init(&numbered_commands);
    try canvas.emitWidgetLayout(&numbered_builder, numbered_layout, .{});
    var first_marker_y: ?f32 = null;
    var second_marker_y: ?f32 = null;
    for (numbered_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |draw| {
                if (std.mem.eql(u8, draw.text, "1")) first_marker_y = draw.origin.y;
                if (std.mem.eql(u8, draw.text, "2")) second_marker_y = draw.origin.y;
            },
            else => {},
        }
    }
    try testing.expect(first_marker_y != null);
    try testing.expect(second_marker_y != null);
    try testing.expect(second_marker_y.? > first_marker_y.?);

    var comment_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer comment_arena.deinit();
    var comment_ui = Ui.init(comment_arena.allocator());
    const comments = try comment_ui.finalize(comment_ui.code(.{
        .language = .zig,
        .line_numbers = true,
    }, "// first\nconst second = true;"));
    const comment_text = findByText(comments.root, "// first\nconst second = true;").?;
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(comment_text.spans, "const").?.color.?);
}

test "empty code retains the exact source text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .line_numbers = true,
    }, ""));

    const paragraph = findByKind(view.root, .text).?;
    try testing.expectEqualStrings("", paragraph.text);
    try testing.expectEqual(@as(usize, 1), paragraph.spans.len);
    try testing.expectEqualStrings("", paragraph.spans[0].text);
    try testing.expectEqual(@as(u8, 1), paragraph.code_line_number_digits);
}

test "code preserves CRLF source without painting carriage returns" {
    const source = "const alpha = 1;\r\nconst beta = 2;";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .zig }, source));

    const paragraph = findByText(view.root, source).?;
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const layout = text_spans.layoutTextSpans(
        paragraph.spans,
        .{ .size = 14, .max_width = 10_000 },
        &runs,
    );
    try testing.expectEqual(@as(usize, 2), layout.line_count);
    for (layout.runs) |run| {
        try testing.expect(std.mem.indexOfScalar(u8, run.text, '\r') == null);
    }
    try testing.expectEqualStrings(source, paragraph.text);
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

    try testing.expect(countByKind(view.root, .text) > 1);
    const chunk_column = view.root.children[0];
    var expected_offset: usize = 0;
    var group_id: ?canvas.ObjectId = null;
    for (chunk_column.children) |chunk| {
        try testing.expect(chunk.static_text_group_id != 0);
        try testing.expectEqual(expected_offset, chunk.static_text_group_offset);
        if (group_id) |expected| {
            try testing.expectEqual(expected, chunk.static_text_group_id);
        } else {
            group_id = chunk.static_text_group_id;
        }
        expected_offset += chunk.text.len;
    }
    try testing.expectEqual(source.items.len, expected_offset);
    try expectCompleteSpanLayouts(view.root);
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "maximal newline-heavy code stays within retained span and node budgets" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..65_536) |_| try source.append(testing.allocator, '\n');

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .plain }, source.items));

    try testing.expectEqual(Ui.max_code_spans_per_surface, countTextSpans(view.root));
    try expectCompleteSpanLayouts(view.root);
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        view.root,
        geometry.RectF.init(0, 0, 320, 20_000),
        &nodes,
    );
    // One panel + one chunk column + one text node per 128 source
    // newlines: 514 stays well below the 1024-node runtime view cap.
    try testing.expectEqual(Ui.max_code_spans_per_surface + 2, layout.nodes.len);

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "large code retains all source while emitting only visible text" {
    const source = try testing.allocator.alloc(u8, 65_536);
    defer testing.allocator.free(source);
    @memset(source, 'x');

    for ([_]bool{ true, false }) |wrap| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const view = try ui.finalize(ui.code(.{
            .wrap = wrap,
            .height = 80,
        }, source));

        var recovered: std.ArrayListUnmanaged(u8) = .empty;
        defer recovered.deinit(testing.allocator);
        try appendTextWidgets(view.root, &recovered, testing.allocator);
        try testing.expectEqualStrings(source, recovered.items);

        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(
            view.root,
            geometry.RectF.init(0, 0, 320, 80),
            &nodes,
        );
        var commands: [2048]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try canvas.emitWidgetLayout(&builder, layout, .{});
        const display_list = builder.displayList();

        try testing.expect(display_list.commands.len < commands.len);
        try testing.expect(displayListTextBytes(display_list) <= canvas.max_display_list_text_bytes);
        try testing.expect(displayListTextBytes(display_list) < source.len);
    }
}

test "direct tree code emission honors scroll viewports and later layout pages" {
    const horizontal_source = "x" ** 65_536;
    const horizontal_spans = [_]canvas.TextSpan{.{
        .text = horizontal_source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const horizontal_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(0, 0, 400_000, 20),
        .text = horizontal_source,
        .spans = &horizontal_spans,
        .text_no_wrap = true,
    }};
    const horizontal_root = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 320, 80),
        .native_scroll = true,
        .children = &horizontal_children,
    };
    var horizontal_commands: [64]canvas.CanvasCommand = undefined;
    var horizontal_builder = canvas.Builder.init(&horizontal_commands);
    try canvas.emitWidgetTree(&horizontal_builder, horizontal_root, .{});
    const horizontal_list = horizontal_builder.displayList();
    try testing.expect(displayListTextBytes(horizontal_list) <= canvas.max_display_list_text_bytes);
    try testing.expect(displayListTextBytes(horizontal_list) < horizontal_source.len);

    const vertical_source = ("x\n" ** 139) ++ "x";
    const vertical_spans = [_]canvas.TextSpan{.{
        .text = vertical_source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const vertical_children = [_]canvas.Widget{.{
        .id = 4,
        .kind = .text,
        .frame = geometry.RectF.init(0, -2400, 100, 2450),
        .text = vertical_source,
        .spans = &vertical_spans,
    }};
    const vertical_root = canvas.Widget{
        .id = 3,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 100, 100),
        .native_scroll = true,
        .children = &vertical_children,
    };
    var vertical_commands: [64]canvas.CanvasCommand = undefined;
    var vertical_builder = canvas.Builder.init(&vertical_commands);
    try canvas.emitWidgetTree(&vertical_builder, vertical_root, .{});

    var visible_text_commands: usize = 0;
    for (vertical_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |draw| {
                if (draw.origin.y >= 0 and draw.origin.y <= vertical_root.frame.maxY()) {
                    visible_text_commands += 1;
                }
            },
            else => {},
        }
    }
    try testing.expect(visible_text_commands > 0);
}

test "maximal one-line numbered code adds no retained gutter bytes" {
    const source = try testing.allocator.alloc(u8, 65_536);
    defer testing.allocator.free(source);
    @memset(source, 'x');

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .line_numbers = true,
        .wrap = false,
    }, source));

    try testing.expectEqual(@as(usize, 1), countByKind(view.root, .text));
    const paragraph = findByText(view.root, source).?;
    try testing.expectEqual(@as(u8, 1), paragraph.code_line_number_digits);
    var retained_text: std.ArrayListUnmanaged(u8) = .empty;
    defer retained_text.deinit(testing.allocator);
    try appendTextWidgets(view.root, &retained_text, testing.allocator);
    try testing.expectEqual(source.len, retained_text.items.len);
    try testing.expectEqualStrings(source, retained_text.items);
}

test "transformed code culling maps the window back into paragraph space" {
    const source = ("x\n" ** 139) ++ "x";
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const root_frame = geometry.RectF.init(0, 0, 100, 100);

    const translated_frame = geometry.RectF.init(0, 200, 20, 2450);
    const translated_nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = root_frame,
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.translate(0, -200),
            },
            .frame = translated_frame,
            .depth = 1,
            .parent_index = 0,
        },
    };
    var translated_commands: [64]canvas.CanvasCommand = undefined;
    var translated_builder = canvas.Builder.init(&translated_commands);
    try canvas.emitWidgetLayout(
        &translated_builder,
        canvas.WidgetLayoutTree{ .nodes = &translated_nodes },
        .{},
    );
    try testing.expect(displayListTextBytes(translated_builder.displayList()) > 0);

    const scaled_frame = geometry.RectF.init(0, 0, 20, 2450);
    const scaled_nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = root_frame,
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.scale(0.01, 0.01),
            },
            .frame = scaled_frame,
            .depth = 1,
            .parent_index = 0,
        },
    };
    var scaled_commands: [256]canvas.CanvasCommand = undefined;
    var scaled_builder = canvas.Builder.init(&scaled_commands);
    try canvas.emitWidgetLayout(
        &scaled_builder,
        canvas.WidgetLayoutTree{ .nodes = &scaled_nodes },
        .{},
    );
    var drawn_lines: usize = 0;
    for (scaled_builder.displayList().commands) |command| {
        if (command == .draw_text) drawn_lines += 1;
    }
    try testing.expectEqual(@as(usize, 140), drawn_lines);
}

test "scaled code degrades under the display-list command budget" {
    const source = ("x\n" ** 2999) ++ "x";
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = geometry.RectF.init(0, 0, 100, 100),
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.scale(0.001, 0.001),
            },
            .frame = geometry.RectF.init(0, 0, 20, 52_500),
            .depth = 1,
            .parent_index = 0,
        },
    };
    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(
        &builder,
        canvas.WidgetLayoutTree{ .nodes = &nodes },
        .{},
    );

    var drawn_lines: usize = 0;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text) drawn_lines += 1;
    }
    try testing.expect(drawn_lines > 0);
    try testing.expect(drawn_lines < 3000);
    try testing.expect(builder.displayList().commands.len < commands.len);
}

test "scaled long code line degrades under the display-list text budget" {
    const source = "x" ** 65_536;
    const preceding_text = "y" ** 20_000;
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = geometry.RectF.init(0, 0, 1000, 100),
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .text_no_wrap = true,
                .transform = canvas.Affine.scale(0.001, 0.001),
            },
            .frame = geometry.RectF.init(0, 0, 400_000, 20),
            .depth = 1,
            .parent_index = 0,
        },
    };
    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawText(.{
        .id = 99,
        .font_id = 2,
        .size = 12,
        .origin = geometry.PointF.init(0, 0),
        .color = canvas.Color.rgb8(255, 255, 255),
        .text = preceding_text,
    });
    try canvas.emitWidgetLayout(
        &builder,
        canvas.WidgetLayoutTree{ .nodes = &nodes },
        .{},
    );

    const text_bytes = displayListTextBytes(builder.displayList());
    try testing.expect(text_bytes > preceding_text.len);
    try testing.expect(text_bytes <= canvas.max_display_list_text_bytes);
    try testing.expect(text_bytes < preceding_text.len + source.len);
}

test "wrapped code keeps an over-capacity logical line in one paragraph" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "// ");
    for (0..130) |_| try source.appendSlice(testing.allocator, "é");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .zig }, source.items));

    try testing.expectEqual(@as(usize, 1), countByKind(view.root, .text));
    try testing.expect(allTextSpansHaveColor(view.root, .syntax_comment));

    const text_widget = findByKind(view.root, .text).?;
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const wide_layout = text_spans.layoutTextSpans(
        text_widget.spans,
        .{ .size = 14, .max_width = 10_000 },
        &runs,
    );
    try testing.expectEqual(@as(usize, 1), wide_layout.line_count);
    try testing.expect(!wide_layout.truncated);

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "numbered code keeps one selectable source paragraph at its limit" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..Ui.max_code_lines) |_| {
        try source.append(testing.allocator, 'x');
        try source.append(testing.allocator, '\n');
    }

    var numbered_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer numbered_arena.deinit();
    var numbered_ui = Ui.init(numbered_arena.allocator());
    const numbered = try numbered_ui.finalize(numbered_ui.code(.{
        .line_numbers = true,
        .wrap = false,
    }, source.items));

    var numbered_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const numbered_layout = try canvas.layoutWidgetTree(
        numbered.root,
        geometry.RectF.init(0, 0, 320, 4000),
        &numbered_nodes,
    );
    // Panel + horizontal scroll + track + one source paragraph +
    // scrollbar spacer. Gutter markers are renderer-owned decoration.
    try testing.expectEqual(@as(usize, 5), numbered_layout.nodes.len);
    try testing.expectEqual(@as(usize, 1), countByKind(numbered.root, .text));
    try testing.expectEqual(
        @as(u8, 3),
        findByText(numbered.root, source.items).?.code_line_number_digits,
    );

    try source.append(testing.allocator, 'x');
    var fallback_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer fallback_arena.deinit();
    var fallback_ui = Ui.init(fallback_arena.allocator());
    const fallback = try fallback_ui.finalize(fallback_ui.code(.{
        .line_numbers = true,
        .wrap = false,
    }, source.items));
    try testing.expectEqual(
        @as(u8, 0),
        findByKind(fallback.root, .text).?.code_line_number_digits,
    );
    var fallback_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    _ = try canvas.layoutWidgetTree(
        fallback.root,
        geometry.RectF.init(0, 0, 320, 4000),
        &fallback_nodes,
    );

    var long_source: std.ArrayListUnmanaged(u8) = .empty;
    defer long_source.deinit(testing.allocator);
    for (0..100) |line_index| {
        if (line_index > 0) try long_source.append(testing.allocator, '\n');
        for (0..130) |_| try long_source.append(testing.allocator, 'x');
    }
    var long_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer long_arena.deinit();
    var long_ui = Ui.init(long_arena.allocator());
    const long_fallback = try long_ui.finalize(long_ui.code(.{
        .line_numbers = true,
    }, long_source.items));
    // Long logical lines remain one selectable paragraph even when their
    // visual wrapping crosses the painter's first retained line page.
    try testing.expectEqual(@as(usize, 1), countByKind(long_fallback.root, .text));
    try testing.expectEqual(
        @as(u8, 3),
        findByText(long_fallback.root, long_source.items).?.code_line_number_digits,
    );
    var long_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    _ = try canvas.layoutWidgetTree(
        long_fallback.root,
        geometry.RectF.init(0, 0, 320, 20_000),
        &long_nodes,
    );
}

test "token-dense numbered code preserves all source in one paragraph" {
    const dense_line = "const a0 = 0; const a1 = 1; const a2 = 2;";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..79) |line_index| {
        if (line_index > 0) try source.append(testing.allocator, '\n');
        try source.appendSlice(testing.allocator, dense_line);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const fallback = try ui.finalize(ui.code(.{
        .language = .zig,
        .line_numbers = true,
    }, source.items));

    try testing.expectEqual(@as(usize, 1), countByKind(fallback.root, .text));
    try testing.expect(countTextSpans(fallback.root) <= text_spans.max_text_spans_per_paragraph);
    try testing.expectEqual(
        @as(u8, 2),
        findByText(fallback.root, source.items).?.code_line_number_digits,
    );

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(fallback.root, &recovered, testing.allocator);
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
