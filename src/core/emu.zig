const std = @import("std");
const nds9 = @import("nds9.zig");
const nds7 = @import("nds7.zig");

const Header = @import("cartridge.zig").Header;
const SharedIo = @import("io.zig").Io;
const Arm946es = nds9.Arm946es;

const Allocator = std.mem.Allocator;

/// Load a NDS Cartridge
///
/// intended to be used immediately after Emulator initialization
pub fn load(allocator: Allocator, nds7_group: nds7.Group, nds9_group: nds9.Group, rom_file: std.fs.File) ![12]u8 {
    const log = std.log.scoped(.load_rom);

    const rom_buf = try rom_file.readToEndAlloc(allocator, try rom_file.getEndPos());
    defer allocator.free(rom_buf);

    var stream = std.io.fixedBufferStream(rom_buf);
    const header = try stream.reader().readStruct(Header);

    log.info("Title: \"{s}\"", .{std.mem.sliceTo(&header.title, 0)});
    log.info("Game Code: \"{s}\"", .{std.mem.sliceTo(&header.game_code, 0)});
    log.info("Maker Code: \"{s}\"", .{std.mem.sliceTo(&header.maker_code, 0)});

    // Dealing with the ARM946E-S
    {
        const arm946es = nds9_group.cpu;

        log.debug("ARM9 ROM Offset: 0x{X:0>8}", .{header.arm9_rom_offset});
        log.debug("ARM9 Entry Address: 0x{X:0>8}", .{header.arm9_entry_address});
        log.debug("ARM9 RAM Address: 0x{X:0>8}", .{header.arm9_ram_address});
        log.debug("ARM9 Size: 0x{X:0>8}", .{header.arm9_size});

        // Copy ARM9 Code into Main Memory
        for (rom_buf[header.arm9_rom_offset..][0..header.arm9_size], 0..) |value, i| {
            const address = header.arm9_ram_address + @as(u32, @intCast(i));
            nds9_group.bus.dbgWrite(u8, address, value);
        }

        arm946es.r[15] = header.arm9_entry_address;
    }

    // Dealing with the ARM7TDMI
    {
        const arm7tdmi = nds7_group.cpu;

        log.debug("ARM7 ROM Offset: 0x{X:0>8}", .{header.arm7_rom_offset});
        log.debug("ARM7 Entry Address: 0x{X:0>8}", .{header.arm7_entry_address});
        log.debug("ARM7 RAM Address: 0x{X:0>8}", .{header.arm7_ram_address});
        log.debug("ARM7 Size: 0x{X:0>8}", .{header.arm7_size});

        // Copy ARM7 Code into Main Memory
        for (rom_buf[header.arm7_rom_offset..][0..header.arm7_size], 0..) |value, i| {
            const address = header.arm7_ram_address + @as(u32, @intCast(i));
            nds7_group.bus.dbgWrite(u8, address, value);
        }

        arm7tdmi.r[15] = header.arm7_entry_address;
    }

    return header.title;
}

const bus_clock = 33513982; // 33.513982 Hz
const dot_clock = 5585664; //   5.585664 Hz
const arm7_clock = bus_clock;
const arm9_clock = bus_clock * 2;

pub fn runFrame(nds7_group: nds7.Group, nds9_group: nds9.Group) void {
    // TODO: might be more efficient to run them both in the same loop?
    {
        const scheduler = nds7_group.scheduler;

        const cycles_per_dot = arm7_clock / dot_clock + 1;
        comptime std.debug.assert(cycles_per_dot == 6);

        const cycles_per_frame = 355 * 263 * cycles_per_dot;
        const frame_end = scheduler.tick + cycles_per_frame;

        const cpu = nds7_group.cpu;
        const bus = nds7_group.bus;

        while (scheduler.tick < frame_end) {
            cpu.step();

            if (scheduler.tick >= scheduler.next()) scheduler.handle(bus);
        }
    }

    {
        const scheduler = nds9_group.scheduler;

        const cycles_per_dot = arm9_clock / dot_clock + 1;
        comptime std.debug.assert(cycles_per_dot == 12);

        const cycles_per_frame = 355 * 263 * cycles_per_dot;
        const frame_end = scheduler.tick + cycles_per_frame;

        const cpu = nds9_group.cpu;
        const bus = nds9_group.bus;

        while (scheduler.tick < frame_end) {
            cpu.step();

            if (scheduler.tick >= scheduler.next()) scheduler.handle(bus);
        }
    }
}

// FIXME: Perf win to allocating on the stack instead?
pub const SharedContext = struct {
    const MiB = 0x100000;

    io: *SharedIo,
    main: *[4 * MiB]u8,

    pub fn init(allocator: Allocator) !@This() {
        const ctx = .{
            .io = try allocator.create(SharedIo),
            .main = try allocator.create([4 * MiB]u8),
        };
        ctx.io.* = .{};

        return ctx;
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.destroy(self.io);
        allocator.destroy(self.main);
    }
};
