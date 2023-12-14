const std = @import("std");

const System = @import("../emu.zig").System;
const DmaCnt = @import("io.zig").DmaCnt;

const rotr = std.math.rotr;
const shift = @import("../../util.zig").shift;
const subset = @import("../../util.zig").subset;

const handleInterrupt = @import("../emu.zig").handleInterrupt;

const log = std.log.scoped(.nds7_dma_transfer);

// TODO: Fill Data

pub const Controllers = struct {
    Controller(0) = Controller(0){},
    Controller(1) = Controller(1){},
    Controller(2) = Controller(2){},
    Controller(3) = Controller(3){},
};

pub fn read(comptime T: type, dma: *const Controllers, addr: u32) ?T {
    const byte_addr: u8 = @truncate(addr);

    return switch (T) {
        u32 => switch (byte_addr) {
            0xB0, 0xB4 => null, // DMA0SAD, DMA0DAD,
            0xB8 => @as(T, dma.*[0].dmacntH()) << 16, // DMA0CNT_L is write-only
            0xBC, 0xC0 => null, // DMA1SAD, DMA1DAD
            0xC4 => @as(T, dma.*[1].dmacntH()) << 16, // DMA1CNT_L is write-only
            0xC8, 0xCC => null, // DMA2SAD, DMA2DAD
            0xD0 => @as(T, dma.*[2].dmacntH()) << 16, // DMA2CNT_L is write-only
            0xD4, 0xD8 => null, // DMA3SAD, DMA3DAD
            0xDC => @as(T, dma.*[3].dmacntH()) << 16, // DMA3CNT_L is write-only
            else => warn("unaligned {} read from 0x{X:0>8}", .{ T, addr }),
        },
        u16 => switch (byte_addr) {
            0xB0, 0xB2, 0xB4, 0xB6 => null, // DMA0SAD, DMA0DAD
            0xB8 => 0x0000, // DMA0CNT_L, suite.gba expects 0x0000 instead of 0xDEAD
            0xBA => dma.*[0].dmacntH(),

            0xBC, 0xBE, 0xC0, 0xC2 => null, // DMA1SAD, DMA1DAD
            0xC4 => 0x0000, // DMA1CNT_L
            0xC6 => dma.*[1].dmacntH(),

            0xC8, 0xCA, 0xCC, 0xCE => null, // DMA2SAD, DMA2DAD
            0xD0 => 0x0000, // DMA2CNT_L
            0xD2 => dma.*[2].dmacntH(),

            0xD4, 0xD6, 0xD8, 0xDA => null, // DMA3SAD, DMA3DAD
            0xDC => 0x0000, // DMA3CNT_L
            0xDE => dma.*[3].dmacntH(),
            else => warn("unaligned {} read from 0x{X:0>8}", .{ T, addr }),
        },
        u8 => switch (byte_addr) {
            0xB0...0xB7 => null, // DMA0SAD, DMA0DAD
            0xB8, 0xB9 => 0x00, // DMA0CNT_L
            0xBA, 0xBB => @truncate(dma.*[0].dmacntH() >> shift(u16, byte_addr)),

            0xBC...0xC3 => null, // DMA1SAD, DMA1DAD
            0xC4, 0xC5 => 0x00, // DMA1CNT_L
            0xC6, 0xC7 => @truncate(dma.*[1].dmacntH() >> shift(u16, byte_addr)),

            0xC8...0xCF => null, // DMA2SAD, DMA2DAD
            0xD0, 0xD1 => 0x00, // DMA2CNT_L
            0xD2, 0xD3 => @truncate(dma.*[2].dmacntH() >> shift(u16, byte_addr)),

            0xD4...0xDB => null, // DMA3SAD, DMA3DAD
            0xDC, 0xDD => 0x00, // DMA3CNT_L
            0xDE, 0xDF => @truncate(dma.*[3].dmacntH() >> shift(u16, byte_addr)),
            else => warn("unexpected {} read from 0x{X:0>8}", .{ T, addr }),
        },
        else => @compileError("DMA: Unsupported read width"),
    };
}

