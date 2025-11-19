const std = @import("std");
const memory = @import("memory.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const log = std.log.scoped(.dma);

const VirtAddr = memory.VirtAddr;
const PhysAddr = memory.PhysAddr;
const PAGE_SIZE = memory.PAGE_SIZE;

/// DMA region representing a physically contiguous memory allocation
pub const DmaRegion = struct {
    virt_addr: VirtAddr,
    phys_addr: PhysAddr,
    size: usize,
    page_count: usize,

    /// Get physical address at offset within this region
    pub fn getPhysAddr(self: DmaRegion, offset: usize) ?PhysAddr {
        if (offset >= self.size) return null;
        return self.phys_addr + offset;
    }

    /// Get virtual address at offset within this region
    pub fn getVirtAddr(self: DmaRegion, offset: usize) ?VirtAddr {
        if (offset >= self.size) return null;
        return self.virt_addr + offset;
    }

    /// Get pointer to region memory
    pub fn asPtr(self: DmaRegion, comptime T: type) *T {
        return @ptrFromInt(self.virt_addr);
    }

    /// Get slice of region memory
    pub fn asSlice(self: DmaRegion, comptime T: type) []T {
        const ptr: [*]T = @ptrFromInt(self.virt_addr);
        return ptr[0..(self.size / @sizeOf(T))];
    }

    /// Zero out the entire region
    pub fn zero(self: DmaRegion) void {
        const ptr: [*]u8 = @ptrFromInt(self.virt_addr);
        @memset(ptr[0..self.size], 0);
    }
};

pub const DmaError = error{
    OutOfMemory,
    NoContiguousRegion,
    InvalidAlignment,
    InvalidSize,
    NotInitialized,
    MapFailed,
};

var initialized = false;

/// Initialize DMA subsystem
pub fn init() !void {
    if (initialized) return;

    log.info("initializing DMA allocator", .{});
    initialized = true;
    log.info("DMA allocator initialized", .{});
}

/// Allocate DMA-capable memory region
/// size: Size in bytes
/// alignment: Alignment requirement in bytes (must be power of 2)
/// Returns DmaRegion with both virtual and physical addresses
pub fn allocDma(size: usize, alignment: usize) DmaError!DmaRegion {
    if (!initialized) return DmaError.NotInitialized;
    if (size == 0) return DmaError.InvalidSize;

    // Validate alignment is power of 2
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
        return DmaError.InvalidAlignment;
    }

    // Calculate pages needed (round up)
    const page_count = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    // Calculate alignment in frames
    const alignment_frames = if (alignment < PAGE_SIZE)
        1
    else
        alignment / PAGE_SIZE;

    // Allocate physically contiguous frames
    const phys_addr = pmm.allocContiguousFrames(page_count, alignment_frames) orelse {
        log.err("failed to allocate {} contiguous frames (alignment: {})", .{ page_count, alignment_frames });
        return DmaError.NoContiguousRegion;
    };

    // Find virtual address space
    const virt_addr = vmm.allocVirtual(page_count) catch |err| {
        // Failed to allocate virtual space, free physical frames
        pmm.freeContiguousFrames(phys_addr, page_count);
        log.err("failed to allocate virtual address space: {}", .{err});
        return DmaError.OutOfMemory;
    };

    // Map physical pages to virtual addresses with DMA-appropriate flags
    const pml4 = vmm.kernel_page_table orelse {
        pmm.freeContiguousFrames(phys_addr, page_count);
        return DmaError.NotInitialized;
    };

    const flags = vmm.PageFlags{
        .present = true,
        .writable = true,
        .cache_disable = true, // Critical for DMA coherency
        .global = true,
    };

    // Map each page
    for (0..page_count) |i| {
        const page_virt = virt_addr + (i * PAGE_SIZE);
        const page_phys = phys_addr + (i * PAGE_SIZE);

        vmm.mapPage(pml4, page_virt, page_phys, flags) catch |err| {
            // Unmap already mapped pages and free memory
            for (0..i) |j| {
                const unmap_virt = virt_addr + (j * PAGE_SIZE);
                vmm.unmapPage(pml4, unmap_virt) catch {};
            }
            pmm.freeContiguousFrames(phys_addr, page_count);
            log.err("failed to map page {}: {}", .{ i, err });
            return DmaError.MapFailed;
        };
    }

    const region = DmaRegion{
        .virt_addr = virt_addr,
        .phys_addr = phys_addr,
        .size = page_count * PAGE_SIZE,
        .page_count = page_count,
    };

    log.debug("allocated DMA region: virt=0x{X}, phys=0x{X}, size={} KB", .{
        virt_addr,
        phys_addr,
        (page_count * PAGE_SIZE) / 1024,
    });

    return region;
}

/// Free DMA region
pub fn freeDma(region: DmaRegion) void {
    if (!initialized) return;
    if (region.page_count == 0) return;

    const pml4 = vmm.kernel_page_table orelse return;

    // Unmap all pages
    for (0..region.page_count) |i| {
        const page_virt = region.virt_addr + (i * PAGE_SIZE);
        vmm.unmapPage(pml4, page_virt) catch |err| {
            log.warn("failed to unmap page {} during DMA free: {}", .{ i, err });
        };
    }

    // Free physical frames
    pmm.freeContiguousFrames(region.phys_addr, region.page_count);

    log.debug("freed DMA region: virt=0x{X}, phys=0x{X}, {} pages", .{
        region.virt_addr,
        region.phys_addr,
        region.page_count,
    });
}

/// Allocate DMA region with page granularity
/// pages: Number of pages to allocate
/// alignment: Alignment in bytes (must be power of 2, >= PAGE_SIZE)
pub fn allocDmaPages(pages: usize, alignment: usize) DmaError!DmaRegion {
    return allocDma(pages * PAGE_SIZE, alignment);
}

/// Helper: Allocate XHCI ring buffer (page-aligned)
/// trb_count: Number of TRBs (Transfer Request Blocks), each is 16 bytes
pub fn allocXhciRing(trb_count: usize) DmaError!DmaRegion {
    const size = trb_count * 16; // 16 bytes per TRB
    return allocDma(size, PAGE_SIZE);
}

/// Helper: Allocate XHCI device context (64-byte aligned)
/// context_size: Size of context in bytes (typically 32, 64, or 1024)
pub fn allocXhciContext(context_size: usize) DmaError!DmaRegion {
    return allocDma(context_size, 64);
}

/// Helper: Allocate XHCI scratchpad buffer (page-aligned)
pub fn allocXhciScratchpad() DmaError!DmaRegion {
    return allocDmaPages(1, PAGE_SIZE);
}
