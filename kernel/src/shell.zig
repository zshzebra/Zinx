const kb = @import("keyboard.zig");
const tty = @import("tty.zig");
const std = @import("std");
const log = std.log.scoped(.shell);
const arch = @import("arch.zig").internals;
const kmain = @import("main.zig");
const allocator = @import("allocator.zig");
const vfs = @import("vfs/vfs.zig");
const VFSError = @import("vfs/errors.zig").VFSError;
const driver_mgr = @import("drivers/manager.zig");

const COMMAND_BUFFER_SIZE = 128;
const MAX_ARGS = 16;

fn writePrompt(console: *tty.Console) void {
    console.setEnableCursor(false);
    console.write("=> ");
    console.setEnableCursor(true);
}

fn tokenizeCommand(buffer: []const u8, args: [][]const u8) usize {
    var arg_count: usize = 0;
    var i: usize = 0;

    while (i < buffer.len and arg_count < args.len) {
        while (i < buffer.len and buffer[i] == ' ') : (i += 1) {}
        if (i >= buffer.len) break;

        const start = i;
        while (i < buffer.len and buffer[i] != ' ') : (i += 1) {}

        args[arg_count] = buffer[start..i];
        arg_count += 1;
    }

    return arg_count;
}

fn printVFSError(console: *tty.Console, err: VFSError) void {
    switch (err) {
        VFSError.NotAbsolutePath => console.write("Error: Path must be absolute (start with /)\n"),
        VFSError.PathNotFound => console.write("Error: Path not found\n"),
        VFSError.IsADirectory => console.write("Error: Is a directory\n"),
        VFSError.IsAFile => console.write("Error: Is a file\n"),
        VFSError.NotAFile => console.write("Error: Not a file\n"),
        VFSError.NotADirectory => console.write("Error: Not a directory\n"),
        VFSError.AlreadyExists => console.write("Error: Already exists\n"),
        VFSError.DoesNotExist => console.write("Error: Does not exist\n"),
        VFSError.AlreadyMounted => console.write("Error: Already mounted\n"),
        VFSError.UnknownFilesystem => console.write("Error: Unknown filesystem\n"),
        VFSError.NoSpaceLeft => console.write("Error: No space left\n"),
        VFSError.OutOfMemory => console.write("Error: Out of memory\n"),
        else => {
            console.write("Error: ");
            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var writer = fbs.writer();
            writer.print("{s}\n", .{@errorName(err)}) catch {};
            console.write(fbs.getWritten());
        },
    }
}

const ShellCommand = enum {
    Exit,
};

fn handleLs(args: []const []const u8, console: *tty.Console) void {
    const path = if (args.len > 0) args[0] else "/";

    const dir = vfs.openDir(path, vfs.OpenFlags.READ_ONLY) catch |err| {
        printVFSError(console, err);
        return;
    };
    defer dir.close();

    var iter = dir.iterate() catch {
        console.write("Error: Cannot read directory\n");
        return;
    };
    defer iter.close();

    while (iter.next() catch null) |entry| {
        console.write(entry.name);
        if (entry.is_directory) {
            console.write("/");
        }
        console.write("\n");
    }
}

fn handleMkdir(args: []const []const u8, console: *tty.Console) void {
    if (args.len != 1) {
        console.write("Usage: mkdir <path>\n");
        return;
    }

    const dir = vfs.open(args[0], vfs.OpenFlags.CREATE_DIR) catch |err| {
        printVFSError(console, err);
        return;
    };
    defer dir.close();

    console.write("Directory created\n");
}

fn handleWrite(args: []const []const u8, console: *tty.Console) void {
    if (args.len < 2) {
        console.write("Usage: write <path> <content>\n");
        return;
    }

    const path = args[0];

    const kernel_allocator = allocator.getAllocator();
    var content_parts = std.ArrayList(u8){};
    defer content_parts.deinit(kernel_allocator);

    for (args[1..], 0..) |arg, i| {
        content_parts.appendSlice(kernel_allocator, arg) catch {
            console.write("Error: Out of memory\n");
            return;
        };
        if (i < args[1..].len - 1) {
            content_parts.append(kernel_allocator, ' ') catch {
                console.write("Error: Out of memory\n");
                return;
            };
        }
    }

    const file = vfs.openFile(path, vfs.OpenFlags.CREATE_FILE) catch |err| {
        printVFSError(console, err);
        return;
    };
    defer file.close();

    const bytes_written = file.write(content_parts.items, 0) catch {
        console.write("Error: Write failed\n");
        return;
    };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    writer.print("Wrote {} bytes\n", .{bytes_written}) catch {};
    console.write(fbs.getWritten());
}

