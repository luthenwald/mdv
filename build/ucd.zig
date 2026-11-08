//! Reading the Unicode character database files, for the table generators.

const std = @import("std");

pub const Range = [2]u21;

/// The `;`-separated fields of a data line, or null for blank and comment lines.
pub fn recordFields(line: []const u8) ?std.mem.SplitIterator(u8, .scalar) {
    const data = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
    if (data.len == 0) return null;
    return std.mem.splitScalar(u8, data, ';');
}

pub fn parseCode(text: []const u8) !u21 {
    return std.fmt.parseInt(u21, std.mem.trim(u8, text, " "), 16);
}

pub fn parseRange(text: []const u8) !Range {
    const field = std.mem.trim(u8, text, " ");
    if (std.mem.indexOf(u8, field, "..")) |dots|
        return .{ try parseCode(field[0..dots]), try parseCode(field[dots + 2 ..]) };
    const code = try parseCode(field);
    return .{ code, code };
}

/// Sorts the ranges and joins those that touch or overlap, in place.
pub fn merge(ranges: []Range) []Range {
    std.mem.sort(Range, ranges, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a[0] < b[0];
        }
    }.lessThan);
    var len: usize = 0;
    for (ranges) |r| {
        if (len > 0 and r[0] <= ranges[len - 1][1] + 1) {
            ranges[len - 1][1] = @max(ranges[len - 1][1], r[1]);
        } else {
            ranges[len] = r;
            len += 1;
        }
    }
    return ranges[0..len];
}

pub fn writeRanges(w: *std.Io.Writer, name: []const u8, ranges: []const Range) !void {
    try w.print("pub const {s} = [_][2]u21{{\n", .{name});
    for (ranges) |r| try w.print("    .{{ 0x{X}, 0x{X} }},\n", .{ r[0], r[1] });
    try w.writeAll("};\n\n");
}
