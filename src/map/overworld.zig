//! Overworld tilemap decompress + metatile rendering (FF2 US / FF4).
//!
//! Tile passability matches everything8215/ff4 field/move.asm CheckPlayerMoveWorld:
//!   (dest_prop & 0x41) & (curr_prop & 0x41) != 0
//! Properties are 128 × 2 bytes (GetTileProp indexes tile_id*2 into $0EDB).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("../gfx/snes.zig");
const vehicle_land = @import("vehicle.zig");

pub const map_size: usize = 256;
pub const meta_px: usize = 16;

/// Segment "world_tilemap" @ $16/8000 (tilemap.asm) → file 0xB0000.
/// Ptr tables then data: OW @ $8480, under @ $C480, moon @ $E180.
const ow_ptrs: usize = 0xB0000; // $16/8000 — 256 rel ptrs
const ow_data: usize = 0xB0480; // $16/8480
const under_ptrs: usize = 0xB0200; // $16/8200 — 256 rel ptrs
const under_data: usize = 0xB4480; // $16/C480
const moon_ptrs: usize = 0xB0400; // $16/8400 — 64 rel ptrs
const moon_data: usize = 0xB6180; // $16/E180
/// WorldBGGfx @ 1D/8000 → 0xE8000; three worlds × $2000 (TfrWorldGfx `$1700<<13`).
const world_gfx: usize = 0xE8000;
const world_tileset: usize = 0xA0000;
/// WorldTilePal — 256 bytes × 3 worlds (TfrWorldGfx `$1700<<8`).
const world_tile_pal: usize = 0xA0600;
const world_pal: usize = 0xA0900;
/// 128 tiles × 2 bytes × 3 worlds (WorldTileProp_0000/1/2).
const world_tile_prop: usize = 0xA0A80;
const world_tile_prop_bytes: usize = 256;

/// MapSizeMask (move.asm @ad0b) — index `$1700` / world id.
pub const map_size_mask_tbl = [_]u8{ 0xFF, 0x7F, 0x3F };

/// Mode-7 water tile ranges (LoadWaterGfx / TfrWaterGfx).
/// VRAM $2000 = tile 128 → 4 tiles (0x80–0x83) → $7f5800 horizontal buffer.
/// VRAM $1e80 = tile 122 → 4 tiles (0x7a–0x7d) → $7f5900 vertical buffer.
const water_tile_x0: usize = 128;
const water_tile_y0: usize = 122;
const water_buf_tiles: usize = 4;
const water_buf_bytes: usize = water_buf_tiles * 64; // 256

/// WaterShiftY / WaterShiftX @ field.asm $909a/$90aa — row/column offsets per $7c phase.
const water_shift_y = [_]u8{ 0x00, 0x41, 0x02, 0x43, 0x04, 0x45, 0x06, 0x47, 0x40, 0x01, 0x42, 0x03, 0x44, 0x05, 0x46, 0x07 };
const water_shift_x = [_]u8{ 0x00, 0x88, 0x10, 0x98, 0x20, 0xa8, 0x30, 0xb8, 0x80, 0x08, 0x90, 0x18, 0xa0, 0x28, 0xb0, 0x38 };

