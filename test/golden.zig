//! Renders documents through the built mdv in a few fixed forms and
//! compares the output, with its escapes in a visible form, to the files
//! in the golden directory.
//!
//! usage: golden MDV GOLDEN_DIR TOUR [--update]
//! Each `NAME.md` in GOLDEN_DIR, and TOUR as `tour`, is compared with
//! `NAME.txt`. With --update, the expected files are written instead.
//!
//! The visible form: `⟨b⟩` and the other letters for SGR attributes (b
//! bold, d dim, i italic, u underline, r reverse, s strike), a color's SGR
//! number such as `⟨34⟩`, `⟨/⟩` for a reset, `⟨link URL⟩` and `⟨/link⟩`
//! for a hyperlink, and `␛` for any other escape byte.

const std = @import("std");

const Form = struct {
    label: []const u8,
    args: []const []const u8,
};

const forms = [_]Form{
    .{ .label = "width 80", .args = &.{ "-w", "80", "--color=always" } },
    .{ .label = "width 40", .args = &.{ "-w", "40", "--color=always" } },
    .{ .label = "width 30, ascii", .args = &.{ "-w", "30", "--color=always", "--ascii" } },
    .{ .label = "width 80, no styles", .args = &.{ "-w", "80", "--color=never" } },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: golden MDV GOLDEN_DIR TOUR [--update]\n", .{});
        return 2;
    }
    const mdv = args[1];
    const dir_path = args[2];
    const update = args.len > 4 and std.mem.eql(u8, args[4], "--update");

    var inputs: std.ArrayList(struct { name: []const u8, path: []const u8 }) = .empty;
    try inputs.append(arena, .{ .name = "tour", .path = args[3] });
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        try inputs.append(arena, .{
            .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - 3]),
            .path = try std.fs.path.join(arena, &.{ dir_path, entry.name }),
        });
    }
    std.mem.sortUnstable(@TypeOf(inputs.items[0]), inputs.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(inputs.items[0]), b: @TypeOf(inputs.items[0])) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Nothing from this environment, such as NO_COLOR or COLUMNS, reaches mdv.
    const environ: std.process.Environ.Map = .init(arena);
    var failed: usize = 0;
    for (inputs.items) |input| {
        var actual: std.Io.Writer.Allocating = .init(arena);
        for (forms) |form| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ mdv, "-P" });
            try argv.appendSlice(arena, form.args);
            try argv.append(arena, input.path);
            const result = try std.process.run(arena, io, .{ .argv = argv.items, .environ_map = &environ });
            try actual.writer.print("-- {s}\n", .{form.label});
            try visible(&actual.writer, result.stdout);
            if (result.stderr.len > 0) try actual.writer.print("-- stderr\n{s}", .{result.stderr});
            switch (result.term) {
                .exited => |code| if (code != 0) try actual.writer.print("-- exit {d}\n", .{code}),
                else => try actual.writer.writeAll("-- killed\n"),
            }
        }
        const expected_name = try std.fmt.allocPrint(arena, "{s}.txt", .{input.name});
        if (update) {
            try dir.writeFile(io, .{ .sub_path = expected_name, .data = actual.written() });
            std.debug.print("wrote {s}\n", .{expected_name});
            continue;
        }
        const expected = dir.readFileAlloc(io, expected_name, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("{s}: no {s}; run `just golden --update`\n", .{ input.name, expected_name });
                failed += 1;
                continue;
            },
            else => return err,
        };
        if (!std.mem.eql(u8, expected, actual.written())) {
            failed += 1;
            report(input.name, expected, actual.written());
        }
    }
    if (!update) std.debug.print("golden: {d}/{d} match\n", .{ inputs.items.len - failed, inputs.items.len });
    return if (failed == 0) 0 else 1;
}

/// The first line that differs, with the form it belongs to.
fn report(name: []const u8, expected: []const u8, actual: []const u8) void {
    var want = std.mem.splitScalar(u8, expected, '\n');
    var got = std.mem.splitScalar(u8, actual, '\n');
    var form: []const u8 = "";
    var line: usize = 0;
    while (true) {
        line += 1;
        const a = want.next();
        const b = got.next();
        if (a == null and b == null) return;
        if (b) |text| {
            if (std.mem.startsWith(u8, text, "-- ")) form = text[3..];
        }
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        std.debug.print("{s}.txt:{d} ({s})\n  expected: {s}\n  actual:   {s}\n", .{ name, line, form, a orelse "(end)", b orelse "(end)" });
        return;
    }
}

fn visible(w: *std.Io.Writer, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] != 0x1b) {
            try w.writeByte(bytes[i]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[i..], "\x1b[")) {
            if (std.mem.indexOfScalarPos(u8, bytes, i + 2, 'm')) |end| {
                try sgr(w, bytes[i + 2 .. end]);
                i = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, bytes[i..], "\x1b]8;;")) {
            if (std.mem.indexOfPos(u8, bytes, i + 5, "\x1b\\")) |end| {
                const url = bytes[i + 5 .. end];
                if (url.len == 0) try w.writeAll("⟨/link⟩") else try w.print("⟨link {s}⟩", .{url});
                i = end + 2;
                continue;
            }
        }
        try w.writeAll("␛");
        i += 1;
    }
}

fn sgr(w: *std.Io.Writer, params: []const u8) !void {
    if (params.len == 0 or std.mem.eql(u8, params, "0")) return w.writeAll("⟨/⟩");
    try w.writeAll("⟨");
    var codes = std.mem.splitScalar(u8, params, ';');
    while (codes.next()) |code| {
        const letter: ?u8 = if (code.len == 1) switch (code[0]) {
            '1' => 'b',
            '2' => 'd',
            '3' => 'i',
            '4' => 'u',
            '7' => 'r',
            '9' => 's',
            else => null,
        } else null;
        if (letter) |c| try w.writeByte(c) else try w.writeAll(code);
    }
    try w.writeAll("⟩");
}
