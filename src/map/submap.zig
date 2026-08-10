//! Sub-map load/render/collision (everything8215/ff4 field module).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("../gfx/snes.zig");

/// TowerAnimBlueLight / Red / Yellow (field_data.asm @f7d6) — 8 words each.
const tower_anim_blue_light = [_]u16{ 0x76C0, 0x5A00, 0x3D60, 0x1CA0, 0x1CA0, 0x3D60, 0x5A00, 0x76C0 };
const tower_anim_red_light = [_]u16{ 0x0007, 0x0007, 0x000D, 0x0014, 0x001B, 0x001B, 0x0014, 0x000D };
const tower_anim_yellow_light = [_]u16{ 0x018F, 0x0256, 0x033D, 0x033D, 0x0256, 0x018F, 0x00C7, 0x00C7 };
/// TowerAnimBluePal (@f826) — 16 words, circular flash.
const tower_anim_blue_pal = [_]u16{
    0x7FFF, 0x7B91, 0x76C0, 0x6620, 0x5940, 0x44A0, 0x2800, 0x0000,
    0x0000, 0x2800, 0x44A0, 0x5940, 0x6620, 0x76C0, 0x7B91, 0x7FFF,
};
/// MonsterCaveAnimPal (field_data.asm @fbc6) — 4 rows × 8 words.
const monster_cave_anim_pal = [_]u16{
    0x00D0, 0x00AE, 0x008C, 0x006A, 0x0048, 0x006A, 0x008C, 0x00AE,
    0x004C, 0x004A, 0x0048, 0x0026, 0x0024, 0x0026, 0x0028, 0x004A,
    0x000A, 0x0008, 0x0006, 0x0004, 0x0002, 0x0004, 0x0006, 0x0008,
    0x0154, 0x0132, 0x0110, 0x00EE, 0x00CC, 0x00EE, 0x0110, 0x0132,
};
/// SylvanCaveAnimPal (field_data.asm @fc06) — when `$0fe0` (map pal id) == $0F.
const sylvan_cave_anim_pal = [_]u16{
    0x26A0, 0x2280, 0x1E40, 0x2200, 0x15C0, 0x1A00, 0x1E40, 0x2280,
    0x19C0, 0x1580, 0x1140, 0x0D00, 0x08C0, 0x0D00, 0x1140, 0x1580,
    0x0CE0, 0x0CC0, 0x08A0, 0x0880, 0x0460, 0x0480, 0x08A0, 0x08C0,
    0x26A0, 0x2280, 0x1E40, 0x2200, 0x15C0, 0x1A00, 0x1E40, 0x2280,
};

pub const map_w: usize = 32;
pub const map_h: usize = 32;
pub const meta_px: usize = 16;

/// Camera top-left in metatiles relative to player (UpdateScrollSub / host center).
/// Submap scroll fetches edges at player±8/±9; player sits at screen (7, 6) in 16×14 view
/// (256×224 / 16). Matches field `$1706`/`$1707` → BG1 scroll stand-in.
pub const camera_ox_sub: i32 = 7;
pub const camera_oy_sub: i32 = 6;
/// World map uses a larger window (UpdateScrollWorld ±$1f).
pub const camera_ox_world: i32 = 7;
pub const camera_oy_world: i32 = 6;

/// Pure camera top-left tile from player position (door/stairs/shop entrances share this).
pub fn cameraTopLeft(player_x: i32, player_y: i32, on_submap: bool) struct { x: i32, y: i32 } {
    if (on_submap) {
        return .{ .x = player_x - camera_ox_sub, .y = player_y - camera_oy_sub };
    }
    return .{ .x = player_x - camera_ox_world, .y = player_y - camera_oy_world };
}

/// UpdateScrollSub horizontal edge column when stepping (move.asm / tilemap.asm @f76b).
/// Right step: `player_x + 9`; left: `player_x - 8`.
pub fn scrollEdgeX(player_x: i32, moving_right: bool) i32 {
    return if (moving_right) player_x + 9 else player_x - 8;
}

/// UpdateScrollSub vertical base: `player_y - 7` (tilemap.asm @f784).
pub fn scrollEdgeYBase(player_y: i32) i32 {
    return player_y - 7;
}

/// UpdateAnimPal light-cycle index: `($7a >> 2) & $0e` then word = /2 (pal_anim.asm @c42d).
pub fn animPalLightIndex(snes_7a: u8) usize {
    return ((snes_7a >> 2) & 0x0E) / 2;
}

/// TowerAnimBluePal rotation start: `($7a >> 1) & $1e` then /2 (word) @c477.
pub fn animPalBlueRotIndex(snes_7a: u8) usize {
    return ((snes_7a >> 1) & 0x1E) / 2;
}

/// True if tileset runs UpdateAnimPal tower/whale path (8 or $0a..$0b).
pub fn tilesetUsesTowerAnim(tileset: u8) bool {
    return tileset == 8 or tileset == 0x0A or tileset == 0x0B;
}

/// True if tileset is underground cave (MonsterCave / Sylvan).
pub fn tilesetUsesCaveAnim(tileset: u8) bool {
    return tileset == 9;
}

