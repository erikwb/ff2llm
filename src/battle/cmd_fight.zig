//! Cmd_00 / DoFightCmd — battle/fight.asm physical attack path.
//!
//! Ports: hit rate (blind/row), CalcHits vs defense hits, elemental mult,
//! crit, weapon status inflict (ApplyAttackStatus subset).
const damage = @import("damage.zig");
const obj_mod = @import("obj.zig");
const status_mod = @import("status.zig");

pub const FightResult = struct {
    damage: u16,
    hits: u8,
    missed: bool,
    crit: bool,
    target_died: bool,
    /// Status1 bits newly applied (for messages).
    status_s1: u8 = 0,
    status_s2: u8 = 0,
};

/// Elemental damage mult from fight.asm @c62c–@c685 → units of ½× (2 = 1×).
fn elementalMult(atk_elem: u8, tgt: *const obj_mod.Obj) u8 {
    if (atk_elem == 0) return 2;
    if ((atk_elem & tgt.very_weak_elem) != 0) return 8; // 4×
    if ((atk_elem & tgt.weak_elem) != 0) return 4; // 2×
    if ((atk_elem & tgt.immune_elem) != 0) return 0; // 0×
    if ((atk_elem & tgt.strong_elem) != 0) return 1; // ½×
    return 2; // 1×
}

pub const FightOpts = struct {
    /// Cmd_0c Aim: max hit rate, zero target defense hits (except image/barrier).
    aim: bool = false,
    /// $3881 monsters invincible — mon targets force miss (fight.asm @c623).
    mon_invincible: bool = false,
};

/// CalcHits + CalcDmg + status (no HP write until impact if animating).
/// `target` is mutable so Image can be consumed (fight.asm @c59f).
pub fn calcFight(
    attacker: *const obj_mod.Obj,
    target: *obj_mod.Obj,
    rng: damage.Rng,
) FightResult {
    return calcFightEx(attacker, target, rng, .{});
}

