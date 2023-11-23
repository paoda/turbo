const std = @import("std");
const Bus = @import("../nds9/Bus.zig");

const FrameBuffer = @import("../ppu.zig").FrameBuffer;

const DispcntA = @import("../nds9/io.zig").DispcntA;
const DispcntB = @import("../nds9/io.zig").DispcntB;

const Ppu = @import("../ppu.zig").Ppu;

const width = @import("../ppu.zig").screen_width;
const height = @import("../ppu.zig").screen_height;

const KiB = 0x400;

const EngineKind = enum { a, b };

pub const EngineA = Engine(.a);
pub const EngineB = Engine(.b);

fn Engine(comptime kind: EngineKind) type {
    const log = std.log.scoped(.engine2d); // TODO: specify between 2D-A and 2D-B

    // FIXME: don't commit zig crimes
    const Type = struct {
        fn inner(comptime TypeA: type, comptime TypeB: type) type {
            return if (kind == .a) TypeA else TypeB;
        }
    }.inner;

    return struct {
        dispcnt: Type(DispcntA, DispcntB) = .{ .raw = 0x0000_0000 },

        bg: [4]bg.Text = .{ .{}, .{}, .{}, .{} },

        // TODO: Rename
        scanline: Scanline,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .scanline = try Scanline.init(allocator),
            };
        }

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            self.scanline.deinit(allocator);
        }

        pub fn drawScanline(self: *@This(), bus: *Bus, fb: *FrameBuffer) void {
            const disp_mode = self.dispcnt.display_mode.read();

            switch (disp_mode) {
                0 => { // Display Off
                    const buf = switch (kind) {
                        .a => if (bus.ppu.io.powcnt.display_swap.read()) fb.top(.back) else fb.btm(.back),
                        .b => if (bus.ppu.io.powcnt.display_swap.read()) fb.btm(.back) else fb.top(.back),
                    };

                    @memset(buf, 0xFF); // set everything to white
                },
                1 => {
                    const bg_mode = self.dispcnt.bg_mode.read();
                    const bg_enable = self.dispcnt.bg_enable.read();
                    const scanline: u32 = bus.ppu.io.nds9.vcount.scanline.read();

                    switch (bg_mode) {
                        //  BG0     BG1     BG2     BG3
                        //  Text/3D Text    Text    Text
                        0 => {
                            // TODO: Fetch Sprites

                            for (0..4) |layer| {
                                // TODO: Draw Sprites

                                inline for (0..4) |i| {
                                    if (layer == self.bg[i].cnt.priority.read() and (bg_enable >> i) & 1 == 1) self.drawBackground(i, bus);
                                }
                            }

                            const buf = switch (kind) {
                                .a => if (bus.ppu.io.powcnt.display_swap.read()) fb.top(.back) else fb.btm(.back),
                                .b => if (bus.ppu.io.powcnt.display_swap.read()) fb.btm(.back) else fb.top(.back),
                            };

                            const scanline_buf = blk: {
                                const rgba_ptr: *[width * height]u32 = @ptrCast(@alignCast(buf));
                                break :blk rgba_ptr[width * scanline ..][0..width];
                            };

                            self.renderTextMode(bus.dbgRead(u16, 0x0500_0000), scanline_buf);
                        },
                        else => |mode| {
                            log.err("TODO: Implement Mode {}", .{mode});
                            @panic("fatal error");
                        },
                    }
                },
                2 => { // VRAM display
                    if (kind == .b) return;
                    // TODO: Master Brightness can still affect this mode

                    const scanline: u32 = bus.ppu.io.nds9.vcount.scanline.read();
                    const buf = if (bus.ppu.io.powcnt.display_swap.read()) fb.top(.back) else fb.btm(.back);

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

        fn drawBackground(self: *@This(), comptime layer: u2, bus: *Bus) void {
            const screen_base = blk: {
                const bgcnt_off: u32 = self.bg[layer].cnt.screen_base.read();
                const dispcnt_off: u32 = if (kind == .a) self.dispcnt.screen_base.read() else 0;

                break :blk (2 * KiB) * bgcnt_off + (64 * KiB) * dispcnt_off;
            };

            const char_base = blk: {
                const bgcnt_off: u32 = self.bg[layer].cnt.char_base.read();
                const dispcnt_off: u32 = if (kind == .a) self.dispcnt.char_base.read() else 0;

                break :blk (16 * KiB) * bgcnt_off + (64 * KiB) * dispcnt_off;
            };

            const is_8bpp = self.bg[layer].cnt.colour_mode.read();
            const size = self.bg[layer].cnt.size.read();

            // In 4bpp: 1 byte represents two pixels so the length is (8 x 8) / 2
            // In 8bpp: 1 byte represents one pixel so the length is 8 x 8
            const tile_len: u32 = if (is_8bpp) 0x40 else 0x20;
            const tile_row_offset: u32 = if (is_8bpp) 0x8 else 0x4;

            const vofs: u32 = self.bg[layer].vofs.offset.read();
            const hofs: u32 = self.bg[layer].hofs.offset.read();

            const y: u32 = vofs + bus.ppu.io.nds9.vcount.scanline.read();

            for (0..width) |idx| {
                const i: u32 = @intCast(idx);
                const x = hofs + i;

                // TODO: Windowing

                // Grab the Screen Entry from VRAM
                const entry_addr = screen_base + tilemapOffset(size, x, y);
                const entry: bg.Screen.Entry = @bitCast(bus.read(u16, 0x0600_0000 + entry_addr));

                // Calculate the Address of the Tile in the designated Charblock
                // We also take this opportunity to flip tiles if necessary
                const tile_id: u32 = entry.tile_id.read();

                // Calculate row and column offsets. Understand that
                // `tile_len`, `tile_row_offset` and `col` are subject to different
                // values depending on whether we are in 4bpp or 8bpp mode.
                const row = @as(u3, @truncate(y)) ^ if (entry.v_flip.read()) 7 else @as(u3, 0);
                const col = @as(u3, @truncate(x)) ^ if (entry.h_flip.read()) 7 else @as(u3, 0);
                const tile_addr = char_base + (tile_id * tile_len) + (row * tile_row_offset) + if (is_8bpp) col else col >> 1;

                const tile = bus.read(u8, 0x0600_0000 + tile_addr);
                // If we're in 8bpp, then the tile value is an index into the palette,
                // If we're in 4bpp, we have to account for a pal bank value in the Screen entry
                // and then we can index the palette
                const pal_addr: u32 = if (!is_8bpp) get4bppTilePalette(entry.pal_bank.read(), col, tile) else tile;

                if (pal_addr != 0) {
                    self.drawBackgroundPixel(layer, i, bus.read(u16, 0x0500_0000 + pal_addr * 2));
                }
            }
        }

        inline fn get4bppTilePalette(pal_bank: u4, col: u3, tile: u8) u8 {
            const nybble_tile = tile >> ((col & 1) << 2) & 0xF;
            if (nybble_tile == 0) return 0;

            return (@as(u8, pal_bank) << 4) | nybble_tile;
        }

        fn renderTextMode(self: *@This(), backdrop: u16, frame_buf: []u32) void {
            for (self.scanline.top(), self.scanline.btm(), frame_buf) |maybe_top, maybe_btm, *rgba| {
                _ = maybe_btm;

                const bgr555 = switch (maybe_top) {
                    .set => |px| px,
                    else => backdrop,
                };

                rgba.* = rgba888(bgr555);
            }

            self.scanline.reset();
        }

        // TODO: Comment this + get a better understanding
        fn tilemapOffset(size: u2, x: u32, y: u32) u32 {
            // Current Row: (y % PIXEL_COUNT) / 8
            // Current COlumn: (x % PIXEL_COUNT) / 8
            // Length of 1 row of Screen Entries: 0x40
            // Length of 1 Screen Entry: 0x2 is the size of a screen entry
            @setRuntimeSafety(false);

            return switch (size) {
                0 => (x % 256 / 8) * 2 + (y % 256 / 8) * 0x40, // 256 x 256
                1 => blk: {
                    // 512 x 256
                    const offset: u32 = if (x & 0x1FF > 0xFF) 0x800 else 0;
                    break :blk offset + (x % 256 / 8) * 2 + (y % 256 / 8) * 0x40;
                },
                2 => blk: {
                    // 256 x 512
                    const offset: u32 = if (y & 0x1FF > 0xFF) 0x800 else 0;
                    break :blk offset + (x % 256 / 8) * 2 + (y % 256 / 8) * 0x40;
                },
                3 => blk: {
                    // 512 x 512
                    const offset: u32 = if (x & 0x1FF > 0xFF) 0x800 else 0;
                    const offset_2: u32 = if (y & 0x1FF > 0xFF) 0x800 else 0;
                    break :blk offset + offset_2 + (x % 256 / 8) * 2 + (y % 512 / 8) * 0x40;
                },
            };
        }

        fn drawBackgroundPixel(self: *@This(), comptime layer: u2, i: u32, bgr555: u16) void {
            _ = layer;

            self.scanline.top()[i] = Scanline.Pixel.from(.Background, bgr555);
        }
    };
}

const Scanline = struct {
    const Pixel = union(enum) {
        // TODO: Rename
        const Layer = enum { Background, Sprite };

        set: u16,
        obj_set: u16,
        unset: void,
        hidden: void,

        fn from(comptime layer: Layer, bgr555: u16) Pixel {
            return switch (layer) {
                .Background => .{ .set = bgr555 },
                .Sprite => .{ .obj_set = bgr555 },
            };
        }

        pub fn isSet(self: @This()) bool {
            return switch (self) {
                .set, .obj_set => true,
                .unset, .hidden => false,
            };
        }
    };

    layers: [2][]Pixel,
    buf: []Pixel,

    fn init(allocator: std.mem.Allocator) !@This() {
        const buf = try allocator.alloc(Pixel, width * 2); // Top & Bottom Scanline
        @memset(buf, .unset);

        return .{
            // Top & Bototm Layers
            .layers = [_][]Pixel{ buf[0..][0..width], buf[width..][0..width] },
            .buf = buf,
        };
    }

    fn reset(self: *@This()) void {
        @memset(self.buf, .unset);
    }

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    fn top(self: *@This()) []Pixel {
        return self.layers[0];
    }

    fn btm(self: *@This()) []Pixel {
        return self.layers[1];
    }
};

const bg = struct {
    const Text = struct {
        const io = @import("../nds9/io.zig");

        /// Read / Write
        cnt: io.Bgcnt = .{ .raw = 0x0000 },
        /// Write Only
        hofs: io.Hofs = .{ .raw = 0x0000 },
        /// Write Only
        vofs: io.Vofs = .{ .raw = 0x0000 },
    };

    const Screen = struct {
        const Entry = extern union {
            const Bitfield = @import("bitfield").Bitfield;
            const Bit = @import("bitfield").Bit;

            tile_id: Bitfield(u16, 0, 10),
            h_flip: Bit(u16, 10),
            v_flip: Bit(u16, 11),
            pal_bank: Bitfield(u16, 12, 4),
            raw: u16,
        };
    };

    const Affine = @compileError("TODO: Implement Affine Backgrounds");
};

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
