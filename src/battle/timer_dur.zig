//! CalcTimerDur — battle/timer_dur.asm (action timer subset).
//!
//! Base duration (init.asm @8d7a):
//!   base = max(1, (max_agility * 50) / (agility * 10))
//!        = max(1, max_agility * 5 / agility)
//!
//! TimerDur_00 (action requeue): ApplySpeedMod(base)
//!   mod = base * speed_mod / 16  (default speed_mod = $10)
//!
//! We scale by `battle_tick_scale` so one host speed-tick ≈ ROM feel at 60Hz.
const obj_mod = @import("obj.zig");

/// Default speed modifier ($203b = $10) — ApplySpeedMod divides by 16.
pub const default_speed_mod: u16 = 16;

/// Scale ROM turn units → host action_timer counts (battle speed ~2 frames/tick).
pub const battle_tick_scale: u16 = 8;

/// Compute base timer duration for one object given battle-max agility.
pub fn baseDuration(agility: u8, max_agility: u8) u16 {
    const a: u16 = if (agility < 1) 1 else agility;
    const m: u16 = if (max_agility < 1) 1 else max_agility;
    // max*5 / agi, min 1
    const num = m *% 5;
    var base = num / a;
    if (base < 1) base = 1;
    return base;
}

/// ApplySpeedMod (timer_dur.asm @9fd8): `base * speed_mod / 16` — **can be 0** (no min).
/// TimerDur_00 then forces min 1; other types use SetTimerDur as-is (min 0).
pub fn applySpeedModRaw(base: u16, speed_mod: u16) u16 {
    const sm: u16 = if (speed_mod < 1) default_speed_mod else speed_mod;
    var d: u32 = @as(u32, base) *% sm;
    d /= 16;
    return @intCast(@min(d, 0xFFFF));
}

/// TimerDur_00 path: ApplySpeedMod then `inc` if zero (min 1).
pub fn applySpeedMod(base: u16, speed_mod: u16) u16 {
    const d = applySpeedModRaw(base, speed_mod);
    return if (d < 1) 1 else d;
}

/// Full action requeue duration in host ticks.
pub fn actionTimerTicks(agility: u8, max_agility: u8, speed_mod: u16) u16 {
    const base = baseDuration(agility, max_agility);
    const mod = applySpeedMod(base, speed_mod);
    return mod *% battle_tick_scale;
}

/// Scale CalcTimerDur ROM units → host timer counts (same as action timers).
pub fn toHostTicks(rom_units: u16) u16 {
    return rom_units *% battle_tick_scale;
}

/// Host arming: at least 1 tick so status is not instantly cleared same field.
pub fn toHostTicksArm(rom_units: u16) u16 {
    const t = toHostTicks(rom_units);
    return if (t < 1) 1 else t;
}

/// TimerDur_01 / _02: “immediate” (InitAIDelay seed `$02`, empty CmdDelay).
/// Char (`$3558` clear): base 0; mon: base 1; then ApplySpeedMod.
/// ROM ApplySpeedMod(0) → 0 (SetTimerDur allows 0). Host keeps 0 as 0.
pub fn timerDurImmediate(is_monster: bool, speed_mod: u16) u16 {
    // Char: Mult16(0, sm)/16 = 0 — do not force min 1 (unlike TimerDur_00).
    if (!is_monster) return 0;
    return applySpeedModRaw(1, speed_mod);
}

/// TimerDur_03: magic cast delay (char.asm GetCharAttack @a6a1).
/// `$397b` = spell id; AttackProp delay = byte0 low 5 (`cast_time`); base = delay×2;
/// auto-battle (`$388b`) → base 0; then ApplySpeedMod (raw, may be 0).
pub fn timerDurMagic(cast_time_5bit: u8, speed_mod: u16, auto_battle: bool) u16 {
    if (auto_battle) return applySpeedModRaw(0, speed_mod);
    const delay: u16 = cast_time_5bit & 0x1F;
    const base = delay *% 2;
    return applySpeedModRaw(base, speed_mod);
}

/// TimerDur_0b: item action delay (GetCharAttack item path).
/// ItemProp delay byte0 low 5 (vanilla all 0); same ×2 + ApplySpeedMod as magic.
pub fn timerDurItem(cast_time_5bit: u8, speed_mod: u16) u16 {
    return timerDurMagic(cast_time_5bit, speed_mod, false);
}

