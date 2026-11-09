# mdv manual

mdv shows a markdown file in your terminal. It reads the file, lays it out once for the width of your window, and exits. There is no full-screen interface and nothing to learn: a long document opens in your pager, a short one is printed, and output into a pipe is plain text that `grep`, `head` or another program can read.

## Starting

```
mdv notes.md              render a file
mdv a.md b.md             render both, one after the other
cat notes.md | mdv        render standard input
mdv - < notes.md          the same, with "-" naming standard input
mdv -P notes.md           print without the pager
mdv --width 60 notes.md   wrap at 60 columns
mdv --help                the options in short
mdv --version             the version
```

With no file, mdv reads standard input. When that is your terminal rather than a pipe or a file, you most likely forgot the file name, so mdv says so and exits instead of waiting for you to type a document.

An option's value can follow it as a separate word or be attached: `--width 60`, `--width=60`, `-w 60` and `-w60` all mean the same. `-h` is short for `--help`. A `--` ends the options, so a file whose name starts with a dash follows it: `mdv -- -notes.md`.

mdv runs on macOS, Linux and the other POSIX systems. It reads a file of up to 256 MiB; a larger one is reported as too large.

## How the elements look

mdv follows CommonMark and three parts of GitHub's dialect: tables, strikethrough and task lists. Everything is drawn with text attributes and your terminal's own palette, so it matches your theme.

Headings keep their `#` markers, in dim. A first-level heading is bold and underlined, a second-level heading bold, and deeper levels bold and dim. A heading too long for one line continues under its text, past the markers.

Emphasis is italic, strong text bold, and `~~struck~~` text struck through. Inline code is blue, with its backticks kept in dim, and never breaks across lines unless it is wider than a whole line.

Lists hang under their markers. Bullets change with depth: •, then ◦, then ▪, and around again. Numbers keep the list's own delimiter and align on the right, so 9 and 10 end in the same column. A task item shows ☐ when it is open and ☑ when it is done, in the place of the bullet, or after the number in a numbered list. A loose list keeps a blank line between its items.

Quotes sit behind a thin dim bar, one bar for each level.

Code blocks sit behind the same bar and keep their lines exactly. The language, when the block names one, stands above the code in dim. Tabs become spaces to the next multiple of four columns. A line too long for the width continues on the next line after a dim ↪.

A thematic break is a dim rule across the width.

Tables are drawn in light box lines in dim, with the header in bold and each column aligned as its delimiter row asks (`:--`, `:-:`, `--:`). A table that does not fit gives its widest columns less room and wraps their cells, though no column gets narrower than its longest word. When even the longest words do not fit side by side, each row is listed instead, one `header: value` line per column, with a blank line between rows.

Links are blue and underlined. In terminals that support hyperlinks, a link whose address names a scheme, such as `https:`, `mailto:` or `file:`, is clickable and its address stays out of the text. A relative address such as `docs/manual.md` or `#section` has nothing a terminal could open, so it follows the link text in parentheses, in dim, as it does with `--no-links`. A `data:` address is shown only up to its first comma. Images show as `[image: description]`, followed by their address in dim.

Raw HTML is shown as it is written, in dim.

Front matter, a block between `---` lines at the very start of the file (the second line may also be `...`), is shown as written, in dim, and is not read as markdown. Many notes and blog posts carry their title and tags this way.

Quotes and lists nested more than 32 levels deep keep the 32 levels of bars and markers they have and show the rest of their content at that depth, since more would fill the line anyway.

## Width and wrapping

mdv wraps to the width of your terminal, and never wider than 80 columns, so prose keeps a readable measure in a wide window. It asks the terminal on standard output, then on standard error, then `/dev/tty`. When none of them is a terminal it uses `COLUMNS`, and otherwise 80. `--width N` (or `-w N`) sets the width yourself and lifts the limit of 80.

Text wraps between words, by the columns the characters take on screen: Chinese and Japanese characters and most emoji take two columns, combining marks none. In text without spaces, such as Chinese or Japanese, lines break between characters, though never before closing punctuation such as `。` or after opening punctuation such as `「`. A word longer than a whole line is broken where it must be.

## Paging

When standard output is a terminal, mdv writes into a pager. It runs `MDV_PAGER` if you set it, then `PAGER`, and otherwise `less -RFX`. With those flags less shows the styles, quits by itself when the document fits on one screen, and leaves the text in your scrollback after you quit. The pager runs through `/bin/sh -c`, so the variable can hold a command with its own options. An empty variable counts as unset.

A bare `less` in `PAGER` would show the escape sequences as text, so when `LESS` is not set in your environment, mdv sets it to `FRX` for the pager, as git does. Your own `LESS` is never changed. While the pager runs, Ctrl-C goes to it alone and mdv waits for it to quit.

`--paging auto` is the default and pages only at a terminal. `--paging always` pages even into a pipe, and `--paging never`, or `-P`, prints directly. If the pager cannot be started, mdv prints directly instead. The shell usually says why on the line before.

## Styles and colors

At a terminal mdv sends bold, dim, italic, underline and strikethrough, and one color, blue, for links and inline code. The blue is your palette's own, one of the sixteen colors your theme defines, and mdv never sets a background.

Into a pipe or a file the output is plain text. `--color always` keeps the styles anyway, for example for `mdv --color always notes.md | less -R`, and `--color never` drops them at a terminal. When `NO_COLOR` is set and not empty, the blue goes and the attributes stay.

## Links without hyperlinks

`--no-links` turns the clickable links off: the address follows each link's text in parentheses, in dim. Output without styles always works this way, so a link's address survives a pipe. An autolink whose text already is its address, such as `<https://example.org>`, is not repeated.

## Plain characters

`--ascii` draws everything with ASCII characters, for terminals or fonts that lack the box-drawing and bullet glyphs, for a terminal that draws characters of ambiguous width, such as `•`, two columns wide, and for output that will be read under a locale without UTF-8:

```
bullets      * - +        (• ◦ ▪)
tasks        [ ] [x]      (☐ ☑)
quote, code  |            (│)
long lines   ->           (↪)
rules        -            (─)
tables       + - |        (┌ ─ │ and the other corners)
```

## Several files

With several files, mdv renders them in order, as one document. Each file starts with its name in dim, and a blank line separates one from the next. Standard input, given as `-`, can be one of them, under the name `standard input`. A file that cannot be read is reported and left out, and the others still show their names.

## What mdv will not print

A document cannot change your terminal's state. Control characters other than tab and line feed, and bytes that are not valid UTF-8, show as a replacement mark (`�`, or `?` with `--ascii`). The only escape sequences mdv sends are its own, for styles and links, and each styled line ends by resetting them, so nothing carries over into the next line when the output is cut short by `head` or a pager.

## Errors

A file that cannot be read is reported on standard error, such as `mdv: notes.md: no such file`, and the other files are still rendered. The exit status is then 1, as it is when the output could not be written. A mistake on the command line, such as an unknown option, is reported with a hint to run `mdv --help`, and exits with status 2; so does running mdv with no file while standard input is the terminal. Otherwise the exit status is 0, also when you quit the pager before the end.

## Environment

```
MDV_PAGER   the pager to use, before PAGER
PAGER       the pager to use when MDV_PAGER is not set
LESS        passed on as it is; set to FRX for the pager when missing
NO_COLOR    when set and not empty, no blue; attributes stay
COLUMNS     the width when no terminal can be asked
TERM        dumb means no styles and no pager unless asked
```
