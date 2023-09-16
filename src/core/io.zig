const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;

const log = std.log.scoped(.shared_io);

pub const Io = struct {
    /// Interrupt Master Enable
    /// Read/Write
    ime: bool = false,

    /// Interrupt Enable
    /// Read/Write
    ///
    /// Caller must cast the `u32` to either `nds7.IntEnable` or `nds9.IntEnable`
    ie: u32 = 0x0000_0000,

    /// IF - Interrupt Request
    /// Read/Write
    ///
    /// Caller must cast the `u32` to either `nds7.IntRequest` or `nds9.IntRequest`
    irq: u32 = 0x0000_0000,

    /// Inter Process Communication FIFO
    ipc_fifo: IpcFifo = .{},

    /// Post Boot Flag
    /// Read/Write
    ///
    /// Caller must cast the `u8` to either `nds7.PostFlg` or `nds9.PostFlg`
    post_flg: u8 = @intFromEnum(nds7.PostFlag.in_progress),

    // TODO: DS Cartridge I/O Ports
};

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}

// TODO: Please Rename
// TODO: Figure out a way to apply masks while calling valueAtAddressOffset
// TODO: These aren't optimized well. Can we improve that?
pub inline fn valueAtAddressOffset(comptime T: type, address: u32, value: T) u8 {
    const L2I = std.math.Log2Int(T);

    return @truncate(switch (T) {
        u16 => value >> @as(L2I, @truncate((address & 1) << 3)),
        u32 => value >> @as(L2I, @truncate((address & 3) << 3)),
        else => @compileError("unsupported for " ++ @typeName(T) ++ "values"),
    });
}

fn WriteOption(comptime T: type) type {
    return struct { mask: ?T = null };
}

// TODO: also please rename
// TODO: Figure out a way to apply masks while calling writeToAddressOffset
// TODO: These aren't optimized well. Can we improve that?
pub inline fn writeToAddressOffset(
    register: anytype,
    address: u32,
    value: anytype,
    // mask: WriteOption(@typeInfo(@TypeOf(register)).Pointer.child),
) void {
    const Ptr = @TypeOf(register);
    const ChildT = @typeInfo(Ptr).Pointer.child;
    const ValueT = @TypeOf(value);

    const left = register.*;

    register.* = switch (ChildT) {
        u32 => switch (ValueT) {
            u16 => blk: {
                // TODO: This probably gets deleted
                const offset: u1 = @truncate(address >> 1);

                break :blk switch (offset) {
                    0b0 => (left & 0xFFFF_0000) | value,
                    0b1 => (left & 0x0000_FFFF) | @as(u32, value) << 16,
                };
            },
            u8 => blk: {
                // TODO: Remove branching
                const offset: u2 = @truncate(address);

                break :blk switch (offset) {
                    0b00 => (left & 0xFFFF_FF00) | value,
                    0b01 => (left & 0xFFFF_00FF) | @as(u32, value) << 8,
                    0b10 => (left & 0xFF00_FFFF) | @as(u32, value) << 16,
                    0b11 => (left & 0x00FF_FFFF) | @as(u32, value) << 24,
                };
            },
            else => @compileError("for " ++ @typeName(Ptr) ++ ", T must be u16 or u8"),
        },
        u16 => blk: {
            if (ValueT != u8) @compileError("for " ++ @typeName(Ptr) ++ ", T must be u8");

            const shamt = @as(u4, @truncate(address & 1)) << 3;
            const mask: u16 = 0xFF00 >> shamt;
            const value_shifted = @as(u16, value) << shamt;

            break :blk (left & mask) | value_shifted;
        },
        else => @compileError("unsupported for " ++ @typeName(Ptr) ++ " values"),
    };
}

