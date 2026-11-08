# Test sources

These files are kept exactly as published, fetched on 2026-11-08. The conformance tests run against them.

## spec.json

The 652 examples of the CommonMark Spec, version 0.31.2.

- From: https://spec.commonmark.org/0.31.2/spec.json
- sha256: `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`
- License: CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/
- Attribution: CommonMark Spec by John MacFarlane, https://spec.commonmark.org/

## gfm.txt

The GitHub Flavored Markdown Spec, version 0.29 (2019-04-06), as shipped in cmark-gfm. We use its sections on tables, strikethrough and task list items.

- From: https://raw.githubusercontent.com/github/cmark-gfm/0.29.0.gfm.13/test/spec.txt (tag `0.29.0.gfm.13`)
- sha256: `7d8e5814befec287ac116786d81ff14e0adc9b13295b4494649e995408fd871c`
- License: CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/
- Attribution: GitHub Flavored Markdown Spec by GitHub, based on the CommonMark Spec by John MacFarlane

## pathological_tests.py

The generator for cmark's pathological inputs (deep nesting, long runs of delimiters). It is kept as the reference for a port of its cases to a Zig test.

- From: https://raw.githubusercontent.com/commonmark/cmark/0.31.2/test/pathological_tests.py (tag `0.31.2`)
- sha256: `6cb0471a67bada46eb9efa42baf09546e5015f1e9aec499e9513e641fa59d930`
- License: BSD-2-Clause, copyright (c) 2014 John MacFarlane. The notice is in `cmark-license.txt`.
