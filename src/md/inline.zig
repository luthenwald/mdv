//! Inline structure: the content of paragraphs and headings to inline nodes.
//!
//! A port of the inline parser of commonmark.js. One pass over the content
//! builds a list of nodes and two stacks: delimiter runs of `*` and `_`, and
//! the brackets that may open links and images. A `]` that completes a link
//! moves the nodes after its bracket into the link; emphasis is resolved over
//! the delimiters inside it at once, and over the rest at the end.
//!
//! The nodes are kept as linked lists while parsing, so that a run of them
//! moves into a new parent in constant time, and are written into the tree
//! once the content is done, each parent's children as one run in `extra`.
//! Unclosed constructs are remembered (backtick runs, comments, titles), so
//! that every scan for a closer is done at most once and parsing stays linear.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Range = Ast.Range;
const Index = Ast.Index;
const Tag = Ast.Node.Tag;
const scan = @import("scan.zig");
const entities = @import("entities.zig");
const unicode = @import("unicode.zig");

/// The parts of the tree the inline pass appends to.
pub const Context = struct {
    arena: Allocator,
    nodes: *std.MultiArrayList(Ast.Node),
    extra: *std.ArrayList(Index),
    text: *std.ArrayList(u8),
    links: *std.ArrayList(Ast.Link),
    /// Normalized labels to their links; see `references`.
    refs: *const References = &.empty,
    /// Strikethrough between one or two tildes.
    gfm: bool = true,
};

/// Link reference definitions by normalized label.
pub const References = std.StringHashMapUnmanaged(Index);

/// Collects the definitions into `refs`, the first of each label winning,
/// with their destinations and titles decoded into `links`.
pub fn references(c: Context, definitions: []const Ast.Definition, refs: *References) Allocator.Error!void {
    for (definitions) |d| {
        const label = try normalizeLabel(c.arena, slice(c, d.label));
        const entry = try refs.getOrPut(c.arena, label);
        if (entry.found_existing) continue;
        entry.value_ptr.* = @intCast(c.links.items.len);
        try c.links.append(c.arena, .{
            .destination = try decode(c, d.destination),
            .title = try decode(c, d.title),
        });
    }
}

