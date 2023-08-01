const std = @import("std");

pub const Bus = @import("nds9/Bus.zig");
pub const io = @import("nds9/io.zig");
pub const Scheduler = @import("nds9/Scheduler.zig");
pub const Arm946es = @import("arm32").Arm946es;

const Allocator = std.mem.Allocator;

// TODO: Rename
pub const Group = struct {
    cpu: *Arm946es,
    bus: *Bus,
    scheduler: *Scheduler,

    /// Responsible for deallocating the ARM9 CPU, Bus and Scheduler
    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.bus.deinit(allocator);
        self.scheduler.deinit();
    }
};
