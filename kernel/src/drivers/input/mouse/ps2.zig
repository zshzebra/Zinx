const std = @import("std");
const x86_64 = @import("../../../arch/x86_64/arch.zig");
const mouse = @import("../../../mouse.zig");

const PS2_DATA_PORT = 0x60;
const PS2_CMD_PORT = 0x64;

var cycle: u8 = 0;
var packet: [3]u8 = .{ 0, 0, 0 };

fn ps2_mouse_wait() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if ((x86_64.inb(PS2_CMD_PORT) & 0b10) == 0) {
            return;
        }
    }
}

fn ps2_mouse_write(data: u8) void {
    ps2_mouse_wait();
    x86_64.outb(PS2_CMD_PORT, 0xD4);
    ps2_mouse_wait();
    x86_64.outb(PS2_DATA_PORT, data);
}

fn ps2_mouse_read() u8 {
    ps2_mouse_wait();
    return x86_64.inb(PS2_DATA_PORT);
}

pub fn irq_handler(ctx: *x86_64.CpuState) *x86_64.CpuState {
    // const byte = x86_64.inb(PS2_DATA_PORT);

    // switch (cycle) {
    //     0 => {
    //         if (byte & 0x08 != 0) {
    //             packet[0] = byte;
    //             cycle = 1;
    //         }
    //     },
    //     1 => {
    //         packet[1] = byte;
    //         cycle = 2;
    //     },
    //     2 => {
    //         packet[2] = byte;
    //         cycle = 0;

    //         const dx = @as(i16, packet[1]);
    //         const dy = @as(i16, packet[2]);

    //         const left_button = (packet[0] & 0x01) != 0;
    //         const right_button = (packet[0] & 0x02) != 0;
    //         const middle_button = (packet[0] & 0x04) != 0;

    //         mouse.Mouse.handle_event(.{
    //             .dx = dx,
    //             .dy = dy,
    //             .left_button = left_button,
    //             .right_button = right_button,
    //             .middle_button = middle_button,
    //         });
    //     },
    //     else => unreachable,
    // }
    return ctx;
}

pub fn init() void {
    ps2_mouse_wait();
    x86_64.outb(PS2_CMD_PORT, 0xA8);

    ps2_mouse_wait();
    x86_64.outb(PS2_CMD_PORT, 0x20);
    const status = ps2_mouse_read();
    ps2_mouse_wait();
    x86_64.outb(PS2_CMD_PORT, 0x60);
    ps2_mouse_wait();
    x86_64.outb(PS2_DATA_PORT, status | 0b10);

    ps2_mouse_write(0xF6);
    _ = ps2_mouse_read();

    ps2_mouse_write(0xF4);
    _ = ps2_mouse_read();
}
