# mdv

A minimal markdown viewer for the terminal. `mdv FILE` renders the file once to standard output and exits: no full-screen interface, no keys to learn. At a terminal, a long document opens in your pager (`less` unless you set `PAGER` or `MDV_PAGER`) and a short one is simply printed. Piped output stays plain text, so `mdv` composes with `head` and `grep` like any other command.

Colors come from your terminal's own theme. mdv sends only text attributes (bold, italic, dim, underline, strikethrough) and, at most, one of the sixteen palette colors, never a color of its own. Links are real hyperlinks in terminals that support them.

mdv is at the very start. Nothing is rendered yet.

## Use

- `mdv README.md` renders a file.
- `cat notes.md | mdv` or `mdv -` renders standard input.
- `mdv -P notes.md` prints without the pager.

## Building

You need a development build of Zig 0.18 and `just`. `just build` makes a debug binary in `zig-out/bin/mdv`, `just release` an optimized one, `just test` runs the tests, `just run FILE` runs it from the source tree, and `just install` installs the release binary under `~/.local` (or `just install prefix=/usr/local`).
