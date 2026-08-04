//! `native_sdk.markdown` — a GitHub-flavored-markdown subset mapped onto
//! the widget tree + inline span model.
//!
//! `Markdown(Msg).view(ui, source, options)` returns an ordinary builder
//! node usable inside any hand-written `view` fn: blocks become the same
//! widgets an author would compose by hand (columns, rows, panels,
//! checkboxes, separators) and inline styling becomes span paragraphs, so
//! layout, theming, semantics, and hit-testing all come from the existing
//! engine.
//!
//! Supported blocks: `#`/`##`/`###` headings (deeper levels clamp to h3),
//! paragraphs, bullet/ordered/task lists (nesting up to
//! `max_markdown_list_depth` by two-space indent), fenced code blocks
//! (source indentation preserved and language-tagged fences highlighted),
//! `>` blockquotes, horizontal rules, GFM pipe tables (header row +
//! delimiter row + body rows onto `table`/`data_row`/`data_cell` widgets;
//! `:---`/`:--:`/`---:` delimiter cells set per-column start/center/end
//! text alignment, header cells render bold, and every cell runs the full
//! inline span grammar including links), a safe presentational HTML subset,
//! and `<details>`/`<summary>`.
//! Supported inlines: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
//! `` `code` ``, `~~strikethrough~~`, `[text](url)` links, `<url>`
//! autolinks, bare `http(s)://` URLs at word boundaries (GFM-style
//! autolink extension, trailing punctuation trimmed), `#123` issue
//! references (opt-in via `Options.issue_link_base`, since resolving a
//! ref needs repo context), and `![alt](url)` images (rendered as their
//! alt text). GitHub-style HTML covers the matching native presentation:
//! emphasis/strong/strike/underline/code spans, anchors, line breaks,
//! headings, paragraphs, blockquotes, horizontal rules, image alt text,
//! harmless structural wrappers, comments, and common HTML entities.
//! Attributes other than `href`, `alt`, and block `align` are ignored;
//! there is no DOM, CSS, script execution, or remote image loading.
//!
//! Deliberately unsupported in v1 (rendered as plain paragraph text, never
//! a build failure): setext headings, indented code blocks, backslash
//! escapes (except `\|` inside table rows, which GFM needs to put a pipe
//! in a cell), reference-style links, HTML with no native presentation
//! (scripts, styles, embeds, and forms), and footnotes. Malformed input degrades to literal
//! text — a pipe block whose delimiter row is missing or does not match
//! the header's column count renders as plain paragraphs, and tables
//! wider than `max_markdown_table_columns` degrade the same way rather
//! than silently dropping columns.
//!
//! State model (Elm-style, no hidden state):
//! - Task-list checkboxes render as disabled checkboxes — display only.
//! - `<details>` blocks are collapsible through the CALLER's model: pass
//!   `details_expanded` (flags indexed by details-block order in the
//!   document) and `on_details` (a Msg constructor receiving that index).
//!   The recommended wiring is a bounded bool array in the model that
//!   `update` toggles on the details message:
//!
//!   ```zig
//!   const Msg = union(enum) { open_url: []const u8, toggle_details: usize };
//!   // model.details_expanded: [8]bool = .{false} ** 8;
//!   markdown.view(ui, source, .{
//!       .on_link = Ui.linkMsg(.open_url),
//!       .on_details = Md.detailsMsg(.toggle_details),
//!       .details_expanded = &model.details_expanded,
//!   });
//!   ```
//!
//! Std-only, allocator-explicit: every allocation goes through the
//! builder's arena, and node/span buffers are capacity-bounded; documents
//! that exceed a capacity truncate deterministically.

