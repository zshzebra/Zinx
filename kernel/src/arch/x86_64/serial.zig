const arch = @import("arch.zig");

pub const SerialError = error{
    InvalidChararacterLength,
    InvalidBaudRate,
};

/// Common serial port locations
/// See https://wiki.osdev.org/Serial_Ports for full list
pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,
};

/// Offset of the Line Control Register
const LCR: u16 = 3;

/// The maximium baudrate
const MAX_BAUDRATE: u32 = 115200;

/// Serial character length (u8)
const CHAR_LEN: u8 = 8;

/// Use a single stop-bit per transmission
const SINGLE_STOP_BIT: bool = true;

/// No parity bit
const PARITY_BIT: bool = false;

pub const DEFAULT_BAUDRATE = 38400;

/// Computes the LCR register value
/// TODO: Learn about msb :)
pub fn computeLcrValue(char_len: u8, stop_bit: bool, parity_bit: bool, msb: u1) SerialError!u8 {
    if (char_len != 0 and (char_len < 5 or char_len > 8))
        return error.InvalidChararacterLength;

    return char_len & 0x3 |
        @as(u8, @intCast(@intFromBool(stop_bit))) << 2 |
        @as(u8, @intCast(@intFromBool(parity_bit))) << 3 |
        @as(u8, @intCast(msb)) << 7;
}

fn baudrateDivisor(baud: u32) SerialError!u16 {
    if (baud > MAX_BAUDRATE or baud == 0)
        return error.InvalidBaudRate;

    return @as(u16, @truncate(MAX_BAUDRATE / baud));
}

// Checks if the transmission buffer is empty, which means data can be sent
fn transmissionIsEmpty(port: Port) bool {
    return arch.in(u8, @intFromEnum(port) + 5) & 0x20 > 0;
}

pub fn write(char: u8, port: Port) void {
    while (!transmissionIsEmpty(port)) {
        arch.halt();
    }
    arch.out(@intFromEnum(port), char);
}

pub fn init(baud: u32, port: Port) SerialError!void {
    const divisor: u16 = try baudrateDivisor(baud);
    const port_int = @intFromEnum(port);

    arch.out(port_int + LCR, computeLcrValue(0, false, false, 1) catch {
        @panic("Failed to init serial");
    });

    arch.out(port_int, @as(u8, @truncate(divisor)));
    arch.out(port_int + 1, @as(u8, @truncate(divisor >> 8)));
    arch.out(port_int + LCR, computeLcrValue(CHAR_LEN, SINGLE_STOP_BIT, PARITY_BIT, 0) catch {
        @panic("Failed to init serial");
    });
    arch.out(port_int + 1, @as(u8, 0));
}
