//! ExecAnimScript header decode — btlgfx/magic.asm @f6bc + btlgfx_data.asm.
//!
//! Full OAM frame loop residual; this module ports **header setup** only:
//!   script id → AnimScriptPtrs → first 2 header bytes
//!   byte0: high nibble → AnimFrameSizeTbl; low nibble → repeat count
//!   byte1: speed bits 3–4 → AnimSpeedTbl; bit7 disables one flag; low 3 bits mode
//!
//! 79 scripts (AnimScriptPtrs count). Used by MagicAnim_1c / DefaultMagicAnim.
const std = @import("std");
const rom_mod = @import("../rom.zig");

/// Number of AnimScript entries (btlgfx_data.asm make_ptr_tbl_rel AnimScript, 79).
pub const script_count: usize = 79;

/// AnimScriptPtrs @ LoROM $0F/D5E0 → file 0x7D5E0 (79 × u16 bank-relative).
pub const anim_script_ptrs_file: usize = 0x7D5E0;
/// Anim scripts live in bank $0F (same as pointer table).
pub const anim_script_bank: u8 = 0x0F;
/// AnimFrameSizeTbl ROM file 0x6FF3E (matches embed below).
pub const anim_frame_size_file: usize = 0x6FF3E;
/// AnimSpeedTbl ROM file 0x6FFD9.
pub const anim_speed_file: usize = 0x6FFD9;

/// AnimFrameSizeTbl @ff3e — 16 pairs (w,h) indexed by (byte0 & $F0) >> 3.
/// Decomp: `and #$f0 / lsr3 / tax` then load size_tbl[x], size_tbl[x+1].
pub const anim_frame_size_tbl: [32]u8 = .{
    0x01, 0x01, 0x03, 0x03, 0x02, 0x02, 0x05, 0x09, 0x0C, 0x09, 0x10, 0x09, 0x04, 0x04, 0x04, 0x09,
    0x03, 0x04, 0x0C, 0x01, 0x02, 0x03, 0x06, 0x09, 0x01, 0x02, 0x04, 0x09, 0x06, 0x09, 0x06, 0x06,
};

/// AnimSpeedTbl @ffd9 — mask for frame wait (`$f27e & speed`).
pub const anim_speed_tbl: [4]u8 = .{ 0x07, 0x03, 0x01, 0x00 };

pub const Header = struct {
    /// Frame size id 0..15 (high nibble of byte0).
    size_id: u8 = 0,
    /// Pixel size from AnimFrameSizeTbl (pair).
    size_w: u8 = 1,
    size_h: u8 = 1,
    /// Repeat count = (byte0 & $0F) + 1.
    repeat: u8 = 1,
    /// Speed table index 0..3 from byte1 bits 3–4.
    speed_id: u8 = 0,
    /// Wait mask from AnimSpeedTbl.
    speed_mask: u8 = 0x07,
    /// byte1 bit7: stz $f261 when set.
    flag_clear_f261: bool = false,
    /// byte1 low 3 bits → $f249.
    mode: u8 = 0,
    /// Host: frames to hold for one script pass ≈ (repeat) * (speed_mask+1) * 4 stand-in.
    host_wait_frames: u8 = 8,
};

/// Decode first two header bytes of an AnimScript (ExecAnimScript @f6ea–@f7a3 setup).
pub fn decodeHeader(byte0: u8, byte1: u8) Header {
    var h: Header = .{};
    // size id: (byte0 & $F0) >> 4  — ROM does and #$f0; lsr3 → even index into pair table
    // lsr3 of high nibble: e.g. $30 → $18? Wait:
    //   and #$f0  → $30
    //   lsr3      → $06  (index into word table as byte index)
    // So size_index = (byte0 & $F0) >> 3  (0,2,4,...,30)
    const size_idx: usize = @as(usize, (byte0 & 0xF0) >> 3);
    h.size_id = (byte0 & 0xF0) >> 4;
    if (size_idx + 1 < anim_frame_size_tbl.len) {
        h.size_w = anim_frame_size_tbl[size_idx];
        h.size_h = anim_frame_size_tbl[size_idx + 1];
    }
    h.repeat = (byte0 & 0x0F) +% 1;
    h.speed_id = (byte1 & 0x18) >> 3;
    if (h.speed_id < anim_speed_tbl.len) {
        h.speed_mask = anim_speed_tbl[h.speed_id];
    }
    h.flag_clear_f261 = (byte1 & 0x80) != 0;
    h.mode = byte1 & 0x07;
    // Host wait: each "frame" waits until ($f27e & mask)==0; mask 7 → every 8 fields, etc.
    // Approximate total fields: repeat * (speed_mask + 1) * 2, cap 255.
    const step: u16 = @as(u16, h.speed_mask) +% 1;
    var wait: u16 = @as(u16, h.repeat) *% step *% 2;
    if (wait < 4) wait = 4;
    if (wait > 255) wait = 255;
    h.host_wait_frames = @intCast(wait);
    return h;
}

/// Decode from script buffer (needs ≥2 bytes). Empty/short → default header.
pub fn decodeScript(script: []const u8) Header {
    if (script.len < 2) return .{};
    return decodeHeader(script[0], script[1]);
}

/// Valid script id for AnimScriptPtrs (0..78).
pub fn validScriptId(id: u8) bool {
    return id < script_count;
}