const std = @import("std");
const code_model = @import("code.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_spans = @import("text_spans.zig");
const ui_builder = @import("ui.zig");

const TextSpan = text_spans.TextSpan;

/// Capacity conventions (`canvas_limits` style): blocks per container,
/// list nesting depth, and details blocks per document. Overflow keeps
/// the tree valid and drops trailing content.
pub const max_markdown_blocks_per_container: usize = 64;
pub const max_markdown_list_items_per_list: usize = 64;
pub const max_markdown_list_depth: usize = 4;
pub const max_markdown_details_per_document: usize = 16;
pub const max_markdown_html_block_depth: usize = 8;
pub const max_markdown_table_columns: usize = 8;
/// Rows per table including the header; trailing rows drop deterministically.
pub const max_markdown_table_rows: usize = 64;
/// Joined bytes per paragraph or blockquote (consecutive source lines
/// collapse into one text widget). Sized generously past real GitHub
/// prose — paragraphs beyond a couple of KiB are pathological input —
/// and well under the runtime's per-view widget-text budget, so a
/// hostile megabyte-long "paragraph" truncates deterministically here
/// instead of ballooning the build arena. The block's remaining lines
/// are still consumed, so parsing resumes at the next block.
pub const max_markdown_paragraph_bytes: usize = 8192;

/// Heading scales relative to the body typography token (GitHub's em
/// ladder), applied through the span `scale` channel so heading pixel
/// sizes stay derived from live tokens.
pub const heading_scales = [_]f32{ 2.0, 1.5, 1.25 };

pub fn Markdown(comptime Msg: type) type {
    return struct {
        pub const Ui = ui_builder.Ui(Msg);
        const Node = Ui.Node;

        pub const Options = struct {
            /// Msg constructor for link presses (pair with `Ui.linkMsg`).
            /// Null renders links styled but inert.
            on_link: ?Ui.LinkMsgFn = null,
            /// Msg constructor for `<details>` summary presses; receives
            /// the details block's document-order index. Pair with
            /// `detailsMsg`. Null renders summaries inert.
            on_details: ?*const fn (index: usize) Msg = null,
            /// Expanded flags for `<details>` blocks in document order;
            /// blocks beyond the slice render collapsed.
            details_expanded: []const bool = &.{},
            /// Non-null turns `#123` issue references at word boundaries
            /// (issue-tracker-client semantics: not preceded by a word
            /// byte, `/`, or `&`; digits end at a word boundary) into
            /// link spans whose target is this prefix followed by the
            /// number — an app scheme (`"ghissue://"`) or a web base
            /// (`"https://github.com/owner/repo/issues/"`). The press
            /// dispatches through `on_link` like any other link. Null
            /// keeps refs as plain text (they need repo context to
            /// resolve, so there is no default).
            issue_link_base: ?[]const u8 = null,
        };

        /// Comptime message constructor for `on_details`:
        /// `detailsMsg(.toggle_details)` yields a function building
        /// `Msg{ .toggle_details = index }`.
        pub fn detailsMsg(comptime tag: std.meta.Tag(Msg)) *const fn (index: usize) Msg {
            return struct {
                fn make(index: usize) Msg {
                    return @unionInit(Msg, @tagName(tag), index);
                }
            }.make;
        }

        /// Map a markdown source into a widget subtree. Never fails: arena
        /// exhaustion latches on the builder (surfacing from `finalize`,
        /// the existing convention) and malformed markdown degrades to
        /// plain text.
        pub fn view(ui: *Ui, source: []const u8, options: Options) Node {
            var builder = Builder{ .ui = ui, .options = options };
            var lines = LineIterator{ .source = source };
            const blocks = builder.parseBlocks(&lines, .document);
            return ui.column(.{ .gap = 12 }, blocks);
        }

        const BlockScope = enum {
            document,
            details,
            html_blockquote,
        };

        const Builder = struct {
            ui: *Ui,
            options: Options,
            details_count: usize = 0,
            /// GitHub permits `align` on a few safe block wrappers. A
            /// standalone `<div align="center">` commonly wraps several
            /// README blocks, so remember that presentation until its
            /// closing wrapper rather than requiring a browser layout tree.
            html_alignment: ?canvas.TextAlign = null,
            html_heading_level: ?usize = null,
            html_block_scope_stack: [16]HtmlBlockScope = undefined,
            html_block_scope_depth: usize = 0,
            html_block_scope_overflow_depth: usize = 0,
            html_block_depth: usize = 0,

            const HtmlBlockScope = struct {
                name: []const u8,
                previous_alignment: ?canvas.TextAlign,
                previous_heading_level: ?usize,
            };

            fn allocNodes(self: *Builder) []Node {
                return self.ui.arena.alloc(Node, max_markdown_blocks_per_container) catch {
                    self.ui.failed = true;
                    return &.{};
                };
            }

            fn parseBlocks(self: *Builder, lines: *LineIterator, scope: BlockScope) []const Node {
                const nodes = self.allocNodes();
                if (nodes.len == 0) return &.{};
                var len: usize = 0;

                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (scope == .details and std.ascii.startsWithIgnoreCase(trimmed, "</details>")) {
                        _ = lines.next();
                        break;
                    }

                    const blockquote_close = if (scope == .html_blockquote)
                        findUnbalancedHtmlClosingTag(line, "blockquote")
                    else
                        null;
                    const scope_close = if (self.activeHtmlBlockScopeName()) |name|
                        findUnbalancedHtmlClosingTag(line, name)
                    else if (self.html_block_scope_overflow_depth > 0)
                        findUnbalancedHtmlPersistentClosingTag(line)
                    else
                        null;
                    if (earlierHtmlTagMatch(blockquote_close, scope_close)) |match| {
                        _ = lines.next();
                        self.appendHtmlLineFragment(nodes, &len, line[0..match.start]);
                        const suffix = line[match.end..];
                        if (suffix.len > 0) lines.prepend(suffix);
                        if (scope_close != null and match.start == scope_close.?.start) {
                            _ = self.closeHtmlBlockScope(match.tag);
                            continue;
                        }
                        break;
                    }
                    if (trimmed.len == 0) {
                        _ = lines.next();
                        continue;
                    }
                    const node = self.parseBlock(lines) orelse continue;
                    if (len >= nodes.len) break;
                    nodes[len] = node;
                    len += 1;
                }
                return nodes[0..len];
            }

            fn appendHtmlLineFragment(self: *Builder, nodes: []Node, len: *usize, fragment: []const u8) void {
                var fragment_lines = LineIterator{ .source = fragment };
                while (fragment_lines.peek()) |line| {
                    if (std.mem.trim(u8, line, " \t").len == 0) {
                        _ = fragment_lines.next();
                        continue;
                    }
                    const node = self.parseBlock(&fragment_lines) orelse continue;
                    if (len.* >= nodes.len) return;
                    nodes[len.*] = node;
                    len.* += 1;
                }
            }

            fn parseBlock(self: *Builder, lines: *LineIterator) ?Node {
                const line = lines.peek() orelse return null;
                const trimmed = std.mem.trim(u8, line, " \t");

                if (std.mem.startsWith(u8, trimmed, "```")) return self.parseCodeFence(lines);
                if (headingLevel(trimmed)) |level| {
                    _ = lines.next();
                    return self.heading(level, std.mem.trim(u8, trimmed[level..], " \t#"));
                }
                if (isHorizontalRule(trimmed)) {
                    _ = lines.next();
                    return self.ui.separator(.{});
                }
                if (std.mem.startsWith(u8, trimmed, ">")) return self.parseBlockquote(lines);
                if (listMarker(line)) |_| return self.parseList(lines, 0, 0);
                if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) return self.parseDetails(lines);
                switch (self.parseHtmlBlock(lines, trimmed)) {
                    .not_html => {},
                    .skipped => return null,
                    .node => |node| return node,
                }
                if (isTableStart(lines)) return self.parseTable(lines);
                return self.parseParagraph(lines);
            }

            // ------------------------------------------------------ blocks

            fn heading(self: *Builder, level: usize, content: []const u8) Node {
                const effective_level = self.html_heading_level orelse level;
                const scale = heading_scales[@min(effective_level, heading_scales.len) - 1];
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(content, .{ .weight = .bold, .scale = scale }, &spans);
                return self.ui.paragraph(.{
                    .on_link = self.options.on_link,
                    .text_alignment = self.html_alignment orelse .start,
                }, parsed);
            }

            fn parseParagraph(self: *Builder, lines: *LineIterator) ?Node {
                const text = self.collectJoined(lines, .paragraph);
                if (text.len == 0) return null;
                return self.paragraphNode(text, .{});
            }

            const JoinKind = enum { paragraph, blockquote };

            /// The next joined piece of a paragraph or blockquote at
            /// `lines`' current position, or null when the block ends
            /// there. `joined_len` is the text joined so far (the
            /// paragraph break rules only apply once the block has
            /// content). Tables interrupt paragraphs (GFM): a header
            /// line followed by a matching delimiter row starts a table.
            fn joinPiece(lines: *LineIterator, kind: JoinKind, joined_len: usize) ?[]const u8 {
                const line = lines.peek() orelse return null;
                const trimmed = std.mem.trim(u8, line, " \t");
                switch (kind) {
                    .blockquote => {
                        if (!std.mem.startsWith(u8, trimmed, ">")) return null;
                        var inner = trimmed[1..];
                        if (std.mem.startsWith(u8, inner, " ")) inner = inner[1..];
                        return std.mem.trim(u8, inner, " \t");
                    },
                    .paragraph => {
                        if (trimmed.len == 0) return null;
                        if (joined_len > 0 and (startsNewBlock(line) or isTableStart(lines))) return null;
                        return trimmed;
                    },
                }
            }

            /// Join a block's consecutive lines with single spaces into
            /// ONE arena allocation. Measuring first keeps hostile input
            /// linear: re-joining per line is quadratic in both time and
            /// arena memory (a megabyte-long single paragraph used to
            /// demand gigabytes). Joined text truncates deterministically
            /// at `max_markdown_paragraph_bytes`; the block's remaining
            /// lines are still consumed either way.
            fn collectJoined(self: *Builder, lines: *LineIterator, kind: JoinKind) []const u8 {
                // Pass 1: measure the block's extent and joined size.
                var probe = lines.*;
                var total: usize = 0;
                while (joinPiece(&probe, kind, total)) |piece| {
                    _ = probe.next();
                    if (total > 0) total += 1;
                    total += piece.len;
                }
                if (total == 0) {
                    lines.* = probe;
                    return &.{};
                }

                const out = self.ui.arena.alloc(u8, @min(total, max_markdown_paragraph_bytes)) catch {
                    self.ui.failed = true;
                    lines.* = probe;
                    return &.{};
                };

                // Pass 2: identical walk, copying until the cap.
                var len: usize = 0;
                var joined: usize = 0;
                while (joinPiece(lines, kind, joined)) |piece| {
                    _ = lines.next();
                    if (joined > 0 and len < out.len) {
                        out[len] = ' ';
                        len += 1;
                    }
                    if (joined > 0) joined += 1;
                    joined += piece.len;
                    const take = @min(piece.len, out.len - len);
                    @memcpy(out[len..][0..take], piece[0..take]);
                    len += take;
                }
                return out[0..len];
            }

            fn paragraphNode(self: *Builder, text: []const u8, base: TextSpan) Node {
                var effective_base = base;
                if (self.html_heading_level) |level| {
                    effective_base.weight = .bold;
                    effective_base.scale = heading_scales[@min(level, heading_scales.len) - 1];
                }
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, effective_base, &spans);
                return self.ui.paragraph(.{
                    .on_link = self.options.on_link,
                    .text_alignment = self.html_alignment orelse .start,
                }, parsed);
            }

            fn parseCodeFence(self: *Builder, lines: *LineIterator) ?Node {
                const opening = lines.next() orelse return null;
                const language = code_model.languageFromFence(opening);
                const start = lines.index;
                var end = start;
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) break;
                    end = lines.index;
                }
                const code = std.mem.trimEnd(u8, lines.source[start..@min(end, lines.source.len)], "\n");
                return self.ui.code(.{ .language = language }, code);
            }

            fn parseBlockquote(self: *Builder, lines: *LineIterator) ?Node {
                const text = self.collectJoined(lines, .blockquote);
                if (text.len == 0) return null;
                return self.ui.row(.{ .gap = 10 }, .{
                    self.ui.el(.separator, .{ .frame = geometry.RectF.init(0, 0, 3, 0) }, .{}),
                    self.paragraphWithOptions(text, .{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }),
                });
            }

            fn paragraphWithOptions(self: *Builder, text: []const u8, options_in: Ui.ElementOptions) Node {
                var options = options_in;
                options.on_link = self.options.on_link;
                if (self.html_alignment) |alignment| options.text_alignment = alignment;
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, .{}, &spans);
                return self.ui.paragraph(options, parsed);
            }

            fn parseList(self: *Builder, lines: *LineIterator, indent: usize, depth: usize) ?Node {
                const items = self.ui.arena.alloc(Node, max_markdown_list_items_per_list) catch {
                    self.ui.failed = true;
                    return null;
                };
                var len: usize = 0;

                while (lines.peek()) |line| {
                    const marker = listMarker(line) orelse break;
                    if (marker.indent < indent) break;
                    if (marker.indent > indent) {
                        // Deeper marker: a nested list under the previous item.
                        if (len == 0 or depth + 1 >= max_markdown_list_depth) {
                            _ = lines.next();
                            continue;
                        }
                        const nested = self.parseList(lines, marker.indent, depth + 1) orelse continue;
                        items[len - 1] = self.ui.column(.{ .gap = 4 }, .{ items[len - 1], nested });
                        continue;
                    }
                    _ = lines.next();
                    if (len >= items.len) continue;
                    items[len] = self.listItemNode(marker, depth);
                    len += 1;
                }
                if (len == 0) return null;
                return self.ui.column(.{ .gap = 4 }, .{items[0..len]});
            }

            fn listItemNode(self: *Builder, marker: ListMarker, depth: usize) Node {
                const content = self.paragraphWithOptions(marker.content, .{ .grow = 1 });
                const lead: Node = switch (marker.kind) {
                    .bullet => self.ui.text(.{}, "•"),
                    .ordered => self.ui.text(.{}, marker.label),
                    .task => self.ui.checkbox(.{
                        .checked = marker.checked,
                        .disabled = true,
                        .semantics = .{ .label = marker.content },
                    }),
                };
                // The outer row must keep stretch alignment so a wrapped
                // paragraph receives the row's full measured height. A
                // one-child column consumes that stretched marker slot
                // while laying its marker at the slot's leading edge.
                const lead_top = self.ui.column(.{}, .{lead});
                if (depth == 0) return self.ui.row(.{ .gap = 8 }, .{ lead_top, content });
                const indent = self.ui.el(.stack, .{ .width = @as(f32, @floatFromInt(depth)) * 16 }, .{});
                return self.ui.row(.{ .gap = 8 }, .{ indent, lead_top, content });
            }

            const HtmlBlockResult = union(enum) {
                not_html,
                skipped,
                node: Node,
            };

            /// Lower the small block-shaped portion of GitHub's safe HTML
            /// vocabulary onto native widgets. Inline-shaped tags are left
            /// to `parseInline`; unsupported tags fall through literally.
            fn parseHtmlBlock(self: *Builder, lines: *LineIterator, trimmed: []const u8) HtmlBlockResult {
                if (parseHtmlCommentAt(trimmed, 0, null)) |comment| {
                    if (comment.consumed == trimmed.len) {
                        _ = lines.next();
                        return .skipped;
                    }
                }

                const opening = parseHtmlTagAt(trimmed, 0) orelse return .not_html;
                if (opening.closing or !isHtmlBlockTag(opening)) {
                    if (opening.consumed == trimmed.len and opening.closing and isHtmlStructuralTag(opening)) {
                        if (!self.closeHtmlBlockScope(opening)) return .not_html;
                        _ = lines.next();
                        return .skipped;
                    }
                    return .not_html;
                }

                if (opening.kind == .horizontal_rule and opening.consumed == trimmed.len) {
                    _ = lines.next();
                    return .{ .node = self.ui.separator(.{}) };
                }

                if (opening.kind == .blockquote and opening.consumed == trimmed.len) {
                    _ = lines.next();
                    if (opening.self_closing) return .skipped;
                    if (self.html_block_depth >= max_markdown_html_block_depth) {
                        skipHtmlElement(lines, opening.name);
                        return .skipped;
                    }
                    self.html_block_depth += 1;
                    const blocks = self.parseBlocks(lines, .html_blockquote);
                    self.html_block_depth -= 1;
                    return .{ .node = self.ui.row(.{ .gap = 10 }, .{
                        self.ui.el(.separator, .{ .frame = geometry.RectF.init(0, 0, 3, 0) }, .{}),
                        self.ui.column(.{ .gap = 12, .grow = 1 }, blocks),
                    }) };
                }

                if (opening.kind == .preformatted and opening.consumed == trimmed.len) {
                    _ = lines.next();
                    if (opening.self_closing) return .skipped;
                    return .{ .node = self.ui.code(.{}, self.collectHtmlPreformatted(lines)) };
                }

                if (singleLineHtmlElement(trimmed, opening)) |element| {
                    const alignment = htmlTagAlignment(opening) orelse self.html_alignment orelse .start;
                    return switch (opening.kind) {
                        .heading => blk: {
                            _ = lines.next();
                            break :blk .{ .node = self.htmlHeading(opening.heading_level, element.content, alignment) };
                        },
                        .paragraph, .container, .list, .table, .table_section, .table_row, .table_cell => blk: {
                            _ = lines.next();
                            break :blk .{ .node = self.htmlParagraph(element.content, alignment) };
                        },
                        .blockquote => blk: {
                            _ = lines.next();
                            break :blk .{ .node = self.ui.row(.{ .gap = 10 }, .{
                                self.ui.el(.separator, .{ .frame = geometry.RectF.init(0, 0, 3, 0) }, .{}),
                                self.htmlParagraphWithOptions(element.content, alignment, .{
                                    .grow = 1,
                                    .style_tokens = .{ .foreground = .text_muted },
                                }),
                            }) };
                        },
                        .preformatted => blk: {
                            _ = lines.next();
                            const code = self.decodeHtmlEntities(unwrapHtmlCode(element.content));
                            break :blk .{ .node = self.ui.code(.{}, code) };
                        },
                        .list_item => blk: {
                            _ = lines.next();
                            break :blk .{ .node = self.htmlListItem(element.content) };
                        },
                        else => .not_html,
                    };
                }

                // A structural tag on its own line is presentation-only.
                // Keep its alignment/heading scope for the Markdown blocks
                // between the opener and closer, then emit no empty widget.
                if (opening.consumed == trimmed.len and isHtmlStructuralTag(opening)) {
                    _ = lines.next();
                    if (opening.self_closing) return .skipped;
                    self.openHtmlBlockScope(opening);
                    return .skipped;
                }
                return .not_html;
            }

            fn openHtmlBlockScope(self: *Builder, tag: HtmlTag) void {
                if (!isPersistentHtmlBlockTag(tag) or tag.self_closing) return;
                if (self.html_block_scope_depth < self.html_block_scope_stack.len) {
                    self.html_block_scope_stack[self.html_block_scope_depth] = .{
                        .name = tag.name,
                        .previous_alignment = self.html_alignment,
                        .previous_heading_level = self.html_heading_level,
                    };
                    self.html_block_scope_depth += 1;
                } else {
                    self.html_block_scope_overflow_depth += 1;
                    return;
                }
                if (isHtmlAlignmentContainer(tag)) {
                    if (htmlTagAlignment(tag)) |alignment| self.html_alignment = alignment;
                }
                if (tag.kind == .heading) self.html_heading_level = tag.heading_level;
            }

            fn activeHtmlBlockScopeName(self: *Builder) ?[]const u8 {
                if (self.html_block_scope_overflow_depth > 0 or self.html_block_scope_depth == 0) return null;
                return self.html_block_scope_stack[self.html_block_scope_depth - 1].name;
            }

            fn closeHtmlBlockScope(self: *Builder, tag: HtmlTag) bool {
                if (!isPersistentHtmlBlockTag(tag)) return true;
                if (self.html_block_scope_overflow_depth > 0) {
                    self.html_block_scope_overflow_depth -= 1;
                    return true;
                }
                if (self.html_block_scope_depth == 0) return false;
                const scope = self.html_block_scope_stack[self.html_block_scope_depth - 1];
                if (!std.ascii.eqlIgnoreCase(scope.name, tag.name)) return false;
                self.html_block_scope_depth -= 1;
                self.html_alignment = scope.previous_alignment;
                self.html_heading_level = scope.previous_heading_level;
                return true;
            }

            fn collectHtmlPreformatted(self: *Builder, lines: *LineIterator) []const u8 {
                var probe = lines.*;
                var probe_depth: usize = 1;
                var total: usize = 0;
                while (probe.next()) |line| {
                    const scan = scanHtmlElementLine(line, "pre", &probe_depth);
                    total += scan.content_end;
                    if (scan.closing_end) |closing_end| {
                        const suffix = line[closing_end..];
                        if (suffix.len > 0) probe.prepend(suffix);
                        break;
                    }
                    total += 1;
                }

                const out = self.ui.arena.alloc(u8, total) catch {
                    self.ui.failed = true;
                    lines.* = probe;
                    return &.{};
                };
                var depth: usize = 1;
                var len: usize = 0;
                while (lines.next()) |line| {
                    const scan = scanHtmlElementLine(line, "pre", &depth);
                    if (scan.content_end > 0) {
                        @memcpy(out[len..][0..scan.content_end], line[0..scan.content_end]);
                        len += scan.content_end;
                    }
                    if (scan.closing_end) |closing_end| {
                        const suffix = line[closing_end..];
                        if (suffix.len > 0) lines.prepend(suffix);
                        break;
                    }
                    out[len] = '\n';
                    len += 1;
                }
                const raw = std.mem.trim(u8, out[0..len], "\r\n");
                const code = std.mem.trim(u8, unwrapHtmlCode(raw), "\r\n");
                return self.decodeHtmlEntities(code);
            }

            fn htmlHeading(self: *Builder, level: usize, content: []const u8, alignment: canvas.TextAlign) Node {
                const scale = heading_scales[@min(level, heading_scales.len) - 1];
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(content, .{ .weight = .bold, .scale = scale }, &spans);
                return self.ui.paragraph(.{ .on_link = self.options.on_link, .text_alignment = alignment }, parsed);
            }

            fn htmlParagraph(self: *Builder, content: []const u8, alignment: canvas.TextAlign) Node {
                return self.htmlParagraphWithOptions(content, alignment, .{});
            }

            fn htmlParagraphWithOptions(
                self: *Builder,
                content: []const u8,
                alignment: canvas.TextAlign,
                options_in: Ui.ElementOptions,
            ) Node {
                var options = options_in;
                options.on_link = self.options.on_link;
                options.text_alignment = alignment;
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(content, .{}, &spans);
                return self.ui.paragraph(options, parsed);
            }

            fn htmlListItem(self: *Builder, content: []const u8) Node {
                const marker = ListMarker{ .kind = .bullet, .indent = 0, .label = "", .content = content };
                return self.listItemNode(marker, 0);
            }

            fn parseDetails(self: *Builder, lines: *LineIterator) ?Node {
                _ = lines.next(); // <details ...>
                const ordinal = self.details_count;
                if (ordinal >= max_markdown_details_per_document) {
                    self.skipDetails(lines);
                    return null;
                }
                self.details_count += 1;
                const expanded = ordinal < self.options.details_expanded.len and self.options.details_expanded[ordinal];

                var summary: []const u8 = "Details";
                if (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "<summary>")) {
                        _ = lines.next();
                        summary = trimmed["<summary>".len..];
                        if (std.ascii.indexOfIgnoreCase(summary, "</summary>")) |close| {
                            summary = summary[0..close];
                        }
                        summary = std.mem.trim(u8, summary, " \t");
                    }
                }

                var header = self.ui.listItem(.{
                    .key = .{ .int = @intCast(ordinal) },
                    .on_press = if (self.options.on_details) |make| make(ordinal) else null,
                }, self.ui.fmt("{s} {s}", .{ if (expanded) "▾" else "▸", summary }));
                header.widget.state.expanded = expanded;

                if (!expanded) {
                    self.skipDetails(lines);
                    return self.ui.column(.{ .gap = 4 }, .{header});
                }
                const blocks = self.parseBlocks(lines, .details);
                const body = self.ui.column(.{ .gap = 12, .padding = 8 }, blocks);
                return self.ui.column(.{ .gap = 4 }, .{ header, body });
            }

            /// GFM pipe table: the caller (`isTableStart`) has verified a
            /// header row followed by a delimiter row with a matching
            /// column count. Body rows run until a blank line or a line
            /// without a pipe; short rows pad with empty cells and long
            /// rows drop trailing cells (GFM semantics). Rows past
            /// `max_markdown_table_rows` drop deterministically.
            fn parseTable(self: *Builder, lines: *LineIterator) ?Node {
                const header_line = lines.next() orelse return null;
                const header = splitTableRow(header_line) orelse return null;
                const delimiter_line = lines.next() orelse return null;
                const alignments = tableDelimiterAlignments(delimiter_line) orelse return null;
                if (alignments.len != header.len) return null;

                const rows = self.ui.arena.alloc(Node, max_markdown_table_rows) catch {
                    self.ui.failed = true;
                    return null;
                };
                rows[0] = self.tableRowNode(header, alignments, true);
                var len: usize = 1;
                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (trimmed.len == 0) break;
                    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) break;
                    const row = splitTableRow(line) orelse break;
                    _ = lines.next();
                    if (len >= rows.len) continue;
                    rows[len] = self.tableRowNode(row, alignments, false);
                    len += 1;
                }
                return self.ui.el(.table, .{}, .{rows[0..len]});
            }

            fn tableRowNode(self: *Builder, row: TableRow, alignments: TableAlignments, is_header: bool) Node {
                const cells = self.ui.arena.alloc(Node, alignments.len) catch {
                    self.ui.failed = true;
                    return self.ui.el(.data_row, .{}, .{});
                };
                for (cells, 0..) |*cell, column| {
                    const content = if (column < row.len) row.cells[column] else "";
                    cell.* = self.tableCellNode(content, alignments.columns[column], is_header);
                }
                return self.ui.el(.data_row, .{}, .{cells});
            }

            /// One cell: a `data_cell` widget carrying inline spans (the
            /// full inline grammar, links included), per-column text
            /// alignment from the delimiter row, and bold header styling.
            fn tableCellNode(self: *Builder, content: []const u8, alignment: canvas.TextAlign, is_header: bool) Node {
                const text = self.unescapeTablePipes(content);
                const base: TextSpan = if (is_header) .{ .weight = .bold } else .{};
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, base, &spans);
                var cell = self.ui.paragraph(.{
                    .grow = 1,
                    .padding = 8,
                    .on_link = self.options.on_link,
                }, parsed);
                cell.widget.kind = .data_cell;
                cell.widget.text_alignment = alignment;
                return cell;
            }

            /// `\|` is the one backslash escape tables need (a literal
            /// pipe inside a cell); everything else keeps the mapper's
            /// no-escapes policy.
            fn unescapeTablePipes(self: *Builder, text: []const u8) []const u8 {
                if (std.mem.indexOf(u8, text, "\\|") == null) return text;
                const out = self.ui.arena.alloc(u8, text.len) catch {
                    self.ui.failed = true;
                    return text;
                };
                var len: usize = 0;
                var index: usize = 0;
                while (index < text.len) : (index += 1) {
                    if (text[index] == '\\' and index + 1 < text.len and text[index + 1] == '|') continue;
                    out[len] = text[index];
                    len += 1;
                }
                return out[0..len];
            }

            fn skipDetails(self: *Builder, lines: *LineIterator) void {
                _ = self;
                var depth: usize = 1;
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) depth += 1;
                    if (std.ascii.startsWithIgnoreCase(trimmed, "</details>")) {
                        depth -= 1;
                        if (depth == 0) return;
                    }
                }
            }

            // ----------------------------------------------------- inlines

            /// Scan inline markdown into spans carrying `base` styling
            /// (headings pass bold + scale). Delimiters without a closer,
            /// and any construct this subset does not model, fall through
            /// as literal text. Span-capacity overflow appends the rest of
            /// the text as one unstyled span.
            fn parseInline(self: *Builder, text: []const u8, base: TextSpan, spans: *[text_spans.max_text_spans_per_paragraph]TextSpan) []const TextSpan {
                var len: usize = 0;
                var style = InlineStyleState{};
                var literal_start: usize = 0;
                var index: usize = 0;
                var scan_cache = ScanCache{};
                var consumed_html = false;

                while (index < text.len) {
                    if (len + 2 >= spans.len) break;
                    const rest = text[index..];

                    if (rest[0] == '`') {
                        if (std.mem.indexOfScalar(u8, rest[1..], '`')) |close| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = rest[1 .. 1 + close], .monospace = true });
                            index += close + 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__")) {
                        const delim = rest[0..2];
                        if (style.markdown_bold or hasCloser(rest[2..], delim)) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_bold = !style.markdown_bold;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "~~")) {
                        if (style.markdown_strike or hasCloser(rest[2..], "~~")) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_strike = !style.markdown_strike;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '*' or rest[0] == '_') {
                        const delim = rest[0..1];
                        const boundary_ok = rest[0] == '*' or index == 0 or !isWordByte(text[index - 1]);
                        const emphasis_ok = if (style.markdown_italic)
                            true
                        else
                            rest.len > 1 and !isInlineSpace(rest[1]) and hasCloser(rest[1..], delim);
                        if (boundary_ok and emphasis_ok) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_italic = !style.markdown_italic;
                            index += 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '[') {
                        if (parseLinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '!' and rest.len > 1 and rest[1] == '[') {
                        if (parseLinkAt(text, index + 1, &scan_cache)) |image| {
                            // Images render as their alt text in v1.
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = image.text });
                            index += image.consumed + 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '<') {
                        if (parseHtmlCommentAt(text, index, &scan_cache)) |comment| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            consumed_html = true;
                            index += comment.consumed;
                            literal_start = index;
                            continue;
                        } else if (parseAutolinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        } else if (parseHtmlTagAt(text, index)) |tag| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            consumed_html = true;
                            self.applyHtmlTag(spans, &len, base, &style, tag);
                            index += tag.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '&') {
                        if (self.decodeHtmlEntity(rest)) |entity| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = entity.text });
                            consumed_html = true;
                            index += entity.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == 'h' and atAutolinkBoundary(text, index)) {
                        if (parseBareUrlAt(rest)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '#' and atAutolinkBoundary(text, index)) {
                        if (self.options.issue_link_base) |issue_base| {
                            if (parseIssueRefAt(rest)) |ref| {
                                flushLiteral(spans, &len, text[literal_start..index], base, style);
                                appendStyledSpan(spans, &len, base, style, .{
                                    .text = rest[0..ref.consumed],
                                    .link = self.ui.fmt("{s}{s}", .{ issue_base, ref.digits }),
                                });
                                index += ref.consumed;
                                literal_start = index;
                                continue;
                            }
                        }
                    }
                    index += 1;
                }
                // Tail (including everything after a span-capacity stop),
                // styled with the state at the stop point.
                flushLiteral(spans, &len, text[literal_start..], base, style);
                if (len == 0 and !consumed_html) {
                    spans[0] = spanWith(base, .{ .text = text });
                    len = 1;
                }
                return spans[0..len];
            }

            const InlineStyleState = struct {
                markdown_bold: bool = false,
                markdown_italic: bool = false,
                markdown_strike: bool = false,
                html_bold: usize = 0,
                html_italic: usize = 0,
                html_strike: usize = 0,
                html_underline: usize = 0,
                html_monospace: usize = 0,
                html_mark: usize = 0,
                html_small: usize = 0,
                html_heading_level: ?usize = null,
                html_link: []const u8 = "",
            };

            fn applyHtmlTag(
                self: *Builder,
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                base: TextSpan,
                style: *InlineStyleState,
                tag: HtmlTag,
            ) void {
                const active = !tag.self_closing;
                switch (tag.kind) {
                    .bold => updateHtmlDepth(&style.html_bold, tag.closing, active),
                    .italic => updateHtmlDepth(&style.html_italic, tag.closing, active),
                    .strike => updateHtmlDepth(&style.html_strike, tag.closing, active),
                    .underline => updateHtmlDepth(&style.html_underline, tag.closing, active),
                    .monospace, .preformatted => updateHtmlDepth(&style.html_monospace, tag.closing, active),
                    .mark => updateHtmlDepth(&style.html_mark, tag.closing, active),
                    .small => updateHtmlDepth(&style.html_small, tag.closing, active),
                    .heading => style.html_heading_level = if (tag.closing or tag.self_closing) null else tag.heading_level,
                    .link => {
                        if (tag.closing or tag.self_closing) {
                            style.html_link = "";
                        } else {
                            const href = htmlAttribute(tag, "href") orelse "";
                            style.html_link = self.decodeHtmlEntities(href);
                        }
                    },
                    .line_break => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .word_break => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\u{200b}" }),
                    .image => if (!tag.closing) {
                        if (htmlAttribute(tag, "alt")) |alt| {
                            appendStyledSpan(spans, len, base, style.*, .{ .text = self.decodeHtmlEntities(alt) });
                        }
                    },
                    .quote => appendStyledSpan(spans, len, base, style.*, .{ .text = if (tag.closing) "”" else "“" }),
                    .list_item => appendStyledSpan(spans, len, base, style.*, .{ .text = if (tag.closing) "\n" else "• " }),
                    .table_cell => if (tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\t" }),
                    .table_row => if (tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .horizontal_rule => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .paragraph, .blockquote, .list, .table, .table_section, .container => {},
                }
            }

            fn decodeHtmlEntities(self: *Builder, text: []const u8) []const u8 {
                if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
                const out = self.ui.arena.alloc(u8, text.len) catch {
                    self.ui.failed = true;
                    return text;
                };
                var source_index: usize = 0;
                var out_len: usize = 0;
                while (source_index < text.len) {
                    if (text[source_index] == '&') {
                        if (self.decodeHtmlEntity(text[source_index..])) |entity| {
                            @memcpy(out[out_len..][0..entity.text.len], entity.text);
                            out_len += entity.text.len;
                            source_index += entity.consumed;
                            continue;
                        }
                    }
                    out[out_len] = text[source_index];
                    out_len += 1;
                    source_index += 1;
                }
                return out[0..out_len];
            }

            fn decodeHtmlEntity(self: *Builder, rest: []const u8) ?DecodedHtmlEntity {
                if (std.mem.startsWith(u8, rest, "&amp;")) return .{ .text = "&", .consumed = 5 };
                if (std.mem.startsWith(u8, rest, "&lt;")) return .{ .text = "<", .consumed = 4 };
                if (std.mem.startsWith(u8, rest, "&gt;")) return .{ .text = ">", .consumed = 4 };
                if (std.mem.startsWith(u8, rest, "&quot;")) return .{ .text = "\"", .consumed = 6 };
                if (std.mem.startsWith(u8, rest, "&apos;")) return .{ .text = "'", .consumed = 6 };
                if (std.mem.startsWith(u8, rest, "&nbsp;")) return .{ .text = "\u{a0}", .consumed = 6 };
                if (!std.mem.startsWith(u8, rest, "&#")) return null;

                const semi = std.mem.indexOfScalar(u8, rest[2..@min(rest.len, 14)], ';') orelse return null;
                const body_end = semi + 2;
                var digits = rest[2..body_end];
                var radix: u8 = 10;
                if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
                    radix = 16;
                    digits = digits[1..];
                }
                if (digits.len == 0) return null;
                const codepoint = std.fmt.parseUnsigned(u21, digits, radix) catch return null;
                if (codepoint == 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return null;
                const bytes = self.ui.arena.alloc(u8, 4) catch {
                    self.ui.failed = true;
                    return null;
                };
                const encoded = std.unicode.utf8Encode(codepoint, bytes) catch return null;
                return .{ .text = bytes[0..encoded], .consumed = body_end + 1 };
            }

            fn flushLiteral(
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                slice: []const u8,
                base: TextSpan,
                style: InlineStyleState,
            ) void {
                if (slice.len == 0) return;
                appendStyledSpan(spans, len, base, style, .{ .text = slice });
            }

            fn appendStyledSpan(
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                base: TextSpan,
                style: InlineStyleState,
                overrides: TextSpan,
            ) void {
                var span = spanWith(base, overrides);
                if (style.markdown_bold or style.html_bold > 0 or style.html_heading_level != null) span.weight = .bold;
                if (style.markdown_italic or style.html_italic > 0) span.italic = true;
                if (style.markdown_strike or style.html_strike > 0) span.strikethrough = true;
                if (style.html_underline > 0) span.underline = true;
                if (style.html_monospace > 0) span.monospace = true;
                if (style.html_mark > 0) span.background = .surface_pressed;
                if (style.html_small > 0) span.scale = if (span.scale > 0) span.scale * 0.875 else 0.875;
                if (style.html_heading_level) |level| span.scale = heading_scales[@min(level, heading_scales.len) - 1];
                if (span.link.len == 0 and style.html_link.len > 0) span.link = style.html_link;
                appendSpan(spans, len, span);
            }

            fn appendSpan(spans: *[text_spans.max_text_spans_per_paragraph]TextSpan, len: *usize, span: TextSpan) void {
                if (len.* >= spans.len) return;
                spans[len.*] = span;
                len.* += 1;
            }

            fn spanWith(base: TextSpan, overrides: TextSpan) TextSpan {
                var span = overrides;
                if (span.weight == .regular) span.weight = base.weight;
                if (!span.italic) span.italic = base.italic;
                if (!span.strikethrough) span.strikethrough = base.strikethrough;
                if (span.scale == 0) span.scale = base.scale;
                if (span.color == null) span.color = base.color;
                return span;
            }
        };
    };
}

