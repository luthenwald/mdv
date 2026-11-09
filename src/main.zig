//! mdv: renders markdown to the terminal once and exits.

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
            deliver(io, stdout, .{ .text = cli.usage_text }) catch return writeFailed(err);
            return 0;
        },
        .version => {
            const text = try std.fmt.allocPrint(arena, "mdv {s}\n", .{build_options.version});
            deliver(io, stdout, .{ .text = text }) catch return writeFailed(err);
            return 0;
        },
        .usage => |message| return usage(err, message),
    };
    // Without a file, markdown comes from standard input; a terminal there means
    // the user forgot the file.
    if (options.files.len == 0 and try std.Io.File.stdin().isTty(io)) {
        return usage(err, "no input: standard input is a terminal");
    }
    // Read every input before any output starts, so errors never land inside the pager.
    const inputs = try readInputs(io, arena, options.files, err);
    try err.flush();
    const exit_status: u8 = if (inputs.failed) 1 else 0;

    const terminal = tty.decide(options, try tty.gather(io, init.environ_map));
    const output: Output = .{
        .lines = try lay(arena, inputs, .{
            .width = terminal.width,
            .styled = terminal.styled,
            .ascii = options.ascii,
            .no_links = options.no_links,
        }),
        .emitter = .{ .styled = terminal.styled, .colors = terminal.colors },
    };

    if (terminal.page and output.lines.len > 0) {
        if (pager.start(io, pager.command(init.environ_map))) |started| {
            var child = started;
            const written = deliver(io, child.stdin.?, output);
            child.stdin.?.close(io);
            child.stdin = null;
            const term = child.wait(io) catch null;
            // The shell could not find or run the pager: write to stdout after all.
            const not_started = if (term) |t| pager.notStarted(t) else false;
            if (!not_started) {
                written catch return writeFailed(err);
                return exit_status;
            }
        }
    }
    deliver(io, stdout, output) catch return writeFailed(err);
    return exit_status;
}

fn usage(err: *std.Io.Writer, message: []const u8) !u8 {
    try err.print("mdv: {s}\ntry mdv --help\n", .{message});
    try err.flush();
    return 2;
}

fn writeFailed(err: *std.Io.Writer) !u8 {
    try err.writeAll("mdv: cannot write the output\n");
    try err.flush();
    return 1;
}

/// What gets written: laid-out lines, or a ready text such as the help.
const Output = struct {
    lines: []const layout.Line = &.{},
    emitter: emit.Emitter = .{ .styled = false, .colors = false },
    text: []const u8 = "",
};

/// Lays out every input. When more than one was asked for, each starts with
/// its name in dim, and a blank line separates them.
fn lay(arena: std.mem.Allocator, inputs: Inputs, options: layout.Options) ![]const layout.Line {
    var lines: std.ArrayList(layout.Line) = .empty;
    for (inputs.texts, 0..) |input, i| {
        if (i > 0) try lines.append(arena, &.{});
        if (inputs.requested > 1) {
            try lines.append(arena, try arena.dupe(emit.Span, &.{.{ .text = input.name, .style = .{ .dim = true } }}));
        }
        try lines.appendSlice(arena, try layout.document(arena, try md.parse(arena, input.text, .{}), options));
    }
    return lines.items;
}

/// Writes `output` to `file`. A reader that went away (a broken pipe) is a
/// normal end for a viewer, not an error.
fn deliver(io: std.Io, file: std.Io.File, output: Output) error{WriteFailed}!void {
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    write(&writer.interface, output) catch |e| {
        if (writer.err) |cause| if (cause == error.BrokenPipe) return;
        return e;
    };
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
    /// The inputs that could be read, in order.
    texts: []const Input,
    /// How many were asked for.
    requested: usize,
    failed: bool,
};

/// Inputs this long or longer are refused. Positions in the parser are 32
/// bits, and nothing readable is this large.
const max_input = 256 * 1024 * 1024;

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
            std.Io.Dir.cwd().readFileAlloc(io, name, arena, .limited(max_input))) catch |e| switch (e) {
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
    return .{ .texts = texts.items, .requested = all.len, .failed = failed };
}

const ReadError = std.Io.Dir.ReadFileAllocError;

fn readStdin(io: std.Io, arena: std.mem.Allocator) ReadError![]u8 {
    var buf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(arena, .limited(max_input)) catch |e| switch (e) {
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
        error.StreamTooLong => "too large",
        else => "cannot be read",
    };
}

test describe {
    try std.testing.expectEqualStrings("no such file", describe(error.FileNotFound));
    try std.testing.expectEqualStrings("is a directory", describe(error.IsDir));
    try std.testing.expectEqualStrings("too large", describe(error.StreamTooLong));
    try std.testing.expectEqualStrings("cannot be read", describe(error.InputOutput));
}

test {
    _ = cli;
    _ = emit;
    _ = layout;
    _ = pager;
    _ = tty;
    _ = @import("term/width.zig");
}
