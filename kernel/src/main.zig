const builtin = @import("builtin");
const std = @import("std");
const limine = @import("limine");
const limine_fb = @import("limine_fb.zig");
const Framebuffer = @import("framebuffer.zig").Framebuffer;
const Console = @import("tty.zig").Console;
const arch = @import("arch.zig").internals;
const log_root = @import("log.zig");
const serial = @import("serial.zig");
const shell = @import("shell.zig");
const keyboard = @import("keyboard.zig");
const pmm = @import("pmm.zig");
const allocator = @import("allocator.zig");
const panic_mod = @import("panic.zig");

const LogoSize = enum { Small, Large };

const LOGO_SIZE: LogoSize = .Small;

const logo = switch (LOGO_SIZE) {
    .Small => @import("Zinx-small.zig"),
    .Large => @import("Zinx-large.zig"),
};

const kernel_log = std.log.scoped(.kernel);
pub var kernel_tty: ?*Console = null;
pub var kernel_serial: ?std.Io.Writer = null;

var panic_buffer: [4 * 1024 * 1024]u8 = undefined;

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};

pub const std_options = std.Options{
    .logFn = log,
    .log_level = .debug,
    .page_size_max = 4096,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_root.log(level, "(" ++ @tagName(scope) ++ "): " ++ format, args);
}

var global_panic_tty: ?*Console = null;

const PanicWriter = struct {
    tty: *Console,
    serial: ?*serial.Serial,

    pub fn print(self: PanicWriter, comptime format: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, format, args);

        if (self.serial) |ser| {
            ser.print(msg);
        }
        self.tty.write(msg);
    }
};

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @branchHint(.cold);

    _ = trace;

    const panic_header = "=== KERNEL PANIC ===\n";
    const panic_msg_prefix = "Error: ";

    if (kernel_serial) |*ser| {
        ser.print("{s}", .{panic_header}) catch {};
        ser.print("{s}", .{panic_msg_prefix}) catch {};
        ser.print("{s}", .{msg}) catch {};
        ser.print("\n\n", .{}) catch {};
    }

    global_panic_tty = kernel_tty orelse arch.done();
    const panic_tty = global_panic_tty.?;
    panic_tty.setColors(0x0, 0xf7a41d);
    panic_tty.setEnableCursor(false);
    panic_tty.clear();
    panic_tty.write("Uh Oh! It looks like Zinx has encountered an error.\n");
    if (kernel_serial == null) panic_tty.write("No serial available\n");
    panic_tty.write(msg);
    panic_tty.writeChar('\n');
    panic_tty.writeChar('\n');

    var fba = std.heap.FixedBufferAllocator.init(&panic_buffer);

    var debug_info = panic_mod.DebugInfo.init(fba.allocator()) catch |err| {
        var buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&buf, "Failed to init debug info: {}\n", .{err}) catch "Failed to init debug info\n";

        if (kernel_serial) |*ser| {
            ser.print("{s}", .{err_msg}) catch {};
            ser.print("Stack print(addresses only):\n", .{}) catch {};
        }
        panic_tty.write(err_msg);
        panic_tty.write("Stack trace (addresses only):\n");

        var it = std.debug.StackIterator.init(ret_addr orelse @returnAddress(), @frameAddress());
        defer it.deinit();

        var frame_num: usize = 0;
        while (it.next()) |addr| : (frame_num += 1) {
            var addr_buf: [64]u8 = undefined;
            const addr_msg = std.fmt.bufPrint(&addr_buf, "  #{d}: 0x{X}\n", .{ frame_num, addr }) catch break;
            if (kernel_serial) |*ser| {
                ser.print("{s}", .{addr_msg}) catch {};
            }
            panic_tty.write(addr_msg);
            if (frame_num >= 20) break;
        }
        shutdownOrHalt(panic_tty);
    };
    defer debug_info.deinit();

    if (kernel_serial) |*ser| {
        ser.print("Stack trace:\n", .{}) catch {};
    }
    panic_tty.write("Stack trace:\n");

    const writer = @constCast(&log_root.log_writer);
    debug_info.printStackTrace(writer, ret_addr orelse @returnAddress(), @frameAddress()) catch |err| {
        var buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&buf, "Failed to print stack trace: {}\n", .{err}) catch "Failed to print stack trace\n";
        if (kernel_serial) |*ser| {
            ser.print("{s}", .{err_msg}) catch {};
        }
        panic_tty.write(err_msg);
    };

    shutdownOrHalt(panic_tty);
}

fn shutdownOrHalt(panic_tty: *Console) noreturn {
    if (keyboard.getKeyboard(0)) |kb| {
        panic_tty.write("\nPress and release <space> to shutdown");

        while (true) {
            if (kb.readKey()) |key| {
                if (key.released and key.position == keyboard.KeyPosition.SPACE) break;
            }
        }

        arch.out(@as(u16, 0x604), @as(u16, 0x2000));
        arch.done();
    }

    panic_tty.write("\nNo keyboard found, manually reset your device\n");
    arch.done();
}

export fn _start() noreturn {
    if (!base_revision.isSupported()) {
        arch.done();
    }

    log_root.init();
    kernel_serial = log_root.log_writer;

    kernel_log.info("base revision supported", .{});
    kernel_log.info("serial initialization succeeded", .{});

    kernel_log.info("initializing framebuffers", .{});
    const framebuffers = limine_fb.initFramebuffers() orelse {
        kernel_log.err("unable to fetch framebuffers", .{});
        arch.done();
    };
    kernel_log.info("got {} framebuffers", .{framebuffers.count});

    if (framebuffers.count == 0) {
        arch.done();
    }

    var framebuffer = framebuffers.buffers[0] orelse arch.done();
    kernel_log.info("using framebuffer #{} with resolution: {}x{}", .{ 0, framebuffer.width, framebuffer.height });

    kernel_log.info("initializing kernel tty", .{});
    var tty = framebuffer.getTTY();
    kernel_tty = &tty;
    kernel_log.info("tty initialized", .{});

    kernel_log.info("initializing arch", .{});
    arch.init();
    kernel_log.info("arch initialized", .{});

    kernel_log.info("starting kernel main", .{});
    main() catch |err| {
        kernel_log.err("Error on kernal main: {}", .{err});
    };

    @panic("Init exited");
}

fn main() !void {
    kernel_tty.?.clear();
    for (0..8) |idx| {
        kernel_tty.?.writeImage(&logo.data, logo.width, logo.height, 0xFFFFFF, if (idx == 7) .Newline else .Word) catch {
            @panic("Unexpected error displaying logo");
        };
    }

    kernel_tty.?.write("Welcome to Zinx!\n");

    const total_mem = pmm.getTotalMemory();
    const free_mem = pmm.getFreeMemory();
    const heap_stats = allocator.getMemoryStats();

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buffer[0..]);
    var writer = fbs.writer();

    writer.print("Memory: {} MB total, {} MB free\n", .{ total_mem / (1024 * 1024), free_mem / (1024 * 1024) }) catch {};
    kernel_tty.?.write(fbs.getWritten());

    fbs.reset();
    writer.print("Heap: {} KB allocated, {} KB free\n", .{ heap_stats.used / 1024, heap_stats.free / 1024 }) catch {};
    kernel_tty.?.write(fbs.getWritten());

    kernel_tty.?.write("Booting shell\n");
    shell.shell_main(kernel_tty.?);
}
