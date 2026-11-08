//! mdv: renders markdown to the terminal once and exits.
//! The design is in .claude/spec.md; this is the starting stub.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [64 * 1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.writeAll("mdv: nothing to render yet\n");
    try out.flush();
}

test "the stub builds" {}
