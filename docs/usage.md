# Using the client

Use the compiler pinned in `flake.lock`. The code depends on the modern `std.Io`
interfaces in this Zig nightly. The package exports a build module named `ursula`:

```zig
const dependency = b.dependency("ursula_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ursula", dependency.module("ursula"));
```

Add `ursula_zig` to your application's `build.zig.zon` dependencies with a local
`.path` during development or a pinned URL and Zig package hash for distribution.

## Runtime and ownership

```zig
var client = try ursula.Client.init(allocator, io, .{
    .base_url = "http://127.0.0.1:4437",
    // .authorization = "Bearer <token>",
});
defer client.deinit();

const stream: ursula.Stream = .{ .bucket = "demo", .name = "hello" };
var result = try client.send(.{ .read = .{ .stream = stream } });
defer result.deinit();
try result.head.requireSuccess();
const metadata = try result.head.metadata();
// Consume result.body and persist metadata.next_offset or metadata.cursor.
```

Use the `io` and `gpa` supplied by `std.process.Init` in an application. The
allocator must be thread-safe and outlive the client and its results. Do not move a
client after starting requests or copy owning values. Close all exchanges before
closing the client. Finite responses may outlive it. Header and metadata strings
borrow their response; copy tokens you need after `deinit`.

The [read example](../examples/read.zig) compiles during `just test` and can be run
against an existing stream:

```sh
nix develop --command zig build example -- http://127.0.0.1:4437 demo hello
```

## Operations

Pass a tagged `ursula.Operation` to `send` or `open`. The types in
[`protocol.zig`](../src/protocol.zig) list the fields and defaults.

| Tag | Behavior |
| --- | --- |
| `create_bucket` | Acknowledge a bucket. |
| `create_stream` | Create with optional payload, lifetime, producer identity, or attributes. |
| `append` | Append bytes; set `options.closed = true` for append-and-close or an empty close. |
| `read` | Read from an offset, cursor, or JSON record position; optionally long-poll. |
| `head` | Inspect metadata, optionally using `if_none_match`. |
| `delete_stream` | Permanently delete a stream. |
| `get_attributes`, `set_attributes` | Read or replace the JSON attribute object. |
| `append_batch` | Send independent length-prefixed frames. Inspect every JSON acknowledgement. |
| `publish_snapshot`, `read_snapshot`, `delete_snapshot` | Work with immutable checkpoint blobs. |
| `advance_retention` | Explicitly discard history before a checkpoint boundary. |
| `bootstrap` | Fetch raw `multipart/mixed` snapshot and update bytes. |

Offsets and cursors are opaque; reuse server-returned strings exactly. JSON record
ordinals are numeric. Check `metadata.hasExtension("json-record-coordinates-v1")`
before using record options. Attribute objects and batch acknowledgements remain
JSON bytes for the caller to parse. Bootstrap multipart decoding is not implemented.

For appends that may need retries, supply all of `Producer.id`, `epoch`, and `seq`.
Reuse the identity and identical payload after an uncertain result; advance the
sequence only after handling the acknowledgement. The client does not retry writes,
reconnect reads, refresh credentials, or choose producer identities automatically.

## Responses and limits

HTTP failures remain values: inspect `result.head.status`, `result.body`, and
`result.head.header("Retry-After")`. Optional `requireSuccess()` maps common statuses
to errors. `metadata()` rejects malformed typed headers and duplicate singleton
fields. All raw headers remain available through `head.headers()`.

The default body limit is 8 MiB and the header limit is 32 KiB, configurable in
`Client.Options`. Body overflow returns `StreamTooLong`; it never returns truncated
success. For snapshots and other larger responses, use `open` and stream the body
to a caller-owned writer:

```zig
const exchange = try client.open(.{ .read_snapshot = .{ .stream = stream, .offset = saved_offset } });
defer exchange.deinit();
try exchange.head.requireSuccess();
_ = try exchange.body.streamRemaining(output_writer);
```

`open` provides a `*std.Io.Reader`; HTTP chunk framing is already removed. Call
`exchange.readError()` after `ReadFailed` for additional diagnostics. Cancel tasks
through the supplied I/O runtime to interrupt pending operations. The client does
not impose a timeout; applications must choose their own deadline policy.

Redirects are returned unchanged, including the latest-snapshot `307`. Inspect
`Location` and validate the destination before deliberately issuing another request.
Authorization is never forwarded automatically. HTTPS certificate validation uses
Zig's standard HTTP client. Tests cover HTTP loopback fixtures and a real local
Ursula server; TLS and multi-node clusters are not covered. See
[integration testing](integration-tests.md) for the opt-in server suite.

## Live SSE reads

Open a stream, inspect its response, then initialize the decoder from the headers:

```zig
const exchange = try client.open(.{ .read = .{
    .stream = stream,
    .options = .{ .position = .now, .live = .sse },
} });
defer exchange.deinit();
try exchange.head.requireSuccess();
var decoder = try ursula.sse.Decoder.fromHead(allocator, exchange.body, exchange.head, .{});
defer decoder.deinit();
while (try decoder.next()) |event| {
    // event.name, event.data, and event.id borrow reusable decoder buffers.
    // Process or copy them before calling next again.
    if (std.mem.eql(u8, event.name, "control")) {
        var control = try event.parseControl(allocator);
        defer control.deinit();
        // Persist streamCursor or streamNextOffset AFTER applying preceding data.
        if (control.value.streamClosed) break;
    }
}
```

`fromHead` requires HTTP 200 and `text/event-stream`. Handle a 204, redirect, or
error response before constructing it. The decoder honors `Stream-Sse-Data-Encoding`
and returns decoded binary bytes for data events. Control events stay JSON. Their
parsed strings are independently owned until the parsed result's `deinit`.

Use configurable `sse.Limits` for larger events. Defaults are 64 KiB per line and
1 MiB per event, counting framing field lines. Invalid UTF-8, invalid base64,
oversized events, and reader errors stop decoding. Destroy a failed decoder and
reconnect with a fresh one if application policy permits.

A `null` event means the connection ended, not that the durable stream is closed.
Reopen from the last successfully applied control cursor or offset. Do not
reconnect after `streamClosed`. Handle `credential-expired` by refreshing the
credential before reconnecting. The parser exposes unknown event names, persistent
SSE IDs, and retry hints but does not enact browser EventSource reconnect behavior.
For JSON data, buffer incomplete NDJSON records across events before parsing.

The compiled [tail example](../examples/tail.zig) prints decoded data and exits on
closure. It reports a disconnect rather than reconnecting automatically:

```sh
nix develop --command zig build tail -- http://127.0.0.1:4437 demo hello
```
