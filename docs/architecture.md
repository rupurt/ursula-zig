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
- The next layer will accept `std.Io` from the caller and use `std.http.Client`.
  Streaming response state must remain at a stable address because Zig's HTTP
  response and reader refer back to the request.
- SSE decoding will operate on `std.Io.Reader`, independently of HTTP and the
  application's choice of runtime.

## Protocol decisions

IDs are raw input, percent-encoded exactly once as path components. Buckets follow
`[a-z0-9_-]{4,64}` and stream IDs have a 122-byte UTF-8 limit. Dot path segments are
rejected. A base URL may include a deployment prefix but no credentials, query, or
fragment. Credentials belong in an explicit authorization header.

Offsets and cursors remain opaque strings. Clients return them unchanged to the
server. Only JSON record ordinals and producer counters are numeric. Producer
identity is explicit and counters are bounded to `2^53 - 1`. No automatic write
retries or producer-sequence mutation are planned.

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
Ursula deployment. Future transport tests should use a deterministic loopback HTTP
fixture, including failure and cancellation paths.