/// Host ticks for magic cast charge (GetCharAttack TimerDur_03).
pub fn magicCastHostTicks(cast_time_5bit: u8, speed_mod: u16, auto_battle: bool) u16 {
    return toHostTicksArm(timerDurMagic(cast_time_5bit, speed_mod, auto_battle));
}

/// Host ticks for item use charge (TimerDur_0b).
pub fn itemCastHostTicks(cast_time_5bit: u8, speed_mod: u16) u16 {
    return toHostTicksArm(timerDurItem(cast_time_5bit, speed_mod));
}

// --- Status timer durations (timer_dur.asm TimerDur_06–0a) ---
// `$3558` = target is monster (slot ≥5); `$397b` = spell power `$289d` when used.

/// TimerDur_06 / _07: poison / gradual petrify.
/// Char: `$2016` vitality + `$14`; mon: `$202f` level + `$14`; then ApplySpeedMod.
pub fn timerDurPoisonOrPetrify(is_monster: bool, mon_level: u8, vitality: u8, speed_mod: u16) u16 {
    const stat: u16 = if (is_monster) mon_level else vitality;
    const base = stat +% 0x14;
    return applySpeedModRaw(base, speed_mod);
}

/// TimerDur_08: reflect / wall (MagicEffect_09).
/// `(spell_power * 2) + $1E`, then ApplySpeedMod. `$397b` = `$289d` power.
pub fn timerDurReflect(spell_power: u8, speed_mod: u16) u16 {
    const base: u16 = (@as(u16, spell_power) *% 2) +% 0x1E;
    return applySpeedModRaw(base, speed_mod);
}

/// TimerDur_09: sap (MagicEffect_01).
/// Mon: Mult8(level, 4) + $1E; char: Mult8(intellect+spirit, 2) + $1E; ApplySpeedMod.
pub fn timerDurSap(is_monster: bool, mon_level: u8, intellect: u8, spirit: u8, speed_mod: u16) u16 {
    const product: u16 = if (is_monster)
        @as(u16, mon_level) *% 4
    else
        (@as(u16, intellect) +% @as(u16, spirit)) *% 2;
    const base = product +% 0x1E;
    return applySpeedModRaw(base, speed_mod);
}

/// TimerDur_0a: stop / magnet (MagicEffect_11).
/// Mult8(spell_power, 3) = power×3, then ApplySpeedMod (may be 0 if power 0).
pub fn timerDurStop(spell_power: u8, speed_mod: u16) u16 {
    const base: u16 = @as(u16, spell_power) *% 3;
    return applySpeedModRaw(base, speed_mod);
}

/// TimerDur_04 / _05: sleep / paralyze (MagicEffect_07).
/// Char: `$2018` spirit; mon: `$202f` level. Then `300 - 4*stat` (min 1),
/// ApplySpeedMod, then Div16 by 6.
pub fn timerDurSleepParalyze(is_monster: bool, mon_level: u8, spirit: u8, speed_mod: u16) u16 {
    const stat: u16 = if (is_monster) mon_level else spirit;
    const quad = stat *% 4;
    var base: u16 = 300; // $012C
    if (quad >= base) {
        base = 1;
    } else {
        base -%= quad;
    }
    const modded = applySpeedModRaw(base, speed_mod);
    // Div16 by 6; ROM may produce 0
    return modded / 6;
}

/// US EN CmdDelayTbl (battle_data.asm @fe89, non-REV1 LANG_EN).
/// Indexed by battle command id for TimerDur_0c.
pub const cmd_delay_tbl = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x01, // $00–$07
    0x00, 0x00, 0x04, 0x02, 0x04, 0x00, 0x81, 0x00, // $08–$0F
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, // $10–$17
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, // $18–$1F Focus2 seed $1f
    0x81, 0x00, 0x8A, // $20–$22 Twin / regen seeds
};

