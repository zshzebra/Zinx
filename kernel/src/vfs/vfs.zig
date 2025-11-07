const std = @import("std");
const Allocator = std.mem.Allocator;
const VFSError = @import("errors.zig").VFSError;
const driver_mgr = @import("../drivers/manager.zig");
const BlockDevice = driver_mgr.BlockDevice;
const log = std.log.scoped(.vfs);

pub const VNode = union(enum) {
    File: *FileVNode,
    Directory: *DirVNode,
    Symlink: *SymlinkVNode,

    pub fn isFile(self: VNode) bool {
        return self == .File;
    }

    pub fn isDir(self: VNode) bool {
        return self == .Directory;
    }

    pub fn isSymlink(self: VNode) bool {
        return self == .Symlink;
    }

    pub fn close(self: VNode) void {
        switch (self) {
            .File => |f| f.close(),
            .Directory => |d| d.close(),
            .Symlink => |s| s.close(),
        }
    }
};

pub const FileVNode = struct {
    fs: *const FileSystem,
    fs_data: *anyopaque,

    pub fn read(self: *const FileVNode, buffer: []u8, offset: u64) VFSError!usize {
        return self.fs.read(self.fs, self, buffer, offset);
    }

    pub fn write(self: *FileVNode, data: []const u8, offset: u64) VFSError!usize {
        return self.fs.write(self.fs, self, data, offset);
    }

    pub fn getSize(self: *const FileVNode) VFSError!u64 {
        return self.fs.get_size(self.fs, @ptrCast(&VNode{ .File = @constCast(self) }));
    }

    pub fn close(self: *const FileVNode) void {
        self.fs.close(self.fs, @ptrCast(&VNode{ .File = @constCast(self) }));
    }
};

pub const DirVNode = struct {
    fs: *const FileSystem,
    fs_data: *anyopaque,
    mount: ?*const DirVNode,

    pub fn open(self: *const DirVNode, name: []const u8, flags: OpenFlags) VFSError!VNode {
        const target = self.mount orelse self;
        return target.fs.open(target.fs, target, name, flags);
    }

    pub fn iterate(self: *const DirVNode) VFSError!DirIterator {
        const target = self.mount orelse self;
        return target.fs.iterate(target.fs, target);
    }

    pub fn close(self: *const DirVNode) void {
        if (root_vnode) |root| {
            if (root == .Directory and root.Directory == self) return;
        }
        self.fs.close(self.fs, @ptrCast(&VNode{ .Directory = @constCast(self) }));
    }
};

pub const SymlinkVNode = struct {
    fs: *const FileSystem,
    fs_data: *anyopaque,
    target_path: []const u8,

    pub fn close(self: *const SymlinkVNode) void {
        self.fs.close(self.fs, @ptrCast(&VNode{ .Symlink = @constCast(self) }));
    }
};

pub const DirEntry = struct {
    name: []const u8,
    is_directory: bool,
    size: u64,
};

pub const DirIterator = struct {
    fs: *const FileSystem,
    fs_data: *anyopaque,

    pub fn next(self: *DirIterator) VFSError!?DirEntry {
        return self.fs.dir_next(self.fs, self);
    }

    pub fn close(self: *DirIterator) void {
        self.fs.dir_close(self.fs, self);
    }
};

pub const FileSystem = struct {
    open: *const fn (*const FileSystem, *const DirVNode, []const u8, OpenFlags) VFSError!VNode,
    close: *const fn (*const FileSystem, *const VNode) void,
    read: *const fn (*const FileSystem, *const FileVNode, []u8, u64) VFSError!usize,
    write: *const fn (*const FileSystem, *FileVNode, []const u8, u64) VFSError!usize,
    get_size: *const fn (*const FileSystem, *const VNode) VFSError!u64,
    get_root: *const fn (*const FileSystem) *DirVNode,
    iterate: *const fn (*const FileSystem, *const DirVNode) VFSError!DirIterator,
    dir_next: *const fn (*const FileSystem, *DirIterator) VFSError!?DirEntry,
    dir_close: *const fn (*const FileSystem, *DirIterator) void,
    instance: *anyopaque,
};

pub const FilesystemDriver = struct {
    name: []const u8,
    probe: *const fn (*BlockDevice) bool,
    init: *const fn (Allocator, *BlockDevice) VFSError!*FileSystem,
    deinit: *const fn (*FileSystem) void,
};

pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    create_dir: bool = false,
    truncate: bool = false,

    pub const READ_ONLY = OpenFlags{ .read = true };
    pub const WRITE_ONLY = OpenFlags{ .write = true };
    pub const READ_WRITE = OpenFlags{ .read = true, .write = true };
    pub const CREATE_FILE = OpenFlags{ .write = true, .create = true };
    pub const CREATE_DIR = OpenFlags{ .create_dir = true };
};

pub const MountPoint = struct {
    path: []const u8,
    dir_node: *DirVNode,
    fs: *const FileSystem,
    fs_root: *DirVNode,
};

