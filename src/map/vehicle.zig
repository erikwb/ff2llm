//! World-map vehicles — decomp field/vehicle.asm + field/sprite.asm + field/field.asm.
//!
//! `$1704` ids, PlayerSpeedTbl, VehiclePassBit (in overworld.zig), board/land anim,
//! VehicleSpriteTbl tile banks, DrawRedWings, ChocoSpriteTbl.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("../gfx/snes.zig");

/// VehicleGfx @ 1C/8000 → file 0xE0000 (3bpp). LoadVehicleGfx transfers `$1d00` bytes.
const vehicle_gfx: usize = 0xE0000;
/// Chocobo @ 1B/C680 → 0xDC680 (LoadVehicleGfx first transfer `$0100` bytes).
const choco_gfx: usize = 0xDC680;
const map_sprite_pal: usize = 0x68000;
/// VehicleSpriteTbl OAM attr `$20` → palette bits ppp=0 (sprite.asm @bfb4).
const vehicle_pal_index: usize = 0;
/// ChocoSpriteTbl OAM attr `$38` → ppp=4 (sprite.asm @c034).
const choco_pal_index: usize = 4;

const bytes_per_tile: usize = 24;
/// LoadVehicleGfx transfers `$1d00` 3bpp bytes → 309 tiles (covers whale OAM names `$fa`+).
const vehicle_tile_count: usize = 0x1D00 / bytes_per_tile; // 309
pub const vehicle_tile_count_pub: usize = vehicle_tile_count;
const choco_tile_count: usize = 16;

/// `$1704` vehicle ids (RAM map).
pub const id_none: u8 = 0;
pub const id_chocobo: u8 = 1;
pub const id_black_chocobo: u8 = 2;
pub const id_hovercraft: u8 = 3;
pub const id_enterprise: u8 = 4;
pub const id_falcon: u8 = 5;
pub const id_whale: u8 = 6;
pub const id_ship: u8 = 7;

/// PlayerSpeedTbl (field.asm @830c).
pub const player_speed_tbl = [_]u8{ 0, 1, 2, 1, 3, 3, 3, 1 };
/// PlayerMoveRateTbl (move.asm @ad12).
pub const player_move_rate_tbl = [_]u8{ 1, 2, 4, 8 };
/// AirshipAnimMask (sprite.asm @be37) — `$7a & mask` for frame B; index `$06fd`.
pub const airship_anim_mask = [_]u8{
    0x10, 0x10, 0x10, 0x08, 0x08, 0x08, 0x08, 0x04, 0x08, 0x04, 0x04, 0x04, 0x02, 0x02, 0x02, 0x02,
};

/// ZoomVehicleTbl (sprite.asm @bfa8) — CalcVehicleSpritePos tiers for `$ad>>4 - 1`.
/// Layout: x_base[3], x_range[3], y_base[3], y_range[3].
pub const zoom_vehicle_tbl = struct {
    pub const x_base = [_]u8{ 0x09, 0x13, 0x20 };
    pub const x_range = [_]u8{ 0x13, 0x2C, 0x42 };
    pub const y_base = [_]u8{ 0x08, 0x17, 0x1F };
    pub const y_range = [_]u8{ 0x10, 0x21, 0x2C };
};

/// Zoom tier from `$ad` (CalcVehicleSpritePos @be4b): `($ad>>4)-1`, clamped 0..2.
pub fn zoomTier(mode7_ad: u8) u8 {
    const t: i16 = @as(i16, mode7_ad >> 4) - 1;
    if (t < 0) return 0;
    if (t > 2) return 2;
    return @intCast(t);
}

/// Signed wrap delta for MapSizeMask maps.
fn wrapDelta(a: i32, b: i32, mask: i32) i32 {
    const size = mask + 1;
    var d = (a - b) & mask;
    if (d >= @divTrunc(size, 2)) d -= size;
    return d;
}

/// _14f380 (field_data.asm) — tier-1 perspective Y LUT (33 entries).
const perspective_y_t1 = [_]u8{
    0x00, 0x03, 0x07, 0x0A, 0x0F, 0x13, 0x17, 0x1B, 0x20, 0x25, 0x2A, 0x2F, 0x34, 0x39, 0x3E, 0x44,
    0x4A, 0x50, 0x56, 0x5D, 0x64, 0x6B, 0x72, 0x7A, 0x82, 0x8B, 0x94, 0x9D, 0xA8, 0xB3, 0xBF, 0xCC,
    0xDA,
};

/// _14f3a1 (field_data.asm) — tier-2 (whale) perspective Y LUT (45 entries).
const perspective_y_t2 = [_]u8{
    0x00, 0x02, 0x04, 0x06, 0x09, 0x0C, 0x0F, 0x12, 0x16, 0x19, 0x1C, 0x1F, 0x23, 0x27, 0x2A, 0x2D,
    0x31, 0x35, 0x39, 0x3D, 0x41, 0x46, 0x4A, 0x4F, 0x54, 0x59, 0x5E, 0x63, 0x68, 0x6D, 0x73, 0x79,
    0x7F, 0x86, 0x8C, 0x93, 0x9A, 0xA2, 0xAA, 0xB2, 0xBB, 0xC4, 0xCD, 0xD8, 0xE4,
};

/// _14f000 (field_data.asm) — tier-1 scale factors, indexed by Y LUT value (224 words).
const perspective_scale_t1 = [_]u16{
    0x0555, 0x055B, 0x0562, 0x0568, 0x056E, 0x0574, 0x057A, 0x0580,
    0x0586, 0x058C, 0x0593, 0x0599, 0x059F, 0x05A5, 0x05AB, 0x05B1,
    0x05B7, 0x05BD, 0x05C4, 0x05CA, 0x05D0, 0x05D6, 0x05DC, 0x05E2,
    0x05E8, 0x05EE, 0x05F5, 0x05FB, 0x0601, 0x0607, 0x060D, 0x0613,
    0x0619, 0x061F, 0x0626, 0x062C, 0x0632, 0x0638, 0x063E, 0x0644,
    0x064A, 0x0650, 0x0656, 0x065D, 0x0663, 0x0669, 0x066F, 0x0675,
    0x067B, 0x0681, 0x0687, 0x068E, 0x0694, 0x069A, 0x06A0, 0x06A6,
    0x06AC, 0x06B2, 0x06B8, 0x06BF, 0x06C5, 0x06CB, 0x06D1, 0x06D7,
    0x06DD, 0x06E3, 0x06E9, 0x06F0, 0x06F6, 0x06FC, 0x0702, 0x0708,
    0x070E, 0x0714, 0x071A, 0x0721, 0x0727, 0x072D, 0x0733, 0x0739,
    0x073F, 0x0745, 0x074B, 0x0752, 0x0758, 0x075E, 0x0764, 0x076A,
    0x0770, 0x0776, 0x077C, 0x0782, 0x0789, 0x078F, 0x0795, 0x079B,
    0x07A1, 0x07A7, 0x07AD, 0x07B3, 0x07BA, 0x07C0, 0x07C6, 0x07CC,
    0x07D2, 0x07D8, 0x07DE, 0x07E4, 0x07EB, 0x07F1, 0x07F7, 0x07FD,
    0x0803, 0x0809, 0x080F, 0x0815, 0x081C, 0x0822, 0x0828, 0x082E,
    0x0834, 0x083A, 0x0840, 0x0846, 0x084D, 0x0853, 0x0859, 0x085F,
    0x0865, 0x086B, 0x0871, 0x0877, 0x087E, 0x0884, 0x088A, 0x0890,
    0x0896, 0x089C, 0x08A2, 0x08A8, 0x08AE, 0x08B5, 0x08BB, 0x08C1,
    0x08C7, 0x08CD, 0x08D3, 0x08D9, 0x08DF, 0x08E6, 0x08EC, 0x08F2,
    0x08F8, 0x08FE, 0x0904, 0x090A, 0x0910, 0x0917, 0x091D, 0x0923,
    0x0929, 0x092F, 0x0935, 0x093B, 0x0941, 0x0948, 0x094E, 0x0954,
    0x095A, 0x0960, 0x0966, 0x096C, 0x0972, 0x0979, 0x097F, 0x0985,
    0x098B, 0x0991, 0x0997, 0x099D, 0x09A3, 0x09AA, 0x09B0, 0x09B6,
    0x09BC, 0x09C2, 0x09C8, 0x09CE, 0x09D4, 0x09DA, 0x09E1, 0x09E7,
    0x09ED, 0x09F3, 0x09F9, 0x09FF, 0x0A05, 0x0A0B, 0x0A12, 0x0A18,
    0x0A1E, 0x0A24, 0x0A2A, 0x0A30, 0x0A36, 0x0A3C, 0x0A43, 0x0A49,
    0x0A4F, 0x0A55, 0x0A5B, 0x0A61, 0x0A67, 0x0A6D, 0x0A74, 0x0A7A,
    0x0A80, 0x0A86, 0x0A8C, 0x0A92, 0x0A98, 0x0A9E, 0x0AA5, 0x0AAB,
};

