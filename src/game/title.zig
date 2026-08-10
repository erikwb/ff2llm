//! Title + game-load screen.
//!
//! Decomp flow (field/title_en.asm → menu/load.asm):
//!   ShowTitle: splash (TitleGfx/TitleBGTiles/TitlePal) + song $15 Prelude, A to continue
//!   GameLoadMenu_main: New Game window + 4 save slots, SelectSaveSlot
//!
//! Host extends the load menu with free-roam start locations (debug / chapter skips).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const window = @import("../battle/window.zig");
const cursor_mod = @import("../battle/cursor.zig");
const font_mod = @import("../gfx/font.zig");
const snes = @import("../gfx/snes.zig");
const save_mod = @import("save.zig");
const L = @import("menu_layout.zig");
const state_mod = @import("state.zig");
const data_mod = @import("../data.zig");
const party_mod = @import("party.zig");
const cmd_magic_mod = @import("../battle/cmd_magic.zig");
const overworld_mod = @import("../map/overworld.zig");
const triggers_mod = @import("../map/triggers.zig");
/// TitleGfx @ $08/C000 → LoROM file (title_en.asm LoadTitleGfx).
const title_gfx_cpu: u24 = 0x08C000;
const title_gfx_size: usize = 0x2000;
/// TitleBGTiles @ $08/E000 size $0800 (32×32 tilemap words).
const title_tm_cpu: u24 = 0x08E000;
const title_tm_size: usize = 0x0800;
/// TitlePal @ $08/E800 size $0100 (128 colors).
const title_pal_cpu: u24 = 0x08E800;
const title_pal_size: usize = 0x0100;

pub const Phase = enum { splash, menu };

/// Menu rows: decomp New Game + 4 slots, then host start locations, Quit.
pub const Option = enum(u8) {
    new_game = 0,
    load_0,
    load_1,
    load_2,
    load_3,
    outside_baron,
    town_baron,
    castle_baron,
    mist,
    kaipo,
    mysidia,
    damcyan,
    fabul,
    /// Moon surface + parked Lunar Whale (Special_2f land pos).
    moon,
    quit,

    pub const count: u8 = @intFromEnum(Option.quit) + 1;

    pub fn label(self: Option) []const u8 {
        return switch (self) {
            .new_game => "New Game",
            .load_0 => "File 1",
            .load_1 => "File 2",
            .load_2 => "File 3",
            .load_3 => "File 4",
            .outside_baron => "Outside Baron",
            .town_baron => "Town of Baron",
            .castle_baron => "Castle Baron",
            .mist => "Mist",
            .kaipo => "Kaipo",
            .mysidia => "Mysidia",
            .damcyan => "Damcyan",
            .fabul => "Fabul",
            .moon => "Moon",
            .quit => "Quit",
        };
    }

    pub fn isLoad(self: Option) bool {
        return switch (self) {
            .load_0, .load_1, .load_2, .load_3 => true,
            else => false,
        };
    }

    pub fn loadSlot(self: Option) ?u8 {
        return switch (self) {
            .load_0 => 0,
            .load_1 => 1,
            .load_2 => 2,
            .load_3 => 3,
            else => null,
        };
    }
};

pub const Choice = union(enum) {
    new_game,
    load: u8,
    start: StartLoc,
    quit,
};

/// Free-roam / chapter-skip destinations (host extension of GameLoadMenu).
pub const StartLoc = enum {
    outside_baron,
    town_baron,
    castle_baron,
    mist,
    kaipo,
    mysidia,
    damcyan,
    fabul,
    moon,
};