pub const Overworld = struct {
    cells: []u8,
    meta_tl: [128]u8 = undefined,
    meta_tr: [128]u8 = undefined,
    meta_bl: [128]u8 = undefined,
    meta_br: [128]u8 = undefined,
    /// Low byte of each tile's 2-byte property (what move.asm tests with #$41).
    prop_lo: [128]u8 = undefined,
    /// High byte (world flags: battles, airship land, forest, etc.).
    prop_hi: [128]u8 = undefined,
    palette: [64]snes.Color = undefined,
    /// Snapshot after LoadWorldPal — UpdateZoomPal blends from this each frame.
    base_palette: [64]snes.Color = undefined,
    tiles: [256][64]u8 = undefined,
    /// Current world 0=OW, 1=under, 2=moon (`$1700` / `$1701` on world).
    world_id: u8 = 0,
    /// MapSizeMask for coordinate wrap.
    size_mask: u8 = 0xFF,
    /// $7c — water animation frame counter (field.asm UpdateWaterAnim).
    water_7c: u8 = 0,
    /// $7f5800 — Mode-7 pixels for tiles 128–131 (horizontal shift buffer).
    water_buf_x: [water_buf_bytes]u8 = undefined,
    /// $7f5900 — Mode-7 pixels for tiles 122–125 (vertical shift buffer).
    water_buf_y: [water_buf_bytes]u8 = undefined,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Overworld) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn load(gpa: std.mem.Allocator, r: *const rom_mod.Rom) !Overworld {
        var ow: Overworld = .{
            .cells = try gpa.alloc(u8, map_size * map_size),
            .allocator = gpa,
        };
        errdefer gpa.free(ow.cells);
        try ow.switchWorld(r, 0);
        return ow;
    }

    /// LoadOverworld / LoadUnderground / LoadMoon (field.asm) — full world swap.
    pub fn switchWorld(self: *Overworld, r: *const rom_mod.Rom, world_id: u8) !void {
        const w: u8 = @min(world_id, 2);
        self.world_id = w;
        self.size_mask = map_size_mask_tbl[w];

        // Tilemap cells
        @memset(self.cells, 0);
        switch (w) {
            0 => try decompressOverworld(r, self.cells),
            1 => try decompressSimple(r, under_ptrs, under_data, 256, 256, self.cells),
            else => try decompressSimple(r, moon_ptrs, moon_data, 64, 64, self.cells),
        }

        // WorldTileset / Prop / Pal per world (0x200 / 0x100 / 0x80 strides).
        const wu: usize = w;
        const ts = try r.slice(world_tileset + wu * 0x200, 512);
        @memcpy(self.meta_tl[0..], ts[0..128]);
        @memcpy(self.meta_tr[0..], ts[0x80..][0..128]);
        @memcpy(self.meta_bl[0..], ts[0x100..][0..128]);
        @memcpy(self.meta_br[0..], ts[0x180..][0..128]);

        const prop = try r.slice(world_tile_prop + wu * 0x100, world_tile_prop_bytes);
        var i: usize = 0;
        while (i < 128) : (i += 1) {
            self.prop_lo[i] = prop[i * 2];
            self.prop_hi[i] = prop[i * 2 + 1];
        }

        const pal_bytes = try r.slice(world_pal + wu * 0x80, 128);
        snes.loadPalette(pal_bytes, self.palette[0..]);
        var p: usize = 0;
        while (p < 64) : (p += 1) {
            self.palette[p].a = 255;
            self.base_palette[p] = self.palette[p];
        }

        // TfrWorldGfx (bg_gfx.asm @b181): WorldTilePal[$1700<<8] + WorldBGGfx[$1700<<13].
        // Three 256-tile banks @ 1D/8000 (0xE8000), stride $2000; tile-pal stride $100.
        const gfx_pal = try r.slice(world_tile_pal + wu * 0x100, 256);
        const gfx = try r.slice(world_gfx + wu * 0x2000, 256 * 32);
        var t: usize = 0;
        while (t < 256) : (t += 1) {
            snes.decodeTileNibbles(gfx[t * 32 ..][0..32], gfx_pal[t], &self.tiles[t]);
        }
        // LoadLavaGfx is a separate VRAM overlay for under lava anim buffers, not a full
        // tileset replace — keep WorldBGGfx bank as the mode-7 base for all worlds.

        self.loadWaterBuffers();
    }

    /// Legacy name used by tunnel path — full switchWorld.
    pub fn reloadWorldAssets(self: *Overworld, r: *const rom_mod.Rom, world_id: u8) !void {
        try self.switchWorld(r, world_id);
    }

    /// ModOverworldTilemap (field.asm @c6f4) — patch OW cells from event switches.
    /// Call after `switchWorld` and whenever a relevant switch is set.
    pub fn applyEventTileMods(self: *Overworld, switches: []const u8) void {
        if (self.world_id != 0) return;
        const on = struct {
            fn bit(sw: []const u8, id: u8) bool {
                const bi: usize = id / 8;
                if (bi >= sw.len) return false;
                const b: u3 = @truncate(id % 8);
                return (sw[bi] & (@as(u8, 1) << b)) != 0;
            }
        }.bit;

        // `$1282&$10` → switch $14: destroyed Damcyan castle (rows $39/$3a, cols $e7/$e8).
        if (on(switches, 0x14)) {
            self.setCell(0xE7, 0x39, 0x2D);
            self.setCell(0xE8, 0x39, 0x2E);
            self.setCell(0xE7, 0x3A, 0x3D);
            self.setCell(0xE8, 0x3A, 0x3E);
        }

        // `$1281&$40` → switch $0E: Mist mountain pass opened (rows $76–$78).
        if (on(switches, 0x0E)) {
            // Row $76: cols $d2–$d6 = $13
            var c: u8 = 0xD2;
            while (c <= 0xD6) : (c += 1) self.setCell(c, 0x76, 0x13);
            // Row $77: $12, $13×3, $14
            self.setCell(0xD2, 0x77, 0x12);
            self.setCell(0xD3, 0x77, 0x13);
            self.setCell(0xD4, 0x77, 0x13);
            self.setCell(0xD5, 0x77, 0x13);
            self.setCell(0xD6, 0x77, 0x14);
            // Row $78: all $13
            c = 0xD2;
            while (c <= 0xD6) : (c += 1) self.setCell(c, 0x78, 0x13);
        }

        // `$1286&$01` → switch $30 OFF: fill Agart hole (rows $d2–$d6). When ON, leave hole.
        if (!on(switches, 0x30)) {
            self.setCell(0xDB, 0xD2, 0x13);
            self.setCell(0xDA, 0xD3, 0x13);
            self.setCell(0xDB, 0xD3, 0x13);
            self.setCell(0xDC, 0xD3, 0x13);
            self.setCell(0xD9, 0xD4, 0x13);
            self.setCell(0xDA, 0xD4, 0x13);
            self.setCell(0xDB, 0xD4, 0x13);
            self.setCell(0xDC, 0xD4, 0x13);
            self.setCell(0xDD, 0xD4, 0x13);
            self.setCell(0xDA, 0xD5, 0x13);
            self.setCell(0xDB, 0xD5, 0x13);
            self.setCell(0xDC, 0xD5, 0x13);
            self.setCell(0xDB, 0xD6, 0x13);
        }
    }

    fn setCell(self: *Overworld, x: u8, y: u8, tile: u8) void {
        const ux: usize = x;
        const uy: usize = y;
        if (ux >= map_size or uy >= map_size) return;
        self.cells[uy * map_size + ux] = tile;
    }

    pub fn wrapCoord(self: *const Overworld, c: i32) i32 {
        return c & @as(i32, self.size_mask);
    }

    /// LoadWaterGfx — copy decoded water tiles into $7f5800 / $7f5900.
    fn loadWaterBuffers(self: *Overworld) void {
        var t: usize = 0;
        while (t < water_buf_tiles) : (t += 1) {
            @memcpy(self.water_buf_x[t * 64 ..][0..64], self.tiles[water_tile_x0 + t][0..]);
            @memcpy(self.water_buf_y[t * 64 ..][0..64], self.tiles[water_tile_y0 + t][0..]);
        }
        self.water_7c = 0;
    }

    /// TfrWaterGfx equivalent: write animated buffers back into `tiles` for rendering.
    fn tfrWaterGfx(self: *Overworld) void {
        var t: usize = 0;
        while (t < water_buf_tiles) : (t += 1) {
            @memcpy(self.tiles[water_tile_x0 + t][0..], self.water_buf_x[t * 64 ..][0..64]);
            @memcpy(self.tiles[water_tile_y0 + t][0..], self.water_buf_y[t * 64 ..][0..64]);
        }
    }

    /// UpdateWaterLavaAnim (field.asm @8e47): OW water / under lava / moon none.
    pub fn tickWaterLavaAnim(self: *Overworld) void {
        switch (self.world_id) {
            0 => self.tickWaterAnim(),
            1 => self.tickLavaAnim(),
            else => {}, // moon: no water/lava anim
        }
    }

    /// UpdateWaterAnim + TfrWaterGfx (field.asm @8fa1 / @8e67).
    pub fn tickWaterAnim(self: *Overworld) void {
        // Horizontal shift only on even $7c (bit0 clear).
        if ((self.water_7c & 1) == 0) {
            self.shiftWaterBufX();
        }

        // Vertical shifts always (two identical passes = 2 px/frame).
        var pass: u8 = 0;
        while (pass < 2) : (pass += 1) {
            const idx: usize = self.water_7c & 0x0F;
            const base_y: usize = water_shift_y[idx];

            var x: usize = base_y + 0x38;
            const saved = self.water_buf_y[x];
            var y: usize = 0;
            while (y < 7) : (y += 1) {
                self.water_buf_y[x] = self.water_buf_y[x - 8];
                x -= 8;
            }
            x = base_y + 0xB8;
            self.water_buf_y[base_y] = self.water_buf_y[x];
            y = 0;
            while (y < 7) : (y += 1) {
                self.water_buf_y[x] = self.water_buf_y[x - 8];
                x -= 8;
            }
            self.water_buf_y[x] = saved;
        }

        self.water_7c +%= 1;
        self.tfrWaterGfx();
    }

    /// UpdateLavaAnim (field.asm @8ee3) — X-only scroll on even `$7c`, same buffer as water.
    pub fn tickLavaAnim(self: *Overworld) void {
        if ((self.water_7c & 1) != 0) {
            // Odd frames: no shift (rts early), but TfrLavaGfx still incs $7c on transfer.
            // ROM: UpdateLavaAnim returns; TfrLavaGfx always incs $7c.
            self.water_7c +%= 1;
            self.tfrLavaGfx();
            return;
        }
        self.shiftWaterBufX();
        self.water_7c +%= 1;
        self.tfrLavaGfx();
    }

    /// UpdateBabilPal (pal_anim.asm @c3ea) — flash BG color 0 (OW) or pal3 c0 (under) when flag set.
    pub fn applyBabilPal(self: *Overworld, snes_7a: u8, flash: bool) void {
        if (self.world_id >= 2) return;
        // OW: `$0cdb+$1e` = color 15 of pal0; under: `$0cdb+$7e` = color 63 of pal3.
        const idx: usize = if (self.world_id == 0) 15 else 63;
        if (idx >= self.palette.len) return;
        if (flash) {
            // `lda $7a / asl / sta lo / eor #$ff / sta hi` — wild flash color.
            const lo: u8 = snes_7a << 1;
            const hi: u8 = ~lo;
            const w: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            self.palette[idx] = snes.Color.fromSnes(w & 0x7FFF);
            self.palette[idx].a = 255;
        } else {
            // Restore from base (clear flash).
            self.palette[idx] = self.base_palette[idx];
        }
    }

    /// UpdateLavaPal (pal_anim.asm @c4cd) — underground only; `$7a&$70` selects LavaAnimPal row.
    pub fn applyLavaPal(self: *Overworld, snes_7a: u8) void {
        if (self.world_id != 1) return;
        const row: usize = (snes_7a & 0x70) >> 4; // 0..7
        const byte_off: usize = lava_pal_tbl[@min(row, lava_pal_tbl.len - 1)];
        const word0: usize = byte_off / 2;
        // `$0cff` = CGRAM color 18 from `$0cdb` base (byte offset $24).
        const base_color: usize = 18;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const wi = word0 + i;
            if (wi >= lava_anim_pal.len) break;
            const ci = base_color + i;
            if (ci >= self.palette.len) break;
            self.palette[ci] = snes.Color.fromSnes(lava_anim_pal[wi]);
            self.palette[ci].a = 255;
        }
    }

    /// Shared horizontal 8-byte rotate used by water (even frames) and lava.
    fn shiftWaterBufX(self: *Overworld) void {
        const idx: usize = (self.water_7c >> 1) & 0x0F;
        const base: usize = water_shift_x[idx];
        var x: usize = base | 0x07;
        const saved = self.water_buf_x[x];
        var y: usize = 0;
        while (y < 7) : (y += 1) {
            self.water_buf_x[x] = self.water_buf_x[x - 1];
            x -= 1;
        }
        x = (x & 0xF8) + 0x47;
        self.water_buf_x[base] = self.water_buf_x[x];
        y = 0;
        while (y < 7) : (y += 1) {
            self.water_buf_x[x] = self.water_buf_x[x - 1];
            x -= 1;
        }
        x = x & 0xF8;
        self.water_buf_x[x] = saved;
    }

    /// TfrLavaGfx: lava only lives in the X buffer (VRAM $3800 path); write back to tiles 128–131.
    fn tfrLavaGfx(self: *Overworld) void {
        var t: usize = 0;
        while (t < water_buf_tiles) : (t += 1) {
            @memcpy(self.tiles[water_tile_x0 + t][0..], self.water_buf_x[t * 64 ..][0..64]);
        }
    }

    /// UpdateZoomPal (pal_anim.asm @c505).
    /// `zoom_level` is the A register at the call site (often `$b7` altitude 0..$10,
    /// not raw `$ad`). Table index = `zoom_level & $fe` (even byte into 9-word row).
    pub fn applyZoomPal(self: *Overworld, zoom_level: u8) void {
        @memcpy(&self.palette, &self.base_palette);
        // Clamp into table: 9 words → offsets 0,2,...,16.
        var zl = zoom_level;
        if (zl > 0x10) zl = 0x10;
        const xi: usize = zl & 0xFE;

        const set = struct {
            fn color(pal: *[64]snes.Color, idx: usize, snes_w: u16) void {
                if (idx >= 64) return;
                pal[idx] = snes.Color.fromSnes(snes_w);
                pal[idx].a = 255;
            }
        }.color;

        switch (self.world_id) {
            0 => {
                // OW: light ocean pal2 c5, dark ocean pal2 c7.
                set(&self.palette, 2 * 16 + 5, zoomPalWord(15, xi));
                set(&self.palette, 2 * 16 + 7, zoomPalWord(16, xi));
            },
            1 => {
                // Underground: rows 7–14 → specific CGRAM slots.
                set(&self.palette, 12, zoomPalWord(7, xi));
                set(&self.palette, 13, zoomPalWord(8, xi));
                set(&self.palette, 2 * 16 + 1, zoomPalWord(9, xi));
                set(&self.palette, 2 * 16 + 2, zoomPalWord(10, xi));
                set(&self.palette, 2 * 16 + 3, zoomPalWord(11, xi));
                set(&self.palette, 2, zoomPalWord(12, xi));
                set(&self.palette, 5, zoomPalWord(13, xi));
                set(&self.palette, 1, zoomPalWord(14, xi));
            },
            else => {
                // Moon: rows 0–6.
                set(&self.palette, 1, zoomPalWord(0, xi));
                set(&self.palette, 5, zoomPalWord(1, xi));
                set(&self.palette, 12, zoomPalWord(2, xi));
                set(&self.palette, 1 * 16 + 12, zoomPalWord(2, xi)); // $0d13 also row2
                set(&self.palette, 2, zoomPalWord(3, xi));
                set(&self.palette, 1 * 16 + 5, zoomPalWord(4, xi));
                set(&self.palette, 1 * 16 + 6, zoomPalWord(5, xi));
                set(&self.palette, 1 * 16 + 8, zoomPalWord(6, xi));
            },
        }
    }

    pub fn tileAt(self: *const Overworld, x: i32, y: i32) u8 {
        const ux: usize = @intCast(self.wrapCoord(x));
        const uy: usize = @intCast(self.wrapCoord(y));
        // Buffer is always 256×256; moon/under occupy [0..mask].
        return self.cells[uy * map_size + ux] & 0x7F;
    }

    pub fn propLoAt(self: *const Overworld, x: i32, y: i32) u8 {
        return self.prop_lo[self.tileAt(x, y)];
    }

    /// High property byte ($0EDC) — world map: `ebcagbbb` (RAM map).
    /// Low 3 bits = battle BG type index into WorldBattleBGTbl; bit6 = random battles.
    pub fn propHiAt(self: *const Overworld, x: i32, y: i32) u8 {
        return self.prop_hi[self.tileAt(x, y)];
    }

    /// DrawPlayerWorld (sprite.asm @b3a0): `$a2 & #$08` → clear OAM priority on lower
    /// half (legs behind forest canopy). Same bit as submap MapTileProp hi bit3.
    pub fn spriteHideLowerBody(self: *const Overworld, x: i32, y: i32) bool {
        return (self.propHiAt(x, y) & 0x08) != 0;
    }

    /// Foot passability — field/move.asm @ac56:
    ///   lda dest_prop
    ///   and #$41
    ///   and curr_prop&$41
    ///   beq blocked
    pub fn canWalk(self: *const Overworld, from_x: i32, from_y: i32, to_x: i32, to_y: i32) bool {
        const curr = self.propLoAt(from_x, from_y) & 0x41;
        const dest = self.propLoAt(to_x, to_y) & 0x41;
        return (dest & curr) != 0;
    }

    /// VehiclePassBit (move.asm @ad04) — dest prop_lo must share the vehicle bit.
    /// Index by `$1704` (1=choco … 6=whale). Ship `$07` reads MapSizeMask `$FF` in ROM.
    pub const vehicle_pass_bit = [_]u8{ 0x01, 0x02, 0x04, 0x10, 0x20, 0x20, 0x80, 0xFF };

    /// CheckPlayerMoveWorld vehicle path (@ac4b): `dest_lo & VehiclePassBit[veh]`.
    pub fn canVehiclePass(self: *const Overworld, to_x: i32, to_y: i32, vehicle: u8) bool {
        if (vehicle == 0 or vehicle > 7) return false;
        const bit = vehicle_pass_bit[vehicle];
        return (self.propLoAt(to_x, to_y) & bit) != 0;
    }

    /// Land chocobo / hover: prop_lo bit0 (LandChoco / LandHover `lda $a1 / and #$01`).
    pub fn canLandFoot(self: *const Overworld, x: i32, y: i32) bool {
        return vehicle_land.tileAllowsFootLand(self.propLoAt(x, y));
    }

    /// Land black chocobo: forest prop_lo bit3 (LandBkChoco @a124 `and #$08`).
    pub fn canLandBlackChoco(self: *const Overworld, x: i32, y: i32) bool {
        return vehicle_land.tileAllowsBlackChocoLand(self.propLoAt(x, y));
    }

    /// Land airship: prop_hi bit4 (LandEnterprise @a66a `lda $a2 / and #$10`).
    pub fn canLandAirship(self: *const Overworld, x: i32, y: i32) bool {
        return vehicle_land.tileAllowsAirshipLand(self.propHiAt(x, y));
    }

    pub fn render(
        self: *const Overworld,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
    ) void {
        self.renderZoomed(dest, dest_w, dest_h, cam_x, cam_y, fine_x, fine_y, 0x20, false, 0);
    }

    /// Mode-7 world render: InitZoomHDMA per-scanline scale + optional tunnel rot.
    /// Screen center `$70,$60` (player sprite); map sample via M7 diagonal (or full rot matrix).
    pub fn renderZoomed(
        self: *const Overworld,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
        mode7_ad: u8,
        whale: bool,
        tunnel_rot: u8,
    ) void {
        @memset(dest, 0);
        const level = zoomBankLevel(mode7_ad, whale);
        const use_rot = tunnel_rot != 0;

        // Foot / identity zoom: fast orthographic metatile path (scale $100 all lines).
        if (level == 0 and !use_rot) {
            self.renderOrtho(dest, dest_w, dest_h, cam_x, cam_y, fine_x, fine_y);
            return;
        }

        // Player world pixel = center of view (cam is pos−7 / pos−6).
        const player_wx: i32 = (cam_x + 7) * 16 + fine_x;
        const player_wy: i32 = (cam_y + 6) * 16 + fine_y;
        const cx: i32 = 0x70; // matches Draw* / CalcVehicleSpritePos center X
        const cy: i32 = 0x60; // 6*16 player foot line

        const tbl: []const u8 = if (whale) &whale_zoom_tbl else &airship_zoom_tbl;
        const earth_moon = @import("earth_moon.zig");
        const m7 = if (use_rot)
            earth_moon.calcMode7Rot(tunnel_rot, mode7_ad)
        else
            earth_moon.Mode7Matrix{ .a = 0x100, .b = 0, .c = 0, .d = 0x100 };

        var sy: i32 = 0;
        while (sy < @as(i32, @intCast(dest_h))) : (sy += 1) {
            // HDMA updates M7A/M7D each scanline from AirshipZoomTbl/WhaleZoomTbl × mult.
            const sl: usize = @intCast(@min(sy, @as(i32, @intCast(tbl.len - 1))));
            const line_scale: i32 = if (use_rot)
                0x100 // rotation matrix already carries zoom via $ad
            else
                @intCast(initZoomScaleWord(tbl[sl], level));

            var sx: i32 = 0;
            while (sx < @as(i32, @intCast(dest_w))) : (sx += 1) {
                const ox = sx - cx;
                const oy = sy - cy;
                const mx_off: i32 = if (use_rot)
                    @divTrunc(m7.a * ox + m7.b * oy, 0x100)
                else
                    @divTrunc(ox * line_scale, 0x100);
                const my_off: i32 = if (use_rot)
                    @divTrunc(m7.c * ox + m7.d * oy, 0x100)
                else
                    @divTrunc(oy * line_scale, 0x100);
                const world_x = player_wx + mx_off;
                const world_y = player_wy + my_off;
                const rgb = self.sampleWorldPixel(world_x, world_y);
                const o: usize = @intCast((sy * @as(i32, @intCast(dest_w)) + sx) * 4);
                if (o + 3 >= dest.len) continue;
                dest[o] = rgb[0];
                dest[o + 1] = rgb[1];
                dest[o + 2] = rgb[2];
                dest[o + 3] = 255;
            }
        }
    }

    /// Orthographic 16×16 metatiles (InitZoomHDMA mult level 0 / foot).
    fn renderOrtho(
        self: *const Overworld,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
    ) void {
        const tiles_x: i32 = @divTrunc(@as(i32, @intCast(dest_w)), 16) + 3;
        const tiles_y: i32 = @divTrunc(@as(i32, @intCast(dest_h)), 16) + 3;
        var ty: i32 = -1;
        while (ty < tiles_y) : (ty += 1) {
            var tx: i32 = -1;
            while (tx < tiles_x) : (tx += 1) {
                const mx = cam_x + tx;
                const my = cam_y + ty;
                const id = self.tileAt(mx, my);
                const dx = tx * 16 - fine_x;
                const dy = ty * 16 - fine_y;
                self.blitMetaScaled(dest, dest_w, dest_h, dx, dy, id, 16, 8);
            }
        }
    }

    /// Sample one Mode-7 world pixel → RGB.
    fn sampleWorldPixel(self: *const Overworld, world_x: i32, world_y: i32) [3]u8 {
        const mx = self.wrapCoord(world_x >> 4);
        const my = self.wrapCoord(world_y >> 4);
        const lx: i32 = world_x & 15;
        const ly: i32 = world_y & 15;
        const id = self.tileAt(mx, my);
        const gid: u8 = if (ly < 8)
            (if (lx < 8) self.meta_tl[id] else self.meta_tr[id])
        else
            (if (lx < 8) self.meta_bl[id] else self.meta_br[id]);
        const tx: usize = @intCast(lx & 7);
        const ty: usize = @intCast(ly & 7);
        const idx = self.tiles[gid][ty * 8 + tx];
        const c = self.palette[idx % 64];
        return .{ c.r, c.g, c.b };
    }

    fn blitMeta(
        self: *const Overworld,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        dx: i32,
        dy: i32,
        id: u8,
    ) void {
        self.blitMetaScaled(dest, dest_w, dest_h, dx, dy, id, @intCast(meta_px), 8);
    }

    fn blitMetaScaled(
        self: *const Overworld,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        dx: i32,
        dy: i32,
        id: u8,
        tile_px: i32,
        half_t: i32,
    ) void {
        _ = dest_h;
        const corners = [_]u8{ self.meta_tl[id], self.meta_tr[id], self.meta_bl[id], self.meta_br[id] };
        const corner_xy = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 },
            .{ .x = half_t, .y = 0 },
            .{ .x = 0, .y = half_t },
            .{ .x = half_t, .y = half_t },
        };
        if (tile_px == 16) {
            for (corners, corner_xy) |gid, off| {
                snes.blitTile(dest, dest_w, dx + off.x, dy + off.y, &self.tiles[gid], self.palette[0..], 0, false);
            }
            return;
        }
        // Nearest-neighbor scale of each 8×8 corner into half_t×half_t.
        for (corners, corner_xy) |gid, off| {
            blitTileScaled(dest, dest_w, dx + off.x, dy + off.y, &self.tiles[gid], self.palette[0..], half_t);
        }
    }
};

