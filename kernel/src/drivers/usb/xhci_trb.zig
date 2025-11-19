/// XHCI Transfer Request Block (TRB) definitions
/// Each TRB is exactly 16 bytes and used for commands, events, and data transfers

const std = @import("std");

/// Transfer Request Block - 16 bytes
pub const TRB = packed struct {
    /// Parameter field (meaning depends on TRB type)
    parameter: u64,

    /// Status field (length, completion code, etc.)
    status: u32,

    /// Control field - contains:
    /// - Bits 0-9: Specific to TRB type
    /// - Bit 10-15: TRB Type
    /// - Bits 16-31: Flags (cycle, interrupt on completion, etc.)
    control: u32,

    /// Get the TRB type from control field
    pub fn getTrbType(self: TRB) TrbType {
        const type_value = @as(u8, @truncate((self.control >> 10) & 0x3F));
        return @enumFromInt(type_value);
    }

    /// Set the TRB type in control field
    pub fn setTrbType(self: *TRB, trb_type: TrbType) void {
        const type_value: u32 = @intFromEnum(trb_type);
        self.control = (self.control & ~(@as(u32, 0x3F) << 10)) | (type_value << 10);
    }

    /// Get cycle bit
    pub fn getCycle(self: TRB) bool {
        return (self.control & 0x1) != 0;
    }

    /// Set cycle bit
    pub fn setCycle(self: *TRB, cycle: bool) void {
        if (cycle) {
            self.control |= 0x1;
        } else {
            self.control &= ~@as(u32, 0x1);
        }
    }

    /// Get interrupt on completion flag
    pub fn getIOC(self: TRB) bool {
        return (self.control & (1 << 5)) != 0;
    }

    /// Set interrupt on completion flag
    pub fn setIOC(self: *TRB, ioc: bool) void {
        if (ioc) {
            self.control |= (1 << 5);
        } else {
            self.control &= ~@as(u32, (1 << 5));
        }
    }
};

/// TRB Types (6.4.6 TRB Type Definitions)
pub const TrbType = enum(u8) {
    // Transfer TRBs
    Normal = 1,
    SetupStage = 2,
    DataStage = 3,
    StatusStage = 4,
    Isoch = 5,
    Link = 6,
    EventData = 7,
    NoOp = 8,

    // Command TRBs
    EnableSlotCommand = 9,
    DisableSlotCommand = 10,
    AddressDeviceCommand = 11,
    ConfigureEndpointCommand = 12,
    EvaluateContextCommand = 13,
    ResetEndpointCommand = 14,
    StopEndpointCommand = 15,
    SetTRDequeuePointerCommand = 16,
    ResetDeviceCommand = 17,
    ForceEventCommand = 18,
    NegotiateBandwidthCommand = 19,
    SetLatencyToleranceValueCommand = 20,
    GetPortBandwidthCommand = 21,
    ForceHeaderCommand = 22,
    NoOpCommand = 23,

    // Event TRBs
    TransferEvent = 32,
    CommandCompletionEvent = 33,
    PortStatusChangeEvent = 34,
    BandwidthRequestEvent = 35,
    DoorbellEvent = 36,
    HostControllerEvent = 37,
    DeviceNotificationEvent = 38,
    MFINDEXWrapEvent = 39,

    _,
};