pub const TitleScreen = struct {
    phase: Phase = .splash,
    sel: u8 = 0,
    chrome: window.WindowChrome = .{},
    hand: cursor_mod.HandCursor = .{},
    font: font_mod.MenuFont = .{},
    /// Pre-rendered splash (256×224 RGBA) from TitleGfx + tilemap + pal.
    splash: ?[]u8 = null,
    splash_w: usize = 256,
    splash_h: usize = 224,
    loaded: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *TitleScreen, gpa: std.mem.Allocator, r: *const rom_mod.Rom) void {
        self.* = .{
            .allocator = gpa,
        };
        self.chrome.load(r) catch {};
        self.hand.load(r) catch {};
        self.font.load(r) catch {};
        self.loaded = self.chrome.loaded and self.font.loaded;
        self.splash = renderSplash(gpa, r) catch null;
    }

    pub fn deinit(self: *TitleScreen) void {
        if (self.splash) |s| self.allocator.free(s);
        self.splash = null;
    }

    pub fn up(self: *TitleScreen) void {
        if (self.phase != .menu) return;
        if (self.sel == 0) self.sel = Option.count - 1 else self.sel -= 1;
    }

    pub fn down(self: *TitleScreen) void {
        if (self.phase != .menu) return;
        self.sel = (self.sel + 1) % Option.count;
    }

    /// Confirm: splash → menu; menu → Choice.
    pub fn confirm(self: *TitleScreen) ?Choice {
        if (self.phase == .splash) {
            self.phase = .menu;
            self.sel = 0;
            return null;
        }
        const opt: Option = @enumFromInt(self.sel);
        return switch (opt) {
            .new_game => .{ .new_game = {} },
            .load_0, .load_1, .load_2, .load_3 => blk: {
                const slot = opt.loadSlot().?;
                if (!save_mod.slotExists(slot)) break :blk null;
                break :blk .{ .load = slot };
            },
            .outside_baron => .{ .start = .outside_baron },
            .town_baron => .{ .start = .town_baron },
            .castle_baron => .{ .start = .castle_baron },
            .mist => .{ .start = .mist },
            .kaipo => .{ .start = .kaipo },
            .mysidia => .{ .start = .mysidia },
            .damcyan => .{ .start = .damcyan },
            .fabul => .{ .start = .fabul },
            .moon => .{ .start = .moon },
            .quit => .{ .quit = {} },
        };
    }

    pub fn present(self: *const TitleScreen, pixels: []u8, dest_w: usize, dest_h: usize) void {
        if (self.phase == .splash) {
            self.drawSplash(pixels, dest_w, dest_h);
            return;
        }
        self.drawMenu(pixels, dest_w, dest_h);
    }

    fn drawSplash(self: *const TitleScreen, pixels: []u8, dest_w: usize, dest_h: usize) void {
        // ShowTitle (title_en.asm @85fa): TitleGfx + TitleBGTiles + TitlePal only.
        // Copyright / "Push start" (if any) are baked into the tilemap — do **not**
        // overlay host font (that covered the EN splash copyright at the bottom).
        // Wait loop only checks JOY_A; host maps that to confirm (A / Enter / pad).
        fill(pixels, dest_w, dest_h, 0, 0, @intCast(dest_w), @intCast(dest_h), 8, 8, 40);
        if (self.splash) |sp| {
            const sw = self.splash_w;
            const sh = self.splash_h;
            const ox: i32 = @divTrunc(@as(i32, @intCast(dest_w)) - @as(i32, @intCast(sw)), 2);
            const oy: i32 = @divTrunc(@as(i32, @intCast(dest_h)) - @as(i32, @intCast(sh)), 2);
            blitRgba(pixels, dest_w, dest_h, ox, oy, sp, sw, sh);
        } else if (self.loaded) {
            // Fallback when splash decode fails: logo plate.
            L.drawDef(&self.chrome, pixels, dest_w, 4, 8, 22, 6);
            self.font.drawAscii(pixels, dest_w, L.ptxtX(7), L.ptxtY(10), "FINAL FANTASY II");
            self.font.drawAsciiInk(pixels, dest_w, L.ptxtX(6), 200, "Press A");
        }
    }

    fn drawMenu(self: *const TitleScreen, pixels: []u8, dest_w: usize, dest_h: usize) void {
        fill(pixels, dest_w, dest_h, 0, 0, @intCast(dest_w), @intCast(dest_h), 8, 8, 40);
        if (!self.loaded) return;

        // NewGameWindow-style header (menu_data.asm @dfc5 def_window 0,0,16,2).
        L.drawDef(&self.chrome, pixels, dest_w, 0, 0, 16, 2);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(1), "New Game");

        // Right hint panel (LoadMsgWindow-ish).
        L.drawDef(&self.chrome, pixels, dest_w, 20, 0, 9, 3);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(21), L.ptxtY(1), "Prelude");

        // Main list — one window, fixed 12px pitch so rows never overlap (224px).
        L.drawDef(&self.chrome, pixels, dest_w, 0, 3, 29, 23);

        // 14 options × 12px from y=36 → ends ~204; section gaps of +4px.
        const pitch: i32 = 12;
        var i: u8 = 0;
        while (i < Option.count) : (i += 1) {
            const opt: Option = @enumFromInt(i);
            const y = optionPixelY(i, pitch);
            var buf: [32]u8 = undefined;
            const text: []const u8 = blk: {
                if (opt.loadSlot()) |slot| {
                    if (save_mod.slotExists(slot)) {
                        break :blk std.fmt.bufPrint(&buf, "File {d}  Load", .{slot + 1}) catch opt.label();
                    }
                    break :blk std.fmt.bufPrint(&buf, "File {d}  Empty", .{slot + 1}) catch opt.label();
                }
                break :blk opt.label();
            };
            if (self.sel == i) {
                self.hand.blit(pixels, dest_w, 6, y - 2);
            }
            // Empty loads gray; everything else white. On window fill, pal idx 1
            // matches chrome blue so cell bg is invisible (SNES behaviour).
            if (opt.loadSlot()) |slot| {
                if (!save_mod.slotExists(slot)) {
                    self.font.drawAsciiPal(pixels, dest_w, 22, y, text, font_mod.pal_gray);
                    continue;
                }
            }
            self.font.drawAscii(pixels, dest_w, 22, y, text);
        }
    }

    /// Pixel Y for menu option `sel`. Gaps after files and before Quit.
    fn optionPixelY(sel: u8, pitch: i32) i32 {
        // List top interior of main window (top=3 tiles → y=24) + 1 tile pad.
        const base: i32 = 36;
        // 0 New Game, 1-4 files, 5-13 starts (9), 14 quit
        const n_starts: i32 = 9;
        if (sel <= 4) return base + @as(i32, sel) * pitch;
        if (sel < 5 + n_starts) return base + 5 * pitch + 4 + @as(i32, sel - 5) * pitch;
        return base + 5 * pitch + 4 + n_starts * pitch + 4;
    }
};

