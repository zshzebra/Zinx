const std = @import("std");
const log = std.log.scoped(.ata_pio);
const arch = @import("../../arch.zig").internals;
const DeviceDriver = @import("../manager.zig").DeviceDriver;
const MatchQuality = @import("../manager.zig").MatchQuality;
const DriverPriority = @import("../manager.zig").DriverPriority;
const DriverError = @import("../manager.zig").DriverError;
const BlockDeviceInterface = @import("../manager.zig").BlockDeviceInterface;
const device_mgr = @import("../device.zig");
const Device = device_mgr.Device;
const driver_mgr = @import("../manager.zig");

pub const device_driver = DeviceDriver{
    .name = "ATA PIO Driver",
    .priority = .Fallback,
    .match = matchDevice,
    .init = initDevice,
    .unload = unloadDevice,
    .block_device_interface = &block_interface,
};

const block_interface = BlockDeviceInterface{
    .read = readSectors,
    .write = writeSectors,
    .get_sector_size = getSectorSize,
    .get_sector_count = getSectorCount,
};

fn matchDevice(device: *const Device) ?MatchQuality {
    return switch (device.metadata) {
        .ATA => .Generic,
        else => null,
    };
}

fn initDevice(device: *Device) DriverError!void {
    const ata_meta = device.metadata.ATA;

    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "ata{d}", .{device.id}) catch "ata?";

    const block_id = driver_mgr.registerBlockDevice(name, device, &block_interface) catch {
        return DriverError.InitializationFailed;
    };

    const size_mb = (ata_meta.sectors * 512) / (1024 * 1024);
    log.info("initialized PIO driver for {s}: {d} MB", .{name, size_mb});

    _ = block_id;
}

fn unloadDevice(device: *Device) void {
    log.debug("unloading PIO driver for device {d}", .{device.id});
}

fn getBasePort(device: *const Device) u16 {
    const ata_meta = device.metadata.ATA;
    return switch (ata_meta.channel) {
        .Primary => 0x1F0,
        .Secondary => 0x170,
    };
}

fn getDriveSelect(device: *const Device) u8 {
    const ata_meta = device.metadata.ATA;
    return switch (ata_meta.drive) {
        .Master => 0xE0,
        .Slave => 0xF0,
    };
}

fn waitBusy(base: u16) void {
    var timeout: u32 = 0;
    while (timeout < 1000000) : (timeout += 1) {
        const status = arch.in(u8, base + 7);
        if ((status & 0x80) == 0) return;
    }
}

fn waitReady(base: u16) bool {
    var timeout: u32 = 0;
    while (timeout < 1000000) : (timeout += 1) {
        const status = arch.in(u8, base + 7);
        if ((status & 0x80) == 0 and (status & 0x08) != 0) {
            return true;
        }
    }
    return false;
}

fn readSectors(device: *Device, lba: u64, count: u32, buffer: []u8) DriverError!void {
    if (buffer.len < count * 512) {
        return DriverError.InitializationFailed;
    }

    const base = getBasePort(device);
    const drive_select = getDriveSelect(device);

    for (0..count) |i| {
        const current_lba = lba + i;
        const buf_offset = i * 512;

        waitBusy(base);

        arch.out(base + 6, drive_select | @as(u8, @truncate((current_lba >> 24) & 0x0F)));
        arch.out(base + 2, @as(u8, 1));
        arch.out(base + 3, @as(u8, @truncate(current_lba & 0xFF)));
        arch.out(base + 4, @as(u8, @truncate((current_lba >> 8) & 0xFF)));
        arch.out(base + 5, @as(u8, @truncate((current_lba >> 16) & 0xFF)));
        arch.out(base + 7, @as(u8, 0x20));

        if (!waitReady(base)) {
            log.err("timeout waiting for data on sector {d}", .{current_lba});
            return DriverError.InitializationFailed;
        }

        var word_ptr = @as([*]u16, @ptrCast(@alignCast(&buffer[buf_offset])));
        for (0..256) |j| {
            word_ptr[j] = arch.in(u16, base);
        }
    }
}

fn writeSectors(device: *Device, lba: u64, count: u32, buffer: []const u8) DriverError!void {
    if (buffer.len < count * 512) {
        return DriverError.InitializationFailed;
    }

    const base = getBasePort(device);
    const drive_select = getDriveSelect(device);

    for (0..count) |i| {
        const current_lba = lba + i;
        const buf_offset = i * 512;

        waitBusy(base);

        arch.out(base + 6, drive_select | @as(u8, @truncate((current_lba >> 24) & 0x0F)));
        arch.out(base + 2, @as(u8, 1));
        arch.out(base + 3, @as(u8, @truncate(current_lba & 0xFF)));
        arch.out(base + 4, @as(u8, @truncate((current_lba >> 8) & 0xFF)));
        arch.out(base + 5, @as(u8, @truncate((current_lba >> 16) & 0xFF)));
        arch.out(base + 7, @as(u8, 0x30));

        if (!waitReady(base)) {
            log.err("timeout waiting to write sector {d}", .{current_lba});
            return DriverError.InitializationFailed;
        }

        const word_ptr = @as([*]const u16, @ptrCast(@alignCast(&buffer[buf_offset])));
        for (0..256) |j| {
            arch.out(base, word_ptr[j]);
        }

        arch.out(base + 7, @as(u8, 0xE7));
        waitBusy(base);
    }
}

fn getSectorSize(device: *Device) u32 {
    _ = device;
    return 512;
}

fn getSectorCount(device: *Device) u64 {
    return device.metadata.ATA.sectors;
}
