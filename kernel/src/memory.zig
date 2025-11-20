const std = @import("std");
const limine = @import("limine");
const main = @import("main.zig");

pub const PAGE_SIZE: u64 = 0x1000;
pub const PAGE_SHIFT: u6 = 12;

pub const VirtAddr = u64;
pub const PhysAddr = u64;

pub const MemoryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
};

pub const MemoryRegion = struct {
    base: PhysAddr,
    length: u64,
    type: MemoryType,
};

pub var hhdm_offset: u64 = 0;

pub fn init() !void {
    const hhdm_response = main.hhdm_request.response orelse return error.NoHHDM;
    hhdm_offset = hhdm_response.offset;

    const log = std.log.scoped(.memory);
    log.info("HHDM offset: 0x{X}", .{hhdm_offset});
}

pub fn physToVirt(phys: PhysAddr) VirtAddr {
    return phys + hhdm_offset;
}

pub fn virtToPhys(virt: VirtAddr) PhysAddr {
    return virt - hhdm_offset;
}

pub fn pageAlign(addr: u64) u64 {
    return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

pub fn pageAlignDown(addr: u64) u64 {
    return addr & ~(PAGE_SIZE - 1);
}

var cached_regions: [256]MemoryRegion = undefined;
var cached_count: usize = 0;
var cache_initialized: bool = false;

pub fn getMemoryMap() []MemoryRegion {
    if (cache_initialized) return cached_regions[0..cached_count];

    const memory_map_response = main.memory_map_request.response orelse return &[_]MemoryRegion{};

    for (memory_map_response.getEntries()) |entry| {
        if (cached_count >= cached_regions.len) break;

        const type_value = @intFromEnum(entry.type);
        const mem_type: MemoryType = switch (type_value) {
            0 => .usable,
            1 => .reserved,
            2 => .acpi_reclaimable,
            3 => .acpi_nvs,
            4 => .bad_memory,
            5 => .bootloader_reclaimable,
            6 => .executable_and_modules,
            7 => .framebuffer,
            else => .reserved,
        };

        cached_regions[cached_count] = MemoryRegion{
            .base = entry.base,
            .length = entry.length,
            .type = mem_type,
        };
        cached_count += 1;
    }

    cache_initialized = true;
    return cached_regions[0..cached_count];
}