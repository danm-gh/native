const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_frame_helpers = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const unionRects = canvas_frame_helpers.unionRects;
const canvasWidgetEscapeKey = canvas_frame_helpers.canvasWidgetEscapeKey;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const WidgetTextStorageRange = canvas_widget_runtime.WidgetTextStorageRange;
const canvasWidgetEditableTextKind = canvas_widget_runtime.canvasWidgetEditableTextKind;
const canvasWidgetLayoutNodeHidden = canvas_widget_runtime.canvasWidgetLayoutNodeHidden;
const canvasWidgetLayoutNodeFrameVisible = canvas_widget_runtime.canvasWidgetLayoutNodeFrameVisible;
const canvasWidgetSingleLineTextKind = canvas_widget_runtime.canvasWidgetSingleLineTextKind;
const appendWidgetTextStorageRange = canvas_widget_runtime.appendWidgetTextStorageRange;
const canvasWidgetTextEditUnchanged = canvas_widget_runtime.canvasWidgetTextEditUnchanged;
const canvasTextSelectionsEqual = canvas_widget_runtime.canvasTextSelectionsEqual;
const textSelectionCollapsedAt = canvas_widget_runtime.textSelectionCollapsedAt;

pub const CanvasWidgetTextHistoryEntry = struct {
    target_id: canvas.ObjectId = 0,
    byte_start: usize = 0,
    removed_len: usize = 0,
    inserted_len: usize = 0,
    prefix_len: usize = 0,
    before_text_len: usize = 0,
    after_text_len: usize = 0,
    before_hash: u64 = 0,
    after_hash: u64 = 0,
    before_selection: canvas.TextSelection = .{},
    after_selection: canvas.TextSelection = .{},
    applied: bool = true,
};

const max_text_history_edits_per_shortcut = 3;

