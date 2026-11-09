//! Draws mdv's styled output as an SVG picture of a terminal, for the
//! readme. Text sits on a grid of cells: each run of one style is placed
//! at its column and stretched to the columns it takes, so box lines, wide
//! characters and emoji line up in whatever monospace font the viewer has.
//!
//! Only what mdv emits is understood: SGR resets, bold, dim, italic,
//! underline, strikethrough and the sixteen palette colors, and OSC 8
//! hyperlinks, which are dropped since a picture cannot be clicked. Any
//! other escape is an error, so the picture never shows something wrong.
//!
//! The colors are Ghostty's "GitHub Light Colorblind" theme, and "GitHub
//! Dark Colorblind" when the viewer prefers a dark scheme.

const std = @import("std");
const width = @import("width");

/// Sizes in tenths of a pixel, so the output is the same everywhere.
const font_size = 140;
const cell = 84;
const line = 180;
const pad = 200;
const baseline = 130;

const Theme = struct {
    background: []const u8,
    foreground: []const u8,
    palette: [16][]const u8,
};

const light: Theme = .{
    .background = "#ffffff",
    .foreground = "#24292f",
    .palette = .{
        "#24292f", "#b35900", "#0550ae", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
        "#57606a", "#8a4600", "#0969da", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f",
    },
};

const dark: Theme = .{
    .background = "#0d1117",
    .foreground = "#c9d1d9",
    .palette = .{
        "#484f58", "#ec8e2c", "#58a6ff", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
        "#6e7681", "#fdac54", "#79c0ff", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff",
    },
};

const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    color: ?u4 = null,
};

const Run = struct {
    row: usize,
    column: usize,
    columns: usize,
    text: []const u8,
    style: Style,
};

/// Writes the picture of `command` printing `output`, an SVG document, to `w`.
pub fn render(arena: std.mem.Allocator, w: *std.Io.Writer, command: []const u8, output: []const u8) !void {
    var runs: std.ArrayList(Run) = .empty;
    try runs.append(arena, .{ .row = 0, .column = 0, .columns = 1, .text = "$", .style = .{ .dim = true } });
    try runs.append(arena, .{ .row = 0, .column = 2, .columns = width.ofString(command), .text = command, .style = .{} });

    var rows: usize = 1;
    var widest: usize = 80;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    while (lines.next()) |bytes| : (rows += 1) {
        const columns = try parseLine(arena, &runs, rows, bytes);
        widest = @max(widest, columns);
    }

    const wide = 2 * pad + widest * cell;
    const high = 2 * pad + rows * line;
    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{f}" height="{f}" viewBox="0 0 {f} {f}" role="img" aria-label="{s}">
        \\<title>{s}</title>
        \\<style>
        \\
    , .{ px(wide), px(high), px(wide), px(high), command, command });
    try theme(w, light);
    try w.writeAll("@media (prefers-color-scheme: dark) {\n");
    try theme(w, dark);
    try w.writeAll("}\n");
    try w.print(
        \\.bg {{ fill: var(--bg); stroke: var(--fg); stroke-opacity: 0.15; }}
        \\text {{ font: {f}px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; fill: var(--fg); white-space: pre; }}
        \\.b {{ font-weight: 700; }}
        \\.i {{ font-style: italic; }}
        \\.u {{ text-decoration: underline; }}
        \\.s {{ text-decoration: line-through; }}
        \\.u.s {{ text-decoration: underline line-through; }}
        \\.d {{ fill-opacity: 0.5; }}
        \\
    , .{px(font_size)});
    for (0..16) |i| try w.print(".c{d} {{ fill: var(--c{d}); }}\n", .{ i, i });
    try w.print(
        \\</style>
        \\<rect class="bg" x="0.5" y="0.5" width="{f}" height="{f}" rx="12"/>
        \\
    , .{ px(wide - 10), px(high - 10) });
    for (runs.items) |run| try text(w, run);
    try w.writeAll("</svg>\n");
}

