const std = @import("std");

/// For use with withe tiniest ROM
pub const Header = extern struct {
    title: [12]u8,
    game_code: [4]u8,
    maker_code: [2]u8,
    unit_code: u8,
    encryption_seed_select: u8,
    device_capacity: u8,
    _: [7]u8 = [_]u8{0} ** 7,
    __: u8 = 0,
    nds_region: u8,
    version: u8,
    auto_start: u8,

    arm9_rom_offset: u32,
    arm9_entry_address: u32,
    arm9_ram_address: u32,
    arm9_size: u32,

    arm7_rom_offset: u32,
    arm7_entry_address: u32,
    arm7_ram_address: u32,
    arm7_size: u32,

    /// File Name Table Offset
    fnt_offset: u32,
    /// File Name Table Size
    fnt_size: u32,

    /// File Allocation Table Offset
    fat_offset: u32,
    // File Allocation Table Size
    fat_size: u32,

    /// File ARM9 Overlay Offset
    farm9_overlay_offset: u32,
    // File ARM9 Overlay Size
    farm9_overlay_size: u32,
    /// File ARM9 Overlay Offset
    farm7_overlay_offset: u32,
    // File ARM9 Overlay Size
    farm7_overlay_size: u32,

    /// Port 40001A4h setting for normal commands (usually 00586000h)
    gamecard_control_setting_normal: u32, // TODO: rename these fields
    /// Port 40001A4h setting for KEY1 commands   (usually 001808F8h)
    gamecard_control_setting_key1: u32,

    /// Icon / Title Offset
    icon_title_offset: u32,

    /// Secure Area Checksum
    secure_checksum: u16,
    /// Secure Area Delay
    secure_delay: u16,

    // TODO: Document
    arm9_auto_load_list: u32,
    arm7_auto_load_list: u32,
    secure_disable: u64 align(1),

    total_used: u32,
    header_size: u32,
    ___: u32 = 0, // TODO: may not be zero?
    ____: u64 align(1) = 0,

    rom_nand_end: u16,
    rw_nand_start: u16,
    _____: [0x18]u8 = [_]u8{0} ** 0x18,
    ______: [0x10]u8 = [_]u8{0} ** 0x10,

    logo: [0x9C]u8,
    logo_checksum: u16,

    /// Header Checksum
    checksum: u16,

    // note, we're missing some debug_ prefixed fields here
    // but we want the header struct to be 0x160 bytes so that
    // the smallest NDS rom's header can be read without any speicifc
    // workarounds
    // TODO: Determine if we ever will need those debug fields, and if so: Implement them

    comptime {
        std.debug.assert(@sizeOf(@This()) == 0x160);
    }
};