pub fn RuntimeViewCanvasWidgetText(comptime RuntimeView: type) type {
    return struct {
        pub fn applyCanvasWidgetTextEdit(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!?geometry.RectF {
            return applyCanvasWidgetTextEditWithHistory(self, target_id, edit, true);
        }

        pub fn applyCanvasWidgetTextEditWithoutHistory(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent) anyerror!?geometry.RectF {
            return applyCanvasWidgetTextEditWithHistory(self, target_id, edit, false);
        }

        fn applyCanvasWidgetTextEditWithHistory(self: *RuntimeView, target_id: canvas.ObjectId, edit: canvas.TextInputEvent, record_history: bool) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            const previous_bounds = widget.frame;
            var edit_buffer: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
            const current_state = canvas.TextEditState{
                .text = widget.text,
                .selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len),
                .composition = widget.text_composition,
            };
            const next_state = try current_state.apply(edit, &edit_buffer);
            if (canvasWidgetTextEditUnchanged(current_state, next_state)) return null;

            const history_recorded = record_history and
                !std.mem.eql(u8, current_state.text, next_state.text) and
                recordCanvasWidgetTextHistory(self, target_id, current_state, next_state);
            self.rewriteCanvasWidgetTextStorage(index, next_state) catch |err| {
                if (history_recorded) removeCanvasWidgetTextHistoryEntry(self, self.canvas_widget_text_history_entry_count - 1);
                return err;
            };
            self.scrollCanvasTextInputCaretIntoView(index);
            const semantics = try self.widgetLayoutTree().collectSemantics(&self.widget_semantics_nodes);
            self.widget_semantics_node_count = semantics.len;
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, unionRects(previous_bounds, self.widget_layout_nodes[index].frame) orelse self.widget_layout_nodes[index].frame);
        }

        pub fn canvasWidgetKeyboardTextEdit(self: *const RuntimeView, target: canvas.WidgetFocusTarget, keyboard: canvas.WidgetKeyboardEvent) ?canvas.TextInputEvent {
            const index = self.canvasWidgetNodeIndexById(target.id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;

            if (keyboard.phase == .key_down and !keyboard.modifiers.shift and !keyboard.modifiers.hasNavigationModifier() and canvasWidgetEscapeKey(keyboard.key)) {
                if (widget.text_composition != null) return .cancel_composition;
                if (widget.kind == .search_field or widget.kind == .combobox) return .clear;
                return null;
            }

            // Multi-line editing contract: Enter (plain or shift) inserts
            // a newline; submit rides the primary-modifier chord instead.
            // Shared with the app dispatch path so the model's `on_input`
            // hears exactly the edit the retained text applied.
            if (canvas.widgetKeyboardNewlineTextEditEvent(widget.kind, keyboard)) |newline_edit| {
                return newline_edit;
            }

            // macOS textarea navigation differs deliberately from the
            // single-line field keymap: Command+Left/Right is line-scoped,
            // while Command+Up/Down reaches the document boundary. Return
            // an explicit selection for the line moves so the exact target
            // is stamped onto on-input and controlled TextBuffers mirror it.
            if (widget.kind == .textarea and
                keyboard.phase == .key_down and
                keyboard.text.len == 0 and
                keyboard.modifiers.super and
                !keyboard.modifiers.alt)
            {
                const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) {
                    const target_offset = canvas.textLineStartOffset(widget.text, selection.focus);
                    return .{ .set_selection = if (keyboard.modifiers.shift)
                        .{ .anchor = selection.anchor, .focus = target_offset }
                    else
                        canvas.TextSelection.collapsed(target_offset) };
                }
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) {
                    const target_offset = canvas.textLineEndOffset(widget.text, selection.focus);
                    return .{ .set_selection = if (keyboard.modifiers.shift)
                        .{ .anchor = selection.anchor, .focus = target_offset }
                    else
                        canvas.TextSelection.collapsed(target_offset) };
                }
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
                    return .{ .move_caret = .{ .direction = .start, .extend = keyboard.modifiers.shift } };
                }
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
                    return .{ .move_caret = .{ .direction = .end, .extend = keyboard.modifiers.shift } };
                }
            }

            // Plain Up/Down follows the textarea's PAINTED visual lines,
            // including soft wraps. Resolve the current caret rectangle
            // through the same streaming layout used to draw it, then
            // hit-test the neighboring line at the caret's x coordinate.
            // The explicit selection is stamped onto on-input, keeping a
            // controlled TextBuffer's selection byte-identical to the
            // retained editor.
            if (widget.kind == .textarea and
                keyboard.phase == .key_down and
                keyboard.text.len == 0 and
                !keyboard.modifiers.hasNavigationModifier())
            {
                const moving_up = std.ascii.eqlIgnoreCase(keyboard.key, "arrowup");
                const moving_down = std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown");
                if (moving_up or moving_down) {
                    const selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
                    var caret_widget = widget;
                    caret_widget.text_selection = canvas.TextSelection.collapsed(selection.focus);
                    const caret = canvas.textGeometryForWidget(caret_widget, self.widget_tokens).caret_bounds orelse return null;
                    const target_y = if (moving_up)
                        caret.y - caret.height * 0.5
                    else
                        caret.y + caret.height * 1.5;
                    const target_offset = canvas.textOffsetForWidgetPoint(
                        widget,
                        geometry.PointF.init(caret.x, target_y),
                        self.widget_tokens,
                    ) orelse return null;
                    return .{ .set_selection = if (keyboard.modifiers.shift)
                        .{ .anchor = selection.anchor, .focus = target_offset }
                    else
                        canvas.TextSelection.collapsed(target_offset) };
                }
            }

            // On a CLOSED combobox these same arrows are the trigger's
            // OPEN keys (`widgetKeyboardControlIntent`'s menu-open
            // mapping, which the app dispatch resolves BEFORE any
            // stamped edit): platform convention is that opening wins
            // and the caret does not move, so the derivation yields no
            // edit and the retained editor agrees with the model's "no
            // edit" verdict. The app-side fallback derivation for
            // events that never crossed the runtime
            // (`textEditEvent()`'s generic keymap) has no ArrowUp/Down
            // arm at all, so both derivations stay in agreement. Once
            // the picker is OPEN the focus step walks the arrows into
            // the mounted menu before routing reaches the trigger; an
            // arrow that still lands on an EXPANDED trigger (no
            // focusable menu entry mounted) keeps the caret jump — the
            // control resolver ignores it there, so both sides hear
            // the same move.
            const arrow_opens_combobox = widget.kind == .combobox and !(widget.state.expanded orelse false);
            if (!arrow_opens_combobox and canvasWidgetSingleLineTextKind(widget.kind) and keyboard.phase == .key_down and keyboard.text.len == 0 and !keyboard.modifiers.hasNavigationModifier()) {
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .{ .move_caret = .{ .direction = .start, .extend = keyboard.modifiers.shift } };
                if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .{ .move_caret = .{ .direction = .end, .extend = keyboard.modifiers.shift } };
            }

            return keyboard.textEditEvent();
        }

        /// Resolve Command/Ctrl+Z against the focused editor's delta
        /// history. `output` is one logical step expressed as ordinary
        /// TextInputEvents so both the retained editor and a controlled
        /// app-side TextBuffer reach byte-identical text and selection.
        pub fn canvasWidgetTextHistoryShortcut(
            self: *RuntimeView,
            target: canvas.WidgetFocusTarget,
            keyboard: canvas.WidgetKeyboardEvent,
            output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
        ) bool {
            output.* = .{ null, null, null };
            if (keyboard.phase != .key_down or
                !keyboard.modifiers.super or
                keyboard.modifiers.alt or
                !std.ascii.eqlIgnoreCase(keyboard.key, "z"))
            {
                return false;
            }
            const node_index = self.canvasWidgetNodeIndexById(target.id) orelse return false;
            const widget = self.widget_layout_nodes[node_index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled or widget.text_composition != null) return false;

            const redo = keyboard.modifiers.shift;
            const history_index = canvasWidgetTextHistoryIndex(self, target.id, redo) orelse return false;
            const entry = self.canvas_widget_text_history_entries[history_index];
            const expected_len = if (redo) entry.before_text_len else entry.after_text_len;
            const expected_hash = if (redo) entry.before_hash else entry.after_hash;
            if (widget.text.len != expected_len or textHistoryHash(widget.text) != expected_hash) {
                clearCanvasWidgetTextHistory(self, target.id);
                return false;
            }

            const removed = canvasWidgetTextHistoryRemoved(self, entry);
            const inserted = canvasWidgetTextHistoryInserted(self, entry);
            var edit_count: usize = 0;
            if (redo) {
                buildCanvasWidgetTextRedoEdits(entry, removed, inserted, widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len), output, &edit_count);
                self.canvas_widget_text_history_entries[history_index].applied = true;
            } else {
                buildCanvasWidgetTextUndoEdits(entry, removed, inserted, widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len), output, &edit_count);
                self.canvas_widget_text_history_entries[history_index].applied = false;
            }
            return edit_count > 0;
        }

        fn recordCanvasWidgetTextHistory(
            self: *RuntimeView,
            target_id: canvas.ObjectId,
            before: canvas.TextEditState,
            after: canvas.TextEditState,
        ) bool {
            // Composition previews are provisional and can rewrite the same
            // marked range many times. They do not become individual undo
            // steps; invalidate older state whose text hash no longer
            // describes this editor.
            if (before.composition != null or after.composition != null) {
                clearCanvasWidgetTextHistory(self, target_id);
                return false;
            }

            const delta = canvasWidgetTextHistoryDelta(before.text, after.text);
            const removed_len = delta.before_end - delta.prefix_len;
            const inserted_len = delta.after_end - delta.prefix_len;
            const byte_len = removed_len + inserted_len;
            if (byte_len == 0) return false;

            // A new edit forks this widget's history: only its redo branch
            // disappears; other editors in the same view keep theirs.
            var cursor = self.canvas_widget_text_history_entry_count;
            while (cursor > 0) {
                cursor -= 1;
                const entry = self.canvas_widget_text_history_entries[cursor];
                if (entry.target_id == target_id and !entry.applied) {
                    removeCanvasWidgetTextHistoryEntry(self, cursor);
                }
            }

            if (byte_len > self.canvas_widget_text_history_bytes.len) {
                clearCanvasWidgetTextHistory(self, target_id);
                return false;
            }
            while (self.canvas_widget_text_history_entry_count >= self.canvas_widget_text_history_entries.len or
                self.canvas_widget_text_history_byte_count + byte_len > self.canvas_widget_text_history_bytes.len)
            {
                if (self.canvas_widget_text_history_entry_count == 0) return false;
                removeCanvasWidgetTextHistoryEntry(self, 0);
            }

            const byte_start = self.canvas_widget_text_history_byte_count;
            const removed_end = byte_start + removed_len;
            const inserted_end = removed_end + inserted_len;
            @memcpy(
                self.canvas_widget_text_history_bytes[byte_start..removed_end],
                before.text[delta.prefix_len..delta.before_end],
            );
            @memcpy(
                self.canvas_widget_text_history_bytes[removed_end..inserted_end],
                after.text[delta.prefix_len..delta.after_end],
            );
            self.canvas_widget_text_history_byte_count = inserted_end;
            self.canvas_widget_text_history_entries[self.canvas_widget_text_history_entry_count] = .{
                .target_id = target_id,
                .byte_start = byte_start,
                .removed_len = removed_len,
                .inserted_len = inserted_len,
                .prefix_len = delta.prefix_len,
                .before_text_len = before.text.len,
                .after_text_len = after.text.len,
                .before_hash = textHistoryHash(before.text),
                .after_hash = textHistoryHash(after.text),
                .before_selection = before.selection,
                .after_selection = after.selection,
            };
            self.canvas_widget_text_history_entry_count += 1;
            return true;
        }

        fn canvasWidgetTextHistoryIndex(self: *const RuntimeView, target_id: canvas.ObjectId, redo: bool) ?usize {
            if (redo) {
                for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                    if (entry.target_id == target_id and !entry.applied) return index;
                }
                return null;
            }
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                const entry = self.canvas_widget_text_history_entries[index];
                if (entry.target_id == target_id and entry.applied) return index;
            }
            return null;
        }

        fn canvasWidgetTextHistoryRemoved(self: *const RuntimeView, entry: CanvasWidgetTextHistoryEntry) []const u8 {
            return self.canvas_widget_text_history_bytes[entry.byte_start .. entry.byte_start + entry.removed_len];
        }

        fn canvasWidgetTextHistoryInserted(self: *const RuntimeView, entry: CanvasWidgetTextHistoryEntry) []const u8 {
            const start = entry.byte_start + entry.removed_len;
            return self.canvas_widget_text_history_bytes[start .. start + entry.inserted_len];
        }

        fn clearCanvasWidgetTextHistory(self: *RuntimeView, target_id: canvas.ObjectId) void {
            var index = self.canvas_widget_text_history_entry_count;
            while (index > 0) {
                index -= 1;
                if (self.canvas_widget_text_history_entries[index].target_id == target_id) {
                    removeCanvasWidgetTextHistoryEntry(self, index);
                }
            }
        }

        fn removeCanvasWidgetTextHistoryEntry(self: *RuntimeView, remove_index: usize) void {
            if (remove_index >= self.canvas_widget_text_history_entry_count) return;
            var write_byte: usize = 0;
            var write_entry: usize = 0;
            for (self.canvas_widget_text_history_entries[0..self.canvas_widget_text_history_entry_count], 0..) |entry, index| {
                if (index == remove_index) continue;
                const entry_byte_len = entry.removed_len + entry.inserted_len;
                const source = self.canvas_widget_text_history_bytes[entry.byte_start .. entry.byte_start + entry_byte_len];
                if (write_byte != entry.byte_start) {
                    std.mem.copyForwards(
                        u8,
                        self.canvas_widget_text_history_bytes[write_byte .. write_byte + entry_byte_len],
                        source,
                    );
                }
                var moved = entry;
                moved.byte_start = write_byte;
                self.canvas_widget_text_history_entries[write_entry] = moved;
                write_byte += entry_byte_len;
                write_entry += 1;
            }
            self.canvas_widget_text_history_entry_count = write_entry;
            self.canvas_widget_text_history_byte_count = write_byte;
        }

        pub fn canEditCanvasWidgetText(self: *const RuntimeView, id: canvas.ObjectId) bool {
            const index = self.canvasWidgetNodeIndexById(id) orelse return false;
            const layout = self.widgetLayoutTree();
            if (canvasWidgetLayoutNodeHidden(layout, index)) return false;
            if (!canvasWidgetLayoutNodeFrameVisible(layout, index)) return false;
            const widget = self.widget_layout_nodes[index].widget;
            return canvasWidgetEditableTextKind(widget.kind) and !widget.state.disabled;
        }

        pub fn applyCanvasWidgetTextPointer(self: *RuntimeView, target_id: canvas.ObjectId, point: geometry.PointF, extend: bool, click_count: u8) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(target_id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            if (canvas.widgetStaticTextSelectable(widget)) return applyCanvasWidgetStaticTextPointer(self, index, target_id, point, extend);
            if (!canvasWidgetEditableTextKind(widget.kind)) return null;

            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(widget.text.len);
            const next_selection = canvasWidgetEditableTextPointerSelection(self, widget, point, extend, click_count, current_selection) orelse return null;
            // A widget with NO stored selection must store one even when
            // it matches the implied default: the emitters draw a caret
            // only for a present selection, so short-circuiting here left
            // a click into an empty field (or past the end of the text)
            // caretless.
            if (widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection) and widget.text_composition == null) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.widget_layout_nodes[index].widget.text_composition = null;
            // A pointer-placed caret is a caret change like any other: a
            // drag past a scrolled single-line field's edge lands on an
            // off-screen offset, and the field follows it.
            if (canvasWidgetSingleLineTextKind(widget.kind)) self.scrollCanvasTextInputCaretIntoView(index);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        /// The selection a pointer event produces in an editable text
        /// widget, by click count. Count 1 is the classic gesture:
        /// press places the caret, drag extends per-character from the
        /// press anchor. Counts 2 and 3 are the multi-click family —
        /// the down selects a whole RUN (the word/whitespace/
        /// punctuation cluster under the pointer, or the line/whole
        /// text for a triple), remembers it as the gesture's anchor
        /// run, and the drag unions the run under the pointer with
        /// that anchor, so extension works in both directions and the
        /// anchor word is never lost. Everything lands in the same
        /// `text_selection` state the keyboard, clipboard, and
        /// renderer already consume — no parallel selection model.
        fn canvasWidgetEditableTextPointerSelection(
            self: *RuntimeView,
            widget: canvas.Widget,
            point: geometry.PointF,
            extend: bool,
            click_count: u8,
            current_selection: canvas.TextSelection,
        ) ?canvas.TextSelection {
            if (click_count >= 2) {
                const offset = canvas.textOffsetForWidgetPoint(widget, point, self.widget_tokens) orelse return null;
                const unit = canvasWidgetMultiClickUnitSelection(widget, offset, click_count);
                if (!extend) {
                    self.canvas_widget_multi_click_anchor = unit.range(widget.text.len);
                    return unit;
                }
                return canvasWidgetMultiClickDragSelection(self.canvas_widget_multi_click_anchor, unit, widget.text.len);
            }
            const anchor: ?usize = if (extend) current_selection.anchor else null;
            return canvas.textSelectionForWidgetPoint(widget, point, anchor, self.widget_tokens);
        }

        /// The run one multi-click selects at `offset`. Triple-click
        /// pins the platform convention: single-line kinds (input,
        /// text field, search field, combobox) select the entire text;
        /// a textarea selects the clicked hard-newline line. Double
        /// selects the word/whitespace/punctuation run — the same
        /// boundaries the caret's word-jump uses.
        fn canvasWidgetMultiClickUnitSelection(widget: canvas.Widget, offset: usize, click_count: u8) canvas.TextSelection {
            if (click_count >= 3) {
                if (canvasWidgetSingleLineTextKind(widget.kind)) return .{ .anchor = 0, .focus = widget.text.len };
                return canvas.textLineSelectionAtOffset(widget.text, offset);
            }
            return canvas.textWordSelectionAtOffset(widget.text, offset);
        }

        /// Union the run under the drag pointer with the gesture's
        /// anchor run, oriented so the selection FOCUS sits at the
        /// dragged edge (a shift-arrow after the drag keeps extending
        /// from where the pointer stopped): dragging before the anchor
        /// run anchors at its end, dragging past it anchors at its
        /// start, and a pointer back inside the anchor run restores
        /// exactly the anchor run.
        fn canvasWidgetMultiClickDragSelection(anchor: canvas.TextRange, unit: canvas.TextSelection, text_len: usize) canvas.TextSelection {
            const anchor_range = anchor.normalized(text_len);
            const unit_range = unit.range(text_len);
            if (unit_range.start < anchor_range.start) {
                return .{ .anchor = anchor_range.end, .focus = unit_range.start };
            }
            if (unit_range.end > anchor_range.end) {
                return .{ .anchor = anchor_range.start, .focus = unit_range.end };
            }
            return .{ .anchor = anchor_range.start, .focus = anchor_range.end };
        }

        /// Click-drag selection inside one static `.text` widget. Press
        /// collapses at the hit offset, drag extends from the press
        /// anchor. Cross-widget selection is out of scope: the selection
        /// model is the widget's own `text_selection` — there is no
        /// document model ordering text across widgets to extend into.
        fn applyCanvasWidgetStaticTextPointer(self: *RuntimeView, index: usize, target_id: canvas.ObjectId, point: geometry.PointF, extend: bool) anyerror!?geometry.RectF {
            const widget = self.widget_layout_nodes[index].widget;
            if (extend and self.canvas_widget_selected_text_id != target_id) return null;
            const current_selection = widget.text_selection orelse canvas.TextSelection.collapsed(0);
            const anchor: ?usize = if (extend) current_selection.anchor else null;
            const next_selection = canvas.staticTextSelectionForWidgetPoint(widget, point, anchor, self.widget_tokens) orelse return null;
            if (self.canvas_widget_selected_text_id == target_id and widget.text_selection != null and canvasTextSelectionsEqual(current_selection, next_selection)) return null;

            self.widget_layout_nodes[index].widget.text_selection = next_selection;
            self.canvas_widget_selected_text_id = target_id;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, widget.frame);
        }

        /// Drop the view's static text selection (pointer pressed
        /// elsewhere, or the copy source went away). Returns the dirty
        /// bounds of the widget that lost its highlight.
        pub fn clearCanvasWidgetStaticTextSelection(self: *RuntimeView) anyerror!?geometry.RectF {
            const id = self.canvas_widget_selected_text_id;
            if (id == 0) return null;
            self.canvas_widget_selected_text_id = 0;
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            if (self.widget_layout_nodes[index].widget.text_selection == null) return null;
            self.widget_layout_nodes[index].widget.text_selection = null;
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }

        /// The text a copy shortcut should place on the clipboard: the
        /// focused editable widget's selection or focused terminal's
        /// emulator selection when it has one, else the view's static
        /// text selection.
        pub fn canvasWidgetCopyText(self: *const RuntimeView) ?[]const u8 {
            if (self.canvas_widget_focused_id != 0) {
                if (self.canvasWidgetNodeIndexById(self.canvas_widget_focused_id)) |index| {
                    const focused = self.widget_layout_nodes[index].widget;
                    if (!focused.state.disabled and focused.kind == .terminal) {
                        if (focused.terminal.grid) |grid| {
                            if (grid.selection_active) return grid.selection_text;
                        }
                    }
                }
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_focused_id, true)) |slice| return slice;
            }
            if (self.canvas_widget_selected_text_id != 0) {
                if (canvasWidgetSelectionSliceById(self, self.canvas_widget_selected_text_id, false)) |slice| return slice;
            }
            return null;
        }

        fn canvasWidgetSelectionSliceById(self: *const RuntimeView, id: canvas.ObjectId, editable_only: bool) ?[]const u8 {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (widget.state.disabled) return null;
            if (editable_only and !canvasWidgetEditableTextKind(widget.kind)) return null;
            const range = canvas.widgetTextSelectionRange(widget) orelse return null;
            if (range.isCollapsed(widget.text.len)) return null;
            return widget.text[range.start..range.end];
        }

        pub fn rewriteCanvasWidgetTextStorage(self: *RuntimeView, edited_index: usize, next_state: canvas.TextEditState) anyerror!void {
            var temp: [max_canvas_widget_text_bytes_per_view]u8 = undefined;
            var text_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var label_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var command_ranges: [max_canvas_widget_nodes_per_view]WidgetTextStorageRange = undefined;
            var temp_len: usize = 0;

            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |node, index| {
                const text = if (index == edited_index) next_state.text else node.widget.text;
                text_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, text);
                label_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, node.widget.semantics.label);
                command_ranges[index] = try appendWidgetTextStorageRange(&temp, &temp_len, node.widget.command);
            }

            @memcpy(self.widget_text_bytes[0..temp_len], temp[0..temp_len]);
            self.widget_text_len = temp_len;
            for (self.widget_layout_nodes[0..self.widget_layout_node_count], 0..) |*node, index| {
                const text_range = text_ranges[index];
                const label_range = label_ranges[index];
                const command_range = command_ranges[index];
                node.widget.text = self.widget_text_bytes[text_range.start..text_range.end];
                node.widget.semantics.label = self.widget_text_bytes[label_range.start..label_range.end];
                node.widget.command = self.widget_text_bytes[command_range.start..command_range.end];
            }
            self.widget_layout_nodes[edited_index].widget.text_selection = next_state.selection;
            self.widget_layout_nodes[edited_index].widget.text_composition = next_state.composition;
        }

        pub fn setCanvasWidgetTextValue(self: *RuntimeView, id: canvas.ObjectId, text: []const u8) anyerror!?geometry.RectF {
            const index = self.canvasWidgetNodeIndexById(id) orelse return null;
            const widget = self.widget_layout_nodes[index].widget;
            if (!canvasWidgetEditableTextKind(widget.kind) or widget.state.disabled) return null;
            if (std.mem.eql(u8, widget.text, text) and widget.text_composition == null and textSelectionCollapsedAt(widget.text_selection, text.len)) return null;

            clearCanvasWidgetTextHistory(self, id);
            try self.rewriteCanvasWidgetTextStorage(index, .{
                .text = text,
                .selection = canvas.TextSelection.collapsed(text.len),
                .composition = null,
            });
            self.scrollCanvasTextInputCaretIntoView(index);
            try self.refreshCanvasWidgetSemantics();
            self.widget_revision += 1;
            return self.canvasWidgetDirtyBounds(index, self.widget_layout_nodes[index].frame);
        }
    };
}

