const fb = @import("framebuffer.zig");
const ImageError = fb.ImageError;
const ImageResult = fb.ImageResult;
const ImageBreak = fb.ImageBreak;

pub const Console = struct {
    width: usize,
    height: usize,
    cursor_x: usize,
    cursor_y: usize,
    buffer: ConsoleBuffer,

    pub fn writeChar(self: *Console, c: u8) void {
        if (c == '\n' or self.cursor_x >= self.width) {
            self.cursor_x = 0;
            self.cursor_y += 1;
            return;
        }

        self.buffer.writeCharFn(self.buffer.ptr, c, self.cursor_x, self.cursor_y);
        self.cursor_x += 1;
    }

    pub fn write(self: *Console, str: []const u8) void {
        for (str) |c| {
            self.writeChar(c);
        }
    }

    pub fn writeImage(self: *Console, image: []const u32, image_width: u64, image_height: u64, chroma_key: ?u32, image_break: ?ImageBreak) ImageError!void {
        const size = try self.buffer.writeImageFn(self.buffer.ptr, image, image_width, image_height, self.cursor_x, self.cursor_y, chroma_key orelse 0);

        switch (image_break orelse ImageBreak.Newline) {
            .Word => {
                self.cursor_x += size.width;
            },
            .Newline => {
                self.cursor_y += size.height;
                self.cursor_x = 0;
            },
            .NoBreak => {},
        }
    }

    pub fn clear(self: *Console) void {
        self.buffer.clearFn(self.buffer.ptr);
        self.setCursor(0, 0);
    }

    pub fn setCursor(self: *Console, x: u64, y: u64) void {
        self.cursor_x = x;
        self.cursor_y = y;
    }
};

pub const ConsoleBuffer = struct {
    ptr: *anyopaque,
    writeCharFn: *const fn (ptr: *anyopaque, c: u8, x: usize, y: usize) void,
    clearFn: *const fn (ptr: *anyopaque) void,
    writeImageFn: *const fn (ptr: *anyopaque, image: []const u32, image_width: u64, image_height: u64, cursor_x: usize, cursor_y: usize, chroma_key: u32) ImageError!ImageResult,
};
