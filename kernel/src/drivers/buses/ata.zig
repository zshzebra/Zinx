const std = @import("std");
const log = std.log.scoped(.ata);
const arch = @import("../../arch.zig").internals;
const Driver = @import("../manager.zig").Driver;
const DriverError = @import("../manager.zig").DriverError;
const device_mgr = @import("../device.zig");

pub const driver = Driver{
    .name = "ATA Bus Controller",
    .capabilities = .{},
    .probe = probe,
    .init = init,
    .unload = unload,
};

const Channel = enum(u16) {
    Primary = 0x1F0,
    Secondary = 0x170,

    pub fn toInt(self: Channel) u16 {
        return @intFromEnum(self);
    }
};

const Drive = enum(u8) {
    Master = 0xA0,
    Slave = 0xB0,

    pub fn toInt(self: Drive) u8 {
        return @intFromEnum(self);
    }
};

const AtaIdentifyData = extern struct {
    config: u16,
    cylinders: u16,
    _reserved1: u16,
    heads: u16,
    _obsolete1: [2]u16,
    sectors_per_track: u16,
    _vendor: [3]u16,
    serial: [20]u8,
    _obsolete2: [2]u16,
    _obsolete3: u16,
    firmware: [8]u8,
    model: [40]u8,
    _rw_multiple: u16,
    _dword_io: u16,
    capabilities: u16,
    _reserved2: u16,
    _obsolete4: [2]u16,
    _valid_fields: u16,
    _obsolete5: [5]u16,
    _rw_multiple_current: u16,
    lba_sectors: u32,
    _obsolete6: u16,
    _multiword_dma: u16,
    _pio_modes: u16,
    _min_multiword_dma: u16,
    _rec_multiword_dma: u16,
    _min_pio: u16,
    _min_pio_iordy: u16,
    _additional_supported: u16,
    _reserved3: u16,
    _reserved4: [4]u16,
    _queue_depth: u16,
    _serial_ata_caps: u16,
    _serial_ata_additional: u16,
    _serial_ata_features_supported: u16,
    _serial_ata_features_enabled: u16,
    major_version: u16,
    minor_version: u16,
    command_set_supported: [3]u16,
    command_set_enabled: [3]u16,
    _ultra_dma: u16,
    _reserved5: [11]u16,
    lba48_sectors: u64,
    _reserved6: [152]u16,
};

fn probe() bool {
    const base = Channel.Primary.toInt();
    const status = arch.in(u8, base + 7);
    return status != 0xFF;
}

fn init() DriverError!void {
    log.info("enumerating ATA devices", .{});

    var found_count: u32 = 0;

    // Try all 4 positions
    const channels = [_]Channel{ .Primary, .Secondary };
    const drives = [_]Drive{ .Master, .Slave };

    for (channels) |channel| {
        for (drives) |drive| {
            if (identifyDevice(channel, drive)) |info| {
                registerAtaDevice(channel, drive, info) catch |err| {
                    log.err("failed to register ATA device on channel {s} drive {s}: {}", .{
                        @tagName(channel),
                        @tagName(drive),
                        err,
                    });
                    continue;
                };
                found_count += 1;
            }
        }
    }

    if (found_count == 0) {
        log.warn("no ATA devices found", .{});
    }
}

fn unload() void {
    // No cleanup needed for bus controller
    log.debug("ATA bus controller unloaded", .{});
}

fn identifyDevice(channel: Channel, drive: Drive) ?AtaIdentifyData {
    const base = channel.toInt();

    // Select drive
    arch.out(base + 6, drive.toInt());

    // Small delay for drive selection
    for (0..4) |_| {
        _ = arch.in(u8, base + 7);
    }

    // Set parameters for IDENTIFY
    arch.out(base + 2, @as(u8, 0)); // Sector count = 0
    arch.out(base + 3, @as(u8, 0)); // LBA low = 0
    arch.out(base + 4, @as(u8, 0)); // LBA mid = 0
    arch.out(base + 5, @as(u8, 0)); // LBA high = 0

    // Send IDENTIFY command
    arch.out(base + 7, @as(u8, 0xEC));

    // Read status
    const status = arch.in(u8, base + 7);

    // If status is 0, no device exists
    if (status == 0) {
        return null;
    }

    // Poll until BSY clears
    var timeout: u32 = 0;
    while (true) : (timeout += 1) {
        const current_status = arch.in(u8, base + 7);

        // Check for timeout
        if (timeout > 1000000) {
            log.debug("timeout waiting for device on channel {s} drive {s}", .{
                @tagName(channel),
                @tagName(drive),
            });
            return null;
        }

        // Check if BSY cleared
        if ((current_status & 0x80) == 0) {
            break;
        }
    }

    // Check for errors
    const final_status = arch.in(u8, base + 7);
    if ((final_status & 0x01) != 0) {
        // Error bit set
        return null;
    }

    // Wait for DRQ (data request) to be set
    timeout = 0;
    while (true) : (timeout += 1) {
        const current_status = arch.in(u8, base + 7);

        if (timeout > 1000000) {
            return null;
        }

        if ((current_status & 0x08) != 0) {
            break;
        }
    }

    // Read 256 words (512 bytes) of identify data
    var data: AtaIdentifyData = undefined;
    var ptr = @as([*]u16, @ptrCast(&data));

    for (0..256) |i| {
        ptr[i] = arch.in(u16, base);
    }

    return data;
}

fn registerAtaDevice(channel: Channel, drive: Drive, info: AtaIdentifyData) !void {
    // Extract sector count (prefer LBA48 if supported)
    const lba48_supported = (info.command_set_supported[1] & (1 << 10)) != 0;
    const sectors = if (lba48_supported and info.lba48_sectors > 0)
        info.lba48_sectors
    else
        info.lba_sectors;

    // Extract and clean up model string (it's byte-swapped in ATA)
    var model: [40]u8 = undefined;
    for (0..20) |i| {
        model[i * 2] = info.model[i * 2 + 1];
        model[i * 2 + 1] = info.model[i * 2];
    }

    // Trim trailing spaces
    var model_len: usize = 40;
    while (model_len > 0 and model[model_len - 1] == ' ') {
        model_len -= 1;
    }

    // Check DMA support
    const supports_dma = (info.capabilities & (1 << 8)) != 0;

    const metadata = device_mgr.DeviceMetadata{
        .ATA = .{
            .channel = if (channel == .Primary) .Primary else .Secondary,
            .drive = if (drive == .Master) .Master else .Slave,
            .sectors = sectors,
            .model = model,
            .supports_lba48 = lba48_supported,
            .supports_dma = supports_dma,
        },
    };

    _ = try device_mgr.registerDevice(metadata);

    const size_mb = (sectors * 512) / (1024 * 1024);
    log.info("found ATA device: {s} ({d} MB, LBA48: {}, DMA: {})", .{
        model[0..model_len],
        size_mb,
        lba48_supported,
        supports_dma,
    });
}
