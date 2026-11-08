//! Display widths in terminal columns, from tables generated at build time.

const std = @import("std");
const table = @import("width_table");

/// Columns for one code point: 0 for combining and format characters, 2 for
/// wide ones, 1 otherwise. Control characters never reach this point.
pub fn ofCodepoint(c: u21) u2 {
    if (c < 0x300) return 1;
    if (inRanges(&table.zero, c)) return 0;
    if (inRanges(&table.wide, c)) return 2;
    return 1;
}

/// Columns for a string. A byte that is not valid UTF-8 counts as one.
pub fn ofString(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            total += 1;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            total += 1;
            i += 1;
            continue;
        };
        const c = if (i + len <= s.len) std.unicode.utf8Decode(s[i..][0..len]) catch null else null;
        if (c) |cp| {
            total += ofCodepoint(cp);
            i += len;
        } else {
            total += 1;
            i += 1;
        }
    }
    return total;
}

fn inRanges(ranges: []const [2]u21, c: u21) bool {
    return std.sort.binarySearch([2]u21, ranges, c, struct {
        fn order(key: u21, range: [2]u21) std.math.Order {
            if (key < range[0]) return .lt;
            if (key > range[1]) return .gt;
            return .eq;
        }
    }.order) != null;
}

const testing = std.testing;

test ofCodepoint {
    try testing.expectEqual(1, ofCodepoint('a'));
    try testing.expectEqual(2, ofCodepoint(0x65E5)); // 日
    try testing.expectEqual(2, ofCodepoint(0x1F33F)); // herb
    try testing.expectEqual(2, ofCodepoint(0xFF21)); // fullwidth A
    try testing.expectEqual(0, ofCodepoint(0x301)); // combining acute
    try testing.expectEqual(0, ofCodepoint(0x200B)); // zero width space
    try testing.expectEqual(0, ofCodepoint(0xFE0F)); // variation selector
    try testing.expectEqual(1, ofCodepoint(0xAD)); // soft hyphen
    try testing.expectEqual(1, ofCodepoint(0x2500)); // box drawing
}

test ofString {
    try testing.expectEqual(5, ofString("hello"));
    try testing.expectEqual(6, ofString("日本語"));
    try testing.expectEqual(1, ofString("e\u{301}"));
    try testing.expectEqual(2, ofString("\xff\xfe"));
}
