//! DoFightAnim / WeaponHitAnim / CmdAnim_00 — btlgfx/weapon.asm + cmd_anim.asm.
//!
//! CmdAnim_00 (@c6bf): StepForwardToAttack → DoFightAnim.
//! DoFightAnim (@cfb8) character path:
//!   wait step-forward complete → clear hands ≥ `$60` (shields) → DoWeaponAnim
//!   → WeaponHitAnim → clear attacker pose flags.
//! WeaponHitAnim (@d06e) vs character: if not miss PlaySfx `$2a` + CritFlash;
//!   then `$4e` 0..`$10` WaitFrame loop (16 frames) with UpdateHitCharPose.
//!
//! Host maps ROM waits to fixed frame counts (no PPU); pure phase math is decomp-derived.
const std = @import("std");
const sprites = @import("sprites.zig");

/// WeaponHitAnim frame loop `@d0c9`: `cmp #$10`.
pub const weapon_hit_frames: u8 = 0x10;

/// PlaySfx on hit (WeaponHitAnim @d09b) — system hit SFX id `$2a`.
pub const weapon_hit_sfx: u8 = 0x2A;

/// DoFightAnim @d007: item id ≥ `$60` is shield — ignore for weapon anim.
pub const shield_item_min: u8 = 0x60;

/// Host step-forward length (maps ROM wait-until `$efc5==$c0`).
pub const step_forward_frames: u8 = 8;
/// Strike hold after step (DoWeaponAnim stand-in).
pub const strike_frames: u8 = 8;
/// Step back after hit flash.
pub const step_back_frames: u8 = 8;

/// Peak attacker dx toward monsters (negative = left on host).
pub const step_forward_dx: i8 = -16;

/// SetAttackerPose ids used by cmd_anim (CharTileTbl indices).
pub const pose_fight: u8 = 0x06; // left arm up / strike
pub const pose_chant: u8 = 0x0A; // chant 1 ($0a) — magic/sing uses $0b/$0c in ROM
pub const pose_sing: u8 = 0x0B; // chant 2 / sing brace
pub const pose_magic: u8 = 0x0C; // mini ready in table — ROM uses $0c for white/black cast pose on class sheet

pub const Phase = enum {
    step_forward,
    strike,
    hit_flash,
    step_back,
    done,
};

/// Cumulative frame boundaries for party fight presentation.
pub fn phaseAt(t: u8) Phase {
    const a = step_forward_frames;
    const b = a + strike_frames;
    const c = b + weapon_hit_frames;
    const d = c + step_back_frames;
    if (t <= a) return .step_forward;
    if (t <= b) return .strike;
    if (t <= c) return .hit_flash;
    if (t <= d) return .step_back;
    return .done;
}

/// Frame within current phase (0-based).
pub fn phaseLocalT(t: u8) u8 {
    const a = step_forward_frames;
    const b = a + strike_frames;
    const c = b + weapon_hit_frames;
    return switch (phaseAt(t)) {
        .step_forward => t,
        .strike => t -% a,
        .hit_flash => t -% b,
        .step_back => t -% c,
        .done => 0,
    };
}

/// Total frames for one party fight anim (inclusive of step back).
pub fn totalPartyFightFrames() u8 {
    return step_forward_frames + strike_frames + weapon_hit_frames + step_back_frames;
}

/// Impact frame index (apply damage) — mid-strike, matches prior host t==12 with old timings.
pub fn impactFrame() u8 {
    return step_forward_frames + (strike_frames / 2);
}

/// Char pose for party fight at global time `t`.
pub fn partyFightPose(t: u8) sprites.CharPose {
    return switch (phaseAt(t)) {
        .step_forward => if (t < step_forward_frames / 2) .ready else .running,
        .strike, .hit_flash => .left_arm_up,
        .step_back => .ready,
        .done => .standing,
    };
}

