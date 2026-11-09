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

/// One step through a string: the code point at `i`, or null for a byte
/// that is not UTF-8, which is one byte wide and one column.
pub const Char = struct {
    code: ?u21,
    len: usize,
};

/// The character at `i` in `s`.
pub fn at(s: []const u8, i: usize) Char {
    const c = s[i];
    if (c < 0x80) return .{ .code = c, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(c) catch return .{ .code = null, .len = 1 };
    if (i + len > s.len) return .{ .code = null, .len = 1 };
    const code = std.unicode.utf8Decode(s[i..][0..len]) catch return .{ .code = null, .len = 1 };
    return .{ .code = code, .len = len };
}

/// Walks a string by character, giving each one's columns. An emoji
/// presentation selector (U+FE0F) after a narrow character widens it to
/// two columns, as terminals draw `❤️`.
pub const Iterator = struct {
    s: []const u8,
    i: usize = 0,

    /// One character, or a narrow character with the emoji presentation
    /// selector that widens it, so that the two are never parted.
    pub const Step = struct {
        char: Char,
        width: usize,
    };

    pub fn next(it: *Iterator) ?Step {
        if (it.i >= it.s.len) return null;
        var char = at(it.s, it.i);
        var w: usize = if (char.code) |c| ofCodepoint(c) else 1;
        if (w == 1 and char.code != null and it.i + char.len < it.s.len) {
            const following = at(it.s, it.i + char.len);
            if (following.code == 0xFE0F) {
                char.len += following.len;
                w = 2;
            }
        }
        it.i += char.len;
        return .{ .char = char, .width = w };
    }
};

/// Columns for a string. A byte that is not valid UTF-8 counts as one.
pub fn ofString(s: []const u8) usize {
    var total: usize = 0;
    var it: Iterator = .{ .s = s };
    while (it.next()) |step| total += step.width;
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
    try testing.expectEqual(2, ofString("\u{2764}\u{FE0F}")); // ❤️ drawn as emoji
    try testing.expectEqual(2, ofString("\u{1F600}\u{FE0F}")); // already wide
    try testing.expectEqual(4, ofString("\u{1F1EF}\u{1F1F5}")); // a flag, two indicators
    try testing.expectEqual(0, ofString("\u{1160}")); // Hangul jungseong filler
    try testing.expectEqual(1, ofString("a\u{AD}") - 1); // soft hyphen shows
}

test at {
    try testing.expectEqual(Char{ .code = 'a', .len = 1 }, at("ab", 0));
    try testing.expectEqual(Char{ .code = 0x65E5, .len = 3 }, at("日", 0));
    try testing.expectEqual(Char{ .code = null, .len = 1 }, at("\xe6\x97", 0));
    try testing.expectEqual(Char{ .code = null, .len = 1 }, at("\x80", 0));
}