// =============================================================================
// Game start factories
// =============================================================================

pub fn beginFromChoice(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    gd: *const data_mod.GameData,
    choice: Choice,
) !?state_mod.GameState {
    return switch (choice) {
        .quit => null,
        .new_game => try state_mod.GameState.initNewGame(gpa, r, gd),
        .load => |slot| try initFromSave(gpa, r, gd, slot),
        .start => |loc| try initStartLoc(gpa, r, gd, loc),
    };
}

fn initFromSave(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    gd: *const data_mod.GameData,
    slot: u8,
) !state_mod.GameState {
    // Seed with free-roam shell (OW + triggers allocated), then overlay save.
    var gs = try initFreeRoamShell(gpa, r, gd);
    errdefer gs.deinit();
    try save_mod.loadSlot(&gs, slot);
    // Re-enter map so submap/OW graphics match saved mode.
    gs.suppress_stack_push = true;
    if (gs.mode == .submap) {
        try gs.enterSubmap(gs.map_id, @intCast(@max(gs.pos_x, 0)), @intCast(@max(gs.pos_y, 0)), gs.facing);
    } else {
        try gs.enterWorld(gs.world_id, @intCast(@max(gs.pos_x, 0) & 0xFF), @intCast(@max(gs.pos_y, 0) & 0xFF));
    }
    gs.setMsg("Game loaded");
    return gs;
}

fn initStartLoc(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    gd: *const data_mod.GameData,
    loc: StartLoc,
) !state_mod.GameState {
    if (loc == .outside_baron) return state_mod.GameState.initBaronSkip(gpa, r, gd);

    var gs = try initFreeRoamShell(gpa, r, gd);
    errdefer gs.deinit();
    // Cecil + Kain like post-intro free roam.
    if (party_mod.initMainChar(r)) |cecil| gs.party[0] = cecil;
    gs.field_leader_slot = 0;
    _ = party_mod.addFromEvent(r, gs.party[0..], 2);
    seedConsumables(&gs);

    // World-trigger destinations (WorldTriggers1 @ $19/FE66).
    gs.suppress_stack_push = true;
    switch (loc) {
        .outside_baron => unreachable,
        .town_baron => try gs.enterSubmap(0, 16, 30, 2),
        .castle_baron => try gs.enterSubmap(36, 16, 30, 2),
        .mist => try gs.enterSubmap(1, 67, 16, 2),
        .kaipo => try gs.enterSubmap(2, 15, 30, 2),
        .mysidia => try gs.enterSubmap(3, 16, 31, 2),
        .damcyan => try gs.enterSubmap(37, 16, 30, 2),
        .fabul => try gs.enterSubmap(38, 15, 29, 2),
        .moon => {
            // Special_2f / crystal moon land: whale parks at ($13,$27) on world 2.
            // Party stands on that tile so A boards (ChangeVehicle / BoardWhale).
            const wx: u8 = 0x13;
            const wy: u8 = 0x27;
            try gs.enterWorld(2, wx, wy);
            gs.whale_x = wx;
            gs.whale_y = wy;
            gs.whale_world = 2;
            gs.whale_vis = 1;
            gs.vehicle = 0;
            gs.setMsg("Lunar surface");
        },
    }
    return gs;
}

fn initFreeRoamShell(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    gd: *const data_mod.GameData,
) !state_mod.GameState {
    _ = gd;
    var gs: state_mod.GameState = .{
        .allocator = gpa,
        .rom = r,
        .pos_x = state_mod.new_game_overworld_x,
        .pos_y = state_mod.new_game_overworld_y,
        .mode = .overworld,
        .facing = 2,
    };
    try gs.loadInitSwitches(r);
    cmd_magic_mod.initSpellLists(r, &gs.spell_lists);
    gs.ow = try overworld_mod.Overworld.load(gpa, r);
    gs.syncOverworldEventTiles();
    gs.world_triggers = try triggers_mod.loadWorldTriggers(gpa, r, gs.world_id);
    return gs;
}