/// _14f1c0 (field_data.asm) — tier-2 scale factors, indexed by Y LUT value (224 words).
const perspective_scale_t2 = [_]u16{
    0x0400, 0x0405, 0x0409, 0x040E, 0x0412, 0x0417, 0x041C, 0x0420,
    0x0425, 0x0429, 0x042E, 0x0433, 0x0437, 0x043C, 0x0440, 0x0445,
    0x0449, 0x044E, 0x0453, 0x0457, 0x045C, 0x0460, 0x0465, 0x046A,
    0x046E, 0x0473, 0x0477, 0x047C, 0x0481, 0x0485, 0x048A, 0x048E,
    0x0493, 0x0498, 0x049C, 0x04A1, 0x04A5, 0x04AA, 0x04AE, 0x04B3,
    0x04B8, 0x04BC, 0x04C1, 0x04C5, 0x04CA, 0x04CF, 0x04D3, 0x04D8,
    0x04DC, 0x04E1, 0x04E6, 0x04EA, 0x04EF, 0x04F3, 0x04F8, 0x04FD,
    0x0501, 0x0506, 0x050A, 0x050F, 0x0514, 0x0518, 0x051D, 0x0521,
    0x0526, 0x052A, 0x052F, 0x0534, 0x0538, 0x053D, 0x0541, 0x0546,
    0x054B, 0x054F, 0x0554, 0x0558, 0x055D, 0x0562, 0x0566, 0x056B,
    0x056F, 0x0574, 0x0579, 0x057D, 0x0582, 0x0586, 0x058B, 0x058F,
    0x0594, 0x0599, 0x059D, 0x05A2, 0x05A6, 0x05AB, 0x05B0, 0x05B4,
    0x05B9, 0x05BD, 0x05C2, 0x05C7, 0x05CB, 0x05D0, 0x05D4, 0x05D9,
    0x05DE, 0x05E2, 0x05E7, 0x05EB, 0x05F0, 0x05F5, 0x05F9, 0x05FE,
    0x0602, 0x0607, 0x060B, 0x0610, 0x0615, 0x0619, 0x061E, 0x0622,
    0x0627, 0x062C, 0x0630, 0x0635, 0x0639, 0x063E, 0x0643, 0x0647,
    0x064C, 0x0650, 0x0655, 0x065A, 0x065E, 0x0663, 0x0667, 0x066C,
    0x0671, 0x0675, 0x067A, 0x067E, 0x0683, 0x0687, 0x068C, 0x0691,
    0x0695, 0x069A, 0x069E, 0x06A3, 0x06A8, 0x06AC, 0x06B1, 0x06B5,
    0x06BA, 0x06BF, 0x06C3, 0x06C8, 0x06CC, 0x06D1, 0x06D6, 0x06DA,
    0x06DF, 0x06E3, 0x06E8, 0x06EC, 0x06F1, 0x06F6, 0x06FA, 0x06FF,
    0x0703, 0x0708, 0x070D, 0x0711, 0x0716, 0x071A, 0x071F, 0x0724,
    0x0728, 0x072D, 0x0731, 0x0736, 0x073B, 0x073F, 0x0744, 0x0748,
    0x074D, 0x0752, 0x0756, 0x075B, 0x075F, 0x0764, 0x0768, 0x076D,
    0x0772, 0x0776, 0x077B, 0x077F, 0x0784, 0x0789, 0x078D, 0x0792,
    0x0796, 0x079B, 0x07A0, 0x07A4, 0x07A9, 0x07AD, 0x07B2, 0x07B7,
    0x07BB, 0x07C0, 0x07C4, 0x07C9, 0x07CD, 0x07D2, 0x07D7, 0x07DB,
    0x07E0, 0x07E4, 0x07E9, 0x07EE, 0x07F2, 0x07F7, 0x07FB, 0x0800,
};

/// Screen position from CalcVehicleSpritePos.
pub const VehicleSpritePos = struct { x: i32, y: i32 };

/// CalcVehicleSpritePos (sprite.asm @be47) — screen pos of parked vehicle, or null if off-screen.
///
/// Tier 0 (low `$ad`): tile→pixel `*16` with fine-scroll subtract (foot / low hover).
/// Tier 1–2 (airship / whale altitude): `_14f380`/`_14f3a1` Y LUT + `_14f000`/`_14f1c0`
/// scale × Mult16, screen X = `$78 ± (product>>9)`.
pub fn calcVehicleSpritePos(
    veh_x: i32,
    veh_y: i32,
    player_x: i32,
    player_y: i32,
    fine_x: i32,
    fine_y: i32,
    mode7_ad: u8,
    size_mask: i32,
) ?VehicleSpritePos {
    const tier: usize = zoomTier(mode7_ad);
    const xb: i32 = zoom_vehicle_tbl.x_base[tier];
    const xr: i32 = zoom_vehicle_tbl.x_range[tier];
    const yb: i32 = zoom_vehicle_tbl.y_base[tier];
    const yr: i32 = zoom_vehicle_tbl.y_range[tier];

    // ROM: (veh + base - player) as unsigned tile delta; we use signed wrap.
    const dx = wrapDelta(veh_x, player_x, size_mask) + xb;
    const dy = wrapDelta(veh_y, player_y, size_mask) + yb;
    // cmp range; bcc visible — unsigned, so 0..range-1
    if (dx < 0 or dx >= xr or dy < 0 or dy >= yr) return null;

    if (tier == 0) {
        // @be68: dec2 / asl4 → (dx-2)*16 - fine_x; y: (dy-1)*16 - fine_y
        const sx = (dx - 2) * 16 - fine_x;
        const sy = (dy - 1) * 16 - fine_y - 2;
        return .{ .x = sx, .y = sy };
    }

    // @bec1–@bfa4: perspective for tier 1 (airship) / tier 2 (whale).
    return calcFlyingSpritePos(tier, dx, dy, fine_x, fine_y);
}

/// Mult16 (field.asm @c38f) then `lsr $32 / ror $31` → byte at product bits 9–16.
fn mult16Shift9(scale: u16, abs_x: u8) u8 {
    const product: u32 = @as(u32, scale) * @as(u32, abs_x);
    return @truncate(product >> 9);
}

/// Flying path @bec1: Y from perspective LUT (half-step interp when fine_y≠0),
/// X = $78 ± Mult16(scale[y], |2·dx − fine_x_bit − center|).
fn calcFlyingSpritePos(
    tier: usize,
    dx: i32,
    dy: i32,
    fine_x: i32,
    fine_y: i32,
) ?VehicleSpritePos {
    const y_lut: []const u8 = if (tier == 2) &perspective_y_t2 else &perspective_y_t1;
    const scale_tbl: []const u16 = if (tier == 2) &perspective_scale_t2 else &perspective_scale_t1;
    // tier1: sbc #$26; tier2: sbc #$40
    const x_center: i32 = if (tier == 2) 0x40 else 0x26;

    const dy_u: usize = @intCast(dy);
    if (dy_u >= y_lut.len) return null;

    // Y: direct LUT if fine_y&$0f==0; else mid-interp between [dy-1] and [dy].
    const screen_y: u8 = blk: {
        if ((fine_y & 0x0f) == 0) {
            break :blk y_lut[dy_u];
        }
        // @bed8/@bf38: dy==0 with subpixel → off-screen
        if (dy_u == 0) return null;
        const lo = y_lut[dy_u - 1];
        const hi = y_lut[dy_u];
        break :blk lo +% ((hi -% lo) >> 1);
    };

    if (screen_y >= scale_tbl.len) return null;
    const scale = scale_tbl[screen_y];

    // X: asl $0c; sbc (fine_x&$08)>>3; sbc center; abs if minus ($0a flag).
    const fine_x_bit: i32 = (fine_x & 0x08) >> 3;
    var abs_x: i32 = dx * 2 - fine_x_bit - x_center;
    var left = false;
    if (abs_x < 0) {
        left = true;
        // 8-bit two's complement negate (eor #$ff / inc)
        abs_x = (-abs_x) & 0xff;
    } else {
        abs_x &= 0xff;
    }

    const x_off: u8 = mult16Shift9(scale, @intCast(abs_x));

    // @bf85: screen X = $78 ± x_off; carry/borrow → off-screen
    const sx: i32 = if (!left) blk: {
        const sum = @as(u16, 0x78) + x_off;
        if (sum > 0xff) return null;
        break :blk sum;
    } else blk: {
        if (x_off > 0x78) return null;
        break :blk @as(i32, 0x78) - x_off;
    };

    return .{ .x = sx, .y = @as(i32, screen_y) };
}

/// Pixel size of one world metatile at current `$ad` (InitZoomHDMA center scale).
pub fn worldTilePx(mode7_ad: u8, whale: bool) i32 {
    const ow = @import("overworld.zig");
    return ow.mode7TilePx(mode7_ad, whale);
}

/// VehicleSongTbl (field.asm @8d92) — 7 bytes indexed by `$1704`; ship `$07` reuses whale `$0E`.
pub const vehicle_song_tbl = [_]u8{ 0x0D, 0x04, 0x05, 0x0D, 0x18, 0x18, 0x0E, 0x0E };

/// Song id for PlayMapSong when `$1704 == vehicle` (0 → caller uses world/sub song).
pub fn songForVehicle(vehicle: u8) ?u8 {
    if (vehicle == 0) return null;
    if (vehicle >= vehicle_song_tbl.len) return null;
    return vehicle_song_tbl[vehicle];
}

