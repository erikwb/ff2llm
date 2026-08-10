//! CheckBattleEnd — battle.asm @a015 pure flag compute.
//!
//! `$a8` battle end flags (subset used by host):
//!   bit7 $80 = party wiped (no living able char; not "no fail" $02)
//!   bit3 $08 = party wiped under "no fail" battle ($38e5 bit1)
//!   bit5+4 $30 = victory (no monsters remain)
//!   bit4 $10 = party update after battle (cleared for NoUpdateBattleTbl)
//!   bit6 $40 = ran away
const auto_battle = @import("auto_battle.zig");

pub const Flags = struct {
    /// $a8 raw
    raw: u8 = 0,
    wiped: bool = false,
    victory: bool = false,
    ran: bool = false,
    /// bit4 set → host should syncPartyOut
    update_party: bool = true,

    pub fn any(self: Flags) bool {
        return self.wiped or self.victory or self.ran;
    }
};

pub const Input = struct {
    /// True if any party slot present, not dead/stone, not jumped ($2005 bit7 hide not for wipe).
    /// CheckBattleEnd: dead/stone ($2003&$c0), or $2005 bit7 (hiding) counts as invalid for "living".
    any_able_party: bool,
    /// $29cd any monsters remain
    any_mons: bool,
    /// $388b auto-battle — no run check
    auto_battle: bool,
    /// $38d3 or L+R held for run attempt
    run_attempt: bool,
    /// $38d6 run counter hit 0 (ready to flee)
    run_ready: bool,
    /// $38e5 bit0 can't run
    cant_run: bool,
    /// $38e5 bit1 "no fail" battle (wiped → $08 not $80)
    no_fail: bool,
    /// Battle id for NoUpdateBattleTbl
    battle_id: u16,
    /// At least one living party char can run (not dead/stone/sleep/para/jump/stop/mag)
    any_runnable_party: bool,
};

/// Pure CheckBattleEnd @a015.
pub fn evaluate(in: Input) Flags {
    var f: Flags = .{};

    if (!in.any_able_party) {
        // Party wiped
        f.wiped = true;
        f.raw = if (in.no_fail) 0x08 else 0x80;
        return f;
    }

    if (!in.any_mons) {
        // Victory $30; clear bit4 if NoUpdateBattleTbl
        f.victory = true;
        f.raw = 0x30;
        if (auto_battle.inTbl(in.battle_id, &auto_battle.no_update_tbl)) {
            f.raw &= ~@as(u8, 0x10);
            f.update_party = false;
        } else {
            f.update_party = true;
        }
        return f;
    }

    // Monsters remain — run away path
    if (in.auto_battle) return f;
    if (!in.run_attempt) return f;
    if (!in.run_ready) return f;
    if (in.cant_run) return f;
    if (in.any_runnable_party) {
        f.ran = true;
        f.raw = 0x40;
    }
    return f;
}

const std = @import("std");

test "victory sets update unless no-update battle" {
    const base = Input{
        .any_able_party = true,
        .any_mons = false,
        .auto_battle = false,
        .run_attempt = false,
        .run_ready = false,
        .cant_run = false,
        .no_fail = false,
        .battle_id = 0x0001,
        .any_runnable_party = true,
    };
    const v = evaluate(base);
    try std.testing.expect(v.victory);
    try std.testing.expect(v.update_party);

    var n = base;
    n.battle_id = 0x00F3; // Tellah vs Golbez NoUpdate
    const v2 = evaluate(n);
    try std.testing.expect(v2.victory);
    try std.testing.expect(!v2.update_party);
}

test "wipe and run flags" {
    const wipe = evaluate(.{
        .any_able_party = false,
        .any_mons = true,
        .auto_battle = false,
        .run_attempt = false,
        .run_ready = false,
        .cant_run = false,
        .no_fail = false,
        .battle_id = 0,
        .any_runnable_party = false,
    });
    try std.testing.expect(wipe.wiped);
    try std.testing.expectEqual(@as(u8, 0x80), wipe.raw);

    const ran = evaluate(.{
        .any_able_party = true,
        .any_mons = true,
        .auto_battle = false,
        .run_attempt = true,
        .run_ready = true,
        .cant_run = false,
        .no_fail = false,
        .battle_id = 0,
        .any_runnable_party = true,
    });
    try std.testing.expect(ran.ran);
    try std.testing.expectEqual(@as(u8, 0x40), ran.raw);

    // Auto-battle never runs
    const no_run = evaluate(.{
        .any_able_party = true,
        .any_mons = true,
        .auto_battle = true,
        .run_attempt = true,
        .run_ready = true,
        .cant_run = false,
        .no_fail = false,
        .battle_id = 0x00F3,
        .any_runnable_party = true,
    });
    try std.testing.expect(!no_run.ran);
}
