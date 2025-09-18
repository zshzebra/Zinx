const arch = @import("arch.zig");
const irq = @import("irq.zig");
const log = @import("std").log.scoped(.kernel);

var timer_ticks: u32 = 0;
var timer_millis: u32 = 0;
var sleep_ticks: u32 = 0;

/// Channel 0 of the PIT, generates an interrupt (ISR0)
const CHANNEL_0_DATA_PORT = 0x40;
/// Channel 1 of the PIT, used for DRAM or RAM, no longer usuable
const CHANNEL_1_DATA_PORT = 0x41;
/// Channel 2 of the PIT, connected to the PC speaker
const CHANNEL_2_DATA_PORT = 0x42;
const COMMAND_PORT = 0x43;

const CommandChannel = enum(u2) {
    CHANNEL_0 = 0,
    CHANNEL_1 = 1,
    CHANNEL_2 = 2,
    READ_BACK_COMMAND = 3,
};

const OperatingMode = enum(u3) {
    /// One shot countdown
    MODE_0 = 0,
    /// Re-triggerable one shot countdown
    MODE_1 = 1,
    /// Rate generator
    MODE_2 = 2,
    /// Square wave generator
    MODE_3 = 3,
    /// Software triggered strobe
    MODE_4 = 4,
    /// Hardware triggered strobe
    MODE_5 = 5,
    // Remaining values are identical to previous values
};

/// Specifies which access mode a channel should be, as the port is only 8 bits wide, but accepts values of 16 bits wide
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

pub fn pitCommand(command: Command) void {
    const command_value: u8 = @as(u8, @bitCast(command));
    arch.out(COMMAND_PORT, command_value);
    arch.ioWait();
}

pub fn millis() u32 {
    return timer_millis;
}

pub fn sleep(ms: u32) void {
    log.debug("Start sleep for {d} ms", .{ms});
    sleep_ticks = ms / 54;

    while (sleep_ticks > 0) {
        arch.halt();
    }
}

fn tickHandler(ctx: *arch.CpuState) *arch.CpuState {
    timer_ticks += 1;
    // 54.23 ms per tick
    timer_millis = timer_ticks * 54;
    if (sleep_ticks > 0) {
        sleep_ticks -= 1;
    }
    return ctx;
}

pub fn init() void {
    irq.registerIrq(0, tickHandler) catch {
        @panic("Failed to register PIT interrupt");
    };

    pitCommand(.{
        .channel = .CHANNEL_0,
        .access_mode = .LOW_BYTE_ONLY,
        .operating_mode = .MODE_3,
        .binary_bcd_mode = .BINARY,
    });

    arch.out(CHANNEL_0_DATA_PORT, @as(u8, 2));
    arch.ioWait();
}