fn blitTileScaled(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    tile: *const [64]u8,
    palette: []const snes.Color,
    size: i32,
) void {
    if (size <= 0) return;
    var py: i32 = 0;
    while (py < size) : (py += 1) {
        var px: i32 = 0;
        while (px < size) : (px += 1) {
            const sx: usize = @intCast(@divTrunc(px * 8, size));
            const sy: usize = @intCast(@divTrunc(py * 8, size));
            const ci = tile[sy * 8 + sx];
            if (ci == 0 or ci >= palette.len) continue;
            const c = palette[ci];
            if (c.a == 0) continue;
            const x = dx + px;
            const y = dy + py;
            if (x < 0 or y < 0) continue;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (ux >= dest_w) continue;
            const o = (uy * dest_w + ux) * 4;
            if (o + 3 >= dest.len) continue;
            dest[o] = c.r;
            dest[o + 1] = c.g;
            dest[o + 2] = c.b;
            dest[o + 3] = 255;
        }
    }
}

/// DecodeOverworldTilemap + ModOverworldTilemap sequence specials (existing path).
fn decompressOverworld(r: *const rom_mod.Rom, out: []u8) !void {
    var row: usize = 0;
    while (row < map_size) : (row += 1) {
        const ptr = try r.readU16Le(ow_ptrs + row * 2);
        var x: usize = ptr;
        var col: usize = 0;
        while (col < map_size) {
            const b = try r.readU8(ow_data + x);
            if ((b & 0x80) != 0) {
                const tile = b & 0x7F;
                const count: usize = @as(usize, try r.readU8(ow_data + x + 1)) + 1;
                var n: usize = 0;
                while (n < count and col < map_size) : (n += 1) {
                    out[row * map_size + col] = tile;
                    col += 1;
                }
                x += 2;
            } else if (b == 0x00 or b == 0x10 or b == 0x20 or b == 0x30) {
                const s = b >> 3;
                const base: u8 = s + (s >> 1) + 0x70;
                const seq = [_]u8{ b, base, base +% 1, base +% 2 };
                for (seq) |t| {
                    if (col >= map_size) break;
                    out[row * map_size + col] = t;
                    col += 1;
                }
                x += 1;
            } else {
                out[row * map_size + col] = b;
                col += 1;
                x += 1;
            }
        }
    }
}

