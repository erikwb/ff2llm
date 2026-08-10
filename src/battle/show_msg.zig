//! ShowMsg `$F8` type paths — btlgfx.asm GfxScriptCmd_f8 @c97f / ShowMsg_00..04.
//!
//! Type param → ShowMsgTbl:
//!   0 attacker name (unused in scripts)
//!   1 target name (unused)
//!   2 attack name (cmd / item / magic / mon attack)
//!   3 battle message (BattleMsg chain)
//!   4 damage numerals (DrawDmgNumerals)
const std = @import("std");

/// `$F8` param (ShowMsgTbl index).
pub const MsgType = enum(u8) {
    attacker_name = 0,
    target_name = 1,
    attack_name = 2,
    battle_msg = 3,
    damage_numerals = 4,
};

pub fn msgTypeFromParam(p: u8) ?MsgType {
    if (p > 4) return null;
    return @enumFromInt(p);
}

// --- ShowMsg_02 attack name ($34c7 / $34c8) ---------------------------------

/// `$34c7` bits 4–6 name class (ShowMsg_02 @cb32).
pub const AttackNameKind = enum {
    /// bits != $10/$20/$40 — no name window
    none,
    /// `$10` — BattleCmdName (5 tiles)
    command,
    /// `$20` — ItemName (8 tiles after icon)
    item,
    /// `$40` — MagicName or AttackName (mon)
    magic_or_attack,
};

/// Decode `$34c7 & $70` → name kind.
pub fn attackNameKind(flag_34c7: u8) AttackNameKind {
    return switch (flag_34c7 & 0x70) {
        0x10 => .command,
        0x20 => .item,
        0x40 => .magic_or_attack,
        else => .none,
    };
}

/// Spell vs monster attack name when kind is magic_or_attack (`$34c8`).
/// `$34c8 < $48` → MagicName (6 tiles + type mark); else AttackName index `$34c8-$48`.
pub fn isMonsterAttackName(name_id: u8) bool {
    return name_id >= 0x48;
}

pub fn monsterAttackNameIndex(name_id: u8) u8 {
    return name_id -% 0x48;
}

/// Host presentation for ShowMsg_02.
pub const AttackNamePresent = struct {
    kind: AttackNameKind,
    /// Raw `$34c8` id (cmd/item/spell/attack).
    id: u8,
    /// True when magic path uses AttackName table (mon skill).
    mon_attack: bool = false,
    /// Show nothing (id 0 for item/magic).
    skip: bool = false,
};

pub fn resolveAttackName(flag_34c7: u8, id_34c8: u8) AttackNamePresent {
    const kind = attackNameKind(flag_34c7);
    var out: AttackNamePresent = .{ .kind = kind, .id = id_34c8 };
    switch (kind) {
        .none => out.skip = true,
        .command => {},
        .item => {
            if (id_34c8 == 0) out.skip = true;
        },
        .magic_or_attack => {
            if (id_34c8 == 0) {
                out.skip = true;
            } else if (isMonsterAttackName(id_34c8)) {
                out.mon_attack = true;
            }
        },
    }
    return out;
}

// --- ShowMsg_00 / _01 name source -------------------------------------------

/// Attacker/target name: bit7 of `$34c2`/`$34c4` → monster vs character.
pub fn isMonsterActor(flags: u8) bool {
    return (flags & 0x80) != 0;
}

/// ShowMsg_01 multi-target: `$34c4 & $40`.
pub fn isMultiTarget(flags_34c4: u8) bool {
    return (flags_34c4 & 0x40) != 0;
}

// --- ShowMsg_04 damage word -------------------------------------------------

/// One target's damage word layout (battle WRAM `$34d4` / `$34de` style).
/// Host packs: low 14 bits damage, bit14 heal (green), bit15 unused host, bit6 of high byte = miss in ROM.
/// ROM: word at ($41),y — low 14 = dmg, bit14 of full word via `bpl` on high after iny? 
/// From ShowMsg_04:
///   lda ($41),y ; damage value (16-bit)
///   and #$3fff  ; magnitude
///   iny; lda ($41),y; and #$40 → miss
///   lda ($41),y; bpl → hp damage else MP (green `$3d` pal)
/// So each entry is 2 bytes: lo, hi where hi bit6=miss, hi bit7=MP damage.
pub const DmgFlags = struct {
    amount: u16,
    miss: bool,
    /// bit7 of second byte set → MP damage (green text).
    mp_damage: bool,
};

/// Pack host damage into ROM-style 2-byte entry (for tests / buffer build).
pub fn packDmgEntry(amount: u14, miss: bool, mp_damage: bool) [2]u8 {
    var hi: u8 = @truncate(amount >> 8);
    const lo: u8 = @truncate(amount);
    if (miss) hi |= 0x40;
    if (mp_damage) hi |= 0x80;
    return .{ lo, hi };
}

