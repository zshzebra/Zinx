const arch = @import("arch.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const interrupts = @import("interrupts.zig");
const log = @import("std").log.scoped(.kernel);

pub const IrqError = error{
    IrqExists,
    InvalidIrq,
};

const NUMBER_OF_ENTRIES: u16 = 16;

const IrqHandler = fn (*arch.CpuState) *arch.CpuState;

pub const IRQ_OFFSET: u16 = 32;

var irq_handlers: [NUMBER_OF_ENTRIES]?*const IrqHandler = .{null} ** NUMBER_OF_ENTRIES;

export fn irqHandler(ctx: *arch.CpuState) *arch.CpuState {
    if (ctx.int_num < IRQ_OFFSET) {
        @panic("Not an IRQ number");
    }

    const irq_offset = ctx.int_num - IRQ_OFFSET;
    if (isValidIrq(irq_offset)) {
        const irq_num = @as(u8, @truncate(irq_offset));
        if (irq_handlers[irq_num]) |handler| {
            if (!pic.spuriousIrq(irq_num)) {
                const return_context = handler(ctx);
                pic.sendEndOfInterrupt(irq_num);
                return return_context;
            }
            return ctx;
        } else {
            @panic("IRQ Not registered");
        }
    } else {
        @panic("Invalid IRQ index");
    }
}

fn openIrq(index: u8, handler: idt.InterruptHandler) void {
    idt.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryAlreadyExists => {
            @panic("IDT entry exists for IRQ entry");
        },
    };
}

pub fn isValidIrq(irq_num: u64) bool {
    return irq_num < NUMBER_OF_ENTRIES;
}

pub fn registerIrq(irq_num: u8, handler: IrqHandler) IrqError!void {
    if (isValidIrq(irq_num)) {
        if (irq_handlers[irq_num]) |_| {
            return error.IrqExists;
        } else {
            irq_handlers[irq_num] = handler;
            pic.clearMask(irq_num);
        }
    } else {
        return error.InvalidIrq;
    }
}

pub fn init() void {
    log.info("init IRQ", .{});
    defer log.info("initialized IRQ", .{});

    comptime var i = IRQ_OFFSET;
    inline while (i < IRQ_OFFSET + 16) : (i += 1) {
        openIrq(i, interrupts.getInterruptStub(i));
    }
}
