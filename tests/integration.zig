//! Black-box checks against the server owned by run_integration.py.
const std = @import("std");
const ursula = @import("ursula");
const t = std.testing;

fn client() !ursula.Client {
    // Deliberately fail when invoked without the launcher; never use a default
    // deployment or silently skip missing integration infrastructure.
    const url = try t.environ.getAlloc(t.allocator, "URSULA_TEST_URL");
    defer t.allocator.free(url);
    return ursula.Client.init(t.allocator, t.io, .{ .base_url = url });
}

fn send(c: *ursula.Client, op: ursula.Operation, expected: std.http.Status) !ursula.Response {
    var response = try c.send(op);
    errdefer response.deinit();
    if (response.head.status != expected) {
        std.debug.print("\n{s}: expected {s}, received {s}\n{s}\n", .{
            @tagName(op), @tagName(expected), @tagName(response.head.status), response.body,
        });
        return error.UnexpectedStatus;
    }
    return response;
}

fn discard(c: *ursula.Client, op: ursula.Operation, expected: std.http.Status) !void {
    var response = try send(c, op, expected);
    defer response.deinit();
}

fn create(c: *ursula.Client, stream: ursula.Stream, options: ursula.CreateOptions) !void {
    try discard(c, .{ .create_bucket = stream.bucket }, .created);
    try discard(c, .{ .create_stream = .{ .stream = stream, .options = options } }, .created);
}

test "integration: binary lifecycle, encoded IDs, opaque offsets, close and delete" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "lifecycle", .name = "a%2Fb %?雪" };
    try create(&c, stream, .{ .body = "\x00abc\xff" });
    var before = try send(&c, .{ .head = .{ .stream = stream } }, .ok);
    defer before.deinit();
    try t.expectEqual(@as(usize, 0), before.body.len);
    const offset = (try before.head.metadata()).next_offset orelse return error.MissingOffset;
    try discard(&c, .{ .append = .{ .stream = stream, .body = "more" } }, .no_content);
    var resumed = try send(&c, .{ .read = .{ .stream = stream, .options = .{ .position = .{ .offset = offset } } } }, .ok);
    defer resumed.deinit();
    try t.expectEqualStrings("more", resumed.body);
    try t.expectEqual(true, (try resumed.head.metadata()).up_to_date.?);
    var whole = try send(&c, .{ .read = .{ .stream = stream } }, .ok);
    defer whole.deinit();
    try t.expectEqualStrings("\x00abc\xffmore", whole.body);
    try discard(&c, .{ .append = .{ .stream = stream, .body = "", .options = .{ .closed = true } } }, .no_content);
    var closed = try send(&c, .{ .head = .{ .stream = stream } }, .ok);
    defer closed.deinit();
    try t.expectEqual(true, (try closed.head.metadata()).closed.?);
    var rejected = try send(&c, .{ .append = .{ .stream = stream, .body = "late" } }, .conflict);
    defer rejected.deinit();
    try t.expectError(error.Conflict, rejected.head.requireSuccess());
    try discard(&c, .{ .delete_stream = stream }, .no_content);
    try discard(&c, .{ .read = .{ .stream = stream } }, .not_found);
}

test "integration: producer retries, sequence gaps and epoch fencing" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "producer", .name = "events" };
    try create(&c, stream, .{});
    const first: ursula.Operation = .{ .append = .{
        .stream = stream,
        .body = "once",
        .options = .{ .producer = .{ .id = "zig", .epoch = 0, .seq = 0 } },
    } };
    var committed = try send(&c, first, .ok);
    defer committed.deinit();
    var retried = try send(&c, first, .no_content);
    defer retried.deinit();
    try t.expectEqualStrings((try committed.head.metadata()).next_offset.?, (try retried.head.metadata()).next_offset.?);
    var gap = try send(&c, .{ .append = .{
        .stream = stream,
        .body = "gap",
        .options = .{ .producer = .{ .id = "zig", .epoch = 0, .seq = 2 } },
    } }, .conflict);
    defer gap.deinit();
    const conflict = try gap.head.metadata();
    try t.expectEqual(@as(u64, 1), conflict.producer_expected_seq.?);
    try t.expectEqual(@as(u64, 2), conflict.producer_received_seq.?);
    try discard(&c, .{ .append = .{
        .stream = stream,
        .body = "twice",
        .options = .{ .producer = .{ .id = "zig", .epoch = 1, .seq = 0 } },
    } }, .ok);
    try discard(&c, first, .forbidden);
    var read = try send(&c, .{ .read = .{ .stream = stream } }, .ok);
    defer read.deinit();
    try t.expectEqualStrings("oncetwice", read.body);
}

