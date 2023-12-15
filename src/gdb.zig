const std = @import("std");
const Server = @import("gdbstub").Server;
const Interface = @import("gdbstub").Emulator;
const System = @import("core/emu.zig").System;
const Scheduler = @import("core/Scheduler.zig");

const Allocator = std.mem.Allocator;

pub const TurboWrapper = struct {
    system: System,
    scheduler: *Scheduler,

    pub fn init(system: System, scheduler: *Scheduler) @This() {
        return .{ .system = system, .scheduler = scheduler };
    }

    pub fn interface(self: *@This(), allocator: Allocator) Interface {
        return Interface.init(allocator, self);
    }

    pub fn read(self: *const @This(), addr: u32) u8 {
        return self.cpu.bus.dbgRead(u8, addr);
    }

    pub fn write(self: *@This(), addr: u32, value: u8) void {
        self.cpu.bus.dbgWrite(u8, addr, value);
    }

    pub fn registers(self: *const @This()) *[16]u32 {
        return &self.cpu.r;
    }

    pub fn cpsr(self: *const @This()) u32 {
        return self.cpu.cpsr.raw;
    }

    pub fn step(self: *@This()) void {
        _ = self;

        @panic("TODO: Handle ARM7 and ARM9 lol");
    }
};