/// DecodeUndergroundTilemap / DecodeMoonTilemap — pure RLE (tilemap.asm @fe00).
/// `rows`/`cols` of logical map; written into 256×256 `out` at (0,0).
/// LavaPalTbl (pal_anim.asm @c4fd) — byte offsets into LavaAnimPal for `$7a>>4` phase.
pub const lava_pal_tbl = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x30, 0x20, 0x10, 0x00 };

/// LavaAnimPal (field_data.asm @fa16) — 4 rows × 8 SNES colors.
pub const lava_anim_pal = [_]u16{
    0x63FF, 0x4BFF, 0x2F9F, 0x2F3F, 0x265F, 0x150E, 0x0095, 0x0C0E,
    0x5BFF, 0x3F9F, 0x337F, 0x2AFF, 0x1A1E, 0x150E, 0x0074, 0x0C0E,
    0x53FF, 0x335F, 0x2B1F, 0x2ABF, 0x11BC, 0x150E, 0x0074, 0x080E,
    0x4BFF, 0x277F, 0x26FF, 0x267F, 0x095B, 0x150E, 0x0053, 0x080E,
};

/// UpdateLavaPal phase: `($7a & $70) >> 4` → LavaPalTbl row 0..7.
pub fn lavaPalPhase(snes_7a: u8) u8 {
    return (snes_7a & 0x70) >> 4;
}

