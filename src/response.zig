//! Owned HTTP responses. HTTP failures remain inspectable values.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Owned response headers. Returned header and metadata slices borrow this value.
pub const Head = struct {
    allocator: Allocator,
    bytes: []u8,
    status: std.http.Status,

    /// Copies a complete HTTP response head before std.http reuses its buffer.
    pub fn init(allocator: Allocator, bytes: []const u8) !Head {
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        const parsed = try std.http.Client.Response.Head.parse(copy);
        return .{ .allocator = allocator, .bytes = copy, .status = parsed.status };
    }

    pub fn deinit(self: *Head) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Iterates all headers, including unknown and repeated headers.
    pub fn headers(self: Head) std.http.HeaderIterator {
        return .init(self.bytes);
    }

    /// Case-insensitive lookup of the first matching raw header.
    pub fn header(self: Head, name: []const u8) ?[]const u8 {
        var it = self.headers();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// Rejects ambiguous duplicate singleton headers, including identical values.
    pub fn singleHeader(self: Head, name: []const u8) !?[]const u8 {
        var result: ?[]const u8 = null;
        var it = self.headers();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
            if (result != null) return error.DuplicateHeader;
            result = h.value;
        }
        return result;
    }

    /// True for 2xx; 304 and redirects are separate, inspectable outcomes.
    pub fn isSuccess(self: Head) bool {
        return self.status.class() == .success;
    }

    /// Optional convenience classification. Retains the body and original headers.
    pub fn requireSuccess(self: Head) !void {
        if (self.isSuccess()) return;
        return switch (self.status) {
            .bad_request => error.BadRequest,
            .unauthorized => error.Unauthorized,
            .forbidden => error.Forbidden,
            .not_found => error.NotFound,
            .conflict => error.Conflict,
            .gone => error.Gone,
            .precondition_failed => error.PreconditionFailed,
            .payload_too_large => error.PayloadTooLarge,
            .too_many_requests => error.RateLimited,
            .service_unavailable => error.ServiceUnavailable,
            else => error.UnexpectedStatus,
        };
    }

    /// Parses known fields without requiring operation-specific headers. Unknown
    /// fields remain available through headers(); malformed known fields fail.
    pub fn metadata(self: Head) !Metadata {
        return .{
            .next_offset = try self.singleHeader("Stream-Next-Offset"),
            .cursor = try self.singleHeader("Stream-Cursor"),
            .earliest_offset = try self.singleHeader("Stream-Earliest-Offset"),
            .closed = try self.boolean("Stream-Closed"),
            .up_to_date = try self.boolean("Stream-Up-To-Date"),
            .content_type = try self.singleHeader("Content-Type"),
            .etag = try self.singleHeader("ETag"),
            .location = try self.singleHeader("Location"),
            .retry_after = try self.singleHeader("Retry-After"),
            .extensions = try self.singleHeader("Stream-Extensions"),
            .snapshot_offset = try self.singleHeader("Stream-Snapshot-Offset"),
            .snapshot_digest = try self.singleHeader("Stream-Snapshot-Digest"),
            .record_first = try self.unsigned("Stream-Record-First"),
            .record_start = try self.unsigned("Stream-Record-Start"),
            .record_next = try self.unsigned("Stream-Record-Next"),
            .producer_epoch = try self.unsigned("Producer-Epoch"),
            .producer_seq = try self.unsigned("Producer-Seq"),
            .producer_expected_seq = try self.unsigned("Producer-Expected-Seq"),
            .producer_received_seq = try self.unsigned("Producer-Received-Seq"),
            .ttl_seconds = try self.unsigned("Stream-TTL"),
            .expires_at = try self.singleHeader("Stream-Expires-At"),
            .sse_data_encoding = try self.singleHeader("Stream-Sse-Data-Encoding"),
            .data_content_type = try self.singleHeader("Stream-Data-Content-Type"),
        };
    }

    fn boolean(self: Head, name: []const u8) !?bool {
        const raw = (try self.singleHeader(name)) orelse return null;
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return error.InvalidResponseHeader;
    }

    fn unsigned(self: Head, name: []const u8) !?u64 {
        const raw = (try self.singleHeader(name)) orelse return null;
        if (raw.len == 0) return error.InvalidResponseHeader;
        for (raw) |c| if (!std.ascii.isDigit(c)) return error.InvalidResponseHeader;
        return std.fmt.parseInt(u64, raw, 10) catch error.InvalidResponseHeader;
    }
};

