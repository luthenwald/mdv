# Notices

mdv itself is under the MIT License in `license`. It carries work by others, listed here with their terms.

## commonmark.js

The parser in `src/md` is a port to Zig of the block and inline parsers of commonmark.js, the reference implementation of CommonMark in JavaScript by John MacFarlane, https://github.com/commonmark/commonmark.js. The port is under the BSD 2-Clause License, which also covers the pathological test cases from cmark in `test/pathological.zig`:

```
Copyright (c) 2014, John MacFarlane

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Unicode Character Database

The tables of display widths, general categories and case folding compiled into mdv are generated from the Unicode Character Database, version 17.0.0, in `data`. Copyright © 1991-2026 Unicode, Inc. Distributed under the Unicode License v3, whose text is in `data/unicode-license.txt`, https://www.unicode.org/license.txt.

## HTML named character references

The table of character references compiled into mdv is generated from `entities.json` of the HTML Living Standard, in `data`. Copyright WHATWG (Apple, Google, Mozilla, Microsoft). Licensed under the Creative Commons Attribution 4.0 International License, https://creativecommons.org/licenses/by/4.0/.

## Test material

The tests, which are not part of the binary, run against the examples of the CommonMark Spec, version 0.31.2, by John MacFarlane, and the GitHub Flavored Markdown Spec, version 0.29, by GitHub, both under the Creative Commons Attribution-ShareAlike 4.0 International License, https://creativecommons.org/licenses/by-sa/4.0/. The files and their checksums are listed in `test/spec/sources.md` and `data/sources.md`.