/// First SNES word of LavaAnimPal for phase (byte off / 2).
pub fn lavaAnimPalBaseWord(snes_7a: u8) usize {
    const row: usize = @min(@as(usize, lavaPalPhase(snes_7a)), lava_pal_tbl.len - 1);
    return @as(usize, lava_pal_tbl[row]) / 2;
}

/// ZoomPalTbl (pal_anim.asm @c5a3) — 17 rows × 9 SNES words (zoom 0..$10 step 2).
/// Rows 0–6 moon, 7–14 under, 15–16 overworld light/dark ocean.
const zoom_pal_tbl = [_][9]u16{
    // moon
    .{ 0x3DEE, 0x3DEE, 0x3DED, 0x39CD, 0x39CC, 0x39CC, 0x35AB, 0x35AB, 0x35AB },
    .{ 0x56D4, 0x52B2, 0x4A71, 0x464F, 0x420E, 0x3DED, 0x39CC, 0x35AB, 0x35AB },
    .{ 0x35EF, 0x35EF, 0x31EF, 0x31CE, 0x2DCE, 0x2DCE, 0x29AD, 0x29AD, 0x29AD },
    .{ 0x35AB, 0x35AB, 0x318B, 0x318A, 0x2D6A, 0x2D6A, 0x2949, 0x2949, 0x2949 },
    .{ 0x333C, 0x333C, 0x331B, 0x2F1A, 0x2EFA, 0x2EF9, 0x2AD9, 0x2AD8, 0x2AD8 },
    .{ 0x2AD8, 0x2AB7, 0x2675, 0x2654, 0x2232, 0x2211, 0x1DD0, 0x1DAF, 0x1DAF },
    .{ 0x4F9E, 0x4B7C, 0x473A, 0x4319, 0x36D7, 0x3296, 0x2E55, 0x2A33, 0x2A33 },
    // underground
    .{ 0x24A6, 0x20A6, 0x1CA6, 0x1886, 0x1487, 0x0C87, 0x0867, 0x0067, 0x0067 },
    .{ 0x0067, 0x0067, 0x0047, 0x0046, 0x0026, 0x0026, 0x0005, 0x0005, 0x0005 },
    .{ 0x25D0, 0x25CF, 0x21AF, 0x1D8E, 0x1D8E, 0x196C, 0x156C, 0x114D, 0x114D },
    .{ 0x21AF, 0x1DAF, 0x1D8F, 0x198E, 0x196E, 0x156E, 0x154D, 0x114D, 0x114D },
    .{ 0x196E, 0x196E, 0x196E, 0x156E, 0x154D, 0x154D, 0x114D, 0x114D, 0x114D },
    .{ 0x155B, 0x115A, 0x1159, 0x0D58, 0x0937, 0x0936, 0x0535, 0x0135, 0x0135 },
    .{ 0x15DD, 0x11BA, 0x11B9, 0x0D98, 0x0977, 0x0976, 0x0555, 0x0135, 0x0135 },
    .{ 0x37DF, 0x2F7D, 0x2B1C, 0x22BA, 0x1A59, 0x11F7, 0x0976, 0x0135, 0x0135 },
    // overworld light / dark ocean
    .{ 0x6520, 0x5D20, 0x5900, 0x5500, 0x50E0, 0x4CE0, 0x48C0, 0x44C0, 0x3CA0 },
    .{ 0x2460, 0x2860, 0x2C60, 0x3080, 0x3480, 0x3880, 0x3CA0, 0x3CA0, 0x3CA0 },
};