test "integration: JSON record coordinates, conditional append and attributes" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "records", .name = "events" };
    try create(&c, stream, .{ .content_type = "application/json", .attributes = "{\"title\":\"original\"}" });
    var initial_attrs = try send(&c, .{ .get_attributes = stream }, .ok);
    defer initial_attrs.deinit();
    const Attributes = struct { title: []const u8 };
    var initial = try std.json.parseFromSlice(Attributes, t.allocator, initial_attrs.body, .{});
    defer initial.deinit();
    try t.expectEqualStrings("original", initial.value.title);
    try discard(&c, .{ .set_attributes = .{ .stream = stream, .json = "{\"title\":\"updated\"}" } }, .no_content);
    var attrs = try send(&c, .{ .get_attributes = stream }, .ok);
    defer attrs.deinit();
    var updated = try std.json.parseFromSlice(Attributes, t.allocator, attrs.body, .{});
    defer updated.deinit();
    try t.expectEqualStrings("updated", updated.value.title);

    var append = try send(&c, .{ .append = .{
        .stream = stream,
        .body = "[{\"id\":1},{\"id\":2}]",
        .options = .{ .content_type = "application/json", .record_match = 0 },
    } }, .no_content);
    defer append.deinit();
    try t.expectEqual(@as(u64, 2), (try append.head.metadata()).record_next.?);
    try discard(&c, .{ .append = .{
        .stream = stream,
        .body = "{\"id\":3}",
        .options = .{ .content_type = "application/json", .record_match = 0 },
    } }, .precondition_failed);
    var record = try send(&c, .{ .read = .{
        .stream = stream,
        .options = .{ .position = .{ .record = 1 }, .max_records = 1 },
    } }, .ok);
    defer record.deinit();
    try t.expectEqualStrings("{\"id\":2}\n", record.body);
    const meta = try record.head.metadata();
    try t.expectEqualStrings("application/x-ndjson", meta.content_type.?);
    try t.expectEqual(@as(u64, 1), meta.record_start.?);
    try t.expectEqual(@as(u64, 2), meta.record_next.?);
    var envelope = try send(&c, .{ .read = .{
        .stream = stream,
        .options = .{ .position = .{ .tail_records = 1 }, .envelope = true },
    } }, .ok);
    defer envelope.deinit();
    try t.expectEqualStrings("{\"record\":1,\"value\":{\"id\":2}}\n", envelope.body);
}

test "integration: append-batch acknowledgements and binary frame ordering" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "batches", .name = "frames" };
    try create(&c, stream, .{});
    var batch = try send(&c, .{ .append_batch = .{ .stream = stream, .frames = &.{ "a\x00b", "\xffend" } } }, .ok);
    defer batch.deinit();
    var acks = try std.json.parseFromSlice([]struct { status: u16 }, t.allocator, batch.body, .{ .ignore_unknown_fields = true });
    defer acks.deinit();
    try t.expectEqual(@as(usize, 2), acks.value.len);
    for (acks.value) |ack| try t.expectEqual(@as(u16, 204), ack.status);
    var read = try send(&c, .{ .read = .{ .stream = stream } }, .ok);
    defer read.deinit();
    try t.expectEqualStrings("a\x00b\xffend", read.body);
}

