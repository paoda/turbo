const std = @import("std");
const KiB = 0x400;

const System = @import("../emu.zig").System;

const Allocator = std.mem.Allocator;
const IntFittingRange = std.math.IntFittingRange;

const page_size = 16 * KiB; // smallest allocation is 16 KiB
const addr_space_size = 0x0100_0000; // 0x0600_0000 -> 0x06FF_FFFF (inclusive)
const table_len = addr_space_size / page_size;
const buf_len = 656 * KiB;

const log = std.log.scoped(.vram);

io: Io = .{},

_buf: *[buf_len]u8,
nds9_table: *const [table_len]?[*]u8,
nds7_table: *const [table_len]?[*]u8,

const Io = struct {
    pub const Vramstat = nds7.Vramstat;

    const nds9 = @import("../nds9/io.zig");
    const nds7 = @import("../nds7/io.zig");

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

/// NDS7 VRAMSTAT
pub fn stat(self: *const @This()) Io.Vramstat {
    const vram_c: u8 = @intFromBool(self.io.cnt_c.enable.read() and self.io.cnt_c.mst.read() == 2);
    const vram_d: u8 = @intFromBool(self.io.cnt_d.enable.read() and self.io.cnt_d.mst.read() == 2);

    return .{ .raw = (vram_d << 1) | vram_c };
}

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

// TODO: Rename
fn range(comptime kind: Kind, mst: u3, offset: u2) u32 {
    const ofs: u32 = offset;
    // panic messages are from GBATEK

    return switch (kind) {
        .a => switch (mst) {
            0 => 0x0680_0000,
            1 => 0x0600_0000 + (0x0002_0000 * ofs),
            2 => 0x0640_0000 + (0x0002_0000 * (ofs & 0b01)),
            3 => @panic("VRAMCNT_A: Slot OFS(0-3)"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .b => switch (mst) {
            0 => 0x0682_0000,
            1 => 0x0600_0000 + (0x0002_0000 * ofs),
            2 => 0x0640_0000 + (0x0002_0000 * (ofs & 0b01)),
            3 => @panic("VRAMCNT_B: Slot OFS(0-3)"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .c => switch (mst) {
            0 => 0x0684_0000,
            1 => 0x0600_0000 + (0x0002_0000 * ofs),
            2 => 0x0600_0000 + (0x0002_0000 * (ofs & 0b01)),
            3 => @panic("VRAMCNT_C: Slot OFS(0-3)"),
            4 => 0x0620_0000,
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .d => switch (mst) {
            0 => 0x0686_0000,
            1 => 0x0600_0000 + (0x0002_0000 * ofs),
            2 => 0x0600_0000 + (0x0002_0000 * (ofs & 0b01)),
            3 => @panic("VRAMCNT_D: Slot OFS(0-3)"),
            4 => 0x0660_0000,
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .e => switch (mst) {
            0 => 0x0688_0000,
            1 => 0x0600_0000,
            2 => 0x0640_0000,
            3 => @panic("VRAMCNT_E: Slots 0-3"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .f => switch (mst) {
            0 => 0x0689_0000,
            1 => 0x0600_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1)),
            2 => 0x0640_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1)),
            3 => @panic("VRAMCNT_F: Slot (OFS.0*1)+(OFS.1*4)"),
            4 => @panic("VRAMCNT_F: Slot 0-1 (OFS=0), Slot 2-3 (OFS=1)"),
            5 => @panic("VRAMCNT_F: Slot 0"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .g => switch (mst) {
            0 => 0x0689_4000,
            1 => 0x0600_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1)),
            2 => 0x0640_0000 + (0x0000_4000 * (ofs & 0b01)) + (0x0001_0000 * (ofs >> 1)),
            3 => @panic("VRAMCNT_G: Slot (OFS.0*1)+(OFS.1*4)"),
            4 => @panic("VRAMCNT_G: Slot 0-1 (OFS=0), Slot 2-3 (OFS=1)"),
            5 => @panic("VRAMCNT_G: Slot 0"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .h => switch (mst) {
            0 => 0x0689_8000,
            1 => 0x0620_0000,
            2 => @panic("VRAMCNT_H: Slot 0-3"),
            else => std.debug.panic("Invalid MST for VRAMCNT_{s}", .{[_]u8{std.ascii.toUpper(@tagName(kind)[0])}}),
        },
        .i => switch (mst) {
            0 => 0x068A_0000,
            1 => 0x0620_8000,
            2 => 0x0660_0000,
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
    const Vramcnt = @import("../nds9/io.zig").Vramcnt;

    return switch (kind) {
        .a => Vramcnt.A,
        .b => Vramcnt.A,
        .c => Vramcnt.C,
        .d => Vramcnt.C,
        .e => Vramcnt.E,
        .f => Vramcnt.C,
        .g => Vramcnt.C,
        .h => Vramcnt.H,
        .i => Vramcnt.H,
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

// TODO: We always update the entirety of VRAM when that argubably isn't necessary
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

            const min = range(kind, cnt.mst.read(), ofs);
            const max = min + kind.size();
            const offset = addr & (kind.size() - 1);

            if (min <= addr and addr < max) {
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

pub fn read(self: @This(), comptime T: type, comptime proc: System.Process, address: u32) T {
    const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
    const masked_addr = address & (addr_space_size - 1);
    const page = masked_addr >> bits;
    const offset = masked_addr & (page_size - 1);
    const table = if (proc == .nds9) self.nds9_table else self.nds7_table;

    if (table[page]) |some_ptr| {
        const ptr: [*]const T = @ptrCast(@alignCast(some_ptr));

        return ptr[offset / @sizeOf(T)];
    }

    log.err("{s}: read(T: {}, addr: 0x{X:0>8}) was in un-mapped VRAM space", .{ @tagName(proc), T, address });
    return 0x00;
}

pub fn write(self: *@This(), comptime T: type, comptime proc: System.Process, address: u32, value: T) void {
    const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
    const masked_addr = address & (addr_space_size - 1);
    const page = masked_addr >> bits;
    const offset = masked_addr & (page_size - 1);
    const table = if (proc == .nds9) self.nds9_table else self.nds7_table;

    if (table[page]) |some_ptr| {
        const ptr: [*]T = @ptrCast(@alignCast(some_ptr));
        ptr[offset / @sizeOf(T)] = value;

        return;
    }

    log.err("{s}: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8}) was in un-mapped VRA< space", .{ @tagName(proc), T, address, value });
}
