const std = @import("std");
const fmt = @import("std").fmt;
const arch = @import("arch.zig").internals;
const serial_hw = @import("arch/x86_64/serial.zig");

const LoggingError = error{};

// const Writer = std.io.Writer(void, LoggingError, logCallback);
var log_buffer: [1]u8 = .{0};
// TODO: Figure out a better way
pub var log_writer = std.Io.Writer{ .buffer = &log_buffer, .end = 0, .vtable = &.{ .drain = logCallback } };

var serial_port: serial_hw.Port = serial_hw.Port.COM1;

fn logCallback(w: *std.Io.Writer, data: []const []const u8, splat: usize) LoggingError!usize {
    const buffered = w.buffered();
    if (buffered.len != 0) {
        for (buffered) |byte| {
            serial_hw.write(byte, serial_port);
        }
        return w.consume(buffered.len);
    }
    for (data[0 .. data.len - 1]) |buf| {
        if (buf.len == 0) continue;
        for (buf) |byte| {
            serial_hw.write(byte, serial_port);
        }
        return w.consume(buf.len);
    }
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return 0;
    for (pattern) |byte| {
        serial_hw.write(byte, serial_port);
    }
    return w.consume(pattern.len);
}

pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    const millis = arch.millis();
    log_writer.print("[{s}] [{d}:{d:0>2}.{d:0>3}] " ++ format ++ "\n", .{ @tagName(level), (millis / (1000 * 60)) % 60, (millis / 1000) % 60, millis % 999 } ++ args) catch unreachable;
}

pub fn init() void {
    serial_hw.init(serial_hw.DEFAULT_BAUDRATE, serial_port) catch {
        // Can't log here since we're initializing the logger!
        // If serial init fails, we just won't have logging
    };
}
