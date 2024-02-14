const std = @import("std");

const Bitfield = @import("bitfield").Bitfield;
const Bit = @import("bitfield").Bit;
const System = @import("emu.zig").System;
const handleInterrupt = @import("emu.zig").handleInterrupt;

const log = std.log.scoped(.shared_io);

pub const Io = struct {
    /// Inter Process Communication FIFO
    ipc: Ipc = .{},

    wramcnt: WramCnt = .{ .raw = 0x00 },

    // Read Only
    input: Input = .{},
};

fn warn(comptime format: []const u8, args: anytype) u0 {
    log.warn(format, args);
    return 0;
}

/// Inter-Process Communication
const Ipc = struct {
    const Sync = IpcSync;
    const Control = IpcFifoCnt;

    _nds7: Impl = .{},
    _nds9: Impl = .{},

    // we need access to the CPUs to handle IPC IRQs
    arm7tdmi: ?*System.Arm7tdmi = null,
    arm946es: ?*System.Arm946es = null,

    // TODO: DS Cartridge I/O Ports

    const Impl = struct {
        /// IPC Synchronize
        /// Read/Write
        sync: Sync = .{ .raw = 0x0000_0000 },

        /// IPC Fifo Control
        /// Read/Write
        cnt: Control = .{ .raw = 0x0000_0101 },

        fifo: Fifo = Fifo{},

        /// Latch containing thel last read value from a FIFO
        last_read: ?u32 = null,
    };

    pub fn configure(self: *@This(), system: System) void {
        self.arm7tdmi = system.arm7tdmi;
        self.arm946es = system.arm946es;
    }

    /// IPCSYNC
    /// Read/Write
    pub fn setIpcSync(self: *@This(), comptime proc: System.Process, value: anytype) void {
        switch (proc) {
            .nds7 => {
                self._nds7.sync.raw = masks.ipcFifoSync(self._nds7.sync.raw, value);
                self._nds9.sync.raw = masks.mask(self._nds9.sync.raw, (self._nds7.sync.raw >> 8) & 0xF, 0xF);

                if (value >> 13 & 1 == 1 and self._nds9.sync.recv_irq.read()) {
                    const bus: *System.Bus9 = @ptrCast(@alignCast(self.arm946es.?.bus.ptr));

                    bus.io.irq.ipcsync.set();
                    handleInterrupt(.nds9, self.arm946es.?);
                }

                if (value >> 3 & 1 == 1) {
                    self._nds7.fifo.reset();

                    self._nds7.cnt.send_fifo_empty.set();
                    self._nds9.cnt.recv_fifo_empty.set();

                    self._nds7.cnt.send_fifo_full.unset();
                    self._nds9.cnt.recv_fifo_full.unset();
                }
            },
            .nds9 => {
                self._nds9.sync.raw = masks.ipcFifoSync(self._nds9.sync.raw, value);
                self._nds7.sync.raw = masks.mask(self._nds7.sync.raw, (self._nds9.sync.raw >> 8) & 0xF, 0xF);

                if (value >> 13 & 1 == 1 and self._nds7.sync.recv_irq.read()) {
                    const bus: *System.Bus7 = @ptrCast(@alignCast(self.arm7tdmi.?.bus.ptr));

                    bus.io.irq.ipcsync.set();
                    handleInterrupt(.nds7, self.arm7tdmi.?);
                }

                if (value >> 3 & 1 == 1) {
                    self._nds9.fifo.reset();

                    self._nds9.cnt.send_fifo_empty.set();
                    self._nds7.cnt.recv_fifo_empty.set();

                    self._nds9.cnt.send_fifo_full.unset();
                    self._nds7.cnt.recv_fifo_full.unset();
                }
            },
        }
    }

    /// IPCFIFOCNT
    /// Read/Write
    pub fn setIpcFifoCnt(self: *@This(), comptime proc: System.Process, value: anytype) void {
        switch (proc) {
            .nds7 => self._nds7.cnt.raw = masks.ipcFifoCnt(self._nds7.cnt.raw, value),
            .nds9 => self._nds9.cnt.raw = masks.ipcFifoCnt(self._nds9.cnt.raw, value),
        }
    }

    /// IPC Send FIFO
    /// Write-Only
    pub fn send(self: *@This(), comptime proc: System.Process, value: u32) void {
        switch (proc) {
            .nds7 => {
                if (!self._nds7.cnt.enable_fifos.read()) return;
                self._nds7.fifo.push(value) catch unreachable; // see early return above

                const not_empty_cache = !self._nds9.cnt.recv_fifo_empty.read();

                // update status bits
                self._nds7.cnt.send_fifo_empty.write(self._nds7.fifo._len() == 0);
                self._nds9.cnt.recv_fifo_empty.write(self._nds7.fifo._len() == 0);

                self._nds7.cnt.send_fifo_full.write(self._nds7.fifo._len() == 0x10);
                self._nds9.cnt.recv_fifo_full.write(self._nds7.fifo._len() == 0x10);

                const not_empty = !self._nds9.cnt.recv_fifo_empty.read();

                if (self._nds9.cnt.recv_fifo_irq_enable.read() and !not_empty_cache and not_empty) {
                    // NDS7 Send | NDS9 RECV (Handling Not Empty)

                    const bus: *System.Bus9 = @ptrCast(@alignCast(self.arm946es.?.bus.ptr));
                    bus.io.irq.ipc_recv_not_empty.set();

                    handleInterrupt(.nds9, self.arm946es.?);
                }
            },
            .nds9 => {
                if (!self._nds9.cnt.enable_fifos.read()) return;
                self._nds9.fifo.push(value) catch unreachable; // see early return above

                const not_empty_cache = !self._nds7.cnt.recv_fifo_empty.read();

                // update status bits
                self._nds9.cnt.send_fifo_empty.write(self._nds9.fifo._len() == 0);
                self._nds7.cnt.recv_fifo_empty.write(self._nds9.fifo._len() == 0);

                self._nds9.cnt.send_fifo_full.write(self._nds9.fifo._len() == 0x10);
                self._nds7.cnt.recv_fifo_full.write(self._nds9.fifo._len() == 0x10);

                const not_empty = !self._nds7.cnt.recv_fifo_empty.read();

                if (self._nds7.cnt.recv_fifo_irq_enable.read() and !not_empty_cache and not_empty) {
                    // NDS9 Send | NDS7 RECV (Handling Not Empty)

                    const bus: *System.Bus7 = @ptrCast(@alignCast(self.arm7tdmi.?.bus.ptr));
                    bus.io.irq.ipc_recv_not_empty.set();

                    handleInterrupt(.nds7, self.arm7tdmi.?);
                }
            },
        }
    }

    /// IPC Receive FIFO
    /// Read-Only
    pub fn recv(self: *@This(), comptime proc: System.Process) u32 {
        switch (proc) {
            .nds7 => {
                const enabled = self._nds7.cnt.enable_fifos.read();
                const val_opt = if (enabled) self._nds9.fifo.pop() else self._nds9.fifo.peek();

                const value = if (val_opt) |val| blk: {
                    self._nds9.last_read = val;
                    break :blk val;
                } else blk: {
                    self._nds7.cnt.fifo_error.set();
                    break :blk self._nds7.last_read orelse 0x0000_0000;
                };

                const empty_cache = self._nds9.cnt.send_fifo_empty.read();

                // update status bits
                self._nds7.cnt.recv_fifo_empty.write(self._nds9.fifo._len() == 0);
                self._nds9.cnt.send_fifo_empty.write(self._nds9.fifo._len() == 0);

                self._nds7.cnt.recv_fifo_full.write(self._nds9.fifo._len() == 0x10);
                self._nds9.cnt.send_fifo_full.write(self._nds9.fifo._len() == 0x10);

                const empty = self._nds9.cnt.send_fifo_empty.read();

                if (self._nds9.cnt.send_fifo_irq_enable.read() and (!empty_cache and empty)) {
                    const bus: *System.Bus9 = @ptrCast(@alignCast(self.arm946es.?.bus.ptr));
                    bus.io.irq.ipc_send_empty.set();

                    handleInterrupt(.nds9, self.arm946es.?);
                }

                return value;
            },
            .nds9 => {
                const enabled = self._nds9.cnt.enable_fifos.read();
                const val_opt = if (enabled) self._nds7.fifo.pop() else self._nds7.fifo.peek();

                const value = if (val_opt) |val| blk: {
                    self._nds7.last_read = val;
                    break :blk val;
                } else blk: {
                    self._nds9.cnt.fifo_error.set();
                    break :blk self._nds7.last_read orelse 0x0000_0000;
                };

                const empty_cache = self._nds7.cnt.send_fifo_empty.read();

                // update status bits
                self._nds9.cnt.recv_fifo_empty.write(self._nds7.fifo._len() == 0);
                self._nds7.cnt.send_fifo_empty.write(self._nds7.fifo._len() == 0);

                self._nds9.cnt.recv_fifo_full.write(self._nds7.fifo._len() == 0x10);
                self._nds7.cnt.send_fifo_full.write(self._nds7.fifo._len() == 0x10);

                const empty = self._nds7.cnt.send_fifo_empty.read();

                if (self._nds7.cnt.send_fifo_irq_enable.read() and (!empty_cache and empty)) {
                    const bus: *System.Bus7 = @ptrCast(@alignCast(self.arm7tdmi.?.bus.ptr));
                    bus.io.irq.ipc_send_empty.set();

                    handleInterrupt(.nds7, self.arm7tdmi.?);
                }

                return value;
            },
        }
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

pub const WramCnt = extern union {
    mode: Bitfield(u8, 0, 2),
    raw: u8,
};

pub const masks = struct {
    const Bus9 = @import("nds9/Bus.zig");
    const Bus7 = @import("nds7/Bus.zig");

    inline fn ipcFifoSync(sync: u32, value: anytype) u32 {
        const _mask: u32 = 0x6F00;
        return (@as(u32, value) & _mask) | (sync & ~_mask);
    }

    inline fn ipcFifoCnt(cnt: u32, value: anytype) u32 {
        const _mask: u32 = 0xC40C;
        const err_mask: u32 = 0x4000; // bit 14

        const err_bit = (cnt & err_mask) & ~(value & err_mask);

        const without_err = (@as(u32, value) & _mask) | (cnt & ~_mask);
        return (without_err & ~err_mask) | err_bit;
    }

    /// General Mask helper
    pub inline fn mask(original: anytype, value: @TypeOf(original), _mask: @TypeOf(original)) @TypeOf(original) {
        return (value & _mask) | (original & ~_mask);
    }
};

// FIXME: bitfields depends on NDS9 / NDS7
pub const IntEnable = extern union {
    vblank: Bit(u32, 0),
    hblank: Bit(u32, 1),
    coincidence: Bit(u32, 2),

    dma0: Bit(u32, 8),
    dma1: Bit(u32, 9),
    dma2: Bit(u32, 10),
    dma3: Bit(u32, 11),

    ipcsync: Bit(u32, 16),
    ipc_send_empty: Bit(u32, 17),
    ipc_recv_not_empty: Bit(u32, 18),
    raw: u32,
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

/// Read Only
/// 0 = Pressed, 1 = Released
pub const KeyInput = extern union {
    a: Bit(u16, 0),
    b: Bit(u16, 1),
    select: Bit(u16, 2),
    start: Bit(u16, 3),
    right: Bit(u16, 4),
    left: Bit(u16, 5),
    up: Bit(u16, 6),
    down: Bit(u16, 7),
    shoulder_r: Bit(u16, 8),
    shoulder_l: Bit(u16, 9),
    raw: u16,
};

pub const ExtKeyIn = extern union {
    x: Bit(u16, 0),
    y: Bit(u16, 1),
    debug: Bit(u16, 3),
    stylus: Bit(u16, 6),
    hinge: Bit(u16, 7),
    raw: u16,
};

const Input = struct {
    const AtomicOrder = std.builtin.AtomicOrder;
    const AtomicRmwOp = std.builtin.AtomicRmwOp;

    inner: u32 = 0x007F_03FF,

    pub inline fn keyinput(self: *const Input) KeyInput {
        const value = @atomicLoad(u32, &self.inner, .Monotonic);
        return .{ .raw = @truncate(value) };
    }

    pub inline fn set_keyinput(self: *Input, comptime op: AtomicRmwOp, input: KeyInput) void {
        const msked = switch (op) {
            .And => 0xFFFF_FFFF & @as(u32, input.raw),
            .Or => 0x0000_0000 | @as(u32, input.raw),
            else => @compileError("not supported"),
        };

        _ = @atomicRmw(u32, &self.inner, op, msked, .Monotonic);
    }

    pub inline fn extkeyin(self: *const Input) ExtKeyIn {
        const value = @atomicLoad(u32, &self.inner, .Monotonic);
        const shifted: u16 = @truncate(value >> 16);

        return .{ .raw = shifted | 0b00110100 }; // bits 2, 4, 5 are always set
    }

    pub inline fn set_extkeyin(self: *Input, comptime op: AtomicRmwOp, input: ExtKeyIn) void {
        const msked = switch (op) {
            .And => 0xFFFF_FFFF & (@as(u32, ~input.raw) << 16),
            .Or => 0x0000_0000 | (@as(u32, input.raw) << 16),
            else => @compileError("not supported"),
        };

        _ = @atomicRmw(u32, &self.inner, op, msked, .Monotonic);
    }

    pub inline fn set(self: *Input, comptime op: AtomicRmwOp, value: u32) void {
        _ = @atomicRmw(u32, &self.inner, op, value, .Monotonic);
    }
};
