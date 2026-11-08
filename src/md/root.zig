//! The markdown library: CommonMark parsing into a syntax tree. No terminal code.

pub const Ast = @import("Ast.zig");
pub const scan = @import("scan.zig");

test {
    _ = Ast;
    _ = scan;
}