const CanvasWidgetTextHistoryDelta = struct {
    prefix_len: usize,
    before_end: usize,
    after_end: usize,
};

fn canvasWidgetTextHistoryDelta(before: []const u8, after: []const u8) CanvasWidgetTextHistoryDelta {
    var prefix_len: usize = 0;
    const shared_len = @min(before.len, after.len);
    while (prefix_len < shared_len and before[prefix_len] == after[prefix_len]) prefix_len += 1;
    prefix_len = @min(canvas.snapTextOffset(before, prefix_len), canvas.snapTextOffset(after, prefix_len));

    var suffix_len: usize = 0;
    while (suffix_len < before.len - prefix_len and
        suffix_len < after.len - prefix_len and
        before[before.len - suffix_len - 1] == after[after.len - suffix_len - 1])
    {
        suffix_len += 1;
    }
    // A common byte suffix can begin inside a shared UTF-8 sequence when
    // two codepoints share continuation bytes. Shrink it until both
    // replacement ends are scalar boundaries.
    while (suffix_len > 0) {
        const before_end = before.len - suffix_len;
        const after_end = after.len - suffix_len;
        if (canvas.snapTextOffset(before, before_end) == before_end and
            canvas.snapTextOffset(after, after_end) == after_end)
        {
            break;
        }
        suffix_len -= 1;
    }
    return .{
        .prefix_len = prefix_len,
        .before_end = before.len - suffix_len,
        .after_end = after.len - suffix_len,
    };
}

