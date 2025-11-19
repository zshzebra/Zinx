/// XHCI Ring Buffer Management
/// Handles circular TRB buffers for command, event, and transfer rings

const std = @import("std");
const dma = @import("../../dma.zig");
const trb_mod = @import("xhci_trb.zig");

const TRB = trb_mod.TRB;
const TrbType = trb_mod.TrbType;
const LinkTRB = trb_mod.LinkTRB;
const DmaRegion = dma.DmaRegion;

pub const RingError = error{
    RingFull,
    InvalidTRB,
    NotInitialized,
};

/// Transfer Ring - circular buffer of TRBs
/// Used for Command Ring, Event Ring, and Transfer Rings (per endpoint)
pub const Ring = struct {
    /// DMA region containing the TRB array
    region: DmaRegion,

    /// Pointer to TRB array in virtual memory
    trbs: []TRB,

    /// Number of TRBs in the ring (excluding Link TRB)
    capacity: usize,

    /// Enqueue index (software writes here)
    enqueue_index: usize,

    /// Dequeue index (software reads here for event rings)
    dequeue_index: usize,

    /// Producer Cycle State
    cycle_state: bool,

    /// Consumer Cycle State (for event rings)
    consumer_cycle_state: bool,

    /// Ring type (for debugging)
    ring_type: RingType,

    pub const RingType = enum {
        Command,
        Event,
        Transfer,
    };

    /// Initialize a ring with the given number of TRBs
    /// Note: Actual capacity will be count-1 because we need a Link TRB
    pub fn init(count: usize, ring_type: RingType) !Ring {
        if (count < 2) return RingError.InvalidTRB;

        // Allocate DMA region for TRBs
        const region = try dma.allocXhciRing(count);
        const trbs: []TRB = region.asSlice(TRB);

        // Zero out all TRBs
        @memset(trbs, std.mem.zeroes(TRB));

        // Set up Link TRB at the end to create circular buffer
        const link_index = count - 1;
        var link_trb = std.mem.zeroes(LinkTRB);
        link_trb.ring_segment_ptr = region.phys_addr;  // Point back to start
        link_trb.cycle_bit = 1;
        link_trb.toggle_cycle = 1;  // Toggle cycle bit on wrap
        link_trb.trb_type = @intFromEnum(TrbType.Link);
        trbs[link_index] = link_trb.toTRB();

        return Ring{
            .region = region,
            .trbs = trbs,
            .capacity = count - 1,  // Exclude Link TRB
            .enqueue_index = 0,
            .dequeue_index = 0,
            .cycle_state = true,  // Start with cycle bit = 1
            .consumer_cycle_state = true,
            .ring_type = ring_type,
        };
    }

    /// Free the ring's DMA memory
    pub fn deinit(self: *Ring) void {
        dma.freeDma(self.region);
    }

    /// Get physical address of the ring
    pub fn getPhysAddr(self: Ring) u64 {
        return self.region.phys_addr;
    }

    /// Get physical address of enqueue pointer
    pub fn getEnqueuePhysAddr(self: Ring) u64 {
        return self.region.phys_addr + (self.enqueue_index * @sizeOf(TRB));
    }

    /// Get physical address of dequeue pointer
    pub fn getDequeuePhysAddr(self: Ring) u64 {
        return self.region.phys_addr + (self.dequeue_index * @sizeOf(TRB));
    }

    /// Enqueue a TRB to the ring (producer operation)
    /// This is used by software to add commands or transfers
    pub fn enqueueTRB(self: *Ring, trb: TRB) RingError!void {
        // Check if ring is full (enqueue caught up to dequeue)
        const next_index = (self.enqueue_index + 1) % self.capacity;
        if (next_index == self.dequeue_index) {
            return RingError.RingFull;
        }

        // Copy TRB to ring
        var new_trb = trb;

        // Set the cycle bit to current cycle state
        new_trb.setCycle(self.cycle_state);

        // Write TRB to ring
        self.trbs[self.enqueue_index] = new_trb;

        // Advance enqueue pointer
        self.enqueue_index += 1;

        // Check if we've reached the Link TRB
        if (self.enqueue_index >= self.capacity) {
            // Update Link TRB's cycle bit
            var link_trb = LinkTRB.fromTRB(self.trbs[self.capacity]);
            link_trb.cycle_bit = if (self.cycle_state) 1 else 0;
            self.trbs[self.capacity] = link_trb.toTRB();

            // Wrap around
            self.enqueue_index = 0;

            // Toggle cycle state
            self.cycle_state = !self.cycle_state;
        }
    }

    /// Dequeue a TRB from the ring (consumer operation for event rings)
    /// Returns null if no events available
    pub fn dequeueTRB(self: *Ring) ?TRB {
        // Get current TRB
        const current_trb = self.trbs[self.dequeue_index];

        // Check if TRB is owned by us (cycle bit matches consumer cycle state)
        if (current_trb.getCycle() != self.consumer_cycle_state) {
            return null;  // No new events
        }

        // Check if it's a Link TRB (shouldn't happen in event ring)
        if (current_trb.getTrbType() == .Link) {
            // Wrap around
            self.dequeue_index = 0;
            self.consumer_cycle_state = !self.consumer_cycle_state;

            // Try again at start of ring
            return self.dequeueTRB();
        }

        // Advance dequeue pointer
        self.dequeue_index += 1;
        if (self.dequeue_index >= self.capacity) {
            self.dequeue_index = 0;
            self.consumer_cycle_state = !self.consumer_cycle_state;
        }

        return current_trb;
    }

    /// Peek at the next TRB without removing it (for event rings)
    pub fn peekTRB(self: *Ring) ?TRB {
        const current_trb = self.trbs[self.dequeue_index];

        // Check if TRB is owned by us
        if (current_trb.getCycle() != self.consumer_cycle_state) {
            return null;
        }

        return current_trb;
    }

    /// Check if ring has events available (for event rings)
    pub fn hasEvents(self: *Ring) bool {
        const current_trb = self.trbs[self.dequeue_index];
        return current_trb.getCycle() == self.consumer_cycle_state;
    }

    /// Reset the ring to empty state
    pub fn reset(self: *Ring) void {
        // Zero out all TRBs except Link
        for (0..self.capacity) |i| {
            self.trbs[i] = std.mem.zeroes(TRB);
        }

        // Re-initialize Link TRB
        var link_trb = std.mem.zeroes(LinkTRB);
        link_trb.ring_segment_ptr = self.region.phys_addr;
        link_trb.cycle_bit = 1;
        link_trb.toggle_cycle = 1;
        link_trb.trb_type = @intFromEnum(TrbType.Link);
        self.trbs[self.capacity] = link_trb.toTRB();

        self.enqueue_index = 0;
        self.dequeue_index = 0;
        self.cycle_state = true;
        self.consumer_cycle_state = true;
    }

    /// Get number of TRBs currently in the ring
    pub fn getCount(self: Ring) usize {
        if (self.enqueue_index >= self.dequeue_index) {
            return self.enqueue_index - self.dequeue_index;
        } else {
            return self.capacity - self.dequeue_index + self.enqueue_index;
        }
    }

    /// Check if ring is empty
    pub fn isEmpty(self: Ring) bool {
        return self.enqueue_index == self.dequeue_index;
    }

    /// Get free space in ring
    pub fn getFreeSpace(self: Ring) usize {
        return self.capacity - self.getCount() - 1; // -1 to never completely fill
    }
};

