//! Field UseMagic — menu/magic.asm @b53d / MagicEffect_0e–1b.
//!
//! Only spell ids `$0E`–`$1B` are castable on the field (Cure1…Warp).
//! Battle AttackProp `effect` is separate; field jumps by **spell id − $0E**.
const std = @import("std");
const status_mod = @import("../battle/status.zig");

/// First/last field-usable spell id (UseMagic @b53d).
pub const field_spell_min: u8 = 0x0E;
pub const field_spell_max: u8 = 0x1B; // inclusive

/// Field magic effect index = spell_id − $0E (MagicEffectTbl @b760).
pub const FieldEffect = enum(u8) {
    cure1 = 0x0E,
    cure2 = 0x0F,
    cure3 = 0x10,
    cure4 = 0x11,
    esuna = 0x12,
    life = 0x13,
    life2 = 0x14,
    mini = 0x15,
    exit = 0x16,
    sight = 0x17,
    float = 0x18,
    toad = 0x19,
    pig = 0x1A,
    warp = 0x1B,
};

/// Cure base constants from ROM `$0F97F5` / `$97FB` / `$9801` / `$9807` (power bytes).
/// CureEffect: `base<<2` then spirit scaling.
pub const cure_base = struct {
    pub const cure1: u8 = 4;
    pub const cure2: u8 = 12;
    pub const cure3: u8 = 36;
    pub const cure4: u8 = 72;
};

pub fn isFieldUsableSpell(spell_id: u8) bool {
    return spell_id >= field_spell_min and spell_id <= field_spell_max;
}

/// GetCharStatus toad `$20` / pig `$08` gates (UseMagic @b568).
/// Toad may only cast Toad (`$19`); pig only Pig (`$1A`); both clear → any field spell.
pub fn statusAllowsCast(status1: u8, spell_id: u8) bool {
    const toad = (status1 & status_mod.Status1.toad) != 0;
    const pig = (status1 & status_mod.Status1.pig) != 0;
    if (!toad and !pig) return true;
    if (toad and spell_id == @intFromEnum(FieldEffect.toad)) return true;
    if (pig and spell_id == @intFromEnum(FieldEffect.pig)) return true;
    // Toad alone blocks non-toad; pig alone blocks non-pig; both: only matching spell
    if (toad and !pig) return spell_id == @intFromEnum(FieldEffect.toad);
    if (pig and !toad) return spell_id == @intFromEnum(FieldEffect.pig);
    // Both statuses: need spell matching one of them (decomp checks toad first then pig)
    return spell_id == @intFromEnum(FieldEffect.toad) or spell_id == @intFromEnum(FieldEffect.pig);
}

/// Cure base for spell id (0 if not cure1–4).
pub fn cureBaseForSpell(spell_id: u8) u8 {
    return switch (spell_id) {
        @intFromEnum(FieldEffect.cure1) => cure_base.cure1,
        @intFromEnum(FieldEffect.cure2) => cure_base.cure2,
        @intFromEnum(FieldEffect.cure3) => cure_base.cure3,
        @intFromEnum(FieldEffect.cure4) => cure_base.cure4,
        else => 0,
    };
}

/// CureEffect heal amount (menu/magic.asm @b7cf).
/// `spirit` = will (`$1018` / PartyMember.will).
/// `multi_target`: `$1bbb` set → result `>> 2`.
pub fn cureHealAmount(base: u8, spirit: u8, multi_target: bool) u16 {
    // base*4
    var acc: u16 = @as(u16, base) *% 4;
    // + spirit/2
    acc +%= @as(u16, spirit) >> 1;
    // multiply by (spirit/8 + 1)
    const mult: u16 = (@as(u16, spirit) >> 3) +% 1;
    var total: u16 = 0;
    var i: u16 = 0;
    while (i < mult) : (i += 1) {
        total +%= acc;
    }
    if (multi_target) total >>= 2;
    return total;
}

/// Apply cure to HP; skip if dead/stone (`status1 & $c0`). Cap at max_hp.
pub fn applyCureHp(hp: u16, max_hp: u16, status1: u8, heal: u16) u16 {
    if ((status1 & status_mod.Status1.ko) != 0) return hp;
    const sum = hp +% heal;
    return if (sum > max_hp) max_hp else sum;
}

