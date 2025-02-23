const std = @import("std");
const tty = @import("tty.zig");

const ssfn = @cImport({
    @cDefine("SSFN_CONSOLEBITMAP_TRUECOLOR", {});
    @cDefine("NULL", "((void*)0)");
    @cInclude("ssfn.h");
});

pub export var ssfn_src: ?*ssfn.ssfn_font_t = null;
pub export var ssfn_dst: ssfn.ssfn_buf_t = std.mem.zeroes(ssfn.ssfn_buf_t);

pub const PixelFormat = enum {
    XRGB,
};

pub const MAX_FRAMEBUFFERS = 16;

pub const FramebufferInfo = struct {
    count: usize,
    buffers: [MAX_FRAMEBUFFERS]?Framebuffer,
};

pub const ImageError = error{
    BoundryError,
};

pub const ImageResult = struct { width: u64, height: u64 };

pub const ImageBreak = enum {
    /// Inserts image without moving the cursor
    NoBreak,
    /// Moves the cursor to the right of image, just like normal write()
    Word,
    /// Move the cursor to a new line after the image. This is the default behavior
    Newline,
};

pub const FramebufferConsole = struct {
    framebuffer: *Framebuffer,
    offset: struct {
        x: u64,
        y: u64,
    },

    pub fn init(framebuffer: *Framebuffer) FramebufferConsole {
        ssfn.ssfn_src = @ptrCast(@constCast(@embedFile("VGA9.sfn")));

        ssfn.ssfn_dst.ptr = framebuffer.buffer;
        ssfn.ssfn_dst.w = @intCast(framebuffer.width);
        ssfn.ssfn_dst.h = @intCast(framebuffer.height);
        ssfn.ssfn_dst.p = @intCast(framebuffer.pitch);
        ssfn.ssfn_dst.x = 0;
        ssfn.ssfn_dst.y = 0;
        ssfn.ssfn_dst.fg = 0xFFFFFF;

        return .{ .framebuffer = framebuffer, .offset = .{ .x = 0, .y = 0 } };
    }

    pub fn buffer(self: *FramebufferConsole) tty.ConsoleBuffer {
        return .{
            .ptr = self,
            .writeCharFn = writeChar,
            .clearFn = clear,
            .writeImageFn = writeImage,
        };
    }
    pub fn writeChar(ptr: *anyopaque, c: u8, char_x: usize, char_y: usize) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        const x = (char_x * ssfn_src.?.width) + self.offset.x;
        const y = (char_y * ssfn_src.?.height) + self.offset.y;

        if (x >= self.framebuffer.width or y >= self.framebuffer.height)
            return;

        ssfn_dst.x = @intCast(x);
        ssfn_dst.y = @intCast(y);

        _ = ssfn.ssfn_putc(c);
    }

    pub fn writeImage(ptr: *anyopaque, image: []const u32, image_width: u64, image_height: u64, cursor_x: usize, cursor_y: usize, chroma_key: u32) ImageError!ImageResult {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        const offset_x = (cursor_x * ssfn_src.?.width) + self.offset.x;
        const offset_y = (cursor_y * ssfn_src.?.height) + self.offset.y;

        for (0..image_height) |y| {
            for (0..image_width) |x| {
                const color: u32 = image[
                    (y * image_width) + x
                ];

                if (color == chroma_key) continue;

                self.framebuffer.setPixel(x + offset_x, y + offset_y, color);
            }
        }

        return .{
            .width = @divFloor(image_width, ssfn_src.?.width),
            .height = @divFloor(image_height, ssfn_src.?.height),
        };
    }

    pub fn clear(ptr: *anyopaque) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.framebuffer.clear(0x1e1e2e);
    }

    pub fn setOffset(ptr: *anyopaque, x: u64, y: u64) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.offset = .{
            .x = x,
            .y = y,
        };
    }
};

pub const Framebuffer = struct {
    buffer: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    pixel_format: PixelFormat,
    console: FramebufferConsole,

    pub fn init(buffer: [*]u8, width: usize, height: usize, pitch: usize, bpp: u16, pixel_format: PixelFormat) Framebuffer {
        var fb = Framebuffer{
            .buffer = buffer,
            .width = width,
            .height = height,
            .pitch = pitch,
            .bpp = bpp,
            .pixel_format = pixel_format,
            .console = undefined,
        };

        fb.console = FramebufferConsole.init(&fb);

        return fb;
    }

    /// Set pixel at (x, y) to color in RGB format
    pub fn setPixel(self: *Framebuffer, x: usize, y: usize, color: u32) void {
        if (x >= self.width or y >= self.height)
            return;

        const offset = y * self.pitch + x * (self.bpp / 8);
        switch (self.pixel_format) {
            .XRGB => {
                @as(*u32, @ptrCast(@alignCast(self.buffer + offset))).* = color | (0xFF << 24);
            },
        }
    }

    /// Clear framebuffer to the specified color in RGB format
    pub fn clear(self: *Framebuffer, color: u32) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                self.setPixel(x, y, color);
            }
        }
    }

    pub fn getTTY(self: *Framebuffer) tty.Console {
        return .{
            .width = @intCast(@divFloor(self.width, ssfn_src.?.width)),
            .height = @intCast(@divFloor(self.height, ssfn_src.?.height)),
            .cursor_x = 0,
            .cursor_y = 0,
            .buffer = self.console.buffer(),
        };
    }
};
