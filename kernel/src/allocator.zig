const std = @import("std");
const memory = @import("memory.zig");
const pmm = @import("pmm.zig");
const log = std.log.scoped(.allocator);

const VirtAddr = memory.VirtAddr;
const PhysAddr = memory.PhysAddr;
const PAGE_SIZE = memory.PAGE_SIZE;

const BlockHeader = struct {
    size: u64,
    next: ?*BlockHeader,
    free: bool,
};

const HEADER_SIZE = @sizeOf(BlockHeader);
const MIN_BLOCK_SIZE = 32;

var heap_start: ?*BlockHeader = null;
var heap_size: u64 = 0;
var initialized = false;

const KernelAllocator = struct {
    const Self = @This();

    fn alloc(ctx: *anyopaque, len: usize, log2_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;

        if (!initialized) return null;

        const size = std.mem.alignForward(usize, len, @as(usize, 1) << @intFromEnum(log2_align));
        return allocBlock(size);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = log2_align;
        _ = ret_addr;

        if (!initialized) return false;

        const header = getHeaderFromPtr(buf.ptr) orelse return false;
        const aligned_size = std.mem.alignForward(usize, new_len, MIN_BLOCK_SIZE);

        if (aligned_size <= header.size) {
            splitBlock(header, aligned_size);
            return true;
        }

        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = log2_align;
        _ = ret_addr;

        if (!initialized) return;

        freeBlock(buf.ptr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = log2_align;
        _ = ret_addr;

        if (!initialized) return null;

        const new_ptr = allocBlock(new_size) orelse return null;
        const copy_size = @min(buf.len, new_size);
        @memcpy(new_ptr[0..copy_size], buf[0..copy_size]);
        freeBlock(buf.ptr);

        return new_ptr;
    }
};

pub fn init() !void {
    const heap_pages = 256;
    const heap_size_bytes = heap_pages * PAGE_SIZE;

    // Use PMM to get physical memory, then convert to virtual via HHDM
    const heap_phys_start = pmm.allocFrame() orelse return error.OutOfMemory;

    // Allocate contiguous physical frames
    var allocated_frames: [256]PhysAddr = undefined;
    allocated_frames[0] = heap_phys_start;

    for (1..heap_pages) |i| {
        allocated_frames[i] = pmm.allocFrame() orelse {
            // Free previously allocated frames on failure
            for (0..i) |j| {
                pmm.freeFrame(allocated_frames[j]);
            }
            return error.OutOfMemory;
        };
    }

    // Use the first frame as our heap start
    const heap_virt = memory.physToVirt(heap_phys_start);
    heap_start = @ptrFromInt(heap_virt);
    heap_size = heap_size_bytes;

    heap_start.?.* = BlockHeader{
        .size = heap_size - HEADER_SIZE,
        .next = null,
        .free = true,
    };

    initialized = true;
    log.info("heap initialized: {} KB at 0x{X}", .{
        heap_size / 1024,
        heap_virt
    });
}

fn allocBlock(size: usize) ?[*]u8 {
    const aligned_size = std.mem.alignForward(usize, size, MIN_BLOCK_SIZE);
    var current = heap_start;

    while (current) |block| {
        if (block.free and block.size >= aligned_size) {
            block.free = false;
            splitBlock(block, aligned_size);

            const data_ptr = @as([*]u8, @ptrCast(block)) + HEADER_SIZE;
            return data_ptr;
        }
        current = block.next;
    }

    return null;
}

fn freeBlock(ptr: [*]u8) void {
    const header = getHeaderFromPtr(ptr) orelse return;
    header.free = true;
    coalesceBlocks();
}

fn getHeaderFromPtr(ptr: [*]u8) ?*BlockHeader {
    if (@intFromPtr(ptr) < @intFromPtr(heap_start) or
        @intFromPtr(ptr) >= @intFromPtr(heap_start) + heap_size)
    {
        return null;
    }

    const header_ptr = ptr - HEADER_SIZE;
    return @as(*BlockHeader, @ptrCast(@alignCast(header_ptr)));
}

fn splitBlock(block: *BlockHeader, size: usize) void {
    if (block.size > size + HEADER_SIZE + MIN_BLOCK_SIZE) {
        const new_block_addr = @intFromPtr(block) + HEADER_SIZE + size;
        const new_block: *BlockHeader = @ptrFromInt(new_block_addr);

        new_block.* = BlockHeader{
            .size = block.size - size - HEADER_SIZE,
            .next = block.next,
            .free = true,
        };

        block.size = size;
        block.next = new_block;
    }
}

fn coalesceBlocks() void {
    var current = heap_start;

    while (current) |block| {
        if (block.free and block.next != null and block.next.?.free) {
            block.size += HEADER_SIZE + block.next.?.size;
            block.next = block.next.?.next;
        } else {
            current = block.next;
        }
    }
}

pub fn getAllocator() std.mem.Allocator {
    return std.mem.Allocator{
        .ptr = undefined,
        .vtable = &std.mem.Allocator.VTable{
            .alloc = KernelAllocator.alloc,
            .resize = KernelAllocator.resize,
            .free = KernelAllocator.free,
            .remap = KernelAllocator.remap,
        },
    };
}

pub fn getMemoryStats() struct { used: u64, free: u64, total: u64 } {
    var used: u64 = 0;
    var free: u64 = 0;
    var current = heap_start;

    while (current) |block| {
        if (block.free) {
            free += block.size;
        } else {
            used += block.size;
        }
        current = block.next;
    }

    return .{
        .used = used,
        .free = free,
        .total = heap_size,
    };
}