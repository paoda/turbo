const std = @import("std");

const log = std.log.scoped(.cp15);

const panic_on_unimplemented: bool = false;

control: u32 = 0x0005_2078,
dtcm_size_base: u32 = 0x0300_000A,
itcm_size_base: u32 = 0x0000_0020,

wait_for_interrupt: bool = false,

// Protection Unit
// cache_bits_data_unified: u32 = 0x0000_0000,
// cache_write_bufability: u32 = 0x0000_0000, // For Data Protection Regions
// cache_bits_instr: u32 = 0x0000_0000,

/// Used in ARMv5TE MRC
pub fn read(self: *const @This(), op1: u3, cn: u4, cm: u4, op2: u3) u32 {
    return switch (addr(op1, cn, cm, op2)) {
        // c0, c0, ?
        0b000_0000_0000_000 => 0x4105_9461, // Main ID Register
        0b000_0000_0000_001 => 0x0F0D_2112, // Cache Type Register
        0b000_0000_0000_010 => 0x00140180, // TCM Size Register (ICTM is 0x8000 bytes, DTCM is 0x4000 bytes)
        0b000_0000_0000_011...0b000_0000_0000_111 => 0x4105_9461, // Unused, return Main ID Register

        0b000_0001_0000_000 => self.control, // Control Register

        // 0b000_0010_0000_000 => return self.cache_bits_data_unified & ~@as(u32, 0xFFFF_FF00),
        // 0b000_0010_0000_001 => return self.cache_bits_instr & ~@as(u32, 0xFFFF_FF00),
        // 0b000_0011_0000_000 => return self.cache_write_bufability & ~@as(u32, 0xFFFF_FF00),
        0b000_1001_0001_000 => return self.dtcm_size_base, // Data TCM Size / Base
        0b000_1001_0001_001 => return self.itcm_size_base, // Instruction TCM Size / Base
        else => panic("TODO: implement read from register {}, c{}, c{}, {}", .{ op1, cn, cm, op2 }),
    };
}

// Used in ARMv5TE MCR
pub fn write(self: *@This(), op1: u3, cn: u4, cm: u4, op2: u3, value: u32) void {
    switch (addr(op1, cn, cm, op2)) {
        0b000_0001_0000_000 => { // Control Register

            const zeroes: u32 = 0b11111111_11110000_00001111_00000010; // every bit except one_mask + 0, 2, 7, 12..19 are zero
            const ones: u32 = 0b00000000_00000000_00000000_01111000; // bits 3..6 are always set

            self.control = (value & ~zeroes) | ones;
        },

        0b000_0010_0000_000 => log.err("TODO: write to PU cachability bits (data/unified region)", .{}),
        0b000_0010_0000_001 => log.err("TODO: write to PU cachability bits (instruction region)", .{}),
        0b000_0011_0000_000 => log.err("TODO: write to PU cache write-bufferability bits (data protection region)", .{}),

        0b000_0101_0000_000 => log.err("TODO: write to access permission protection region (data/unified)", .{}),
        0b000_0101_0000_001 => log.err("TODO: write to access permission protection region (insruction)", .{}),
        0b000_0101_0000_010 => log.err("TODO: write to extended access permission protection region (data/unified)", .{}),
        0b000_0101_0000_011 => log.err("TODO: write to extended access permission protection region (insruction)", .{}),

        0b000_0110_0000_000,
        0b000_0110_0001_000,
        0b000_0110_0010_000,
        0b000_0110_0011_000,
        0b000_0110_0100_000,
        0b000_0110_0101_000,
        0b000_0110_0110_000,
        0b000_0110_0111_000,
        => log.err("TODO: write to PU data/unified region #{}", .{cm}),

        0b000_0110_0000_001,
        0b000_0110_0001_001,
        0b000_0110_0010_001,
        0b000_0110_0011_001,
        0b000_0110_0100_001,
        0b000_0110_0101_001,
        0b000_0110_0110_001,
        0b000_0110_0111_001,
        => log.err("TODO: write to PU instruction region #{}", .{cm}),

        0b000_0111_0000_100 => self.wait_for_interrupt = true, // NDS9 Halt
        0b000_0111_0101_000 => log.err("TODO: invalidate instruction cache", .{}),
        0b000_0111_0110_000 => log.err("TODO: invalidate data cache", .{}),
        0b000_0111_1010_100 => log.err("TODO: drain write buffer", .{}),

        0b000_1001_0001_000 => { // Data TCM Size / Base
            const zeroes: u32 = 0b00000000_00000000_00001111_11000001;

            self.dtcm_size_base = value & ~zeroes;

            // const size_shamt: u5 = blk: {
            //     const size = self.dtcm_size_base >> 1 & 0x1F;

            //     if (size < 3) break :blk 3;
            //     if (size > 23) break :blk 23;

            //     break :blk @intCast(size);
            // };

            // log.debug("DTCM Virtual Size: {}B", .{@as(u32, 0x200) << size_shamt});
            // log.debug("DTCM Region Base: 0x{X:0>8}", .{self.dtcm_size_base & 0xFFFF_F000});
        },
        0b000_1001_0001_001 => { // Instruction TCM Size / Base
            const zeroes: u32 = 0b00000000_00000000_00001111_11000001;
            const itcm_specific: u32 = 0b11111111_11111111_11110000_00000000;

            self.itcm_size_base = value & ~(zeroes | itcm_specific);

            // const size_shamt: u5 = blk: {
            //     const size = self.dtcm_size_base >> 1 & 0x1F;

            //     if (size < 3) break :blk 3;
            //     if (size > 23) break :blk 23;

            //     break :blk @intCast(size);
            // };

            // log.debug("ICTM Virtual Size: {}B", .{@as(u32, 0x200) << size_shamt});
            // log.debug("ICTM Region Base: 0x{X:0>8}", .{0x0000_0000});
        },

        else => _ = panic("TODO: implement write to register {}, c{}, c{}, {}", .{ op1, cn, cm, op2 }),
    }
}

fn addr(op1: u3, cn: u4, cm: u4, op2: u3) u14 {
    // 111nnnnmmmm222
    // zig fmt: off
    return @as(u14, op1) << 1
        | @as(u14, cn) << 7 
        | @as(u14, cm) << 3  
        | @as(u14, op2) << 0;
    // zig fmt: on
}

pub fn reset(self: *@This()) void {
    _ = self;
    @panic("TODO: implement ability to reinit coprocessor");
}

fn panic(comptime format: []const u8, args: anytype) u32 {
    log.err(format, args);
    if (panic_on_unimplemented) @panic("cp15 invariant broken");

    return 0;
}
