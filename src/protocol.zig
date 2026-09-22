//! Typed inputs for Ursula's public HTTP API. All input slices are borrowed.

/// A bucket and stream ID, supplied as raw, unescaped UTF-8.
pub const Stream = struct { bucket: []const u8, name: []const u8 };

/// Explicit identity for an append attempt. Reuse all fields and the same payload
/// when retrying an uncertain write. The client never advances these counters.
pub const Producer = struct {
    id: []const u8,
    epoch: u64,
    seq: u64,
    pub const max_counter = (1 << 53) - 1;
};

/// Mutually exclusive lifetime settings for stream creation.
pub const Lifetime = union(enum) { ttl_seconds: u64, expires_at: []const u8 };

/// Headers controlling stream creation and its optional initial payload.
pub const CreateOptions = struct {
    body: []const u8 = "",
    content_type: []const u8 = "application/octet-stream",
    closed: bool = false,
    lifetime: ?Lifetime = null,
    seq: ?[]const u8 = null,
    producer: ?Producer = null,
    /// JSON attribute object; the server validates its schema.
    attributes: ?[]const u8 = null,
};

/// Append bytes, optionally closing the stream in the same operation.
pub const AppendOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    closed: bool = false,
    seq: ?[]const u8 = null,
    producer: ?Producer = null,
    record_match: ?u64 = null,
};

/// A read position. Offset and cursor strings must be passed back unchanged.
pub const Position = union(enum) {
    beginning,
    now,
    offset: []const u8,
    cursor: []const u8,
    record: u64,
    record_now,
    tail_records: u64,
};

/// Read modes share the same route. Use Client.open for unbounded SSE bodies.
pub const ReadOptions = struct {
    position: Position = .beginning,
    live: enum { catch_up, long_poll, sse } = .catch_up,
    max_bytes: ?u64 = null,
    max_records: ?u64 = null,
    envelope: bool = false,
    if_none_match: ?[]const u8 = null,
};

/// Snapshot and retention boundaries use either an opaque offset or JSON ordinal.
pub const Boundary = union(enum) { offset: []const u8, record: u64 };

/// Every supported route has a typed operation; unsupported bucket routes are
/// intentionally absent. Bodies and option strings are borrowed during a call.
pub const Operation = union(enum) {
    create_bucket: []const u8,
    create_stream: struct { stream: Stream, options: CreateOptions = .{} },
    append: struct { stream: Stream, body: []const u8, options: AppendOptions = .{} },
    read: struct { stream: Stream, options: ReadOptions = .{} },
    head: struct { stream: Stream, if_none_match: ?[]const u8 = null },
    delete_stream: Stream,
    get_attributes: Stream,
    set_attributes: struct { stream: Stream, json: []const u8 },
    /// Each frame is a separate append. Inspect every acknowledgement in the JSON
    /// response, even when its HTTP status is 200. Producer controls are unsupported.
    append_batch: struct { stream: Stream, frames: []const []const u8, content_type: []const u8 = "application/octet-stream" },
    publish_snapshot: struct { stream: Stream, at: Boundary, body: []const u8, content_type: []const u8 = "application/octet-stream", match: ?[]const u8 = null },
    /// Null requests the latest snapshot (usually a 307 with Location).
    read_snapshot: struct { stream: Stream, offset: ?[]const u8 = null },
    delete_snapshot: struct { stream: Stream, offset: []const u8 },
    advance_retention: struct { stream: Stream, at: Boundary },
    /// Returns the raw multipart/mixed body; no multipart decoding is performed.
    bootstrap: Stream,
};
