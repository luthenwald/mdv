//! The markdown library: CommonMark parsing into a syntax tree. No terminal code.

pub const Ast = @import("Ast.zig");
pub const scan = @import("scan.zig");
pub const parse = @import("block.zig").parse;

test {
    _ = Ast;
    _ = scan;
    _ = @import("block.zig");
}
