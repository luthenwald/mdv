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
    task_open: []const u8,
    task_done: []const u8,
    /// A table's corners and junctions: the rows are the top, the line under
    /// the header and the bottom; the columns left, between cells and right.
    box: [3][3][]const u8,
    horizontal: []const u8,
    vertical: []const u8,
    /// Stands in for control characters.
    replacement: []const u8,
};

const unicode_glyphs: Glyphs = .{
    .quote = "│ ",
    .code = "│ ",
    .wrap = "↪ ",
    .rule = "─",
    .bullets = .{ "•", "◦", "▪" },
    .task_open = "☐",
    .task_done = "☑",
    .box = .{ .{ "┌", "┬", "┐" }, .{ "├", "┼", "┤" }, .{ "└", "┴", "┘" } },
    .horizontal = "─",
    .vertical = "│",
    .replacement = "\u{FFFD}",
};

const ascii_glyphs: Glyphs = .{
    .quote = "| ",
    .code = "| ",
    .wrap = "->",
    .rule = "-",
    .bullets = .{ "*", "-", "+" },
    .task_open = "[ ]",
    .task_done = "[x]",
    .box = @splat(@splat("+")),
    .horizontal = "-",
    .vertical = "|",
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

/// A word, a space between words, a place to break between wide
/// characters without a space, or a hard line break.
const Piece = struct {
    kind: enum { text, space, joint, newline },
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
    /// Quotes and lists around the current block.
    depth: usize = 0,

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
        const tag = l.ast.tag(n);
        if (tag == .block_quote or tag == .list) {
            if (l.depth == max_depth) return l.flat(n);
            l.depth += 1;
        }
        defer if (tag == .block_quote or tag == .list) {
            l.depth -= 1;
        };
        switch (tag) {
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
            .thematic_break => try l.line(try l.span(try l.repeat(l.glyphs.rule, l.room()), dim)),
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
            .table => try l.table(n),
            else => unreachable,
        }
    }

    /// A table in light box lines, the header bold. Columns take their
    /// natural width when the table fits; otherwise the widest are capped
    /// and their cells wrap, never narrower than their longest word. When
    /// the words alone do not fit, every body row is listed as
    /// `header: value` lines instead.
    fn table(l: *Layout, n: Index) !void {
        const rows = l.ast.children(n);
        const headers = l.ast.children(rows[0]);
        const columns = headers.len;
        // Every cell laid out on one line first; a cell a short row lacks
        // stays an empty line.
        const cells = try l.arena.alloc([]const Line, rows.len * columns);
        @memset(cells, &.{&.{}});
        const natural = try l.arena.alloc(usize, columns);
        const longest = try l.arena.alloc(usize, columns);
        @memset(natural, 1);
        @memset(longest, 1);
        for (rows, 0..) |row, r| {
            for (l.ast.children(row), 0..) |cell, c| {
                var pieces: std.ArrayList(Piece) = .empty;
                try l.inlines(&pieces, cell, if (r == 0) .{ .bold = true } else .plain, null);
                const lines = try l.wrapInto(pieces.items, std.math.maxInt(u32));
                for (lines) |content| natural[c] = @max(natural[c], spansWidth(content));
                longest[c] = @max(longest[c], longestWord(pieces.items));
                cells[r * columns + c] = lines;
            }
        }

        const borders = 3 * columns + 1;
        const available = l.room();
        var total: usize = 0;
        for (natural) |w| total += w;
        const widths = if (total + borders <= available) natural else blk: {
            // Columns keep room for their longest word, or the rows stack.
            var least: usize = 0;
            for (longest) |w| least += w;
            if (least + borders > available) return l.stacked(n);
            const cap = capFor(natural, longest, available - borders);
            var used: usize = 0;
            const widths = try l.arena.alloc(usize, columns);
            for (natural, longest, widths) |w, floor, *out| {
                out.* = @max(@min(w, cap), floor);
                used += out.*;
            }
            // What is left goes one column each to the capped ones.
            var left = available - borders - used;
            for (natural, widths) |w, *out| {
                if (left == 0) break;
                if (w > out.*) {
                    out.* += 1;
                    left -= 1;
                }
            }
            break :blk widths;
        };

        try l.rule(widths, 0);
        for (rows, 0..) |row, r| {
            if (r == 1) try l.rule(widths, 1);
            const contents = cells[r * columns ..][0..columns];
            var height: usize = 1;
            for (l.ast.children(row), 0..) |cell, c| {
                if (widths[c] < natural[c]) {
                    var pieces: std.ArrayList(Piece) = .empty;
                    try l.inlines(&pieces, cell, if (r == 0) .{ .bold = true } else .plain, null);
                    contents[c] = try l.wrapInto(pieces.items, widths[c]);
                }
                height = @max(height, contents[c].len);
            }
            const bar = l.glyphs.vertical;
            const outer_left = try std.mem.concat(l.arena, u8, &.{ bar, " " });
            const inner = try std.mem.concat(l.arena, u8, &.{ " ", bar, " " });
            const outer_right = try std.mem.concat(l.arena, u8, &.{ " ", bar });
            for (0..height) |k| {
                var spans: std.ArrayList(Span) = .empty;
                try spans.append(l.arena, .{ .text = outer_left, .style = dim });
                for (headers, 0..) |header, c| {
                    if (c > 0) try spans.append(l.arena, .{ .text = inner, .style = dim });
                    const content: []const Span = if (k < contents[c].len) contents[c][k] else &.{};
                    const pad = widths[c] - spansWidth(content);
                    const before: usize = switch (l.ast.alignment(header)) {
                        .none, .left => 0,
                        .right => pad,
                        .center => pad / 2,
                    };
                    if (before > 0) try spans.append(l.arena, .{ .text = try l.filler(before) });
                    try spans.appendSlice(l.arena, content);
                    if (pad > before) try spans.append(l.arena, .{ .text = try l.filler(pad - before) });
                }
                try spans.append(l.arena, .{ .text = outer_right, .style = dim });
                try l.line(spans.items);
            }
        }
        try l.rule(widths, 2);
    }

    /// A box line: `which` 0 above the table, 1 under the header, 2 below.
    fn rule(l: *Layout, widths: []const usize, which: usize) !void {
        const corners = l.glyphs.box[which];
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(l.arena, corners[0]);
        for (widths, 0..) |w, c| {
            if (c > 0) try text.appendSlice(l.arena, corners[1]);
            try text.appendSlice(l.arena, try l.repeat(l.glyphs.horizontal, w + 2));
        }
        try text.appendSlice(l.arena, corners[2]);
        try l.line(try l.span(text.items, dim));
    }

    /// A table too wide for the room: each body row as `header: value`
    /// lines, rows apart by a blank line. Without body rows, the headers.
    fn stacked(l: *Layout, n: Index) !void {
        const rows = l.ast.children(n);
        const headers = l.ast.children(rows[0]);
        if (rows.len == 1) {
            for (headers) |header| try l.paragraph(header, .{ .bold = true });
            return;
        }
        for (rows[1..], 0..) |row, r| {
            if (r > 0) try l.blank();
            const cells = l.ast.children(row);
            for (headers, 0..) |header, c| {
                var pieces: std.ArrayList(Piece) = .empty;
                try l.inlines(&pieces, header, .{ .bold = true }, null);
                try pieces.append(l.arena, .{ .kind = .text, .text = ":", .style = .{ .bold = true } });
                if (c < cells.len) {
                    try pieces.append(l.arena, .{ .kind = .space });
                    try l.inlines(&pieces, cells[c], .plain, null);
                }
                for (try l.wrapInto(pieces.items, l.room())) |content| try l.line(content);
            }
        }
    }

    /// The leaf blocks under `n`, in order and apart by blank lines, without
    /// further gutters or markers: what a container nested deeper than
    /// `max_depth` shows, since its prefixes would fill the line anyway.
    /// Iterative, so no input can nest the layout deeper.
    fn flat(l: *Layout, n: Index) Allocator.Error!void {
        var pending: std.ArrayList(Index) = .empty;
        try pushReversed(l.arena, &pending, l.ast.children(n));
        var first = true;
        while (pending.pop()) |child| switch (l.ast.tag(child)) {
            .block_quote, .list, .list_item => try pushReversed(l.arena, &pending, l.ast.children(child)),
            else => {
                if (!first) try l.blank();
                first = false;
                try l.block(child);
            },
        };
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
            // A task's box takes the bullet's place, or follows the number.
            const box: []const u8 = if (l.ast.task(item)) |done| (if (done) l.glyphs.task_done else l.glyphs.task_open) else "";
            const marker = if (info.ordered) blk: {
                const number = info.start + i;
                const pad = spaces(digits - std.fmt.count("{d}", .{number}));
                const sep = if (box.len > 0) " " else "";
                break :blk try std.fmt.allocPrint(l.arena, "{s}{d}{c} {s}{s}", .{ pad, number, info.marker, box, sep });
            } else try std.fmt.allocPrint(l.arena, "{s} ", .{if (box.len > 0) box else bullet});
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
        for (try l.wrapInto(pieces.items, l.room())) |content| try l.line(content);
    }

    /// The inline content of `n` as pieces. Iterative, with a stack of the
    /// open emphasis and links, so deep nesting cannot exhaust the stack.
    fn inlines(l: *Layout, out: *std.ArrayList(Piece), n: Index, style: Style, link: ?[]const u8) Allocator.Error!void {
        const ast = l.ast;
        const Frame = struct {
            children: []const Index,
            next: usize = 0,
            style: Style,
            link: ?[]const u8,
            /// A link whose target follows its text, in the outer style.
            target: ?struct { destination: []const u8, style: Style, link: ?[]const u8 } = null,
        };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(l.arena, .{ .children = ast.children(n), .style = style, .link = link });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next == top.children.len) {
                const done = stack.pop().?;
                if (done.target) |t| try l.target(out, t.destination, t.style, t.link);
                continue;
            }
            const child = top.children[top.next];
            top.next += 1;
            const outer = top.style;
            const outer_link = top.link;
            switch (ast.tag(child)) {
                .text => try l.words(out, ast.content(child), outer, outer_link),
                .soft_break => try out.append(l.arena, .{ .kind = .space, .style = outer, .link = outer_link }),
                .hard_break => try out.append(l.arena, .{ .kind = .newline }),
                .code_span => {
                    // One word: a code span breaks only when it is wider than a line.
                    var tick = outer;
                    tick.dim = true;
                    var text = outer;
                    text.fg = accent;
                    const content = try l.clean(ast.content(child));
                    try out.appendSlice(l.arena, &.{
                        .{ .kind = .text, .text = "`", .style = tick, .link = outer_link },
                        .{ .kind = .text, .text = try l.spacedTabs(content), .style = text, .link = outer_link },
                        .{ .kind = .text, .text = "`", .style = tick, .link = outer_link },
                    });
                },
                .html_inline => {
                    var raw = outer;
                    raw.dim = true;
                    try l.words(out, ast.content(child), raw, outer_link);
                },
                .emphasis, .strong, .strikethrough => |tag| {
                    var inner = outer;
                    switch (tag) {
                        .emphasis => inner.italic = true,
                        .strong => inner.bold = true,
                        else => inner.strike = true,
                    }
                    try stack.append(l.arena, .{ .children = ast.children(child), .style = inner, .link = outer_link });
                },
                .link => {
                    const destination = ast.string(ast.link(child).destination);
                    const hyper = l.options.styled and !l.options.no_links and destination.len > 0;
                    var inner = outer;
                    inner.underline = true;
                    inner.fg = accent;
                    try stack.append(l.arena, .{
                        .children = ast.children(child),
                        .style = inner,
                        .link = if (hyper) destination else outer_link,
                        .target = if (!hyper and destination.len > 0 and !l.isAutolink(child, destination))
                            .{ .destination = destination, .style = outer, .link = outer_link }
                        else
                            null,
                    });
                },
                .image => {
                    var alt: std.ArrayList(u8) = .empty;
                    try alt.appendSlice(l.arena, "[image: ");
                    try l.plainText(&alt, child);
                    try alt.append(l.arena, ']');
                    try l.words(out, alt.items, outer, outer_link);
                    const destination = ast.string(ast.link(child).destination);
                    if (destination.len > 0) try l.target(out, destination, outer, outer_link);
                },
                else => unreachable,
            }
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

    /// The text under `n`, without markup, for an image description.
    fn plainText(l: *Layout, out: *std.ArrayList(u8), n: Index) Allocator.Error!void {
        var pending: std.ArrayList(Index) = .empty;
        try pushReversed(l.arena, &pending, l.ast.children(n));
        while (pending.pop()) |child| switch (l.ast.tag(child)) {
            .text, .code_span => try out.appendSlice(l.arena, l.ast.content(child)),
            .soft_break, .hard_break => try out.append(l.arena, ' '),
            .html_inline => {},
            else => try pushReversed(l.arena, &pending, l.ast.children(child)),
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
            var start = i;
            var previous: u21 = 0;
            while (i < text.len and !isSpace(text[i])) {
                // Invalid UTF-8 goes a byte at a time, as a replacement, so
                // a space after a broken sequence still separates words.
                const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const decoded: ?u21 = if (i + n <= text.len) std.unicode.utf8Decode(text[i..][0..n]) catch null else null;
                const len = if (decoded != null) n else 1;
                const c = decoded orelse 0xFFFD;
                if (i > start and canBreakBetween(previous, c)) {
                    try out.append(l.arena, .{ .kind = .text, .text = text[start..i], .style = style, .link = link });
                    try out.append(l.arena, .{ .kind = .joint, .style = style, .link = link });
                    start = i;
                }
                previous = c;
                i = @min(text.len, i + len);
            }
            try out.append(l.arena, .{ .kind = .text, .text = text[start..i], .style = style, .link = link });
        }
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    /// Greedy wrapping on display width, to the content of lines at most
    /// `avail` wide. Words that do not fit go to the next line; a word wider
    /// than a line is cut. At least one line, even an empty one.
    fn wrapInto(l: *Layout, pieces: []const Piece, avail: usize) ![]const Line {
        var out: std.ArrayList(Line) = .empty;
        var current: std.ArrayList(Span) = .empty;
        var col: usize = 0;
        // The space or joint before the next word, if the line goes on.
        var space: ?Piece = null;
        var i: usize = 0;
        while (i < pieces.len) {
            const p = pieces[i];
            switch (p.kind) {
                .space => {
                    if (col > 0) space = p;
                    i += 1;
                },
                .joint => {
                    if (col > 0 and space == null) space = p;
                    i += 1;
                },
                .newline => {
                    try out.append(l.arena, try current.toOwnedSlice(l.arena));
                    col = 0;
                    space = null;
                    i += 1;
                },
                .text => {
                    var end = i;
                    var w: usize = 0;
                    while (end < pieces.len and pieces[end].kind == .text) : (end += 1) w += width.ofString(pieces[end].text);
                    const gap: usize = if (space) |s| @intFromBool(s.kind == .space) else 0;
                    if (col > 0 and col + gap + w > avail) {
                        try out.append(l.arena, try current.toOwnedSlice(l.arena));
                        col = 0;
                    } else if (space != null and space.?.kind == .space) {
                        try current.append(l.arena, .{ .text = " ", .style = space.?.style, .link = space.?.link });
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
                                try out.append(l.arena, try current.toOwnedSlice(l.arena));
                                col = 0;
                                continue;
                            }
                            try current.append(l.arena, .{ .text = rest[0..len], .style = q.style, .link = q.link });
                            try out.append(l.arena, try current.toOwnedSlice(l.arena));
                            col = 0;
                            rest = rest[len..];
                        }
                    }
                    i = end;
                },
            }
        }
        if (current.items.len > 0 or out.items.len == 0) try out.append(l.arena, try current.toOwnedSlice(l.arena));
        return out.items;
    }

    // Text.
    /// The text with whatever could act on the terminal replaced: C0
    /// controls but tab and line feed, DEL, C1 controls, and bytes that are
    /// not UTF-8, one mark each, since two such bytes from neighbouring text
    /// could otherwise meet as a C1 control.
    fn clean(l: *Layout, s: []const u8) ![]const u8 {
        var i: usize = 0;
        const dirty = while (i < s.len) {
            const at = codeAt(s, i);
            if (!at.safe) break true;
            i += at.len;
        } else false;
        if (!dirty) return s;
        var out: std.ArrayList(u8) = try .initCapacity(l.arena, s.len);
        i = 0;
        while (i < s.len) {
            const at = codeAt(s, i);
            try out.appendSlice(l.arena, if (at.safe) s[i..][0..at.len] else l.glyphs.replacement);
            i += at.len;
        }
        return out.items;
    }

    /// The code point at `i`: its length, or 1 for a byte that is not
    /// UTF-8, and whether it may reach the terminal.
    fn codeAt(s: []const u8, i: usize) struct { len: usize, safe: bool } {
        const c = s[i];
        if (c < 0x80) return .{ .len = 1, .safe = (c >= 0x20 or c == '\t' or c == '\n') and c != 0x7f };
        const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .len = 1, .safe = false };
        if (i + n > s.len) return .{ .len = 1, .safe = false };
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .len = 1, .safe = false };
        return .{ .len = n, .safe = cp < 0x80 or cp > 0x9f };
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

    fn filler(l: *Layout, n: usize) ![]const u8 {
        if (n <= blanks.len) return blanks[0..n];
        const out = try l.arena.alloc(u8, n);
        @memset(out, ' ');
        return out;
    }

    /// `glyph` `n` times.
    fn repeat(l: *Layout, glyph: []const u8, n: usize) ![]const u8 {
        const out = try l.arena.alloc(u8, glyph.len * n);
        for (0..n) |i| @memcpy(out[i * glyph.len ..][0..glyph.len], glyph);
        return out;
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

/// The largest cap on column widths that fits them in `room`, each column
/// at least its `floor`.
fn capFor(natural: []const usize, floor: []const usize, room: usize) usize {
    var low: usize = 0;
    var high: usize = std.mem.max(usize, natural);
    while (low < high) {
        const mid = high - (high - low) / 2;
        var total: usize = 0;
        for (natural, floor) |w, f| total += @max(@min(w, mid), f);
        if (total <= room) low = mid else high = mid - 1;
    }
    return low;
}

/// The widest run of text pieces, which wrapping never breaks unless it must.
fn longestWord(pieces: []const Piece) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (pieces) |p| {
        run = if (p.kind == .text) run + width.ofString(p.text) else 0;
        longest = @max(longest, run);
    }
    return longest;
}