fn zoomPalWord(row: usize, byte_index: usize) u16 {
    // byte_index is even 0..16 → word index 0..8
    const wi: usize = @min(byte_index / 2, 8);
    return zoom_pal_tbl[row][wi];
}

/// AirshipZoomTbl (field_data.asm @f3ce) — 224 scanline M7A seeds (InitZoomHDMA).
pub const airship_zoom_tbl = [_]u8{
    0x80, 0x7F, 0x7E, 0x7E, 0x7D, 0x7C, 0x7C, 0x7B, 0x7A, 0x7A, 0x79, 0x78, 0x78, 0x77, 0x76, 0x76,
    0x75, 0x75, 0x74, 0x73, 0x73, 0x72, 0x71, 0x71, 0x70, 0x70, 0x6F, 0x6E, 0x6E, 0x6D, 0x6D, 0x6C,
    0x6B, 0x6B, 0x6A, 0x6A, 0x69, 0x69, 0x68, 0x67, 0x67, 0x66, 0x66, 0x65, 0x65, 0x64, 0x64, 0x63,
    0x63, 0x62, 0x61, 0x61, 0x60, 0x60, 0x5F, 0x5F, 0x5E, 0x5E, 0x5D, 0x5D, 0x5C, 0x5C, 0x5B, 0x5B,
    0x5A, 0x5A, 0x59, 0x59, 0x58, 0x58, 0x57, 0x57, 0x56, 0x56, 0x55, 0x55, 0x54, 0x54, 0x53, 0x53,
    0x52, 0x52, 0x52, 0x51, 0x51, 0x50, 0x50, 0x4F, 0x4F, 0x4E, 0x4E, 0x4D, 0x4D, 0x4D, 0x4C, 0x4C,
    0x4B, 0x4B, 0x4A, 0x4A, 0x4A, 0x49, 0x49, 0x48, 0x48, 0x47, 0x47, 0x47, 0x46, 0x46, 0x45, 0x45,
    0x45, 0x44, 0x44, 0x43, 0x43, 0x42, 0x42, 0x42, 0x41, 0x41, 0x41, 0x40, 0x40, 0x3F, 0x3F, 0x3F,
    0x3E, 0x3E, 0x3D, 0x3D, 0x3D, 0x3C, 0x3C, 0x3C, 0x3B, 0x3B, 0x3A, 0x3A, 0x3A, 0x39, 0x39, 0x39,
    0x38, 0x38, 0x38, 0x37, 0x37, 0x37, 0x36, 0x36, 0x35, 0x35, 0x35, 0x34, 0x34, 0x34, 0x33, 0x33,
    0x33, 0x32, 0x32, 0x32, 0x31, 0x31, 0x31, 0x30, 0x30, 0x30, 0x2F, 0x2F, 0x2F, 0x2E, 0x2E, 0x2E,
    0x2E, 0x2D, 0x2D, 0x2D, 0x2C, 0x2C, 0x2C, 0x2B, 0x2B, 0x2B, 0x2A, 0x2A, 0x2A, 0x29, 0x29, 0x29,
    0x29, 0x28, 0x28, 0x28, 0x27, 0x27, 0x27, 0x26, 0x26, 0x26, 0x26, 0x25, 0x25, 0x25, 0x24, 0x24,
    0x24, 0x24, 0x23, 0x23, 0x23, 0x22, 0x22, 0x22, 0x22, 0x21, 0x21, 0x21, 0x21, 0x20, 0x20, 0x20,
};

