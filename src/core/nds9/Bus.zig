const std = @import("std");
const io = @import("io.zig");

const Ppu = @import("../ppu.zig").Ppu;
const Scheduler = @import("Scheduler.zig");
const SharedContext = @import("../emu.zig").SharedContext;
const forceAlign = @import("../emu.zig").forceAlign;

const Allocator = std.mem.Allocator;

const Mode = enum { normal, debug };
const MiB = 0x100000;
const KiB = 0x400;

const log = std.log.scoped(.nds9_bus);

main: *[4 * MiB]u8,
vram1: *[512 * KiB]u8, // TODO: Rename
io: io.Io,
ppu: Ppu,

scheduler: *Scheduler,

pub fn init(allocator: Allocator, scheduler: *Scheduler, shared_ctx: SharedContext) !@This() {
    const vram1_mem = try allocator.create([512 * KiB]u8);
    errdefer allocator.destroy(vram1_mem);
    @memset(vram1_mem, 0);

    const dots_per_cycle = 3; // ARM946E-S runs twice as fast as the ARM7TDMI
    scheduler.push(.draw, 256 * dots_per_cycle);

    return .{
        .main = shared_ctx.main,
        .vram1 = vram1_mem,
        .ppu = try Ppu.init(allocator),
        .scheduler = scheduler,
        .io = io.Io.init(shared_ctx.io),
    };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.ppu.deinit(allocator);

    allocator.destroy(self.vram1);
}

pub fn reset(self: *@This()) void {
    @memset(self.main, 0);
    @memset(self.vram1, 0);
}

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
        0x0200_0000...0x02FF_FFFF => readInt(T, self.main[aligned_addr & 0x003F_FFFF ..][0..byte_count]),
        0x0400_0000...0x04FF_FFFF => io.read(self, T, aligned_addr),
        0x0600_0000...0x06FF_FFFF => readInt(T, self.vram1[aligned_addr & 0x0007_FFFF ..][0..byte_count]),
        else => warn("unexpected read: 0x{x:0>8} -> {}", .{ aligned_addr, T }),
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
        0x0200_0000...0x02FF_FFFF => writeInt(T, self.main[aligned_addr & 0x003F_FFFF ..][0..byte_count], value),
        0x0400_0000...0x04FF_FFFF => io.write(self, T, aligned_addr, value),
        0x0600_0000...0x06FF_FFFF => writeInt(T, self.vram1[aligned_addr & 0x0007_FFFF ..][0..byte_count], value),
        else => log.warn("unexpected write: 0x{X:}{} -> 0x{X:0>8}", .{ value, T, aligned_addr }),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