const map_prop_base: usize = 0xA9C84;
const map_prop_stride: usize = 13;
const map_prop_count: usize = 383;
const map_tile_prop_base: usize = 0xA0E00;
const map_tileset_base: usize = 0xA1E00;
const map_pal_base: usize = 0xA5E00;
const sub_tilemap_ptrs: usize = 0xB8000;
const map_gfx_ptrs: usize = 0xF0000;
/// MapAnimGfx @ $1FB9C0 — torch/water etc. frames (LoadBGAnimGfx / TfrBGAnimGfx).
const map_anim_gfx: usize = 0xFB9C0;
/// Per-tileset offset selectors (BGAnimTbl); see bg_anim.asm.
const bg_anim_tbl = [_]u8{ 0x00, 0x00, 0x00, 0x02, 0x03, 0x06, 0x07, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0D, 0x0D, 0x0D, 0x10 };
/// Animated tiles replace static MapGfx tiles starting here (VRAM $1200 → tile 288).
const anim_tile_base: usize = 288;
const anim_tiles_per_frame: usize = 16;
const anim_frame_count: usize = 4;

/// Bank for each MapGfx_* (from ff4-en.lnk segments).
const map_gfx_bank = [_]u8{
    0x15, // 0 ship
    0x1E, // 1 lunar
    0x1E, // 2 sealed cave
    0x1D, // 3 castle exterior
    0x1E, // 4 town exterior
    0x1E, // 5 town interior
    0x1E, // 6 castle interior
    0x1E, // 7 crystal
    0x1F, // 8 tower
    0x1F, // 9 underground cave
    0x1F, // A tower
    0x1F, // B giant
    0x1E, // C lunar
    0x1F, // D mountains
    0x1F, // E overworld cave
    0x15, // F ship
};

pub const MapProp = struct {
    flags: u8,
    bg1_form: u8,
    tileset: u8,
    npc_index: u8,
    fill_flags: u8,
    palette: u8,
    npc_pal: u8,
    song: u8,
    bg2_form: u8,
    scroll_flags: u8,
    tilemap_msb: u8,
    unused: u8,
    treasure_off: u8,
};

/// SNES BG tilemap word: `vhopppcc cccccccc`
///   tile 9:0, pal 12:10, priority 13, hflip 14, vflip 15
const MetaWord = struct {
    tile: u16,
    pal: u3,
    /// Bit 13 — high priority draws above sprites (walls, bed tops, arches).
    priority: bool,
    hflip: bool,
    vflip: bool,

    fn parse(w: u16) MetaWord {
        return .{
            .tile = w & 0x3FF,
            .pal = @truncate(w >> 10),
            .priority = (w & 0x2000) != 0,
            .hflip = (w & 0x4000) != 0,
            .vflip = (w & 0x8000) != 0,
        };
    }
};

/// OpenDoor (move.asm @aa40 / GetDoorTiles @ab60): map cell stays $70/$71 so
/// triggers/exit bits still work; graphics are metatile $6F (offset $DE in tileset).
pub const open_door_metatile: u8 = 0x6F;
pub const closed_door_a: u8 = 0x70;
pub const closed_door_b: u8 = 0x71;

