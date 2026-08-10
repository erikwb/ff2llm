//! Field EventCmd_fd special id registry — soft-lock / end-state classification.
//!
//! Decomp jump table: special.asm Special_00..Special_40 (65 entries).
//! Host `GameState.startSpecial` implements every id in that range; ids > $40 use a
//! finite hold cinema (no soft-lock). True ROM "empty" specials are still WaitVblankEvent.
const std = @import("std");

/// Last special id in the ROM jump table (Special_40).
pub const special_id_max: u8 = 0x40;

/// How `startSpecial` ends for a given FD id (for no soft-lock guarantees).
pub const EndKind = enum {
    /// Instant state change (map stack, park vehicle, song fade, party flags) — no cinema wait.
    instant,
    /// Finite cinema / hold; event blocked only while cinema_timer runs.
    cinema,
    /// Soft reset path (Special_3c → Reset); host stops EventPlayer.
    soft_reset,
    /// Outside ROM table: brief hold cinema (16 fields).
    unported_hold,
};

/// Classify end-state for FD special id (matches startSpecial switch arms).
pub fn endKind(id: u8) EndKind {
    if (id > special_id_max) return .unported_hold;
    return switch (id) {
        // Instant (or battle-pending without cinema hold here)
        0x0A, 0x0B, 0x0D, 0x15, 0x1C, 0x1D, 0x28, 0x2D, 0x2E, 0x3D, 0x3E, 0x3F => .instant,
        0x04 => .instant, // pending_event_battle; event blocked on battle not infinite cinema
        0x3C => .soft_reset,
        // Everything else 0..$40 starts a cinema / giant hold with finite timer.
        else => .cinema,
    };
}

/// True if id is in the ROM special jump table.
pub fn inRomTable(id: u8) bool {
    return id <= special_id_max;
}

/// No soft-lock: every id either finishes instantly or has a finite hold path.
pub fn noSoftLock(id: u8) bool {
    return switch (endKind(id)) {
        .instant, .cinema, .soft_reset, .unported_hold => true,
    };
}

test "special id table covers 0..$40" {
    try std.testing.expectEqual(@as(u8, 0x40), special_id_max);
    var id: u16 = 0;
    while (id <= special_id_max) : (id += 1) {
        try std.testing.expect(inRomTable(@intCast(id)));
        try std.testing.expect(noSoftLock(@intCast(id)));
    }
}

test "special endKind samples" {
    try std.testing.expectEqual(EndKind.cinema, endKind(0x00));
    try std.testing.expectEqual(EndKind.instant, endKind(0x2E));
    try std.testing.expectEqual(EndKind.soft_reset, endKind(0x3C));
    try std.testing.expectEqual(EndKind.unported_hold, endKind(0x41));
    try std.testing.expectEqual(EndKind.unported_hold, endKind(0xFF));
    try std.testing.expect(noSoftLock(0xFF));
}
