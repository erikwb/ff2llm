//! Battle opener flags — battle.asm BattleMain @8609 / init.asm @8c66.
//!
//! `$38d7` opener_flag: 0 none, nonzero first strike, bit7 ($80) surprised.
//! `$3581` bit3: forced/rolled back attack.
//! Message priority: back (4) > surprise (3) > first strike (2).
//! After AddMsg1: stz $38d7 / stz $3581.
const std = @import("std");
const battle_msg = @import("battle_msg.zig");

/// BattleMsg ids (ShowMsg_03 / battle_msg.MsgId).
pub const msg_back: u8 = battle_msg.MsgId.attacked_from_behind; // 4
pub const msg_first: u8 = battle_msg.MsgId.strike_first; // 2
pub const msg_surprise: u8 = battle_msg.MsgId.surprised; // 3

/// BattleMain @8609: which opener BattleMsg to show, or null if none.
pub fn openerMsgId(back_attack: bool, opener_flag: u8) ?u8 {
    // Entry: $38d7 != 0 OR $3581 bit3
    if (!back_attack and opener_flag == 0) return null;
    // Priority: back attack first
    if (back_attack) return msg_back;
    // $38d7 BMI → surprised
    if ((opener_flag & 0x80) != 0) return msg_surprise;
    // else first strike
    return msg_first;
}

/// Whether BattleMain should enter the opener message path at all.
pub fn hasOpener(back_attack: bool, opener_flag: u8) bool {
    return back_attack or opener_flag != 0;
}

/// Forced back-attack from BattleProp flags bit3 → timer_adv $80 (init.asm).
pub fn forcedBackAttackTimerAdv() u8 {
    return 0x80;
}

test "openerMsgId priority back > surprise > first" {
    try std.testing.expectEqual(@as(?u8, null), openerMsgId(false, 0));
    try std.testing.expectEqual(@as(?u8, msg_first), openerMsgId(false, 1));
    try std.testing.expectEqual(@as(?u8, msg_surprise), openerMsgId(false, 0x80));
    try std.testing.expectEqual(@as(?u8, msg_back), openerMsgId(true, 0));
    try std.testing.expectEqual(@as(?u8, msg_back), openerMsgId(true, 1));
    try std.testing.expectEqual(@as(?u8, msg_back), openerMsgId(true, 0x80));
    try std.testing.expectEqual(@as(u8, 4), msg_back);
    try std.testing.expectEqual(@as(u8, 3), msg_surprise);
    try std.testing.expectEqual(@as(u8, 2), msg_first);
}

test "hasOpener" {
    try std.testing.expect(!hasOpener(false, 0));
    try std.testing.expect(hasOpener(true, 0));
    try std.testing.expect(hasOpener(false, 1));
}
