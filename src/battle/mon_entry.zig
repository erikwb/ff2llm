//! UpdateMonsterEntry — btlgfx.asm @8263 + InitBtlGfx entry loop @8205.
//!
//! Monster entry runs `$f28e = $16` frames: each field `dec`, load AnimSineTbl[x],
//! `asl2`, write BG1 H-scroll (or V-scroll if flying). Back attack negates the offset.
const std = @import("std");

/// InitBtlGfx `@81f8`: `lda #$16` — entry counter start (22 fields after first dec path).
pub const entry_counter_init: u8 = 0x16;

/// AnimSineTbl @ LoROM $1C/FF00 (file 0xE7F00) — first 32 bytes used by entry.
/// Full table is 256 bytes; entry indexes 0..$15 after counter dec.
pub const anim_sine_tbl_prefix = [_]u8{
    0x00, 0x03, 0x06, 0x09, 0x0C, 0x10, 0x13, 0x16, 0x19, 0x1C, 0x1F, 0x22, 0x25, 0x28, 0x2B, 0x2E,
    0x31, 0x33, 0x36, 0x39, 0x3C, 0x3F, 0x41, 0x44, 0x47, 0x49, 0x4C, 0x4E, 0x51, 0x53, 0x55, 0x58,
};

/// `$ed4e` bit6 — flying monsters enter from above (V-scroll).
pub const flying_bit: u8 = 0x40;

pub const Axis = enum { horizontal, vertical };

/// Choose scroll axis (UpdateMonsterEntry @8263).
pub fn entryAxis(ed4e: u8) Axis {
    if ((ed4e & flying_bit) != 0) return .vertical;
    return .horizontal;
}

/// Raw sine×4 offset for a post-dec counter value (0..$15).
/// ROM: `lda AnimSineTbl,x / asl2` — signed via back-attack path only.
pub fn sineOffset(counter_after_dec: u8) u8 {
    const i: usize = @min(counter_after_dec, anim_sine_tbl_prefix.len - 1);
    // asl2 on 8-bit: ×4, wrap
    return anim_sine_tbl_prefix[i] *% 4;
}

/// Apply back-attack invert (`eor #$ff / inc`) when `$6cc0 != 0` and not flying.
/// Result is sign-extended 8-bit (ROM writes one byte to BG1 H-scroll HDMA).
pub fn scrollDelta(raw_offset: u8, back_attack: bool, flying: bool) i16 {
    if (flying) return @as(i16, raw_offset);
    if (back_attack) {
        const n: u8 = (~raw_offset) +% 1;
        return @as(i16, @as(i8, @bitCast(n)));
    }
    return @as(i16, raw_offset);
}

/// One field of entry: returns new counter, scroll delta, and whether entry finished.
/// Call with current `$f28e` **before** dec (InitBtlGfx loop).
pub fn tickEntry(counter: u8, back_attack: bool, flying: bool) struct {
    next_counter: u8,
    delta: i16,
    done: bool,
} {
    if (counter == 0) {
        return .{ .next_counter = 0, .delta = 0, .done = true };
    }
    const next = counter -% 1;
    const raw = sineOffset(next);
    const d = scrollDelta(raw, back_attack, flying);
    return .{ .next_counter = next, .delta = d, .done = next == 0 };
}

/// Total entry fields from init counter (dec each field until 0 inclusive after last).
pub fn entryFieldCount() u8 {
    return entry_counter_init; // 0x16 fields of movement; ends with counter 0
}

test "entry axis flying vs ground" {
    try std.testing.expectEqual(Axis.horizontal, entryAxis(0));
    try std.testing.expectEqual(Axis.vertical, entryAxis(flying_bit));
    try std.testing.expectEqual(Axis.vertical, entryAxis(0xC0));
}

test "sineOffset matches asl2 of table" {
    try std.testing.expectEqual(@as(u8, 0), sineOffset(0));
    try std.testing.expectEqual(@as(u8, 12), sineOffset(1)); // 3*4
    try std.testing.expectEqual(@as(u8, 252), sineOffset(0x15)); // 0x3F*4
}

test "back attack negates offset" {
    const raw: u8 = 12;
    try std.testing.expectEqual(@as(i16, 12), scrollDelta(raw, false, false));
    try std.testing.expectEqual(@as(i16, -12), scrollDelta(raw, true, false));
    // Flying ignores back-attack invert
    try std.testing.expectEqual(@as(i16, 12), scrollDelta(raw, true, true));
}

test "tickEntry countdown to done" {
    var c: u8 = entry_counter_init;
    var steps: usize = 0;
    var last_delta: i16 = 0;
    while (true) {
        const r = tickEntry(c, false, false);
        c = r.next_counter;
        last_delta = r.delta;
        steps += 1;
        if (r.done) break;
        try std.testing.expect(steps < 40);
    }
    try std.testing.expectEqual(@as(usize, 22), steps); // $16
    try std.testing.expectEqual(@as(u8, 0), c);
    // Last field uses sine[0]*4 = 0
    try std.testing.expectEqual(@as(i16, 0), last_delta);
}

test "tickEntry back attack first step" {
    // counter $16 → next $15, sine[$15]=$3F, *4=$FC → -252 as i16 from 8-bit negate
    const r = tickEntry(entry_counter_init, true, false);
    try std.testing.expectEqual(@as(u8, 0x15), r.next_counter);
    const raw = sineOffset(0x15);
    try std.testing.expectEqual(scrollDelta(raw, true, false), r.delta);
}
