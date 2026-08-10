//! DecTimers / GetPendingAction / DoTimerEffect — battle.asm + timer.asm.
//!
//! Timers (subset of $29eb enable bits + $2a04 duration):
//!   action, stop, sap, poison, petrify (gradual), reflect, doom
//!
//! Poison damage (TimerEffect_03): max_hp >> 3, min 1; reload stored duration.
const obj_mod = @import("obj.zig");
const status_mod = @import("status.zig");
const timer_dur = @import("timer_dur.zig");

pub const TickResult = struct {
    /// Slot that took poison/sap/doom damage this tick (for floaters).
    dmg_slot: ?usize = null,
    dmg_amount: u16 = 0,
    dmg_kind: enum { none, poison, sap, doom } = .none,
    /// Slot that landed from jump this tick.
    jump_land_slot: ?usize = null,
};

/// Host ticks from TimerDur_06/07 (poison / petrify) — InitPoison / MagicEffect_17.
fn poisonPetrifyHostTicks(o: *const obj_mod.Obj) u16 {
    const rom = timer_dur.timerDurPoisonOrPetrify(o.is_monster, o.level, o.vitality, o.speed_mod);
    return timer_dur.toHostTicksArm(rom);
}

/// Enable poison timer when poison status applied (magic.asm / init.asm InitPoison).
pub fn armPoison(o: *obj_mod.Obj) void {
    const t = poisonPetrifyHostTicks(o);
    o.poison_reload = t;
    o.poison_timer = t;
}

/// MagicEffect_11: stop — TimerDur_0a (spell power ×3 + ApplySpeedMod).
pub fn armStop(o: *obj_mod.Obj, spell_power: u8) void {
    o.status.setStop(true);
    const rom = timer_dur.timerDurStop(spell_power, o.speed_mod);
    o.stop_timer = timer_dur.toHostTicksArm(rom);
    o.action_ready = false;
}

/// MagicEffect_01 sap — TimerDur_09.
pub fn armSap(o: *obj_mod.Obj) void {
    o.status.setSap(true);
    const rom = timer_dur.timerDurSap(o.is_monster, o.level, o.intellect, o.spirit, o.speed_mod);
    const t = timer_dur.toHostTicksArm(rom);
    o.sap_reload = t;
    o.sap_timer = t;
}

pub fn armDoom(o: *obj_mod.Obj, counts: u16) void {
    o.doom_timer = if (counts < 1) 1 else counts;
}

/// Gradual petrify — TimerDur_07 (same formula as poison).
pub fn armPetrify(o: *obj_mod.Obj) void {
    const t = poisonPetrifyHostTicks(o);
    o.petrify_reload = t;
    o.petrify_timer = t;
}

/// MagicEffect_09 reflect/wall — TimerDur_08: (power×2)+$1E + ApplySpeedMod.
pub fn armReflect(o: *obj_mod.Obj, spell_power: u8) void {
    o.status.setReflect(true);
    const rom = timer_dur.timerDurReflect(spell_power, o.speed_mod);
    o.reflect_timer = timer_dur.toHostTicksArm(rom);
}

/// MagicEffect_07: sleep/paralyze arms **action timer** with TimerDur_04 (not a separate timer).
/// Status bits must already be set; duration expires → TimerEffect_01 clear on action ready.
pub fn armSleepParalyze(o: *obj_mod.Obj) void {
    o.action_timer = timer_dur.sleepParalyzeHostTicks(o.is_monster, o.level, o.spirit, o.speed_mod);
    o.action_ready = false;
}

