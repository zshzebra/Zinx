const builtin = @import("builtin");
const std = @import("std");
const limine = @import("limine");
const limine_fb = @import("limine_fb.zig");
const Console = @import("tty.zig").Console;
const arch = @import("arch.zig").internals;
const log_root = @import("log.zig");

const LogoSize = enum { Small, Large };

const LOGO_SIZE: LogoSize = .Large;

const logo = switch (LOGO_SIZE) {
    .Small => @import("Zinx-small.zig"),
    .Large => @import("Zinx-large.zig"),
};

const kernel_log = std.log.scoped(.kernel);
pub var kernel_tty: ?*Console = null;

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

fn initialized_done(console: *Console) noreturn {
    for (0..console.width) |_| {
        console.writeChar('=');
    }
    console.write("\nFinished Execution\n");
    for (0..console.width) |_| {
        console.writeChar('=');
    }
    arch.done();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_root.log(level, "(" ++ @tagName(scope) ++ "): " ++ format, args);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    const panic_tty = kernel_tty orelse arch.done();
    inline for (0..3) |_| {
        panic_tty.writeChar('\n');
    }
    panic_tty.write("=== KERNEL PANIC ===\n");
    panic_tty.write(msg);

    arch.done();
}

export fn _start() callconv(.C) noreturn {
    if (!base_revision.is_supported()) {
        arch.done();
    }

    const framebuffers = limine_fb.initFramebuffers() orelse arch.done();

    if (framebuffers.count == 0) {
        arch.done();
    }

    var framebuffer = framebuffers.buffers[0] orelse arch.done();

    var tty = framebuffer.getTTY();
    kernel_tty = &tty;

    arch.init();

    log_root.init(kernel_tty orelse arch.done());

    kernel_log.debug("Hello World!", .{});

    tty.clear();

    for (0..8) |idx| {
        kernel_tty.?.writeImage(&logo.data, logo.width, logo.height, 0xFFFFFF, if (idx == 7) .Newline else .Word) catch {
            @panic("Unexpected error displaying logo");
        };
    }

    tty.write("Welcome to Zinx!\n");
    for (0..1024) |i| {
        const code: u8 = @intCast('0' + (i % ('9' + 1 - '0')));
        const str: []const u8 = &[_]u8{code};
        tty.write(str);
    }
    tty.writeChar('\n');
    initialized_done(&tty);
}
