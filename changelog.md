# Changelog

## Unreleased

- New: `mdv FILE` and `cat FILE | mdv` print the text of a markdown file as paragraphs, wrapped to your terminal and never wider than 80 columns. Markdown syntax is still shown as it is written.
- New: at a terminal the output opens in `less`, which quits by itself when everything fits on one screen. Set `MDV_PAGER` or `PAGER` to use another pager, or pass `-P` to print directly.
- New: with several files, each one after the first starts with its name in dim.
- New: `--width`, `--color` and `--paging` override what mdv finds out about your terminal, and `NO_COLOR` is respected.