pub fn calcFightEx(
    attacker: *const obj_mod.Obj,
    target: *obj_mod.Obj,
    rng: damage.Rng,
    opts: FightOpts,
) FightResult {
    // --- hit rate setup (fight.asm @c4fb–@c55b) — raw rates, no invented defaults ---
    var hit_rate: u8 = attacker.hit_rate;
    if (opts.aim) hit_rate = 99;
    if (attacker.status.isBlind()) hit_rate /= 2;
    if (attacker.row != 0 and !attacker.no_row_penalty and !attacker.jumping()) {
        hit_rate /= 2;
    }
    if (target.row != 0 and !attacker.no_row_penalty and !attacker.jumping()) {
        hit_rate /= 2;
    }
    if (!attacker.is_monster and attacker.slot_index == 0) {
        // +25% via *5/4 (fight.asm @c526) — result may exceed 99; CalcHits uses raw
        const bonus: u16 = @as(u16, hit_rate) * 5 / 4;
        hit_rate = @intCast(@min(bonus, 255));
    }

    // Attack multiplier ($269b) — CalcHits returns 0 if base_hits==0
    const base_hits: u8 = attacker.attack_mult;

    const atk_hits = damage.calcHits(.{
        .base_hits = base_hits,
        .hit_rate = hit_rate,
    }, rng);

    // Defense hits (fight.asm @c579–@c5ea)
    // Barrier first: 255 def hits, no image peel. Else image: peel 1 charge → 255 def.
    // Aim (Cmd_0c): force def hits 0 (ROM clears $2729).
    var def_hits: u8 = 0;
    if (target.status.hasBarrier()) {
        def_hits = 255;
    } else if (target.status.imageCharges() > 0) {
        target.status.consumeImage();
        def_hits = 255;
    } else if (!opts.aim) {
        var def_rate: u8 = target.defense_rate; // raw; 0 → always 0 def hits
        if (target.status.isBlind()) def_rate /= 2;
        // Party slot 0: defense rate +25% (fight.asm @c5af)
        if (!target.is_monster and target.slot_index == 0) {
            const bonus: u16 = @as(u16, def_rate) * 5 / 4;
            def_rate = @intCast(@min(bonus, 255));
        }
        var def_mult: u8 = target.defense_mult;
        if (target.status.isToadMini()) def_mult = 0;
        def_hits = if (def_mult == 0) 0 else damage.calcHits(.{
            .base_hits = def_mult,
            .hit_rate = def_rate,
        }, rng);
    }

    // Mon invincible ($3881): nonzero hits path still aborts for mon targets (fight.asm @c623)
    if (opts.mon_invincible and target.is_monster) {
        return .{
            .damage = 0,
            .hits = 0,
            .missed = true,
            .crit = false,
            .target_died = false,
        };
    }

    const net: i16 = @as(i16, atk_hits) - @as(i16, def_hits);
    if (net <= 0) {
        return .{
            .damage = 0,
            .hits = 0,
            .missed = true,
            .crit = false,
            .target_died = false,
        };
    }
    const hits: u8 = @intCast(@min(net, 255));

    // Defense rate for status inflict roll (fight.asm @c819 — raw, no invent)
    var def_rate: u8 = target.defense_rate;
    if (target.status.isBlind()) def_rate /= 2;

    // --- attack power / defense (fight.asm @c6e4–@c75f) ---
    var atk: u16 = attacker.attack;
    var def: u16 = target.defense;
    // Jump ($2005 bit1) or Focus (bit3): attack power +100% (fight.asm @c6d7 and #$0a)
    if (attacker.jumping() or attacker.status.isFocusing()) atk *%= 2;
    if (attacker.status.isToadMini()) atk = 1; // fight.asm toad/mini attacker
    if (target.row != 0) def *%= 2;
    if (target.status.isDefending()) def *%= 2;
    // Target focusing: defense -100% (fight.asm @c730 LSR defense)
    if (target.status.isFocusing()) def /= 2;
    if (target.status.isToadMini()) def = 0;

    // Berserk: attack * 1.5 (fight.asm @c6d7)
    if (attacker.status.isBerserk()) {
        atk = atk +% atk / 2;
    }

    var crit = false;
    var crit_bonus: u8 = 0;
    if (attacker.crit_rate > 0) {
        const roll = rng.next() % 100;
        if (roll < attacker.crit_rate) {
            crit = true;
            crit_bonus = attacker.crit_bonus;
        }
    }

    const elem_u = elementalMult(attacker.attack_element, target);
    // Creature mult $38ff (fight.asm @c685): default 2 (1×).
    // Char→mon: attack creature bits ($269a) ∩ mon type ($2740) → 8 (4×).
    // Mon→char: mon type ∩ char creature def ($2727) → 1 (½×).
    const creature_u: u8 = blk: {
        if (!attacker.is_monster and target.is_monster) {
            if (attacker.creature_atk != 0 and (attacker.creature_atk & target.creature_type) != 0)
                break :blk 8;
        } else if (attacker.is_monster and !target.is_monster) {
            if (attacker.creature_type != 0 and (attacker.creature_type & target.creature_def) != 0)
                break :blk 1;
        }
        break :blk 2;
    };
    const res = damage.calcDamage(.{
        .base_attack = atk,
        .defense = def,
        .hits = hits,
        .elemental_mult = elem_u,
        .creature_mult = creature_u,
        .is_crit = crit,
        .crit_bonus = crit_bonus,
        .defense_divisor = 1,
    }, rng);

    // Status inflict (fight.asm @c819) — separate hit roll using attack hits as mult
    var got_s1: u8 = 0;
    var got_s2: u8 = 0;
    if (res.damage > 0 and (attacker.inflict_s1 != 0 or attacker.inflict_s2 != 0) and !target.is_boss) {
        const rate_diff: i16 = @as(i16, attacker.hit_rate) - @as(i16, def_rate);
        if (rate_diff > 0) {
            const st_hits = damage.calcHits(.{
                .base_hits = hits,
                .hit_rate = @intCast(@min(rate_diff, 99)),
            }, rng);
            if (st_hits > 0) {
                // Apply would mutate; report bits that would apply
                const a1 = attacker.inflict_s1 & ~target.immune_s1;
                const a2 = attacker.inflict_s2 & ~target.immune_s2;
                if ((target.status.s1 & a1) != a1) got_s1 = a1;
                if ((target.status.s2 & a2) != a2) got_s2 = a2;
            }
        }
    }

    return .{
        .damage = res.damage,
        .hits = hits,
        .missed = false,
        .crit = crit,
        .target_died = target.hp <= res.damage,
        .status_s1 = got_s1,
        .status_s2 = got_s2,
    };
}

