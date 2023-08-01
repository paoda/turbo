const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Bus = @import("Bus.zig");
const SharedIo = @import("../io.zig").Io;
const writeToAddressOffset = @import("../io.zig").writeToAddressOffset;
const valueAtAddressOffset = @import("../io.zig").valueAtAddressOffset;

const log = std.log.scoped(.nds9_io);

pub const Io = struct {
    shared: *SharedIo,

    /// POWCNT1 - Graphics Power Control
    /// Read / Write
    powcnt: PowCnt = .{ .raw = 0x0000_0000 },

    // Read Only
    keyinput: AtomicKeyInput = .{},

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
            0x0400_0000...0x0400_0003 => valueAtAddressOffset(u32, address, bus.ppu.io.dispcnt_a.raw),
            0x0400_0004...0x0400_0005 => valueAtAddressOffset(u16, address, bus.ppu.io.dispstat.raw),

            0x0400_0130...0x0400_0131 => valueAtAddressOffset(u16, address, bus.io.keyinput.load(.Monotonic)),
            0x0400_0180...0x0400_0183 => valueAtAddressOffset(u32, address, bus.io.shared.ipc_sync.raw),
            0x0400_0184...0x0400_0187 => valueAtAddressOffset(u32, address, bus.io.shared.ipc_fifo_cnt.raw),

            0x0400_0208...0x0400_020B => valueAtAddressOffset(u32, address, @intFromBool(bus.io.shared.ime)),

            0x0400_0304...0x0400_0307 => valueAtAddressOffset(u32, address, bus.io.powcnt.raw),
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
            0x0400_0000...0x0400_0003 => writeToAddressOffset(&bus.ppu.io.dispcnt_a.raw, address, value),

            0x0400_0180...0x0400_0183 => writeToAddressOffset(&bus.io.shared.ipc_sync.raw, address, value),
            0x0400_0184...0x0400_0187 => writeToAddressOffset(&bus.io.shared.ipc_fifo_cnt.raw, address, value),

            0x0400_0208 => bus.io.shared.ime = value & 1 == 1,
            0x0400_0209...0x0400_020B => {}, // unused bytes from IME

            0x0400_0240 => bus.ppu.io.vramcnt_a.raw = value,
            0x0400_0241 => bus.ppu.io.vramcnt_b.raw = value,
            0x0400_0242 => bus.ppu.io.vramcnt_c.raw = value,
            0x0400_0243 => bus.ppu.io.vramcnt_d.raw = value,

            0x0400_0304...0x0400_0307 => writeToAddressOffset(&bus.io.powcnt.raw, address, value),
            else => log.warn("unexpected write: 0x{X:}u8 -> 0x{X:0>8}", .{ value, address }),
        },
        else => @compileError(T ++ " is an unsupported bus write type"),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}

const PowCnt = extern union {
    // Enable flag for both LCDs
    lcd: Bit(u32, 0),
    gfx_2da: Bit(u32, 1),
    render_3d: Bit(u32, 2),
    geometry_3d: Bit(u32, 3),
    gfx_2db: Bit(u32, 9),
    display_swap: Bit(u32, 15),
    raw: u32,
};

pub const DispcntA = extern union {
    bg_mode: Bitfield(u32, 0, 2),

    /// toggle between 2D and 3D for BG0
    bg0_dimension: Bit(u32, 3),
    tile_obj_mapping: Bit(u32, 4),
    bitmap_obj_2d_dimension: Bit(u32, 5),
    bitmap_obj_mapping: Bit(u32, 6),
    forced_blank: Bit(u32, 7),
    bg_enable: Bitfield(u32, 8, 4),
    obj_enable: Bit(u32, 12),
    win_enable: Bitfield(u32, 13, 2),
    obj_win_enable: Bit(u32, 15),
    display_mode: Bitfield(u32, 16, 2),
    vram_block: Bitfield(u32, 18, 2),
    tile_obj_1d_boundary: Bitfield(u32, 20, 2),
    bitmap_obj_1d_boundary: Bit(u32, 22),
    obj_during_hblank: Bit(u32, 23),
    character_base: Bitfield(u32, 24, 3),
    screen_base: Bitfield(u32, 27, 2),
    bg_ext_pal_enable: Bit(u32, 30),
    obj_ext_pal_enable: Bit(u32, 31),
    raw: u32,
};

pub const Vramcnt = struct {
    /// Can be used by VRAM-A and VRAM-B
    pub const A = extern union {
        mst: Bitfield(u8, 0, 2),
        offset: Bitfield(u8, 3, 2),
        enable: Bit(u8, 7),
        raw: u8,
    };

    /// Can be used by VRAM-C, VRAM-D, VRAM-F, VRAM-G
    pub const C = extern union {
        mst: Bitfield(u8, 0, 3),
        offset: Bitfield(u8, 3, 2),
        enable: Bit(u8, 7),
        raw: u8,
    };

    /// Can be used by VRAM-E
    pub const E = extern union {
        mst: Bitfield(u8, 0, 3),
        enable: Bit(u8, 7),
        raw: u8,
    };

    /// can be used by VRAM-H and VRAM-I
    pub const H = extern union {
        mst: Bitfield(u8, 0, 2),
        enable: Bit(u8, 7),
        raw: u8,
    };
};

// Compared to the GBA:
//    - LY/LYC values are now 9-bits
pub const Vcount = extern union {
    scanline: Bitfield(u16, 0, 9),
    raw: u16,
};

pub const Dispstat = extern union {
    vblank: Bit(u16, 0),
    hblank: Bit(u16, 1),
    coincidence: Bit(u16, 2),
    vblank_irq: Bit(u16, 3),
    hblank_irq: Bit(u16, 4),
    vcount_irq: Bit(u16, 5),

    /// FIXME: confirm that I'm reading DISPSTAT.7 correctly into LYC
    lyc: Bitfield(u16, 7, 9),
    raw: u16,
};

/// Read Only
/// 0 = Pressed, 1 = Released
pub const KeyInput = extern union {
    a: Bit(u16, 0),
    b: Bit(u16, 1),
    select: Bit(u16, 2),
    start: Bit(u16, 3),
    right: Bit(u16, 4),
    left: Bit(u16, 5),
    up: Bit(u16, 6),
    down: Bit(u16, 7),
    shoulder_r: Bit(u16, 8),
    shoulder_l: Bit(u16, 9),
    raw: u16,
};

const AtomicKeyInput = struct {
    const Self = @This();
    const Ordering = std.atomic.Ordering;

    inner: KeyInput = .{ .raw = 0x03FF },

    pub inline fn load(self: *const Self, comptime ordering: Ordering) u16 {
        return switch (ordering) {
            .AcqRel, .Release => @compileError("not supported for atomic loads"),
            else => @atomicLoad(u16, &self.inner.raw, ordering),
        };
    }

    pub inline fn fetchOr(self: *Self, value: u16, comptime ordering: Ordering) void {
        _ = @atomicRmw(u16, &self.inner.raw, .Or, value, ordering);
    }

    pub inline fn fetchAnd(self: *Self, value: u16, comptime ordering: Ordering) void {
        _ = @atomicRmw(u16, &self.inner.raw, .And, value, ordering);
    }
};
