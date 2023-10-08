const std = @import("std");
const clap = @import("zig-clap");

const emu = @import("core/emu.zig");

const Ui = @import("platform.zig").Ui;
const SharedCtx = @import("core/emu.zig").SharedCtx;
const System = @import("core/emu.zig").System;
const Scheduler = @import("core/Scheduler.zig");

const Allocator = std.mem.Allocator;
const ClapResult = clap.Result(clap.Help, &cli_params, clap.parsers.default);

const cli_params = clap.parseParamsComptime(
    \\-h, --help        Display this help and exit.
    \\<str>             Path to the NDS ROM
    \\
);

pub fn main() !void {
    const log = std.log.scoped(.main);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    const result = try clap.parse(clap.Help, &cli_params, clap.parsers.default, .{});
    defer result.deinit();

    const rom_path = try handlePositional(result);
    log.debug("loading rom from: {s}", .{rom_path});

    const rom_file = try std.fs.cwd().openFile(rom_path, .{});
    defer rom_file.close();

    const ctx = try SharedCtx.init(allocator);
    defer ctx.deinit(allocator);

    var scheduler = try Scheduler.init(allocator);
    defer scheduler.deinit();

    const system: System = blk: {
        const IBus = @import("arm32").Bus;
        const IScheduler = @import("arm32").Scheduler;
        const ICoprocessor = @import("arm32").Coprocessor;

        var cp15 = System.Cp15{};

        var bus7 = try System.Bus7.init(allocator, &scheduler, ctx);
        var bus9 = try System.Bus9.init(allocator, &scheduler, ctx);

        var arm7tdmi = System.Arm7tdmi.init(IScheduler.init(&scheduler), IBus.init(&bus7));
        var arm946es = System.Arm946es.init(IScheduler.init(&scheduler), IBus.init(&bus9), ICoprocessor.init(&cp15));

        break :blk .{ .arm7tdmi = &arm7tdmi, .arm946es = &arm946es, .bus7 = &bus7, .bus9 = &bus9, .cp15 = &cp15 };
    };
    defer system.deinit(allocator);
    const rom_title = try emu.load(allocator, system, rom_file);

    var ui = try Ui.init(allocator);
    defer ui.deinit(allocator);

    ui.setTitle(rom_title);
    try ui.run(&scheduler, system);
}

fn handlePositional(result: ClapResult) ![]const u8 {
    return switch (result.positionals.len) {
        0 => error.too_few_positional_arguments,
        1 => result.positionals[0],
        else => return error.too_many_positional_arguments,
    };
}
