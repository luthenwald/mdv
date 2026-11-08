# The tour

This document shows every element mdv supports in its first version. A paragraph runs long enough to wrap at the measure, so you can see how soft breaks
join into a single flowing line, and how the right edge settles.

A line can end in a hard break\
like this one, or with two trailing spaces  
like this.

## Inline

Text can be *emphasized*, **strong**, ***both***, ~~struck through~~, or `code`. Escapes keep \*literal\* stars, and entities such as &copy; &amp; &#8212; decode.

A [link with a title](https://commonmark.org "CommonMark"), a [reference link][spec], an autolink <https://ziglang.org>, and an image ![a small diagram](diagram.png).

[spec]: https://spec.commonmark.org/0.31.2/

Setext heading, level two
-------------------------

### Third level

#### Fourth level

## Lists

- a bullet
- another, with a nested list
  - second depth
    - third depth
- back at the top

8. eighth
9. ninth
10. tenth, so the numbers align

- [ ] a task to do
- [x] a task done

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
    _ = init;
}
```

    an indented code block
    keeps its spacing

## Tables

| element | rendering | since |
|:--------|:---------:|------:|
| heading | bold      | v1    |
| table   | box lines | v1    |
| math    | unicode   | later |

## Breaks and raw HTML

***

<div>raw html is shown as it is</div>

Wide characters wrap by display width: 日本語のテキスト, and emoji 🌿 count as two columns.
