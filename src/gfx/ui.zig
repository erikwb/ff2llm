//! Field UI: 2bpp window border + dialogue font from ROM WindowGfx.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("snes.zig");

/// WindowGfx @ $0AF000 (LoROM file 0x57000), 2bpp, full 4 KiB DMA region.
const window_gfx_cpu: u24 = 0x0AF000;
/// WindowPal @ $0D87D0
const window_pal_cpu: u24 = 0x0D87D0;

/// WindowGfx dialogue border tiles (verified from 2bpp bitmaps, not names alone).
///
///   $16/$17/$18 — top corners / top edge (bezel in lower half of tile)
///   $19/$1A     — straight left / right sides (body rows)
///   $1B/$1C/$1D — bottom-left / bottom edge / bottom-right (curves)
///
/// field_data.asm labels Mid=$1B..$1D and Btm=$19/$FF/$1A describe the
/// *expanding scroll buffer* (short window closes with Mid, then grows with
/// Btm rows). For a static fully-open box the on-screen order is:
///   top → body($19/fill/$1A)… → bottom($1B/$1C/$1D).
const tile_tl: u8 = 0x16;
const tile_t: u8 = 0x17;
const tile_tr: u8 = 0x18;
const tile_sl: u8 = 0x19; // side left (body)
const tile_sr: u8 = 0x1A; // side right (body)
const tile_bl: u8 = 0x1B; // bottom left curve
const tile_b: u8 = 0x1C; // bottom edge
const tile_br: u8 = 0x1D; // bottom right curve

/// EN DecodeDlgText (window.asm): fills $0774 with $68 bytes = 4 lines × 26 chars.
/// OpenDlgWindow then waits for a key and calls DecodeDlgText again for the next
/// chunk until the string terminator — multi-page dialogue.
pub const dlg_chars_per_line: usize = 26;
pub const dlg_lines_per_page: usize = 4;
/// Cap total laid-out lines (longest map lines we measured ≈ 34).
pub const dlg_max_lines: usize = 64;
/// Fully-open dialogue window height in 8px rows (OpenDlgWindow grows $df to 8).
const dlg_win_rows: i32 = 8;
/// Border + 28 content columns matches EN DlgTiles* (with side pads omitted).
const dlg_win_cols: i32 = 30;

