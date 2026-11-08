//! The syntax tree to lines of styled spans for a given width. Every visual
//! decision lives here (spec 03/09 and 06/09).
//!
//! Blocks are walked with a stack of prefixes: a block quote adds its
//! gutter, a list item its marker on the first line and spaces of the same
//! width after. Inline content becomes a flat list of pieces, words and the
//! spaces between them, which are wrapped greedily on display width.

const std = @import("std");
const Allocator = std.mem.Allocator;
const md = @import("md");
const Ast = md.Ast;
const Index = Ast.Index;
const emit = @import("emit.zig");
const Span = emit.Span;
const Style = emit.Style;
const width = @import("width.zig");

pub const Line = []const Span;

pub const Options = struct {
    width: u16,
    /// The styles reach a terminal. Without them, link targets are printed.
    styled: bool = true,
    ascii: bool = false,
    no_links: bool = false,
};

const Glyphs = struct {
    quote: []const u8,
    code: []const u8,
    wrap: []const u8,
    rule: []const u8,
    bullets: [3][]const u8,
    /// Stands in for control characters.
    replacement: []const u8,
};

const unicode_glyphs: Glyphs = .{
    .quote = "│ ",
    .code = "│ ",
    .wrap = "↪ ",
    .rule = "─",
    .bullets = .{ "•", "◦", "▪" },
    .replacement = "\u{FFFD}",
};

const ascii_glyphs: Glyphs = .{
    .quote = "| ",
    .code = "| ",
    .wrap = "->",
    .rule = "-",
    .bullets = .{ "*", "-", "+" },
    .replacement = "?",
};

const dim: Style = .{ .dim = true };
const accent: emit.Color = .blue;

/// Lays out a whole document.
pub fn document(arena: Allocator, ast: Ast, options: Options) Allocator.Error![]const Line {
    var l: Layout = .{
        .arena = arena,
        .ast = ast,
        .options = options,
        .glyphs = if (options.ascii) &ascii_glyphs else &unicode_glyphs,
    };
    try l.children(0, true);
    return l.lines.items;
}

const Prefix = struct {
    first: []const Span,
    rest: []const Span,
    used: bool = false,
};

/// A word, a space between words, or a hard line break.
const Piece = struct {
    kind: enum { text, space, newline },
    text: []const u8 = "",
    style: Style = .plain,
    link: ?[]const u8 = null,
};