fn textHistoryHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn historySelectionCollapsedAt(selection: canvas.TextSelection, offset: usize) bool {
    return selection.anchor == offset and selection.focus == offset;
}

fn historySingleCodepoint(text: []const u8) bool {
    return text.len > 0 and canvas.snapTextOffset(text, text.len - 1) == 0;
}

fn appendCanvasWidgetTextHistoryEdit(
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
    edit: canvas.TextInputEvent,
) void {
    if (count.* >= output.len) return;
    output[count.*] = edit;
    count.* += 1;
}

fn buildCanvasWidgetTextUndoEdits(
    entry: CanvasWidgetTextHistoryEntry,
    removed: []const u8,
    inserted: []const u8,
    current_selection: canvas.TextSelection,
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
) void {
    const prefix = entry.prefix_len;
    if (removed.len == 0 and
        historySingleCodepoint(inserted) and
        historySelectionCollapsedAt(current_selection, prefix + inserted.len) and
        historySelectionCollapsedAt(entry.before_selection, prefix))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_backward);
        return;
    }
    if (inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        historySelectionCollapsedAt(entry.before_selection, prefix + removed.len))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = removed });
        return;
    }

    const replacement_selection = canvas.TextSelection{ .anchor = prefix, .focus = prefix + inserted.len };
    if (!canvasTextSelectionsEqual(current_selection, replacement_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = replacement_selection });
    }
    appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = removed });
    const insertion_selection = canvas.TextSelection.collapsed(prefix + removed.len);
    if (!canvasTextSelectionsEqual(insertion_selection, entry.before_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = entry.before_selection });
    }
}

