const arch = @import("../../../arch.zig").internals;
const log = std.log.scoped(.pic);
const std = @import("std");
const manager = @import("../../manager.zig");

const MASTER_COMMAND_REG: u16 = 0x20;
const MASTER_STATUS_REG: u16 = 0x20;
const MASTER_DATA_REG: u16 = 0x21;
const SLAVE_COMMAND_REG: u16 = 0xA0;
const SLAVE_STATUS_REG: u16 = 0xA0;
const SLAVE_DATA_REG: u16 = 0xA1;

const ICW1_EXPECT_ICW4: u8 = 0x01;
const ICW1_SINGLE_CASCADE_MODE: u8 = 0x02;
const ICW1_CALL_ADDRESS_INTERVAL_4: u8 = 0x08;
const ICW1_LEVEL_TRIGGER_MODE: u8 = 0x08;
const ICW1_INITIALISATION: u8 = 0x10;

const ICW2_MASTER_REMAP_OFFSET: u8 = 0x20;
const ICW2_SLAVE_REMAP_OFFSET: u8 = 0x28;

const ICW3_SLAVE_IRQ_MAP_TO_MASTER: u8 = 0x02;
const ICW3_MASTER_IRQ_MAP_FROM_SLAVE: u8 = 0x04;

const ICW4_80x86_MODE: u8 = 0x01;
const ICW4_AUTO_END_OF_INTERRUPT: u8 = 0x02;
const ICW4_BUFFER_SELECT: u8 = 0x04;
const ICW4_FULLY_NESTED_MODE: u8 = 0x10;

const OCW1_MASK_IRQ0_8: u8 = 0x01;
const OCW1_MASK_IRQ1_9: u8 = 0x02;
const OCW1_MASK_IRQ2_10: u8 = 0x04;
const OCW1_MASK_IRQ3_11: u8 = 0x08;
const OCW1_MASK_IRQ4_12: u8 = 0x10;
const OCW1_MASK_IRQ5_13: u8 = 0x20;
const OCW1_MASK_IRQ6_14: u8 = 0x40;
const OCW1_MASK_IRQ7_15: u8 = 0x80;

const OCW2_INTERRUPT_LEVEL_1: u8 = 0x01;
const OCW2_INTERRUPT_LEVEL_2: u8 = 0x02;
const OCW2_INTERRUPT_LEVEL_3: u8 = 0x04;
const OCW2_END_OF_INTERRUPT: u8 = 0x20;
const OCW2_SELECTION: u8 = 0x40;
const OCW2_ROTATION: u8 = 0x80;

const OCW3_READ_IRR: u8 = 0x00;
const OCW3_READ_ISR: u8 = 0x01;
const OCW3_ACT_ON_READ: u8 = 0x02;
const OCW3_POLL_COMMAND_ISSUED: u8 = 0x04;
const OCW3_DEFAULT: u8 = 0x08;
const OCW3_SPECIAL_MASK: u8 = 0x20;
const OCW3_ACK_ON_SPECIAL_MASK: u8 = 0x40;

pub const IRQ_PIT: u8 = 0x00;
pub const IRQ_KEYBOARD: u8 = 0x01;
pub const IRQ_CASCADE_FOR_SLAVE: u8 = 0x02;
pub const IRQ_SERIAL_PORT_2: u8 = 0x03;
pub const IRQ_SERIAL_PORT_1: u8 = 0x04;
pub const IRQ_PARALLEL_PORT_2: u8 = 0x05;
pub const IRQ_DISKETTE_DRIVE: u8 = 0x06;
pub const IRQ_PARALLEL_PORT_1: u8 = 0x07;
pub const IRQ_REAL_TIME_CLOCK: u8 = 0x08;
pub const IRQ_CGA_VERTICAL_RETRACE: u8 = 0x09;
pub const IRQ_RESERVED1: u8 = 0x0A;
pub const IRQ_RESERVED2: u8 = 0x0B;
pub const IRQ_PS2_MOUSE: u8 = 0x0C;
pub const IRQ_FLOATING_POINT_UNIT: u8 = 0x0D;
pub const IRQ_PRIMARY_HARD_DISK_CONTROLLER: u8 = 0x0E;
pub const IRQ_SECONDARY_HARD_DISK_CONTROLLER: u8 = 0x0F;

