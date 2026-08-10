//! Cmd_17 Sneak (steal) + Cmd_16 Dart (throw) — battle/cmd.asm.
const damage = @import("damage.zig");
const obj_mod = @import("obj.zig");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const inventory_mod = @import("../game/inventory.zig");
const equip = @import("equip.zig");
const battle_msg = @import("battle_msg.zig");

pub const StealResult = struct {
    ok: bool = false,
    /// BattleMsg id for feedback.
    msg_id: u8 = battle_msg.MsgId.failed,
    /// Item stolen (0 if none).
    item_id: u8 = 0,
    /// Self-damage if caught (max_hp/16).
    self_damage: u16 = 0,
};

/// Steal rate = clamp((atk_level + 50) - (mon_level + 10), 1, 99).
/// Success if rate >= Rand99. Fail may deal max_hp/16 if Rand99 < mon_level+10.
pub fn doSteal(
    r: *const rom_mod.Rom,
    inv: *inventory_mod.Inventory,
    attacker: *obj_mod.Obj,
    target: *const obj_mod.Obj,
    rng: damage.Rng,
) StealResult {
    if (!target.is_monster or target.is_boss) {
        return .{ .msg_id = battle_msg.MsgId.failed };
    }
    // mon level+10 used in ROM ($272f)
    const mon_lv10: u16 = @as(u16, target.level) +% 10;
    var rate: i16 = @as(i16, attacker.level) + 50 - @as(i16, @intCast(mon_lv10));
    if (rate < 1) rate = 1;
    if (rate > 99) rate = 99;

    const roll = rng.next() % 100;
    if (@as(i16, roll) > rate) {
        // Fail — chance of being caught
        const catch_roll = rng.next() % 100;
        if (@as(u16, catch_roll) < mon_lv10) {
            var dmg: u16 = attacker.max_hp >> 4;
            if (dmg < 1) dmg = 1;
            if (attacker.hp > dmg) attacker.hp -= dmg else {
                attacker.hp = 0;
                attacker.status.setDead();
            }
            return .{ .msg_id = 28, .self_damage = dmg }; // "Failed." / caught — use 28
        }
        return .{ .msg_id = 27 }; // couldn't steal
    }

    // Success: first item in MonsterItems[set] (cmd.asm always slot 0)
    const item_id = monItemId(r, target);
    if (item_id == 0) return .{ .msg_id = 27 };

    // Inventory.give already grants 10 for arrows $54–$5F.
    if (!inv.give(item_id)) return .{ .msg_id = 27 };
    return .{ .ok = true, .msg_id = 29, .item_id = item_id }; // "Found ."
}

fn monItemId(r: *const rom_mod.Rom, mon: *const obj_mod.Obj) u8 {
    // item_set holds full prop drop byte; set index is low 6 bits
    const set_i: usize = mon.item_set & 0x3F;
    if (set_i >= 64) return 0;
    const raw = r.slice(offsets.en.monster_items + set_i * 4, 4) catch return 0;
    return raw[0];
}

pub const ThrowResult = struct {
    ok: bool = false,
    damage: u16 = 0,
    missed: bool = false,
};

/// Cmd_16 Throw (cmd.asm @e34f): EquipProp.attack × level + Rand99, cap 9999.
/// Misses if mon invincible ($3881) or non-mon target.
pub fn doThrow(
    r: *const rom_mod.Rom,
    inv: *inventory_mod.Inventory,
    bag_slot: usize,
    attacker: *const obj_mod.Obj,
    target: *obj_mod.Obj,
    rng: damage.Rng,
    mon_invincible: bool,
) ThrowResult {
    if (bag_slot >= inv.slots.len) return .{};
    const s = inv.slots[bag_slot];
    if (s.id == 0 or s.qty == 0) return .{};
    // Must target mon; invincible → "nothing" path (@e367)
    if (!target.is_monster or target.hp == 0 or mon_invincible) {
        // Still consume? ROM still stores $3580 then checks invincible first — no consume on fail path before load
        return .{ .missed = true };
    }

    const eq = equip.EquipProp.load(r, s.id) orelse return .{};
    // Mult8: attack × level, then + Rand99, cap $270f
    const atk = eq.attack;
    var dmg: u32 = @as(u32, atk) *% @as(u32, if (attacker.level == 0) 1 else attacker.level);
    dmg +%= rng.next() % 100;
    if (dmg > 9999) dmg = 9999;

    const d: u16 = @intCast(dmg);
    if (target.hp > d) target.hp -= d else {
        target.hp = 0;
        target.status.setDead();
    }
    _ = inv.take(s.id);
    return .{ .ok = true, .damage = d };
}
