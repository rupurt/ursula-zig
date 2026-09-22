const std = @import("std");
const t = std.testing;
const Client = @import("Client.zig");
const p = @import("protocol.zig");
const Fixture = @import("test_http.zig").Fixture;
const stream: p.Stream = .{ .bucket = "demo", .name = "hello" };

fn clientFor(fixture: Fixture, limit: usize) !Client {
    const url = try fixture.url(t.allocator);
    defer t.allocator.free(url);
    return Client.init(t.allocator, t.io, .{ .base_url = url, .authorization = "Bearer secret", .max_response_bytes = limit });
}

test "HTTP lifecycle preserves payload headers errors and reusable connections" {
    var fixture = try Fixture.init(&.{
        .{ .method = .PUT, .target = "/demo", .response = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n" },
        .{ .method = .PUT, .target = "/demo/hello", .response = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nStream-Next-Offset: 00000\r\n\r\n" },
        .{ .method = .POST, .target = "/demo/hello", .body = "\x00\xffx", .headers = &.{
            .{ .name = "Content-Type", .value = "application/octet-stream" },
            .{ .name = "Content-Length", .value = "3" },
            .{ .name = "Authorization", .value = "Bearer secret" },
            .{ .name = "Producer-Id", .value = "writer" },
            .{ .name = "Producer-Epoch", .value = "1" },
            .{ .name = "Producer-Seq", .value = "0" },
        }, .response = "HTTP/1.1 204 No Content\r\nStream-Next-Offset: 00003\r\nProducer-Seq: 0\r\n\r\n" },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\nStream-Next-Offset: 00003\r\nStream-Up-To-Date: true\r\n\r\n\x00\xffx" },
        .{ .method = .HEAD, .target = "/demo/hello", .response = "HTTP/1.1 200 OK\r\nContent-Length: 5000\r\nStream-Next-Offset: 00003\r\n\r\n" },
        .{ .method = .POST, .target = "/demo/hello", .headers = &.{.{ .name = "Stream-Closed", .value = "true" }}, .response = "HTTP/1.1 204 No Content\r\nStream-Closed: true\r\n\r\n" },
        .{ .method = .DELETE, .target = "/demo/hello", .response = "HTTP/1.1 204 No Content\r\n\r\n" },
        .{ .response = "HTTP/1.1 404 Not Found\r\nContent-Length: 7\r\n\r\nmissing" },
    });
    fixture.reuse_connection = true;
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 1024);
    defer client.deinit();
    const operations = [_]p.Operation{
        .{ .create_bucket = "demo" },                                                                                                     .{ .create_stream = .{ .stream = stream } },
        .{ .append = .{ .stream = stream, .body = "\x00\xffx", .options = .{ .producer = .{ .id = "writer", .epoch = 1, .seq = 0 } } } }, .{ .read = .{ .stream = stream } },
        .{ .head = .{ .stream = stream } },                                                                                               .{ .append = .{ .stream = stream, .body = "", .options = .{ .closed = true } } },
        .{ .delete_stream = stream },                                                                                                     .{ .read = .{ .stream = stream } },
    };
    for (operations, 0..) |operation, i| {
        var response = try client.send(operation);
        defer response.deinit();
        if (i == 3) {
            try t.expectEqualSlices(u8, "\x00\xffx", response.body);
            try t.expectEqualStrings("00003", (try response.head.metadata()).next_offset.?);
        } else if (i == 7) {
            try t.expectError(error.NotFound, response.head.requireSuccess());
            try t.expectEqualStrings("missing", response.body);
        } else {
            try response.head.requireSuccess();
            try t.expectEqual(@as(usize, 0), response.body.len);
        }
    }
    try future.await(t.io);
}

test "chunked bodies can be fragmented and headers survive body consumption" {
    var fixture = try Fixture.init(&.{.{ .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nStream-Next-Offset: opaque\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n" }});
    fixture.fragment = true;
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 5);
    var response = try client.send(.{ .read = .{ .stream = stream } });
    client.deinit();
    defer response.deinit();
    try t.expectEqualStrings("hello", response.body);
    try t.expectEqualStrings("opaque", response.head.header("Stream-Next-Offset").?);
    try future.await(t.io);
}

test "redirect and conditional statuses retain headers and do not resend" {
    var fixture = try Fixture.init(&.{
        .{ .response = "HTTP/1.1 307 Temporary Redirect\r\nContent-Length: 0\r\nLocation: http://example.test/other\r\n\r\n" },
        .{ .response = "HTTP/1.1 304 Not Modified\r\nContent-Length: 900\r\nETag: \"same\"\r\n\r\n" },
    });
    fixture.reuse_connection = true;
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 10);
    defer client.deinit();
    var redirect = try client.send(.{ .read = .{ .stream = stream } });
    defer redirect.deinit();
    try t.expectEqual(.temporary_redirect, redirect.head.status);
    try t.expectEqualStrings("http://example.test/other", redirect.head.header("Location").?);
    var unchanged = try client.send(.{ .read = .{ .stream = stream } });
    defer unchanged.deinit();
    try t.expectEqual(.not_modified, unchanged.head.status);
    try t.expectEqual(@as(usize, 0), unchanged.body.len);
    try future.await(t.io);
}

test "body limit fails without leaking or pooling a half-read response" {
    var fixture = try Fixture.init(&.{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" },
        .{ .response = "HTTP/1.1 204 No Content\r\n\r\n" },
    });
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 4);
    defer client.deinit();
    try t.expectError(error.StreamTooLong, client.send(.{ .read = .{ .stream = stream } }));
    var next = try client.send(.{ .read = .{ .stream = stream } });
    defer next.deinit();
    try next.head.requireSuccess();
    try future.await(t.io);
}

test "truncated chunk framing and unsolicited compression fail" {
    var fixture = try Fixture.init(&.{
        .{ .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na" },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n" },
    });
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 1024);
    defer client.deinit();
    try t.expectError(error.HttpChunkTruncated, client.send(.{ .read = .{ .stream = stream } }));
    try t.expectError(error.UnsupportedContentEncoding, client.send(.{ .read = .{ .stream = stream } }));
    try future.await(t.io);
}

