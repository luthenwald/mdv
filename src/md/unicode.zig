//! The Unicode classes and case folding CommonMark needs, from tables
//! generated at build time.

const std = @import("std");
const table = @import("unicode_table");

/// A punctuation character: general category P or S.
pub fn isPunctuation(c: u21) bool {
    return inRanges(&table.punctuation, c);
}

/// A Unicode whitespace character: a space separator (Zs), tab, line feed,
/// form feed or carriage return.
pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        '\t', '\n', '\x0c', '\r' => true,
        else => inRanges(&table.space, c),
    };
}

/// The full case folding of a code point as UTF-8, or null when it folds to itself.
pub fn fold(c: u21) ?[]const u8 {
    const i = std.sort.binarySearch(u21, &table.fold_keys, c, struct {
        fn order(key: u21, item: u21) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) orelse return null;
    return table.fold_values[i];
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

test isPunctuation {
    for ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~") |c| try testing.expect(isPunctuation(c));
    for ("aZ0 \t") |c| try testing.expect(!isPunctuation(c));
    try testing.expect(isPunctuation(0xA3)); // pound sign, Sc
    try testing.expect(isPunctuation(0x201C)); // left double quotation mark, Pi
    try testing.expect(!isPunctuation(0xE9));
}

test isWhitespace {
    for (" \t\n\x0c\r") |c| try testing.expect(isWhitespace(c));
    try testing.expect(isWhitespace(0xA0));
    try testing.expect(isWhitespace(0x3000));
    try testing.expect(!isWhitespace(0x0b));
    try testing.expect(!isWhitespace(0x200B)); // zero width space is Cf
}

test fold {
    try testing.expectEqualStrings("a", fold('A').?);
    try testing.expectEqualStrings("ss", fold(0x1E9E).?);
    try testing.expectEqualStrings("ss", fold(0xDF).?);
    try testing.expectEqual(null, fold('a'));
}
