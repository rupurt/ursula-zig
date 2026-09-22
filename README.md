# ursula-zig

A Zig client library for [Ursula](https://ursula.tonbo.io/), a durable streams
service with an HTTP API and Server-Sent Events (SSE) for live reads.

The client supports bucket creation; stream creation, append, close, read, HEAD,
and deletion; long-polling; attributes; append batches; snapshots; retention; and
raw multipart bootstrap responses. It accepts the caller's `std.Io` and uses Zig's
HTTP client for HTTP/HTTPS. Incremental SSE decoding supports text and binary
payloads, control metadata, and bounded memory use. This is an early client library,
tested with protocol fixtures and a local Ursula server. Distributed durability
and TLS integration are not yet covered.

See [the architecture notes](docs/architecture.md) for ownership and protocol
choices, and [client usage](docs/usage.md) for examples and limits.

## Development

Install Nix with `nix-command` and `flakes` enabled, then enter the development
shell from the repository root:

```sh
nix develop
just
just check
```

The shell includes `just`, Python 3, the Zig `master` nightly from
[zig-overlay](https://github.com/mitchellh/zig-overlay), the Ursula server, and its
`ursulactl` operations CLI.
`flake.lock` pins the inputs, so entering the shell uses the same tools until
their pins are updated.
The shell supports Linux and macOS on x86_64 and aarch64.

[Ursula v0.5.1](https://github.com/tonbo-io/ursula/releases/tag/v0.5.1), the latest
tag checked on 2026-09-22, is built from source by `nix/ursula.nix`. It pins the
release source, Cargo dependencies, and upstream's Rust nightly `2026-06-01`.
`nix/ursulactl.nix` builds the CLI from the same release and shares those pins.
The first shell entry builds both tools; later entries reuse Nix's build results.
Build the server separately with `nix build .#ursula --no-link`, or inspect its
CLI with `nix run .#ursula -- --help`.

Build and run the operations CLI separately:

```sh
nix build .#ursulactl --no-link
nix run .#ursulactl -- --help
```

Inside `nix develop`, both `ursula` and `ursulactl` are on `PATH`.

If you use direnv with Nix support, the existing `.envrc` loads this shell after
`direnv allow`. A single command can also run without entering an interactive
shell:

```sh
nix develop --command just check
```

There are five tasks:

| Command | Purpose |
| --- | --- |
| `just` | List available tasks. |
| `just build` | Build the static library into `zig-out/lib/`. |
| `just test [unit\|integration]` | Print each test name and result; defaults to unit tests. |
| `just fmt` | Format Zig sources and build files. |
| `just check` | Check formatting, build, and run tests. |

`just test` always executes the tests and retains their full output, even when the
compiled test binary is cached. `just check` uses Zig's normal concise test output.

Unit tests use an ephemeral loopback HTTP fixture and require local socket access.
The opt-in integration suite starts a temporary Ursula process, exercises the
client against its HTTP API, and cleans up the server and its working directory:

```sh
nix develop --command just test integration
```

It covers binary stream lifecycle, producer deduplication, JSON records and
attributes, append batches, snapshots and retention, raw bootstrap responses,
long-polling, and text/binary SSE. Once tools are built, both suites run without
external services or network access beyond loopback. See
[integration testing](docs/integration-tests.md) for isolation, deadlines,
coverage limits, and server upgrade instructions.

Update the pinned Zig nightly deliberately, then check compatibility:

```sh
nix flake update zig-overlay
nix develop --command just check
```

Include the updated `flake.lock` with any changes needed for the new compiler.

## Layout

- `src/root.zig`: public `ursula` module.
- `src/protocol.zig` and `src/request.zig`: typed operations and request validation.
- `src/Client.zig` and `src/response.zig`: I/O transport and owned responses.
- `src/sse.zig`: incremental event decoding over `std.Io.Reader`.
- `examples/`: compiled examples for catch-up reads and live tailing.
- `tests/`: live integration tests and their temporary-server launcher.
- `docs/`: architecture and client usage.
- `build.zig`: library, unit-test, and integration-test build steps.
- `build.zig.zon`: Zig package metadata.
- `flake.nix` and `flake.lock`: development tools and their pinned versions.
- `nix/ursula.nix`: source-built Ursula server and Rust toolchain pin.
- `nix/ursulactl.nix`: operations CLI sharing the server's release and build inputs.
- `justfile`: development commands.
- `AGENTS.md`: guidance for contributors and coding agents.

## Contributing

Read [AGENTS.md](AGENTS.md), keep changes focused, and run `just check` before
submitting code. Document public APIs and add tests alongside their implementation.
Clearly distinguish implemented functionality from planned functionality.

## License

[MIT](LICENSE).