pub const SubMap = struct {
    prop: MapProp = undefined,
    map_id: u16 = 0,
    /// BG1 metatile ids (32×32).
    cells: [map_w * map_h]u8 = .{0} ** (map_w * map_h),
    /// BG2 metatile ids (32×32) — drawn under BG1; BG1 pixel index 0 is transparent.
    cells_bg2: [map_w * map_h]u8 = .{0} ** (map_w * map_h),
    /// 128 metatiles × 4 corners as SNES tilemap words.
    meta: [128][4]MetaWord = undefined,
    prop_lo: [128]u8 = undefined,
    prop_hi: [128]u8 = undefined,
    tiles: [][64]u8 = &.{},
    tile_count: usize = 0,
    /// 8 SNES palettes × 16 colors (CGRAM layout). 3bpp uses indices 0–7; ship 4bpp uses 0–15.
    palette: [128]snes.Color = undefined,
    /// Snapshot after LoadMapPal — UpdateAnimPal rewrites slots each frame from this.
    base_palette: [128]snes.Color = undefined,
    /// Ship/airship tilesets 0 and $0F are 4bpp (LoadBGGfx @b091); others 3bpp.
    bpp4: bool = false,
    /// All 64 MapAnimGfx tiles for this tileset (3bpp decoded).
    /// Layout is interleaved — see applyAnimFrame / TfrBGAnimGfx.
    anim_src: [anim_frame_count * anim_tiles_per_frame][64]u8 = undefined,
    has_anim: bool = false,
    anim_frame: u8 = 0,
    /// $66 — BG2 horizontal scroll offset from BG1 (UpdateBG2Scroll continuous path).
    bg2_off_x: i16 = 0,
    /// $68 — BG2 vertical scroll offset from BG1.
    bg2_off_y: i16 = 0,
    /// $c9 — when nonzero, BG2 is stationary (no UpdateBG2Scroll). Cleared on load.
    bg2_stationary: bool = false,
    /// OpenDoor: which BG1 cells show metatile $6F gfx while cell id stays $70/$71.
    /// Bit i of `opened_doors[y]` = column x opened (GetDoorTiles VRAM patch equivalent).
    opened_doors: [map_h]u32 = .{0} ** map_h,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SubMap) void {
        if (self.tiles.len != 0) self.allocator.free(self.tiles);
        self.* = undefined;
    }

    pub fn load(gpa: std.mem.Allocator, r: *const rom_mod.Rom, map_id: u16) !SubMap {
        var sm: SubMap = .{ .allocator = gpa, .map_id = map_id };
        if (map_id >= map_prop_count) return error.BadMapId;

        const pr = try r.slice(map_prop_base + map_id * map_prop_stride, map_prop_stride);
        sm.prop = .{
            .flags = pr[0],
            .bg1_form = pr[1],
            .tileset = pr[2] & 0x0F,
            .npc_index = pr[3],
            .fill_flags = pr[4],
            .palette = pr[5],
            .npc_pal = pr[6],
            .song = pr[7],
            .bg2_form = pr[8],
            .scroll_flags = pr[9],
            .tilemap_msb = pr[10],
            .unused = pr[11],
            .treasure_off = pr[12],
        };

        try decodeTilemap(r, sm.prop.bg1_form, &sm.cells);
        try decodeTilemap(r, sm.prop.bg2_form, &sm.cells_bg2);

        // MapTileset: 4 × 256-byte banks of 128 SNES tilemap words (TL, TR, BL, BR).
        // File order is linear TL→TR→BL→BR (each bank 0x100 bytes / 128 words).
        // Verified against vanilla airship deck (map $C0): this order yields correct
        // wood grain, railings, grates, and whole BG2 clouds; swapping TR/BL banks
        // chops clouds and shears the deck (common mistake reading $7f4900/$7f4a00).
        const ts = try r.slice(map_tileset_base + @as(usize, sm.prop.tileset) * 1024, 1024);
        var i: usize = 0;
        while (i < 128) : (i += 1) {
            const o = i * 2;
            sm.meta[i][0] = MetaWord.parse(std.mem.readInt(u16, ts[0x000 + o ..][0..2], .little)); // TL
            sm.meta[i][1] = MetaWord.parse(std.mem.readInt(u16, ts[0x100 + o ..][0..2], .little)); // TR
            sm.meta[i][2] = MetaWord.parse(std.mem.readInt(u16, ts[0x200 + o ..][0..2], .little)); // BL
            sm.meta[i][3] = MetaWord.parse(std.mem.readInt(u16, ts[0x300 + o ..][0..2], .little)); // BR
        }

        const tp = try r.slice(map_tile_prop_base + @as(usize, sm.prop.tileset) * 256, 256);
        i = 0;
        while (i < 128) : (i += 1) {
            sm.prop_lo[i] = tp[i * 2];
            sm.prop_hi[i] = tp[i * 2 + 1];
        }

        loadMapPal(r, sm.prop.palette, &sm.palette);
        @memcpy(&sm.base_palette, &sm.palette);
        // field/bg_gfx.asm LoadBGGfx: tileset 0 and $0F (ship/airship) are 4bpp.
        sm.bpp4 = (sm.prop.tileset == 0 or sm.prop.tileset == 0x0F);
        sm.tiles = try loadMapGfx(gpa, r, sm.prop.tileset, sm.bpp4);
        sm.tile_count = sm.tiles.len;
        // Anim gfx is 3bpp bank; skip for pure 4bpp ship sets (no BGAnimTbl entry useful).
        sm.has_anim = if (sm.bpp4) false else loadBgAnimSrc(r, sm.prop.tileset, &sm.anim_src);
        if (sm.has_anim) sm.applyAnimFrame(0);
        // InitMapRAM: stz $66/$68; stz $c9
        sm.bg2_off_x = 0;
        sm.bg2_off_y = 0;
        sm.bg2_stationary = false;
        return sm;
    }

    /// UpdateAnimPal (pal_anim.asm @c41a) — tower/zot/babil/giant/cave color cycles.
    /// `$0fdd` = tileset: 8, $0a–$0b tower/whale/giant; 9 = underground cave.
    ///
    /// CGRAM mirror base `$0cdb` (color 0). Word offsets → palette color indices:
    ///   $0cfd → 17, $0cff → 18, $0d01 → 19, $0d1d → 33, $0d5d → 65,
    ///   $0d7d → 62, $0d7f → 63, $0dbd → 89 (verified vs decomp writes).
    pub fn applyAnimPal(self: *SubMap, snes_7a: u8) void {
        @memcpy(&self.palette, &self.base_palette);
        const ts = self.prop.tileset;
        const set = struct {
            fn c(pal: *[128]snes.Color, idx: usize, w: u16) void {
                if (idx >= pal.len) return;
                pal[idx] = snes.Color.fromSnes(w);
                pal[idx].a = 255;
            }
        }.c;

        if (tilesetUsesCaveAnim(ts)) {
            // Underground cave: MonsterCaveAnimPal; Sylvan when map pal id `$0fe0`==$0F
            // (decomp adds $40 to X into the same bank as MonsterCave + Sylvan).
            const base = animPalLightIndex(snes_7a);
            const cave: []const u16 = if (self.prop.palette == 0x0F)
                &sylvan_cave_anim_pal
            else
                &monster_cave_anim_pal;
            if (base < 8 and cave.len >= 32) {
                // ROM: $0cfd, $0cff+$0d7f, $0d01, $0d7d
                set(&self.palette, 17, cave[base]);
                set(&self.palette, 18, cave[8 + base]);
                set(&self.palette, 63, cave[8 + base]);
                set(&self.palette, 19, cave[16 + base]);
                set(&self.palette, 62, cave[24 + base]);
            }
            return;
        }
        // big whale / tower of zot/babil / giant: tileset 8 or $0a..$0b only
        // (pal_anim.asm @c41a: cmp #$0a bcc ret; cmp #$0c bcs ret — excludes $0c+).
        if (!tilesetUsesTowerAnim(ts)) return;

        const wi = animPalLightIndex(snes_7a);
        if (wi < 8) {
            // $0cfd, $0d1d, $0d5d → colors 17, 33, 65
            set(&self.palette, 17, tower_anim_blue_light[wi]);
            set(&self.palette, 33, tower_anim_red_light[wi]);
            set(&self.palette, 65, tower_anim_yellow_light[wi]);
        }
        // Giant of Babil (tileset $0b): skip TowerNoEffectTbl; still do blue pal shift.
        const bi = animPalBlueRotIndex(snes_7a);
        var y: usize = 0;
        while (y < 8) : (y += 1) {
            const src = (bi + y) % 16;
            // $0dbd = color 89; write 8 colors of flashing blue
            set(&self.palette, 89 + y, tower_anim_blue_pal[src]);
        }
    }

    /// UpdateBG2Scroll (tilemap.asm @f533) — exact port of continuous + parallax paths.
    /// `$0fe4` = `prop.scroll_flags` (ssdd-hva). Only runs on sub-maps (`$1700==3`).
    ///
    /// Continuous (h/v clear): advances `$66`/`$68` by Horz/VertMoveRateTbl[d] when
    /// `($7a & BG2ScrollRateTbl[s]) == 0`, then BG2 scroll = BG1 + offset.
    /// Parallax (h and/or v set): scales BG1 scroll into BG2 (½ / 1× / 2×).
    pub fn tickBg2Scroll(self: *SubMap, snes_7a: u8) void {
        if (self.bg2_stationary) return;
        const fe4 = self.prop.scroll_flags;
        // Must have continuous-or-parallax speed bits in high nibble of s, or h/v.
        if ((fe4 & 0xC0) == 0) return;

        // Continuous vs parallax: branch on bits h|v ($06).
        if ((fe4 & 0x06) == 0) {
            // Continuous scroll
            // BG2ScrollRateTbl: $00,$07,$01,$00 indexed by s (bits 6–7)
            const rate_tbl = [_]u8{ 0x00, 0x07, 0x01, 0x00 };
            const s: usize = (fe4 >> 6) & 3;
            if ((snes_7a & rate_tbl[s]) == 0) {
                // HorzMoveRateTbl / VertMoveRateTbl indexed by d (bits 4–5) * 2 as word index
                // d: 0=up, 1=right, 2=down, 3=left
                const d: usize = (fe4 >> 4) & 3;
                const horz = [_]i16{ 0, -1, 0, 1 };
                const vert = [_]i16{ 1, 0, -1, 0 };
                self.bg2_off_x +%= horz[d];
                self.bg2_off_y +%= vert[d];
            }
            // BG2 position = BG1 + offset is applied at render time.
            return;
        }

        // Parallax path: $66/$68 unused; render applies scale of BG1 fine scroll
        // (bg2FineDelta). No per-frame offset accumulate.
    }

    /// Compute BG2 pixel scroll relative to BG1 fine (for render).
    /// Returns additional fine offset for BG2 (to be combined with cam/fine).
    pub fn bg2FineDelta(self: *const SubMap, fine_x: i32, fine_y: i32) struct { x: i32, y: i32 } {
        if (self.bg2_stationary) return .{ .x = 0, .y = 0 };
        const fe4 = self.prop.scroll_flags;
        if ((fe4 & 0xC0) == 0) return .{ .x = 0, .y = 0 };

        if ((fe4 & 0x06) == 0) {
            // Continuous: BG2 = BG1 + ($66,$68)
            return .{ .x = self.bg2_off_x, .y = self.bg2_off_y };
        }

        // Parallax (tilemap.asm @f593)
        var dx: i32 = 0;
        var dy: i32 = 0;
        const s = fe4 & 0xC0;
        if ((fe4 & 0x04) != 0) {
            // H parallax from BG1 H ($5a → $5e)
            dx = fine_x;
            if (s == 0xC0) {
                dx = fine_x * 2; // twice bg1
            } else if (s == 0x40) {
                dx = fine_x >> 1; // half bg1 (signed)
            }
            // s==$80: same as bg1 (dx already fine_x)
            // If only H (bits==$04), V is zeroed
            if ((fe4 & 0x06) == 0x04) {
                return .{ .x = dx - fine_x, .y = -fine_y }; // cancel BG1 V for pure-H
            }
        }
        if ((fe4 & 0x02) != 0) {
            dy = fine_y;
            if (s == 0xC0) {
                dy = fine_y * 2;
            } else if (s == 0x40) {
                dy = fine_y >> 1;
            }
            if ((fe4 & 0x06) == 0x02) {
                return .{ .x = -fine_x, .y = dy - fine_y };
            }
        }
        // Both H and V: BG2 scroll is absolute (scaled BG1), so delta from BG1 is (scaled - bg1)
        return .{ .x = dx - fine_x, .y = dy - fine_y };
    }

    /// Advance torch/water animation from the emulated SNES field counter `$7a`.
    ///
    /// Exact behavior from everything8215/ff4:
    /// - field.asm NMI: `inc $7a` once per NTSC field
    /// - NMI sub-map path only calls TfrBGAnimGfx on even `$7a` (`lsr` / `bcc`)
    /// - TfrBGAnimGfx returns unless `($7a & $06) == 0`
    /// - Combined: DMA only when `($7a & $07) == 0` (every 8 fields)
    /// - Frame select: `($7a & $18) >> 3` → 0..3
    /// So each of 4 flame frames is held for 8 NTSC fields (~8/60.1 s); full cycle ~32/60.1 s.
    pub fn tickAnim(self: *SubMap, snes_7a: u8) void {
        if (!self.has_anim) return;
        // Only the fields where the ROM actually uploads new anim tiles.
        if ((snes_7a & 7) != 0) return;
        const frame: u8 = (snes_7a & 0x18) >> 3;
        if (frame == self.anim_frame) return;
        self.applyAnimFrame(frame);
    }

    fn applyAnimFrame(self: *SubMap, frame: u8) void {
        self.anim_frame = frame;
        if (!self.has_anim or self.tiles.len <= anim_tile_base) return;
        // TfrBGAnimGfx buffer layout is interleaved, not 4 contiguous strips of 16 tiles.
        // Converted WRAM holds 64 tiles; each frame DMAs 16 of them to VRAM $1200 (tile 288+):
        //   VRAM slot s  ←  source tile (s%4) + frame*4 + (s/4)*16
        // so tile 288 cycles sources 0,4,8,12 — a proper 4-frame flame, not wall garbage.
        const f: usize = frame % anim_frame_count;
        var s: usize = 0;
        while (s < anim_tiles_per_frame) : (s += 1) {
            const dest = anim_tile_base + s;
            if (dest >= self.tiles.len) break;
            const src = (s % 4) + f * 4 + (s / 4) * 16;
            self.tiles[dest] = self.anim_src[src];
        }
    }

    pub fn tileAt(self: *const SubMap, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) {
            // Outside map: fill metatile (low 7 bits of fill byte)
            return self.prop.fill_flags & 0x7F;
        }
        return self.cells[@as(usize, @intCast(y)) * map_w + @as(usize, @intCast(x))];
    }

    pub fn tileAtBg2(self: *const SubMap, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return self.prop.fill_flags & 0x7F;
        return self.cells_bg2[@as(usize, @intCast(y)) * map_w + @as(usize, @intCast(x))];
    }

    pub fn propLoAt(self: *const SubMap, x: i32, y: i32) u8 {
        return self.prop_lo[self.tileAt(x, y) & 0x7F];
    }

    pub fn propHiAt(self: *const SubMap, x: i32, y: i32) u8 {
        return self.prop_hi[self.tileAt(x, y) & 0x7F];
    }

    /// Map tile flags byte2 bit4: "Exit to Previous Map" (rip mapTileProperties).
    pub fn isExitTile(self: *const SubMap, x: i32, y: i32) bool {
        return (self.propHiAt(x, y) & 0x10) != 0;
    }

    /// Map tile flags byte2 bit7: coordinate trigger (doors/warps/chests table).
    pub fn isTriggerTile(self: *const SubMap, x: i32, y: i32) bool {
        return (self.propHiAt(x, y) & 0x80) != 0;
    }

    /// Map tile prop lo bit3: save point (`$a1&$08` → `$1a02` + event $76).
    pub fn isSavePoint(self: *const SubMap, x: i32, y: i32) bool {
        return (self.propLoAt(x, y) & 0x08) != 0;
    }

    /// Map tile prop hi bit0: floor damage tile (`$a2&$01` → DoFloorDmg).
    pub fn isDamageFloor(self: *const SubMap, x: i32, y: i32) bool {
        return (self.propHiAt(x, y) & 0x01) != 0;
    }

    /// NPC free-roam z key (`_00bfe3`: prop_lo & `$83`) — dest must match current.
    pub fn npcRoamZKey(self: *const SubMap, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return 0;
        return self.propLoAt(x, y) & 0x83;
    }

    /// EventCmd_d5 (event.asm @ee9f) — pure rewrite in `field_fx.openSecretDoorCells`.
    pub fn openSecretDoorNear(self: *SubMap, px: i32, py: i32) bool {
        return @import("../game/field_fx.zig").openSecretDoorCells(&self.cells, px, py);
    }

    /// OpenDoor (move.asm): keep cell id $70/$71 (triggers stay); patch draw to $6F.
    /// Returns true if this call newly opened the door (PlaySfx once).
    pub fn openDoorAt(self: *SubMap, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return false;
        const ux: u5 = @intCast(x);
        const uy: usize = @intCast(y);
        const id = self.cells[uy * map_w + @as(usize, ux)];
        if (id != closed_door_a and id != closed_door_b) return false;
        const bit = @as(u32, 1) << ux;
        if ((self.opened_doors[uy] & bit) != 0) return false; // already open
        self.opened_doors[uy] |= bit;
        return true;
    }

    pub fn isDoorOpen(self: *const SubMap, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return false;
        const ux: u5 = @intCast(x);
        const uy: usize = @intCast(y);
        return (self.opened_doors[uy] & (@as(u32, 1) << ux)) != 0;
    }

    /// Metatile id used for drawing (open doors → $6F gfx, cell id unchanged).
    pub fn displayTileAt(self: *const SubMap, x: i32, y: i32) u8 {
        const id = self.tileAt(x, y) & 0x7F;
        if (self.isDoorOpen(x, y) and (id == closed_door_a or id == closed_door_b)) {
            return open_door_metatile;
        }
        return id;
    }

    /// DrawPlayerSub @b2d6–@b2f8: `$a2&$04` full sprite hide with bridge/z tests.
    pub fn spriteFullyHidden(self: *const SubMap, x: i32, y: i32, party_z: u8) bool {
        const hi = self.propHiAt(x, y);
        if ((hi & 0x04) == 0) return false;
        const lo = self.propLoAt(x, y);
        // Bridge (lo bit2): show if (lo&3) & $d2 != 0.
        if ((lo & 0x04) != 0) {
            return ((lo & 0x03) & (party_z & 0x03)) == 0;
        }
        // Non-bridge + hi bit2: hide (under ledge / upper layer).
        // Many outdoor tiles set hi bit2 with lo=0; those are not walkable z-matched
        // floors — only hide when lo z is 0 (impassable fill-like under).
        return (lo & 0x03) == 0;
    }

    /// MapTileProp hi bit3 → `$090a` (InitNPCs / CheckMoveNPCs): hide lower OAM half.
    pub fn spriteHideLowerBody(self: *const SubMap, x: i32, y: i32) bool {
        return (self.propHiAt(x, y) & 0x08) != 0;
    }

    pub fn canWalk(self: *const SubMap, from_x: i32, from_y: i32, to_x: i32, to_y: i32) bool {
        if (to_x < 0 or to_y < 0 or to_x >= map_w or to_y >= map_h) {
            return (self.prop.fill_flags & 0x80) == 0; // bit7 = impassable fill
        }
        // From outside the map (scripted walk overshoot): allow re-entry onto any
        // non-solid tile. Impassable fill + z-level 0 would otherwise soft-lock.
        const from_oob = from_x < 0 or from_y < 0 or from_x >= map_w or from_y >= map_h;
        if (from_oob) {
            const dest = self.propLoAt(to_x, to_y);
            return (dest & 0x07) != 0x07;
        }
        const curr = self.propLoAt(from_x, from_y);
        const dest = self.propLoAt(to_x, to_y);
        if ((dest & 0x07) == 0x07) return false;
        const z = curr & 0x03;
        const mask: u8 = z + 4;
        if ((curr & 0x04) != 0) {
            return (dest & 0x03 & z) != 0 or (dest & 0x04) != 0;
        }
        return (dest & mask) != 0;
    }

    /// Full map without sprites (menu underlay). BG2 + all BG1 priorities.
    pub fn render(
        self: *const SubMap,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
    ) void {
        self.clearBackdrop(dest);
        self.renderBackground(dest, dest_w, dest_h, cam_x, cam_y, fine_x, fine_y);
        self.renderForeground(dest, dest_w, dest_h, cam_x, cam_y, fine_x, fine_y);
    }

    /// SNES draw order under sprites: backdrop → BG2 → BG1 low-priority 8×8s.
    /// Call then blit sprites, then `renderForeground` for walls/bed tops/arches.
    pub fn renderBackground(
        self: *const SubMap,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
    ) void {
        const tiles_x: i32 = @intCast(dest_w / meta_px + 2);
        const tiles_y: i32 = @intCast(dest_h / meta_px + 2);
        const d = self.bg2FineDelta(fine_x, fine_y);
        const bg2_scroll_x = fine_x + d.x;
        const bg2_scroll_y = fine_y + d.y;
        const bg2_cam_x = cam_x + @divFloor(bg2_scroll_x, @as(i32, @intCast(meta_px)));
        const bg2_cam_y = cam_y + @divFloor(bg2_scroll_y, @as(i32, @intCast(meta_px)));
        const bg2_fx = @mod(bg2_scroll_x, @as(i32, @intCast(meta_px)));
        const bg2_fy = @mod(bg2_scroll_y, @as(i32, @intCast(meta_px)));
        // BG2 (all corners; priority rarely used for BG2 field maps).
        self.renderLayer(dest, dest_w, tiles_x, tiles_y, bg2_cam_x, bg2_cam_y, bg2_fx, bg2_fy, .bg2, true, .all);
        // BG1 low priority only (under sprites).
        self.renderLayer(dest, dest_w, tiles_x, tiles_y, cam_x, cam_y, fine_x, fine_y, .bg1, false, .low_only);
    }

    /// BG1 high-priority 8×8s over sprites (SNES tilemap priority bit).
    pub fn renderForeground(
        self: *const SubMap,
        dest: []u8,
        dest_w: usize,
        dest_h: usize,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
    ) void {
        const tiles_x: i32 = @intCast(dest_w / meta_px + 2);
        const tiles_y: i32 = @intCast(dest_h / meta_px + 2);
        self.renderLayer(dest, dest_w, tiles_x, tiles_y, cam_x, cam_y, fine_x, fine_y, .bg1, false, .high_only);
    }

    pub fn clearBackdrop(self: *const SubMap, dest: []u8) void {
        _ = self;
        var i: usize = 0;
        while (i < dest.len) : (i += 4) {
            dest[i] = 0;
            dest[i + 1] = 0;
            dest[i + 2] = 0;
            dest[i + 3] = 255;
        }
    }

    const LayerKind = enum { bg1, bg2 };
    const PriFilter = enum { all, low_only, high_only };

    fn renderLayer(
        self: *const SubMap,
        dest: []u8,
        dest_w: usize,
        tiles_x: i32,
        tiles_y: i32,
        cam_x: i32,
        cam_y: i32,
        fine_x: i32,
        fine_y: i32,
        layer: LayerKind,
        wrap: bool,
        pri: PriFilter,
    ) void {
        var ty: i32 = -1;
        while (ty < tiles_y) : (ty += 1) {
            var tx: i32 = -1;
            while (tx < tiles_x) : (tx += 1) {
                var mx = cam_x + tx;
                var my = cam_y + ty;
                if (wrap) {
                    mx = @mod(mx, @as(i32, @intCast(map_w)));
                    my = @mod(my, @as(i32, @intCast(map_h)));
                }
                const id: u8 = switch (layer) {
                    .bg2 => self.tileAtBg2(mx, my) & 0x7F,
                    .bg1 => self.displayTileAt(mx, my),
                };
                const dx = tx * @as(i32, @intCast(meta_px)) - fine_x;
                const dy = ty * @as(i32, @intCast(meta_px)) - fine_y;
                self.blitMeta(dest, dest_w, dx, dy, id, pri);
            }
        }
    }

    fn blitMeta(
        self: *const SubMap,
        dest: []u8,
        dest_w: usize,
        dx: i32,
        dy: i32,
        id: u8,
        pri: PriFilter,
    ) void {
        const corners = self.meta[id % 128];
        const offs = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 8 }, .{ .x = 8, .y = 8 },
        };
        for (corners, offs) |mw, off| {
            if (self.tile_count == 0) continue;
            switch (pri) {
                .all => {},
                .low_only => if (mw.priority) continue,
                .high_only => if (!mw.priority) continue,
            }
            const ti = mw.tile % self.tile_count;
            // SNES: tilemap palette field P → CGRAM colors P*16 .. P*16+15
            const pal_off: usize = @as(usize, mw.pal) * 16;
            blitTileFlip(dest, dest_w, dx + off.x, dy + off.y, &self.tiles[ti], self.palette[0..], pal_off, mw.hflip, mw.vflip);
        }
    }
};