fn theme(w: *std.Io.Writer, t: Theme) !void {
    try w.print("svg {{ --bg: {s}; --fg: {s};", .{ t.background, t.foreground });
    for (t.palette, 0..) |color, i| try w.print(" --c{d}: {s};", .{ i, color });
    try w.writeAll(" }\n");
}

/// Splits one line of output into runs of one style, without the spaces
/// around them. Returns the columns the line takes.
fn parseLine(arena: std.mem.Allocator, runs: *std.ArrayList(Run), row: usize, bytes: []const u8) !usize {
    var style: Style = .{};
    var column: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            if (std.mem.startsWith(u8, bytes[i..], "\x1b[")) {
                const end = std.mem.indexOfScalarPos(u8, bytes, i + 2, 'm') orelse return error.UnknownEscape;
                style = try sgr(style, bytes[i + 2 .. end]);
                i = end + 1;
            } else if (std.mem.startsWith(u8, bytes[i..], "\x1b]8;;")) {
                const end = std.mem.indexOfPos(u8, bytes, i + 5, "\x1b\\") orelse return error.UnknownEscape;
                i = end + 2;
            } else return error.UnknownEscape;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, bytes, i, 0x1b) orelse bytes.len;
        const chunk = bytes[i..end];
        const lead = chunk.len - std.mem.trimStart(u8, chunk, " ").len;
        const body = std.mem.trim(u8, chunk, " ");
        if (body.len > 0) try runs.append(arena, .{
            .row = row,
            .column = column + lead,
            .columns = width.ofString(body),
            .text = body,
            .style = style,
        });
        column += width.ofString(chunk);
        i = end;
    }
    return column;
}

fn sgr(current: Style, params: []const u8) !Style {
    var style = current;
    var codes = std.mem.splitScalar(u8, params, ';');
    while (codes.next()) |code| {
        const n = std.fmt.parseInt(u8, code, 10) catch if (code.len == 0) 0 else return error.UnknownEscape;
        switch (n) {
            0 => style = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = true,
            9 => style.strike = true,
            30...37 => style.color = @intCast(n - 30),
            90...97 => style.color = @intCast(n - 90 + 8),
            else => return error.UnknownEscape,
        }
    }
    return style;
}

fn text(w: *std.Io.Writer, run: Run) !void {
    try w.print("<text x=\"{f}\" y=\"{f}\" textLength=\"{f}\" lengthAdjust=\"spacingAndGlyphs\"", .{
        px(pad + run.column * cell),
        px(pad + run.row * line + baseline),
        px(run.columns * cell),
    });
    const s = run.style;
    if (s.bold or s.dim or s.italic or s.underline or s.strike or s.color != null) {
        try w.writeAll(" class=\"");
        var first = true;
        const flags = [_]struct { on: bool, name: []const u8 }{
            .{ .on = s.bold, .name = "b" },
            .{ .on = s.dim, .name = "d" },
            .{ .on = s.italic, .name = "i" },
            .{ .on = s.underline, .name = "u" },
            .{ .on = s.strike, .name = "s" },
        };
        for (flags) |flag| if (flag.on) {
            if (!first) try w.writeByte(' ');
            try w.writeAll(flag.name);
            first = false;
        };
        if (s.color) |c| {
            if (!first) try w.writeByte(' ');
            try w.print("c{d}", .{c});
        }
        try w.writeByte('"');
    }
    try w.writeByte('>');
    for (run.text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
    try w.writeAll("</text>\n");
}

/// Tenths of a pixel, printed as pixels without a trailing `.0`.
fn px(tenths: usize) Pixels {
    return .{ .tenths = tenths };
}

const Pixels = struct {
    tenths: usize,

    pub fn format(p: Pixels, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{p.tenths / 10});
        if (p.tenths % 10 != 0) try w.print(".{d}", .{p.tenths % 10});
    }
};
