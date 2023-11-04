const std = @import("std");
const Bus = @import("../nds9/Bus.zig");

const FrameBuffer = @import("../ppu.zig").FrameBuffer;

const DispcntA = @import("../nds9/io.zig").DispcntA;
const DispcntB = @import("../nds9/io.zig").DispcntB;

const Dispstat = @import("../nds9/io.zig").Dispstat;
const Vcount = @import("../nds9/io.zig").Vcount;

const PowCnt = @import("../nds9/io.zig").PowCnt;

const width = @import("../ppu.zig").screen_width;
const height = @import("../ppu.zig").screen_height;

const EngineKind = enum { a, b };

pub const EngineA = Engine(.a);
pub const EngineB = Engine(.b);

fn Engine(comptime kind: EngineKind) type {
    const log = std.log.scoped(.engine2d);
    _ = log; // TODO: specify between 2D-A and 2D-B

    // FIXME: don't commit zig crimes
    const Type = struct {
        fn inner(comptime TypeA: type, comptime TypeB: type) type {
            return if (kind == .a) TypeA else TypeB;
        }
    }.inner;

    return struct {
        dispcnt: Type(DispcntA, DispcntB) = .{ .raw = 0x0000_0000 },
        dispstat: Dispstat = .{ .raw = 0x0000_0000 },
        vcount: Vcount = .{ .raw = 0x0000_0000 },

        pub fn drawScanline(self: *@This(), bus: *Bus, fb: *FrameBuffer, powcnt: *PowCnt) void {
            const disp_mode = self.dispcnt.display_mode.read();

            switch (disp_mode) {
                0 => { // Display Off
                    const buf = switch (kind) {
                        .a => if (powcnt.display_swap.read()) fb.top(.back) else fb.btm(.back),
                        .b => if (powcnt.display_swap.read()) fb.btm(.back) else fb.top(.back),
                    };

                    @memset(buf, 0xFF); // set everything to white
                },
                1 => @panic("TODO: standard graphics display (text mode, etc)"),
                2 => { // VRAM display
                    if (kind == .b) return;
                    // TODO: Master Brightness can still affect this mode

                    const scanline: u32 = self.vcount.scanline.read();
                    const buf = if (powcnt.display_swap.read()) fb.top(.back) else fb.btm(.back);

                    const scanline_buf = blk: {
                        const rgba_ptr: *[width * height]u32 = @ptrCast(@alignCast(buf));
                        break :blk rgba_ptr[width * scanline ..][0..width];
                    };

                    const base_addr: u32 = 0x0680_0000 + (width * @sizeOf(u16)) * @as(u32, scanline);

                    for (scanline_buf, 0..) |*rgba, i| {
                        const addr = base_addr + @as(u32, @intCast(i)) * @sizeOf(u16);
                        rgba.* = rgba888(bus.dbgRead(u16, addr));
                    }
                },
                3 => {
                    if (kind == .b) return;

                    @panic("TODO: main memory display");
                },
            }
        }
    };
}

inline fn rgba888(bgr555: u16) u32 {
    const b: u32 = bgr555 >> 10 & 0x1F;
    const g: u32 = bgr555 >> 5 & 0x1F;
    const r: u32 = bgr555 & 0x1F;

    // zig fmt: off
    return (r << 3 | r >> 2) << 24
        |  (g << 3 | g >> 2) << 16
        |  (b << 3 | b >> 2) << 8
        |  0xFF;
    // zig fmt: on
}
