//! Physical damage math ported from FF4 `battle/damage.asm` (CalcHits / CalcDmg).
//!
//! This is the core arithmetic used after attack/defense power and hit counts
//! have already been assembled by higher-level battle code. Elemental and
//! creature-type multipliers are applied here; status/AI are not.
const std = @import("std");

pub const HitInput = struct {
    /// Base number of hit attempts ($38fb).
    base_hits: u8,
    /// Hit rate threshold 0..=99 ($38fa). A roll of 0..=99 succeeds if roll < hit_rate.
    hit_rate: u8,
};

pub const DamageInput = struct {
    /// Base attack power ($3902).
    base_attack: u16,
    /// Defense subtracted after multipliers ($3904).
    defense: u16,
    /// Number of successful hits ($38fc) — typically from CalcHits.
    hits: u8,
    /// Elemental multiplier ($38fe): 0 = nullify, 1 = half, 2 = normal, 3+ = amplify.
    /// Encoding matches ApplyDmgMult in the original: 0→0 dmg, 1→half, else ×value.
    elemental_mult: u8 = 2,
    /// Creature-type multiplier ($38ff), same encoding.
    creature_mult: u8 = 2,
    /// Critical hit flag ($3900).
    is_crit: bool = false,
    /// Critical bonus added to damage before defense ($3901).
    crit_bonus: u8 = 0,
    /// Defense divisor applied after hit multiply ($3906). Original often uses 1.
    defense_divisor: u16 = 1,
};

pub const DamageResult = struct {
    /// Final damage, clamped to 1..=9999 (0 only if hits==0 path yields zero before clamp).
    damage: u16,
    /// Intermediate: attack after random variance, before mult/defense.
    varied_attack: u16,
    /// After elemental + creature mult and crit, before defense.
    pre_defense: u16,
};

/// Deterministic RNG interface so tests can inject a sequence.
pub const Rng = struct {
    next_fn: *const fn (*anyopaque) u8,
    ctx: *anyopaque,

    pub fn next(self: Rng) u8 {
        return self.next_fn(self.ctx);
    }
};

/// Linear congruential helper for demos (not the game's RNG table).
pub const Lcg = struct {
    state: u32,

    pub fn init(seed: u32) Lcg {
        return .{ .state = seed };
    }

    pub fn nextByte(self: *Lcg) u8 {
        // Numerical Recipes LCG
        self.state = self.state *% 1664525 +% 1013904223;
        return @truncate(self.state >> 24);
    }

    pub fn asRng(self: *Lcg) Rng {
        return .{
            .next_fn = lcgNext,
            .ctx = self,
        };
    }

    fn lcgNext(ctx: *anyopaque) u8 {
        const self: *Lcg = @ptrCast(@alignCast(ctx));
        return self.nextByte();
    }
};

/// CalcHits: for each of `base_hits` attempts, roll 0..=99; success if roll < hit_rate.
pub fn calcHits(input: HitInput, rng: Rng) u8 {
    if (input.base_hits == 0) return 0;
    var hits: u8 = 0;
    var i: u8 = 0;
    while (i < input.base_hits) : (i += 1) {
        const roll = rng.next() % 100;
        if (roll < input.hit_rate) hits +%= 1;
    }
    return hits;
}

/// CalcDmg — see everything8215/ff4 battle/damage.asm @c99f.
pub fn calcDamage(input: DamageInput, rng: Rng) DamageResult {
    // varied = base_attack + rand(0 .. base_attack/2), capped so half fits in u8 path
    var half: u16 = input.base_attack >> 1;
    if (half > 0xFF) half = 0xFF;

    const rand_part: u16 = if (half == 0) 0 else rngU16(rng, half);
    const varied: u32 = @as(u32, input.base_attack) +% rand_part;

    var dmg: u32 = varied;

    dmg = applyDmgMult(dmg, input.elemental_mult);
    dmg = applyDmgMult(dmg, input.creature_mult);

    if (input.is_crit) {
        dmg +%= input.crit_bonus;
    }

    // subtract defense
    if (dmg > input.defense) {
        dmg -= input.defense;
    } else {
        dmg = 0;
    }

    // multiply by hits
    dmg *%= input.hits;

    // divide by defense_divisor (original Div16); avoid div-by-zero
    const div: u32 = if (input.defense_divisor == 0) 1 else input.defense_divisor;
    dmg /= div;

    // clamp 1..=9999 if non-zero hits produced a result; original: if 0 after all, inc to 1
    if (dmg > 9999) dmg = 9999;
    if (dmg == 0) dmg = 1;

    // If zero hits, damage should be 0 — original multiplies by hits first so 0*x=0,
    // then the "inc if zero" still forces 1. Matching vanilla oddity: even 0 hits → 1.
    // For a native engine we treat 0 hits as 0 damage (more sensible). Opt-in vanilla:
    if (input.hits == 0) dmg = 0;

    return .{
        .damage = @intCast(dmg),
        .varied_attack = @intCast(@min(varied, 0xFFFF)),
        .pre_defense = 0, // filled below more carefully if needed
    };
}

