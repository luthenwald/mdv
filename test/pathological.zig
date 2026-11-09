//! The pathological inputs of cmark's `test/pathological_tests.py`, built
//! here and rendered to HTML. Each must give the expected HTML within a
//! second; the times show whether parsing stays linear.
//!
//! usage: pathological [NAME_PART]
//! With a part of a name, runs only the cases whose names contain it.

const std = @import("std");
const md = @import("md");

const limit_ms = 1000;

const Expect = union(enum) {
    /// The HTML holds this, as `re.search` finds the regex in cmark's script.
    contains: []const u8,
    check: *const fn (html: []const u8) bool,
};

const Case = struct {
    name: []const u8,
    input: []const u8,
    expect: Expect,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const filter: []const u8 = if (args.len > 1) args[1] else "";
    var failed: usize = 0;
    // The HTML renderer recurses once per nesting level, and some cases
    // nest 100,000 deep.
    const thread = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run, .{ init.io, arena, filter, &failed });
    thread.join();
    return if (failed == 0) 0 else 1;
}

fn run(io: std.Io, arena: std.mem.Allocator, filter: []const u8, failed: *usize) void {
    runCases(io, arena, filter, failed) catch |err| {
        std.debug.print("pathological: {t}\n", .{err});
        failed.* += 1;
    };
}

fn runCases(io: std.Io, arena: std.mem.Allocator, filter: []const u8, failed: *usize) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var total: usize = 0;
    for (try cases(arena)) |case| {
        if (std.mem.indexOf(u8, case.name, filter) == null) continue;
        total += 1;
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const start = std.Io.Timestamp.now(io, .awake);
        const ast = try md.parse(scratch.allocator(), case.input, .{});
        var html: std.Io.Writer.Allocating = .init(scratch.allocator());
        try md.html.render(ast, &html.writer);
        const ms = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6;
        const right = switch (case.expect) {
            .contains => |s| std.mem.indexOf(u8, html.written(), s) != null,
            .check => |f| f(html.written()),
        };
        const verdict = if (!right) "wrong" else if (ms > limit_ms) "slow" else "ok";
        if (!right or ms > limit_ms) failed.* += 1;
        try out.print("{s: <52} {d: >8.1} ms  {s}\n", .{ case.name, ms, verdict });
        try out.flush();
    }
    try out.print("\n{d}/{d} pass\n", .{ total - failed.*, total });
}