/// TimerDur_0c: command action delay (Focus/Twin/Regen charge).
/// `$397b` = command id; `$a9` = base timer duration from object.
/// Jump `$06` special in TimerDur_0c: base 4 then ApplySpeedMod.
/// Note: Cmd_06 Jump1 **bypasses** this and hardcodes `$d4=4` with no speed mod
/// (`cmd_special.jump1HostTicks`). This branch is only if CalcTimerDur type $0c
/// runs with `$397b=$06`.
/// delay 0 → TimerDur_01 path (immediate min 1 after ApplySpeedMod).
/// delay bit7 set → Mult16(base_timer, delay&$7f); clear → Div16(base_timer, delay) min 1.
pub fn timerDurCmdDelay(cmd_id: u8, base_timer: u16, speed_mod: u16) u16 {
    if (cmd_id == 0x06) {
        return applySpeedModRaw(4, speed_mod);
    }
    const delay: u8 = if (cmd_id < cmd_delay_tbl.len) cmd_delay_tbl[cmd_id] else 0;
    if (delay == 0) {
        // TimerDur_01: char base 0 / mon base 1 — GetCharAttack is always a party actor here → 0
        // After ApplySpeedMod raw 0. Host arms with toHostTicksArm.
        return applySpeedModRaw(0, speed_mod);
    }
    var base: u16 = undefined;
    if ((delay & 0x80) != 0) {
        const factor: u16 = delay & 0x7F;
        const bt: u16 = if (base_timer < 1) 1 else base_timer;
        base = bt *% factor;
    } else {
        const bt: u16 = if (base_timer < 1) 1 else base_timer;
        base = bt / delay;
        if (base < 1) base = 1;
    }
    return applySpeedModRaw(base, speed_mod);
}

/// Host ticks for sleep/paralyze action-timer charge (MagicEffect_07).
pub fn sleepParalyzeHostTicks(is_monster: bool, mon_level: u8, spirit: u8, speed_mod: u16) u16 {
    return toHostTicksArm(timerDurSleepParalyze(is_monster, mon_level, spirit, speed_mod));
}

/// Host ticks for Focus ($1f seed) / Twin ($20) / Regen ($22) charges via TimerDur_0c.
pub fn cmdDelayHostTicks(cmd_id: u8, base_timer: u16, speed_mod: u16) u16 {
    return toHostTicksArm(timerDurCmdDelay(cmd_id, base_timer, speed_mod));
}

/// After all objects loaded: set base_timer and initial action_timer from max agility.
pub fn initAllTimers(objs: *obj_mod.ObjTable) void {
    var max_a: u8 = 1;
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present) continue;
        if (o.agility > max_a) max_a = o.agility;
    }
    objs.max_agility = max_a;
    i = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present) continue;
        o.base_timer = baseDuration(o.agility, max_a);
        o.speed_mod = default_speed_mod;
        // Initial AT: same as requeue (init uses CalcTimerDur type 0)
        o.action_timer = actionTimerTicks(o.agility, max_a, o.speed_mod);
        o.action_ready = false;
    }
}

pub fn requeueAction(o: *obj_mod.Obj, max_agility: u8) void {
    o.action_timer = actionTimerTicks(o.agility, max_agility, o.speed_mod);
    o.action_ready = false;
    o.setDefending(false);
}

/// Apply $38d8 first-strike / surprise timer bias (init.asm @8e1d–@8e4e).
///
/// `adv` = $38d8: 0 = none; positive = first strike (party AT=1, mon ×2);
/// bit7 set = surprise (mon AT=1, party ×2). Zero after ASL becomes 2.
pub fn applyOpenerAdv(objs: *obj_mod.ObjTable, adv: u8) void {
    if (adv == 0) return;
    const first_strike = (adv & 0x80) == 0;
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present) continue;
        // ROM skips $2003 BMI (dead)
        if (o.status.isDead()) continue;
        const is_party = i < obj_mod.party_slots;
        const give_instant = if (first_strike) is_party else !is_party;
        if (give_instant) {
            o.action_timer = 1;
        } else {
            // ASL duration; if result 0 set to 2
            var t: u32 = @as(u32, o.action_timer) << 1;
            if (t == 0) t = 2;
            if (t > 0xFFFF) t = 0xFFFF;
            o.action_timer = @intCast(t);
        }
    }
}

