const std = @import("std");
const log = std.log.scoped(.framebuffer);
const manager = @import("../../manager.zig");
const limine_fb = @import("../../../limine_fb.zig");
const framebuffer_impl = @import("../../../framebuffer.zig");

var active_framebuffer: ?*framebuffer_impl.Framebuffer = null;
var initialized_state = false;

fn framebufferClear(color: u32) void {
    if (active_framebuffer) |fb| {
        fb.clear(color);
    }
}

fn framebufferSetPixel(x: usize, y: usize, color: u32) void {
    if (active_framebuffer) |fb| {
        fb.setPixel(x, y, color);
    }
}

fn framebufferGetPixel(x: usize, y: usize) u32 {
    if (active_framebuffer) |fb| {
        return fb.getPixel(x, y);
    }
    return 0;
}

const display_interface = manager.DisplayInterface{
    .clear = framebufferClear,
    .setPixel = framebufferSetPixel,
    .getPixel = framebufferGetPixel,
};

fn probe() bool {
    const framebuffers = limine_fb.initFramebuffers() orelse return false;
    return framebuffers.count > 0;
}

fn init() manager.DriverError!void {
    log.info("initializing framebuffer display driver", .{});

    const framebuffers = limine_fb.initFramebuffers() orelse {
        return manager.DriverError.InitializationFailed;
    };

    if (framebuffers.count == 0) {
        return manager.DriverError.InitializationFailed;
    }

    active_framebuffer = @constCast(&framebuffers.buffers[0].?);
    initialized_state = true;

    log.info("framebuffer display driver initialized with resolution: {}x{}", .{
        active_framebuffer.?.width,
        active_framebuffer.?.height
    });
}

fn unload() void {
    log.info("unloading framebuffer display driver", .{});

    if (initialized_state) {
        if (active_framebuffer) |fb| {
            fb.clear(0x000000);
            active_framebuffer = null;
        }
        initialized_state = false;
    }

    log.info("framebuffer display driver unloaded", .{});
}

pub const driver = manager.Driver{
    .name = "Generic Framebuffer Display",
    .capabilities = .{
        .display = true,
    },
    .probe = probe,
    .init = init,
    .unload = unload,
    .display_interface = &display_interface,
};