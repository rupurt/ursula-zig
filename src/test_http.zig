//! Internal deterministic loopback fixture. Uses the same std.Io interface as
//! production; raw response bytes allow malformed and fragmented HTTP fixtures.
const std = @import("std");
const t = std.testing;

pub const Case = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/demo/hello?offset=-1",
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    response: []const u8,
};

pub const Fixture = struct {
    server: std.Io.net.Server,
    cases: []const Case,
    /// All cases use one connection when true; otherwise each uses a new socket.
    reuse_connection: bool = false,
    /// Flush one byte at a time to exercise incremental HTTP readers.
    fragment: bool = false,
    /// Keep the response unfinished until the fixture task is canceled.
    hold_open: bool = false,

    pub fn init(cases: []const Case) !Fixture {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .server = try address.listen(t.io, .{}), .cases = cases };
    }

    pub fn deinit(self: *Fixture) void {
        self.server.deinit(t.io);
    }

    pub fn url(self: Fixture, allocator: std.mem.Allocator) ![]u8 {
        return allocator.print("http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    pub fn run(self: *Fixture) !void {
        if (self.reuse_connection) {
            try self.serve(self.cases);
        } else {
            for (self.cases) |case| try self.serve(&.{case});
        }
    }

    fn serve(self: *Fixture, cases: []const Case) !void {
        const stream = try self.server.accept(t.io);
        defer stream.close(t.io);
        var read_buffer: [32768]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(t.io, &read_buffer);
        var writer = stream.writer(t.io, &write_buffer);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        for (cases) |case| {
            var request = try http.receiveHead();
            try t.expectEqual(case.method, request.head.method);
            try t.expectEqualStrings(case.target, request.head.target);
            for (case.headers) |expected| {
                var it = request.iterateHeaders();
                var actual: ?[]const u8 = null;
                while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, expected.name)) {
                    actual = h.value;
                    break;
                };
                try t.expect(actual != null);
                try t.expectEqualStrings(expected.value, actual.?);
            }
            const body = try request.readerExpectNone(&.{}).allocRemaining(t.allocator, .limited(1024 * 1024));
            defer t.allocator.free(body);
            try t.expectEqualSlices(u8, case.body, body);
            const end_of_status = std.mem.find(u8, case.response, "\r\n") orelse return error.InvalidFixture;
            const wire = if (self.reuse_connection)
                try t.allocator.dupe(u8, case.response)
            else
                try t.allocator.print("{s}\r\nConnection: close{s}", .{ case.response[0..end_of_status], case.response[end_of_status..] });
            defer t.allocator.free(wire);
            if (self.fragment) {
                for (wire) |byte| {
                    try writer.interface.writeByte(byte);
                    try writer.interface.flush();
                }
            } else {
                try writer.interface.writeAll(wire);
                try writer.interface.flush();
            }
        }
        if (self.hold_open) {
            var event: std.Io.Event = .unset;
            try event.wait(t.io);
        }
    }
};
