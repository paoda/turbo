const std = @import("std");

const Header = @import("cartridge.zig").Header;
const Scheduler = @import("Scheduler.zig");
const Ui = @import("../platform.zig").Ui;

const Allocator = std.mem.Allocator;

const dma7 = @import("nds7/dma.zig");
const dma9 = @import("nds9/dma.zig");

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

        try system.bus7.bios.load(allocator, buf);
    }

    { // NDS9 BIOS
        const path = try std.mem.join(allocator, "/", &.{ firm_path, "bios9.bin" });
        defer allocator.free(path);

        log.debug("bios9 path: {s}", .{path});

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buf = try file.readToEndAlloc(allocator, try file.getEndPos());
        defer allocator.free(buf);

        try system.bus9.bios.load(allocator, buf);
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
        switch (isHalted(system)) {
            .both => scheduler.tick = scheduler.peekTimestamp(),
            inline else => |halt| {
                if (!dma9.step(system.arm946es) and comptime halt != .arm9) {
                    system.arm946es.step();
                    system.arm946es.step();
                }

                if (!dma7.step(system.arm7tdmi) and comptime halt != .arm7) {
                    system.arm7tdmi.step();
                }
            },
        }

        if (scheduler.check()) |ev| {
            const late = scheduler.tick - ev.tick;
            scheduler.handle(system, ev, late);
        }
    }
}

const Halted = enum { arm7, arm9, both, none };

inline fn isHalted(system: System) Halted {
    const ret = [_]Halted{ .none, .arm7, .arm9, .both };
    const nds7_bus: *System.Bus7 = @ptrCast(@alignCast(system.arm7tdmi.bus.ptr));

    const nds9_halt: u2 = @intFromBool(system.cp15.wait_for_interrupt);
    const nds7_halt: u2 = @intFromBool(nds7_bus.io.haltcnt == .halt);

    return ret[(nds9_halt << 1) | nds7_halt];
}

// FIXME: Perf win to allocating on the stack instead?
pub const SharedCtx = struct {
    const MiB = 0x100000;
    const KiB = 0x400;

    pub const Io = @import("io.zig").Io;
    const Vram = @import("ppu/Vram.zig");

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

    pub fn read(self: @This(), comptime T: type, comptime proc: System.Process, address: u32) T {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (proc == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]const T = @ptrCast(@alignCast(some_ptr));

            return ptr[offset / @sizeOf(T)];
        }

        log.err("{s}: read(T: {}, addr: 0x{X:0>8}) was in un-mapped WRAM space", .{ @tagName(proc), T, 0x0300_0000 + address });
        return 0x00;
    }

    pub fn write(self: *@This(), comptime T: type, comptime proc: System.Process, address: u32, value: T) void {
        const bits = @typeInfo(IntFittingRange(0, page_size - 1)).Int.bits;
        const masked_addr = address & (addr_space_size - 1);
        const page = masked_addr >> bits;
        const offset = masked_addr & (page_size - 1);
        const table = if (proc == .nds9) self.nds9_table else self.nds7_table;

        if (table[page]) |some_ptr| {
            const ptr: [*]T = @ptrCast(@alignCast(some_ptr));
            ptr[offset / @sizeOf(T)] = value;

            return;
        }

        log.err("{s}: write(T: {}, addr: 0x{X:0>8}, value: 0x{X:0>8}) was in un-mapped WRAM space", .{ @tagName(proc), T, 0x0300_0000 + address, value });
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

    pub const Process = enum { nds7, nds9 };

    arm7tdmi: *Arm7tdmi,
    arm946es: *Arm946es,

    bus7: *Bus7,
    bus9: *Bus9,

    cp15: *Cp15,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.bus7.deinit(allocator);
        self.bus9.deinit(allocator);
    }

    fn Cpu(comptime proc: Process) type {
        return switch (proc) {
            .nds7 => Arm7tdmi,
            .nds9 => Arm946es,
        };
    }

    fn Bus(comptime proc: Process) type {
        return switch (proc) {
            .nds7 => Bus7,
            .nds9 => Bus9,
        };
    }
};

