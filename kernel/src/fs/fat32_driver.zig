const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("../vfs/vfs.zig");
const VFSError = @import("../vfs/errors.zig").VFSError;
const BlockStream = @import("../vfs/block_stream.zig").BlockStream;
const FAT32 = @import("fat32.zig").FAT32;
const driver_mgr = @import("../drivers/manager.zig");
const BlockDevice = driver_mgr.BlockDevice;
const log = std.log.scoped(.fat32_driver);

pub const fat32_driver = vfs.FilesystemDriver{
    .name = "FAT32",
    .probe = probeFAT32,
    .init = initFAT32,
    .deinit = deinitFAT32,
};

fn probeFAT32(block_dev: *BlockDevice) bool {
    const kernel_alloc = @import("../allocator.zig").getAllocator();
    var stream = BlockStream.init(block_dev, kernel_alloc);
    var boot_sector: [512]u8 = undefined;
    var buffer: [4096]u8 = undefined;

    stream.seekTo(0) catch return false;
    var r = stream.reader(&buffer);
    r.interface.readSliceAll(&boot_sector) catch return false;

    if (boot_sector[510] != 0x55 or boot_sector[511] != 0xAA) return false;

    const fs_type = boot_sector[82..90];
    return std.mem.eql(u8, "FAT32   ", fs_type);
}

fn initFAT32(allocator: Allocator, block_dev: *BlockDevice) VFSError!*vfs.FileSystem {
    const stream = try allocator.create(BlockStream);
    stream.* = BlockStream.init(block_dev, allocator);

    const fat32_fs = FAT32.init(allocator, stream) catch |err| {
        log.err("FAT32 init failed: {}", .{err});
        allocator.destroy(stream);
        return VFSError.InitializationFailed;
    };

    return &fat32_fs.fs;
}

fn deinitFAT32(fs: *vfs.FileSystem) void {
    const fat32_fs: *FAT32 = @ptrCast(@alignCast(fs.instance));
    const stream = fat32_fs.stream;
    const allocator = fat32_fs.allocator;
    fat32_fs.deinit();
    allocator.destroy(stream);
}