var spurious_irq_count: u64 = 0;
var initialized_state = false;

inline fn sendCommandMaster(cmd: u8) void {
    arch.out(MASTER_COMMAND_REG, cmd);
}

inline fn sendCommandSlave(cmd: u8) void {
    arch.out(SLAVE_COMMAND_REG, cmd);
}

inline fn sendDataMaster(data: u8) void {
    arch.out(MASTER_DATA_REG, data);
}

inline fn sendDataSlave(data: u8) void {
    arch.out(SLAVE_DATA_REG, data);
}

inline fn readDataMaster() u8 {
    return arch.in(u8, MASTER_DATA_REG);
}

inline fn readDataSlave() u8 {
    return arch.in(u8, SLAVE_DATA_REG);
}

inline fn readMasterIrr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.in(u8, MASTER_STATUS_REG);
}

inline fn readSlaveIrr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.in(u8, SLAVE_STATUS_REG);
}

inline fn readMasterIsr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.in(u8, MASTER_STATUS_REG);
}

inline fn readSlaveIsr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.in(u8, SLAVE_STATUS_REG);
}

fn picSendEndOfInterrupt(irq_num: u8) void {
    if (irq_num >= 8) {
        sendCommandSlave(OCW2_END_OF_INTERRUPT);
    }

    sendCommandMaster(OCW2_END_OF_INTERRUPT);
}

fn picSpuriousIrq(irq_num: u8) bool {
    if (irq_num == 7) {
        if ((readMasterIsr() & 0x80) == 0) {
            spurious_irq_count += 1;
            return true;
        }
    } else if (irq_num == 15) {
        if ((readSlaveIsr() & 0x80) == 0) {
            sendCommandMaster(OCW2_END_OF_INTERRUPT);
            spurious_irq_count += 1;
            return true;
        }
    }

    return false;
}

fn picSetMask(irq_num: u8) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @as(u3, @intCast(irq_num % 8));
    const value: u8 = arch.in(u8, port) | (@as(u8, 1) << shift);
    arch.out(port, value);
}

fn picClearMask(irq_num: u8) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @as(u3, @intCast(irq_num % 8));
    const value: u8 = arch.in(u8, port) & ~(@as(u8, 1) << shift);
    arch.out(port, value);
}

const interrupt_interface = manager.InterruptInterface{
    .sendEndOfInterrupt = picSendEndOfInterrupt,
    .clearMask = picClearMask,
    .setMask = picSetMask,
    .spuriousIrq = picSpuriousIrq,
};

fn probe() bool {
    return true;
}

fn init() manager.DriverError!void {
    log.info("initializing PIC interrupt controller", .{});

    sendCommandMaster(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);
    arch.ioWait();
    sendCommandSlave(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);
    arch.ioWait();

    sendDataMaster(ICW2_MASTER_REMAP_OFFSET);
    arch.ioWait();
    sendDataSlave(ICW2_SLAVE_REMAP_OFFSET);
    arch.ioWait();

    sendDataMaster(ICW3_MASTER_IRQ_MAP_FROM_SLAVE);
    arch.ioWait();
    sendDataSlave(ICW3_SLAVE_IRQ_MAP_TO_MASTER);
    arch.ioWait();

    sendDataMaster(ICW4_80x86_MODE);
    arch.ioWait();
    sendDataSlave(ICW4_80x86_MODE);
    arch.ioWait();

    sendDataMaster(0xFF);
    arch.ioWait();
    sendDataSlave(0xFF);
    arch.ioWait();

    picClearMask(IRQ_CASCADE_FOR_SLAVE);

    initialized_state = true;
    log.info("PIC interrupt controller initialized", .{});
}

fn unload() void {
    log.info("unloading PIC interrupt controller", .{});

    if (initialized_state) {
        sendDataMaster(0xFF);
        arch.ioWait();
        sendDataSlave(0xFF);
        arch.ioWait();

        initialized_state = false;
        spurious_irq_count = 0;
    }

    log.info("PIC interrupt controller unloaded", .{});
}

pub const driver = manager.Driver{
    .name = "Intel 8259 PIC",
    .capabilities = .{
        .interrupt_controller = true,
    },
    .probe = probe,
    .init = init,
    .unload = unload,
    .interrupt_interface = &interrupt_interface,
};