pub fn handleInterrupt(comptime proc: System.Process, cpu: *System.Cpu(proc)) void {
    const bus_ptr: *System.Bus(proc) = @ptrCast(@alignCast(cpu.bus.ptr));

    if (!bus_ptr.io.ime or cpu.cpsr.i.read()) return; // ensure irqs are enabled
    if ((bus_ptr.io.ie.raw & bus_ptr.io.irq.raw) == 0) return; // ensure there is an irq to handle

    switch (proc) {
        .nds9 => {
            const cp15: *System.Cp15 = @ptrCast(@alignCast(cpu.cp15.ptr));
            cp15.wait_for_interrupt = false;
        },
        .nds7 => bus_ptr.io.haltcnt = .execute,
    }

    const ret_addr = cpu.r[15] - if (cpu.cpsr.t.read()) 0 else @as(u32, 4);
    const spsr = cpu.cpsr;

    cpu.changeMode(.Irq);
    cpu.cpsr.t.unset();
    cpu.cpsr.i.set();

    cpu.r[14] = ret_addr;
    cpu.spsr.raw = spsr.raw;
    cpu.r[15] = if (proc == .nds9) 0xFFFF_0018 else 0x0000_0018;
    cpu.pipe.reload(cpu);
}

pub fn fastBoot(system: System) void {
    {
        const Bank = System.Arm946es.Bank;

        const cpu = system.arm946es;

        // from advanDS
        cpu.spsr = .{ .raw = 0x0000_000DF };

        @memset(cpu.r[0..12], 0x0000_0000); // r0 -> r11 are zeroed
        // TODO: r12, r14, and r15 are set to the entrypoint?
        cpu.r[13] = 0x0300_2F7C; // FIXME: Why is there (!) in GBATEK?
        cpu.bank.r[Bank.regIdx(.Irq, .R13)] = 0x0300_3F80;
        cpu.bank.r[Bank.regIdx(.Supervisor, .R13)] = 0x0300_3FC0;
        cpu.bank.spsr[Bank.spsrIdx(.Irq)] = .{ .raw = 0x0000_0000 };
        cpu.bank.spsr[Bank.spsrIdx(.Supervisor)] = .{ .raw = 0x0000_0000 };
    }
    {
        const Bank = System.Arm7tdmi.Bank;

        const cpu = system.arm7tdmi;

        // from advanDS
        cpu.spsr = .{ .raw = 0x0000_000D3 };

        @memset(cpu.r[0..12], 0x0000_0000); // r0 -> r11 are zeroed
        // TODO: r12, r14, and r15 are set to the entrypoint?
        cpu.r[13] = 0x0380_FD80;
        cpu.bank.r[Bank.regIdx(.Irq, .R13)] = 0x0380_FF80;
        cpu.bank.r[Bank.regIdx(.Supervisor, .R13)] = 0x0380_FFC0;
        cpu.bank.spsr[Bank.spsrIdx(.Irq)] = .{ .raw = 0x0000_0000 };
        cpu.bank.spsr[Bank.spsrIdx(.Supervisor)] = .{ .raw = 0x0000_0000 };
    }
}

pub const Sync = struct {
    const Atomic = std.atomic.Value;

    should_quit: Atomic(bool) = Atomic(bool).init(false),

    pub fn init(self: *Sync) void {
        self.* = .{};
    }
};

