# List the available development tasks.
default:
    @just --list

# Build the library.
build:
    zig build

# Run unit tests, printing each test name and result.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    # A pipe makes Zig print every test instead of replacing terminal progress.
    zig build test -Dverbose-tests 2>&1 | cat

# Format Zig source and build files.
fmt:
    zig fmt build.zig build.zig.zon src examples

# Check formatting, build the library, and run tests.
check:
    zig fmt --check build.zig build.zig.zon src examples
    zig build
    zig build test
