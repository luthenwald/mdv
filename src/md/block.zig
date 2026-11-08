//! Block structure: lines to containers and leaf blocks.
//!
//! This follows the parsing strategy in the appendix of the CommonMark spec,
//! shaped like the block parser of commonmark.js. Each line first walks the
//! open blocks to see which ones it continues, then tries to start new blocks,
//! and what remains of it goes to a paragraph, a code block or an HTML block.
//! Columns are tracked beside byte offsets, since a tab counts to the next
//! multiple of four only where indentation is measured.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const scan = @import("scan.zig");
const Index = Ast.Index;
const isSpaceOrTab = scan.isSpaceOrTab;

/// Parses `source` into a syntax tree. Everything is allocated in `arena`.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!Ast {
    const text = try normalize(arena, source);
    var p: Parser = .{ .arena = arena };
    try p.begin();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // A final line ending does not start another line.
        if (lines.index == null and line.len == 0) break;
        try p.incorporateLine(line);
    }
    while (p.open.items.len > 0) try p.finalize();
    return .{
        .nodes = p.nodes.toOwnedSlice(),
        .extra = p.extra.items,
        .text = p.text.items,
        .lists = p.lists.items,
        .definitions = p.definitions.items,
    };
}

/// Line endings become `\n`, and NUL becomes U+FFFD.
pub fn normalize(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, source, "\r\x00") == null) return source;
    var out: std.ArrayList(u8) = try .initCapacity(arena, source.len + source.len / 8);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '\r' => {
                try out.append(arena, '\n');
                if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
            },
            0 => try out.appendSlice(arena, "\u{FFFD}"),
            else => |c| try out.append(arena, c),
        }
    }
    return out.items;
}

/// An open block and what its continuation needs to know.
const Open = struct {
    node: Index,
    tag: Ast.Tag,
    /// Where this block's children begin in `Parser.children`.
    children_start: u32,
    /// Where a leaf's content begins in `Parser.text`.
    content_start: u32,
    start_line: u32,
    /// Lists and list items.
    marker: scan.ListMarker = .{ .ordered = false, .char = 0, .len = 0 },
    marker_offset: usize = 0,
    padding: usize = 0,
    list: u32 = 0,
    /// Code blocks.
    fenced: bool = false,
    fence: scan.Fence = .{ .char = 0, .len = 0 },
    fence_offset: usize = 0,
    /// HTML blocks: which of the seven kinds.
    html_kind: u8 = 0,
    /// Headings.
    level: u8 = 0,
};

