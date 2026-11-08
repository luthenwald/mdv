//! Spans to bytes: SGR attributes and the sixteen palette colors, nothing else.
//! Knows nothing about markdown.

const std = @import("std");

pub const Color = enum(u5) {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    /// The SGR foreground code: 30 to 37, then 90 to 97.
    fn code(color: Color) u8 {
        const i: u8 = @backingInt(color);
        return if (i <= 8) 29 + i else 81 + i;
    }
};

/// Packed, so styles compare with `==` by their backing integer.
pub const Style = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    reverse: bool = false,
    fg: Color = .default,

    pub const plain: Style = .{};
};

pub const Span = struct {
    text: []const u8,
    style: Style = .plain,
};

pub const Emitter = struct {
    /// Send SGR sequences at all.
    styled: bool,
    /// Send palette colors; off under NO_COLOR, attributes stay.
    colors: bool,

    /// Writes one output line and its newline. A style change is a full reset
    /// followed by the whole new style, and a styled line ends with a reset,
    /// so nothing bleeds into the next line through `head` or a pager.
    pub fn line(e: Emitter, w: *std.Io.Writer, spans: []const Span) std.Io.Writer.Error!void {
        var current: Style = .plain;
        for (spans) |span| {
            if (e.styled) {
                var style = span.style;
                if (!e.colors) style.fg = .default;
                if (style != current) {
                    if (current != Style.plain) try w.writeAll(reset);
                    if (style != Style.plain) try sgr(w, style);
                    current = style;
                }
            }
            try w.writeAll(span.text);
        }
        if (current != Style.plain) try w.writeAll(reset);
        try w.writeByte('\n');
    }
};

const reset = "\x1b[0m";

/// The SGR sequence that sets `style` from a reset state.
fn sgr(w: *std.Io.Writer, style: Style) std.Io.Writer.Error!void {
    const attributes = [_]struct { on: bool, code: u8 }{
        .{ .on = style.bold, .code = 1 },
        .{ .on = style.dim, .code = 2 },
        .{ .on = style.italic, .code = 3 },
        .{ .on = style.underline, .code = 4 },
        .{ .on = style.reverse, .code = 7 },
        .{ .on = style.strike, .code = 9 },
        .{ .on = style.fg != .default, .code = style.fg.code() },
    };
    try w.writeAll("\x1b[");
    var first = true;
    for (attributes) |a| {
        if (!a.on) continue;
        if (!first) try w.writeByte(';');
        try w.print("{d}", .{a.code});
        first = false;
    }
    try w.writeByte('m');
}

const testing = std.testing;

fn expectLine(expected: []const u8, e: Emitter, spans: []const Span) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try e.line(&out.writer, spans);
    try testing.expectEqualStrings(expected, out.written());
}

const styled: Emitter = .{ .styled = true, .colors = true };

test "plain text sends no escapes" {
    try expectLine("hello\n", styled, &.{.{ .text = "hello" }});
}

test "a style change resets and sends the whole new style" {
    const spans = [_]Span{
        .{ .text = "a", .style = .{ .bold = true, .dim = true } },
        .{ .text = "b", .style = .{ .bold = true } },
        .{ .text = "c" },
    };
    try expectLine("\x1b[1;2ma\x1b[0m\x1b[1mb\x1b[0mc\n", styled, &spans);
}

test "a styled line ends with a reset" {
    const spans = [_]Span{.{ .text = "x", .style = .{ .underline = true, .fg = .blue } }};
    try expectLine("\x1b[4;34mx\x1b[0m\n", styled, &spans);
}

test "bright colors and the remaining attributes" {
    const spans = [_]Span{.{ .text = "x", .style = .{ .italic = true, .strike = true, .reverse = true, .fg = .bright_white } }};
    try expectLine("\x1b[3;7;9;97mx\x1b[0m\n", styled, &spans);
}

test "without colors the attributes stay" {
    const spans = [_]Span{.{ .text = "x", .style = .{ .bold = true, .fg = .blue } }};
    try expectLine("\x1b[1mx\x1b[0m\n", .{ .styled = true, .colors = false }, &spans);
}

test "a color alone becomes nothing without colors" {
    const spans = [_]Span{ .{ .text = "a", .style = .{ .fg = .blue } }, .{ .text = "b" } };
    try expectLine("ab\n", .{ .styled = true, .colors = false }, &spans);
}

test "unstyled output is the text alone" {
    const spans = [_]Span{ .{ .text = "a", .style = .{ .bold = true } }, .{ .text = "b" } };
    try expectLine("ab\n", .{ .styled = false, .colors = false }, &spans);
}
