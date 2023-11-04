const std = @import("std");

const Bus9 = @import("nds9/Bus.zig");
const Bus7 = @import("nds7/Bus.zig");

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

pub fn remove(self: *@This(), needle: Event.Kind) void {
    for (self.queue.items, 0..) |event, i| {
        if (!std.meta.eql(event.kind, needle)) continue;

        _ = self.queue.removeIndex(i); // note: invalidates self.queue.items
        return;
    }
}

pub fn deinit(self: @This()) void {
    self.queue.deinit();
}

pub fn now(self: @This()) u64 {
    return self.tick;
}

pub fn reset(self: *@This()) void {
    self.tick = 0;
}

pub inline fn check(self: *@This()) ?Event {
    @setRuntimeSafety(false);
    if (self.tick < self.queue.items[0].tick) return null;

    return self.queue.remove();
}

pub fn handle(self: *@This(), bus_ptr: ?*anyopaque, event: Event, late: u64) void {
    switch (event.kind) {
        .heat_death => unreachable,
        .nds7 => |ev| {
            const bus: *Bus7 = @ptrCast(@alignCast(bus_ptr));
            _ = bus;

            switch (ev) {}
        },
        .nds9 => |ev| {
            const bus: *Bus9 = @ptrCast(@alignCast(bus_ptr));

            switch (ev) {
                .draw => {
                    bus.ppu.drawScanline(bus);
                    bus.ppu.onHdrawEnd(self, late);
                },
                .hblank => bus.ppu.onHblankEnd(self, late),
                .vblank => bus.ppu.onVblankEnd(self, late),
                .sqrt => bus.io.sqrt.onSqrtCalc(),
                .div => bus.io.div.onDivCalc(),
            }
        },
    }
}

pub const Event = struct {
    tick: u64,
    kind: Kind,

    const Kind7 = enum {};
    const Kind9 = enum { draw, hblank, vblank, sqrt, div };

    pub const Kind = union(enum) {
        nds7: Kind7,
        nds9: Kind9,
        heat_death: void,
    };

    fn lessThan(_: void, left: @This(), right: @This()) std.math.Order {
        return std.math.order(left.tick, right.tick);
    }
};