var mount_points: std.ArrayList(MountPoint) = undefined;
var filesystem_drivers: std.ArrayList(*const FilesystemDriver) = undefined;
var root_vnode: ?VNode = null;
var vfs_allocator: Allocator = undefined;
var initialized = false;

pub fn init(allocator: Allocator, root_fs: *const FileSystem) !void {
    if (initialized) return;

    log.info("initializing vfs", .{});

    vfs_allocator = allocator;
    mount_points = std.ArrayList(MountPoint){};
    filesystem_drivers = std.ArrayList(*const FilesystemDriver){};

    root_vnode = VNode{ .Directory = root_fs.get_root(root_fs) };

    initialized = true;
    log.info("vfs initialized", .{});
}

pub fn deinit() void {
    if (!initialized) return;

    for (mount_points.items) |*mp| {
        mp.dir_node.mount = null;
        vfs_allocator.free(mp.path);
    }
    mount_points.deinit(vfs_allocator);
    filesystem_drivers.deinit(vfs_allocator);

    initialized = false;
}

pub fn registerFilesystemDriver(driver: *const FilesystemDriver) !void {
    try filesystem_drivers.append(vfs_allocator, driver);
    log.info("registered filesystem driver: {s}", .{driver.name});
}

pub fn mount(path: []const u8, fs: *const FileSystem) VFSError!void {
    const dir = try openDir(path, OpenFlags.READ_ONLY);

    if (dir.mount != null) {
        dir.close();
        return VFSError.AlreadyMounted;
    }

    dir.mount = fs.get_root(fs);

    try mount_points.append(vfs_allocator, .{
        .path = try vfs_allocator.dupe(u8, path),
        .dir_node = dir,
        .fs = fs,
        .fs_root = fs.get_root(fs),
    });

    log.info("mounted filesystem at {s}", .{path});
}

pub fn unmount(path: []const u8) VFSError!void {
    for (mount_points.items, 0..) |*mp, i| {
        if (std.mem.eql(u8, mp.path, path)) {
            mp.dir_node.mount = null;
            vfs_allocator.free(mp.path);
            _ = mount_points.swapRemove(i);
            log.info("unmounted filesystem at {s}", .{path});
            return;
        }
    }
    return VFSError.NotMounted;
}

pub fn mountBlockDevice(path: []const u8, block_dev: *BlockDevice) !void {
    for (filesystem_drivers.items) |driver| {
        if (driver.probe(block_dev)) {
            const name_slice = std.mem.sliceTo(&block_dev.name, 0);
            log.info("detected {s} on block device {s}", .{ driver.name, name_slice });

            const fs = try driver.init(vfs_allocator, block_dev);
            try mount(path, fs);
            return;
        }
    }

    return VFSError.UnknownFilesystem;
}

fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

pub fn open(path: []const u8, flags: OpenFlags) VFSError!VNode {
    if (!initialized) return VFSError.InitializationFailed;
    if (!isAbsolute(path)) return VFSError.NotAbsolutePath;

    if (std.mem.eql(u8, path, "/")) {
        return root_vnode orelse VFSError.InitializationFailed;
    }

    var iter = std.mem.splitScalar(u8, path[1..], '/');
    var current: VNode = root_vnode orelse return VFSError.InitializationFailed;
    var segment_count: usize = 0;

    var count_iter = std.mem.splitScalar(u8, path[1..], '/');
    while (count_iter.next()) |_| segment_count += 1;

    var current_segment: usize = 0;
    while (iter.next()) |segment| : (current_segment += 1) {
        if (segment.len == 0) continue;

        const is_last = (current_segment == segment_count - 1);

        if (!current.isDir()) {
            current.close();
            return VFSError.NotADirectory;
        }

        const dir = current.Directory;
        current = dir.open(segment, if (is_last) flags else OpenFlags.READ_ONLY) catch |err| {
            dir.close();
            return err;
        };

        if (dir != root_vnode.?.Directory) {
            dir.close();
        }

        if (!is_last and current.isSymlink()) {
            const target = current.Symlink.target_path;
            const target_copy = try vfs_allocator.dupe(u8, target);
            defer vfs_allocator.free(target_copy);
            current.close();
            current = try open(target_copy, OpenFlags.READ_ONLY);
        }
    }

    return current;
}

pub fn openFile(path: []const u8, flags: OpenFlags) VFSError!*FileVNode {
    const node = try open(path, flags);
    return switch (node) {
        .File => node.File,
        .Directory => |d| {
            d.close();
            return VFSError.IsADirectory;
        },
        .Symlink => return VFSError.InvalidPath,
    };
}

pub fn openDir(path: []const u8, flags: OpenFlags) VFSError!*DirVNode {
    const node = try open(path, flags);
    return switch (node) {
        .Directory => node.Directory,
        .File => |f| {
            f.close();
            return VFSError.IsAFile;
        },
        .Symlink => return VFSError.InvalidPath,
    };
}

pub fn getRoot() VNode {
    return root_vnode orelse @panic("VFS not initialized");
}