test "VehicleSongTbl matches field.asm @8d92" {
    try std.testing.expectEqual(@as(u8, 0x0D), vehicle_song_tbl[0]); // unused index 0
    try std.testing.expectEqual(@as(u8, 0x04), vehicle_song_tbl[id_chocobo]);
    try std.testing.expectEqual(@as(u8, 0x05), vehicle_song_tbl[id_black_chocobo]);
    try std.testing.expectEqual(@as(u8, 0x0D), vehicle_song_tbl[id_hovercraft]);
    try std.testing.expectEqual(@as(u8, 0x18), vehicle_song_tbl[id_enterprise]);
    try std.testing.expectEqual(@as(u8, 0x18), vehicle_song_tbl[id_falcon]);
    try std.testing.expectEqual(@as(u8, 0x0E), vehicle_song_tbl[id_whale]);
    try std.testing.expectEqual(@as(u8, 0x0E), vehicle_song_tbl[id_ship]);
    try std.testing.expectEqual(@as(?u8, 0x18), songForVehicle(id_enterprise));
    try std.testing.expect(songForVehicle(0) == null);
}

/// Draw* tile addend on VehicleSpriteTbl character (sprite.asm).
fn tileBank(vehicle: u8) u8 {
    return switch (vehicle) {
        id_hovercraft => 0x48,
        id_ship => 0x60,
        id_enterprise => 0x78,
        id_black_chocobo => 0x90,
        id_whale => 0x00, // DrawWhale uses WhaleSpriteTiles absolute names, not bank+$A8
        id_falcon => 0xD8,
        else => 0x00, // base airship / red wings
    };
}

/// WhaleFlashPal (special.asm @cf13) — LoadWhaleFlashPal animates `$0ebb` with `$7a`.
pub const whale_flash_pal = [_]u16{
    0x6108, 0x4010, 0x2118, 0x021F, 0x2318, 0x43F0, 0x6308, 0x7E00,
};

/// WhalePal (pal_anim.asm @c3da) — UpdateWhalePal cycles one color while riding.
pub const whale_anim_pal = [_]u16{
    0x021F, 0x0198, 0x0110, 0x0088, 0x0088, 0x0110, 0x0198, 0x021F,
};

/// MapSpritePal+31 (explosion / fire) — `_00e075` when `$0ace==0`.
pub const explosion_pal_fire = [_]u16{
    0x0000, 0x4BFF, 0x337F, 0x1ABF, 0x01FF, 0x0139, 0x0073, 0x000C,
};
/// MapSpritePal+32 (sand / dust) — `$0ace!=0`.
pub const explosion_pal_sand = [_]u16{
    0x0000, 0x7FFF, 0x6BBE, 0x635B, 0x56F9, 0x4695, 0x4653, 0x3611,
};

/// `_00e1b4` — stage → `_14f9d6` frame base (byte offset into 16-byte frames).
pub const explosion_stage_tbl = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x20, 0x30, 0x20, 0x30 };

/// `_14f9d6` — 4 frames × 4 OAM entries × (dx, dy, tile, attr). dy `$ff` = hide (`$f0`).
pub const explosion_oam_tbl = [_][4]u8{
    // frame 0 — tile $c8
    .{ 0xF8, 0xF8, 0xC8, 0x31 }, .{ 0x00, 0xFF, 0xC8, 0x71 },
    .{ 0xF0, 0xFF, 0xC8, 0xB1 }, .{ 0x00, 0xFF, 0xC8, 0xF1 },
    // frame 1 — $ca
    .{ 0xF8, 0xF8, 0xCA, 0x31 }, .{ 0x00, 0xFF, 0xCA, 0x71 },
    .{ 0xF0, 0xFF, 0xCA, 0xB1 }, .{ 0x00, 0xFF, 0xCA, 0xF1 },
    // frame 2 — $cc/$ce 16²
    .{ 0xF0, 0xF0, 0xCC, 0x31 }, .{ 0x00, 0xF0, 0xCE, 0x31 },
    .{ 0xF0, 0x00, 0xCC, 0xB1 }, .{ 0x00, 0x00, 0xCE, 0xB1 },
    // frame 3 — $e0/$e2
    .{ 0xF0, 0xF0, 0xE0, 0x31 }, .{ 0x00, 0xF0, 0xE2, 0x31 },
    .{ 0xF0, 0x00, 0xE0, 0xB1 }, .{ 0x00, 0x00, 0xE2, 0xB1 },
};

/// Apply WhaleFlashPal frame (`$7a & $1e` indexes word pairs) into `out` (8 colors).
pub fn applyWhaleFlashPal(snes_7a: u8, out: *[8]snes.Color) void {
    const base: usize = snes_7a & 0x1E;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const wi = (base / 2 + i) % whale_flash_pal.len;
        out[i] = snes.Color.fromSnes(whale_flash_pal[wi]);
        out[i].a = 255;
    }
    out[0].a = 0;
}

/// UpdateWhalePal (@c3bd): pulse palette color from WhalePal[`($7a>>2)&$0e`].
pub fn whaleAnimColor(snes_7a: u8) snes.Color {
    const idx: usize = (snes_7a >> 2) & 0x0E;
    const wi = @min(idx / 2, whale_anim_pal.len - 1);
    var c = snes.Color.fromSnes(whale_anim_pal[wi]);
    c.a = 255;
    return c;
}

/// WhaleSpritePos (sprite.asm @bd97) — 16 × (x,y) for 4×4 of 8×8 tiles.
const whale_sprite_pos = [_][2]i8{
    .{ 0x08, -0x03 }, .{ 0x10, -0x03 }, .{ 0x18, -0x03 }, .{ 0x20, -0x03 },
    .{ 0x08, 0x05 }, .{ 0x10, 0x05 }, .{ 0x18, 0x05 }, .{ 0x20, 0x05 },
    .{ 0x08, 0x0D }, .{ 0x10, 0x0D }, .{ 0x18, 0x0D }, .{ 0x20, 0x0D },
    .{ 0x08, 0x15 }, .{ 0x10, 0x15 }, .{ 0x18, 0x15 }, .{ 0x20, 0x15 },
};

/// WhaleSpriteTiles (sprite.asm @bdb7) — 4 facings × 16 × (tile, attr).
/// Attr bit0 = 9th name bit (+256); bit6 = hflip.
const whale_sprite_tiles = [_][2]u8{
    // up
    .{ 0x0A, 0x2F }, .{ 0x0B, 0x2F }, .{ 0x0C, 0x2F }, .{ 0x0A, 0x6F },
    .{ 0x0E, 0x2F }, .{ 0x0F, 0x2F }, .{ 0x10, 0x2F }, .{ 0x0E, 0x6F },
    .{ 0x12, 0x2F }, .{ 0x13, 0x2F }, .{ 0x14, 0x2F }, .{ 0x12, 0x6F },
    .{ 0x16, 0x2F }, .{ 0x17, 0x2F }, .{ 0x18, 0x2F }, .{ 0x19, 0x2F },
    // right
    .{ 0x1D, 0x6F }, .{ 0x0D, 0x6F }, .{ 0x1B, 0x6F }, .{ 0x1A, 0x6F },
    .{ 0x21, 0x6F }, .{ 0x20, 0x6F }, .{ 0x1F, 0x6F }, .{ 0x1E, 0x6F },
    .{ 0x25, 0x6F }, .{ 0x24, 0x6F }, .{ 0x23, 0x6F }, .{ 0x22, 0x6F },
    .{ 0x0D, 0x6F }, .{ 0x28, 0x6F }, .{ 0x27, 0x6F }, .{ 0x26, 0x6F },
    // down
    .{ 0xFA, 0x2E }, .{ 0xFB, 0x2E }, .{ 0xFC, 0x2E }, .{ 0xFA, 0x6E },
    .{ 0xFE, 0x2E }, .{ 0xFF, 0x2E }, .{ 0x00, 0x2F }, .{ 0x0D, 0x6F },
    .{ 0x02, 0x2F }, .{ 0x03, 0x2F }, .{ 0x04, 0x2F }, .{ 0x02, 0x6F },
    .{ 0x06, 0x2F }, .{ 0x07, 0x2F }, .{ 0x08, 0x2F }, .{ 0x06, 0x6F },
    // left
    .{ 0x1A, 0x2F }, .{ 0x1B, 0x2F }, .{ 0x0D, 0x2F }, .{ 0x1D, 0x2F },
    .{ 0x1E, 0x2F }, .{ 0x1F, 0x2F }, .{ 0x20, 0x2F }, .{ 0x21, 0x2F },
    .{ 0x22, 0x2F }, .{ 0x23, 0x2F }, .{ 0x24, 0x2F }, .{ 0x25, 0x2F },
    .{ 0x26, 0x2F }, .{ 0x27, 0x2F }, .{ 0x28, 0x2F }, .{ 0x0D, 0x2F },
};

/// OAM count for standard VehicleSpriteTbl draw (ship/airship/hover: 4 × 8×8 = 16×16).
pub const vehicle_oam_count: usize = 4;
/// DrawWhale: 4×4 grid of 8×8 (sprite.asm @bc2f).
pub const whale_oam_count: usize = 16;
/// HoverSpriteTbl bank: 4 sprites per facing (DrawHover @b7eb `cpy #$0010`).
pub const hover_oam_count: usize = 4;

