/// XHCI (USB 3.0) Host Controller Driver
/// Implements the xHCI specification for USB 3.0/3.1 support

const std = @import("std");
const log = std.log.scoped(.xhci);

const device_mod = @import("../device.zig");
const Device = device_mod.Device;
const DeviceMetadata = device_mod.DeviceMetadata;

const manager = @import("../manager.zig");
const DeviceDriver = manager.DeviceDriver;
const MatchQuality = manager.MatchQuality;
const DriverError = manager.DriverError;

const vmm = @import("../../vmm.zig");
const memory = @import("../../memory.zig");
const arch = @import("../../arch/x86_64/arch.zig");
const irq = @import("../../arch/x86_64/irq.zig");
const pci = @import("../buses/pci.zig");

const reg = @import("xhci_registers.zig");
const ring_mod = @import("xhci_ring.zig");
const trb_mod = @import("xhci_trb.zig");

const PAGE_SIZE = memory.PAGE_SIZE;
const PCIDevice = pci.PCIDevice;
const Ring = ring_mod.Ring;
const DCBAA = ring_mod.DCBAA;
const EventRingSegmentTable = ring_mod.EventRingSegmentTable;
const TRB = trb_mod.TRB;
const CompletionCode = trb_mod.CompletionCode;
const CommandCompletionEventTRB = trb_mod.CommandCompletionEventTRB;
const PortStatusChangeEventTRB = trb_mod.PortStatusChangeEventTRB;

/// Maximum number of XHCI controllers supported
const MAX_CONTROLLERS = 4;

/// Controller slot (to avoid heap allocation)
const ControllerSlot = struct {
    controller: XhciController,
    in_use: bool,
};

/// Controller state
var controller_slots: [MAX_CONTROLLERS]ControllerSlot = undefined;
var controller_count: usize = 0;
var controllers_initialized = false;

