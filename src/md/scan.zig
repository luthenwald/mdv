//! Small scanners for the syntax CommonMark recognizes at the start of a line,
//! and for the pieces of links and tags that inline parsing will reuse.
//! Each one looks at a slice and reports how much of it matched.

const std = @import("std");

pub fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Whitespace as the tag and link grammar means it, line endings included.
pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

/// ASCII punctuation, the characters a backslash can escape.
pub fn isEscapable(c: u8) bool {
    return std.ascii.isPunctuation(c);
}

/// Whether `s` holds only spaces and tabs.
pub fn isBlank(s: []const u8) bool {
    for (s) |c| if (!isSpaceOrTab(c)) return false;
    return true;
}

/// Spaces and tabs, at most one line ending, then spaces and tabs.
pub fn spaceAndNewline(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    if (i < s.len and s[i] == '\n') {
        i += 1;
        while (i < s.len and isSpaceOrTab(s[i])) i += 1;
    }
    return i;
}

/// Characters that may start a block other than a paragraph.
pub fn maybeSpecial(s: []const u8) bool {
    if (s.len == 0) return false;
    return switch (s[0]) {
        '#', '`', '~', '*', '+', '_', '=', '<', '>', '-', '0'...'9', '|', ':' => true,
        else => false,
    };
}

/// Three or more of the same `*`, `-` or `_`, with only spaces and tabs between and after.
pub fn thematicBreak(s: []const u8) bool {
    if (s.len == 0 or (s[0] != '*' and s[0] != '-' and s[0] != '_')) return false;
    var count: usize = 0;
    for (s) |c| {
        if (c == s[0]) count += 1 else if (!isSpaceOrTab(c)) return false;
    }
    return count >= 3;
}

pub const AtxOpener = struct {
    level: u8,
    /// The `#`s and the spaces or tabs after them.
    len: usize,
};

/// One to six `#`, then a space, a tab or the end of the line.
pub fn atxOpener(s: []const u8) ?AtxOpener {
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < s.len and !isSpaceOrTab(s[n])) return null;
    var len = n;
    while (len < s.len and isSpaceOrTab(s[len])) len += 1;
    return .{ .level = @intCast(n), .len = len };
}

/// The text of an ATX heading without its optional closing sequence of `#`s.
pub fn atxContent(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and isSpaceOrTab(s[end - 1])) end -= 1;
    var hashes = end;
    while (hashes > 0 and s[hashes - 1] == '#') hashes -= 1;
    if (hashes == end) return s[0..end];
    // The closing sequence needs a space or tab before it, or nothing at all.
    if (hashes == 0) return s[0..0];
    if (!isSpaceOrTab(s[hashes - 1])) return s[0..end];
    return std.mem.trimEnd(u8, s[0..hashes], " \t");
}

pub const Fence = struct {
    char: u8,
    len: usize,
};

/// Three or more backticks (with no backtick later on the line) or tildes.
pub fn fenceOpener(s: []const u8) ?Fence {
    if (s.len == 0 or (s[0] != '`' and s[0] != '~')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) n += 1;
    if (n < 3) return null;
    if (s[0] == '`' and std.mem.indexOfScalar(u8, s[n..], '`') != null) return null;
    return .{ .char = s[0], .len = n };
}

/// A run of `char`, then only spaces and tabs; returns the run's length.
pub fn fenceCloser(s: []const u8, char: u8) ?usize {
    var n: usize = 0;
    while (n < s.len and s[n] == char) n += 1;
    if (n < 3 or !isBlank(s[n..])) return null;
    return n;
}

/// `=`s (level 1) or `-`s (level 2), then only spaces and tabs.
pub fn setextUnderline(s: []const u8) ?u8 {
    if (s.len == 0 or (s[0] != '=' and s[0] != '-')) return null;
    var n: usize = 0;
    while (n < s.len and s[n] == s[0]) n += 1;
    if (!isBlank(s[n..])) return null;
    return if (s[0] == '=') 1 else 2;
}