test "integration: snapshots, explicit redirects, retention and raw bootstrap" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "snapshots", .name = "state" };
    try create(&c, stream, .{ .body = "abc" });
    var head = try send(&c, .{ .head = .{ .stream = stream } }, .ok);
    defer head.deinit();
    const boundary = (try head.head.metadata()).next_offset.?;
    try discard(&c, .{ .append = .{ .stream = stream, .body = "delta" } }, .no_content);
    const snapshot = "{\"state\":\"abc\"}";
    try discard(&c, .{ .publish_snapshot = .{
        .stream = stream,
        .at = .{ .offset = boundary },
        .body = snapshot,
        .content_type = "application/json",
    } }, .no_content);
    var redirect = try send(&c, .{ .read_snapshot = .{ .stream = stream } }, .temporary_redirect);
    defer redirect.deinit();
    const url = try t.environ.getAlloc(t.allocator, "URSULA_TEST_URL");
    defer t.allocator.free(url);
    const location = try t.allocator.print("{s}/snapshots/state/snapshot/{s}", .{ url, boundary });
    defer t.allocator.free(location);
    try t.expectEqualStrings(location, (try redirect.head.metadata()).location.?);
    var retrieved = try send(&c, .{ .read_snapshot = .{ .stream = stream, .offset = boundary } }, .ok);
    defer retrieved.deinit();
    try t.expectEqualStrings(snapshot, retrieved.body);
    // Publishing a snapshot must not advance retention on its own.
    var before = try send(&c, .{ .read = .{ .stream = stream } }, .ok);
    defer before.deinit();
    try t.expectEqualStrings("abcdelta", before.body);
    try discard(&c, .{ .advance_retention = .{ .stream = stream, .at = .{ .offset = boundary } } }, .no_content);
    var gone = try send(&c, .{ .read = .{ .stream = stream } }, .gone);
    defer gone.deinit();
    try t.expectError(error.Gone, gone.head.requireSuccess());
    try t.expectEqualStrings(boundary, (try gone.head.metadata()).next_offset.?);
    var bootstrap = try send(&c, .{ .bootstrap = stream }, .ok);
    defer bootstrap.deinit();
    try t.expect(std.mem.startsWith(u8, (try bootstrap.head.metadata()).content_type.?, "multipart/mixed; boundary="));
    try t.expect(std.mem.find(u8, bootstrap.body, snapshot) != null);
    try t.expect(std.mem.find(u8, bootstrap.body, "delta") != null);
    // The snapshot anchoring retained history cannot be removed.
    try discard(&c, .{ .delete_snapshot = .{ .stream = stream, .offset = boundary } }, .conflict);
}

fn liveRoundTrip(bucket: []const u8, content_type: []const u8, payload: []const u8) !void {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = bucket, .name = "live" };
    try create(&c, stream, .{ .content_type = content_type });
    const exchange = try c.open(.{ .read = .{ .stream = stream, .options = .{ .live = .sse } } });
    defer exchange.deinit();
    var decoder = try ursula.sse.Decoder.fromHead(t.allocator, exchange.body, exchange.head, .{});
    defer decoder.deinit();
    // Synchronize on the server's initial caught-up control, with no sleeps.
    const first = (try decoder.next()) orelse return error.MissingInitialControl;
    var initial = try first.parseControl(t.allocator);
    defer initial.deinit();
    try t.expect(initial.value.isUpToDate());
    try t.expect(!initial.value.streamClosed);
    var append = try send(&c, .{ .append = .{
        .stream = stream,
        .body = payload,
        .options = .{ .content_type = content_type, .closed = true },
    } }, .no_content);
    defer append.deinit();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(t.allocator);
    var closed = false;
    var events: usize = 0;
    while (try decoder.next()) |event| {
        events += 1;
        try t.expect(events <= 16);
        if (std.mem.eql(u8, event.name, "data")) {
            try received.appendSlice(t.allocator, event.data);
        } else if (std.mem.eql(u8, event.name, "control")) {
            var control = try event.parseControl(t.allocator);
            defer control.deinit();
            if (control.value.streamClosed) {
                // Closure is protocol metadata, not transport EOF, and follows data.
                try t.expectEqualStrings(payload, received.items);
                try t.expectEqualStrings((try append.head.metadata()).next_offset.?, control.value.streamNextOffset);
                closed = true;
            }
        } else return error.UnexpectedSseEvent;
    }
    try t.expect(closed);
    try t.expectEqualStrings(payload, received.items);
}

test "integration: live text SSE delivers appended data before closure" {
    try liveRoundTrip("text_sse", "text/plain", "hello from Zig");
}

test "integration: live binary SSE decodes base64 and closed control" {
    try liveRoundTrip("binary_sse", "application/octet-stream", "\x00\xff\r\n\x80binary");
}

fn poll(stream: ursula.Stream) !void {
    var c = try client();
    defer c.deinit();
    var response = try send(&c, .{ .read = .{ .stream = stream, .options = .{ .live = .long_poll } } }, .ok);
    defer response.deinit();
    try t.expectEqualStrings("wake", response.body);
}

test "integration: long-poll receives a concurrent append" {
    var c = try client();
    defer c.deinit();
    const stream: ursula.Stream = .{ .bucket = "long_poll", .name = "events" };
    try create(&c, stream, .{});
    var read = try t.io.concurrent(poll, .{stream});
    defer read.cancel(t.io) catch {};
    try discard(&c, .{ .append = .{ .stream = stream, .body = "wake", .options = .{ .closed = true } } }, .no_content);
    try read.await(t.io);
}