const Layout = struct {
    arena: Allocator,
    ast: Ast,
    options: Options,
    glyphs: *const Glyphs,
    lines: std.ArrayList(Line) = .empty,
    prefixes: std.ArrayList(Prefix) = .empty,
    prefix_width: usize = 0,
    bullet_depth: usize = 0,

    // Lines and prefixes.

    /// The columns left for content after the prefixes.
    fn room(l: *const Layout) usize {
        return @max(1, @as(usize, l.options.width) -| l.prefix_width);
    }

    fn push(l: *Layout, first: []const Span, rest: []const Span) !void {
        try l.prefixes.append(l.arena, .{ .first = first, .rest = rest });
        l.prefix_width += spansWidth(rest);
    }

    fn pop(l: *Layout) void {
        l.prefix_width -= spansWidth(l.prefixes.pop().?.rest);
    }

    /// One output line: the prefixes, then `content`. A line without content
    /// loses its trailing spaces.
    fn line(l: *Layout, content: []const Span) !void {
        var spans: std.ArrayList(Span) = .empty;
        for (l.prefixes.items) |*p| {
            try spans.appendSlice(l.arena, if (p.used) p.rest else p.first);
            p.used = true;
        }
        try spans.appendSlice(l.arena, content);
        if (content.len == 0) trimEnd(&spans);
        try l.lines.append(l.arena, spans.items);
    }

    /// The blank line between blocks, inside the same prefixes.
    fn blank(l: *Layout) !void {
        var spans: std.ArrayList(Span) = .empty;
        for (l.prefixes.items) |p| try spans.appendSlice(l.arena, p.rest);
        trimEnd(&spans);
        try l.lines.append(l.arena, spans.items);
    }

    fn span(l: *Layout, text: []const u8, style: Style) ![]const Span {
        return l.arena.dupe(Span, &.{.{ .text = text, .style = style }});
    }

    // Blocks.

    fn children(l: *Layout, n: Index, separated: bool) Allocator.Error!void {
        for (l.ast.children(n), 0..) |child, i| {
            if (i > 0 and separated) try l.blank();
            try l.block(child);
        }
    }

    fn block(l: *Layout, n: Index) !void {
        switch (l.ast.tag(n)) {
            .paragraph => try l.paragraph(n, .plain),
            .heading => {
                const level = l.ast.level(n);
                const marker = try l.arena.alloc(u8, level + 1);
                @memset(marker[0..level], '#');
                marker[level] = ' ';
                try l.push(try l.span(marker, dim), try l.span(spaces(level + 1), .plain));
                try l.paragraph(n, switch (level) {
                    1 => .{ .bold = true, .underline = true },
                    2 => .{ .bold = true },
                    else => .{ .bold = true, .dim = true },
                });
                l.pop();
            },
            .thematic_break => {
                const rule = try l.arena.alloc(u8, l.glyphs.rule.len * l.room());
                for (0..l.room()) |i| @memcpy(rule[i * l.glyphs.rule.len ..][0..l.glyphs.rule.len], l.glyphs.rule);
                try l.line(try l.span(rule, dim));
            },
            .code_block => try l.code(n),
            .html_block => {
                var rows = std.mem.splitScalar(u8, l.ast.content(n), '\n');
                while (rows.next()) |row| {
                    try l.hardWrapped(try l.expandTabs(try l.clean(row)), dim, &.{}, &.{});
                }
            },
            .block_quote => {
                const gutter = try l.span(l.glyphs.quote, dim);
                try l.push(gutter, gutter);
                if (l.ast.children(n).len == 0) try l.line(&.{}) else try l.children(n, true);
                l.pop();
            },
            .list => try l.list(n),
            else => unreachable,
        }
    }

    fn list(l: *Layout, n: Index) !void {
        const info = l.ast.list(n);
        const items = l.ast.children(n);
        const bullet = l.glyphs.bullets[l.bullet_depth % 3];
        if (!info.ordered) l.bullet_depth += 1;
        defer {
            if (!info.ordered) l.bullet_depth -= 1;
        }
        const last = @as(u64, info.start) + items.len - 1;
        const digits = std.fmt.count("{d}", .{last});
        for (items, 0..) |item, i| {
            if (i > 0 and !info.tight) try l.blank();
            const marker = if (info.ordered) blk: {
                const number = info.start + i;
                const pad = spaces(digits - std.fmt.count("{d}", .{number}));
                break :blk try std.fmt.allocPrint(l.arena, "{s}{d}{c} ", .{ pad, number, info.marker });
            } else try std.fmt.allocPrint(l.arena, "{s} ", .{bullet});
            try l.push(try l.span(marker, .plain), try l.span(spaces(width.ofString(marker)), .plain));
            if (l.ast.children(item).len == 0) try l.line(&.{}) else try l.children(item, !info.tight);
            l.pop();
        }
    }

    fn code(l: *Layout, n: Index) !void {
        const gutter = try l.span(l.glyphs.code, dim);
        const mark = try l.span(l.glyphs.wrap, dim);
        const info = l.ast.info(n);
        const language = info[0 .. std.mem.indexOfAny(u8, info, " \t\n") orelse info.len];
        if (language.len > 0) try l.line(&.{ gutter[0], .{ .text = try l.clean(language), .style = dim } });
        var content = l.ast.content(n);
        if (std.mem.endsWith(u8, content, "\n")) content = content[0 .. content.len - 1];
        if (content.len == 0 and language.len > 0) return;
        var rows = std.mem.splitScalar(u8, content, '\n');
        while (rows.next()) |row| try l.hardWrapped(try l.expandTabs(try l.clean(row)), .plain, gutter, mark);
    }

    /// A line that is never reflowed: cut at the room, the first piece
    /// after `gutter` and the rest after `mark`.
    fn hardWrapped(l: *Layout, text: []const u8, style: Style, gutter: []const Span, mark: []const Span) !void {
        if (text.len == 0) {
            const bare = if (gutter.len > 0) try l.span(std.mem.trimEnd(u8, gutter[0].text, " "), gutter[0].style) else &.{};
            return l.line(bare);
        }
        const avail = @max(1, l.room() -| spansWidth(gutter));
        var rest = text;
        var first = true;
        while (rest.len > 0) {
            const len = cut(rest, avail);
            var spans: std.ArrayList(Span) = .empty;
            try spans.appendSlice(l.arena, if (first) gutter else mark);
            try spans.append(l.arena, .{ .text = rest[0..len], .style = style });
            try l.line(spans.items);
            rest = rest[len..];
            first = false;
        }
    }

    // Inlines.

    fn paragraph(l: *Layout, n: Index, base: Style) !void {
        var pieces: std.ArrayList(Piece) = .empty;
        try l.inlines(&pieces, n, base, null);
        try l.wrap(pieces.items);
    }

    fn inlines(l: *Layout, out: *std.ArrayList(Piece), n: Index, style: Style, link: ?[]const u8) Allocator.Error!void {
        for (l.ast.children(n)) |child| try l.inlineNode(out, child, style, link);
    }

    fn inlineNode(l: *Layout, out: *std.ArrayList(Piece), n: Index, style: Style, link: ?[]const u8) !void {
        const ast = l.ast;
        switch (ast.tag(n)) {
            .text => try l.words(out, ast.content(n), style, link),
            .soft_break => try out.append(l.arena, .{ .kind = .space, .style = style, .link = link }),
            .hard_break => try out.append(l.arena, .{ .kind = .newline }),
            .code_span => {
                // One word: a code span breaks only when it is wider than a line.
                var tick = style;
                tick.dim = true;
                var text = style;
                text.fg = accent;
                const content = try l.clean(ast.content(n));
                try out.appendSlice(l.arena, &.{
                    .{ .kind = .text, .text = "`", .style = tick, .link = link },
                    .{ .kind = .text, .text = try l.spacedTabs(content), .style = text, .link = link },
                    .{ .kind = .text, .text = "`", .style = tick, .link = link },
                });
            },
            .html_inline => {
                var raw = style;
                raw.dim = true;
                try l.words(out, ast.content(n), raw, link);
            },
            .emphasis => {
                var s = style;
                s.italic = true;
                try l.inlines(out, n, s, link);
            },
            .strong => {
                var s = style;
                s.bold = true;
                try l.inlines(out, n, s, link);
            },
            .link => {
                const destination = ast.string(ast.link(n).destination);
                const hyper = l.options.styled and !l.options.no_links and destination.len > 0;
                var s = style;
                s.underline = true;
                s.fg = accent;
                try l.inlines(out, n, s, if (hyper) destination else link);
                if (!hyper and destination.len > 0 and !l.isAutolink(n, destination)) try l.target(out, destination, style, link);
            },
            .image => {
                var alt: std.ArrayList(u8) = .empty;
                try alt.appendSlice(l.arena, "[image: ");
                try l.plainText(&alt, n);
                try alt.append(l.arena, ']');
                try l.words(out, alt.items, style, link);
                const destination = ast.string(ast.link(n).destination);
                if (destination.len > 0) try l.target(out, destination, style, link);
            },
            else => unreachable,
        }
    }

    /// ` (url)` in dim after a link or image.
    fn target(l: *Layout, out: *std.ArrayList(Piece), destination: []const u8, style: Style, link: ?[]const u8) !void {
        try out.appendSlice(l.arena, &.{
            .{ .kind = .space, .style = style, .link = link },
            .{ .kind = .text, .text = try std.fmt.allocPrint(l.arena, "({s})", .{try l.clean(destination)}), .style = dim },
        });
    }

    /// A link whose text is its own destination, as `<https://x.org>` makes.
    fn isAutolink(l: *const Layout, n: Index, destination: []const u8) bool {
        const kids = l.ast.children(n);
        if (kids.len != 1 or l.ast.tag(kids[0]) != .text) return false;
        const text = l.ast.content(kids[0]);
        return std.mem.eql(u8, text, destination) or
            (std.mem.startsWith(u8, destination, "mailto:") and std.mem.eql(u8, text, destination[7..]));
    }

    fn plainText(l: *Layout, out: *std.ArrayList(u8), n: Index) Allocator.Error!void {
        for (l.ast.children(n)) |child| switch (l.ast.tag(child)) {
            .text, .code_span => try out.appendSlice(l.arena, l.ast.content(child)),
            .soft_break, .hard_break => try out.append(l.arena, ' '),
            .html_inline => {},
            else => try l.plainText(out, child),
        };
    }

    /// Splits text into words and the spaces between them.
    fn words(l: *Layout, out: *std.ArrayList(Piece), raw: []const u8, style: Style, link: ?[]const u8) !void {
        const text = try l.clean(raw);
        var i: usize = 0;
        while (i < text.len) {
            if (isSpace(text[i])) {
                while (i < text.len and isSpace(text[i])) i += 1;
                try out.append(l.arena, .{ .kind = .space, .style = style, .link = link });
                continue;
            }
            const start = i;
            while (i < text.len and !isSpace(text[i])) i += 1;
            try out.append(l.arena, .{ .kind = .text, .text = text[start..i], .style = style, .link = link });
        }
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    /// Greedy wrapping on display width. Words that do not fit go to the
    /// next line; a word wider than a line is cut.
    fn wrap(l: *Layout, pieces: []const Piece) !void {
        const avail = l.room();
        var current: std.ArrayList(Span) = .empty;
        var col: usize = 0;
        var space: ?Piece = null;
        const lines_before = l.lines.items.len;
        var i: usize = 0;
        while (i < pieces.len) {
            const p = pieces[i];
            switch (p.kind) {
                .space => {
                    if (col > 0) space = p;
                    i += 1;
                },
                .newline => {
                    try l.line(current.items);
                    current.clearRetainingCapacity();
                    col = 0;
                    space = null;
                    i += 1;
                },
                .text => {
                    var end = i;
                    var w: usize = 0;
                    while (end < pieces.len and pieces[end].kind == .text) : (end += 1) w += width.ofString(pieces[end].text);
                    const gap: usize = @intFromBool(space != null);
                    if (col > 0 and col + gap + w > avail) {
                        try l.line(current.items);
                        current.clearRetainingCapacity();
                        col = 0;
                    } else if (space) |s| {
                        try current.append(l.arena, .{ .text = " ", .style = s.style, .link = s.link });
                        col += 1;
                    }
                    space = null;
                    for (pieces[i..end]) |q| {
                        var rest = q.text;
                        while (rest.len > 0) {
                            const rest_width = width.ofString(rest);
                            if (col + rest_width <= avail) {
                                try current.append(l.arena, .{ .text = rest, .style = q.style, .link = q.link });
                                col += rest_width;
                                break;
                            }
                            const len = cut(rest, avail -| col);
                            if (len == 0 or (col > 0 and width.ofString(rest[0..len]) > avail - col)) {
                                try l.line(current.items);
                                current.clearRetainingCapacity();
                                col = 0;
                                continue;
                            }
                            try current.append(l.arena, .{ .text = rest[0..len], .style = q.style, .link = q.link });
                            try l.line(current.items);
                            current.clearRetainingCapacity();
                            col = 0;
                            rest = rest[len..];
                        }
                    }
                    i = end;
                },
            }
        }
        if (current.items.len > 0 or l.lines.items.len == lines_before) try l.line(current.items);
    }

    // Text.

    /// The text with control characters replaced, so that a document cannot
    /// send escapes to the terminal: C0 except tab and line feed, DEL, and C1.
    fn clean(l: *Layout, s: []const u8) ![]const u8 {
        var i: usize = 0;
        const dirty = while (i < s.len) : (i += 1) {
            if (isControl(s, i)) break true;
        } else false;
        if (!dirty) return s;
        var out: std.ArrayList(u8) = try .initCapacity(l.arena, s.len);
        i = 0;
        while (i < s.len) {
            if (isControl(s, i)) {
                try out.appendSlice(l.arena, l.glyphs.replacement);
                i += if (s[i] == 0xC2) 2 else 1;
            } else {
                try out.append(l.arena, s[i]);
                i += 1;
            }
        }
        return out.items;
    }

    fn isControl(s: []const u8, i: usize) bool {
        const c = s[i];
        if (c < 0x20) return c != '\t' and c != '\n';
        if (c == 0x7f) return true;
        return c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F;
    }

    /// Tabs to spaces, up to the next multiple of four columns.
    fn expandTabs(l: *Layout, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var col: usize = 0;
        var parts = std.mem.splitScalar(u8, s, '\t');
        var first = true;
        while (parts.next()) |part| {
            if (!first) {
                const n = 4 - col % 4;
                try out.appendNTimes(l.arena, ' ', n);
                col += n;
            }
            first = false;
            try out.appendSlice(l.arena, part);
            col += width.ofString(part);
        }
        return out.items;
    }

    /// Tabs to single spaces, for code spans.
    fn spacedTabs(l: *Layout, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
        const out = try l.arena.dupe(u8, s);
        std.mem.replaceScalar(u8, out, '\t', ' ');
        return out;
    }
};

/// The longest start of `s`, in bytes, that fits in `columns`. At least one
/// code point, even when that one is wider.
fn cut(s: []const u8, columns: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(s.len, i + len);
        const w = width.ofString(s[i..end]);
        if (used + w > columns) return if (i == 0) end else i;
        used += w;
        i = end;
    }
    return s.len;
}

