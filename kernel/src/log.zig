const std = @import("std");
const fmt = @import("std").fmt;
const Serial = @import("serial.zig").Serial;

const LoggingError = error{};

// const Writer = std.io.Writer(void, LoggingError, logCallback);
// var log_buffer: []u8 = {};
// var log_writer = std.Io.Writer{ .buffer = log_buffer, .end = 0, .vtable = .{ .drain = logCallback } };

var serial: Serial = undefined;

// fn logCallback(w: *std.Io.Writer) LoggingError!usize {
//     serial.writeBytes(w.buffer[0..w.end]);
//     return w.end;
// }

pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    // fmt.format(Writer{ .context = {} }, "[" ++ @tagName(level) ++ "]" ++ format ++ "\n", args) catch unreachable;
    // log_writer.print("[{}]");
    _ = level;
    _ = format;
    _ = args;
}

pub fn init(ser: Serial) void {
    serial = ser;
}
