//! Menu/battle font — WindowGfx sheet @ 0A/F000 (file 0x57000).
//!
//! English DrawLetterNoDakuten (btlgfx/menu.asm): tile index = character code.
//! Encoding (text.zig / item names / BattleCmdName):
//!   $42..$5B A-Z, $5C..$75 a-z, $80..$89 0-9
//!   $C0 '  $C1 .  $C2 -  $C3 /  $C4 !  $C5 ?  $C6 %  $C7 /  $C8 :  $C9 ,
//!   $FF space/pad; $77/$78 small "hp" pair; $C7 slash in HP text (MenuText_0002)
const snes = @import("snes.zig");
const rom_mod = @import("../rom.zig");

pub const font_gfx_file: usize = 0x57000;
pub const font_tile_count: usize = 256;
/// WindowPal — white text uses subpalette 0 (colors 0–3).
pub const font_pal_file: usize = 0x687D0;

/// Palette offset for white text (lda #$00) vs gray (lda #$04).
pub const pal_white: usize = 0;
pub const pal_gray: usize = 4;

pub const MenuFont = struct {
    tiles: [font_tile_count][64]u8 = undefined,
    palette: [16]snes.Color = undefined,
    loaded: bool = false,

    pub fn load(self: *MenuFont, r: *const rom_mod.Rom) !void {
        const gfx = try r.slice(font_gfx_file, font_tile_count * 16);
        var t: usize = 0;
        while (t < font_tile_count) : (t += 1) {
            decodeTile2bpp(gfx[t * 16 ..][0..16], &self.tiles[t]);
        }
        const pal = try r.slice(font_pal_file, 32);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const w = @as(u16, pal[i * 2]) | (@as(u16, pal[i * 2 + 1]) << 8);
            self.palette[i] = snes.Color.fromSnes(w);
            self.palette[i].a = 255;
        }
        // Index 0 transparent within each 4-color subpalette.
        self.palette[0].a = 0;
        self.palette[4].a = 0;
        self.palette[8].a = 0;
        self.palette[12].a = 0;
        self.loaded = true;
    }

    /// Same as WindowChrome.applyWindowColor / UpdateWindowColor (system.asm @fed6).
    /// Font and window share WindowPal on SNES; glyph tiles use color 1 as the
    /// opaque cell behind letters, so `$16aa` must hit font CGRAM too.
    pub fn applyWindowColor(self: *MenuFont, color_snes: u16) void {
        if (!self.loaded) return;
        var c = snes.Color.fromSnes(color_snes);
        c.a = 255;
        const idxs = [_]usize{ 1, 5, 9, 13 };
        for (idxs) |i| self.palette[i] = c;
    }

    /// Draw ROM-encoded tile codes (not ASCII).
    pub fn drawRaw(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        codes: []const u8,
    ) void {
        self.drawRawPal(dest, dest_w, x, y, codes, pal_white);
    }

    pub fn drawRawPal(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        codes: []const u8,
        pal_off: usize,
    ) void {
        self.drawRawPalEx(dest, dest_w, x, y, codes, pal_off, false);
    }

    /// `ink_only`: skip palette index 1 (cell fill) — letter strokes only.
    pub fn drawRawPalEx(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        codes: []const u8,
        pal_off: usize,
        ink_only: bool,
    ) void {
        if (!self.loaded) return;
        var cx = x;
        for (codes) |code| {
            if (code == 0) break;
            if (code == 0xFF) {
                cx += 8;
                continue;
            }
            snes.blitTileEx(dest, dest_w, cx, y, &self.tiles[code], &self.palette, pal_off, true, false, false, ink_only);
            cx += 8;
        }
    }

    /// Draw ASCII mapped to ROM tile codes.
    pub fn drawAscii(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        s: []const u8,
    ) void {
        self.drawAsciiPal(dest, dest_w, x, y, s, pal_white);
    }

    /// Letter ink only (no blue cell behind glyphs) — title splash / non-fill bgs.
    pub fn drawAsciiInk(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        s: []const u8,
    ) void {
        self.drawAsciiPalEx(dest, dest_w, x, y, s, pal_white, true);
    }

    pub fn drawAsciiPal(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        s: []const u8,
        pal_off: usize,
    ) void {
        self.drawAsciiPalEx(dest, dest_w, x, y, s, pal_off, false);
    }

    pub fn drawAsciiPalEx(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        s: []const u8,
        pal_off: usize,
        ink_only: bool,
    ) void {
        if (!self.loaded) return;
        var cx = x;
        for (s) |ch| {
            const code = asciiToTile(ch);
            if (code == 0xFF) {
                cx += 8;
                continue;
            }
            snes.blitTileEx(dest, dest_w, cx, y, &self.tiles[code], &self.palette, pal_off, true, false, false, ink_only);
            cx += 8;
        }
    }

    /// Draw a decimal number with ROM digit tiles $80–$89 (no leading zeros unless width forces).
    pub fn drawNumber(
        self: *const MenuFont,
        dest: []u8,
        dest_w: usize,
        x: i32,
        y: i32,
        value: u32,
        /// Minimum width; pad left with $FF blanks (not zero) like NormalizeNum.
        min_width: u8,
    ) void {
        if (!self.loaded) return;
        var digits: [10]u8 = .{0xFF} ** 10;
        var n: usize = 0;
        var v = value;
        if (v == 0) {
            digits[0] = 0x80;
            n = 1;
        } else {
            var tmp: [10]u8 = undefined;
            var tlen: usize = 0;
            while (v > 0 and tlen < 10) {
                tmp[tlen] = 0x80 + @as(u8, @intCast(v % 10));
                v /= 10;
                tlen += 1;
            }
            // reverse
            var i: usize = 0;
            while (i < tlen) : (i += 1) digits[i] = tmp[tlen - 1 - i];
            n = tlen;
        }
        const width: usize = @max(n, min_width);
        const pad = width - n;
        var codes: [10]u8 = .{0xFF} ** 10;
        var i: usize = 0;
        while (i < pad) : (i += 1) codes[i] = 0xFF;
        i = 0;
        while (i < n) : (i += 1) codes[pad + i] = digits[i];
        self.drawRaw(dest, dest_w, x, y, codes[0..width]);
    }

    pub const glyph_w: i32 = 8;
    pub const glyph_h: i32 = 8;
};

/// Reverse of text.zig decode for A–Z, a–z, 0–9, common punctuation.
pub fn asciiToTile(ch: u8) u8 {
    return switch (ch) {
        'A'...'Z' => 0x42 + (ch - 'A'),
        'a'...'z' => 0x5C + (ch - 'a'),
        '0'...'9' => 0x80 + (ch - '0'),
        ' ' => 0xFF,
        '\'' => 0xC0,
        '.' => 0xC1,
        '-' => 0xC2,
        '/' => 0xC7, // MenuText_0002 HP separator (also $C3 exists)
        '!' => 0xC4,
        '?' => 0xC5,
        '%' => 0xC6,
        ':' => 0xC8,
        ',' => 0xC9,
        else => 0xFF,
    };
}

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
