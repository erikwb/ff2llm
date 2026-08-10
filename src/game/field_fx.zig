//! Field screen FX pure helpers — EventCmd_d1/d2 flash/mosaic + LoadPlayerGfx form ids
//! + EventCmd_d5 secret-door tile rewrite.
//!
//! Decomp:
//! - EventCmd_d2 / EventMosaicTbl @ field_data.asm $fa66 (event.asm @ee5c)
//! - EventCmd_d1 flash 2× WaitVblankShort with $c4 invert (event.asm @ee25)
//! - EventCmd_d5 open secret door (event.asm @ee9f): find `$60`, rewrite `$64–$67`
//! - LoadPlayerGfx status overrides (player.asm @c88b): toad $0F / mini $0E / pig $10
const std = @import("std");
const status_mod = @import("../battle/status.zig");

/// Submap is always 32×32 metatiles (submap.zig map_w/map_h).
pub const submap_w: usize = 32;
pub const submap_h: usize = 32;

/// EventMosaicTbl @ field_data.asm $fa66 — 32 entries.
/// EventCmd_d2: `$79` runs 0..$3F; table index = `$79 >> 1`; byte written to hMOSAIC ($2106).
pub const event_mosaic_tbl = [_]u8{
    0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F, 0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF,
    0xEF, 0xDF, 0xCF, 0xBF, 0xAF, 0x9F, 0x8F, 0x7F, 0x6F, 0x5F, 0x4F, 0x3F, 0x2F, 0x1F, 0x0F, 0x0F,
};

/// EventCmd_d1 (event.asm @ee25): flash holds `$79 = 2` inverted-palette vblanks.
pub const flash_hold_frames: u8 = 2;

/// Host `mosaic_frame`: 0 = off; 1..$40 running (matches `$79` inc until cmp #$40).
/// Returns SNES mosaic pixel size = (hMOSAIC high nibble) + 1, or 0 when off.
pub fn mosaicBlockSizeFromFrame(mosaic_frame: u8) u8 {
    if (mosaic_frame == 0) return 0;
    // Index while running: (frame-1)>>1 over the 32-byte table (frame 1→idx0 … frame $40→idx $1F).
    const idx: usize = @min((@as(usize, mosaic_frame) - 1) >> 1, event_mosaic_tbl.len - 1);
    return (event_mosaic_tbl[idx] >> 4) + 1;
}

/// Raw hMOSAIC register byte for a given host mosaic_frame (for tests / host parity).
pub fn mosaicRegFromFrame(mosaic_frame: u8) u8 {
    if (mosaic_frame == 0) return 0;
    const idx: usize = @min((@as(usize, mosaic_frame) - 1) >> 1, event_mosaic_tbl.len - 1);
    return event_mosaic_tbl[idx];
}

/// Advance mosaic_frame one field (tickTransition). Clears after frame exceeds $40.
pub fn advanceMosaicFrame(mosaic_frame: u8) u8 {
    if (mosaic_frame == 0) return 0;
    const next = mosaic_frame +% 1;
    if (next > 0x40) return 0;
    return next;
}

/// LoadPlayerGfx (player.asm @c88b) form override priority:
/// toad ($1003&$20) → $0F, mini ($10) → $0E, pig ($08) → $10, else class gfx `$1001&$1F`.
/// Stone does **not** change MapCharGfx id in ROM (no branch in LoadPlayerGfx).
pub fn fieldGfxId(class_gfx: u8, status1: u8) u8 {
    if ((status1 & status_mod.Status1.toad) != 0) return 0x0F;
    if ((status1 & status_mod.Status1.mini) != 0) return 0x0E;
    if ((status1 & status_mod.Status1.pig) != 0) return 0x10;
    return class_gfx & 0x1F;
}

/// True when status form uses a dedicated MapCharGfx sheet (pal index forced 0 on host).
pub fn fieldFormOverride(status1: u8) bool {
    return (status1 & status_mod.Status1.form_bits) != 0;
}

