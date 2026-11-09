# Changelog

## Unreleased

- New: `mdv FILE` and `cat FILE | mdv` render a markdown file for your terminal, wrapped to its width and never wider than 80 columns. The width comes from the terminal on standard output, standard error or `/dev/tty`, then from `COLUMNS`, and `--width` sets it yourself, past 80 if you like.
- New: headings show their `#` markers in dim. The first level is bold and underlined, the second bold, and deeper levels bold and dim. Emphasis is italic, strong text bold, and inline code keeps its backticks around blue text.
- New: lists get bullets that change with depth and numbers aligned on the right; quotes and code blocks sit behind a dim gutter, and code is never reflowed. A code block's language stands above it in dim, and a code line too long for the width continues after a `↪`.
- New: a thematic break is a dim rule, raw HTML is shown as written in dim, and an image shows as `[image: description]` with its address.
- New: links whose address names a scheme, such as `https:` or `mailto:`, are clickable in terminals that support hyperlinks. A relative address follows the link text in dim, as every address does with `--no-links` or when the output has no styles. A `data:` address is cut after its first comma.
- New: `--ascii` draws bullets, gutters, rules, task boxes and table lines with plain ASCII characters.
- New: tables are drawn in light box lines with a bold header, and each column keeps the alignment its delimiter row asks for. When a table is too wide for the terminal, its longest cells wrap; when even its words would not fit, each row is listed as one line per column.
- New: text between one or two tildes, as in `~~gone~~`, is struck through.
- New: task list items show an empty or a checked box where the bullet would be, or after the number in an ordered list.
- New: front matter between `---` lines at the top of a file is shown as written, in dim, instead of being read as a rule and a heading.
- New: wide characters and emoji wrap by the columns they take on screen, and text without spaces, such as Chinese or Japanese, breaks between characters. A flag's two halves and an emoji with its presentation selector stay together.
- New: quotes and lists nested more than 32 levels deep keep 32 levels of gutters and markers and show the rest at that depth.
- New: control characters and bytes that are not UTF-8 are shown as a replacement mark, so a file cannot change your terminal's state.
- New: at a terminal the output opens in `less`, which quits by itself when everything fits on one screen. Set `MDV_PAGER` or `PAGER` to use another pager, or pass `-P` to print directly. A bare `less` in those variables works too: `LESS` is set to `FRX` for the pager when you have not set it. When the pager cannot be started, mdv prints directly.
- New: Ctrl-C while the pager runs goes to the pager alone; mdv waits for it to quit and leaves your terminal as it found it.
- New: with several files, each starts with its name in dim, including after one that could not be read.
- New: `--width`, `--color` and `--paging` override what mdv finds out about your terminal, `NO_COLOR` is respected, and `TERM=dumb` gets plain, unpaged output.
- New: with no file and your terminal on standard input, mdv says `no input` and exits instead of waiting. A file that cannot be read gives exit status 1, a mistake on the command line status 2, and a file of 256 MiB or more is refused as too large.
- New: a manual, `manual.md`, describes every option and how each element looks, and `notices.md` lists the work mdv carries and its terms. Both install beside the binary under `share/doc/mdv`.
