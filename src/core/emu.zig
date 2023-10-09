const std = @import("std");

const Header = @import("cartridge.zig").Header;
const Scheduler = @import("Scheduler.zig");

const Allocator = std.mem.Allocator;

/// Load a NDS Cartridge
///
/// intended to be used immediately after Emulator initialization
pub fn load(allocator: Allocator, system: System, rom_path: []const u8) ![12]u8 {
    const log = std.log.scoped(.load_rom);

    const file = try std.fs.cwd().openFile(rom_path, .{});
    defer file.close();

    const buf = try file.readToEndAlloc(allocator, try file.getEndPos());
    defer allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
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
        for (buf[header.arm9_rom_offset..][0..header.arm9_size], 0..) |value, i| {
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
        for (buf[header.arm7_rom_offset..][0..header.arm7_size], 0..) |value, i| {
            const address = header.arm7_ram_address + @as(u32, @intCast(i));
            system.bus7.dbgWrite(u8, address, value);
        }

        system.arm7tdmi.r[15] = header.arm7_entry_address;
    }

    return header.title;
}

/// Load NDS Firmware
pub fn loadFirm(allocator: Allocator, system: System, firm_path: []const u8) !void {
    const log = std.log.scoped(.load_firm);

    { // NDS7 BIOS
        const path = try std.mem.join(allocator, "/", &.{ firm_path, "bios7.bin" });
        defer allocator.free(path);

        log.debug("bios7 path: {s}", .{path});

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buf = try file.readToEndAlloc(allocator, try file.getEndPos());
        defer allocator.free(buf);

        @memcpy(system.bus7.bios[0..buf.len], buf);
    }

    { // NDS9 BIOS
        const path = try std.mem.join(allocator, "/", &.{ firm_path, "bios9.bin" });
        defer allocator.free(path);

        log.debug("bios9 path: {s}", .{path});

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buf = try file.readToEndAlloc(allocator, try file.getEndPos());
        defer allocator.free(buf);

        @memcpy(system.bus9.bios[0..buf.len], buf);
    }
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
pub const SharedCtx = struct {
    const MiB = 0x100000;
    const KiB = 0x400;

    pub const Io = @import("io.zig").Io;
    const Vram = @import("ppu.zig").Vram;

    io: *Io,
    main: *[4 * MiB]u8,
    wram: *Wram,
    vram: *Vram,

    pub fn init(allocator: Allocator) !@This() {
        const wram = try allocator.create(Wram);
        errdefer allocator.destroy(wram);
        try wram.init(allocator);

        const vram = try allocator.create(Vram);
        errdefer allocator.destroy(vram);
        try vram.init(allocator);

        const ctx = .{
            .io = blk: {
                const io = try allocator.create(Io);
                io.* = .{};

                break :blk io;
            },
            .wram = wram,
            .vram = vram,
            .main = try allocator.create([4 * MiB]u8),
        };

        return ctx;
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.wram.deinit(allocator);
        allocator.destroy(self.wram);

        self.vram.deinit(allocator);
        allocator.destroy(self.vram);

        allocator.destroy(self.io);
        allocator.destroy(self.main);
    }
};

// Before I implement Bus-wide Fastmem, Let's play with some more limited (read: less useful)
// fastmem implementations

// TODO: move somewhere else ideally
pub const Wram = struct {
    const page_size = 1 * KiB; // perhaps too big?
    const addr_space_size = 0x8000;
    const table_len = addr_space_size / page_size;
    const buf_len = 32 * KiB;

    const IntFittingRange = std.math.IntFittingRange;

    const io = @import("io.zig");
    const KiB = 0x400;

    const log = std.log.scoped(.shared_wram);

    _buf: *[buf_len]u8,

    nds9_table: *const [table_len]?[*]u8,
    nds7_table: *const [table_len]?[*]u8,

    pub fn init(self: *@This(), allocator: Allocator) !void {
        const buf = try allocator.create([buf_len]u8);
        errdefer allocator.destroy(buf);

        const tables = try allocator.alloc(?[*]u8, 2 * table_len);
        @memset(tables, null);

        self.* = .{
            .nds9_table = tables[0..table_len],
            .nds7_table = tables[table_len .. 2 * table_len],
            ._buf = buf,
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.destroy(self._buf);

        const ptr: [*]?[*]const u8 = @ptrCast(@constCast(self.nds9_table));
        allocator.free(ptr[0 .. 2 * table_len]);
    }

    pub fn update(self: *@This(), wramcnt: io.WramCnt) void {
        const mode = wramcnt.mode.read();

        const nds9_tbl = @constCast(self.nds9_table);
        const nds7_tbl = @constCast(self.nds7_table);

        for (nds9_tbl, nds7_tbl, 0..) |*nds9_ptr, *nds7_ptr, i| {
            const addr = i * page_size;

            switch (mode) {
                0b00 => {
                    nds9_ptr.* = self._buf[addr..].ptr;
                    nds7_ptr.* = null;
                },
                0b01 => {
                    nds9_ptr.* = self._buf[0x4000 + (addr & 0x3FFF) ..].ptr;
                    nds7_ptr.* = self._buf[(addr & 0x3FFF)..].ptr;
                },
                0b10 => {
                    nds9_ptr.* = self._buf[(addr & 0x3FFF)..].ptr;
                    nds7_ptr.* = self._buf[0x4000 + (addr & 0x3FFF) ..].ptr;
                },
                0b11 => {
                    nds9_ptr.* = null;
                    nds7_ptr.* = self._buf[addr..].ptr;
                },
            }
        }
    }

    // TODO: Rename
    const Device = enum { nds9, nds7 };

    pub fn read(self: @This(), comptime T: type, comptime dev: Device, address: u32) T {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (dev == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]const T = @ptrCast(@alignCast(some_ptr));

            return ptr[offset / @sizeOf(T)];
        }

        log.err("{s}: read(T: {}, addr: 0x{X:0>8}) was in un-mapped WRAM space", .{ @tagName(dev), T, 0x0300_0000 + address });
        return 0x00;
    }

    pub fn write(self: *@This(), comptime T: type, comptime dev: Device, address: u32, value: T) void {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (dev == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]T = @ptrCast(@alignCast(some_ptr));
            ptr[offset / @sizeOf(T)] = value;

            return;
        }

        log.err("{s}: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8}) was in un-mapped WRAM space", .{ @tagName(dev), T, 0x0300_0000 + address, value });
    }
};

