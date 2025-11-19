const std = @import("std");
const log = std.log.scoped(.pci);
const pci_arch = @import("../../arch/x86_64/pci.zig");
const device = @import("../device.zig");
const Driver = @import("../manager.zig").Driver;
const DriverError = @import("../manager.zig").DriverError;

/// PCI Device Classes
pub const PCI_CLASS_UNCLASSIFIED: u8 = 0x00;
pub const PCI_CLASS_STORAGE: u8 = 0x01;
pub const PCI_CLASS_NETWORK: u8 = 0x02;
pub const PCI_CLASS_DISPLAY: u8 = 0x03;
pub const PCI_CLASS_MULTIMEDIA: u8 = 0x04;
pub const PCI_CLASS_MEMORY: u8 = 0x05;
pub const PCI_CLASS_BRIDGE: u8 = 0x06;
pub const PCI_CLASS_COMMUNICATION: u8 = 0x07;
pub const PCI_CLASS_PERIPHERAL: u8 = 0x08;
pub const PCI_CLASS_INPUT: u8 = 0x09;
pub const PCI_CLASS_DOCKING: u8 = 0x0A;
pub const PCI_CLASS_PROCESSOR: u8 = 0x0B;
pub const PCI_CLASS_SERIAL_BUS: u8 = 0x0C;
pub const PCI_CLASS_WIRELESS: u8 = 0x0D;

/// PCI Serial Bus Subclasses
pub const PCI_SUBCLASS_SERIAL_USB: u8 = 0x03;
pub const PCI_SUBCLASS_SERIAL_FIREWIRE: u8 = 0x00;

/// USB Controller Programming Interfaces
pub const PCI_PROGIF_UHCI: u8 = 0x00; // USB 1.1 (Intel)
pub const PCI_PROGIF_OHCI: u8 = 0x10; // USB 1.1 (Compaq)
pub const PCI_PROGIF_EHCI: u8 = 0x20; // USB 2.0
pub const PCI_PROGIF_XHCI: u8 = 0x30; // USB 3.0

/// PCI Device representation
pub const PCIDevice = struct {
    bus: u8,
    device: u5,
    function: u3,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    header_type: u8,
    interrupt_line: u8,
    bars: [6]u32,

    pub fn format(self: PCIDevice, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "PCI {X:0>2}:{X:0>2}.{X} [{X:0>2}:{X:0>2}] {X:0>4}:{X:0>4} (IRQ {})",
            .{
                self.bus,
                self.device,
                self.function,
                self.class_code,
                self.subclass,
                self.vendor_id,
                self.device_id,
                self.interrupt_line,
            },
        );
    }

    /// Get human-readable device class name
    pub fn getClassName(self: PCIDevice) []const u8 {
        return switch (self.class_code) {
            PCI_CLASS_UNCLASSIFIED => "Unclassified",
            PCI_CLASS_STORAGE => "Storage Controller",
            PCI_CLASS_NETWORK => "Network Controller",
            PCI_CLASS_DISPLAY => "Display Controller",
            PCI_CLASS_MULTIMEDIA => "Multimedia Controller",
            PCI_CLASS_MEMORY => "Memory Controller",
            PCI_CLASS_BRIDGE => "Bridge",
            PCI_CLASS_COMMUNICATION => "Communication Controller",
            PCI_CLASS_PERIPHERAL => "System Peripheral",
            PCI_CLASS_INPUT => "Input Device Controller",
            PCI_CLASS_DOCKING => "Docking Station",
            PCI_CLASS_PROCESSOR => "Processor",
            PCI_CLASS_SERIAL_BUS => "Serial Bus Controller",
            PCI_CLASS_WIRELESS => "Wireless Controller",
            else => "Unknown",
        };
    }

    /// Get USB controller type name
    pub fn getUsbControllerType(self: PCIDevice) ?[]const u8 {
        if (self.class_code != PCI_CLASS_SERIAL_BUS or self.subclass != PCI_SUBCLASS_SERIAL_USB) {
            return null;
        }

        return switch (self.prog_if) {
            PCI_PROGIF_UHCI => "UHCI (USB 1.1)",
            PCI_PROGIF_OHCI => "OHCI (USB 1.1)",
            PCI_PROGIF_EHCI => "EHCI (USB 2.0)",
            PCI_PROGIF_XHCI => "XHCI (USB 3.0)",
            else => "Unknown USB Controller",
        };
    }

    /// Check if this is a USB controller
    pub fn isUsbController(self: PCIDevice) bool {
        return self.class_code == PCI_CLASS_SERIAL_BUS and self.subclass == PCI_SUBCLASS_SERIAL_USB;
    }

    /// Enable bus mastering for DMA
    pub fn enableBusMastering(self: PCIDevice) void {
        var command = pci_arch.configReadU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND);
        command |= pci_arch.PCI_COMMAND_MASTER;
        pci_arch.configWriteU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND, command);
    }

    /// Enable memory space access
    pub fn enableMemorySpace(self: PCIDevice) void {
        var command = pci_arch.configReadU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND);
        command |= pci_arch.PCI_COMMAND_MEMORY;
        pci_arch.configWriteU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND, command);
    }

    /// Enable I/O space access
    pub fn enableIoSpace(self: PCIDevice) void {
        var command = pci_arch.configReadU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND);
        command |= pci_arch.PCI_COMMAND_IO;
        pci_arch.configWriteU16(self.bus, self.device, self.function, pci_arch.PCI_COMMAND, command);
    }
};