const Parser = struct {
    arena: Allocator,

    nodes: std.MultiArrayList(Ast.Node) = .empty,
    /// Per node: the last line it held was blank (for list tightness).
    blank_end: std.ArrayList(bool) = .empty,
    extra: std.ArrayList(Index) = .empty,
    text: std.ArrayList(u8) = .empty,
    lists: std.ArrayList(Ast.List) = .empty,
    definitions: std.ArrayList(Ast.Definition) = .empty,
    /// The open blocks, the document first and the tip last.
    open: std.ArrayList(Open) = .empty,
    /// The children of open blocks so far, each block's after its parent's.
    children: std.ArrayList(Index) = .empty,

    line: []const u8 = "",
    line_number: u32 = 0,
    offset: usize = 0,
    column: usize = 0,
    partially_consumed_tab: bool = false,
    next_nonspace: usize = 0,
    next_nonspace_column: usize = 0,
    indent: usize = 0,
    indented: bool = false,
    blank: bool = false,
    all_closed: bool = true,
    last_matched: usize = 0,

    fn begin(p: *Parser) !void {
        try p.nodes.append(p.arena, .{ .tag = .document, .data = .{ .container = .{} } });
        try p.blank_end.append(p.arena, false);
        try p.open.append(p.arena, .{ .node = 0, .tag = .document, .children_start = 0, .content_start = 0, .start_line = 0 });
    }

    fn tip(p: *Parser) *Open {
        return &p.open.items[p.open.items.len - 1];
    }

    fn peek(p: *const Parser, i: usize) u8 {
        return if (i < p.line.len) p.line[i] else 0;
    }

    fn hasChildren(p: *const Parser, depth: usize) bool {
        return p.children.items.len > p.open.items[depth].children_start;
    }

    fn incorporateLine(p: *Parser, line: []const u8) !void {
        p.line = line;
        p.line_number += 1;
        p.offset = 0;
        p.column = 0;
        p.blank = false;
        p.partially_consumed_tab = false;

        // Walk the open blocks; `container` ends at the last one this line continues.
        const old_tip = p.open.items.len - 1;
        var container: usize = 0;
        while (container < old_tip) {
            p.findNextNonspace();
            switch (try p.continueBlock(container + 1)) {
                .matched => container += 1,
                .failed => break,
                .done => return,
            }
        }
        p.all_closed = container == old_tip;
        p.last_matched = container;

        var matched_leaf = switch (p.open.items[container].tag) {
            .code_block, .html_block => true,
            else => false,
        };
        while (!matched_leaf) {
            p.findNextNonspace();
            if (!p.indented and !scan.maybeSpecial(p.line[p.next_nonspace..])) {
                p.advanceNextNonspace();
                break;
            }
            switch (try p.tryStarts(container)) {
                .none => {
                    p.advanceNextNonspace();
                    break;
                },
                .container => container = p.open.items.len - 1,
                .leaf => {
                    container = p.open.items.len - 1;
                    matched_leaf = true;
                },
            }
        }

        if (!p.all_closed and !p.blank and p.tip().tag == .paragraph) {
            // A lazy continuation line.
            try p.addLine();
            return;
        }

        try p.closeUnmatchedBlocks();
        const depth = p.open.items.len - 1;
        const o = p.open.items[depth];
        if (p.blank and p.hasChildren(depth)) {
            p.blank_end.items[p.children.items[p.children.items.len - 1]] = true;
        }
        // Blank lines in block quotes and fenced code, or right after an empty
        // list item's marker, do not make a list loose.
        const last_line_blank = p.blank and !(o.tag == .block_quote or
            (o.tag == .code_block and o.fenced) or
            (o.tag == .list_item and !p.hasChildren(depth) and o.start_line == p.line_number));
        for (p.open.items[0 .. depth + 1]) |a| p.blank_end.items[a.node] = last_line_blank;

        switch (o.tag) {
            .paragraph, .code_block, .html_block => {
                try p.addLine();
                if (o.tag == .html_block and o.html_kind <= 5 and scan.htmlBlockEnd(o.html_kind, p.line[p.offset..])) {
                    try p.finalize();
                }
            },
            else => if (p.offset < p.line.len and !p.blank) {
                _ = try p.addChild(.paragraph);
                p.advanceNextNonspace();
                try p.addLine();
            },
        }
    }

    const Continue = enum { matched, failed, done };

    fn continueBlock(p: *Parser, depth: usize) !Continue {
        const o = p.open.items[depth];
        switch (o.tag) {
            .document, .list => return .matched,
            .heading, .thematic_break => return .failed,
            .paragraph => return if (p.blank) .failed else .matched,
            .html_block => return if (p.blank and o.html_kind >= 6) .failed else .matched,
            .block_quote => {
                if (p.indented or p.peek(p.next_nonspace) != '>') return .failed;
                p.advanceNextNonspace();
                p.advanceOffset(1, false);
                if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
                return .matched;
            },
            .list_item => {
                if (p.blank) {
                    // A blank line after an empty item ends it.
                    if (!p.hasChildren(depth)) return .failed;
                    p.advanceNextNonspace();
                } else if (p.indent >= o.marker_offset + o.padding) {
                    p.advanceOffset(o.marker_offset + o.padding, true);
                } else {
                    return .failed;
                }
                return .matched;
            },
            .code_block => {
                if (o.fenced) {
                    if (p.indent <= 3 and p.peek(p.next_nonspace) == o.fence.char) {
                        if (scan.fenceCloser(p.line[p.next_nonspace..], o.fence.char)) |n| {
                            if (n >= o.fence.len) {
                                try p.finalize();
                                return .done;
                            }
                        }
                    }
                    var i = o.fence_offset;
                    while (i > 0 and isSpaceOrTab(p.peek(p.offset))) : (i -= 1) p.advanceOffset(1, true);
                } else if (p.indent >= 4) {
                    p.advanceOffset(4, true);
                } else if (p.blank) {
                    p.advanceNextNonspace();
                } else {
                    return .failed;
                }
                return .matched;
            },
        }
    }

    const Start = enum { none, container, leaf };

    /// Tries each kind of block start in the spec's order of precedence.
    fn tryStarts(p: *Parser, container: usize) !Start {
        const rest = p.line[p.next_nonspace..];
        const container_tag = p.open.items[container].tag;

        if (!p.indented and p.peek(p.next_nonspace) == '>') {
            p.advanceNextNonspace();
            p.advanceOffset(1, false);
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
            try p.closeUnmatchedBlocks();
            _ = try p.addChild(.block_quote);
            return .container;
        }

        if (!p.indented) if (scan.atxOpener(rest)) |opener| {
            p.advanceNextNonspace();
            p.advanceOffset(opener.len, false);
            try p.closeUnmatchedBlocks();
            const d = try p.addChild(.heading);
            p.open.items[d].level = opener.level;
            try p.text.appendSlice(p.arena, scan.atxContent(p.line[p.offset..]));
            p.advanceOffset(p.line.len - p.offset, false);
            return .leaf;
        };

        if (!p.indented) if (scan.fenceOpener(rest)) |fence| {
            try p.closeUnmatchedBlocks();
            const d = try p.addChild(.code_block);
            p.open.items[d].fenced = true;
            p.open.items[d].fence = fence;
            p.open.items[d].fence_offset = p.indent;
            p.advanceNextNonspace();
            p.advanceOffset(fence.len, false);
            return .leaf;
        };

        if (!p.indented and p.peek(p.next_nonspace) == '<') if (scan.htmlBlockStart(rest)) |kind| {
            // The seventh kind cannot interrupt a paragraph, not even a lazy one.
            const lazy = !p.all_closed and !p.blank and p.tip().tag == .paragraph;
            if (kind < 7 or (container_tag != .paragraph and !lazy)) {
                try p.closeUnmatchedBlocks();
                // The spaces before the tag belong to the block.
                const d = try p.addChild(.html_block);
                p.open.items[d].html_kind = kind;
                return .leaf;
            }
        };

        if (!p.indented and container_tag == .paragraph) if (scan.setextUnderline(rest)) |level| {
            try p.closeUnmatchedBlocks();
            const o = p.tip();
            _ = try p.takeDefinitions(&o.content_start);
            if (!scan.isBlank(std.mem.trimEnd(u8, p.text.items[o.content_start..], "\n"))) {
                o.tag = .heading;
                o.level = level;
                p.nodes.items(.tag)[o.node] = .heading;
                p.advanceOffset(p.line.len - p.offset, false);
                return .leaf;
            }
        };

        if (!p.indented and scan.thematicBreak(rest)) {
            try p.closeUnmatchedBlocks();
            _ = try p.addChild(.thematic_break);
            p.advanceOffset(p.line.len - p.offset, false);
            return .leaf;
        }

        if (!p.indented or container_tag == .list) if (p.listMarker(container)) |item| {
            try p.closeUnmatchedBlocks();
            const t = p.tip();
            if (t.tag != .list or t.marker.ordered != item.marker.ordered or t.marker.char != item.marker.char) {
                const d = try p.addChild(.list);
                p.open.items[d].marker = item.marker;
                p.open.items[d].list = @intCast(p.lists.items.len);
                try p.lists.append(p.arena, .{ .ordered = item.marker.ordered, .marker = item.marker.char, .start = item.marker.start });
            }
            const d = try p.addChild(.list_item);
            p.open.items[d].marker = item.marker;
            p.open.items[d].marker_offset = item.marker_offset;
            p.open.items[d].padding = item.padding;
            return .container;
        };

        if (p.indented and p.tip().tag != .paragraph and !p.blank) {
            p.advanceOffset(4, true);
            try p.closeUnmatchedBlocks();
            _ = try p.addChild(.code_block);
            return .leaf;
        }

        return .none;
    }

    const Item = struct {
        marker: scan.ListMarker,
        marker_offset: usize,
        padding: usize,
    };

    /// A list marker at the next non-space position, and the item's padding:
    /// how far its content sits from the marker.
    fn listMarker(p: *Parser, container: usize) ?Item {
        if (p.indent >= 4) return null;
        const marker = scan.listMarker(p.line[p.next_nonspace..]) orelse return null;
        const container_tag = p.open.items[container].tag;
        // Only a list starting at 1 may interrupt a paragraph.
        if (marker.ordered and container_tag == .paragraph and marker.start != 1) return null;
        const after = p.next_nonspace + marker.len;
        const next = p.peek(after);
        if (!(next == 0 or isSpaceOrTab(next))) return null;
        // An empty item cannot interrupt a paragraph.
        if (container_tag == .paragraph and scan.isBlank(p.line[after..])) return null;

        const marker_offset = p.indent;
        p.advanceNextNonspace();
        p.advanceOffset(marker.len, true);
        const spaces_column = p.column;
        const spaces_offset = p.offset;
        while (true) {
            p.advanceOffset(1, true);
            if (!(p.column - spaces_column < 5 and isSpaceOrTab(p.peek(p.offset)))) break;
        }
        const blank_item = p.offset >= p.line.len;
        const spaces = p.column - spaces_column;
        var padding = marker.len + spaces;
        if (spaces >= 5 or spaces < 1 or blank_item) {
            // Content that starts five or more columns away is indented code
            // inside the item; the item itself takes one space.
            padding = marker.len + 1;
            p.column = spaces_column;
            p.offset = spaces_offset;
            if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
        }
        return .{ .marker = marker, .marker_offset = marker_offset, .padding = padding };
    }

    fn findNextNonspace(p: *Parser) void {
        var i = p.offset;
        var cols = p.column;
        while (i < p.line.len) : (i += 1) {
            switch (p.line[i]) {
                ' ' => cols += 1,
                '\t' => cols += 4 - cols % 4,
                else => break,
            }
        }
        p.blank = i == p.line.len;
        p.next_nonspace = i;
        p.next_nonspace_column = cols;
        p.indent = cols - p.column;
        p.indented = p.indent >= 4;
    }

    fn advanceNextNonspace(p: *Parser) void {
        p.offset = p.next_nonspace;
        p.column = p.next_nonspace_column;
        p.partially_consumed_tab = false;
    }

    /// Moves `count` characters ahead, or `count` columns when `columns` is
    /// set, in which case a tab may be consumed only in part.
    fn advanceOffset(p: *Parser, count_in: usize, columns: bool) void {
        var count = count_in;
        while (count > 0 and p.offset < p.line.len) {
            if (p.line[p.offset] == '\t') {
                const to_tab = 4 - p.column % 4;
                if (columns) {
                    p.partially_consumed_tab = to_tab > count;
                    const step = @min(to_tab, count);
                    p.column += step;
                    if (!p.partially_consumed_tab) p.offset += 1;
                    count -= step;
                } else {
                    p.partially_consumed_tab = false;
                    p.column += to_tab;
                    p.offset += 1;
                    count -= 1;
                }
            } else {
                p.partially_consumed_tab = false;
                p.offset += 1;
                p.column += 1;
                count -= 1;
            }
        }
    }

    /// Adds the rest of the line to the tip, with the columns left over from a
    /// tab that was consumed in part.
    fn addLine(p: *Parser) !void {
        if (p.partially_consumed_tab) {
            p.offset += 1;
            const spaces = 4 - p.column % 4;
            @memset(try p.text.addManyAsSlice(p.arena, spaces), ' ');
        }
        try p.text.appendSlice(p.arena, p.line[p.offset..]);
        try p.text.append(p.arena, '\n');
    }

    fn closeUnmatchedBlocks(p: *Parser) !void {
        if (p.all_closed) return;
        while (p.open.items.len - 1 > p.last_matched) try p.finalize();
        p.all_closed = true;
    }

    fn canContain(parent: Ast.Tag, child: Ast.Tag) bool {
        return switch (parent) {
            .document, .block_quote, .list_item => child != .list_item,
            .list => child == .list_item,
            else => false,
        };
    }

    /// Opens a block under the tip, closing blocks that cannot hold it.
    /// Returns its depth in `open`.
    fn addChild(p: *Parser, tag: Ast.Tag) !usize {
        while (!canContain(p.tip().tag, tag)) try p.finalize();
        const node: Index = @intCast(p.nodes.len);
        try p.nodes.append(p.arena, .{
            .tag = tag,
            .data = if (tag.isContainer()) .{ .container = .{} } else .{ .leaf = .{} },
        });
        try p.blank_end.append(p.arena, false);
        try p.children.append(p.arena, node);
        try p.open.append(p.arena, .{
            .node = node,
            .tag = tag,
            .children_start = @intCast(p.children.items.len),
            .content_start = @intCast(p.text.items.len),
            .start_line = p.line_number,
        });
        return p.open.items.len - 1;
    }

    /// Closes the tip and settles what it holds.
    fn finalize(p: *Parser) !void {
        const o = p.open.pop().?;
        const data = &p.nodes.items(.data)[o.node];
        const end: u32 = @intCast(p.text.items.len);
        switch (o.tag) {
            .document, .block_quote, .list, .list_item => {
                const kids = p.children.items[o.children_start..];
                const start: u32 = @intCast(p.extra.items.len);
                try p.extra.appendSlice(p.arena, kids);
                p.children.shrinkRetainingCapacity(o.children_start);
                data.* = .{ .container = .{ .children = .{ .start = start, .len = @intCast(kids.len) }, .list = o.list } };
                if (o.tag == .list) p.lists.items[o.list].tight = p.isTight(o.node);
            },
            .paragraph => {
                var start = o.content_start;
                const had_definitions = try p.takeDefinitions(&start);
                const content = p.trimmed(start, end);
                if (had_definitions and content.len == 0) {
                    // Only definitions: the paragraph disappears.
                    _ = p.children.pop();
                    return;
                }
                data.* = .{ .leaf = .{ .content = content } };
            },
            .heading => data.* = .{ .leaf = .{ .content = p.trimmed(o.content_start, end), .level = o.level } },
            .thematic_break => data.* = .{ .leaf = .{} },
            .code_block => {
                if (o.fenced) {
                    // The opening line holds the info string.
                    const text = p.text.items[o.content_start..end];
                    const newline: u32 = @intCast(std.mem.indexOfScalar(u8, text, '\n').?);
                    data.* = .{ .leaf = .{
                        .content = .{ .start = o.content_start + newline + 1, .len = @intCast(text.len - newline - 1) },
                        .info = p.trimmed(o.content_start, o.content_start + newline),
                        .fenced = true,
                    } };
                } else {
                    // Trailing blank lines are not part of indented code.
                    var stop = end;
                    while (stop > o.content_start) {
                        const body = p.text.items[o.content_start .. stop - 1];
                        const line_start: u32 = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| o.content_start + @as(u32, @intCast(i)) + 1 else o.content_start;
                        if (!scan.isBlank(p.text.items[line_start .. stop - 1])) break;
                        stop = line_start;
                    }
                    data.* = .{ .leaf = .{ .content = .{ .start = o.content_start, .len = stop - o.content_start } } };
                }
            },
            .html_block => {
                // Without the line endings and blank lines at the end.
                var stop = end;
                while (true) {
                    var k = stop;
                    while (k > o.content_start and p.text.items[k - 1] == ' ') k -= 1;
                    if (k > o.content_start and p.text.items[k - 1] == '\n') stop = k - 1 else break;
                }
                data.* = .{ .leaf = .{ .content = .{ .start = o.content_start, .len = stop - o.content_start } } };
            },
        }
    }

    fn trimmed(p: *const Parser, start: u32, end: u32) Ast.Range {
        var a = start;
        var b = end;
        while (a < b and scan.isWhitespace(p.text.items[a])) a += 1;
        while (b > a and scan.isWhitespace(p.text.items[b - 1])) b -= 1;
        return .{ .start = a, .len = b - a };
    }

    fn childrenOf(p: *const Parser, node: Index) []const Index {
        return p.nodes.items(.data)[node].container.children.of(Index, p.extra.items);
    }

    fn endsWithBlankLine(p: *const Parser, node: Index) bool {
        var n = node;
        while (true) {
            if (p.blank_end.items[n]) return true;
            const tag = p.nodes.items(.tag)[n];
            if (tag != .list and tag != .list_item) return false;
            const kids = p.childrenOf(n);
            if (kids.len == 0) return false;
            n = kids[kids.len - 1];
        }
    }

    /// A list is loose when a blank line separates two of its items, or two
    /// blocks directly inside one item.
    fn isTight(p: *const Parser, list: Index) bool {
        const items = p.childrenOf(list);
        for (items, 0..) |item, i| {
            const has_next = i + 1 < items.len;
            if (has_next and p.endsWithBlankLine(item)) return false;
            const blocks = p.childrenOf(item);
            for (blocks, 0..) |block, j| {
                if (p.endsWithBlankLine(block) and (has_next or j + 1 < blocks.len)) return false;
            }
        }
        return true;
    }

    /// Takes link reference definitions from the start of a paragraph's
    /// content, moving `start` past them. Returns whether there were any.
    fn takeDefinitions(p: *Parser, start: *u32) !bool {
        var any = false;
        while (true) {
            const s = p.text.items[start.*..];
            if (s.len == 0 or s[0] != '[') break;
            const d = definition(s) orelse break;
            const base = start.*;
            try p.definitions.append(p.arena, .{
                .label = .{ .start = base + d.label[0], .len = d.label[1] - d.label[0] },
                .destination = .{ .start = base + d.destination[0], .len = d.destination[1] - d.destination[0] },
                .title = .{ .start = base + d.title[0], .len = d.title[1] - d.title[0] },
            });
            start.* += @intCast(d.len);
            any = true;
        }
        return any;
    }
};

