const std = @import("std");
const clap = @import("zig-clap");

const nds9 = @import("core/nds9.zig");
const nds7 = @import("core/nds7.zig");
const emu = @import("core/emu.zig");

const IBus = @import("arm32").Bus;
const IScheduler = @import("arm32").Scheduler;
const ICoprocessor = @import("arm32").Coprocessor;

const Ui = @import("platform.zig").Ui;
const SharedContext = @import("core/emu.zig").SharedContext;

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

    const shared_ctx = try SharedContext.init(allocator);
    defer shared_ctx.deinit(allocator);

    const nds9_group: nds9.Group = blk: {
        var scheduler = try nds9.Scheduler.init(allocator);
        var bus = try nds9.Bus.init(allocator, &scheduler, shared_ctx);
        var cp15 = nds9.Cp15{};

        var arm946es = nds9.Arm946es.init(IScheduler.init(&scheduler), IBus.init(&bus), ICoprocessor.init(&cp15));

        break :blk .{ .cpu = &arm946es, .bus = &bus, .scheduler = &scheduler };
    };
    defer nds9_group.deinit(allocator);

    const nds7_group: nds7.Group = blk: {
        var scheduler = try nds7.Scheduler.init(allocator);
        var bus = try nds7.Bus.init(allocator, &scheduler, shared_ctx);
        var arm7tdmi = nds7.Arm7tdmi.init(IScheduler.init(&scheduler), IBus.init(&bus));

        break :blk .{ .cpu = &arm7tdmi, .bus = &bus, .scheduler = &scheduler };
    };
    defer nds7_group.deinit(allocator);

    const rom_title = try emu.load(allocator, nds7_group, nds9_group, rom_file);

    var ui = try Ui.init(allocator);
    defer ui.deinit(allocator);

    ui.setTitle(rom_title);
    try ui.run(nds7_group, nds9_group);
}

fn handlePositional(result: ClapResult) ![]const u8 {
    return switch (result.positionals.len) {
        0 => error.too_few_positional_arguments,
        1 => result.positionals[0],
        else => return error.too_many_positional_arguments,
    };
}
