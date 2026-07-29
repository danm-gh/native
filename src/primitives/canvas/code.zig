//! Syntax-aware source-code presentation shared by `Ui.code` and
//! Markdown fenced blocks.
//!
//! The lexer is deliberately small and deterministic: it recognizes the
//! punctuation classes that make common snippets readable, emits only
//! theme-token colors, and always preserves an unstyled remainder when a
//! token-dense source reaches the paragraph span limit.

const std = @import("std");
const text_spans = @import("text_spans.zig");

pub const TextSpan = text_spans.TextSpan;

pub const Language = enum {
    plain,
    zig,
    javascript,
    typescript,
    json,
    shell,
    python,
    rust,
    c_like,
    go,
    html,
    css,
    sql,
};

/// Lexer state carried between bounded source chunks by `Ui.code`.
/// Keeping it explicit lets the component reset its span budget without
/// forgetting a multiline tag, string, or block comment.
pub const HighlightState = struct {
    html_in_tag: bool = false,
    html_expect_tag_name: bool = false,
    html_expression_depth: usize = 0,
    html_comment: bool = false,
    block_comment: bool = false,
    line_comment: bool = false,
    preprocessor_line: bool = false,
    string_quote: ?u8 = null,
};

/// Resolve a public language name. Unknown names remain plain instead of
/// guessing a grammar and coloring ordinary identifiers as keywords.
pub fn languageFromName(name_raw: []const u8) Language {
    const name = std.mem.trim(u8, name_raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(name, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(name, "jsx") or std.ascii.eqlIgnoreCase(name, "tsx")) return .html;
    if (std.ascii.eqlIgnoreCase(name, "js") or std.ascii.eqlIgnoreCase(name, "javascript")) return .javascript;
    if (std.ascii.eqlIgnoreCase(name, "ts") or std.ascii.eqlIgnoreCase(name, "typescript")) return .typescript;
    if (std.ascii.eqlIgnoreCase(name, "json") or std.ascii.eqlIgnoreCase(name, "jsonc")) return .json;
    if (std.ascii.eqlIgnoreCase(name, "sh") or std.ascii.eqlIgnoreCase(name, "bash") or std.ascii.eqlIgnoreCase(name, "zsh") or std.ascii.eqlIgnoreCase(name, "shell")) return .shell;
    if (std.ascii.eqlIgnoreCase(name, "py") or std.ascii.eqlIgnoreCase(name, "python")) return .python;
    if (std.ascii.eqlIgnoreCase(name, "rs") or std.ascii.eqlIgnoreCase(name, "rust")) return .rust;
    if (std.ascii.eqlIgnoreCase(name, "c") or std.ascii.eqlIgnoreCase(name, "h") or
        std.ascii.eqlIgnoreCase(name, "cc") or std.ascii.eqlIgnoreCase(name, "cpp") or std.ascii.eqlIgnoreCase(name, "c++") or
        std.ascii.eqlIgnoreCase(name, "cs") or std.ascii.eqlIgnoreCase(name, "csharp") or
        std.ascii.eqlIgnoreCase(name, "java") or std.ascii.eqlIgnoreCase(name, "kotlin") or
        std.ascii.eqlIgnoreCase(name, "swift"))
    {
        return .c_like;
    }
    if (std.ascii.eqlIgnoreCase(name, "go") or std.ascii.eqlIgnoreCase(name, "golang")) return .go;
    if (std.ascii.eqlIgnoreCase(name, "html") or std.ascii.eqlIgnoreCase(name, "xml") or std.ascii.eqlIgnoreCase(name, "svg")) return .html;
    if (std.ascii.eqlIgnoreCase(name, "css") or std.ascii.eqlIgnoreCase(name, "scss") or std.ascii.eqlIgnoreCase(name, "less")) return .css;
    if (std.ascii.eqlIgnoreCase(name, "sql")) return .sql;
    return .plain;
}

pub fn isLanguageName(name_raw: []const u8) bool {
    const name = std.mem.trim(u8, name_raw, " \t\r\n");
    return languageFromName(name) != .plain or
        std.ascii.eqlIgnoreCase(name, "plain") or
        std.ascii.eqlIgnoreCase(name, "text");
}

/// Resolve the first word of a Markdown fence's info string.
pub fn languageFromFence(opening: []const u8) Language {
    const trimmed = std.mem.trim(u8, opening, " \t");
    if (trimmed.len <= 3) return .plain;
    var info = std.mem.trim(u8, trimmed[3..], " \t");
    if (std.mem.startsWith(u8, info, "{.")) info = info[2..];
    var end: usize = 0;
    while (end < info.len) : (end += 1) {
        const byte = info[end];
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '+' or byte == '#')) break;
    }
    return languageFromName(info[0..end]);
}