/// Esuna: `status1/2` word `and #$7c80` on $1003–$1004 as 16-bit @b87e.
/// Clears poison/blind/mute/pig/mini/toad; keeps stone/dead (high bits).
pub fn esunaStatus1(s1: u8) u8 {
    // and #$7c80 on 16-bit: low byte and #$80 (dead only from s1? $7c80 = s1&$80, s2&$7c)
    // $1003/$1004 as little-endian word: lo=s1 hi=s2
    // result lo = s1 & $80 (keep dead only from s1 low? $7c80 means lo mask $80, hi mask $7c)
    return s1 & 0x80;
}

pub fn esunaStatus2(s2: u8) u8 {
    return s2 & 0x7C; // keep float? $7c = bits 2–6; float is bit6 $40 — kept
}

/// Life: clear dead bit, HP = min(max_hp, will*5) (@b8a8).
pub fn lifeHp(max_hp: u16, will: u8) u16 {
    const v: u16 = @as(u16, will) *% 5;
    return if (v > max_hp) max_hp else v;
}

/// Life2: full HP, clear dead (+ clear s2 bit7 if any).
pub fn life2ClearsDead(s1: u8) u8 {
    return s1 & ~status_mod.Status1.dead;
}

/// Mini/Toad/Pig toggle masks on status1.
pub const mini_mask: u8 = status_mod.Status1.mini;
pub const toad_mask: u8 = status_mod.Status1.toad;
pub const pig_mask: u8 = status_mod.Status1.pig;

/// Toggle status bit (magic_status_effect @b949): clear bit then set if was clear (eor).
pub fn toggleStatusBit(s1: u8, mask: u8) u8 {
    // decomp: and ~mask; ora (old & mask eor mask) effectively toggles mask bit
    return s1 ^ mask;
}

/// Float: `ora #$40` on status2.
pub fn applyFloat(s2: u8) u8 {
    return s2 | status_mod.Status2.float_bit;
}

/// `$1a04` bits set in CheckMenu (field.asm @8209) before MainMenu_ext.
pub const MenuMapFlags = struct {
    pub const warp: u8 = 0x10; // MapProp.flags bit4 — Warp spell / menu event 3
    pub const exit: u8 = 0x20; // MapProp.flags bit5 — Exit spell / emergency exit item
    pub const sight: u8 = 0x40; // overworld on foot — Sight / dwarven bread
    pub const book: u8 = 0x80; // always on submaps — naughty book
};

/// Menu event ids written to `$1a03` (magic.asm @b9d0 / item.asm @_a87e).
/// Field CheckMenu maps them to ExecEvent ids (field.asm @8241).
pub const MenuEvent = enum(u8) {
    none = 0,
    tent = 1,
    cabin = 2,
    warp = 3,
    exit = 4,
    sight = 5,
    alarm = 6,
    book = 7,
};

/// ExecEvent id for menu event (field.asm @8241–@8287).
pub fn eventIdForMenuEvent(me: MenuEvent) ?u8 {
    return switch (me) {
        .none => null,
        .tent => 0x77,
        .cabin => 0x78,
        .warp => 0x87, // → FD $0A LoadMapStack one level
        .exit => 0x86, // → FD $0B clear stack + LoadMapStack
        .sight => 0xFB, // → FD $33 Sight zoom
        .alarm => null, // sets `$c0` battle flag — host residual
        .book => 0xDB,
    };
}

/// CheckMenu `$1a04` (field.asm @8209):
/// - submap (`$1700==3`): `(MapProp.flags & $30) | $80`
/// - overworld on foot (`$1704==0`): `$40` (sight only)
/// - vehicle: `$00`
pub fn computeMenuMapFlags(on_submap: bool, map_prop_flags: u8, vehicle_id: u8) u8 {
    if (on_submap) {
        return (map_prop_flags & 0x30) | MenuMapFlags.book;
    }
    if (vehicle_id == 0) return MenuMapFlags.sight;
    return 0;
}

/// Bit of `$1a04` required for Exit/Sight/Warp (magic.asm MagicEffect_16/17/1b).
pub fn mapFlagBitForEffect(fe: FieldEffect) ?u8 {
    return switch (fe) {
        .warp => MenuMapFlags.warp,
        .exit => MenuMapFlags.exit,
        .sight => MenuMapFlags.sight,
        else => null,
    };
}