const Found = struct {
    label: [2]u32,
    destination: [2]u32,
    title: [2]u32,
    /// Through the line ending after the definition.
    len: usize,
};

/// A link reference definition at the start of `s`.
fn definition(s: []const u8) ?Found {
    const label_end = scan.linkLabel(s, 0) orelse return null;
    for (s[1 .. label_end - 1]) |c| {
        if (!scan.isWhitespace(c)) break;
    } else return null;
    if (label_end >= s.len or s[label_end] != ':') return null;
    const dest = scan.linkDestination(s, spaceAndNewline(s, label_end + 1)) orelse return null;
    var found: Found = .{
        .label = .{ 1, @intCast(label_end - 1) },
        .destination = .{ @intCast(dest.start), @intCast(dest.end) },
        .title = .{ 0, 0 },
        .len = 0,
    };
    const before_title = dest.next;
    const title_at = spaceAndNewline(s, before_title);
    if (title_at != before_title) {
        if (scan.linkTitle(s, title_at)) |title| {
            if (lineEnd(s, title.next)) |end| {
                found.title = .{ @intCast(title.start), @intCast(title.end) };
                found.len = end;
                return found;
            }
        }
    }
    // Without a title that ends its line, the destination has to.
    found.len = lineEnd(s, before_title) orelse return null;
    return found;
}

