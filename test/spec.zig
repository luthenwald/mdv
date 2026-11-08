//! Runs the CommonMark examples through the parser and the HTML renderer,
//! and reports passes per section.
//!
//! usage: spec SPEC_JSON [EXAMPLE | --time FILE]
//! With an example number, prints that example's input, expected and actual output.
//! With --time, parses FILE and prints how long that took.

const std = @import("std");
const md = @import("md");

const Example = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    section: []const u8,
};

/// Sections whose examples must all pass, apart from the deferred ones.
const block_sections = [_][]const u8{
    "Tabs",                       "Precedence",           "Thematic breaks",    "ATX headings",
    "Setext headings",            "Indented code blocks", "Fenced code blocks", "HTML blocks",
    "Link reference definitions", "Paragraphs",           "Blank lines",        "Block quotes",
    "List items",                 "Lists",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.writeAll("usage: spec SPEC_JSON [EXAMPLE]\n");
        return 2;
    }
    const json = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const examples = try std.json.parseFromSliceLeaky([]Example, arena, json, .{ .ignore_unknown_fields = true });

    if (args.len > 3 and std.mem.eql(u8, args[2], "--time")) {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, args[3], arena, .unlimited);
        const runs = 20;
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..runs) |_| {
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            _ = try md.parse(scratch.allocator(), source);
        }
        const ns = start.untilNow(io, .awake).nanoseconds;
        try out.print("{s}: {d} KB parsed in {d:.2} ms\n", .{ args[3], source.len / 1024, @as(f64, @floatFromInt(ns)) / runs / 1e6 });
        return 0;
    }
    if (args.len > 2) {
        const number = try std.fmt.parseInt(u32, args[2], 10);
        for (examples) |ex| if (ex.example == number) {
            try out.print("example {d}, {s}\n\n-- markdown\n{s}-- expected\n{s}-- actual\n{s}", .{
                ex.example, ex.section, ex.markdown, ex.html, try render(arena, ex.markdown),
            });
            return 0;
        };
        try out.print("no example {d}\n", .{number});
        return 2;
    }

    const Tally = struct {
        name: []const u8,
        total: u32 = 0,
        passed: u32 = 0,
        deferred: u32 = 0,
        failed: std.ArrayList(u32) = .empty,
    };
    var sections: std.ArrayList(Tally) = .empty;
    for (examples) |ex| {
        if (sections.items.len == 0 or !std.mem.eql(u8, sections.getLast().name, ex.section)) {
            try sections.append(arena, .{ .name = ex.section });
        }
        const t = &sections.items[sections.items.len - 1];
        t.total += 1;
        const actual = try render(arena, ex.markdown);
        if (std.mem.eql(u8, actual, ex.html)) {
            t.passed += 1;
        } else if (needsInlines(ex) or std.mem.eql(u8, try unescapeTags(arena, actual), ex.html)) {
            // Deferred to inline parsing, as long as the blocks are right.
            if (!try sameBlocks(arena, try unescapeTags(arena, actual), ex.html)) {
                try t.failed.append(arena, ex.example);
                continue;
            }
            t.deferred += 1;
        } else {
            try t.failed.append(arena, ex.example);
        }
    }

    var fatal = false;
    var passed: u32 = 0;
    var deferred: u32 = 0;
    for (sections.items) |t| {
        const counted = isBlockSection(t.name);
        passed += t.passed;
        deferred += t.deferred;
        try out.print("{s: <28} {d: >3}/{d: <3}", .{ t.name, t.passed, t.total });
        if (t.deferred > 0) try out.print("  {d} need inlines", .{t.deferred});
        if (t.failed.items.len > 0) {
            try out.writeAll(if (counted) "  failing:" else "  not yet:");
            for (t.failed.items) |n| try out.print(" {d}", .{n});
            if (counted) fatal = true;
        }
        try out.writeByte('\n');
    }
    try out.print("\n{d}/{d} pass, {d} wait for inline parsing\n", .{ passed, examples.len, deferred });
    return if (fatal) 1 else 0;
}

fn render(arena: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    const ast = try md.parse(arena, markdown);
    var out: std.Io.Writer.Allocating = .init(arena);
    try md.html.render(ast, &out.writer);
    return out.written();
}

fn isBlockSection(name: []const u8) bool {
    for (block_sections) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Whether two outputs have the same block tags in the same order, so that
/// the difference lies inside the blocks.
fn sameBlocks(arena: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    return std.mem.eql(u8, try blockTags(arena, a), try blockTags(arena, b));
}

fn blockTags(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    const names = [_][]const u8{ "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr" };
    var tags: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |at| : (i = at + 1) {
        var j = at + 1;
        if (j < html.len and html[j] == '/') j += 1;
        for (names) |name| {
            if (!std.mem.startsWith(u8, html[j..], name)) continue;
            const after = j + name.len;
            if (after < html.len and std.mem.indexOfScalar(u8, " >/", html[after]) != null) {
                try tags.appendSlice(arena, html[at..after]);
                try tags.append(arena, '>');
                break;
            }
        }
    }
    return tags.items;
}

/// The output with the tags that inline parsing would keep as raw HTML,
/// which the stand-in escapes, turned back into tags.
fn unescapeTags(arena: std.mem.Allocator, actual: []const u8) ![]const u8 {
    const lt = try std.mem.replaceOwned(u8, arena, actual, "&lt;", "<");
    const gt = try std.mem.replaceOwned(u8, arena, lt, "&gt;", ">");
    return std.mem.replaceOwned(u8, arena, gt, "&quot;", "\"");
}

/// Whether an example's expected output depends on inline parsing: emphasis,
/// links, images, code spans, hard breaks, escapes or entities.
fn needsInlines(ex: Example) bool {
    for ([_][]const u8{ "<em>", "<strong>", "<a ", "<img ", "<br />" }) |marker| {
        if (std.mem.indexOf(u8, ex.html, marker) != null) return true;
    }
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, ex.html, i, "<code>")) |at| : (i = at + 1) {
        if (!(at >= 5 and std.mem.eql(u8, ex.html[at - 5 .. at], "<pre>"))) return true;
    }
    return std.mem.indexOfAny(u8, ex.markdown, "\\&") != null;
}
