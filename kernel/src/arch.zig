const builtin = @import("builtin");

pub const internals = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/arch.zig"),
    // .aarch64 => @import("arch/aarch64/arch.zig"),
    // .riscv64 => @import("arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};
