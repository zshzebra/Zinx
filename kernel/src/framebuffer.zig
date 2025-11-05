const std = @import("std");
const tty = @import("tty.zig");
const mojangles = @import("mojangles.zig");

const Font = struct {
    width: usize,
    height: usize,
    data: [256][8]u8,
};

const font: Font = .{
    .width = mojangles.width,
    .height = mojangles.height,
    .data = mojangles.data,
};

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
    fg: u32,
    bg: u32,
    offset: struct {
        x: u64,
        y: u64,
    },

    pub fn init(framebuffer: *Framebuffer) FramebufferConsole {
        return .{ .framebuffer = framebuffer, .offset = .{ .x = 0, .y = 0 }, .fg = 0xFFFFFF, .bg = 0x1e1e2e };
    }

    pub fn buffer(self: *FramebufferConsole) tty.ConsoleBuffer {
        return .{
            .ptr = self,
            .writeCharFn = writeChar,
            .writeCursorFn = writeCursor,
            .clearCharFn = clearChar,
            .clearFn = clear,
            .writeImageFn = writeImage,
            .setColorsFn = setColors,
        };
    }

    pub fn writeChar(console: *tty.Console, ptr: *anyopaque, c: u8, char_x: usize, char_y: usize) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        const x = (char_x * 8) + self.offset.x;
        var y = (char_y * 8) + self.offset.y;

        if (x >= self.framebuffer.width) return;
        if (y >= self.framebuffer.height) {
            self.framebuffer.scroll(8);
            console.cursor_y -= 1;
            y -= 8;
        }

        for (0..8) |row| {
            for (0..8) |col| {
                var color: u32 = self.bg;
                if ((mojangles.data[c][row] >> @as(u3, @intCast(col))) & 1 == 1) {
                    color = self.fg;
                }
                self.framebuffer.setPixel(x + col, y + row, color);
            }
        }
    }

    pub fn writeImage(ptr: *anyopaque, image: []const u32, image_width: u64, image_height: u64, cursor_x: usize, cursor_y: usize, chroma_key: u32) ImageError!ImageResult {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        const offset_x = (cursor_x * font.width) + self.offset.x;
        const offset_y = (cursor_y * font.height) + self.offset.y;

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
            .width = @divFloor(image_width, font.width),
            .height = @divFloor(image_height, font.height),
        };
    }

    fn setCharBlock(self: *FramebufferConsole, color: u32, cursor_x: usize, cursor_y: usize) void {
        const offset_x = (cursor_x * font.width) + self.offset.x;
        const offset_y = (cursor_y * font.height) + self.offset.y;

        for (0..font.height) |font_y| {
            for (0..font.width) |font_x| {
                self.framebuffer.setPixel(font_x + offset_x, font_y + offset_y, color);
            }
        }
    }

    pub fn writeCursor(ptr: *anyopaque, char_x: usize, char_y: usize) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.setCharBlock(self.fg, char_x, char_y);
    }

    pub fn clearChar(ptr: *anyopaque, char_x: usize, char_y: usize) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.setCharBlock(self.bg, char_x, char_y);
    }

    pub fn clear(ptr: *anyopaque) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.framebuffer.clear(self.bg);
    }

    pub fn setColors(ptr: *anyopaque, fg: u32, bg: u32) void {
        const self: *FramebufferConsole = @ptrCast(@alignCast(ptr));

        self.fg = fg;
        self.bg = bg;
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

    pub fn getPixel(self: *Framebuffer, x: usize, y: usize) u32 {
        if (x >= self.width or y >= self.height) return 0;

        const offset = y * self.pitch + x * (self.bpp / 8);
        switch (self.pixel_format) {
            .XRGB => {
                return (@as(*u32, @ptrCast(@alignCast(self.buffer + offset))).*) & (0x00FFFFFF);
            },
        }
    }

    pub fn scroll(self: *Framebuffer, y: usize) void {
        for (0..self.height + 1) |pixel_y| {
            for (0..self.width + 1) |pixel_x| {
                self.setPixel(pixel_x, pixel_y, self.getPixel(pixel_x, pixel_y + y));
            }
        }

        for (0..y + 1) |pixel_y| {
            for (0..self.width + 1) |pixel_x| {
                self.setPixel(pixel_x, self.height - pixel_y, self.console.bg);
            }
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
            .width = @intCast(@divFloor(self.width, font.width)),
            .height = @intCast(@divFloor(self.height, font.height)),
            .cursor_x = 0,
            .cursor_y = 0,
            .buffer = self.console.buffer(),
        };
    }
};
