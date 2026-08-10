//! Monster death dissolve helpers — MonsterDeathAnim / UpdateMonsterDeathHDMA / DecColor.
//! Pure functions for host blit + unit tests (btlgfx monster_death.asm / btlgfx.asm).
const std = @import("std");

/// Embed of MonsterDeathHDMATbl first 48 words (phase 0..$2F) when ROM absent.
/// File $13/F99D → 0x9F99D. Values match ROM dump for US FF2.
pub const mon_death_hdma_embed = [_]u16{
    0x0101, 0x0202, 0x0404, 0x0808, 0x1010, 0x2120, 0x4240, 0x8480,
    0x0801, 0x1002, 0x2104, 0x4208, 0x8410, 0x0821, 0x1142, 0x2284,
    0x4408, 0x8910, 0x1221, 0x2542, 0x4a84, 0x9508, 0x2b11, 0x5622,
    0xad44, 0x5b89, 0xb712, 0x6f25, 0xde4a, 0xbd95, 0x7b2b, 0xf756,
    0xefad, 0xdf5b, 0xbeb7, 0x7d6f, 0xfbde, 0xf7bd, 0xef7b, 0xdff7,
    0xbfef, 0x7fdf, 0xffbe, 0xfe7d, 0xfdfb, 0xfbf7, 0xf7ef, 0xefdf,
};

/// Table word for frame `phase` (0..$2F). Second HDMA mirror loop uses the same
/// words in reverse band order; hide decision per band is identical (show = !bit15).
pub fn deathHdmaWordEmbed(phase: u8) u16 {
    if (phase < mon_death_hdma_embed.len) return mon_death_hdma_embed[phase];
    return 0xFFFF;
}

/// UpdateMonsterDeathHDMA (@fae5): loads tbl[0]→$01, tbl[1]→$00 then `asl $00` (16-bit).
/// That puts ROM LE **low byte** in the high half of the shifted word, so C = **lo bit7**.
/// show = eor #1 → hide when `(word & $0080) != 0` (not bit15).
pub fn deathBandHidden(word: u16) bool {
    return (word & 0x0080) != 0;
}

/// Whether band `band` (0..15) is hidden at death frame `phase` (`$4e`).
pub fn deathBandHiddenAt(phase: u8, band: u8) bool {
    return deathBandHidden(deathHdmaWordEmbed(phase +% band));
}

/// DecColor (@bd43) on one SNES 5-bit channel: subtract `amount`, floor 0.
pub fn decColor5(channel: u5, amount: u8) u5 {
    if (amount >= channel) return 0;
    return @intCast(@as(u8, channel) -% amount);
}

/// Exact DecColor (@bd43): `$00` is BGR555 word; `amount` is 8-bit step.
/// Red −= amount; green −= amount in green units; blue −= amount in blue units.
/// When channel raw < scaled amount, that channel is cleared via bit mask.
pub fn decColorExact(w: u16, amount: u8) u16 {
    var color: u16 = w;
    const a: u16 = amount;
    // red bits 0–4
    const r: u16 = color & 0x001F;
    if (r != 0) {
        if (r >= a) color -%= a else color &= 0x7FE0;
    }
    // green bits 5–9: compare field to amount<<5, subtract amount<<5
    const g_field: u16 = color & 0x03E0;
    const a_g: u16 = a << 5;
    if (g_field != 0) {
        if (g_field >= a_g) color -%= a_g else color &= 0x3E1F;
    }
    // blue bits 10–14
    const b_field: u16 = color & 0x7C00;
    const a_b: u16 = a << 10;
    if (b_field != 0) {
        if (b_field >= a_b) color -%= a_b else color &= 0x03FF;
    }
    return color & 0x7FFF;
}

/// DecColor one SNES RGB555 word by `steps` on each channel (cumulative death fade).
pub fn decColorWord(w: u16, steps: u8) u16 {
    // Prefer exact bit-field math (matches DecColor @bd43 for amount=steps).
    return decColorExact(w, steps);
}

test "death band hide uses LE low-byte bit7 (not bit15)" {
    // 0x8410: phase0 band12 ROM — lo=$10 → show; bit15 set would wrongly hide under old mask.
    try std.testing.expect(!deathBandHidden(0x8410));
    try std.testing.expect(!deathBandHidden(0x8000)); // lo=$00 → show
    try std.testing.expect(deathBandHidden(0x0080));
    try std.testing.expect(deathBandHidden(0x8480));
    try std.testing.expect(!deathBandHidden(0x007F));
    try std.testing.expect(!deathBandHidden(0x7F00)); // hi bits only → show
}

test "death phase0 band12 matches ROM word 0x8410 show" {
    // mon_death_hdma_embed[12] must be 0x8410 and visible.
    try std.testing.expectEqual(@as(u16, 0x8410), deathHdmaWordEmbed(12));
    try std.testing.expect(!deathBandHiddenAt(0, 12));
}

test "death phase0 band7/15 hide via lo bit7" {
    try std.testing.expectEqual(@as(u16, 0x8480), deathHdmaWordEmbed(7));
    try std.testing.expect(deathBandHiddenAt(0, 7));
    try std.testing.expectEqual(@as(u16, 0x2284), deathHdmaWordEmbed(15));
    try std.testing.expect(deathBandHiddenAt(0, 15)); // lo=$84
}

test "death phase 0 early bands fewer hides than late" {
    var hidden_early: usize = 0;
    var hidden_late: usize = 0;
    var b: u8 = 0;
    while (b < 16) : (b += 1) {
        if (deathBandHiddenAt(0, b)) hidden_early += 1;
        if (deathBandHiddenAt(0x2C, b)) hidden_late += 1;
    }
    try std.testing.expect(hidden_late >= hidden_early);
}

test "decColor5 floors at zero" {
    try std.testing.expectEqual(@as(u5, 0), decColor5(3, 10));
    try std.testing.expectEqual(@as(u5, 2), decColor5(5, 3));
}

test "decColorWord reduces all channels" {
    const w: u16 = 0x7FFF; // max white
    const d = decColorWord(w, 1);
    try std.testing.expect(d < w);
    try std.testing.expectEqual(@as(u5, 0x1E), @as(u5, @truncate(d)));
}

test "decColorExact clears channel when amount exceeds" {
    // red only $001F, amount 0x20 → clear red via mask
    try std.testing.expectEqual(@as(u16, 0), decColorExact(0x001F, 0x20));
    // green only $03E0, amount 1 → subtract $20
    try std.testing.expectEqual(@as(u16, 0x03C0), decColorExact(0x03E0, 1));
    // full white one step: each channel −1
    try std.testing.expectEqual(@as(u16, 0x7BDE), decColorExact(0x7FFF, 1));
}
