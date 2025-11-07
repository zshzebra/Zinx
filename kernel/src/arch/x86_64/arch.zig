const builtin = @import("builtin");
const idt = @import("idt.zig");
const irq = @import("irq.zig");
const isr = @import("isr.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const keyboard = @import("keyboard.zig");
const serial = @import("serial.zig");
const Serial = @import("../../serial.zig").Serial;
const memory = @import("../../memory.zig");
const pmm = @import("../../pmm.zig");
const vmm = @import("../../vmm.zig");
const allocator = @import("../../allocator.zig");

pub const CpuState = struct {
    // General purpose registers (pushed last by common stub)
    rax: u64,
    rcx: u64,
    rdx: u64,
    rbx: u64,
    rbp: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    // Segment registers
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,

    // Interrupt info (pushed by stub)
    int_num: u64,
    error_code: u64,

    // CPU-pushed state
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn done() noreturn {
    while (true) {
        halt();
    }
}

pub fn spinWait() noreturn {
    enableInterrupts();

    while (true) {
        halt();
    }
}

pub fn loadIdt(idt_ptr: *const idt.IdtPtr) void {
    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (idt_ptr),
    );
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn in(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> T),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("Unsupported type"),
    };
}

pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
            : .{ .memory = true }),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
            : .{ .memory = true }),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
            : .{ .memory = true }),
        else => @compileError("Unsupported type for out"),
    }
}

pub fn ioWait() void {
    out(0x80, @as(u8, 0));
}

/// A common way to initialise the architecture specifics, ie a HAL
pub fn init() void {
    idt.init();
    irq.init();
    isr.init();
    pic.init();
    pit.init();

    keyboard.init();

    initMemory() catch {
        @panic("Failed to initialize memory management");
    };

    // asm volatile ("int $32");
}

fn initMemory() !void {
    try memory.init();
    try pmm.init();
    try vmm.init();
    try allocator.init();
}

pub fn initSerial() Serial {
    serial.init(9600, serial.Port.COM1) catch {
        @panic("Failed to initialize serial");
    };

    return .{
        .write = writeSerialCom1,
    };
}

pub fn millis() u32 {
    return pit.millis();
}

pub fn sleep(ms: u32) void {
    pit.sleep(ms);
}

fn writeSerialCom1(byte: u8) void {
    serial.write(byte, serial.Port.COM1);
}