fn spansWidth(spans: []const Span) usize {
    var total: usize = 0;
    for (spans) |s| total += width.ofString(s.text);
    return total;
}

/// Drops trailing spaces, and spans left empty by that.
fn trimEnd(spans: *std.ArrayList(Span)) void {
    while (spans.items.len > 0) {
        const last = &spans.items[spans.items.len - 1];
        last.text = std.mem.trimEnd(u8, last.text, " ");
        if (last.text.len > 0) return;
        _ = spans.pop();
    }
}

const blanks: [64]u8 = @splat(' ');

fn spaces(n: usize) []const u8 {
    return blanks[0..@min(n, blanks.len)];
}

const testing = std.testing;

/// Lays out `markdown` and writes the lines in a visible form: styled text
/// in `⟨...⟩` marks naming its attributes (b, d, i, u, s, c for the accent,
/// @url for a hyperlink), closed by `⟨/⟩`.
fn expectLayout(markdown: []const u8, options: Options, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try document(a, try md.parse(a, markdown), options);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (lines, 0..) |row, i| {
        if (i > 0) try w.writeByte('\n');
        // Neighbours with the same look read as one.
        var merged: std.ArrayList(Span) = .empty;
        for (row) |s| {
            if (merged.items.len > 0) {
                const last = &merged.items[merged.items.len - 1];
                if (last.style == s.style and sameLink(last.link, s.link)) {
                    last.text = try std.mem.concat(a, u8, &.{ last.text, s.text });
                    continue;
                }
            }
            try merged.append(a, s);
        }
        for (merged.items) |s| {
            const marked = options.styled and (s.style != Style.plain or s.link != null);
            if (marked) {
                try w.writeAll("⟨");
                const st = s.style;
                for ([_]struct { on: bool, c: u8 }{
                    .{ .on = st.bold, .c = 'b' },   .{ .on = st.dim, .c = 'd' },
                    .{ .on = st.italic, .c = 'i' }, .{ .on = st.underline, .c = 'u' },
                    .{ .on = st.strike, .c = 's' }, .{ .on = st.fg != .default, .c = 'c' },
                }) |attr| if (attr.on) try w.writeByte(attr.c);
                if (s.link) |url| try w.print("@{s}", .{url});
                try w.writeAll("⟩");
            }
            try w.writeAll(s.text);
            if (marked) try w.writeAll("⟨/⟩");
        }
    }
    try testing.expectEqualStrings(expected, out.written());
}