test "abandoning an unbounded live body never drains it" {
    var fixture = try Fixture.init(&.{.{ .target = "/demo/hello?offset=-1&live=sse", .response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" }});
    fixture.hold_open = true;
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 1024);
    defer client.deinit();
    const operation: p.Operation = .{ .read = .{ .stream = stream, .options = .{ .live = .sse } } };
    try t.expectError(error.StreamingRequiresOpen, client.send(operation));
    const exchange = try client.open(operation);
    try t.expectEqual(.ok, exchange.head.status);
    exchange.deinit();
    try t.expectError(error.Canceled, future.cancel(t.io));
}

fn initAllocationCase(allocator: std.mem.Allocator) !void {
    var client = try Client.init(allocator, t.io, .{ .base_url = "https://example.test", .authorization = "Bearer test" });
    defer client.deinit();
}

test "client init cleans up allocation failures and rejects authorization injection" {
    try t.checkAllAllocationFailures(t.allocator, initAllocationCase, .{});
    try t.expectError(error.InvalidHeaderValue, Client.init(t.allocator, t.io, .{ .base_url = "https://example.test", .authorization = "Bearer test\nInjected: yes" }));
}

fn readCancelable(exchange: *Client.Exchange) !void {
    _ = exchange.body.takeByte() catch |err| {
        if (err == error.ReadFailed) return exchange.readError() orelse error.ReadFailed;
        return err;
    };
}

test "the supplied I/O runtime can cancel a blocked streaming read" {
    var fixture = try Fixture.init(&.{.{ .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" }});
    fixture.hold_open = true;
    defer fixture.deinit();
    var server = try t.io.concurrent(Fixture.run, .{&fixture});
    defer server.cancel(t.io) catch {};
    var client = try clientFor(fixture, 1024);
    defer client.deinit();
    const exchange = try client.open(.{ .read = .{ .stream = stream } });
    defer exchange.deinit();
    var read = try t.io.concurrent(readCancelable, .{exchange});
    try t.expectError(error.Canceled, read.cancel(t.io));
}

fn transportAllocationCase(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init(&.{.{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nStream-Next-Offset: 00005\r\n\r\nhello" }});
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    const url = try fixture.url(t.allocator);
    defer t.allocator.free(url);
    var client = try Client.init(allocator, t.io, .{ .base_url = url });
    defer client.deinit();
    var response = try client.send(.{ .read = .{ .stream = stream } });
    defer response.deinit();
    try t.expectEqualStrings("hello", response.body);
    try future.await(t.io);
}

test "HTTP request response and connection cleanup at every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, transportAllocationCase, .{});
}

test "informational HTTP heads are skipped until the final response" {
    var fixture = try Fixture.init(&.{.{ .response = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok" }});
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    var client = try clientFor(fixture, 1024);
    defer client.deinit();
    var result = try client.send(.{ .read = .{ .stream = stream } });
    defer result.deinit();
    try t.expectEqual(.ok, result.head.status);
    try t.expectEqualStrings("ok", result.body);
    try future.await(t.io);
}

test "response header limit is enforced before allocating a body" {
    const raw = try t.allocator.print("HTTP/1.1 200 OK\r\nX-Large: {s}\r\nContent-Length: 0\r\n\r\n", .{@as([1024]u8, @splat('a'))});
    defer t.allocator.free(raw);
    var fixture = try Fixture.init(&.{.{ .response = raw }});
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    const url = try fixture.url(t.allocator);
    defer t.allocator.free(url);
    var client = try Client.init(t.allocator, t.io, .{ .base_url = url, .max_header_bytes = 256 });
    defer client.deinit();
    try t.expectError(error.HttpHeadersOversize, client.send(.{ .read = .{ .stream = stream } }));
    try future.await(t.io);
}
