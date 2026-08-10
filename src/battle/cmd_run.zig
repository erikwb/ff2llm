//! Cmd_24 run away + L+R flee — battle/cmd.asm @e1b5 + battle.asm @a07e.
//!
//! L+R flee is **not** a random chance. Exact behavior:
//!   • $38e5 bit0 set → can't run
//!   • $38d6 run counter:
//!       - Init $FF (InitRAM)
//!       - Mon level ≥ 97 → MonsterRunTbl[level−97] = {3,7,10}
//!       - GetCharAttack zeros $38d6 unless mon level is 97/98/99
//!       - While L+R held: if $38d6==$FF no-op; if 0 → flee; else DEC
//!       - Level 99: if L+R not held, reset counter to 15 each frame
//!   • Cmd_24 (Escape spell): set hide + msg 5 + force flee flag (no roll)
//!
//! MonsterRunTbl @ battle_data.asm @ff0f.
const obj_mod = @import("obj.zig");

/// MonsterRunTbl for levels 97, 98, 99.
pub const monster_run_tbl: [3]u8 = .{ 3, 7, 10 };

/// Battle-side run state ($38d6 + can't-run flag).
pub const RunState = struct {
    /// $38d6 — frames of L+R remaining; $FF = disabled until GetCharAttack zeros it.
    counter: u8 = 0xFF,
    /// $38e5 bit0 — formation can't run.
    cant_run: bool = false,
    /// Highest living monster level (for 97–99 special cases).
    max_mon_level: u8 = 0,
};

/// Init run counter after monsters loaded (battle.asm @8210).
pub fn initRunState(max_mon_level: u8, battle_flags: u8) RunState {
    var st: RunState = .{
        .counter = 0xFF,
        .cant_run = (battle_flags & 0x01) != 0,
        .max_mon_level = max_mon_level,
    };
    if (max_mon_level >= 97) {
        const i: usize = @min(max_mon_level - 97, 2);
        st.counter = monster_run_tbl[i];
    }
    return st;
}

/// GetCharAttack side-effect: zero counter unless mon level is 97/98/99 (char.asm @a396).
pub fn onCharMenuOpen(st: *RunState) void {
    const lv = st.max_mon_level;
    if (lv != 97 and lv != 98 and lv != 99) {
        st.counter = 0;
    }
}

/// Per-frame L+R hold (battle.asm @a07e). Returns true if party flees this frame.
/// `holding_lr` = $352d (both shoulders).
pub fn tickFlee(st: *RunState, holding_lr: bool) bool {
    if (st.cant_run) return false;
    if (!holding_lr) {
        // Level 99: reset counter to 15 when not holding (battle.asm @8638)
        if (st.max_mon_level == 99 and st.counter != 0xFF) {
            st.counter = 15;
        }
        return false;
    }
    if (st.counter == 0xFF) return false;
    if (st.counter == 0) return true;
    st.counter -%= 1;
    return st.counter == 0;
}

/// One-shot L+R press from menu (our UI): apply GetCharAttack zeroing then check.
/// Matches: normal battles succeed immediately; 97–99 need counter exhaustion.
pub fn tryFleeOnce(st: *RunState) bool {
    if (st.cant_run) return false;
    onCharMenuOpen(st);
    if (st.counter == 0xFF) return false;
    if (st.counter == 0) return true;
    // Hard mon: one press decrements once (player must hold across frames in ROM)
    st.counter -%= 1;
    return st.counter == 0;
}

/// Highest living mon level for run table.
pub fn maxLivingMonLevel(objs: *const obj_mod.ObjTable) u8 {
    var max_lv: u8 = 0;
    var i: usize = obj_mod.party_slots;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.objs[i];
        if (o.present and o.hp > 0 and o.level > max_lv) max_lv = o.level;
    }
    return max_lv;
}

test "monster run tbl levels" {
    const std = @import("std");
    const st97 = initRunState(97, 0);
    try std.testing.expectEqual(@as(u8, 3), st97.counter);
    const st98 = initRunState(98, 0);
    try std.testing.expectEqual(@as(u8, 7), st98.counter);
    const st99 = initRunState(99, 0);
    try std.testing.expectEqual(@as(u8, 10), st99.counter);
    const st_norm = initRunState(20, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), st_norm.counter);
    var s = st_norm;
    try std.testing.expect(tryFleeOnce(&s)); // zeros then immediate flee
}

test "cant run flag" {
    const std = @import("std");
    var st = initRunState(10, 0x01);
    try std.testing.expect(!tryFleeOnce(&st));
}
