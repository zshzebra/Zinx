const arch = @import("arch.zig").internals;

pub const Serial = struct {
    pub const Write = *const fn (byte: u8) void;

    write: Write,

    pub fn writeBytes(self: *const @This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.write(byte);
        }
    }
};

pub fn init() Serial {
    return arch.initSerial();
}
