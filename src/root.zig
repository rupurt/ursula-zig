//! A Zig client for Ursula's durable streams HTTP API.
pub const protocol = @import("protocol.zig");
pub const PreparedRequest = @import("request.zig");
pub const Stream = protocol.Stream;
pub const Producer = protocol.Producer;
pub const Operation = protocol.Operation;
pub const CreateOptions = protocol.CreateOptions;
pub const AppendOptions = protocol.AppendOptions;
pub const ReadOptions = protocol.ReadOptions;
pub const Position = protocol.Position;
pub const Boundary = protocol.Boundary;

test {
    @import("std").testing.refAllDecls(@This());
}
