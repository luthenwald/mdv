//! Inline structure: the content of paragraphs and headings to inline nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Index = Ast.Index;

/// The parts of the tree the inline pass appends to.
pub const Context = struct {
    arena: Allocator,
    nodes: *std.MultiArrayList(Ast.Node),
    extra: *std.ArrayList(Index),
    text: *std.ArrayList(u8),
    links: *std.ArrayList(Ast.Link),
};

/// Parses the inline content at `content` in `text` and returns the run of
/// its top-level nodes in `extra`.
pub fn parse(c: Context, content: Ast.Range) Allocator.Error!Ast.Range {
    var kids: std.ArrayList(Index) = .empty;
    var start = content.start;
    const end = content.start + content.len;
    while (start <= end) {
        const rest = c.text.items[start..end];
        const line_end = start + @as(u32, @intCast(std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len));
        if (start > content.start) try kids.append(c.arena, try add(c, .soft_break, .{ .none = {} }));
        var a = start;
        var b = line_end;
        while (a < b and c.text.items[a] == ' ') a += 1;
        while (b > a and c.text.items[b - 1] == ' ') b -= 1;
        if (b > a) try kids.append(c.arena, try add(c, .text, .{ .literal = .{ .start = a, .len = b - a } }));
        start = line_end + 1;
    }
    const run: Ast.Range = .{ .start = @intCast(c.extra.items.len), .len = @intCast(kids.items.len) };
    try c.extra.appendSlice(c.arena, kids.items);
    return run;
}

fn add(c: Context, tag: Ast.Node.Tag, data: Ast.Node.Data) !Index {
    const node: Index = @intCast(c.nodes.len);
    try c.nodes.append(c.arena, .{ .tag = tag, .data = data });
    return node;
}