/// Read all BARs for a device
fn readBars(bus: u8, dev: u5, func: u3) [6]u32 {
    var bars: [6]u32 = undefined;
    for (0..6) |i| {
        const bar_offset = pci_arch.getBarOffset(@intCast(i));
        bars[i] = pci_arch.configReadU32(bus, dev, func, bar_offset);
    }
    return bars;
}

/// Probe a single PCI function
fn probeFunction(bus: u8, dev: u5, func: u3) !void {
    if (!pci_arch.deviceExists(bus, dev, func)) {
        return;
    }

    const vendor_id = pci_arch.configReadU16(bus, dev, func, pci_arch.PCI_VENDOR_ID);
    const device_id = pci_arch.configReadU16(bus, dev, func, pci_arch.PCI_DEVICE_ID);
    const class_code = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_CLASS_CODE);
    const subclass = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_SUBCLASS);
    const prog_if = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_PROG_IF);
    const revision = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_REVISION_ID);
    const header_type = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_HEADER_TYPE);
    const interrupt_line = pci_arch.configReadU8(bus, dev, func, pci_arch.PCI_INTERRUPT_LINE);
    const bars = readBars(bus, dev, func);

    const pci_device = PCIDevice{
        .bus = bus,
        .device = dev,
        .function = func,
        .vendor_id = vendor_id,
        .device_id = device_id,
        .class_code = class_code,
        .subclass = subclass,
        .prog_if = prog_if,
        .revision = revision,
        .header_type = header_type & pci_arch.PCI_HEADER_TYPE_MASK,
        .interrupt_line = interrupt_line,
        .bars = bars,
    };

    // Log device discovery
    log.info("Found {s}: {any}", .{ pci_device.getClassName(), pci_device });

    // Special logging for USB controllers
    if (pci_device.isUsbController()) {
        if (pci_device.getUsbControllerType()) |usb_type| {
            log.info("  USB Controller Type: {s}", .{usb_type});
        }
    }

    // Register device with device manager
    const dev_metadata = device.DeviceMetadata{
        .PCI = .{
            .vendor_id = vendor_id,
            .device_id = device_id,
            .class_code = class_code,
            .subclass = subclass,
            .bus = bus,
            .device = dev,
            .function = func,
            .bar = bars,
            .irq_line = interrupt_line,
        },
    };

    _ = try device.registerDevice(dev_metadata);
}

/// Probe a single PCI device (may have multiple functions)
fn probeDevice(bus: u8, dev: u5) !void {
    if (!pci_arch.deviceExists(bus, dev, 0)) {
        return;
    }

    // Always probe function 0
    try probeFunction(bus, dev, 0);

    // Check if this is a multifunction device
    if (pci_arch.isMultifunction(bus, dev, 0)) {
        // Probe functions 1-7
        for (1..8) |func| {
            try probeFunction(bus, dev, @intCast(func));
        }
    }
}

/// Probe a single PCI bus
fn probeBus(bus: u8) !void {
    for (0..32) |dev| {
        try probeDevice(bus, @intCast(dev));
    }
}

/// Probe all PCI buses
fn probeAllBuses() !void {
    log.info("Scanning PCI buses...", .{});

    // Scan all 256 possible buses
    for (0..256) |bus| {
        try probeBus(@intCast(bus));
    }

    log.info("PCI scan complete", .{});
}

/// Check if PCI is available (it always is on x86)
fn probe() bool {
    return true;
}

/// Initialize PCI bus and enumerate devices
fn init() DriverError!void {
    probeAllBuses() catch |err| {
        log.err("Failed to probe PCI buses: {}", .{err});
        return DriverError.InitializationFailed;
    };
}

/// Unload PCI bus driver
fn unload() void {
    log.debug("PCI bus driver unloaded", .{});
}

/// PCI Bus Driver (exported for driver manager)
pub const driver = Driver{
    .name = "PCI Bus",
    .capabilities = .{},
    .probe = probe,
    .init = init,
    .unload = unload,
};