pub fn write(comptime T: type, dma: *Controllers, addr: u32, value: T) void {
    const byte_addr: u8 = @truncate(addr);

    switch (T) {
        u32 => switch (byte_addr) {
            0xB0 => dma.*[0].setDmasad(value),
            0xB4 => dma.*[0].setDmadad(value),
            0xB8 => dma.*[0].setDmacnt(value),

            0xBC => dma.*[1].setDmasad(value),
            0xC0 => dma.*[1].setDmadad(value),
            0xC4 => dma.*[1].setDmacnt(value),

            0xC8 => dma.*[2].setDmasad(value),
            0xCC => dma.*[2].setDmadad(value),
            0xD0 => dma.*[2].setDmacnt(value),

            0xD4 => dma.*[3].setDmasad(value),
            0xD8 => dma.*[3].setDmadad(value),
            0xDC => dma.*[3].setDmacnt(value),
            else => log.warn("Tried to write 0x{X:0>8}{} to 0x{X:0>8}", .{ value, T, addr }),
        },
        u16 => switch (byte_addr) {
            0xB0, 0xB2 => dma.*[0].setDmasad(subset(u32, u16, byte_addr, dma.*[0].sad, value)),
            0xB4, 0xB6 => dma.*[0].setDmadad(subset(u32, u16, byte_addr, dma.*[0].dad, value)),
            0xB8 => dma.*[0].setDmacntL(value),
            0xBA => dma.*[0].setDmacntH(value),

            0xBC, 0xBE => dma.*[1].setDmasad(subset(u32, u16, byte_addr, dma.*[1].sad, value)),
            0xC0, 0xC2 => dma.*[1].setDmadad(subset(u32, u16, byte_addr, dma.*[1].dad, value)),
            0xC4 => dma.*[1].setDmacntL(value),
            0xC6 => dma.*[1].setDmacntH(value),

            0xC8, 0xCA => dma.*[2].setDmasad(subset(u32, u16, byte_addr, dma.*[2].sad, value)),
            0xCC, 0xCE => dma.*[2].setDmadad(subset(u32, u16, byte_addr, dma.*[2].dad, value)),
            0xD0 => dma.*[2].setDmacntL(value),
            0xD2 => dma.*[2].setDmacntH(value),

            0xD4, 0xD6 => dma.*[3].setDmasad(subset(u32, u16, byte_addr, dma.*[3].sad, value)),
            0xD8, 0xDA => dma.*[3].setDmadad(subset(u32, u16, byte_addr, dma.*[3].dad, value)),
            0xDC => dma.*[3].setDmacntL(value),
            0xDE => dma.*[3].setDmacntH(value),
            else => log.warn("Tried to write 0x{X:0>4}{} to 0x{X:0>8}", .{ value, T, addr }),
        },
        u8 => switch (byte_addr) {
            0xB0, 0xB1, 0xB2, 0xB3 => dma.*[0].setDmasad(subset(u32, u8, byte_addr, dma.*[0].sad, value)),
            0xB4, 0xB5, 0xB6, 0xB7 => dma.*[0].setDmadad(subset(u32, u8, byte_addr, dma.*[0].dad, value)),
            0xB8, 0xB9 => dma.*[0].setDmacntL(subset(u16, u8, byte_addr, @as(u16, @truncate(dma.*[0].word_count)), value)), // FIXME: How wrong is this? lol
            0xBA, 0xBB => dma.*[0].setDmacntH(subset(u16, u8, byte_addr, dma.*[0].cnt.raw, value)),

            0xBC, 0xBD, 0xBE, 0xBF => dma.*[1].setDmasad(subset(u32, u8, byte_addr, dma.*[1].sad, value)),
            0xC0, 0xC1, 0xC2, 0xC3 => dma.*[1].setDmadad(subset(u32, u8, byte_addr, dma.*[1].dad, value)),
            0xC4, 0xC5 => dma.*[1].setDmacntL(subset(u16, u8, byte_addr, @as(u16, @truncate(dma.*[1].word_count)), value)),
            0xC6, 0xC7 => dma.*[1].setDmacntH(subset(u16, u8, byte_addr, dma.*[1].cnt.raw, value)),

            0xC8, 0xC9, 0xCA, 0xCB => dma.*[2].setDmasad(subset(u32, u8, byte_addr, dma.*[2].sad, value)),
            0xCC, 0xCD, 0xCE, 0xCF => dma.*[2].setDmadad(subset(u32, u8, byte_addr, dma.*[2].dad, value)),
            0xD0, 0xD1 => dma.*[2].setDmacntL(subset(u16, u8, byte_addr, @as(u16, @truncate(dma.*[2].word_count)), value)),
            0xD2, 0xD3 => dma.*[2].setDmacntH(subset(u16, u8, byte_addr, dma.*[2].cnt.raw, value)),

            0xD4, 0xD5, 0xD6, 0xD7 => dma.*[3].setDmasad(subset(u32, u8, byte_addr, dma.*[3].sad, value)),
            0xD8, 0xD9, 0xDA, 0xDB => dma.*[3].setDmadad(subset(u32, u8, byte_addr, dma.*[3].dad, value)),
            0xDC, 0xDD => dma.*[3].setDmacntL(subset(u16, u8, byte_addr, @as(u16, @truncate(dma.*[3].word_count)), value)),
            0xDE, 0xDF => dma.*[3].setDmacntH(subset(u16, u8, byte_addr, dma.*[3].cnt.raw, value)),
            else => log.warn("Tried to write 0x{X:0>2}{} to 0x{X:0>8}", .{ value, T, addr }),
        },
        else => @compileError("DMA: Unsupported write width"),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}

/// Function that creates a DMAController. Determines unique DMA Controller behaiour at compile-time
fn Controller(comptime id: u2) type {
    return struct {
        const Self = @This();

        const sad_mask: u32 = 0x0FFF_FFFE;
        const dad_mask: u32 = 0x0FFF_FFFE;
        const WordCount = u21;

        /// Write-only. The first address in a DMA transfer. (DMASAD)
        /// Note: use writeSrc instead of manipulating src_addr directly
        sad: u32 = 0x0000_0000,
        /// Write-only. The final address in a DMA transffer. (DMADAD)
        /// Note: Use writeDst instead of manipulatig dst_addr directly
        dad: u32 = 0x0000_0000,
        /// Write-only. The Word Count for the DMA Transfer (DMACNT_L)
        word_count: WordCount = 0,
        /// Read / Write. DMACNT_H
        /// Note: Use writeControl instead of manipulating cnt directly.
        cnt: DmaCnt = .{ .raw = 0x0000 },

        /// Internal. The last successfully read value
        data_latch: u32 = 0x0000_0000,
        /// Internal. Currrent Source Address
        sad_latch: u32 = 0x0000_0000,
        /// Internal. Current Destination Address
        dad_latch: u32 = 0x0000_0000,
        /// Internal. Word Count
        _word_count: WordCount = 0,

        /// Some DMA Transfers are enabled during Hblank / VBlank and / or
        /// have delays. Thefore bit 15 of DMACNT isn't actually something
        /// we can use to control when we do or do not execute a step in a DMA Transfer
        in_progress: bool = false,

        pub fn reset(self: *Self) void {
            self.* = Self.init();
        }

        pub fn setDmasad(self: *Self, addr: u32) void {
            self.sad = addr & sad_mask;
        }

        pub fn setDmadad(self: *Self, addr: u32) void {
            self.dad = addr & dad_mask;
        }

        pub fn setDmacntL(self: *Self, halfword: u16) void {
            self.word_count = halfword;
        }

        pub fn dmacntH(self: *const Self) u16 {
            return self.cnt.raw & if (id == 3) 0xFFE0 else 0xF7E0;
        }

        pub fn setDmacntH(self: *Self, halfword: u16) void {
            const new = DmaCnt{ .raw = halfword };

            if (!self.cnt.enabled.read() and new.enabled.read()) {
                // Reload Internals on Rising Edge.
                self.sad_latch = self.sad;
                self.dad_latch = self.dad;
                self._word_count = if (self.word_count == 0) std.math.maxInt(WordCount) else self.word_count;

                // Only a Start Timing of 00 has a DMA Transfer immediately begin
                self.in_progress = new.start_timing.read() == 0b00;

                if (self.in_progress) {
                    log.debug("Immediate DMA9({}): 0x{X:0>8} -> 0x{X:0>8} {} words", .{ id, self.sad_latch, self.dad_latch, self._word_count });
                }
            }

            self.cnt.raw = halfword;
        }

        pub fn setDmacnt(self: *Self, word: u32) void {
            self.setDmacntL(@truncate(word));
            self.setDmacntH(@truncate(word >> 16));
        }

        pub fn step(self: *Self, cpu: *System.Arm946es) void {
            const bus_ptr: *System.Bus7 = @ptrCast(@alignCast(cpu.bus.ptr));

            const is_fifo = (id == 1 or id == 2) and self.cnt.start_timing.read() == 0b11;
            const sad_adj: Adjustment = @enumFromInt(self.cnt.sad_adj.read());
            const dad_adj: Adjustment = if (is_fifo) .Fixed else @enumFromInt(self.cnt.dad_adj.read());

            const transfer_type = is_fifo or self.cnt.transfer_type.read();
            const offset: u32 = if (transfer_type) @sizeOf(u32) else @sizeOf(u16);

            const mask = if (transfer_type) ~@as(u32, 3) else ~@as(u32, 1);
            const sad_addr = self.sad_latch & mask;
            const dad_addr = self.dad_latch & mask;

            if (transfer_type) {
                if (sad_addr >= 0x0200_0000) self.data_latch = cpu.bus.read(u32, sad_addr);
                cpu.bus.write(u32, dad_addr, self.data_latch);
            } else {
                if (sad_addr >= 0x0200_0000) {
                    const value: u32 = cpu.bus.read(u16, sad_addr);
                    self.data_latch = value << 16 | value;
                }

                cpu.bus.write(u16, dad_addr, @as(u16, @truncate(rotr(u32, self.data_latch, 8 * (dad_addr & 3)))));
            }

            switch (@as(u8, @truncate(sad_addr >> 24))) {
                // according to fleroviux, DMAs with a source address in ROM misbehave
                // the resultant behaviour is that the source address will increment despite what DMAXCNT says
                0x08...0x0D => self.sad_latch +%= offset, // obscure behaviour
                else => switch (sad_adj) {
                    .Increment => self.sad_latch +%= offset,
                    .Decrement => self.sad_latch -%= offset,
                    .IncrementReload => log.err("{} is a prohibited adjustment on SAD", .{sad_adj}),
                    .Fixed => {},
                },
            }

            switch (dad_adj) {
                .Increment, .IncrementReload => self.dad_latch +%= offset,
                .Decrement => self.dad_latch -%= offset,
                .Fixed => {},
            }

            self._word_count -= 1;

            if (self._word_count == 0) {
                if (self.cnt.irq.read()) {
                    switch (id) {
                        0 => bus_ptr.io.irq.dma0.set(),
                        1 => bus_ptr.io.irq.dma1.set(),
                        2 => bus_ptr.io.irq.dma2.set(),
                        3 => bus_ptr.io.irq.dma3.set(),
                    }

                    handleInterrupt(.nds9, cpu);
                }

                // If we're not repeating, Fire the IRQs and disable the DMA
                if (!self.cnt.repeat.read()) self.cnt.enabled.unset();

                // We want to disable our internal enabled flag regardless of repeat
                // because we only want to step A DMA that repeats during it's specific
                // timing window
                self.in_progress = false;
            }
        }

        fn poll(self: *Self, comptime kind: Kind) void {
            if (self.in_progress) return; // If there's an ongoing DMA Transfer, exit early

            // No ongoing DMA Transfer, We want to check if we should repeat an existing one
            // Determined by the repeat bit and whether the DMA is in the right start_timing

            switch (kind) {
                .vblank => self.in_progress = self.cnt.enabled.read() and self.cnt.start_timing.read() == 0b01,
                .hblank => self.in_progress = self.cnt.enabled.read() and self.cnt.start_timing.read() == 0b10,
                else => {},
            }

            // If we determined that the repeat bit is set (and now the Hblank / Vblank DMA is now in progress)
            // Reload internal word count latch
            // Reload internal DAD latch if we are in IncrementRelaod
            if (self.in_progress) {
                self._word_count = if (self.word_count == 0) std.math.maxInt(@TypeOf(self._word_count)) else self.word_count;
                if (@as(Adjustment, @enumFromInt(self.cnt.dad_adj.read())) == .IncrementReload) self.dad_latch = self.dad;
            }
        }

        pub fn requestAudio(self: *Self, _: u32) void {
            comptime std.debug.assert(id == 1 or id == 2);
            if (self.in_progress) return; // APU must wait their turn

            // DMA May not be configured for handling DMAs
            if (self.cnt.start_timing.read() != 0b11) return;

            // We Assume the Repeat Bit is Set
            // We Assume that DAD is set to 0x0400_00A0 or 0x0400_00A4 (fifo_addr)
            // We Assume DMACNT_L is set to 4

            // FIXME: Safe to just assume whatever DAD is set to is the FIFO Address?
            // self.dad_latch = fifo_addr;
            self.cnt.repeat.set();
            self._word_count = 4;
            self.in_progress = true;
        }
    };
}

pub fn onVblank(bus: *System.Bus9) void {
    inline for (0..4) |i| bus.dma[i].poll(.vblank);
}

pub fn onHblank(bus: *System.Bus9) void {
    inline for (0..4) |i| bus.dma[i].poll(.hblank);
}

pub fn step(cpu: *System.Arm946es) bool {
    const bus: *System.Bus9 = @ptrCast(@alignCast(cpu.bus.ptr));

    inline for (0..4) |i| {
        if (bus.dma[i].in_progress) {
            bus.dma[i].step(cpu);
            return true;
        }
    }

    return false;
}

const Adjustment = enum(u2) {
    Increment = 0,
    Decrement = 1,
    Fixed = 2,
    IncrementReload = 3,
};

const Kind = enum(u3) {
    immediate = 0,
    vblank,
    hblank,

    display_start_sync,
    main_mem_display,
    cartridge_slot,
    pak_slot,
    geo_cmd_fifo,
};
