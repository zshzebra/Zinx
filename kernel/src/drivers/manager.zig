const std = @import("std");
const log = std.log.scoped(.driver_manager);

pub const DriverCapabilities = struct {
    timer: bool = false,
    interrupt_controller: bool = false,
    serial: bool = false,
    keyboard: bool = false,
    display: bool = false,
    pci: bool = false,
    usb: bool = false,
    memory_controller: bool = false,
};

pub const TimerInterface = struct {
    sleep: *const fn(ms: u32) void,
    millis: *const fn() u32,
};

pub const InterruptInterface = struct {
    sendEndOfInterrupt: *const fn(irq_num: u8) void,
    clearMask: *const fn(irq_num: u8) void,
    setMask: *const fn(irq_num: u8) void,
    spuriousIrq: *const fn(irq_num: u8) bool,
};

pub const SerialInterface = struct {
    write: *const fn(byte: u8) void,
    read: *const fn() ?u8,
};

pub const KeyboardInterface = struct {
    readKey: *const fn() ?KeyEvent,
    isEmpty: *const fn() bool,
};

pub const DisplayInterface = struct {
    clear: *const fn(color: u32) void,
    setPixel: *const fn(x: usize, y: usize, color: u32) void,
    getPixel: *const fn(x: usize, y: usize) u32,
};

pub const KeyEvent = struct {
    position: u8,
    released: bool,
    modifiers: struct {
        shift: bool,
        ctrl: bool,
        alt: bool,
    },
};

pub const DriverError = error{
    ProbeFailed,
    InitializationFailed,
    NoDriverFound,
    DriverAlreadyActive,
    UnloadFailed,
};

pub const Driver = struct {
    name: []const u8,
    capabilities: DriverCapabilities,
    probe: *const fn() bool,
    init: *const fn() DriverError!void,
    unload: *const fn() void,

    timer_interface: ?*const TimerInterface = null,
    interrupt_interface: ?*const InterruptInterface = null,
    serial_interface: ?*const SerialInterface = null,
    keyboard_interface: ?*const KeyboardInterface = null,
    display_interface: ?*const DisplayInterface = null,
};

const ActiveDrivers = struct {
    timer: ?*const Driver = null,
    interrupt_controller: ?*const Driver = null,
    serial: ?*const Driver = null,
    keyboard: ?*const Driver = null,
    display: ?*const Driver = null,
};

var active_drivers: ActiveDrivers = .{};
var initialized = false;

pub fn init() !void {
    if (initialized) return;

    log.info("initializing driver manager", .{});

    try probeAndInitDrivers();

    initialized = true;
    log.info("driver manager initialized", .{});
}

pub fn deinit() void {
    if (!initialized) return;

    log.info("shutting down driver manager", .{});

    unloadAllDrivers();

    initialized = false;
}

fn probeAndInitDrivers() !void {
    try probeInterruptControllers();
    try probeTimers();
    try probeSerialDrivers();
    try probeKeyboardDrivers();
    try probeDisplayDrivers();
}

fn unloadAllDrivers() void {
    if (active_drivers.timer) |driver| {
        log.info("unloading timer driver: {s}", .{driver.name});
        driver.unload();
        active_drivers.timer = null;
    }

    if (active_drivers.interrupt_controller) |driver| {
        log.info("unloading interrupt controller: {s}", .{driver.name});
        driver.unload();
        active_drivers.interrupt_controller = null;
    }

    if (active_drivers.serial) |driver| {
        log.info("unloading serial driver: {s}", .{driver.name});
        driver.unload();
        active_drivers.serial = null;
    }

    if (active_drivers.keyboard) |driver| {
        log.info("unloading keyboard driver: {s}", .{driver.name});
        driver.unload();
        active_drivers.keyboard = null;
    }

    if (active_drivers.display) |driver| {
        log.info("unloading display driver: {s}", .{driver.name});
        driver.unload();
        active_drivers.display = null;
    }
}

fn probeTimers() !void {
    const timer_drivers = getTimerDrivers();

    for (timer_drivers) |driver| {
        if (driver.probe()) {
            log.info("probing timer driver: {s} - success", .{driver.name});
            driver.init() catch |err| {
                log.err("failed to initialize timer driver {s}: {}", .{driver.name, err});
                continue;
            };
            active_drivers.timer = driver;
            log.info("active timer driver: {s}", .{driver.name});
            return;
        }
        log.debug("probing timer driver: {s} - failed", .{driver.name});
    }

    return DriverError.NoDriverFound;
}

