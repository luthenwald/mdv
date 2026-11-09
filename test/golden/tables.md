# Tables

| left | center | right | none |
|:-----|:------:|------:|------|
| a | b | c | d |
| longer text | `code` | 1,234 | **bold** |

A table with a long cell wraps it, and each column keeps its longest word:

| name | description |
|------|-------------|
| mdv | a minimal markdown viewer for the terminal, which renders once to standard output and leaves the rest to the pager |
| less | the pager |

At a narrow width, a wide table lists its rows:

| parameter | type | default | description |
|-----------|------|---------|-------------|
| width | integer | terminal | the wrap width, at most eighty columns |
| paging | auto, always or never | auto | whether output goes through the pager |

Wide characters take two columns:

| 言語 | 名前 |
|------|------|
| Zig | ジグ |
| 🦎 | lizard |

- A table in a list:

  | a | b |
  |---|---|
  | 1 | 2 |

> | quoted | table |
> |--------|-------|
> | x | [link](https://example.org) |

| header only | no body |
|-------------|---------|

| escaped \| pipe | `a \| b` |
|---|---|
| one | two | dropped |
| short |
