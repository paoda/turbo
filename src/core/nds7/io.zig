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
        // zig fmt: off
        u32 => 
              @as(T, read(bus, u8, address + 3)) << 24
            | @as(T, read(bus, u8, address + 2)) << 16
            | @as(T, read(bus, u8, address + 1)) << 8
            | read(bus, u8, address + 0) << 0,
        // zig fmt: on
        u16 => @as(T, read(bus, u8, address + 1)) << 8 | read(bus, u8, address),
        u8 => switch (address) {
            0x0400_0180...0x0400_0183 => valueAtAddressOffset(u32, address, bus.io.shared.ipc_sync.raw),
            0x0400_0184...0x0400_0187 => valueAtAddressOffset(u32, address, bus.io.shared.ipc_fifo_cnt.raw),

            0x0400_0208...0x0400_020B => valueAtAddressOffset(u32, address, @intFromBool(bus.io.shared.ime)),

            else => warn("unexpected read: 0x{X:0>8}", .{address}),
        },
        else => @compileError(T ++ " is an unsupported bus read type"),
    };
}

pub fn write(bus: *Bus, comptime T: type, address: u32, value: T) void {
    switch (T) {
        u32 => {
            write(bus, u8, address + 3, @as(u8, @truncate(value >> 24)));
            write(bus, u8, address + 2, @as(u8, @truncate(value >> 16)));
            write(bus, u8, address + 1, @as(u8, @truncate(value >> 8)));
            write(bus, u8, address + 0, @as(u8, @truncate(value >> 0)));
        },
        u16 => {
            write(bus, u8, address + 1, @as(u8, @truncate(value >> 8)));
            write(bus, u8, address + 0, @as(u8, @truncate(value >> 0)));
        },
        u8 => switch (address) {
            0x0400_0180...0x0400_0183 => writeToAddressOffset(&bus.io.shared.ipc_sync.raw, address, value),
            0x0400_0184...0x0400_0187 => writeToAddressOffset(&bus.io.shared.ipc_fifo_cnt.raw, address, value),

            0x0400_0208 => bus.io.shared.ime = value & 1 == 1,
            0x0400_0209...0x0400_020B => {}, // unused bytes from IME

            else => log.warn("unexpected write: 0x{X:}u8 -> 0x{X:0>8}", .{ value, address }),
        },
        else => @compileError(T ++ " is an unsupported bus write type"),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
