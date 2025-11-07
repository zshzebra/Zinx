const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("../vfs/vfs.zig");
const VFSError = @import("../vfs/errors.zig").VFSError;
const BlockStream = @import("../vfs/block_stream.zig").BlockStream;
const log = std.log.scoped(.fat32);

const BootRecord = extern struct {
    jmp: [3]u8,
    oem: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    root_directory_size: u16,
    total_sectors_12_16: u16,
    media_descriptor_type: u8,
    sectors_per_fat_12_16: u16,
    sectors_per_track: u16,
    head_count: u16,
    hidden_sectors: u32,
    total_sectors: u32,
    sectors_per_fat: u32,
    mirror_flags: u16,
    version_number: u16,
    root_directory_cluster: u32,
    fsinfo_sector: u16,
    backup_boot_sector: u16,
    reserved0: [12]u8,
    drive_number: u8,
    reserved1: u8,
    signature: u8,
    serial_number: u32,
    volume_label: [11]u8,
    filesystem_type: [8]u8,
};

const ShortName = extern struct {
    name: [8]u8,
    extension: [3]u8,
    attributes: u8,
    reserved: u8,
    time_created_tenth: u8,
    time_created: u16,
    date_created: u16,
    date_last_access: u16,
    cluster_high: u16,
    time_last_modification: u16,
    date_last_modification: u16,
    cluster_low: u16,
    size: u32,

    const ATTR_READ_ONLY = 0x01;
    const ATTR_HIDDEN = 0x02;
    const ATTR_SYSTEM = 0x04;
    const ATTR_VOLUME_ID = 0x08;
    const ATTR_DIRECTORY = 0x10;
    const ATTR_ARCHIVE = 0x20;
    const ATTR_LONG_NAME = 0x0F;

    fn isDir(self: *const ShortName) bool {
        return (self.attributes & ATTR_DIRECTORY) != 0;
    }

    fn isLongName(self: *const ShortName) bool {
        return (self.attributes & 0x3F) == ATTR_LONG_NAME;
    }

    fn getCluster(self: *const ShortName) u32 {
        return (@as(u32, self.cluster_high) << 16) | self.cluster_low;
    }

    fn getName(self: *const ShortName, buff: []u8) u32 {
        var index: u32 = 0;
        for (self.name) |char| {
            if (char != ' ') {
                buff[index] = if (char == 0x05) 0xE5 else char;
                index += 1;
            } else break;
        }
        if (!self.isDir() and self.extension[0] != ' ') {
            buff[index] = '.';
            index += 1;
            for (self.extension) |char| {
                if (char != ' ') {
                    buff[index] = char;
                    index += 1;
                } else break;
            }
        }
        return index;
    }
};

const FATConfig = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    total_sectors: u32,
    sectors_per_fat: u32,
    root_directory_cluster: u32,
    cluster_end_marker: u32,

    fn clusterToSector(self: *const FATConfig, cluster: u32) u32 {
        return (self.sectors_per_fat * 2) + self.reserved_sectors + ((cluster - 2) * self.sectors_per_cluster);
    }
};

const OpenedFileInfo = struct {
    cluster: u32,
    size: u32,
    is_directory: bool,
};

