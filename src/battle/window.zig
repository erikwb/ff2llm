//! Battle/menu windows — WindowGfx (2bpp) + WindowPal + BorderTilesTbl.
//! Ports btlgfx/menu.asm DrawWindow / GetBorderTiles / MenuWindowTbl.
const snes = @import("../gfx/snes.zig");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");

/// WindowGfx @ 0A/F000 — 256 tiles × 16 bytes (2bpp). File 0x57000.
/// (Border + font share this sheet; we decode all for fill tile $FF.)
pub const window_gfx_file: usize = 0x57000;
pub const window_gfx_tiles: usize = 256;
/// WindowPal @ 0D/87D0 — 16 colors (4 subpalettes × 4). File 0x687D0.
///   [0]=$0000 transparent/black  [1]=$4000 blue fill  [2]=gray  [3]=white
pub const window_pal_file: usize = 0x687D0;

/// BorderTilesTbl @ btlgfx/menu.asm $9b91 — three 3×3 sets (top/mid/bot rows).
/// Set 0: DrawWindow3 (battle command / main strip)
/// Set 1: DrawWindow / field-style chrome ($f7…)
/// Set 2: DrawMsgWindow (message chrome)
pub const BorderSet = enum(u8) {
    battle = 0, // $10/$11/$12 · $0b/$ff/$0c · $0d/$0e/$0f
    field = 1, // $f7/$f8/$f9 · $fa/$ff/$fb · $fc/$fd/$fe
    message = 2, // $16/$17/$18 · $fa/$ff/$fb · $fc/$fd/$fe
};

const border_tbl = [3][9]u8{
    .{ 0x10, 0x11, 0x12, 0x0B, 0xFF, 0x0C, 0x0D, 0x0E, 0x0F },
    .{ 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xFB, 0xFC, 0xFD, 0xFE },
    .{ 0x16, 0x17, 0x18, 0xFA, 0xFF, 0xFB, 0xFC, 0xFD, 0xFE },
};

/// Fill tile $FF is solid palette index 1 (blue $4000) — ROM interior.
pub const fill_tile: u8 = 0xFF;

