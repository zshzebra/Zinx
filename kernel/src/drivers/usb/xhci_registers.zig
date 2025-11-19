/// XHCI Register Definitions
/// Based on the xHCI Specification Revision 1.2

const std = @import("std");

/// Capability Registers (Section 5.3)
/// Base offset: 0x00
/// These registers describe the controller's capabilities and configuration
pub const CapabilityRegisters = extern struct {
    /// Capability Register Length - offset to operational registers
    caplength: u8,

    /// Reserved
    _reserved: u8,

    /// Host Controller Interface Version Number
    hciversion: u16,

    /// Structural Parameters 1
    hcsparams1: packed struct {
        max_slots: u8,          // Maximum device slots
        max_intrs: u11,         // Maximum interrupters
        _reserved: u5,
        max_ports: u8,          // Number of ports
    },

    /// Structural Parameters 2
    hcsparams2: packed struct {
        ist: u4,                // Isochronous Scheduling Threshold
        erst_max: u4,           // Event Ring Segment Table Max
        _reserved: u13,
        max_scratchpad_bufs_hi: u5,  // Max Scratchpad Buffers Hi
        spr: u1,                // Scratchpad Restore
        max_scratchpad_bufs_lo: u5,  // Max Scratchpad Buffers Lo
    },

    /// Structural Parameters 3
    hcsparams3: packed struct {
        u1_device_exit_latency: u8,  // U1 Device Exit Latency
        _reserved: u8,
        u2_device_exit_latency: u16, // U2 Device Exit Latency
    },

    /// Capability Parameters 1
    hccparams1: packed struct {
        ac64: u1,               // 64-bit Addressing Capability
        bnc: u1,                // BW Negotiation Capability
        csz: u1,                // Context Size (0=32 bytes, 1=64 bytes)
        ppc: u1,                // Port Power Control
        pind: u1,               // Port Indicators
        lhrc: u1,               // Light HC Reset Capability
        ltc: u1,                // Latency Tolerance Messaging Capability
        nss: u1,                // No Secondary SID Support
        pae: u1,                // Parse All Event Data
        spc: u1,                // Stopped - Short Packet Capability
        sec: u1,                // Stopped EDTLA Capability
        cfc: u1,                // Contiguous Frame ID Capability
        maxpsasize: u4,         // Maximum Primary Stream Array Size
        xecp: u16,              // xHCI Extended Capabilities Pointer
    },

    /// Doorbell Offset
    dboff: u32,

    /// Runtime Register Space Offset
    rtsoff: u32,

    /// Capability Parameters 2
    hccparams2: packed struct {
        u3c: u1,                // U3 Entry Capability
        cmc: u1,                // Configure Endpoint Command Max Exit Latency Too Large Capability
        fsc: u1,                // Force Save Context Capability
        ctc: u1,                // Compliance Transition Capability
        lec: u1,                // Large ESIT Payload Capability
        cic: u1,                // Configuration Information Capability
        etc: u1,                // Extended TBC Capability
        etc_tsc: u1,            // Extended TBC TRB Status Capability
        gsc: u1,                // Get/Set Extended Property Capability
        vtc: u1,                // Virtualization Based Trusted I/O Capability
        _reserved: u22,
    },

    comptime {
        std.debug.assert(@sizeOf(CapabilityRegisters) == 0x20);
    }
};

/// Operational Registers (Section 5.4)
/// Base offset: CAPLENGTH
pub const OperationalRegisters = extern struct {
    /// USB Command Register
    usbcmd: u32,

    /// USB Status Register
    usbsts: u32,

    /// Page Size Register
    pagesize: u32,

    /// Reserved
    _reserved1: [2]u32,

    /// Device Notification Control Register
    dnctrl: u32,

    /// Command Ring Control Register
    crcr: u64,

    /// Reserved
    _reserved2: [4]u32,

    /// Device Context Base Address Array Pointer
    dcbaap: u64,

    /// Configure Register
    config: u32,
};

/// Port Register Set (Section 5.4.8)
/// One set per port, starting at Operational Base + 0x400
/// Each set is 16 bytes (0x10)
pub const PortRegisterSet = extern struct {
    /// Port Status and Control Register
    portsc: u32,

    /// Port PM Status and Control Register
    portpmsc: u32,

    /// Port Link Info Register
    portli: u32,

    /// Port Hardware LPM Control Register
    porthlpmc: u32,
};

/// Runtime Registers (Section 5.5)
/// Base offset: RTSOFF
pub const RuntimeRegisters = extern struct {
    /// Microframe Index Register
    mfindex: u32,

    /// Reserved
    _reserved: [7]u32,

    // Followed by interrupter register sets
};

/// Interrupter Register Set (Section 5.5.2)
/// One set per interrupter, starting at Runtime Base + 0x20
/// Each set is 32 bytes (0x20)
pub const InterrupterRegisterSet = extern struct {
    /// Interrupter Management Register
    iman: u32,

    /// Interrupter Moderation Register
    imod: u32,

    /// Event Ring Segment Table Size Register
    erstsz: u32,

    /// Reserved
    _reserved: u32,

    /// Event Ring Segment Table Base Address Register
    erstba: u64,

    /// Event Ring Dequeue Pointer Register
    erdp: u64,
};

// Register bit constants

