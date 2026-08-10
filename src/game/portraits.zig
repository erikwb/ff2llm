//! Menu portraits — PortraitGfx @ $1D/D3C0 + PortraitPal @ $0D/86D0 (menu.asm LoadPortraits).
//!
//! Each portrait is 16 × 3bpp tiles (4×4 = 32×32). Index = job/gfx id `$1001&$0F`.
const snes = @import("../gfx/snes.zig");
const rom_mod = @import("../rom.zig");

/// PortraitGfx LoROM $1D/D3C0 → file 0xED3C0.
pub const portrait_gfx_file: usize = 0xED3C0;
/// PortraitPal before WindowPal @ 0D/87D0 — 16 rows × 16 bytes (8 colors).
pub const portrait_pal_file: usize = 0x686D0;
pub const portrait_stride: usize = 0x180;
pub const portrait_count: usize = 14;
const tiles_per: usize = 16; // 4×4
const bytes_3bpp: usize = 24;

/// PortraitPosTbl 3-front/2-back (menu.asm @fe0a) — (x,y) pixel, party_row==0.
pub const portrait_pos_front3 = [_][2]u8{
    .{ 0x10, 0x60 },
    .{ 0x10, 0x10 },
    .{ 0x10, 0xB0 },
    .{ 0x18, 0x38 },
    .{ 0x18, 0x88 },
};
/// PortraitPosTbl 2-front/3-back (@fe14) — party_row!=0.
pub const portrait_pos_front2 = [_][2]u8{
    .{ 0x18, 0x60 },
    .{ 0x18, 0x10 },
    .{ 0x18, 0xB0 },
    .{ 0x10, 0x38 },
    .{ 0x10, 0x88 },
};

pub const Portraits = struct {
    /// Decoded 32×32 RGBA for each job index 0..13.
    sheets: [portrait_count][32 * 32 * 4]u8 = undefined,
    loaded: bool = false,

    pub fn load(self: *Portraits, r: *const rom_mod.Rom) void {
        self.loaded = false;
        var pi: usize = 0;
        while (pi < portrait_count) : (pi += 1) {
            const gfx = r.slice(portrait_gfx_file + pi * portrait_stride, portrait_stride) catch {
                @memset(&self.sheets[pi], 0);
                continue;
            };
            const pal_raw = r.slice(portrait_pal_file + pi * 16, 16) catch {
                @memset(&self.sheets[pi], 0);
                continue;
            };
            var pal: [8]snes.Color = undefined;
            var ci: usize = 0;
            while (ci < 8) : (ci += 1) {
                const w = @as(u16, pal_raw[ci * 2]) | (@as(u16, pal_raw[ci * 2 + 1]) << 8);
                pal[ci] = snes.Color.fromSnes(w);
                pal[ci].a = 255;
            }
            pal[0].a = 0;
            var tiles: [tiles_per][64]u8 = undefined;
            var t: usize = 0;
            while (t < tiles_per) : (t += 1) {
                decode3bpp(gfx[t * bytes_3bpp ..][0..bytes_3bpp], &tiles[t]);
            }
            @memset(&self.sheets[pi], 0);
            // 4×4 tile grid → 32×32
            var ty: usize = 0;
            while (ty < 4) : (ty += 1) {
                var tx: usize = 0;
                while (tx < 4) : (tx += 1) {
                    const ti = ty * 4 + tx;
                    blitTile32(&self.sheets[pi], tx * 8, ty * 8, &tiles[ti], &pal);
                }
            }
        }
        self.loaded = true;
    }

    /// Draw portrait for job/gfx id at pixel (x,y). Empty if id out of range.
    pub fn blit(
        self: *const Portraits,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        job_id: u8,
    ) void {
        if (!self.loaded) return;
        const idx: usize = job_id & 0x0F;
        if (idx >= portrait_count) return;
        const src = &self.sheets[idx];
        var row: i32 = 0;
        while (row < 32) : (row += 1) {
            var col: i32 = 0;
            while (col < 32) : (col += 1) {
                const si: usize = @intCast((row * 32 + col) * 4);
                if (src[si + 3] == 0) continue;
                const dx = x + col;
                const dy = y + row;
                if (dx < 0 or dy < 0) continue;
                const ux: usize = @intCast(dx);
                const uy: usize = @intCast(dy);
                if (ux >= dest_w) continue;
                const di = (uy * dest_w + ux) * 4;
                if (di + 3 >= dest.len) continue;
                dest[di] = src[si];
                dest[di + 1] = src[si + 1];
                dest[di + 2] = src[si + 2];
                dest[di + 3] = 255;
            }
        }
    }
};

fn decode3bpp(tile: *const [24]u8, out: *[64]u8) void {
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

fn blitTile32(dest: *[32 * 32 * 4]u8, ox: usize, oy: usize, tile: *const [64]u8, pal: *const [8]snes.Color) void {
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            const idx = tile[y * 8 + x];
            if (idx == 0) continue;
            const c = pal[idx & 7];
            const o = ((oy + y) * 32 + (ox + x)) * 4;
            dest[o] = c.r;
            dest[o + 1] = c.g;
            dest[o + 2] = c.b;
            dest[o + 3] = c.a;
        }
    }
}

const std = @import("std");

test "portrait pos tables length 5" {
    try std.testing.expectEqual(@as(usize, 5), portrait_pos_front3.len);
    try std.testing.expectEqual(@as(u8, 0x10), portrait_pos_front3[0][0]);
    try std.testing.expectEqual(@as(u8, 0x60), portrait_pos_front3[0][1]);
}