pub const WindowChrome = struct {
    tiles: [window_gfx_tiles][64]u8 = undefined,
    palette: [16]snes.Color = undefined,
    loaded: bool = false,

    pub fn load(self: *WindowChrome, r: *const rom_mod.Rom) !void {
        const gfx = try r.slice(window_gfx_file, window_gfx_tiles * 16);
        var t: usize = 0;
        while (t < window_gfx_tiles) : (t += 1) {
            decodeTile2bpp(gfx[t * 16 ..][0..16], &self.tiles[t]);
        }
        const pal = try r.slice(window_pal_file, 32);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const w = @as(u16, pal[i * 2]) | (@as(u16, pal[i * 2 + 1]) << 8);
            self.palette[i] = snes.Color.fromSnes(w);
            self.palette[i].a = 255;
        }
        // Index 0 is transparent in SNES BG; keep a=0 so skip_zero works if used.
        self.palette[0].a = 0;
        self.loaded = true;
    }

    /// Blue fill color (WindowPal[1] = $4000, or $16aa after UpdateWindowColor).
    pub fn fillColor(self: *const WindowChrome) snes.Color {
        return self.palette[1];
    }

    /// UpdateWindowColor (menu/system.asm @fed6): write `$16aa` into color index 1
    /// of each 4-color WindowPal subpalette (CGRAM slots 1, 5, 9, 13).
    /// Battle InitPal also hits the same four words in its WindowPal copy.
    pub fn applyWindowColor(self: *WindowChrome, color_snes: u16) void {
        if (!self.loaded) return;
        var c = snes.Color.fromSnes(color_snes);
        c.a = 255;
        // Subpal 0..3: offset 2 + n*8 bytes → color index 1 + n*4.
        const idxs = [_]usize{ 1, 5, 9, 13 };
        for (idxs) |i| self.palette[i] = c;
    }

    /// CalcWindowColor (config.asm @d427): pack 5-bit R/G/B → SNES BGR555 word.
    /// R bits 0–4, G bits 5–9 (asl5), B bits 10–14 (asl2 into high byte).
    pub fn calcWindowColor(r: u8, g: u8, b: u8) u16 {
        const r5: u16 = r & 0x1F;
        const g5: u16 = g & 0x1F;
        const b5: u16 = b & 0x1F;
        return r5 | (g5 << 5) | (b5 << 10);
    }

    /// CalcColorComponents (config.asm @d44a): unpack `$16aa` → $1ba8/$1ba9/$1baa.
    pub fn calcColorComponents(color_snes: u16) struct { r: u8, g: u8, b: u8 } {
        return .{
            .r = @truncate(color_snes & 0x1F),
            .g = @truncate((color_snes >> 5) & 0x1F),
            .b = @truncate((color_snes >> 10) & 0x1F),
        };
    }

    /// Draw bordered window. Default border set = battle (DrawWindow3).
    /// `w_tiles`/`h_tiles` are **total** size including the 1-tile borders
    /// (battle MenuWindowTbl / DrawWindow3 convention: middle loop is size−2).
    ///
    /// Field `def_window` width/height are **interior** only — pass interior+2
    /// (see menu.zig `fieldWinTotal`) or use `drawFieldDef`.
    pub fn draw(
        self: *const WindowChrome,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        w_tiles: u8,
        h_tiles: u8,
    ) void {
        self.drawEx(dest, dest_w, x, y, w_tiles, h_tiles, .battle);
    }

    /// Field menu DrawWindow: def_window interior width/height + pixel origin.
    pub fn drawFieldDef(
        self: *const WindowChrome,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        interior_w: u8,
        interior_h: u8,
    ) void {
        self.drawEx(dest, dest_w, x, y, interior_w +% 2, interior_h +% 2, .field);
    }

    pub fn drawEx(
        self: *const WindowChrome,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        w_tiles: u8,
        h_tiles: u8,
        border: BorderSet,
    ) void {
        self.drawExOpts(dest, dest_w, x, y, w_tiles, h_tiles, border, .{ .full_plate = true });
    }

    pub const DrawOpts = struct {
        /// When true (battle menu strip): opaque blue under the full window so
        /// battlefield never bleeds through bezel fringes.
        /// When false (battle message windows): fill **interior only** and leave
        /// palette-0 in border tiles transparent — message chrome art has empty
        /// pixels north of the top frame; a full plate draws blue outside the border.
        full_plate: bool = true,
    };

    pub fn drawExOpts(
        self: *const WindowChrome,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        w_tiles: u8,
        h_tiles: u8,
        border: BorderSet,
        opts: DrawOpts,
    ) void {
        if (!self.loaded or w_tiles < 2 or h_tiles < 2) return;
        const set = border_tbl[@intFromEnum(border)];
        const wt: i32 = w_tiles;
        const ht: i32 = h_tiles;
        const pw: i32 = wt * 8;
        const ph: i32 = ht * 8;
        const fill = self.fillColor();

        if (opts.full_plate) {
            // Menu strip: opaque plate + index-0 remapped to fill.
            fillRect(dest, dest_w, x, y, pw, ph, fill);
        } else {
            // Message windows: interior only (tiles [1..w-2] × [1..h-2]).
            fillRect(dest, dest_w, x + 8, y + 8, pw - 16, ph - 16, fill);
        }

        var row: i32 = 0;
        while (row < ht) : (row += 1) {
            var col: i32 = 0;
            while (col < wt) : (col += 1) {
                const tid = borderTileId(col, row, wt, ht, &set);
                if (tid == fill_tile) {
                    if (!opts.full_plate) {
                        // Interior already filled; skip $FF.
                    }
                    continue;
                }
                if (tid >= window_gfx_tiles) continue;
                if (opts.full_plate) {
                    blitBorderTile(dest, dest_w, x + col * 8, y + row * 8, &self.tiles[tid], &self.palette);
                } else {
                    blitBorderTileSkipZero(dest, dest_w, x + col * 8, y + row * 8, &self.tiles[tid], &self.palette);
                }
            }
        }
    }

    /// DrawFull / Left / Right message window (menu.asm Draw*MsgWindow).
    pub fn drawMsg(
        self: *const WindowChrome,
        dest: []u8,
        dest_w: usize,
        kind: MsgKind,
    ) void {
        switch (kind) {
            .full => self.drawExOpts(dest, dest_w, msg_window.x_px, msg_window.y_px, msg_window.w, msg_window.h, .message, .{ .full_plate = false }),
            .left => self.drawExOpts(dest, dest_w, msg_window_left.x_px, msg_window_left.y_px, msg_window_left.w, msg_window_left.h, .message, .{ .full_plate = false }),
            .right => self.drawExOpts(dest, dest_w, msg_window_right.x_px, msg_window_right.y_px, msg_window_right.w, msg_window_right.h, .message, .{ .full_plate = false }),
        }
    }

    /// Pixel Y for one line of 8px text vertically centered in the window interior
    /// (between top and bottom border tiles).
    pub fn textCenterY(y: i32, h_tiles: u8) i32 {
        // Interior spans tiles [1 .. h-2]; center an 8px glyph in that band.
        if (h_tiles <= 2) return y + 8;
        const interior_top = y + 8;
        const interior_h = (@as(i32, h_tiles) - 2) * 8;
        return interior_top + @divTrunc(interior_h - 8, 2);
    }
};

