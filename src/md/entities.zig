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