fn wordInList(word: []const u8, list: []const u8, ignore_case: bool) bool {
    var words = std.mem.tokenizeScalar(u8, list, ' ');
    while (words.next()) |candidate| {
        if (if (ignore_case) std.ascii.eqlIgnoreCase(word, candidate) else std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

/// Zig fences dominate SDK documentation, so the hot grammar uses a
/// length-indexed map instead of rescanning a word list per identifier.
const zig_words = std.StaticStringMap(text_spans.TextSpanColor).initComptime(.{
    .{ "addrspace", .info },         .{ "align", .info },           .{ "allowzero", .info },
    .{ "and", .info },               .{ "anyerror", .warning },     .{ "anyframe", .info },
    .{ "anytype", .info },           .{ "asm", .info },             .{ "async", .info },
    .{ "await", .info },             .{ "bool", .warning },         .{ "break", .info },
    .{ "callconv", .info },          .{ "catch", .info },           .{ "comptime", .info },
    .{ "comptime_float", .warning }, .{ "comptime_int", .warning }, .{ "const", .info },
    .{ "continue", .info },          .{ "defer", .info },           .{ "else", .info },
    .{ "enum", .info },              .{ "errdefer", .info },        .{ "error", .info },
    .{ "export", .info },            .{ "extern", .info },          .{ "f16", .warning },
    .{ "f32", .warning },            .{ "f64", .warning },          .{ "f80", .warning },
    .{ "f128", .warning },           .{ "false", .warning },        .{ "fn", .info },
    .{ "for", .info },               .{ "i8", .warning },           .{ "i16", .warning },
    .{ "i32", .warning },            .{ "i64", .warning },          .{ "i128", .warning },
    .{ "if", .info },                .{ "inline", .info },          .{ "isize", .warning },
    .{ "linksection", .info },       .{ "noalias", .info },         .{ "noinline", .info },
    .{ "noreturn", .warning },       .{ "nosuspend", .info },       .{ "null", .warning },
    .{ "opaque", .info },            .{ "or", .info },              .{ "orelse", .info },
    .{ "packed", .info },            .{ "pub", .info },             .{ "resume", .info },
    .{ "return", .info },            .{ "struct", .info },          .{ "suspend", .info },
    .{ "switch", .info },            .{ "test", .info },            .{ "threadlocal", .info },
    .{ "true", .warning },           .{ "try", .info },             .{ "type", .warning },
    .{ "u8", .warning },             .{ "u16", .warning },          .{ "u32", .warning },
    .{ "u64", .warning },            .{ "u128", .warning },         .{ "undefined", .warning },
    .{ "union", .info },             .{ "unreachable", .info },     .{ "usize", .warning },
    .{ "usingnamespace", .info },    .{ "var", .info },             .{ "void", .warning },
    .{ "volatile", .info },          .{ "while", .info },
});

fn wordColor(language: Language, word: []const u8) ?text_spans.TextSpanColor {
    if (word.len > 0 and word[0] == '@') return .info;
    if (language == .zig) return zig_words.get(word);
    if (wordInList(word, "true false null nil none undefined this self super", language == .sql)) return .warning;

    const keywords = switch (language) {
        .plain => return null,
        .zig => unreachable,
        .javascript => "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static switch throw try typeof var void while with yield",
        .typescript => "abstract any as asserts async await bigint boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer interface instanceof is keyof let module namespace never new number object of override private protected public readonly require return satisfies set static string super switch symbol this throw try type typeof undefined unique unknown var void while with yield",
        .json => "",
        .shell => "case coproc do done elif else esac fi for function if in select then time until while",
        .python => "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
        .rust => "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while",
        .c_like => "abstract alignas alignof asm auto break case catch class const constexpr continue default delete do else enum explicit export extends extern final finally for foreach friend goto if implements import in inline interface internal namespace native new noexcept operator override package private protected public register reinterpret_cast return sealed signed sizeof static strictfp struct switch synchronized template this throw throws trait transient try typedef typeid typename union unsigned using virtual volatile while",
        .go => "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        .html => "",
        .css => "and important inherit initial none not only or revert unset",
        .sql => "add all alter and any as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full grant group having in index inner insert intersect into is join key left like limit not null on or order outer primary references right rollback row select set table then union unique update values view when where with",
    };
    if (wordInList(word, keywords, language == .sql)) return .info;

    const types = switch (language) {
        .rust => "bool char str String Vec Option Result Box i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64",
        .c_like => "bool boolean byte char decimal double float int long object sbyte short string uint ulong ushort void",
        .go => "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr",
        .javascript, .typescript => "Array BigInt Boolean Date Error Map Number Object Promise RegExp Set String Symbol",
        .python => "bool bytes dict float int list object set str tuple",
        else => "",
    };
    if (wordInList(word, types, false)) return .warning;
    return null;
}

fn identifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '@' or byte == '$';
}

fn identifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '@' or byte == '$';
}

fn stringQuote(language: Language, byte: u8) bool {
    return switch (language) {
        .plain, .html => false,
        .json => byte == '"',
        .shell, .javascript, .typescript, .go => byte == '"' or byte == '\'' or byte == '`',
        else => byte == '"' or byte == '\'',
    };
}

fn backslashEscapesQuote(language: Language, state: HighlightState, quote: u8) bool {
    if (quote != '\'') return true;
    return switch (language) {
        // These grammars treat single quotes literally (or escape them by
        // doubling the quote), rather than with a backslash.
        .shell, .sql => false,
        // Plain HTML attributes do not use JavaScript escapes, but JSX
        // expressions do.
        .html => state.html_expression_depth > 0,
        else => true,
    };
}

fn lineCommentPrefix(language: Language, rest: []const u8) usize {
    if (rest.len == 0) return 0;
    return switch (language) {
        .zig, .javascript, .typescript, .rust, .c_like, .go => if (std.mem.startsWith(u8, rest, "//")) 2 else 0,
        .shell, .python => if (rest[0] == '#') 1 else 0,
        .sql => if (std.mem.startsWith(u8, rest, "--")) 2 else 0,
        else => 0,
    };
}

fn hasBlockComments(language: Language) bool {
    return switch (language) {
        .zig, .javascript, .typescript, .rust, .c_like, .go, .css, .sql => true,
        else => false,
    };
}

/// Add one token, coalescing adjacent tokens with the same color. The
/// final slot is an unstyled remainder, so capacity never drops source.
fn appendSpan(
    storage: *[text_spans.max_text_spans_per_paragraph]TextSpan,
    len: *usize,
    source: []const u8,
    start: usize,
    end: usize,
    color: ?text_spans.TextSpanColor,
) bool {
    if (end <= start) return true;
    if (len.* > 0) {
        const previous = &storage[len.* - 1];
        if (previous.color == color and previous.text.ptr + previous.text.len == source[start..].ptr) {
            previous.text = previous.text.ptr[0 .. previous.text.len + end - start];
            return true;
        }
    }
    if (len.* + 1 >= storage.len) {
        storage[len.*] = .{ .text = source[start..], .monospace = true };
        len.* += 1;
        return false;
    }
    storage[len.*] = .{ .text = source[start..end], .monospace = true, .color = color };
    len.* += 1;
    return true;
}

/// Tokenize `source` into theme-colored monospace spans.
pub fn highlight(
    source: []const u8,
    language: Language,
    storage: *[text_spans.max_text_spans_per_paragraph]TextSpan,
) []const TextSpan {
    var state: HighlightState = .{};
    return highlightWithState(source, language, storage, &state);
}

/// Stateful form used when one code surface emits multiple bounded
/// paragraphs. Each chunk gets the full span capacity while lexer context
/// survives into the next chunk.
pub fn highlightWithState(
    source: []const u8,
    language: Language,
    storage: *[text_spans.max_text_spans_per_paragraph]TextSpan,
    state: *HighlightState,
) []const TextSpan {
    if (source.len == 0) return &.{};
    if (language == .plain) {
        storage[0] = .{ .text = source, .monospace = true };
        return storage[0..1];
    }

    var len: usize = 0;
    var styling_full = false;
    var index: usize = 0;
    while (index < source.len) {
        const start = index;
        const rest = source[index..];
        var color: ?text_spans.TextSpanColor = null;

        // Artificial presentation chunks can end in the middle of a
        // logical source line. A real newline ends the two line-scoped
        // states before ordinary token dispatch handles that byte.
        if (rest[0] == '\n') {
            state.line_comment = false;
            state.preprocessor_line = false;
        }

        if (state.line_comment) {
            while (index < source.len and source[index] != '\n') index += 1;
            state.line_comment = index == source.len;
            color = .text_muted;
        } else if (state.preprocessor_line) {
            while (index < source.len and source[index] != '\n') index += 1;
            state.preprocessor_line = index == source.len;
            color = .info;
        } else if (state.html_comment) {
            while (index < source.len and !std.mem.startsWith(u8, source[index..], "-->")) index += 1;
            if (index < source.len) {
                index = @min(source.len, index + 3);
                state.html_comment = false;
            }
            color = .text_muted;
        } else if (state.block_comment) {
            while (index < source.len and !std.mem.startsWith(u8, source[index..], "*/")) index += 1;
            if (index < source.len) {
                index = @min(source.len, index + 2);
                state.block_comment = false;
            }
            color = .text_muted;
        } else if (state.string_quote) |quote| {
            var closed = false;
            while (index < source.len) {
                if (source[index] == '\\' and
                    backslashEscapesQuote(language, state.*, quote) and
                    index + 1 < source.len)
                {
                    index += 2;
                    continue;
                }
                const byte = source[index];
                index += 1;
                if (byte == quote) {
                    closed = true;
                    break;
                }
            }
            if (closed) state.string_quote = null;
            color = .success;
        } else if (language == .html and std.mem.startsWith(u8, rest, "<!--")) {
            index += 4;
            while (index < source.len and !std.mem.startsWith(u8, source[index..], "-->")) index += 1;
            if (index < source.len) {
                index = @min(source.len, index + 3);
            } else {
                state.html_comment = true;
            }
            color = .text_muted;
        } else if (hasBlockComments(language) and std.mem.startsWith(u8, rest, "/*")) {
            index += 2;
            while (index < source.len and !std.mem.startsWith(u8, source[index..], "*/")) index += 1;
            if (index < source.len) {
                index = @min(source.len, index + 2);
            } else {
                state.block_comment = true;
            }
            color = .text_muted;
        } else if (lineCommentPrefix(language, rest) != 0) {
            while (index < source.len and source[index] != '\n') index += 1;
            state.line_comment = index == source.len;
            color = .text_muted;
        } else if (language == .c_like and rest[0] == '#') {
            while (index < source.len and source[index] != '\n') index += 1;
            state.preprocessor_line = index == source.len;
            color = .info;
        } else if (language == .html and rest[0] == '<') {
            index += 1;
            if (index < source.len and source[index] == '/') index += 1;
            state.html_in_tag = true;
            state.html_expect_tag_name = true;
            state.html_expression_depth = 0;
            color = .info;
        } else if (language == .html and
            state.html_in_tag and
            state.html_expression_depth == 0 and
            rest[0] == '>')
        {
            index += 1;
            state.html_in_tag = false;
            state.html_expect_tag_name = false;
            state.html_expression_depth = 0;
            color = .info;
        } else if (language == .html and rest[0] == '{') {
            index += 1;
            state.html_expression_depth += 1;
            color = .info;
        } else if (language == .html and state.html_expression_depth > 0 and rest[0] == '}') {
            index += 1;
            state.html_expression_depth -= 1;
            color = .info;
        } else if (stringQuote(language, rest[0]) or
            (language == .html and
                (state.html_in_tag or state.html_expression_depth > 0) and
                (rest[0] == '"' or rest[0] == '\'' or rest[0] == '`')))
        {
            const quote = rest[0];
            index += 1;
            var closed = false;
            while (index < source.len) {
                if (source[index] == '\\' and
                    backslashEscapesQuote(language, state.*, quote) and
                    index + 1 < source.len)
                {
                    index += 2;
                    continue;
                }
                const byte = source[index];
                index += 1;
                if (byte == quote) {
                    closed = true;
                    break;
                }
            }
            if (!closed) state.string_quote = quote;
            color = .success;
        } else if (std.ascii.isDigit(rest[0])) {
            index += 1;
            while (index < source.len) {
                const byte = source[index];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.')) break;
                index += 1;
            }
            color = .warning;
        } else if (identifierStart(rest[0])) {
            index += 1;
            while (index < source.len and
                (identifierContinue(source[index]) or
                    ((language == .html or language == .css) and source[index] == '-')))
            {
                index += 1;
            }
            if (language == .html and state.html_in_tag) {
                if (state.html_expect_tag_name) {
                    color = .info;
                    state.html_expect_tag_name = false;
                } else if (state.html_expression_depth == 0) {
                    color = .warning;
                } else {
                    color = wordColor(.typescript, source[start..index]);
                }
            } else if (language == .html and state.html_expression_depth > 0) {
                color = wordColor(.typescript, source[start..index]);
            } else {
                color = wordColor(language, source[start..index]);
            }
        } else {
            index += 1;
        }

        // The last span already covers the entire unstyled remainder once
        // capacity fills, but keep scanning it so state handed to the next
        // paragraph still reflects comments, strings, and JSX expressions.
        if (!styling_full and !appendSpan(storage, &len, source, start, index, color)) {
            styling_full = true;
        }
    }
    return storage[0..len];
}
