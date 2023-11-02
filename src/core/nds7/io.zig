const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Bus = @import("Bus.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const masks = @import("../io.zig").masks;

const IntEnable = @import("../io.zig").IntEnable;
const IntRequest = @import("../io.zig").IntEnable;

const log = std.log.scoped(.nds7_io);

pub const Io = struct {
    shr: *SharedCtx.Io,

    /// Interrupt Master Enable
    /// Read/Write
    ime: bool = false,

    /// Interrupt Enable
    /// Read/Write
    ///
    /// Caller must cast the `u32` to either `nds7.IntEnable` or `nds9.IntEnable`
    ie: IntEnable = .{ .raw = 0x0000_0000 },

    /// IF - Interrupt Request
    /// Read/Write
    ///
    /// Caller must cast the `u32` to either `nds7.IntRequest` or `nds9.IntRequest`
    irq: IntRequest = .{ .raw = 0x0000_0000 },

    /// Post Boot Flag
    /// Read/Write
    ///
    /// Caller must cast the `u8` to either `nds7.PostFlg` or `nds9.PostFlg`
    postflg: PostFlag = .in_progress,

    pub fn init(io: *SharedCtx.Io) @This() {
        return .{ .shr = io };
    }
};

pub fn read(bus: *const Bus, comptime T: type, address: u32) T {
    return switch (T) {
        u32 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DC => warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010C => warn("TODO: Implement Timer", .{}),

            0x0400_0180 => bus.io.shr.ipc._nds7.sync.raw,
            0x0400_0208 => @intFromBool(bus.io.ime),
            0x0400_0210 => bus.io.ie.raw,
            0x0400_0214 => bus.io.irq.raw,

            0x0410_0000 => bus.io.shr.ipc.recv(.nds7),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u16 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DE => warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010E => warn("TODO: Implement Timer", .{}),

            0x0400_0180 => @truncate(bus.io.shr.ipc._nds7.sync.raw),
            0x0400_0184 => @truncate(bus.io.shr.ipc._nds7.cnt.raw),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u8 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DF => warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010F => warn("TODO: Implement Timer", .{}),

            0x0400_0240 => bus.vram.stat().raw,
            0x0400_0241 => bus.io.shr.wramcnt.raw,

            0x0400_0300 => @intFromEnum(bus.io.postflg),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        else => @compileError(T ++ " is an unsupported bus read type"),
    };
}

pub fn write(bus: *Bus, comptime T: type, address: u32, value: T) void {
    switch (T) {
        u32 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DC => log.warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010C => log.warn("TODO: Implement Timer", .{}),

            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds7, value),
            0x0400_0208 => bus.io.ime = value & 1 == 1,
            0x0400_0210 => bus.io.ie.raw = value,
            0x0400_0214 => bus.io.irq.raw &= ~value,

            0x0400_0188 => bus.io.shr.ipc.send(.nds7, value),
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u16 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DE => log.warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010E => log.warn("TODO: Implement Timer", .{}),

            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds7, value),
            0x0400_0184 => bus.io.shr.ipc.setIpcFifoCnt(.nds7, value),
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>4})", .{ T, address, value }),
        },
        u8 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DF => log.warn("TODO: Implement DMA", .{}),

            // Timers
            0x0400_0100...0x0400_010F => log.warn("TODO: Implement Timer", .{}),

            0x0400_0208 => bus.io.ime = value & 1 == 1,
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>2})", .{ T, address, value }),
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

const PostFlag = enum(u8) { in_progress = 0, completed };
