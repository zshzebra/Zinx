const arch = @import("arch.zig");
const pic = @import("pic.zig");
const irq = @import("irq.zig");
const log = @import("std").log.scoped(.kernel);
const kb = @import("../../keyboard.zig");
const KeyAction = kb.KeyAction;
const KeyPosition = kb.KeyPosition;

var on_print_screen = false;
var special_sequence = false;
var pressed_keys: usize = 0;
var expected_releases: usize = 0;

var keyboard: ?*kb.Keyboard = null;

fn readKeyboardBuffer() u8 {
    return arch.in(u8, 0x60);
}

fn parseScanCode(scan_code: u8) ?KeyAction {
    var released = false;
    // The print screen key requires special processing since it uses a unique byte sequence
    if (on_print_screen or scan_code >= 128) {
        released = true;
        if (special_sequence or on_print_screen) {
            // Special sequences are followed by a certain number of release scan codes that should be ignored. Update the expected number
            if (expected_releases >= 1) {
                expected_releases -= 1;
                return null;
            }
        } else {
            if (pressed_keys == 0) {
                // A special sequence is started by a lone key release scan code
                special_sequence = true;
                return null;
            }
        }
    }
    // Cut off the top bit, which denotes that the key was released
    const key_code = @as(u7, @truncate(scan_code));
    var key_pos: ?KeyPosition = null;
    if (special_sequence or on_print_screen) {
        if (!released) {
            // Most special sequences are followed by an extra key release byte
            expected_releases = 1;
        }
        switch (key_code) {
            72 => key_pos = KeyPosition.UP_ARROW,
            75 => key_pos = KeyPosition.LEFT_ARROW,
            77 => key_pos = KeyPosition.RIGHT_ARROW,
            80 => key_pos = KeyPosition.DOWN_ARROW,
            // First byte sent for the pause key
            29 => return null,
            42 => {
                // The print screen key is followed by five extra key release bytes
                key_pos = KeyPosition.PRINT_SCREEN;
                if (!released) {
                    on_print_screen = true;
                    expected_releases = 5;
                }
            },
            // Second and final byte sent for the pause key
            69 => {
                // The pause key is followed by two extra key release bytes
                key_pos = KeyPosition.PAUSE;
                if (!released) {
                    expected_releases = 2;
                }
            },
            82 => key_pos = KeyPosition.INSERT,
            71 => key_pos = KeyPosition.HOME,
            73 => key_pos = KeyPosition.PAGE_UP,
            83 => key_pos = KeyPosition.DELETE,
            79 => key_pos = KeyPosition.END,
            81 => key_pos = KeyPosition.PAGE_DOWN,
            53 => key_pos = KeyPosition.KEYPAD_SLASH,
            28 => key_pos = KeyPosition.KEYPAD_ENTER,
            56 => key_pos = KeyPosition.RIGHT_ALT,
            91 => key_pos = KeyPosition.SPECIAL,
            else => return null,
        }
    }
    key_pos = key_pos orelse switch (key_code) {
        1 => KeyPosition.ESC,
        2...28 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.ONE) + (key_code - 2))),
        29 => KeyPosition.LEFT_CTRL,
        30...40 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.A) + (key_code - 30))),
        41 => KeyPosition.BACKTICK,
        42 => KeyPosition.LEFT_SHIFT,
        43 => KeyPosition.HASH,
        44...54 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.Z) + (key_code - 44))),
        55 => KeyPosition.KEYPAD_ASTERISK,
        56 => KeyPosition.LEFT_ALT,
        57 => KeyPosition.SPACE,
        58 => KeyPosition.CAPS_LOCK,
        59...68 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.F1) + (key_code - 59))),
        69 => KeyPosition.NUM_LOCK,
        70 => KeyPosition.SCROLL_LOCK,
        71...73 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.KEYPAD_7) + (key_code - 71))),
        74 => KeyPosition.KEYPAD_MINUS,
        75...77 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.KEYPAD_4) + (key_code - 75))),
        78 => KeyPosition.KEYPAD_PLUS,
        79...81 => @as(KeyPosition, @enumFromInt(@intFromEnum(KeyPosition.KEYPAD_1) + (key_code - 79))),
        82 => KeyPosition.KEYPAD_0,
        83 => KeyPosition.KEYPAD_DOT,
        86 => KeyPosition.BACKSLASH,
        87 => KeyPosition.F11,
        88 => KeyPosition.F12,
        else => null,
    };
    if (key_pos) |k| {
        // If we're releasing a key decrement the number of keys pressed, else increment it
        if (!released) {
            pressed_keys += 1;
        } else {
            pressed_keys -= 1;
            // Releasing a special key means we are no longer on that special key
            special_sequence = false;
        }
        return KeyAction{ .position = k, .released = released, .modifiers = undefined };
    }
    return null;
}

fn keyEvent(ctx: *arch.CpuState) *arch.CpuState {
    const scan_code = readKeyboardBuffer();
    if (parseScanCode(scan_code)) |action| {
        log.debug("key pressed, scan_code={x} action={}", .{ scan_code, action });
        if (!keyboard.?.writeKey(action)) {
            log.warn("unable to handle key, no room", .{});
        }
    }
    return ctx;
}

pub fn init() void {
    keyboard = kb.getKeyboard(0);

    irq.registerIrq(pic.IRQ_KEYBOARD, keyEvent) catch {
        @panic("Failed to register keyboard interrupt");
    };
}
