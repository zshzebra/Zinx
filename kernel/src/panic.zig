const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const embed_dwarf = config.embed_dwarf;

const debug_info_data = if (embed_dwarf) @embedFile("debug_info") else &[_]u8{};
const debug_abbrev_data = if (embed_dwarf) @embedFile("debug_abbrev") else &[_]u8{};
const debug_str_data = if (embed_dwarf) @embedFile("debug_str") else &[_]u8{};
const debug_line_data = if (embed_dwarf) @embedFile("debug_line") else &[_]u8{};
const debug_ranges_data = if (embed_dwarf) @embedFile("debug_ranges") else &[_]u8{};

pub const DebugInfo = struct {
    allocator: std.mem.Allocator,
    elf_module: std.debug.Dwarf.ElfModule,

    pub fn init(allocator: std.mem.Allocator) !DebugInfo {
        const debug_info = debug_info_data;
        const debug_abbrev = debug_abbrev_data;
        const debug_str = debug_str_data;
        const debug_line = debug_line_data;
        const debug_ranges = debug_ranges_data;

        var sections = std.debug.Dwarf.null_section_array;
        sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
            .data = debug_info,
            .virtual_address = @intFromPtr(debug_info.ptr),
            .owned = false,
        };
        sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
            .data = debug_abbrev,
            .virtual_address = @intFromPtr(debug_abbrev.ptr),
            .owned = false,
        };
        sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
            .data = debug_str,
            .virtual_address = @intFromPtr(debug_str.ptr),
            .owned = false,
        };
        sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
            .data = debug_line,
            .virtual_address = @intFromPtr(debug_line.ptr),
            .owned = false,
        };
        sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
            .data = debug_ranges,
            .virtual_address = @intFromPtr(debug_ranges.ptr),
            .owned = false,
        };

        var dwarf: std.debug.Dwarf = .{
            .endian = builtin.cpu.arch.endian(),
            .sections = sections,
            .is_macho = false,
        };
        try dwarf.open(allocator);

        return .{
            .allocator = allocator,
            .elf_module = .{
                .base_address = 0,
                .dwarf = dwarf,
                .mapped_memory = undefined,
                .external_mapped_memory = undefined,
            },
        };
    }

    pub fn deinit(self: *DebugInfo) void {
        self.elf_module.dwarf.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn printStackTrace(self: *DebugInfo, writer: anytype, return_address: usize, frame_address: usize) !void {
        var it = std.debug.StackIterator.init(return_address, frame_address);
        defer it.deinit();

        while (it.next()) |address| {
            const symbol = try self.elf_module.getSymbolAtAddress(self.allocator, address);
            defer if (symbol.source_location) |sl| self.allocator.free(sl.file_name);

            try printLineInfo(writer, symbol.source_location, address, symbol.name, symbol.compile_unit_name);
        }
    }

    fn printLineInfo(
        writer: anytype,
        source_location: ?std.debug.SourceLocation,
        address: usize,
        symbol_name: []const u8,
        compile_unit_name: []const u8,
    ) !void {
        if (source_location) |sl| {
            try writer.print("{s}:{d}:{d}: 0x{X} in {s} ({s})\n", .{
                sl.file_name,
                sl.line,
                sl.column,
                address,
                symbol_name,
                compile_unit_name,
            });
        } else {
            try writer.print("???:?:?: 0x{X} in {s} ({s})\n", .{
                address,
                symbol_name,
                compile_unit_name,
            });
        }
    }
};