pub fn menuEventForMapEffect(fe: FieldEffect) ?MenuEvent {
    return switch (fe) {
        .warp => .warp,
        .exit => .exit,
        .sight => .sight,
        else => null,
    };
}

pub fn mapMagicAllowed(menu_flags: u8, fe: FieldEffect) bool {
    const bit = mapFlagBitForEffect(fe) orelse return true;
    return (menu_flags & bit) != 0;
}

pub const CastResult = enum {
    ok,
    not_field_spell,
    status_block,
    no_mp,
    battle_only,
    /// Exit/Sight/Warp blocked by `$1a04` (MagicError path).
    map_flag_block,
};

pub const CastOutcome = struct {
    result: CastResult = .ok,
    /// MP to deduct (0 if failed before cost).
    mp_cost: u8 = 0,
    /// Heal amount for cure (0 if N/A).
    heal: u16 = 0,
    /// Which field effect for host apply.
    effect: ?FieldEffect = null,
    /// `$1a03` menu event for Exit/Sight/Warp (0 if N/A).
    menu_event: MenuEvent = .none,
};

/// Pure field cast gate + cure math (before party mutation).
/// `menu_flags` = `$1a04` from CheckMenu (required for exit/sight/warp).
pub fn prepareCast(
    spell_id: u8,
    mp_cost: u8,
    caster_mp: u16,
    caster_status1: u8,
    caster_will: u8,
    multi_target: bool,
    menu_flags: u8,
) CastOutcome {
    if (!isFieldUsableSpell(spell_id)) {
        // Damage spells etc. — host may say only in battle
        return .{ .result = .not_field_spell };
    }
    if (!statusAllowsCast(caster_status1, spell_id)) {
        return .{ .result = .status_block };
    }
    if (caster_mp < mp_cost) {
        return .{ .result = .no_mp, .mp_cost = mp_cost };
    }
    const fe: FieldEffect = @enumFromInt(spell_id);
    if (!mapMagicAllowed(menu_flags, fe)) {
        return .{ .result = .map_flag_block, .mp_cost = mp_cost, .effect = fe };
    }
    var out: CastOutcome = .{
        .result = .ok,
        .mp_cost = mp_cost,
        .effect = fe,
    };
    switch (fe) {
        .cure1, .cure2, .cure3, .cure4 => {
            const base = cureBaseForSpell(spell_id);
            out.heal = cureHealAmount(base, caster_will, multi_target);
        },
        .exit, .sight, .warp => {
            out.menu_event = menuEventForMapEffect(fe) orelse .none;
        },
        else => {},
    }
    return out;
}

test "field usable spell range $0E-$1B" {
    try std.testing.expect(isFieldUsableSpell(0x0E));
    try std.testing.expect(isFieldUsableSpell(0x1B));
    try std.testing.expect(!isFieldUsableSpell(0x0D));
    try std.testing.expect(!isFieldUsableSpell(0x1C));
    try std.testing.expect(!isFieldUsableSpell(0x00));
}

test "toad may only cast toad spell" {
    const toad = status_mod.Status1.toad;
    try std.testing.expect(statusAllowsCast(toad, 0x19));
    try std.testing.expect(!statusAllowsCast(toad, 0x0E));
    try std.testing.expect(statusAllowsCast(0, 0x0E));
    try std.testing.expect(statusAllowsCast(status_mod.Status1.pig, 0x1A));
    try std.testing.expect(!statusAllowsCast(status_mod.Status1.pig, 0x0E));
}

test "cureHealAmount spirit scaling" {
    // base 4, spirit 0: (16+0)*(0+1)=16
    try std.testing.expectEqual(@as(u16, 16), cureHealAmount(4, 0, false));
    // base 4, spirit 16: (16+8)*(2+1)=72
    try std.testing.expectEqual(@as(u16, 72), cureHealAmount(4, 16, false));
    // multi >> 2
    try std.testing.expectEqual(@as(u16, 18), cureHealAmount(4, 16, true));
}

test "cure bases match ROM power bytes" {
    try std.testing.expectEqual(@as(u8, 4), cureBaseForSpell(0x0E));
    try std.testing.expectEqual(@as(u8, 12), cureBaseForSpell(0x0F));
    try std.testing.expectEqual(@as(u8, 36), cureBaseForSpell(0x10));
    try std.testing.expectEqual(@as(u8, 72), cureBaseForSpell(0x11));
}

