//! Field random battles — field/rand_battle.asm (CheckBattle / ChooseRandBattle).
//!
//! Produces a battle_id for Host.enter (mirrors writing $1800 / $1802).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const prop = @import("prop.zig");

/// Result of a successful random-battle roll (field → battle transition).
pub const Encounter = struct {
    battle_id: u16,
    /// $1802 battle BG / flags (subset).
    bg_flags: u8 = 0,
};

/// WorldBattleBGTbl @ rand_battle.asm $8caf — index = (tile prop_hi & 7).
const world_battle_bg_tbl = [_]u8{ 0x00, 0x0A, 0x01, 0x09, 0x0F, 0x05 };

/// Slot weights for ChooseRandBattle (battle.asm probabilities).
fn chooseSlot(roll: u8) u8 {
    if (roll < 0x2B) return 0;
    if (roll < 0x56) return 1;
    if (roll < 0x81) return 2;
    if (roll < 0xAC) return 3;
    if (roll < 0xCC) return 4;
    if (roll < 0xEC) return 5;
    if (roll < 0xFC) return 6;
    return 7;
}

/// Overworld region index 0..63 — CheckBattle overworld path.
pub fn overworldRegionIndex(x: i32, y: i32) usize {
    const ux: u32 = @intCast(x & 0xFF);
    const uy: u32 = @intCast(y & 0xFF);
    const row = (uy >> 2) & 0xF8;
    const col = ux >> 5;
    return @as(usize, row) + col;
}

/// $1802 from world tile prop high byte ($a2 in field WRAM).
/// `prop_hi & 7` indexes WorldBattleBGTbl; bit6 must be set for random fights (caller).
pub fn worldBattleBg(prop_hi: u8) u8 {
    const i = prop_hi & 7;
    if (i < world_battle_bg_tbl.len) return world_battle_bg_tbl[i];
    return world_battle_bg_tbl[0];
}

pub fn tryOverworld(
    r: *const rom_mod.Rom,
    world_x: i32,
    world_y: i32,
    /// WorldTileProp high byte at player tile ($a2).
    tile_prop_hi: u8,
    rng_byte: u8,
    slot_byte: u8,
) ?Encounter {
    // CheckBattle: require prop_hi bit6 (enable random battles) when on foot.
    if ((tile_prop_hi & 0x40) == 0) return null;

    const idx = overworldRegionIndex(world_x, world_y);
    const rates = r.slice(offsets.en.overworld_battle_rate, 64) catch return null;
    const grps = r.slice(offsets.en.overworld_battle_grp, 64) catch return null;
    if (idx >= rates.len) return null;
    const rate = rates[idx];
    if (rate == 0) return null;
    if (rng_byte >= rate) return null;

    const group = grps[idx];
    const slot = chooseSlot(slot_byte);
    const form_i = @as(usize, group) * 8 + slot;
    const forms = r.slice(offsets.en.world_battles, offsets.en.world_battle_groups * 8) catch return null;
    if (form_i >= forms.len) return null;
    return .{
        .battle_id = forms[form_i],
        .bg_flags = worldBattleBg(tile_prop_hi),
    };
}

/// GetBattleBG (rand_battle.asm @8cd4): MapProp byte0.
/// Also used for event battles ($EC) on the current submap (airship intro, etc.).
pub fn submapBattleBg(r: *const rom_mod.Rom, map_id: u16) u8 {
    const map_prop_base: usize = 0xA9C84;
    const map_prop_stride: usize = 13;
    if (map_id >= 383) return 0;
    const raw = r.slice(map_prop_base + @as(usize, map_id) * map_prop_stride, map_prop_stride) catch return 0;
    const b0 = raw[0];
    var bg: u8 = b0 & 0x8F;
    if ((b0 & 0x40) != 0) bg |= 0x20; // alternate palette
    return bg;
}

/// Forced event battle ($EC formation id) — same shape as a random encounter result.
pub fn eventBattle(r: *const rom_mod.Rom, battle_id: u16, map_id: u16, mode_overworld: bool, tile_prop_hi: u8) Encounter {
    const bg: u8 = if (mode_overworld) worldBattleBg(tile_prop_hi) else submapBattleBg(r, map_id);
    return .{ .battle_id = battle_id, .bg_flags = bg };
}

pub fn trySubmap(
    r: *const rom_mod.Rom,
    map_id: u16,
    rng_byte: u8,
    slot_byte: u8,
) ?Encounter {
    if (map_id >= 512) return null;
    const rates = r.slice(offsets.en.sub_battle_rate, 512) catch return null;
    const grps = r.slice(offsets.en.sub_battle_grp, 512) catch return null;
    const rate = rates[map_id];
    if (rate == 0) return null;
    if (rng_byte >= rate) return null;

    const group = grps[map_id];
    const slot = chooseSlot(slot_byte);
    const form_i = @as(usize, group) * 8 + slot;
    const forms = r.slice(offsets.en.sub_battles, offsets.en.sub_battle_groups * 8) catch return null;
    if (form_i >= forms.len) return null;
    return .{ .battle_id = forms[form_i], .bg_flags = submapBattleBg(r, map_id) };
}

/// Validate battle_id exists (optional debug).
pub fn hasProp(r: *const rom_mod.Rom, battle_id: u16) bool {
    return prop.load(r, battle_id) catch null != null;
}

test "world battle bg table" {
    try std.testing.expectEqual(@as(u8, 0x00), worldBattleBg(0x40)); // field + battles
    try std.testing.expectEqual(@as(u8, 0x0A), worldBattleBg(0x41)); // beach
    try std.testing.expectEqual(@as(u8, 0x01), worldBattleBg(0x42)); // forest
    try std.testing.expectEqual(@as(u8, 0x09), worldBattleBg(0x43)); // desert
}