/// Vehicle multi-OAM count by vehicle id (V5).
pub fn vehicleOamCount(vehicle: u8) usize {
    return switch (vehicle) {
        id_whale => whale_oam_count,
        id_hovercraft => hover_oam_count,
        id_chocobo, id_black_chocobo => vehicle_oam_count, // ChocoSpriteTbl 4 tiles
        else => vehicle_oam_count, // ship / enterprise / falcon / airship
    };
}

/// VehicleSpriteTbl @ sprite.asm $bfb4.
const vehicle_sprite_tbl = [_][4]u8{
    .{ 0x00, 0x00, 0x08, 0x20 }, .{ 0x08, 0x00, 0x09, 0x20 },
    .{ 0x00, 0x08, 0x0A, 0x20 }, .{ 0x08, 0x08, 0x0B, 0x20 },
    .{ 0x00, 0x00, 0x0C, 0x20 }, .{ 0x08, 0x00, 0x0D, 0x20 },
    .{ 0x00, 0x08, 0x0E, 0x20 }, .{ 0x08, 0x08, 0x0F, 0x20 },
    .{ 0x00, 0x00, 0x11, 0x60 }, .{ 0x08, 0x00, 0x10, 0x60 },
    .{ 0x00, 0x08, 0x13, 0x60 }, .{ 0x08, 0x08, 0x12, 0x60 },
    .{ 0x00, 0x00, 0x15, 0x60 }, .{ 0x08, 0x00, 0x14, 0x60 },
    .{ 0x00, 0x08, 0x17, 0x60 }, .{ 0x08, 0x08, 0x16, 0x60 },
    .{ 0x00, 0x00, 0x00, 0x20 }, .{ 0x08, 0x00, 0x01, 0x20 },
    .{ 0x00, 0x08, 0x02, 0x20 }, .{ 0x08, 0x08, 0x03, 0x20 },
    .{ 0x00, 0x00, 0x04, 0x20 }, .{ 0x08, 0x00, 0x05, 0x20 },
    .{ 0x00, 0x08, 0x06, 0x20 }, .{ 0x08, 0x08, 0x07, 0x20 },
    .{ 0x00, 0x00, 0x10, 0x20 }, .{ 0x08, 0x00, 0x11, 0x20 },
    .{ 0x00, 0x08, 0x12, 0x20 }, .{ 0x08, 0x08, 0x13, 0x20 },
    .{ 0x00, 0x00, 0x14, 0x20 }, .{ 0x08, 0x00, 0x15, 0x20 },
    .{ 0x00, 0x08, 0x16, 0x20 }, .{ 0x08, 0x08, 0x17, 0x20 },
};

/// ChocoSpriteTbl @ sprite.asm $c034.
const choco_sprite_tbl = [_][4]u8{
    .{ 0x00, 0x00, 0x24, 0x38 }, .{ 0x08, 0x00, 0x25, 0x38 },
    .{ 0x00, 0x08, 0x26, 0x38 }, .{ 0x08, 0x08, 0x27, 0x38 },
    .{ 0x00, 0x00, 0x25, 0x78 }, .{ 0x08, 0x00, 0x24, 0x78 },
    .{ 0x00, 0x08, 0x27, 0x78 }, .{ 0x08, 0x08, 0x26, 0x78 },
    .{ 0x00, 0x00, 0x29, 0x78 }, .{ 0x08, 0x00, 0x28, 0x78 },
    .{ 0x00, 0x08, 0x2B, 0x78 }, .{ 0x08, 0x08, 0x2A, 0x78 },
    .{ 0x00, 0x00, 0x2D, 0x78 }, .{ 0x08, 0x00, 0x2C, 0x78 },
    .{ 0x00, 0x08, 0x2F, 0x78 }, .{ 0x08, 0x08, 0x2E, 0x78 },
    .{ 0x00, 0x00, 0x20, 0x38 }, .{ 0x08, 0x00, 0x21, 0x38 },
    .{ 0x00, 0x08, 0x22, 0x38 }, .{ 0x08, 0x08, 0x23, 0x38 },
    .{ 0x00, 0x00, 0x21, 0x78 }, .{ 0x08, 0x00, 0x20, 0x78 },
    .{ 0x00, 0x08, 0x23, 0x78 }, .{ 0x08, 0x08, 0x22, 0x78 },
    .{ 0x00, 0x00, 0x28, 0x38 }, .{ 0x08, 0x00, 0x29, 0x38 },
    .{ 0x00, 0x08, 0x2A, 0x38 }, .{ 0x08, 0x08, 0x2B, 0x38 },
    .{ 0x00, 0x00, 0x2C, 0x38 }, .{ 0x08, 0x00, 0x2D, 0x38 },
    .{ 0x00, 0x08, 0x2E, 0x38 }, .{ 0x08, 0x08, 0x2F, 0x38 },
};

/// HookYTbl (vehicle.asm @a6e2) — GrabHover / DropHover.
pub const hook_y_tbl = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0 };

/// GrabHover / DropHover total frames (`$79` 0..$3F).
pub const hover_hook_frames: u8 = 0x40;
/// Frame when `$06d0` toggles (GrabHover @a755 / DropHover @a726).
pub const hover_hook_mid: u8 = 0x20;
/// Event switch `$36` must be set to GrabHover (LandEnterprise @a60b).
pub const grab_hover_event_switch: u8 = 0x36;
/// DropHover needs `$a1 & $10` (prop_lo landable bit).
pub const drop_hover_tile_bit: u8 = 0x10;

/// HookYTbl[`$79 >> 2`] for frame `$79` in 0..$3F.
pub fn hookYAtFrame(timer: u8) u8 {
    const idx = @min(@as(usize, timer >> 2), hook_y_tbl.len - 1);
    return hook_y_tbl[idx];
}

/// True at the frame GrabHover sets `$06d0` / DropHover clears it.
pub fn hoverHookToggleFrame(timer: u8) bool {
    return timer == hover_hook_mid;
}

/// GrabHover eligibility (LandEnterprise @a61c): event `$36`, hover visible,
/// same world as enterprise, same tile as party (`$1706` == hover xy).
pub fn canGrabHover(
    event_switch_36: bool,
    holding_hover: bool,
    hover_vis: u8,
    hover_world: u8,
    hover_x: u8,
    hover_y: u8,
    enterprise_world: u8,
    party_x: u8,
    party_y: u8,
) bool {
    if (holding_hover) return false;
    if (!event_switch_36) return false;
    if (hover_vis == 0) return false;
    if (hover_world != enterprise_world) return false;
    return hover_x == party_x and hover_y == party_y;
}

/// DropHover eligibility (LandEnterprise @a630): holding hover, not on falcon/whale,
/// and `$a1&$10` landable (caller passes `tile_allows_drop`).
pub fn canDropHover(
    holding_hover: bool,
    tile_allows_drop: bool,
    party_x: u8,
    party_y: u8,
    party_world: u8,
    falcon_vis: u8,
    falcon_world: u8,
    falcon_x: u8,
    falcon_y: u8,
    whale_vis: u8,
    whale_world: u8,
    whale_x: u8,
    whale_y: u8,
) bool {
    if (!holding_hover) return false;
    // Can't drop on falcon (@a640)
    if (falcon_vis != 0 and falcon_world == party_world and falcon_x == party_x and falcon_y == party_y)
        return false;
    // Can't drop on whale (@a650)
    if (whale_vis != 0 and whale_world == party_world and whale_x == party_x and whale_y == party_y)
        return false;
    return tile_allows_drop;
}

test "HookYTbl endpoints and mid peak" {
    try std.testing.expectEqual(@as(usize, 16), hook_y_tbl.len);
    try std.testing.expectEqual(@as(u8, 0), hookYAtFrame(0));
    try std.testing.expectEqual(@as(u8, 0), hookYAtFrame(1));
    try std.testing.expectEqual(@as(u8, 0), hookYAtFrame(2));
    try std.testing.expectEqual(@as(u8, 0), hookYAtFrame(3));
    try std.testing.expectEqual(@as(u8, 1), hookYAtFrame(4));
    // Peak at frames $20-$27 → idx 8 → 7
    try std.testing.expectEqual(@as(u8, 7), hookYAtFrame(0x20));
    try std.testing.expectEqual(@as(u8, 7), hookYAtFrame(0x23));
    try std.testing.expectEqual(@as(u8, 0), hookYAtFrame(0x3C));
    try std.testing.expect(hoverHookToggleFrame(0x20));
    try std.testing.expect(!hoverHookToggleFrame(0x1F));
}

test "canGrabHover requires switch $36 co-location" {
    try std.testing.expect(canGrabHover(true, false, 1, 0, 10, 20, 0, 10, 20));
    try std.testing.expect(!canGrabHover(false, false, 1, 0, 10, 20, 0, 10, 20));
    try std.testing.expect(!canGrabHover(true, true, 1, 0, 10, 20, 0, 10, 20));
    try std.testing.expect(!canGrabHover(true, false, 0, 0, 10, 20, 0, 10, 20));
    try std.testing.expect(!canGrabHover(true, false, 1, 1, 10, 20, 0, 10, 20));
    try std.testing.expect(!canGrabHover(true, false, 1, 0, 11, 20, 0, 10, 20));
}

test "canDropHover blocks falcon whale and needs tile bit" {
    try std.testing.expect(canDropHover(true, true, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0));
    try std.testing.expect(!canDropHover(false, true, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0));
    try std.testing.expect(!canDropHover(true, false, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0));
    // Falcon on tile
    try std.testing.expect(!canDropHover(true, true, 5, 5, 0, 1, 0, 5, 5, 0, 0, 0, 0));
    // Whale on tile
    try std.testing.expect(!canDropHover(true, true, 5, 5, 0, 0, 0, 0, 0, 1, 0, 5, 5));
}