/// WhaleZoomTbl (field_data.asm @f4ae) — 224 scanline M7A seeds (InitZoomHDMA whale).
pub const whale_zoom_tbl = [_]u8{
    0xC0, 0xBF, 0xBE, 0xBD, 0xBC, 0xBB, 0xBA, 0xB9, 0xB8, 0xB7, 0xB6, 0xB6, 0xB5, 0xB4, 0xB3, 0xB2,
    0xB1, 0xB0, 0xAF, 0xAF, 0xAE, 0xAD, 0xAC, 0xAB, 0xAA, 0xAA, 0xA9, 0xA8, 0xA7, 0xA6, 0xA5, 0xA5,
    0xA4, 0xA3, 0xA2, 0xA1, 0xA1, 0xA0, 0x9F, 0x9E, 0x9E, 0x9D, 0x9C, 0x9B, 0x9B, 0x9A, 0x99, 0x98,
    0x98, 0x97, 0x96, 0x95, 0x95, 0x94, 0x93, 0x93, 0x92, 0x91, 0x90, 0x90, 0x8F, 0x8E, 0x8E, 0x8D,
    0x8C, 0x8C, 0x8B, 0x8A, 0x8A, 0x89, 0x88, 0x88, 0x87, 0x86, 0x86, 0x85, 0x85, 0x84, 0x83, 0x83,
    0x82, 0x81, 0x81, 0x80, 0x80, 0x7F, 0x7E, 0x7E, 0x7D, 0x7D, 0x7C, 0x7B, 0x7B, 0x7A, 0x7A, 0x79,
    0x78, 0x78, 0x77, 0x77, 0x76, 0x76, 0x75, 0x74, 0x74, 0x73, 0x73, 0x72, 0x72, 0x71, 0x71, 0x70,
    0x70, 0x6F, 0x6E, 0x6E, 0x6D, 0x6D, 0x6C, 0x6C, 0x6B, 0x6B, 0x6A, 0x6A, 0x69, 0x69, 0x68, 0x68,
    0x67, 0x67, 0x66, 0x66, 0x65, 0x65, 0x64, 0x64, 0x63, 0x63, 0x62, 0x62, 0x61, 0x61, 0x60, 0x60,
    0x5F, 0x5F, 0x5F, 0x5E, 0x5E, 0x5D, 0x5D, 0x5C, 0x5C, 0x5B, 0x5B, 0x5A, 0x5A, 0x5A, 0x59, 0x59,
    0x58, 0x58, 0x57, 0x57, 0x56, 0x56, 0x56, 0x55, 0x55, 0x54, 0x54, 0x53, 0x53, 0x53, 0x52, 0x52,
    0x51, 0x51, 0x51, 0x50, 0x50, 0x4F, 0x4F, 0x4F, 0x4E, 0x4E, 0x4D, 0x4D, 0x4D, 0x4C, 0x4C, 0x4B,
    0x4B, 0x4B, 0x4A, 0x4A, 0x49, 0x49, 0x49, 0x48, 0x48, 0x48, 0x47, 0x47, 0x46, 0x46, 0x46, 0x45,
    0x45, 0x45, 0x44, 0x44, 0x44, 0x43, 0x43, 0x42, 0x42, 0x42, 0x41, 0x41, 0x41, 0x40, 0x40, 0x40,
};

/// InitZoomHDMA zoom bank index 0..16 from `$ad` (UpdateZoomHDMA @c16b / @c1a8).
pub fn zoomBankLevel(mode7_ad: u8, whale: bool) u8 {
    if (whale) {
        // bank_hi = (($ad-$10)&$fe)+$22; whale base $22 → level = (bank_hi-$22)/2
        const t: u16 = (@as(u16, mode7_ad) -% 0x10) & 0xfe;
        const bank_hi: u16 = t + 0x22;
        if (bank_hi < 0x22) return 0;
        return @intCast(@min((bank_hi - 0x22) / 2, 16));
    }
    // bank_hi = ($ad-$10)*2 → level = $ad-$10
    if (mode7_ad < 0x10) return 0;
    return @intCast(@min(mode7_ad - 0x10, 16));
}