pub const debug = struct {
    const Interface = @import("gdbstub").Emulator;
    const Server = @import("gdbstub").Server;
    const AtomicBool = std.atomic.Value(bool);
    const log = std.log.scoped(.gdbstub);

    const nds7 = struct {
        const target: []const u8 =
            \\<target version="1.0">
            \\    <architecture>armv4t</architecture>
            \\    <feature name="org.gnu.gdb.arm.core">
            \\        <reg name="r0" bitsize="32" type="uint32"/>
            \\        <reg name="r1" bitsize="32" type="uint32"/>
            \\        <reg name="r2" bitsize="32" type="uint32"/>
            \\        <reg name="r3" bitsize="32" type="uint32"/>
            \\        <reg name="r4" bitsize="32" type="uint32"/>
            \\        <reg name="r5" bitsize="32" type="uint32"/>
            \\        <reg name="r6" bitsize="32" type="uint32"/>
            \\        <reg name="r7" bitsize="32" type="uint32"/>
            \\        <reg name="r8" bitsize="32" type="uint32"/>
            \\        <reg name="r9" bitsize="32" type="uint32"/>
            \\        <reg name="r10" bitsize="32" type="uint32"/>
            \\        <reg name="r11" bitsize="32" type="uint32"/>
            \\        <reg name="r12" bitsize="32" type="uint32"/>
            \\        <reg name="sp" bitsize="32" type="data_ptr"/>
            \\        <reg name="lr" bitsize="32"/>
            \\        <reg name="pc" bitsize="32" type="code_ptr"/>
            \\
            \\        <reg name="cpsr" bitsize="32" regnum="25"/>
            \\    </feature>
            \\</target>
        ;

        // Remember that a lot of memory regions are mirrored
        const memory_map: []const u8 =
            \\ <memory-map version="1.0">
            \\     <memory type="rom" start="0x00000000" length="0x00004000"/>
            \\     <memory type="ram" start="0x02000000" length="0x01000000"/>
            \\     <memory type="ram" start="0x03000000" length="0x00800000"/>
            \\     <memory type="ram" start="0x03800000" length="0x00800000"/>
            \\     <memory type="ram" start="0x04000000" length="0x00100010"/>
            \\     <memory type="ram" start="0x06000000" length="0x01000000"/>
            \\     <memory type="rom" start="0x08000000" length="0x02000000"/>
            \\     <memory type="rom" start="0x0A000000" length="0x01000000"/>
            \\ </memory-map>
        ;
    };

    pub fn Wrapper(comptime proc: System.Process) type {
        return struct {
            system: System,
            scheduler: *Scheduler,

            tick: u64 = 0,

            pub fn init(system: System, scheduler: *Scheduler) @This() {
                return .{ .system = system, .scheduler = scheduler };
            }

            pub fn interface(self: *@This(), allocator: Allocator) Interface {
                return Interface.init(allocator, self);
            }

            pub fn read(self: *const @This(), addr: u32) u8 {
                const arm = switch (proc) {
                    .nds7 => self.system.arm7tdmi,
                    .nds9 => self.system.arm946es,
                };

                return arm.dbgRead(u8, addr);
            }

            pub fn write(self: *@This(), addr: u32, value: u8) void {
                const arm = switch (proc) {
                    .nds7 => self.system.arm7tdmi,
                    .nds9 => self.system.arm946es,
                };

                return arm.dbgWrite(u8, addr, value);
            }

            pub fn registers(self: *const @This()) *[16]u32 {
                const arm = switch (proc) {
                    .nds7 => self.system.arm7tdmi,
                    .nds9 => self.system.arm946es,
                };

                return &arm.r;
            }

            pub fn cpsr(self: *const @This()) u32 {
                const arm = switch (proc) {
                    .nds7 => self.system.arm7tdmi,
                    .nds9 => self.system.arm946es,
                };

                return arm.cpsr.raw;
            }

            pub fn step(self: *@This()) void {
                const scheduler = self.scheduler;
                const system = self.system;

                var did_step: bool = false;

                // TODO: keep in lockstep with runFrame
                while (true) {
                    if (did_step) break;

                    switch (isHalted(system)) {
                        .both => scheduler.tick = scheduler.peekTimestamp(),
                        inline else => |halt| {
                            if (!dma9.step(system.arm946es) and comptime halt != .arm9) {
                                system.arm946es.step();

                                switch (proc) {
                                    .nds9 => did_step = true,
                                    .nds7 => system.arm946es.step(),
                                }
                            }

                            if (!dma7.step(system.arm7tdmi) and comptime halt != .arm7) {
                                if (proc == .nds7 or self.tick % 2 == 0) system.arm7tdmi.step();

                                if (proc == .nds7) {
                                    did_step = true;
                                    self.tick += 1;
                                }
                            }
                        },
                    }

                    if (scheduler.check()) |ev| {
                        const late = scheduler.tick - ev.tick;
                        scheduler.handle(system, ev, late);
                    }
                }
            }
        };
    }

    pub fn run(allocator: Allocator, ui: *Ui, scheduler: *Scheduler, system: System, sync: *Sync) !void {
        var wrapper = Wrapper(.nds9).init(system, scheduler);

        var emu_interface = wrapper.interface(allocator);
        defer emu_interface.deinit();

        var server = try Server.init(emu_interface, .{ .target = nds7.target, .memory_map = nds7.memory_map });
        defer server.deinit(allocator);

        const thread = try std.Thread.spawn(.{}, Server.run, .{ &server, allocator, &sync.should_quit });
        defer thread.join();

        try ui.debug_run(scheduler, system, sync);
    }
};
