---
title: The tour
tags: [markdown, terminal]
---

# The tour

This document shows every element mdv supports in its first version, starting with the front matter above, which is shown as written. A paragraph runs long enough to wrap at the measure, so you can see how soft breaks
join into a single flowing line, and how the right edge settles.

A line can end in a hard break\
like this one, or with two trailing spaces  
like this.

## Inline

Text can be *emphasized*, **strong**, ***both***, ~~struck through~~ with two tildes or ~one~, or `code`. Escapes keep \*literal\* stars, and entities such as &copy; &amp; &#8212; decode. Raw <kbd>inline html</kbd> is shown as written.

A [link with a title](https://commonmark.org "CommonMark"), a [reference link][spec], a [relative link](manual.md) whose path follows it, an autolink <https://ziglang.org>, an email <hello@example.org>, and an image ![a small diagram](diagram.png).

[spec]: https://spec.commonmark.org/0.31.2/

Setext heading, level two
-------------------------

### Third level

#### Fourth level

##### Fifth level

###### Sixth level

## A heading long enough to wrap at the measure, so its second line hangs under the text and not under the markers

## Lists

- a bullet
- another, with a nested list
  - second depth
    - third depth
- back at the top

8. eighth
9. ninth
10. tenth, so the numbers align

1) a parenthesis
2) as the delimiter

- [ ] a task to do
- [x] a task done

1. [ ] a numbered task
2. [x] and one done

A loose list:

- one paragraph item

- another, with a second paragraph

  that continues here.

## Quotes

> A quote with *emphasis*.
>
> > And a nested one.

## Code

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
	_ = init; // indented with a tab
}
```

    an indented code block
    keeps its spacing

## Tables

| element | rendering | since |
|:--------|:---------:|------:|
| heading | bold      | v1    |
| table   | box lines | v1    |
| emoji   | two cells | v1    |

A table whose longest words do not fit side by side is listed row by row instead:

| option | meaning | default |
|--------|---------|---------|
| `--width` | the wrap width, which lifts the eighty-column cap | the terminal's |
| `--paging` | `auto`, `always` or `never` | `auto` |

## Breaks and raw HTML

***

<div>raw html is shown as it is</div>

Wide characters wrap by display width: 日本語のテキスト, and emoji 🌿 count as two columns.