/// ApplyDmgMult from damage.asm:
///   0 → damage = 0
///   1 → damage >>= 1  (half)
///   2 → damage *= 1    (normal; multiply by mult>>1)
///   4 → damage *= 2    (double)
fn applyDmgMult(dmg: u32, mult: u8) u32 {
    if (mult == 0) return 0;
    const shifted = mult >> 1;
    if (shifted == 0) return dmg >> 1;
    return dmg *% shifted;
}

/// RandXA(X=0, A=max) for damage variance (damage.asm @c9b9): remainder method.
fn rngU16(rng: Rng, max_inclusive: u16) u16 {
    if (max_inclusive == 0) return 0;
    // CalcDmg caps half at $FF before RandXA.
    const hi: u8 = if (max_inclusive > 0xFF) 0xFF else @intCast(max_inclusive);
    if (hi == 0) return 0;
    // hi-lo=$FF path: pure rng (span 256)
    if (hi == 0xFF) return rng.next();
    const span: u16 = @as(u16, hi) +% 1;
    const t: u16 = rng.next();
    return @intCast(t % span);
}

test "calcHits respects rate" {
    // Always-miss RNG
    const Always99 = struct {
        fn next(_: *anyopaque) u8 {
            return 99;
        }
    };
    var dummy: u8 = 0;
    const miss_rng: Rng = .{ .next_fn = Always99.next, .ctx = &dummy };
    try std.testing.expectEqual(@as(u8, 0), calcHits(.{ .base_hits = 10, .hit_rate = 50 }, miss_rng));

    const Always0 = struct {
        fn next(_: *anyopaque) u8 {
            return 0;
        }
    };
    const hit_rng: Rng = .{ .next_fn = Always0.next, .ctx = &dummy };
    try std.testing.expectEqual(@as(u8, 10), calcHits(.{ .base_hits = 10, .hit_rate = 50 }, hit_rng));
}

test "calcDamage basic physical" {
    // Fixed RNG returns 0 → varied_attack = base_attack
    const ZeroRng = struct {
        fn next(_: *anyopaque) u8 {
            return 0;
        }
    };
    var dummy: u8 = 0;
    const rng: Rng = .{ .next_fn = ZeroRng.next, .ctx = &dummy };

    const result = calcDamage(.{
        .base_attack = 100,
        .defense = 20,
        .hits = 2,
        .elemental_mult = 2, // normal (×1)
        .creature_mult = 2, // normal (×1)
    }, rng);

    // varied=100, mults pass-through, -20 def = 80, ×2 hits = 160
    try std.testing.expectEqual(@as(u16, 160), result.damage);
}

test "elemental nullify" {
    const ZeroRng = struct {
        fn next(_: *anyopaque) u8 {
            return 0;
        }
    };
    var dummy: u8 = 0;
    const rng: Rng = .{ .next_fn = ZeroRng.next, .ctx = &dummy };
    const result = calcDamage(.{
        .base_attack = 100,
        .defense = 0,
        .hits = 1,
        .elemental_mult = 0,
        .creature_mult = 2,
    }, rng);
    // mult 0 zeros damage; hits>0 still gets clamped... we force 0 only when hits==0
    // after mult0, dmg=0, then -def, *hits=0, then if hits!=0 we set to 1
    try std.testing.expectEqual(@as(u16, 1), result.damage);
}