/// ExplosionPosTbl (special.asm @c9ef) — signed circle r≈60 for smoke burst.
pub const explosion_pos_tbl = [_]i8{
    0, -60, 23, -55, 42, -42, 55, -23, 60, 0, 55, 23, 42, 42, 23, 55,
    0, 60, -23, 55, -42, 42, -55, 23, -60, 0, -55, -23, -42, -42, -23, -55,
};

/// TunnelYTbl (field_data.asm @fa86) — airship Y offset during tunnel.
pub const tunnel_y_tbl = [_]u8{
    0x10, 0x11, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1B, 0x1C, 0x1E, 0x1F, 0x21,
    0x23, 0x24, 0x26, 0x28, 0x2A, 0x2D, 0x2F, 0x31, 0x33, 0x36, 0x38, 0x3B, 0x3E, 0x40, 0x43, 0x46,
    0x49, 0x4C, 0x4F, 0x53, 0x56, 0x59, 0x5D, 0x60, 0x64, 0x68, 0x6B, 0x6F, 0x73, 0x77, 0x7B, 0x7F,
};

/// TunnelRotTbl (field_data.asm @fab6) — Mode-7 rotation during tunnel (stored for future Mode-7).
pub const tunnel_rot_tbl = [_]u8{
    0x01, 0x02, 0x04, 0x06, 0x09, 0x0C, 0x10, 0x14, 0x19, 0x1E, 0x23, 0x29, 0x30, 0x36, 0x3E, 0x45,
    0x4E, 0x56, 0x5F, 0x69, 0x73, 0x7D, 0x88, 0x94, 0x9F, 0xAC, 0xB8, 0xC6, 0xD3, 0xE1, 0xF0, 0xFF,
};

pub const red_wings_intro_pos = [_]struct { x: i32, y: i32 }{
    .{ .x = 0x70, .y = 0x70 },
    .{ .x = 0x64, .y = 0x7C },
    .{ .x = 0x7C, .y = 0x7C },
    .{ .x = 0x54, .y = 0x8C },
    .{ .x = 0x8C, .y = 0x8C },
};
const intro_zoom_ad: i32 = 0x20;

/// DamcyanRedWingsXTbl / YTbl (special.asm @d799) — offsets for 3 ships in Special_03.
pub const damcyan_red_wings_off = [_]struct { x: i32, y: i32 }{
    .{ .x = 0x10, .y = 0x10 },
    .{ .x = 0x00, .y = 0x20 },
    .{ .x = 0x10, .y = 0x30 },
};

/// WhirlpoolSpriteTbl (field_data.asm @f5d6) — 16 × (tile, attr) for 4×4 large sprites.
pub const whirlpool_sprite_tbl = [_][2]u8{
    .{ 0xA0, 0x15 }, .{ 0xA2, 0x15 }, .{ 0xA8, 0x15 }, .{ 0xAA, 0x15 },
    .{ 0xA4, 0x15 }, .{ 0xA6, 0x15 }, .{ 0xAC, 0x15 }, .{ 0xAE, 0x15 },
    .{ 0xAE, 0xD5 }, .{ 0xAC, 0xD5 }, .{ 0xA6, 0xD5 }, .{ 0xA4, 0xD5 },
    .{ 0xAA, 0xD5 }, .{ 0xA8, 0xD5 }, .{ 0xA2, 0xD5 }, .{ 0xA0, 0xD5 },
};

/// LeviathanTailYTbl (special.asm @d246).
pub const leviathan_tail_y_tbl = [_]u8{
    0x74, 0x73, 0x71, 0x6F, 0x6C, 0x6A, 0x69, 0x68, 0x68, 0x69, 0x6A, 0x6C, 0x6F, 0x71, 0x73, 0x74,
};

/// MapSpritePal+33 (LoadWhirlpoolPal → `$0e1b` / backup `$0aad`) — 8 SNES colors.
pub const whirlpool_pal_words = [_]u16{
    0x0000, 0x4000, 0x4800, 0x6400, 0x7C80, 0x6400, 0x4800, 0x4000,
};

/// ShiftWhirlpoolPal (special.asm @d30a): every 4 frames, rotate colors 1–7
/// through 6 phases (`$79` 0..5) from the backup pal.
pub fn shiftWhirlpoolPal(phase: u8, out: *[8]snes.Color) void {
    const p: usize = phase % 6;
    out[0] = snes.Color.fromSnes(whirlpool_pal_words[0]);
    out[0].a = 0;
    // Copy 7 colors starting at word index `p` wrapping within 1..7 of source.
    // ROM: y = phase*2 into $0aaf (skip first color word); loop 14 bytes.
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const src = 1 + (p + i) % 7;
        out[i + 1] = snes.Color.fromSnes(whirlpool_pal_words[src]);
        out[i + 1].a = 255;
    }
}

/// Blit vehicle tile with an explicit 8-color palette (whirlpool ShiftWhirlpoolPal).
pub fn blitVehicleTilePal(
    self: *const VehicleSprites,
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    tile: u8,
    hflip: bool,
    pal: *const [8]snes.Color,
) void {
    if (!self.loaded or tile >= vehicle_tile_count) return;
    blitTile8(dest, dest_w, dx, dy, &self.tiles[tile], pal, hflip);
}

test "shiftWhirlpoolPal phase0 color1 is first non-transparent word" {
    var pal: [8]snes.Color = undefined;
    shiftWhirlpoolPal(0, &pal);
    try std.testing.expectEqual(@as(u8, 0), pal[0].a);
    // phase 0: src 1..7 → words[1] first animated color
    const c1 = snes.Color.fromSnes(whirlpool_pal_words[1]);
    try std.testing.expectEqual(c1.r, pal[1].r);
    try std.testing.expectEqual(c1.g, pal[1].g);
    try std.testing.expectEqual(c1.b, pal[1].b);
}

test "shiftWhirlpoolPal phase1 rotates color1" {
    var p0: [8]snes.Color = undefined;
    var p1: [8]snes.Color = undefined;
    shiftWhirlpoolPal(0, &p0);
    shiftWhirlpoolPal(1, &p1);
    // phase1 starts at words[2]
    const expect = snes.Color.fromSnes(whirlpool_pal_words[2]);
    try std.testing.expectEqual(expect.r, p1[1].r);
    try std.testing.expect(p0[1].r != p1[1].r or p0[1].g != p1[1].g or p0[1].b != p1[1].b);
}

// ---------------------------------------------------------------------------
// Board / land animation (vehicle.asm) — stepped per field via tickAnim.
// ---------------------------------------------------------------------------

/// Mirrors board/land loops that call Animate4 / Animate8.
pub const AnimKind = enum(u8) {
    none = 0,
    /// LiftoffBkChoco: `$b5` 0→$10 via Animate4.
    bk_liftoff,
    /// LandBkChoco: `$b5` $10→0; then forest check or re-liftoff.
    bk_land,
    /// BoardHover: `$b6` 0→4 via Animate8.
    hover_board,
    /// LandHover: `$b6` down to 0 via Animate8 (after foot-bit check).
    hover_land,
    /// LiftoffEnterprise/Falcon/Whale: `$79` 0→$30, `$b7` altitude.
    air_liftoff,
    /// LandEnterprise/Falcon/Whale: `$79` $30→0, can-land checks mid-loop.
    air_land,
    /// LandChoco @a0c1 — pixel flee off-screen (`$1710`/`$1711` + `$2c`/`$2e`).
    choco_flee,
    /// GrabHover `$79` 0→$40, set `$06d0` at $20.
    grab_hover,
    /// DropHover `$79` 0→$40, clear `$06d0` at $20.
    drop_hover,
    /// ShowVehicleSmoke @a198 — `$0ad2` from `$28` → 0 (explosion frames).
    show_smoke,
    /// GoDownTunnel (field.asm @9533): phase0 zoom `$1f→$10`, phase1 rot `$1f→0`,
    /// mid-swap under, phase2 TunnelYTbl `$2f→0`.
    tunnel_down,
    /// TunnelAnim / GoUpTunnel rise (field.asm @964b): `$79` `$00→$2f` + TunnelYTbl.
    tunnel_up,
    /// DrillAnim @9690 after LoadOverworld: rot `$00→$20`, then alt climb `$11→$21`.
    drill_anim,
};

