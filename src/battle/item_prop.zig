//! ItemProp — consumable item properties @ 0F/9680 (48 × 6).
//! Same layout as AttackProp (magic.asm LoadArrayItem for items).
//! Item id $B0 + index → table entry (Cmd_01 / DoMagicAttack).
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");

/// First consumable/item-prop id (ItemProp[0]).
pub const item_prop_base: u8 = 0xB0;
pub const item_prop_count: usize = 48;

pub const ItemProp = struct {
    /// Byte 0: casting time (low 5) + targeting (high 3).
    target: u8,
    cast_time: u8,
    /// Byte 1: power.
    power: u8,
    /// Byte 2: hit% (low 7); bit7 = always miss bosses ($289e).
    hit: u8,
    miss_boss: bool,
    /// Byte 3: effect id (low 7); bit7 = fixed 1 base hit ($289f, magic.asm @cef1).
    effect: u8,
    /// ROM: effect bit7 → fixed hits (not “split”). Kept name `fixed_hits`.
    fixed_hits: bool,
    /// Legacy alias used by older call sites — same as fixed_hits.
    split: bool,
    /// Byte 4: element/status index (low 7); bit7 = damage (vs heal).
    element: u8,
    is_damage: bool,
    /// Byte 5: mp cost (unused for items); bit7 = no reflect.
    mp_cost: u8,
    no_reflect: bool,

    pub fn load(r: *const rom_mod.Rom, item_id: u8) ?ItemProp {
        if (item_id < item_prop_base) return null;
        const idx: usize = item_id - item_prop_base;
        if (idx >= item_prop_count) return null;
        const off = offsets.en.item_properties + idx * offsets.en.item_property_stride;
        const raw = r.slice(off, 6) catch return null;
        return .{
            .cast_time = raw[0] & 0x1F,
            .target = raw[0] >> 5,
            .power = raw[1],
            .hit = raw[2] & 0x7F,
            .miss_boss = (raw[2] & 0x80) != 0,
            .effect = raw[3] & 0x7F,
            .fixed_hits = (raw[3] & 0x80) != 0,
            .split = (raw[3] & 0x80) != 0, // alias: was misnamed; effect bit7 = fixed hits
            .element = raw[4] & 0x7F,
            .is_damage = (raw[4] & 0x80) != 0,
            .mp_cost = raw[5] & 0x7F,
            .no_reflect = (raw[5] & 0x80) != 0,
        };
    }

    /// True if item id is in the ItemProp table (battle consumable / throwable magic).
    pub fn isBattleItem(item_id: u8) bool {
        return item_id >= item_prop_base and item_id < item_prop_base + item_prop_count;
    }
};

test "item prop base ids" {
    const std = @import("std");
    try std.testing.expect(ItemProp.isBattleItem(0xCE)); // Cure1
    try std.testing.expect(ItemProp.isBattleItem(0xB0));
    try std.testing.expect(!ItemProp.isBattleItem(0xAF));
    try std.testing.expect(!ItemProp.isBattleItem(0xE0));
}
