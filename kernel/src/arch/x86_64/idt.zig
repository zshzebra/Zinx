const arch = @import("arch.zig");
const log = @import("std").log.scoped(.kernel);
const main = @import("../../main.zig");
const interrupts = @import("interrupts.zig");

pub const IdtEntry = packed struct {
    /// The lower 16 bits of the offset
    base_low: u16,

    /// The code segment in the GDT which the handlers will be held
    selector: u16,

    /// First 3 bits are an offset into the IST, other bits are 0. If the offset is 0, then the IST is not used.
    ist: u8,

    /// The type of gate.
    /// 0b1110 -> 64-bit interrupt gate
    /// 0b1111 -> 64-bit trap gate
    gate_type: u4,

    /// Must be 0 for 64-bit interrupt gates
    storage: u1,

    /// Privilege level of the gate_type
    dpl: u2,

    /// Present bits
    present: u1,

    /// The middle 16 bits of the offset
    base_mid: u16,

    /// The high 32 bits of the offset
    base_high: u32,

    /// Must be 0
    reserved: u32,
};

pub const IdtPtr = packed struct {
    /// The total limit of the IDT (minus 1) in bytes
    limit: u16,
    /// The base address of the IDT
    base: u64,
};

pub const InterruptHandler = *const fn () callconv(.Naked) *arch.CpuState;

// ----------
// Task gates
// ----------

/// The base addresses aren't used, so set these to 0. When a interrupt happens, interrupts are not
/// automatically disabled. This is used for referencing the TSS descriptor in the GDT.
const TASK_GATE: u4 = 0x5;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are
/// automatically disabled then enabled upon the IRET instruction which restores the saved EFLAGS.
const INTERRUPT_GATE: u4 = 0xE;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are not
/// automatically disabled and doesn't restores the saved EFLAGS upon the IRET instruction.
const TRAP_GATE: u4 = 0xF;

// ----------
// Privilege levels
// ----------

/// Privilege level 0. Kernel land. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_0: u2 = 0x0;

/// Privilege level 1. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_1: u2 = 0x1;

/// Privilege level 2. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_2: u2 = 0x2;

/// Privilege level 3. User land. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_3: u2 = 0x3;

/// The total size of all the IDT entries (minus 1).
const TABLE_SIZE: u16 = @sizeOf(IdtEntry) * NUMBER_OF_ENTRIES - 1;

/// The total number of entries the IDT can have (2^8).
pub const NUMBER_OF_ENTRIES: u16 = 256;

pub const IdtError = error{
    IdtEntryAlreadyExists,
};

/// The IDT pointer that the CPU is loaded with that contains the base address of the IDT and the
/// size.
var idt_ptr: IdtPtr = IdtPtr{
    .limit = TABLE_SIZE,
    .base = 0,
};

var idt_entries: [NUMBER_OF_ENTRIES]IdtEntry = [_]IdtEntry{.{
    .base_low = 0,
    .selector = 0,
    .ist = 0,
    .gate_type = 0,
    .storage = 0,
    .dpl = 0,
    .present = 0,
    .base_mid = 0,
    .base_high = 0,
    .reserved = 0,
}} ** NUMBER_OF_ENTRIES;

fn makeEntry(base: u64, selector: u16, ist: u3, gate_type: u4, privilege: u2) IdtEntry {
    return .{
        .base_low = @truncate(base),
        .selector = selector,
        .ist = ist,
        .gate_type = gate_type,
        .storage = 0,
        .dpl = privilege,
        .present = 1,
        .base_mid = @truncate(base >> 16),
        .base_high = @truncate(base >> 32),
        .reserved = 0,
    };
}

pub fn isIdtOpen(entry: IdtEntry) bool {
    return entry.present == 1;
}

pub fn openInterruptGate(index: u8, handler: InterruptHandler) IdtError!void {
    if (isIdtOpen(idt_entries[index])) {
        return error.IdtEntryAlreadyExists;
    }

    idt_entries[index] = makeEntry(@intFromPtr(handler), 0x28, 0, INTERRUPT_GATE, PRIVILEGE_RING_0);
}

pub fn init() void {
    idt_ptr.base = @intFromPtr(&idt_entries);

    arch.loadIdt(&idt_ptr);

    arch.enableInterrupts();
}
