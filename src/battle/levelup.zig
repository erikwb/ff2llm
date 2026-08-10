//! LevelUp / LevelUpHPMP — battle/win.asm @f02e / @f0cd.
//!
//! LevelUpProp 5 bytes per level (LevelUpPropPtrs @ 0F/B500):
//!   [0] stat gain flags (bits shift into str/agi/vit/wis/will)
//!   [1] HP gain base (LevelUpHPMP)
//!   [2] MP gain bits (low 5) + exp high nibble packing
//!   [3..4] exp threshold low 16 (with [2] high bits → 24-bit needed exp)
//!
//! win.asm @ef6a: needed = bytes[3] | bytes[4]<<8 | (bytes[2]>>5)<<16
//! compared against accumulated exp ($1037).
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const state_mod = @import("../game/state.zig");

pub const LevelResult = struct {
    leveled: bool = false,
    new_level: u8 = 0,
    hp_gain: u16 = 0,
    mp_gain: u16 = 0,
};

/// Exp required to advance from `level` → level+1 for character id (0-based slot in LevelUpPropPtrs).
pub fn expNeeded(r: *const rom_mod.Rom, char_id: u8, level: u8) u32 {
    if (level >= 99 or level < 1) return 0xFFFFFFFF;
    const rec = loadProp(r, char_id, level) orelse return 0xFFFFFFFF;
    // win.asm: $289f/$28a0 + ($289e >> 5)
    const lo: u32 = rec[3];
    const mid: u32 = rec[4];
    const hi: u32 = rec[2] >> 5;
    return lo | (mid << 8) | (hi << 16);
}

fn loadProp(r: *const rom_mod.Rom, char_id: u8, level: u8) ?[5]u8 {
    // LevelUpPropPtrs: 20 entries × 2, CPU bank $0F
    const ptrs = offsets.en.level_up_ptrs;
    const cid = @min(char_id, 19);
    const pref = r.slice(ptrs + @as(usize, cid) * 2, 2) catch return null;
    const cpu_ptr: u32 = @as(u32, pref[0]) | (@as(u32, pref[1]) << 8);
    // LoROM bank 0F: file = ((bank&0x7F)<<15) | (addr&0x7FFF)
    const cpu: u24 = @intCast(0x0F0000 | (cpu_ptr & 0xFFFF));
    const base: usize = rom_mod.Rom.loromOffset(cpu);
    const lv: usize = if (level < 1) 0 else level - 1;
    const off = base + lv * 5;
    const raw = r.slice(off, 5) catch return null;
    var out: [5]u8 = undefined;
    @memcpy(&out, raw);
    return out;
}

/// Apply one level-up if exp is enough. May loop for multi-level (caller loop).
pub fn tryLevelUp(
    r: *const rom_mod.Rom,
    m: *state_mod.PartyMember,
    rng_byte: u8,
) LevelResult {
    if (m.level >= 99 or !m.present) return .{};
    const need = expNeeded(r, m.id, m.level);
    if (m.exp < need) return .{};

    const rec = loadProp(r, m.id, m.level) orelse return .{};
    var out: LevelResult = .{ .leveled = true, .new_level = m.level + 1 };

    // Stat gains (LevelUp @f043): amount = byte0 & 7; flags = bits 7..3 via ASL×5
    const gain_amt: u8 = rec[0] & 7;
    const stats = [_]*u8{ &m.strength, &m.agility, &m.vitality, &m.wisdom, &m.will };
    var bits = rec[0];
    for (stats) |st| {
        const apply = (bits & 0x80) != 0;
        bits <<= 1;
        if (!apply) continue;
        if (gain_amt == 7) {
            if (st.* > 1) st.* -= 1;
        } else {
            const n = st.* +% gain_amt;
            st.* = if (n > 99) 99 else n;
        }
    }

    // HP: rec[1] base; LevelUpHPMP adds rand(0..base/8)+base, cap 9999
    const hp_base = rec[1];
    const hp_r = rng_byte % (@max(1, hp_base / 8) + 1);
    var hp_add: u16 = @as(u16, hp_base) +% hp_r;
    if (m.max_hp +% hp_add > 9999) hp_add = 9999 -| m.max_hp;
    m.max_hp +%= hp_add;
    m.hp +%= hp_add;
    out.hp_gain = hp_add;

    // MP: rec[2] & 0x1f base; cap 999
    const mp_base = rec[2] & 0x1F;
    const mp_r = (rng_byte ^ 0x5A) % (@max(1, mp_base / 8) + 1);
    var mp_add: u16 = @as(u16, mp_base) +% mp_r;
    if (m.max_mp +% mp_add > 999) mp_add = 999 -| m.max_mp;
    m.max_mp +%= mp_add;
    m.mp +%= mp_add;
    out.mp_gain = mp_add;

    m.level +%= 1;
    out.new_level = m.level;
    return out;
}

/// After battle: grant exp and level until short.
pub fn grantExpAndLevel(
    r: *const rom_mod.Rom,
    m: *state_mod.PartyMember,
    exp: u32,
    rng_byte: u8,
) u8 {
    if (!m.present or m.hp == 0) return 0;
    m.exp +%= exp;
    var levels: u8 = 0;
    var rb = rng_byte;
    while (levels < 10) {
        const res = tryLevelUp(r, m, rb);
        if (!res.leveled) break;
        levels += 1;
        rb +%= 17;
    }
    return levels;
}
