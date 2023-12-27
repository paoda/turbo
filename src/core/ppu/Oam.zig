const KiB = 0x400;

buf: [2 * KiB]u8,

pub fn init(self: *@This()) void {
    @memset(self.buf[0..], 0);
}
