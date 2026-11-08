//! mdv: renders markdown to the terminal once and exits.
//! The design is in .claude/spec.md.

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &stderr.interface;

    const args = try init.minimal.args.toSlice(arena);
    const options = switch (try cli.parse(arena, args[1..])) {
        .run => |options| options,
        .help => {
            try out.writeAll(cli.usage_text);
            try out.flush();
            return 0;
        },
        .version => {
            try out.print("mdv {s}\n", .{build_options.version});
            try out.flush();
            return 0;
        },
        .usage => |message| {
            try err.print("mdv: {s}\ntry mdv --help\n", .{message});
            try err.flush();
            return 2;
        },
    };
    _ = options;

    try out.writeAll("mdv: nothing to render yet\n");
    try out.flush();
    return 0;
}

test {
    _ = cli;
}
