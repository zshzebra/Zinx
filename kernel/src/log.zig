const std = @import("std");
const fmt = @import("std").fmt;
const Serial = @import("serial.zig").Serial;

const LoggingError = error{};

const Writer = std.io.Writer(void, LoggingError, logCallback);

var serial: Serial = undefined;

fn logCallback(context: void, str: []const u8) LoggingError!usize {
    _ = context;
    serial.writeBytes(str);
    return str.len;
}

pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    fmt.format(Writer{ .context = {} }, "[" ++ @tagName(level) ++ "]" ++ format ++ "\n", args) catch unreachable;
}

pub fn init(ser: Serial) void {
    serial = ser;
}
