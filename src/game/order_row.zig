//! Main-menu Order / Row — menu/order.asm ChangeRow @acde + Order swap.
//!
//! ChangeRow: `lda #1 / eor $16a8` — flip party default row config.
//! Order: swap two present party slots (and controller map `$16b9` — host omits).
const std = @import("std");

/// ChangeRow (order.asm @acde): toggle config `$16a8` (0 ↔ 1).
/// InitCharRows uses this to invert battle row layout.
pub fn togglePartyRow(party_row: u8) u8 {
    return party_row ^ 1;
}

/// Swap two party members in-place (Order menu A-on-A confirm).
/// Returns false if either index out of range.
pub fn swapPartySlots(comptime T: type, party: []T, a: usize, b: usize) bool {
    if (a >= party.len or b >= party.len) return false;
    if (a == b) return true;
    const tmp = party[a];
    party[a] = party[b];
    party[b] = tmp;
    return true;
}

test "ChangeRow toggles $16a8" {
    try std.testing.expectEqual(@as(u8, 1), togglePartyRow(0));
    try std.testing.expectEqual(@as(u8, 0), togglePartyRow(1));
    // eor #$01 only flips bit0
    try std.testing.expectEqual(@as(u8, 3), togglePartyRow(2));
    try std.testing.expectEqual(@as(u8, 2), togglePartyRow(3));
    try std.testing.expectEqual(@as(u8, 0), togglePartyRow(togglePartyRow(0)));
}

test "swapPartySlots exchanges and rejects OOB" {
    var p = [_]u8{ 10, 20, 30, 40, 50 };
    try std.testing.expect(swapPartySlots(u8, p[0..], 0, 2));
    try std.testing.expectEqual(@as(u8, 30), p[0]);
    try std.testing.expectEqual(@as(u8, 10), p[2]);
    try std.testing.expect(swapPartySlots(u8, p[0..], 1, 1));
    try std.testing.expect(!swapPartySlots(u8, p[0..], 0, 9));
}