fn seedConsumables(gs: *state_mod.GameState) void {
    _ = gs.inventory.give(0xCE);
    _ = gs.inventory.give(0xCE);
    _ = gs.inventory.give(0xCE);
    _ = gs.inventory.give(0xCF);
    _ = gs.inventory.give(0xD1);
}

// =============================================================================
// Splash decode (title_en.asm ShowTitle / LoadTitleGfx)
// =============================================================================

fn renderSplash(gpa: std.mem.Allocator, r: *const rom_mod.Rom) ![]u8 {
    const gfx = try r.readAtCpu(title_gfx_cpu, title_gfx_size);
    const tm = try r.readAtCpu(title_tm_cpu, title_tm_size);
    const pal_raw = try r.readAtCpu(title_pal_cpu, title_pal_size);

    var pal: [128]snes.Color = undefined;
    var pi: usize = 0;
    while (pi < 128) : (pi += 1) {
        const w = @as(u16, pal_raw[pi * 2]) | (@as(u16, pal_raw[pi * 2 + 1]) << 8);
        pal[pi] = snes.Color.fromSnes(w);
        pal[pi].a = 255;
    }

    const tile_count = title_gfx_size / 32;
    var tiles: [256][64]u8 = undefined;
    var t: usize = 0;
    while (t < tile_count and t < 256) : (t += 1) {
        snes.decodeTile4bpp(gfx[t * 32 ..][0..32], &tiles[t]);
    }

    const w: usize = 256;
    const h: usize = 224; // 28 tile rows
    const out = try gpa.alloc(u8, w * h * 4);
    @memset(out, 0);

    var row: usize = 0;
    while (row < 28) : (row += 1) {
        var col: usize = 0;
        while (col < 32) : (col += 1) {
            const entry = @as(u16, tm[(row * 32 + col) * 2]) |
                (@as(u16, tm[(row * 32 + col) * 2 + 1]) << 8);
            const tid: usize = entry & 0x3FF;
            const pal_n: usize = (entry >> 10) & 7;
            const flip_h = (entry & 0x4000) != 0;
            const flip_v = (entry & 0x8000) != 0;
            if (tid >= tile_count) continue;
            const base = pal_n * 16;
            var ty: usize = 0;
            while (ty < 8) : (ty += 1) {
                var tx: usize = 0;
                while (tx < 8) : (tx += 1) {
                    const sx: usize = if (flip_h) 7 - tx else tx;
                    const sy: usize = if (flip_v) 7 - ty else ty;
                    const idx = tiles[tid][sy * 8 + sx];
                    if (idx == 0) continue; // transparent → dark field behind
                    const c = pal[base + idx];
                    const px = col * 8 + tx;
                    const py = row * 8 + ty;
                    const o = (py * w + px) * 4;
                    out[o] = c.r;
                    out[o + 1] = c.g;
                    out[o + 2] = c.b;
                    out[o + 3] = 255;
                }
            }
        }
    }
    return out;
}

fn fill(pixels: []u8, dest_w: usize, dest_h: usize, x: i32, y: i32, w: i32, h: i32, r: u8, g: u8, b: u8) void {
    var py = y;
    while (py < y + h) : (py += 1) {
        if (py < 0 or py >= @as(i32, @intCast(dest_h))) continue;
        var px = x;
        while (px < x + w) : (px += 1) {
            if (px < 0 or px >= @as(i32, @intCast(dest_w))) continue;
            const o: usize = @intCast((py * @as(i32, @intCast(dest_w)) + px) * 4);
            pixels[o] = r;
            pixels[o + 1] = g;
            pixels[o + 2] = b;
            pixels[o + 3] = 255;
        }
    }
}

fn blitRgba(dest: []u8, dest_w: usize, dest_h: usize, ox: i32, oy: i32, src: []const u8, sw: usize, sh: usize) void {
    var y: usize = 0;
    while (y < sh) : (y += 1) {
        const dy = oy + @as(i32, @intCast(y));
        if (dy < 0 or dy >= @as(i32, @intCast(dest_h))) continue;
        var x: usize = 0;
        while (x < sw) : (x += 1) {
            const dx = ox + @as(i32, @intCast(x));
            if (dx < 0 or dx >= @as(i32, @intCast(dest_w))) continue;
            const si = (y * sw + x) * 4;
            if (src[si + 3] == 0) continue;
            const di: usize = @intCast((dy * @as(i32, @intCast(dest_w)) + dx) * 4);
            dest[di] = src[si];
            dest[di + 1] = src[si + 1];
            dest[di + 2] = src[si + 2];
            dest[di + 3] = 255;
        }
    }
}