pub const Anim = struct {
    kind: AnimKind = .none,
    /// `$79` step counter in board/land loops.
    timer: u8 = 0,
    /// `$b5` / `$b6` / `$b7` altitude (pixels subtracted from center Y).
    alt: u8 = 0,
    /// Wait gate for Animate4 (`$7a&3`) or Animate8 (`$7a&7`).
    wait_mask: u8 = 0,
    /// True after land checks failed → restart liftoff (bk / air).
    reject_land: bool = false,
    /// LandChoco flee: screen X/Y (`$1710`/`$1711`) and velocity `$2c`/`$2e`.
    flee_sx: u8 = 0x70,
    flee_sy: u8 = 0x70,
    flee_dx: i8 = 2,
    flee_dy: i8 = 2,
    /// ShowVehicleSmoke: `$0ad2` countdown (starts `$28`).
    smoke_timer: u16 = 0,
    /// Tunnel sub-phase (GoDownTunnel 0=zoom, 1=rot, 2=under Y).
    phase: u8 = 0,
    /// One-shot: LoadUnderground mid GoDownTunnel (after phase 1).
    tunnel_do_swap: bool = false,
    /// `$ad` during tunnel (`$79` written each frame); `$FF` = no override.
    tunnel_ad: u8 = 0xFF,
    /// `$06fb` TunnelRotTbl angle (Mode-7 rotation stand-in).
    tunnel_rot: u8 = 0,

    pub fn active(self: Anim) bool {
        return self.kind != .none;
    }

    pub fn begin(self: *Anim, kind: AnimKind) void {
        self.* = .{
            .kind = kind,
            .timer = switch (kind) {
                .air_land => 0x30,
                .bk_land => 0,
                .show_smoke => 0,
                .tunnel_down => 0x1F,
                .tunnel_up => 0x00,
                .drill_anim => 0x00,
                else => 0,
            },
            .alt = 0,
            .wait_mask = 0,
            .reject_land = false,
            .flee_sx = 0x70,
            .flee_sy = 0x70,
            .flee_dx = 2,
            .flee_dy = 2,
            .smoke_timer = if (kind == .show_smoke) 0x28 else 0,
            .phase = 0,
            .tunnel_do_swap = false,
            .tunnel_ad = 0xFF,
            .tunnel_rot = 0,
        };
        if (kind == .bk_land) self.alt = 0x10;
        if (kind == .hover_land) self.alt = 0x04;
        if (kind == .air_land) self.alt = 0x10;
        if (kind == .tunnel_down) {
            // Cruise alt before dive; `$ad` starts at `$1f`.
            self.alt = 0x10;
            self.tunnel_ad = 0x1F;
        }
        if (kind == .tunnel_up) {
            self.alt = tunnel_y_tbl[0];
            self.tunnel_ad = 0x20;
        }
        if (kind == .drill_anim) {
            // After LoadOverworld: `$ad/$79=0`, alt 0, reverse spin then climb.
            self.alt = 0;
            self.tunnel_ad = 0;
            self.tunnel_rot = tunnel_rot_tbl[@min(0x1F, tunnel_rot_tbl.len - 1)];
            self.phase = 0;
        }
    }

    /// LandChoco @a082: init flee velocity from Rand (caller supplies 2 random bytes).
    pub fn beginChocoFlee(self: *Anim, rand0: u8, rand1: u8) void {
        self.begin(.choco_flee);
        // Facing right ($01) + dx=+2, or left ($03) + dx=-2.
        if ((rand0 & 1) != 0) {
            self.flee_dx = -2;
        } else {
            self.flee_dx = 2;
        }
        if ((rand1 & 1) != 0) {
            self.flee_dy = -2;
        } else {
            self.flee_dy = 2;
        }
        self.flee_sx = 0x70;
        self.flee_sy = 0x70;
    }

    pub fn clear(self: *Anim) void {
        self.* = .{};
    }
};

/// One field of vehicle anim. `snes_7a` is `$7a`. Returns true if still running.
/// `can_land` is polled for air/bk land mid-sequence (caller supplies tile tests).
/// `rand_byte` used for LandChoco mid-flee Y flip (`Rand cmp #$10`).
pub fn tickAnim(
    anim: *Anim,
    snes_7a: u8,
    can_land: bool,
    facing_out: *u8,
    rand_byte: u8,
) bool {
    if (anim.kind == .none) return false;

    // Animate4: face left, wait until `$7a&3==0`. Animate8: `$7a&7==0`.
    const mask: u8 = switch (anim.kind) {
        .hover_board, .hover_land => 0x07,
        .choco_flee, .grab_hover, .drop_hover, .show_smoke, .tunnel_down, .tunnel_up, .drill_anim => 0x00,
        else => 0x03,
    };
    if (mask != 0) {
        facing_out.* = 3; // Animate4/8: `lda #$03 / sta $1705`
        if ((snes_7a & mask) != 0) return true;
    }

    switch (anim.kind) {
        .none => return false,

        .bk_liftoff => {
            anim.alt +%= 1;
            anim.timer +%= 1;
            if (anim.timer >= 0x10) {
                anim.clear();
                return false;
            }
        },
        .bk_land => {
            if (anim.alt > 0) anim.alt -%= 1;
            anim.timer +%= 1;
            if (anim.timer >= 0x10) {
                if (!can_land) {
                    anim.begin(.bk_liftoff);
                    anim.reject_land = true;
                    return true;
                }
                anim.clear();
                return false;
            }
        },
        .hover_board => {
            anim.alt +%= 1;
            anim.timer +%= 1;
            if (anim.timer >= 4) {
                anim.clear();
                return false;
            }
        },
        .hover_land => {
            if (anim.alt > 0) anim.alt -%= 1;
            anim.timer +%= 1;
            if (anim.timer >= 4) {
                anim.clear();
                return false;
            }
        },
        .air_liftoff => {
            if (anim.timer < 0x20) {
                anim.timer +%= 1;
            } else {
                anim.alt +%= 1;
                anim.timer +%= 1;
                if (anim.timer >= 0x30) {
                    anim.clear();
                    return false;
                }
            }
        },
        .air_land => {
            if (anim.timer >= 0x21) {
                if (anim.alt > 0) anim.alt -%= 1;
                anim.timer -%= 1;
            } else {
                if (!can_land) {
                    anim.begin(.air_liftoff);
                    anim.reject_land = true;
                    return true;
                }
                if (anim.timer <= 1) {
                    anim.clear();
                    return false;
                }
                anim.timer -%= 2;
            }
        },
        .choco_flee => {
            // LandChoco @a0c1 frame loop.
            // Randomly flip Y velocity when Rand < $10.
            if (rand_byte < 0x10) {
                anim.flee_dy = -%anim.flee_dy;
            }
            // Advance screen position (`$1710 += $2c`, `$1711 += $2e`).
            const nx: i16 = @as(i16, anim.flee_sx) + anim.flee_dx;
            const ny: i16 = @as(i16, anim.flee_sy) + anim.flee_dy;
            // Exit when X/Y hit 0 or $F0 (unsigned wrap / edge).
            if (nx <= 0 or nx >= 0xF0 or ny <= 0 or ny >= 0xF0) {
                anim.clear();
                return false;
            }
            anim.flee_sx = @intCast(nx);
            anim.flee_sy = @intCast(ny);
            // Facing from flee_dx (right if +).
            facing_out.* = if (anim.flee_dx >= 0) 1 else 3;
            anim.timer +%= 1;
        },
        .grab_hover => {
            anim.timer +%= 1;
            if (anim.timer >= 0x40) {
                anim.clear();
                return false;
            }
        },
        .drop_hover => {
            anim.timer +%= 1;
            if (anim.timer >= 0x40) {
                anim.clear();
                return false;
            }
        },
        .show_smoke => {
            // ShowVehicleSmoke: `$0ad2` from $28 → 0, one step per frame.
            if (anim.smoke_timer > 0) anim.smoke_timer -%= 1;
            if (anim.smoke_timer == 0) {
                anim.clear();
                return false;
            }
        },
        .tunnel_down => {
            // GoDownTunnel @9533 — three phases.
            facing_out.* = 3;
            anim.tunnel_do_swap = false;
            switch (anim.phase) {
                0 => {
                    // @953c: `$79` `$1f→$10`, `$ad=$79`, dec `$b7`/`$b8` each frame.
                    anim.tunnel_ad = anim.timer;
                    if (anim.alt > 0) anim.alt -%= 1;
                    anim.timer -%= 1;
                    if (anim.timer < 0x10) {
                        anim.phase = 1;
                        anim.timer = 0x1F;
                    }
                },
                1 => {
                    // @9570: TunnelRotTbl[0x1f-$79] → `$06fb`, `$ad=$79`, rotate until `$79` wraps.
                    const rot_i: usize = @min(@as(usize, 0x1F -% anim.timer), tunnel_rot_tbl.len - 1);
                    anim.tunnel_rot = tunnel_rot_tbl[rot_i];
                    anim.tunnel_ad = anim.timer;
                    if (anim.timer == 0) {
                        // After this frame, LoadUnderground then phase 2.
                        anim.tunnel_do_swap = true;
                        anim.phase = 2;
                        anim.timer = 0x2F;
                        anim.tunnel_ad = 0x20;
                        anim.tunnel_rot = 0;
                        if (0x2F < tunnel_y_tbl.len) anim.alt = tunnel_y_tbl[0x2F];
                    } else {
                        anim.timer -%= 1;
                    }
                },
                else => {
                    // @95ee: under world, TunnelYTbl[$79] → `$b7`/`$b8`, fade via INIDISP.
                    const yi: usize = @min(@as(usize, anim.timer), tunnel_y_tbl.len - 1);
                    anim.alt = tunnel_y_tbl[yi];
                    anim.tunnel_ad = 0x20;
                    if (anim.timer == 0) {
                        anim.clear();
                        return false;
                    }
                    anim.timer -%= 1;
                },
            }
        },
        .tunnel_up => {
            // TunnelAnim @964b: `$79` `$00→$2f`, TunnelYTbl[$79] → alt, face left.
            facing_out.* = 3;
            const yi: usize = @min(@as(usize, anim.timer), tunnel_y_tbl.len - 1);
            anim.alt = tunnel_y_tbl[yi];
            anim.tunnel_ad = 0x20;
            anim.timer +%= 1;
            if (anim.timer >= 0x30) {
                anim.clear();
                return false;
            }
        },
        .drill_anim => {
            // DrillAnim @96d7 / @970d after LoadOverworld.
            facing_out.* = 3;
            if (anim.phase == 0) {
                // `$79` 0→$20: TunnelRotTbl[$20-$79] → `$06fb`, `$ad=$79`.
                const ri: usize = @min(@as(usize, 0x20 -% anim.timer), tunnel_rot_tbl.len - 1);
                anim.tunnel_rot = tunnel_rot_tbl[ri];
                anim.tunnel_ad = anim.timer;
                anim.timer +%= 1;
                if (anim.timer >= 0x20) {
                    anim.phase = 1;
                    anim.timer = 0x11;
                    anim.tunnel_ad = 0x11;
                    anim.tunnel_rot = 0;
                    anim.alt = 0;
                }
            } else {
                // `$79` $11→$21: `$ad=$79`, inc `$b7`/`$b8`, UpdateZoomPal.
                anim.tunnel_ad = anim.timer;
                anim.alt +%= 1;
                anim.timer +%= 1;
                if (anim.timer >= 0x21) {
                    anim.clear();
                    return false;
                }
            }
        },
    }
    return true;
}