/// Parsed protocol metadata; every string borrows the originating Head.
pub const Metadata = struct {
    next_offset: ?[]const u8,
    cursor: ?[]const u8,
    earliest_offset: ?[]const u8,
    closed: ?bool,
    up_to_date: ?bool,
    content_type: ?[]const u8,
    etag: ?[]const u8,
    location: ?[]const u8,
    retry_after: ?[]const u8,
    extensions: ?[]const u8,
    snapshot_offset: ?[]const u8,
    snapshot_digest: ?[]const u8,
    record_first: ?u64,
    record_start: ?u64,
    record_next: ?u64,
    producer_epoch: ?u64,
    producer_seq: ?u64,
    producer_expected_seq: ?u64,
    producer_received_seq: ?u64,
    ttl_seconds: ?u64,
    expires_at: ?[]const u8,
    sse_data_encoding: ?[]const u8,
    data_content_type: ?[]const u8,

    /// Matches whole comma-separated capability tokens, not substrings.
    pub fn hasExtension(self: Metadata, token: []const u8) bool {
        if (token.len == 0) return false;
        var it = std.mem.splitScalar(u8, self.extensions orelse return false, ',');
        while (it.next()) |part| if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), token)) return true;
        return false;
    }
};

/// A finite response owning both its headers and its body. Call deinit once.
pub const Response = struct {
    head: Head,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.head.allocator.free(self.body);
        self.head.deinit();
        self.* = undefined;
    }
};

test "metadata preserves opaque tokens and parses case-insensitive fields" {
    var head = try Head.init(std.testing.allocator, "HTTP/1.1 200 OK\r\nstream-next-offset: opaque/0001\r\nStream-Cursor: a=b\r\nStream-Up-To-Date: true\r\nStream-Closed: false\r\nStream-Record-Next: 42\r\nStream-Extensions: one, json-record-coordinates-v1\r\nX-Custom: yes\r\n\r\n");
    defer head.deinit();
    const meta = try head.metadata();
    try std.testing.expectEqualStrings("opaque/0001", meta.next_offset.?);
    try std.testing.expectEqualStrings("a=b", meta.cursor.?);
    try std.testing.expectEqual(true, meta.up_to_date.?);
    try std.testing.expectEqual(false, meta.closed.?);
    try std.testing.expectEqual(@as(u64, 42), meta.record_next.?);
    try std.testing.expect(meta.hasExtension("json-record-coordinates-v1"));
    try std.testing.expect(!meta.hasExtension("record-coordinates"));
    try std.testing.expectEqualStrings("yes", head.header("x-custom").?);
}

test "malformed and duplicate singleton response headers stay inspectable" {
    for ([_][]const u8{ "Stream-Closed: yes", "Stream-Record-Next: -1", "Stream-Record-Next: 1_0", "Stream-Record-Next: 18446744073709551616" }) |line| {
        const raw = try std.testing.allocator.print("HTTP/1.1 200 OK\r\n{s}\r\n\r\n", .{line});
        defer std.testing.allocator.free(raw);
        var head = try Head.init(std.testing.allocator, raw);
        defer head.deinit();
        try std.testing.expectError(error.InvalidResponseHeader, head.metadata());
    }
    var duplicate = try Head.init(std.testing.allocator, "HTTP/1.1 200 OK\r\nStream-Next-Offset: 1\r\nstream-next-offset: 2\r\n\r\n");
    defer duplicate.deinit();
    try std.testing.expectError(error.DuplicateHeader, duplicate.metadata());
    var failure = try Head.init(std.testing.allocator, "HTTP/1.1 409 Conflict\r\nProducer-Expected-Seq: 7\r\n\r\n");
    defer failure.deinit();
    try std.testing.expectError(error.Conflict, failure.requireSuccess());
    try std.testing.expectEqual(@as(u64, 7), (try failure.metadata()).producer_expected_seq.?);
}