test "base duration max_agi*5/agi" {
    const std = @import("std");
    // max=20, agi=10 → base 10; with speed_mod 16 → 10
    try std.testing.expectEqual(@as(u16, 10), baseDuration(10, 20));
    try std.testing.expectEqual(@as(u16, 1), baseDuration(99, 1));
    try std.testing.expectEqual(@as(u16, 10), applySpeedMod(10, 16));
    try std.testing.expectEqual(@as(u16, 5), applySpeedMod(10, 8));
    // Faster unit (higher agi) → shorter base
    try std.testing.expect(baseDuration(20, 20) < baseDuration(5, 20));
}

test "TimerDur_06 poison/petrify vit or level + $14 ApplySpeedMod" {
    const std = @import("std");
    // Char vit 10 → base 10+$14($14=20)=30; speed_mod $10 → 30
    try std.testing.expectEqual(@as(u16, 30), timerDurPoisonOrPetrify(false, 99, 10, 16));
    // Mon level 20 → 20+20=40
    try std.testing.expectEqual(@as(u16, 40), timerDurPoisonOrPetrify(true, 20, 0, 16));
    // speed_mod 8 → half of 30
    try std.testing.expectEqual(@as(u16, 15), timerDurPoisonOrPetrify(false, 0, 10, 8));
}

test "TimerDur_08 reflect (power*2)+$1E ApplySpeedMod" {
    const std = @import("std");
    // power 10 → 20+30=50; mod 16 → 50
    try std.testing.expectEqual(@as(u16, 50), timerDurReflect(10, 16));
    // power 0 → $1E=30
    try std.testing.expectEqual(@as(u16, 30), timerDurReflect(0, 16));
    // power 5, mod 8 → (10+30)*8/16=20
    try std.testing.expectEqual(@as(u16, 20), timerDurReflect(5, 8));
}

test "TimerDur_09 sap Mult8+level or int+spirit" {
    const std = @import("std");
    // Mon level 10 → 10*4+30=70
    try std.testing.expectEqual(@as(u16, 70), timerDurSap(true, 10, 0, 0, 16));
    // Char int 5 spirit 5 → (5+5)*2+30=50
    try std.testing.expectEqual(@as(u16, 50), timerDurSap(false, 0, 5, 5, 16));
}

test "TimerDur_0a stop power*3 ApplySpeedMod raw" {
    const std = @import("std");
    // power 10 → 30; mod 16 → 30
    try std.testing.expectEqual(@as(u16, 30), timerDurStop(10, 16));
    // power 0 → Mult8 0 → ApplySpeedMod raw 0 (SetTimerDur allows 0)
    try std.testing.expectEqual(@as(u16, 0), timerDurStop(0, 16));
    // power 8, mod 8 → 24*8/16=12
    try std.testing.expectEqual(@as(u16, 12), timerDurStop(8, 8));
}

test "toHostTicks scales by battle_tick_scale" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 30 * battle_tick_scale), toHostTicks(30));
}

test "TimerDur_04 sleep/para 300-4*spirit /6" {
    const std = @import("std");
    // Char spirit 10 → 300-40=260; mod 16 → 260; /6 = 43
    try std.testing.expectEqual(@as(u16, 43), timerDurSleepParalyze(false, 0, 10, 16));
    // Mon level 5 → 300-20=280; /6 = 46
    try std.testing.expectEqual(@as(u16, 46), timerDurSleepParalyze(true, 5, 0, 16));
    // High spirit 80 → 4*80=320 > 300 → min 1; ApplySpeedMod(1)=1; /6=0
    try std.testing.expectEqual(@as(u16, 0), timerDurSleepParalyze(false, 0, 80, 16));
}

test "TimerDur_0c Focus $1f mult 2 of base" {
    const std = @import("std");
    // CmdDelayTbl[$1f]=$82 → factor 2; base_timer 10 → 20; mod 16 → 20
    try std.testing.expectEqual(@as(u16, 20), timerDurCmdDelay(0x1F, 10, 16));
    // Twin $20 → $81 factor 1 → 10
    try std.testing.expectEqual(@as(u16, 10), timerDurCmdDelay(0x20, 10, 16));
    // Jump $06 fixed 4
    try std.testing.expectEqual(@as(u16, 4), timerDurCmdDelay(0x06, 99, 16));
    // Fight $00 delay 0 → TimerDur_01 char path base 0 → raw 0
    try std.testing.expectEqual(@as(u16, 0), timerDurCmdDelay(0x00, 10, 16));
    // Dark $05 delay $02 → 10/2=5
    try std.testing.expectEqual(@as(u16, 5), timerDurCmdDelay(0x05, 10, 16));
}

