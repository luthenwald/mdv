# Changelog

## Unreleased

- New: `mdv FILE` and `cat FILE | mdv` render a markdown file for your terminal, wrapped to its width and never wider than 80 columns.
- New: headings show their `#` markers in dim, emphasis is italic, strong text bold, and inline code keeps its backticks around blue text.
- New: lists get bullets that change with depth and numbers aligned on the right; quotes and code blocks sit behind a dim gutter, and code is never reflowed. A code line too long for the width continues after a `↪`.
- New: links are clickable in terminals that support hyperlinks. With `--no-links`, or when the output has no styles, the address follows the link text.
- New: `--ascii` draws bullets, gutters and rules with plain ASCII characters.
- New: wide characters and emoji wrap by the columns they take on screen.
- New: control characters in a document are shown as a replacement mark, so a file cannot change your terminal's state.
- New: at a terminal the output opens in `less`, which quits by itself when everything fits on one screen. Set `MDV_PAGER` or `PAGER` to use another pager, or pass `-P` to print directly.
- New: with several files, each one after the first starts with its name in dim.
- New: `--width`, `--color` and `--paging` override what mdv finds out about your terminal, and `NO_COLOR` is respected.
