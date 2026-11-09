//! Renders documents through the built mdv in a few fixed forms and
//! compares the output, with its escapes in a visible form, to the files
//! in the golden directory. A table of command-line cases (errors, exit
//! statuses, standard input, several files, the pager, the environment)
//! is compared the same way with the files in its `cli` subdirectory.
//!
//! usage: golden MDV GOLDEN_DIR TOUR [--update]
//! Each `NAME.md` in GOLDEN_DIR, and TOUR as `tour`, is compared with
//! `NAME.txt`; each case with `cli/NAME.txt`. With --update, the expected
//! files are written instead. A `.txt` without a document or a case fails.
//!
//! The visible form: `⟨b⟩` and the other letters for SGR attributes (b
//! bold, d dim, i italic, u underline, s strike), a color's SGR number
//! such as `⟨34⟩`, `⟨/⟩` for a reset, `⟨link URL⟩` and `⟨/link⟩` for a
//! hyperlink, and `␛` for any other escape byte.

const std = @import("std");
const build_options = @import("build_options");

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

/// One run of mdv from inside the golden directory, so that file names in
/// the output are short and the same on every machine.
const Case = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8 = &.{},
    stdin: ?[]const u8 = null,
    /// The shell words its own complaint differently on each system.
    ignore_stderr: bool = false,
};

const cases = [_]Case{
    .{ .name = "help", .args = &.{"--help"} },
    .{ .name = "version", .args = &.{"--version"} },
    .{ .name = "unknown-option", .args = &.{ "--bogus", "text.md" } },
    .{ .name = "width-zero", .args = &.{ "-w", "0", "text.md" } },
    .{ .name = "missing-file", .args = &.{"no-such.md"} },
    .{ .name = "missing-then-real", .args = &.{ "-P", "--color=never", "-w", "40", "no-such.md", "lists.md" } },
    .{ .name = "directory", .args = &.{ "-P", "." } },
    .{ .name = "two-files", .args = &.{ "-P", "--color=always", "-w", "40", "lists.md", "tables.md" } },
    .{ .name = "stdin-between-files", .args = &.{ "-P", "--color=never", "-w", "40", "lists.md", "-", "lists.md" }, .stdin = "# From standard input\n\nA paragraph.\n" },
    .{ .name = "stdin-alone", .args = &.{ "-P", "--color=never" }, .stdin = "*only* stdin\n" },
    .{ .name = "empty-input", .args = &.{ "-P", "--color=never" }, .stdin = "" },
    .{ .name = "pager-cat", .args = &.{ "--paging=always", "--color=never", "-w", "40", "lists.md" }, .env = &.{.{ "MDV_PAGER", "cat" }} },
    .{ .name = "pager-head", .args = &.{ "--paging=always", "--color=never", "-w", "40", "lists.md" }, .env = &.{.{ "MDV_PAGER", "head -1" }} },
    .{ .name = "pager-missing", .args = &.{ "--paging=always", "--color=never", "-w", "40", "lists.md" }, .env = &.{.{ "MDV_PAGER", "no-such-command-anywhere" }}, .ignore_stderr = true },
    .{ .name = "pager-over-pager", .args = &.{ "--paging=always", "--color=never", "-w", "40", "lists.md" }, .env = &.{ .{ "PAGER", "head -2" }, .{ "MDV_PAGER", "head -1" } } },
    .{ .name = "pager-empty-variable", .args = &.{ "--paging=always", "--color=never", "-w", "40", "lists.md" }, .env = &.{ .{ "MDV_PAGER", "" }, .{ "PAGER", "head -1" } } },
    .{ .name = "pager-nothing-to-show", .args = &.{ "--paging=always", "no-such.md" }, .env = &.{.{ "MDV_PAGER", "echo PAGER RAN" }} },
    .{ .name = "no-color", .args = &.{ "-P", "--color=always", "-w", "40", "text.md" }, .env = &.{.{ "NO_COLOR", "1" }} },
    .{ .name = "no-color-empty", .args = &.{ "-P", "--color=always", "-w", "40", "text.md" }, .env = &.{.{ "NO_COLOR", "" }} },
    .{ .name = "columns-50", .args = &.{ "-P", "--color=never", "text.md" }, .env = &.{.{ "COLUMNS", "50" }} },
    .{ .name = "columns-200", .args = &.{ "-P", "--color=never", "text.md" }, .env = &.{.{ "COLUMNS", "200" }} },
    .{ .name = "columns-zero", .args = &.{ "-P", "--color=never", "text.md" }, .env = &.{.{ "COLUMNS", "0" }} },
    .{ .name = "columns-overridden", .args = &.{ "-P", "--color=never", "-w", "120", "text.md" }, .env = &.{.{ "COLUMNS", "50" }} },
    .{ .name = "no-links", .args = &.{ "-P", "--color=always", "--no-links", "-w", "60", "links.md" } },
    .{ .name = "double-dash", .args = &.{ "-P", "--color=never", "--", "-w" } },
};

