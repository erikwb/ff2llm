//! ChangeBossFrame / BossTransition — btlgfx.asm @cca8 / @ccca (GfxScript $F0).
//!
//! Param byte: `ssgggggg` → mon_slot = bits 6–7, frame = bits 0–5.
//! Frame is BossGfxProp row index (DrawBoss Mult8 frame×5).
//! `$efa6` low nibble = transition type after tile transfer.
const std = @import("std");

/// Decode $F0 param (same as gfx_script.decodeBossFrame).
pub fn decodeParam(param: u8) struct { mon_slot: u8, frame: u8 } {
    return .{
        .mon_slot = param >> 6,
        .frame = param & 0x3F,
    };
}

/// BossTransition types (`$efa6 & $0F`) — btlgfx.asm @ccca.
pub const Transition = enum(u8) {
    /// 0: no transition — SwapMonsterScreen only
    none = 0,
    /// 1: pixelate mosaic in/out (7 steps × 8 frames each way)
    pixelate = 1,
    /// 2: flash + sfx `$59`
    flash = 2,
    /// 3: materialize — `$30` frames of UpdateMonsterDeathAnim
    materialize = 3,
    /// 4: flash/shake (ShakeMonster) then same as none
    shake = 4,
    /// ≥5: fallthrough `_02cc69` — treat as none on host
    other = 5,
};

pub fn transitionFromNibble(n: u8) Transition {
    return switch (n & 0x0F) {
        0 => .none,
        1 => .pixelate,
        2 => .flash,
        3 => .materialize,
        4 => .shake,
        else => .other,
    };
}

/// BossGfxProp[3] high nibble bits used as transition live in `$efa6` after DrawBoss load.
/// DrawBoss copies 5 bytes; `$efa6` is prop byte index 3.
pub fn transitionFromBossPropByte3(b3: u8) Transition {
    return transitionFromNibble(b3);
}

/// Host wait frames for each transition (decomp WaitFrame / WaitX loops).
pub fn transitionWaitFrames(t: Transition) u16 {
    return switch (t) {
        .none, .other, .shake => 0, // shake is one-shot jsl; no long wait on host
        .flash => 4, // _02be56 brief flash stand-in
        .materialize => 0x30, // @ccf1
        // 7×8 up + 7×8 down mosaic (@cd11–@cd27)
        .pixelate => 7 * 8 + 7 * 8,
    };
}

/// SFX for flash transition (BossTransition type 2 @cd06).
pub const flash_sfx: u8 = 0x59;

/// Apply ChangeBossFrame pure: store frame id for mon_slot (WRAM `$f2b4,y`).
/// `frames` is length-4 array (slots 0–3); 0xFF = unset (LoadMonsterGfx default).
pub fn applyFrame(frames: *[4]u8, mon_slot: u8, frame: u8) void {
    if (mon_slot < 4) frames[mon_slot] = frame & 0x3F;
}

/// BossGfxProp stride (5 bytes per frame row) — DrawBoss Mult8.
pub const boss_gfx_prop_stride: usize = 5;

/// File offset helper: BossGfxProp base @ 0x7CE00 (sprites.zig).
pub const boss_gfx_prop_base: usize = 0x7CE00;

/// ROM offset of BossGfxProp row for frame id.
pub fn bossGfxPropOffset(frame: u8) usize {
    return boss_gfx_prop_base + @as(usize, frame & 0x3F) * boss_gfx_prop_stride;
}

test "decodeParam slot and frame" {
    const a = decodeParam(0x03); // slot 0 frame 3
    try std.testing.expectEqual(@as(u8, 0), a.mon_slot);
    try std.testing.expectEqual(@as(u8, 3), a.frame);
    const b = decodeParam(0x85); // slot 2 frame 5
    try std.testing.expectEqual(@as(u8, 2), b.mon_slot);
    try std.testing.expectEqual(@as(u8, 5), b.frame);
    const c = decodeParam(0xC0); // slot 3 frame 0
    try std.testing.expectEqual(@as(u8, 3), c.mon_slot);
    try std.testing.expectEqual(@as(u8, 0), c.frame);
}

test "BossTransition wait frames" {
    try std.testing.expectEqual(@as(u16, 0), transitionWaitFrames(.none));
    try std.testing.expectEqual(@as(u16, 0x30), transitionWaitFrames(.materialize));
    try std.testing.expectEqual(@as(u16, 112), transitionWaitFrames(.pixelate));
    try std.testing.expectEqual(Transition.flash, transitionFromNibble(2));
    try std.testing.expectEqual(Transition.materialize, transitionFromBossPropByte3(0x03));
    try std.testing.expectEqual(Transition.pixelate, transitionFromBossPropByte3(0x21)); // low nibble 1
}

test "applyFrame stores per slot" {
    var f: [4]u8 = .{0xFF} ** 4;
    applyFrame(&f, 1, 0x12);
    try std.testing.expectEqual(@as(u8, 0x12), f[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), f[0]);
    applyFrame(&f, 9, 1); // OOB no-op
    try std.testing.expectEqual(@as(u8, 0xFF), f[0]);
}

test "bossGfxPropOffset frame*5" {
    try std.testing.expectEqual(@as(usize, 0x7CE00), bossGfxPropOffset(0));
    try std.testing.expectEqual(@as(usize, 0x7CE00 + 5), bossGfxPropOffset(1));
    try std.testing.expectEqual(@as(usize, 0x7CE00 + 5 * 0x3F), bossGfxPropOffset(0x3F));
}
