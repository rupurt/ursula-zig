# List the available development tasks.
default:
    @just --list

# Build the library.
build:
    zig build

# Run the library's unit tests.
test:
    zig build test

# Format Zig source and build files.
fmt:
    zig fmt build.zig build.zig.zon src

# Check formatting, build the library, and run tests.
check:
    zig fmt --check build.zig build.zig.zon src
    zig build
    zig build test
