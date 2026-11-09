# Text

Wide characters wrap by the columns they take: 日本語のテキストは二列の幅で、折り返しもその幅で数えます。Emoji too: 🦎🦎🦎, each two columns wide, and a family 👨‍👩‍👧 stays on one line.

A word longer than the line breaks where it must: example.org/a/very/long/path/that/keeps/going/past/the/edge/of/an/eighty/column/terminal

A hard break\
and an [inline link](https://example.org/a "title"), an autolink <https://example.org>, an email <me@example.org>, a [reference][r] and an image ![alt *text*](img.png).

[r]: https://example.org/ref

Nested styles: ***bold italic***, **bold with `code` and a [link](https://example.org)**, ~one tilde~ and ~~two~~.

Raw <span>inline html</span> is dim.

Control characters are replaced: bell , escape [31m, delete , C1  end.

```
code with a tab	here and an escape ]8;;x\ inside
```