// ------------------------------------------------------------- safe HTML

/// The HTML vocabulary is deliberately presentational. Every accepted tag
/// has a native text/widget lowering; everything else stays visible as
/// literal source, so accepting Markdown never creates a DOM or an execution
/// surface.
const HtmlTagKind = enum {
    bold,
    italic,
    strike,
    underline,
    monospace,
    mark,
    small,
    link,
    image,
    line_break,
    word_break,
    quote,
    heading,
    horizontal_rule,
    paragraph,
    blockquote,
    preformatted,
    list,
    list_item,
    table,
    table_section,
    table_row,
    table_cell,
    container,
};

const HtmlTag = struct {
    kind: HtmlTagKind,
    name: []const u8,
    attributes: []const u8,
    closing: bool = false,
    self_closing: bool = false,
    heading_level: usize = 0,
    consumed: usize,
};

const HtmlTagMatch = struct {
    start: usize,
    end: usize,
    tag: HtmlTag,
};

fn earlierHtmlTagMatch(a: ?HtmlTagMatch, b: ?HtmlTagMatch) ?HtmlTagMatch {
    if (a) |first| {
        if (b) |second| return if (first.start <= second.start) first else second;
        return first;
    }
    return b;
}

fn nextHtmlTagMatch(source: []const u8, cursor: *usize) ?HtmlTagMatch {
    while (std.mem.indexOfScalarPos(u8, source, cursor.*, '<')) |start| {
        if (parseHtmlCommentAt(source, start, null)) |comment| {
            cursor.* = start + comment.consumed;
            continue;
        }
        if (parseHtmlTagAt(source, start)) |tag| {
            cursor.* = start + tag.consumed;
            return .{ .start = start, .end = cursor.*, .tag = tag };
        }
        cursor.* = start + 1;
    }
    return null;
}