/// Spaces and tabs, at most one line ending, then spaces and tabs.
fn spaceAndNewline(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    if (i < s.len and s[i] == '\n') {
        i += 1;
        while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    }
    return i;
}

/// Past the spaces, tabs and line ending at `pos`, if nothing else comes first.
fn lineEnd(s: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    if (i == s.len) return i;
    return if (s[i] == '\n') i + 1 else null;
}

const testing = std.testing;

fn expectTags(source: []const u8, expected: []const Ast.Tag) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try parse(arena.allocator(), source);
    var got: std.ArrayList(Ast.Tag) = .empty;
    try collect(ast, 0, &got, arena.allocator());
    try testing.expectEqualSlices(Ast.Tag, expected, got.items);
}

fn collect(ast: Ast, node: Index, out: *std.ArrayList(Ast.Tag), gpa: Allocator) !void {
    try out.append(gpa, ast.tag(node));
    if (ast.tag(node).isContainer()) for (ast.children(node)) |child| try collect(ast, child, out, gpa);
}

test "normalize line endings and NUL" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\nb\nc\n\u{FFFD}", try normalize(arena.allocator(), "a\r\nb\rc\n\x00"));
}

test "a quote holding a list holding code" {
    try expectTags("> - a\n>\n>       code\n", &.{ .document, .block_quote, .list, .list_item, .paragraph, .code_block });
}

