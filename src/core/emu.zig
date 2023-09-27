const std = @import("std");

const Header = @import("cartridge.zig").Header;
const SharedIo = @import("io.zig").Io;
const Scheduler = @import("Scheduler.zig");

const Allocator = std.mem.Allocator;

/// Load a NDS Cartridge
///
/// intended to be used immediately after Emulator initialization
pub fn load(allocator: Allocator, system: System, rom_file: std.fs.File) ![12]u8 {
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
        log.debug("ARM9 ROM Offset: 0x{X:0>8}", .{header.arm9_rom_offset});
        log.debug("ARM9 Entry Address: 0x{X:0>8}", .{header.arm9_entry_address});
        log.debug("ARM9 RAM Address: 0x{X:0>8}", .{header.arm9_ram_address});
        log.debug("ARM9 Size: 0x{X:0>8}", .{header.arm9_size});

        // Copy ARM9 Code into Main Memory
        for (rom_buf[header.arm9_rom_offset..][0..header.arm9_size], 0..) |value, i| {
            const address = header.arm9_ram_address + @as(u32, @intCast(i));
            system.bus9.dbgWrite(u8, address, value);
        }

        system.arm946es.r[15] = header.arm9_entry_address;
    }

    // Dealing with the ARM7TDMI
    {
        log.debug("ARM7 ROM Offset: 0x{X:0>8}", .{header.arm7_rom_offset});
        log.debug("ARM7 Entry Address: 0x{X:0>8}", .{header.arm7_entry_address});
        log.debug("ARM7 RAM Address: 0x{X:0>8}", .{header.arm7_ram_address});
        log.debug("ARM7 Size: 0x{X:0>8}", .{header.arm7_size});

        // Copy ARM7 Code into Main Memory
        for (rom_buf[header.arm7_rom_offset..][0..header.arm7_size], 0..) |value, i| {
            const address = header.arm7_ram_address + @as(u32, @intCast(i));
            system.bus7.dbgWrite(u8, address, value);
        }

        system.arm7tdmi.r[15] = header.arm7_entry_address;
    }

    return header.title;
}

const bus_clock = 33513982; // 33.513982 Hz
const dot_clock = 5585664; //   5.585664 Hz
const arm7_clock = bus_clock;
const arm9_clock = bus_clock * 2;

pub fn runFrame(scheduler: *Scheduler, system: System) void {
    const cycles_per_dot = arm9_clock / dot_clock + 1;
    comptime std.debug.assert(cycles_per_dot == 12);

    const cycles_per_frame = 355 * 263 * cycles_per_dot;
    const frame_end = scheduler.tick + cycles_per_frame;

    while (scheduler.tick < frame_end) {
        system.arm7tdmi.step();
        system.arm946es.step();
        system.arm946es.step();

        if (scheduler.check()) |ev| {
            const late = scheduler.tick - ev.tick;

            // this is kinda really jank lol
            const bus_ptr: ?*anyopaque = switch (ev.kind) {
                .heat_death => null,
                .nds7 => system.bus7,
                .nds9 => system.bus9,
            };

            scheduler.handle(bus_ptr, ev, late);
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

pub inline fn forceAlign(comptime T: type, address: u32) u32 {
    return switch (T) {
        u32 => address & ~@as(u32, 3),
        u16 => address & ~@as(u32, 1),
        u8 => address,
        else => @compileError("Bus: Invalid read/write type"),
    };
}

pub const System = struct {
    pub const Bus7 = @import("nds7/Bus.zig");
    pub const Bus9 = @import("nds9/Bus.zig");
    pub const Cp15 = @import("nds9/Cp15.zig");

    pub const Arm7tdmi = @import("arm32").Arm7tdmi;
    pub const Arm946es = @import("arm32").Arm946es;

    arm7tdmi: *Arm7tdmi,
    arm946es: *Arm946es,

    bus7: *Bus7,
    bus9: *Bus9,

    cp15: *Cp15,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.bus7.deinit(allocator);
        self.bus9.deinit(allocator);
    }
};
