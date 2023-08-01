const std = @import("std");

pub const Bus = @import("nds7/Bus.zig");
pub const io = @import("nds7/io.zig");
pub const Scheduler = @import("nds7/Scheduler.zig");
pub const Arm7tdmi = @import("arm32").Arm7tdmi;

const Allocator = std.mem.Allocator;

// TODO: Rename (maybe Devices?)
pub const Group = struct {
    cpu: *Arm7tdmi,
    bus: *Bus,
    scheduler: *Scheduler,

    /// Responsible for deallocated the ARM7 CPU, Bus and Scheduler
    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.bus.deinit(allocator);
        self.scheduler.deinit();
    }
};