pub const UiGfx = struct {
    /// 256 8×8 tiles, each pixel index 0..3.
    tiles: [256][64]u8 = undefined,
    /// 16-color window palette (first 4 used by 2bpp window/font).
    pal: [16]snes.Color = undefined,
    loaded: bool = false,

    pub fn load(self: *UiGfx, r: *const rom_mod.Rom) void {
        const gfx_off = rom_mod.Rom.loromOffset(window_gfx_cpu);
        const pal_off = rom_mod.Rom.loromOffset(window_pal_cpu);
        const raw = r.slice(gfx_off, 0x1000) catch {
            self.loaded = false;
            return;
        };
        const pal_bytes = r.slice(pal_off, 32) catch {
            self.loaded = false;
            return;
        };

        var t: usize = 0;
        while (t < 256) : (t += 1) {
            decode2bpp(raw[t * 16 ..][0..16], &self.tiles[t]);
        }
        snes.loadPalette(pal_bytes, self.pal[0..]);
        // Force opaque for UI (index 0 stays transparent for sprites, solid for fill).
        var i: usize = 0;
        while (i < 16) : (i += 1) self.pal[i].a = 255;
        self.loaded = true;
    }

    /// Map an ASCII character to an FF4 dialogue/menu font tile index.
    /// Same table as gfx/font.zig (WindowGfx sheet).
    pub fn asciiToTile(ch: u8) u8 {
        return @import("font.zig").asciiToTile(ch);
    }

    pub fn drawTile(
        self: *const UiGfx,
        dest: []u8,
        dest_w: usize,
        dx: i32,
        dy: i32,
        tile: u8,
        /// CGRAM subpalette slot (0–3) × 4 colors.
        pal_slot: u2,
        transparent0: bool,
    ) void {
        if (!self.loaded) return;
        const base: usize = @as(usize, pal_slot) * 4;
        const indices = &self.tiles[tile];
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                const idx = indices[row * 8 + col];
                if (transparent0 and idx == 0) continue;
                const px = dx + @as(i32, @intCast(col));
                const py = dy + @as(i32, @intCast(row));
                if (px < 0 or py < 0) continue;
                const ux: usize = @intCast(px);
                const uy: usize = @intCast(py);
                const dh = dest.len / (dest_w * 4);
                if (ux >= dest_w or uy >= dh) continue;
                const color = self.pal[base + idx];
                const o = (uy * dest_w + ux) * 4;
                dest[o] = color.r;
                dest[o + 1] = color.g;
                dest[o + 2] = color.b;
                dest[o + 3] = 255;
            }
        }
    }

    /// Draw a classic FF4 dialogue window and one page of text (bottom of screen).
    /// `page` is 0-based; each page is up to `dlg_lines_per_page` lines (DecodeDlgText $68).
    pub fn drawDialogue(self: *const UiGfx, dest: []u8, dest_w: usize, dest_h: usize, text: []const u8, page: usize) void {
        if (!self.loaded) {
            drawDialogueFallback(dest, dest_w, dest_h, text);
            return;
        }

        var lines: [dlg_max_lines][dlg_chars_per_line]u8 = undefined;
        var line_lens: [dlg_max_lines]usize = .{0} ** dlg_max_lines;
        const n_lines = layoutDialogueLines(text, &lines, &line_lens);
        const pages = dialoguePageCountFromLines(n_lines);
        const page_i = @min(page, pages -% 1);
        const line0 = page_i * dlg_lines_per_page;
        const line1 = @min(line0 + dlg_lines_per_page, n_lines);

        // Fully-open EN dialogue is 8 tile rows (OpenDlgWindow: $df → 8).
        const rows: i32 = dlg_win_rows;
        const cols: i32 = dlg_win_cols;
        const win_w_px = cols * 8;
        const win_h_px = rows * 8;
        const origin_x: i32 = @divTrunc(@as(i32, @intCast(dest_w)) - win_w_px, 2);
        const origin_y: i32 = @as(i32, @intCast(dest_h)) - win_h_px - 8;

        // Interior fill: solid tile $FF = palette index 1 (blue $4000), not pal[0].
        // Top border bezel sits in the lower half of $16–$18; fill from first body row.
        if (rows > 1) {
            fillRect(dest, dest_w, origin_x + 8, origin_y + 8, win_w_px - 16, win_h_px - 16, self.pal[1]);
        }

        var ry: i32 = 0;
        while (ry < rows) : (ry += 1) {
            var rx: i32 = 0;
            while (rx < cols) : (rx += 1) {
                if (ry > 0 and ry < rows - 1 and rx > 0 and rx < cols - 1) continue;

                const tile: u8 = blk: {
                    if (ry == 0) {
                        if (rx == 0) break :blk tile_tl;
                        if (rx == cols - 1) break :blk tile_tr;
                        break :blk tile_t;
                    } else if (ry == rows - 1) {
                        if (rx == 0) break :blk tile_bl;
                        if (rx == cols - 1) break :blk tile_br;
                        break :blk tile_b;
                    } else {
                        if (rx == 0) break :blk tile_sl;
                        break :blk tile_sr;
                    }
                };
                self.drawTile(dest, dest_w, origin_x + rx * 8, origin_y + ry * 8, tile, 0, true);
            }
        }

        // Text: 26 chars/line, 8px glyphs, 12px pitch (fits 4 lines above bottom border).
        const text_x = origin_x + 16;
        const text_y = origin_y + 10;
        const line_pitch: i32 = 12;
        var li: usize = line0;
        var row_i: usize = 0;
        while (li < line1) : ({
            li += 1;
            row_i += 1;
        }) {
            const dy = text_y + @as(i32, @intCast(row_i)) * line_pitch;
            if (dy + 8 > origin_y + win_h_px - 8) break;
            var ci: usize = 0;
            while (ci < line_lens[li]) : (ci += 1) {
                const ch = lines[li][ci];
                const tile = asciiToTile(ch);
                if (tile == 0xFF) continue; // space / blank
                self.drawTile(dest, dest_w, text_x + @as(i32, @intCast(ci)) * 8, dy, tile, 0, true);
            }
        }
    }
};