pub const FAT32 = struct {
    fs: vfs.FileSystem,
    allocator: Allocator,
    stream: *BlockStream,
    fat_config: FATConfig,
    fat_cache: []u32,
    root: *vfs.DirVNode,

    pub fn init(allocator: Allocator, stream: *BlockStream) !*FAT32 {
        var boot_sector: [512]u8 = undefined;
        var read_buffer: [4096]u8 = undefined;

        try stream.seekTo(0);
        var r = stream.reader(&read_buffer);
        try r.interface.readSliceAll(&boot_sector);

        const boot_record: *const BootRecord = @ptrCast(@alignCast(&boot_sector));

        if (boot_sector[510] != 0x55 or boot_sector[511] != 0xAA) {
            return VFSError.FilesystemCorrupted;
        }

        if (!std.mem.eql(u8, "FAT32   ", &boot_record.filesystem_type)) {
            return VFSError.UnknownFilesystem;
        }

        const fat_config = FATConfig{
            .bytes_per_sector = boot_record.bytes_per_sector,
            .sectors_per_cluster = boot_record.sectors_per_cluster,
            .reserved_sectors = boot_record.reserved_sectors,
            .total_sectors = boot_record.total_sectors,
            .sectors_per_fat = boot_record.sectors_per_fat,
            .root_directory_cluster = boot_record.root_directory_cluster,
            .cluster_end_marker = 0x0FFFFFF8,
        };

        const fat_size_bytes = fat_config.sectors_per_fat * fat_config.bytes_per_sector;
        const fat_entries = fat_size_bytes / 4;
        const fat_cache = try allocator.alloc(u32, @intCast(fat_entries));
        errdefer allocator.free(fat_cache);

        const fat_offset = fat_config.reserved_sectors * fat_config.bytes_per_sector;
        try stream.seekTo(fat_offset);

        const fat_bytes = std.mem.sliceAsBytes(fat_cache);
        var r2 = stream.reader(&read_buffer);
        try r2.interface.readSliceAll(fat_bytes);

        const fat32 = try allocator.create(FAT32);
        fat32.* = .{
            .fs = .{
                .open = fsOpen,
                .close = fsClose,
                .read = fsRead,
                .write = fsWrite,
                .get_size = fsGetSize,
                .get_root = fsGetRoot,
                .iterate = fsIterate,
                .dir_next = fsDirNext,
                .dir_close = fsDirClose,
                .instance = @ptrCast(fat32),
            },
            .allocator = allocator,
            .stream = stream,
            .fat_config = fat_config,
            .fat_cache = fat_cache,
            .root = undefined,
        };

        const root_info = try allocator.create(OpenedFileInfo);
        root_info.* = .{
            .cluster = fat_config.root_directory_cluster,
            .size = 0,
            .is_directory = true,
        };

        const root_vnode = try allocator.create(vfs.DirVNode);
        root_vnode.* = .{
            .fs = &fat32.fs,
            .fs_data = @ptrCast(root_info),
            .mount = null,
        };
        fat32.root = root_vnode;

        log.info("fat32 initialized", .{});
        return fat32;
    }

    pub fn deinit(self: *FAT32) void {
        self.allocator.free(self.fat_cache);
        const root_info: *OpenedFileInfo = @ptrCast(@alignCast(self.root.fs_data));
        self.allocator.destroy(root_info);
        self.allocator.destroy(self.root);
        self.allocator.destroy(self);
    }

    fn readCluster(self: *FAT32, cluster: u32, buffer: []u8) !void {
        const sector = self.fat_config.clusterToSector(cluster);
        const offset = sector * self.fat_config.bytes_per_sector;
        try self.stream.seekTo(offset);

        const cluster_size = @as(u32, self.fat_config.sectors_per_cluster) * self.fat_config.bytes_per_sector;
        var read_buffer: [4096]u8 = undefined;
        var r = self.stream.reader(&read_buffer);
        try r.interface.readSliceAll(buffer[0..cluster_size]);
    }

    fn getNextCluster(self: *FAT32, cluster: u32) ?u32 {
        const entry = self.fat_cache[cluster];
        if (entry >= self.fat_config.cluster_end_marker) return null;
        return entry;
    }

    fn fsOpen(
        fs: *const vfs.FileSystem,
        parent: *const vfs.DirVNode,
        name: []const u8,
        flags: vfs.OpenFlags,
    ) VFSError!vfs.VNode {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        const parent_info: *OpenedFileInfo = @ptrCast(@alignCast(parent.fs_data));

        if (!parent_info.is_directory) return VFSError.NotADirectory;

        const cluster_size = @as(u32, self.fat_config.sectors_per_cluster) * self.fat_config.bytes_per_sector;
        var cluster_buffer = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(cluster_buffer);

        var current_cluster = parent_info.cluster;
        while (true) {
            try self.readCluster(current_cluster, cluster_buffer);

            var offset: usize = 0;
            while (offset + 32 <= cluster_buffer.len) : (offset += 32) {
                const entry: *const ShortName = @ptrCast(@alignCast(&cluster_buffer[offset]));

                if (entry.name[0] == 0x00) break;
                if (entry.name[0] == 0xE5) continue;
                if (entry.isLongName()) continue;
                if ((entry.attributes & ShortName.ATTR_VOLUME_ID) != 0) continue;

                var name_buffer: [13]u8 = undefined;
                const name_len = entry.getName(&name_buffer);

                if (std.mem.eql(u8, name, name_buffer[0..name_len])) {
                    const file_info = try self.allocator.create(OpenedFileInfo);
                    file_info.* = .{
                        .cluster = entry.getCluster(),
                        .size = entry.size,
                        .is_directory = entry.isDir(),
                    };

                    if (entry.isDir()) {
                        const dir_vnode = try self.allocator.create(vfs.DirVNode);
                        dir_vnode.* = .{
                            .fs = &self.fs,
                            .fs_data = @ptrCast(file_info),
                            .mount = null,
                        };
                        return vfs.VNode{ .Directory = dir_vnode };
                    } else {
                        const file_vnode = try self.allocator.create(vfs.FileVNode);
                        file_vnode.* = .{
                            .fs = &self.fs,
                            .fs_data = @ptrCast(file_info),
                        };
                        return vfs.VNode{ .File = file_vnode };
                    }
                }
            }

            current_cluster = self.getNextCluster(current_cluster) orelse break;
        }

        if (flags.create or flags.create_dir) {
            return VFSError.Unsupported;
        }

        return VFSError.DoesNotExist;
    }

    fn fsClose(fs: *const vfs.FileSystem, node: *const vfs.VNode) void {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        switch (node.*) {
            .File => |f| {
                const info: *OpenedFileInfo = @ptrCast(@alignCast(f.fs_data));
                self.allocator.destroy(info);
                self.allocator.destroy(f);
            },
            .Directory => |d| {
                if (d == self.root) return;
                const info: *OpenedFileInfo = @ptrCast(@alignCast(d.fs_data));
                self.allocator.destroy(info);
                self.allocator.destroy(d);
            },
            .Symlink => |s| {
                self.allocator.destroy(s);
            },
        }
    }

    fn fsRead(
        fs: *const vfs.FileSystem,
        node: *const vfs.FileVNode,
        buffer: []u8,
        offset: u64,
    ) VFSError!usize {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        const file_info: *OpenedFileInfo = @ptrCast(@alignCast(node.fs_data));

        if (offset >= file_info.size) return 0;

        const cluster_size = @as(u32, self.fat_config.sectors_per_cluster) * self.fat_config.bytes_per_sector;
        const bytes_to_read = @min(buffer.len, file_info.size - @as(u32, @intCast(offset)));

        var cluster_buffer = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(cluster_buffer);

        var current_cluster = file_info.cluster;
        var file_offset: u64 = 0;
        var bytes_read: usize = 0;

        while (current_cluster < self.fat_config.cluster_end_marker and bytes_read < bytes_to_read) {
            try self.readCluster(current_cluster, cluster_buffer);

            if (file_offset + cluster_size > offset) {
                const cluster_offset = if (file_offset < offset) offset - file_offset else 0;
                const bytes_from_cluster = @min(
                    cluster_size - cluster_offset,
                    bytes_to_read - bytes_read,
                );

                @memcpy(
                    buffer[bytes_read..][0..bytes_from_cluster],
                    cluster_buffer[@intCast(cluster_offset)..][0..bytes_from_cluster],
                );
                bytes_read += bytes_from_cluster;
            }

            file_offset += cluster_size;
            current_cluster = self.getNextCluster(current_cluster) orelse break;
        }

        return bytes_read;
    }

    fn fsWrite(
        fs: *const vfs.FileSystem,
        node: *vfs.FileVNode,
        data: []const u8,
        offset: u64,
    ) VFSError!usize {
        _ = fs;
        _ = node;
        _ = data;
        _ = offset;
        return VFSError.Unsupported;
    }

    fn fsGetSize(fs: *const vfs.FileSystem, node: *const vfs.VNode) VFSError!u64 {
        _ = fs;
        return switch (node.*) {
            .File => |f| blk: {
                const info: *OpenedFileInfo = @ptrCast(@alignCast(f.fs_data));
                break :blk info.size;
            },
            .Directory => 0,
            .Symlink => 0,
        };
    }

    fn fsGetRoot(fs: *const vfs.FileSystem) *vfs.DirVNode {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        return self.root;
    }

    fn fsIterate(fs: *const vfs.FileSystem, dir: *const vfs.DirVNode) VFSError!vfs.DirIterator {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        const dir_info: *OpenedFileInfo = @ptrCast(@alignCast(dir.fs_data));

        const iter_data = try self.allocator.create(FAT32Iterator);
        iter_data.* = .{
            .cluster = dir_info.cluster,
            .offset = 0,
            .cluster_buffer = null,
        };

        return vfs.DirIterator{
            .fs = &self.fs,
            .fs_data = @ptrCast(iter_data),
        };
    }

    fn fsDirNext(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) VFSError!?vfs.DirEntry {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        const iter_data: *FAT32Iterator = @ptrCast(@alignCast(iter.fs_data));

        const cluster_size = @as(u32, self.fat_config.sectors_per_cluster) * self.fat_config.bytes_per_sector;

        if (iter_data.cluster_buffer == null) {
            iter_data.cluster_buffer = try self.allocator.alloc(u8, cluster_size);
            try self.readCluster(iter_data.cluster, iter_data.cluster_buffer.?);
        }

        while (iter_data.cluster < self.fat_config.cluster_end_marker) {
            const buffer = iter_data.cluster_buffer.?;

            while (iter_data.offset + 32 <= buffer.len) {
                const offset = iter_data.offset;
                iter_data.offset += 32;

                const entry: *const ShortName = @ptrCast(@alignCast(&buffer[offset]));

                if (entry.name[0] == 0x00) return null;
                if (entry.name[0] == 0xE5) continue;
                if (entry.isLongName()) continue;
                if ((entry.attributes & ShortName.ATTR_VOLUME_ID) != 0) continue;
                if (entry.name[0] == '.' and entry.name[1] == ' ') continue;

                var name_buffer: [13]u8 = undefined;
                const name_len = entry.getName(&name_buffer);
                const name = try self.allocator.dupe(u8, name_buffer[0..name_len]);

                return vfs.DirEntry{
                    .name = name,
                    .is_directory = entry.isDir(),
                    .size = entry.size,
                };
            }

            iter_data.cluster = self.getNextCluster(iter_data.cluster) orelse return null;
            iter_data.offset = 0;
            try self.readCluster(iter_data.cluster, buffer);
        }

        return null;
    }

    fn fsDirClose(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) void {
        const self: *FAT32 = @ptrCast(@alignCast(fs.instance));
        const iter_data: *FAT32Iterator = @ptrCast(@alignCast(iter.fs_data));
        if (iter_data.cluster_buffer) |buffer| {
            self.allocator.free(buffer);
        }
        self.allocator.destroy(iter_data);
    }
};

const FAT32Iterator = struct {
    cluster: u32,
    offset: usize,
    cluster_buffer: ?[]u8,
};