/// Find a closer for an already-open block scope, ignoring matching tags
/// opened and closed wholly within this line.
fn findUnbalancedHtmlClosingTag(source: []const u8, name: []const u8) ?HtmlTagMatch {
    var cursor: usize = 0;
    var nested: usize = 0;
    while (nextHtmlTagMatch(source, &cursor)) |match| {
        if (!std.ascii.eqlIgnoreCase(match.tag.name, name)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) nested += 1;
            continue;
        }
        if (nested == 0) return match;
        nested -= 1;
    }
    return null;
}

fn findUnbalancedHtmlPersistentClosingTag(source: []const u8) ?HtmlTagMatch {
    var cursor: usize = 0;
    var nested: usize = 0;
    while (nextHtmlTagMatch(source, &cursor)) |match| {
        if (!isPersistentHtmlBlockTag(match.tag)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) nested += 1;
            continue;
        }
        if (nested == 0) return match;
        nested -= 1;
    }
    return null;
}

const HtmlElementLineScan = struct {
    content_end: usize,
    closing_end: ?usize = null,
};

fn scanHtmlElementLine(line: []const u8, name: []const u8, depth: *usize) HtmlElementLineScan {
    var cursor: usize = 0;
    while (nextHtmlTagMatch(line, &cursor)) |match| {
        if (!std.ascii.eqlIgnoreCase(match.tag.name, name)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) depth.* += 1;
            continue;
        }
        if (depth.* > 0) depth.* -= 1;
        if (depth.* == 0) return .{ .content_end = match.start, .closing_end = match.end };
    }
    return .{ .content_end = line.len };
}

