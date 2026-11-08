# Lists the recipes.
_default:
   @just --list

# Builds a debug binary into zig-out/bin.
build:
   zig build

# Runs the tests.
test:
   zig build test

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
   zig fmt --check build.zig src
