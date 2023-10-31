const std = @import("std");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.nds7_bios);

const KiB = 0x400;
const len = 16 * KiB;

buf: ?*align(4) [len]u8 = null,

// FIXME: Currently we dupe here, should we just take ownership?
pub fn load(self: *@This(), allocator: Allocator, data: []u8) !void {
    if (data.len != len) {
        const acutal_size = @as(f32, @floatFromInt(data.len)) / KiB;
        log.warn("BIOS was {d:.2} KiB (should be {} KiB)", .{ acutal_size, len });
    }

    const buf = try allocator.alignedAlloc(u8, 4, len);
    @memset(buf, 0);
    @memcpy(buf[0..data.len], data);

    self.* = .{ .buf = buf[0..len] };
}

pub fn deinit(self: @This(), allocator: Allocator) void {
    if (self.buf) |ptr| allocator.destroy(ptr);
}

// Note: Parts of 16MiB addrspace that aren't mapped to BIOS are typically undefined
pub fn read(self: *const @This(), comptime T: type, address: u32) T {
    const readInt = std.mem.readIntLittle;
    const byte_count = @divExact(@typeInfo(T).Int.bits, 8);

    // if (address >= len) return 0x0000_0000; // TODO: What is undefined actually?

    const ptr = self.buf orelse {
        log.err("read(T: {}, address: 0x{X:0>8}) from BIOS but none was found!", .{ T, address });
        @panic("TODO: ability to load in NDS7 BIOS just-in-time");
    };

    return readInt(T, ptr[address & (len - 1) ..][0..byte_count]);
}

pub fn write(_: *const @This(), comptime T: type, address: u32, value: T) void {
    log.err("write(T: {}, address: 0x{X:0>8}, value: 0x{X:}) but we're in the BIOS!", .{ T, address, value });
}
