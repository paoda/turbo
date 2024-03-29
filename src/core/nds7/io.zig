const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Ppu = @import("../ppu.zig").Ppu;

const Bus = @import("Bus.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const masks = @import("../io.zig").masks;

const IntEnable = @import("../io.zig").IntEnable;
const IntRequest = @import("../io.zig").IntEnable;

const dma = @import("dma.zig");

const log = std.log.scoped(.nds7_io);

pub const Io = struct {
    shr: *SharedCtx.Io,

    /// IME - Interrupt Master Enable
    /// Read/Write
    ime: bool = false,

    /// IE -  Interrupt Enable
    /// Read/Write
    ie: IntEnable = .{ .raw = 0x0000_0000 },

    /// IF - Interrupt Request
    /// Read/Write
    irq: IntRequest = .{ .raw = 0x0000_0000 },

    /// POSTFLG - Post Boot Flag
    /// Read/Write
    postflg: PostFlag = .in_progress,

    /// HALTCNT - Low Power Mode Control
    /// Read/Write
    haltcnt: Haltcnt = .execute,

    ppu: ?*Ppu.Io = null,

    pub fn init(io: *SharedCtx.Io) @This() {
        return .{ .shr = io };
    }

    pub fn configure(self: *@This(), ppu: *Ppu) void {
        self.ppu = &ppu.io;
    }
};

pub fn read(bus: *const Bus, comptime T: type, address: u32) T {
    return switch (T) {
        u32 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DC => dma.read(T, &bus.dma, address) orelse 0x000_0000,

            // Timers
            0x0400_0100...0x0400_010C => warn("TODO(timer): read(T: {}, addr: 0x{X:0>8}) {}", .{ T, address, T }),

            0x0400_0180 => bus.io.shr.ipc._nds7.sync.raw,
            0x0400_0208 => @intFromBool(bus.io.ime),
            0x0400_0210 => bus.io.ie.raw,
            0x0400_0214 => bus.io.irq.raw,

            0x0410_0000 => bus.io.shr.ipc.recv(.nds7),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u16 => switch (address) {
            0x0400_0004 => bus.io.ppu.?.nds7.dispstat.raw,
            // DMA Transfers
            0x0400_00B0...0x0400_00DE => dma.read(T, &bus.dma, address) orelse 0x0000,

            // Timers
            0x0400_0100...0x0400_010E => warn("TODO(timer): read(T: {}, addr: 0x{X:0>8}) {}", .{ T, address, T }),

            0x0400_0130 => bus.io.shr.input.keyinput().raw,
            0x0400_0136 => bus.io.shr.input.extkeyin().raw,

            0x0400_0180 => @truncate(bus.io.shr.ipc._nds7.sync.raw),
            0x0400_0184 => @truncate(bus.io.shr.ipc._nds7.cnt.raw),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u8 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DF => dma.read(T, &bus.dma, address) orelse 0x00,

            // Timers
            0x0400_0100...0x0400_010F => warn("TODO(timer): read(T: {}, addr: 0x{X:0>8}) {}", .{ T, address, T }),

            // RTC
            0x0400_0138 => warn("TODO(rtc): read(T: {}, addr: 0x{X:0>8}) {}", .{ T, address, T }),

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
            0x0400_00B0...0x0400_00DC => dma.write(T, &bus.dma, address, value),

            // Timers
            0x0400_0100...0x0400_010C => log.warn("TODO(timer): write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),

            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds7, value),
            0x0400_0208 => bus.io.ime = value & 1 == 1,
            0x0400_0210 => bus.io.ie.raw = value,
            0x0400_0214 => bus.io.irq.raw &= ~value,

            0x0400_0188 => bus.io.shr.ipc.send(.nds7, value),
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u16 => switch (address) {
            0x0400_0004 => bus.io.ppu.?.nds7.dispstat.raw = value,

            // DMA Transfers
            0x0400_00B0...0x0400_00DE => dma.write(T, &bus.dma, address, value),

            // Timers
            0x0400_0100...0x0400_010E => log.warn("TODO(timer): write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),

            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds7, value),
            0x0400_0184 => bus.io.shr.ipc.setIpcFifoCnt(.nds7, value),

            0x0400_0208 => bus.io.ime = value & 1 == 1,
            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>4})", .{ T, address, value }),
        },
        u8 => switch (address) {
            // DMA Transfers
            0x0400_00B0...0x0400_00DF => dma.write(T, &bus.dma, address, value),

            // Timers
            0x0400_0100...0x0400_010F => log.warn("TODO(timer): write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),

            // RTC
            0x0400_0138 => log.warn("TODO(rtc): write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),

            0x0400_0208 => bus.io.ime = value & 1 == 1,

            0x0400_0301 => switch ((value >> 6) & 0b11) {
                0b00 => bus.io.haltcnt = .execute,
                0b10 => bus.io.haltcnt = .halt,
                else => |val| {
                    const tag: Haltcnt = @enumFromInt(val);
                    log.err("TODO: Implement {}", .{tag});
                },
            },
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

const Haltcnt = enum(u2) {
    execute = 0,
    gba_mode,
    halt,
    sleep,
};

const PostFlag = enum(u8) { in_progress = 0, completed };

pub const DmaCnt = extern union {
    dad_adj: Bitfield(u16, 5, 2),
    sad_adj: Bitfield(u16, 7, 2),
    repeat: Bit(u16, 9),
    transfer_type: Bit(u16, 10),
    start_timing: Bitfield(u16, 12, 2),
    irq: Bit(u16, 14),
    enabled: Bit(u16, 15),
    raw: u16,
};
