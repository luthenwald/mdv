//! What the output goes to: its width, and whether to style and page it.

const std = @import("std");
const cli = @import("../cli.zig");

pub const Terminal = struct {
    width: u16,
    /// Send SGR attributes.
    styled: bool,
    /// Send palette colors (the accent); off under NO_COLOR.
    colors: bool,
    /// Write into the pager instead of stdout.
    page: bool,
};

/// The readable measure; an explicit `--width` goes past it.
pub const max_width = 80;
const fallback_width = 80;

pub const Facts = struct {
    stdout_is_tty: bool,
    /// Columns of the first terminal found among stdout, stderr and /dev/tty.
    measured: ?u16 = null,
    /// `COLUMNS`, when it holds a positive number.
    columns: ?u16 = null,
    /// `NO_COLOR` is set and not empty.
    no_color: bool = false,
};

/// The decisions, from the options and what was found about the environment.
pub fn decide(options: cli.Options, facts: Facts) Terminal {
    const page = switch (options.paging) {
        .auto => facts.stdout_is_tty,
        .always => true,
        .never => false,
    };
    // A pager started at a terminal shows the styles, so auto follows stdout either way.
    const styled = switch (options.color) {
        .auto => facts.stdout_is_tty,
        .always => true,
        .never => false,
    };
    return .{
        .width = options.width orelse @min(facts.measured orelse facts.columns orelse fallback_width, max_width),
        .styled = styled,
        .colors = styled and !facts.no_color,
        .page = page,
    };
}

/// Looks at the real stdout, terminal and environment.
pub fn gather(io: std.Io, env: *const std.process.Environ.Map) std.Io.Cancelable!Facts {
    const stdout = std.Io.File.stdout();
    return .{
        .stdout_is_tty = try stdout.isTty(io),
        .measured = try measure(io),
        .columns = if (env.get("COLUMNS")) |text| std.fmt.parseInt(u16, text, 10) catch null else null,
        .no_color = if (env.get("NO_COLOR")) |text| text.len > 0 else false,
    };
}

fn measure(io: std.Io) std.Io.Cancelable!?u16 {
    if (try columnsOf(io, std.Io.File.stdout())) |n| return n;
    if (try columnsOf(io, std.Io.File.stderr())) |n| return n;
    const tty = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{}) catch return null;
    defer tty.close(io);
    return columnsOf(io, tty);
}

fn columnsOf(io: std.Io, file: std.Io.File) std.Io.Cancelable!?u16 {
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = (try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } })).device_io_control;
    return if (result >= 0 and size.col > 0) size.col else null;
}

const testing = std.testing;

test "at a terminal: styled, paged, capped at 80" {
    const t = decide(.{}, .{ .stdout_is_tty = true, .measured = 120 });
    try testing.expectEqual(Terminal{ .width = 80, .styled = true, .colors = true, .page = true }, t);
}

test "into a pipe: plain, not paged, COLUMNS then 80" {
    try testing.expectEqual(Terminal{ .width = 50, .styled = false, .colors = false, .page = false }, decide(.{}, .{ .stdout_is_tty = false, .columns = 50 }));
    try testing.expectEqual(80, decide(.{}, .{ .stdout_is_tty = false }).width);
}

test "a narrow terminal wins over COLUMNS" {
    try testing.expectEqual(60, decide(.{}, .{ .stdout_is_tty = true, .measured = 60, .columns = 200 }).width);
}

test "an explicit width lifts the cap" {
    try testing.expectEqual(120, decide(.{ .width = 120 }, .{ .stdout_is_tty = true, .measured = 100 }).width);
}

test "NO_COLOR keeps attributes and drops colors" {
    const t = decide(.{}, .{ .stdout_is_tty = true, .no_color = true });
    try testing.expect(t.styled and !t.colors);
}

test "the flags override what was found" {
    const t = decide(.{ .color = .always, .paging = .never }, .{ .stdout_is_tty = false });
    try testing.expect(t.styled and t.colors and !t.page);
    const u = decide(.{ .color = .never, .paging = .always }, .{ .stdout_is_tty = true });
    try testing.expect(!u.styled and !u.colors and u.page);
}