test "applyCureHp skips dead" {
    try std.testing.expectEqual(@as(u16, 0), applyCureHp(0, 100, status_mod.Status1.dead, 50));
    try std.testing.expectEqual(@as(u16, 80), applyCureHp(30, 100, 0, 50));
    try std.testing.expectEqual(@as(u16, 100), applyCureHp(90, 100, 0, 50));
}

test "esuna keeps dead clears poison toad" {
    const s1 = status_mod.Status1.poison | status_mod.Status1.toad | status_mod.Status1.dead;
    try std.testing.expectEqual(status_mod.Status1.dead, esunaStatus1(s1));
    // $7c80 hi mask: s2 & $7C — 0x4F keeps float ($40) + bits 2–3 → $4C
    try std.testing.expectEqual(@as(u8, 0x4C), esunaStatus2(0x4F));
    try std.testing.expectEqual(status_mod.Status2.float_bit, esunaStatus2(0x40));
}

test "life and float" {
    try std.testing.expectEqual(@as(u16, 50), lifeHp(100, 10));
    try std.testing.expectEqual(@as(u16, 100), lifeHp(100, 30));
    try std.testing.expectEqual(@as(u8, 0), life2ClearsDead(status_mod.Status1.dead));
    try std.testing.expectEqual(status_mod.Status2.float_bit, applyFloat(0));
}

test "toggle mini toad pig" {
    try std.testing.expectEqual(status_mod.Status1.mini, toggleStatusBit(0, mini_mask));
    try std.testing.expectEqual(@as(u8, 0), toggleStatusBit(status_mod.Status1.mini, mini_mask));
}

test "prepareCast gates" {
    const ok = prepareCast(0x0E, 3, 10, 0, 8, false, 0);
    try std.testing.expectEqual(CastResult.ok, ok.result);
    try std.testing.expect(ok.heal > 0);

    const bad = prepareCast(0x01, 5, 99, 0, 8, false, 0);
    try std.testing.expectEqual(CastResult.not_field_spell, bad.result);

    const nmp = prepareCast(0x0E, 10, 5, 0, 8, false, 0);
    try std.testing.expectEqual(CastResult.no_mp, nmp.result);
}

test "computeMenuMapFlags CheckMenu" {
    // Submap: MapProp $30 | book
    try std.testing.expectEqual(@as(u8, 0xB0), computeMenuMapFlags(true, 0x30, 0));
    try std.testing.expectEqual(@as(u8, 0x90), computeMenuMapFlags(true, 0x10, 0)); // warp only
    try std.testing.expectEqual(@as(u8, 0xA0), computeMenuMapFlags(true, 0x20, 0)); // exit only
    // OW on foot → sight
    try std.testing.expectEqual(MenuMapFlags.sight, computeMenuMapFlags(false, 0, 0));
    // Vehicle → none
    try std.testing.expectEqual(@as(u8, 0), computeMenuMapFlags(false, 0, 1));
}

test "exit sight warp map flags and menu events" {
    try std.testing.expect(!mapMagicAllowed(0, .exit));
    try std.testing.expect(mapMagicAllowed(MenuMapFlags.exit, .exit));
    try std.testing.expect(mapMagicAllowed(MenuMapFlags.sight, .sight));
    try std.testing.expect(mapMagicAllowed(MenuMapFlags.warp, .warp));

    const blocked = prepareCast(0x16, 5, 99, 0, 8, false, 0); // exit no flag
    try std.testing.expectEqual(CastResult.map_flag_block, blocked.result);

    const exit_ok = prepareCast(0x16, 5, 99, 0, 8, false, MenuMapFlags.exit);
    try std.testing.expectEqual(CastResult.ok, exit_ok.result);
    try std.testing.expectEqual(MenuEvent.exit, exit_ok.menu_event);
    try std.testing.expectEqual(@as(u8, 0x86), eventIdForMenuEvent(.exit).?);
    try std.testing.expectEqual(@as(u8, 0x87), eventIdForMenuEvent(.warp).?);
    try std.testing.expectEqual(@as(u8, 0xFB), eventIdForMenuEvent(.sight).?);
}