const HtmlComment = struct { consumed: usize };
const DecodedHtmlEntity = struct { text: []const u8, consumed: usize };

const SingleLineHtmlElement = struct { content: []const u8 };

/// Parse one allowlisted tag at `source[index]`. The scan rejects another
/// `<` outside a quoted attribute and caps a tag at 1 KiB, keeping a hostile
/// wall of plausible openers linear and capacity-bounded.
fn parseHtmlTagAt(source: []const u8, index: usize) ?HtmlTag {
    if (index >= source.len or source[index] != '<') return null;
    var cursor = index + 1;
    var closing = false;
    if (cursor < source.len and source[cursor] == '/') {
        closing = true;
        cursor += 1;
    }
    if (cursor >= source.len or !std.ascii.isAlphabetic(source[cursor])) return null;

    const name_start = cursor;
    while (cursor < source.len and (std.ascii.isAlphanumeric(source[cursor]) or source[cursor] == '-')) cursor += 1;
    const name = source[name_start..cursor];
    const classified = classifyHtmlTag(name) orelse return null;
    if (cursor < source.len and source[cursor] != '>' and source[cursor] != '/' and !std.ascii.isWhitespace(source[cursor])) return null;

    const attributes_start = cursor;
    const limit = @min(source.len, index + 1024);
    var quote: ?u8 = null;
    while (cursor < limit) : (cursor += 1) {
        const byte = source[cursor];
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '<') return null;
        if (byte != '>') continue;

        const attributes = source[attributes_start..cursor];
        const trimmed_attributes = std.mem.trim(u8, attributes, " \t\r\n");
        return .{
            .kind = classified.kind,
            .name = name,
            .attributes = attributes,
            .closing = closing,
            .self_closing = !closing and trimmed_attributes.len > 0 and trimmed_attributes[trimmed_attributes.len - 1] == '/',
            .heading_level = classified.heading_level,
            .consumed = cursor + 1 - index,
        };
    }
    return null;
}

