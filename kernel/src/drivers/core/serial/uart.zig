const arch = @import("../../../arch.zig").internals;
const serial_impl = @import("../../../arch/x86_64/serial.zig");
const log = std.log.scoped(.uart);
const std = @import("std");
const manager = @import("../../manager.zig");

var initialized_state = false;

fn uartWrite(byte: u8) void {
    serial_impl.write(byte, serial_impl.Port.COM1);
}

fn uartRead() ?u8 {
    return serial_impl.read(serial_impl.Port.COM1);
}

const serial_interface = manager.SerialInterface{
    .write = uartWrite,
    .read = uartRead,
};

fn probe() bool {
    return serial_impl.isPresent(serial_impl.Port.COM1);
}

fn init() manager.DriverError!void {
    log.info("initializing UART serial driver", .{});

    serial_impl.init(9600, serial_impl.Port.COM1) catch {
        return manager.DriverError.InitializationFailed;
    };

    initialized_state = true;
    log.info("UART serial driver initialized", .{});
}

fn unload() void {
    log.info("unloading UART serial driver", .{});

    if (initialized_state) {
        initialized_state = false;
    }

    log.info("UART serial driver unloaded", .{});
}

pub const driver = manager.Driver{
    .name = "16550 UART Serial",
    .capabilities = .{
        .serial = true,
    },
    .probe = probe,
    .init = init,
    .unload = unload,
    .serial_interface = &serial_interface,
};