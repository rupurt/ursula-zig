# Client architecture

## Protocol baseline

The implementation follows the [Ursula API overview](https://ursula.tonbo.io/docs/api/overview/)
and its linked endpoint pages, checked on 2026-09-22. The
[extensions specification](https://ursula.tonbo.io/docs/specs/extensions/) supplies
batch framing, record coordinates, attributes, and snapshot details. Ursula's
endpoint documentation is qualified by verified behavior of the pinned server
where it conflicts with the protocol; known discrepancies are recorded below.
The documentation is a moving target; check it again when adding behavior.

## Layers and ownership

- `protocol.zig` describes operations with tagged unions and borrowed inputs.
  Lifetime and read-position unions prevent conflicting options.
- `request.zig` validates operations and encodes URLs and headers without I/O.
  `PreparedRequest` owns an arena holding its URL, headers, and encoded batch body.
  Ordinary payloads are borrowed. Call `deinit` once; do not copy an owning value.
- `Client.zig` accepts `std.Io` and uses `std.http.Client`. `open` allocates an
  `Exchange` at a stable address because the HTTP body reader refers back to its
  request. `send` collects finite responses with a configurable byte limit.
- `response.zig` copies response headers before body consumption invalidates the
  HTTP parser's slices. A finite `Response` owns both headers and body; it can
  outlive its client. Parsed metadata borrows that response head.
- `sse.zig` decodes a `std.Io.Reader` independently of HTTP and the runtime.
  `Decoder` owns reusable bounded buffers. Events borrow those buffers; parsed
  control JSON owns its storage and survives subsequent events.

## Protocol decisions

IDs are raw input, percent-encoded exactly once as path components. Buckets follow
`[a-z0-9_-]{4,64}`. The combined UTF-8 `bucket/stream` identity, including the slash,
has a 122-byte limit. Stream names cannot contain slash, NUL, or `..`, or equal
the reserved name `streams`. The client also rejects `.` to prevent URL path
normalization. These rules match the v0.5.1 server's
[validator](https://github.com/tonbo-io/ursula/blob/v0.5.1/crates/ursula-stream/src/validate.rs);
the create-stream endpoint documentation understates the restrictions.
A base URL may include a deployment prefix but no credentials, query, or
fragment. Credentials belong in an explicit authorization header.

Offsets and cursors remain opaque strings. Clients return them unchanged to the
server, but they serve different purposes: `Position` selects the byte/record
coordinate, while `ReadOptions.cursor` echoes a cache token alongside it. A cursor
is neither a checkpoint nor a stream-incarnation guard. Only JSON record ordinals
and producer counters are numeric. Producer
identity is explicit and counters are bounded to `2^53 - 1`. There are no automatic
write retries or producer-sequence mutations.

Ursula v0.5.1's [read guide](https://github.com/tonbo-io/ursula/blob/v0.5.1/docs/web/src/content/docs/pages/api/read.mdx)
calls cursor an alternative to offset, and its
[offsets guide](https://github.com/tonbo-io/ursula/blob/v0.5.1/docs/web/src/content/docs/pages/concepts/offsets.mdx)
claims stream-incarnation protection. Direct HTTP and client tests instead show
cursor-only catch-up restarting at zero and cursor-only long-poll returning 400.
The [server](https://github.com/tonbo-io/ursula/blob/v0.5.1/crates/ursula/src/lib.rs#L3050)
and the [protocol's sections 5.7/8.1](https://github.com/tonbo-io/ursula/blob/v0.5.1/docs/web/src/content/docs/pages/specs/durable-stream.mdx)
use a position plus a separate cursor. The client follows that separation; no
promise of detecting deleted/recreated streams is inferred from a cursor.

Append-batch sends independent length-prefixed records. Its outer HTTP success
status does not establish success for every frame: callers must inspect the JSON
acknowledgements. This endpoint cannot carry producer or conditional-write controls.

Snapshots and retention are separate operations. Publishing a snapshot does not
advance retention. Bootstrap returns multipart bytes; decoding and applying them
belongs to the application until a separate multipart API is implemented.

Bucket listing, bucket metadata, and bucket deletion are absent because Ursula's
API overview lists them as unimplemented. Group administration is outside this SDK.

## Validation

`just check` validates formatting, builds the module, and runs tests. Request tests
cover every endpoint's method and URL, injection and option validation, frame
encoding, and allocation-failure cleanup. Keep protocol tests independent of a live
Ursula deployment. Transport tests use a deterministic loopback HTTP
fixture, including failure, size limits, connection reuse, cancellation, abandoned
live bodies, and allocation-failure cleanup. They need local socket access, not an
Ursula deployment. Both usage examples are compiled as part of the test step.

`just test integration` separately runs black-box tests against source-built
Ursula v0.5.1. A Python standard-library launcher owns a fresh loopback server,
waits for readiness, passes its URL to the Zig tests, enforces deadlines, and
stops both processes on failure or interruption. The tests exercise the public
client with `std.testing.io` and the testing allocator. See
[integration testing](integration-tests.md) for coverage and upgrade instructions.

## Transport policy

All HTTP statuses, including redirects, 304, and server errors, return response
values. `requireSuccess` is an optional classifier; it does not discard the error
body or headers. Redirects are never automatically followed. This preserves write
semantics and prevents forwarding authorization to a different server. A caller
may validate `Location` and deliberately select a new client endpoint.

Requests advertise `Accept-Encoding: identity`; unsupported compressed responses
fail explicitly. HTTP chunk framing is decoded by Zig. Headers default to a 32 KiB
limit, collected bodies to 8 MiB. `open` exposes a reader for larger bodies. HEAD,
204, and 304 responses never wait for a body. Unread exchanges close their socket
instead of draining potentially unbounded data.

The caller owns runtime policy: scheduling, cancellation, deadlines, and retry
backoff. A blocked operation can be canceled through `std.Io` futures or groups.
After a body reader reports `ReadFailed`, `Exchange.readError()` exposes the
underlying framing or transport error, including cancellation.

## Live reads

The parser follows [SSE event framing](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)
and [Ursula binary SSE semantics](https://ursula.tonbo.io/docs/concepts/binary-sse/).
It handles byte fragmentation, UTF-8 BOM, LF/CRLF/CR, comments, multiline data,
event names, persistent IDs, and numeric retry hints. It rejects invalid UTF-8
instead of the browser algorithm's replacement behavior. Incomplete events at EOF
are discarded. Unknown event types remain visible to callers.

Only `event: data` is base64-decoded when the response advertises it. Newlines
inserted by SSE framing are removed before decoding binary payloads; text payloads
retain SSE newline joining. Control events remain JSON, including optional record
coordinates and unknown future fields. NDJSON record assembly is the caller's job.

Do not treat `upToDate` or transport EOF as stream closure. Persist a control
checkpoint only after applying preceding data. Reconnect from the last applied
offset or record position, echoing the cursor separately when supplied, unless
`streamClosed` is true. Automatic reconnect, credential
refresh, durable checkpoint storage, and retry backoff are application policies.

The decoder defaults to 64 KiB lines and 1 MiB events. The event budget counts
non-comment field lines and delimiters; line limits also apply to comments. These
limits are configurable separately from HTTP body collection limits. Decoder
errors are terminal, so callers cannot accidentally continue a corrupted frame.

## Further work

TLS and multi-node durability tests, multipart decoding, typed batch acknowledgement
parsing, optional higher-level reconnect policy, and streamed request uploads are
not implemented. Add them as separate tested APIs rather than changing raw response
semantics or introducing hidden retry behavior.
