//! Field map character sprites (MapSpriteGfx) — 3bpp, 24 bytes/tile, 32 tiles/char.
//! Layout from everything8215/ff4 field/player.asm + field/sprite.asm.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("../gfx/snes.zig");

const map_char_gfx: usize = 0xD8000;
const map_sprite_pal: usize = 0x68000;
/// LoadPlayerGfx: offset high = id*3+$80 → stride $300 between characters.
const char_gfx_stride: usize = 0x300;
/// Tfr3bppGfx with size $200 → $200/16 = 32 tiles transferred; 32×24 = 768 ROM bytes.
const tiles_per_char: usize = 32;
const bytes_per_tile: usize = 24;

/// PlayerPalTbl (field/sprite.asm @b2fa) — MapSpritePal index from class/char id ($1001&$1f).
pub const player_pal_tbl = [_]u8{ 0, 0, 1, 2, 2, 2, 0, 1, 1, 3, 0, 1, 0, 0, 0, 0, 0, 0 };

/// Field map-sprite palette index for a character class id (LoadPlayer / DrawPlayerSub).
pub fn fieldPalIndex(class_id: u8) u8 {
    if (class_id < player_pal_tbl.len) return player_pal_tbl[class_id];
    return 0;
}

const Corner = struct { tile: u8, hflip: bool };

/// PlayerSpriteTiles @c0c4 — `$1705` pose index (0–3 face, 4–7 special cutscene poses).
/// Each pose is 16 bytes (2 walk frames × 4 corners × tile+attr); we use tile ids + hflip from attr bit6.
///
/// Special poses (event $CA–$CD → $1705 = $05/$04/$06/$07): hang head, raised arms, etc.
/// Tiles $10–$1F live in the same 32-tile MapCharGfx sheet.
fn lookupFrame(pose: u8, walk_frame: u8) [4]Corner {
    const f = walk_frame & 1;
    // $CF / $d8 spin: DrawPlayerSub forces $1705=$08 and cycles face via $7b.
    if (pose == 8) {
        return lookupFrame(@as(u8, walk_frame) & 3, 0);
    }
    // Special cutscene poses 4–7 (PlayerSpriteTiles @c0c4 + $40..)
    if (pose >= 4 and pose <= 7) {
        const base: u8 = switch (pose) {
            4 => 0x14, // $CB → $1705=$04  (tiles $14–$17 / $18–$1B)
            5 => 0x18, // $CA → $1705=$05  hang-head / bow (tiles $18–$1B)
            6 => 0x10, // $CC → $1705=$06  (tiles $10–$13)
            else => 0x1C, // $CD → $1705=$07  (tiles $1C–$1F)
        };
        // Pose 4 has a distinct second walk frame; 5–7 are static in ROM.
        const t0: u8 = if (pose == 4 and f != 0) 0x18 else base;
        return .{
            .{ .tile = t0 + 0, .hflip = false },
            .{ .tile = t0 + 1, .hflip = false },
            .{ .tile = t0 + 2, .hflip = false },
            .{ .tile = t0 + 3, .hflip = false },
        };
    }
    return switch (pose & 3) {
        0 => if (f == 0) // up
            .{
                .{ .tile = 4, .hflip = false },
                .{ .tile = 5, .hflip = false },
                .{ .tile = 6, .hflip = false },
                .{ .tile = 7, .hflip = false },
            }
        else
            .{
                .{ .tile = 4, .hflip = false },
                .{ .tile = 5, .hflip = false },
                .{ .tile = 7, .hflip = true },
                .{ .tile = 6, .hflip = true },
            },
        1 => if (f == 0) // right
            .{
                .{ .tile = 9, .hflip = true },
                .{ .tile = 8, .hflip = true },
                .{ .tile = 11, .hflip = true },
                .{ .tile = 10, .hflip = true },
            }
        else
            .{
                .{ .tile = 13, .hflip = true },
                .{ .tile = 12, .hflip = true },
                .{ .tile = 15, .hflip = true },
                .{ .tile = 14, .hflip = true },
            },
        2 => if (f == 0) // down
            .{
                .{ .tile = 0, .hflip = false },
                .{ .tile = 1, .hflip = false },
                .{ .tile = 2, .hflip = false },
                .{ .tile = 3, .hflip = false },
            }
        else
            .{
                .{ .tile = 0, .hflip = false },
                .{ .tile = 1, .hflip = false },
                .{ .tile = 3, .hflip = true },
                .{ .tile = 2, .hflip = true },
            },
        else => if (f == 0) // left
            .{
                .{ .tile = 8, .hflip = false },
                .{ .tile = 9, .hflip = false },
                .{ .tile = 10, .hflip = false },
                .{ .tile = 11, .hflip = false },
            }
        else
            .{
                .{ .tile = 12, .hflip = false },
                .{ .tile = 13, .hflip = false },
                .{ .tile = 14, .hflip = false },
                .{ .tile = 15, .hflip = false },
            },
    };
}

