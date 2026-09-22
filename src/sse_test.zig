const std = @import("std");
const t = std.testing;
const sse = @import("sse.zig");
const Head = @import("response.zig").Head;

const Fragmented = struct {
    interface: std.Io.Reader,
    source: []const u8,
    position: usize = 0,
    chunk: usize,

    fn init(source: []const u8, buffer: []u8, chunk: usize) Fragmented {
        return .{ .source = source, .chunk = chunk, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Fragmented = @alignCast(@fieldParentPtr("interface", reader));
        if (self.position == self.source.len) return error.EndOfStream;
        const size = @min(self.chunk, limit.minInt(self.source.len - self.position));
        const n = try writer.write(self.source[self.position..][0..size]);
        self.position += n;
        return n;
    }
};

test "SSE works with every small chunk size including split UTF-8 and CRLF" {
    const bytes = "\xef\xbb\xbf: heartbeat\r\nevent: data\r\ndata: hello 雪\r\ndata:  second:line\r\n\r\n";
    for (1..bytes.len + 1) |chunk| {
        var buffer: [7]u8 = undefined;
        var reader = Fragmented.init(bytes, &buffer, chunk);
        var decoder = sse.Decoder.init(t.allocator, &reader.interface, .{});
        defer decoder.deinit();
        const event = (try decoder.next()).?;
        try t.expectEqualStrings("data", event.name);
        try t.expectEqualStrings("hello 雪\n second:line", event.data);
        try t.expect(try decoder.next() == null);
    }
}

test "LF CRLF and CR delimiters dispatch equally" {
    for ([_][]const u8{ "data: a\n\n", "data: a\r\n\r\n", "data: a\r\r" }) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        var decoder = sse.Decoder.init(t.allocator, &reader, .{});
        defer decoder.deinit();
        try t.expectEqualStrings("a", (try decoder.next()).?.data);
        try t.expect(try decoder.next() == null);
    }
}

test "empty data dispatches but comments and event-only frames do not" {
    var reader = std.Io.Reader.fixed(": comment\n\nevent: ignored\n\nunknown: ignored\ndata\n\ndata:\n\n");
    var decoder = sse.Decoder.init(t.allocator, &reader, .{});
    defer decoder.deinit();
    const event = (try decoder.next()).?;
    try t.expectEqualStrings("message", event.name);
    try t.expectEqualStrings("", event.data);
    try t.expectEqualStrings("", (try decoder.next()).?.data);
    try t.expect(try decoder.next() == null);
}

test "event IDs and retry values persist with standard invalid-field handling" {
    var reader = std.Io.Reader.fixed("id: first\nretry: 1200\ndata: a\n\nid: bad\x00id\nretry: +2\ndata: b\n\nid:\nretry: 18446744073709551616\ndata: c\n\n");
    var decoder = sse.Decoder.init(t.allocator, &reader, .{});
    defer decoder.deinit();
    const first = (try decoder.next()).?;
    try t.expectEqualStrings("first", first.id.?);
    try t.expectEqual(@as(u64, 1200), first.retry_ms.?);
    const second = (try decoder.next()).?;
    try t.expectEqualStrings("first", second.id.?);
    try t.expectEqual(@as(u64, 1200), second.retry_ms.?);
    const third = (try decoder.next()).?;
    try t.expectEqualStrings("", third.id.?);
    try t.expectEqual(@as(u64, 1200), third.retry_ms.?);
}

test "EOF discards incomplete events and does not imply stream closure" {
    for ([_][]const u8{ "data: partial", "data: partial\n", "event: data\n", ": comment" }) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        var decoder = sse.Decoder.init(t.allocator, &reader, .{});
        defer decoder.deinit();
        try t.expect(try decoder.next() == null);
        try t.expect(try decoder.next() == null);
    }
}

test "binary multiline data is decoded while control JSON and unknown events stay text" {
    var reader = std.Io.Reader.fixed("event: data\ndata: AQIDBAUG\ndata: BwgJCg==\n\nevent: control\ndata: {\"streamNextOffset\":\"opaque\\u002Foffset\",\"streamClosed\":true,\"streamNextRecord\":4,\"futureField\":1}\n\nevent: custom\ndata: unchanged\n\n");
    var decoder = sse.Decoder.init(t.allocator, &reader, .{ .encoding = .base64 });
    defer decoder.deinit();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, (try decoder.next()).?.data);
    var control = try (try decoder.next()).?.parseControl(t.allocator);
    defer control.deinit();
    try t.expect(control.value.streamClosed);
    try t.expect(control.value.isUpToDate());
    try t.expect(control.value.streamCursor == null);
    try t.expectEqual(@as(u64, 4), control.value.streamNextRecord.?);
    const custom = (try decoder.next()).?;
    try t.expectEqualStrings("custom", custom.name);
    try t.expectEqualStrings("unchanged", custom.data);
    // parseControl owns its strings even after the decoder reuses event buffers.
    try t.expectEqualStrings("opaque/offset", control.value.streamNextOffset);
}

test "empty binary payload is valid and malformed base64 is terminal" {
    var empty_reader = std.Io.Reader.fixed("event: data\ndata:\n\n");
    var empty = sse.Decoder.init(t.allocator, &empty_reader, .{ .encoding = .base64 });
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), (try empty.next()).?.data.len);
    for ([_][]const u8{ "?===", "AQI", "AA A", "====", "AQ==junk" }) |value| {
        const bytes = try t.allocator.print("event: data\ndata: {s}\n\n", .{value});
        defer t.allocator.free(bytes);
        var reader = std.Io.Reader.fixed(bytes);
        var decoder = sse.Decoder.init(t.allocator, &reader, .{ .encoding = .base64 });
        defer decoder.deinit();
        try t.expectError(error.InvalidBase64, decoder.next());
        try t.expectError(error.DecoderFailed, decoder.next());
    }
}

