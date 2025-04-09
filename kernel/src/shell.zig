const kb = @import("keyboard.zig");
const tty = @import("tty.zig");
const std = @import("std");
const log = std.log.scoped(.shell);
const arch = @import("arch.zig").internals;
const kmain = @import("main.zig");

const COMMAND_BUFFER_SIZE = 128;

fn writePrompt(console: *tty.Console) void {
    console.setEnableCursor(false);
    console.write("=> ");
    console.setEnableCursor(true);
}

const ShellCommand = enum {
    Exit,
};

fn parseCommand(buffer: []u8, console: *tty.Console) ?ShellCommand {
    if (std.mem.startsWith(u8, buffer, "echo ")) {
        console.write(buffer[5..]);
        console.writeChar('\n');
    }
    if (std.mem.startsWith(u8, buffer, "serialw ")) {
        kmain.kernel_serial.?.writeBytes(buffer[8..]);
        kmain.kernel_serial.?.write('\n');
        console.write(buffer[8..]);
        console.writeChar('\n');
    }
    if (std.mem.startsWith(u8, buffer, "panic")) {
        @panic("User triggered panic");
    }

    return null;
}

pub fn shell_main(console: *tty.Console) void {
    var keyboard = kb.getKeyboard(0).?;
    var commandBuffer: [COMMAND_BUFFER_SIZE]u8 = undefined;
    var commandHead: usize = 0;
    writePrompt(console);

    while (true) {
        if (keyboard.readKey()) |key| {
            if (key.released) continue;
            if (kb.KeyPositionToAscii(key.position, key.modifiers.shift)) |char| {
                if (char == '\n') {
                    console.writeChar('\n');

                    // Parse and execute the command
                    if (parseCommand(commandBuffer[0..commandHead], console)) |command| {
                        _ = command;
                    }

                    commandHead = 0;
                    console.cursor_x = 0;

                    writePrompt(console);
                    continue;
                }

                if (commandHead >= COMMAND_BUFFER_SIZE) continue;
                commandBuffer[commandHead] = char;
                commandHead += 1;
                console.writeChar(char);
            } // else not a printable character
        }

        if (keyboard.isEmpty()) arch.halt();
    }
}
