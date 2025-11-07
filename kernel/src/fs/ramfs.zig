const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("../vfs/vfs.zig");
const VFSError = @import("../vfs/errors.zig").VFSError;
const log = std.log.scoped(.ramfs);

const RamNode = union(enum) {
    File: *RamFile,
    Directory: *RamDirectory,
};

const RamFile = struct {
    name: []const u8,
    data: std.ArrayList(u8),
    allocator: Allocator,

    fn create(allocator: Allocator, name: []const u8) !*RamFile {
        const file = try allocator.create(RamFile);
        file.* = .{
            .name = try allocator.dupe(u8, name),
            .data = std.ArrayList(u8){},
            .allocator = allocator,
        };
        return file;
    }

    fn destroy(self: *RamFile) void {
        self.allocator.free(self.name);
        self.data.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const RamDirectory = struct {
    name: []const u8,
    entries: std.StringHashMapUnmanaged(RamNode),
    allocator: Allocator,

    fn create(allocator: Allocator, name: []const u8) !*RamDirectory {
        const dir = try allocator.create(RamDirectory);
        dir.* = .{
            .name = try allocator.dupe(u8, name),
            .entries = std.StringHashMapUnmanaged(RamNode){},
            .allocator = allocator,
        };
        return dir;
    }

    fn destroy(self: *RamDirectory) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |node| {
            switch (node.*) {
                .File => |f| f.destroy(),
                .Directory => |d| d.destroy(),
            }
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

pub const RamFS = struct {
    fs: vfs.FileSystem,
    allocator: Allocator,
    root: *RamDirectory,

    pub fn init(allocator: Allocator) !*RamFS {
        const ramfs = try allocator.create(RamFS);
        errdefer allocator.destroy(ramfs);

        const root = try RamDirectory.create(allocator, "/");
        errdefer root.destroy(allocator);

        ramfs.* = .{
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
                .instance = @ptrCast(ramfs),
            },
            .allocator = allocator,
            .root = root,
        };

        log.info("ramfs initialized", .{});
        return ramfs;
    }

    pub fn deinit(self: *RamFS) void {
        self.root.destroy();
        self.allocator.destroy(self);
    }

    fn fsOpen(
        fs: *const vfs.FileSystem,
        parent: *const vfs.DirVNode,
        name: []const u8,
        flags: vfs.OpenFlags,
    ) VFSError!vfs.VNode {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        const parent_dir: *RamDirectory = @ptrCast(@alignCast(parent.fs_data));

        if (parent_dir.entries.get(name)) |node| {
            return switch (node) {
                .File => |f| blk: {
                    const file_vnode = try self.allocator.create(vfs.FileVNode);
                    file_vnode.* = .{
                        .fs = &self.fs,
                        .fs_data = @ptrCast(f),
                    };
                    break :blk vfs.VNode{ .File = file_vnode };
                },
                .Directory => |d| blk: {
                    const dir_vnode = try self.allocator.create(vfs.DirVNode);
                    dir_vnode.* = .{
                        .fs = &self.fs,
                        .fs_data = @ptrCast(d),
                        .mount = null,
                    };
                    break :blk vfs.VNode{ .Directory = dir_vnode };
                },
            };
        }

        if (flags.create) {
            const file = try RamFile.create(self.allocator, name);
            const name_copy = try self.allocator.dupe(u8, name);
            try parent_dir.entries.put(self.allocator, name_copy, .{ .File = file });

            const file_vnode = try self.allocator.create(vfs.FileVNode);
            file_vnode.* = .{
                .fs = &self.fs,
                .fs_data = @ptrCast(file),
            };
            return vfs.VNode{ .File = file_vnode };
        }

        if (flags.create_dir) {
            const dir = try RamDirectory.create(self.allocator, name);
            const name_copy = try self.allocator.dupe(u8, name);
            try parent_dir.entries.put(self.allocator, name_copy, .{ .Directory = dir });

            const dir_vnode = try self.allocator.create(vfs.DirVNode);
            dir_vnode.* = .{
                .fs = &self.fs,
                .fs_data = @ptrCast(dir),
                .mount = null,
            };
            return vfs.VNode{ .Directory = dir_vnode };
        }

        return VFSError.DoesNotExist;
    }

    fn fsClose(fs: *const vfs.FileSystem, node: *const vfs.VNode) void {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        switch (node.*) {
            .File => |f| self.allocator.destroy(f),
            .Directory => |d| self.allocator.destroy(d),
            .Symlink => |s| self.allocator.destroy(s),
        }
    }

    fn fsRead(
        fs: *const vfs.FileSystem,
        node: *const vfs.FileVNode,
        buffer: []u8,
        offset: u64,
    ) VFSError!usize {
        _ = fs;
        const file: *RamFile = @ptrCast(@alignCast(node.fs_data));

        if (offset >= file.data.items.len) return 0;

        const bytes_to_read = @min(buffer.len, file.data.items.len - offset);
        @memcpy(buffer[0..bytes_to_read], file.data.items[@intCast(offset)..][0..bytes_to_read]);

        return bytes_to_read;
    }

    fn fsWrite(
        fs: *const vfs.FileSystem,
        node: *vfs.FileVNode,
        data: []const u8,
        offset: u64,
    ) VFSError!usize {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        const file: *RamFile = @ptrCast(@alignCast(node.fs_data));

        const end_pos = offset + data.len;
        if (end_pos > file.data.items.len) {
            file.data.resize(self.allocator, @intCast(end_pos)) catch return VFSError.OutOfMemory;
        }

        @memcpy(file.data.items[@intCast(offset)..][0..data.len], data);

        return data.len;
    }

    fn fsGetSize(fs: *const vfs.FileSystem, node: *const vfs.VNode) VFSError!u64 {
        _ = fs;
        return switch (node.*) {
            .File => |f| blk: {
                const file: *RamFile = @ptrCast(@alignCast(f.fs_data));
                break :blk file.data.items.len;
            },
            .Directory => 0,
            .Symlink => 0,
        };
    }

    fn fsGetRoot(fs: *const vfs.FileSystem) *vfs.DirVNode {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        const root_vnode = self.allocator.create(vfs.DirVNode) catch @panic("out of memory");
        root_vnode.* = .{
            .fs = &self.fs,
            .fs_data = @ptrCast(self.root),
            .mount = null,
        };
        return root_vnode;
    }

    fn fsIterate(fs: *const vfs.FileSystem, dir: *const vfs.DirVNode) VFSError!vfs.DirIterator {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        const ram_dir: *RamDirectory = @ptrCast(@alignCast(dir.fs_data));

        const iter_data = try self.allocator.create(RamIteratorData);
        iter_data.* = .{
            .iter = ram_dir.entries.iterator(),
        };

        return vfs.DirIterator{
            .fs = &self.fs,
            .fs_data = @ptrCast(iter_data),
        };
    }

    fn fsDirNext(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) VFSError!?vfs.DirEntry {
        _ = fs;
        const iter_data: *RamIteratorData = @ptrCast(@alignCast(iter.fs_data));

        if (iter_data.iter.next()) |entry| {
            return vfs.DirEntry{
                .name = entry.key_ptr.*,
                .is_directory = entry.value_ptr.* == .Directory,
                .size = switch (entry.value_ptr.*) {
                    .File => |f| f.data.items.len,
                    .Directory => 0,
                },
            };
        }

        return null;
    }

    fn fsDirClose(fs: *const vfs.FileSystem, iter: *vfs.DirIterator) void {
        const self: *RamFS = @ptrCast(@alignCast(fs.instance));
        const iter_data: *RamIteratorData = @ptrCast(@alignCast(iter.fs_data));
        self.allocator.destroy(iter_data);
    }
};

const RamIteratorData = struct {
    iter: std.StringHashMap(RamNode).Iterator,
};