test "EventMosaicTbl length and endpoints" {
    try std.testing.expectEqual(@as(usize, 32), event_mosaic_tbl.len);
    try std.testing.expectEqual(@as(u8, 0x0F), event_mosaic_tbl[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), event_mosaic_tbl[15]);
    try std.testing.expectEqual(@as(u8, 0x0F), event_mosaic_tbl[31]);
}

test "mosaicBlockSizeFromFrame peak mid-ramp" {
    try std.testing.expectEqual(@as(u8, 0), mosaicBlockSizeFromFrame(0));
    // frame 1 → idx 0 → $0F → size nibble 0 → 1 px
    try std.testing.expectEqual(@as(u8, 1), mosaicBlockSizeFromFrame(1));
    try std.testing.expectEqual(@as(u8, 0x0F), mosaicRegFromFrame(1));
    // frame 2 → still idx 0
    try std.testing.expectEqual(@as(u8, 1), mosaicBlockSizeFromFrame(2));
    // frame 3–4 → idx 1 → $1F → 2 px
    try std.testing.expectEqual(@as(u8, 2), mosaicBlockSizeFromFrame(3));
    // peak: frame (15*2+1)=31 → idx 15 → $FF → 16 px
    try std.testing.expectEqual(@as(u8, 16), mosaicBlockSizeFromFrame(31));
    try std.testing.expectEqual(@as(u8, 16), mosaicBlockSizeFromFrame(32));
    // last entries: frame $3F/$40 → idx 31 → $0F → 1 px
    try std.testing.expectEqual(@as(u8, 1), mosaicBlockSizeFromFrame(0x3F));
    try std.testing.expectEqual(@as(u8, 1), mosaicBlockSizeFromFrame(0x40));
}

test "advanceMosaicFrame 64 fields then clear" {
    var f: u8 = 1;
    var i: usize = 0;
    while (i < 63) : (i += 1) {
        f = advanceMosaicFrame(f);
        try std.testing.expect(f != 0);
    }
    // After start 1 + 63 advances → frame 64 ($40); one more clears.
    try std.testing.expectEqual(@as(u8, 0x40), f);
    try std.testing.expectEqual(@as(u8, 0), advanceMosaicFrame(f));
    try std.testing.expectEqual(@as(u8, 0), advanceMosaicFrame(0));
}

test "LoadPlayerGfx form priority toad > mini > pig" {
    try std.testing.expectEqual(@as(u8, 0x0F), fieldGfxId(0x01, status_mod.Status1.toad));
    try std.testing.expectEqual(@as(u8, 0x0E), fieldGfxId(0x01, status_mod.Status1.mini));
    try std.testing.expectEqual(@as(u8, 0x10), fieldGfxId(0x01, status_mod.Status1.pig));
    // toad wins when multiple form bits set
    try std.testing.expectEqual(@as(u8, 0x0F), fieldGfxId(0x05, status_mod.Status1.toad | status_mod.Status1.mini));
    try std.testing.expectEqual(@as(u8, 0x0E), fieldGfxId(0x05, status_mod.Status1.mini | status_mod.Status1.pig));
    // stone alone does not override class gfx
    try std.testing.expectEqual(@as(u8, 0x03), fieldGfxId(0x03, status_mod.Status1.stone));
    try std.testing.expectEqual(@as(u8, 0x07), fieldGfxId(0x27, 0)); // & $1F
    try std.testing.expect(!fieldFormOverride(0));
    try std.testing.expect(fieldFormOverride(status_mod.Status1.pig));
}

test "EventCmd_d1 flash hold is 2 frames" {
    try std.testing.expectEqual(@as(u8, 2), flash_hold_frames);
}