test "TimerDur_01/02 immediate InitAIDelay" {
    const std = @import("std");
    // Char base 0
    try std.testing.expectEqual(@as(u16, 0), timerDurImmediate(false, 16));
    // Mon base 1, speed_mod $10 → 1*16/16=1
    try std.testing.expectEqual(@as(u16, 1), timerDurImmediate(true, 16));
    // Mon speed_mod 8 → 1*8/16=0 (raw; host toHostTicksArm → 1)
    try std.testing.expectEqual(@as(u16, 0), timerDurImmediate(true, 8));
}

test "TimerDur_03 magic cast_time*2 ApplySpeedMod raw" {
    const std = @import("std");
    // cast_time 5 → base 10; mod 16 → 10
    try std.testing.expectEqual(@as(u16, 10), timerDurMagic(5, 16, false));
    // cast_time 0 → base 0 → raw 0
    try std.testing.expectEqual(@as(u16, 0), timerDurMagic(0, 16, false));
    // auto-battle → base 0 → raw 0
    try std.testing.expectEqual(@as(u16, 0), timerDurMagic(15, 16, true));
    // cast_time 8, mod 8 → 16*8/16=8
    try std.testing.expectEqual(@as(u16, 8), timerDurMagic(8, 8, false));
    // only low 5 bits
    try std.testing.expectEqual(@as(u16, 10), timerDurMagic(0xE5, 16, false)); // $05
}

test "TimerDur_0b item same as magic cast_time path" {
    const std = @import("std");
    try std.testing.expectEqual(timerDurMagic(3, 16, false), timerDurItem(3, 16));
    try std.testing.expectEqual(@as(u16, 0), timerDurItem(0, 16));
}

test "ApplySpeedMod TimerDur_00 min1 vs raw can be 0" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 0), applySpeedModRaw(0, 16));
    try std.testing.expectEqual(@as(u16, 1), applySpeedMod(0, 16)); // TimerDur_00 inc
    try std.testing.expectEqual(@as(u16, 10), applySpeedModRaw(10, 16));
    try std.testing.expectEqual(@as(u16, 10), applySpeedMod(10, 16));
}

test "decomp TimerDur_08 MagicEffect_09 power=$0A speed=$10" {
    const std = @import("std");
    // $289d=10 → *2 + $1E = 50; * $10 / $10 = 50
    try std.testing.expectEqual(@as(u16, 50), timerDurReflect(0x0A, 0x10));
}

test "decomp TimerDur_0a MagicEffect_11 power=$0A speed=$10" {
    const std = @import("std");
    // Mult8(10,3)=30; ApplySpeedMod → 30
    try std.testing.expectEqual(@as(u16, 30), timerDurStop(0x0A, 0x10));
}

test "applyOpenerAdv first strike party instant mon double" {
    const std = @import("std");
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0].present = true;
    objs.objs[0].action_timer = 40;
    objs.objs[5].present = true;
    objs.objs[5].is_monster = true;
    objs.objs[5].action_timer = 40;
    applyOpenerAdv(&objs, 1); // first strike
    try std.testing.expectEqual(@as(u16, 1), objs.objs[0].action_timer);
    try std.testing.expectEqual(@as(u16, 80), objs.objs[5].action_timer);
}

test "applyOpenerAdv surprise mon instant party double" {
    const std = @import("std");
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0].present = true;
    objs.objs[0].action_timer = 40;
    objs.objs[5].present = true;
    objs.objs[5].is_monster = true;
    objs.objs[5].action_timer = 40;
    applyOpenerAdv(&objs, 0x80); // surprise
    try std.testing.expectEqual(@as(u16, 80), objs.objs[0].action_timer);
    try std.testing.expectEqual(@as(u16, 1), objs.objs[5].action_timer);
}
