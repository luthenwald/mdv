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
const inlines = @import("inline.zig");
const Index = Ast.Index;
const isSpaceOrTab = scan.isSpaceOrTab;

pub const Options = struct {
    /// The extensions of GitHub Flavored Markdown in v1: tables,
    /// strikethrough and task list items.
    gfm: bool = true,
};

/// Parses `source` into a syntax tree. Everything is allocated in `arena`.
pub fn parse(arena: Allocator, source: []const u8, options: Options) Allocator.Error!Ast {
    const text = try normalize(arena, source);
    var p: Parser = .{ .arena = arena, .gfm = options.gfm };
    try p.begin();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // A final line ending does not start another line.
        if (lines.index == null and line.len == 0) break;
        try p.incorporateLine(line);
    }
    while (p.open.items.len > 0) try p.finalize();

    // Inlines come second, once every link reference definition is known.
    var context: inlines.Context = .{
        .arena = arena,
        .nodes = &p.nodes,
        .extra = &p.extra,
        .text = &p.text,
        .links = &p.links,
        .gfm = options.gfm,
    };
    var refs: inlines.References = .empty;
    try inlines.references(context, p.definitions.items, &refs);
    context.refs = &refs;
    for (p.nodes.items(.tag), p.nodes.items(.data)) |tag, *data| {
        if (tag == .code_block) data.code.info = try inlines.decode(context, data.code.info);
    }
    if (options.gfm) try p.taskItems();
    for (p.text_blocks.items) |block| {
        const children = try inlines.parse(context, block.content);
        p.nodes.items(.data)[block.node].parent.children = children;
    }

    return .{
        .nodes = p.nodes.toOwnedSlice(),
        .extra = p.extra.items,
        .text = p.text.items,
        .lists = p.lists.items,
        .links = p.links.items,
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
    tag: Ast.Node.Tag,
    /// Where this block's children begin in `Parser.children`.
    children_start: u32,
    /// Where a leaf's content begins in `Parser.text`.
    content_start: u32,
    start_line: u32,
    /// How many lines had been settled (`Parser.settled`) when it opened.
    born: u32 = 0,
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
    gfm: bool,

    nodes: std.MultiArrayList(Ast.Node) = .empty,
    /// Per node: the last line it held was blank (for list tightness). Set
    /// when the node closes, from the last line settled while it was open.
    blank_end: std.ArrayList(bool) = .empty,
    /// Per list and list item: its last child ends with a blank line.
    tail_blank: std.ArrayList(bool) = .empty,
    extra: std.ArrayList(Index) = .empty,
    text: std.ArrayList(u8) = .empty,
    lists: std.ArrayList(Ast.List) = .empty,
    links: std.ArrayList(Ast.Link) = .empty,
    definitions: std.ArrayList(Ast.Definition) = .empty,
    /// Paragraphs and headings with their raw content, for the inline pass.
    text_blocks: std.ArrayList(struct { node: Index, content: Ast.Range }) = .empty,
    /// The open blocks, the document first and the tip last.
    open: std.ArrayList(Open) = .empty,
    /// The children of open blocks so far, each block's after its parent's.
    children: std.ArrayList(Index) = .empty,
    /// The depths in `open` of the blocks that a line with nothing left
    /// does not continue for free, in order: all but lists and list items
    /// with children.
    stops: std.ArrayList(u32) = .empty,
    /// Lines that reached the end of `incorporateLine`, and whether the last
    /// of them was blank for list tightness.
    settled: u32 = 0,
    last_settled_blank: bool = false,

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
    /// The line and offset of the last scan for the next non-space.
    scanned_line: u32 = 0,
    scanned_from: usize = 0,
    /// Where a thematic break scan of this line gave up.
    break_give_up: usize = 0,

    fn begin(p: *Parser) !void {
        try p.nodes.append(p.arena, .{ .tag = .document, .data = .{ .parent = .{} } });
        try p.appendFlags();
        try p.open.append(p.arena, .{ .node = 0, .tag = .document, .children_start = 0, .content_start = 0, .start_line = 0 });
        try p.restop();
    }

    fn appendFlags(p: *Parser) !void {
        try p.blank_end.append(p.arena, false);
        try p.tail_blank.append(p.arena, false);
    }

    /// Brings `stops` up to date for the tip and its parent, the only open
    /// blocks whose children change.
    fn restop(p: *Parser) !void {
        const len = p.open.items.len;
        const from = len -| 2;
        while (p.stops.items.len > 0 and p.stops.items[p.stops.items.len - 1] >= from) _ = p.stops.pop();
        for (from..len) |depth| {
            const free = switch (p.open.items[depth].tag) {
                .list => true,
                .list_item => p.hasChildren(depth),
                else => false,
            };
            if (!free) try p.stops.append(p.arena, @intCast(depth));
        }
    }

    /// The first depth after `depth` in `stops`, or the number of open blocks.
    fn nextStop(p: *const Parser, depth: usize) usize {
        var low: usize = 0;
        var high = p.stops.items.len;
        while (low < high) {
            const mid = (low + high) / 2;
            if (p.stops.items[mid] <= depth) low = mid + 1 else high = mid;
        }
        return if (low < p.stops.items.len) p.stops.items[low] else p.open.items.len;
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
        p.break_give_up = 0;

        // Walk the open blocks; `container` ends at the last one this line continues.
        const old_tip = p.open.items.len - 1;
        var container: usize = 0;
        while (container < old_tip) {
            p.findNextNonspace();
            if (p.offset == p.line.len) {
                // Nothing is left of the line: lists and list items with
                // children continue without moving, up to the next stop.
                const skip_to = p.nextStop(container) - 1;
                if (skip_to > container) {
                    container = skip_to;
                    continue;
                }
            }
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
        // Every open block now holds this line; each takes the value when
        // it closes.
        p.last_settled_blank = last_line_blank;
        p.settled += 1;

        switch (o.tag) {
            .paragraph, .code_block, .html_block, .table => {
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
            // A row without cells, such as a lone pipe, ends a table.
            .table => return if (p.blank or scan.Cells.count(p.line[p.next_nonspace..]) == 0) .failed else .matched,
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
            else => unreachable,
        }
    }

    const Start = enum { none, container, leaf };

    /// Tries each kind of block start in the spec's order of precedence.
    fn tryStarts(p: *Parser, container: usize) !Start {
        const rest = p.line[p.next_nonspace..];
        const container_tag = p.open.items[container].tag;

        if (!p.indented) {
            if (rest.len > 0 and rest[0] == '>') {
                p.advanceNextNonspace();
                p.advanceOffset(1, false);
                if (isSpaceOrTab(p.peek(p.offset))) p.advanceOffset(1, true);
                try p.closeUnmatchedBlocks();
                _ = try p.addChild(.block_quote);
                return .container;
            }

            if (scan.atxOpener(rest)) |opener| {
                p.advanceNextNonspace();
                p.advanceOffset(opener.len, false);
                try p.closeUnmatchedBlocks();
                const d = try p.addChild(.heading);
                p.open.items[d].level = opener.level;
                try p.text.appendSlice(p.arena, scan.atxContent(p.line[p.offset..]));
                p.advanceOffset(p.line.len - p.offset, false);
                return .leaf;
            }

            if (scan.fenceOpener(rest)) |fence| {
                try p.closeUnmatchedBlocks();
                const d = try p.addChild(.code_block);
                p.open.items[d].fenced = true;
                p.open.items[d].fence = fence;
                p.open.items[d].fence_offset = p.indent;
                p.advanceNextNonspace();
                p.advanceOffset(fence.len, false);
                return .leaf;
            }

            if (scan.htmlBlockStart(rest)) |kind| {
                // The seventh kind cannot interrupt a paragraph, not even a lazy one.
                const lazy = !p.all_closed and !p.blank and p.tip().tag == .paragraph;
                if (kind < 7 or (container_tag != .paragraph and !lazy)) {
                    try p.closeUnmatchedBlocks();
                    // The spaces before the tag belong to the block.
                    const d = try p.addChild(.html_block);
                    p.open.items[d].html_kind = kind;
                    return .leaf;
                }
            }

            if (container_tag == .paragraph) {
                if (scan.setextUnderline(rest)) |level| {
                    try p.closeUnmatchedBlocks();
                    const o = p.tip();
                    _ = try p.takeDefinitions(&o.content_start, @intCast(p.text.items.len));
                    if (!scan.isBlank(std.mem.trimEnd(u8, p.text.items[o.content_start..], "\n"))) {
                        o.tag = .heading;
                        o.level = level;
                        p.nodes.items(.tag)[o.node] = .heading;
                        p.advanceOffset(p.line.len - p.offset, false);
                        return .leaf;
                    }
                }
            }

            // A line such as `- - - … x` would be scanned again from each
            // list marker; skip starts before where the last scan gave up.
            const broke = p.next_nonspace >= p.break_give_up and if (scan.thematicBreakScan(rest)) |at| blk: {
                p.break_give_up = p.next_nonspace + at;
                break :blk false;
            } else true;
            if (broke) {
                try p.closeUnmatchedBlocks();
                _ = try p.addChild(.thematic_break);
                p.advanceOffset(p.line.len - p.offset, false);
                return .leaf;
            }
        }

        // `listMarker` refuses an indented marker by itself.
        if (p.listMarker(container)) |item| {
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
        }

        // The table extension comes after every core block, as in cmark-gfm,
        // so `- | -` under a paragraph starts a list.
        if (p.gfm and !p.indented and container_tag == .paragraph and try p.tableStart(rest)) return .leaf;

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
        if (p.scanned_line == p.line_number and p.scanned_from <= p.offset and p.offset <= p.next_nonspace) {
            // Inside spaces already scanned: an indented line under deep
            // lists is not scanned again for each list.
            i = p.next_nonspace;
            cols = p.next_nonspace_column;
        } else {
            while (i < p.line.len) : (i += 1) {
                switch (p.line[i]) {
                    ' ' => cols += 1,
                    '\t' => cols += 4 - cols % 4,
                    else => break,
                }
            }
            p.scanned_line = p.line_number;
            p.scanned_from = p.offset;
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

    fn canContain(parent: Ast.Node.Tag, child: Ast.Node.Tag) bool {
        return switch (parent) {
            .document, .block_quote, .list_item => child != .list_item,
            .list => child == .list_item,
            else => false,
        };
    }

    /// Opens a block under the tip, closing blocks that cannot hold it.
    /// Returns its depth in `open`.
    fn addChild(p: *Parser, tag: Ast.Node.Tag) !usize {
        while (!canContain(p.tip().tag, tag)) try p.finalize();
        const node: Index = @intCast(p.nodes.len);
        try p.nodes.append(p.arena, .{
            .tag = tag,
            .data = switch (tag) {
                .code_block => .{ .code = .{} },
                .html_block => .{ .literal = .{} },
                .thematic_break => .{ .none = {} },
                else => .{ .parent = .{} },
            },
        });
        try p.appendFlags();
        try p.children.append(p.arena, node);
        try p.open.append(p.arena, .{
            .node = node,
            .tag = tag,
            .children_start = @intCast(p.children.items.len),
            .content_start = @intCast(p.text.items.len),
            .start_line = p.line_number,
            .born = p.settled,
        });
        try p.restop();
        return p.open.items.len - 1;
    }

    /// A table opens when a paragraph's last line is a header row and this
    /// line a delimiter row with as many cells. The lines before the header
    /// stay a paragraph, after any link reference definitions at its start,
    /// which are taken first so that none of their lines can be the header.
    fn tableStart(p: *Parser, rest: []const u8) !bool {
        const columns = scan.delimiterRow(rest) orelse return false;
        const o = p.tip();
        _ = try p.takeDefinitions(&o.content_start, @intCast(p.text.items.len));
        const body = std.mem.trimEnd(u8, p.text.items[o.content_start..], "\n");
        const header_at: u32 = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| @intCast(i + 1) else 0;
        if (scan.Cells.count(body[header_at..]) != columns) return false;
        const header_start = o.content_start + header_at;
        try p.finalizeTo(header_start);
        const d = try p.addChild(.table);
        p.open.items[d].content_start = header_start;
        return true;
    }

    /// Closes the tip and settles what it holds.
    fn finalize(p: *Parser) !void {
        return p.finalizeTo(@intCast(p.text.items.len));
    }

    /// Closes the tip, its content ending at `end` in `text`.
    fn finalizeTo(p: *Parser, end: u32) !void {
        const o = p.open.pop().?;
        p.blank_end.items[o.node] = o.born < p.settled and p.last_settled_blank;
        try p.close(o, end);
        try p.restop();
    }

    fn close(p: *Parser, o: Open, end: u32) !void {
        const data = &p.nodes.items(.data)[o.node];
        switch (o.tag) {
            .document, .block_quote, .list, .list_item => {
                const kids = p.children.items[o.children_start..];
                if (kids.len > 0) p.tail_blank.items[o.node] = p.endsWithBlankLine(kids[kids.len - 1]);
                const start: u32 = @intCast(p.extra.items.len);
                try p.extra.appendSlice(p.arena, kids);
                p.children.shrinkRetainingCapacity(o.children_start);
                data.* = .{ .parent = .{ .children = .{ .start = start, .len = @intCast(kids.len) }, .index = o.list } };
                if (o.tag == .list) p.lists.items[o.list].tight = p.isTight(o.node);
            },
            .paragraph => {
                var start = o.content_start;
                _ = try p.takeDefinitions(&start, end);
                const content = p.trimmed(start, end);
                if (content.len == 0) {
                    // Only definitions, or nothing before a table's header:
                    // the paragraph disappears.
                    _ = p.children.pop();
                    return;
                }
                data.* = .{ .parent = .{} };
                try p.text_blocks.append(p.arena, .{ .node = o.node, .content = content });
            },
            .heading => {
                data.* = .{ .parent = .{ .index = o.level } };
                try p.text_blocks.append(p.arena, .{ .node = o.node, .content = p.trimmed(o.content_start, end) });
            },
            .thematic_break => data.* = .{ .none = {} },
            .code_block => {
                if (o.fenced) {
                    // The opening line holds the info string.
                    const text = p.text.items[o.content_start..end];
                    const newline: u32 = @intCast(std.mem.indexOfScalar(u8, text, '\n').?);
                    data.* = .{ .code = .{
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
                    data.* = .{ .code = .{ .content = .{ .start = o.content_start, .len = stop - o.content_start } } };
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
                data.* = .{ .literal = .{ .start = o.content_start, .len = stop - o.content_start } };
            },
            .table => try p.finalizeTable(o, end),
            else => unreachable,
        }
    }

    /// The header row, the delimiter row, then the body rows. A row keeps the
    /// cells it has, at most the header's number; a short row is not padded,
    /// so a table costs its cells and not its rows times its columns.
    fn finalizeTable(p: *Parser, o: Open, end: u32) !void {
        var lines: std.ArrayList([2]u32) = .empty;
        var at = o.content_start;
        while (at < end) {
            const stop: u32 = @intCast(std.mem.indexOfScalarPos(u8, p.text.items[0..end], at, '\n') orelse end);
            try lines.append(p.arena, .{ at, stop });
            at = stop + 1;
        }

        var alignments: std.ArrayList(Ast.Alignment) = .empty;
        const delimiter = p.text.items[lines.items[1][0]..lines.items[1][1]];
        var marks = scan.Cells.init(delimiter);
        while (marks.next()) |c| {
            const cell = delimiter[c[0]..c[1]];
            const left = cell[0] == ':';
            const right = cell[cell.len - 1] == ':';
            try alignments.append(p.arena, if (left and right) .center else if (right) .right else if (left) .left else .none);
        }

        var rows: std.ArrayList(Index) = .empty;
        var ranges: std.ArrayList([2]u32) = .empty;
        var cells: std.ArrayList(Index) = .empty;
        for (lines.items, 0..) |line, i| {
            if (i == 1) continue;
            // Cell ranges first: unescaping pipes appends to `text`.
            ranges.clearRetainingCapacity();
            var it = scan.Cells.init(p.text.items[line[0]..line[1]]);
            while (ranges.items.len < alignments.items.len) {
                const c = it.next() orelse break;
                try ranges.append(p.arena, .{ line[0] + @as(u32, @intCast(c[0])), line[0] + @as(u32, @intCast(c[1])) });
            }
            cells.clearRetainingCapacity();
            for (ranges.items, alignments.items[0..ranges.items.len]) |range, alignment| {
                const content = try p.unescapePipes(range[0], range[1]);
                const cell = try p.newNode(.table_cell, .{ .parent = .{ .index = @backingInt(alignment) } });
                try p.text_blocks.append(p.arena, .{ .node = cell, .content = content });
                try cells.append(p.arena, cell);
            }
            try rows.append(p.arena, try p.newNode(.table_row, .{ .parent = .{ .children = try p.run(cells.items) } }));
        }
        p.nodes.items(.data)[o.node] = .{ .parent = .{ .children = try p.run(rows.items) } };
    }

    /// The range, with `\\|` turned into `|`: copied into `text` when it has any.
    fn unescapePipes(p: *Parser, start: u32, end: u32) !Ast.Range {
        if (std.mem.indexOf(u8, p.text.items[start..end], "\\|") == null) return .{ .start = start, .len = end - start };
        const out: u32 = @intCast(p.text.items.len);
        try p.text.ensureUnusedCapacity(p.arena, end - start);
        var i = start;
        while (i < end) : (i += 1) {
            const c = p.text.items[i];
            if (c == '\\' and i + 1 < end and p.text.items[i + 1] == '|') continue;
            p.text.appendAssumeCapacity(c);
        }
        return .{ .start = out, .len = @as(u32, @intCast(p.text.items.len)) - out };
    }

    /// A node made outside the open blocks, such as a table's rows and cells.
    fn newNode(p: *Parser, tag: Ast.Node.Tag, data: Ast.Node.Data) !Index {
        const node: Index = @intCast(p.nodes.len);
        try p.nodes.append(p.arena, .{ .tag = tag, .data = data });
        try p.appendFlags();
        return node;
    }

    /// Appends a run of nodes to `extra`.
    fn run(p: *Parser, nodes: []const Index) !Ast.Range {
        const start: u32 = @intCast(p.extra.items.len);
        try p.extra.appendSlice(p.arena, nodes);
        return .{ .start = start, .len = @intCast(nodes.len) };
    }

    fn trimmed(p: *const Parser, start: u32, end: u32) Ast.Range {
        var a = start;
        var b = end;
        while (a < b and scan.isWhitespace(p.text.items[a])) a += 1;
        while (b > a and scan.isWhitespace(p.text.items[b - 1])) b -= 1;
        return .{ .start = a, .len = b - a };
    }

    fn childrenOf(p: *const Parser, node: Index) []const Index {
        return p.nodes.items(.data)[node].parent.children.of(Index, p.extra.items);
    }

    /// The node's last line was blank, or, for a list or list item, its last
    /// child's (`tail_blank`, settled when the node closed).
    fn endsWithBlankLine(p: *const Parser, node: Index) bool {
        if (p.blank_end.items[node]) return true;
        return switch (p.nodes.items(.tag)[node]) {
            .list, .list_item => p.tail_blank.items[node],
            else => false,
        };
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
                if ((has_next or j + 1 < blocks.len) and p.endsWithBlankLine(block)) return false;
            }
        }
        return true;
    }

    /// Turns list items whose first paragraph starts with `[ ]`, `[x]` or
    /// `[X]` and whitespace, or ends right after the marker, into task
    /// items, the marker cut from the content.
    fn taskItems(p: *Parser) !void {
        // Which text block holds each paragraph.
        const block_of = try p.arena.alloc(u32, p.nodes.len);
        @memset(block_of, std.math.maxInt(u32));
        for (p.text_blocks.items, 0..) |b, i| block_of[b.node] = @intCast(i);
        const tags = p.nodes.items(.tag);
        const data = p.nodes.items(.data);
        for (tags, data) |tag, *item| {
            if (tag != .list_item) continue;
            const kids = item.parent.children.of(Index, p.extra.items);
            if (kids.len == 0 or tags[kids[0]] != .paragraph) continue;
            const content = &p.text_blocks.items[block_of[kids[0]]].content;
            const s = content.of(u8, p.text.items);
            if (s.len < 3 or s[0] != '[' or s[2] != ']' or (s.len > 3 and !scan.isWhitespace(s[3]))) continue;
            const done = switch (s[1]) {
                ' ', '\t' => false,
                'x', 'X' => true,
                else => continue,
            };
            var skip: u32 = 3;
            while (skip < s.len and scan.isWhitespace(s[skip])) skip += 1;
            content.start += skip;
            content.len -= skip;
            item.parent.index = if (done) 2 else 1;
        }
    }

    /// Takes link reference definitions from the start of a paragraph's
    /// content, moving `start` past them. Returns whether there were any.
    fn takeDefinitions(p: *Parser, start: *u32, end: u32) !bool {
        var any = false;
        while (true) {
            const s = p.text.items[start.*..end];
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
    const dest = scan.linkDestination(s, scan.spaceAndNewline(s, label_end + 1)) orelse return null;
    var found: Found = .{
        .label = .{ 1, @intCast(label_end - 1) },
        .destination = .{ @intCast(dest.start), @intCast(dest.end) },
        .title = .{ 0, 0 },
        .len = 0,
    };
    const before_title = dest.next;
    const title_at = scan.spaceAndNewline(s, before_title);
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

/// Past the spaces, tabs and line ending at `pos`, if nothing else comes first.
fn lineEnd(s: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    if (i == s.len) return i;
    return if (s[i] == '\n') i + 1 else null;
}

const testing = std.testing;

fn expectTags(source: []const u8, expected: []const Ast.Node.Tag) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try parse(arena.allocator(), source, .{});
    var got: std.ArrayList(Ast.Node.Tag) = .empty;
    try collect(ast, 0, &got, arena.allocator());
    try testing.expectEqualSlices(Ast.Node.Tag, expected, got.items);
}

fn collect(ast: Ast, node: Index, out: *std.ArrayList(Ast.Node.Tag), gpa: Allocator) !void {
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
    const ast = try parse(arena.allocator(), "[a]: /u 'T'\n[b]:\n  <x y>\ntext\n", .{});
    try testing.expectEqual(2, ast.definitions.len);
    try testing.expectEqualStrings("a", ast.string(ast.definitions[0].label));
    try testing.expectEqualStrings("/u", ast.string(ast.definitions[0].destination));
    try testing.expectEqualStrings("T", ast.string(ast.definitions[0].title));
    try testing.expectEqualStrings("x y", ast.string(ast.definitions[1].destination));
    const kids = ast.children(0);
    try testing.expectEqual(1, kids.len);
    try testing.expectEqualStrings("text", ast.content(ast.children(kids[0])[0]));
}

test "tight and loose lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tight = try parse(arena.allocator(), "- a\n- b\n", .{});
    try testing.expect(tight.lists[0].tight);
    const loose = try parse(arena.allocator(), "- a\n\n- b\n", .{});
    try testing.expect(!loose.lists[0].tight);
}

test "a tab consumed in part leaves spaces in code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try parse(arena.allocator(), ">\t\tfoo\n", .{});
    const code = ast.children(ast.children(0)[0])[0];
    try testing.expectEqualStrings("  foo\n", ast.content(code));
}
