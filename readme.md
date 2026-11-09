# mdv

A minimal markdown viewer for the terminal. `mdv FILE` renders the file once to standard output and exits: no full-screen interface, no keys to learn. At a terminal, a long document opens in your pager (`less` unless you set `PAGER` or `MDV_PAGER`) and a short one is simply printed. Piped output stays plain text, so `mdv` composes with `head` and `grep` like any other command.

Colors come from your terminal's own theme. mdv sends only text attributes (bold, italic, dim, underline, strikethrough) and, at most, one of the sixteen palette colors, never a color of its own. Links are real hyperlinks in terminals that support them.

mdv follows CommonMark. Headings keep their `#` markers in dim, emphasis is italic and strong text bold, lists and quotes are indented under their markers, and code blocks sit behind a thin gutter without being reflowed. Text wraps by display width, so wide characters and emoji take the room they really take. From GitHub's dialect it adds strikethrough between tildes, task lists with a box in place of each bullet, and tables drawn in light box lines. A table too wide for the terminal wraps its longest cells, and when even that would break words, each row is listed as one line per column.

## Use

- `mdv README.md` renders a file.
- `cat notes.md | mdv` or `mdv -` renders standard input.
- `mdv -P notes.md` prints without the pager.
- `mdv a.md b.md` renders both, each after the first headed by its name.
- `mdv --width 60 notes.md` wraps at 60 columns; `--color=always` keeps the styles in a pipe, `--color=never` drops them.
- `mdv --no-links notes.md` prints each link's address after its text instead of making it clickable. Output without styles, such as in a pipe, always does this.
- `mdv --ascii notes.md` draws bullets, gutters, rules, boxes and table lines with plain ASCII.

The [manual](manual.md) describes every option, how each element looks, and what mdv does with paging, colors and width.

## Building

You need a development build of Zig 0.18 and `just`. `just build` makes a debug binary in `zig-out/bin/mdv`, `just release` an optimized one, `just test` runs the tests, `just run FILE` runs it from the source tree, and `just install` installs the release binary under `~/.local` (or `just install prefix=/usr/local`).