/// TRB Completion Codes (6.4.5)
pub const CompletionCode = enum(u8) {
    Invalid = 0,
    Success = 1,
    DataBufferError = 2,
    BabbleDetectedError = 3,
    USBTransactionError = 4,
    TRBError = 5,
    StallError = 6,
    ResourceError = 7,
    BandwidthError = 8,
    NoSlotsAvailableError = 9,
    InvalidStreamTypeError = 10,
    SlotNotEnabledError = 11,
    EndpointNotEnabledError = 12,
    ShortPacket = 13,
    RingUnderrun = 14,
    RingOverrun = 15,
    VFEventRingFullError = 16,
    ParameterError = 17,
    BandwidthOverrunError = 18,
    ContextStateError = 19,
    NoPingResponseError = 20,
    EventRingFullError = 21,
    IncompatibleDeviceError = 22,
    MissedServiceError = 23,
    CommandRingStopped = 24,
    CommandAborted = 25,
    Stopped = 26,
    StoppedLengthInvalid = 27,
    MaxExitLatencyTooLargeError = 29,
    IsochBufferOverrun = 31,
    EventLostError = 32,
    UndefinedError = 33,
    InvalidStreamIDError = 34,
    SecondaryBandwidthError = 35,
    SplitTransactionError = 36,

    _,

    pub fn toString(self: CompletionCode) []const u8 {
        return switch (self) {
            .Success => "Success",
            .DataBufferError => "Data Buffer Error",
            .BabbleDetectedError => "Babble Detected",
            .USBTransactionError => "USB Transaction Error",
            .TRBError => "TRB Error",
            .StallError => "Stall Error",
            .ResourceError => "Resource Error",
            .BandwidthError => "Bandwidth Error",
            .NoSlotsAvailableError => "No Slots Available",
            .ShortPacket => "Short Packet",
            .ParameterError => "Parameter Error",
            .ContextStateError => "Context State Error",
            .CommandRingStopped => "Command Ring Stopped",
            .CommandAborted => "Command Aborted",
            else => "Unknown Error",
        };
    }
};

/// Link TRB - used to link ring segments
pub const LinkTRB = packed struct {
    ring_segment_ptr: u64,
    _reserved1: u22,
    interrupter_target: u10,
    cycle_bit: u1,
    toggle_cycle: u1,
    _reserved2: u2,
    chain_bit: u1,
    ioc: u1,
    _reserved3: u4,
    trb_type: u6,  // Must be 6 for Link TRB
    _reserved4: u16,

    pub fn toTRB(self: LinkTRB) TRB {
        return @bitCast(self);
    }

    pub fn fromTRB(trb: TRB) LinkTRB {
        return @bitCast(trb);
    }
};

/// Command Completion Event TRB
pub const CommandCompletionEventTRB = packed struct {
    command_trb_ptr: u64,
    completion_param: u24,
    completion_code: u8,
    cycle_bit: u1,
    _reserved1: u9,
    trb_type: u6,  // Must be 33
    vf_id: u8,
    slot_id: u8,

    pub fn toTRB(self: CommandCompletionEventTRB) TRB {
        return @bitCast(self);
    }

    pub fn fromTRB(trb: TRB) CommandCompletionEventTRB {
        return @bitCast(trb);
    }

    pub fn getCompletionCode(self: CommandCompletionEventTRB) CompletionCode {
        return @enumFromInt(self.completion_code);
    }
};

/// Port Status Change Event TRB
pub const PortStatusChangeEventTRB = packed struct {
    _reserved1: u24,
    port_id: u8,
    _reserved2: u32,
    completion_param: u24,
    completion_code: u8,
    cycle_bit: u1,
    _reserved3: u9,
    trb_type: u6,  // Must be 34
    _reserved4: u16,

    pub fn toTRB(self: PortStatusChangeEventTRB) TRB {
        return @bitCast(self);
    }

    pub fn fromTRB(trb: TRB) PortStatusChangeEventTRB {
        return @bitCast(trb);
    }
};

/// Transfer Event TRB
pub const TransferEventTRB = packed struct {
    trb_pointer: u64,
    transfer_length: u24,
    completion_code: u8,
    cycle_bit: u1,
    _reserved1: u1,
    event_data: u1,
    _reserved2: u7,
    trb_type: u6,  // Must be 32
    endpoint_id: u5,
    _reserved3: u3,
    slot_id: u8,

    pub fn toTRB(self: TransferEventTRB) TRB {
        return @bitCast(self);
    }

    pub fn fromTRB(trb: TRB) TransferEventTRB {
        return @bitCast(trb);
    }

    pub fn getCompletionCode(self: TransferEventTRB) CompletionCode {
        return @enumFromInt(self.completion_code);
    }
};