/// USBCMD bits
pub const USBCMD_RUN_STOP: u32 = 1 << 0;
pub const USBCMD_HCRST: u32 = 1 << 1;
pub const USBCMD_INTE: u32 = 1 << 2;
pub const USBCMD_HSEE: u32 = 1 << 3;

/// CONFIG bits
pub const CONFIG_MAX_SLOTS_MASK: u32 = 0xFF;

/// USBSTS bits
pub const USBSTS_HCH: u32 = 1 << 0;
pub const USBSTS_HSE: u32 = 1 << 2;
pub const USBSTS_EINT: u32 = 1 << 3;
pub const USBSTS_PCD: u32 = 1 << 4;
pub const USBSTS_CNR: u32 = 1 << 11;
pub const USBSTS_HCE: u32 = 1 << 12;

/// CRCR bits
pub const CRCR_RCS: u64 = 1 << 0;       // Ring Cycle State
pub const CRCR_CS: u64 = 1 << 1;        // Command Stop
pub const CRCR_CA: u64 = 1 << 2;        // Command Abort
pub const CRCR_CRR: u64 = 1 << 3;       // Command Ring Running
pub const CRCR_PTR_MASK: u64 = ~@as(u64, 0x3F);  // Command Ring Pointer (bits 6-63)

/// IMAN bits
pub const IMAN_IP: u32 = 1 << 0;        // Interrupt Pending
pub const IMAN_IE: u32 = 1 << 1;        // Interrupt Enable

/// PORTSC bits
pub const PORTSC_CCS: u32 = 1 << 0;     // Current Connect Status
pub const PORTSC_PED: u32 = 1 << 1;     // Port Enabled/Disabled
pub const PORTSC_OCA: u32 = 1 << 3;     // Over-current Active
pub const PORTSC_PR: u32 = 1 << 4;      // Port Reset
pub const PORTSC_PP: u32 = 1 << 9;      // Port Power
pub const PORTSC_CSC: u32 = 1 << 17;    // Connect Status Change
pub const PORTSC_PEC: u32 = 1 << 18;    // Port Enabled/Disabled Change
pub const PORTSC_WRC: u32 = 1 << 19;    // Warm Port Reset Change
pub const PORTSC_OCC: u32 = 1 << 20;    // Over-current Change
pub const PORTSC_PRC: u32 = 1 << 21;    // Port Reset Change
pub const PORTSC_PLC: u32 = 1 << 22;    // Port Link State Change
pub const PORTSC_CEC: u32 = 1 << 23;    // Port Config Error Change

/// Port Link State values
pub const PLS_U0: u32 = 0;
pub const PLS_U1: u32 = 1;
pub const PLS_U2: u32 = 2;
pub const PLS_U3: u32 = 3;
pub const PLS_DISABLED: u32 = 4;
pub const PLS_RX_DETECT: u32 = 5;
pub const PLS_INACTIVE: u32 = 6;
pub const PLS_POLLING: u32 = 7;
pub const PLS_RECOVERY: u32 = 8;
pub const PLS_HOT_RESET: u32 = 9;
pub const PLS_COMPLIANCE_MODE: u32 = 10;
pub const PLS_TEST_MODE: u32 = 11;
pub const PLS_RESUME: u32 = 15;

/// Port Speed values (PORTSC.PortSpeed field)
pub const PORT_SPEED_UNDEFINED: u8 = 0;
pub const PORT_SPEED_FULL: u8 = 1;      // USB 1.1 Full Speed (12 Mbps)
pub const PORT_SPEED_LOW: u8 = 2;       // USB 1.0 Low Speed (1.5 Mbps)
pub const PORT_SPEED_HIGH: u8 = 3;      // USB 2.0 High Speed (480 Mbps)
pub const PORT_SPEED_SUPER: u8 = 4;     // USB 3.0 Super Speed (5 Gbps)
pub const PORT_SPEED_SUPER_PLUS: u8 = 5; // USB 3.1 Super Speed Plus (10 Gbps)

/// Port speed to string
pub fn portSpeedToString(speed: u4) []const u8 {
    return switch (speed) {
        PORT_SPEED_FULL => "Full Speed (12 Mbps)",
        PORT_SPEED_LOW => "Low Speed (1.5 Mbps)",
        PORT_SPEED_HIGH => "High Speed (480 Mbps)",
        PORT_SPEED_SUPER => "Super Speed (5 Gbps)",
        PORT_SPEED_SUPER_PLUS => "Super Speed+ (10 Gbps)",
        else => "Unknown",
    };
}

/// Port Link State to string
pub fn portLinkStateToString(pls: u4) []const u8 {
    return switch (pls) {
        PLS_U0 => "U0",
        PLS_U1 => "U1",
        PLS_U2 => "U2",
        PLS_U3 => "U3 (Suspended)",
        PLS_DISABLED => "Disabled",
        PLS_RX_DETECT => "RxDetect",
        PLS_INACTIVE => "Inactive",
        PLS_POLLING => "Polling",
        PLS_RECOVERY => "Recovery",
        PLS_HOT_RESET => "Hot Reset",
        PLS_COMPLIANCE_MODE => "Compliance Mode",
        PLS_TEST_MODE => "Test Mode",
        PLS_RESUME => "Resume",
        else => "Reserved",
    };
}
