const std = @import("std");

const io = @import("io.zig");

const Scheduler = @import("Scheduler.zig");
const SharedIo = @import("../io.zig").Io;

const Allocator = std.mem.Allocator;

const Mode = enum { normal, debug };
const MiB = 0x100000;
const KiB = 0x400;

const log = std.log.scoped(.nds7_bus);

scheduler: *Scheduler,
main: *[4 * MiB]u8,
wram: *[64 * KiB]u8,
io: io.Io,

pub fn init(allocator: Allocator, scheduler: *Scheduler, shared_io: *SharedIo) !@This() {
    const main_mem = try allocator.create([4 * MiB]u8);
    errdefer allocator.destroy(main_mem);
    @memset(main_mem, 0);

    const wram = try allocator.create([64 * KiB]u8);
    errdefer allocator.destroy(wram);
    @memset(wram, 0);

    return .{
        .main = main_mem,
        .wram = wram,
        .scheduler = scheduler,
        .io = io.Io.init(shared_io),
    };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    allocator.destroy(self.main);
    allocator.destroy(self.wram);
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

    switch (mode) {
        // .debug => log.debug("read {} from 0x{X:0>8}", .{ T, address }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    return switch (address) {
        0x0200_0000...0x02FF_FFFF => readInt(T, self.main[address & 0x003F_FFFF ..][0..byte_count]),
        0x0380_0000...0x0380_FFFF => readInt(T, self.wram[address & 0x0000_FFFF ..][0..byte_count]),
        0x0400_0000...0x04FF_FFFF => io.read(self, T, address),
        else => warn("unexpected read: 0x{x:0>8} -> {}", .{ address, T }),
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

    switch (mode) {
        // .debug => log.debug("wrote 0x{X:}{} to 0x{X:0>8}", .{ value, T, address }),
        .debug => {},
        else => self.scheduler.tick += 1,
    }

    switch (address) {
        0x0200_0000...0x02FF_FFFF => writeInt(T, self.main[address & 0x003F_FFFF ..][0..byte_count], value),
        0x0380_0000...0x0380_FFFF => writeInt(T, self.wram[address & 0x0000_FFFF ..][0..byte_count], value),
        0x0400_0000...0x04FF_FFFF => io.write(self, T, address, value),
        else => log.warn("unexpected write: 0x{X:}{} -> 0x{X:0>8}", .{ value, T, address }),
    }
}

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}
