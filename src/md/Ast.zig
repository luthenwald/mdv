//! The syntax tree of a markdown document, data-oriented after `std.zig.Ast`.
//!
//! Blocks and inlines are nodes in one `MultiArrayList`; the document is
//! node 0. A node's children are a contiguous run of node indices in `extra`.
//! All text lives in one `text` buffer, already decoded: escapes and
//! character references are resolved while parsing, so a text node's string
//! is what a reader sees.

const std = @import("std");
const Ast = @This();

nodes: std.MultiArrayList(Node).Slice,
extra: []const Index,
text: []const u8,
lists: []const List,
links: []const Link,
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
        // Blocks.
        document,
        block_quote,
        list,
        list_item,
        paragraph,
        heading,
        thematic_break,
        code_block,
        html_block,
        // Inlines, inside paragraphs and headings.
        text,
        soft_break,
        hard_break,
        code_span,
        html_inline,
        emphasis,
        strong,
        strikethrough,
        link,
        image,

        pub fn hasChildren(t: Tag) bool {
            return switch (t) {
                .document, .block_quote, .list, .list_item, .paragraph, .heading => true,
                .emphasis, .strong, .strikethrough, .link, .image => true,
                else => false,
            };
        }

        /// Holds blocks rather than inlines.
        pub fn isContainer(t: Tag) bool {
            return switch (t) {
                .document, .block_quote, .list, .list_item => true,
                else => false,
            };
        }
    };

    /// Which field is live follows from `tag`.
    pub const Data = union {
        /// Every tag with children.
        parent: Parent,
        /// `code_block`.
        code: Code,
        /// In `text`: `html_block`, `text`, `code_span` and `html_inline`.
        literal: Range,
        /// `thematic_break`, `soft_break` and `hard_break`.
        none: void,
    };

    pub const Parent = struct {
        /// Node indices in `extra`.
        children: Range = .{},
        /// A list's index in `lists`, a heading's level (1 to 6), or a link's
        /// or image's index in `links`.
        index: u32 = 0,
    };

    pub const Code = struct {
        /// In `text`, with its final line ending.
        content: Range = .{},
        /// In `text`: the info string of a fenced code block, trimmed and decoded.
        info: Range = .{},
        /// Fenced rather than indented.
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

/// Where a link or image goes, decoded. An empty title is no title.
pub const Link = struct {
    destination: Range = .{},
    title: Range = .{},
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

fn data(ast: Ast, node: Index) Node.Data {
    return ast.nodes.items(.data)[node];
}

pub fn children(ast: Ast, node: Index) []const Index {
    std.debug.assert(ast.tag(node).hasChildren());
    return ast.data(node).parent.children.of(Index, ast.extra);
}

/// The text of a literal node, or the content of a code block.
pub fn content(ast: Ast, node: Index) []const u8 {
    const range = switch (ast.tag(node)) {
        .code_block => ast.data(node).code.content,
        .html_block, .text, .code_span, .html_inline => ast.data(node).literal,
        else => unreachable,
    };
    return range.of(u8, ast.text);
}

pub fn code(ast: Ast, node: Index) Node.Code {
    std.debug.assert(ast.tag(node) == .code_block);
    return ast.data(node).code;
}

pub fn info(ast: Ast, node: Index) []const u8 {
    return ast.code(node).info.of(u8, ast.text);
}

pub fn level(ast: Ast, node: Index) u8 {
    std.debug.assert(ast.tag(node) == .heading);
    return @intCast(ast.data(node).parent.index);
}

pub fn list(ast: Ast, node: Index) List {
    std.debug.assert(ast.tag(node) == .list);
    return ast.lists[ast.data(node).parent.index];
}

pub fn link(ast: Ast, node: Index) Link {
    std.debug.assert(ast.tag(node) == .link or ast.tag(node) == .image);
    return ast.links[ast.data(node).parent.index];
}

/// The text of a range, such as a link's destination or a definition's label.
pub fn string(ast: Ast, r: Range) []const u8 {
    return r.of(u8, ast.text);
}
