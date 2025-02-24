const builtin = @import("builtin");
const idt = @import("idt.zig");
const serial = @import("serial.zig");
const Serial = @import("../../serial.zig").Serial;

pub fn halt() void {
    asm volatile ("hlt");
}

pub inline fn done() noreturn {
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
            : "memory" // Clobber list
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
            : "memory"
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
            : "memory"
        ),
        else => @compileError("Unsupported type for out"),
    }
}

pub fn ioWait() void {
    out(0x80, @as(u8, 0));
}

/// A common way to initialise the architecture specifics, ie a HAL
pub fn init() void {
    idt.init();

    asm volatile ("int $0");
}

pub fn initSerial() Serial {
    serial.init(9600, serial.Port.COM1) catch {
        @panic("Failed to initialize serial");
    };

    return .{
        .write = writeSerialCom1,
    };
}

fn writeSerialCom1(byte: u8) void {
    serial.write(byte, serial.Port.COM1);
}
