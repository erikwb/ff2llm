//! Field UseItem subset — menu/item.asm @a706 ItemEffect_ce–e1 / d4–dc.
//!
//! CalcPotionEffect: heal = ItemProp.power × 48.
//! Status items $D5–$DC: AND status with ItemStatusMaskTbl (menu.asm @fec3).
const state_mod = @import("state.zig");
const inventory_mod = @import("inventory.zig");
const item_prop = @import("../battle/item_prop.zig");
const rom_mod = @import("../rom.zig");
const status_mod = @import("../battle/status.zig");

pub const UseResult = struct {
    ok: bool = false,
    msg: []const u8 = "",
};

/// ItemStatusMaskTbl for items $D5–$DC (and $DD panacea separate).
/// Word AND on status1|status2<<8 — bits cleared are the cured status.
pub const item_status_mask_tbl = [_]u16{
    0xFFBF, // $D5 clear stone (s1 bit6)
    0xFFDF, // $D6 clear toad
    0xFFEF, // $D7 clear mini
    0xFFF7, // $D8 clear pig
    0xFFFB, // $D9 clear mute
    0xFFFD, // $DA clear blind
    0xFFFE, // $DB clear poison
    0x7FFF, // $DC clear s2 bit7 (float high in some layouts — ROM word)
};

/// CalcPotionEffect @a611: power×48 from ItemProp.
pub fn potionAmount(r: ?*const rom_mod.Rom, item_id: u8) u16 {
    if (r) |rom| {
        if (item_prop.ItemProp.load(rom, item_id)) |ip| {
            return @as(u16, ip.power) *% 48;
        }
    }
    return 48;
}

fn statusWord(m: *const state_mod.PartyMember) u16 {
    return @as(u16, m.status1) | (@as(u16, m.status2) << 8);
}

fn setStatusWord(m: *state_mod.PartyMember, w: u16) void {
    m.status1 = @truncate(w);
    m.status2 = @truncate(w >> 8);
}

/// Use bag item on party[target]. Consumes one from inventory on success.
pub fn useOnParty(
    inv: *inventory_mod.Inventory,
    party: []state_mod.PartyMember,
    target: usize,
    item_id: u8,
    rom: ?*const rom_mod.Rom,
) UseResult {
    if (target >= party.len or !party[target].present) {
        return .{ .msg = "No target" };
    }
    const m = &party[target];
    const dead = (m.status1 & status_mod.Status1.dead) != 0 or m.hp == 0;

    // Phoenix Down $D4 (ItemEffect_d4)
    if (item_id == 0xD4) {
        if (!dead) return .{ .msg = "Unnecessary" };
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        m.status1 &= ~status_mod.Status1.dead;
        // HP = max(current, vitality×5)
        const vit5: u16 = @as(u16, m.vitality) *% 5;
        if (vit5 > m.hp) m.hp = if (vit5 > m.max_hp) m.max_hp else vit5;
        if (m.hp < 1) m.hp = 1;
        return .{ .ok = true, .msg = "Revived" };
    }

    // Panacea $DD — clear s1, clear s2 bit7
    if (item_id == 0xDD) {
        if (dead) return .{ .msg = "Doesn't work" };
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        m.status1 = 0;
        m.status2 &= 0x7F;
        return .{ .ok = true, .msg = "Cured" };
    }

    // Status restoring $D5–$DC
    if (item_id >= 0xD5 and item_id <= 0xDC) {
        if (dead) return .{ .msg = "Doesn't work" };
        const idx: usize = item_id - 0xD5;
        const mask = item_status_mask_tbl[idx];
        const before = statusWord(m);
        const after = before & mask;
        if (after == before) return .{ .msg = "Unnecessary" };
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        setStatusWord(m, after);
        // Mirror poison bit into hp==0? no — poison is status only on field
        return .{ .ok = true, .msg = "Cured" };
    }

    // Dead/stone block potions (CalcPotionEffect)
    if (dead and item_id != 0xD4) {
        return .{ .msg = "Doesn't work" };
    }

    // Apples / soma
    if (item_id == 0xDF) {
        m.max_hp = @min(m.max_hp +% 100, 9999);
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        return .{ .ok = true, .msg = "Max HP +100" };
    }
    if (item_id == 0xE0) {
        m.max_hp = @min(m.max_hp +% 50, 9999);
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        return .{ .ok = true, .msg = "Max HP +50" };
    }
    if (item_id == 0xE1) {
        m.max_mp = @min(m.max_mp +% 10, 999);
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        return .{ .ok = true, .msg = "Max MP +10" };
    }

    if (item_id == 0xD3) {
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        m.hp = m.max_hp;
        m.mp = m.max_mp;
        return .{ .ok = true, .msg = "Fully restored" };
    }

    const amt = potionAmount(rom, item_id);
    if (item_id >= 0xCE and item_id <= 0xD0) {
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        const nh = m.hp +% amt;
        m.hp = if (nh > m.max_hp) m.max_hp else nh;
        return .{ .ok = true, .msg = "HP restored" };
    }
    if (item_id >= 0xD1 and item_id <= 0xD2) {
        if (!inv.take(item_id)) return .{ .msg = "No item" };
        const nm = m.mp +% amt;
        m.mp = if (nm > m.max_mp) m.max_mp else nm;
        return .{ .ok = true, .msg = "MP restored" };
    }
    return .{ .msg = "Can't use here" };
}

test "potion amount power times 48" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 48), potionAmount(null, 0xCE));
}

test "status mask clears poison" {
    const std = @import("std");
    // $DB index 6 → $FFFE
    const mask = item_status_mask_tbl[6];
    const before: u16 = 0x0001; // poison
    try std.testing.expectEqual(@as(u16, 0), before & mask);
}
