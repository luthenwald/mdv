//! mdv: renders markdown to the terminal once and exits.
//! The design is in .claude/spec.md.

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const emit = @import("term/emit.zig");
const tty = @import("term/tty.zig");

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

    // Read every input before any output starts, so errors never land inside the pager.
    const inputs = try readInputs(io, arena, options.files, err);
    try err.flush();

    const terminal = tty.decide(options, try tty.gather(io, init.environ_map));
    const emitter: emit.Emitter = .{ .styled = terminal.styled, .colors = terminal.colors };

    for (inputs.texts, 0..) |input, i| {
        // Every file after the first starts after a blank line with its name in dim.
        if (i > 0) {
            try out.writeByte('\n');
            try emitter.line(out, &.{.{ .text = input.name, .style = .{ .dim = true } }});
        }
        try out.writeAll(input.text);
    }
    try out.flush();
    return if (inputs.failed) 1 else 0;
}

const Input = struct {
    /// The name as given, or "standard input".
    name: []const u8,
    text: []const u8,
};

const Inputs = struct {
    texts: []const Input,
    failed: bool,
};

/// Reads the named files in order; "-" or no names at all mean standard input.
/// A file that cannot be read is reported on `err` and skipped.
fn readInputs(io: std.Io, arena: std.mem.Allocator, names: []const []const u8, err: *std.Io.Writer) !Inputs {
    const stdin_only: []const []const u8 = &.{"-"};
    const all = if (names.len == 0) stdin_only else names;
    var texts: std.ArrayList(Input) = try .initCapacity(arena, all.len);
    var failed = false;
    for (all) |name| {
        const text = (if (std.mem.eql(u8, name, "-"))
            readStdin(io, arena)
        else
            std.Io.Dir.cwd().readFileAlloc(io, name, arena, .unlimited)) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                failed = true;
                try err.print("mdv: {s}: {s}\n", .{ name, describe(e) });
                continue;
            },
        };
        texts.appendAssumeCapacity(.{
            .name = if (std.mem.eql(u8, name, "-")) "standard input" else name,
            .text = text,
        });
    }
    return .{ .texts = texts.items, .failed = failed };
}

fn readStdin(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    var buf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(arena, .unlimited) catch |e| switch (e) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => return e,
    };
}

/// The lowercase phrase that follows the file name in an error line.
fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.IsDir, error.NotDir => "is a directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        else => "cannot be read",
    };
}

test {
    _ = cli;
    _ = emit;
    _ = tty;
}
