//! BattleDlg — in-battle dialogue (btlgfx GfxScriptCmd $F1/$F2).
//!
//! Ptrs @ $0E/F200 (file 0x77200), relative to $0E0000, 186 strings.
const rom_mod = @import("../rom.zig");
const text_mod = @import("../text.zig");

pub const battle_dlg_ptrs_file: usize = 0x77200;
pub const battle_dlg_count: u16 = 186;
/// Relative pointer base (SNES $0E0000).
const ptr_base_cpu: u24 = 0x0E0000;

/// Decode BattleDlg[id] into `buf`. Returns written slice.
pub fn load(r: *const rom_mod.Rom, id: u8, buf: []u8) []const u8 {
    if (id >= battle_dlg_count or buf.len == 0) return buf[0..0];
    const poff = battle_dlg_ptrs_file + @as(usize, id) * 2;
    const rel = r.readU16Le(poff) catch return buf[0..0];
    const cpu: u24 = ptr_base_cpu +% rel;
    const fo = rom_mod.Rom.loromOffset(cpu);
    // Read up to 128 bytes (btlgfx copies $80 into buffer).
    const raw = r.slice(fo, 128) catch return buf[0..0];
    var len: usize = 0;
    while (len < raw.len and raw[len] != 0) : (len += 1) {}
    return text_mod.decodeFixed(raw[0..len], buf);
}
