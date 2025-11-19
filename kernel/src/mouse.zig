const std = @import("std");
const framebuffer = @import("framebuffer.zig");

pub const MouseEvent = struct {
    dx: i16,
    dy: i16,
    left_button: bool,
    right_button: bool,
    middle_button: bool,
};

pub var mouse: Mouse = .{
    .x = 0,
    .y = 0,
    .left_button = false,
    .right_button = false,
    .middle_button = false,
};

pub const Mouse = struct {
    x: u32,
    y: u32,
    left_button: bool,
    right_button: bool,
    middle_button: bool,

    pub fn handle_event(event: MouseEvent) void {
        // framebuffer.clear_cursor(mouse.x, mouse.y);

        var new_x = @as(i64, mouse.x) + @as(i64, event.dx);
        var new_y = @as(i64, mouse.y) - @as(i64, event.dy);

        if (new_x < 0) {
            new_x = 0;
        }
        if (new_x >= framebuffer.width) {
            new_x = framebuffer.width - 1;
        }
        if (new_y < 0) {
            new_y = 0;
        }
        if (new_y >= framebuffer.height) {
            new_y = framebuffer.height - 1;
        }

        mouse.x = @intCast(new_x);
        mouse.y = @intCast(new_y);
        mouse.left_button = event.left_button;
        mouse.right_button = event.right_button;
        mouse.middle_button = event.middle_button;

        // framebuffer.draw_cursor(mouse.x, mouse.y);
    }
};