fn blitTileFlip(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: []const snes.Color,
    pal_off: usize,
    hflip: bool,
    vflip: bool,
) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const sx: usize = if (hflip) 7 - col else col;
            const sy: usize = if (vflip) 7 - row else row;
            const idx = indices[sy * 8 + sx];
            // SNES: color index 0 is transparent (reveals lower BG / backdrop).
            // Drawing it opaque produced solid tan/orange "untextured" ground and wall speckles.
            if (idx == 0) continue;
            const px = dx + @as(i32, @intCast(col));
            const py = dy + @as(i32, @intCast(row));
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            const dh = dest.len / (dest_w * 4);
            if (ux >= dest_w or uy >= dh) continue;
            const ci = pal_off + idx;
            const color = if (ci < palette.len) palette[ci] else snes.Color{ .r = 255, .g = 0, .b = 255 };
            const o = (uy * dest_w + ux) * 4;
            dest[o] = color.r;
            dest[o + 1] = color.g;
            dest[o + 2] = color.b;
            dest[o + 3] = 255;
        }
    }
}

/// WindowPal 16 colors @ 0D/87D0 (file 0x687D0) — LoadWindowPal → CGRAM 0–15.
const window_pal: usize = 0x687D0;

fn loadMapPal(r: *const rom_mod.Rom, pal_id: u8, out: *[128]snes.Color) void {
    // Exact CGRAM layout after LoadWindowPal + LoadMapPal (field.asm):
    //   colors 0–15  = WindowPal (tilemap palette 0)
    //   colors 16–31 = map palette 1: MapPal+0x10 (8) + MapPal+0x90 (8)
    //   colors 32–47 = map palette 2: MapPal+0x20 + MapPal+0xA0
    //   … up through palette 7
    // MapPal set base = pal_id * 128; reads past +0x90 may touch the next set.
    @memset(out, snes.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });

    if (r.slice(window_pal, 32)) |wp| {
        var c: usize = 0;
        while (c < 16) : (c += 1) {
            const w = std.mem.readInt(u16, wp[c * 2 ..][0..2], .little);
            out[c] = snes.Color.fromSnes(w);
            out[c].a = 255;
        }
    } else |_| {}

    // Need up to +0x90+0x70 = +0x100 bytes from set start (into next pal set).
    const off = map_pal_base + @as(usize, pal_id % 32) * 128;
    const bytes = r.slice(off, 256) catch r.slice(off, 128) catch return;

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const lo = 0x10 + i * 0x10;
        const hi = 0x90 + i * 0x10;
        var c: usize = 0;
        while (c < 8) : (c += 1) {
            if (lo + c * 2 + 1 < bytes.len) {
                const w = std.mem.readInt(u16, bytes[lo + c * 2 ..][0..2], .little);
                out[(i + 1) * 16 + c] = snes.Color.fromSnes(w);
                out[(i + 1) * 16 + c].a = 255;
            }
            if (hi + c * 2 + 1 < bytes.len) {
                const w = std.mem.readInt(u16, bytes[hi + c * 2 ..][0..2], .little);
                out[(i + 1) * 16 + 8 + c] = snes.Color.fromSnes(w);
                out[(i + 1) * 16 + 8 + c].a = 255;
            }
        }
    }
}

