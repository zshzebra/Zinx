const idt = @import("idt.zig");
const syscalls = @import("syscalls.zig");
const arch = @import("arch.zig");
const irq = @import("irq.zig");
const log = @import("std").log.scoped(.kernel);

extern fn irqHandler(ctx: *arch.CpuState) *arch.CpuState;
extern fn isrHandler(ctx: *arch.CpuState) *arch.CpuState;

export fn handler(ctx: *arch.CpuState) *arch.CpuState {
    // TODO: Add flag to log/not log per interrupt
    if (ctx.int_num != 32) {
        log.debug("Interrupt {d} called with error code: {d}", .{
            ctx.int_num,
            ctx.error_code,
        });
    }

    if (ctx.int_num < irq.IRQ_OFFSET or ctx.int_num == syscalls.INTERRUPT) {
        return isrHandler(ctx);
    } else {
        return irqHandler(ctx);
    }
}

export fn commonStub() callconv(.naked) void {
    asm volatile (
    // Push segment registers
        \\xor %%rax, %%rax
        \\mov %%ds, %%ax
        \\push %%rax
        \\mov %%es, %%ax
        \\push %%rax
        \\mov %%fs, %%ax
        \\push %%rax
        \\mov %%gs, %%ax
        \\push %%rax

        // Save all general purpose registers
        \\push %%r15
        \\push %%r14
        \\push %%r13
        \\push %%r12
        \\push %%r11
        \\push %%r10
        \\push %%r9
        \\push %%r8
        \\push %%rdi
        \\push %%rsi
        \\push %%rbp
        \\push %%rbx
        \\push %%rdx
        \\push %%rcx
        \\push %%rax

        // Call handler
        \\mov %%rsp, %%rdi
        \\call handler

        // Restore GP registers
        \\pop %%rax
        \\pop %%rcx
        \\pop %%rdx
        \\pop %%rbx
        \\pop %%rbp
        \\pop %%rsi
        \\pop %%rdi
        \\pop %%r8
        \\pop %%r9
        \\pop %%r10
        \\pop %%r11
        \\pop %%r12
        \\pop %%r13
        \\pop %%r14
        \\pop %%r15

        // Restore segment registers
        \\pop %%rax
        \\mov %%ax, %%ds
        \\pop %%rax
        \\mov %%ax, %%es
        \\pop %%rax
        \\mov %%ax, %%fs
        \\pop %%rax
        \\mov %%ax, %%gs

        // Skip int_num and error_code
        \\add $16, %%rsp

        // Return from interrupt
        \\iretq
    );
}

pub fn getInterruptStub(comptime interrupt_num: u32) idt.InterruptHandler {
    return struct {
        fn func() callconv(.naked) *arch.CpuState {
            // First, check if we need to push a dummy error code
            if (interrupt_num != 8 and !(interrupt_num >= 10 and interrupt_num <= 14) and interrupt_num != 17) {
                asm volatile (
                    \\ push $0
                );
            }

            // Then push the interrupt number
            asm volatile (
                \\ push %[int_num]
                \\ jmp commonStub
                :
                : [int_num] "i" (interrupt_num),
            );
        }
    }.func;
}
