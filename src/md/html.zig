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
    /// A task item's checkbox, waiting for the item's first paragraph.
    task: ?bool = null,

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
                    try r.w.print("<ol start=\"{d}\">", .{list.start});
                    r.last = '>';
                }
                try r.cr();
                for (ast.children(n)) |item| try r.node(item, list.tight);
                try r.cr();
                try r.lit(if (list.ordered) "</ol>" else "</ul>");
                try r.cr();
            },
            .list_item => {
                try r.lit("<li>");
                r.task = ast.task(n);
                for (ast.children(n)) |child| try r.node(child, tight);
                try r.lit("</li>");
                try r.cr();
            },
            .paragraph => {
                if (tight) {
                    try r.checkbox();
                    return r.inlines(n);
                }
                try r.cr();
                try r.lit("<p>");
                try r.checkbox();
                try r.inlines(n);
                try r.lit("</p>");
                try r.cr();
            },
            .heading => {
                var open: [4]u8 = "<h0>".*;
                var close: [5]u8 = "</h0>".*;
                open[2] = '0' + ast.level(n);
                close[3] = open[2];
                try r.cr();
                try r.lit(&open);
                try r.inlines(n);
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
            .text => try r.esc(ast.content(n)),
            .soft_break => try r.lit("\n"),
            .hard_break => try r.lit("<br />\n"),
            .code_span => {
                try r.lit("<code>");
                try r.esc(ast.content(n));
                try r.lit("</code>");
            },
            .html_inline => try r.lit(ast.content(n)),
            .emphasis => try r.wrap(n, "<em>", "</em>"),
            .strong => try r.wrap(n, "<strong>", "</strong>"),
            .strikethrough => try r.wrap(n, "<del>", "</del>"),
            .link => {
                const link = ast.link(n);
                try r.lit("<a href=\"");
                try r.url(ast.string(link.destination));
                try r.lit("\"");
                try r.title(ast.string(link.title));
                try r.lit(">");
                try r.inlines(n);
                try r.lit("</a>");
            },
            .image => {
                const link = ast.link(n);
                try r.lit("<img src=\"");
                try r.url(ast.string(link.destination));
                try r.lit("\" alt=\"");
                try r.plain(n);
                try r.lit("\"");
                try r.title(ast.string(link.title));
                try r.lit(" />");
            },
        }
    }

    /// As the GFM spec's examples print it.
    fn checkbox(r: *Renderer) !void {
        const done = r.task orelse return;
        r.task = null;
        try r.lit(if (done) "<input checked=\"\" disabled=\"\" type=\"checkbox\"> " else "<input disabled=\"\" type=\"checkbox\"> ");
    }

    fn inlines(r: *Renderer, n: Ast.Index) std.Io.Writer.Error!void {
        for (r.ast.children(n)) |child| try r.node(child, false);
    }

    fn wrap(r: *Renderer, n: Ast.Index, open: []const u8, close: []const u8) !void {
        try r.lit(open);
        try r.inlines(n);
        try r.lit(close);
    }

    fn title(r: *Renderer, s: []const u8) !void {
        if (s.len == 0) return;
        try r.lit(" title=\"");
        try r.esc(s);
        try r.lit("\"");
    }

    /// The text of an image's description, for its `alt`, without markup.
    fn plain(r: *Renderer, n: Ast.Index) std.Io.Writer.Error!void {
        for (r.ast.children(n)) |child| switch (r.ast.tag(child)) {
            .text, .code_span => try r.esc(r.ast.content(child)),
            .soft_break, .hard_break => try r.lit("\n"),
            .html_inline => {},
            else => try r.plain(child),
        };
    }

    /// A destination as an attribute: bytes outside the characters URLs
    /// allow are percent-encoded, existing `%XX` escapes are kept, and HTML
    /// specials are escaped, as commonmark.js does it with mdurl.
    fn url(r: *Renderer, s: []const u8) !void {
        const hex = "0123456789ABCDEF";
        for (s, 0..) |c, i| {
            if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
                try r.lit("%");
            } else if (c == '&') {
                try r.lit("&amp;");
            } else if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ";/?:@=+$,-_.!~*'()#", c) != null) {
                try r.lit(&.{c});
            } else {
                try r.lit(&.{ '%', hex[c >> 4], hex[c & 15] });
            }
        }
    }
};

const testing = std.testing;

fn expectHtml(markdown: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ast = try @import("block.zig").parse(arena.allocator(), markdown, .{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(ast, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "strikethrough between one or two tildes" {
    try expectHtml("~~Hi~~ Hello, ~there~ ~~~not~~~ ~~a~\n", "<p><del>Hi</del> Hello, <del>there</del> ~~~not~~~ ~~a~</p>\n");
    try expectHtml("This ~~has a\n\nnew paragraph~~.\n", "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n");
}

test "task list items" {
    try expectHtml("- [ ] foo\n- [x] bar\n",
        \\<ul>
        \\<li><input disabled="" type="checkbox"> foo</li>
        \\<li><input checked="" disabled="" type="checkbox"> bar</li>
        \\</ul>
        \\
    );
    try expectHtml("- [X] a\n\n- [ ] b\n",
        \\<ul>
        \\<li>
        \\<p><input checked="" disabled="" type="checkbox"> a</p>
        \\</li>
        \\<li>
        \\<p><input disabled="" type="checkbox"> b</p>
        \\</li>
        \\</ul>
        \\
    );
    // Not tasks: nothing after the marker, another letter, no space.
    try expectHtml("- [ ]\n- [y] a\n- [x]a\n", "<ul>\n<li>[ ]</li>\n<li>[y] a</li>\n<li>[x]a</li>\n</ul>\n");
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