/// Opaque blue plate (WindowPal[1] = $4000).
fn fillRect(dest: []u8, dest_w: usize, x: i32, y: i32, w: i32, h: i32, c: snes.Color) void {
    const dest_h: i32 = @intCast(dest.len / (dest_w * 4));
    var py: i32 = y;
    while (py < y + h) : (py += 1) {
        if (py < 0 or py >= dest_h) continue;
        var px: i32 = x;
        while (px < x + w) : (px += 1) {
            if (px < 0 or px >= @as(i32, @intCast(dest_w))) continue;
            const o: usize = @intCast((py * @as(i32, @intCast(dest_w)) + px) * 4);
            dest[o] = c.r;
            dest[o + 1] = c.g;
            dest[o + 2] = c.b;
            dest[o + 3] = 255;
        }
    }
}

/// Border tile: palette index 0 → fill blue (menu BG under chrome), not battlefield.
fn blitBorderTile(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: *const [16]snes.Color,
) void {
    blitBorderTileInner(dest, dest_w, dx, dy, indices, palette, false);
}

/// Message chrome: palette 0 is transparent (battlefield shows through).
fn blitBorderTileSkipZero(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: *const [16]snes.Color,
) void {
    blitBorderTileInner(dest, dest_w, dx, dy, indices, palette, true);
}

fn blitBorderTileInner(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: *const [16]snes.Color,
    skip_zero: bool,
) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const px = dx + @as(i32, @intCast(col));
            const py = dy + @as(i32, @intCast(row));
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            if (ux >= dest_w) continue;
            const dest_h = dest.len / (dest_w * 4);
            if (uy >= dest_h) continue;
            var idx = indices[row * 8 + col];
            if (idx == 0) {
                if (skip_zero) continue;
                idx = 1; // under-chrome fill for menu plate
            }
            const color = palette[idx];
            const o = (uy * dest_w + ux) * 4;
            dest[o] = color.r;
            dest[o + 1] = color.g;
            dest[o + 2] = color.b;
            dest[o + 3] = 255;
        }
    }
}

fn borderTileId(col: i32, row: i32, w: i32, h: i32, set: *const [9]u8) u8 {
    const top = row == 0;
    const bot = row == h - 1;
    const left = col == 0;
    const right = col == w - 1;
    if (top and left) return set[0];
    if (top and right) return set[2];
    if (top) return set[1];
    if (bot and left) return set[6];
    if (bot and right) return set[8];
    if (bot) return set[7];
    if (left) return set[3];
    if (right) return set[5];
    return set[4]; // $FF fill
}

/// Decode SNES 2bpp planar tile (16 bytes) → 64 indices (0..3).
fn decodeTile2bpp(tile: *const [16]u8, out: *[64]u8) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const p0 = tile[row * 2];
        const p1 = tile[row * 2 + 1];
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const bit: u3 = @intCast(7 - col);
            out[row * 8 + col] =
                ((p0 >> bit) & 1) |
                (((p1 >> bit) & 1) << 1);
        }
    }
}

// --- Command name table ---
pub const battle_cmd_names = offsets.en.battle_command_names;
pub const battle_cmd_stride = offsets.en.battle_command_name_stride;
pub const battle_cmd_count = offsets.en.battle_command_name_count;

