//! The markdown library: CommonMark parsing into a syntax tree. No terminal code.

pub const Ast = @import("Ast.zig");
pub const scan = @import("scan.zig");
pub const parse = @import("block.zig").parse;
pub const Options = @import("block.zig").Options;
/// HTML output, for the conformance tests.
pub const html = @import("html.zig");
/// Seed documents for fuzz tests.
pub const fuzz_corpus = @import("corpus.zig").seeds;

test {
    _ = Ast;
    _ = scan;
    _ = @import("block.zig");
    _ = html;
    _ = @import("entities.zig");
    _ = @import("unicode.zig");
    _ = @import("inline.zig");
}

test "any input parses and renders as HTML" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const source = buf[0..smith.slice(&buf)];
            for ([_]bool{ false, true }) |gfm| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const ast = try parse(arena.allocator(), source, .{ .gfm = gfm });
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try html.render(ast, &out.writer);
            }
        }
    }.one, .{ .corpus = fuzz_corpus });
}

const std = @import("std");