/// Pixel dx for attacker during party fight.
pub fn partyFightDx(t: u8) i8 {
    return switch (phaseAt(t)) {
        .step_forward => blk: {
            // 0 → step_forward_dx over step_forward_frames
            const num: i16 = @as(i16, t) * @as(i16, step_forward_dx);
            const den: i16 = step_forward_frames;
            break :blk @intCast(@divTrunc(num, den));
        },
        .strike, .hit_flash => step_forward_dx,
        .step_back => blk: {
            const local = phaseLocalT(t);
            // step_forward_dx → 0
            const num: i16 = @as(i16, step_forward_dx) * @as(i16, step_back_frames -% local);
            break :blk @intCast(@divTrunc(num, step_back_frames));
        },
        .done => 0,
    };
}

/// DoFightAnim @d007: drop shield items from hand ids used for weapon anim.
pub fn handForWeaponAnim(item_id: u8) u8 {
    if (item_id >= shield_item_min) return 0;
    return item_id;
}

/// Prefer right hand then left (DoFightAnim loads $50 then $51).
pub fn pickWeaponItem(right_hand: u8, left_hand: u8) u8 {
    const r = handForWeaponAnim(right_hand);
    if (r != 0) return r;
    return handForWeaponAnim(left_hand);
}

/// Miss flag bit on $34c7 path: host uses bool; WeaponHitAnim skips SFX/flash when miss.
pub fn shouldPlayHitSfx(missed: bool) bool {
    return !missed;
}

/// Crit flash length host uses when crit (CritFlash stand-in).
pub fn critFlashFrames(crit: bool) u8 {
    return if (crit) 10 else 6;
}

// --- PreMagicAnim (cmd_anim.asm @c779 / magic.asm PreMagicAnim1 / btlgfx PreMagicAnim2) ---

/// PreMagicAnim id: 0 black, 1 white/sing/brace, 2 summon.
pub const PreMagicId = enum(u8) {
    black = 0,
    white = 1,
    summon = 2,
};

/// PreMagicSfxTbl @ea2c — sfx id per pre-magic kind (black/white/summon).
pub const pre_magic_sfx_tbl = [_]u8{ 0xFC, 0xFD, 0xFE };

/// PreMagicAnim2 white params (btlgfx.asm @e309): angle mask, max stage, radius target.
pub const pre_magic_white = struct {
    pub const angle_mask: u8 = 0x07; // `$f11b`
    pub const max_stage: u8 = 0x05; // `$f11c`
    pub const radius_target: u8 = 0x14; // `$f118`
    pub const polar_step_every: u8 = 0; // `$f116` 0 = IncPolarAngle every frame
    pub const pal_effect: u8 = 0xAE;
};

/// PreMagicAnim2 summon params (btlgfx.asm @e31f).
pub const pre_magic_summon = struct {
    pub const angle_mask: u8 = 0x03;
    pub const max_stage: u8 = 0x08;
    pub const radius_target: u8 = 0xFF; // hold full radius
    pub const polar_step_every: u8 = 0x08; // `$f116` nonzero skips per-frame angle spin
    pub const pal_effect: u8 = 0x9E;
};

/// SFX id for PreMagicAnim1 (magic.asm @ea2f).
pub fn preMagicSfx(kind: PreMagicId) u8 {
    return pre_magic_sfx_tbl[@intFromEnum(kind)];
}

/// SetAttackerPose before PreMagicAnim for white/black (cmd_anim #$0c).
/// Host CharPose: chant1 for cast lead-in.
pub fn preMagicPose(kind: PreMagicId) sprites.CharPose {
    return switch (kind) {
        .black, .white => .chant1,
        .summon => .chant2,
    };
}