/// XHCI Controller instance
pub const XhciController = struct {
    /// PCI device information
    pci_device: PCIDevice,

    /// MMIO base physical address
    mmio_phys: u64,

    /// MMIO base virtual address
    mmio_virt: u64,

    /// MMIO size in bytes
    mmio_size: usize,

    /// Capability registers pointer
    cap_regs: *volatile reg.CapabilityRegisters,

    /// Operational registers pointer
    op_regs: *volatile reg.OperationalRegisters,

    /// Runtime registers pointer
    runtime_regs: *volatile reg.RuntimeRegisters,

    /// Interrupter 0 registers
    interrupter_regs: *volatile reg.InterrupterRegisterSet,

    /// Doorbell array pointer
    doorbell_array: [*]volatile u32,

    /// Port register sets
    port_regs: []volatile reg.PortRegisterSet,

    /// Controller capabilities
    max_slots: u8,
    max_ports: u8,
    max_intrs: u16,
    context_size: usize,  // 32 or 64 bytes

    /// Memory structures
    dcbaa: DCBAA,
    command_ring: Ring,
    event_ring: Ring,
    event_ring_segment_table: EventRingSegmentTable,

    /// IRQ line
    irq_line: u8,

    /// Controller is running
    running: bool,

    const Self = @This();

    /// Initialize XHCI controller
    pub fn init(dev: *const Device) !Self {
        const pci_metadata = switch (dev.metadata) {
            .PCI => |p| p,
            else => return DriverError.InitializationFailed,
        };

        log.info("Initializing XHCI controller at PCI {X:0>2}:{X:0>2}.{X}", .{
            pci_metadata.bus,
            pci_metadata.device,
            pci_metadata.function,
        });

        // Create controller structure on stack
        var controller: Self = undefined;

        // Create PCI device handle
        controller.pci_device = PCIDevice{
            .bus = pci_metadata.bus,
            .device = @intCast(pci_metadata.device),
            .function = @intCast(pci_metadata.function),
            .vendor_id = pci_metadata.vendor_id,
            .device_id = pci_metadata.device_id,
            .class_code = pci_metadata.class_code,
            .subclass = pci_metadata.subclass,
            .prog_if = 0x30,  // XHCI
            .revision = 0,
            .header_type = 0,
            .interrupt_line = pci_metadata.irq_line,
            .bars = pci_metadata.bar,
        };

        // Get MMIO base address from BAR0
        const bar0 = pci_metadata.bar[0];
        if ((bar0 & 0x1) != 0) {
            log.err("BAR0 is I/O space, expected memory space", .{});
            return DriverError.InitializationFailed;
        }

        controller.mmio_phys = bar0 & ~@as(u64, 0xF);
        controller.mmio_size = 64 * 1024;  // Assume 64KB, should read from BAR
        controller.irq_line = pci_metadata.irq_line;
        controller.running = false;

        // Map MMIO region to virtual memory
        try controller.mapMMIO();

        // Initialize capability registers
        controller.cap_regs = @ptrFromInt(controller.mmio_virt);

        // Get operational register base
        const op_base = controller.mmio_virt + controller.cap_regs.caplength;
        controller.op_regs = @ptrFromInt(op_base);

        // Get runtime register base
        const runtime_base = controller.mmio_virt + controller.cap_regs.rtsoff;
        controller.runtime_regs = @ptrFromInt(runtime_base);

        // Get interrupter 0 registers
        const interrupter_base = runtime_base + 0x20;
        controller.interrupter_regs = @ptrFromInt(interrupter_base);

        // Get doorbell array base
        const doorbell_base = controller.mmio_virt + controller.cap_regs.dboff;
        controller.doorbell_array = @ptrFromInt(doorbell_base);

        // Parse capabilities
        controller.max_slots = controller.cap_regs.hcsparams1.max_slots;
        controller.max_ports = controller.cap_regs.hcsparams1.max_ports;
        controller.max_intrs = controller.cap_regs.hcsparams1.max_intrs;
        controller.context_size = if (controller.cap_regs.hccparams1.csz == 1) 64 else 32;

        // Get port registers (starting at operational base + 0x400)
        const port_base = op_base + 0x400;
        const port_ptr: [*]volatile reg.PortRegisterSet = @ptrFromInt(port_base);
        controller.port_regs = port_ptr[0..controller.max_ports];

        log.info("XHCI version: {}.{}", .{
            controller.cap_regs.hciversion >> 8,
            controller.cap_regs.hciversion & 0xFF,
        });
        log.info("MaxSlots={}, MaxPorts={}, MaxIntrs={}, ContextSize={} bytes", .{
            controller.max_slots,
            controller.max_ports,
            controller.max_intrs,
            controller.context_size,
        });

        // Enable PCI bus mastering and memory space
        controller.pci_device.enableBusMastering();
        controller.pci_device.enableMemorySpace();

        // Reset controller
        try controller.reset();

        // Allocate memory structures
        try controller.allocateStructures();

        // Set up interrupt handling
        try controller.setupInterrupts();

        // Start controller
        try controller.start();

        // Enumerate ports
        controller.enumeratePorts();

        log.info("XHCI controller initialized successfully", .{});

        return controller;
    }

    /// Map MMIO region to virtual memory
    fn mapMMIO(self: *Self) !void {
        const page_count = (self.mmio_size + PAGE_SIZE - 1) / PAGE_SIZE;

        // Allocate virtual address space
        const virt_addr = try vmm.allocVirtual(page_count);

        // Map with cache_disable for MMIO
        const pml4 = vmm.kernel_page_table orelse return error.NotInitialized;
        const flags = vmm.PageFlags{
            .present = true,
            .writable = true,
            .cache_disable = true,
            .global = true,
        };

        for (0..page_count) |i| {
            try vmm.mapPage(
                pml4,
                virt_addr + (i * PAGE_SIZE),
                self.mmio_phys + (i * PAGE_SIZE),
                flags,
            );
        }

        self.mmio_virt = virt_addr;
        log.debug("Mapped MMIO: phys=0x{X}, virt=0x{X}, size={} KB", .{
            self.mmio_phys,
            self.mmio_virt,
            self.mmio_size / 1024,
        });
    }

    /// Reset the controller
    fn reset(self: *Self) !void {
        log.debug("Resetting controller...", .{});

        // Halt the controller if running
        self.op_regs.usbcmd &= ~reg.USBCMD_RUN_STOP;

        // Wait for controller to halt
        var timeout: u32 = 0;
        while ((self.op_regs.usbsts & reg.USBSTS_HCH) == 0) {
            arch.ioWait();
            timeout += 1;
            if (timeout > 10000) {
                log.err("Timeout waiting for controller to halt", .{});
                return DriverError.InitializationFailed;
            }
        }

        // Reset controller
        self.op_regs.usbcmd |= reg.USBCMD_HCRST;

        // Wait for reset to complete
        timeout = 0;
        while ((self.op_regs.usbcmd & reg.USBCMD_HCRST) != 0) {
            arch.ioWait();
            timeout += 1;
            if (timeout > 500000) {  // 500ms timeout
                log.err("Timeout waiting for controller reset", .{});
                return DriverError.InitializationFailed;
            }
        }

        // Wait for controller to be ready
        timeout = 0;
        while ((self.op_regs.usbsts & reg.USBSTS_CNR) != 0) {
            arch.ioWait();
            timeout += 1;
            if (timeout > 10000) {
                log.err("Timeout waiting for controller ready", .{});
                return DriverError.InitializationFailed;
            }
        }

        log.debug("Controller reset complete", .{});
    }

    /// Allocate memory structures
    fn allocateStructures(self: *Self) !void {
        log.debug("Allocating memory structures...", .{});

        // Allocate DCBAA
        self.dcbaa = try DCBAA.init(self.max_slots);
        self.op_regs.dcbaap = self.dcbaa.getPhysAddr();
        log.debug("DCBAA allocated at 0x{X}", .{self.dcbaa.getPhysAddr()});

        // Allocate Command Ring
        self.command_ring = try Ring.init(256, .Command);
        const cmd_ring_phys = self.command_ring.getPhysAddr() | reg.CRCR_RCS;  // Set RCS bit
        self.op_regs.crcr = cmd_ring_phys;
        log.debug("Command Ring allocated at 0x{X}", .{self.command_ring.getPhysAddr()});

        // Allocate Event Ring Segment Table
        self.event_ring_segment_table = try EventRingSegmentTable.init(1);

        // Allocate Event Ring
        self.event_ring = try Ring.init(256, .Event);
        self.event_ring_segment_table.setEntry(0, &self.event_ring);
        log.debug("Event Ring allocated at 0x{X}", .{self.event_ring.getPhysAddr()});

        // Configure Event Ring
        self.interrupter_regs.erstsz = 1;
        self.interrupter_regs.erstba = self.event_ring_segment_table.getPhysAddr();
        self.interrupter_regs.erdp = self.event_ring.getPhysAddr();

        log.debug("Memory structures allocated successfully", .{});
    }

    /// Set up interrupt handling
    fn setupInterrupts(self: *Self) !void {
        log.debug("Setting up interrupts (IRQ {})...", .{self.irq_line});

        // Register IRQ handler
        try irq.registerIrq(self.irq_line, xhciIrqHandler);

        // Enable interrupter 0
        self.interrupter_regs.iman = reg.IMAN_IE;  // Clear pending, enable interrupts

        // Enable controller interrupts
        self.op_regs.usbcmd |= reg.USBCMD_INTE;

        log.debug("Interrupts enabled", .{});
    }

    /// Start the controller
    fn start(self: *Self) !void {
        log.debug("Starting controller...", .{});

        // Set max device slots enabled
        self.op_regs.config = (self.op_regs.config & ~reg.CONFIG_MAX_SLOTS_MASK) | self.max_slots;

        // Start the controller
        self.op_regs.usbcmd |= reg.USBCMD_RUN_STOP;

        // Wait for controller to start
        var timeout: u32 = 0;
        while ((self.op_regs.usbsts & reg.USBSTS_HCH) != 0) {
            arch.ioWait();
            timeout += 1;
            if (timeout > 10000) {
                log.err("Timeout waiting for controller to start", .{});
                return DriverError.InitializationFailed;
            }
        }

        self.running = true;
        log.info("Controller started successfully", .{});
    }

    /// Enumerate and log all ports
    fn enumeratePorts(self: *Self) void {
        log.info("Enumerating {} ports...", .{self.max_ports});

        for (self.port_regs, 0..) |*port, i| {
            const port_num = i + 1;
            const portsc = port.portsc;

            if ((portsc & reg.PORTSC_CCS) != 0) {
                // Device connected
                const port_speed: u4 = @intCast((portsc >> 10) & 0xF);
                const port_link_state: u4 = @intCast((portsc >> 5) & 0xF);
                const speed_str = reg.portSpeedToString(port_speed);
                const link_state_str = reg.portLinkStateToString(port_link_state);

                log.info("Port {}: Connected - {s}, Link State: {s}", .{
                    port_num,
                    speed_str,
                    link_state_str,
                });

                if ((portsc & reg.PORTSC_PED) != 0) {
                    log.info("  Port {} is enabled", .{port_num});
                } else {
                    log.info("  Port {} is disabled", .{port_num});
                }

                if ((portsc & reg.PORTSC_PR) != 0) {
                    log.info("  Port {} is in reset", .{port_num});
                }

                if ((portsc & reg.PORTSC_PP) != 0) {
                    log.debug("  Port {} power is on", .{port_num});
                }
            } else {
                log.debug("Port {}: Not connected", .{port_num});
            }

            // Clear all change bits (W1C - write 1 to clear)
            const change_bits = reg.PORTSC_CSC | reg.PORTSC_PEC | reg.PORTSC_WRC |
                                reg.PORTSC_OCC | reg.PORTSC_PRC | reg.PORTSC_PLC | reg.PORTSC_CEC;
            port.portsc = portsc | change_bits;
        }
    }

    /// Process event ring (called from IRQ handler)
    fn processEvents(self: *Self) void {
        while (self.event_ring.hasEvents()) {
            const trb = self.event_ring.dequeueTRB() orelse break;
            const trb_type = trb.getTrbType();

            switch (trb_type) {
                .CommandCompletionEvent => {
                    const event = CommandCompletionEventTRB.fromTRB(trb);
                    const code = event.getCompletionCode();
                    log.debug("Command completion: {s}, Slot={}", .{
                        code.toString(),
                        event.slot_id,
                    });
                },
                .PortStatusChangeEvent => {
                    const event = PortStatusChangeEventTRB.fromTRB(trb);
                    log.debug("Port {} status change", .{event.port_id});
                    // Re-enumerate this port
                    if (event.port_id > 0 and event.port_id <= self.max_ports) {
                        const port_index = event.port_id - 1;
                        const portsc = self.port_regs[port_index].portsc;
                        if ((portsc & reg.PORTSC_CCS) != 0) {
                            const port_speed: u4 = @intCast((portsc >> 10) & 0xF);
                            const speed_str = reg.portSpeedToString(port_speed);
                            log.info("Port {}: Device connected - {s}", .{
                                event.port_id,
                                speed_str,
                            });
                        } else {
                            log.info("Port {}: Device disconnected", .{event.port_id});
                        }
                    }
                },
                .TransferEvent => {
                    log.debug("Transfer event received", .{});
                },
                else => {
                    log.warn("Unhandled event type: {}", .{trb_type});
                },
            }
        }

        // Update ERDP to acknowledge processed events
        const erdp = self.event_ring.getDequeuePhysAddr();
        self.interrupter_regs.erdp = erdp;
    }
};