/// ClassCmd @ 13/FD55 — 22 classes × 5 command ids. File 0x9FD55.
pub const class_cmd_file: usize = 0x9FD55;
pub const class_cmd_stride: usize = 5;
pub const class_cmd_count: usize = 22;

/// Load up to 7 command ids for a class (5 from ClassCmd + Chang $1A + Parry $1B).
pub fn loadClassCommands(r: *const rom_mod.Rom, class_id: u8, out: *[7]u8) u8 {
    @memset(out, 0xFF);
    const cls = @min(class_id, class_cmd_count - 1);
    const raw = r.slice(class_cmd_file + @as(usize, cls) * class_cmd_stride, class_cmd_stride) catch return 0;
    var n: u8 = 0;
    for (raw) |c| {
        if (c == 0xFF) continue;
        if (n >= 5) break;
        out[n] = c;
        n += 1;
    }
    // init.asm: always append Chang ($1A) then Parry ($1B)
    if (n < 7) {
        out[n] = 0x1A;
        n += 1;
    }
    if (n < 7) {
        out[n] = 0x1B;
        n += 1;
    }
    return n;
}

pub fn commandName(r: *const rom_mod.Rom, cmd_id: u8, buf: []u8) []const u8 {
    if (cmd_id == 0xFF or cmd_id >= battle_cmd_count) {
        if (buf.len > 0) {
            buf[0] = '-';
            return buf[0..1];
        }
        return "";
    }
    const text = @import("../text.zig");
    const raw = r.slice(battle_cmd_names + @as(usize, cmd_id) * battle_cmd_stride, battle_cmd_stride) catch {
        const fb = "???";
        const n = @min(fb.len, buf.len);
        @memcpy(buf[0..n], fb[0..n]);
        return buf[0..n];
    };
    return text.decodeFixed(raw, buf);
}

// =============================================================================
// MenuWindowTbl (btlgfx_data.asm @fe5a) + MenuHDMAProp / MenuUpdateVRAMTfrTbl.
//
// Buffer size is 13 rows ($0d) — borders are drawn into a tall WRAM tilemap.
// On-screen reveal is only **10 rows** (MenuHDMAProp: 10 × 8 scanlines = 80px;
// MenuUpdateVRAMTfrTbl comments “10 rows”). Bottom-aligned on 224:
//   menu_y0 = 224 − 10*8 = 144 ($90).
// That lines up CmdCursorYTbl first row $98 with interior top (strip + 8).
// =============================================================================

/// Visible HDMA row count (not the 13-row WRAM buffer height).
pub const menu_visible_rows: u8 = 10;
/// Pixel Y of the visible menu strip top on the 256×224 view.
pub const menu_strip_y: i32 = 224 - @as(i32, menu_visible_rows) * 8; // 144 ($90)
/// Visible strip height in pixels.
pub const menu_strip_h: i32 = @as(i32, menu_visible_rows) * 8; // 80

/// 0: monster names — buffer $01,$00,$0c,$0d; visible h = 10.
pub const mon_name_window = struct {
    pub const x_tiles: u8 = 1;
    pub const y_tiles: u8 = 0;
    pub const w: u8 = 12;
    pub const h: u8 = menu_visible_rows;
    pub const x_px: i32 = @as(i32, x_tiles) * 8;
    pub const y_px: i32 = menu_strip_y + @as(i32, y_tiles) * 8;
    /// Text inset (one tile inside border) — top of interior, not box-centered.
    pub const text_x: i32 = x_px + 8;
    pub const text_y0: i32 = y_px + 8;
    pub const text_dy: i32 = 8;
};

/// 1: character names and HP — buffer $0d,$00,$12,$0d; visible h = 10.
pub const party_window = struct {
    pub const x_tiles: u8 = 13;
    pub const y_tiles: u8 = 0;
    pub const w: u8 = 18;
    pub const h: u8 = menu_visible_rows;
    pub const x_px: i32 = @as(i32, x_tiles) * 8;
    pub const y_px: i32 = menu_strip_y + @as(i32, y_tiles) * 8;
    pub const text_x: i32 = x_px + 8;
    pub const text_y0: i32 = y_px + 8;
    /// CharOrderTbl spacing: name then HP on next 8px line; next char +16.
    pub const row_dy: i32 = 16;
};

