//! Battle menu hand cursor — MiscBattleGfx tile $4A (name-table 1).
//!
//! OAM uses tile $4a + name select (attr $31) → absolute name $14A.
//! MiscBattleGfx loads at VRAM word $1400 = tile $140, so cursor is
//! sheet offset $0A (tiles 10,11,26,27 for 16×16). See btlgfx DrawMenuCursors.
const snes = @import("../gfx/snes.zig");
const rom_mod = @import("../rom.zig");

/// MiscBattleGfx @ 0C/F9C0 → file 0x679C0 (3bpp).
const misc_gfx_file: usize = 0x679C0;
/// AnimPal first 8 colors (sprite pal 0-ish) @ 0E/CB00 → 0x74B00.
const anim_pal_file: usize = 0x74B00;

/// CmdCursorYTbl @ btlgfx_data.asm $fc51 — pixel Y for command rows 0..4.
/// Hand sprite top-left; 8px command text is drawn at y+4 (center in 16px hand).
pub const cmd_cursor_y = [_]u8{ 0x98, 0xA4, 0xB0, 0xBC, 0xC8 };
/// UpdateCmdCursor x for command list (cursor.asm @b988).
pub const cmd_cursor_x: i32 = 0x28;
/// 8px text centered in 16px hand row.
pub const cmd_text_dy: i32 = 4;

/// InventoryCursorXTbl / ListCursorYTbl — battle item list (2×5 visible).
pub const inv_cursor_x = [_]i32{ 0x0C, 0x7C };
pub const inv_cursor_y = [_]i32{ 0x9C, 0xA8, 0xB4, 0xC0, 0xCC };
pub const inv_text_dx: i32 = 16;
pub const inv_text_dy: i32 = 4;

/// MagicListCursorXTbl — 3 columns (btlgfx_data.asm @fc56).
pub const magic_cursor_x = [_]i32{ 0x04, 0x3C, 0x74 };
/// Same Y table as inventory.
pub const magic_cursor_y = inv_cursor_y;
pub const magic_text_dx: i32 = 16;
pub const magic_text_dy: i32 = 4;

pub const HandCursor = struct {
    /// 16×16 RGBA.
    pixels: [16 * 16 * 4]u8 = undefined,
    loaded: bool = false,

    pub fn load(self: *HandCursor, r: *const rom_mod.Rom) !void {
        // Large sprite: N, N+1, N+16, N+17 relative to misc base tile 10.
        const base_t: usize = 10;
        const order = [_]usize{ base_t, base_t + 1, base_t + 16, base_t + 17 };
        var tiles: [4][64]u8 = undefined;
        for (order, 0..) |ti, i| {
            const off = misc_gfx_file + ti * 24;
            const raw = try r.slice(off, 24);
            snes.decodeTile3bpp(raw[0..24], &tiles[i]);
        }
        var pal: [8]snes.Color = undefined;
        const pr = try r.slice(anim_pal_file, 16);
        var pi: usize = 0;
        while (pi < 8) : (pi += 1) {
            const w = @as(u16, pr[pi * 2]) | (@as(u16, pr[pi * 2 + 1]) << 8);
            pal[pi] = snes.Color.fromSnes(w);
        }
        // Expand 8-color subpalette for blit (indices 0–7).
        var pal16: [16]snes.Color = .{snes.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 16;
        @memcpy(pal16[0..8], pal[0..8]);

        @memset(&self.pixels, 0);
        // Compose 16×16: TL=0 TR=1 BL=2 BR=3
        const places = [_]struct { tx: i32, ty: i32, ti: usize }{
            .{ .tx = 0, .ty = 0, .ti = 0 },
            .{ .tx = 8, .ty = 0, .ti = 1 },
            .{ .tx = 0, .ty = 8, .ti = 2 },
            .{ .tx = 8, .ty = 8, .ti = 3 },
        };
        for (places) |p| {
            snes.blitTile(&self.pixels, 16, p.tx, p.ty, &tiles[p.ti], &pal16, 0, true);
        }
        self.loaded = true;
    }

    pub fn blit(self: *const HandCursor, dest: []u8, dest_w: usize, x: i32, y: i32) void {
        if (!self.loaded) return;
        // DrawMenuCursors: sprite at (ef6b, ef6d) — top-left of 16×16 hand.
        var row: i32 = 0;
        while (row < 16) : (row += 1) {
            var col: i32 = 0;
            while (col < 16) : (col += 1) {
                const si: usize = @intCast((row * 16 + col) * 4);
                if (self.pixels[si + 3] == 0) continue;
                const dx = x + col;
                const dy = y + row;
                if (dx < 0 or dy < 0) continue;
                const ux: usize = @intCast(dx);
                const uy: usize = @intCast(dy);
                if (ux >= dest_w) continue;
                const dest_h = dest.len / (dest_w * 4);
                if (uy >= dest_h) continue;
                const di = (uy * dest_w + ux) * 4;
                dest[di] = self.pixels[si];
                dest[di + 1] = self.pixels[si + 1];
                dest[di + 2] = self.pixels[si + 2];
                dest[di + 3] = 255;
            }
        }
    }
};
