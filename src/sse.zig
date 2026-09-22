//! Incremental Ursula SSE decoding over any std.Io.Reader. HTTP transfer framing
//! must already be removed. EOF is a disconnect, not proof of stream closure.
const std = @import("std");
const Head = @import("response.zig").Head;
const Allocator = std.mem.Allocator;

/// Controls memory use independently of the HTTP reader's buffer size.
pub const Limits = struct {
    max_line_bytes: usize = 64 * 1024,
    max_event_bytes: usize = 1024 * 1024,
};

/// Borrowed views valid until the next Decoder.next() or Decoder.deinit().
pub const Event = struct {
    name: []const u8,
    data: []const u8,
    id: ?[]const u8,
    retry_ms: ?u64,

    /// Parses a control event into independently owned JSON storage. Unknown
    /// fields are tolerated for forward compatibility. Caller calls deinit().
    pub fn parseControl(self: Event, allocator: Allocator) !std.json.Parsed(Control) {
        if (!std.mem.eql(u8, self.name, "control")) return error.NotControlEvent;
        var parsed = try std.json.parseFromSlice(Control, allocator, self.data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        if (parsed.value.streamNextOffset.len == 0) return error.InvalidControlEvent;
        return parsed;
    }
};

/// Field names match Ursula's control JSON. Persist continuation tokens only
/// after processing the preceding data events successfully.
pub const Control = struct {
    streamNextOffset: []const u8,
    streamCursor: ?[]const u8 = null,
    upToDate: bool = false,
    streamClosed: bool = false,
    streamFirstRecord: ?u64 = null,
    streamNextRecord: ?u64 = null,

    pub fn isUpToDate(self: Control) bool {
        return self.upToDate or self.streamClosed;
    }
};

/// Stateful bounded parser. It owns reusable buffers but borrows its reader.
/// Errors are terminal; create another decoder after reconnecting.
pub const Decoder = struct {
    allocator: Allocator,
    reader: *std.Io.Reader,
    limits: Limits,
    encoding: enum { text, base64 },
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event_name: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    decoded: std.ArrayList(u8) = .empty,
    has_id: bool = false,
    retry_ms: ?u64 = null,
    first_line: bool = true,
    skip_lf: bool = false,
    ended: bool = false,
    failed: bool = false,

    /// Initializes an offline decoder; encoding applies only to `event: data`.
    pub fn init(allocator: Allocator, reader: *std.Io.Reader, options: struct {
        limits: Limits = .{},
        encoding: @FieldType(Decoder, "encoding") = .text,
    }) Decoder {
        return .{ .allocator = allocator, .reader = reader, .limits = options.limits, .encoding = options.encoding };
    }

    /// Validates a successful event-stream response and selects binary decoding
    /// from Stream-Sse-Data-Encoding. The head is only borrowed during this call.
    pub fn fromHead(allocator: Allocator, reader: *std.Io.Reader, head: Head, limits: Limits) !Decoder {
        if (head.status != .ok) return error.NotEventStream;
        const content_type = (try head.singleHeader("Content-Type")) orelse return error.NotEventStream;
        var parts = std.mem.splitScalar(u8, content_type, ';');
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, parts.first(), " \t"), "text/event-stream")) return error.NotEventStream;
        var result = init(allocator, reader, .{ .limits = limits });
        if (try head.singleHeader("Stream-Sse-Data-Encoding")) |encoding| {
            if (!std.ascii.eqlIgnoreCase(encoding, "base64")) return error.UnsupportedSseEncoding;
            result.encoding = .base64;
        }
        return result;
    }

    pub fn deinit(self: *Decoder) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.event_name.deinit(self.allocator);
        self.last_id.deinit(self.allocator);
        self.decoded.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reads one complete event. Comments and unknown fields are ignored. LF,
    /// CRLF, and CR line endings are accepted. Incomplete events at EOF are
    /// discarded. Invalid UTF-8 is rejected instead of silently replacing bytes.
    pub fn next(self: *Decoder) !?Event {
        if (self.failed) return error.DecoderFailed;
        if (self.ended) return null;
        errdefer self.failed = true;
        self.data.clearRetainingCapacity();
        self.event_name.clearRetainingCapacity();
        var has_data = false;
        var event_bytes: usize = 0;
        while (try self.readLine()) |raw| {
            var line = raw;
            if (self.first_line) {
                self.first_line = false;
                if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
            }
            if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
            if (line.len == 0) {
                if (!has_data) {
                    self.event_name.clearRetainingCapacity();
                    event_bytes = 0;
                    continue;
                }
                // Every data field contributes a newline, including empty data.
                self.data.items.len -= 1;
                const name = if (self.event_name.items.len == 0) "message" else self.event_name.items;
                var payload: []const u8 = self.data.items;
                if (self.encoding == .base64 and std.mem.eql(u8, name, "data")) {
                    var n: usize = 0;
                    for (self.data.items) |c| {
                        if (c == '\n' or c == '\r') continue;
                        self.data.items[n] = c;
                        n += 1;
                    }
                    const encoded = self.data.items[0..n];
                    const decoder = std.base64.standard.Decoder;
                    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
                    try self.decoded.resize(self.allocator, size);
                    decoder.decode(self.decoded.items, encoded) catch return error.InvalidBase64;
                    payload = self.decoded.items;
                }
                return .{ .name = name, .data = payload, .id = if (self.has_id) self.last_id.items else null, .retry_ms = self.retry_ms };
            }
            if (line[0] == ':') continue;
            // Limit all non-comment fields, even unknown/repeated ones. A blank
            // event resets the budget, so heartbeat-only streams stay bounded.
            const cost = std.math.add(usize, line.len, 1) catch return error.EventTooLong;
            event_bytes = std.math.add(usize, event_bytes, cost) catch return error.EventTooLong;
            if (event_bytes > self.limits.max_event_bytes) return error.EventTooLong;
            const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
            const field = line[0..colon];
            var value = if (colon == line.len) "" else line[colon + 1 ..];
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (std.mem.eql(u8, field, "data")) {
                try self.data.appendSlice(self.allocator, value);
                try self.data.append(self.allocator, '\n');
                has_data = true;
            } else if (std.mem.eql(u8, field, "event")) {
                self.event_name.clearRetainingCapacity();
                try self.event_name.appendSlice(self.allocator, value);
            } else if (std.mem.eql(u8, field, "id")) {
                if (std.mem.findScalar(u8, value, 0) != null) continue;
                self.last_id.clearRetainingCapacity();
                try self.last_id.appendSlice(self.allocator, value);
                self.has_id = true;
            } else if (std.mem.eql(u8, field, "retry")) {
                if (value.len == 0) continue;
                var digits = true;
                for (value) |c| if (!std.ascii.isDigit(c)) {
                    digits = false;
                    break;
                };
                if (digits) self.retry_ms = std.fmt.parseInt(u64, value, 10) catch self.retry_ms;
            }
        }
        return null;
    }

    fn readLine(self: *Decoder) !?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            const c = self.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    self.ended = true;
                    return null;
                },
                else => return err,
            };
            if (self.skip_lf) {
                self.skip_lf = false;
                if (c == '\n') continue;
            }
            if (c == '\r' or c == '\n') {
                self.skip_lf = c == '\r';
                return self.line.items;
            }
            if (self.line.items.len >= self.limits.max_line_bytes) return error.LineTooLong;
            try self.line.append(self.allocator, c);
        }
    }
};

test {
    _ = @import("sse_test.zig");
}
