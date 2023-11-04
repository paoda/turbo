const std = @import("std");
const Allocator = std.mem.Allocator;

const Scheduler = @import("Scheduler.zig");
const System = @import("emu.zig").System;

const Vram = @import("ppu/Vram.zig");
const EngineA = @import("ppu/engine.zig").EngineA;
const EngineB = @import("ppu/engine.zig").EngineB;

pub const screen_width = 256;
pub const screen_height = 192;
const KiB = 0x400;

const cycles_per_dot = 6;

pub const Ppu = struct {
    fb: FrameBuffer,

    vram: *Vram,

    engines: struct { EngineA, EngineB } = .{ .{}, .{} },

    io: Io = .{},

    const Io = struct {
        const types = @import("nds9/io.zig");

        powcnt: types.PowCnt = .{ .raw = 0x0000_0000 },
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
        if (self.io.powcnt.engine2d_a.read())
            self.engines[0].drawScanline(bus, &self.fb, &self.io.powcnt);

        if (self.io.powcnt.engine2d_b.read())
            self.engines[1].drawScanline(bus, &self.fb, &self.io.powcnt);
    }

    /// HDraw -> HBlank
    pub fn onHdrawEnd(self: *@This(), scheduler: *Scheduler, late: u64) void {
        inline for (&self.engines) |*engine| {
            std.debug.assert(engine.dispstat.hblank.read() == false);
            std.debug.assert(engine.dispstat.vblank.read() == false);

            // TODO: Signal HBlank IRQ

            engine.dispstat.hblank.set();
        }

        const dots_in_hblank = 99;
        scheduler.push(.{ .nds9 = .hblank }, dots_in_hblank * cycles_per_dot -| late);
    }

    // VBlank -> HBlank (Still VBlank)
    pub fn onVblankEnd(self: *@This(), scheduler: *Scheduler, late: u64) void {
        inline for (&self.engines) |*engine| {
            std.debug.assert(!engine.dispstat.hblank.read());
            std.debug.assert(engine.vcount.scanline.read() == 262 or engine.dispstat.vblank.read());

            // TODO: Signal HBlank IRQ

            engine.dispstat.hblank.set();
        }

        const dots_in_hblank = 99;
        scheduler.push(.{ .nds9 = .hblank }, dots_in_hblank * cycles_per_dot -| late);
    }

    /// HBlank -> HDraw / VBlank
    pub fn onHblankEnd(self: *@This(), scheduler: *Scheduler, late: u64) void {
        const scanline_total = 263; // 192 visible, 71 blanking

        std.debug.assert(self.engines[0].vcount.scanline.read() == self.engines[1].vcount.scanline.read());

        inline for (&self.engines) |*engine| {
            const prev_scanline = engine.vcount.scanline.read();
            const scanline = (prev_scanline + 1) % scanline_total;

            engine.vcount.scanline.write(scanline);
            engine.dispstat.hblank.unset();

            const coincidence = scanline == engine.dispstat.lyc.read();
            engine.dispstat.coincidence.write(coincidence);
        }

        const scanline = self.engines[0].vcount.scanline.read();

        // TODO: LYC == LY IRQ

        if (scanline < 192) {
            inline for (&self.engines) |*engine| {
                std.debug.assert(engine.dispstat.vblank.read() == false);
                std.debug.assert(engine.dispstat.hblank.read() == false);
            }

            // Draw Another Scanline
            const dots_in_hdraw = 256;
            return scheduler.push(.{ .nds9 = .draw }, dots_in_hdraw * cycles_per_dot -| late);
        }

        if (scanline == 192) {
            // Transition from Hblank to Vblank
            self.fb.swap();

            inline for (&self.engines) |*engine|
                engine.dispstat.vblank.set();

            // TODO: Signal VBlank IRQ
        }

        if (scanline == 262) {
            inline for (&self.engines) |*engine| {
                engine.dispstat.vblank.unset();
                std.debug.assert(engine.dispstat.vblank.read() == (scanline != 262));
            }
        }

        const dots_in_vblank = 256;
        scheduler.push(.{ .nds9 = .vblank }, dots_in_vblank * cycles_per_dot -| late);
    }
};

pub const FrameBuffer = struct {
    const len = (screen_width * @sizeOf(u32)) * screen_height;

    current: u1 = 0,

    ptr: *align(@sizeOf(u32)) [len * 4]u8,

    const Position = enum { top, bottom };
    const Layer = enum { front, back };

    pub fn init(allocator: Allocator) !@This() {
        const buf = try allocator.alignedAlloc(u8, @sizeOf(u32), len * 4);

        return .{ .ptr = buf[0 .. len * 4] };
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
