//! WinUpdate subset — battle/win.asm @ec72.
//!
//! Sum MonsterXP / MonsterGil per defeated mon; roll MonsterItems drops
//! (rate in prop byte7 bits 6–7, set in bits 0–5).
const std = @import("std");
const data_mod = @import("../data.zig");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");

pub const max_drops: u8 = 8;

pub const DropList = struct {
    items: [max_drops]u8 = .{0} ** max_drops,
    count: u8 = 0,

    pub fn push(self: *DropList, id: u8) void {
        if (id == 0 or id == 0xFF) return;
        if (self.count >= max_drops) return;
        self.items[self.count] = id;
        self.count +%= 1;
    }
};

pub const Rewards = struct {
    gil: u32 = 0,
    exp: u32 = 0,
    drops: DropList = .{},
};

/// Total gil + exp for the defeated formation (one full count of each mon type).
pub fn calcRewards(mon_types: []const u8, mon_count: u8, gd: *const data_mod.GameData) Rewards {
    var out: Rewards = .{};
    var i: u8 = 0;
    while (i < mon_count and i < mon_types.len) : (i += 1) {
        const tid = mon_types[i];
        if (tid == 0xFF) continue;
        if (tid >= gd.monsters.len) continue;
        const m = gd.monsters[tid];
        out.gil +%= m.gil;
        out.exp +%= m.exp;
    }
    return out;
}

/// WinUpdate @ec84–@ed68: gil/exp + item drops per killed mon.
///
/// `rand99_fn` / `rand_fn` match Rand99 / Rand (0..98 and 0..255).
pub fn calcRewardsWithDrops(
    mon_types: []const u8,
    mon_count: u8,
    gd: *const data_mod.GameData,
    rom: *const rom_mod.Rom,
    rand99_fn: *const fn (*anyopaque) u8,
    rand_fn: *const fn (*anyopaque) u8,
    rng_ctx: *anyopaque,
) Rewards {
    var out: Rewards = .{};
    var i: u8 = 0;
    while (i < mon_count and i < mon_types.len) : (i += 1) {
        const tid = mon_types[i];
        if (tid == 0xFF) continue;
        if (tid >= gd.monsters.len) continue;
        const m = gd.monsters[tid];
        out.gil +%= m.gil;
        out.exp +%= m.exp;
        // $358e drop byte = prop[7]
        const drop_byte: u8 = if (m.prop_raw.len > 7) m.prop_raw[7] else 0;
        if (rollDrop(drop_byte, rom, rand99_fn(rng_ctx), rand_fn(rng_ctx))) |item| {
            out.drops.push(item);
        }
    }
    return out;
}

/// win.asm @ed00–@ed5f: rate bits → threshold; always if $C0.
/// Item slot from Rand thresholds 0x80 / 0xD0 / 0xFC.
pub fn rollDrop(drop_byte: u8, rom: *const rom_mod.Rom, rand99: u8, rand255: u8) ?u8 {
    if (!dropRatePass(drop_byte, rand99)) return null;
    const set_i: usize = @as(usize, drop_byte & 0x3F);
    if (set_i >= 64) return null;
    const raw = rom.slice(offsets.en.monster_items + set_i * 4, 4) catch return null;
    const slot: u8 = if (rand255 < 0x80)
        0
    else if (rand255 < 0xD0)
        1
    else if (rand255 < 0xFC)
        2
    else
        3;
    const id = raw[slot];
    if (id == 0 or id == 0xFF) return null;
    return id;
}

/// Divide exp among living party members (DivXP subset: at least 1 each).
pub fn expPerMember(total: u32, living_party: u8) u32 {
    if (living_party == 0) return 0;
    var share = total / living_party;
    if (share < 1 and total > 0) share = 1;
    return share;
}

/// Party gil cap (field/event same 9_999_999).
pub const gil_cap: u32 = 9_999_999;

/// Add gil with cap (WinUpdate → party $16a0).
pub fn addGil(current: u32, gain: u32) u32 {
    const sum = current +% gain;
    return if (sum > gil_cap or sum < current) gil_cap else sum;
}

/// Drop rate threshold from prop byte7 bits 6–7 (win.asm @ecf6).
/// 0 = never; $40 → 5; $80 → $19; $C0 → always.
pub fn dropRateThreshold(drop_byte: u8) ?u8 {
    const rate = drop_byte & 0xC0;
    if (rate == 0) return null; // never
    if (rate == 0xC0) return 100; // always (any rand99 < 100)
    if (rate == 0x40) return 5;
    if (rate == 0x80) return 0x19;
    return null;
}

/// True if Rand99 passes drop rate (win.asm @ed06).
pub fn dropRatePass(drop_byte: u8, rand99: u8) bool {
    const thr = dropRateThreshold(drop_byte) orelse return false;
    if (thr >= 100) return true; // always
    return rand99 < thr;
}

test "drop rate thresholds" {
    // rate 0 → no drop
    try std.testing.expect(rollDrop(0x00, undefined, 0, 0) == null);
    // rate bits only matter when we have a ROM for the set table — unit-test pick logic:
    // slot from rand: 0x00→0, 0x80→1, 0xD0→2, 0xFC→3
    try std.testing.expectEqual(@as(u8, 0), dropSlot(0x00));
    try std.testing.expectEqual(@as(u8, 0), dropSlot(0x7F));
    try std.testing.expectEqual(@as(u8, 1), dropSlot(0x80));
    try std.testing.expectEqual(@as(u8, 1), dropSlot(0xCF));
    try std.testing.expectEqual(@as(u8, 2), dropSlot(0xD0));
    try std.testing.expectEqual(@as(u8, 2), dropSlot(0xFB));
    try std.testing.expectEqual(@as(u8, 3), dropSlot(0xFC));
    try std.testing.expectEqual(@as(u8, 3), dropSlot(0xFF));
}

fn dropSlot(rand255: u8) u8 {
    if (rand255 < 0x80) return 0;
    if (rand255 < 0xD0) return 1;
    if (rand255 < 0xFC) return 2;
    return 3;
}

test "rate 40 is 5 percent 80 is 25" {
    try std.testing.expectEqual(@as(?u8, 5), dropRateThreshold(0x40));
    try std.testing.expectEqual(@as(?u8, 0x19), dropRateThreshold(0x80));
    try std.testing.expectEqual(@as(?u8, 100), dropRateThreshold(0xC0));
    try std.testing.expect(dropRateThreshold(0x00) == null);
    try std.testing.expect(dropRatePass(0xC0, 99));
    try std.testing.expect(dropRatePass(0x40, 4));
    try std.testing.expect(!dropRatePass(0x40, 5));
}

test "expPerMember at least 1" {
    try std.testing.expectEqual(@as(u32, 0), expPerMember(0, 3));
    try std.testing.expectEqual(@as(u32, 1), expPerMember(2, 3));
    try std.testing.expectEqual(@as(u32, 10), expPerMember(30, 3));
    try std.testing.expectEqual(@as(u32, 0), expPerMember(100, 0));
}

test "addGil caps at 9999999" {
    try std.testing.expectEqual(@as(u32, 100), addGil(50, 50));
    try std.testing.expectEqual(gil_cap, addGil(gil_cap - 10, 100));
    try std.testing.expectEqual(gil_cap, addGil(gil_cap, 1));
}