pub inline fn forceAlign(comptime T: type, address: u32) u32 {
    return address & ~@as(u32, @sizeOf(T) - 1);
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

// FIXME: Using Wram.Device here is jank. System should probably carry an Enum + some Generic Type Fns
pub fn handleInterrupt(comptime dev: Wram.Device, cpu: if (dev == .nds9) *System.Arm946es else *System.Arm7tdmi) void {
    const Bus = if (dev == .nds9) System.Bus9 else System.Bus7;
    const bus_ptr: *Bus = @ptrCast(@alignCast(cpu.bus.ptr));

    if (!bus_ptr.io.ime or cpu.cpsr.i.read()) return; // ensure irqs are enabled
    if ((bus_ptr.io.ie.raw & bus_ptr.io.irq.raw) == 0) return; // ensure there is an irq to handle

    // TODO: Handle HALT
    // HALTCNG (NDS7) and CP15 (NDS9)

    const ret_addr = cpu.r[15] - if (cpu.cpsr.t.read()) 0 else @as(u32, 4);
    const spsr = cpu.cpsr;

    cpu.changeMode(.Irq);
    cpu.cpsr.t.unset();
    cpu.cpsr.i.set();

    cpu.r[14] = ret_addr;
    cpu.spsr.raw = spsr.raw;
    cpu.r[15] = if (dev == .nds9) 0xFFFF_0018 else 0x0000_0018;
    cpu.pipe.reload(cpu);
}