/// Cmd_0e Kick / Cmd_05 Dark Wave — DoMultiAttack.
/// `full_power`: Dark Wave keeps full mult; Kick halves mult ($c1==0).
pub fn doMultiAttack(
    attacker: *const obj_mod.Obj,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    full_power: bool,
    out_slots: *[8]usize,
    out_dmgs: *[8]u16,
) u8 {
    var n: u8 = 0;
    const mult: u16 = if (attacker.attack_mult == 0) 1 else attacker.attack_mult;
    var hits_m: u16 = if (full_power) mult else mult / 2;
    if (hits_m < 1) hits_m = 1;
    var base: u32 = (@as(u32, attacker.attack) *% hits_m) / 2;
    if (base < 1) base = 1;

    var i: usize = obj_mod.party_slots;
    while (i < obj_mod.total_slots and n < 8) : (i += 1) {
        const t = objs.get(i);
        if (!t.present or t.hp == 0 or t.status.isKo()) continue;
        if (t.status.isHidden() or t.status.isJumping()) continue;
        var dmg: u32 = base +% (rng.next() % @max(1, attacker.attack));
        // Kick subtracts mon defense × mult; Dark Wave also (when $c1==0 path).
        // Dark full_power still applies defense sub in ROM for non-c1 path.
        if (!full_power) {
            const sub: u32 = (@as(u32, t.defense) *% hits_m) / 2;
            if (dmg > sub) dmg -= sub else dmg = 1;
        } else {
            // Dark Wave: quarter damage vs undead ($2040 bit7) — fight.asm multi path
            if ((t.creature_type & 0x80) != 0) {
                dmg = @max(1, dmg / 4);
            }
        }
        if (dmg > 9999) dmg = 9999;
        const d: u16 = @intCast(dmg);
        if (t.hp > d) t.hp -= d else {
            t.hp = 0;
            t.status.setDead();
        }
        out_slots[n] = i;
        out_dmgs[n] = d;
        n += 1;
    }
    return n;
}

pub fn doKick(
    attacker: *const obj_mod.Obj,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    out_slots: *[8]usize,
    out_dmgs: *[8]u16,
) u8 {
    return doMultiAttack(attacker, objs, rng, false, out_slots, out_dmgs);
}

pub fn doDarkWave(
    attacker: *const obj_mod.Obj,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    out_slots: *[8]usize,
    out_dmgs: *[8]u16,
) u8 {
    return doMultiAttack(attacker, objs, rng, true, out_slots, out_dmgs);
}

/// Apply HP damage + status + clear charm on hit (DoFightCmd apply path).
/// Image peel already done in calcFight when applicable.
pub fn applyFightResult(target: *obj_mod.Obj, fr: FightResult) void {
    if (fr.missed or fr.damage == 0) return;
    if (target.hp > fr.damage) target.hp -= fr.damage else {
        target.hp = 0;
        target.status.setDead();
    }
    target.status.clearCharm();
    if (fr.status_s1 != 0) {
        if (target.status.applyStatus1(fr.status_s1, target.immune_s1)) {
            if ((fr.status_s1 & status_mod.Status1.poison) != 0)
                @import("timer.zig").armPoison(target);
        }
    }
    if (fr.status_s2 != 0) _ = target.status.applyStatus2(fr.status_s2, target.immune_s2);
}

pub fn doFight(
    attacker: *obj_mod.Obj,
    target: *obj_mod.Obj,
    rng: damage.Rng,
) FightResult {
    const fr = calcFight(attacker, target, rng);
    applyFightResult(target, fr);
    return .{
        .damage = fr.damage,
        .hits = fr.hits,
        .missed = fr.missed,
        .crit = fr.crit,
        .target_died = target.hp == 0,
        .status_s1 = fr.status_s1,
        .status_s2 = fr.status_s2,
    };
}
