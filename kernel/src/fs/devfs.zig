const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("../vfs/vfs.zig");
const VFSError = @import("../vfs/errors.zig").VFSError;
const driver_mgr = @import("../drivers/manager.zig");
const log = std.log.scoped(.devfs);

pub const DevFS = struct {
    fs: vfs.FileSystem,
    allocator: Allocator,
    root: *vfs.DirVNode,
    root_dir_data: *RootDirNode,

    pub fn init(allocator: Allocator) !*DevFS {
        const devfs = try allocator.create(DevFS);

        const root_dir_data = try allocator.create(RootDirNode);
        root_dir_data.* = .{};

        const root = try allocator.create(vfs.DirVNode);
        root.* = .{
            .fs = undefined,
            .fs_data = @ptrCast(root_dir_data),
            .mount = null,
        };

        devfs.* = .{
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
                .instance = @ptrCast(devfs),
            },
            .allocator = allocator,
            .root = root,
            .root_dir_data = root_dir_data,
        };

        root.fs = &devfs.fs;

        log.info("devfs initialized", .{});
        return devfs;
    }

    fn fsGetRoot(fs: *const vfs.FileSystem) *vfs.DirVNode {
        const self: *DevFS = @ptrCast(@alignCast(fs.instance));
        return self.root;
    }

    fn fsOpen(
        fs: *const vfs.FileSystem,
        parent: *const vfs.DirVNode,
        name: []const u8,
        flags: vfs.OpenFlags,
    ) VFSError!vfs.VNode {
        _ = parent;
        _ = flags;

        const self: *DevFS = @ptrCast(@alignCast(fs.instance));

        const block_dev = driver_mgr.getBlockDeviceByName(name) orelse {
            return VFSError.DoesNotExist;
        };

        const dev_node = try self.allocator.create(DeviceNode);
        dev_node.* = .{ .block_device = block_dev };

        const file_vnode = try self.allocator.create(vfs.FileVNode);
        file_vnode.* = .{
            .fs = &self.fs,
            .fs_data = @ptrCast(dev_node),
        };

        return vfs.VNode{ .File = file_vnode };
    }

    fn fsClose(fs: *const vfs.FileSystem, node: *const vfs.VNode) void {
        const self: *DevFS = @ptrCast(@alignCast(fs.instance));

        switch (node.*) {
            .File => |f| {
                const dev_node: *DeviceNode = @ptrCast(@alignCast(f.fs_data));
                self.allocator.destroy(dev_node);
                self.allocator.destroy(f);
            },
            .Directory => {},
            .Symlink => {},
        }
    }

    fn fsRead(
        fs: *const vfs.FileSystem,
        node: *const vfs.FileVNode,
        buffer: []u8,
        offset: u64,
    ) VFSError!usize {
        const self: *DevFS = @ptrCast(@alignCast(fs.instance));
        const dev_node: *DeviceNode = @ptrCast(@alignCast(node.fs_data));
        const bd = dev_node.block_device;

        const sector_size: u64 = 512;
        const start_sector = offset / sector_size;
        const sector_offset = offset % sector_size;
        const end_offset = offset + buffer.len;
        const end_sector = (end_offset + sector_size - 1) / sector_size;
        const sector_count = end_sector - start_sector;

        const temp_size = sector_count * sector_size;
        const temp_buf = self.allocator.alloc(u8, temp_size) catch {
            return VFSError.OutOfMemory;
        };
        defer self.allocator.free(temp_buf);

        bd.interface.read(bd.device, start_sector, @intCast(sector_count), temp_buf) catch {
            return VFSError.ReadError;
        };

        const bytes_available = temp_buf.len - sector_offset;
        const bytes_to_copy = @min(buffer.len, bytes_available);
        @memcpy(buffer[0..bytes_to_copy], temp_buf[sector_offset..][0..bytes_to_copy]);

        return bytes_to_copy;
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

        switch (node.*) {
            .File => |f| {
                const dev_node: *DeviceNode = @ptrCast(@alignCast(f.fs_data));
                const bd = dev_node.block_device;
                const sector_count = bd.interface.get_sector_count(bd.device);
                return sector_count * 512;
            },
            else => return VFSError.InvalidPath,
        }
    }

    fn fsIterate(fs: *const vfs.FileSystem, dir: *const vfs.DirVNode) VFSError!vfs.DirIterator {
        _ = dir;

        const self: *DevFS = @ptrCast(@alignCast(fs.instance));

        const iter_data = try self.allocator.create(DevIteratorData);
        iter_data.* = .{
            .devices = driver_mgr.getBlockDevices(),
            .index = 0,
        };

        return vfs.DirIterator{
            .fs = &self.fs,
            .fs_data = @ptrCast(iter_data),
        };
    }

    fn fsDirNext(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) VFSError!?vfs.DirEntry {
        _ = fs;
        const iter_data: *DevIteratorData = @ptrCast(@alignCast(iter.fs_data));

        if (iter_data.index >= iter_data.devices.len) {
            return null;
        }

        const bd = &iter_data.devices[iter_data.index];
        iter_data.index += 1;

        const name_slice = std.mem.sliceTo(&bd.name, 0);
        const sectors = bd.interface.get_sector_count(bd.device);

        return vfs.DirEntry{
            .name = name_slice,
            .is_directory = false,
            .size = sectors * 512,
        };
    }

    fn fsDirClose(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) void {
        const self: *DevFS = @ptrCast(@alignCast(fs.instance));
        const iter_data: *DevIteratorData = @ptrCast(@alignCast(iter.fs_data));
        self.allocator.destroy(iter_data);
    }
};

const RootDirNode = struct {};

const DeviceNode = struct {
    block_device: *driver_mgr.BlockDevice,
};

const DevIteratorData = struct {
    devices: []driver_mgr.BlockDevice,
    index: usize,
};
