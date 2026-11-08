//! The command line: options in, a command out. Nothing here touches the terminal.

const std = @import("std");

pub const Mode = enum { auto, always, never };

pub const Options = struct {
    /// An explicit wrap width; it lifts the 80-column cap.
    width: ?u16 = null,
    color: Mode = .auto,
    paging: Mode = .auto,
    no_links: bool = false,
    ascii: bool = false,
    /// File names in order; "-" is standard input. Empty means standard input.
    files: []const []const u8 = &.{},
};

pub const Command = union(enum) {
    run: Options,
    help,
    version,
    /// A usage error, already worded for `mdv: <message>`.
    usage: []const u8,
};

pub const usage_text =
    \\usage: mdv [options] [file ...]
    \\
    \\renders markdown for the terminal. with no file, or "-", reads standard input.
    \\
    \\  -w, --width N                 wrap width (default: terminal, at most 80)
    \\      --color auto|always|never
    \\      --paging auto|always|never
    \\  -P                            same as --paging=never
    \\      --no-links                no hyperlinks; the url follows the link text
    \\      --ascii                   ascii glyphs only
    \\  -h, --help
    \\      --version
    \\
;

/// Parses the arguments after the program name. Messages are allocated in `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Command {
    var options: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    var only_files = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (only_files or arg.len < 2 or arg[0] != '-') {
            try files.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_files = true;
            continue;
        }

        // Split "--name=value" and "-wN" into a name and an attached value.
        var name = arg;
        var attached: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                attached = arg[eq + 1 ..];
            }
        } else if (arg.len > 2) {
            name = arg[0..2];
            attached = arg[2..];
        }

        const flag = flags.get(name) orelse
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown option {s}", .{arg}) };

        if (!flag.takes_value) {
            if (attached != null)
                return .{ .usage = try std.fmt.allocPrint(arena, "{s} takes no value", .{name}) };
            switch (flag.id) {
                .help => return .help,
                .version => return .version,
                .no_paging => options.paging = .never,
                .no_links => options.no_links = true,
                .ascii => options.ascii = true,
                else => unreachable,
            }
            continue;
        }

        const value = attached orelse blk: {
            i += 1;
            if (i == args.len)
                return .{ .usage = try std.fmt.allocPrint(arena, "{s} needs a value", .{name}) };
            break :blk args[i];
        };
        switch (flag.id) {
            .width => options.width = parseWidth(value) orelse
                return .{ .usage = try std.fmt.allocPrint(arena, "{s}: not a width: {s}", .{ name, value }) },
            .color, .paging => {
                const mode = std.meta.stringToEnum(Mode, value) orelse
                    return .{ .usage = try std.fmt.allocPrint(arena, "{s}: expected auto, always or never, not {s}", .{ name, value }) };
                if (flag.id == .color) options.color = mode else options.paging = mode;
            },
            else => unreachable,
        }
    }
    options.files = files.items;
    return .{ .run = options };
}

const Flag = struct {
    id: enum { width, color, paging, no_paging, no_links, ascii, help, version },
    takes_value: bool = false,
};

const flags = std.StaticStringMap(Flag).initComptime(.{
    .{ "-w", Flag{ .id = .width, .takes_value = true } },
    .{ "--width", Flag{ .id = .width, .takes_value = true } },
    .{ "--color", Flag{ .id = .color, .takes_value = true } },
    .{ "--paging", Flag{ .id = .paging, .takes_value = true } },
    .{ "-P", Flag{ .id = .no_paging } },
    .{ "--no-links", Flag{ .id = .no_links } },
    .{ "--ascii", Flag{ .id = .ascii } },
    .{ "-h", Flag{ .id = .help } },
    .{ "--help", Flag{ .id = .help } },
    .{ "--version", Flag{ .id = .version } },
});

fn parseWidth(text: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (n >= 1) n else null;
}

const testing = std.testing;

test "no arguments reads standard input with defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = (try parse(arena.allocator(), &.{})).run;
    try testing.expectEqual(@as(?u16, null), options.width);
    try testing.expectEqual(Mode.auto, options.color);
    try testing.expectEqual(Mode.auto, options.paging);
    try testing.expectEqual(@as(usize, 0), options.files.len);
}

test "the width in all four spellings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const []const u8{
        &.{ "-w", "40" }, &.{"-w40"}, &.{ "--width", "40" }, &.{"--width=40"},
    }) |args| {
        try testing.expectEqual(@as(?u16, 40), (try parse(arena.allocator(), args)).run.width);
    }
}

test "modes, flags and files keep their order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const args: []const []const u8 = &.{ "a.md", "--color=never", "-P", "-", "--ascii", "--no-links", "--", "-w" };
    const options = (try parse(arena.allocator(), args)).run;
    try testing.expectEqual(Mode.never, options.color);
    try testing.expectEqual(Mode.never, options.paging);
    try testing.expect(options.ascii and options.no_links);
    try testing.expectEqual(@as(usize, 3), options.files.len);
    try testing.expectEqualStrings("a.md", options.files[0]);
    try testing.expectEqualStrings("-", options.files[1]);
    try testing.expectEqualStrings("-w", options.files[2]);
}

test "help and version win at once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try parse(arena.allocator(), &.{ "a.md", "-h" })) == .help);
    try testing.expect((try parse(arena.allocator(), &.{"--version"})) == .version);
}

test "usage errors are worded for the user" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{"--bogus"}, .message = "unknown option --bogus" },
        .{ .args = &.{"-w"}, .message = "-w needs a value" },
        .{ .args = &.{ "--width", "0" }, .message = "--width: not a width: 0" },
        .{ .args = &.{"--color=loud"}, .message = "--color: expected auto, always or never, not loud" },
        .{ .args = &.{"--ascii=yes"}, .message = "--ascii takes no value" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case.message, (try parse(arena.allocator(), case.args)).usage);
    }
}
