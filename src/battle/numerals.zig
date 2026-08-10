//! Damage numerals — ShowMsg_04 / DrawDmgNumerals (btlgfx).
//!
//! Bounce offsets from DmgNumeralBounceTbl; digit tiles use font codes $80–$89.
const std = @import("std");
const font_mod = @import("../gfx/font.zig");

/// DmgNumeralBounceTbl (btlgfx_data.asm @fc8a) — first 42 frames used by ROM.
pub const bounce_tbl = [_]i8{
    0, 0, 0, 0, 0, -3, -6, -9, -12, -14, -15, -15, -16, -16, -16, -15,
    -15, -14, -12, -9, -6, -3, 0, -2, -4, -4, -5, -5, -5, -4, -4, -2,
    -1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

pub const Floater = struct {
    active: bool = false,
    /// Frames elapsed (0..$29 ROM disables at $2a).
    t: u8 = 0,
    x: i16 = 0,
    y: i16 = 0,
    /// Digits as ROM font codes $80–$89, leading $FF = blank.
    digits: [4]u8 = .{0xFF} ** 4,
    miss: bool = false,
    crit: bool = false,

    pub fn spawn(self: *Floater, x: i16, y: i16, damage: u16, miss: bool, crit: bool) void {
        self.* = .{
            .active = true,
            .t = 0,
            .x = x,
            .y = y,
            .miss = miss,
            .crit = crit,
        };
        if (miss) {
            // EN "Miss" tiles $6c-$6f in ROM; show as MISS via font if available.
            self.digits = .{ 0xFF, 0xFF, 0xFF, 0xFF };
            return;
        }
        // HexToDec → 4 digits; NormalizeNum leading blank as $FF.
        var d: u16 = damage;
        if (d > 9999) d = 9999;
        var buf: [4]u8 = .{0xFF} ** 4;
        var i: usize = 4;
        if (d == 0) {
            buf[3] = 0x80; // '0'
        } else {
            while (d > 0 and i > 0) {
                i -= 1;
                buf[i] = 0x80 + @as(u8, @intCast(d % 10));
                d /= 10;
            }
        }
        self.digits = buf;
    }

    pub fn tick(self: *Floater) void {
        if (!self.active) return;
        self.t +%= 1;
        if (self.t >= 0x2A) self.active = false;
    }

    pub fn draw(self: *const Floater, dest: []u8, dest_w: usize, font: *const font_mod.MenuFont) void {
        if (!self.active or !font.loaded) return;
        const t: usize = @min(@as(usize, self.t), bounce_tbl.len - 1);
        if (self.miss) {
            const by = self.y + bounce_tbl[t] - 8;
            font.drawAscii(dest, dest_w, self.x - 8, by, "Miss");
            return;
        }
        // Digits delayed by 3 frames each (DrawDmgNumerals @e552).
        var di: usize = 0;
        while (di < 4) : (di += 1) {
            const code = self.digits[di];
            if (code == 0xFF) continue;
            const delay = di * 3;
            if (self.t < delay) continue;
            const bt: usize = @min(@as(usize, self.t - @as(u8, @intCast(delay))), bounce_tbl.len - 1);
            const by = self.y + bounce_tbl[bt] - 8;
            const bx = self.x - 16 + @as(i16, @intCast(di)) * 8;
            font.drawRaw(dest, dest_w, bx, by, &[_]u8{code});
        }
    }
};

pub const FloaterBank = struct {
    slots: [8]Floater = [_]Floater{.{}} ** 8,

    pub fn spawn(self: *FloaterBank, x: i16, y: i16, damage: u16, miss: bool, crit: bool) void {
        for (&self.slots) |*f| {
            if (!f.active) {
                f.spawn(x, y, damage, miss, crit);
                return;
            }
        }
        // Overwrite oldest
        self.slots[0].spawn(x, y, damage, miss, crit);
    }

    pub fn tick(self: *FloaterBank) void {
        for (&self.slots) |*f| f.tick();
    }

    pub fn draw(self: *const FloaterBank, dest: []u8, dest_w: usize, font: *const font_mod.MenuFont) void {
        for (&self.slots) |*f| f.draw(dest, dest_w, font);
    }
};