const IpcFifo = struct {
    const Sync = IpcSync;
    const Control = IpcFifoCnt;

    /// IPC Synchronize
    /// Read/Write
    sync: Sync = .{ .raw = 0x0000_0000 },

    /// IPC Fifo Control
    /// Read/Write
    cnt: Control = .{ .raw = 0x0000_0000 },

    fifo: [2]Fifo = .{ Fifo{}, Fifo{} },

    const Source = enum { arm7, arm9 };

    /// IPC Send FIFO
    /// Write-Only
    pub fn send(self: *@This(), comptime src: Source, value: u32) !void {
        const idx = switch (src) {
            .arm7 => 0,
            .arm9 => 1,
        };

        if (!self.cnt.enable_fifos.read()) return;

        try self.fifo[idx].push(value);
    }

    /// IPC Receive FIFO
    /// Read-Only
    pub fn recv(self: *@This(), comptime src: Source) u32 {
        const idx = switch (src) {
            .arm7 => 1, // switched around on purpose
            .arm9 => 0,
        };

        const enabled = self.cnt.enable_fifos.read();
        const val_opt = if (enabled) self.fifo[idx].pop() else self.fifo[idx].peek();

        return val_opt orelse blk: {
            self.cnt.send_fifo_empty.set();

            break :blk 0x0000_0000;
        };
    }
};

const IpcSync = extern union {
    /// Data input to IPCSYNC Bit 8->11 of remote CPU
    /// Read-Only
    data_input: Bitfield(u32, 0, 4),

    /// Data output to IPCSYNC Bit 0->3 of remote CPU
    /// Read/Write
    data_output: Bitfield(u32, 8, 4),

    /// Send IRQ to remote CPU
    /// Write-Only
    send_irq: Bit(u32, 13),

    /// Enable IRQ from remote CPU
    /// Read/Write
    recv_irq: Bit(u32, 14),

    raw: u32,
};

const IpcFifoCnt = extern union {
    /// Read-Only
    send_fifo_empty: Bit(u32, 0),
    /// Read-Only
    send_fifo_full: Bit(u32, 1),
    /// Read/Write
    send_fifo_irq_enable: Bit(u32, 2),
    /// Write-Only
    send_fifo_clear: Bit(u32, 3),

    /// Read-Only
    recv_fifo_empty: Bit(u32, 8),
    /// Read-Only
    recv_fifo_full: Bit(u32, 9),

    /// IRQ for when the Receive FIFO is **not empty**
    /// Read/Write
    recv_fifo_irq_enable: Bit(u32, 10),

    /// Error, recv FIFO empty or send FIFO full
    /// Read/Write
    fifo_error: Bit(u32, 14),
    /// Read/Write
    enable_fifos: Bit(u32, 15),

    raw: u32,
};

pub const nds7 = struct {
    pub const IntEnable = extern union {
        raw: u32,
    };

    pub const IntRequest = IntEnable;
    pub const PostFlag = enum(u8) { in_progress = 0, completed };
};

pub const nds9 = struct {
    pub const IntEnable = extern union {
        raw: u32,
    };

    pub const IntRequest = IntEnable;

    pub const PostFlag = enum(u8) { in_progress = 0, completed };
};

const Fifo = struct {
    const Index = u8;
    const Error = error{full};
    const len = 0x10;

    read_idx: Index = 0,
    write_idx: Index = 0,

    buf: [len]u32 = [_]u32{undefined} ** len,

    comptime {
        const max_capacity = (@as(Index, 1) << @typeInfo(Index).Int.bits - 1) - 1; // half the range of index type

        std.debug.assert(std.math.isPowerOfTwo(len));
        std.debug.assert(len <= max_capacity);
    }

    pub fn reset(self: *@This()) void {
        self.read_idx = 0;
        self.write_idx = 0;
    }

    pub fn push(self: *@This(), value: u32) Error!void {
        if (self.isFull()) return Error.full;
        defer self.write_idx += 1;

        self.buf[self.mask(self.write_idx)] = value;
    }

    pub fn pop(self: *@This()) ?u32 {
        if (self.isEmpty()) return null;
        defer self.read_idx += 1;

        return self.buf[self.mask(self.read_idx)];
    }

    pub fn peek(self: *const @This()) ?u32 {
        if (self.isEmpty()) return null;

        return self.buf[self.mask(self.read_idx)];
    }

    fn _len(self: *const @This()) Index {
        return self.write_idx - self.read_idx;
    }

    fn isFull(self: *const @This()) bool {
        return self._len() == self.buf.len;
    }

    fn isEmpty(self: *const @This()) bool {
        return self.read_idx == self.write_idx;
    }

    inline fn mask(self: *const @This(), idx: Index) Index {
        const _mask: Index = @intCast(self.buf.len - 1);

        return idx & _mask;
    }
};
