//! CheckCmdEnabled / DisableCmdStatusTbl — char.asm @a27e / battle_data.asm @fd19.
//!
//! Each command has status1/status2 masks that disable it when set on the actor.
const status_mod = @import("status.zig");

/// DisableCmdStatusTbl: 30 commands × (s1_mask, s2_mask).
/// s1: toad $20, mini $10, pig $08, mute $04, poison $01, …
/// s2 bit6 float $40 used by kick only.
pub const disable_cmd_status_tbl = [_][2]u8{
    .{ 0x00, 0x00 }, // $00 fight
    .{ 0x00, 0x00 }, // $01 item
    .{ 0x2C, 0x00 }, // $02 white — toad, pig, mute
    .{ 0x04, 0x00 }, // $03 black — mute
    .{ 0x2C, 0x00 }, // $04 summon — toad, pig, mute
    .{ 0x38, 0x00 }, // $05 dark — toad, mini, pig
    .{ 0x30, 0x00 }, // $06 jump — toad, mini
    .{ 0x2C, 0x00 }, // $07 recall — toad, pig, mute
    .{ 0x04, 0x00 }, // $08 sing — mute
    .{ 0x00, 0x00 }, // $09 hide
    .{ 0x00, 0x00 }, // $0a salve
    .{ 0x00, 0x00 }, // $0b pray
    .{ 0x38, 0x00 }, // $0c aim
    .{ 0x39, 0x00 }, // $0d focus — +poison
    .{ 0x38, 0x40 }, // $0e kick — +float (s2)
    .{ 0x38, 0x00 }, // $0f brace
    .{ 0x3C, 0x00 }, // $10 twin — +mute
    .{ 0x38, 0x00 }, // $11 bluff
    .{ 0x38, 0x00 }, // $12 cry
    .{ 0x30, 0x00 }, // $13 cover
    .{ 0x38, 0x00 }, // $14 peep
    .{ 0x38, 0x00 }, // $15
    .{ 0x30, 0x00 }, // $16 dart
    .{ 0x20, 0x00 }, // $17 sneak — toad only
    .{ 0x2C, 0x00 }, // $18 ninja
    .{ 0x38, 0x00 }, // $19 regen
    .{ 0x00, 0x00 }, // $1a chang
    .{ 0x00, 0x00 }, // $1b parry
    .{ 0x00, 0x00 }, // $1c show
    .{ 0x00, 0x00 }, // $1d don't cover
};

/// True if command is disabled by actor status (CheckCmdEnabled status half).
pub fn cmdDisabledByStatus(cmd: u8, s1: u8, s2: u8) bool {
    if (cmd >= disable_cmd_status_tbl.len) return false;
    const m = disable_cmd_status_tbl[cmd];
    if ((s1 & m[0]) != 0) return true;
    if ((s2 & m[1]) != 0) return true;
    return false;
}

/// CheckCmdReq (char.asm @a27e): equip gates for dark/sing/aim.
/// Returns false if command requires equip that is missing.
pub fn cmdReqMet(cmd: u8, left_hand: u8, right_hand: u8) bool {
    return switch (cmd) {
        // Dark wave: any weapon id 1..$60 in a hand
        0x05 => isWeapon(left_hand) or isWeapon(right_hand),
        // Sing: harp $44..$4C
        0x08 => isHarp(left_hand) or isHarp(right_hand),
        // Aim: bow $4D..$60 in one hand (ROM checks both present oddly — any bow)
        0x0C => isBow(left_hand) or isBow(right_hand),
        else => true,
    };
}

fn isWeapon(id: u8) bool {
    return id != 0 and id < 0x61;
}
fn isHarp(id: u8) bool {
    return id >= 0x44 and id < 0x4D;
}
fn isBow(id: u8) bool {
    return id >= 0x4D and id < 0x61;
}

/// Filter ClassCmd list in place; returns new count.
pub fn filterEnabledCmds(
    cmds: []u8,
    count: u8,
    s1: u8,
    s2: u8,
    left_hand: u8,
    right_hand: u8,
) u8 {
    var w: u8 = 0;
    var r: u8 = 0;
    while (r < count) : (r += 1) {
        const c = cmds[r];
        if (c == 0xFF) continue;
        if (cmdDisabledByStatus(c, s1, s2)) continue;
        if (!cmdReqMet(c, left_hand, right_hand)) continue;
        cmds[w] = c;
        w += 1;
    }
    return w;
}

test "mute disables white not fight" {
    const std = @import("std");
    try std.testing.expect(cmdDisabledByStatus(0x02, status_mod.Status1.mute, 0));
    try std.testing.expect(!cmdDisabledByStatus(0x00, status_mod.Status1.mute, 0));
    try std.testing.expect(cmdDisabledByStatus(0x05, status_mod.Status1.toad, 0));
    try std.testing.expect(cmdDisabledByStatus(0x17, status_mod.Status1.toad, 0));
    try std.testing.expect(!cmdDisabledByStatus(0x17, status_mod.Status1.mute, 0));
}

test "CheckCmdReq dark needs weapon sing needs harp" {
    const std = @import("std");
    try std.testing.expect(cmdReqMet(0x05, 0x17, 0)); // weapon
    try std.testing.expect(!cmdReqMet(0x05, 0, 0));
    try std.testing.expect(cmdReqMet(0x08, 0x45, 0)); // harp
    try std.testing.expect(!cmdReqMet(0x08, 0x17, 0));
    try std.testing.expect(cmdReqMet(0x0C, 0x50, 0)); // bow
    try std.testing.expect(!cmdReqMet(0x0C, 0x17, 0));
}