fn cases(a: std.mem.Allocator) ![]const Case {
    const r = struct {
        fn rep(arena: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
            const out = try arena.alloc(u8, s.len * n);
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            return out;
        }
    }.rep;
    const cat = struct {
        fn cat(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
            return std.mem.concat(arena, u8, parts);
        }
    }.cat;

    var nested_lists: std.ArrayList(u8) = .empty;
    for (0..500) |x| {
        try nested_lists.appendNTimes(a, ' ', 2 * x);
        try nested_lists.appendSlice(a, "* a\n");
    }
    var backticks: std.ArrayList(u8) = .empty;
    for (1..2500) |x| {
        try backticks.append(a, 'e');
        try backticks.appendNTimes(a, '`', x);
    }
    // cmark's case picks labels that collide in its hash table; ours keeps
    // the shape: many definitions, and a label that none of them defines.
    var references: std.ArrayList(u8) = .empty;
    for (1..25000) |i| try references.print(a, "[x{d}]: /url\n\n[x0]\n\n", .{i});

    return a.dupe(Case, &.{
        .{
            .name = "nested strong emph",
            .input = try cat(a, &.{ try r(a, "*a **a ", 32500), "b", try r(a, " a** a*", 32500) }),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "<em>a <strong>a ", 32500), "b", try r(a, " a</strong> a</em>", 32500) }) },
        },
        .{
            .name = "many emph closers with no openers",
            .input = try r(a, "a_ ", 32500),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "a_ ", 32499), "a_" }) },
        },
        .{
            .name = "many emph openers with no closers",
            .input = try r(a, "_a ", 32500),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "_a ", 32499), "_a" }) },
        },
        .{
            .name = "many link closers with no openers",
            .input = try r(a, "a]", 32500),
            .expect = .{ .contains = try r(a, "a]", 32500) },
        },
        .{
            .name = "many link openers with no closers",
            .input = try r(a, "[a", 32500),
            .expect = .{ .contains = try r(a, "[a", 32500) },
        },
        .{
            .name = "mismatched openers and closers",
            .input = try r(a, "*a_ ", 25000),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "*a_ ", 24999), "*a_" }) },
        },
        .{
            .name = "issue #389",
            .input = try cat(a, &.{ try r(a, "*a ", 20000), try r(a, "_a*_ ", 20000) }),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "<em>a ", 20000), try r(a, "_a</em>_ ", 19999), "_a</em>_" }) },
        },
        .{
            .name = "openers and closers multiple of 3",
            .input = try cat(a, &.{ "a**b", try r(a, "c* ", 25000) }),
            .expect = .{ .contains = try cat(a, &.{ "a**b", try r(a, "c* ", 24999), "c*" }) },
        },
        .{
            .name = "link openers and emph closers",
            .input = try r(a, "[ a_", 25000),
            .expect = .{ .contains = try r(a, "[ a_", 25000) },
        },
        .{
            .name = "pattern [ (]( repeated",
            .input = try r(a, "[ (](", 40000),
            .expect = .{ .contains = try r(a, "[ (](", 40000) },
        },
        .{
            .name = "pattern ![[]() repeated",
            .input = try r(a, "![[]()", 160000),
            .expect = .{ .contains = try r(a, "![<a href=\"\"></a>", 160000) },
        },
        .{
            .name = "hard link/emph case",
            .input = "**x [a*b**c*](d)",
            .expect = .{ .contains = "**x <a href=\"d\">a<em>b**c</em></a>" },
        },
        .{
            .name = "nested brackets",
            .input = try cat(a, &.{ try r(a, "[", 25000), "a", try r(a, "]", 25000) }),
            .expect = .{ .contains = try cat(a, &.{ try r(a, "[", 25000), "a", try r(a, "]", 25000) }) },
        },
        .{
            .name = "nested block quotes",
            .input = try cat(a, &.{ try r(a, "> ", 25000), "a" }),
            .expect = .{ .contains = try r(a, "<blockquote>\n", 25000) },
        },
        .{
            .name = "deeply nested lists",
            .input = nested_lists.items,
            .expect = .{ .contains = try cat(a, &.{ "<ul>\n", try r(a, "<li>a\n<ul>\n", 499), "<li>a</li>\n</ul>\n", try r(a, "</li>\n</ul>\n", 499) }) },
        },
        .{
            .name = "U+0000 in input",
            .input = "abc\x00de\x00",
            .expect = .{ .contains = "abc\u{FFFD}de\u{FFFD}" },
        },
        .{
            .name = "backticks",
            .input = backticks.items,
            .expect = .{ .check = onlyBackticks },
        },
        .{
            .name = "unclosed links A",
            .input = try r(a, "[a](<b", 30000),
            .expect = .{ .contains = try r(a, "[a](&lt;b", 30000) },
        },
        .{
            .name = "unclosed links B",
            .input = try r(a, "[a](b", 30000),
            .expect = .{ .contains = try r(a, "[a](b", 30000) },
        },
        .{
            .name = "unclosed <!--",
            .input = try cat(a, &.{ "</", try r(a, "<!--", 300000) }),
            .expect = .{ .contains = try cat(a, &.{ "&lt;/", try r(a, "&lt;!--", 300000) }) },
        },
        .{
            .name = "empty lines in deeply nested lists",
            .input = try cat(a, &.{ try r(a, "- ", 30000), "x", try r(a, "\n", 30000) }),
            .expect = .{ .check = tagsAroundX },
        },
        .{
            .name = "empty lines in deeply nested lists in blockquote",
            .input = try cat(a, &.{ "> ", try r(a, "- ", 30000), "x\n", try r(a, ">\n", 30000) }),
            .expect = .{ .check = tagsAroundX },
        },
        .{
            .name = "emph in deep blockquote",
            .input = try cat(a, &.{ try r(a, ">", 100000), try r(a, "a*", 100000) }),
            .expect = .{ .check = paragraphInTags },
        },
        .{
            .name = "references to a label nobody defines",
            .input = references.items,
            .expect = .{ .contains = try r(a, "<p>[x0]</p>\n", 24999) },
        },
        .{
            // cmark checks this one through its CommonMark output.
            .name = "nested inlines",
            .input = try cat(a, &.{ try r(a, "*", 20000), "a", try r(a, "*", 20000) }),
            .expect = .{ .contains = try cat(a, &.{ "<p>", try r(a, "<strong>", 10000), "a", try r(a, "</strong>", 10000), "</p>\n" }) },
        },
    });
}

/// `^<p>[e`]*</p>\n$`
fn onlyBackticks(html: []const u8) bool {
    if (!std.mem.startsWith(u8, html, "<p>") or !std.mem.endsWith(u8, html, "</p>\n")) return false;
    for (html[3 .. html.len - 5]) |c| if (c != 'e' and c != '`') return false;
    return true;
}

/// `^(<\w+>\n?)+x(</\w+>\n)+$`
fn tagsAroundX(html: []const u8) bool {
    var i: usize = 0;
    var opened: usize = 0;
    while (tag(html, i, false)) |end| : (opened += 1) {
        i = end;
        if (i < html.len and html[i] == '\n') i += 1;
    }
    if (opened == 0 or i >= html.len or html[i] != 'x') return false;
    return closingTags(html, i + 1);
}

/// `^(<\w+>\n)+<p>.*</p>\n(</\w+>\n)+$`, the paragraph on one line.
fn paragraphInTags(html: []const u8) bool {
    var i: usize = 0;
    var opened: usize = 0;
    while (!std.mem.startsWith(u8, html[i..], "<p>")) : (opened += 1) {
        i = tag(html, i, false) orelse return false;
        if (i >= html.len or html[i] != '\n') return false;
        i += 1;
    }
    const end = std.mem.indexOfScalarPos(u8, html, i, '\n') orelse return false;
    if (opened == 0 or !std.mem.endsWith(u8, html[i..end], "</p>")) return false;
    return closingTags(html, end + 1);
}

/// `(</\w+>\n)+$` from `i`.
fn closingTags(html: []const u8, start: usize) bool {
    var i = start;
    var closed: usize = 0;
    while (i < html.len) : (closed += 1) {
        i = tag(html, i, true) orelse return false;
        if (i >= html.len or html[i] != '\n') return false;
        i += 1;
    }
    return closed > 0;
}

/// The end of `<\w+>`, or `</\w+>` when `closing`, at `i`.
fn tag(html: []const u8, start: usize, closing: bool) ?usize {
    var i = start;
    if (i >= html.len or html[i] != '<') return null;
    i += 1;
    if (closing) {
        if (i >= html.len or html[i] != '/') return null;
        i += 1;
    }
    const name = i;
    while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '_')) i += 1;
    if (i == name or i >= html.len or html[i] != '>') return null;
    return i + 1;
}
