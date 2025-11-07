const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("../vfs/vfs.zig");
const VFSError = @import("../vfs/errors.zig").VFSError;
const driver_mgr = @import("../drivers/manager.zig");
const log = std.log.scoped(.sysfs);

pub const SysFS = struct {
    fs: vfs.FileSystem,
    allocator: Allocator,
    root: *vfs.DirVNode,
    root_dir_data: *SysDirNode,

    pub fn init(allocator: Allocator) !*SysFS {
        const sysfs = try allocator.create(SysFS);

        const root_dir_data = try allocator.create(SysDirNode);
        root_dir_data.* = .{ .path_type = .root };

        const root = try allocator.create(vfs.DirVNode);
        root.* = .{
            .fs = undefined,
            .fs_data = @ptrCast(root_dir_data),
            .mount = null,
        };

        sysfs.* = .{
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
                .instance = @ptrCast(sysfs),
            },
            .allocator = allocator,
            .root = root,
            .root_dir_data = root_dir_data,
        };

        root.fs = &sysfs.fs;

        log.info("sysfs initialized", .{});
        return sysfs;
    }

    fn fsGetRoot(fs: *const vfs.FileSystem) *vfs.DirVNode {
        const self: *SysFS = @ptrCast(@alignCast(fs.instance));
        return self.root;
    }

    fn fsOpen(
        fs: *const vfs.FileSystem,
        parent: *const vfs.DirVNode,
        name: []const u8,
        flags: vfs.OpenFlags,
    ) VFSError!vfs.VNode {
        _ = flags;

        const self: *SysFS = @ptrCast(@alignCast(fs.instance));
        const parent_node: *SysDirNode = @ptrCast(@alignCast(parent.fs_data));

        switch (parent_node.path_type) {
            .root => {
                if (std.mem.eql(u8, name, "block")) {
                    const dir_node = try self.allocator.create(SysDirNode);
                    dir_node.* = .{ .path_type = .block_root };

                    const dir_vnode = try self.allocator.create(vfs.DirVNode);
                    dir_vnode.* = .{
                        .fs = &self.fs,
                        .fs_data = @ptrCast(dir_node),
                        .mount = null,
                    };
                    return vfs.VNode{ .Directory = dir_vnode };
                }
                return VFSError.DoesNotExist;
            },
            .block_root => {
                const block_dev = driver_mgr.getBlockDeviceByName(name) orelse {
                    return VFSError.DoesNotExist;
                };

                const dir_node = try self.allocator.create(SysDirNode);
                dir_node.* = .{ .path_type = .{ .device_dir = block_dev } };

                const dir_vnode = try self.allocator.create(vfs.DirVNode);
                dir_vnode.* = .{
                    .fs = &self.fs,
                    .fs_data = @ptrCast(dir_node),
                    .mount = null,
                };
                return vfs.VNode{ .Directory = dir_vnode };
            },
            .device_dir => |block_dev| {
                const attr = if (std.mem.eql(u8, name, "size"))
                    SysAttribute.size
                else if (std.mem.eql(u8, name, "sectors"))
                    SysAttribute.sectors
                else if (std.mem.eql(u8, name, "name"))
                    SysAttribute.name
                else
                    return VFSError.DoesNotExist;

                const file_node = try self.allocator.create(SysFileNode);
                file_node.* = .{
                    .block_device = block_dev,
                    .attribute = attr,
                };

                const file_vnode = try self.allocator.create(vfs.FileVNode);
                file_vnode.* = .{
                    .fs = &self.fs,
                    .fs_data = @ptrCast(file_node),
                };
                return vfs.VNode{ .File = file_vnode };
            },
        }
    }

    fn fsClose(fs: *const vfs.FileSystem, node: *const vfs.VNode) void {
        const self: *SysFS = @ptrCast(@alignCast(fs.instance));

        switch (node.*) {
            .File => |f| {
                const file_node: *SysFileNode = @ptrCast(@alignCast(f.fs_data));
                self.allocator.destroy(file_node);
                self.allocator.destroy(f);
            },
            .Directory => |d| {
                if (d != self.root) {
                    const dir_node: *SysDirNode = @ptrCast(@alignCast(d.fs_data));
                    self.allocator.destroy(dir_node);
                    self.allocator.destroy(d);
                }
            },
            .Symlink => {},
        }
    }

    fn fsRead(
        fs: *const vfs.FileSystem,
        node: *const vfs.FileVNode,
        buffer: []u8,
        offset: u64,
    ) VFSError!usize {
        _ = fs;

        const file_node: *SysFileNode = @ptrCast(@alignCast(node.fs_data));
        const bd = file_node.block_device;

        var content_buf: [256]u8 = undefined;
        const content = switch (file_node.attribute) {
            .size => blk: {
                const sectors = bd.interface.get_sector_count(bd.device);
                const size = sectors * 512;
                break :blk std.fmt.bufPrint(&content_buf, "{d}\n", .{size}) catch "";
            },
            .sectors => blk: {
                const sectors = bd.interface.get_sector_count(bd.device);
                break :blk std.fmt.bufPrint(&content_buf, "{d}\n", .{sectors}) catch "";
            },
            .name => blk: {
                const name_slice = std.mem.sliceTo(&bd.name, 0);
                break :blk std.fmt.bufPrint(&content_buf, "{s}\n", .{name_slice}) catch "";
            },
        };

        if (offset >= content.len) return 0;

        const bytes_to_copy = @min(buffer.len, content.len - offset);
        @memcpy(buffer[0..bytes_to_copy], content[offset..][0..bytes_to_copy]);

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
            .File => return 0,
            else => return VFSError.InvalidPath,
        }
    }

    fn fsIterate(fs: *const vfs.FileSystem, dir: *const vfs.DirVNode) VFSError!vfs.DirIterator {
        const self: *SysFS = @ptrCast(@alignCast(fs.instance));
        const dir_node: *SysDirNode = @ptrCast(@alignCast(dir.fs_data));

        const iter_data = try self.allocator.create(SysIteratorData);
        iter_data.* = .{
            .path_type = dir_node.path_type,
            .index = 0,
            .devices = if (dir_node.path_type == .block_root) driver_mgr.getBlockDevices() else &[_]driver_mgr.BlockDevice{},
            .device = if (dir_node.path_type == .device_dir) dir_node.path_type.device_dir else null,
        };

        return vfs.DirIterator{
            .fs = &self.fs,
            .fs_data = @ptrCast(iter_data),
        };
    }

    fn fsDirNext(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) VFSError!?vfs.DirEntry {
        _ = fs;

        const iter_data: *SysIteratorData = @ptrCast(@alignCast(iter.fs_data));

        switch (iter_data.path_type) {
            .root => {
                if (iter_data.index == 0) {
                    iter_data.index += 1;
                    return vfs.DirEntry{
                        .name = "block",
                        .is_directory = true,
                        .size = 0,
                    };
                }
                return null;
            },
            .block_root => {
                if (iter_data.index >= iter_data.devices.len) return null;

                const bd = &iter_data.devices[iter_data.index];
                iter_data.index += 1;

                return vfs.DirEntry{
                    .name = std.mem.sliceTo(&bd.name, 0),
                    .is_directory = true,
                    .size = 0,
                };
            },
            .device_dir => {
                const attrs = [_][]const u8{ "size", "sectors", "name" };
                if (iter_data.index >= attrs.len) return null;

                const attr_name = attrs[iter_data.index];
                iter_data.index += 1;

                return vfs.DirEntry{
                    .name = attr_name,
                    .is_directory = false,
                    .size = 0,
                };
            },
        }
    }

    fn fsDirClose(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) void {
        const self: *SysFS = @ptrCast(@alignCast(fs.instance));
        const iter_data: *SysIteratorData = @ptrCast(@alignCast(iter.fs_data));
        self.allocator.destroy(iter_data);
    }
};

const PathType = union(enum) {
    root,
    block_root,
    device_dir: *driver_mgr.BlockDevice,
};

const SysDirNode = struct {
    path_type: PathType,
};

const SysFileNode = struct {
    block_device: *driver_mgr.BlockDevice,
    attribute: SysAttribute,
};

const SysAttribute = enum {
    size,
    sectors,
    name,
};

const SysIteratorData = struct {
    path_type: PathType,
    index: usize,
    devices: []driver_mgr.BlockDevice,
    device: ?*driver_mgr.BlockDevice,
};
