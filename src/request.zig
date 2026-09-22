//! Pure, allocation-checked request construction, separate from network I/O.
const std = @import("std");
const p = @import("protocol.zig");
const Allocator = std.mem.Allocator;
const PreparedRequest = @This();

arena: std.heap.ArenaAllocator,
method: std.http.Method,
url: []const u8,
headers: []const std.http.Header,
/// Borrowed from the operation, except encoded append-batch bodies.
body: []const u8,

/// Owns URL and headers. The operation's body must outlive the prepared request.
pub fn init(gpa: Allocator, base_url: []const u8, operation: p.Operation) !PreparedRequest {
    try validateBaseUrl(base_url);
    var b: Builder = .{ .arena = .init(gpa) };
    errdefer b.arena.deinit();
    try b.path.appendSlice(b.allocator(), std.mem.trimEnd(u8, base_url, "/"));
    var method: std.http.Method = .GET;
    var body: []const u8 = "";
    switch (operation) {
        .create_bucket => |bucket| {
            method = .PUT;
            try validateBucket(bucket);
            try b.segment(bucket);
        },
        .create_stream => |v| {
            method = .PUT;
            try b.stream(v.stream);
            const o = v.options;
            body = o.body;
            try b.contentType(o.content_type);
            if (o.closed) try b.header("Stream-Closed", "true");
            if (o.lifetime) |lifetime| switch (lifetime) {
                .ttl_seconds => |n| try b.numberHeader("Stream-TTL", n),
                .expires_at => |s| try b.header("Stream-Expires-At", s),
            };
            if (o.seq) |s| try b.header("Stream-Seq", s);
            if (o.producer) |producer| try b.producer(producer);
            if (o.attributes) |json| {
                if (json.len > 16 * 1024) return error.AttributesTooLarge;
                try b.header("Stream-Attrs", json);
            }
        },
        .append => |v| {
            method = .POST;
            try b.stream(v.stream);
            if (v.body.len == 0 and !v.options.closed) return error.EmptyAppend;
            body = v.body;
            if (body.len != 0) try b.contentType(v.options.content_type);
            if (v.options.closed) try b.header("Stream-Closed", "true");
            if (v.options.seq) |s| try b.header("Stream-Seq", s);
            if (v.options.producer) |producer| try b.producer(producer);
            if (v.options.record_match) |n| try b.numberHeader("Stream-Record-Match", n);
        },
        .read => |v| {
            try b.stream(v.stream);
            const o = v.options;
            const record_aware = switch (o.position) {
                .record, .record_now, .tail_records => true,
                else => false,
            };
            if (o.max_records != null and (!record_aware or o.max_bytes != null)) return error.InvalidReadOptions;
            if (o.envelope and !record_aware) return error.InvalidReadOptions;
            switch (o.position) {
                .beginning => try b.query("offset", "-1"),
                .now => try b.query("offset", "now"),
                .offset => |s| try b.queryToken("offset", s),
                .cursor => |s| try b.queryToken("cursor", s),
                .record => |n| try b.numberQuery("record", n),
                .record_now => try b.query("record", "now"),
                .tail_records => |n| try b.numberQuery("tail_records", n),
            }
            switch (o.live) {
                .catch_up => {},
                .long_poll => try b.query("live", "long-poll"),
                .sse => {
                    try b.query("live", "sse");
                    try b.header("Accept", "text/event-stream");
                },
            }
            if (o.max_bytes) |n| try b.numberQuery("max_bytes", n);
            if (o.max_records) |n| try b.numberQuery("max_records", n);
            if (o.envelope) try b.query("record_view", "envelope");
            if (o.if_none_match) |s| try b.header("If-None-Match", s);
        },
        .head => |v| {
            method = .HEAD;
            try b.stream(v.stream);
            if (v.if_none_match) |s| try b.header("If-None-Match", s);
        },
        .delete_stream => |s| {
            method = .DELETE;
            try b.stream(s);
        },
        .get_attributes => |s| {
            try b.stream(s);
            try b.segment("attrs");
        },
        .set_attributes => |v| {
            method = .PUT;
            try b.stream(v.stream);
            try b.segment("attrs");
            if (v.json.len > 16 * 1024) return error.AttributesTooLarge;
            try b.contentType("application/json");
            body = v.json;
        },
        .append_batch => |v| {
            method = .POST;
            try b.stream(v.stream);
            try b.segment("append-batch");
            try b.contentType(v.content_type);
            if (v.frames.len == 0 or v.frames.len > 512) return error.InvalidBatch;
            var size: usize = 0;
            for (v.frames) |frame| {
                if (frame.len == 0 or frame.len > 32 * 1024 * 1024 - 4) return error.InvalidBatch;
                size = std.math.add(usize, size, frame.len + 4) catch return error.InvalidBatch;
                if (size > 32 * 1024 * 1024) return error.InvalidBatch;
            }
            const encoded = try b.allocator().alloc(u8, size);
            var i: usize = 0;
            for (v.frames) |frame| {
                std.mem.writeInt(u32, encoded[i..][0..4], @intCast(frame.len), .big);
                @memcpy(encoded[i + 4 ..][0..frame.len], frame);
                i += 4 + frame.len;
            }
            body = encoded;
        },
        .publish_snapshot => |v| {
            method = .PUT;
            try b.stream(v.stream);
            try b.segment("snapshot");
            try b.boundary(v.at);
            if (v.body.len > 128 * 1024 * 1024) return error.SnapshotTooLarge;
            try b.contentType(v.content_type);
            if (v.match) |s| try b.header("Stream-Snapshot-Match", s);
            body = v.body;
        },
        .read_snapshot => |v| {
            try b.stream(v.stream);
            try b.segment("snapshot");
            if (v.offset) |s| try b.offsetSegment(s);
        },
        .delete_snapshot => |v| {
            method = .DELETE;
            try b.stream(v.stream);
            try b.segment("snapshot");
            try b.offsetSegment(v.offset);
        },
        .advance_retention => |v| {
            method = .PUT;
            try b.stream(v.stream);
            try b.segment("retention");
            try b.boundary(v.at);
        },
        .bootstrap => |s| {
            try b.stream(s);
            try b.segment("bootstrap");
        },
    }
    return .{ .arena = b.arena, .method = method, .url = b.path.items, .headers = b.headers.items, .body = body };
}

