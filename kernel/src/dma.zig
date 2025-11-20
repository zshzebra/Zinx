const std = @import("std");
const pmm = @import("pmm.zig");
const memory = @import("memory.zig");

const VirtAddr = memory.VirtAddr;
const PhysAddr = memory.PhysAddr;
const PAGE_SIZE = memory.PAGE_SIZE;

const log = std.log.scoped(.dma);

/// DMA buffer that tracks both physical and virtual addresses
/// This is critical for XHCI and other DMA-capable devices that need
/// physical addresses for hardware while CPU uses virtual addresses
pub const DMABuffer = struct {
    virt_addr: VirtAddr,
    phys_addr: PhysAddr,
    size: usize,
    pages: usize,

    /// Allocate a DMA buffer of the specified number of pages
    /// The buffer is automatically zero-initialized to prevent leaking data to hardware
    pub fn init(pages: usize) !DMABuffer {
        if (pages == 0) return error.InvalidSize;

        // Allocate the first page
        const first_phys = pmm.allocFrame() orelse return error.OutOfMemory;
        const first_virt = memory.physToVirt(first_phys);

        // For multi-page allocations, we allocate each page separately
        // Note: This does NOT guarantee physical contiguity across pages
        // For true contiguous allocation, we'd need PMM support
        if (pages > 1) {
            // For now, we only support single-page DMA buffers
            // Multi-page support requires contiguous physical memory allocation
            log.warn("Multi-page DMA allocation requested ({} pages), but only single-page is currently guaranteed to work correctly", .{pages});

            // Free the allocated page since we can't fulfill the request properly
            pmm.freeFrame(first_phys);
            return error.ContiguousAllocationNotSupported;
        }

        const total_size = pages * PAGE_SIZE;

        // Zero-initialize the buffer (CRITICAL for security and correctness)
        // Prevents leaking kernel data to DMA-capable hardware
        const ptr: [*]u8 = @ptrFromInt(first_virt);
        @memset(ptr[0..total_size], 0);

        log.debug("Allocated DMA buffer: virt=0x{X}, phys=0x{X}, size={} bytes", .{ first_virt, first_phys, total_size });

        return DMABuffer{
            .virt_addr = first_virt,
            .phys_addr = first_phys,
            .size = total_size,
            .pages = pages,
        };
    }

    /// Free the DMA buffer
    pub fn deinit(self: *DMABuffer) void {
        // For now we only support single-page allocations
        pmm.freeFrame(self.phys_addr);
        log.debug("Freed DMA buffer: phys=0x{X}", .{self.phys_addr});

        self.virt_addr = 0;
        self.phys_addr = 0;
        self.size = 0;
        self.pages = 0;
    }

    /// Get the buffer as a typed slice
    /// This is useful for arrays of structures (like TRBs, contexts, etc.)
    pub fn asSlice(self: *DMABuffer, comptime T: type) []T {
        const count = self.size / @sizeOf(T);
        const ptr: [*]T = @ptrFromInt(self.virt_addr);
        return ptr[0..count];
    }

    /// Get the buffer as a mutable typed slice
    pub fn asSliceMut(self: *DMABuffer, comptime T: type) []T {
        return self.asSlice(T);
    }

    /// Get a pointer to a single element at the start of the buffer
    pub fn asPtr(self: *DMABuffer, comptime T: type) *T {
        return @ptrFromInt(self.virt_addr);
    }

    /// Get a volatile pointer for hardware register access
    pub fn asPtrVolatile(self: *DMABuffer, comptime T: type) *volatile T {
        return @ptrFromInt(self.virt_addr);
    }

    /// Get the physical address (for programming into hardware registers)
    pub fn getPhysAddr(self: *const DMABuffer) PhysAddr {
        return self.phys_addr;
    }

    /// Get the virtual address (for CPU access)
    pub fn getVirtAddr(self: *const DMABuffer) VirtAddr {
        return self.virt_addr;
    }

    /// Zero the entire buffer
    pub fn zero(self: *DMABuffer) void {
        const ptr: [*]u8 = @ptrFromInt(self.virt_addr);
        @memset(ptr[0..self.size], 0);
    }
};

/// Allocate multiple single-page DMA buffers
/// This is useful when you need multiple DMA regions that don't need to be contiguous
/// (e.g., array of device context pointers)
pub fn allocBufferArray(count: usize) ![]DMABuffer {
    // For now, return an error since we don't have a general allocator
    // The caller should allocate a fixed-size array and init each buffer separately
    _ = count;
    return error.NotImplemented;
}

/// Check if an address is DMA-safe (within first 4GB for 32-bit DMA)
/// Some older devices can only DMA to the first 4GB of physical memory
pub fn isDMA32Safe(phys_addr: PhysAddr) bool {
    return phys_addr < 0x1_0000_0000; // 4GB limit
}

/// Check if an address is DMA-safe for 64-bit DMA
pub fn isDMA64Safe(phys_addr: PhysAddr) bool {
    // Modern devices support full 64-bit addressing
    return true;
}