const ClassifiedHtmlTag = struct {
    kind: HtmlTagKind,
    heading_level: usize = 0,
};

fn classifyHtmlTag(name: []const u8) ?ClassifiedHtmlTag {
    if (std.ascii.eqlIgnoreCase(name, "b") or std.ascii.eqlIgnoreCase(name, "strong")) return .{ .kind = .bold };
    if (std.ascii.eqlIgnoreCase(name, "i") or std.ascii.eqlIgnoreCase(name, "em") or
        std.ascii.eqlIgnoreCase(name, "var") or std.ascii.eqlIgnoreCase(name, "cite")) return .{ .kind = .italic };
    if (std.ascii.eqlIgnoreCase(name, "s") or std.ascii.eqlIgnoreCase(name, "strike") or std.ascii.eqlIgnoreCase(name, "del")) return .{ .kind = .strike };
    if (std.ascii.eqlIgnoreCase(name, "u") or std.ascii.eqlIgnoreCase(name, "ins")) return .{ .kind = .underline };
    if (std.ascii.eqlIgnoreCase(name, "code") or std.ascii.eqlIgnoreCase(name, "kbd") or
        std.ascii.eqlIgnoreCase(name, "samp") or std.ascii.eqlIgnoreCase(name, "tt")) return .{ .kind = .monospace };
    if (std.ascii.eqlIgnoreCase(name, "mark")) return .{ .kind = .mark };
    if (std.ascii.eqlIgnoreCase(name, "small") or std.ascii.eqlIgnoreCase(name, "sub") or std.ascii.eqlIgnoreCase(name, "sup")) return .{ .kind = .small };
    if (std.ascii.eqlIgnoreCase(name, "a")) return .{ .kind = .link };
    if (std.ascii.eqlIgnoreCase(name, "img")) return .{ .kind = .image };
    if (std.ascii.eqlIgnoreCase(name, "br")) return .{ .kind = .line_break };
    if (std.ascii.eqlIgnoreCase(name, "wbr")) return .{ .kind = .word_break };
    if (std.ascii.eqlIgnoreCase(name, "q")) return .{ .kind = .quote };
    if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
        return .{ .kind = .heading, .heading_level = name[1] - '0' };
    }
    if (std.ascii.eqlIgnoreCase(name, "hr")) return .{ .kind = .horizontal_rule };
    if (std.ascii.eqlIgnoreCase(name, "p")) return .{ .kind = .paragraph };
    if (std.ascii.eqlIgnoreCase(name, "blockquote")) return .{ .kind = .blockquote };
    if (std.ascii.eqlIgnoreCase(name, "pre")) return .{ .kind = .preformatted };
    if (std.ascii.eqlIgnoreCase(name, "ol") or std.ascii.eqlIgnoreCase(name, "ul") or std.ascii.eqlIgnoreCase(name, "dl")) return .{ .kind = .list };
    if (std.ascii.eqlIgnoreCase(name, "li") or std.ascii.eqlIgnoreCase(name, "dt") or std.ascii.eqlIgnoreCase(name, "dd")) return .{ .kind = .list_item };
    if (std.ascii.eqlIgnoreCase(name, "table")) return .{ .kind = .table };
    if (std.ascii.eqlIgnoreCase(name, "thead") or std.ascii.eqlIgnoreCase(name, "tbody") or std.ascii.eqlIgnoreCase(name, "tfoot")) return .{ .kind = .table_section };
    if (std.ascii.eqlIgnoreCase(name, "tr")) return .{ .kind = .table_row };
    if (std.ascii.eqlIgnoreCase(name, "td") or std.ascii.eqlIgnoreCase(name, "th")) return .{ .kind = .table_cell };
    if (std.ascii.eqlIgnoreCase(name, "abbr") or std.ascii.eqlIgnoreCase(name, "bdo") or
        std.ascii.eqlIgnoreCase(name, "caption") or std.ascii.eqlIgnoreCase(name, "center") or
        std.ascii.eqlIgnoreCase(name, "div") or std.ascii.eqlIgnoreCase(name, "span") or
        std.ascii.eqlIgnoreCase(name, "section") or std.ascii.eqlIgnoreCase(name, "article") or
        std.ascii.eqlIgnoreCase(name, "header") or std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "main") or std.ascii.eqlIgnoreCase(name, "figure") or
        std.ascii.eqlIgnoreCase(name, "figcaption") or std.ascii.eqlIgnoreCase(name, "time") or
        std.ascii.eqlIgnoreCase(name, "ruby") or std.ascii.eqlIgnoreCase(name, "rt") or
        std.ascii.eqlIgnoreCase(name, "rp")) return .{ .kind = .container };
    return null;
}

fn parseHtmlCommentAt(source: []const u8, index: usize, cache: ?*ScanCache) ?HtmlComment {
    if (index > source.len or !std.mem.startsWith(u8, source[index..], "<!--")) return null;
    const close = if (cache) |scan|
        ScanCache.nextPattern(&scan.html_comment_close, source, index + 4, "-->")
    else
        std.mem.indexOfPos(u8, source, index + 4, "-->");
    const close_index = close orelse return null;
    return .{ .consumed = close_index + 3 - index };
}

fn singleLineHtmlElement(line: []const u8, opening: HtmlTag) ?SingleLineHtmlElement {
    if (opening.closing or opening.self_closing) return null;
    const close_start = std.mem.lastIndexOfScalar(u8, line, '<') orelse return null;
    if (close_start < opening.consumed) return null;
    const closing = parseHtmlTagAt(line, close_start) orelse return null;
    if (!closing.closing or closing.consumed != line.len - close_start or
        !std.ascii.eqlIgnoreCase(opening.name, closing.name)) return null;
    return .{ .content = line[opening.consumed..close_start] };
}

fn unwrapHtmlCode(content: []const u8) []const u8 {
    const opening = parseHtmlTagAt(content, 0) orelse return content;
    if (opening.kind != .monospace or opening.closing) return content;
    const element = singleLineHtmlElement(content, opening) orelse return content;
    return element.content;
}