fn probeInterruptControllers() !void {
    const interrupt_drivers = getInterruptDrivers();

    for (interrupt_drivers) |driver| {
        if (driver.probe()) {
            log.info("probing interrupt controller: {s} - success", .{driver.name});
            driver.init() catch |err| {
                log.err("failed to initialize interrupt controller {s}: {}", .{driver.name, err});
                continue;
            };
            active_drivers.interrupt_controller = driver;
            log.info("active interrupt controller: {s}", .{driver.name});
            return;
        }
        log.debug("probing interrupt controller: {s} - failed", .{driver.name});
    }

    return DriverError.NoDriverFound;
}

fn probeSerialDrivers() !void {
    const serial_drivers = getSerialDrivers();

    for (serial_drivers) |driver| {
        if (driver.probe()) {
            log.info("probing serial driver: {s} - success", .{driver.name});
            driver.init() catch |err| {
                log.err("failed to initialize serial driver {s}: {}", .{driver.name, err});
                continue;
            };
            active_drivers.serial = driver;
            log.info("active serial driver: {s}", .{driver.name});
            return;
        }
        log.debug("probing serial driver: {s} - failed", .{driver.name});
    }

    return DriverError.NoDriverFound;
}

fn probeKeyboardDrivers() !void {
    const keyboard_drivers = getKeyboardDrivers();

    for (keyboard_drivers) |driver| {
        if (driver.probe()) {
            log.info("probing keyboard driver: {s} - success", .{driver.name});
            driver.init() catch |err| {
                log.err("failed to initialize keyboard driver {s}: {}", .{driver.name, err});
                continue;
            };
            active_drivers.keyboard = driver;
            log.info("active keyboard driver: {s}", .{driver.name});
            return;
        }
        log.debug("probing keyboard driver: {s} - failed", .{driver.name});
    }

    return DriverError.NoDriverFound;
}

fn probeDisplayDrivers() !void {
    const display_drivers = getDisplayDrivers();

    for (display_drivers) |driver| {
        if (driver.probe()) {
            log.info("probing display driver: {s} - success", .{driver.name});
            driver.init() catch |err| {
                log.err("failed to initialize display driver {s}: {}", .{driver.name, err});
                continue;
            };
            active_drivers.display = driver;
            log.info("active display driver: {s}", .{driver.name});
            return;
        }
        log.debug("probing display driver: {s} - failed", .{driver.name});
    }

    return DriverError.NoDriverFound;
}

pub fn getTimer() *const TimerInterface {
    if (active_drivers.timer) |driver| {
        return driver.timer_interface orelse @panic("Timer driver missing interface");
    }
    @panic("No active timer driver");
}

pub fn getInterruptController() *const InterruptInterface {
    if (active_drivers.interrupt_controller) |driver| {
        return driver.interrupt_interface orelse @panic("Interrupt controller missing interface");
    }
    @panic("No active interrupt controller");
}

pub fn getSerial() *const SerialInterface {
    if (active_drivers.serial) |driver| {
        return driver.serial_interface orelse @panic("Serial driver missing interface");
    }
    @panic("No active serial driver");
}

pub fn getKeyboard() *const KeyboardInterface {
    if (active_drivers.keyboard) |driver| {
        return driver.keyboard_interface orelse @panic("Keyboard driver missing interface");
    }
    @panic("No active keyboard driver");
}

pub fn getDisplay() *const DisplayInterface {
    if (active_drivers.display) |driver| {
        return driver.display_interface orelse @panic("Display driver missing interface");
    }
    @panic("No active display driver");
}

pub fn getTimerInterface() ?*const TimerInterface {
    if (active_drivers.timer) |driver| {
        return driver.timer_interface;
    }
    return null;
}

pub fn getSerialInterface() ?*const SerialInterface {
    if (active_drivers.serial) |driver| {
        return driver.serial_interface;
    }
    return null;
}

fn getTimerDrivers() []const *const Driver {
    const pit_timer = @import("core/timer/pit.zig");

    return &[_]*const Driver{
        &pit_timer.driver,
    };
}

fn getInterruptDrivers() []const *const Driver {
    const pic_controller = @import("core/interrupts/pic.zig");

    return &[_]*const Driver{
        &pic_controller.driver,
    };
}

fn getSerialDrivers() []const *const Driver {
    const uart_serial = @import("core/serial/uart.zig");

    return &[_]*const Driver{
        &uart_serial.driver,
    };
}

fn getKeyboardDrivers() []const *const Driver {
    const ps2_keyboard = @import("input/keyboard/ps2.zig");

    return &[_]*const Driver{
        &ps2_keyboard.driver,
    };
}

fn getDisplayDrivers() []const *const Driver {
    const framebuffer_display = @import("core/display/framebuffer.zig");

    return &[_]*const Driver{
        &framebuffer_display.driver,
    };
}