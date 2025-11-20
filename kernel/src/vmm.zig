const std = @import("std");
const memory = @import("memory.zig");
const pmm = @import("pmm.zig");
const arch = @import("arch.zig").internals;
const log = std.log.scoped(.vmm);

const VirtAddr = memory.VirtAddr;
const PhysAddr = memory.PhysAddr;
const PAGE_SIZE = memory.PAGE_SIZE;

pub const PageFlags = packed struct {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge: bool = false,
    global: bool = false,
    avail: u3 = 0,
};

const PageEntry = packed struct {
    flags: PageFlags,
    addr: u40,
    available: u12 = 0,

    fn getPhysAddr(self: PageEntry) PhysAddr {
        return @as(u64, self.addr) << 12;
    }

    fn setPhysAddr(self: *PageEntry, addr: PhysAddr) void {
        self.addr = @intCast(addr >> 12);
    }
};

const PageTable = struct {
    entries: [512]PageEntry,

    fn getEntry(self: *PageTable, index: u9) *PageEntry {
        return &self.entries[index];
    }
};

pub var kernel_page_table: ?*PageTable = null;

fn allocPageTable() !*PageTable {
    const phys_addr = pmm.allocFrame() orelse return error.OutOfMemory;
    const virt_addr = memory.physToVirt(phys_addr);
    log.debug("allocPageTable: phys=0x{X}, virt=0x{X}", .{ phys_addr, virt_addr });
    const page_table: *PageTable = @ptrFromInt(virt_addr);
    @memset(@as([*]u8, @ptrCast(page_table))[0..PAGE_SIZE], 0);
    return page_table;
}

fn walkPageTable(pml4: *PageTable, virt_addr: VirtAddr, allocate: bool) !?*PageEntry {
    const indices = [4]u9{
        @intCast((virt_addr >> 39) & 0x1FF),
        @intCast((virt_addr >> 30) & 0x1FF),
        @intCast((virt_addr >> 21) & 0x1FF),
        @intCast((virt_addr >> 12) & 0x1FF),
    };

    var current_table = pml4;

    for (indices[0..3], 0..) |index, level| {
        const entry = current_table.getEntry(index);

        if (!entry.flags.present) {
            if (!allocate) return null;

            log.debug("walkPageTable: allocating new table at level {d}", .{level});
            const new_table = try allocPageTable();
            entry.setPhysAddr(memory.virtToPhys(@intFromPtr(new_table)));
            entry.flags.present = true;
            entry.flags.writable = true;
        }

        const next_table_phys = entry.getPhysAddr();
        const next_table_virt = memory.physToVirt(next_table_phys);
        current_table = @ptrFromInt(next_table_virt);
    }

    return current_table.getEntry(indices[3]);
}

pub fn init() !void {
    const cr3_value = arch.getCR3();
    const cr3_phys = cr3_value & 0xFFFFFFFFFF000; // Mask out lower 12 bits (flags)
    const cr3_virt = memory.physToVirt(cr3_phys);
    kernel_page_table = @ptrFromInt(cr3_virt);
    log.info("VMM initialized with PML4 at phys=0x{X}, virt=0x{X}", .{ cr3_phys, cr3_virt });
}

pub fn mapPage(pml4: *PageTable, virt_addr: VirtAddr, phys_addr: PhysAddr, flags: PageFlags) !void {
    const entry = try walkPageTable(pml4, virt_addr, true) orelse return error.PageTableWalk;

    if (entry.flags.present) {
        return error.PageAlreadyMapped;
    }

    entry.setPhysAddr(phys_addr);
    entry.flags = flags;

    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt_addr),
        : .{ .memory = true }
    );
}

/// Map a page with cache disabled for device MMIO
/// This is CRITICAL for preventing hardware corruption (e.g., framebuffer, USB controller registers)
/// Without this, CPU cache can corrupt device registers and vice versa
pub fn mapPageUncached(pml4: *PageTable, virt_addr: VirtAddr, phys_addr: PhysAddr, flags: PageFlags) !void {
    var device_flags = flags;
    device_flags.cache_disable = true; // Disable caching for device MMIO
    device_flags.write_through = true; // Enable write-through for safety
    try mapPage(pml4, virt_addr, phys_addr, device_flags);
}

/// Map multiple contiguous pages with cache disabled for device MMIO
/// This is used for mapping device BARs (Base Address Registers)
pub fn mapPagesUncached(pml4: *PageTable, virt_addr: VirtAddr, phys_addr: PhysAddr, page_count: usize, flags: PageFlags) !void {
    for (0..page_count) |i| {
        const page_virt = virt_addr + (i * memory.PAGE_SIZE);
        const page_phys = phys_addr + (i * memory.PAGE_SIZE);
        try mapPageUncached(pml4, page_virt, page_phys, flags);
    }
}

pub fn unmapPage(pml4: *PageTable, virt_addr: VirtAddr) !void {
    const entry = try walkPageTable(pml4, virt_addr, false) orelse return error.PageNotMapped;

    if (!entry.flags.present) {
        return error.PageNotMapped;
    }

    @memset(@as([*]u8, @ptrCast(entry))[0..@sizeOf(PageEntry)], 0);

    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt_addr),
        : .{ .memory = true }
    );
}

fn switchPageTable() void {
    if (kernel_page_table) |pml4| {
        const phys_addr = memory.virtToPhys(@intFromPtr(pml4));
        asm volatile ("mov %[addr], %%cr3"
            :
            : [addr] "r" (phys_addr),
            : .{ .memory = true }
        );
    }
}

pub fn allocVirtual(pages: u64) !VirtAddr {
    const start_addr: u64 = 0xFFFF800000000000;
    const end_addr: u64 = 0xFFFFFFFF80000000;

    var addr: u64 = start_addr;
    while (addr < end_addr) {
        var found = true;
        for (0..pages) |i| {
            const check_addr = addr + (i * PAGE_SIZE);
            if (walkPageTable(kernel_page_table.?, check_addr, false) catch null) |entry| {
                if (entry.flags.present) {
                    found = false;
                    break;
                }
            }
        }

        if (found) {
            for (0..pages) |i| {
                const page_addr = addr + (i * PAGE_SIZE);
                const phys_addr = pmm.allocFrame() orelse return error.OutOfMemory;
                try mapPage(kernel_page_table.?, page_addr, phys_addr, PageFlags{
                    .present = true,
                    .writable = true,
                    .global = true,
                });
            }
            return addr;
        }

        addr += PAGE_SIZE;
    }

    return error.OutOfVirtualMemory;
}

pub fn freeVirtual(addr: VirtAddr, pages: u64) void {
    for (0..pages) |i| {
        const page_addr = addr + (i * PAGE_SIZE);
        if (walkPageTable(kernel_page_table.?, page_addr, false) catch null) |entry| {
            if (entry.flags.present) {
                const phys_addr = entry.getPhysAddr();
                pmm.freeFrame(phys_addr);
                unmapPage(kernel_page_table.?, page_addr) catch {};
            }
        }
    }
}