/// EventCmd_d5 (event.asm @ee9f): find metatile `$60` near the player, rewrite a 2×2
/// block to `$64..$67`. Search: start (px−7, py−7), scan 16 east × up to 15 south.
/// When py−7 < 0: base_y=0 and rows = 0x0F + (py−7) (ROM adc #$0f).
pub fn openSecretDoorCells(cells: *[submap_w * submap_h]u8, px: i32, py: i32) bool {
    const base_x = px - 7;
    var base_y = py - 7;
    var rows: i32 = 15;
    if (base_y < 0) {
        rows += base_y;
        base_y = 0;
    }
    if (rows <= 0) return false;
    var y: i32 = base_y;
    var left: i32 = rows;
    while (left > 0 and y < @as(i32, @intCast(submap_h))) : ({
        y += 1;
        left -= 1;
    }) {
        var x: i32 = base_x;
        var col: i32 = 0;
        while (col < 16 and x < @as(i32, @intCast(submap_w))) : ({
            col += 1;
            x += 1;
        }) {
            if (x < 0) continue;
            const idx: usize = @as(usize, @intCast(y)) * submap_w + @as(usize, @intCast(x));
            if (cells[idx] != 0x60) continue;
            cells[idx] = 0x64;
            if (x + 1 < @as(i32, @intCast(submap_w))) cells[idx + 1] = 0x65;
            if (y + 1 < @as(i32, @intCast(submap_h))) {
                const below = idx + submap_w;
                cells[below] = 0x66;
                if (x + 1 < @as(i32, @intCast(submap_w))) cells[below + 1] = 0x67;
            }
            return true;
        }
    }
    return false;
}

test "openSecretDoorCells rewrites 2x2 $60 to $64-$67" {
    var cells = [_]u8{0} ** (submap_w * submap_h);
    cells[10 * submap_w + 10] = 0x60;
    cells[10 * submap_w + 11] = 0x11;
    cells[11 * submap_w + 10] = 0x22;
    cells[11 * submap_w + 11] = 0x33;
    try std.testing.expect(openSecretDoorCells(&cells, 10, 10));
    try std.testing.expectEqual(@as(u8, 0x64), cells[10 * submap_w + 10]);
    try std.testing.expectEqual(@as(u8, 0x65), cells[10 * submap_w + 11]);
    try std.testing.expectEqual(@as(u8, 0x66), cells[11 * submap_w + 10]);
    try std.testing.expectEqual(@as(u8, 0x67), cells[11 * submap_w + 11]);
}

test "openSecretDoorCells finds $60 at player-7 corner" {
    var cells = [_]u8{0} ** (submap_w * submap_h);
    cells[8 * submap_w + 8] = 0x60;
    try std.testing.expect(openSecretDoorCells(&cells, 15, 15));
    try std.testing.expectEqual(@as(u8, 0x64), cells[8 * submap_w + 8]);
}

test "openSecretDoorCells misses outside window" {
    var cells = [_]u8{0} ** (submap_w * submap_h);
    cells[0] = 0x60;
    try std.testing.expect(!openSecretDoorCells(&cells, 20, 20));
    try std.testing.expectEqual(@as(u8, 0x60), cells[0]);
}

test "openSecretDoorCells clamps negative base_y like ROM adc #$0f" {
    var cells = [_]u8{0} ** (submap_w * submap_h);
    cells[0 * submap_w + 5] = 0x60;
    try std.testing.expect(openSecretDoorCells(&cells, 12, 3));
    try std.testing.expectEqual(@as(u8, 0x64), cells[0 * submap_w + 5]);
}

// --- DoPoisonDmg / DoFloorDmg (trigger.asm @97b3 / @97ff) --------------------

/// Apply one poison tick to HP (DoPoisonDmg): −1, floor at 1; no-op if hp==0.
pub fn applyPoisonHp(hp: u16) u16 {
    if (hp == 0) return 0;
    if (hp > 1) return hp - 1;
    return 1;
}

/// Apply one floor-damage tick (DoFloorDmg): −50, floor at 1; no-op if hp==0.
pub fn applyFloorHp(hp: u16) u16 {
    if (hp == 0) return 0;
    if (hp > 50) return hp - 50;
    return 1;
}