fn handleCat(args: []const []const u8, console: *tty.Console) void {
    if (args.len != 1) {
        console.write("Usage: cat <path>\n");
        return;
    }

    const file = vfs.openFile(args[0], vfs.OpenFlags.READ_ONLY) catch |err| {
        printVFSError(console, err);
        return;
    };
    defer file.close();

    const size = file.getSize() catch {
        console.write("Error: Cannot get file size\n");
        return;
    };

    const kernel_allocator = allocator.getAllocator();
    const buffer = kernel_allocator.alloc(u8, size) catch {
        console.write("Error: Out of memory\n");
        return;
    };
    defer kernel_allocator.free(buffer);

    const bytes_read = file.read(buffer, 0) catch {
        console.write("Error: Read failed\n");
        return;
    };

    console.write(buffer[0..bytes_read]);
    console.write("\n");
}

fn handleMount(args: []const []const u8, console: *tty.Console) void {
    if (args.len != 2) {
        console.write("Usage: mount <device> <path>\n");
        console.write("Example: mount ata0 /mnt\n");
        return;
    }

    const device = driver_mgr.getBlockDeviceByName(args[0]) orelse {
        console.write("Error: Block device '");
        console.write(args[0]);
        console.write("' not found\n");
        console.write("Use 'lsblk' to list available devices\n");
        return;
    };

    vfs.mountBlockDevice(args[1], device) catch |err| {
        printVFSError(console, err);
        return;
    };

    console.write("Mounted ");
    console.write(args[0]);
    console.write(" at ");
    console.write(args[1]);
    console.write("\n");
}

fn handleLsblk(args: []const []const u8, console: *tty.Console) void {
    _ = args;

    const devices = driver_mgr.getBlockDevices();

    if (devices.len == 0) {
        console.write("No block devices found\n");
        return;
    }

    console.write("NAME      SIZE\n");

    for (devices) |*bd| {
        const name_slice = std.mem.sliceTo(&bd.name, 0);
        const sectors = bd.interface.get_sector_count(bd.device);
        const size_mb = (sectors * 512) / (1024 * 1024);

        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        writer.print("{s:<10}{d} MB\n", .{ name_slice, size_mb }) catch {};
        console.write(fbs.getWritten());
    }
}

fn parseCommand(buffer: []u8, console: *tty.Console) ?ShellCommand {
    var arg_storage: [MAX_ARGS][]const u8 = undefined;
    const arg_count = tokenizeCommand(buffer, &arg_storage);

    if (arg_count == 0) return null;

    const cmd = arg_storage[0];
    const args = arg_storage[1..arg_count];

    if (std.mem.eql(u8, cmd, "ls")) {
        handleLs(args, console);
    } else if (std.mem.eql(u8, cmd, "mkdir")) {
        handleMkdir(args, console);
    } else if (std.mem.eql(u8, cmd, "write")) {
        handleWrite(args, console);
    } else if (std.mem.eql(u8, cmd, "cat")) {
        handleCat(args, console);
    } else if (std.mem.eql(u8, cmd, "mount")) {
        handleMount(args, console);
    } else if (std.mem.eql(u8, cmd, "lsblk")) {
        handleLsblk(args, console);
    } else if (std.mem.eql(u8, cmd, "echo")) {
        if (args.len > 0) {
            for (args, 0..) |arg, i| {
                console.write(arg);
                if (i < args.len - 1) console.write(" ");
            }
        }
        console.write("\n");
    } else if (std.mem.eql(u8, cmd, "serialw")) {
        if (args.len > 0) {
            for (args, 0..) |arg, i| {
                kmain.kernel_serial.?.print("{s}", .{arg}) catch {};
                if (i < args.len - 1) kmain.kernel_serial.?.print(" ", .{}) catch {};
            }
            kmain.kernel_serial.?.print("\n", .{}) catch {};
            for (args, 0..) |arg, i| {
                console.write(arg);
                if (i < args.len - 1) console.write(" ");
            }
            console.write("\n");
        }
    } else if (std.mem.eql(u8, cmd, "panic")) {
        @panic("User triggered panic");
    } else if (std.mem.eql(u8, cmd, "memtest")) {
        var kernel_allocator = allocator.getAllocator();

        console.write("Testing memory allocation...\n");

        const test_ptr = kernel_allocator.alloc(u8, 1024) catch {
            console.write("Allocation failed!\n");
            return null;
        };
        @memset(test_ptr, 0xAA);

        var print_buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(print_buf[0..]);
        var writer = fbs.writer();
        writer.print("Allocated 1KB at 0x{X}\n", .{@intFromPtr(test_ptr.ptr)}) catch {};
        console.write(fbs.getWritten());

        kernel_allocator.free(test_ptr);
        console.write("Memory freed successfully\n");
    } else if (std.mem.eql(u8, cmd, "exit")) {
        return .Exit;
    } else {
        console.write("Unknown command: ");
        console.write(cmd);
        console.write("\n");
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
                        switch (command) {
                            .Exit => {
                                return;
                            },
                        }
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
