//! Read an existing stream and write its raw bytes to stdout.
const std = @import("std");
const ursula = @import("ursula");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: ursula-read BASE_URL BUCKET STREAM\n", .{});
        return error.InvalidArguments;
    }
    var client = try ursula.Client.init(init.gpa, init.io, .{ .base_url = args[1] });
    defer client.deinit();
    var response = try client.send(.{ .read = .{ .stream = .{ .bucket = args[2], .name = args[3] } } });
    defer response.deinit();
    try response.head.requireSuccess();
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try stdout.interface.writeAll(response.body);
    try stdout.interface.flush();
}