fn loadMapGfx(gpa: std.mem.Allocator, r: *const rom_mod.Rom, tileset: u8, bpp4: bool) ![][64]u8 {
    const ts: usize = tileset & 0x0F;
    const ptr = try r.readU16Le(map_gfx_ptrs + ts * 2);
    const bank = map_gfx_bank[ts];
    const addr: u16 = if (ptr < 0x8000) ptr | 0x8000 else ptr;
    const file_off = rom_mod.Rom.loromOffset((@as(u24, bank) << 16) | addr);

    if (file_off >= r.data.len) return try gpa.alloc([64]u8, 0);
    const avail = r.data.len - file_off;

    if (bpp4) {
        // LoadBGGfx 4bpp path: copy $2400 bytes → 288 tiles × 32 bytes (ship/airship).
        const n: usize = @min(@as(usize, 288), avail / 32);
        if (n == 0) return try gpa.alloc([64]u8, 0);
        const raw = try r.slice(file_off, n * 32);
        const out = try gpa.alloc([64]u8, n);
        var t: usize = 0;
        while (t < n) : (t += 1) {
            snes.decodeTile4bpp(raw[t * 32 ..][0..32], &out[t]);
        }
        return out;
    }

    // 3bpp: TfrBGGfx copies 0x180 = 384 tiles × 24 bytes.
    const n: usize = @min(@as(usize, 384), avail / 24);
    if (n == 0) return try gpa.alloc([64]u8, 0);
    const raw = try r.slice(file_off, n * 24);
    const out = try gpa.alloc([64]u8, n);
    var t: usize = 0;
    while (t < n) : (t += 1) {
        snes.decodeTile3bpp(raw[t * 24 ..][0..24], &out[t]);
    }
    return out;
}