/// Decrement all timers one battle-speed tick. Applies poison/sap/doom effects.
pub fn decTimers(objs: *obj_mod.ObjTable) TickResult {
    var result: TickResult = .{};
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present or o.hp == 0) continue;

        // Stop: freeze action; expire clears stop
        if (o.status.isStopped()) {
            if (o.stop_timer > 0) {
                o.stop_timer -= 1;
                if (o.stop_timer == 0) {
                    o.status.setStop(false);
                }
            }
            continue; // no other timers while stopped (battle.asm @96a2)
        }

        // Jump land
        if (o.status.isJumping() and o.jump_timer > 0) {
            o.jump_timer -= 1;
            if (o.jump_timer == 0) {
                result.jump_land_slot = i;
            }
        }

        // Action timer
        if (!o.action_ready and !o.status.isJumping()) {
            if (o.action_timer > 0) {
                o.action_timer -= 1;
                if (o.action_timer == 0) {
                    o.action_ready = true;
                    // TimerEffect_01: clear sleep/paralyze when action comes up
                    o.status.clearSleepParalyze();
                }
            } else {
                o.action_ready = true;
            }
        }

        // Poison (TimerEffect_03): max_hp/8 min 1; skip jump/hide
        if (o.status.isPoison() and !o.status.isJumping() and !o.status.isHidden()) {
            if (o.poison_timer > 0) o.poison_timer -= 1;
            if (o.poison_timer == 0) {
                var dmg: u16 = o.max_hp >> 3;
                if (dmg < 1) dmg = 1;
                if (o.hp > dmg) o.hp -= dmg else {
                    o.hp = 0;
                    o.status.setDead();
                }
                o.poison_timer = if (o.poison_reload > 0) o.poison_reload else poisonPetrifyHostTicks(o);
                if (result.dmg_slot == null) {
                    result.dmg_slot = i;
                    result.dmg_amount = dmg;
                    result.dmg_kind = .poison;
                }
            }
        }

        // Sap timer expire (TimerEffect_02): clear sap only — damage is SapRegenEffect (2 HP).
        if (o.status.isSapped()) {
            if (o.sap_timer > 0) o.sap_timer -= 1;
            if (o.sap_timer == 0) {
                o.status.setSap(false);
                o.sap_reload = 0;
            }
        }

        // Doom: count down to death
        if (o.doom_timer > 0) {
            o.doom_timer -= 1;
            if (o.doom_timer == 0) {
                o.hp = 0;
                o.status.setDead();
                if (result.dmg_slot == null) {
                    result.dmg_slot = i;
                    result.dmg_amount = 0;
                    result.dmg_kind = .doom;
                }
            }
        }

        // Gradual petrify (TimerEffect_04): stages 1..3 then stone
        if (o.petrify_timer > 0 and !o.status.isJumping()) {
            o.petrify_timer -= 1;
            if (o.petrify_timer == 0) {
                const stoned = o.status.advancePetrify();
                if (!stoned) {
                    o.petrify_timer = if (o.petrify_reload > 0) o.petrify_reload else poisonPetrifyHostTicks(o);
                }
            }
        }

        // Reflect expire (TimerEffect_05)
        if (o.status.hasReflect() and o.reflect_timer > 0) {
            o.reflect_timer -= 1;
            if (o.reflect_timer == 0) o.status.setReflect(false);
        }
    }
    return result;
}

/// SapRegenEffect sap half (timer.asm @aa13): fixed 2 HP if sap active, not KO/stop/jump/hide.
/// Returns first damaged slot + amount for floater (one report).
pub fn sapRegenTick(objs: *obj_mod.ObjTable) TickResult {
    var result: TickResult = .{};
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present or !o.status.isSapped()) continue;
        if (o.status.isKo() or o.status.isStopped() or o.status.isJumping() or o.status.isHidden()) continue;
        const dmg: u16 = 2;
        if (o.hp > dmg) o.hp -= dmg else {
            o.hp = 0;
            o.status.setDead();
        }
        if (result.dmg_slot == null) {
            result.dmg_slot = i;
            result.dmg_amount = dmg;
            result.dmg_kind = .sap;
        }
    }
    return result;
}

/// Party regen heal (SapRegenEffect @aaa3): +amount HP to each living party member.
pub fn partyRegenHeal(objs: *obj_mod.ObjTable, amount: u8) void {
    if (amount == 0) return;
    var i: usize = 0;
    while (i < obj_mod.party_slots) : (i += 1) {
        const o = objs.get(i);
        if (!o.present or o.status.isKo()) continue;
        const add: u16 = amount;
        const nh = o.hp +% add;
        o.hp = if (nh > o.max_hp) o.max_hp else nh;
    }
}

/// Critical HP: hp < max_hp/4 (damage.asm @caf6).
pub fn isCriticalHp(hp: u16, max_hp: u16) bool {
    if (max_hp == 0) return false;
    return hp < (max_hp >> 2);
}

test "critical hp threshold max/4" {
    const std = @import("std");
    try std.testing.expect(isCriticalHp(24, 100));
    try std.testing.expect(!isCriticalHp(25, 100));
    try std.testing.expect(!isCriticalHp(0, 0));
}