/// How many confirm-pages `text` needs (OpenDlgWindow loop over DecodeDlgText).
pub fn dialoguePageCount(text: []const u8) usize {
    var lines: [dlg_max_lines][dlg_chars_per_line]u8 = undefined;
    var line_lens: [dlg_max_lines]usize = .{0} ** dlg_max_lines;
    const n = layoutDialogueLines(text, &lines, &line_lens);
    return dialoguePageCountFromLines(n);
}

fn dialoguePageCountFromLines(n_lines: usize) usize {
    if (n_lines == 0) return 1;
    return (n_lines + dlg_lines_per_page - 1) / dlg_lines_per_page;
}

test "dialogue page count multi-page crew F0 $20" {
    // Event dlg $20: 6 lines → 2 pages (4 lines/page). Page 0 ends on "That's our duty."
    const text =
        \\Crew:Why are we robbing
        \\ crystals from innocent
        \\ people?
        \\Crew:That's our duty.
        \\Crew:Do we really have to
        \\ keep doing this?
    ;
    try std.testing.expectEqual(@as(usize, 2), dialoguePageCount(text));
}

test "dialogue page count single page F0 $1f" {
    const text =
        \\Crew:Captain Cecil,
        \\ we are about to arrive!
        \\Cecil:Good.
    ;
    try std.testing.expectEqual(@as(usize, 1), dialoguePageCount(text));
}

/// Layout dialogue like EN DecodeDlgText / TextCmd_01:
/// `$01`/`$09` → newline (pad to next 26-col row); hard wrap at 26.
/// Soft word-wrap only when a line would otherwise overflow without a break.
fn layoutDialogueLines(
    text: []const u8,
    lines: *[dlg_max_lines][dlg_chars_per_line]u8,
    lens: *[dlg_max_lines]usize,
) usize {
    var line_i: usize = 0;
    var col: usize = 0;
    var i: usize = 0;

    if (text.len == 0) {
        lens[0] = 0;
        return 1;
    }

    while (i < text.len and line_i < dlg_max_lines) {
        const ch = text[i];

        if (ch == '\n') {
            // TextCmd_01 / $09: advance to next 26-char line slot.
            lens[line_i] = col;
            line_i += 1;
            col = 0;
            i += 1;
            // Collapse runs of newlines into empty lines (explicit blank rows).
            continue;
        }

        // Soft wrap at word boundary when the next word won't fit.
        if (ch == ' ' and col > 0) {
            var word_len: usize = 0;
            var j = i + 1;
            while (j < text.len and text[j] != ' ' and text[j] != '\n') : (j += 1) word_len += 1;
            if (col + 1 + word_len > dlg_chars_per_line and word_len <= dlg_chars_per_line) {
                lens[line_i] = col;
                line_i += 1;
                col = 0;
                i += 1;
                continue;
            }
        }

        // Hard wrap at 26 (buffer fills linearly in the original).
        if (col >= dlg_chars_per_line) {
            lens[line_i] = col;
            line_i += 1;
            col = 0;
            if (line_i >= dlg_max_lines) break;
            if (ch == ' ') {
                i += 1;
                continue;
            }
        }

        lines[line_i][col] = ch;
        col += 1;
        i += 1;
    }

    if (line_i < dlg_max_lines) {
        lens[line_i] = col;
        line_i += 1;
    }
    // Drop a trailing empty line produced by a final newline.
    if (line_i > 1 and lens[line_i - 1] == 0) line_i -= 1;
    return @max(line_i, 1);
}

fn decode2bpp(tile: *const [16]u8, out: *[64]u8) void {
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

fn fillRect(dest: []u8, dest_w: usize, dx: i32, dy: i32, w: i32, h: i32, color: snes.Color) void {
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const px = dx + x;
            const py = dy + y;
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            const dh = dest.len / (dest_w * 4);
            if (ux >= dest_w or uy >= dh) continue;
            const o = (uy * dest_w + ux) * 4;
            dest[o] = color.r;
            dest[o + 1] = color.g;
            dest[o + 2] = color.b;
            dest[o + 3] = 255;
        }
    }
}

fn drawDialogueFallback(dest: []u8, dest_w: usize, dest_h: usize, text: []const u8) void {
    const y0: i32 = @as(i32, @intCast(dest_h)) - 56;
    fillRect(dest, dest_w, 8, y0, @as(i32, @intCast(dest_w)) - 16, 48, snes.Color{ .r = 0, .g = 0, .b = 80 });
    _ = text;
}
