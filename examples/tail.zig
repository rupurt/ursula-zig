//! Tail an existing stream. This example prints payloads and exits on closure;
//! reconnect and credential-refresh policy belongs to the application.
const std = @import("std");
const ursula = @import("ursula");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: ursula-tail BASE_URL BUCKET STREAM\n", .{});
        return error.InvalidArguments;
    }
    var client = try ursula.Client.init(init.gpa, init.io, .{ .base_url = args[1] });
    defer client.deinit();
    const exchange = try client.open(.{ .read = .{
        .stream = .{ .bucket = args[2], .name = args[3] },
        .options = .{ .live = .sse },
    } });
    defer exchange.deinit();
    try exchange.head.requireSuccess();
    // Some servers can signal an already-closed stream without an SSE body.
    if (exchange.head.status == .no_content) {
        if ((try exchange.head.metadata()).closed orelse false) return;
        return error.StreamDisconnected;
    }
    var decoder = try ursula.sse.Decoder.fromHead(init.gpa, exchange.body, exchange.head, .{});
    defer decoder.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    while (try decoder.next()) |event| {
        if (std.mem.eql(u8, event.name, "data")) {
            try stdout.interface.writeAll(event.data);
            try stdout.interface.flush();
        } else if (std.mem.eql(u8, event.name, "control")) {
            var control = try event.parseControl(init.gpa);
            defer control.deinit();
            // A resumable application persists tokens after applying earlier data.
            if (control.value.streamClosed) return;
        } else if (std.mem.eql(u8, event.name, "credential-expired")) {
            return error.CredentialExpired;
        }
    }
    // EOF without a closed control event is a disconnect, not durable EOF.
    return error.StreamDisconnected;
}