pub const SpriteSheet = struct {
    tiles: [tiles_per_char][64]u8 = undefined,
    palette: [8]snes.Color = undefined,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SpriteSheet) void {
        self.* = undefined;
    }

    /// Load field character sheet. `char_gfx_id` = MapCharGfx index (class/$1001).
    /// `pal_index` = MapSpritePal entry (use `fieldPalIndex(class_id)` / PlayerPalTbl).
    pub fn load(gpa: std.mem.Allocator, r: *const rom_mod.Rom, char_gfx_id: usize, pal_index: usize) !SpriteSheet {
        var sheet: SpriteSheet = .{ .allocator = gpa };

        // Player pals live in the low MapSpritePal entries (0–3 typically).
        const max_pals: usize = 16;
        const pal_raw = try r.slice(map_sprite_pal, max_pals * 16);
        const pi = pal_index % max_pals;
        const po = pi * 16;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const w = std.mem.readInt(u16, pal_raw[po + i * 2 ..][0..2], .little);
            sheet.palette[i] = snes.Color.fromSnes(w);
        }
        sheet.palette[0].a = 0;

        // Packed 24-byte 3bpp tiles (not 32-byte slots)
        const gfx_id = @min(char_gfx_id, 32); // MapCharGfx early party ids
        const gfx_off = map_char_gfx + gfx_id * char_gfx_stride;
        const need = tiles_per_char * bytes_per_tile;
        const gfx = try r.slice(gfx_off, need);
        var t: usize = 0;
        while (t < tiles_per_char) : (t += 1) {
            decodeTile3bpp(gfx[t * bytes_per_tile ..][0..bytes_per_tile], &sheet.tiles[t]);
        }
        return sheet;
    }

    /// Reload sheet in place when the field leader changes (ValidateTopChar / e7).
    pub fn reload(self: *SpriteSheet, r: *const rom_mod.Rom, char_gfx_id: usize, pal_index: usize) !void {
        const gpa = self.allocator;
        const fresh = try load(gpa, r, char_gfx_id, pal_index);
        self.tiles = fresh.tiles;
        self.palette = fresh.palette;
    }

    /// `hide_lower`: MapTileProp hi bit3 / DrawPlayer `$a2&$08` path — skip bottom 8px.
    pub fn blit(
        self: *const SpriteSheet,
        dest: []u8,
        dest_w: usize,
        dx: i32,
        dy: i32,
        facing: u8,
        walk_frame: u8,
        hide_lower: bool,
    ) void {
        const fr = lookupFrame(facing, walk_frame);
        const offsets = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 },
            .{ .x = 8, .y = 0 },
            .{ .x = 0, .y = 8 },
            .{ .x = 8, .y = 8 },
        };
        for (fr, offsets, 0..) |corner, off, i| {
            if (hide_lower and i >= 2) continue;
            if (corner.tile >= tiles_per_char) continue;
            blitTile8(dest, dest_w, dx + off.x, dy + off.y, &self.tiles[corner.tile], &self.palette, corner.hflip);
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
            const px = dx + @as(i32, @intCast(col));
            const py = dy + @as(i32, @intCast(row));
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            const dest_h = dest.len / (dest_w * 4);
            if (ux >= dest_w or uy >= dest_h) continue;
            const c = palette[idx % 8];
            const o = (uy * dest_w + ux) * 4;
            dest[o] = c.r;
            dest[o + 1] = c.g;
            dest[o + 2] = c.b;
            dest[o + 3] = 255;
        }
    }
}
