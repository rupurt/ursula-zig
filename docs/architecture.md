# Client architecture

## Protocol baseline

The implementation follows the [Ursula API overview](https://ursula.tonbo.io/docs/api/overview/)
and its linked endpoint pages, checked on 2026-09-22. The
[extensions specification](https://ursula.tonbo.io/docs/specs/extensions/) supplies
batch framing, record coordinates, attributes, and snapshot details. Ursula's
endpoint documentation takes precedence where it differs from the broader protocol.
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
- SSE decoding will operate on `std.Io.Reader`, independently of HTTP and the
  application's choice of runtime.

## Protocol decisions

IDs are raw input, percent-encoded exactly once as path components. Buckets follow
`[a-z0-9_-]{4,64}` and stream IDs have a 122-byte UTF-8 limit. Dot path segments are
rejected. A base URL may include a deployment prefix but no credentials, query, or
fragment. Credentials belong in an explicit authorization header.

Offsets and cursors remain opaque strings. Clients return them unchanged to the
server. Only JSON record ordinals and producer counters are numeric. Producer
identity is explicit and counters are bounded to `2^53 - 1`. There are no automatic
write retries or producer-sequence mutations.

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
Ursula deployment. The read-only usage example is compiled as part of the test step.

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