/// Whether a line may break between `a` and `b` inside a run without
/// spaces: next to a wide character, as between ideographs, but not inside
/// a joined emoji or before a combining mark, not before closing
/// punctuation or a small kana, and not after opening punctuation.
fn canBreakBetween(a: u21, b: u21) bool {
    if (width.ofCodepoint(a) != 2 and width.ofCodepoint(b) != 2) return false;
    if (width.ofCodepoint(b) == 0 or a == 0x200D) return false;
    if (b >= 0x1F3FB and b <= 0x1F3FF) return false; // skin tones
    if (std.mem.indexOfScalar(u21, no_line_start, b) != null) return false;
    return std.mem.indexOfScalar(u21, no_line_end, a) == null;
}

const no_line_start: []const u21 = &.{
    '、',
    '。',
    '，',
    '．',
    '：',
    '；',
    '？',
    '！',
    '）',
    '］',
    '｝',
    '」',
    '』',
    '】',
    '〕',
    '〉',
    '》',
    '〙',
    '〗',
    '〟',
    '・',
    'ー',
    'ゝ',
    'ゞ',
    'ヽ',
    'ヾ',
    '々',
    '〜',
    'ぁ',
    'ぃ',
    'ぅ',
    'ぇ',
    'ぉ',
    'っ',
    'ゃ',
    'ゅ',
    'ょ',
    'ゎ',
    'ゕ',
    'ゖ',
    'ァ',
    'ィ',
    'ゥ',
    'ェ',
    'ォ',
    'ッ',
    'ャ',
    'ュ',
    'ョ',
    'ヮ',
    'ヵ',
    'ヶ',
    ')',
    ']',
    '}',
    ',',
    '.',
    ':',
    ';',
    '?',
    '!',
};

