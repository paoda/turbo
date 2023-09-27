const std = @import("std");

const assert = std.debug.assert;

/// Sign-Extends a `SrcT` value to a `DestT`.
///
/// Notes:
/// - `DestT` can be a signed or unsigned integer
/// - `value` is of type `anytype` and may be a signed / unsigned / comptime integer
///
/// Invariants:
/// - `SrcT` *must* be a signed Integer (the idea being: "why would we sign extend an unsigned value?")
/// - `SrcT` must have equal or less bits than DestT
/// - `SrcT` must have equal or less bits than ValT (`@TypeOf(value)`)
pub fn sext(comptime DestT: type, comptime SrcT: type, value: anytype) DestT {
    const ValT = @TypeOf(value);
    const dst_info = @typeInfo(DestT);
    const src_info = @typeInfo(SrcT);
    const val_info = @typeInfo(ValT);

    comptime {
        // DestT, SrcT and ValT are expected to be integers
        std.debug.assert(dst_info == .Int);
        std.debug.assert(src_info == .Int);
        std.debug.assert(val_info == .ComptimeInt or val_info == .Int);

        // sexting to a type smaller than SrcT isn't "extension" and therefore doesn't make sense
        // sexting also implies a signed value (we may remove this assumption later)
        std.debug.assert(src_info.Int.signedness == .signed);
        std.debug.assert(src_info.Int.bits <= dst_info.Int.bits);

        // ValT is allowed to have more bits than SrcT, we just truncate
        std.debug.assert(val_info == .ComptimeInt or src_info.Int.bits <= val_info.Int.bits);
    }

    // signed integers implement Arithmetic Right Shift
    const SignedSrcT = @Type(.{ .Int = .{ .signedness = .signed, .bits = src_info.Int.bits } });
    const SignedDestT = @Type(.{ .Int = .{ .signedness = .signed, .bits = dst_info.Int.bits } });
    const SignedValT = switch (val_info) {
        .Int => @Type(.{ .Int = .{ .signedness = .signed, .bits = val_info.Int.bits } }),
        .ComptimeInt => FittingInt(value),
        else => unreachable,
    };

    const signed_value: SignedSrcT = switch (val_info) {
        .Int => switch (val_info.Int.signedness) {
            .signed => @truncate(value),
            .unsigned => @truncate(@as(SignedValT, @bitCast(value))),
        },
        .ComptimeInt => @truncate(value),
        else => unreachable,
    };

    // maybe no shifts are needed at all?
    return @bitCast(@as(SignedDestT, signed_value));
}

test "sext" {
    const expect = std.testing.expectEqual;

    try expect(@as(u4, 0b1111), sext(u4, i2, 0b11));
    try expect(@as(u4, 0b0001), sext(u4, i2, 0b01));

    try expect(@as(u4, 0b1111), sext(u4, i2, 0b1111_1111));
    try expect(@as(u4, 0b0001), sext(u4, i2, 0b0000_0001));

    try expect(@as(i4, -1), sext(i4, i2, 0b11));
    try expect(@as(i4, 1), sext(i4, i2, 0b01));

    try expect(@as(i4, -1), sext(i4, i2, 0b1111_1111));
    try expect(@as(i4, 1), sext(i4, i2, 0b0000_0001));

    try expect(@as(u4, 0b1111), sext(u4, i2, @as(u2, 0b11)));
    try expect(@as(u4, 0b0001), sext(u4, i2, @as(u2, 0b01)));

    try expect(@as(u4, 0b1111), sext(u4, i2, @as(u8, 0b1111_1111)));
    try expect(@as(u4, 0b0001), sext(u4, i2, @as(u8, 0b0000_0001)));

    try expect(@as(i4, -1), sext(i4, i2, @as(i2, -1)));
    try expect(@as(i4, 1), sext(i4, i2, @as(i2, 1)));

    try expect(@as(i4, -1), sext(i4, i2, @as(i8, -1)));
    try expect(@as(i4, 1), sext(i4, i2, @as(i8, 1)));
}

fn FittingInt(comptime value: comptime_int) type {
    const bits = blk: {
        var i: comptime_int = 0;
        while (value >> i != 0) : (i += 1) {}

        break :blk i;
    };

    return @Type(.{ .Int = .{ .signedness = .signed, .bits = bits } });
}

test "FittingInt" {
    try std.testing.expect(FittingInt(0) == i0);
    try std.testing.expect(FittingInt(0b1) == i1);
    try std.testing.expect(FittingInt(0b1) == i1);
    try std.testing.expect(FittingInt(0b11) == i2);
    try std.testing.expect(FittingInt(0b101) == i3);
    try std.testing.expect(FittingInt(0b1010) == i4);
}