/// 2: battle commands — buffer $06,$00,$07,$0d; visible h = 10.
/// Cursor X=$28 (left of window); text to the right of 16×16 hand.
/// CmdCursorYTbl ($98…) is absolute screen Y — independent of strip math.
pub const cmd_window = struct {
    pub const x_tiles: u8 = 6;
    pub const y_tiles: u8 = 0;
    pub const w: u8 = 7;
    pub const h: u8 = menu_visible_rows;
    pub const x_px: i32 = @as(i32, x_tiles) * 8; // 48
    pub const y_px: i32 = menu_strip_y + @as(i32, y_tiles) * 8;
    /// Text X: right of hand at $28 (16 wide) → $38.
    pub const text_x: i32 = 0x38;
};

/// Inventory window (MenuWindowTbl id 5) — battle item list.
/// Full buffer is 30×51; HDMA shows the same 10-row bottom strip as main menu.
pub const inv_window = struct {
    pub const x_tiles: u8 = 1;
    pub const y_tiles: u8 = 0;
    pub const w: u8 = 30; // $1e
    pub const h: u8 = menu_visible_rows;
    pub const x_px: i32 = @as(i32, x_tiles) * 8;
    pub const y_px: i32 = menu_strip_y;
    /// InventoryCursorXTbl / ListCursorYTbl (btlgfx_data.asm @fc59 / @fc5b).
    pub const cursor_x = [_]i32{ 0x0C, 0x7C };
    pub const cursor_y = [_]i32{ 0x9C, 0xA8, 0xB4, 0xC0, 0xCC };
    pub const cols: u8 = 2;
    pub const rows: u8 = 5;
    /// Text inset from hand: icon+name starts ~16px right of cursor X.
    pub const text_dx: i32 = 16;
    /// 8px glyph centered in 16px hand row.
    pub const text_dy: i32 = 4;
};

/// Battle message window kinds (menu.asm Draw*MsgWindow).
/// Tile positions are in the message tilemap buffer; host maps Y to the
/// BG3 slot that OpenMsgWindow uploads to VRAM `$78e0` (row 7 of a $7800 map
/// stand-in → y = 56). X matches decomp (3,0)/(2,0)/(20,0).
pub const MsgKind = enum { full, left, right };

/// Shared Y for all battle message windows (OpenMsgWindow → `$78e0`).
pub const msg_y_px: i32 = 7 * 8; // 56 — BG3 row for `$78e0` with map base `$7800`

/// DrawFullMsgWindow: (3,0) 26×4 — ShowMsg_03 BattleMsg / dialogue.
pub const msg_window = struct {
    pub const x_tiles: u8 = 3;
    pub const y_tiles: u8 = 0;
    pub const w: u8 = 26;
    pub const h: u8 = 4;
    pub const x_px: i32 = @as(i32, x_tiles) * 8; // 24
    pub const y_px: i32 = msg_y_px;
    pub const text_x: i32 = x_px + 8;
    pub const text_y: i32 = y_px + 8; // first interior row under top border
    pub const border: BorderSet = .message;
};

/// DrawLeftMsgWindow: (2,0) 10×4 — attack names when `$6cc0` set; back attack.
pub const msg_window_left = struct {
    pub const x_tiles: u8 = 2;
    pub const w: u8 = 10;
    pub const h: u8 = 4;
    pub const x_px: i32 = @as(i32, x_tiles) * 8; // 16
    pub const y_px: i32 = msg_y_px;
    pub const text_x: i32 = x_px + 8;
    pub const text_y: i32 = y_px + 8;
    pub const border: BorderSet = .message;
};

/// DrawRightMsgWindow: (20,0) 10×4 — DrawAttackNameWindow default.
pub const msg_window_right = struct {
    pub const x_tiles: u8 = 20;
    pub const w: u8 = 10;
    pub const h: u8 = 4;
    pub const x_px: i32 = @as(i32, x_tiles) * 8; // 160
    pub const y_px: i32 = msg_y_px;
    pub const text_x: i32 = x_px + 8;
    pub const text_y: i32 = y_px + 8;
    pub const border: BorderSet = .message;
};