/// Releases the owned URL, headers, and any encoded batch body.
pub fn deinit(self: *PreparedRequest) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Rejects credentials, query strings, fragments, and unsafe URI bytes. Prefix
/// paths are supported. Authentication belongs in Client.Options.authorization.
pub fn validateBaseUrl(url: []const u8) !void {
    for (url) |c| if (c <= 0x20 or c >= 0x7f or c == '\\') return error.InvalidBaseUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidBaseUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBaseUrl;
}

/// Validates values before they reach std.http's assertion-based checks.
pub fn validateHeaderValue(value: []const u8) !void {
    for (value) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidHeaderValue;
}

fn validateBucket(bucket: []const u8) !void {
    if (bucket.len < 4 or bucket.len > 64) return error.InvalidBucket;
    for (bucket) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return error.InvalidBucket;
}

const Builder = struct {
    arena: std.heap.ArenaAllocator,
    path: std.ArrayList(u8) = .empty,
    headers: std.ArrayList(std.http.Header) = .empty,
    has_query: bool = false,

    fn allocator(b: *Builder) Allocator {
        return b.arena.allocator();
    }

    fn encode(b: *Builder, raw: []const u8) !void {
        const hex = "0123456789ABCDEF";
        for (raw) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try b.path.append(b.allocator(), c);
            } else {
                try b.path.appendSlice(b.allocator(), &.{ '%', hex[c >> 4], hex[c & 15] });
            }
        }
    }

    fn segment(b: *Builder, raw: []const u8) !void {
        try b.path.append(b.allocator(), '/');
        try b.encode(raw);
    }

    fn stream(b: *Builder, s: p.Stream) !void {
        try validateBucket(s.bucket);
        // Ursula caps the full bucket/stream identity, including its separator.
        // Bucket length is already validated, so the subtraction cannot underflow.
        if (s.name.len == 0 or s.name.len > 121 - s.bucket.len or
            !std.unicode.utf8ValidateSlice(s.name) or
            std.mem.findScalar(u8, s.name, 0) != null or
            std.mem.findScalar(u8, s.name, '/') != null or
            std.mem.find(u8, s.name, "..") != null or
            std.mem.eql(u8, s.name, ".") or std.mem.eql(u8, s.name, "streams"))
            return error.InvalidStream;
        try b.segment(s.bucket);
        try b.segment(s.name);
    }

    fn offsetSegment(b: *Builder, raw: []const u8) !void {
        if (raw.len == 0 or std.mem.eql(u8, raw, ".") or std.mem.eql(u8, raw, "..")) return error.InvalidOffset;
        try b.segment(raw);
    }

    fn boundary(b: *Builder, at: p.Boundary) !void {
        switch (at) {
            .offset => |s| try b.offsetSegment(s),
            .record => |n| try b.numberQuery("record", n),
        }
    }

    fn query(b: *Builder, name: []const u8, value: []const u8) !void {
        try b.path.append(b.allocator(), if (b.has_query) '&' else '?');
        b.has_query = true;
        try b.path.appendSlice(b.allocator(), name);
        try b.path.append(b.allocator(), '=');
        try b.encode(value);
    }

    fn queryToken(b: *Builder, name: []const u8, value: []const u8) !void {
        if (value.len == 0) return error.InvalidReadOptions;
        try b.query(name, value);
    }

    fn numberQuery(b: *Builder, name: []const u8, value: u64) !void {
        try b.query(name, try b.allocator().print("{d}", .{value}));
    }

    fn header(b: *Builder, name: []const u8, value: []const u8) !void {
        try validateHeaderValue(value);
        try b.headers.append(b.allocator(), .{ .name = name, .value = try b.allocator().dupe(u8, value) });
    }

    fn numberHeader(b: *Builder, name: []const u8, value: u64) !void {
        try b.header(name, try b.allocator().print("{d}", .{value}));
    }

    fn contentType(b: *Builder, value: []const u8) !void {
        if (value.len == 0) return error.InvalidContentType;
        try b.header("Content-Type", value);
    }

    fn producer(b: *Builder, value: p.Producer) !void {
        if (value.id.len == 0 or value.epoch > p.Producer.max_counter or value.seq > p.Producer.max_counter) return error.InvalidProducer;
        try b.header("Producer-Id", value.id);
        try b.numberHeader("Producer-Epoch", value.epoch);
        try b.numberHeader("Producer-Seq", value.seq);
    }
};

test {
    _ = @import("request_test.zig");
}
