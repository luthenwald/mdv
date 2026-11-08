//! The syntax tree as HTML, the way the reference implementations print it.
//! Used only to check the parser against the CommonMark examples.

const std = @import("std");
const Ast = @import("Ast.zig");

pub fn render(ast: Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var r: Renderer = .{ .ast = ast, .w = w };
    try r.node(0, false);
}

const Renderer = struct {
    ast: Ast,
    w: *std.Io.Writer,
    /// The last byte written, for `cr`.
    last: u8 = '\n',

    fn lit(r: *Renderer, s: []const u8) !void {
        if (s.len == 0) return;
        try r.w.writeAll(s);
        r.last = s[s.len - 1];
    }

    /// A line ending, unless the output already ends with one.
    fn cr(r: *Renderer) !void {
        if (r.last != '\n') try r.lit("\n");
    }

    fn esc(r: *Renderer, s: []const u8) !void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            const entity: []const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            try r.lit(s[start..i]);
            try r.lit(entity);
            start = i + 1;
        }
        try r.lit(s[start..]);
    }

    /// `tight`: the node sits directly in an item of a tight list, so a
    /// paragraph shows without `<p>`.
    fn node(r: *Renderer, n: Ast.Index, tight: bool) !void {
        const ast = r.ast;
        switch (ast.tag(n)) {
            .document => for (ast.children(n)) |child| try r.node(child, false),
            .block_quote => {
                try r.cr();
                try r.lit("<blockquote>");
                try r.cr();
                for (ast.children(n)) |child| try r.node(child, false);
                try r.cr();
                try r.lit("</blockquote>");
                try r.cr();
            },
            .list => {
                const list = ast.list(n);
                try r.cr();
                if (!list.ordered) {
                    try r.lit("<ul>");
                } else if (list.start == 1) {
                    try r.lit("<ol>");
                } else {
                    var buf: [32]u8 = undefined;
                    try r.lit(std.fmt.bufPrint(&buf, "<ol start=\"{d}\">", .{list.start}) catch unreachable);
                }
                try r.cr();
                for (ast.children(n)) |item| try r.node(item, list.tight);
                try r.cr();
                try r.lit(if (list.ordered) "</ol>" else "</ul>");
                try r.cr();
            },
            .list_item => {
                try r.lit("<li>");
                for (ast.children(n)) |child| try r.node(child, tight);
                try r.lit("</li>");
                try r.cr();
            },
            .paragraph => {
                if (tight) return r.inlines(ast.content(n));
                try r.cr();
                try r.lit("<p>");
                try r.inlines(ast.content(n));
                try r.lit("</p>");
                try r.cr();
            },
            .heading => {
                var open: [4]u8 = "<h0>".*;
                var close: [5]u8 = "</h0>".*;
                open[2] = '0' + ast.leaf(n).level;
                close[3] = open[2];
                try r.cr();
                try r.lit(&open);
                try r.inlines(ast.content(n));
                try r.lit(&close);
                try r.cr();
            },
            .thematic_break => {
                try r.cr();
                try r.lit("<hr />");
                try r.cr();
            },
            .code_block => {
                const info = ast.info(n);
                const word_end = std.mem.indexOfAny(u8, info, " \t\n") orelse info.len;
                try r.cr();
                try r.lit("<pre><code");
                if (word_end > 0) {
                    try r.lit(" class=\"language-");
                    try r.esc(info[0..word_end]);
                    try r.lit("\"");
                }
                try r.lit(">");
                try r.esc(ast.content(n));
                try r.lit("</code></pre>");
                try r.cr();
            },
            .html_block => {
                try r.cr();
                try r.lit(ast.content(n));
                try r.cr();
            },
        }
    }

    /// Inline content. Until the inline parser exists, the text is escaped as
    /// it is, with the spaces around line endings dropped as soft breaks do.
    fn inlines(r: *Renderer, s: []const u8) !void {
        var lines = std.mem.splitScalar(u8, s, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try r.lit("\n");
            first = false;
            try r.esc(std.mem.trim(u8, line, " "));
        }
    }
};

const testing = std.testing;

fn expectHtml(markdown: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try @import("block.zig").parse(arena.allocator(), markdown);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(ast, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "a tight list in a quote" {
    try expectHtml("> 1. a\n> 2. b\n", "<blockquote>\n<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n</blockquote>\n");
}

test "a loose list starting at 3, code with a language" {
    try expectHtml("3) a\n\n4) b\n\n```zig x\n<&>\n```\n",
        \\<ol start="3">
        \\<li>
        \\<p>a</p>
        \\</li>
        \\<li>
        \\<p>b</p>
        \\</li>
        \\</ol>
        \\<pre><code class="language-zig">&lt;&amp;&gt;
        \\</code></pre>
        \\
    );
}