/// File offset of this tileset's anim block inside MapAnimGfx (LoadBGAnimGfx math).
fn bgAnimFileOffset(tileset: u8) usize {
    const v: usize = bg_anim_tbl[tileset & 0x0F];
    // 65816: 16-bit (v<<8) >> 1, then high byte += v
    return ((((v >> 1) + v) << 8) | ((v << 7) & 0xFF));
}

fn loadBgAnimSrc(
    r: *const rom_mod.Rom,
    tileset: u8,
    out: *[anim_frame_count * anim_tiles_per_frame][64]u8,
) bool {
    const base = map_anim_gfx + bgAnimFileOffset(tileset);
    // 64 tiles × 24 bytes 3bpp (LoadBGAnimGfx converts these to 4bpp in $7F5000)
    const n = anim_frame_count * anim_tiles_per_frame;
    const raw = r.slice(base, n * 24) catch return false;
    var t: usize = 0;
    while (t < n) : (t += 1) {
        snes.decodeTile3bpp(raw[t * 24 ..][0..24], &out[t]);
    }
    return true;
}

fn decodeTilemap(r: *const rom_mod.Rom, form: u8, cells: *[map_w * map_h]u8) !void {
    const prel = try r.readU16Le(sub_tilemap_ptrs + @as(usize, form) * 2);
    const nrel = try r.readU16Le(sub_tilemap_ptrs + @as(usize, form) * 2 + 2);

    var p: u16 = prel;
    var bank: u8 = 0x17;
    if ((p & 0x8000) != 0) {
        bank += 1;
        p &= 0x7FFF;
    }
    var np: u16 = nrel;
    var nbank: u8 = 0x17;
    if ((np & 0x8000) != 0) {
        nbank += 1;
        np &= 0x7FFF;
    }

    const start = rom_mod.Rom.loromOffset((@as(u24, bank) << 16) | (0x8000 +% p));
    var end = rom_mod.Rom.loromOffset((@as(u24, nbank) << 16) | (0x8000 +% np));
    if (end <= start) end = @min(start + 0x800, r.data.len);
    const data = try r.slice(start, end - start);

    var row: usize = 0;
    var col: usize = 0;
    var src: usize = 0;
    @memset(cells, 0);
    while (row < map_h and src < data.len) {
        const b = data[src];
        src += 1;
        if ((b & 0x80) != 0) {
            const tile = b & 0x7F;
            if (src >= data.len) break;
            var count: usize = @as(usize, data[src]) + 1;
            src += 1;
            while (count > 0 and row < map_h) : (count -= 1) {
                cells[row * map_w + col] = tile;
                col += 1;
                if (col >= map_w) {
                    col = 0;
                    row += 1;
                }
            }
        } else {
            cells[row * map_w + col] = b;
            col += 1;
            if (col >= map_w) {
                col = 0;
                row += 1;
            }
        }
    }
}

