//! Post-battle party writeback — win.asm RestoreCharProp @f18b + ClearWinStatus @880f.
//!
//! CheckBattleEnd `$a8` bit4 (cleared for NoUpdateBattleTbl) gates **WinUpdate**
//! (gil/exp/level/drops) only. RestoreCharProp still copies `$2000 → $1000` always.
//! Host `no_party_update` therefore means “no WinUpdate”, not “skip HP/status”.
const std = @import("std");
const status_mod = @import("status.zig");

/// ClearWinStatus @8812: `and #$f8` — clear poison/blind/mute for victory pose only.
pub const clear_win_s1_mask: u8 = 0xF8;
/// ClearWinStatus: `and #$40` — keep float only on status2 during win anim.
pub const clear_win_s2_mask: u8 = 0x40;

/// Temporary status for victory animation (saved to `$38bf` then restored).
pub fn clearWinStatus1(s1: u8) u8 {
    return s1 & clear_win_s1_mask;
}

pub fn clearWinStatus2(s2: u8) u8 {
    return s2 & clear_win_s2_mask;
}

/// Field status after RestoreCharProp: full battle s1/s2 (pre-ClearWinStatus values).
/// No extra mask — ROM copies `$2003/$2004` after restore from `$38bf`.
pub fn fieldStatusFromBattle(s1: u8, s2: u8) struct { s1: u8, s2: u8 } {
    return .{ .s1 = s1, .s2 = s2 };
}

/// True if field should reload MapCharGfx (toad/mini/pig / form bits).
pub fn fieldGfxDirty(s1: u8) bool {
    return (s1 & status_mod.Status1.form_bits) != 0;
}

/// `$a8` bit4: WinUpdate (gil/exp/level/drops). NoUpdateBattleTbl clears this bit.
pub fn shouldWinUpdate(a8_raw: u8) bool {
    return (a8_raw & 0x10) != 0;
}

/// Victory `$a8` base `$30`; NoUpdate → `$20` (bit4 clear).
pub fn victoryA8(no_update: bool) u8 {
    var a: u8 = 0x30;
    if (no_update) a &= ~@as(u8, 0x10);
    return a;
}

/// One party slot writeback fields (RestoreCharProp char block → `$1000`).
pub const SlotOut = struct {
    hp: u16,
    mp: u16,
    max_hp: u16,
    max_mp: u16,
    level: u8,
    left_hand: u8,
    right_hand: u8,
    status1: u8,
    status2: u8,
};

pub fn slotFromBattle(
    hp: u16,
    mp: u16,
    max_hp: u16,
    max_mp: u16,
    level: u8,
    left_hand: u8,
    right_hand: u8,
    s1: u8,
    s2: u8,
) SlotOut {
    const st = fieldStatusFromBattle(s1, s2);
    return .{
        .hp = hp,
        .mp = mp,
        .max_hp = max_hp,
        .max_mp = max_mp,
        .level = level,
        .left_hand = left_hand,
        .right_hand = right_hand,
        .status1 = st.s1,
        .status2 = st.s2,
    };
}

test "ClearWinStatus clears poison blind mute keeps dead stone form" {
    const s1 = status_mod.Status1.poison | status_mod.Status1.blind | status_mod.Status1.mute |
        status_mod.Status1.toad | status_mod.Status1.dead;
    const cleared = clearWinStatus1(s1);
    try std.testing.expectEqual(@as(u8, 0), cleared & status_mod.Status1.poison);
    try std.testing.expectEqual(@as(u8, 0), cleared & status_mod.Status1.blind);
    try std.testing.expectEqual(@as(u8, 0), cleared & status_mod.Status1.mute);
    try std.testing.expect((cleared & status_mod.Status1.toad) != 0);
    try std.testing.expect((cleared & status_mod.Status1.dead) != 0);
}

test "ClearWinStatus2 keeps only float" {
    const s2 = status_mod.Status2.float_bit | status_mod.Status2.berserk | status_mod.Status2.sleep;
    try std.testing.expectEqual(status_mod.Status2.float_bit, clearWinStatus2(s2));
    try std.testing.expectEqual(@as(u8, 0), clearWinStatus2(status_mod.Status2.berserk));
}

test "field status is full battle status after RestoreCharProp" {
    const s1 = status_mod.Status1.poison | status_mod.Status1.toad;
    const s2 = status_mod.Status2.float_bit | status_mod.Status2.sleep;
    const f = fieldStatusFromBattle(s1, s2);
    try std.testing.expectEqual(s1, f.s1);
    try std.testing.expectEqual(s2, f.s2);
    try std.testing.expect(fieldGfxDirty(s1));
    try std.testing.expect(!fieldGfxDirty(status_mod.Status1.poison));
}

test "NoUpdate clears only WinUpdate bit of victory $a8" {
    try std.testing.expectEqual(@as(u8, 0x30), victoryA8(false));
    try std.testing.expectEqual(@as(u8, 0x20), victoryA8(true));
    try std.testing.expect(shouldWinUpdate(0x30));
    try std.testing.expect(!shouldWinUpdate(0x20));
}

test "slotFromBattle copies status for field antidotes" {
    const s = slotFromBattle(100, 20, 200, 40, 5, 0x60, 0, status_mod.Status1.poison, 0);
    try std.testing.expectEqual(@as(u16, 100), s.hp);
    try std.testing.expectEqual(status_mod.Status1.poison, s.status1);
}
