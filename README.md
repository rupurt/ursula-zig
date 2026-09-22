# ursula-zig

A Zig client library for [Ursula](https://ursula.tonbo.io/), a durable streams
service with an HTTP API and Server-Sent Events (SSE) for live reads.

The first implementation layer provides typed operations and validated HTTP request
construction for the public stream API. Network transport and live SSE reads are
being added next. See [the architecture notes](docs/architecture.md) for ownership,
protocol choices, and the implementation roadmap.

## Development

Install Nix with `nix-command` and `flakes` enabled, then enter the development
shell from the repository root:

```sh
nix develop
just
just check
```

While the new flake files are still untracked by Git, enter the shell with
`nix develop path:.` instead.

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

Builds and unit tests do not require an Ursula server. To try Ursula itself, follow
its [quick start](https://ursula.tonbo.io/docs/quick-start/).

Update the pinned Zig nightly deliberately, then check compatibility:

```sh
nix flake update zig-overlay
nix develop --command just check
```

Include the updated `flake.lock` with any changes needed for the new compiler.

## Layout

- `src/root.zig`: library entry point, exposed as the `ursula` Zig module.
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
