//! mdv: renders markdown to the terminal once and exits.
//! The design is in .claude/spec.md.

const std = @import("std");
const build_options = @import("build_options");
const md = @import("md");
const cli = @import("cli.zig");
const emit = @import("term/emit.zig");
const layout = @import("term/layout.zig");
const pager = @import("term/pager.zig");
const tty = @import("term/tty.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const stdout = std.Io.File.stdout();

    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &stderr.interface;

    const args = try init.minimal.args.toSlice(arena);
    const options = switch (try cli.parse(arena, args[1..])) {
        .run => |options| options,
        .help => {
            _ = try deliver(io, stdout, .{ .text = cli.usage_text });
            return 0;
        },
        .version => {
            const text = try std.fmt.allocPrint(arena, "mdv {s}\n", .{build_options.version});
            _ = try deliver(io, stdout, .{ .text = text });
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
    const exit_status: u8 = if (inputs.failed) 1 else 0;

    const terminal = tty.decide(options, try tty.gather(io, init.environ_map));
    const output: Output = .{
        .lines = try lay(arena, inputs.texts, .{
            .width = terminal.width,
            .styled = terminal.styled,
            .ascii = options.ascii,
            .no_links = options.no_links,
        }),
        .emitter = .{ .styled = terminal.styled, .colors = terminal.colors },
    };

    if (terminal.page) {
        if (pager.start(io, pager.command(init.environ_map))) |started| {
            var child = started;
            // A broken pipe means the reader quit early, which is a normal end.
            _ = try deliver(io, child.stdin.?, output);
            child.stdin.?.close(io);
            child.stdin = null;
            const term = child.wait(io) catch return exit_status;
            if (!pager.notStarted(term)) return exit_status;
            // The shell could not find or run the pager: write to stdout after all.
        }
    }
    _ = try deliver(io, stdout, output);
    return exit_status;
}

/// What gets written: laid-out lines, or a ready text such as the help.
const Output = struct {
    lines: []const layout.Line = &.{},
    emitter: emit.Emitter = .{ .styled = false, .colors = false },
    text: []const u8 = "",
};

/// Lays out every input; each one after the first starts after a blank line
/// with its name in dim.
fn lay(arena: std.mem.Allocator, inputs: []const Input, options: layout.Options) ![]const layout.Line {
    var lines: std.ArrayList(layout.Line) = .empty;
    for (inputs, 0..) |input, i| {
        if (i > 0) {
            const header = try arena.dupe(emit.Span, &.{.{ .text = input.name, .style = .{ .dim = true } }});
            try lines.appendSlice(arena, &.{ &.{}, header });
        }
        try lines.appendSlice(arena, try layout.document(arena, try md.parse(arena, input.text), options));
    }
    return lines.items;
}

/// Writes `output` to `file`. Returns false when the reader went away
/// (a broken pipe), which is not an error for a viewer.
fn deliver(io: std.Io, file: std.Io.File, output: Output) !bool {
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    const w = &writer.interface;
    write(w, output) catch |e| switch (e) {
        error.WriteFailed => return if (writer.err) |cause| switch (cause) {
            error.BrokenPipe => false,
            else => cause,
        } else e,
    };
    return true;
}

fn write(w: *std.Io.Writer, output: Output) std.Io.Writer.Error!void {
    try w.writeAll(output.text);
    for (output.lines) |line| try output.emitter.line(w, line);
    try w.flush();
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

const ReadError = std.Io.Dir.ReadFileAllocError;

fn readStdin(io: std.Io, arena: std.mem.Allocator) ReadError![]u8 {
    var buf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(arena, .unlimited) catch |e| switch (e) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |other| return other,
    };
}

/// The lowercase phrase that follows the file name in an error line.
fn describe(e: ReadError) []const u8 {
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
    _ = layout;
    _ = pager;
    _ = tty;
    _ = @import("term/width.zig");
}
