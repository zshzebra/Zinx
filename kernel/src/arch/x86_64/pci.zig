const arch = @import("arch.zig");

/// PCI Configuration Space I/O Ports
const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

/// PCI Address Format (32-bit value written to 0xCF8):
/// Bit 31: Enable bit (must be 1)
/// Bits 30-24: Reserved (0)
/// Bits 23-16: Bus number (0-255)
/// Bits 15-11: Device number (0-31)
/// Bits 10-8: Function number (0-7)
/// Bits 7-2: Register offset (0-63, in DWORDS)
/// Bits 1-0: Always 0 (DWORD aligned)

/// Calculate PCI configuration address
fn makeConfigAddress(bus: u8, device: u5, function: u3, offset: u8) u32 {
    const enable_bit: u32 = 1 << 31;
    const bus_bits: u32 = @as(u32, bus) << 16;
    const device_bits: u32 = @as(u32, device) << 11;
    const function_bits: u32 = @as(u32, function) << 8;
    const offset_bits: u32 = @as(u32, offset & 0xFC); // Ensure DWORD alignment

    return enable_bit | bus_bits | device_bits | function_bits | offset_bits;
}

/// Read 32-bit value from PCI configuration space
pub fn configReadU32(bus: u8, device: u5, function: u3, offset: u8) u32 {
    const address = makeConfigAddress(bus, device, function, offset);
    arch.out(PCI_CONFIG_ADDRESS, address);
    return arch.in(u32, PCI_CONFIG_DATA);
}

/// Read 16-bit value from PCI configuration space
pub fn configReadU16(bus: u8, device: u5, function: u3, offset: u8) u16 {
    const dword = configReadU32(bus, device, function, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x02) * 8);
    return @truncate(dword >> shift);
}

/// Read 8-bit value from PCI configuration space
pub fn configReadU8(bus: u8, device: u5, function: u3, offset: u8) u8 {
    const dword = configReadU32(bus, device, function, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x03) * 8);
    return @truncate(dword >> shift);
}

/// Write 32-bit value to PCI configuration space
pub fn configWriteU32(bus: u8, device: u5, function: u3, offset: u8, value: u32) void {
    const address = makeConfigAddress(bus, device, function, offset);
    arch.out(PCI_CONFIG_ADDRESS, address);
    arch.out(PCI_CONFIG_DATA, value);
}

/// Write 16-bit value to PCI configuration space
pub fn configWriteU16(bus: u8, device: u5, function: u3, offset: u8, value: u16) void {
    const offset_aligned = offset & 0xFC;
    const dword = configReadU32(bus, device, function, offset_aligned);
    const shift: u5 = @intCast((offset & 0x02) * 8);
    const mask: u32 = ~(@as(u32, 0xFFFF) << shift);
    const new_value = (dword & mask) | (@as(u32, value) << shift);
    configWriteU32(bus, device, function, offset_aligned, new_value);
}

/// Write 8-bit value to PCI configuration space
pub fn configWriteU8(bus: u8, device: u5, function: u3, offset: u8, value: u8) void {
    const offset_aligned = offset & 0xFC;
    const dword = configReadU32(bus, device, function, offset_aligned);
    const shift: u5 = @intCast((offset & 0x03) * 8);
    const mask: u32 = ~(@as(u32, 0xFF) << shift);
    const new_value = (dword & mask) | (@as(u32, value) << shift);
    configWriteU32(bus, device, function, offset_aligned, new_value);
}

/// PCI Configuration Space Header Offsets
pub const PCI_VENDOR_ID: u8 = 0x00;
pub const PCI_DEVICE_ID: u8 = 0x02;
pub const PCI_COMMAND: u8 = 0x04;
pub const PCI_STATUS: u8 = 0x06;
pub const PCI_REVISION_ID: u8 = 0x08;
pub const PCI_PROG_IF: u8 = 0x09;
pub const PCI_SUBCLASS: u8 = 0x0A;
pub const PCI_CLASS_CODE: u8 = 0x0B;
pub const PCI_CACHE_LINE_SIZE: u8 = 0x0C;
pub const PCI_LATENCY_TIMER: u8 = 0x0D;
pub const PCI_HEADER_TYPE: u8 = 0x0E;
pub const PCI_BIST: u8 = 0x0F;
pub const PCI_BAR0: u8 = 0x10;
pub const PCI_BAR1: u8 = 0x14;
pub const PCI_BAR2: u8 = 0x18;
pub const PCI_BAR3: u8 = 0x1C;
pub const PCI_BAR4: u8 = 0x20;
pub const PCI_BAR5: u8 = 0x24;
pub const PCI_INTERRUPT_LINE: u8 = 0x3C;
pub const PCI_INTERRUPT_PIN: u8 = 0x3D;

/// PCI Command Register Bits
pub const PCI_COMMAND_IO: u16 = 1 << 0; // Enable I/O Space
pub const PCI_COMMAND_MEMORY: u16 = 1 << 1; // Enable Memory Space
pub const PCI_COMMAND_MASTER: u16 = 1 << 2; // Enable Bus Mastering
pub const PCI_COMMAND_INTERRUPT_DISABLE: u16 = 1 << 10; // Disable INTx interrupts

/// PCI Header Type Bits
pub const PCI_HEADER_TYPE_MASK: u8 = 0x7F;
pub const PCI_HEADER_TYPE_MULTIFUNCTION: u8 = 0x80;

/// Check if a PCI device exists at the given location
pub fn deviceExists(bus: u8, device: u5, function: u3) bool {
    const vendor_id = configReadU16(bus, device, function, PCI_VENDOR_ID);
    return vendor_id != 0xFFFF;
}

/// Check if a device is multifunction
pub fn isMultifunction(bus: u8, device: u5, function: u3) bool {
    const header_type = configReadU8(bus, device, function, PCI_HEADER_TYPE);
    return (header_type & PCI_HEADER_TYPE_MULTIFUNCTION) != 0;
}

/// Get BAR register offset for given index (0-5)
pub fn getBarOffset(bar_index: u3) u8 {
    return PCI_BAR0 + (@as(u8, bar_index) * 4);
}
