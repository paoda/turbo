const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Bus = @import("Bus.zig");
const SharedIo = @import("../io.zig").Io;
const writeToAddressOffset = @import("../io.zig").writeToAddressOffset;
const valueAtAddressOffset = @import("../io.zig").valueAtAddressOffset;

const log = std.log.scoped(.nds7_io);

pub const Io = struct {
    shared: *SharedIo,

    pub fn init(io: *SharedIo) @This() {
        return .{ .shared = io };
    }
};

pub fn read(bus: *const Bus, comptime T: type, address: u32) T {
    return switch (T) {
        u32 => switch (address) {
            0x0400_0208 => @intFromBool(bus.io.shared.ime),
            0x0400_0210 => bus.io.shared.ie,
            0x0400_0214 => bus.io.shared.irq,
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u16 => switch (address) {
            0x0400_0180 => @truncate(bus.io.shared.ipc_sync.raw),
            0x0400_0184 => @truncate(bus.io.shared.ipc_fifo_cnt.raw),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u8 => switch (address) {
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        else => @compileError(T ++ " is an unsupported bus read type"),
    };
}

pub fn write(bus: *Bus, comptime T: type, address: u32, value: T) void {
    switch (T) {
        u32 => switch (address) {
            0x0400_0208 => bus.io.shared.ime = value & 1 == 1,
            0x0400_0210 => bus.io.shared.ie = value,
            0x0400_0214 => bus.io.shared.irq = value,
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u16 => switch (address) {
            0x0400_0180 => bus.io.shared.ipc_sync.raw = value,
            0x0400_0184 => bus.io.shared.ipc_fifo_cnt.raw = value,
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u8 => switch (address) {
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        else => @compileError(T ++ " is an unsupported bus write type"),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
