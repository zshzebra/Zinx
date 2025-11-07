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
    reserved: u3 = 0,
    _unused: u52 = 0,
};

const PageEntry = packed struct {
    flags: PageFlags,
    addr: u52,

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

var kernel_page_table: ?*PageTable = null;

fn allocPageTable() !*PageTable {
    const phys_addr = pmm.allocFrame() orelse return error.OutOfMemory;
    const virt_addr = memory.physToVirt(phys_addr);
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

            const new_table = try allocPageTable();
            entry.setPhysAddr(memory.virtToPhys(@intFromPtr(new_table)));
            entry.flags.present = true;
            entry.flags.writable = true;
        }

        const next_table_phys = entry.getPhysAddr();
        const next_table_virt = memory.physToVirt(next_table_phys);
        current_table = @ptrFromInt(next_table_virt);

        _ = level;
    }

    return current_table.getEntry(indices[3]);
}

pub fn init() !void {
    log.info("virtual memory manager initialized (using limine page tables)", .{});
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
