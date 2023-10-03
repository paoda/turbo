const std = @import("std");
const Allocator = std.mem.Allocator;

const Scheduler = @import("Scheduler.zig");
const System = @import("emu.zig").System;

pub const screen_width = 256;
pub const screen_height = 192;
const KiB = 0x400;

const cycles_per_dot = 6;

pub const Ppu = struct {
    fb: FrameBuffer,

    vram: *Vram,

    io: Io = .{},

    const Io = struct {
        const nds9 = @import("nds9/io.zig");

        /// Read / Write
        dispcnt_a: nds9.DispcntA = .{ .raw = 0x0000_0000 },
        /// Read / Write
        dispstat: nds9.Dispstat = .{ .raw = 0x0000 },

        /// Read-Only
        vcount: nds9.Vcount = .{ .raw = 0x0000 },
    };

    pub fn init(allocator: Allocator, vram: *Vram) !@This() {
        return .{
            .fb = try FrameBuffer.init(allocator),
            .vram = vram,
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.fb.deinit(allocator);
    }

    pub fn drawScanline(self: *@This(), bus: *System.Bus9) void {
        const bg_mode = self.io.dispcnt_a.display_mode.read();
        const scanline = self.io.vcount.scanline.read();

        switch (bg_mode) {
            0x0 => {},
            0x1 => {},
            0x2 => {
                // Draw Top Screen
                {
                    const buf = self.fb.top(.back);

                    const ptr: *[screen_width * screen_height]u32 = @ptrCast(@alignCast(buf.ptr));
                    const scanline_ptr = ptr[screen_width * @as(u32, scanline) ..][0..screen_width];

                    const base_addr: u32 = 0x0680_0000 + (screen_width * @sizeOf(u16)) * @as(u32, scanline);

                    // FIXME: I don't think it's okay to be accessing the ARM9 Bus instead of just working with
                    // memory directly. However, I do understand that VRAM-A, VRAM-B might change things

                    for (scanline_ptr, 0..) |*rgba, i| {
                        const addr = base_addr + @as(u32, @intCast(i)) * @sizeOf(u16);
                        rgba.* = rgba888(bus.dbgRead(u16, addr));
                    }
                }
            },
            0x3 => {},
        }
    }

    /// HDraw -> HBlank
    pub fn onHdrawEnd(self: *@This(), scheduler: *Scheduler, late: u64) void {
        const dots_in_hblank = 99;
        std.debug.assert(self.io.dispstat.hblank.read() == false);
        std.debug.assert(self.io.dispstat.vblank.read() == false);

        // TODO: Signal HBlank IRQ

        self.io.dispstat.hblank.set();
        scheduler.push(.{ .nds9 = .hblank }, dots_in_hblank * cycles_per_dot -| late);
    }

    pub fn onHblankEnd(self: *@This(), scheduler: *Scheduler, late: u64) void {
        const scanline_count = 192 + 71;

        const prev_scanline = self.io.vcount.scanline.read();
        const scanline = (prev_scanline + 1) % scanline_count;

        self.io.vcount.scanline.write(scanline);
        self.io.dispstat.hblank.unset();

        const coincidence = scanline == self.io.dispstat.lyc.read();
        self.io.dispstat.coincidence.write(coincidence);

        // TODO: LYC == LY IRQ

        if (scanline < 192) {
            std.debug.assert(self.io.dispstat.vblank.read() == false);
            std.debug.assert(self.io.dispstat.hblank.read() == false);

            // Draw Another Scanline
            const dots_in_hdraw = 256;
            return scheduler.push(.{ .nds9 = .draw }, dots_in_hdraw * cycles_per_dot -| late);
        }

        if (scanline == 192) {
            // Transition from Hblank to Vblank
            self.fb.swap();
            self.io.dispstat.vblank.set();

            // TODO: Signal VBlank IRQ
        }

        if (scanline == 262) self.io.dispstat.vblank.unset();
        std.debug.assert(self.io.dispstat.vblank.read() == (scanline != 262));

        const dots_in_scanline = 256 + 99;
        scheduler.push(.{ .nds9 = .hblank }, dots_in_scanline * cycles_per_dot -| late);
    }
};

pub const FrameBuffer = struct {
    const len = (screen_width * @sizeOf(u32)) * screen_height;

    current: u1 = 0,

    ptr: *[len * 4]u8,

    const Position = enum { top, bottom };
    const Layer = enum { front, back };

    pub fn init(allocator: Allocator) !@This() {
        const ptr = try allocator.create([len * 4]u8);

        return .{ .ptr = ptr };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.destroy(self.ptr);
    }

    fn get(self: @This(), comptime position: Position, comptime layer: Layer) *[len]u8 {
        const toggle: usize = if (layer == .front) self.current else ~self.current;

        return switch (position) {
            .top => self.ptr[len * toggle ..][0..len],
            .bottom => self.ptr[(len << 1) + len * toggle ..][0..len],
        };
    }

    pub fn swap(self: *@This()) void {
        self.current = ~self.current;
    }

    pub fn top(self: @This(), comptime layer: Layer) *[len]u8 {
        return self.get(.top, layer);
    }

    pub fn btm(self: @This(), comptime layer: Layer) *[len]u8 {
        return self.get(.bottom, layer);
    }
};

inline fn rgba888(bgr555: u16) u32 {
    const b: u32 = bgr555 >> 10 & 0x1F;
    const g: u32 = bgr555 >> 5 & 0x1F;
    const r: u32 = bgr555 & 0x1F;

    // zig fmt: off
    return (r << 3 | r >> 2) << 24
        |  (g << 3 | g >> 2) << 16
        |  (b << 3 | b >> 2) << 8
        |  0xFF;
    // zig fmt: on
}

pub const Vram = struct {
    const page_size = 16 * KiB; // smallest allocation is 16 KiB
    const addr_space_size = 0x0100_0000; // 0x0600_0000 -> 0x06FF_FFFF (inclusive)
    const table_len = addr_space_size / page_size;
    const buf_len = 656 * KiB;

    const IntFittingRange = std.math.IntFittingRange;
    const log = std.log.scoped(.vram);

    io: Io = .{},

    _buf: *[buf_len]u8,
    nds9_table: *const [table_len]?[*]u8,
    nds7_table: *const [table_len]?[*]u8,

    const Io = struct {
        const nds9 = @import("nds9/io.zig");
        const nds7 = @import("nds7/io.zig");
        pub const Vramstat = @import("nds7/io.zig").Vramstat;

        stat: nds7.Vramstat = .{ .raw = 0x00 },

        /// Write-Only (according to melonDS these are readable lol)
        cnt_a: nds9.Vramcnt.A = .{ .raw = 0x00 },
        cnt_b: nds9.Vramcnt.A = .{ .raw = 0x00 },
        cnt_c: nds9.Vramcnt.C = .{ .raw = 0x00 },
        cnt_d: nds9.Vramcnt.C = .{ .raw = 0x00 },
        cnt_e: nds9.Vramcnt.E = .{ .raw = 0x00 },
        cnt_f: nds9.Vramcnt.C = .{ .raw = 0x00 },
        cnt_g: nds9.Vramcnt.C = .{ .raw = 0x00 },
        cnt_h: nds9.Vramcnt.H = .{ .raw = 0x00 },
        cnt_i: nds9.Vramcnt.H = .{ .raw = 0x00 },
    };

    pub fn init(self: *@This(), allocator: Allocator) !void {
        const buf = try allocator.create([buf_len]u8);
        errdefer allocator.destroy(buf);
        @memset(buf, 0);

        const tables = try allocator.alloc(?[*]u8, 2 * table_len);
        @memset(tables, null);

        self.* = .{
            .nds9_table = tables[0..table_len],
            .nds7_table = tables[table_len .. 2 * table_len],
            ._buf = buf,
        };

        // ROMS like redpanda.nds won't write to VRAMCNT before trying to write to VRAM
        // therefore we assume some default allocation (in this casee VRAMCNT_A -> VRAMCNT_I are 0x00)
        self.update();
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.destroy(self._buf);

        const ptr: [*]?[*]const u8 = @ptrCast(@constCast(self.nds9_table));
        allocator.free(ptr[0 .. 2 * table_len]);
    }

    pub fn stat(self: *const @This()) Io.Vramstat {
        const vram_c: u8 = @intFromBool(self.io.cnt_c.enable.read() and self.io.cnt_c.mst.read() == 2);
        const vram_d: u8 = @intFromBool(self.io.cnt_d.enable.read() and self.io.cnt_d.mst.read() == 2);

        return .{ .raw = (vram_d << 1) | vram_c };
    }

    const Range = struct { min: u32, max: u32 };
    const Kind = enum {
        a,
        b,
        c,
        d,
        e,
        f,
        g,
        h,
        i,

        /// In Bytes
        inline fn size(self: @This()) u32 {
            return switch (self) {
                .a => 128 * KiB,
                .b => 128 * KiB,
                .c => 128 * KiB,
                .d => 128 * KiB,
                .e => 64 * KiB,
                .f => 16 * KiB,
                .g => 16 * KiB,
                .h => 32 * KiB,
                .i => 16 * KiB,
            };
        }
    };

    /// max inclusive
    fn range(comptime kind: Kind, mst: u3, offset: u2) Range {
        const ofs: u32 = offset;
        // panic messages are from GBATEK

        return switch (kind) {
            .a => switch (mst) {
                0 => .{ .min = 0x0680_0000, .max = 0x0682_0000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * ofs);
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0640_0000 + (0x0002_0000 * (ofs & 0b01));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_A: Slot OFS(0-3)"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .b => switch (mst) {
                0 => .{ .min = 0x0682_0000, .max = 0x0684_0000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * ofs);
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0640_0000 + (0x0002_0000 * (ofs & 0b01));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_B: Slot OFS(0-3)"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .c => switch (mst) {
                0 => .{ .min = 0x0684_0000, .max = 0x0686_0000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * ofs);
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * (ofs & 0b01));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_C: Slot OFS(0-3)"),
                4 => .{ .min = 0x0620_0000, .max = 0x0620_0000 + kind.size() },
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .d => switch (mst) {
                0 => .{ .min = 0x0686_0000, .max = 0x0688_0000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * ofs);
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0600_0000 + (0x0002_0000 * (ofs & 0b01));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_D: Slot OFS(0-3)"),
                4 => .{ .min = 0x0660_0000, .max = 0x0660_0000 + kind.size() },
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .e => switch (mst) {
                0 => .{ .min = 0x0688_0000, .max = 0x0689_0000 },
                1 => .{ .min = 0x0600_0000, .max = 0x0600_0000 + kind.size() },
                2 => .{ .min = 0x0640_0000, .max = 0x0640_0000 + kind.size() },
                3 => @panic("VRAMCNT_E: Slots 0-3"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .f => switch (mst) {
                0 => .{ .min = 0x0689_0000, .max = 0x0689_4000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0640_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_F: Slot (OFS.0*1)+(OFS.1*4)"),
                4 => @panic("VRAMCNT_F: Slot 0-1 (OFS=0), Slot 2-3 (OFS=1)"),
                5 => @panic("VRAMCNT_F: Slot 0"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .g => switch (mst) {
                0 => .{ .min = 0x0689_4000, .max = 0x0689_8000 },
                1 => blk: {
                    const base = 0x0600_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                2 => blk: {
                    const base = 0x0640_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1));
                    break :blk .{ .min = base, .max = base + kind.size() };
                },
                3 => @panic("VRAMCNT_G: Slot (OFS.0*1)+(OFS.1*4)"),
                4 => @panic("VRAMCNT_G: Slot 0-1 (OFS=0), Slot 2-3 (OFS=1)"),
                5 => @panic("VRAMCNT_G: Slot 0"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .h => switch (mst) {
                0 => .{ .min = 0x0689_8000, .max = 0x068A_0000 },
                1 => .{ .min = 0x0620_0000, .max = 0x0620_0000 + kind.size() },
                2 => @panic("VRAMCNT_H: Slot 0-3"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
            .i => switch (mst) {
                0 => .{ .min = 0x068A_0000, .max = 0x068A_4000 },
                1 => .{ .min = 0x0620_8000, .max = 0x0620_8000 + kind.size() },
                2 => .{ .min = 0x0660_0000, .max = 0x0660_0000 + kind.size() },
                3 => @panic("Slot 0"),
                else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
            },
        };
    }

    fn buf_offset(comptime kind: Kind) usize {
        // zig fmt: off
        return switch (kind) {
            .a => 0,                                                            // 0x00000
            .b => (128 * KiB) * 1,                                              // 0x20000 (+ 0x20000)
            .c => (128 * KiB) * 2,                                              // 0x40000 (+ 0x20000)
            .d => (128 * KiB) * 3,                                              // 0x60000 (+ 0x20000)
            .e => (128 * KiB) * 4,                                              // 0x80000 (+ 0x20000)
            .f => (128 * KiB) * 4 + (64 * KiB),                                 // 0x90000 (+ 0x10000)
            .g => (128 * KiB) * 4 + (64 * KiB) + (16 * KiB) * 1,                // 0x94000 (+ 0x04000)
            .h => (128 * KiB) * 4 + (64 * KiB) + (16 * KiB) * 2,                // 0x98000 (+ 0x04000)
            .i => (128 * KiB) * 4 + (64 * KiB) + (16 * KiB) * 2 + (32 * KiB)    // 0xA0000 (+ 0x08000)
        };
        // zig fmt: on
    }

    fn CntType(comptime kind: Kind) type {
        const io = @import("nds9/io.zig");

        return switch (kind) {
            .a => io.Vramcnt.A,
            .b => io.Vramcnt.A,
            .c => io.Vramcnt.C,
            .d => io.Vramcnt.C,
            .e => io.Vramcnt.E,
            .f => io.Vramcnt.C,
            .g => io.Vramcnt.C,
            .h => io.Vramcnt.H,
            .i => io.Vramcnt.H,
        };
    }

    fn cntValue(self: *const @This(), comptime kind: Kind) CntType(kind) {
        return switch (kind) {
            .a => self.io.cnt_a,
            .b => self.io.cnt_b,
            .c => self.io.cnt_c,
            .d => self.io.cnt_d,
            .e => self.io.cnt_e,
            .f => self.io.cnt_f,
            .g => self.io.cnt_g,
            .h => self.io.cnt_h,
            .i => self.io.cnt_i,
        };
    }

    pub fn update(self: *@This()) void {
        const nds9_tbl = @constCast(self.nds9_table);
        const nds7_tbl = @constCast(self.nds7_table);

        for (nds9_tbl, nds7_tbl, 0..) |*nds9_ptr, *nds7_ptr, i| {
            const addr = 0x0600_0000 + (i * page_size);

            inline for (std.meta.fields(Kind)) |f| {
                const kind = @field(Kind, f.name);
                const cnt = cntValue(self, kind);
                const ofs = switch (kind) {
                    .e, .h, .i => 0,
                    else => cnt.offset.read(),
                };

                const rnge = range(kind, cnt.mst.read(), ofs);
                const offset = addr & (kind.size() - 1);

                if (rnge.min <= addr and addr < rnge.max) {
                    if ((kind == .c or kind == .d) and cnt.mst.read() == 2) {
                        // Allocate to ARM7
                        nds7_ptr.* = self._buf[buf_offset(kind) + offset ..].ptr;
                    } else {
                        nds9_ptr.* = self._buf[buf_offset(kind) + offset ..].ptr;
                    }
                }
            }
        }
    }

    // TODO: Rename
    const Device = enum { nds9, nds7 };

    pub fn read(self: @This(), comptime T: type, comptime dev: Device, address: u32) T {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (dev == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]const T = @ptrCast(@alignCast(some_ptr));

            return ptr[offset / @sizeOf(T)];
        }

        log.err("{s}: read(T: {}, addr: 0x{X:0>8}) was in un-mapped VRAM space", .{ @tagName(dev), T, address });
        return 0x00;
    }

    pub fn write(self: *@This(), comptime T: type, comptime dev: Device, address: u32, value: T) void {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (dev == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]T = @ptrCast(@alignCast(some_ptr));
            ptr[offset / @sizeOf(T)] = value;

            return;
        }

        log.err("{s}: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8}) was in un-mapped VRA< space", .{ @tagName(dev), T, address, value });
    }
};