pub const ListMarker = struct {
    ordered: bool,
    /// The bullet, or the delimiter after the number.
    char: u8,
    start: u32 = 1,
    len: usize,
};

/// `-`, `+` or `*`, or one to nine digits and `.` or `)`.
pub fn listMarker(s: []const u8) ?ListMarker {
    if (s.len == 0) return null;
    if (s[0] == '-' or s[0] == '+' or s[0] == '*') return .{ .ordered = false, .char = s[0], .len = 1 };
    var n: usize = 0;
    while (n < s.len and n < 10 and std.ascii.isDigit(s[n])) n += 1;
    if (n == 0 or n > 9 or n == s.len or (s[n] != '.' and s[n] != ')')) return null;
    const start = std.fmt.parseInt(u32, s[0..n], 10) catch unreachable;
    return .{ .ordered = true, .char = s[n], .start = start, .len = n + 1 };
}

const block_tags = std.StaticStringMap(void).initComptime(.{
    .{"address"},  .{"article"},    .{"aside"},   .{"base"},     .{"basefont"}, .{"blockquote"},
    .{"body"},     .{"caption"},    .{"center"},  .{"col"},      .{"colgroup"}, .{"dd"},
    .{"details"},  .{"dialog"},     .{"dir"},     .{"div"},      .{"dl"},       .{"dt"},
    .{"fieldset"}, .{"figcaption"}, .{"figure"},  .{"footer"},   .{"form"},     .{"frame"},
    .{"frameset"}, .{"h1"},         .{"h2"},      .{"h3"},       .{"h4"},       .{"h5"},
    .{"h6"},       .{"head"},       .{"header"},  .{"hr"},       .{"html"},     .{"iframe"},
    .{"legend"},   .{"li"},         .{"link"},    .{"main"},     .{"menu"},     .{"menuitem"},
    .{"nav"},      .{"noframes"},   .{"ol"},      .{"optgroup"}, .{"option"},   .{"p"},
    .{"param"},    .{"search"},     .{"section"}, .{"summary"},  .{"table"},    .{"tbody"},
    .{"td"},       .{"tfoot"},      .{"th"},      .{"thead"},    .{"title"},    .{"tr"},
    .{"track"},    .{"ul"},
});

const raw_tags = [_][]const u8{ "pre", "script", "style", "textarea" };

/// Which of the seven kinds of HTML block `s` starts, if any. Kind 7 is
/// reported too; the caller knows whether it may interrupt a paragraph.
pub fn htmlBlockStart(s: []const u8) ?u8 {
    if (s.len < 2 or s[0] != '<') return null;
    // 1: <pre, <script, <style or <textarea, then whitespace, '>' or the end.
    for (raw_tags) |name| {
        if (std.ascii.startsWithIgnoreCase(s[1..], name)) {
            const rest = s[1 + name.len ..];
            if (rest.len == 0 or isWhitespace(rest[0]) or rest[0] == '>') return 1;
        }
    }
    if (std.mem.startsWith(u8, s, "<!--")) return 2;
    if (std.mem.startsWith(u8, s, "<?")) return 3;
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return 5;
    if (s[1] == '!' and s.len > 2 and std.ascii.isAlphabetic(s[2])) return 4;
    // 6: a block-level tag name, opening or closing.
    const name_start: usize = if (s[1] == '/') 2 else 1;
    var name_end = name_start;
    while (name_end < s.len and std.ascii.isAlphanumeric(s[name_end])) name_end += 1;
    if (name_end > name_start and name_end - name_start <= 10) {
        var lower: [10]u8 = undefined;
        const name = std.ascii.lowerString(&lower, s[name_start..name_end]);
        if (block_tags.has(name)) {
            const rest = s[name_end..];
            if (rest.len == 0 or isWhitespace(rest[0]) or rest[0] == '>' or
                std.mem.startsWith(u8, rest, "/>")) return 6;
        }
    }
    // 7: one complete open or closing tag, and nothing else on the line.
    const end = openTag(s, 0) orelse closingTag(s, 0) orelse return null;
    for (s[end..]) |c| if (!isWhitespace(c)) return null;
    return 7;
}

