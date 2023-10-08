const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Bus = @import("Bus.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const masks = @import("../io.zig").masks;

const log = std.log.scoped(.nds7_io);

pub const Io = struct {
    shr: *SharedCtx.Io,

    pub fn init(io: *SharedCtx.Io) @This() {
        return .{ .shr = io };
    }
};

pub fn read(bus: *const Bus, comptime T: type, address: u32) T {
    return switch (T) {
        u32 => switch (address) {
            0x0400_0208 => @intFromBool(bus.io.shr.ime),
            0x0400_0210 => bus.io.shr.ie,
            0x0400_0214 => bus.io.shr.irq,

            0x0410_0000 => bus.io.shr.ipc_fifo.recv(.nds7),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u16 => switch (address) {
            0x0400_0180 => @truncate(bus.io.shr.ipc_fifo._nds7.sync.raw),
            0x0400_0184 => @truncate(bus.io.shr.ipc_fifo._nds7.cnt.raw),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u8 => switch (address) {
            0x0400_0240 => bus.vram.stat().raw,
            0x0400_0241 => bus.io.shr.wramcnt.raw,
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        else => @compileError(T ++ " is an unsupported bus read type"),
    };
}

pub fn write(bus: *Bus, comptime T: type, address: u32, value: T) void {
    switch (T) {
        u32 => switch (address) {
            0x0400_0208 => bus.io.shr.ime = value & 1 == 1,
            0x0400_0210 => bus.io.shr.ie = value,
            0x0400_0214 => bus.io.shr.irq = value,

            0x0400_0188 => bus.io.shr.ipc_fifo.send(.nds7, value) catch |e| std.debug.panic("FIFO error: {}", .{e}),
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u16 => switch (address) {
            0x0400_0180 => bus.io.shr.ipc_fifo.setIpcSync(.nds7, value),
            0x0400_0184 => bus.io.shr.ipc_fifo.setIpcFifoCnt(.nds7, value),
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

pub const Vramstat = extern union {
    vramc_enabled: Bit(u8, 0),
    vramd_enabled: Bit(u8, 1),
    raw: u8,
};
