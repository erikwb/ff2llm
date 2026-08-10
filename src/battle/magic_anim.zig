//! DoMagicAnim / MagicAnimTbl — btlgfx/magic.asm @eac1 / @eb79.
//!
//! DoItemMagicAnim (@eac9):
//!   1. attack id 0 → rts (no anim)
//!   2. id ∈ `$4D`..`$5D` → summon path (LoadSummonGfx, hide chars, DarkenBattleBG)
//!   3. AnimProp[(id−1)×4]: pal, gfx, script ($f397), anim index
//!   4. script `$FF` → skip anim script flags
//!   5. anim `$FF` → skip MagicAnimTbl
//!   6. else jmp MagicAnimTbl[anim] (48 entries `$00`–`$2F`)
//!
//! Host cannot run full SNES AnimScript/OAM; this module resolves **decomp-faithful
//! dispatch state** (prop load, table index, presentation flags with documented waits).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const cmd_magic = @import("cmd_magic.zig");

/// MagicAnimTbl length — MagicAnim_00 .. MagicAnim_2f (@eb79).
pub const magic_anim_tbl_len: u8 = 0x30;

/// Summon attack id range (DoItemMagicAnim @eac9).
pub const summon_id_lo: u8 = 0x4D;
pub const summon_id_hi: u8 = 0x5D; // exclusive upper: cmp #$5e bcs

pub const Flags = struct {
    /// DefaultMagicAnim / MagicAnim_1c: ExecAnimScript with prop.script
    use_anim_script: bool = false,
    /// MagicAnim_00 / ReflectMagicAnim second pass
    reflect_pass: bool = false,
    /// SelfTargetMagicAnim family
    self_target: bool = false,
    /// DarkenBattleBG
    darken_bg: bool = false,
    /// LightenBattleBG (after darken)
    lighten_bg: bool = false,
    /// FlashScreen* (white/red/etc.)
    screen_flash: bool = false,
    /// PlayMagicSfx
    play_magic_sfx: bool = false,
    /// WaitX frames inside the MagicAnim_* body (host hold)
    wait_frames: u8 = 0,
    /// $f320 hide character sprites (summon path @eac9)
    hide_chars: bool = false,
};

/// Resolved DoMagicAnim presentation plan for one attack id.
pub const Present = struct {
    attack_id: u8 = 0,
    /// Loaded AnimProp (decomp index id−1). Empty if id==0.
    prop: cmd_magic.AnimProp = .{},
    /// True when MagicAnimTbl is entered (anim ≠ $FF and id ≠ 0).
    run_tbl: bool = false,
    /// MagicAnimTbl index 0..$2F (prop.anim).
    anim_index: u8 = 0xFF,
    is_summon: bool = false,
    flags: Flags = .{},
};

/// True if attack id uses summon branch (DoItemMagicAnim @eac9).
pub fn isSummonAttackId(id: u8) bool {
    return id >= summon_id_lo and id < 0x5E;
}

/// Host presentation flags for one MagicAnimTbl index (decomp MagicAnim_00..2f).
/// Full OAM/AnimScript residual; waits/sfx/flash/darken match routine structure.
pub fn flagsForAnimIndex(anim: u8) Flags {
    if (anim >= magic_anim_tbl_len) return .{};
    return switch (anim) {
        // MagicAnim_00: MagicAnim_1c + ReflectMagicAnim
        0x00 => .{ .use_anim_script = true, .reflect_pass = true, .wait_frames = 16 },
        // MagicAnim_1c: DefaultMagicAnim only (no reflect)
        0x1c => .{ .use_anim_script = true, .wait_frames = 16 },
        // MagicAnim_01/02 → setup + _02f310 → 00 path
        0x01, 0x02, 0x1b => .{ .use_anim_script = true, .reflect_pass = true, .wait_frames = 16 },
        // MagicAnim_1f self-target; 1d = 1f + 1c; 2e = self + 1c
        0x1f => .{ .self_target = true, .wait_frames = 12 },
        0x1d => .{ .self_target = true, .use_anim_script = true, .wait_frames = 16 },
        0x2e => .{ .self_target = true, .use_anim_script = true, .wait_frames = 16 },
        // MagicAnim_2f black hole: SFX + darken + flash white + WaitX 32 + lighten
        0x2f => .{
            .play_magic_sfx = true,
            .darken_bg = true,
            .screen_flash = true,
            .lighten_bg = true,
            .wait_frames = 32,
        },
        // MagicAnim_2a/2b/2c glance-style: flash + sfx
        0x2a, 0x2b, 0x2c => .{ .play_magic_sfx = true, .screen_flash = true, .wait_frames = 16 },
        // MagicAnim_2d: wait 16 + flash + script
        0x2d => .{ .play_magic_sfx = true, .screen_flash = true, .use_anim_script = true, .wait_frames = 16 },
        // MagicAnim_05 comet: MagicAnim_00 + FlashScreenRed
        0x05 => .{ .use_anim_script = true, .reflect_pass = true, .screen_flash = true, .wait_frames = 16 },
        // MagicAnim_03 teleport-ish: PlayMagicSfx
        0x03, 0x22 => .{ .play_magic_sfx = true, .wait_frames = 16 },
        // Summon-ish AfterMagicAnim family — short hold
        0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x1a => .{
            .use_anim_script = true,
            .wait_frames = 20,
        },
        // Default: most entries funnel to ExecAnimScript / MagicAnim_00/1c
        else => .{ .use_anim_script = true, .wait_frames = 16 },
    };
}

