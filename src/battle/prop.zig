//! BattleProp + MonsterPos load — battle.asm InitBattle (@80ec–@81f6).
//!
//! Table: 512 × 8 bytes @ 0E/8000 (offsets.en.battle_properties).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");

/// 8-byte formation record (mirrors $299c..$29a3 after load).
pub const BattleProp = struct {
    flags: u8,
    /// Up to 3 monster type ids (0xFF = empty). Order matches ROM bytes 1–3.
    mon_type: [3]u8,
    /// Counts for each mon_type (0–3), unpacked from byte 4 (2 bits each, MSB first).
    mon_count: [3]u8,
    /// Index into MonsterPos (×8).
    pos_index: u8,
    /// Battle flags / song / auto-battle bits ($29a2).
    battle_flags: u8,
    /// Index into MonsterCursor (×16).
    cursor_index: u8,

    pub fn backAttack(self: BattleProp) bool {
        return (self.flags & 0x08) != 0;
    }

    /// BattleSongTbl index from byte 6 bits 2–3 (init.asm → $38e5).
    /// 0..2 → song; 3 → silence (no battle BGM).
    pub fn songIndex(self: BattleProp) u8 {
        return (self.battle_flags >> 2) & 3;
    }
};

/// Expanded monster slot before object init (mirrors $29b5 type ids, up to 8).
pub const SlotPlan = struct {
    /// Monster type id per slot 0..count-1
    type_id: [8]u8 = .{0xFF} ** 8,
    count: u8 = 0,
    /// Screen positions (pixel-ish) per slot from MonsterPos
    x: [8]u8 = .{0} ** 8,
    y: [8]u8 = .{0} ** 8,
};

/// Load BattleProp for battle_id ($1800 low 9 bits used by game).
pub fn load(r: *const rom_mod.Rom, battle_id: u16) !BattleProp {
    if (battle_id >= offsets.en.battle_property_count) return error.BadBattleId;
    const off = offsets.en.battle_properties + @as(usize, battle_id) * 8;
    const raw = try r.slice(off, 8);
    var counts: [3]u8 = .{ 0, 0, 0 };
    // InitBattle @813d: for each of 3 types, 2× ASL of counts byte into count
    var ab: u8 = raw[4];
    var ti: usize = 0;
    while (ti < 3) : (ti += 1) {
        var n: u8 = 0;
        var bit: u8 = 0;
        while (bit < 2) : (bit += 1) {
            const carry: u8 = if ((ab & 0x80) != 0) 1 else 0;
            ab = ab << 1;
            n = (n << 1) | carry;
        }
        counts[ti] = n;
    }
    return .{
        .flags = raw[0],
        .mon_type = .{ raw[1], raw[2], raw[3] },
        .mon_count = counts,
        .pos_index = raw[5],
        .battle_flags = raw[6],
        .cursor_index = raw[7],
    };
}

/// Expand types×counts with duplicate-type merge (InitBattle @8152–@81a3).
pub fn expandSlots(bp: BattleProp) SlotPlan {
    // Working lists like $29ad / $29ca
    var types: [3]u8 = bp.mon_type;
    var counts: [3]u8 = bp.mon_count;

    // Merge duplicate types into earlier slot
    var x: usize = 0;
    while (x < 2) : (x += 1) {
        if (types[x] == 0xFF) continue;
        var y: usize = x + 1;
        while (y < 3) : (y += 1) {
            if (types[y] == 0xFF) continue;
            if (types[y] == types[x]) {
                counts[x] +%= counts[y];
                counts[y] = 0;
                types[y] = 0xFF;
            }
        }
    }

    var plan: SlotPlan = .{};
    var slot: u8 = 0;
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        if (types[t] == 0xFF or counts[t] == 0) continue;
        var c: u8 = 0;
        while (c < counts[t] and slot < 8) : (c += 1) {
            plan.type_id[slot] = types[t];
            slot += 1;
        }
    }
    plan.count = slot;
    return plan;
}

test "MonsterPos nibble → sprite top-left" {
    // byte $37: hi=3 lo=7 → sprite (3*8+16, 7*8) = (40, 56)
    // cursor would be (32, 56 + h*4 - 4)
    const b: u8 = 0x37;
    const sx: u8 = ((b & 0xF0) >> 1) +% 16;
    const sy: u8 = (b & 0x0F) *% 8;
    try std.testing.expectEqual(@as(u8, 40), sx);
    try std.testing.expectEqual(@as(u8, 56), sy);
    const cursor_x: i32 = @as(i32, sx) - 8;
    try std.testing.expectEqual(@as(i32, 32), cursor_x);
}

/// Apply MonsterPos table (0E/9000, 256×8) — one packed byte per slot.
///
/// DrawMonster (ppu.asm @8d72) places the **sprite top-left** at:
///   tile_x = (byte >> 4) + 2   →  pixel_x = tile_x * 8 = ((byte & $F0) >> 1) + 16
///   tile_y =  byte & $0F       →  pixel_y = tile_y * 8
///
/// UpdateMonsterPos (@8b7f) target **cursor** is different:
///   cursor_x = ((byte & $F0) >> 1) + 8   (= sprite_x − 8)
///   cursor_y = pixel_y + height_tiles*4 − 4
/// (cursor computed at draw time from sprite size — see Obj.monCursorX/Y).
pub fn applyPositions(r: *const rom_mod.Rom, plan: *SlotPlan, pos_index: u8) void {
    const off = offsets.en.monster_positions + @as(usize, pos_index) * 8;
    const raw = r.slice(off, 8) catch return;
    var i: u8 = 0;
    while (i < plan.count and i < 8) : (i += 1) {
        const b = raw[i];
        if (b == 0xFF) {
            plan.x[i] = 40 +% i *% 24;
            plan.y[i] = 48 +% (i % 2) *% 32;
            continue;
        }
        // Sprite top-left (DrawMonster), not cursor coords.
        plan.x[i] = ((b & 0xF0) >> 1) +% 16;
        plan.y[i] = (b & 0x0F) *% 8;
    }
}
