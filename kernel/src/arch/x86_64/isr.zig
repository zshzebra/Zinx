const arch = @import("arch.zig");
const interrupts = @import("interrupts.zig");
const idt = @import("idt.zig");
const syscalls = @import("syscalls.zig");
const log = @import("std").log.scoped(.kernel);

pub const IsrError = error{
    InvalidIsr,
    IsrExits,
};

const IsrHandler = fn (*arch.CpuState) *arch.CpuState;

const NUMBER_OF_ENTRIES: u8 = 32;

// Thank you Pluto :)
/// Divide By Zero exception.
pub const DIVIDE_BY_ZERO: u8 = 0;

/// Single Step (Debugger) exception.
pub const SINGLE_STEP_DEBUG: u8 = 1;

/// Non Maskable Interrupt exception.
pub const NON_MASKABLE_INTERRUPT: u8 = 2;

/// Breakpoint (Debugger) exception.
pub const BREAKPOINT_DEBUG: u8 = 3;

/// Overflow exception.
pub const OVERFLOW: u8 = 4;

/// Bound Range Exceeded exception.
pub const BOUND_RANGE_EXCEEDED: u8 = 5;

/// Invalid Opcode exception.
pub const INVALID_OPCODE: u8 = 6;

/// No Coprocessor, Device Not Available exception.
pub const DEVICE_NOT_AVAILABLE: u8 = 7;

/// Double Fault exception.
pub const DOUBLE_FAULT: u8 = 8;

/// Coprocessor Segment Overrun exception.
pub const COPROCESSOR_SEGMENT_OVERRUN: u8 = 9;

/// Invalid Task State Segment (TSS) exception.
pub const INVALID_TASK_STATE_SEGMENT: u8 = 10;

/// Segment Not Present exception.
pub const SEGMENT_NOT_PRESENT: u8 = 11;

/// Stack Segment Overrun exception.
pub const STACK_SEGMENT_FAULT: u8 = 12;

/// General Protection Fault exception.
pub const GENERAL_PROTECTION_FAULT: u8 = 13;

/// Page Fault exception.
pub const PAGE_FAULT: u8 = 14;

/// x87 FPU Floating Point Error exception.
pub const X87_FLOAT_POINT: u8 = 16;

/// Alignment Check exception.
pub const ALIGNMENT_CHECK: u8 = 17;

/// Machine Check exception.
pub const MACHINE_CHECK: u8 = 18;

/// SIMD Floating Point exception.
pub const SIMD_FLOAT_POINT: u8 = 19;

/// Virtualisation exception.
pub const VIRTUALISATION: u8 = 20;

/// Security exception.
pub const SECURITY: u8 = 30;

var isr_handlers: [NUMBER_OF_ENTRIES]?*const IsrHandler = .{null} ** NUMBER_OF_ENTRIES;

var syscall_handler: ?*const IsrHandler = null;

export fn isrHandler(ctx: *arch.CpuState) *arch.CpuState {
    const int_num = ctx.int_num;

    if (isValidIsr(int_num)) {
        if (int_num == syscalls.INTERRUPT) {
            if (syscall_handler) |handler| {
                return handler(ctx);
            } else {
                @panic("No syscall handler is registered");
            }
        } else {
            if (isr_handlers[int_num]) |handler| {
                return handler(ctx);
            } else {
                @panic("ISR not registered");
            }
        }
    } else {
        @panic("Invalid ISR index");
    }
}

fn openIsr(index: u8, handler: idt.InterruptHandler) void {
    idt.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryAlreadyExists => {
            @panic("ISR is already registered");
        },
    };
}

fn isValidIsr(int_num: u64) bool {
    return int_num < NUMBER_OF_ENTRIES or int_num == syscalls.INTERRUPT;
}

pub fn registerIsr(int_num: u16, handler: IsrHandler) IsrError!void {
    if (isValidIsr(int_num)) {
        if (int_num == syscalls.INTERRUPT) {
            if (syscall_handler) |_| {
                return error.IsrExits;
            } else {
                syscall_handler = handler;
            }
        } else {
            if (isr_handlers[int_num]) |_| {
                return error.IsrExits;
            } else {
                isr_handlers[int_num] = handler;
            }
        }
    } else {
        return error.InvalidIsr;
    }
}

fn testHandler(ctx: *arch.CpuState) *arch.CpuState {
    log.debug("int {} called", .{ctx.int_num});
    return ctx;
}

pub fn init() void {
    log.info("init ISR", .{});
    defer log.info("initialized ISR", .{});

    comptime var i = 0;
    inline while (i < 32) : (i += 1) {
        openIsr(i, interrupts.getInterruptStub(i));
    }

    registerIsr(syscalls.INTERRUPT, testHandler) catch |err| {
        log.err("error registering syscall handler: {}", .{err});
    };
    openIsr(syscalls.INTERRUPT, interrupts.getInterruptStub(syscalls.INTERRUPT));
    asm volatile ("int %[int_num]"
        :
        : [int_num] "i" (syscalls.INTERRUPT),
    );
}
