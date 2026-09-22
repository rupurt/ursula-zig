# ursula-zig

A Zig client library for [Ursula](https://ursula.tonbo.io/), a durable streams
service with an HTTP API and Server-Sent Events (SSE) for live reads.

The client supports bucket creation; stream creation, append, close, read, HEAD,
and deletion; long-polling; attributes; append batches; snapshots; retention; and
raw multipart bootstrap responses. It accepts the caller's `std.Io` and uses Zig's
HTTP client for HTTP/HTTPS. Incremental SSE decoding supports text and binary
payloads, control metadata, and bounded memory use. This is an early client library;
validation currently uses protocol fixtures rather than a live Ursula cluster.

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

The shell includes `just` and the Zig `master` nightly from
[zig-overlay](https://github.com/mitchellh/zig-overlay). `flake.lock` pins the
inputs, so entering the shell uses the same compiler until the lock is updated.
The shell supports Linux and macOS on x86_64 and aarch64.

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
| `just test` | Run deterministic library tests. |
| `just fmt` | Format Zig sources and build files. |
| `just check` | Check formatting, build, and run tests. |

Tests use an ephemeral loopback HTTP fixture and require local socket access,
but do not require an Ursula server or external network access. To try Ursula
itself, follow its [quick start](https://ursula.tonbo.io/docs/quick-start/).

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
- `docs/`: architecture and client usage.
- `build.zig`: library and unit-test build steps.
- `build.zig.zon`: Zig package metadata.
- `flake.nix` and `flake.lock`: development tools and their pinned versions.
- `justfile`: development commands.
- `AGENTS.md`: guidance for contributors and coding agents.

## Contributing

Read [AGENTS.md](AGENTS.md), keep changes focused, and run `just check` before
submitting code. Document public APIs and add tests alongside their implementation.
Clearly distinguish implemented functionality from planned functionality.

## License

[MIT](LICENSE).