fn skipHtmlElement(lines: *LineIterator, name: []const u8) void {
    var depth: usize = 1;
    while (lines.next()) |line| {
        const scan = scanHtmlElementLine(line, name, &depth);
        if (scan.closing_end) |closing_end| {
            const suffix = line[closing_end..];
            if (suffix.len > 0) lines.prepend(suffix);
            return;
        }
    }
}

fn isHtmlBlockTag(tag: HtmlTag) bool {
    return switch (tag.kind) {
        .heading, .horizontal_rule, .paragraph, .blockquote, .preformatted, .list, .list_item, .table, .table_section, .table_row, .table_cell => true,
        .container => isHtmlStructuralTag(tag),
        else => false,
    };
}

fn isHtmlStructuralTag(tag: HtmlTag) bool {
    if (tag.kind != .container) return isHtmlBlockTagWithoutContainer(tag.kind);
    return std.ascii.eqlIgnoreCase(tag.name, "center") or std.ascii.eqlIgnoreCase(tag.name, "div") or
        std.ascii.eqlIgnoreCase(tag.name, "section") or std.ascii.eqlIgnoreCase(tag.name, "article") or
        std.ascii.eqlIgnoreCase(tag.name, "header") or std.ascii.eqlIgnoreCase(tag.name, "footer") or
        std.ascii.eqlIgnoreCase(tag.name, "main") or std.ascii.eqlIgnoreCase(tag.name, "figure") or
        std.ascii.eqlIgnoreCase(tag.name, "figcaption") or std.ascii.eqlIgnoreCase(tag.name, "caption");
}

fn isHtmlBlockTagWithoutContainer(kind: HtmlTagKind) bool {
    return switch (kind) {
        .heading, .horizontal_rule, .paragraph, .blockquote, .preformatted, .list, .list_item, .table, .table_section, .table_row, .table_cell => true,
        else => false,
    };
}

fn isHtmlAlignmentContainer(tag: HtmlTag) bool {
    if (tag.kind == .paragraph) return true;
    if (tag.kind != .container) return false;
    return std.ascii.eqlIgnoreCase(tag.name, "center") or std.ascii.eqlIgnoreCase(tag.name, "div") or
        std.ascii.eqlIgnoreCase(tag.name, "section") or std.ascii.eqlIgnoreCase(tag.name, "article") or
        std.ascii.eqlIgnoreCase(tag.name, "header") or std.ascii.eqlIgnoreCase(tag.name, "footer") or
        std.ascii.eqlIgnoreCase(tag.name, "main") or std.ascii.eqlIgnoreCase(tag.name, "figure") or
        std.ascii.eqlIgnoreCase(tag.name, "figcaption");
}

fn isPersistentHtmlBlockTag(tag: HtmlTag) bool {
    return isHtmlAlignmentContainer(tag) or tag.kind == .heading;
}

fn htmlTagAlignment(tag: HtmlTag) ?canvas.TextAlign {
    if (std.ascii.eqlIgnoreCase(tag.name, "center")) return .center;
    const value = htmlAttribute(tag, "align") orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(value, "right") or std.ascii.eqlIgnoreCase(value, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(value, "left") or std.ascii.eqlIgnoreCase(value, "start")) return .start;
    return null;
}

/// Return one attribute value without exposing any other attribute to the
/// widget engine. Quoted and unquoted values are accepted case-insensitively,
/// matching the forms commonly found in README HTML.
fn htmlAttribute(tag: HtmlTag, wanted: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < tag.attributes.len) {
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len or tag.attributes[cursor] == '/') break;
        const name_start = cursor;
        while (cursor < tag.attributes.len and (std.ascii.isAlphanumeric(tag.attributes[cursor]) or
            tag.attributes[cursor] == '-' or tag.attributes[cursor] == '_' or tag.attributes[cursor] == ':')) cursor += 1;
        if (cursor == name_start) {
            cursor += 1;
            continue;
        }
        const name = tag.attributes[name_start..cursor];
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len or tag.attributes[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len) return null;

        var value: []const u8 = undefined;
        if (tag.attributes[cursor] == '"' or tag.attributes[cursor] == '\'') {
            const quote = tag.attributes[cursor];
            cursor += 1;
            const value_start = cursor;
            while (cursor < tag.attributes.len and tag.attributes[cursor] != quote) cursor += 1;
            if (cursor >= tag.attributes.len) return null;
            value = tag.attributes[value_start..cursor];
            cursor += 1;
        } else {
            const value_start = cursor;
            while (cursor < tag.attributes.len and !std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
            value = tag.attributes[value_start..cursor];
        }
        if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn updateHtmlDepth(depth: *usize, closing: bool, active: bool) void {
    if (closing) {
        if (depth.* > 0) depth.* -= 1;
    } else if (active and depth.* < std.math.maxInt(usize)) {
        depth.* += 1;
    }
}

// ------------------------------------------------------------ line model

const LineIterator = struct {
    source: []const u8,
    index: usize = 0,
    pending: ?[]const u8 = null,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pending) |line| {
            self.pending = null;
            return line;
        }
        if (self.index >= self.source.len) return null;
        const start = self.index;
        const end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
        self.index = @min(end + 1, self.source.len);
        return std.mem.trimEnd(u8, self.source[start..end], "\r");
    }

    fn prepend(self: *LineIterator, line: []const u8) void {
        std.debug.assert(self.pending == null);
        self.pending = line;
    }

    fn peek(self: *LineIterator) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }

    fn peekSecond(self: *LineIterator) ?[]const u8 {
        var copy = self.*;
        _ = copy.next() orelse return null;
        return copy.next();
    }
};

// ----------------------------------------------------------- table model

const TableRow = struct {
    cells: [max_markdown_table_columns][]const u8 = undefined,
    len: usize = 0,
};

const TextAlignValue = canvas.TextAlign;

const TableAlignments = struct {
    columns: [max_markdown_table_columns]TextAlignValue = undefined,
    len: usize = 0,
};

/// Split a pipe row into trimmed cell slices. Null when the line has no
/// pipe, yields no cells, or has more than `max_markdown_table_columns`
/// cells (the caller then degrades the block to plain text). `\|` does
/// not split (GFM's in-cell pipe escape); the cell text is unescaped at
/// emit time.
fn splitTableRow(line: []const u8) ?TableRow {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return null;
    var rest = trimmed;
    if (rest[0] == '|') rest = rest[1..];
    if (rest.len > 0 and rest[rest.len - 1] == '|' and !(rest.len > 1 and rest[rest.len - 2] == '\\')) {
        rest = rest[0 .. rest.len - 1];
    }
    var row = TableRow{};
    var start: usize = 0;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        if (rest[index] == '\\') {
            index += 1; // Skip the escaped byte (covers `\|`).
            continue;
        }
        if (rest[index] != '|') continue;
        if (row.len >= max_markdown_table_columns) return null;
        row.cells[row.len] = std.mem.trim(u8, rest[start..index], " \t");
        row.len += 1;
        start = index + 1;
    }
    if (row.len >= max_markdown_table_columns) return null;
    row.cells[row.len] = std.mem.trim(u8, rest[@min(start, rest.len)..], " \t");
    row.len += 1;
    return row;
}

/// Parse a GFM delimiter row (`| --- | :--: | ---: |`): every cell must
/// be dashes with optional leading/trailing colons mapping to
/// start/center/end column alignment.
fn tableDelimiterAlignments(line: []const u8) ?TableAlignments {
    const row = splitTableRow(line) orelse return null;
    var result = TableAlignments{ .len = row.len };
    for (row.cells[0..row.len], 0..) |cell, column| {
        if (cell.len == 0) return null;
        var body = cell;
        const leading = body[0] == ':';
        if (leading) body = body[1..];
        var trailing = false;
        if (body.len > 0 and body[body.len - 1] == ':') {
            trailing = true;
            body = body[0 .. body.len - 1];
        }
        if (body.len == 0) return null;
        for (body) |byte| {
            if (byte != '-') return null;
        }
        result.columns[column] = if (leading and trailing)
            .center
        else if (trailing)
            .end
        else
            .start;
    }
    return result;
}

/// A table starts at a pipe header row whose next line is a delimiter row
/// with the same column count (GFM). Anything else falls through to the
/// paragraph path.
fn isTableStart(lines: *LineIterator) bool {
    const first = lines.peek() orelse return false;
    const header = splitTableRow(first) orelse return false;
    const second = lines.peekSecond() orelse return false;
    const alignments = tableDelimiterAlignments(second) orelse return false;
    return alignments.len == header.len;
}

fn headingLevel(line: []const u8) ?usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < line.len and line[level] != ' ') return null;
    return level;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: usize = 0;
    for (line) |byte| {
        if (byte == marker) {
            count += 1;
        } else if (byte != ' ') {
            return false;
        }
    }
    return count >= 3;
}

const ListMarkerKind = enum { bullet, ordered, task };

