//! BattleMsg — ShowMsg_03 text from ROM (`btlgfx` BattleMsgPtrs).
//!
//! EN: segment `battle_msg` @ 0F/B000 (file 0x7B000), 59 relative ptrs + strings.
//! Decoding uses the same primary font map as `text.zig`.
const rom_mod = @import("../rom.zig");
const text = @import("../text.zig");

/// File offset of BattleMsgPtrs (EN).
pub const battle_msg_ptrs_file: usize = 0x7B000;
pub const battle_msg_count: u8 = 59;
/// LoROM bank base for absolute lowords in this segment (bank $0F → file 0x78000).
const bank_file_base: usize = 0x78000;

/// Well-known BattleMsg indices (EN text verified from ROM dump).
pub const MsgId = struct {
    pub const nothing_happened: u8 = 0;
    pub const not_enough_mp: u8 = 1;
    pub const strike_first: u8 = 2;
    pub const surprised: u8 = 3;
    pub const attacked_from_behind: u8 = 4;
    pub const ran_away: u8 = 5;
    pub const won: u8 = 6;
    pub const miss: u8 = 10;
    pub const failed: u8 = 17;
};

/// Load BattleMsg `id` into `buf` (decoded ASCII). Returns written slice.
pub fn load(r: *const rom_mod.Rom, id: u8, buf: []u8) []const u8 {
    if (id >= battle_msg_count or buf.len == 0) return buf[0..0];
    const pref = r.slice(battle_msg_ptrs_file + @as(usize, id) * 2, 2) catch return buf[0..0];
    const rel: u16 = @as(u16, pref[0]) | (@as(u16, pref[1]) << 8);
    const file_off = bank_file_base + @as(usize, rel & 0x7FFF);
    // Cap read; messages are short
    const raw = r.slice(file_off, @min(64, r.data.len -| file_off)) catch return buf[0..0];
    // Terminate at 0x00
    var end: usize = 0;
    while (end < raw.len and raw[end] != 0) : (end += 1) {}
    return text.decodeFixed(raw[0..end], buf);
}
