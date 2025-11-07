const arch = @import("../../../arch.zig").internals;
const irq = @import("../../../arch/x86_64/irq.zig");
const log = std.log.scoped(.pit_timer);
const std = @import("std");
const manager = @import("../../manager.zig");

var timer_ticks: u32 = 0;
var timer_millis: u32 = 0;
var sleep_ticks: u32 = 0;
var irq_registered = false;

const CHANNEL_0_DATA_PORT: u16 = 0x40;
const CHANNEL_1_DATA_PORT: u16 = 0x41;
const CHANNEL_2_DATA_PORT: u16 = 0x42;
const COMMAND_PORT: u16 = 0x43;

const CommandChannel = enum(u2) {
    CHANNEL_0 = 0,
    CHANNEL_1 = 1,
    CHANNEL_2 = 2,
    READ_BACK_COMMAND = 3,
};

const OperatingMode = enum(u3) {
    MODE_0 = 0,
    MODE_1 = 1,
    MODE_2 = 2,
    MODE_3 = 3,
    MODE_4 = 4,
    MODE_5 = 5,
};

const AccessMode = enum(u2) {
    COUNTER_LATCH_VALUE_COMMAND = 0,
    LOW_BYTE_ONLY = 1,
    HIGH_BYTE_ONLY = 2,
    LOW_BYTE_HIGH_BYTE = 3,
};

const BcdMode = enum(u1) {
    BINARY = 0,
    BCD = 1,
};

const Command = packed struct {
    channel: CommandChannel,
    access_mode: AccessMode,
    operating_mode: OperatingMode,
    binary_bcd_mode: BcdMode,
};

fn pitCommand(command: Command) void {
    const command_value: u8 = @as(u8, @bitCast(command));
    arch.out(COMMAND_PORT, command_value);
    arch.ioWait();
}

fn pitMillis() u32 {
    return timer_millis;
}

fn pitSleep(ms: u32) void {
    log.debug("Start sleep for {d} ms", .{ms});
    sleep_ticks = ms / 54;

    while (sleep_ticks > 0) {
        arch.halt();
    }
}

fn tickHandler(ctx: *arch.CpuState) *arch.CpuState {
    timer_ticks += 1;
    timer_millis = timer_ticks * 54;
    if (sleep_ticks > 0) {
        sleep_ticks -= 1;
    }
    return ctx;
}

const timer_interface = manager.TimerInterface{
    .sleep = pitSleep,
    .millis = pitMillis,
};

fn probe() bool {
    return true;
}

fn init() manager.DriverError!void {
    log.info("initializing PIT timer driver", .{});

    irq.registerIrq(0, tickHandler) catch {
        return manager.DriverError.InitializationFailed;
    };
    irq_registered = true;

    pitCommand(.{
        .channel = .CHANNEL_0,
        .access_mode = .LOW_BYTE_ONLY,
        .operating_mode = .MODE_3,
        .binary_bcd_mode = .BINARY,
    });

    arch.out(CHANNEL_0_DATA_PORT, @as(u8, 2));
    arch.ioWait();

    log.info("PIT timer driver initialized", .{});
}

fn unload() void {
    log.info("unloading PIT timer driver", .{});

    if (irq_registered) {
        arch.out(COMMAND_PORT, @as(u8, 0x30));
        arch.ioWait();
        arch.out(CHANNEL_0_DATA_PORT, @as(u8, 0));
        arch.ioWait();
        arch.out(CHANNEL_0_DATA_PORT, @as(u8, 0));
        arch.ioWait();

        irq_registered = false;
    }

    timer_ticks = 0;
    timer_millis = 0;
    sleep_ticks = 0;

    log.info("PIT timer driver unloaded", .{});
}

pub const driver = manager.Driver{
    .name = "Intel 8253/8254 PIT Timer",
    .capabilities = .{
        .timer = true,
    },
    .probe = probe,
    .init = init,
    .unload = unload,
    .timer_interface = &timer_interface,
};