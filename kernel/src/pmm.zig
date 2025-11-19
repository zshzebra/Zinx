const std = @import("std");
const memory = @import("memory.zig");
const log = std.log.scoped(.pmm);

const MemoryType = memory.MemoryType;
const MemoryRegion = memory.MemoryRegion;
const PhysAddr = memory.PhysAddr;
const PAGE_SIZE = memory.PAGE_SIZE;

const Bitmap = struct {
    data: []u8,
    total_frames: u64,

    fn setFrame(self: *Bitmap, frame: u64) void {
        const byte_index = frame / 8;
        const bit_index: u3 = @intCast(frame % 8);
        if (byte_index < self.data.len) {
            self.data[byte_index] |= (@as(u8, 1) << bit_index);
        }
    }

    fn clearFrame(self: *Bitmap, frame: u64) void {
        const byte_index = frame / 8;
        const bit_index: u3 = @intCast(frame % 8);
        if (byte_index < self.data.len) {
            self.data[byte_index] &= ~(@as(u8, 1) << bit_index);
        }
    }

    fn isFrameSet(self: *const Bitmap, frame: u64) bool {
        const byte_index = frame / 8;
        const bit_index: u3 = @intCast(frame % 8);
        if (byte_index >= self.data.len) return true;
        return (self.data[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    fn findFreeFrame(self: *const Bitmap) ?u64 {
        for (self.data, 0..) |byte, byte_index| {
            if (byte != 0xFF) {
                for (0..8) |bit_index| {
                    const bit_idx: u3 = @intCast(bit_index);
                    if ((byte & (@as(u8, 1) << bit_idx)) == 0) {
                        const frame = byte_index * 8 + bit_index;
                        return if (frame < self.total_frames) frame else null;
                    }
                }
            }
        }
        return null;
    }

    fn findContiguousFrames(self: *const Bitmap, count: u64, alignment_frames: u64) ?u64 {
        if (count == 0) return null;
        if (count > self.total_frames) return null;

        var start_frame: u64 = 0;

        // Align start_frame to alignment requirement
        if (alignment_frames > 1) {
            start_frame = ((start_frame + alignment_frames - 1) / alignment_frames) * alignment_frames;
        }

        while (start_frame + count <= self.total_frames) {
            // Check if all frames from start_frame to start_frame + count are free
            var all_free = true;
            for (0..count) |offset| {
                if (self.isFrameSet(start_frame + offset)) {
                    all_free = false;
                    // Jump to next potential aligned position after this occupied frame
                    start_frame = start_frame + offset + 1;
                    if (alignment_frames > 1) {
                        start_frame = ((start_frame + alignment_frames - 1) / alignment_frames) * alignment_frames;
                    }
                    break;
                }
            }

            if (all_free) {
                return start_frame;
            }
        }

        return null;
    }
};

var bitmap: Bitmap = undefined;
var initialized = false;
var highest_frame: u64 = 0;
var total_memory: u64 = 0;
var free_memory: u64 = 0;

pub fn init() !void {
    const memory_map = memory.getMemoryMap();
    if (memory_map.len == 0) return error.NoMemoryMap;

    for (memory_map) |region| {
        const end_addr = region.base + region.length;
        const end_frame = end_addr / PAGE_SIZE;
        if (end_frame > highest_frame) {
            highest_frame = end_frame;
        }
        if (region.type == .usable) {
            total_memory += region.length;
        }
    }

    const bitmap_size = (highest_frame + 7) / 8;
    var bitmap_addr: ?PhysAddr = null;

    for (memory_map) |region| {
        if (region.type == .usable and region.length >= bitmap_size) {
            bitmap_addr = region.base;
            break;
        }
    }

    if (bitmap_addr == null) return error.NoSpaceForBitmap;

    const bitmap_virt = memory.physToVirt(bitmap_addr.?);
    bitmap = Bitmap{
        .data = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bitmap_size],
        .total_frames = highest_frame,
    };

    @memset(bitmap.data, 0xFF);

    for (memory_map) |region| {
        if (region.type == .usable) {
            const start_frame = memory.pageAlignDown(region.base) / PAGE_SIZE;
            const end_frame = memory.pageAlign(region.base + region.length) / PAGE_SIZE;

            for (start_frame..end_frame) |frame| {
                bitmap.clearFrame(frame);
            }
        }
    }

    const bitmap_start_frame = bitmap_addr.? / PAGE_SIZE;
    const bitmap_end_frame = (bitmap_addr.? + bitmap_size + PAGE_SIZE - 1) / PAGE_SIZE;
    for (bitmap_start_frame..bitmap_end_frame) |frame| {
        bitmap.setFrame(frame);
    }

    free_memory = total_memory;
    initialized = true;

    log.info("initialized: {} MB total, {} frames managed", .{
        total_memory / (1024 * 1024),
        highest_frame
    });
}

pub fn allocFrame() ?PhysAddr {
    if (!initialized) return null;

    const frame = bitmap.findFreeFrame() orelse return null;
    bitmap.setFrame(frame);
    free_memory -= PAGE_SIZE;

    return frame * PAGE_SIZE;
}

pub fn freeFrame(addr: PhysAddr) void {
    if (!initialized) return;

    const frame = addr / PAGE_SIZE;
    if (frame < highest_frame and bitmap.isFrameSet(frame)) {
        bitmap.clearFrame(frame);
        free_memory += PAGE_SIZE;
    }
}

pub fn getFreeMemory() u64 {
    return free_memory;
}

pub fn getTotalMemory() u64 {
    return total_memory;
}

/// Allocate multiple contiguous physical frames with alignment
/// count: Number of frames to allocate
/// alignment_frames: Alignment in frames (e.g., 16 frames = 64KB alignment)
/// Returns physical address of first frame, or null if allocation fails
pub fn allocContiguousFrames(count: u64, alignment_frames: u64) ?PhysAddr {
    if (!initialized) return null;
    if (count == 0) return null;

    const start_frame = bitmap.findContiguousFrames(count, alignment_frames) orelse return null;

    // Mark all frames as used
    for (0..count) |offset| {
        bitmap.setFrame(start_frame + offset);
    }

    free_memory -= count * PAGE_SIZE;

    const phys_addr = start_frame * PAGE_SIZE;
    log.debug("allocated {} contiguous frames at 0x{X} ({} KB)", .{
        count,
        phys_addr,
        (count * PAGE_SIZE) / 1024,
    });

    return phys_addr;
}

/// Free multiple contiguous frames
/// addr: Physical address of first frame (must be page-aligned)
/// count: Number of frames to free
pub fn freeContiguousFrames(addr: PhysAddr, count: u64) void {
    if (!initialized) return;
    if (count == 0) return;

    const start_frame = addr / PAGE_SIZE;
    if (start_frame + count > highest_frame) return;

    // Free all frames
    for (0..count) |offset| {
        const frame = start_frame + offset;
        if (bitmap.isFrameSet(frame)) {
            bitmap.clearFrame(frame);
            free_memory += PAGE_SIZE;
        }
    }

    log.debug("freed {} contiguous frames at 0x{X}", .{ count, addr });
}