/// Enable Slot Command TRB
pub const EnableSlotCommandTRB = packed struct {
    _reserved1: u64,
    _reserved2: u32,
    cycle_bit: u1,
    _reserved3: u9,
    trb_type: u6,  // Must be 9
    slot_type: u5,
    _reserved4: u11,

    pub fn toTRB(self: EnableSlotCommandTRB) TRB {
        return @bitCast(self);
    }
};

/// Address Device Command TRB
pub const AddressDeviceCommandTRB = packed struct {
    input_context_ptr: u64,
    _reserved1: u32,
    cycle_bit: u1,
    _reserved2: u8,
    bsr: u1,  // Block Set Address Request
    trb_type: u6,  // Must be 11
    _reserved3: u8,
    slot_id: u8,

    pub fn toTRB(self: AddressDeviceCommandTRB) TRB {
        return @bitCast(self);
    }
};

/// No-Op Command TRB
pub const NoOpCommandTRB = packed struct {
    _reserved1: u64,
    _reserved2: u32,
    cycle_bit: u1,
    _reserved3: 9,
    trb_type: u6,  // Must be 23
    _reserved4: u16,

    pub fn toTRB(self: NoOpCommandTRB) TRB {
        return @bitCast(self);
    }
};

/// Setup Stage TRB (for control transfers)
pub const SetupStageTRB = packed struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
    transfer_length: u17,  // Always 8 for setup
    _reserved1: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    _reserved2: u4,
    ioc: u1,
    idt: u1,  // Immediate Data
    _reserved3: u3,
    trb_type: u6,  // Must be 2
    trt: u2,  // Transfer Type
    _reserved4: u14,

    pub fn toTRB(self: SetupStageTRB) TRB {
        return @bitCast(self);
    }
};

/// Data Stage TRB (for control transfers)
pub const DataStageTRB = packed struct {
    data_buffer_ptr: u64,
    transfer_length: u17,
    td_size: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: u1,  // Evaluate Next TRB
    isp: u1,  // Interrupt on Short Packet
    ns: u1,   // No Snoop
    ch: u1,   // Chain bit
    ioc: u1,  // Interrupt on Completion
    idt: u1,  // Immediate Data
    _reserved1: u3,
    trb_type: u6,  // Must be 3
    dir: u1,  // Direction (0=OUT, 1=IN)
    _reserved2: u15,

    pub fn toTRB(self: DataStageTRB) TRB {
        return @bitCast(self);
    }
};

/// Status Stage TRB (for control transfers)
pub const StatusStageTRB = packed struct {
    _reserved1: u64,
    _reserved2: u22,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: u1,
    _reserved3: u2,
    ch: u1,
    ioc: u1,
    _reserved4: u4,
    trb_type: u6,  // Must be 4
    dir: u1,  // Direction
    _reserved5: u15,

    pub fn toTRB(self: StatusStageTRB) TRB {
        return @bitCast(self);
    }
};

/// Normal TRB (for bulk/interrupt transfers)
pub const NormalTRB = packed struct {
    data_buffer_ptr: u64,
    transfer_length: u17,
    td_size: u5,
    interrupter_target: u10,
    cycle_bit: u1,
    ent: u1,
    isp: u1,
    ns: u1,
    ch: u1,
    ioc: u1,
    idt: u1,
    _reserved1: u2,
    bei: u1,  // Block Event Interrupt
    trb_type: u6,  // Must be 1
    _reserved2: u16,

    pub fn toTRB(self: NormalTRB) TRB {
        return @bitCast(self);
    }
};

comptime {
    // Verify TRB size is exactly 16 bytes
    std.debug.assert(@sizeOf(TRB) == 16);
    std.debug.assert(@sizeOf(LinkTRB) == 16);
    std.debug.assert(@sizeOf(CommandCompletionEventTRB) == 16);
    std.debug.assert(@sizeOf(PortStatusChangeEventTRB) == 16);
    std.debug.assert(@sizeOf(TransferEventTRB) == 16);
}
