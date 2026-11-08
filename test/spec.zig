//! Runs the CommonMark examples through the parser and the HTML renderer,
//! and reports passes per section.
//!
//! usage: spec SPEC_JSON [EXAMPLE | --time FILE | --html FILE]
//! With an example number, prints that example's input, expected and actual output.
//! With --time, parses FILE and prints how long that took; with --html,
//! prints FILE as HTML.

const std = @import("std");
const md = @import("md");

const Example = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    section: []const u8,
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
        try out.writeAll("usage: spec SPEC_JSON [EXAMPLE | --time FILE | --html FILE]\n");
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
    if (args.len > 3 and std.mem.eql(u8, args[2], "--html")) {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, args[3], arena, .unlimited);
        try out.writeAll(try render(arena, source));
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
        } else {
            try t.failed.append(arena, ex.example);
        }
    }

    var passed: u32 = 0;
    for (sections.items) |t| {
        passed += t.passed;
        try out.print("{s: <28} {d: >3}/{d: <3}", .{ t.name, t.passed, t.total });
        if (t.failed.items.len > 0) {
            try out.writeAll("  failing:");
            for (t.failed.items) |n| try out.print(" {d}", .{n});
        }
        try out.writeByte('\n');
    }
    try out.print("\n{d}/{d} pass\n", .{ passed, examples.len });
    return if (passed == examples.len) 0 else 1;
}

fn render(arena: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    const ast = try md.parse(arena, markdown);
    var out: std.Io.Writer.Allocating = .init(arena);
    try md.html.render(ast, &out.writer);
    return out.written();
}