/// Whether `line` ends an HTML block of `kind` (1 to 5; 6 and 7 end at a blank line).
pub fn htmlBlockEnd(kind: u8, line: []const u8) bool {
    return switch (kind) {
        1 => closesRawTag(line),
        2 => std.mem.indexOf(u8, line, "-->") != null,
        3 => std.mem.indexOf(u8, line, "?>") != null,
        4 => std.mem.indexOfScalar(u8, line, '>') != null,
        5 => std.mem.indexOf(u8, line, "]]>") != null,
        else => false,
    };
}

/// Whether `line` holds `</pre>`, `</script>`, `</style>` or `</textarea>`, in any case.
fn closesRawTag(line: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "</")) |at| : (i = at + 2) {
        const rest = line[at + 2 ..];
        for (raw_tags) |name| {
            if (std.ascii.startsWithIgnoreCase(rest, name) and rest.len > name.len and rest[name.len] == '>') return true;
        }
    }
    return false;
}

fn tagName(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len or !std.ascii.isAlphabetic(s[pos])) return null;
    var i = pos + 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    return i;
}

fn skipWhitespace(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and isWhitespace(s[i])) i += 1;
    return i;
}

/// An open tag at `pos`: `<name`, attributes, optional `/`, `>`. Returns the end.
pub fn openTag(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len or s[pos] != '<') return null;
    var i = tagName(s, pos + 1) orelse return null;
    while (true) {
        const after_space = skipWhitespace(s, i);
        if (after_space == i) break;
        i = attribute(s, after_space) orelse {
            i = after_space;
            break;
        };
    }
    if (i < s.len and s[i] == '/') i += 1;
    if (i >= s.len or s[i] != '>') return null;
    return i + 1;
}

/// An attribute name and an optional value, at `pos`. Returns the end.
fn attribute(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len) return null;
    const first = s[pos];
    if (!(std.ascii.isAlphabetic(first) or first == '_' or first == ':')) return null;
    var i = pos + 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or std.mem.indexOfScalar(u8, "_.:-", s[i]) != null)) i += 1;
    const before_value = i;
    const eq = skipWhitespace(s, i);
    if (eq >= s.len or s[eq] != '=') return before_value;
    const value = skipWhitespace(s, eq + 1);
    return attributeValue(s, value) orelse before_value;
}

fn attributeValue(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len) return null;
    if (s[pos] == '"' or s[pos] == '\'') {
        const close = std.mem.indexOfScalarPos(u8, s, pos + 1, s[pos]) orelse return null;
        return close + 1;
    }
    var i = pos;
    while (i < s.len and s[i] > ' ' and std.mem.indexOfScalar(u8, "\"'=<>`", s[i]) == null) i += 1;
    return if (i > pos) i else null;
}

/// A closing tag at `pos`: `</name`, optional whitespace, `>`. Returns the end.
pub fn closingTag(s: []const u8, pos: usize) ?usize {
    if (pos + 1 >= s.len or s[pos] != '<' or s[pos + 1] != '/') return null;
    const i = skipWhitespace(s, tagName(s, pos + 2) orelse return null);
    if (i >= s.len or s[i] != '>') return null;
    return i + 1;
}

/// A link label `[...]` at `pos`: at most 999 characters inside, no unescaped
/// brackets. Returns the end, after the `]`.
pub fn linkLabel(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len or s[pos] != '[') return null;
    var i = pos + 1;
    while (i < s.len) : (i += 1) {
        if (i - pos - 1 > 999) return null;
        switch (s[i]) {
            '\\' => {
                if (i + 1 < s.len and isEscapable(s[i + 1])) i += 1;
            },
            '[' => return null,
            ']' => return i + 1,
            else => {},
        }
    }
    return null;
}