/// Event Ring Segment Table Entry
pub const ERSTEntry = packed struct {
    ring_segment_base_address: u64,
    ring_segment_size: u16,
    _reserved: u48,

    comptime {
        std.debug.assert(@sizeOf(ERSTEntry) == 16);
    }
};

/// Event Ring Segment Table
pub const EventRingSegmentTable = struct {
    /// DMA region for the table
    region: DmaRegion,

    /// Pointer to entries
    entries: []ERSTEntry,

    /// Number of segments
    count: usize,

    /// Initialize ERST with the given number of segments
    pub fn init(count: usize) !EventRingSegmentTable {
        if (count == 0) return RingError.InvalidTRB;

        const size = count * @sizeOf(ERSTEntry);
        const region = try dma.allocDma(size, 64);  // 64-byte alignment
        const entries: []ERSTEntry = region.asSlice(ERSTEntry);

        // Zero out entries
        @memset(entries, std.mem.zeroes(ERSTEntry));

        return EventRingSegmentTable{
            .region = region,
            .entries = entries,
            .count = count,
        };
    }

    /// Free ERST memory
    pub fn deinit(self: *EventRingSegmentTable) void {
        dma.freeDma(self.region);
    }

    /// Set an entry in the table
    pub fn setEntry(self: *EventRingSegmentTable, index: usize, ring: *const Ring) void {
        if (index >= self.count) return;

        self.entries[index] = ERSTEntry{
            .ring_segment_base_address = ring.getPhysAddr(),
            .ring_segment_size = @intCast(ring.capacity + 1),  // Include Link TRB in count
            ._reserved = 0,
        };
    }

    /// Get physical address of the table
    pub fn getPhysAddr(self: EventRingSegmentTable) u64 {
        return self.region.phys_addr;
    }
};

/// Device Context Base Address Array (DCBAA)
pub const DCBAA = struct {
    /// DMA region for the array
    region: DmaRegion,

    /// Pointer to array of device context addresses
    entries: []u64,

    /// Maximum number of slots
    max_slots: usize,

    /// Initialize DCBAA for the given number of slots
    pub fn init(max_slots: u8) !DCBAA {
        // Array size is (max_slots + 1) because slot 0 is for scratchpad buffer array
        const count = @as(usize, max_slots) + 1;
        const size = count * @sizeOf(u64);
        const region = try dma.allocDma(size, 64);  // 64-byte alignment
        const entries: []u64 = region.asSlice(u64);

        // Zero out all entries
        @memset(entries, 0);

        return DCBAA{
            .region = region,
            .entries = entries,
            .max_slots = max_slots,
        };
    }

    /// Free DCBAA memory
    pub fn deinit(self: *DCBAA) void {
        dma.freeDma(self.region);
    }

    /// Set device context address for a slot
    pub fn setDeviceContext(self: *DCBAA, slot_id: u8, phys_addr: u64) void {
        if (slot_id > self.max_slots) return;
        self.entries[slot_id] = phys_addr;
    }

    /// Get device context address for a slot
    pub fn getDeviceContext(self: *DCBAA, slot_id: u8) u64 {
        if (slot_id > self.max_slots) return 0;
        return self.entries[slot_id];
    }

    /// Set scratchpad buffer array address (slot 0)
    pub fn setScratchpadArray(self: *DCBAA, phys_addr: u64) void {
        self.entries[0] = phys_addr;
    }

    /// Get physical address of the DCBAA
    pub fn getPhysAddr(self: DCBAA) u64 {
        return self.region.phys_addr;
    }
};