test "line and event budgets reject oversized input and tolerate heartbeat streams" {
    var line_reader = std.Io.Reader.fixed("data: large\n\n");
    var line = sse.Decoder.init(t.allocator, &line_reader, .{ .limits = .{ .max_line_bytes = 4 } });
    defer line.deinit();
    try t.expectError(error.LineTooLong, line.next());
    var event_reader = std.Io.Reader.fixed("data: a\ndata: b\n\n");
    var event = sse.Decoder.init(t.allocator, &event_reader, .{ .limits = .{ .max_event_bytes = 8 } });
    defer event.deinit();
    try t.expectError(error.EventTooLong, event.next());
    var comments_reader = std.Io.Reader.fixed(": ping\n: ping\n: ping\ndata:a\n\n");
    var comments = sse.Decoder.init(t.allocator, &comments_reader, .{ .limits = .{ .max_event_bytes = 7 } });
    defer comments.deinit();
    try t.expectEqualStrings("a", (try comments.next()).?.data);
}

test "invalid UTF-8 and malformed control JSON are rejected" {
    var reader = std.Io.Reader.fixed("data: \xff\n\n");
    var decoder = sse.Decoder.init(t.allocator, &reader, .{});
    defer decoder.deinit();
    try t.expectError(error.InvalidUtf8, decoder.next());
    const event: sse.Event = .{ .name = "control", .data = "{}", .id = null, .retry_ms = null };
    try t.expectError(error.MissingField, event.parseControl(t.allocator));
    var bad = event;
    bad.data = "{\"streamNextOffset\":\"\"}";
    try t.expectError(error.InvalidControlEvent, bad.parseControl(t.allocator));
    bad.name = "data";
    try t.expectError(error.NotControlEvent, bad.parseControl(t.allocator));
}

test "SSE response validation checks status MIME type and encoding" {
    var reader = std.Io.Reader.fixed("");
    var valid = try Head.init(t.allocator, "HTTP/1.1 200 OK\r\nContent-Type: Text/Event-Stream; charset=utf-8\r\nStream-Sse-Data-Encoding: base64\r\n\r\n");
    defer valid.deinit();
    var decoder = try sse.Decoder.fromHead(t.allocator, &reader, valid, .{});
    defer decoder.deinit();
    try t.expectEqual(.base64, decoder.encoding);
    for ([_][]const u8{ "HTTP/1.1 204 No Content\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" }) |bytes| {
        var head = try Head.init(t.allocator, bytes);
        defer head.deinit();
        try t.expectError(error.NotEventStream, sse.Decoder.fromHead(t.allocator, &reader, head, .{}));
    }
    var unsupported = try Head.init(t.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nStream-Sse-Data-Encoding: hex\r\n\r\n");
    defer unsupported.deinit();
    try t.expectError(error.UnsupportedSseEncoding, sse.Decoder.fromHead(t.allocator, &reader, unsupported, .{}));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var reader = std.Io.Reader.fixed("id: session\nevent: data\ndata: AQID\n\nevent: control\ndata: {\"streamNextOffset\":\"opaque\",\"streamCursor\":\"cursor\"}\n\n");
    var decoder = sse.Decoder.init(allocator, &reader, .{ .encoding = .base64 });
    defer decoder.deinit();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, (try decoder.next()).?.data);
    var control = try (try decoder.next()).?.parseControl(allocator);
    defer control.deinit();
    try t.expectEqualStrings("opaque", control.value.streamNextOffset);
}

test "SSE buffers decoding and parsed control clean up all allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}

test "SSE decodes a real chunked HTTP response with fragmented writes" {
    const Fixture = @import("test_http.zig").Fixture;
    const Client = @import("Client.zig");
    const events = "event: data\ndata: aGVsbG8=\n\nevent: control\ndata: {\"streamNextOffset\":\"00005\",\"streamClosed\":true}\n\n";
    const raw = try t.allocator.print("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nStream-Sse-Data-Encoding: base64\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ events.len, events });
    defer t.allocator.free(raw);
    var fixture = try Fixture.init(&.{.{ .target = "/demo/hello?offset=-1&live=sse", .response = raw }});
    fixture.fragment = true;
    defer fixture.deinit();
    var future = try t.io.concurrent(Fixture.run, .{&fixture});
    defer future.cancel(t.io) catch {};
    const url = try fixture.url(t.allocator);
    defer t.allocator.free(url);
    var client = try Client.init(t.allocator, t.io, .{ .base_url = url });
    defer client.deinit();
    const exchange = try client.open(.{ .read = .{ .stream = .{ .bucket = "demo", .name = "hello" }, .options = .{ .live = .sse } } });
    defer exchange.deinit();
    var decoder = try sse.Decoder.fromHead(t.allocator, exchange.body, exchange.head, .{});
    defer decoder.deinit();
    try t.expectEqualStrings("hello", (try decoder.next()).?.data);
    var control = try (try decoder.next()).?.parseControl(t.allocator);
    defer control.deinit();
    try t.expect(control.value.streamClosed);
    try t.expectEqualStrings("00005", control.value.streamNextOffset);
    try t.expect(try decoder.next() == null);
    try future.await(t.io);
}

test "underlying reader failures stop the decoder permanently" {
    const Broken = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var buffer: [1]u8 = undefined;
    var reader: std.Io.Reader = .{ .vtable = &.{ .stream = Broken.stream }, .buffer = &buffer, .seek = 0, .end = 0 };
    var decoder = sse.Decoder.init(t.allocator, &reader, .{});
    defer decoder.deinit();
    try t.expectError(error.ReadFailed, decoder.next());
    try t.expectError(error.DecoderFailed, decoder.next());
}
