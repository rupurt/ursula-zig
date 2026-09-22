# Working on ursula-zig

## Purpose and current state

Build a Zig client library for Ursula's public durable streams API. The repository
implements typed protocol operations, validated request construction, HTTP
transport using caller-supplied `std.Io`, and incremental SSE decoding. Unit and
loopback tests cover these layers; opt-in integration tests use a real local
Ursula server. Consult `docs/architecture.md` for their ownership
rules, and keep the README accurate as functionality lands.

## Sources of truth

- [Ursula API overview](https://ursula.tonbo.io/docs/api/overview/)
- [Ursula client guide](https://ursula.tonbo.io/docs/clients/)
- [Durable Streams protocol](https://ursula.tonbo.io/docs/specs/durable-stream/)

Read the relevant endpoint documentation before implementing behavior. Distinguish
Ursula's implemented API from the broader protocol and its extensions; do not
assume every protocol operation exists on the server.

## Toolchain and workflow

- Use `nix develop` or `nix develop --command <command>` for the pinned tools.
- Zig comes from `zig-overlay.packages.${system}.master`. `flake.lock` selects the
  exact nightly; consult that compiler's standard library and build API when
  working with Zig APIs that change between releases.
- Use `just build`, `just test`, `just fmt`, and `just check`. Bare `just` lists
  tasks. Keep the justfile at five recipes or fewer.
- `just test` prints every test name and result; `just check` keeps concise output.
  The verbose recipe uses Bash `pipefail` to preserve failures through its output pipe.
- `just test integration` runs the live suite. Read `docs/integration-tests.md`
  before changing its fixture or the server derivation. The shell supplies Python
  and source-built Ursula and `ursulactl`; `nix build .#ursula --no-link` builds
  just the server, and `nix build .#ursulactl --no-link` builds just the CLI.
  The separate `ursula-overlay` input owns their derivations and shared pins.
  Edit packaging in `../ursula-overlay`, following its AGENTS.md. Keep this
  repository consuming the overlay rather than duplicating its derivations.
  The input uses `github:rupurt/ursula-overlay`; update its lock after overlay
  changes have been committed and published. Do not use a local file input.
- Run `just fmt` after Zig edits and `just check` before handing off code changes.
  Report checks that could not run and explain the actual blocker.
- `.github/workflows/ci.yml` runs checks plus Debug and ReleaseSafe unit and live
  integration tests on Linux. It evaluates all flake platforms without building
  foreign targets. Keep its commands aligned with the justfile and preserve
  failure propagation through verbose test output pipes.
- Pin GitHub Actions to full commit hashes, with a version comment. Validate
  workflow edits with `actionlint` and run any changed check/test commands locally.
- Update the toolchain intentionally with `nix flake update zig-overlay`, rerun
  checks inside a fresh shell, and include `flake.lock` with related fixes.
- Keep generated `.zig-cache/`, `zig-out/`, and `.direnv/` files out of version
  control.

## Code structure and conventions

- Read `docs/architecture.md` before changing transport, ownership, or protocol
  behavior.
- Expose the public library API through `src/root.zig` and the `ursula` build
  module. Keep implementation modules under `src/`.
- Accept `std.Io` from callers; do not create a hidden runtime or use legacy
  blocking networking APIs. Preserve cancellation and stable request addresses.
- Prefer the Zig standard library and keep dependencies minimal.
- Accept an allocator where allocation is needed. Document who owns returned
  buffers, their lifetimes, and how callers release resources. Use `defer` and
  `errdefer` consistently for cleanup.
- Document public declarations with `///` comments. Follow `zig fmt` and the
  naming conventions in the pinned Zig standard library.
- Return errors for recoverable failures. Preserve enough HTTP status and
  protocol metadata for callers to understand server responses.
- Keep the server URL and request configuration explicit. Do not hard-code a
  deployment or log credentials and stream payloads.
- Keep `Client` and open `Exchange` addresses stable; std.http readers refer to
  their request. Copy response headers before reading the body. Close abandoned
  live exchanges without draining them.
- SSE event slices borrow decoder buffers until the next `next` call. Parsed
  control results own their strings. Preserve this distinction in tests and docs.
- Follow documented offset, cursor, header, and SSE semantics. Do not assume
  network chunks align with records or SSE events.
- Never advance application checkpoints before preceding data is processed.
  SSE transport EOF is not stream closure; only protocol closure metadata is.
- Make append retries and producer identity explicit; do not silently retry
  writes whose outcome is unknown without the protocol's deduplication guarantees.

## Validation and scope

- Add focused unit tests with new behavior, including malformed responses and
  cleanup paths where relevant. Use `std.testing.allocator` for allocation tests.
- Keep default unit tests deterministic and independent of a running server.
  The loopback fixture requires local sockets but no external service. Keep live
  Ursula integration tests opt-in. Use the launcher-owned server, never an existing
  deployment. Preserve readiness/test deadlines, failure logs, signal cleanup, and
  fresh state on every invocation. Give independent tests distinct bucket names.
- Run `just test integration` after changing wire behavior or the Ursula pin.
  Update release/build pins in `ursula-overlay`, then run
  `nix flake update ursula-overlay` here. Verify the latest upstream tag when
  upgrading and preserve shared server/CLI pins. Match observed release behavior
  when endpoint docs are stale, and document discrepancies with links to the
  tagged source.
- `zig build test` also compiles the examples. For transport, parsing, or ownership
  changes, validate both Debug and `zig build test -Doptimize=ReleaseSafe`. Use
  allocation-failure checks for new owning structures and deterministic byte
  fragmentation tests for incremental parsers.
- Keep changes limited to the requested work. Update documentation when public
  behavior or development commands change.
- Preserve existing user changes and the project's MIT license.
