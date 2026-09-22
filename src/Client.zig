//! HTTP transport using caller-supplied std.Io. No implicit retries or redirects.
const std = @import("std");
const p = @import("protocol.zig");
const PreparedRequest = @import("request.zig");
const response = @import("response.zig");
const Client = @This();

http: std.http.Client,
base_url: []u8,
authorization: ?[]u8,
max_response_bytes: usize,

/// Client configuration. init copies the base URL and authorization value.
pub const Options = struct {
    base_url: []const u8,
    /// Full value, e.g. "Bearer <token>". Never forwarded through redirects.
    authorization: ?[]const u8 = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
    max_header_bytes: usize = 32 * 1024,
};

/// The allocator must be thread-safe. Do not move the client after its first
/// request. The supplied I/O runtime must outlive the client and its exchanges.
pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Client {
    try PreparedRequest.validateBaseUrl(options.base_url);
    if (options.max_header_bytes < 256) return error.InvalidHeaderLimit;
    if (options.authorization) |value| try PreparedRequest.validateHeaderValue(value);
    const base_url = try allocator.dupe(u8, options.base_url);
    errdefer allocator.free(base_url);
    const authorization = if (options.authorization) |value| try allocator.dupe(u8, value) else null;
    return .{
        .http = .{ .allocator = allocator, .io = io, .read_buffer_size = options.max_header_bytes },
        .base_url = base_url,
        .authorization = authorization,
        .max_response_bytes = options.max_response_bytes,
    };
}

/// All open exchanges must be closed first. Owned finite responses may outlive
/// the client as long as their allocator remains valid.
pub fn deinit(self: *Client) void {
    const allocator = self.http.allocator;
    self.http.deinit();
    allocator.free(self.base_url);
    if (self.authorization) |value| allocator.free(value);
    self.* = undefined;
}

/// Executes a finite operation with a bounded body allocation. All HTTP statuses
/// return Response values; I/O, validation, framing, and size failures are errors.
/// SSE must use open() to avoid collecting a never-ending response.
pub fn send(self: *Client, operation: p.Operation) !response.Response {
    if (operation == .read and operation.read.options.live == .sse) return error.StreamingRequiresOpen;
    const exchange = try self.open(operation);
    defer exchange.deinit();
    const body = exchange.body.allocRemaining(self.http.allocator, .limited(self.max_response_bytes)) catch |err| {
        if (err == error.ReadFailed) return exchange.readError() orelse error.ReadFailed;
        return err;
    };
    exchange.owns_head = false;
    return .{ .head = exchange.head, .body = body };
}

/// Sends the payload before returning a stable, heap-allocated exchange. Input
/// slices need only live for this call. Read exchange.body incrementally and call
/// exchange.deinit() to release the connection, even when abandoning a live tail.
pub fn open(self: *Client, operation: p.Operation) !*Exchange {
    const allocator = self.http.allocator;
    const e = try allocator.create(Exchange);
    errdefer allocator.destroy(e);
    e.allocator = allocator;
    e.prepared = try PreparedRequest.init(allocator, self.base_url, operation);
    errdefer e.prepared.deinit();
    e.request = try self.http.request(e.prepared.method, try std.Uri.parse(e.prepared.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (self.authorization) |value| .{ .override = value } else .omit,
            .accept_encoding = .{ .override = "identity" },
            .content_type = .omit,
            .user_agent = .{ .override = "ursula-zig/0.0.0" },
        },
        .extra_headers = e.prepared.headers,
    });
    errdefer {
        // Never drain an unbounded or failed response during error cleanup.
        e.request.reader.state = .closing;
        e.request.deinit();
    }
    if (e.prepared.method.requestHasBody()) {
        e.request.transfer_encoding = .{ .content_length = e.prepared.body.len };
        var writer = try e.request.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(e.prepared.body);
        try writer.end();
        try e.request.connection.?.flush();
    } else {
        try e.request.sendBodiless();
    }
    e.prepared.body = "";
    var received = try e.request.receiveHead(&.{});
    e.head = try response.Head.init(allocator, received.head.bytes);
    errdefer e.head.deinit();
    e.owns_head = true;
    if (received.head.content_encoding != .identity) return error.UnsupportedContentEncoding;
    // HTTP forbids bodies here, even if Content-Length advertises representation
    // size. Do not wait for bytes that will never arrive on a persistent connection.
    if (e.prepared.method == .HEAD or e.head.status == .no_content or e.head.status == .not_modified or e.head.status.class() == .informational) {
        e.request.reader.state = .ready;
        e.body = .ending;
    } else {
        e.body = received.reader(&e.transfer_buffer);
    }
    return e;
}

/// An active request, response head, and decoded HTTP transfer-body reader.
/// Address stability is required; only obtain these through Client.open().
pub const Exchange = struct {
    allocator: std.mem.Allocator,
    prepared: PreparedRequest,
    request: std.http.Client.Request,
    head: response.Head,
    body: *std.Io.Reader,
    transfer_buffer: [8192]u8,
    owns_head: bool,

    /// Closes unread responses without draining them. Fully consumed responses
    /// may return their connection to the HTTP pool. Destroys this object.
    pub fn deinit(self: *Exchange) void {
        self.request.deinit();
        if (self.owns_head) self.head.deinit();
        self.prepared.deinit();
        self.allocator.destroy(self);
    }

    /// Detailed framing/network error after body reports error.ReadFailed.
    /// Includes cancellation reported by the caller's I/O implementation.
    pub fn readError(self: *const Exchange) ?anyerror {
        if (self.request.reader.body_err) |err| return err;
        if (self.request.connection) |connection| {
            if (connection.getReadError()) |err| return err;
        }
        return null;
    }
};

test {
    _ = @import("client_test.zig");
}