/// One InitZoomHDMA word: `(MPYM<<3)+$100` or final `(seed<<2)+$100`.
/// Mult levels 0..15 use `$40 = level*8`; level 16 is the max `*4` bank.
pub fn initZoomScaleWord(seed: u8, level: u8) u16 {
    if (level >= 16) {
        return @as(u16, seed) * 4 + 0x100;
    }
    const mult: u32 = @as(u32, level) * 8;
    const prod: u32 = @as(u32, seed) * mult;
    const mpym: u32 = prod >> 8;
    return @truncate((mpym << 3) + 0x100);
}

/// Mid-screen (scanline 112) Mode-7 diagonal scale for current `$ad`.
pub fn mode7CenterScale(mode7_ad: u8, whale: bool) u16 {
    const level = zoomBankLevel(mode7_ad, whale);
    const tbl: []const u8 = if (whale) &whale_zoom_tbl else &airship_zoom_tbl;
    const sl: usize = @min(112, tbl.len - 1);
    return initZoomScaleWord(tbl[sl], level);
}

/// Screen pixels per world metatile from InitZoomHDMA center scale.
/// Mode-7: map_delta = screen_delta * scale / 256 → tile_px = 16 * 256 / scale.
pub fn mode7TilePx(mode7_ad: u8, whale: bool) i32 {
    const scale = mode7CenterScale(mode7_ad, whale);
    if (scale == 0) return @intCast(meta_px);
    return @max(4, @divTrunc(@as(i32, @intCast(meta_px)) * 0x100, @as(i32, scale)));
}

fn decompressSimple(
    r: *const rom_mod.Rom,
    ptrs_off: usize,
    data_off: usize,
    rows: usize,
    cols: usize,
    out: []u8,
) !void {
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const rel = try r.readU16Le(ptrs_off + row * 2);
        var x: usize = rel;
        var col: usize = 0;
        while (col < cols) {
            const b = try r.readU8(data_off + x);
            if ((b & 0x80) != 0) {
                const tile = b & 0x7F;
                const count: usize = @as(usize, try r.readU8(data_off + x + 1)) + 1;
                var n: usize = 0;
                while (n < count and col < cols) : (n += 1) {
                    out[row * map_size + col] = tile;
                    col += 1;
                }
                x += 2;
            } else {
                out[row * map_size + col] = b;
                col += 1;
                x += 1;
            }
        }
    }
}

test "zoomBankLevel foot $10 is orthographic level 0" {
    // InitMapRAM `$ad=$10` → level 0 → renderZoomed uses ortho path.
    try std.testing.expectEqual(@as(u8, 0), zoomBankLevel(0x10, false));
    try std.testing.expectEqual(@as(u8, 0), zoomBankLevel(0x0F, false));
    // Airship cruise `$ad=$20` → level $10.
    try std.testing.expectEqual(@as(u8, 0x10), zoomBankLevel(0x20, false));
}

test "DrawPlayerWorld forest occlusion prop hi bit3" {
    // sprite.asm @b3a0: `lda $a2 / and #$08` → hide lower OAM half.
    const gpa = std.testing.allocator;
    const cells = try gpa.alloc(u8, map_size * map_size);
    defer gpa.free(cells);
    @memset(cells, 0);
    var ow: Overworld = .{
        .cells = cells,
        .size_mask = 0xFF,
        .world_id = 0,
        .allocator = gpa,
    };
    // Synthetic: tile id 9 at (0,0) with forest hi bit (ROM forest samples hi=$49).
    ow.cells[0] = 0x09;
    ow.prop_hi[0x09] = 0x49; // bit3 set
    ow.prop_lo[0x09] = 0xA4;
    try std.testing.expect(ow.spriteHideLowerBody(0, 0));
    ow.prop_hi[0x09] = 0x41; // bit3 clear
    try std.testing.expect(!ow.spriteHideLowerBody(0, 0));
    ow.cells[0] = 0x00;
    ow.prop_hi[0x00] = 0x00;
    try std.testing.expect(!ow.spriteHideLowerBody(0, 0));
}

test "UpdateLavaPal phase and LavaPalTbl" {
    // `$7a&$70>>4`: 0x00→0, 0x10→1, 0x70→7
    try std.testing.expectEqual(@as(u8, 0), lavaPalPhase(0x00));
    try std.testing.expectEqual(@as(u8, 1), lavaPalPhase(0x10));
    try std.testing.expectEqual(@as(u8, 3), lavaPalPhase(0x30));
    try std.testing.expectEqual(@as(u8, 7), lavaPalPhase(0x70));
    // Symmetric bounce: phase 0 and 7 both byte 0 → word 0
    try std.testing.expectEqual(@as(usize, 0), lavaAnimPalBaseWord(0x00));
    try std.testing.expectEqual(@as(usize, 0), lavaAnimPalBaseWord(0x70));
    try std.testing.expectEqual(@as(usize, 0x18), lavaAnimPalBaseWord(0x30)); // $30 bytes → word 24
    try std.testing.expectEqual(@as(u16, 0x63FF), lava_anim_pal[0]);
    try std.testing.expectEqual(@as(u16, 0x4BFF), lava_anim_pal[24]); // row3 first color
}

test "InitZoomHDMA AirshipZoomTbl length and scale word" {
    try std.testing.expectEqual(@as(usize, 224), airship_zoom_tbl.len);
    try std.testing.expectEqual(@as(usize, 224), whale_zoom_tbl.len);
    const s0 = airship_zoom_tbl[112]; // mid scanline seed
    // Level 0: mult 0 → MPYM 0 → $100 (foot ortho bank)
    try std.testing.expectEqual(@as(u16, 0x100), initZoomScaleWord(s0, 0));
    // Level 16: seed*4 + $100
    try std.testing.expectEqual(@as(u16, @as(u16, s0) * 4 + 0x100), initZoomScaleWord(s0, 16));
    // Mid level finite nonzero
    try std.testing.expect(initZoomScaleWord(s0, 8) >= 0x100);
}
