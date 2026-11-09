# Lists the recipes.
_default:
   @just --list

# Builds a debug binary into zig-out/bin.
build:
   zig build

# Runs the unit tests, the CommonMark and GFM examples, and the golden files.
test:
   zig build test spec

# Runs the CommonMark and GFM extension examples, or shows one, such as `just spec 42` or `just spec gfm 198`.
spec *args:
   zig build spec -- {{args}}

# Runs cmark's pathological inputs, timed, or those whose names contain the argument.
pathological *args:
   zig build pathological -- {{args}}

# Compares mdv's output with the golden files in test/golden, or rewrites them with `--update`.
golden *args:
   zig build golden -- {{args}}

# Fuzzes the parser and the layout for the given number of runs, such as `just fuzz 1M`.
fuzz runs="100K":
   zig build test --fuzz={{runs}}

# Runs mdv with the given arguments, such as `just run examples/tour.md`.
run *args:
   zig build run -- {{args}}

# Builds the release binary.
release:
   zig build --release=fast

# Installs the release binary under the prefix, ~/.local by default.
install prefix="~/.local":
   zig build --release=fast --prefix {{prefix}}

# Renders the tour, the reference document for every supported element.
tour:
   zig build run -- examples/tour.md

# Checks the formatting of the Zig sources.
fmt-check:
   zig fmt --check build.zig build src test
