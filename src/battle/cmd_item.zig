//! Cmd_01 inventory helpers + legacy single-target doItem.
//!
//! Live battle path: Host.execItem → cmd_magic.doItemMagic (DoMagicAttack @ebfa).
//! This file keeps slot enumeration + a thin doItem for unit tests.
const std = @import("std");
const damage = @import("damage.zig");
const obj_mod = @import("obj.zig");
const item_prop = @import("item_prop.zig");
const rom_mod = @import("../rom.zig");
const inventory_mod = @import("../game/inventory.zig");

pub const ItemResult = struct {
    ok: bool = false,
    /// Amount healed or damage dealt (message display).
    amount: u16 = 0,
    healed: bool = false,
    target_died: bool = false,
    /// Item was consumed from inventory.
    consumed: bool = false,
};

/// DoMagicAttack power setup (magic.asm @d039–@d068): base = power × 4 (items/non-summon).
fn baseFromPower(power: u8) u16 {
    return @as(u16, power) *% 4;
}

/// RestoreHP / damage via CalcDmg with 0 defense for party-on-party heals.
fn calcAmount(power: u8, defense: u16, rng: damage.Rng) u16 {
    const res = damage.calcDamage(.{
        .base_attack = baseFromPower(power),
        .defense = defense,
        .hits = 1,
        .elemental_mult = 2,
        .creature_mult = 2,
        .defense_divisor = 1,
    }, rng);
    return res.damage;
}

/// Cmd_01: use inventory item on target (party or monster).
pub fn doItem(
    r: *const rom_mod.Rom,
    inv: *inventory_mod.Inventory,
    item_id: u8,
    target: *obj_mod.Obj,
    rng: damage.Rng,
) ItemResult {
    if (!item_prop.ItemProp.isBattleItem(item_id)) return .{};
    const ip = item_prop.ItemProp.load(r, item_id) orelse return .{};
    if (!inv.has(item_id)) return .{};

    var out: ItemResult = .{ .ok = true };

    switch (ip.effect) {
        // Spell Damage (throwables $B0+ with eff 0)
        0 => {
            if (target.hp == 0) return .{};
            const amt = calcAmount(ip.power, target.defense, rng);
            if (target.hp > amt) target.hp -= amt else target.hp = 0;
            out.amount = amt;
            out.healed = false;
            out.target_died = target.hp == 0;
        },
        // Restore HP (Cure1/2/3 = $CE/$CF/$D0)
        2 => {
            if (target.hp == 0) return .{};
            // Character target → defense 0 (magic.asm @d084)
            const def: u16 = if (target.is_monster) target.defense else 0;
            const amt = calcAmount(ip.power, def, rng);
            const room = target.max_hp -| target.hp;
            const heal = @min(amt, room);
            target.hp +%= heal;
            out.amount = heal;
            out.healed = true;
        },
        // Life
        10 => {
            if (target.hp != 0) return .{};
            target.hp = @max(1, target.max_hp / 10);
            if (target.hp > target.max_hp) target.hp = target.max_hp;
            out.amount = target.hp;
            out.healed = true;
        },
        // Heal / Esuna — clear common statuses (no status bits yet; no-op heal toast)
        11 => {
            out.amount = 0;
            out.healed = true;
        },
        // Restore MP
        21 => {
            const def: u16 = 0;
            const amt = calcAmount(ip.power, def, rng);
            const room = target.max_mp -| target.mp;
            const heal = @min(amt, room);
            target.mp +%= heal;
            out.amount = heal;
            out.healed = true;
        },
        // Elixir — full HP + MP
        22 => {
            out.amount = (target.max_hp -| target.hp) +% (target.max_mp -| target.mp);
            target.hp = target.max_hp;
            target.mp = target.max_mp;
            out.healed = true;
        },
        else => {
            // Unsupported effect: still consume if ROM would (most items go through DoMagicAttack).
            // Apply power as heal when not flagged damage, else damage.
            if (ip.is_damage) {
                if (target.hp == 0) return .{};
                const amt = calcAmount(ip.power, target.defense, rng);
                if (target.hp > amt) target.hp -= amt else target.hp = 0;
                out.amount = amt;
                out.target_died = target.hp == 0;
            } else if (ip.power > 0) {
                const def: u16 = if (target.is_monster) target.defense else 0;
                const amt = calcAmount(ip.power, def, rng);
                const room = target.max_hp -| target.hp;
                const heal = @min(amt, room);
                target.hp +%= heal;
                out.amount = heal;
                out.healed = true;
            }
        },
    }

    // char.asm @a67c–@a759: decrement qty (except auto-battle / crystal $C8 special).
    if (item_id != 0xC8) {
        out.consumed = inv.take(item_id);
    }
    return out;
}

/// Enumerate inventory slots that are battle-usable (ItemProp range).
pub fn firstUsableSlot(inv: *const inventory_mod.Inventory) ?usize {
    for (inv.slots, 0..) |s, i| {
        if (s.id != 0 and s.qty > 0 and item_prop.ItemProp.isBattleItem(s.id)) return i;
    }
    return null;
}

pub fn nextUsableSlot(inv: *const inventory_mod.Inventory, from: usize, dir: i8) usize {
    const n = inventory_mod.slot_count;
    var i: usize = from;
    var steps: usize = 0;
    while (steps < n) : (steps += 1) {
        if (dir >= 0) {
            i = (i + 1) % n;
        } else {
            i = if (i == 0) n - 1 else i - 1;
        }
        const s = inv.slots[i];
        if (s.id != 0 and s.qty > 0 and item_prop.ItemProp.isBattleItem(s.id)) return i;
    }
    return from;
}

test "first usable slot finds cure" {
    var inv: inventory_mod.Inventory = .{};
    try std.testing.expect(firstUsableSlot(&inv) == null);
    _ = inv.give(0xCE);
    const s = firstUsableSlot(&inv).?;
    try std.testing.expectEqual(@as(u8, 0xCE), inv.slots[s].id);
}
