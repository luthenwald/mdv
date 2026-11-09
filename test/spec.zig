//! Runs the CommonMark examples through the parser and the HTML renderer
//! with the extensions off, then the examples of the GFM extensions we
//! support with them on, and reports passes per section. The CommonMark
//! examples that read differently with the extensions on are listed as a
//! note.
//!
//! usage: spec SPEC_JSON GFM_SPEC [EXAMPLE | gfm EXAMPLE | --time FILE | --html FILE]
//! With an example number, prints that example's input, expected and actual output.
//! With --time, parses FILE and prints how long that took; with --html,
//! prints FILE as HTML. Both use the extensions.

const std = @import("std");
const md = @import("md");

const Example = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    section: []const u8,
};

/// The sections of `GFM_SPEC` for the extensions mdv supports.
const gfm_sections = [_][]const u8{
    "Tables (extension)",
    "Strikethrough (extension)",
    "Task list items (extension)",
};

const usage = "usage: spec SPEC_JSON GFM_SPEC [EXAMPLE | gfm EXAMPLE | --time FILE | --html FILE]\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try out.writeAll(usage);
        return 2;
    }
    const json = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const examples = try std.json.parseFromSliceLeaky([]Example, arena, json, .{ .ignore_unknown_fields = true });
    const extensions = try gfmExamples(arena, try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited));

    const rest = args[3..];
    if (rest.len > 1 and std.mem.eql(u8, rest[0], "--time")) {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, rest[1], arena, .unlimited);
        const runs = 20;
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..runs) |_| {
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            _ = try md.parse(scratch.allocator(), source, .{});
        }
        const ns = start.untilNow(io, .awake).nanoseconds;
        try out.print("{s}: {d} KB parsed in {d:.2} ms\n", .{ rest[1], source.len / 1024, @as(f64, @floatFromInt(ns)) / runs / 1e6 });
        return 0;
    }
    if (rest.len > 1 and std.mem.eql(u8, rest[0], "--html")) {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, rest[1], arena, .unlimited);
        try out.writeAll(try render(arena, source, .{}));
        return 0;
    }
    if (rest.len > 0) {
        const gfm = std.mem.eql(u8, rest[0], "gfm");
        const number = std.fmt.parseInt(u32, rest[if (gfm) 1 else 0], 10) catch {
            try out.writeAll(usage);
            return 2;
        };
        for (if (gfm) extensions else examples) |ex| if (ex.example == number) {
            try out.print("example {d}, {s}\n\n-- markdown\n{s}-- expected\n{s}-- actual\n{s}", .{
                ex.example, ex.section, ex.markdown, ex.html, try render(arena, ex.markdown, .{ .gfm = gfm }),
            });
            return 0;
        };
        try out.print("no example {d}\n", .{number});
        return 2;
    }

    const commonmark = try tally(arena, out, examples, .{ .gfm = false });
    try out.print("\n{d}/{d} pass\n\n", .{ commonmark, examples.len });
    const gfm = try tally(arena, out, extensions, .{});
    try out.print("\n{d}/{d} pass with the extensions\n", .{ gfm, extensions.len });

    var differ: std.ArrayList(u32) = .empty;
    for (examples) |ex| {
        if (!std.mem.eql(u8, try render(arena, ex.markdown, .{}), ex.html)) try differ.append(arena, ex.example);
    }
    if (differ.items.len > 0) {
        try out.print("\nwith the extensions on, {d}/{d} CommonMark examples read differently:", .{ differ.items.len, examples.len });
        for (differ.items) |n| try out.print(" {d}", .{n});
        try out.writeByte('\n');
    }
    return if (commonmark == examples.len and gfm == extensions.len) 0 else 1;
}

/// Runs the examples and prints passes per section. Returns the passes.
fn tally(arena: std.mem.Allocator, out: *std.Io.Writer, examples: []const Example, options: md.Options) !usize {
    const Tally = struct {
        name: []const u8,
        total: u32 = 0,
        passed: u32 = 0,
        failed: std.ArrayList(u32) = .empty,
    };
    var sections: std.ArrayList(Tally) = .empty;
    for (examples) |ex| {
        if (sections.items.len == 0 or !std.mem.eql(u8, sections.getLast().name, ex.section)) {
            try sections.append(arena, .{ .name = ex.section });
        }
        const t = &sections.items[sections.items.len - 1];
        t.total += 1;
        const actual = try render(arena, ex.markdown, options);
        if (std.mem.eql(u8, actual, ex.html)) {
            t.passed += 1;
        } else {
            try t.failed.append(arena, ex.example);
        }
    }

    var passed: usize = 0;
    for (sections.items) |t| {
        passed += t.passed;
        try out.print("{s: <28} {d: >3}/{d: <3}", .{ t.name, t.passed, t.total });
        if (t.failed.items.len > 0) {
            try out.writeAll("  failing:");
            for (t.failed.items) |n| try out.print(" {d}", .{n});
        }
        try out.writeByte('\n');
    }
    return passed;
}

/// The examples of the supported extensions in a spec in the format of
/// `spec.txt`: fenced by 32 backticks and `example`, the markdown apart
/// from the HTML by a line holding a dot, `→` for a tab. Numbered in file
/// order, all examples counted, as the reference runner does.
const fence: [32]u8 = @splat('`');

fn gfmExamples(arena: std.mem.Allocator, spec: []const u8) ![]const Example {
    var examples: std.ArrayList(Example) = .empty;
    var section: []const u8 = "";
    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, spec, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            const text = std.mem.trimStart(u8, line, "#");
            if (text.len > 0 and text[0] == ' ') section = text[1..];
            continue;
        }
        if (!std.mem.startsWith(u8, line, fence ++ " example")) continue;
        number += 1;
        var parts: [2]std.ArrayList(u8) = .{ .empty, .empty };
        var part: usize = 0;
        while (lines.next()) |inner| {
            if (std.mem.eql(u8, inner, &fence)) break;
            if (part == 0 and std.mem.eql(u8, inner, ".")) {
                part = 1;
                continue;
            }
            try parts[part].appendSlice(arena, inner);
            try parts[part].append(arena, '\n');
        }
        for (gfm_sections) |name| if (std.mem.eql(u8, section, name)) {
            try examples.append(arena, .{
                .markdown = try std.mem.replaceOwned(u8, arena, parts[0].items, "→", "\t"),
                .html = try std.mem.replaceOwned(u8, arena, parts[1].items, "→", "\t"),
                .example = number,
                .section = section,
            });
        };
    }
    return examples.items;
}

fn render(arena: std.mem.Allocator, markdown: []const u8, options: md.Options) ![]const u8 {
    const ast = try md.parse(arena, markdown, options);
    var out: std.Io.Writer.Allocating = .init(arena);
    try md.html.render(ast, &out.writer);
    return out.written();
}