/// IRQ handler for XHCI interrupts
fn xhciIrqHandler(ctx: *arch.CpuState) *arch.CpuState {
    if (!controllers_initialized) return ctx;

    // Find which controller generated the interrupt
    for (&controller_slots) |*slot| {
        if (slot.in_use) {
            // Check if this controller has a pending interrupt
            const usbsts = slot.controller.op_regs.usbsts;
            if ((usbsts & reg.USBSTS_EINT) != 0) {
                // Process events
                slot.controller.processEvents();

                // Clear interrupt pending (write 1 to clear)
                slot.controller.interrupter_regs.iman = reg.IMAN_IP | reg.IMAN_IE;

                // Clear event interrupt in USBSTS (write 1 to clear)
                slot.controller.op_regs.usbsts = reg.USBSTS_EINT;
            }
        }
    }

    return ctx;
}

/// Match XHCI devices (PCI Class 0x0C, Subclass 0x03, ProgIF 0x30)
fn matchDevice(dev: *const Device) ?MatchQuality {
    return switch (dev.metadata) {
        .PCI => |pci_data| {
            if (pci_data.class_code == 0x0C and pci_data.subclass == 0x03 and pci_data.prog_if == 0x30) {
                return .ExactMatch;
            }
            return null;
        },
        else => null,
    };
}

