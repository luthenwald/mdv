# mdv

A minimal markdown viewer for the terminal. `mdv FILE` renders the file once to standard output and exits: no full-screen interface, no keys to learn. At a terminal, a long document opens in your pager (`less` unless you set `PAGER` or `MDV_PAGER`), which you leave with <kbd>q</kbd>, and a short one is simply printed. Piped output stays plain text, so `mdv` composes with `head` and `grep` like any other command.

![This readme as mdv prints it at 80 columns](examples/readme.svg)

Colors come from your terminal's own theme. mdv sends only text attributes (bold, italic, dim, underline, strikethrough) and, at most, one of the sixteen palette colors, never a color of its own. Links with a web address are real [hyperlinks](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda "Hyperlinks in terminal emulators") in terminals that support them; a relative one shows its path after the text.

mdv follows [CommonMark][]. Headings keep their `#` markers in dim, *emphasis* is italic and **strong text** bold, lists and quotes are indented under their markers, and code blocks sit behind a thin gutter without being reflowed. Text wraps by display width, so wide characters such as 日本語 and emoji such as 🌿 take the room they really take. From GitHub's dialect it adds ~~strikethrough~~ between tildes, task lists with a box in place of each bullet, and tables drawn in light box lines. A table too wide for the terminal wraps its longest cells, and when even that would break words, each row is listed as one line per column.

> mdv has only been tried on macOS so far. If something looks wrong in your terminal on Linux or elsewhere, a report is welcome.

## Use

- `mdv README.md` renders a file.
- `cat notes.md | mdv` or `mdv -` renders standard input.
- `mdv a.md b.md` renders both, each headed by its name.

### Options

| option | effect |
|---|---|
| `-P` | prints without the pager |
| `-w`, `--width N` | wraps at N columns, past 80 if you like |
| `--color always\|never` | keeps the styles in a pipe, or drops them |
| `--no-links` | prints each link's address after its text, as output without styles always does |
| `--ascii` | draws bullets, gutters, rules, boxes and table lines in plain ASCII |

The [manual](manual.md) describes every option, how each element looks, and what mdv does with paging, colors and width.

## What it reads

- CommonMark 0.31.2, passing all 652 examples of its spec
- GitHub's additions to it:
  - [x] tables
  - [x] strikethrough
  - [x] task lists
  - [ ] footnotes
  - [ ] bare web addresses as links
  - [ ] alerts

## Building

mdv builds with Zig 0.17.0 through 0.18.0-dev.954+60635c2bd, a development build, and other versions may not compile.

1. Get Zig from <https://ziglang.org/download/>.
2. Run `zig build --release=fast --prefix ~/.local`, which installs the binary and the manual under `~/.local`. Any other prefix, such as `/usr/local`, works the same way.
3. Make sure `~/.local/bin` is on your `PATH`.

From the source tree:

```sh
zig build                       # a debug binary in zig-out/bin/mdv
zig build test spec             # the unit tests and the spec examples
zig build run -- FILE           # runs it without installing
zig build golden -- --update    # redraws the picture above, among others
```

---

mdv is under the MIT License. It carries a port of commonmark.js and tables generated from Unicode and WHATWG data; their terms are in [notices.md](notices.md).

[CommonMark]: https://spec.commonmark.org/0.31.2/
