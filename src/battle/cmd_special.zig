//! Pure edges for ClassCmd specials — battle/cmd.asm Cover / Jump / Twin / Hide.
//!
//! Cmd_06 Jump1 (@e957): party→party fails (nothing happened); mon targets ok.
//!   Sets $2005 bit1, action timer duration **hardcoded 4** (no ApplySpeedMod),
//!   pending cmd $1e (Jump2), enables action timer only, `inc $390a` (no retal).
//! Cmd_1e Jump2 (@e9a5): DoFightCmd **while** jumping (2× ATK + no row penalty),
//!   then clear jump bit and restore timer enable mask.
//! CmdTargetTbl[$06]=$58: mon default + target selectable (not all).
//! Cmd_10 Twin1 (@e441): partner must be present, not dead/stone ($c0), not
//!   sleep/para/berserk/charm ($3c), not stop ($40).
//! Cmd_13 Cover: set $2006 bit1 on covered; Cmd_1d clears it.
//! Cmd_09 Hide: $2006 bit7; alone check is host-side (Edward critical).
const std = @import("std");
const status_mod = @import("status.zig");
const timer_dur = @import("timer_dur.zig");

/// Cmd_06: true if jump is legal (attacker and target not both party).
/// Decomp: `lda $cd / bmi ok; lda $ce / bmi ok; else nothing happened`.
pub fn jumpTargetsLegal(attacker_is_mon: bool, target_is_mon: bool) bool {
    // Fail only when both are characters (party).
    return attacker_is_mon or target_is_mon;
}

/// Cmd_06 @e96c: `ldx #$0004 / stx $d4` then SetTimer — **no** ApplySpeedMod.
pub const jump1_duration_rom: u16 = 4;

/// Host ticks for Jump1 air time (ROM duration 4 × battle_tick_scale).
pub fn jump1HostTicks() u16 {
    return timer_dur.toHostTicksArm(jump1_duration_rom);
}

/// Jump2 land target still valid? (attack.asm @af06: not jump/hide; present/alive).
pub fn jumpLandTargetOk(present: bool, hp: u16, is_ko: bool, is_jumping: bool, is_hidden: bool) bool {
    return present and hp > 0 and !is_ko and !is_jumping and !is_hidden;
}

/// TwinFailed status gate for partner (Cmd_10 @e44c–@e472).
pub fn twinPartnerOk(status: status_mod.Status, present: bool, hp: u16) bool {
    if (!present or hp == 0) return false;
    if ((status.s1 & 0xC0) != 0) return false; // dead/stone
    if ((status.s2 & 0x3C) != 0) return false; // sleep/para/berserk/charm
    if ((status.s3 & 0x40) != 0) return false; // stop
    return true;
}

/// Cover flag bit on $2006 (status4) — Cmd_13 ORA #$02 / Cmd_1d AND #$FD.
pub const cover_status_bit: u8 = status_mod.Status4.covered;

/// Apply cover: covered slot gets bit; coverer records covering_slot.
pub fn applyCover(
    coverer_covering_slot: *u8,
    covered_cover_by: *u8,
    covered_s4: *u8,
    coverer_slot: u8,
    covered_slot: u8,
) void {
    coverer_covering_slot.* = covered_slot;
    covered_cover_by.* = coverer_slot;
    covered_s4.* |= cover_status_bit;
}

/// Cmd_1d: clear cover on covered unit and coverer's link.
pub fn clearCover(
    coverer_covering_slot: *u8,
    covered_cover_by: *u8,
    covered_s4: *u8,
    coverer_slot: u8,
) void {
    const c = coverer_covering_slot.*;
    if (c == 0xFF) return;
    if (covered_cover_by.* == coverer_slot) {
        covered_cover_by.* = 0xFF;
        covered_s4.* &= ~cover_status_bit;
    }
    coverer_covering_slot.* = 0xFF;
}

/// Hide: set $2006 bit7. Alone-party fail is separate (ForceCharActions).
pub fn applyHide(s4: *u8) void {
    s4.* |= status_mod.Status4.hide;
}

pub fn applyShow(s4: *u8) void {
    s4.* &= ~status_mod.Status4.hide;
}

/// Legacy alias — prefer `jump1_duration_rom` / `jump1HostTicks()`.
pub const jump_timer_duration: u16 = jump1_duration_rom;

