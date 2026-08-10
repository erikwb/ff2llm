//! SNES graphics primitives (4bpp tiles, 15-bit BGR palettes).
const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn fromSnes(word: u16) Color {
        const r5: u5 = @truncate(word);
        const g5: u5 = @truncate(word >> 5);
        const b5: u5 = @truncate(word >> 10);
        return .{
            .r = @as(u8, r5) << 3 | @as(u8, r5) >> 2,
            .g = @as(u8, g5) << 3 | @as(u8, g5) >> 2,
            .b = @as(u8, b5) << 3 | @as(u8, b5) >> 2,
            .a = 255,
        };
    }

    pub fn toU32(self: Color) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }
};

/// Decode one 8×8 SNES 4bpp planar tile (32 bytes) into 64 palette indices.
pub fn decodeTile4bpp(tile: *const [32]u8, out: *[64]u8) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const p0 = tile[row * 2];
        const p1 = tile[row * 2 + 1];
        const p2 = tile[16 + row * 2];
        const p3 = tile[16 + row * 2 + 1];
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const bit: u3 = @intCast(7 - col);
            const c: u8 =
                ((p0 >> bit) & 1) |
                (((p1 >> bit) & 1) << 1) |
                (((p2 >> bit) & 1) << 2) |
                (((p3 >> bit) & 1) << 3);
            out[row * 8 + col] = c;
        }
    }
}

/// Decode one 8×8 SNES 3bpp planar tile (24 bytes) into 64 palette indices.
/// Planes 0–1 (16 bytes) + plane 2 (8 bytes); plane 3 is zero.
pub fn decodeTile3bpp(tile: *const [24]u8, out: *[64]u8) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const p0 = tile[row * 2];
        const p1 = tile[row * 2 + 1];
        const p2 = tile[16 + row];
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const bit: u3 = @intCast(7 - col);
            const c: u8 =
                ((p0 >> bit) & 1) |
                (((p1 >> bit) & 1) << 1) |
                (((p2 >> bit) & 1) << 2);
            out[row * 8 + col] = c;
        }
    }
}

/// FF4 overworld Mode-7 style tiles: 32 bytes of packed nibbles (low then high),
/// each nibble is a color offset added to `pal_base` (from WorldTilePal).
/// Matches battle/field `TfrWorldGfx` in everything8215/ff4.
pub fn decodeTileNibbles(tile: *const [32]u8, pal_base: u8, out: *[64]u8) void {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const b = tile[i];
        out[i * 2] = (b & 0x0F) +% pal_base;
        out[i * 2 + 1] = ((b >> 4) & 0x0F) +% pal_base;
    }
}

/// Load `count` little-endian SNES colors from ROM bytes.
pub fn loadPalette(bytes: []const u8, out: []Color) void {
    const n = @min(out.len, bytes.len / 2);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const w = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
        out[i] = Color.fromSnes(w);
        if (i % 16 == 0) out[i].a = 0; // index 0 transparent per subpalette
    }
}

/// Blit an 8×8 tile into an RGBA8888 buffer.
/// If `skip_zero`, palette index 0 is treated as transparent (sprites).
pub fn blitTile(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: []const Color,
    pal_offset: usize,
    skip_zero: bool,
) void {
    blitTileEx(dest, dest_w, dx, dy, indices, palette, pal_offset, skip_zero, false, false, false);
}

/// Like `blitTile` with optional H/V flip (SNES BG tilemap attributes).
/// `skip_fill`: also skip palette index 1 (WindowPal fill / glyph cell bg) so only
/// letter “ink” is drawn — needed when the destination is not already that fill color.
pub fn blitTileEx(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: []const Color,
    pal_offset: usize,
    skip_zero: bool,
    flip_h: bool,
    flip_v: bool,
    skip_fill: bool,
) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const src_row = if (flip_v) 7 - row else row;
            const src_col = if (flip_h) 7 - col else col;
            const px = dx + @as(i32, @intCast(col));
            const py = dy + @as(i32, @intCast(row));
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            if (ux >= dest_w) continue;
            const dest_h = dest.len / (dest_w * 4);
            if (uy >= dest_h) continue;

            const idx = indices[src_row * 8 + src_col];
            if (skip_zero and idx == 0) continue;
            if (skip_fill and idx == 1) continue;
            const ci = pal_offset + @as(usize, idx);
            const color = if (ci < palette.len) palette[ci] else Color{ .r = 255, .g = 0, .b = 255 };
            const o = (uy * dest_w + ux) * 4;
            dest[o] = color.r;
            dest[o + 1] = color.g;
            dest[o + 2] = color.b;
            dest[o + 3] = 255;
        }
    }
}

test "4bpp tile not all zero for non-empty" {
    var tile: [32]u8 = .{0} ** 32;
    tile[0] = 0xFF;
    tile[1] = 0x00;
    var out: [64]u8 = undefined;
    decodeTile4bpp(&tile, &out);
    try std.testing.expect(out[0] == 1 or out[7] == 1);
}