const no_line_end: []const u21 = &.{ '（', '［', '｛', '「', '『', '【', '〔', '〈', '《', '〘', '〖', '〝', '(', '[', '{' };

/// Quotes and lists nested deeper than this lay out flat.
const max_depth = 32;

fn pushReversed(arena: Allocator, stack: *std.ArrayList(Index), nodes: []const Index) !void {
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        try stack.append(arena, nodes[i]);
    }
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

const blanks: [256]u8 = @splat(' ');

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
    const lines = try document(a, try md.parse(a, markdown, .{}), options);
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

test "bytes that are not UTF-8 are replaced, so none can meet as a C1 control" {
    try expectLayout("x\xc2*\x9c*y \xff \xed\xa0\x80 \xc0\xaf", plain, "x\u{FFFD}\u{FFFD}y \u{FFFD} \u{FFFD}\u{FFFD}\u{FFFD} \u{FFFD}\u{FFFD}");
}

test "lines break between wide characters, minding punctuation" {
    try expectLayout("日本語のテキスト。「引用」です", .{ .width = 10, .styled = false }, "日本語のテ\nキスト。\n「引用」で\nす");
    try expectLayout("text 日本 more", .{ .width = 8, .styled = false }, "text 日\n本 more");
    try expectLayout("🦎🦎🦎", .{ .width = 4, .styled = false }, "🦎🦎\n🦎");
    try expectLayout("日\xe6\x97", .{ .width = 4, .styled = false }, "日\u{FFFD}\u{FFFD}");
    try expectLayout("a\xc9\tb", .{ .width = 4, .styled = false }, "a\u{FFFD} b");
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
    try expectLayout("~~gone~~", .{ .width = 20 }, "⟨s⟩gone⟨/⟩");
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

test "task items: the box replaces the bullet and follows the number" {
    try expectLayout("- plain\n- [ ] to do\n- [x] done and wrapped", .{ .width = 12, .styled = false },
        \\• plain
        \\☐ to do
        \\☑ done and
        \\  wrapped
    );
    try expectLayout("1. [x] numbered", plain, "1. ☑ numbered");
    try expectLayout("- [ ] a b", .{ .width = 6, .styled = false, .ascii = true }, "[ ] a\n    b");
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

test "a table at its natural width, cells aligned" {
    try expectLayout("| a | bb | c |\n|:-|-:|:-:|\n| ccc | d | eee |", plain,
        \\┌─────┬────┬─────┐
        \\│ a   │ bb │  c  │
        \\├─────┼────┼─────┤
        \\│ ccc │  d │ eee │
        \\└─────┴────┴─────┘
    );
    try expectLayout("| 日本 | x |\n|--|--|\n| a | b |", plain,
        \\┌──────┬───┐
        \\│ 日本 │ x │
        \\├──────┼───┤
        \\│ a    │ b │
        \\└──────┴───┘
    );
}

test "a table too wide wraps its widest cells" {
    try expectLayout("| one two three | x |\n|-|-|\n| a | b |", .{ .width = 20, .styled = false },
        \\┌──────────────┬───┐
        \\│ one two      │ x │
        \\│ three        │   │
        \\├──────────────┼───┤
        \\│ a            │ b │
        \\└──────────────┴───┘
    );
}

test "a table whose words do not fit lists its rows" {
    try expectLayout("| name | value |\n|-|-|\n| a | b |\n| c | d d d d |", .{ .width = 12, .styled = false },
        \\name: a
        \\value: b
        \\
        \\name: c
        \\value: d d d
        \\d
    );
    try expectLayout("| name | value |\n|-|-|", .{ .width = 8 }, "⟨b⟩name⟨/⟩\n⟨b⟩value⟨/⟩");
}

test "a short row leaves its missing cells empty" {
    try expectLayout("| a | b |\n|-|-:|\n| 1 |\n| 2 | 3 |", plain,
        \\┌───┬───┐
        \\│ a │ b │
        \\├───┼───┤
        \\│ 1 │   │
        \\│ 2 │ 3 │
        \\└───┴───┘
    );
    try expectLayout("| name | value |\n|-|-|\n| a |", .{ .width = 10, .styled = false }, "name: a\nvalue:");
}

test "a table's lines are dim and its header bold" {
    try expectLayout("a|b\n-|-", .{ .width = 20 },
        \\⟨d⟩┌───┬───┐⟨/⟩
        \\⟨d⟩│ ⟨/⟩⟨b⟩a⟨/⟩⟨d⟩ │ ⟨/⟩⟨b⟩b⟨/⟩⟨d⟩ │⟨/⟩
        \\⟨d⟩└───┴───┘⟨/⟩
    );
    try expectLayout("a | b\n-|-\n1 | 2", .{ .width = 20, .styled = false, .ascii = true },
        \\+---+---+
        \\| a | b |
        \\+---+---+
        \\| 1 | 2 |
        \\+---+---+
    );
}

test "containers deeper than the limit lay out flat" {
    const quotes: [2 * (max_depth + 2)]u8 = @bitCast(@as([max_depth + 2][2]u8, @splat("> ".*)));
    const gutters: [2 * max_depth]u8 = @bitCast(@as([max_depth][2]u8, @splat("| ".*)));
    try expectLayout(quotes ++ "deep\n>\n> back", .{ .width = 80, .styled = false, .ascii = true }, gutters ++ "deep\n|\n| back");
}

test "deep inline nesting needs no deep stack" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    for (0..20000) |_| try source.appendSlice(a, "*a **a ");
    try source.append(a, 'b');
    for (0..20000) |_| try source.appendSlice(a, " a** a*");
    const lines = try document(a, try md.parse(a, source.items, .{}), .{ .width = 80 });
    try testing.expect(lines.len > 1000);
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

test "any input lays out without sending control characters" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const source = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const ast = try md.parse(a, source, .{});
            for ([_]u16{ 1, 7, 30, 80 }) |w| for ([_]bool{ false, true }) |ascii| {
                const lines = try document(a, ast, .{ .width = w, .ascii = ascii });
                var out: std.Io.Writer.Allocating = .init(a);
                const emitter: emit.Emitter = .{ .styled = true, .colors = true };
                for (lines) |row| try emitter.line(&out.writer, row);
                try expectOnlyOurEscapes(out.written());
            };
        }
    }.one, .{ .corpus = md.fuzz_corpus });
}

/// No control characters but line feeds and the escapes emit makes: SGR
/// sequences and OSC 8 hyperlinks.
fn expectOnlyOurEscapes(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == 0x1b) {
            if (std.mem.startsWith(u8, bytes[i..], "\x1b[")) {
                const end = std.mem.indexOfScalarPos(u8, bytes, i, 'm') orelse return error.UnendedEscape;
                for (bytes[i + 2 .. end]) |p| if (!std.ascii.isDigit(p) and p != ';') return error.ForeignEscape;
                i = end;
            } else if (std.mem.startsWith(u8, bytes[i..], "\x1b]8;;")) {
                const end = std.mem.indexOfPos(u8, bytes, i + 5, "\x1b\\") orelse return error.UnendedEscape;
                for (bytes[i + 5 .. end]) |p| if (p <= ' ' or p >= 0x7f) return error.ForeignEscape;
                i = end + 1;
            } else return error.ForeignEscape;
            continue;
        }
        if ((c < 0x20 and c != '\n') or c == 0x7f) return error.ControlCharacter;
        if (c == 0xc2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9f) return error.ControlCharacter;
    }
}
