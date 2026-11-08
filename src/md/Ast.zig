//! The syntax tree of a markdown document, data-oriented after `std.zig.Ast`.
//!
//! Nodes live in a `MultiArrayList`; the document is node 0. A container's
//! children are a contiguous run of node indices in `extra`. The content of
//! leaf blocks is copied into one `text` buffer, so each leaf's content is a
//! single string even when its source lines were interleaved with block quote
//! markers or indentation.

const std = @import("std");
const Ast = @This();

nodes: std.MultiArrayList(Node).Slice,
extra: []const Index,
text: []const u8,
lists: []const List,
definitions: []const Definition,

pub const Index = u32;

pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn of(r: Range, comptime T: type, items: []const T) []const T {
        return items[r.start..][0..r.len];
    }
};

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        document,
        block_quote,
        list,
        list_item,
        paragraph,
        heading,
        thematic_break,
        code_block,
        html_block,

        pub fn isContainer(t: Tag) bool {
            return switch (t) {
                .document, .block_quote, .list, .list_item => true,
                else => false,
            };
        }
    };

    /// Which field is live follows from `tag`.
    pub const Data = union {
        container: Container,
        leaf: Leaf,
    };

    pub const Container = struct {
        /// Node indices in `extra`.
        children: Range = .{},
        /// For a list, its index in `lists`.
        list: u32 = 0,
    };

    pub const Leaf = struct {
        /// In `text`. Paragraphs and headings are trimmed; code keeps its final newline.
        content: Range = .{},
        /// In `text`: the info string of a fenced code block, trimmed.
        info: Range = .{},
        /// 1 to 6 for headings.
        level: u8 = 0,
        /// For code blocks: fenced rather than indented.
        fenced: bool = false,
    };
};

pub const List = struct {
    ordered: bool,
    tight: bool = true,
    /// The bullet ('-', '+', '*') or the delimiter after the number ('.', ')').
    marker: u8,
    /// The first number of an ordered list.
    start: u32 = 1,
};

/// A link reference definition, as written: the label without its brackets,
/// the destination without angle brackets, the title without its quotes.
/// Escapes and entities are still in place.
pub const Definition = struct {
    label: Range,
    destination: Range,
    title: Range,
};

pub fn tag(ast: Ast, node: Index) Node.Tag {
    return ast.nodes.items(.tag)[node];
}

pub fn children(ast: Ast, node: Index) []const Index {
    std.debug.assert(ast.tag(node).isContainer());
    return ast.nodes.items(.data)[node].container.children.of(Index, ast.extra);
}

pub fn leaf(ast: Ast, node: Index) Node.Leaf {
    std.debug.assert(!ast.tag(node).isContainer());
    return ast.nodes.items(.data)[node].leaf;
}

pub fn content(ast: Ast, node: Index) []const u8 {
    return ast.leaf(node).content.of(u8, ast.text);
}

pub fn info(ast: Ast, node: Index) []const u8 {
    return ast.leaf(node).info.of(u8, ast.text);
}

pub fn list(ast: Ast, node: Index) List {
    std.debug.assert(ast.tag(node) == .list);
    return ast.lists[ast.nodes.items(.data)[node].container.list];
}

/// The text of a definition's label, destination or title.
pub fn string(ast: Ast, r: Range) []const u8 {
    return r.of(u8, ast.text);
}
