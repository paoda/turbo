const std = @import("std");
const io = @import("io.zig");

const Ppu = @import("../ppu.zig").Ppu;
const Scheduler = @import("../Scheduler.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const Wram = @import("../emu.zig").Wram;
const Bios = @import("Bios.zig");
const forceAlign = @import("../emu.zig").forceAlign;

const Controllers = @import("dma.zig").Controllers;

const Allocator = std.mem.Allocator;

const Mode = enum { normal, debug };
const MiB = 0x100000;
const KiB = 0x400;

const log = std.log.scoped(.nds9_bus);

main: *[4 * MiB]u8,
wram: *Wram,
makeshift_palram: *[2 * KiB]u8,
scheduler: *Scheduler,

dma: Controllers = .{},

io: io.Io,
ppu: Ppu,
bios: Bios,

pub fn init(allocator: Allocator, scheduler: *Scheduler, ctx: SharedCtx) !@This() {
    const dots_per_cycle = 3; // ARM946E-S runs twice as fast as the ARM7TDMI
    scheduler.push(.{ .nds9 = .draw }, 256 * dots_per_cycle);

    return .{
        .main = ctx.main,
        .wram = ctx.wram,
        .makeshift_palram = try allocator.create([2 * KiB]u8),
        .ppu = try Ppu.init(allocator, ctx.vram),
        .scheduler = scheduler,
        .io = io.Io.init(ctx.io),

        .bios = .{},
    };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.ppu.deinit(allocator);
    self.bios.deinit(allocator);

    allocator.destroy(self.makeshift_palram);
}

pub fn reset(_: *@This()) void {
    @panic("TODO: PPU Reset");
}

pub fn read(self: *@This(), comptime T: type, address: u32) T {
    return self._read(T, .normal, address);
}

pub fn dbgRead(self: *@This(), comptime T: type, address: u32) T {
    return self._read(T, .debug, address);
}

fn _read(self: *@This(), comptime T: type, comptime mode: Mode, address: u32) T {
    const byte_count = @divExact(@typeInfo(T).Int.bits, 8);
    const aligned_addr = forceAlign(T, address);

    switch (mode) {
        // .debug => log.debug("read {} from 0x{X:0>8}", .{ T, aligned_addr }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    return switch (aligned_addr) {
        0x0200_0000...0x02FF_FFFF => std.mem.readInt(T, self.main[aligned_addr & (4 * MiB - 1) ..][0..byte_count], .little),
        0x0300_0000...0x03FF_FFFF => self.wram.read(T, .nds9, aligned_addr),
        0x0400_0000...0x04FF_FFFF => io.read(self, T, aligned_addr),
        0x0500_0000...0x05FF_FFFF => std.mem.readInt(T, self.makeshift_palram[aligned_addr & (2 * KiB - 1) ..][0..@sizeOf(T)], .little),
        0x0600_0000...0x06FF_FFFF => self.ppu.vram.read(T, .nds9, aligned_addr),
        0x0700_0000...0x07FF_FFFF => std.mem.readInt(T, self.ppu.oam.buf[aligned_addr & (2 * KiB - 1) ..][0..byte_count], .little),
        0xFFFF_0000...0xFFFF_FFFF => self.bios.read(T, address),
        else => warn("unexpected: read(T: {}, addr: 0x{X:0>8}) {} ", .{ T, address, T }),
    };
}

pub fn write(self: *@This(), comptime T: type, address: u32, value: T) void {
    return self._write(T, .normal, address, value);
}

pub fn dbgWrite(self: *@This(), comptime T: type, address: u32, value: T) void {
    return self._write(T, .debug, address, value);
}

fn _write(self: *@This(), comptime T: type, comptime mode: Mode, address: u32, value: T) void {
    const byte_count = @divExact(@typeInfo(T).Int.bits, 8);
    const aligned_addr = forceAlign(T, address);

    switch (mode) {
        // .debug => log.debug("wrote 0x{X:}{} to 0x{X:0>8}", .{ value, T, aligned_addr }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    switch (aligned_addr) {
        0x0200_0000...0x02FF_FFFF => std.mem.writeInt(T, self.main[aligned_addr & (4 * MiB - 1) ..][0..byte_count], value, .little),
        0x0300_0000...0x03FF_FFFF => self.wram.write(T, .nds9, aligned_addr, value),
        0x0400_0000...0x04FF_FFFF => io.write(self, T, aligned_addr, value),
        0x0500_0000...0x05FF_FFFF => std.mem.writeInt(T, self.makeshift_palram[aligned_addr & (2 * KiB - 1) ..][0..@sizeOf(T)], value, .little),
        0x0600_0000...0x06FF_FFFF => self.ppu.vram.write(T, .nds9, aligned_addr, value),
        0x0700_0000...0x07FF_FFFF => std.mem.writeInt(T, self.ppu.oam.buf[aligned_addr & (2 * KiB - 1) ..][0..@sizeOf(T)], value, .little),
        0xFFFF_0000...0xFFFF_FFFF => self.bios.write(T, address, value),
        else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