test "poison dmg is max_hp/8 min 1; stop freezes other timers" {
    const std = @import("std");
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0] = .{
        .present = true,
        .hp = 100,
        .max_hp = 80,
        .poison_timer = 1,
        .poison_reload = 10,
        .action_timer = 5,
        .action_ready = false,
    };
    objs.objs[0].status.s1 |= status_mod.Status1.poison;
    const r = decTimers(&objs);
    try std.testing.expectEqual(@as(u16, 10), r.dmg_amount); // 80>>3
    try std.testing.expect(r.dmg_kind == .poison);
    try std.testing.expectEqual(@as(u16, 90), objs.objs[0].hp);

    // Stop: skip poison and action (battle.asm @96a2 path / host continue)
    objs.objs[1] = .{
        .present = true,
        .hp = 50,
        .max_hp = 50,
        .stop_timer = 2,
        .poison_timer = 1,
        .action_timer = 3,
        .action_ready = false,
    };
    objs.objs[1].status.setStop(true);
    objs.objs[1].status.s1 |= status_mod.Status1.poison;
    _ = decTimers(&objs);
    try std.testing.expectEqual(@as(u8, 1), objs.objs[1].stop_timer);
    try std.testing.expectEqual(@as(u16, 50), objs.objs[1].hp); // no poison while stopped
    try std.testing.expectEqual(@as(u16, 3), objs.objs[1].action_timer);
}

test "sap regen fixed 2" {
    const std = @import("std");
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0].present = true;
    objs.objs[0].hp = 50;
    objs.objs[0].max_hp = 50;
    objs.objs[0].status.setSap(true);
    const r = sapRegenTick(&objs);
    try std.testing.expectEqual(@as(u16, 48), objs.objs[0].hp);
    try std.testing.expectEqual(@as(u16, 2), r.dmg_amount);
    try std.testing.expect(r.dmg_slot != null);
}

test "armReflect TimerDur_08 power*2+$1E host ticks" {
    const std = @import("std");
    var o: obj_mod.Obj = .{ .present = true, .speed_mod = 16 };
    armReflect(&o, 10);
    // ROM 50 * battle_tick_scale
    try std.testing.expectEqual(@as(u16, 50 * timer_dur.battle_tick_scale), o.reflect_timer);
    try std.testing.expect(o.status.hasReflect());
}

test "armStop TimerDur_0a power*3 host ticks" {
    const std = @import("std");
    var o: obj_mod.Obj = .{ .present = true, .speed_mod = 16 };
    armStop(&o, 10);
    try std.testing.expectEqual(@as(u16, 30 * timer_dur.battle_tick_scale), o.stop_timer);
    try std.testing.expect(o.status.isStopped());
    try std.testing.expect(!o.action_ready);
}

test "armPoison TimerDur_06 vitality+$14 mon uses level" {
    const std = @import("std");
    var party: obj_mod.Obj = .{
        .present = true,
        .is_monster = false,
        .vitality = 10,
        .level = 99,
        .speed_mod = 16,
    };
    armPoison(&party);
    // vit 10 + $14 = 30 ROM units
    try std.testing.expectEqual(@as(u16, 30 * timer_dur.battle_tick_scale), party.poison_timer);
    try std.testing.expectEqual(party.poison_timer, party.poison_reload);

    var mon: obj_mod.Obj = .{
        .present = true,
        .is_monster = true,
        .level = 20,
        .vitality = 1,
        .speed_mod = 16,
    };
    armPoison(&mon);
    // level 20 + $14 ($14=20) = 40
    try std.testing.expectEqual(@as(u16, 40 * timer_dur.battle_tick_scale), mon.poison_timer);
}

test "armSap TimerDur_09 mon level*4+$1E" {
    const std = @import("std");
    var mon: obj_mod.Obj = .{
        .present = true,
        .is_monster = true,
        .level = 10,
        .speed_mod = 16,
    };
    armSap(&mon);
    // 10*4+30=70
    try std.testing.expectEqual(@as(u16, 70 * timer_dur.battle_tick_scale), mon.sap_timer);
    try std.testing.expect(mon.status.isSapped());
}

test "armSleepParalyze TimerDur_04 sets action timer" {
    const std = @import("std");
    var o: obj_mod.Obj = .{
        .present = true,
        .spirit = 10,
        .speed_mod = 16,
        .action_ready = true,
        .action_timer = 0,
    };
    armSleepParalyze(&o);
    // (300-40)/6 = 43 ROM units
    try std.testing.expectEqual(@as(u16, 43 * timer_dur.battle_tick_scale), o.action_timer);
    try std.testing.expect(!o.action_ready);
}

/// Scan from `start_slot` for next ready object (wraps). Skips stopped/jumping/KO.
pub fn getPendingAction(objs: *obj_mod.ObjTable, start_slot: usize) ?usize {
    var checked: usize = 0;
    var s = start_slot % obj_mod.total_slots;
    while (checked < obj_mod.total_slots) : (checked += 1) {
        const o = objs.get(s);
        if (o.present and o.hp > 0 and !o.status.isKo() and o.action_ready and o.status.canAct())
            return s;
        // Jump land is handled as special pending in host via jump_timer
        if (o.present and o.status.isJumping() and o.jump_timer == 0)
            return s;
        s += 1;
        if (s >= obj_mod.total_slots) s = 0;
    }
    return null;
}