/// DoFloorDmg eligibility: present, not dead (status1 bit7), not float (status2 bit6).
pub fn floorDmgEligible(present: bool, status1: u8, status2: u8) bool {
    if (!present) return false;
    if ((status1 & status_mod.Status1.dead) != 0) return false;
    if ((status2 & status_mod.Status2.float_bit) != 0) return false;
    return true;
}

/// DoPoisonDmg eligibility: present + poison bit0.
pub fn poisonDmgEligible(present: bool, status1: u8) bool {
    if (!present) return false;
    return (status1 & status_mod.Status1.poison) != 0;
}

/// SFX ids from trigger.asm: poison `$7A`, floor `$7B`.
pub const sfx_poison_dmg: u8 = 0x7A;
pub const sfx_floor_dmg: u8 = 0x7B;

/// WhaleButton land (vehicle.asm @a851): ExecTriggerScript `$52` when `$b1==0`.
pub const whale_land_trigger_script: u8 = 0x52;

/// EventCmd_d8 FadeOutSongSlow → SPC cmd `$85` (field.asm @8d53).
/// Host stand-in: song_fade_mode=1, gain num 16→0 every 4 fields @ den 16.
pub const fade_out_song_slow_spc: u8 = 0x85;
pub const song_fade_slow_start_num: u8 = 16;
pub const song_fade_slow_period: u8 = 4;

/// One period step of host slow song fade. Returns new (num, done).
pub fn stepSongFadeSlow(gain_num: u8) struct { num: u8, done: bool } {
    if (gain_num > 0) return .{ .num = gain_num - 1, .done = false };
    return .{ .num = 0, .done = true };
}

test "DoPoisonDmg hp clamp" {
    try std.testing.expectEqual(@as(u16, 9), applyPoisonHp(10));
    try std.testing.expectEqual(@as(u16, 1), applyPoisonHp(1));
    try std.testing.expectEqual(@as(u16, 1), applyPoisonHp(2));
    try std.testing.expectEqual(@as(u16, 0), applyPoisonHp(0));
    try std.testing.expect(poisonDmgEligible(true, status_mod.Status1.poison));
    try std.testing.expect(!poisonDmgEligible(true, 0));
    try std.testing.expect(!poisonDmgEligible(false, status_mod.Status1.poison));
}

test "DoFloorDmg hp clamp and eligibility" {
    try std.testing.expectEqual(@as(u16, 50), applyFloorHp(100));
    try std.testing.expectEqual(@as(u16, 1), applyFloorHp(50));
    try std.testing.expectEqual(@as(u16, 1), applyFloorHp(49));
    try std.testing.expectEqual(@as(u16, 0), applyFloorHp(0));
    try std.testing.expect(floorDmgEligible(true, 0, 0));
    try std.testing.expect(!floorDmgEligible(true, status_mod.Status1.dead, 0));
    try std.testing.expect(!floorDmgEligible(true, 0, status_mod.Status2.float_bit));
    try std.testing.expect(!floorDmgEligible(false, 0, 0));
    try std.testing.expectEqual(@as(u8, 0x7A), sfx_poison_dmg);
    try std.testing.expectEqual(@as(u8, 0x7B), sfx_floor_dmg);
}

test "whale land trigger script $52" {
    try std.testing.expectEqual(@as(u8, 0x52), whale_land_trigger_script);
}

test "FadeOutSongSlow host gain ramp" {
    try std.testing.expectEqual(@as(u8, 0x85), fade_out_song_slow_spc);
    var num: u8 = song_fade_slow_start_num;
    var steps: usize = 0;
    while (true) {
        const r = stepSongFadeSlow(num);
        steps += 1;
        if (r.done) break;
        num = r.num;
    }
    // 16 decrements then done on the 17th call with num=0.
    try std.testing.expectEqual(@as(usize, 17), steps);
    try std.testing.expectEqual(@as(u8, 0), stepSongFadeSlow(0).num);
}
