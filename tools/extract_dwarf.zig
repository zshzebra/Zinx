const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    var input_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, "--input", arg)) {
            i += 1;
            if (i >= args.len) fatal("expected path after --input", .{});
            input_path = args[i];
        } else if (std.mem.eql(u8, "--output-dir", arg)) {
            i += 1;
            if (i >= args.len) fatal("expected path after --output-dir", .{});
            output_dir = args[i];
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    const input = input_path orelse fatal("missing --input", .{});
    const output = output_dir orelse fatal("missing --output-dir", .{});

    try extractDwarfSections(arena, input, output);
}

fn extractDwarfSections(allocator: std.mem.Allocator, elf_path: []const u8, output_dir: []const u8) !void {
    const file = try std.fs.cwd().openFile(elf_path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try allocator.alloc(u8, file_size);
    _ = try file.readAll(buffer);

    if (buffer.len < 64) return error.InvalidElf;
    const elf_header = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, buffer[0..@sizeOf(std.elf.Elf64_Ehdr)]);

    if (!std.mem.eql(u8, elf_header.e_ident[0..4], "\x7fELF")) return error.InvalidElfMagic;

    const section_names = [_][]const u8{
        ".debug_info",
        ".debug_abbrev",
        ".debug_str",
        ".debug_line",
        ".debug_ranges",
    };

    const output_names = [_][]const u8{
        "debug_info.bin",
        "debug_abbrev.bin",
        "debug_str.bin",
        "debug_line.bin",
        "debug_ranges.bin",
    };

    try std.fs.cwd().makePath(output_dir);

    for (section_names, output_names) |section_name, output_name| {
        if (findSection(buffer, elf_header, section_name)) |section_data| {
            const out_path = try std.fs.path.join(allocator, &.{ output_dir, output_name });
            const out_file = try std.fs.cwd().createFile(out_path, .{});
            defer out_file.close();
            try out_file.writeAll(section_data);
            std.debug.print("Extracted {s} ({d} bytes) -> {s}\n", .{ section_name, section_data.len, out_path });
        } else {
            std.debug.print("Warning: {s} not found in ELF\n", .{section_name});
        }
    }
}

fn findSection(buffer: []const u8, elf_header: *align(1) const std.elf.Elf64_Ehdr, name: []const u8) ?[]const u8 {
    const shoff = elf_header.e_shoff;
    const shentsize = elf_header.e_shentsize;
    const shnum = elf_header.e_shnum;
    const shstrndx = elf_header.e_shstrndx;

    if (shstrndx >= shnum) return null;

    const shstrtab_offset = shoff + shstrndx * shentsize;
    const shstrtab_header = std.mem.bytesAsValue(
        std.elf.Elf64_Shdr,
        buffer[shstrtab_offset..][0..@sizeOf(std.elf.Elf64_Shdr)],
    );
    const shstrtab = buffer[shstrtab_header.sh_offset..][0..shstrtab_header.sh_size];

    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const sh_offset = shoff + i * shentsize;
        const sh = std.mem.bytesAsValue(
            std.elf.Elf64_Shdr,
            buffer[sh_offset..][0..@sizeOf(std.elf.Elf64_Shdr)],
        );

        const section_name = std.mem.sliceTo(shstrtab[sh.sh_name..], 0);
        if (std.mem.eql(u8, section_name, name)) {
            return buffer[sh.sh_offset..][0..sh.sh_size];
        }
    }

    return null;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n", args);
    std.process.exit(1);
}