pub fn unpackDmgEntry(lo: u8, hi: u8) DmgFlags {
    const amount: u16 = (@as(u16, hi & 0x3F) << 8) | lo;
    return .{
        .amount = amount,
        .miss = (hi & 0x40) != 0,
        .mp_damage = (hi & 0x80) != 0,
    };
}

/// ShowMsg_04 early-out: all damage words zero → no numerals (@c9db).
pub fn anyDamageNonzero(entries: []const DmgFlags) bool {
    for (entries) |e| {
        if (e.miss or e.amount != 0) return true;
    }
    return false;
}

/// Window layout for ShowMsg types (host residual chrome; pure classification).
pub const WindowKind = enum {
    left_msg, // ShowMsg_00 DrawLeftMsgWindow
    center_msg, // ShowMsg_01 DrawCenterMsgWindow
    attack_name, // ShowMsg_02 DrawAttackNameWindow
    full_msg, // ShowMsg_03 DrawFullMsgWindow
    numerals_only, // ShowMsg_04 no text window
};

pub fn windowKind(t: MsgType) WindowKind {
    return switch (t) {
        .attacker_name => .left_msg,
        .target_name => .center_msg,
        .attack_name => .attack_name,
        .battle_msg => .full_msg,
        .damage_numerals => .numerals_only,
    };
}

test "ShowMsg type param 0-4" {
    try std.testing.expectEqual(MsgType.attack_name, msgTypeFromParam(2).?);
    try std.testing.expectEqual(MsgType.damage_numerals, msgTypeFromParam(4).?);
    try std.testing.expect(msgTypeFromParam(5) == null);
}

test "ShowMsg_02 name kind from $34c7" {
    try std.testing.expectEqual(AttackNameKind.command, attackNameKind(0x10));
    try std.testing.expectEqual(AttackNameKind.item, attackNameKind(0x20));
    try std.testing.expectEqual(AttackNameKind.magic_or_attack, attackNameKind(0x40));
    try std.testing.expectEqual(AttackNameKind.none, attackNameKind(0x00));
    try std.testing.expectEqual(AttackNameKind.command, attackNameKind(0x1F)); // low nibble ignored
}

test "resolveAttackName spell vs mon attack" {
    const cmd = resolveAttackName(0x10, 0x00);
    try std.testing.expectEqual(AttackNameKind.command, cmd.kind);
    try std.testing.expect(!cmd.skip);

    const item0 = resolveAttackName(0x20, 0);
    try std.testing.expect(item0.skip);

    const spell = resolveAttackName(0x40, 0x0E); // Cure
    try std.testing.expect(!spell.mon_attack);
    try std.testing.expect(!spell.skip);

    const mon = resolveAttackName(0x40, 0x48);
    try std.testing.expect(mon.mon_attack);
    try std.testing.expectEqual(@as(u8, 0), monsterAttackNameIndex(0x48));
    try std.testing.expectEqual(@as(u8, 1), monsterAttackNameIndex(0x49));
}

test "ShowMsg_04 dmg pack miss and mp" {
    const m = packDmgEntry(100, true, false);
    const u = unpackDmgEntry(m[0], m[1]);
    try std.testing.expectEqual(@as(u16, 100), u.amount);
    try std.testing.expect(u.miss);
    try std.testing.expect(!u.mp_damage);

    const h = packDmgEntry(50, false, true);
    const uh = unpackDmgEntry(h[0], h[1]);
    try std.testing.expectEqual(@as(u16, 50), uh.amount);
    try std.testing.expect(uh.mp_damage);
    try std.testing.expect(!uh.miss);
}

test "anyDamageNonzero" {
    const z = [_]DmgFlags{.{ .amount = 0, .miss = false, .mp_damage = false }};
    try std.testing.expect(!anyDamageNonzero(&z));
    const miss = [_]DmgFlags{.{ .amount = 0, .miss = true, .mp_damage = false }};
    try std.testing.expect(anyDamageNonzero(&miss));
    const d = [_]DmgFlags{.{ .amount = 1, .miss = false, .mp_damage = false }};
    try std.testing.expect(anyDamageNonzero(&d));
}

test "windowKind per ShowMsg type" {
    try std.testing.expectEqual(WindowKind.numerals_only, windowKind(.damage_numerals));
    try std.testing.expectEqual(WindowKind.attack_name, windowKind(.attack_name));
    try std.testing.expectEqual(WindowKind.full_msg, windowKind(.battle_msg));
}

test "actor monster bit7" {
    try std.testing.expect(isMonsterActor(0x80));
    try std.testing.expect(!isMonsterActor(0x01));
    try std.testing.expect(isMultiTarget(0x40));
}
