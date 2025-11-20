const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64;

    var code_model: std.builtin.CodeModel = .default;
    var linker_script_path: []const u8 = undefined;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    switch (arch) {
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));

            code_model = .kernel;
            linker_script_path = "linker-x86_64.ld";
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));

            linker_script_path = "linker-aarch64.ld";
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));

            linker_script_path = "linker-riscv64.ld";
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.dependency("limine_zig", .{ .api_revision = 3, .allow_deprecated = false, .no_pointers = false });

    const options = b.addOptions();
    options.addOption(bool, "embed_dwarf", false);

    // Build the kernel itself.
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = code_model,
        }),
    });

    // Disable LTO. This prevents Limine requests from being optimized away.
    kernel.want_lto = false;

    // Add Limine as a dependency.
    kernel.root_module.addImport("limine", limine.module("limine"));
    kernel.root_module.addImport("config", options.createModule());

    // Set the linker script.
    kernel.setLinkerScript(.{ .cwd_relative = linker_script_path });

    kernel.addIncludePath(b.path("include"));

    kernel.root_module.addAnonymousImport("VGA9.sfn", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "include/VGA9.sfn" } } });

    const extract_dwarf = b.addExecutable(.{
        .name = "extract_dwarf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../tools/extract_dwarf.zig"),
            .target = b.graph.host,
        }),
    });

    const extract_dwarf_run = b.addRunArtifact(extract_dwarf);
    extract_dwarf_run.addArg("--input");
    extract_dwarf_run.addFileArg(kernel.getEmittedBin());
    extract_dwarf_run.addArg("--output-dir");
    const dwarf_dir = extract_dwarf_run.addOutputDirectoryArg("dwarf");

    const options_final = b.addOptions();
    options_final.addOption(bool, "embed_dwarf", true);

    const kernel_final = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = code_model,
        }),
    });

    kernel_final.want_lto = false;
    kernel_final.root_module.addImport("limine", limine.module("limine"));
    kernel_final.root_module.addImport("config", options_final.createModule());
    kernel_final.setLinkerScript(.{ .cwd_relative = linker_script_path });
    kernel_final.addIncludePath(b.path("include"));
    kernel_final.root_module.addAnonymousImport("VGA9.sfn", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "include/VGA9.sfn" } } });

    kernel_final.root_module.addAnonymousImport("debug_info", .{
        .root_source_file = dwarf_dir.path(b, "debug_info.bin"),
    });
    kernel_final.root_module.addAnonymousImport("debug_abbrev", .{
        .root_source_file = dwarf_dir.path(b, "debug_abbrev.bin"),
    });
    kernel_final.root_module.addAnonymousImport("debug_str", .{
        .root_source_file = dwarf_dir.path(b, "debug_str.bin"),
    });
    kernel_final.root_module.addAnonymousImport("debug_line", .{
        .root_source_file = dwarf_dir.path(b, "debug_line.bin"),
    });
    kernel_final.root_module.addAnonymousImport("debug_ranges", .{
        .root_source_file = dwarf_dir.path(b, "debug_ranges.bin"),
    });

    b.installArtifact(kernel_final);
}