/// A label for matching: case folded, with runs of whitespace as one space
/// and none at either end.
pub fn normalizeLabel(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var space = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (scan.isWhitespace(c)) {
            space = true;
            i += 1;
            continue;
        }
        if (space and out.items.len > 0) try out.append(arena, ' ');
        space = false;
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const code: ?u21 = if (i + len <= raw.len) std.unicode.utf8Decode(raw[i..][0..len]) catch null else null;
        if (code) |cp| {
            if (unicode.fold(cp)) |folded| {
                try out.appendSlice(arena, folded);
                i += len;
                continue;
            }
            try out.appendSlice(arena, raw[i..][0..len]);
            i += len;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

/// The range with backslash escapes and character references resolved. The
/// range itself when there is nothing to resolve, else new text.
pub fn decode(c: Context, r: Range) Allocator.Error!Range {
    if (std.mem.indexOfAny(u8, slice(c, r), "\\&") == null) return r;
    const start: u32 = @intCast(c.text.items.len);
    const end = r.start + r.len;
    var i: usize = r.start;
    var buf: [4]u8 = undefined;
    while (i < end) {
        const ch = c.text.items[i];
        if (ch == '\\' and i + 1 < end and scan.isEscapable(c.text.items[i + 1])) {
            try c.text.append(c.arena, c.text.items[i + 1]);
            i += 2;
        } else if (ch == '&') {
            if (entities.reference(c.text.items[0..end], i, &buf)) |ref| {
                try c.text.appendSlice(c.arena, ref.value);
                i = ref.end;
            } else {
                try c.text.append(c.arena, ch);
                i += 1;
            }
        } else {
            try c.text.append(c.arena, ch);
            i += 1;
        }
    }
    return .{ .start = start, .len = @as(u32, @intCast(c.text.items.len)) - start };
}

fn slice(c: Context, r: Range) []const u8 {
    return r.of(u8, c.text.items);
}

/// Parses the inline content at `content` in `text` and returns the run of
/// its top-level nodes in `extra`.
pub fn parse(c: Context, content: Range) Allocator.Error!Range {
    var p: Parser = .{ .c = c, .start = content.start, .pos = content.start, .end = content.start + content.len };
    while (p.pos < p.end) try p.step();
    try p.processEmphasis(none, &p.top);
    return p.emit();
}

const none = std.math.maxInt(u32);

/// A doubly linked list of items.
const Chain = struct {
    first: u32 = none,
    last: u32 = none,
};

const Item = struct {
    tag: Tag,
    data: Ast.Node.Data,
    prev: u32 = none,
    next: u32 = none,
    children: Chain = .{},
};

/// A run of `*` or `_` that may open or close emphasis.
const Delimiter = struct {
    char: u8,
    /// Delimiters left in the run.
    count: u32,
    /// The length of the run as written, for the rule of three.
    original: u32,
    item: u32,
    can_open: bool,
    can_close: bool,
    prev: u32 = none,
    next: u32 = none,
};

/// A `[` or `![` that may open a link or an image.
const Bracket = struct {
    item: u32,
    /// The top of the delimiter stack when the bracket was pushed.
    delimiter: u32,
    /// Where the link text begins, after the bracket.
    label_start: u32,
    image: bool,
    /// Another bracket came after this one, so its text cannot be a label.
    bracket_after: bool = false,
};

const Class = enum { whitespace, punctuation, other };

const Parser = struct {
    c: Context,
    start: u32,
    pos: u32,
    end: u32,

    items: std.ArrayList(Item) = .empty,
    top: Chain = .{},

    delimiters: std.ArrayList(Delimiter) = .empty,
    delimiter_top: u32 = none,
    brackets: std.ArrayList(Bracket) = .empty,
    /// Link brackets below this depth are inactive: no links in links.
    link_floor: usize = 0,

    /// Per run length, where the last backtick run of that length seen so
    /// far starts; complete once a scan has reached the end.
    backtick_runs: std.ArrayList(u32) = .empty,
    backticks_scanned: bool = false,
    /// Openers whose closers are known not to come.
    no_comment_end: bool = false,
    no_instruction_end: bool = false,
    no_declaration_end: bool = false,
    no_cdata_end: bool = false,
    no_title_end: [2]bool = .{ false, false },

    fn src(p: *const Parser) []const u8 {
        return p.c.text.items[0..p.end];
    }

    fn at(p: *const Parser, i: usize) u8 {
        return if (i < p.end) p.c.text.items[i] else 0;
    }

    fn step(p: *Parser) !void {
        switch (p.at(p.pos)) {
            '\n' => try p.newline(),
            '\\' => try p.backslash(),
            '`' => try p.backticks(),
            '*', '_' => try p.delimiterRun(),
            '~' => {
                const len = p.runLength(p.pos, '~');
                if (p.c.gfm and len <= 2) return p.delimiterRun();
                _ = try p.text(p.pos, len);
                p.pos += len;
            },
            '[' => {
                try p.pushBracket(try p.text(p.pos, 1), p.pos + 1, false);
                p.pos += 1;
            },
            '!' => if (p.at(p.pos + 1) == '[') {
                try p.pushBracket(try p.text(p.pos, 2), p.pos + 2, true);
                p.pos += 2;
            } else {
                _ = try p.text(p.pos, 1);
                p.pos += 1;
            },
            ']' => try p.closeBracket(),
            '<' => try p.angle(),
            '&' => try p.reference(),
            else => {
                var i = p.pos + 1;
                while (i < p.end and !isSpecial(p.c.text.items[i])) i += 1;
                _ = try p.text(p.pos, i - p.pos);
                p.pos = i;
            },
        }
    }

    fn isSpecial(c: u8) bool {
        return switch (c) {
            '\n', '\\', '`', '*', '_', '~', '[', ']', '!', '<', '&' => true,
            else => false,
        };
    }

    // Items.

    /// A new item outside every chain.
    fn newItem(p: *Parser, tag: Tag, data: Ast.Node.Data) !u32 {
        const i: u32 = @intCast(p.items.items.len);
        try p.items.append(p.c.arena, .{ .tag = tag, .data = data });
        return i;
    }

    /// A new item at the end of `chain`.
    fn add(p: *Parser, chain: *Chain, tag: Tag, data: Ast.Node.Data) !u32 {
        const i = try p.newItem(tag, data);
        p.items.items[i].prev = chain.last;
        if (chain.last != none) p.items.items[chain.last].next = i else chain.first = i;
        chain.last = i;
        return i;
    }

    fn text(p: *Parser, start: u32, len: u32) !u32 {
        return p.add(&p.top, .text, .{ .literal = .{ .start = start, .len = len } });
    }

    /// New text, copied into the buffer.
    fn newText(p: *Parser, bytes: []const u8) !u32 {
        const start: u32 = @intCast(p.c.text.items.len);
        try p.c.text.appendSlice(p.c.arena, bytes);
        return p.text(start, @intCast(bytes.len));
    }

    fn unlink(p: *Parser, chain: *Chain, i: u32) void {
        const item = p.items.items[i];
        if (item.prev != none) p.items.items[item.prev].next = item.next else chain.first = item.next;
        if (item.next != none) p.items.items[item.next].prev = item.prev else chain.last = item.prev;
    }

    /// Takes the items after `after` through `through` out of `chain`, as a chain of their own.
    fn cut(p: *Parser, chain: *Chain, after: u32, through: u32) Chain {
        const first = p.items.items[after].next;
        if (first == none or after == through) return .{};
        const rest = p.items.items[through].next;
        p.items.items[after].next = rest;
        if (rest != none) p.items.items[rest].prev = after else chain.last = after;
        p.items.items[first].prev = none;
        p.items.items[through].next = none;
        return .{ .first = first, .last = through };
    }

    fn insertAfter(p: *Parser, chain: *Chain, after: u32, i: u32) void {
        const next = p.items.items[after].next;
        p.items.items[i].prev = after;
        p.items.items[i].next = next;
        p.items.items[after].next = i;
        if (next != none) p.items.items[next].prev = i else chain.last = i;
    }

    fn literal(p: *Parser, i: u32) *Range {
        return &p.items.items[i].data.literal;
    }

    // Line breaks, escapes, code spans and references.

    fn newline(p: *Parser) !void {
        p.pos += 1;
        var tag: Tag = .soft_break;
        const last = p.top.last;
        if (last != none and p.items.items[last].tag == .text) {
            const lit = p.literal(last);
            const s = slice(p.c, lit.*);
            if (s.len > 0 and s[s.len - 1] == ' ') {
                if (s.len >= 2 and s[s.len - 2] == ' ') tag = .hard_break;
                while (lit.len > 0 and p.c.text.items[lit.start + lit.len - 1] == ' ') lit.len -= 1;
            }
        }
        _ = try p.add(&p.top, tag, .{ .none = {} });
        p.skipSpaces();
    }

    /// The spaces that begin a line are not part of its content.
    fn skipSpaces(p: *Parser) void {
        while (p.at(p.pos) == ' ') p.pos += 1;
    }

    fn backslash(p: *Parser) !void {
        const next = p.at(p.pos + 1);
        if (next == '\n') {
            p.pos += 2;
            _ = try p.add(&p.top, .hard_break, .{ .none = {} });
            p.skipSpaces();
        } else if (p.pos + 1 < p.end and scan.isEscapable(next)) {
            _ = try p.text(p.pos + 1, 1);
            p.pos += 2;
        } else {
            _ = try p.text(p.pos, 1);
            p.pos += 1;
        }
    }

    fn runLength(p: *const Parser, i: u32, c: u8) u32 {
        var j = i;
        while (p.at(j) == c) j += 1;
        return j - i;
    }

    fn backticks(p: *Parser) !void {
        const len = p.runLength(p.pos, '`');
        const open = p.pos;
        p.pos += len;
        const close = try p.closingBackticks(open, len) orelse {
            _ = try p.text(open, len);
            return;
        };
        var r: Range = .{ .start = p.pos, .len = close - p.pos };
        p.pos = close + len;
        // Line endings become spaces.
        if (std.mem.indexOfScalar(u8, slice(p.c, r), '\n') != null) {
            const start: u32 = @intCast(p.c.text.items.len);
            try p.c.text.ensureUnusedCapacity(p.c.arena, r.len);
            for (r.start..r.start + r.len) |i| {
                const ch = p.c.text.items[i];
                p.c.text.appendAssumeCapacity(if (ch == '\n') ' ' else ch);
            }
            r.start = start;
        }
        // One space comes off each end, unless the span is only spaces.
        const s = slice(p.c, r);
        if (s.len >= 2 and s[0] == ' ' and s[s.len - 1] == ' ' and std.mem.indexOfNone(u8, s, " ") != null) {
            r.start += 1;
            r.len -= 2;
        }
        _ = try p.add(&p.top, .code_span, .{ .literal = r });
    }

    /// Where a run of exactly `len` backticks after `open` starts, if one does.
    fn closingBackticks(p: *Parser, open: u32, len: u32) !?u32 {
        const runs = &p.backtick_runs;
        if (p.backticks_scanned) {
            if (len >= runs.items.len or runs.items[len] == none or runs.items[len] <= open) return null;
        }
        var i = open + len;
        while (std.mem.indexOfScalarPos(u8, p.src(), i, '`')) |run| {
            const n = p.runLength(@intCast(run), '`');
            if (!p.backticks_scanned) {
                if (n >= runs.items.len) try runs.appendNTimes(p.c.arena, none, n + 1 - runs.items.len);
                runs.items[n] = @intCast(run);
            }
            if (n == len) return @intCast(run);
            i = @intCast(run + n);
        }
        p.backticks_scanned = true;
        return null;
    }

    fn reference(p: *Parser) !void {
        var buf: [4]u8 = undefined;
        if (entities.reference(p.src(), p.pos, &buf)) |ref| {
            _ = try p.newText(ref.value);
            p.pos = @intCast(ref.end);
        } else {
            _ = try p.text(p.pos, 1);
            p.pos += 1;
        }
    }

    // Autolinks and raw HTML.

    fn angle(p: *Parser) !void {
        const s = p.src();
        if (scan.autolink(s, p.pos)) |a| {
            const raw: Range = .{ .start = p.pos + 1, .len = @intCast(a.end - p.pos - 2) };
            var destination = raw;
            if (a.email) {
                const t = p.c.text;
                destination.start = @intCast(t.items.len);
                try t.ensureUnusedCapacity(p.c.arena, 7 + raw.len);
                t.appendSliceAssumeCapacity("mailto:");
                t.appendSliceAssumeCapacity(t.items[raw.start..][0..raw.len]);
                destination.len += 7;
            }
            const link: u32 = @intCast(p.c.links.items.len);
            try p.c.links.append(p.c.arena, .{ .destination = destination });
            const item = try p.add(&p.top, .link, .{ .parent = .{ .index = link } });
            var children: Chain = .{};
            _ = try p.add(&children, .text, .{ .literal = raw });
            p.items.items[item].children = children;
            p.pos = @intCast(a.end);
        } else if (p.rawHtml()) |end| {
            _ = try p.add(&p.top, .html_inline, .{ .literal = .{ .start = p.pos, .len = end - p.pos } });
            p.pos = end;
        } else {
            _ = try p.text(p.pos, 1);
            p.pos += 1;
        }
    }

    /// The end of an inline HTML tag, comment, processing instruction,
    /// declaration or CDATA section at the current `<`.
    fn rawHtml(p: *Parser) ?u32 {
        const s = p.src();
        const i = p.pos;
        if (scan.openTag(s, i) orelse scan.closingTag(s, i)) |end| return @intCast(end);
        if (std.mem.startsWith(u8, s[i..], "<!--")) {
            if (std.mem.startsWith(u8, s[i..], "<!-->")) return i + 5;
            if (std.mem.startsWith(u8, s[i..], "<!--->")) return i + 6;
            return findCloser(s, i + 4, "-->", &p.no_comment_end);
        }
        if (std.mem.startsWith(u8, s[i..], "<?")) return findCloser(s, i + 2, "?>", &p.no_instruction_end);
        if (std.mem.startsWith(u8, s[i..], "<![CDATA[")) return findCloser(s, i + 9, "]]>", &p.no_cdata_end);
        if (i + 2 < s.len and s[i + 1] == '!' and std.ascii.isAlphabetic(s[i + 2]))
            return findCloser(s, i + 2, ">", &p.no_declaration_end);
        return null;
    }

    /// Past the first `needle` from `from`. Once one is missing, it is
    /// missing for every later opener too.
    fn findCloser(s: []const u8, from: usize, needle: []const u8, missing: *bool) ?u32 {
        if (missing.*) return null;
        const found = std.mem.indexOfPos(u8, s, from, needle) orelse {
            missing.* = true;
            return null;
        };
        return @intCast(found + needle.len);
    }

    // Emphasis.

    fn classify(c: ?u21) Class {
        const cp = c orelse return .other;
        if (unicode.isWhitespace(cp)) return .whitespace;
        if (unicode.isPunctuation(cp)) return .punctuation;
        return .other;
    }

    /// The code point that ends before `i`; a line ending at the start.
    fn charBefore(p: *const Parser, i: u32) ?u21 {
        if (i <= p.start) return '\n';
        var j = i - 1;
        while (j > p.start and i - j < 4 and p.c.text.items[j] & 0xC0 == 0x80) j -= 1;
        // Invalid UTF-8 has no code point here.
        const len = std.unicode.utf8ByteSequenceLength(p.c.text.items[j]) catch return null;
        if (j + len != i) return null;
        return std.unicode.utf8Decode(p.c.text.items[j..i]) catch null;
    }

    /// The code point that starts at `i`; a line ending at the end.
    fn charAfter(p: *const Parser, i: u32) ?u21 {
        if (i >= p.end) return '\n';
        const len = std.unicode.utf8ByteSequenceLength(p.c.text.items[i]) catch return null;
        if (i + len > p.end) return null;
        return std.unicode.utf8Decode(p.c.text.items[i..][0..len]) catch null;
    }

    fn delimiterRun(p: *Parser) !void {
        const char = p.at(p.pos);
        const len = p.runLength(p.pos, char);
        const b = classify(p.charBefore(p.pos));
        const a = classify(p.charAfter(p.pos + len));
        const left = a != .whitespace and (a != .punctuation or b != .other);
        const right = b != .whitespace and (b != .punctuation or a != .other);
        const can_open = if (char == '_') left and (!right or b == .punctuation) else left;
        const can_close = if (char == '_') right and (!left or a == .punctuation) else right;
        const item = try p.text(p.pos, len);
        p.pos += len;
        if (!can_open and !can_close) return;
        const i: u32 = @intCast(p.delimiters.items.len);
        try p.delimiters.append(p.c.arena, .{
            .char = char,
            .count = len,
            .original = len,
            .item = item,
            .can_open = can_open,
            .can_close = can_close,
            .prev = p.delimiter_top,
        });
        if (p.delimiter_top != none) p.delimiters.items[p.delimiter_top].next = i;
        p.delimiter_top = i;
    }

    fn removeDelimiter(p: *Parser, i: u32) void {
        const d = p.delimiters.items[i];
        if (d.prev != none) p.delimiters.items[d.prev].next = d.next;
        if (d.next != none) p.delimiters.items[d.next].prev = d.prev else p.delimiter_top = d.prev;
    }

    /// Resolves emphasis among the delimiters above `bottom`, whose items
    /// are all in `chain`, and removes them from the stack.
    fn processEmphasis(p: *Parser, bottom: u32, chain: *Chain) !void {
        const ds = p.delimiters.items;
        // Per character, whether the closer can also open, and its length
        // mod 3: no opener at or below this one will match. Delimiters are
        // compared by index, which follows their order on the stack, so the
        // bound holds even after the delimiter it names is removed.
        var openers_bottom: [3][2][3]u32 = @splat(@splat(@splat(bottom)));

        var closer_i = p.delimiter_top;
        if (closer_i == bottom) closer_i = none;
        while (closer_i != none and ds[closer_i].prev != bottom) closer_i = ds[closer_i].prev;

        while (closer_i != none) {
            const closer = &ds[closer_i];
            if (!closer.can_close) {
                closer_i = closer.next;
                continue;
            }
            const char: usize = switch (closer.char) {
                '_' => 0,
                '*' => 1,
                else => 2,
            };
            const floor = &openers_bottom[char][@intFromBool(closer.can_open)][closer.original % 3];
            var opener_i = closer.prev;
            const found = while (opener_i != none and (floor.* == none or opener_i > floor.*)) {
                const opener = ds[opener_i];
                // Tildes pair only with a run of the same length; the rule
                // of three is for `*` and `_`.
                const fits = if (closer.char == '~')
                    opener.original == closer.original
                else
                    !((closer.can_open or opener.can_close) and closer.original % 3 != 0 and
                        (opener.original + closer.original) % 3 == 0);
                if (opener.char == closer.char and opener.can_open and fits) break true;
                opener_i = opener.prev;
            } else false;

            if (!found) {
                floor.* = closer.prev;
                const next = closer.next;
                if (!closer.can_open) p.removeDelimiter(closer_i);
                closer_i = next;
                continue;
            }

            const opener = &ds[opener_i];
            const use: u32 = if (closer.char == '~') closer.count else if (closer.count >= 2 and opener.count >= 2) 2 else 1;
            opener.count -= use;
            closer.count -= use;
            p.literal(opener.item).len -= use;
            p.literal(closer.item).len -= use;

            const before_closer = p.items.items[closer.item].prev;
            const inner = p.cut(chain, opener.item, before_closer);
            const tag: Tag = if (closer.char == '~') .strikethrough else if (use == 1) .emphasis else .strong;
            const emphasis = try p.newItem(tag, .{ .parent = .{} });
            p.items.items[emphasis].children = inner;
            p.insertAfter(chain, opener.item, emphasis);

            // The delimiters between them are spent.
            opener.next = closer_i;
            closer.prev = opener_i;

            if (opener.count == 0) {
                p.unlink(chain, opener.item);
                p.removeDelimiter(opener_i);
            }
            if (closer.count == 0) {
                p.unlink(chain, closer.item);
                const next = closer.next;
                p.removeDelimiter(closer_i);
                closer_i = next;
            }
        }

        while (p.delimiter_top != none and p.delimiter_top != bottom) p.removeDelimiter(p.delimiter_top);
    }

    // Links and images.

    fn pushBracket(p: *Parser, item: u32, label_start: u32, image: bool) !void {
        const brackets = &p.brackets;
        if (brackets.items.len > 0) brackets.items[brackets.items.len - 1].bracket_after = true;
        p.link_floor = @min(p.link_floor, brackets.items.len);
        try brackets.append(p.c.arena, .{
            .item = item,
            .delimiter = p.delimiter_top,
            .label_start = label_start,
            .image = image,
        });
    }

    fn closeBracket(p: *Parser) !void {
        const close = p.pos;
        p.pos += 1;
        const opener = p.brackets.getLastOrNull() orelse {
            _ = try p.text(close, 1);
            return;
        };
        if (!opener.image and p.brackets.items.len - 1 < p.link_floor) {
            _ = p.brackets.pop();
            _ = try p.text(close, 1);
            return;
        }

        const link = try p.inlineLink() orelse try p.referenceLink(opener, close) orelse {
            _ = p.brackets.pop();
            p.pos = close + 1;
            _ = try p.text(close, 1);
            return;
        };

        const node = try p.add(&p.top, if (opener.image) .image else .link, .{ .parent = .{ .index = link } });
        var inner = p.cut(&p.top, opener.item, p.items.items[node].prev);
        try p.processEmphasis(opener.delimiter, &inner);
        p.items.items[node].children = inner;
        _ = p.brackets.pop();
        p.unlink(&p.top, opener.item);
        // No links in links: the link brackets still open are spent.
        if (!opener.image) p.link_floor = p.brackets.items.len;
    }

    /// `(destination "title")` right after the `]`.
    fn inlineLink(p: *Parser) !?u32 {
        const s = p.src();
        if (p.at(p.pos) != '(') return null;
        var i = scan.spaceAndNewline(s, p.pos + 1);
        var destination: Range = .{};
        if (scan.linkDestination(s, i)) |d| {
            destination = .{ .start = @intCast(d.start), .len = @intCast(d.end - d.start) };
            i = d.next;
        } else if (p.at(i) != ')') {
            return null;
        }
        const before_title = i;
        i = scan.spaceAndNewline(s, i);
        var title: Range = .{};
        if (i > before_title and i < s.len) {
            if (p.scanTitle(i)) |t| {
                title = .{ .start = @intCast(t.start), .len = @intCast(t.end - t.start) };
                i = scan.spaceAndNewline(s, t.next);
            }
        }
        if (p.at(i) != ')') return null;
        p.pos = @intCast(i + 1);
        const link: u32 = @intCast(p.c.links.items.len);
        try p.c.links.append(p.c.arena, .{
            .destination = try decode(p.c, destination),
            .title = try decode(p.c, title),
        });
        return link;
    }

    fn scanTitle(p: *Parser, i: usize) ?scan.Part {
        const quote: ?usize = switch (p.at(i)) {
            '"' => 0,
            '\'' => 1,
            else => null,
        };
        if (quote) |q| if (p.no_title_end[q]) return null;
        const t = scan.linkTitle(p.src(), i) orelse {
            // A quoted title only fails for want of a closing quote.
            if (quote) |q| p.no_title_end[q] = true;
            return null;
        };
        return t;
    }

    /// `[label]`, `[]` or nothing after the `]`, naming a definition.
    fn referenceLink(p: *Parser, opener: Bracket, close: u32) !?u32 {
        const s = p.src();
        var label: ?Range = null;
        var end = p.pos;
        if (scan.linkLabel(s, p.pos)) |label_end| {
            if (label_end - p.pos > 2) {
                label = .{ .start = p.pos + 1, .len = @intCast(label_end - p.pos - 2) };
            } else if (!opener.bracket_after) {
                label = .{ .start = opener.label_start, .len = close - opener.label_start };
            }
            end = @intCast(label_end);
        } else if (!opener.bracket_after) {
            label = .{ .start = opener.label_start, .len = close - opener.label_start };
        }
        const raw = label orelse return null;
        // A label has at most 999 characters.
        if (raw.len > 999) {
            var chars: usize = 0;
            for (slice(p.c, raw)) |b| chars += @intFromBool(b & 0xC0 != 0x80);
            if (chars > 999) return null;
        }
        const key = try normalizeLabel(p.c.arena, slice(p.c, raw));
        const link = p.c.refs.get(key) orelse return null;
        p.pos = end;
        return link;
    }

    // Output.

    /// A chain still to write, as the children of `node`.
    const Job = struct { first: u32, node: Index };

    /// Writes the items into the tree and returns the top-level run.
    fn emit(p: *Parser) !Range {
        var jobs: std.ArrayList(Job) = .empty;
        const run = try p.writeChain(p.top.first, &jobs);
        while (jobs.pop()) |job| {
            const children = try p.writeChain(job.first, &jobs);
            p.c.nodes.items(.data)[job.node].parent.children = children;
        }
        return run;
    }

    /// Writes one chain as a run in `extra`, joining adjacent text, and
    /// queues the chains of its children.
    fn writeChain(p: *Parser, first: u32, jobs: *std.ArrayList(Job)) !Range {
        const run_start: u32 = @intCast(p.c.extra.items.len);
        var i = first;
        while (i != none) {
            const item = p.items.items[i];
            if (item.tag == .text) {
                var r = item.data.literal;
                i = item.next;
                while (i != none and p.items.items[i].tag == .text) : (i = p.items.items[i].next) {
                    const next = p.items.items[i].data.literal;
                    if (next.len == 0) continue;
                    if (r.len == 0) {
                        r = next;
                    } else if (r.start + r.len == next.start) {
                        r.len += next.len;
                    } else break;
                }
                if (r.len > 0) try p.c.extra.append(p.c.arena, try p.newNode(.text, .{ .literal = r }));
                continue;
            }
            const n = try p.newNode(item.tag, item.data);
            try p.c.extra.append(p.c.arena, n);
            if (item.tag.hasChildren()) try jobs.append(p.c.arena, .{ .first = item.children.first, .node = n });
            i = item.next;
        }
        return .{ .start = run_start, .len = @as(u32, @intCast(p.c.extra.items.len)) - run_start };
    }

    fn newNode(p: *Parser, tag: Tag, data: Ast.Node.Data) !Index {
        const n: Index = @intCast(p.c.nodes.len);
        try p.c.nodes.append(p.c.arena, .{ .tag = tag, .data = data });
        return n;
    }
};

const testing = std.testing;

test normalizeLabel {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo bar", try normalizeLabel(a, "  Foo \t\n BAR "));
    try testing.expectEqualStrings("ss", try normalizeLabel(a, "\u{1E9E}"));
    try testing.expectEqualStrings("\u{3b1}\u{3b3}\u{3c9}", try normalizeLabel(a, "\u{391}\u{393}\u{3a9}"));
}
