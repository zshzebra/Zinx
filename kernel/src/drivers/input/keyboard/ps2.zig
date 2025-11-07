const arch = @import("../../../arch.zig").internals;
const pic = @import("../../../arch/x86_64/pic.zig");
const irq = @import("../../../arch/x86_64/irq.zig");
const keyboard_impl = @import("../../../arch/x86_64/keyboard.zig");
const kb = @import("../../../keyboard.zig");
const log = std.log.scoped(.ps2_keyboard);
const std = @import("std");
const manager = @import("../../manager.zig");

var keyboard: ?*kb.Keyboard = null;
var initialized_state = false;

fn ps2ReadKey() ?manager.KeyEvent {
    if (keyboard) |kb_device| {
        if (kb_device.readKey()) |key| {
            return manager.KeyEvent{
                .position = @intFromEnum(key.position),
                .released = key.released,
                .modifiers = .{
                    .shift = key.modifiers.shift,
                    .ctrl = key.modifiers.control,
                    .alt = key.modifiers.alt,
                },
            };
        }
    }
    return null;
}

fn ps2IsEmpty() bool {
    if (keyboard) |kb_device| {
        return kb_device.isEmpty();
    }
    return true;
}

const keyboard_interface = manager.KeyboardInterface{
    .readKey = ps2ReadKey,
    .isEmpty = ps2IsEmpty,
};

fn probe() bool {
    return true;
}

fn init() manager.DriverError!void {
    log.info("initializing PS/2 keyboard driver", .{});

    keyboard = kb.getKeyboard(0);
    if (keyboard == null) {
        return manager.DriverError.InitializationFailed;
    }

    keyboard_impl.init();
    pic.clearMask(pic.IRQ_KEYBOARD);

    initialized_state = true;
    log.info("PS/2 keyboard driver initialized", .{});
}

fn unload() void {
    log.info("unloading PS/2 keyboard driver", .{});

    if (initialized_state) {
        pic.setMask(pic.IRQ_KEYBOARD);
        keyboard = null;
        initialized_state = false;
    }

    log.info("PS/2 keyboard driver unloaded", .{});
}

pub const driver = manager.Driver{
    .name = "PS/2 Keyboard",
    .capabilities = .{
        .keyboard = true,
    },
    .probe = probe,
    .init = init,
    .unload = unload,
    .keyboard_interface = &keyboard_interface,
};