/// Hook Y offset for grab/drop draw (`HookYTbl[$79>>2]`).
pub fn hookY(anim: Anim) u8 {
    if (anim.kind != .grab_hover and anim.kind != .drop_hover) return 0;
    return hookYAtFrame(anim.timer);
}

// ---------------------------------------------------------------------------
// Sprites
// ---------------------------------------------------------------------------

pub const VehicleSprites = struct {
    tiles: [vehicle_tile_count][64]u8 = undefined,
    choco_tiles: [choco_tile_count][64]u8 = undefined,
    palette: [8]snes.Color = undefined,
    choco_palette: [8]snes.Color = undefined,
    loaded: bool = false,

    pub fn load(self: *VehicleSprites, r: *const rom_mod.Rom) !void {
        const nbytes = vehicle_tile_count * bytes_per_tile;
        const gfx = try r.slice(vehicle_gfx, nbytes);
        var t: usize = 0;
        while (t < vehicle_tile_count) : (t += 1) {
            decodeTile3bpp(gfx[t * bytes_per_tile ..][0..bytes_per_tile], &self.tiles[t]);
        }
        if (r.slice(choco_gfx, choco_tile_count * bytes_per_tile)) |cg| {
            var ct: usize = 0;
            while (ct < choco_tile_count) : (ct += 1) {
                decodeTile3bpp(cg[ct * bytes_per_tile ..][0..bytes_per_tile], &self.choco_tiles[ct]);
            }
        } else |_| {}
        const pal_raw = try r.slice(map_sprite_pal + vehicle_pal_index * 16, 16);
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const w = std.mem.readInt(u16, pal_raw[i * 2 ..][0..2], .little);
            self.palette[i] = snes.Color.fromSnes(w);
        }
        self.palette[0].a = 0;
        const cp = try r.slice(map_sprite_pal + choco_pal_index * 16, 16);
        i = 0;
        while (i < 8) : (i += 1) {
            const w = std.mem.readInt(u16, cp[i * 2 ..][0..2], .little);
            self.choco_palette[i] = snes.Color.fromSnes(w);
        }
        self.choco_palette[0].a = 0;
        self.loaded = true;
    }

    pub fn blitRedWings(self: *const VehicleSprites, dest: []u8, dest_w: usize, snes_7a: u8) void {
        if (!self.loaded) return;
        const frame: usize = if ((snes_7a & 0x02) != 0) 1 else 0;
        const tbl_base = frame * 4;
        for (red_wings_intro_pos) |pos| {
            const sy = pos.y - intro_zoom_ad + 8;
            self.blitTbl(dest, dest_w, pos.x, sy, tbl_base, 0);
        }
    }

    /// Special_03: three airships at base + DamcyanRedWings offsets.
    pub fn blitDamcyanRedWings(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        base_x: i32,
        base_y: i32,
        snes_7a: u8,
    ) void {
        if (!self.loaded) return;
        const frame: usize = if ((snes_7a & 0x02) != 0) 1 else 0;
        const tbl_base = frame * 4; // facing right-ish / frame B for fly
        // Use right-facing bank of VehicleSpriteTbl (face 1 * 8).
        const face_base: usize = 1 * 8 + frame * 4;
        _ = tbl_base;
        for (damcyan_red_wings_off) |off| {
            self.blitTbl(dest, dest_w, base_x + off.x, base_y + off.y, face_base, 0);
        }
    }

    /// Ridden vehicle at screen center. `alt` = `$b5`/`$b6`/`$b7` (pixels up).
    /// `anim_spd` = `$06fd` for AirshipAnimMask (DrawEnterprise).
    pub fn blitRidden(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        vehicle: u8,
        facing: u8,
        snes_7a: u8,
        moving: bool,
        alt: u8,
        anim_spd: u8,
    ) void {
        if (!self.loaded or vehicle == 0) return;
        const sx: i32 = 0x70; // ROM centered at $70,$70
        const sy: i32 = 0x70 - @as(i32, alt);
        const face = facing & 3;
        // DrawEnterprise: `$7a & AirshipAnimMask[$06fd]` → frame B ($10).
        // DrawHover: `$7a&2`. Choco/ship: `$7a&4` while moving.
        const frame: usize = blk: {
            if (vehicle == id_hovercraft) {
                break :blk if ((snes_7a & 0x02) != 0) 1 else 0;
            }
            if (vehicle == id_enterprise or vehicle == id_falcon or vehicle == id_whale) {
                const mi: usize = @min(@as(usize, anim_spd), airship_anim_mask.len - 1);
                const mask = airship_anim_mask[mi];
                break :blk if ((snes_7a & mask) != 0) 1 else 0;
            }
            if (moving and (snes_7a & 0x04) != 0) break :blk 1;
            break :blk 0;
        };
        if (vehicle == id_chocobo) {
            self.blitChoco(dest, dest_w, sx, sy - 2, face, frame);
            return;
        }
        if (vehicle == id_whale) {
            // DrawWhale @bcd3 + UpdateWhalePal while riding.
            self.blitWhaleEx(dest, dest_w, sx - 0x10, sy - 0x10, face, .anim, snes_7a);
            return;
        }
        // Black choco uses VehicleSpriteTbl + $90 (DrawBkChoco).
        const tbl_base = face * 8 + frame * 4;
        self.blitTbl(dest, dest_w, sx, sy, tbl_base, tileBank(vehicle));
    }

    pub fn blitParked(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        sx: i32,
        sy: i32,
        vehicle: u8,
        facing: u8,
        snes_7a: u8,
    ) void {
        if (!self.loaded or vehicle == 0) return;
        const face = facing & 3;
        const frame: usize = if ((snes_7a & 0x04) != 0) 1 else 0;
        if (vehicle == id_chocobo) {
            self.blitChoco(dest, dest_w, sx, sy, face, frame);
            return;
        }
        if (vehicle == id_whale) {
            self.blitWhale(dest, dest_w, sx - 0x10, sy - 0x10, face);
            return;
        }
        const tbl_base = face * 8 + frame * 4;
        self.blitTbl(dest, dest_w, sx, sy, tbl_base, tileBank(vehicle));
    }

    /// DrawWhale (sprite.asm @bc2f) — 4×4 grid of 8×8 from WhaleSpritePos/Tiles.
    pub fn blitWhale(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        base_x: i32,
        base_y: i32,
        facing: u8,
    ) void {
        self.blitWhaleEx(dest, dest_w, base_x, base_y, facing, null, 0);
    }

    pub fn blitWhaleEx(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        base_x: i32,
        base_y: i32,
        facing: u8,
        /// null = stock pal; `.flash(7a)` = WhaleFlashPal; `.anim(7a)` = UpdateWhalePal.
        pal_mode: ?enum { flash, anim },
        snes_7a: u8,
    ) void {
        if (!self.loaded) return;
        var work_pal: [8]snes.Color = undefined;
        const pal: *const [8]snes.Color = blk: {
            if (pal_mode) |pm| {
                switch (pm) {
                    .flash => {
                        applyWhaleFlashPal(snes_7a, &work_pal);
                        break :blk &work_pal;
                    },
                    .anim => {
                        work_pal = self.palette;
                        work_pal[1] = whaleAnimColor(snes_7a);
                        break :blk &work_pal;
                    },
                }
            }
            break :blk &self.palette;
        };
        const face: usize = facing & 3;
        const tile_base = face * 16;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const pos = whale_sprite_pos[i];
            const te = whale_sprite_tiles[tile_base + i];
            const name: usize = te[0];
            const attr = te[1];
            // OAM attr bit0 = 9th character bit.
            var tile_i = name;
            if ((attr & 1) != 0) tile_i += 256;
            if (tile_i >= vehicle_tile_count) continue;
            const hflip = (attr & 0x40) != 0;
            blitTile8(
                dest,
                dest_w,
                base_x + pos[0],
                base_y + pos[1],
                &self.tiles[tile_i],
                pal,
                hflip,
            );
        }
    }

    fn blitTbl(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        sx: i32,
        sy: i32,
        tbl_base: usize,
        bank: u8,
    ) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const e = vehicle_sprite_tbl[tbl_base + i];
            const tile: usize = @as(usize, e[2]) + bank;
            if (tile >= vehicle_tile_count) continue;
            const hflip = (e[3] & 0x40) != 0;
            blitTile8(dest, dest_w, sx + @as(i32, e[0]), sy + @as(i32, e[1]), &self.tiles[tile], &self.palette, hflip);
        }
    }

    fn blitChoco(
        self: *const VehicleSprites,
        dest: []u8,
        dest_w: usize,
        sx: i32,
        sy: i32,
        facing: u8,
        frame: usize,
    ) void {
        const base = @as(usize, facing) * 8 + frame * 4;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const e = choco_sprite_tbl[base + i];
            if (e[2] < 0x20) continue;
            const local = e[2] - 0x20;
            if (local >= choco_tile_count) continue;
            const hflip = (e[3] & 0x40) != 0;
            blitTile8(dest, dest_w, sx + @as(i32, e[0]), sy + @as(i32, e[1]), &self.choco_tiles[local], &self.choco_palette, hflip);
        }
    }
};

