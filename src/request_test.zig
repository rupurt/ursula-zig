const std = @import("std");
const t = std.testing;
const Request = @import("request.zig");
const p = @import("protocol.zig");
const stream: p.Stream = .{ .bucket = "demo", .name = "hello" };
const base = "https://example.test/api/";

fn header(r: Request, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

test "routes and HTTP methods match Ursula endpoints" {
    const Case = struct { op: p.Operation, method: std.http.Method, path: []const u8 };
    const cases = [_]Case{
        .{ .op = .{ .create_bucket = "demo" }, .method = .PUT, .path = "/demo" },
        .{ .op = .{ .create_stream = .{ .stream = stream } }, .method = .PUT, .path = "/demo/hello" },
        .{ .op = .{ .append = .{ .stream = stream, .body = "a" } }, .method = .POST, .path = "/demo/hello" },
        .{ .op = .{ .read = .{ .stream = stream } }, .method = .GET, .path = "/demo/hello?offset=-1" },
        .{ .op = .{ .head = .{ .stream = stream } }, .method = .HEAD, .path = "/demo/hello" },
        .{ .op = .{ .delete_stream = stream }, .method = .DELETE, .path = "/demo/hello" },
        .{ .op = .{ .get_attributes = stream }, .method = .GET, .path = "/demo/hello/attrs" },
        .{ .op = .{ .set_attributes = .{ .stream = stream, .json = "{}" } }, .method = .PUT, .path = "/demo/hello/attrs" },
        .{ .op = .{ .append_batch = .{ .stream = stream, .frames = &.{"a"} } }, .method = .POST, .path = "/demo/hello/append-batch" },
        .{ .op = .{ .publish_snapshot = .{ .stream = stream, .at = .{ .offset = "00042" }, .body = "snapshot" } }, .method = .PUT, .path = "/demo/hello/snapshot/00042" },
        .{ .op = .{ .read_snapshot = .{ .stream = stream } }, .method = .GET, .path = "/demo/hello/snapshot" },
        .{ .op = .{ .read_snapshot = .{ .stream = stream, .offset = "a/b?&%" } }, .method = .GET, .path = "/demo/hello/snapshot/a%2Fb%3F%26%25" },
        .{ .op = .{ .delete_snapshot = .{ .stream = stream, .offset = "00042" } }, .method = .DELETE, .path = "/demo/hello/snapshot/00042" },
        .{ .op = .{ .advance_retention = .{ .stream = stream, .at = .{ .record = 42 } } }, .method = .PUT, .path = "/demo/hello/retention?record=42" },
        .{ .op = .{ .bootstrap = stream }, .method = .GET, .path = "/demo/hello/bootstrap" },
    };
    for (cases) |case| {
        var r = try Request.init(t.allocator, base, case.op);
        defer r.deinit();
        try t.expectEqual(case.method, r.method);
        const expected = try t.allocator.print("https://example.test/api{s}", .{case.path});
        defer t.allocator.free(expected);
        try t.expectEqualStrings(expected, r.url);
    }
}

test "raw stream IDs and opaque read tokens are encoded exactly once" {
    var r = try Request.init(t.allocator, base, .{ .read = .{
        .stream = .{ .bucket = "demo", .name = "a%2Fb %?雪" },
        .options = .{ .position = .{ .offset = "offset/+%42" }, .cursor = "a+b/=&%20", .live = .long_poll },
    } });
    defer r.deinit();
    try t.expectEqualStrings("https://example.test/api/demo/a%252Fb%20%25%3F%E9%9B%AA?offset=offset%2F%2B%2542&cursor=a%2Bb%2F%3D%26%2520&live=long-poll", r.url);
}

test "create headers cover lifetime identity and attributes" {
    var r = try Request.init(t.allocator, base, .{ .create_stream = .{ .stream = stream, .options = .{
        .body = "{}",
        .content_type = "application/json",
        .closed = true,
        .lifetime = .{ .ttl_seconds = 3600 },
        .seq = "0001",
        .producer = .{ .id = "writer", .epoch = 7, .seq = 0 },
        .attributes = "{}",
    } } });
    defer r.deinit();
    try t.expectEqualStrings("{}", r.body);
    try t.expectEqualStrings("application/json", header(r, "Content-Type").?);
    try t.expectEqualStrings("true", header(r, "Stream-Closed").?);
    try t.expectEqualStrings("3600", header(r, "Stream-TTL").?);
    try t.expectEqualStrings("0001", header(r, "Stream-Seq").?);
    try t.expectEqualStrings("writer", header(r, "Producer-Id").?);
    try t.expectEqualStrings("7", header(r, "Producer-Epoch").?);
    try t.expectEqualStrings("0", header(r, "Producer-Seq").?);
    try t.expectEqualStrings("{}", header(r, "Stream-Attrs").?);
    try t.expect(header(r, "Stream-Expires-At") == null);
}

test "append preconditions and close-only requests" {
    var r = try Request.init(t.allocator, base, .{ .append = .{ .stream = stream, .body = "", .options = .{ .closed = true, .record_match = 2 } } });
    defer r.deinit();
    try t.expectEqualStrings("true", header(r, "Stream-Closed").?);
    try t.expectEqualStrings("2", header(r, "Stream-Record-Match").?);
    try t.expect(header(r, "Content-Type") == null);
    try t.expectError(error.EmptyAppend, Request.init(t.allocator, base, .{ .append = .{ .stream = stream, .body = "" } }));
}

test "read variants include record limits and conditional SSE headers" {
    var r = try Request.init(t.allocator, base, .{ .read = .{ .stream = stream, .options = .{
        .position = .record_now,
        .cursor = "previous",
        .live = .sse,
        .max_records = 10,
        .envelope = true,
        .if_none_match = "\"etag\"",
    } } });
    defer r.deinit();
    try t.expectEqualStrings("https://example.test/api/demo/hello?record=now&cursor=previous&live=sse&max_records=10&record_view=envelope", r.url);
    try t.expectEqualStrings("text/event-stream", header(r, "Accept").?);
    try t.expectEqualStrings("\"etag\"", header(r, "If-None-Match").?);
    const invalid = [_]p.ReadOptions{
        .{ .max_records = 10 },                                                .{ .envelope = true },
        .{ .position = .{ .record = 0 }, .max_records = 10, .max_bytes = 10 }, .{ .position = .{ .offset = "" } },
        .{ .cursor = "" },
    };
    for (invalid) |options| try t.expectError(error.InvalidReadOptions, Request.init(t.allocator, base, .{ .read = .{ .stream = stream, .options = options } }));
}

test "cursor supplements every position and never suppresses its coordinate" {
    const Case = struct { position: p.Position, query: []const u8 };
    for ([_]Case{
        .{ .position = .beginning, .query = "offset=-1" },
        .{ .position = .now, .query = "offset=now" },
        .{ .position = .{ .offset = "00008" }, .query = "offset=00008" },
        .{ .position = .{ .record = 1 }, .query = "record=1" },
        .{ .position = .record_now, .query = "record=now" },
        .{ .position = .{ .tail_records = 2 }, .query = "tail_records=2" },
    }) |case| {
        var r = try Request.init(t.allocator, base, .{ .read = .{ .stream = stream, .options = .{
            .position = case.position,
            .cursor = "cache-token",
            .live = .long_poll,
        } } });
        defer r.deinit();
        const expected = try t.allocator.print("https://example.test/api/demo/hello?{s}&cursor=cache-token&live=long-poll", .{case.query});
        defer t.allocator.free(expected);
        try t.expectEqualStrings(expected, r.url);
    }
}

test "append-batch encodes independent big-endian frames" {
    var r = try Request.init(t.allocator, base, .{ .append_batch = .{ .stream = stream, .frames = &.{ "a", "\x00\xff" } } });
    defer r.deinit();
    try t.expectEqualSlices(u8, "\x00\x00\x00\x01a\x00\x00\x00\x02\x00\xff", r.body);
    try t.expectError(error.InvalidBatch, Request.init(t.allocator, base, .{ .append_batch = .{ .stream = stream, .frames = &.{} } }));
    try t.expectError(error.InvalidBatch, Request.init(t.allocator, base, .{ .append_batch = .{ .stream = stream, .frames = &.{""} } }));
    const too_many: [513][]const u8 = @splat("x");
    try t.expectError(error.InvalidBatch, Request.init(t.allocator, base, .{ .append_batch = .{ .stream = stream, .frames = &too_many } }));
}

test "invalid addresses and identifiers fail before I/O" {
    for ([_][]const u8{ "ftp://host", "http://", "https://user:pass@host", "http://host?x=1", "http://host/#x", "http://host\r\nInjected: yes", "http://host/a b" }) |url| {
        try t.expectError(error.InvalidBaseUrl, Request.init(t.allocator, url, .{ .create_bucket = "demo" }));
    }
    for ([_][]const u8{ "a", "UPPER", "de/mo", "demo?x=1" }) |bucket| {
        try t.expectError(error.InvalidBucket, Request.init(t.allocator, base, .{ .create_bucket = bucket }));
    }
    for ([_][]const u8{ "", "..", ".", "a/b", "a/../b", "a..b", "streams", "a\x00b", "\xff", &@as([123]u8, @splat('a')) }) |name| {
        try t.expectError(error.InvalidStream, Request.init(t.allocator, base, .{ .delete_stream = .{ .bucket = "demo", .name = name } }));
    }
}

test "stream identity limit counts bucket separator and UTF-8 bytes" {
    const name = @as([114]u8, @splat('a')) ++ "雪"; // 117 bytes, not 115.
    var exact = try Request.init(t.allocator, base, .{ .head = .{ .stream = .{ .bucket = "demo", .name = name } } });
    defer exact.deinit();
    try t.expectError(error.InvalidStream, Request.init(t.allocator, base, .{ .head = .{ .stream = .{ .bucket = "demos", .name = name } } }));
    const bucket: [64]u8 = @splat('b');
    const max_name: [57]u8 = @splat('n');
    var long_bucket = try Request.init(t.allocator, base, .{ .head = .{ .stream = .{ .bucket = &bucket, .name = &max_name } } });
    defer long_bucket.deinit();
    try t.expectError(error.InvalidStream, Request.init(t.allocator, base, .{ .head = .{ .stream = .{ .bucket = &bucket, .name = max_name ++ "n" } } }));
}

test "header injection and incomplete producer identity are rejected" {
    for ([_][]const u8{ "text/plain\r\nX: y", "text/plain\nX: y", "text/plain\x00" }) |content_type| {
        try t.expectError(error.InvalidHeaderValue, Request.init(t.allocator, base, .{ .append = .{ .stream = stream, .body = "a", .options = .{ .content_type = content_type } } }));
    }
    for ([_]p.Producer{
        .{ .id = "", .epoch = 0, .seq = 0 },
        .{ .id = "id", .epoch = p.Producer.max_counter + 1, .seq = 0 },
        .{ .id = "id", .epoch = 0, .seq = p.Producer.max_counter + 1 },
    }) |producer| {
        try t.expectError(error.InvalidProducer, Request.init(t.allocator, base, .{ .append = .{ .stream = stream, .body = "a", .options = .{ .producer = producer } } }));
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var r = try Request.init(allocator, base, .{ .create_stream = .{ .stream = stream, .options = .{
        .lifetime = .{ .expires_at = "2027-01-01T00:00:00Z" },
        .producer = .{ .id = "writer", .epoch = 1, .seq = 0 },
        .attributes = "{}",
    } } });
    defer r.deinit();
    try t.expectEqualStrings("2027-01-01T00:00:00Z", header(r, "Stream-Expires-At").?);
    var batch = try Request.init(allocator, base, .{ .append_batch = .{ .stream = stream, .frames = &.{ "a", "b" } } });
    defer batch.deinit();
    var read = try Request.init(allocator, base, .{ .read = .{ .stream = stream, .options = .{
        .position = .{ .offset = "opaque/+offset" },
        .cursor = "separate/cache+token",
        .live = .long_poll,
    } } });
    defer read.deinit();
}

test "request construction cleans up every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