/// Load AnimScriptPtrs[id] → bank $0F address (CPU low 16).
pub fn scriptPtr(r: *const rom_mod.Rom, id: u8) ?u16 {
    if (!validScriptId(id)) return null;
    const off = anim_script_ptrs_file + @as(usize, id) * 2;
    const raw = r.slice(off, 2) catch return null;
    return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
}

/// File offset of AnimScript body for `id`.
pub fn scriptFileOffset(r: *const rom_mod.Rom, id: u8) ?usize {
    const p = scriptPtr(r, id) orelse return null;
    return rom_mod.Rom.loromOffset((@as(u24, anim_script_bank) << 16) | p);
}

/// Load first `n` bytes of AnimScript[id] into `out` (ExecAnimScript setup needs ≥2).
pub fn loadScriptBytes(r: *const rom_mod.Rom, id: u8, out: []u8) ?usize {
    const foff = scriptFileOffset(r, id) orelse return null;
    const n = out.len;
    const raw = r.slice(foff, n) catch return null;
    @memcpy(out[0..raw.len], raw);
    return raw.len;
}

/// Decode header for AnimScript id from ROM (DefaultMagicAnim path).
pub fn loadHeader(r: *const rom_mod.Rom, id: u8) ?Header {
    var buf: [2]u8 = undefined;
    _ = loadScriptBytes(r, id, &buf) orelse return null;
    return decodeHeader(buf[0], buf[1]);
}

/// Verify embed tables match ROM when present (parity guard).
pub fn tablesMatchRom(r: *const rom_mod.Rom) bool {
    const sz = r.slice(anim_frame_size_file, anim_frame_size_tbl.len) catch return false;
    if (!std.mem.eql(u8, sz, &anim_frame_size_tbl)) return false;
    const sp = r.slice(anim_speed_file, anim_speed_tbl.len) catch return false;
    return std.mem.eql(u8, sp, &anim_speed_tbl);
}

test "AnimFrameSizeTbl first pair 1x1" {
    try std.testing.expectEqual(@as(u8, 0x01), anim_frame_size_tbl[0]);
    try std.testing.expectEqual(@as(u8, 0x01), anim_frame_size_tbl[1]);
    try std.testing.expectEqual(@as(u8, 0x03), anim_frame_size_tbl[2]);
}

test "AnimSpeedTbl" {
    try std.testing.expectEqual(@as(u8, 0x07), anim_speed_tbl[0]);
    try std.testing.expectEqual(@as(u8, 0x03), anim_speed_tbl[1]);
    try std.testing.expectEqual(@as(u8, 0x01), anim_speed_tbl[2]);
    try std.testing.expectEqual(@as(u8, 0x00), anim_speed_tbl[3]);
}

test "decodeHeader size nibble and repeat" {
    // byte0 = $00 → size_id 0, size 1x1, repeat 1
    const a = decodeHeader(0x00, 0x00);
    try std.testing.expectEqual(@as(u8, 0), a.size_id);
    try std.testing.expectEqual(@as(u8, 1), a.size_w);
    try std.testing.expectEqual(@as(u8, 1), a.size_h);
    try std.testing.expectEqual(@as(u8, 1), a.repeat);
    try std.testing.expectEqual(@as(u8, 0x07), a.speed_mask);

    // byte0 = $13 → size_id 1, size 3x3, repeat 4
    const b = decodeHeader(0x13, 0x18); // speed_id = 3
    try std.testing.expectEqual(@as(u8, 1), b.size_id);
    try std.testing.expectEqual(@as(u8, 3), b.size_w);
    try std.testing.expectEqual(@as(u8, 3), b.size_h);
    try std.testing.expectEqual(@as(u8, 4), b.repeat);
    try std.testing.expectEqual(@as(u8, 3), b.speed_id);
    try std.testing.expectEqual(@as(u8, 0x00), b.speed_mask);

    // bit7 clear f261
    const c = decodeHeader(0x00, 0x80);
    try std.testing.expect(c.flag_clear_f261);
    try std.testing.expectEqual(@as(u8, 0), c.mode);
}

test "validScriptId 0..78" {
    try std.testing.expect(validScriptId(0));
    try std.testing.expect(validScriptId(78));
    try std.testing.expect(!validScriptId(79));
}

test "decodeScript short buffer default" {
    const h = decodeScript(&[_]u8{0x01});
    try std.testing.expectEqual(@as(u8, 1), h.repeat); // default
}

test "loadHeader script 0 from ROM" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    try std.testing.expect(tablesMatchRom(&r));
    const h = loadHeader(&r, 0) orelse return error.NoScript;
    // ROM script0 hdr 24 b0 → size_id 2, size 2x2, repeat 5, speed from $b0
    try std.testing.expectEqual(@as(u8, 2), h.size_id);
    try std.testing.expectEqual(@as(u8, 2), h.size_w);
    try std.testing.expectEqual(@as(u8, 2), h.size_h);
    try std.testing.expectEqual(@as(u8, 5), h.repeat); // ($24&$0f)+1
    try std.testing.expect(h.flag_clear_f261); // $b0 bit7
    const p = scriptPtr(&r, 0).?;
    try std.testing.expectEqual(@as(u16, 0xD681), p);
}

test "loadHeader invalid id null" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    try std.testing.expect(loadHeader(&r, 79) == null);
    try std.testing.expect(loadHeader(&r, 255) == null);
}