/// Focus1 (Cmd_0d): pending Focus2 command id.
pub const focus2_cmd: u8 = 0x1F;
/// Salve (Cmd_0a): Cure item id $CE consumed.
pub const salve_item_id: u8 = 0xCE;
/// Brace (Cmd_0f): casts Armor/Barrier spell id $05.
pub const brace_spell_id: u8 = 0x05;
/// Pray (Cmd_0b): Cure2 spell $0E on success (50%).
pub const pray_spell_id: u8 = 0x0E;
/// Pray success threshold: Rand < $80 (50%).
pub const pray_success_thr: u8 = 0x80;

/// Pure Focus1 eligibility: always ok if present/alive (no special gates in ROM).
pub fn focus1Ready(present: bool, hp: u16) bool {
    return present and hp > 0;
}

/// Pray: true if Rand byte < $80 (cmd.asm @e855).
pub fn praySucceeds(rand_byte: u8) bool {
    return rand_byte < pray_success_thr;
}

/// Salve: inventory has at least one Cure ($CE) with qty ≥ 1.
pub fn salveHasCure(item_id: u8, qty: u8) bool {
    return item_id == salve_item_id and qty >= 1;
}

test "jumpTargetsLegal party to mon ok, party to party fail" {
    try std.testing.expect(jumpTargetsLegal(false, true));
    try std.testing.expect(jumpTargetsLegal(true, false));
    try std.testing.expect(jumpTargetsLegal(true, true));
    try std.testing.expect(!jumpTargetsLegal(false, false));
}

test "jump1HostTicks is ROM 4 scaled no speed mod" {
    try std.testing.expectEqual(@as(u16, 4), jump1_duration_rom);
    try std.testing.expectEqual(timer_dur.toHostTicksArm(4), jump1HostTicks());
}

test "jumpLandTargetOk rejects dead jump hide" {
    try std.testing.expect(jumpLandTargetOk(true, 10, false, false, false));
    try std.testing.expect(!jumpLandTargetOk(true, 0, false, false, false));
    try std.testing.expect(!jumpLandTargetOk(true, 10, true, false, false));
    try std.testing.expect(!jumpLandTargetOk(true, 10, false, true, false));
    try std.testing.expect(!jumpLandTargetOk(true, 10, false, false, true));
    try std.testing.expect(!jumpLandTargetOk(false, 10, false, false, false));
}

test "twinPartnerOk rejects KO sleep stop" {
    var st: status_mod.Status = .{};
    try std.testing.expect(twinPartnerOk(st, true, 10));
    st.s1 = status_mod.Status1.dead;
    try std.testing.expect(!twinPartnerOk(st, true, 10));
    st = .{};
    st.s2 = status_mod.Status2.sleep;
    try std.testing.expect(!twinPartnerOk(st, true, 10));
    st = .{};
    st.s3 = status_mod.Status3.stop;
    try std.testing.expect(!twinPartnerOk(st, true, 10));
    try std.testing.expect(!twinPartnerOk(.{}, false, 10));
    try std.testing.expect(!twinPartnerOk(.{}, true, 0));
}

test "applyCover and clearCover" {
    var covering: u8 = 0xFF;
    var cover_by: u8 = 0xFF;
    var s4: u8 = 0;
    applyCover(&covering, &cover_by, &s4, 0, 2);
    try std.testing.expectEqual(@as(u8, 2), covering);
    try std.testing.expectEqual(@as(u8, 0), cover_by);
    try std.testing.expect((s4 & cover_status_bit) != 0);
    clearCover(&covering, &cover_by, &s4, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), covering);
    try std.testing.expectEqual(@as(u8, 0xFF), cover_by);
    try std.testing.expect((s4 & cover_status_bit) == 0);
}

test "hide show bit7" {
    var s4: u8 = 0;
    applyHide(&s4);
    try std.testing.expect((s4 & status_mod.Status4.hide) != 0);
    applyShow(&s4);
    try std.testing.expect((s4 & status_mod.Status4.hide) == 0);
}

test "praySucceeds 50 percent thr" {
    try std.testing.expect(praySucceeds(0x00));
    try std.testing.expect(praySucceeds(0x7F));
    try std.testing.expect(!praySucceeds(0x80));
    try std.testing.expect(!praySucceeds(0xFF));
}

test "salveHasCure only CE qty>=1" {
    try std.testing.expect(salveHasCure(0xCE, 1));
    try std.testing.expect(!salveHasCure(0xCE, 0));
    try std.testing.expect(!salveHasCure(0xCF, 5));
}

test "focus1 constants" {
    try std.testing.expectEqual(@as(u8, 0x1F), focus2_cmd);
    try std.testing.expectEqual(@as(u8, 0x05), brace_spell_id);
    try std.testing.expect(focus1Ready(true, 10));
    try std.testing.expect(!focus1Ready(true, 0));
}


