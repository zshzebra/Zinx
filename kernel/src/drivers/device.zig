const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.device_manager);

pub const BusType = enum {
    ATA,
    PCI,
    USB,
};

pub const DeviceMetadata = union(BusType) {
    ATA: struct {
        channel: enum { Primary, Secondary },
        drive: enum { Master, Slave },
        sectors: u64,
        model: [40]u8,
        supports_lba48: bool,
        supports_dma: bool,
    },
    PCI: struct {
        vendor_id: u16,
        device_id: u16,
        class_code: u8,
        subclass: u8,
        bus: u8,
        device: u8,
        function: u8,
        bar: [6]u32,
        irq_line: u8,
    },
    USB: struct {
        vendor_id: u16,
        product_id: u16,
        device_class: u8,
        port: u8,
    },
};

pub const Device = struct {
    id: u32,
    metadata: DeviceMetadata,
    bound_driver: ?*const anyopaque = null,
};

var device_list: std.ArrayList(Device) = undefined;
var device_allocator: Allocator = undefined;
var next_device_id: u32 = 0;
var initialized = false;

pub fn init(allocator: Allocator) !void {
    if (initialized) return;

    device_allocator = allocator;
    device_list = std.ArrayList(Device).empty;
    next_device_id = 0;
    initialized = true;

    log.debug("device manager initialized", .{});
}

pub fn registerDevice(metadata: DeviceMetadata) !*Device {
    if (!initialized) return error.NotInitialized;

    const device = Device{
        .id = next_device_id,
        .metadata = metadata,
    };
    next_device_id += 1;

    try device_list.append(device_allocator, device);
    return &device_list.items[device_list.items.len - 1];
}

pub fn getDevices() []Device {
    if (!initialized) return &[_]Device{};
    return device_list.items;
}

pub fn getDevice(id: u32) ?*Device {
    if (!initialized) return null;

    for (device_list.items) |*device| {
        if (device.id == id) return device;
    }
    return null;
}

pub fn deinit() void {
    if (!initialized) return;

    device_list.deinit(device_allocator);
    initialized = false;
}