pub const Part = struct {
    /// The inside: without the angle brackets of a destination or the quotes of a title.
    start: usize,
    end: usize,
    /// Where scanning continues.
    next: usize,
};

/// The deepest nesting of parentheses in a link destination. The spec
/// asks for at least three.
pub const max_paren_depth = 32;

/// A link destination at `pos`: `<...>` on one line, or a run without spaces
/// or control characters in which parentheses balance.
pub fn linkDestination(s: []const u8, pos: usize) ?Part {
    if (pos < s.len and s[pos] == '<') {
        var i = pos + 1;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                '>' => return .{ .start = pos + 1, .end = i, .next = i + 1 },
                '<', '\n' => return null,
                '\\' => {
                    if (i + 1 < s.len and isEscapable(s[i + 1])) i += 1;
                },
                else => {},
            }
        }
        return null;
    }
    var i = pos;
    var depth: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isEscapable(s[i + 1])) {
            i += 1;
        } else if (c == '(') {
            // Deeper nesting is refused, which keeps scanning linear.
            if (depth == max_paren_depth) return null;
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        } else if (c <= ' ' or c == 0x7f) {
            break;
        }
    }
    if (depth != 0 or i == pos) return null;
    return .{ .start = pos, .end = i, .next = i };
}

/// A link title at `pos`: in `"`, `'` or `(...)`, with backslash escapes.
pub fn linkTitle(s: []const u8, pos: usize) ?Part {
    if (pos >= s.len) return null;
    const close: u8 = switch (s[pos]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var i = pos + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and isEscapable(s[i + 1])) {
            i += 1;
        } else if (c == close) {
            return .{ .start = pos + 1, .end = i, .next = i + 1 };
        } else if (close == ')' and c == '(') {
            return null;
        }
    }
    return null;
}

/// The cells of a table row: the line trimmed, without a leading pipe or an
/// unescaped trailing one, split at unescaped pipes. A backslash takes the
/// byte after it along, so `\\|` stays inside a cell. A row without
/// content still has one empty cell.
pub const Cells = struct {
    line: []const u8,
    pos: usize,
    end: usize,
    done: bool = false,

    pub fn init(line: []const u8) Cells {
        var start: usize = 0;
        var end = line.len;
        while (start < end and isWhitespace(line[start])) start += 1;
        while (end > start and isWhitespace(line[end - 1])) end -= 1;
        if (start < end and line[start] == '|') start += 1;
        if (end > start and line[end - 1] == '|' and !isEscaped(line, end - 1, start)) end -= 1;
        return .{ .line = line, .pos = start, .end = end };
    }

    /// The next cell, trimmed, as offsets into the line.
    pub fn next(c: *Cells) ?[2]usize {
        if (c.done) return null;
        var i = c.pos;
        while (i < c.end and c.line[i] != '|') : (i += 1) {
            if (c.line[i] == '\\' and i + 1 < c.end) i += 1;
        }
        var a = c.pos;
        var b = i;
        while (a < b and isWhitespace(c.line[a])) a += 1;
        while (b > a and isWhitespace(c.line[b - 1])) b -= 1;
        if (i >= c.end) c.done = true else c.pos = i + 1;
        return .{ a, b };
    }

    pub fn count(line: []const u8) usize {
        var cells = init(line);
        var n: usize = 0;
        while (cells.next()) |_| n += 1;
        return n;
    }
};

/// Whether the byte at `i` follows an odd number of backslashes.
fn isEscaped(s: []const u8, i: usize, start: usize) bool {
    var j = i;
    while (j > start and s[j - 1] == '\\') j -= 1;
    return (i - j) % 2 == 1;
}

