//! Final Fantasy II (US) / FF4 English text encoding.
//!
//! Primary font indices (names, battle commands, most menus):
//!   0x42..=0x5B  A-Z
//!   0x5C..=0x75  a-z
//!   0x80..=0x89  0-9  (HexToDec / DrawDmgNumerals / HP numbers)
//!   0xC0..        punctuation (' . - / ! ? % / : ,)
//!   0xFF         padding / space (trailing pad stripped)
//!   0x40         magic-type marker (rendered as *)
//!
//! Unknown bytes become \xNN placeholders when decoding for display.
const std = @import("std");

pub fn decodeByte(b: u8) ?u8 {
    return switch (b) {
        0x42...0x5B => 'A' + (b - 0x42),
        0x5C...0x75 => 'a' + (b - 0x5C),
        0x80...0x89 => '0' + (b - 0x80),
        // Small digits / alternate range used sparingly
        0x76...0x7F => '0' + (b - 0x76),
        0xC0 => '\'',
        0xC1 => '.',
        0xC2 => '-',
        0xC3, 0xC7 => '/',
        0xC4 => '!',
        0xC5 => '?',
        0xC6 => '%',
        0xC8 => ':',
        0xC9 => ',',
        0xFF => ' ',
        0x40 => '*',
        0x00 => 0, // empty / terminator-ish in some tables
        else => null,
    };
}

/// Decode a fixed-width name field into `buf`. Returns the written slice (trimmed).
pub fn decodeFixed(raw: []const u8, buf: []u8) []const u8 {
    var out_i: usize = 0;
    for (raw) |b| {
        if (out_i >= buf.len) break;
        if (b == 0x00) break;
        if (decodeByte(b)) |ch| {
            if (ch == 0) break;
            buf[out_i] = ch;
            out_i += 1;
        } else {
            // Keep a printable placeholder for unknown tiles
            if (out_i + 4 <= buf.len) {
                const written = std.fmt.bufPrint(buf[out_i..], "\\x{X:0>2}", .{b}) catch break;
                out_i += written.len;
            }
        }
    }
    // Trim trailing spaces from 0xFF padding
    while (out_i > 0 and buf[out_i - 1] == ' ') : (out_i -= 1) {}
    return buf[0..out_i];
}

/// CharacterName ROM table @ 0F/A710 (file 0x7A710) — 14 × 6 bytes.
/// Copied to WRAM `$1500` at New Game (`_01979b` / CharName mvn).
pub const char_name_rom: usize = 0x7A710;
pub const char_name_stride: usize = 6;
pub const char_name_count: usize = 14;

/// TextCmd_04 / DrawCharName name-slot → decoded ASCII into `buf`.
/// `slot` is the byte after `$04` (index into CharacterName / `$1500`), not party id.
pub fn decodeCharNameSlot(rom_data: []const u8, slot: u8, buf: []u8) []const u8 {
    if (slot >= char_name_count) return buf[0..0];
    const off = char_name_rom + @as(usize, slot) * char_name_stride;
    if (off + char_name_stride > rom_data.len) return buf[0..0];
    return decodeFixed(rom_data[off..][0..char_name_stride], buf);
}

/// Decode, skipping a leading icon byte (item names: claw/rod/sword tile id).
pub fn decodeItemName(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len == 0) return buf[0..0];
    // Empty item slot is all 0xFF
    var all_ff = true;
    for (raw) |b| {
        if (b != 0xFF) {
            all_ff = false;
            break;
        }
    }
    if (all_ff) return buf[0..0];

    // First byte is often a weapon/armor icon tile (0x29..0x2E etc.)
    const start: usize = if (raw[0] < 0x40) 1 else 0;
    return decodeFixed(raw[start..], buf);
}

test "decode Cecil and Fight" {
    var buf: [32]u8 = undefined;
    const cecil = decodeFixed(&[_]u8{ 0x44, 0x60, 0x5E, 0x64, 0x67, 0xFF }, &buf);
    try std.testing.expectEqualStrings("Cecil", cecil);

    const fight = decodeFixed(&[_]u8{ 0x47, 0x64, 0x62, 0x63, 0x6F }, &buf);
    try std.testing.expectEqualStrings("Fight", fight);

    const imp = decodeFixed(&[_]u8{ 0x4A, 0x68, 0x6B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, &buf);
    try std.testing.expectEqualStrings("Imp", imp);
}

test "char name slot table constants" {
    try std.testing.expectEqual(@as(usize, 0x7A710), char_name_rom);
    try std.testing.expectEqual(@as(usize, 6), char_name_stride);
    try std.testing.expectEqual(@as(usize, 14), char_name_count);
    // Empty ROM → empty name (no panic)
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), decodeCharNameSlot(&.{}, 0, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), decodeCharNameSlot(&.{}, 99, &buf).len);
}