test "headings, breaks and fences" {
    try expectTags("# a\nb\n===\n***\n```\nx\n```\n", &.{ .document, .heading, .heading, .thematic_break, .code_block });
}

test "a paragraph of definitions disappears" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try parse(arena.allocator(), "[a]: /u 'T'\n[b]:\n  <x y>\ntext\n");
    try testing.expectEqual(@as(usize, 2), ast.definitions.len);
    try testing.expectEqualStrings("a", ast.string(ast.definitions[0].label));
    try testing.expectEqualStrings("/u", ast.string(ast.definitions[0].destination));
    try testing.expectEqualStrings("T", ast.string(ast.definitions[0].title));
    try testing.expectEqualStrings("x y", ast.string(ast.definitions[1].destination));
    const kids = ast.children(0);
    try testing.expectEqual(@as(usize, 1), kids.len);
    try testing.expectEqualStrings("text", ast.content(kids[0]));
}

test "tight and loose lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tight = try parse(arena.allocator(), "- a\n- b\n");
    try testing.expect(tight.lists[0].tight);
    const loose = try parse(arena.allocator(), "- a\n\n- b\n");
    try testing.expect(!loose.lists[0].tight);
}

test "a tab consumed in part leaves spaces in code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try parse(arena.allocator(), ">\t\tfoo\n");
    const code = ast.children(ast.children(0)[0])[0];
    try testing.expectEqualStrings("  foo\n", ast.content(code));
}
