# Working on ursula-zig

## Purpose and current state

Build a Zig client library for Ursula's public durable streams API. The repository
currently contains development tooling and a minimal library scaffold; protocol
operations and their tests remain to be implemented. Keep the README accurate as
functionality lands.

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
- Run `just fmt` after Zig edits and `just check` before handing off code changes.
  Report checks that could not run and explain the actual blocker.
- Update the toolchain intentionally with `nix flake update zig-overlay`, rerun
  checks inside a fresh shell, and include `flake.lock` with related fixes.
- Keep generated `.zig-cache/`, `zig-out/`, and `.direnv/` files out of version
  control.

## Code structure and conventions

- Expose the public library API through `src/root.zig` and the `ursula` build
  module. Keep implementation modules under `src/`.
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
- Follow documented offset, cursor, header, and SSE semantics. Do not assume
  network chunks align with records or SSE events.
- Make append retries and producer identity explicit; do not silently retry
  writes whose outcome is unknown without the protocol's deduplication guarantees.

## Validation and scope

- Add focused unit tests with new behavior, including malformed responses and
  cleanup paths where relevant. Use `std.testing.allocator` for allocation tests.
- Keep default unit tests deterministic and independent of a running server.
  Make future integration tests opt-in and document their server requirements.
- Keep changes limited to the requested work. Update documentation when public
  behavior or development commands change.
- Preserve existing user changes and the project's MIT license.
