const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const Bus = @import("Bus.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const masks = @import("../io.zig").masks;

const IntEnable = @import("../io.zig").IntEnable;
const IntRequest = @import("../io.zig").IntEnable;

const sext = @import("../../util.zig").sext;
const shift = @import("../../util.zig").shift;

const log = std.log.scoped(.nds9_io);

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

    /// POWCNT1 - Graphics Power Control
    /// Read / Write
    powcnt: PowCnt = .{ .raw = 0x0000_0000 },

    // Read Only
    keyinput: AtomicKeyInput = .{},

    /// DS Maths
    div: Divisor = .{},
    sqrt: SquareRootUnit = .{},

    pub fn init(io: *SharedCtx.Io) @This() {
        return .{ .shr = io };
    }
};

pub fn read(bus: *const Bus, comptime T: type, address: u32) T {
    return switch (T) {
        u32 => switch (address) {
            0x0400_0180 => bus.io.shr.ipc._nds9.sync.raw,
            0x0400_0208 => @intFromBool(bus.io.ime),
            0x0400_0210 => bus.io.ie.raw,
            0x0400_0214 => bus.io.irq.raw,

            0x0400_02A0, 0x0400_02A4 => @truncate(bus.io.div.result >> shift(u64, address)),
            0x0400_02A8, 0x0400_02AC => @truncate(bus.io.div.remainder >> shift(u64, address)),
            0x0400_02B4 => @truncate(bus.io.sqrt.result),

            0x0400_4008 => 0x0000_0000, // Lets software know this is NOT a DSi

            0x0410_0000 => bus.io.shr.ipc.recv(.nds9),
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u16 => switch (address) {
            0x0400_0004 => bus.ppu.io.dispstat.raw,
            0x0400_0130 => bus.io.keyinput.load(.Monotonic),

            0x0400_0180 => @truncate(bus.io.shr.ipc._nds9.sync.raw),
            0x0400_0184 => @truncate(bus.io.shr.ipc._nds9.cnt.raw),

            0x0400_0280 => @truncate(bus.io.div.cnt.raw),
            0x0400_02B0 => @truncate(bus.io.sqrt.cnt.raw),

            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        u8 => switch (address) {
            0x0400_4000 => 0x00, // Lets software know this is NOT a DSi
            else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
        },
        else => @compileError(T ++ " is an unsupported bus read type"),
    };
}

const subset = @import("../../util.zig").subset;

pub fn write(bus: *Bus, comptime T: type, address: u32, value: T) void {
    switch (T) {
        u32 => switch (address) {
            0x0400_0000 => bus.ppu.io.dispcnt_a.raw = value,
            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds9, value),
            0x0400_0184 => bus.io.shr.ipc.setIpcFifoCnt(.nds9, value),
            0x0400_0188 => bus.io.shr.ipc.send(.nds9, value),

            0x0400_0240 => {
                bus.ppu.vram.io.cnt_a.raw = @truncate(value >> 0); // 0x0400_0240
                bus.ppu.vram.io.cnt_b.raw = @truncate(value >> 8); // 0x0400_0241
                bus.ppu.vram.io.cnt_c.raw = @truncate(value >> 16); // 0x0400_0242
                bus.ppu.vram.io.cnt_d.raw = @truncate(value >> 24); // 0x0400_0243
            },

            0x0400_0208 => bus.io.ime = value & 1 == 1,
            0x0400_0210 => bus.io.ie.raw = value,
            0x0400_0214 => bus.io.irq.raw &= ~value,

            0x0400_0290, 0x0400_0294 => {
                bus.io.div.numerator = subset(u64, u32, address, bus.io.div.numerator, value);
                bus.io.div.schedule(bus.scheduler);
            },

            0x0400_0298, 0x0400_029C => {
                bus.io.div.denominator = subset(u64, u32, address, bus.io.div.denominator, value);
                bus.io.div.schedule(bus.scheduler);
            },

            0x0400_02B8, 0x0400_02BC => {
                bus.io.sqrt.param = subset(u64, u32, address, bus.io.sqrt.param, value);
                bus.io.sqrt.schedule(bus.scheduler);
            },

            0x0400_0304 => bus.io.powcnt.raw = value,

            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
        },
        u16 => switch (address) {
            0x0400_0180 => bus.io.shr.ipc.setIpcSync(.nds9, value),
            0x0400_0184 => bus.io.shr.ipc.setIpcFifoCnt(.nds9, value),
            0x0400_0208 => bus.io.ime = value & 1 == 1,

            0x0400_0280 => {
                bus.io.div.cnt.raw = value;
                bus.io.div.schedule(bus.scheduler);
            },

            0x0400_02B0 => {
                bus.io.sqrt.cnt.raw = value;
                bus.io.sqrt.schedule(bus.scheduler);
            },

            0x0400_0304 => bus.io.powcnt.raw = value,

            else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>4})", .{ T, address, value }),
        },
        u8 => switch (address) {
            0x0400_0240 => {
                bus.ppu.vram.io.cnt_a.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0241 => {
                bus.ppu.vram.io.cnt_b.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0242 => {
                bus.ppu.vram.io.cnt_c.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0243 => {
                bus.ppu.vram.io.cnt_d.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0244 => {
                bus.ppu.vram.io.cnt_e.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0245 => {
                bus.ppu.vram.io.cnt_f.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0246 => {
                bus.ppu.vram.io.cnt_g.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0247 => {
                bus.io.shr.wramcnt.raw = value;
                bus.wram.update(bus.io.shr.wramcnt);
            },
            0x0400_0248 => {
                bus.ppu.vram.io.cnt_h.raw = value;
                bus.ppu.vram.update();
            },
            0x0400_0249 => {
                bus.ppu.vram.io.cnt_i.raw = value;
                bus.ppu.vram.update();
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

const PowCnt = extern union {
    // Enable flag for both LCDs
    lcd: Bit(u32, 0),
    engine2d_a: Bit(u32, 1),
    render3d: Bit(u32, 2),
    geometry3d: Bit(u32, 3),
    engine2d_b: Bit(u32, 9),
    display_swap: Bit(u32, 15),
    raw: u32,
};

/// Divisor
const Divisor = struct {
    const Scheduler = @import("../Scheduler.zig");

    /// DIVCNT - Division Control (R/W)
    cnt: Cnt = .{ .raw = 0x0000_0000 },
    /// DIV_NUMER - division numerator (R/W)
    numerator: u64 = 0x0000_0000_0000_0000,
    /// DIV_DENOM - division denominator (R/W)
    denominator: u64 = 0x0000_0000_0000_0000,

    /// DIV_RESULT - division quotient (R)
    result: u64 = 0x0000_0000_0000_0000,
    /// DIVREM_RESULT - remainder
    remainder: u64 = 0x0000_0000_0000_0000,

    const Cnt = extern union {
        mode: Bitfield(u32, 0, 2),
        div_by_zero: Bit(u32, 14),
        busy: Bit(u32, 15),
        raw: u32,
    };

    pub fn schedule(self: *@This(), scheduler: *Scheduler) void {
        defer self.cnt.busy.set();

        const cycle_count: u64 = switch (self.cnt.mode.read()) {
            0b00 => 18,
            0b01, 0b10, 0b11 => 34,
        };

        scheduler.remove(.{ .nds9 = .div });
        scheduler.push(.{ .nds9 = .div }, cycle_count);
    }

    pub fn onDivCalc(self: *@This()) void {
        defer self.cnt.busy.unset();
        self.cnt.div_by_zero.write(self.denominator == 0);

        switch (self.cnt.mode.read()) {
            0b00 => {
                // 32bit / 32bit = 32bit , 32bit
                const left = sext(i64, i32, self.numerator);
                const right = sext(i64, i32, self.denominator);

                if (right == 0) {
                    self.remainder = @bitCast(left);
                    self.result = if (left >> 63 & 1 == 1) @as(u64, 1) else @bitCast(@as(i64, -1));

                    // FIXME(chore): replace `>> 32 ) << 32` with mask
                    self.result = masks.mask(self.result, (~self.result >> 32) << 32, 0xFFFF_FFFF << 32);

                    return;
                }

                self.result = @bitCast(@divTrunc(left, right));
                self.remainder = @bitCast(@rem(left, right));
            },
            0b01, 0b11 => {
                // 64bit / 32bit = 64bit , 32bit
                const left = sext(i128, i64, self.numerator);
                const right = sext(i128, i32, self.denominator);

                if (right == 0) {
                    self.remainder = @bitCast(@as(i64, @truncate(left)));
                    self.result = if (left >> 63 & 1 == 1) @as(u64, 1) else @bitCast(@as(i64, -1));

                    return;
                }

                self.result = @bitCast(@as(i64, @truncate(@divTrunc(left, right))));
                self.remainder = @bitCast(@as(i64, @truncate(@rem(left, right))));
            },
            0b10 => {
                // 64bit / 64bit = 64bit , 64bit
                const left = sext(i128, i64, self.numerator);
                const right = sext(i128, i64, self.denominator);

                if (right == 0) {
                    self.remainder = @bitCast(@as(i64, @truncate(left)));
                    self.result = if (left >> 63 & 1 == 1) @as(u64, 1) else @bitCast(@as(i64, -1));

                    return;
                }

                self.result = @bitCast(@as(i64, @truncate(@divTrunc(left, right))));
                self.remainder = @bitCast(@as(i64, @truncate(@rem(left, right))));
            },
        }
    }
};

/// Square Root Unit
const SquareRootUnit = struct {
    const Scheduler = @import("../Scheduler.zig");

    /// SQRTCNT - Division Control (R/W)
    cnt: Cnt = .{ .raw = 0x0000_0000 },

    /// SQRT_RESULT - square root result (R)
    result: u32 = 0x0000_0000,
    /// SQRT_PARAM - square root paramater input (R/W)
    param: u64 = 0x0000_0000_0000_0000,

    const Cnt = extern union {
        mode: Bit(u32, 0),
        busy: Bit(u32, 15),
        raw: u32,
    };

    pub fn schedule(self: *@This(), scheduler: *Scheduler) void {
        defer self.cnt.busy.set();

        scheduler.remove(.{ .nds9 = .sqrt });
        scheduler.push(.{ .nds9 = .sqrt }, 13); // always takes 13 cycles
    }

    pub fn onSqrtCalc(self: *@This()) void {
        defer self.cnt.busy.unset();

        const mask: u64 = blk: {
            const value: u64 = @intFromBool(!self.cnt.mode.read());
            break :blk (value << 32) -% 1;
        };

        self.result = @truncate(std.math.sqrt(self.param & mask));
    }
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
