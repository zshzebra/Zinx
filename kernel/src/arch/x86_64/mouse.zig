const ps2 = @import("../../drivers/input/mouse/ps2.zig");
const irq = @import("irq.zig");

pub fn init() void {
    ps2.init();
    irq.registerIrq(12, ps2.irq_handler) catch |err| switch (err) {
        error.IrqExists => @panic("IRQ 12 already exists"),
        error.InvalidIrq => @panic("Invalid IRQ 12"),
    };
}