/// Frame count for PreMagicAnim2 loop (btlgfx @e375):
/// each frame: `f114++`; when `(f114 & mask)==0` then `f115++`; stop when `f115 == max_stage`.
/// Stages advance every `(mask+1)` frames starting after first wrap → `max_stage * (mask+1)`.
/// Black only runs PreMagicAnim1 (AnimScript); use short host wait.
pub fn preMagicWaitFrames(kind: PreMagicId) u8 {
    return switch (kind) {
        .black => 16, // PreMagicAnim1 ExecAnimScript stand-in
        .white => pre_magic_white.max_stage *% (pre_magic_white.angle_mask +% 1), // 5*8=40
        .summon => pre_magic_summon.max_stage *% (pre_magic_summon.angle_mask +% 1), // 8*4=32
    };
}

/// CmdAnim id → PreMagicAnim parameter (cmd_anim.asm).
/// `$02` white → 1, `$03` black → 0, `$08`/`$0f` sing/brace → 1, summon cmds → 2.
pub fn preMagicForCmd(cmd: u8) ?PreMagicId {
    return switch (cmd) {
        0x02 => .white, // white magic
        0x03 => .black, // black magic
        0x04 => .summon, // call / summon
        0x08, 0x0F => .white, // sing / brace
        else => null,
    };
}

test "WeaponHitAnim is 16 frames" {
    try std.testing.expectEqual(@as(u8, 0x10), weapon_hit_frames);
}

test "shield items cleared for weapon anim" {
    try std.testing.expectEqual(@as(u8, 0), handForWeaponAnim(0x60));
    try std.testing.expectEqual(@as(u8, 0), handForWeaponAnim(0x7F));
    try std.testing.expectEqual(@as(u8, 0x17), handForWeaponAnim(0x17));
    try std.testing.expectEqual(@as(u8, 0x17), pickWeaponItem(0x60, 0x17));
    try std.testing.expectEqual(@as(u8, 0x01), pickWeaponItem(0x01, 0x02));
}

test "party fight phases span step+strike+hit+back" {
    try std.testing.expect(phaseAt(0) == .step_forward);
    try std.testing.expect(phaseAt(step_forward_frames) == .step_forward);
    try std.testing.expect(phaseAt(step_forward_frames + 1) == .strike);
    const hit_start = step_forward_frames + strike_frames + 1;
    try std.testing.expect(phaseAt(hit_start) == .hit_flash);
    const back_start = step_forward_frames + strike_frames + weapon_hit_frames + 1;
    try std.testing.expect(phaseAt(back_start) == .step_back);
    try std.testing.expect(phaseAt(totalPartyFightFrames() + 1) == .done);
    try std.testing.expectEqual(@as(u8, 40), totalPartyFightFrames()); // 8+8+16+8
}

test "impact during strike phase" {
    const imp = impactFrame();
    try std.testing.expect(phaseAt(imp) == .strike);
}

test "dx ends at 0 after step back" {
    try std.testing.expectEqual(@as(i8, 0), partyFightDx(0));
    try std.testing.expectEqual(step_forward_dx, partyFightDx(step_forward_frames + 1));
    try std.testing.expectEqual(@as(i8, 0), partyFightDx(totalPartyFightFrames() + 1));
}

test "PreMagicAnim cmd mapping" {
    try std.testing.expect(preMagicForCmd(0x03).? == .black);
    try std.testing.expect(preMagicForCmd(0x02).? == .white);
    try std.testing.expect(preMagicForCmd(0x04).? == .summon);
    try std.testing.expect(preMagicForCmd(0x00) == null);
    try std.testing.expect(preMagicPose(.black) == .chant1);
    try std.testing.expectEqual(@as(u8, 32), preMagicWaitFrames(.summon));
    try std.testing.expectEqual(@as(u8, 40), preMagicWaitFrames(.white));
    try std.testing.expectEqual(@as(u8, 0xFC), preMagicSfx(.black));
    try std.testing.expectEqual(@as(u8, 0xFD), preMagicSfx(.white));
    try std.testing.expectEqual(@as(u8, 0xFE), preMagicSfx(.summon));
}

test "miss skips hit sfx" {
    try std.testing.expect(shouldPlayHitSfx(false));
    try std.testing.expect(!shouldPlayHitSfx(true));
}
