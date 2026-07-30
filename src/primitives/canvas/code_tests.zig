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
    try testing.expect(findByText(numbered.root, "1") != null);
    try testing.expect(findByText(numbered.root, "2") != null);
    try testing.expect(findByText(numbered.root, "alpha") != null);
    try testing.expect(findByText(numbered.root, "beta") != null);

    var comment_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer comment_arena.deinit();
    var comment_ui = Ui.init(comment_arena.allocator());
    const comments = try comment_ui.finalize(comment_ui.code(.{
        .language = .zig,
        .line_numbers = true,
    }, "// first\nconst second = true;"));
    const second = findByText(comments.root, "const second = true;").?;
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(second.spans, "const").?.color.?);
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

test "wrapped code chunks long logical lines before span layout can truncate them" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "// ");
    for (0..130) |_| try source.appendSlice(testing.allocator, "é");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .zig }, source.items));

    try testing.expectEqual(@as(usize, 2), countByKind(view.root, .text));
    try expectCompleteSpanLayouts(view.root);
    try testing.expect(allTextSpansHaveColor(view.root, .syntax_comment));

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "numbered code stays below the retained widget node budget at its limit" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..Ui.max_code_lines) |index| {
        if (index > 0) try source.append(testing.allocator, '\n');
        try source.append(testing.allocator, 'x');
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
    // Panel + horizontal scroll + track + content column + scrollbar
    // spacer, then four retained widgets per numbered source line.
    try testing.expectEqual(
        @as(usize, Ui.max_code_lines * 4 + 5),
        numbered_layout.nodes.len,
    );

    try source.append(testing.allocator, '\n');
    try source.append(testing.allocator, 'x');
    var fallback_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer fallback_arena.deinit();
    var fallback_ui = Ui.init(fallback_arena.allocator());
    const fallback = try fallback_ui.finalize(fallback_ui.code(.{
        .line_numbers = true,
        .wrap = false,
    }, source.items));
    try testing.expectEqual(@as(usize, 0), countByKind(fallback.root, .row));
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
    try testing.expectEqual(@as(usize, 0), countByKind(long_fallback.root, .row));
    var long_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    _ = try canvas.layoutWidgetTree(
        long_fallback.root,
        geometry.RectF.init(0, 0, 320, 20_000),
        &long_nodes,
    );
}

test "token-dense numbered code falls back below the retained span budget" {
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

    // Numbered rendering would retain 1,027 spans: twelve highlighted
    // spans plus one gutter span for each logical line.
    try testing.expectEqual(@as(usize, 0), countByKind(fallback.root, .row));
    try testing.expect(countTextSpans(fallback.root) <= Ui.max_code_spans_per_surface);

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