/// Generous: every case ends in milliseconds.
const case_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: golden MDV GOLDEN_DIR TOUR [--update]\n", .{});
        return 2;
    }
    // The command-line cases run from inside the golden directory.
    const mdv = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
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
    var total: usize = 0;
    for (inputs.items) |input| {
        var actual: std.Io.Writer.Allocating = .init(arena);
        for (forms) |form| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ mdv, "-P" });
            try argv.appendSlice(arena, form.args);
            try argv.append(arena, input.path);
            const result = try std.process.run(arena, io, .{ .argv = argv.items, .environ_map = &environ, .timeout = case_timeout });
            try actual.writer.print("-- {s}\n", .{form.label});
            try record(&actual.writer, result.stdout, result.stderr, result.term);
        }
        total += 1;
        if (!try compare(io, arena, dir, input.name, actual.written(), update)) failed += 1;
    }

    var cli_dir = try dir.createDirPathOpen(io, "cli", .{ .open_options = .{ .iterate = true } });
    defer cli_dir.close(io);
    for (cases) |case| {
        var actual: std.Io.Writer.Allocating = .init(arena);
        var env: std.process.Environ.Map = .init(arena);
        for (case.env) |pair| try env.put(pair[0], pair[1]);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, mdv);
        try argv.appendSlice(arena, case.args);
        const result = try runIn(io, arena, argv.items, &env, dir, case.stdin);
        try actual.writer.print("-- mdv", .{});
        for (case.env) |pair| try actual.writer.print(" {s}={s}", .{ pair[0], pair[1] });
        for (case.args) |arg| try actual.writer.print(" {s}", .{arg});
        if (case.stdin) |text| try actual.writer.print(" < {d} bytes", .{text.len});
        try actual.writer.writeAll("\n");
        try record(&actual.writer, try withoutVersion(arena, result.stdout), if (case.ignore_stderr) "" else result.stderr, result.term);
        total += 1;
        if (!try compare(io, arena, cli_dir, case.name, actual.written(), update)) failed += 1;
    }

    // A golden file whose document or case is gone would pass unnoticed.
    const names = try arena.alloc([]const u8, inputs.items.len);
    for (inputs.items, names) |input, *name| name.* = input.name;
    const case_names = try arena.alloc([]const u8, cases.len);
    for (&cases, case_names) |case, *name| name.* = case.name;
    failed += try orphans(io, arena, dir, "", names);
    failed += try orphans(io, arena, cli_dir, "cli/", case_names);

    if (!update) std.debug.print("golden: {d}/{d} match\n", .{ total - failed, total });
    return if (failed == 0) 0 else 1;
}

const Result = struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term };

/// Runs `argv` inside `dir`, with `env` as its whole environment and
/// `stdin` written to it when given. Both outputs are collected.
fn runIn(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8, env: *const std.process.Environ.Map, dir: std.Io.Dir, stdin: ?[]const u8) !Result {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .environ_map = env,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    if (stdin) |text| {
        // mdv reads everything before it writes, and the texts are short,
        // so the pipe takes them whole.
        try child.stdin.?.writeStreamingAll(io, text);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, case_timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    return .{ .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1), .term = term };
}

fn record(w: *std.Io.Writer, stdout: []const u8, stderr: []const u8, term: std.process.Child.Term) !void {
    try visible(w, stdout);
    if (stderr.len > 0) try w.print("-- stderr\n{s}", .{stderr});
    switch (term) {
        .exited => |code| if (code != 0) try w.print("-- exit {d}\n", .{code}),
        else => try w.writeAll("-- killed\n"),
    }
}

/// The version line reads `mdv <version>`, so a release does not touch the golden files.
fn withoutVersion(arena: std.mem.Allocator, stdout: []const u8) ![]const u8 {
    const line = "mdv " ++ build_options.version ++ "\n";
    if (!std.mem.eql(u8, stdout, line)) return stdout;
    return try arena.dupe(u8, "mdv <version>\n");
}

/// Writes or checks `NAME.txt` in `dir`. True when it matches (or was written).
fn compare(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, actual: []const u8, update: bool) !bool {
    const expected_name = try std.fmt.allocPrint(arena, "{s}.txt", .{name});
    if (update) {
        try dir.writeFile(io, .{ .sub_path = expected_name, .data = actual });
        std.debug.print("wrote {s}\n", .{expected_name});
        return true;
    }
    const expected = dir.readFileAlloc(io, expected_name, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("{s}: no {s}; run `just golden --update`\n", .{ name, expected_name });
            return false;
        },
        else => return err,
    };
    if (std.mem.eql(u8, expected, actual)) return true;
    report(name, expected, actual);
    return false;
}

/// Counts the `.txt` files in `dir` that belong to none of `names`.
fn orphans(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, prefix: []const u8, names: []const []const u8) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        for (names) |name| {
            if (std.mem.eql(u8, name, stem)) break;
        } else {
            std.debug.print("{s}{s}: no document or case for it; remove the file\n", .{ prefix, try arena.dupe(u8, entry.name) });
            count += 1;
        }
    }
    return count;
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
            '9' => 's',
            else => null,
        } else null;
        if (letter) |c| try w.writeByte(c) else try w.writeAll(code);
    }
    try w.writeAll("⟩");
}
