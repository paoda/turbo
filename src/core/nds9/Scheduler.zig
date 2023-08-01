const std = @import("std");

const Bus = @import("Bus.zig");

const PriorityQueue = std.PriorityQueue(Event, void, Event.lessThan);
const Allocator = std.mem.Allocator;

tick: u64 = 0,
queue: PriorityQueue,

pub fn init(allocator: Allocator) !@This() {
    var queue = PriorityQueue.init(allocator, {});
    try queue.add(.{ .tick = std.math.maxInt(u64), .kind = .heat_death });

    return .{ .queue = queue };
}

pub fn push(self: *@This(), kind: Event.Kind, offset: u64) void {
    self.queue.add(.{ .kind = kind, .tick = self.tick + offset }) catch unreachable;
}

pub fn deinit(self: @This()) void {
    self.queue.deinit();
}

pub fn now(self: @This()) u64 {
    return self.tick;
}

pub fn next(self: @This()) u64 {
    @setRuntimeSafety(false);

    return self.queue.items[0].tick;
}

pub fn reset(self: *@This()) void {
    self.tick = 0;
}

pub fn handle(self: *@This(), bus: *Bus) void {
    const event = self.queue.remove();
    const late = self.tick - event.tick;

    switch (event.kind) {
        .heat_death => unreachable,
        .draw => {
            bus.ppu.drawScanline(bus);
            bus.ppu.onHdrawEnd(self, late);
        },
        .hblank => bus.ppu.onHblankEnd(self, late),
        .vblank => bus.ppu.onHblankEnd(self, late),
    }
}

pub const Event = struct {
    tick: u64,
    kind: Kind,

    pub const Kind = enum {
        heat_death,
        draw,
        hblank,
        vblank,
    };

    fn lessThan(_: void, left: @This(), right: @This()) std.math.Order {
        return std.math.order(left.tick, right.tick);
    }
};
