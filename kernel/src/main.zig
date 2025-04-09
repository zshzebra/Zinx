const builtin = @import("builtin");
const std = @import("std");
const limine = @import("limine");
const limine_fb = @import("limine_fb.zig");
const Framebuffer = @import("framebuffer.zig").Framebuffer;
const Console = @import("tty.zig").Console;
const arch = @import("arch.zig").internals;
const log_root = @import("log.zig");
const serial = @import("serial.zig");
const shell = @import("shell.zig");
const keyboard = @import("keyboard.zig");

const LogoSize = enum { Small, Large };

const LOGO_SIZE: LogoSize = .Small;

const logo = switch (LOGO_SIZE) {
    .Small => @import("Zinx-small.zig"),
    .Large => @import("Zinx-large.zig"),
};

const kernel_log = std.log.scoped(.kernel);
pub var kernel_tty: ?*Console = null;
pub var kernel_serial: ?serial.Serial = null;

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

pub const std_options = std.Options{
    .logFn = log,
    .log_level = .debug,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_root.log(level, "(" ++ @tagName(scope) ++ "): " ++ format, args);
}

var global_panic_tty: ?*Console = null;
fn panicWrite(_: void, str: []const u8) error{}!usize {
    global_panic_tty.?.write(str);

    return str.len;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);

    global_panic_tty = kernel_tty orelse arch.done();
    const panic_tty = global_panic_tty.?;
    panic_tty.setColors(0x0, 0xf7a41d);
    panic_tty.setEnableCursor(false);
    panic_tty.clear();
    panic_tty.write("Uh Oh! It looks like Zinx has encountered an error.\n");
    panic_tty.write(msg);
    panic_tty.writeChar('\n');

    if (ret_addr) |addr| {
        const Writer = std.io.Writer(void, error{}, panicWrite);
        panic_tty.write("Return Address: 0x");
        std.fmt.formatIntValue(addr, "x", .{}, Writer{ .context = {} }) catch {};
        panic_tty.writeChar('\n');
    } else {
        panic_tty.write("No return address\n");
    }

    if (keyboard.getKeyboard(0)) |kb| {
        panic_tty.write("Press and release <space> to shutdown");

        while (true) {
            if (kb.readKey()) |key| {
                if (key.released and key.position == keyboard.KeyPosition.SPACE) break;
            }
        }

        arch.out(@as(u16, 0x604), @as(u16, 0x2000));
        arch.done();
    }

    panic_tty.write("No keyboard found, manually reset your device\n");
    arch.done();
}

export fn _start() callconv(.C) noreturn {
    if (!base_revision.is_supported()) {
        arch.done();
    }

    kernel_serial = serial.init();
    log_root.init(kernel_serial.?);

    kernel_log.info("base revision supported", .{});
    kernel_log.info("serial initialization succeeded", .{});

    kernel_log.info("initializing framebuffers", .{});
    const framebuffers = limine_fb.initFramebuffers() orelse {
        kernel_log.err("unable to fetch framebuffers", .{});
        arch.done();
    };
    kernel_log.info("got {} framebuffers", .{framebuffers.count});

    if (framebuffers.count == 0) {
        arch.done();
    }

    var framebuffer = framebuffers.buffers[0] orelse arch.done();
    kernel_log.info("using framebuffer #{} with resolution: {}x{}", .{ 0, framebuffer.width, framebuffer.height });

    kernel_log.info("initializing kernel tty", .{});
    var tty = framebuffer.getTTY();
    kernel_tty = &tty;
    kernel_log.info("tty initialized", .{});

    kernel_log.info("initializing arch", .{});
    arch.init();
    kernel_log.info("arch initialized", .{});

    kernel_log.info("starting kernel main", .{});
    main() catch |err| {
        kernel_log.err("Error on kernal main: {}", .{err});
    };

    arch.spinWait();
}

fn main() !void {
    kernel_tty.?.clear();
    for (0..8) |idx| {
        kernel_tty.?.writeImage(&logo.data, logo.width, logo.height, 0xFFFFFF, if (idx == 7) .Newline else .Word) catch {
            @panic("Unexpected error displaying logo");
        };
    }

    kernel_tty.?.write("Welcome to Zinx!\n");
    kernel_tty.?.write("Booting shell\n");

    shell.shell_main(kernel_tty.?);
}
