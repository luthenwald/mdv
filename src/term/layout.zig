//! Text to lines of styled spans for a given width. Every visual decision lives here.
//!
//! For now the input is raw text cut into paragraphs at blank lines; the AST
//! takes its place once the block parser exists.

const std = @import("std");
const emit = @import("emit.zig");

pub const Line = []const emit.Span;

/// Splits `text` into paragraphs at blank lines, joins the lines of each with
/// single spaces, and wraps them greedily to `width` bytes. A word longer than
/// the width breaks at the width. Paragraphs are separated by an empty line.
pub fn paragraphs(arena: std.mem.Allocator, text: []const u8, width: u16) std.mem.Allocator.Error![]const Line {
    std.debug.assert(width > 0);
    var lines: std.ArrayList(Line) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| {
        var tokens = std.mem.tokenizeAny(u8, row, " \t\r");
        if (tokens.peek() == null) {
            try wrap(arena, &lines, words.items, width);
            words.clearRetainingCapacity();
            continue;
        }
        while (tokens.next()) |word| try words.append(arena, word);
    }
    try wrap(arena, &lines, words.items, width);
    return lines.items;
}

/// Appends one paragraph's lines, after an empty line if others came before.
fn wrap(arena: std.mem.Allocator, lines: *std.ArrayList(Line), words: []const []const u8, width: u16) !void {
    if (words.len == 0) return;
    if (lines.items.len > 0) try lines.append(arena, &.{});

    var current: std.ArrayList(u8) = .empty;
    for (words) |whole| {
        var word = whole;
        // A word that cannot fit on any line is cut into pieces of the width.
        while (word.len > width) {
            if (current.items.len > 0) try finish(arena, lines, &current);
            try current.appendSlice(arena, word[0..width]);
            try finish(arena, lines, &current);
            word = word[width..];
        }
        if (word.len == 0) continue;
        if (current.items.len > 0 and current.items.len + 1 + word.len > width)
            try finish(arena, lines, &current);
        if (current.items.len > 0) try current.append(arena, ' ');
        try current.appendSlice(arena, word);
    }
    if (current.items.len > 0) try finish(arena, lines, &current);
}

fn finish(arena: std.mem.Allocator, lines: *std.ArrayList(Line), current: *std.ArrayList(u8)) !void {
    const spans = try arena.alloc(emit.Span, 1);
    spans[0] = .{ .text = try current.toOwnedSlice(arena) };
    try lines.append(arena, spans);
}

const testing = std.testing;

fn expectLines(expected: []const []const u8, text: []const u8, width: u16) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const lines = try paragraphs(arena.allocator(), text, width);
    var got: std.ArrayList([]const u8) = .empty;
    for (lines) |line| try got.append(arena.allocator(), if (line.len == 0) "" else line[0].text);
    try testing.expectEqualDeep(expected, got.items);
}

test "soft breaks join and the paragraph wraps at the width" {
    try expectLines(&.{ "one two", "three four", "five" }, "one two\nthree\nfour five\n", 10);
}

test "a line that fits exactly stays whole" {
    try expectLines(&.{ "abcd efgh", "ij" }, "abcd efgh ij", 9);
}

test "a long word breaks at the width" {
    try expectLines(&.{ "a", "abcde", "fghij", "k b" }, "a abcdefghijk b", 5);
}

test "blank lines separate paragraphs, however many" {
    try expectLines(&.{ "one", "", "two" }, "\n\none\n  \n\t\ntwo\n\n", 20);
}

test "carriage returns and runs of spaces are whitespace" {
    try expectLines(&.{ "a b", "", "c" }, "a   b\r\n\r\nc\r\n", 20);
}

test "nothing in, nothing out" {
    try expectLines(&.{}, "", 20);
}