const ListMarker = struct {
    kind: ListMarkerKind,
    /// Nesting level derived from leading spaces (two per level).
    indent: usize,
    /// Ordinal label for ordered items ("3."), empty otherwise.
    label: []const u8,
    checked: bool = false,
    content: []const u8,
};

fn listMarker(line: []const u8) ?ListMarker {
    var spaces: usize = 0;
    while (spaces < line.len and line[spaces] == ' ') spaces += 1;
    const indent = @min(spaces / 2, max_markdown_list_depth - 1);
    const rest = line[spaces..];
    if (rest.len < 2) return null;

    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        const content = std.mem.trim(u8, rest[2..], " \t");
        if (std.mem.startsWith(u8, content, "[ ] ")) {
            return .{ .kind = .task, .indent = indent, .label = "", .checked = false, .content = content[4..] };
        }
        if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
            return .{ .kind = .task, .indent = indent, .label = "", .checked = true, .content = content[4..] };
        }
        return .{ .kind = .bullet, .indent = indent, .label = "", .content = content };
    }

    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits > 0 and digits + 1 < rest.len and rest[digits] == '.' and rest[digits + 1] == ' ') {
        return .{
            .kind = .ordered,
            .indent = indent,
            .label = rest[0 .. digits + 1],
            .content = std.mem.trim(u8, rest[digits + 2 ..], " \t"),
        };
    }
    return null;
}

fn startsNewBlock(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "```")) return true;
    if (headingLevel(trimmed) != null) return true;
    if (isHorizontalRule(trimmed)) return true;
    if (std.mem.startsWith(u8, trimmed, ">")) return true;
    if (listMarker(line) != null) return true;
    if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) return true;
    if (parseHtmlTagAt(trimmed, 0)) |tag| {
        if (isHtmlBlockTag(tag)) return true;
    }
    if (parseHtmlCommentAt(trimmed, 0, null)) |comment| {
        if (comment.consumed == trimmed.len) return true;
    }
    return false;
}

const InlineLink = struct {
    text: []const u8,
    target: []const u8,
    consumed: usize,
};

/// Memoized forward scans for one `parseInline` pass. The inline walk
/// only moves forward, so the next occurrence of a closer (or of the
/// autolink scheme separator) found from one position stays the answer
/// for every position up to it — without this, a wall of `[`, `<`, or
/// `![` rescans to the terminator at every byte, and a kilobyte of
/// hostile input costs a megabyte of scanning (quadratic; a real
/// pasted-garbage hang).
const ScanCache = struct {
    close_bracket: Slot = .{}, // ']'
    close_paren: Slot = .{}, // ')'
    angle_close: Slot = .{}, // '>'
    /// ' ' queried by autolink target checks (from just past `<`).
    space: Slot = .{}, // ' '
    /// ' ' queried by link title-strips (from just past `](`). A
    /// separate slot: the two query streams sit at different offsets,
    /// and sharing one memo lets them evict each other back into
    /// quadratic rescans on interleaved `[`/`<` walls.
    title_space: Slot = .{}, // ' '
    scheme_sep: Slot = .{}, // "://"
    html_comment_close: Slot = .{}, // "-->"

    const Slot = struct {
        valid: bool = false,
        scanned_from: usize = 0,
        /// Next occurrence at/after `scanned_from`; null when the scan
        /// proved none remains.
        pos: ?usize = null,
    };

    fn nextScalar(slot: *Slot, text: []const u8, from: usize, byte: u8) ?usize {
        if (cached(slot, from)) |hit| return hit.pos;
        const found = std.mem.indexOfScalarPos(u8, text, from, byte);
        slot.* = .{ .valid = true, .scanned_from = from, .pos = found };
        return found;
    }

    fn nextPattern(slot: *Slot, text: []const u8, from: usize, pattern: []const u8) ?usize {
        if (cached(slot, from)) |hit| return hit.pos;
        const found = std.mem.indexOfPos(u8, text, from, pattern);
        slot.* = .{ .valid = true, .scanned_from = from, .pos = found };
        return found;
    }

    const Hit = struct { pos: ?usize };

    fn cached(slot: *Slot, from: usize) ?Hit {
        if (!slot.valid or from < slot.scanned_from) return null;
        if (slot.pos) |pos| {
            if (from > pos) return null;
            return .{ .pos = pos };
        }
        return .{ .pos = null };
    }
};

/// Parse `[text](target)` at `source[index]`; null when malformed (the
/// caller then treats `[` as literal text). `consumed` is relative to
/// `index`.
fn parseLinkAt(source: []const u8, index: usize, cache: *ScanCache) ?InlineLink {
    const rest = source[index..];
    if (rest.len < 4 or rest[0] != '[') return null;
    const close_bracket_abs = ScanCache.nextScalar(&cache.close_bracket, source, index, ']') orelse return null;
    const close_bracket = close_bracket_abs - index;
    if (close_bracket + 1 >= rest.len or rest[close_bracket + 1] != '(') return null;
    const close_paren_abs = ScanCache.nextScalar(&cache.close_paren, source, close_bracket_abs + 2, ')') orelse return null;
    const close_paren = close_paren_abs - index;
    const text = rest[1..close_bracket];
    var target = rest[close_bracket + 2 .. close_paren];
    // Strip an optional title: [text](url "title"). Memoized like the
    // closers: an unbounded target rescanned per failed attempt is the
    // same quadratic wall.
    if (ScanCache.nextScalar(&cache.title_space, source, close_bracket_abs + 2, ' ')) |space_abs| {
        if (space_abs < close_paren_abs) target = target[0 .. space_abs - (close_bracket_abs + 2)];
    }
    if (text.len == 0 or target.len == 0) return null;
    return .{ .text = text, .target = target, .consumed = close_paren + 1 };
}

/// Parse `<scheme://...>` autolinks at `source[index]`. `consumed` is
/// relative to `index`.
fn parseAutolinkAt(source: []const u8, index: usize, cache: *ScanCache) ?InlineLink {
    const rest = source[index..];
    if (rest.len < 3 or rest[0] != '<') return null;
    const close_abs = ScanCache.nextScalar(&cache.angle_close, source, index, '>') orelse return null;
    const close = close_abs - index;
    const target = rest[1..close];
    const sep_abs = ScanCache.nextPattern(&cache.scheme_sep, source, index + 1, "://") orelse return null;
    if (sep_abs + "://".len > close_abs) return null;
    if (ScanCache.nextScalar(&cache.space, source, index + 1, ' ')) |space_abs| {
        if (space_abs < close_abs) return null;
    }
    return .{ .text = target, .target = target, .consumed = close + 1 };
}

/// Word-boundary test for bare-URL and `#N` autolinking (the classic
/// `(^|[^\w/&])` register): don't link when continuing a word, a
/// path (`/`), or an HTML entity (`&`).
fn atAutolinkBoundary(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = text[index - 1];
    return !isWordByte(previous) and previous != '/' and previous != '&';
}

/// Parse a bare `http://`/`https://` URL at the start of `rest`
/// (GFM-style autolink extension): the URL runs to whitespace or `<`,
/// then trailing punctuation and unbalanced close parens are trimmed so
/// prose like "see https://example.com." links cleanly.
fn parseBareUrlAt(rest: []const u8) ?InlineLink {
    const scheme_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, rest, "http://"))
        "http://".len
    else
        return null;
    var end = scheme_len;
    var balance: isize = 0;
    while (end < rest.len) : (end += 1) {
        const byte = rest[end];
        if (isInlineSpace(byte) or byte == '\n' or byte == '<' or byte == '>') break;
        if (byte == '(') balance += 1;
        if (byte == ')') balance -= 1;
    }
    // Trim trailing punctuation, keeping the paren balance current
    // incrementally — recomputing it per trimmed ')' is quadratic in the
    // tail length (a hostile URL ending in a wall of parens used to
    // hang).
    while (end > scheme_len) {
        const byte = rest[end - 1];
        if (byte == ')') {
            if (balance < 0) {
                end -= 1;
                balance += 1;
                continue;
            }
            break;
        }
        switch (byte) {
            '.', ',', ';', ':', '!', '?', '\'', '"' => end -= 1,
            else => break,
        }
    }
    if (end == scheme_len) return null;
    const target = rest[0..end];
    return .{ .text = target, .target = target, .consumed = end };
}

const IssueRef = struct {
    /// The digits after `#`.
    digits: []const u8,
    consumed: usize,
};

/// Parse `#123` at the start of `rest`: one or more digits ending at a
/// word boundary (the classic `#(\d+)\b` register). The caller checks
/// the leading boundary and supplies the link base.
fn parseIssueRefAt(rest: []const u8) ?IssueRef {
    if (rest.len < 2 or rest[0] != '#') return null;
    var end: usize = 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 1) return null;
    if (end < rest.len and isWordByte(rest[end])) return null;
    return .{ .digits = rest[1..end], .consumed = end };
}

fn hasCloser(rest: []const u8, delim: []const u8) bool {
    return std.mem.indexOf(u8, rest, delim) != null;
}

fn isInlineSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
