//! The markdown library: CommonMark parsing into a syntax tree. No terminal code.

pub const Ast = @import("Ast.zig");
pub const scan = @import("scan.zig");
pub const parse = @import("block.zig").parse;
/// HTML output, for the conformance tests.
pub const html = @import("html.zig");

test {
    _ = Ast;
    _ = scan;
    _ = @import("block.zig");
    _ = html;
    _ = @import("entities.zig");
    _ = @import("unicode.zig");
    _ = @import("inline.zig");
}
