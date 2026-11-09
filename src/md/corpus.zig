//! Short documents that seed the fuzz tests, each as a fuzz input: its
//! length as four little-endian bytes, then the bytes.

pub const seeds: []const []const u8 = &.{
    seed("# heading\n\nparagraph with *emphasis*, **strong** and `code`\n"),
    seed("> quote\n> > nested\n>\n> - item\n>   1. ordered\n\n    indented code\n"),
    seed("- a\n\n  b\n- [ ] task\n- [x] done\n\n10) ten\n11) eleven\n"),
    seed("| a | b |\n|:-:|--:|\n| `x \\| y` | [l](u) |\nno pipe\n"),
    seed("***a** *b __c_ d~~e~ ~~f~~ [g](<h> \"i\") ![j](k) <l@m.n>\n"),
    seed("```zig info\n\tcode\n```\n~~~\nunclosed\n"),
    seed("<div>\n*raw*\n\n</div>\n<!-- comment\n-->\n"),
    seed("[ref]: /url 'title'\n[ref] [ref][] [REF][ref] [nope]\n"),
    seed("a\\\nb  \nc &amp; &#x41; &bogus; \x00 \x1b[31m \x7f \xc2\x9b\n"),
    seed("日本語のテキスト、「引用」。🦎👨\u{200d}👩 e\u{301}\n"),
    seed("- - - - - x\n\n\n> > > > >\n"),
    seed("Setext\n===\n\n---\n\n* * *\n\n#\n# #\n"),
};

fn seed(comptime s: []const u8) []const u8 {
    comptime {
        const len: [4]u8 = @bitCast(@as(u32, s.len));
        const out = len ++ s[0..s.len].*;
        return &out;
    }
}
