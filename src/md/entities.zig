//! HTML named character references, from a table generated at build time.

const std = @import("std");
const table = @import("entity_table");

/// The UTF-8 for a reference name without `&` and `;`, such as "amp".
pub fn lookup(name: []const u8) ?[]const u8 {
    const i = std.sort.binarySearch([]const u8, &table.names, name, struct {
        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    }.order) orelse return null;
    return table.values[i];
}

/// The longest name in the table, to bound the scan for one.
pub const max_name_len = blk: {
    @setEvalBranchQuota(100_000);
    var max: usize = 0;
    for (table.names) |name| max = @max(max, name.len);
    break :blk max;
};

pub const Reference = struct {
    /// Past the `;`.
    end: usize,
    /// The UTF-8 it stands for.
    value: []const u8,
};

/// A character reference at `pos`: `&name;`, `&#digits;` or `&#xhex;`. A
/// numeric one is encoded into `buf`; zero, surrogates and code points past
/// U+10FFFF become U+FFFD.
pub fn reference(s: []const u8, pos: usize, buf: *[4]u8) ?Reference {
    if (pos + 2 >= s.len or s[pos] != '&') return null;
    var i = pos + 1;
    if (s[i] == '#') {
        i += 1;
        const hex = i < s.len and (s[i] == 'x' or s[i] == 'X');
        if (hex) i += 1;
        const base: u8 = if (hex) 16 else 10;
        const max_digits: usize = if (hex) 6 else 7;
        const digits = i;
        var value: u32 = 0;
        while (i < s.len and i - digits < max_digits) : (i += 1) {
            value = value * base + (std.fmt.charToDigit(s[i], base) catch break);
        }
        if (i == digits or i >= s.len or s[i] != ';') return null;
        const valid = value != 0 and value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF);
        const len = std.unicode.utf8Encode(if (valid) @intCast(value) else 0xFFFD, buf) catch unreachable;
        return .{ .end = i + 1, .value = buf[0..len] };
    }
    if (!std.ascii.isAlphabetic(s[i])) return null;
    const name = i;
    while (i < s.len and i - name < max_name_len and std.ascii.isAlphanumeric(s[i])) i += 1;
    if (i >= s.len or s[i] != ';') return null;
    return .{ .end = i + 1, .value = lookup(s[name..i]) orelse return null };
}

const testing = std.testing;

test lookup {
    try testing.expectEqualStrings("&", lookup("amp").?);
    try testing.expectEqualStrings("\u{C6}", lookup("AElig").?);
    // Two code points in one reference.
    try testing.expectEqualStrings("\u{2242}\u{338}", lookup("NotEqualTilde").?);
    try testing.expectEqual(null, lookup("amp;"));
    try testing.expectEqual(null, lookup("ampx"));
    try testing.expectEqual(null, lookup(""));
}

test max_name_len {
    try testing.expectEqual(31, max_name_len);
}

test reference {
    var buf: [4]u8 = undefined;
    const cases = [_]struct { in: []const u8, out: ?[]const u8 }{
        .{ .in = "&amp;x", .out = "&" },
        .{ .in = "&#35;", .out = "#" },
        .{ .in = "&#X22;", .out = "\"" },
        .{ .in = "&#0;", .out = "\u{FFFD}" },
        .{ .in = "&#xD800;", .out = "\u{FFFD}" },
        .{ .in = "&#1234567;", .out = "\u{FFFD}" },
        .{ .in = "&#12345678;", .out = null },
        .{ .in = "&#;", .out = null },
        .{ .in = "&nosuch;", .out = null },
        .{ .in = "&amp", .out = null },
        .{ .in = "&1amp;", .out = null },
    };
    for (cases) |case| {
        const got = reference(case.in, 0, &buf);
        if (case.out) |out| {
            try testing.expectEqualStrings(out, got.?.value);
        } else {
            try testing.expectEqual(null, got);
        }
    }
    try testing.expectEqual(5, reference("&amp;x", 0, &buf).?.end);
}
