# Integration testing

The client is tested against [Ursula v0.5.1](https://github.com/tonbo-io/ursula/releases/tag/v0.5.1),
the latest tag checked on 2026-09-22 (commit
`e6d8d70770e1991d2eedf0ce2c3f74ac01f57f43`). This is the HTTP server, distinct
from the Tonbo embedded database.

## Commands

```sh
nix develop --command just test              # verbose unit and loopback tests
nix develop --command just test integration  # verbose live-server tests
nix develop --command just check             # format, build, unit tests
nix develop --command zig build test-integration -Doptimize=ReleaseSafe
```

The justfile has five recipes; the optional `test` argument chooses the suite.
Both test recipes execute on every invocation, including when compilation is
cached. `just check` remains independent of a running server. Integration tests
also run directly through `zig build test-integration` inside the shell.

`nix build .#ursula --no-link` builds the server separately.
`nix run .#ursula -- --help` shows its CLI. The operations CLI is available through
`nix build .#ursulactl --no-link` and `nix run .#ursulactl -- --help`.
The default shell supplies both binaries, Python 3 for the launcher, Zig, and
just. The first build downloads the pinned sources and toolchains; tests
themselves only use loopback networking.

## Fixture and coverage

`tests/run_integration.py` selects an ephemeral loopback port and creates a
temporary config and working directory. It runs `ursula server --preset default`
with one group, two runtime cores, memory WAL, no cold storage, and inline
snapshots. The admin listener also binds an ephemeral loopback port. This tests
the single-node in-memory API, without requiring S3, Docker, or Raft bootstrap.
It does not establish persistence or distributed durability guarantees.

Readiness has a 30-second deadline and the test binary has a 120-second deadline,
including blocked SSE and long-poll reads. The launcher passes `URSULA_TEST_URL`
only to its child tests; directly running the binary without that variable fails.
Inherited Ursula/OTel environment settings and HTTP proxies are excluded from the
fixture configuration. Test buckets are unique within each fresh server.

On completion, failure, SIGINT, or SIGTERM, the launcher stops its child process
groups, waits up to five seconds before escalating to SIGKILL, and removes the
temporary directory. A nonzero test exit is propagated. Startup failures and
timeouts also fail the build, and the last 80 server log lines are printed on
failure. The normal unit suite remains separate and deterministic.

`tests/integration.zig` uses the public Zig API, `std.testing.io`, and the leak
checking allocator to cover:

- Bucket creation; encoded UTF-8 stream IDs; binary creation, append, offset
  resume, HEAD, close, rejected late writes, deletion, and 404 responses.
- Producer retry deduplication, sequence gap metadata, and stale epoch fencing.
- JSON record reads, envelopes, conditional appends, and attribute round trips.
- Binary append-batch framing, each acknowledgement, and committed byte ordering.
- Snapshot publish/read, explicit 307 redirects, retention and 410 responses,
  bootstrap multipart bytes, and protected snapshot deletion.
- Text and binary live SSE, with an initial control event synchronizing the
  append; data must arrive before a matching terminal closure checkpoint.
- Long-poll reads alongside concurrent writes.
- Long-poll continuation with offset plus cursor and record plus cursor, checking
  that only the next JSON record is returned; SSE resumption with offset plus
  cursor, checking that earlier data is not repeated before closure.

The suite has been run in Debug and ReleaseSafe on x86_64 Linux. The flake also
evaluates on aarch64 Linux and both macOS architectures; runtime testing on those
platforms remains to be done. TLS, authentication gateways, multi-node Raft,
restart persistence, S3 storage, and full multipart decoding are outside this
suite. Unit tests retain malformed-wire and allocation-failure coverage that a
well-behaved real server cannot supply.

## Release details and upgrades

The [ursula-overlay](https://github.com/rupurt/ursula-overlay) input owns the
source-built server and CLI packages. This project's flake consumes and re-exports them; there
are no local copies of their derivations. The overlay pins the release source,
Cargo dependencies, Rust nightly, and Nixpkgs/rust-overlay inputs. It shares those
pins between the two binaries and uses Nix's `protoc` for code generation.

The overlay's `nix flake check` builds the packages and checks their installed
CLIs with `--help`. Upstream's network-dependent cluster tests are not run in
the Nix sandbox. This project's integration suite validates the installed server
separately through the Zig client.

The input uses `github:rupurt/ursula-overlay`, with a published revision pinned
in `flake.lock`. No sibling checkout is required to build or test this client.

To upgrade:

1. Follow the release upgrade instructions in the overlay's README. Update and
   validate the shared source, Cargo, and Rust pins there, then commit and publish
   the change.
2. Run `nix flake update ursula-overlay` in this repository to select that commit.
3. Build both packages with `nix build .#ursula .#ursulactl --no-link`, run
   `just check` and `just test integration`, and check both suites with
   `-Doptimize=ReleaseSafe`. Evaluate all outputs with
   `nix flake check --all-systems --no-build`.
4. Update this baseline and record any protocol discrepancies. Avoid updating
   unrelated Zig/nixpkgs inputs during a server upgrade.

The first live run exposed stale create-stream documentation: v0.5.1 rejects
slashes, `..` anywhere, and the reserved name `streams`, and caps the complete
`bucket/stream` identity at 122 UTF-8 bytes including the separator. The client
now validates those rules, backed by unit boundary tests and the tagged
[server validator](https://github.com/tonbo-io/ursula/blob/v0.5.1/crates/ursula-stream/src/validate.rs).
Live snapshot redirects contain absolute URLs; the client returns `Location`
unchanged and leaves validation and following the redirect to the caller.

Cursor continuation exposed another documentation discrepancy: v0.5.1 treats
cursor as a cache token, not a read position or incarnation guard. The public API
now models it separately from offset/record position. Unit tests cover independent
token encoding and validation; the live continuation tests exercise the combined
requests. See [the protocol notes](architecture.md#protocol-decisions) and
[migration instructions](usage.md#read-continuation-and-cursor-migration).