fn buildCanvasWidgetTextRedoEdits(
    entry: CanvasWidgetTextHistoryEntry,
    removed: []const u8,
    inserted: []const u8,
    current_selection: canvas.TextSelection,
    output: *[max_text_history_edits_per_shortcut]?canvas.TextInputEvent,
    count: *usize,
) void {
    const prefix = entry.prefix_len;
    if (removed.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        historySelectionCollapsedAt(entry.after_selection, prefix + inserted.len))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = inserted });
        return;
    }
    if (historySingleCodepoint(removed) and
        inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix + removed.len) and
        historySelectionCollapsedAt(entry.after_selection, prefix))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_backward);
        return;
    }
    if (historySingleCodepoint(removed) and
        inserted.len == 0 and
        historySelectionCollapsedAt(current_selection, prefix) and
        historySelectionCollapsedAt(entry.after_selection, prefix))
    {
        appendCanvasWidgetTextHistoryEdit(output, count, .delete_forward);
        return;
    }

    const replacement_selection = canvas.TextSelection{ .anchor = prefix, .focus = prefix + removed.len };
    if (!canvasTextSelectionsEqual(current_selection, replacement_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = replacement_selection });
    }
    appendCanvasWidgetTextHistoryEdit(output, count, .{ .insert_text = inserted });
    const insertion_selection = canvas.TextSelection.collapsed(prefix + inserted.len);
    if (!canvasTextSelectionsEqual(insertion_selection, entry.after_selection)) {
        appendCanvasWidgetTextHistoryEdit(output, count, .{ .set_selection = entry.after_selection });
    }
}
