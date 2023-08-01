const std = @import("std");
const Allocator = std.mem.Allocator;

const nds9 = @import("nds9.zig");

pub const screen_width = 256;
pub const screen_height = 192;

const cycles_per_dot = 6;

pub const Ppu = struct {
    fb: FrameBuffer,

    io: io = .{},

    pub fn init(allocator: Allocator) !@This() {
        return .{
            .fb = try FrameBuffer.init(allocator),
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.fb.deinit(allocator);
    }

    pub fn drawScanline(self: *@This(), nds9_bus: *nds9.Bus) void {
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
                        rgba.* = rgba888(nds9_bus.dbgRead(u16, addr));
                    }
                }
            },
            0x3 => {},
        }
    }

    /// HDraw -> HBlank
    pub fn onHdrawEnd(self: *@This(), nds9_scheduler: *nds9.Scheduler, late: u64) void {
        const dots_in_hblank = 99;
        std.debug.assert(self.io.dispstat.hblank.read() == false);
        std.debug.assert(self.io.dispstat.vblank.read() == false);

        // TODO: Signal HBlank IRQ

        self.io.dispstat.hblank.set();
        nds9_scheduler.push(.hblank, dots_in_hblank * cycles_per_dot -| late);
    }

    pub fn onHblankEnd(self: *@This(), nds9_scheduler: *nds9.Scheduler, late: u64) void {
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
            return nds9_scheduler.push(.draw, dots_in_hdraw * cycles_per_dot -| late);
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
        nds9_scheduler.push(.hblank, dots_in_scanline * cycles_per_dot -| late);
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

const io = struct {
    const nds9_io = @import("nds9/io.zig"); // TODO: rename

    /// Read / Write
    dispcnt_a: nds9_io.DispcntA = .{ .raw = 0x0000_0000 },
    /// Read / Write
    dispstat: nds9_io.Dispstat = .{ .raw = 0x0000 },

    /// Read-Only
    vcount: nds9_io.Vcount = .{ .raw = 0x0000 },

    /// Write-Only
    vramcnt_a: nds9_io.Vramcnt.A = .{ .raw = 0x00 },
    vramcnt_b: nds9_io.Vramcnt.A = .{ .raw = 0x00 },
    vramcnt_c: nds9_io.Vramcnt.C = .{ .raw = 0x00 },
    vramcnt_d: nds9_io.Vramcnt.C = .{ .raw = 0x00 },
};
