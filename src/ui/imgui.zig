const std = @import("std");
const zgui = @import("zgui");

const platform = @import("../platform.zig");

const Arm946es = @import("../core/nds9.zig").Arm946es;
const Dimensions = platform.Dimensions;

const nds_height = @import("../core/ppu.zig").screen_height;
const nds_width = @import("../core/ppu.zig").screen_width;

const GLuint = c_uint;

pub const State = struct {
    const default_rom_title: [12:0]u8 = "No Title\x00\x00\x00\x00".*;

    title: [12:0]u8 = default_rom_title,
    dim: Dimensions = .{ .width = 1280, .height = 720 },
};

pub fn draw(state: *const State, top_tex: GLuint, btm_tex: GLuint, arm946es: *Arm946es) bool {
    _ = arm946es;
    zgui.backend.newFrame(@floatFromInt(state.dim.width), @floatFromInt(state.dim.height));

    {
        const w: f32 = @floatFromInt((nds_width * 3) / 2);
        const h: f32 = @floatFromInt((nds_height * 3) / 2);

        const provided = std.mem.sliceTo(&state.title, 0);
        const window_title = if (provided.len == 0) &State.default_rom_title else provided;

        _ = zgui.begin(window_title, .{ .flags = .{ .no_resize = true, .always_auto_resize = true } });
        defer zgui.end();

        zgui.image(@ptrFromInt(top_tex), .{ .w = w, .h = h });
        zgui.image(@ptrFromInt(btm_tex), .{ .w = w, .h = h });
    }

    return true;
}
