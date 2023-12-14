const std = @import("std");
const io = @import("io.zig");

const Scheduler = @import("../Scheduler.zig");
const SharedCtx = @import("../emu.zig").SharedCtx;
const Wram = @import("../emu.zig").Wram;
const Vram = @import("../ppu/Vram.zig");
const Bios = @import("Bios.zig");
const forceAlign = @import("../emu.zig").forceAlign;

const Controllers = @import("dma.zig").Controllers;

const Allocator = std.mem.Allocator;

const Mode = enum { normal, debug };
const MiB = 0x100000;
const KiB = 0x400;

const log = std.log.scoped(.nds7_bus);

scheduler: *Scheduler,
main: *[4 * MiB]u8,
shr_wram: *Wram,
wram: *[64 * KiB]u8,
vram: *Vram,

dma: Controllers = .{},

io: io.Io,
bios: Bios,

pub fn init(allocator: Allocator, scheduler: *Scheduler, ctx: SharedCtx) !@This() {
    const wram = try allocator.create([64 * KiB]u8);
    @memset(wram, 0);

    return .{
        .main = ctx.main,
        .shr_wram = ctx.wram,
        .vram = ctx.vram,
        .wram = wram,
        .scheduler = scheduler,
        .io = io.Io.init(ctx.io),

        .bios = .{},
    };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    allocator.destroy(self.wram);
    self.bios.deinit(allocator);
}

pub fn reset(_: *@This()) void {}

pub fn read(self: *@This(), comptime T: type, address: u32) T {
    return self._read(T, .normal, address);
}

pub fn dbgRead(self: *@This(), comptime T: type, address: u32) T {
    return self._read(T, .debug, address);
}

fn _read(self: *@This(), comptime T: type, comptime mode: Mode, address: u32) T {
    const byte_count = @divExact(@typeInfo(T).Int.bits, 8);
    const readInt = std.mem.readIntLittle;

    const aligned_addr = forceAlign(T, address);

    switch (mode) {
        // .debug => log.debug("read {} from 0x{X:0>8}", .{ T, aligned_addr }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    return switch (aligned_addr) {
        0x0000_0000...0x01FF_FFFF => self.bios.read(T, address),
        0x0200_0000...0x02FF_FFFF => readInt(T, self.main[aligned_addr & 0x003F_FFFF ..][0..byte_count]),
        0x0300_0000...0x037F_FFFF => switch (self.io.shr.wramcnt.mode.read()) {
            0b00 => readInt(T, self.wram[aligned_addr & 0x0000_FFFF ..][0..byte_count]),
            else => self.shr_wram.read(T, .nds7, aligned_addr),
        },
        0x0380_0000...0x03FF_FFFF => readInt(T, self.wram[aligned_addr & 0x0000_FFFF ..][0..byte_count]),
        0x0400_0000...0x04FF_FFFF => io.read(self, T, aligned_addr),
        0x0600_0000...0x06FF_FFFF => self.vram.read(T, .nds7, aligned_addr),

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
    const writeInt = std.mem.writeIntLittle;

    const aligned_addr = forceAlign(T, address);

    switch (mode) {
        // .debug => log.debug("wrote 0x{X:}{} to 0x{X:0>8}", .{ value, T, aligned_addr }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    switch (aligned_addr) {
        0x0000_0000...0x01FF_FFFF => self.bios.write(T, address, value),
        0x0200_0000...0x02FF_FFFF => writeInt(T, self.main[aligned_addr & 0x003F_FFFF ..][0..byte_count], value),
        0x0300_0000...0x037F_FFFF => switch (self.io.shr.wramcnt.mode.read()) {
            0b00 => writeInt(T, self.wram[aligned_addr & 0x0000_FFFF ..][0..byte_count], value),
            else => self.shr_wram.write(T, .nds7, aligned_addr, value),
        },
        0x0380_0000...0x03FF_FFFF => writeInt(T, self.wram[aligned_addr & 0x0000_FFFF ..][0..byte_count], value),
        0x0400_0000...0x04FF_FFFF => io.write(self, T, aligned_addr, value),
        0x0600_0000...0x06FF_FFFF => self.vram.write(T, .nds7, aligned_addr, value),
        else => log.warn("unexpected: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8})", .{ T, address, value }),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