/// A table's delimiter row, such as `| :-- | :-: |`: every cell is dashes
/// with an optional colon at either end. Returns the number of columns.
pub fn delimiterRow(line: []const u8) ?usize {
    var cells = Cells.init(line);
    var n: usize = 0;
    while (cells.next()) |c| {
        const cell = line[c[0]..c[1]];
        var i: usize = 0;
        if (i < cell.len and cell[i] == ':') i += 1;
        const dashes = i;
        while (i < cell.len and cell[i] == '-') i += 1;
        if (i == dashes) return null;
        if (i < cell.len and cell[i] == ':') i += 1;
        if (i != cell.len) return null;
        n += 1;
    }
    return n;
}

pub const Autolink = struct {
    /// Past the `>`.
    end: usize,
    /// An email address rather than a URI.
    email: bool,
};

/// `<scheme:rest>` or `<address@domain>` at `pos`.
pub fn autolink(s: []const u8, pos: usize) ?Autolink {
    if (pos >= s.len or s[pos] != '<') return null;
    const scheme = pos + 1;
    if (scheme < s.len and std.ascii.isAlphabetic(s[scheme])) {
        var i = scheme + 1;
        while (i < s.len and i - scheme < 32 and isSchemeChar(s[i])) i += 1;
        if (i - scheme >= 2 and i < s.len and s[i] == ':') {
            i += 1;
            while (i < s.len and s[i] > ' ' and s[i] != '<' and s[i] != '>') i += 1;
            if (i < s.len and s[i] == '>') return .{ .end = i + 1, .email = false };
        }
    }
    var i = pos + 1;
    while (i < s.len and isEmailChar(s[i])) i += 1;
    if (i == pos + 1 or i >= s.len or s[i] != '@') return null;
    i += 1;
    // Labels of at most 63 letters, digits and hyphens, not starting or ending with a hyphen.
    while (true) {
        const label = i;
        if (i >= s.len or !std.ascii.isAlphanumeric(s[i])) return null;
        while (i < s.len and i - label < 63 and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
        if (s[i - 1] == '-') return null;
        if (i < s.len and s[i] == '.') {
            i += 1;
            continue;
        }
        break;
    }
    if (i < s.len and s[i] == '>') return .{ .end = i + 1, .email = true };
    return null;
}

fn isSchemeChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-';
}

fn isEmailChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null;
}

const testing = std.testing;

test "thematic breaks" {
    try testing.expect(thematicBreak("***"));
    try testing.expect(thematicBreak("- - -"));
    try testing.expect(thematicBreak("_\t_ _  "));
    try testing.expect(!thematicBreak("**"));
    try testing.expect(!thematicBreak("*-*"));
    try testing.expect(!thematicBreak("--- a"));
}

test "atx openers and closing sequences" {
    try testing.expectEqual(AtxOpener{ .level = 2, .len = 3 }, atxOpener("## foo").?);
    try testing.expectEqual(AtxOpener{ .level = 1, .len = 1 }, atxOpener("#").?);
    try testing.expect(atxOpener("#5 bolt") == null);
    try testing.expect(atxOpener("####### foo") == null);
    try testing.expectEqualStrings("foo", atxContent("foo ##  "));
    try testing.expectEqualStrings("foo#", atxContent("foo#"));
    try testing.expectEqualStrings("", atxContent("###"));
    try testing.expectEqualStrings("foo \\###", atxContent("foo \\###"));
}

test "fences" {
    try testing.expectEqual(Fence{ .char = '`', .len = 4 }, fenceOpener("````zig").?);
    try testing.expect(fenceOpener("``` a`b") == null);
    try testing.expectEqual(Fence{ .char = '~', .len = 3 }, fenceOpener("~~~ a`b").?);
    try testing.expectEqual(5, fenceCloser("`````  ", '`'));
    try testing.expect(fenceCloser("``` x", '`') == null);
}

test "setext underlines and list markers" {
    try testing.expectEqual(1, setextUnderline("=== "));
    try testing.expectEqual(2, setextUnderline("-"));
    try testing.expect(setextUnderline("= =") == null);
    try testing.expectEqual(ListMarker{ .ordered = true, .char = ')', .start = 12, .len = 3 }, listMarker("12) a").?);
    try testing.expectEqual(ListMarker{ .ordered = false, .char = '+', .len = 1 }, listMarker("+ a").?);
    try testing.expect(listMarker("1234567890. a") == null);
}

