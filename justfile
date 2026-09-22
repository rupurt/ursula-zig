# List the available development tasks.
default:
    @just --list

# Build the library.
build:
    zig build

# Print each test name and result; use `just test integration` for a real server.
test suite="unit":
    #!/usr/bin/env bash
    set -euo pipefail
    # A pipe makes Zig print every test instead of replacing terminal progress.
    case {{quote(suite)}} in
      unit) zig build test -Dverbose-tests 2>&1 | cat ;;
      integration) zig build test-integration 2>&1 | cat ;;
      *) echo 'Usage: just test [unit|integration]' >&2; exit 2 ;;
    esac

# Format Zig source and build files.
fmt:
    zig fmt build.zig build.zig.zon src examples tests

# Check formatting, build the library, and run tests.
check:
    zig fmt --check build.zig build.zig.zon src examples tests
    zig build
    zig build test