test "cameraTopLeft centers player (door/stairs/shop share path)" {
    const c = cameraTopLeft(10, 12, true);
    try std.testing.expectEqual(@as(i32, 10 - camera_ox_sub), c.x);
    try std.testing.expectEqual(@as(i32, 12 - camera_oy_sub), c.y);
    const w = cameraTopLeft(50, 40, false);
    try std.testing.expectEqual(@as(i32, 50 - camera_ox_world), w.x);
}

test "UpdateScrollSub edge columns match tilemap.asm" {
    try std.testing.expectEqual(@as(i32, 19), scrollEdgeX(10, true)); // +9
    try std.testing.expectEqual(@as(i32, 2), scrollEdgeX(10, false)); // -8
    try std.testing.expectEqual(@as(i32, 5), scrollEdgeYBase(12)); // -7
}

test "UpdateAnimPal phase indices and tileset gates" {
    try std.testing.expect(tilesetUsesTowerAnim(8));
    try std.testing.expect(tilesetUsesTowerAnim(0x0A));
    try std.testing.expect(tilesetUsesTowerAnim(0x0B));
    try std.testing.expect(!tilesetUsesTowerAnim(0x0C));
    try std.testing.expect(tilesetUsesCaveAnim(9));
    try std.testing.expect(!tilesetUsesCaveAnim(8));
    // `$7a=0` → light idx 0; `$7a=4` → (1&$0e)/2 = 0; `$7a=8` → 1
    try std.testing.expectEqual(@as(usize, 0), animPalLightIndex(0));
    try std.testing.expectEqual(@as(usize, 1), animPalLightIndex(8));
    try std.testing.expectEqual(@as(usize, 0), animPalBlueRotIndex(0));
    try std.testing.expectEqual(@as(usize, 1), animPalBlueRotIndex(4));
}