/// Initialize XHCI device driver
fn initDevice(dev: *Device) DriverError!void {
    // Initialize controller slots on first use
    if (!controllers_initialized) {
        for (&controller_slots) |*slot| {
            slot.in_use = false;
        }
        controllers_initialized = true;
    }

    if (controller_count >= MAX_CONTROLLERS) {
        log.err("Maximum number of XHCI controllers reached", .{});
        return DriverError.InitializationFailed;
    }

    const controller = XhciController.init(dev) catch |err| {
        log.err("Failed to initialize XHCI controller: {}", .{err});
        return DriverError.InitializationFailed;
    };

    // Find an empty slot
    for (&controller_slots) |*slot| {
        if (!slot.in_use) {
            slot.controller = controller;
            slot.in_use = true;
            controller_count += 1;
            return;
        }
    }

    log.err("No free controller slots available", .{});
    return DriverError.InitializationFailed;
}

/// Unload XHCI device driver
fn unloadDevice(dev: *Device) void {
    _ = dev;
    log.debug("XHCI device driver unloaded", .{});
}

/// XHCI Device Driver (exported for driver manager)
pub const device_driver = DeviceDriver{
    .name = "XHCI USB 3.0 Host Controller",
    .priority = .Normal,
    .match = matchDevice,
    .init = initDevice,
    .unload = unloadDevice,
};