/// DoMagicAnim / DoItemMagicAnim pure resolve (magic.asm @eac1).
pub fn resolve(r: *const rom_mod.Rom, attack_id: u8) Present {
    var p: Present = .{ .attack_id = attack_id };
    if (attack_id == 0) return p; // DoMagicAnim: bne DoItemMagicAnim else rts

    p.prop = cmd_magic.AnimProp.load(r, attack_id);
    p.is_summon = isSummonAttackId(attack_id);
    if (p.is_summon) {
        p.flags.hide_chars = true;
        p.flags.darken_bg = true;
        p.flags.wait_frames = @max(p.flags.wait_frames, 24);
    }

    // AnimProp+2 script $FF → no ExecAnimScript setup (@eb51 path skip partial)
    // AnimProp+3 anim $FF → no MagicAnimTbl
    if (p.prop.anim == 0xFF) {
        // Still may flash from pal load even without tbl entry
        if (p.prop.pal != 0) p.flags.wait_frames = @max(p.flags.wait_frames, 8);
        return p;
    }

    p.run_tbl = true;
    p.anim_index = p.prop.anim;
    var f = flagsForAnimIndex(p.prop.anim);
    if (p.prop.script == 0xFF) {
        f.use_anim_script = false;
    }
    if (p.is_summon) {
        f.hide_chars = true;
        f.darken_bg = true;
        f.wait_frames = @max(f.wait_frames, 24);
    }
    p.flags = f;
    return p;
}

/// Flash frames from AnimProp pal nibble (host; LoadAnimPal intensity stand-in).
pub fn flashFromPal(pal: u8) u8 {
    if (pal == 0) return 6;
    return 4 +% (pal & 7);
}

test "MagicAnimTbl has 48 entries 0..2f" {
    try std.testing.expectEqual(@as(u8, 0x30), magic_anim_tbl_len);
    try std.testing.expect(flagsForAnimIndex(0x00).reflect_pass);
    try std.testing.expect(!flagsForAnimIndex(0x1c).reflect_pass);
    try std.testing.expectEqual(@as(u8, 32), flagsForAnimIndex(0x2f).wait_frames);
    try std.testing.expect(flagsForAnimIndex(0x2f).darken_bg);
    try std.testing.expect(flagsForAnimIndex(0x2f).lighten_bg);
    try std.testing.expect(flagsForAnimIndex(0x1f).self_target);
    try std.testing.expect(!flagsForAnimIndex(0x30).use_anim_script); // OOB empty
}

test "isSummonAttackId range $4D..$5D" {
    try std.testing.expect(!isSummonAttackId(0x4C));
    try std.testing.expect(isSummonAttackId(0x4D));
    try std.testing.expect(isSummonAttackId(0x5D));
    try std.testing.expect(!isSummonAttackId(0x5E));
}

test "DoMagicAnim id 0 is no-op" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    const p = resolve(&r, 0);
    try std.testing.expect(!p.run_tbl);
    try std.testing.expectEqual(@as(u8, 0xFF), p.prop.anim);
}

test "DoMagicAnim Fire $01 uses AnimProp index 0 and MagicAnimTbl" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    // Decomp: dec; asl2 → entry 0 for id $01
    const prop0 = cmd_magic.AnimProp.load(&r, 0x01);
    try std.testing.expectEqual(@as(u8, 0x13), prop0.pal);
    try std.testing.expectEqual(@as(u8, 0x10), prop0.gfx);
    try std.testing.expectEqual(@as(u8, 0x23), prop0.script);
    try std.testing.expectEqual(@as(u8, 0x00), prop0.anim);

    const p = resolve(&r, 0x01);
    try std.testing.expect(p.run_tbl);
    try std.testing.expectEqual(@as(u8, 0x00), p.anim_index);
    try std.testing.expect(p.flags.use_anim_script);
    try std.testing.expect(p.flags.reflect_pass);
    try std.testing.expectEqual(@as(u8, 0x23), p.prop.script);
}

test "DoMagicAnim Cure $0E AnimProp index $0D" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    const prop = cmd_magic.AnimProp.load(&r, 0x0E);
    // headerless dump: idx $0d = 08 00 16 00
    try std.testing.expectEqual(@as(u8, 0x08), prop.pal);
    try std.testing.expectEqual(@as(u8, 0x00), prop.gfx);
    try std.testing.expectEqual(@as(u8, 0x16), prop.script);
    try std.testing.expectEqual(@as(u8, 0x00), prop.anim);
    const p = resolve(&r, 0x0E);
    try std.testing.expect(p.run_tbl);
    try std.testing.expectEqual(@as(u8, 0x00), p.anim_index);
}

test "summon id sets hide_chars and darken" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    const p = resolve(&r, 0x4D);
    try std.testing.expect(p.is_summon);
    try std.testing.expect(p.flags.hide_chars);
    try std.testing.expect(p.flags.darken_bg);
}

test "flashFromPal pal nibble" {
    try std.testing.expectEqual(@as(u8, 6), flashFromPal(0));
    try std.testing.expectEqual(@as(u8, 4 + 3), flashFromPal(0x13));
}
