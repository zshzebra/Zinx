const std = @import("std");
const fmt = @import("std").fmt;
const Serial = @import("serial.zig").Serial;

const LoggingError = error{};

// const Writer = std.io.Writer(void, LoggingError, logCallback);
var log_buffer: [1]u8 = .{0};
var log_writer = std.Io.Writer{ .buffer = &log_buffer, .end = 0, .vtable = &.{ .drain = logCallback } };

var serial: Serial = undefined;

fn logCallback(w: *std.Io.Writer, data: []const []const u8, splat: usize) LoggingError!usize {
    const buffered = w.buffered();
    if (buffered.len != 0) {
        serial.writeBytes(buffered);
        return w.consume(buffered.len);
    }
    for (data[0 .. data.len - 1]) |buf| {
        if (buf.len == 0) continue;
        serial.writeBytes(buf);
        return w.consume(buf.len);
    }
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return 0;
    serial.writeBytes(pattern);
    return w.consume(pattern.len);
}

pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    // fmt.format(Writer{ .context = {} }, "[" ++ @tagName(level) ++ "]" ++ format ++ "\n", args) catch unreachable;
    log_writer.print("[{s}] " ++ format ++ "\n", .{@tagName(level)} ++ args) catch unreachable;
}

pub fn init(ser: Serial) void {
    serial = ser;
}