fn sameLink(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

const plain: Options = .{ .width = 20, .styled = false };

test "paragraphs wrap at the width and are separated by a blank line" {
    try expectLayout("one two three four five six\nseven\n\nnext", plain,
        \\one two three four
        \\five six seven
        \\
        \\next
    );
}

test "a word wider than the line is cut" {
    try expectLayout("abcdefghij", .{ .width = 4, .styled = false }, "abcd\nefgh\nij");
}

test "wide characters wrap by display width" {
    try expectLayout("日本語 日本語", .{ .width = 7, .styled = false }, "日本語\n日本語");
}

test "a hard break ends the line" {
    try expectLayout("a\\\nb  \nc", plain, "a\nb\nc");
}

test "headings keep dim markers and hang their continuation" {
    try expectLayout("# Title\n\n### Third level heading here", .{ .width = 16 },
        \\⟨d⟩# ⟨/⟩⟨bu⟩Title⟨/⟩
        \\
        \\⟨d⟩### ⟨/⟩⟨bd⟩Third level⟨/⟩
        \\    ⟨bd⟩heading here⟨/⟩
    );
}

test "emphasis, strong and code" {
    try expectLayout("*a* **b** `c d`", .{ .width = 20 }, "⟨i⟩a⟨/⟩ ⟨b⟩b⟨/⟩ ⟨d⟩`⟨/⟩⟨c⟩c d⟨/⟩⟨d⟩`⟨/⟩");
}

test "a quote holding a tight list" {
    try expectLayout("> - a\n> - b\n>\n> c", plain, "│ • a\n│ • b\n│\n│ c");
}

test "loose lists and nested bullets" {
    try expectLayout("- a\n\n- b", plain, "• a\n\n• b");
    try expectLayout("- a\n  - b\n    - c\n      - d", plain, "• a\n  ◦ b\n    ▪ c\n      • d");
}

test "ordered numbers align to the widest" {
    try expectLayout("9. nine\n10. ten", plain, " 9. nine\n10. ten");
    try expectLayout("3) x", plain, "3) x");
}

test "list items wrap under their text" {
    try expectLayout("- one two three", .{ .width = 10, .styled = false }, "• one two\n  three");
}

test "code keeps its lines, expands tabs and marks a hard wrap" {
    try expectLayout("```zig\na\tb\n\nccccccccccc\n```", .{ .width = 8, .styled = false },
        \\│ zig
        \\│ a   b
        \\│
        \\│ cccccc
        \\↪ ccccc
    );
}

test "a break spans the room inside a quote" {
    try expectLayout("> ***", .{ .width = 6, .styled = false }, "│ ────");
}

test "ascii glyphs" {
    try expectLayout("> - a\n\n---\n\n    code", .{ .width = 6, .styled = false, .ascii = true }, "| * a\n\n------\n\n| code");
}

test "links: hyperlinks when styled, the target in parentheses otherwise" {
    try expectLayout("[a](u)", .{ .width = 20 }, "⟨uc@u⟩a⟨/⟩");
    try expectLayout("[a](u)", .{ .width = 20, .no_links = true }, "⟨uc⟩a⟨/⟩ ⟨d⟩(u)⟨/⟩");
    try expectLayout("[a b](u) <http://x> <m@x.org>", .{ .width = 40, .styled = false }, "a b (u) http://x m@x.org");
}

test "images show their description and target" {
    try expectLayout("![alt *x*](p.png)", .{ .width = 40, .styled = false }, "[image: alt x] (p.png)");
}

test "raw HTML is dim and control characters are replaced" {
    try expectLayout("a <b>x</b>\x1b[31m", .{ .width = 40 }, "a ⟨d⟩<b>⟨/⟩x⟨d⟩</b>⟨/⟩\u{FFFD}[31m");
    try expectLayout("<div>\n  x\n</div>", .{ .width = 20 }, "⟨d⟩<div>⟨/⟩\n⟨d⟩  x⟨/⟩\n⟨d⟩</div>⟨/⟩");
}