fn decodeTile3bpp(tile: *const [24]u8, out: *[64]u8) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const p0 = tile[row * 2];
        const p1 = tile[row * 2 + 1];
        const p2 = tile[16 + row];
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const bit: u3 = @intCast(7 - col);
            out[row * 8 + col] =
                ((p0 >> bit) & 1) |
                (((p1 >> bit) & 1) << 1) |
                (((p2 >> bit) & 1) << 2);
        }
    }
}

/// Public helper for specials (giant OAM) to blit one vehicle 8×8.
pub fn blitVehicleTile(
    self: *const VehicleSprites,
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    tile: u8,
    hflip: bool,
) void {
    if (!self.loaded or tile >= vehicle_tile_count) return;
    blitTile8(dest, dest_w, dx, dy, &self.tiles[tile], &self.palette, hflip);
}

/// DrawExplosion (special.asm @e15a) — one burst at (cx,cy), stage 0..3 from `_00e1b4`.
/// `sand` selects MapSpritePal+32 vs +31 (`$0ace`).
pub fn blitExplosion(
    self: *const VehicleSprites,
    dest: []u8,
    dest_w: usize,
    cx: i32,
    cy: i32,
    stage: u8,
    sand: bool,
) void {
    if (!self.loaded) return;
    const st: usize = @min(@as(usize, stage), explosion_stage_tbl.len - 1);
    const frame_off: usize = explosion_stage_tbl[st] / 4; // 0,4,8,12 → entry index
    var pal: [8]snes.Color = undefined;
    const src = if (sand) explosion_pal_sand else explosion_pal_fire;
    var pi: usize = 0;
    while (pi < 8) : (pi += 1) {
        pal[pi] = snes.Color.fromSnes(src[pi]);
        pal[pi].a = 255;
    }
    pal[0].a = 0;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const e = explosion_oam_tbl[frame_off + i];
        const dx: i8 = @bitCast(e[0]);
        const dy_b = e[1];
        if (dy_b == 0xFF) continue; // hidden sub-sprite
        const dy: i8 = @bitCast(dy_b);
        const tile: usize = e[2];
        const attr = e[3];
        if (tile >= vehicle_tile_count) continue;
        const hflip = (attr & 0x40) != 0;
        const vflip = (attr & 0x80) != 0;
        // 16×16 large sprite: 4× 8×8 at tile, tile+1, tile+16, tile+17
        const qnames = [_]usize{ tile, tile + 1, tile + 16, tile + 17 };
        const qxy = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 8 }, .{ .x = 8, .y = 8 },
        };
        for (qnames, qxy) |nm, q| {
            if (nm >= vehicle_tile_count) continue;
            var qx = q.x;
            var qy = q.y;
            if (hflip) qx = 8 - q.x;
            if (vflip) qy = 8 - q.y;
            blitTile8(
                dest,
                dest_w,
                cx + dx + qx,
                cy + dy + qy,
                &self.tiles[nm],
                &pal,
                hflip,
            );
        }
    }
}

fn blitTile8(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: *const [8]snes.Color,
    hflip: bool,
) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const sx: usize = if (hflip) 7 - col else col;
            const idx = indices[row * 8 + sx];
            if (idx == 0) continue;
            const c = palette[idx % 8];
            if (c.a == 0) continue;
            const x = dx + @as(i32, @intCast(col));
            const y = dy + @as(i32, @intCast(row));
            if (x < 0 or y < 0) continue;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (ux >= dest_w) continue;
            const di = (uy * dest_w + ux) * 4;
            if (di + 3 >= dest.len) continue;
            dest[di] = c.r;
            dest[di + 1] = c.g;
            dest[di + 2] = c.b;
            dest[di + 3] = 255;
        }
    }
}

// --- Land tile rules (vehicle.asm) — pure prop-byte tests ---

/// LandChoco / LandHover: `lda $a1 / and #$01` (prop_lo bit0).
pub fn tileAllowsFootLand(prop_lo: u8) bool {
    return (prop_lo & 0x01) != 0;
}

/// LandBkChoco @a124: `lda $a1 / and #$08` forest (prop_lo bit3).
pub fn tileAllowsBlackChocoLand(prop_lo: u8) bool {
    return (prop_lo & 0x08) != 0;
}

/// LandEnterprise / LandFalcon / LandWhale mid-loop: `lda $a2 / and #$10` (prop_hi bit4).
pub fn tileAllowsAirshipLand(prop_hi: u8) bool {
    return (prop_hi & 0x10) != 0;
}

test "LandBkChoco forest bit $a1&$08" {
    try std.testing.expect(!tileAllowsBlackChocoLand(0x00));
    try std.testing.expect(!tileAllowsBlackChocoLand(0x01));
    try std.testing.expect(tileAllowsBlackChocoLand(0x08));
    try std.testing.expect(tileAllowsBlackChocoLand(0xFF));
}

test "Land airship prop_hi bit4 $a2&$10" {
    try std.testing.expect(!tileAllowsAirshipLand(0x00));
    try std.testing.expect(!tileAllowsAirshipLand(0x08));
    try std.testing.expect(tileAllowsAirshipLand(0x10));
    try std.testing.expect(tileAllowsAirshipLand(0xF0));
}

test "LandChoco foot bit0" {
    try std.testing.expect(tileAllowsFootLand(0x01));
    try std.testing.expect(!tileAllowsFootLand(0x02));
}

test "vehicle multi-OAM counts DrawShip/Whale/Hover" {
    try std.testing.expectEqual(@as(usize, 4), vehicleOamCount(id_ship));
    try std.testing.expectEqual(@as(usize, 4), vehicleOamCount(id_enterprise));
    try std.testing.expectEqual(@as(usize, 4), vehicleOamCount(id_hovercraft));
    try std.testing.expectEqual(@as(usize, 16), vehicleOamCount(id_whale));
    try std.testing.expectEqual(@as(usize, 4), vehicleOamCount(id_chocobo));
    // VehicleSpriteTbl: 4 entries per facing×frame (cpy #$0010)
    try std.testing.expectEqual(@as(usize, 4), vehicle_oam_count);
    try std.testing.expectEqual(@as(usize, 16), whale_oam_count);
}

/// Animate4 wait gate (`$7a & 3 == 0`); Animate8 (`$7a & 7 == 0`).
pub fn animateWaitReady(snes_7a: u8, animate8: bool) bool {
    const mask: u8 = if (animate8) 0x07 else 0x03;
    return (snes_7a & mask) == 0;
}

test "Animate4/Animate8 wait gates board land" {
    try std.testing.expect(animateWaitReady(0x00, false)); // Animate4
    try std.testing.expect(!animateWaitReady(0x01, false));
    try std.testing.expect(animateWaitReady(0x04, false)); // bit2 clear for &3
    try std.testing.expect(animateWaitReady(0x00, true)); // Animate8
    try std.testing.expect(!animateWaitReady(0x04, true));
    try std.testing.expect(animateWaitReady(0x08, true));
}

/// TunnelAnim index: `TunnelRotTbl[0x1f - timer]` (field.asm @9570).
pub fn tunnelRotAt(timer_79: u8) u8 {
    const i: usize = @min(@as(usize, 0x1F -% timer_79), tunnel_rot_tbl.len - 1);
    return tunnel_rot_tbl[i];
}

/// DrillAnim open index: `TunnelRotTbl[0x20 - timer]` (field.asm @96d7).
pub fn drillRotAt(timer_79: u8) u8 {
    const i: usize = @min(@as(usize, 0x20 -% timer_79), tunnel_rot_tbl.len - 1);
    return tunnel_rot_tbl[i];
}

test "TunnelRotTbl endpoints and tunnel/drill index" {
    try std.testing.expectEqual(@as(u8, 0x01), tunnel_rot_tbl[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), tunnel_rot_tbl[31]);
    // timer 0 → index 0x1f → $ff
    try std.testing.expectEqual(@as(u8, 0xFF), tunnelRotAt(0));
    // timer 0x1f → index 0 → $01
    try std.testing.expectEqual(@as(u8, 0x01), tunnelRotAt(0x1F));
    try std.testing.expectEqual(@as(u8, 0xFF), drillRotAt(0));
}