test "html block kinds" {
    try testing.expectEqual(1, htmlBlockStart("<pre class=\"x\">"));
    try testing.expectEqual(2, htmlBlockStart("<!-- c"));
    try testing.expectEqual(4, htmlBlockStart("<!DOCTYPE html>"));
    try testing.expectEqual(6, htmlBlockStart("<DIV>"));
    try testing.expectEqual(6, htmlBlockStart("</table"));
    try testing.expectEqual(7, htmlBlockStart("<a href=\"foo\">  "));
    try testing.expectEqual(7, htmlBlockStart("</ins>"));
    try testing.expect(htmlBlockStart("<a href=\"foo\"> text") == null);
    try testing.expect(htmlBlockStart("<33>") == null);
    try testing.expect(htmlBlockEnd(1, "x </STYLE> y"));
    try testing.expect(!htmlBlockEnd(1, "</styles>"));
}

test "tags" {
    const full = "<a foo=\"bar\" bam='b'/>";
    try testing.expectEqual(full.len, openTag(full, 0));
    const lines = "<x data-y=z\n  zz >";
    try testing.expectEqual(lines.len, openTag(lines ++ "rest", 0));
    try testing.expect(openTag("<a  b=>", 0) == null);
    try testing.expect(openTag("<a\"b\">", 0) == null);
    try testing.expectEqual(7, closingTag("</foo >", 0));
}

test "link labels, destinations and titles" {
    try testing.expectEqual(5, linkLabel("[foo]: /u", 0));
    try testing.expectEqual(6, linkLabel("[a\\]b]", 0));
    try testing.expect(linkLabel("[a[b]", 0) == null);
    const d = linkDestination("<a b> x", 0).?;
    try testing.expectEqualStrings("a b", "<a b> x"[d.start..d.end]);
    const e = linkDestination("/u(r(l)) t", 0).?;
    try testing.expectEqualStrings("/u(r(l))", "/u(r(l)) t"[e.start..e.end]);
    try testing.expect(linkDestination("/u(rl", 0) == null);
    const t = linkTitle("'it\\'s' x", 0).?;
    try testing.expectEqualStrings("it\\'s", "'it\\'s' x"[t.start..t.end]);
    try testing.expect(linkTitle("(a(b))", 0) == null);
}

test autolink {
    try testing.expectEqual(Autolink{ .end = 20, .email = false }, autolink("<http://foo.bar.baz>", 0).?);
    try testing.expectEqual(Autolink{ .end = 17, .email = true }, autolink("<foo@bar.example>x", 0).?);
    try testing.expectEqual(null, autolink("<m:abc>", 0));
    try testing.expectEqual(null, autolink("<http://a b>", 0));
    try testing.expectEqual(null, autolink("<foo@-bar>", 0));
    try testing.expectEqual(null, autolink("<foo@bar->", 0));
}

test Cells {
    const line = " | a | b \\| c |` d \\\\|";
    var cells = Cells.init(line);
    try testing.expectEqualStrings("a", line[cells.next().?[0]..][0..1]);
    const second = cells.next().?;
    try testing.expectEqualStrings("b \\| c", line[second[0]..second[1]]);
    const third = cells.next().?;
    try testing.expectEqualStrings("` d \\\\", line[third[0]..third[1]]);
    try testing.expectEqual(null, cells.next());
    try testing.expectEqual(1, Cells.count("|"));
    try testing.expectEqual(2, Cells.count("a | b"));
}

test delimiterRow {
    try testing.expectEqual(2, delimiterRow("| --- | :-: |"));
    try testing.expectEqual(1, delimiterRow(":-"));
    try testing.expectEqual(2, delimiterRow("-|-"));
    try testing.expectEqual(null, delimiterRow("| --- | x |"));
    try testing.expectEqual(null, delimiterRow("| :: |"));
}
