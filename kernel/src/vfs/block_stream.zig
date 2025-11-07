const std = @import("std");
const Allocator = std.mem.Allocator;
const driver_mgr = @import("../drivers/manager.zig");
const DriverError = driver_mgr.DriverError;
const BlockDevice = driver_mgr.BlockDevice;

pub const BlockStream = struct {
    block_device: *BlockDevice,
    allocator: Allocator,
    position: u64,

    pub const ReadError = DriverError || error{OutOfMemory};
    pub const WriteError = DriverError;
    pub const SeekError = error{InvalidSeekPosition};

    pub fn init(block_dev: *BlockDevice, allocator: Allocator) BlockStream {
        return .{
            .block_device = block_dev,
            .allocator = allocator,
            .position = 0,
        };
    }

    pub const Reader = struct {
        stream: *BlockStream,
        interface: std.io.Reader,

        pub fn init(stream: *BlockStream, buffer: []u8) Reader {
            return .{
                .stream = stream,
                .interface = .{
                    .vtable = &.{
                        .stream = readerStream,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn readerStream(io_reader: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
            const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
            const n = r.stream.read(dest) catch return error.ReadFailed;
            w.advance(n);
            return n;
        }
    };

    pub fn reader(self: *BlockStream, buffer: []u8) Reader {
        return Reader.init(self, buffer);
    }

    pub fn seekTo(self: *BlockStream, pos: u64) SeekError!void {
        const max_pos = self.block_device.interface.get_sector_count(
            self.block_device.device,
        ) * self.block_device.interface.get_sector_size(
            self.block_device.device,
        );

        if (pos > max_pos) return SeekError.InvalidSeekPosition;
        self.position = pos;
    }

    pub fn seekBy(self: *BlockStream, offset: i64) SeekError!void {
        const new_pos: i64 = @as(i64, @intCast(self.position)) + offset;
        if (new_pos < 0) return SeekError.InvalidSeekPosition;
        try self.seekTo(@intCast(new_pos));
    }

    pub fn getPos(self: *BlockStream) u64 {
        return self.position;
    }

    pub fn getEndPos(self: *BlockStream) u64 {
        return self.block_device.interface.get_sector_count(
            self.block_device.device,
        ) * self.block_device.interface.get_sector_size(
            self.block_device.device,
        );
    }

    fn read(self: *BlockStream, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;

        const sector_size = self.block_device.interface.get_sector_size(
            self.block_device.device,
        );
        const start_lba = self.position / sector_size;
        const offset_in_sector = self.position % sector_size;

        const bytes_to_read = buffer.len;
        const sectors_needed = (offset_in_sector + bytes_to_read + sector_size - 1) / sector_size;
        const buffer_size_needed = sectors_needed * sector_size;

        const sector_buffer = try self.allocator.alloc(u8, buffer_size_needed);
        defer self.allocator.free(sector_buffer);

        try self.block_device.interface.read(
            self.block_device.device,
            start_lba,
            @intCast(sectors_needed),
            sector_buffer,
        );

        const bytes_available = @min(bytes_to_read, buffer_size_needed - offset_in_sector);
        @memcpy(buffer[0..bytes_available], sector_buffer[offset_in_sector..][0..bytes_available]);

        self.position += bytes_available;
        return bytes_available;
    }
};
