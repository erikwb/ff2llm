//! NPCs: graphics via NPCGfxID + MapSpriteGfx, talk via scripts → events → dialogue.
//!
//! Idle/walk animation follows DrawNPCs (field/npc.asm): walk frame from `$7a&$10`
//! when the "walk while stationary" prop bit is set. Sleep bubbles and other
//! multi-pose sheets cycle poses from `$7a` as well.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const snes = @import("../gfx/snes.zig");
const text_mod = @import("../text.zig");

const npc_prop_ptrs: usize = 0x98000;
const npc_prop_data: usize = 0x98300;
const npc_script_ptrs: usize = 0x99800;
const npc_script_data: usize = 0x99C00;
const npc_gfx_id_tbl: usize = 0x97000;
const map_sprite_pal: usize = 0x68000;

const map_dlg_ptrs: usize = 0x88000;
const map_dlg_data: usize = 0x88300;
const event_dlg1_ptrs: usize = 0x80000;
const event_dlg1_data: usize = 0x80400;
const event_dlg2_ptrs: usize = 0x9A500;
const event_dlg2_data: usize = 0x9A700;
const dte_table: usize = 0x99700;
const event_script_ptrs: usize = 0x90000;
const event_script_data: usize = 0x90200;

/// MapSpritePal entry size: 8 colors × 2 bytes (3bpp sprites).
const pal_bytes: usize = 16;
/// LoadNPCPal base: MapSpritePal + 13×16 — NPC sets start here (player uses 0+).
const npc_pal_base_index: usize = 13;
/// Largest MapSpriteGfx sheet (ids $00–$10).
const max_tiles_per_sheet: usize = 32;

/// PlayerPalTbl (field/sprite.asm @b2fa) — keep in sync with map/sprites.zig.
const player_pal_tbl = [_]u8{ 0, 0, 1, 2, 2, 2, 0, 1, 1, 3, 0, 1, 0, 0, 0, 0, 0, 0 };

/// MoveNPCs speed tables (field/npc.asm @c117 / @c11b). Event walks use speed class 2.
/// Pixel step is applied only when `$08ff & 3 == 0` (@c045) — so class 0 is 1px/4 frames
/// (¼ player walk), not 1px every frame.
const move_px_per_frame = [_]u8{ 1, 1, 1, 2 };
const move_counter_step = [_]u8{ 1, 2, 4, 8 };
/// Event walk / pure spin: $0908 target = $40 (field/event.asm _00e35f).
const event_move_target: u8 = 0x40;
/// Event jump / spin+jump: $0908 = $80 (actions 9, B).
const event_jump_target: u8 = 0x80;
/// NPCJumpYTbl @ field_data.asm $fcc6 — index ($08ff>>2)&$1f while jumping.
const npc_jump_y_tbl = [_]u8{
    0x00, 0x03, 0x06, 0x08, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x14, 0x15, 0x17, 0x17, 0x18, 0x19, 0x19,
    0x19, 0x19, 0x19, 0x18, 0x17, 0x17, 0x15, 0x14, 0x13, 0x11, 0x0F, 0x0D, 0x0B, 0x08, 0x06, 0x03,
};
/// Spin facing tables (DrawNPCs @bbd7): index = ($08ff>>4)&7.
/// `_00bdfe` — pure spin (action A, $090c bit1 only).
const spin_face_tbl = [_]u8{ 0x03, 0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x02 };
/// `_00be06` — spin while jumping (action B, $090c bits 0+1).
const spin_jump_face_tbl = [_]u8{ 0x02, 0x02, 0x03, 0x00, 0x01, 0x02, 0x02, 0x02 };

const Corner = struct { tile: u8, hflip: bool, vflip: bool = false };

pub const Npc = struct {
    /// NPCProp byte0: switch id / script id / GfxID table index.
    prop_gfx: u8,
    sheet_id: u8,
    x: u8,
    y: u8,
    /// $0909: facing 0–3 cardinal; 4–7 special cutscene poses (hang/collapse/…).
    facing: u8,
    /// Prop byte3 bit5: walk-while-stationary (idle step anim).
    walk_idle: bool,
    /// Prop palette 0–3 → which of the 4 map NPC palettes.
    pal_slot: u8,
    /// Movement-type class from sheet size (InitNPCs $07). 0 = normal 16-tile.
    move_type: u8,
    /// Prop byte1 bit7: free-roam AI (InitNPCs keeps `$0902` = facing+1).
    free_roam: bool = false,
    /// Prop byte3 bits 6–7 → MoveNPCs speed class (`$0901` >> 6).
    speed_class: u8 = 0,
    /// `$08ff` free-roam counter. CheckMoveNPCs re-decides when `($08ff & $7f)==0`
    /// (bit6 clear and low 6 bits 0 — @be33/@be3d). MoveNPCs steps pixels only when
    /// `($08ff & 3)==0` (@c045).
    roam_counter: u8 = 0,
    visible: bool,
    /// Decoded 8×8 tiles (4 / 8 / 16 / 32 depending on sheet class).
    tiles: [max_tiles_per_sheet][64]u8 = undefined,
    tile_count: u8 = 0,
    /// 16×16 poses available (= tile_count / 4).
    pose_count: u8 = 0,
    /// 8-color palette for this NPC.
    pal: [8]snes.Color = undefined,

    /// Event / field walk: 0 = idle, 1=up 2=right 3=down 4=left ($0902).
    move_dir: u8 = 0,
    /// Fine pixel offset within the current tile step (0..15). X when L/R, Y when U/D.
    move_px: u8 = 0,
    /// Event movement counter ($08ff) — stops when >= move_target.
    move_counter: u8 = 0,
    /// Target counter for this step ($0908); 0 = not event-walking/jumping/spinning.
    move_target: u8 = 0,
    /// $090c bit0 — enable jump Y offset (NPCJumpYTbl). Actions 9 and B.
    jumping: bool = false,
    /// $090c bit1 — spin pose cycle (DrawNPCs @bbd7). Actions A and B.
    spinning: bool = false,


    /// True if this sprite is a human (or similar talkable being) for *voice* chat.
    ///
    /// ROM still lets you Z-talk doors/fires/chests (script events). Voice STT/LLM
    /// is only for multi-pose character sheets — not scenery props.
    ///
    /// Sheet classes (MapSpriteGfx):
    ///   $00–$10: 8 poses (party/armor)  $11–$2F: 4 poses (townsfolk, monks, …)
    ///   $30–$45: 2 poses (effects/animals)  $46+: 1 pose (doors, fires, chests, Zzz)
    pub fn canVoiceChat(self: Npc) bool {
        if (!self.visible) return false;
        // Prop / effect / single-pose sheets: doors, torches, chests, sparkles, …
        if (self.sheet_id >= 0x30) return false;
        // Graphics never loaded → empty stand-in, not a speaker.
        if (self.tile_count == 0 or self.pose_count == 0) return false;
        // Need a real walk-capable character (≥2 full 16×16 poses = 8 tiles).
        if (self.tile_count < 8 or self.pose_count < 2) return false;
        // move_type 1 = 1-pose class (should already be sheet ≥ $46); belt-and-suspenders.
        if (self.move_type == 1) return false;
        return true;
    }

    /// Snap mid-step to the destination tile and clear walk/jump state.
    pub fn finishMove(self: *Npc) void {
        if (self.move_dir != 0 and self.move_px != 0) {
            // If we haven't crossed the 16px boundary yet, commit the tile now.
            switch (self.move_dir) {
                1 => {
                    if (self.y > 0) self.y -= 1;
                },
                2 => {
                    if (self.x < 31) self.x += 1;
                },
                3 => {
                    if (self.y < 31) self.y += 1;
                },
                else => {
                    if (self.x > 0) self.x -= 1;
                },
            }
        }
        self.move_dir = 0;
        self.move_px = 0;
        self.move_counter = 0;
        self.move_target = 0;
        self.jumping = false;
        self.spinning = false;
    }

    /// True while event choreography is driving this NPC (`$0908` / jump / spin).
    /// Free-roam uses `move_dir` without a target — do not treat that as event.
    pub fn isEventActive(self: Npc) bool {
        return self.move_target != 0 or self.jumping or self.spinning;
    }

    /// DrawNPCs spin facing: table index = ($08ff>>4)&7; walk frame forced to 0.
    pub fn spinFacing(self: Npc) u8 {
        const idx: usize = (@as(usize, self.move_counter) >> 4) & 7;
        if (self.jumping) return spin_jump_face_tbl[idx];
        return spin_face_tbl[idx];
    }

    /// Screen-space pixel offset while mid-step (positive in travel direction).
    /// Jump arc is applied separately via `jumpY()`.
    pub fn moveFine(self: Npc) struct { x: i32, y: i32 } {
        const p: i32 = self.move_px;
        return switch (self.move_dir) {
            1 => .{ .x = 0, .y = -p }, // up
            2 => .{ .x = p, .y = 0 }, // right
            3 => .{ .x = 0, .y = p }, // down
            4 => .{ .x = -p, .y = 0 }, // left
            else => .{ .x = 0, .y = 0 },
        };
    }

    /// NPCJumpYTbl pixel lift while `jumping` (DrawNPCs @bc5c subtracts from sprite Y).
    pub fn jumpY(self: Npc) i32 {
        if (!self.jumping) return 0;
        const idx: usize = (@as(usize, self.move_counter) >> 2) & 0x1F;
        return npc_jump_y_tbl[idx];
    }
};

/// Submap NPC occupancy ($7f4c00, 32×32). Bit7 set = occupied; low bits = slot
/// (player uses $FF). CheckNPCBlock tests bit7. Index = y*32+x (GetNPCMapPtr).
const map_w: usize = 32;
const map_h: usize = 32;

pub const NpcSet = struct {
    npcs: []Npc,
    allocator: std.mem.Allocator,
    /// `$cf`: when true, event walk actions (0–3) do not update `$0909` facing.
    hold_facing: bool = false,
    /// `$7f4c00` occupancy: 0 empty, $80|slot NPC, $FF player dest (optional).
    occ: [map_w * map_h]u8 = .{0} ** (map_w * map_h),

    pub fn deinit(self: *NpcSet) void {
        self.allocator.free(self.npcs);
        self.* = undefined;
    }

    /// ResetNPCMap + SetNPCMap for all visible NPCs (InitNPCs / after F4–F5).
    /// Preserves player `$FF` marker if present.
    ///
    /// Free-roamers keep `$0902` (move_dir) set as walk *intent* even while
    /// standing on a tile (move_px==0). Marking only the facing destination
    /// made their body tile empty (walk-through) and blocked the tile in front
    /// ("can't approach"). Correct rule:
    /// - Always mark the tile the NPC currently occupies (x,y).
    /// - Also reserve destination while mid-step (move_px!=0) or event-walking.
    pub fn rebuildOccupancy(self: *NpcSet) void {
        var px: i32 = -1;
        var py: i32 = -1;
        for (self.occ, 0..) |v, i| {
            if (v == 0xFF) {
                px = @intCast(i % map_w);
                py = @intCast(i / map_w);
                break;
            }
        }
        @memset(&self.occ, 0);
        for (self.npcs, 0..) |n, i| {
            if (!n.visible) continue;
            const marker: u8 = 0x80 | @as(u8, @truncate(i));
            // Body tile — always solid.
            self.markOcc(n.x, n.y, marker);
            // Reserve next tile only while actually sliding between tiles, or
            // while an event walk/jump owns the slot (ROM SetNPCMap dest).
            const mid_step = n.move_px != 0;
            const event_walk = n.move_target != 0 and n.move_dir != 0;
            if ((mid_step or event_walk) and n.move_dir >= 1 and n.move_dir <= 4) {
                const d = dirDelta(n.move_dir);
                const tx = @as(i32, n.x) + d.dx;
                const ty = @as(i32, n.y) + d.dy;
                self.markOcc(tx, ty, marker);
            }
        }
        if (px >= 0 and py >= 0) self.placePlayer(px, py);
    }

    fn markOcc(self: *NpcSet, x: i32, y: i32, marker: u8) void {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return;
        const idx = @as(usize, @intCast(y)) * map_w + @as(usize, @intCast(x));
        // Don't overwrite player marker.
        if (self.occ[idx] == 0xFF) return;
        self.occ[idx] = marker;
    }

    /// ClearPlayerNPCMap + SetPlayerNPCMap with `$ae=$FF` (move.asm @aad8/@ab13).
    /// `dir` 0 = idle on (x,y); 1–4 = marker on destination from (x,y).
    pub fn placePlayer(self: *NpcSet, x: i32, y: i32) void {
        self.clearPlayerMarker();
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return;
        const idx = @as(usize, @intCast(y)) * map_w + @as(usize, @intCast(x));
        self.occ[idx] = 0xFF;
    }

    pub fn clearPlayerMarker(self: *NpcSet) void {
        for (&self.occ) |*c| {
            if (c.* == 0xFF) c.* = 0;
        }
    }

    /// CheckNPCBlock: bit7 set and not player self-marker → blocked.
    pub fn occupiedByNpc(self: *const NpcSet, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= map_w or y >= map_h) return false;
        const v = self.occ[@as(usize, @intCast(y)) * map_w + @as(usize, @intCast(x))];
        // $FF is the player — free-roam CheckTilePass runs before re-placing player.
        return (v & 0x80) != 0 and v != 0xFF;
    }

    fn dirDelta(dir: u8) struct { dx: i32, dy: i32 } {
        return switch (dir) {
            1 => .{ .dx = 0, .dy = -1 },
            2 => .{ .dx = 1, .dy = 0 },
            3 => .{ .dx = 0, .dy = 1 },
            4 => .{ .dx = -1, .dy = 0 },
            else => .{ .dx = 0, .dy = 0 },
        };
    }

    /// `npc_switches` is the 0x40-byte InitNPCSwitch / $12e0 bitfield.
    /// `map_high` is map_id >> 8 (or map prop npcMSB) — selects the second 256-switch bank.
    /// `map_npc_pal` is MapProp.npc_pal ($0fe1): low/high nibbles select palette sets.
    pub fn load(
        gpa: std.mem.Allocator,
        r: *const rom_mod.Rom,
        npc_index: u8,
        npc_switches: []const u8,
        map_high: bool,
        map_npc_pal: u8,
    ) !NpcSet {
        const ptr_idx: usize = @as(usize, npc_index) + if (map_high) @as(usize, 256) else 0;
        const rel = try r.readU16Le(npc_prop_ptrs + ptr_idx * 2);
        var pos = npc_prop_data + rel;
        const gfx_map = try r.slice(npc_gfx_id_tbl, 0x200);

        // Four NPC palettes for this map (LoadNPCPal ×2 from MapSpritePal+13×16).
        var map_pals: [4][8]snes.Color = undefined;
        loadMapNpcPals(r, map_npc_pal, &map_pals);

        var list: std.ArrayList(Npc) = .empty;
        errdefer list.deinit(gpa);

        // InitNPCs loads every prop entry into consecutive slots ($08fe count).
        // Event actor opcodes use that slot index (high nibble of $00–$BF).
        // Keep invisible NPCs too so cutscene choreography indices stay correct.
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const b = try r.slice(pos, 4);
            if (b[0] == 0) break;
            const prop_gfx = b[0];
            const visible = npcSwitchOn(npc_switches, prop_gfx, map_high);
            const sheet: u8 = if (prop_gfx < gfx_map.len) gfx_map[prop_gfx] else prop_gfx;
            const fac = b[3];
            const pal_slot: u8 = (fac >> 2) & 0x03;
            const free_roam = (b[1] & 0x80) != 0;
            const facing: u8 = fac & 0x03;
            var npc = Npc{
                .prop_gfx = prop_gfx,
                .sheet_id = sheet,
                .x = b[1] & 0x3F,
                .y = b[2] & 0x3F,
                .facing = facing,
                .walk_idle = (fac & 0x20) != 0,
                .pal_slot = pal_slot,
                .move_type = moveTypeForSheet(sheet),
                .free_roam = free_roam,
                .speed_class = (fac >> 6) & 0x03,
                .visible = visible,
            };
            // InitNPCs: free-roam keeps `$0902` = facing+1; stationary clears it.
            if (free_roam and visible) {
                npc.move_dir = facing + 1;
            }
            // Party-like sheets ($00–$0D): PlayerPalTbl → MapSpritePal (InitNPCs @c1e0).
            // Other sheets: prop pal_slot into the map's 4 NPC palette sets.
            if (sheet < 0x0E) {
                const pi = if (sheet < player_pal_tbl.len) player_pal_tbl[sheet] else 0;
                loadMapSpritePal(r, pi, &npc.pal);
            } else {
                npc.pal = map_pals[pal_slot % 4];
            }
            npc.pal[0].a = 0;
            // Still decode gfx for invisible slots (events may F4-enable them mid-cutscene).
            loadSheetTiles(r, sheet, &npc) catch {};
            try list.append(gpa, npc);
            pos += 4;
        }
        var set: NpcSet = .{ .npcs = try list.toOwnedSlice(gpa), .allocator = gpa };
        set.rebuildOccupancy();
        return set;
    }

    /// Apply one event choreography byte ($00–$BF): high nibble = NPC slot, low = action.
    /// Exact action map from field/event.asm `_00e35f` @e35f.
    ///
    /// | action | ROM effect |
    /// |--------|------------|
    /// | 0–3    | walk U/R/D/L (`$0902`=1–4, `$0908`=$40) |
    /// | 4–7    | face U/R/D/L (`$0909`=0–3) |
    /// | 8      | toggle `$090b` visibility |
    /// | 9      | jump (`$090c`=1, `$0908`=$80); L/R also walks |
    /// | A      | spin (`$090c`=2, `$0908`=$40) |
    /// | B      | spin+jump (`$090c`=3, `$0908`=$80) |
    /// | C–F    | special pose `$0909` = 5/4/6/7 |
    pub fn applyEventOpcode(self: *NpcSet, op: u8) void {
        if (op >= 0xC0) return;
        const slot: usize = op >> 4;
        if (slot >= self.npcs.len) return;
        const n = &self.npcs[slot];
        const action: u8 = op & 0x0F;
        if (action < 4) {
            // Walk: dir = action+1 → 1=up 2=right 3=down 4=left; $0908=$40.
            // Facing from dir only when `$cf` clear (event.asm @e38a).
            const dir = action + 1;
            // Host passes party_follow via optional; default update facing (cf clear).
            // applyEventOpcode has no ctx — facing always set unless we add a flag later.
            // Wired through NpcSet.hold_facing (set from GameState.party_follow).
            if (!self.hold_facing) {
                n.facing = switch (dir) {
                    1 => 0,
                    2 => 1,
                    3 => 2,
                    else => 3,
                };
            }
            if (n.isEventActive()) n.finishMove();
            n.move_dir = dir;
            n.move_px = 0;
            n.move_counter = 0;
            n.move_target = event_move_target;
            n.jumping = false;
            n.spinning = false;
            n.visible = true;
        } else if (action < 8) {
            // Face only (action 4–7 → $0909 = 0–3). Does not clear spin mid-anim in ROM,
            // but face after a finished step is the common case; snap active motion first.
            if (n.isEventActive()) n.finishMove();
            n.facing = action - 4;
            n.visible = true;
        } else if (action == 0x08) {
            // Toggle $090b visibility (event.asm @e3aa) — pure show/hide.
            if (n.isEventActive()) n.finishMove();
            n.visible = !n.visible;
        } else if (action == 0x09) {
            // Jump (@e406): $090c=$01, $0908=$80; L/R facing also walks that way.
            if (n.isEventActive()) n.finishMove();
            n.jumping = true;
            n.spinning = false;
            n.move_counter = 0;
            n.move_target = event_jump_target;
            n.move_px = 0;
            n.visible = true;
            const face = n.facing & 3;
            if ((face & 1) != 0) {
                // Right (1) or left (3): hop while moving one tile.
                if ((face & 2) != 0) {
                    n.move_dir = 4; // left
                    n.facing = 3;
                } else {
                    n.move_dir = 2; // right
                    n.facing = 1;
                }
            } else {
                // Up/down: jump in place (no tile walk).
                n.move_dir = 0;
            }
        } else if (action == 0x0A) {
            // Spin only (@e444): $090c=$02, $0908=$40. Facing cycles via _00bdfe.
            if (n.isEventActive()) n.finishMove();
            n.jumping = false;
            n.spinning = true;
            n.move_dir = 0;
            n.move_px = 0;
            n.move_counter = 0;
            n.move_target = event_move_target;
            n.visible = true;
        } else if (action == 0x0B) {
            // Spin + jump (@e458): $090c=$03, $0908=$80. Facing via _00be06 + jump arc.
            if (n.isEventActive()) n.finishMove();
            n.jumping = true;
            n.spinning = true;
            n.move_dir = 0;
            n.move_px = 0;
            n.move_counter = 0;
            n.move_target = event_jump_target;
            n.visible = true;
        } else if (action >= 0x0C and action <= 0x0F) {
            // Special poses → $0909 = $05/$04/$06/$07 (same order as player $CA–$CD).
            if (n.isEventActive()) n.finishMove();
            n.facing = switch (action) {
                0x0C => 5, // hang-head / bow
                0x0D => 4, // arms / alternate
                0x0E => 6,
                else => 7,
            };
            n.visible = true;
            n.jumping = false;
            n.spinning = false;
        }
        self.rebuildOccupancy();
    }

    /// MoveNPCs one field: advance fine offsets + jump/spin counter; commit when done.
    /// Returns true if any NPC is still mid-walk/jump/spin (event should wait).
    pub fn tickMoves(self: *NpcSet) bool {
        var any = false;
        var moved = false;
        for (self.npcs) |*n| {
            // Active when walking, jump/spin in place, or any $0908 target.
            if (!n.isEventActive()) continue;
            any = true;
            // Event speed class 2 → counter +4; with @c045 gate always open → 1 px/frame.
            const spd: usize = 2;
            const step_px = move_px_per_frame[spd];
            const step_ctr = move_counter_step[spd];

            // MoveNPCs @c045: only step pixels when `$08ff & 3 == 0`.
            if (n.move_dir != 0 and (n.move_counter & 0x03) == 0) {
                switch (n.move_dir) {
                    1 => { // up
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.y > 0) n.y -= 1;
                            moved = true;
                        }
                    },
                    2 => { // right
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.x < 31) n.x += 1;
                            moved = true;
                        }
                    },
                    3 => { // down
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.y < 31) n.y += 1;
                            moved = true;
                        }
                    },
                    else => { // left
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.x > 0) n.x -= 1;
                            moved = true;
                        }
                    },
                }
            }

            // Always advance $08ff while a target is active (incl. jump/spin in place).
            if (n.move_target != 0) {
                n.move_counter +%= step_ctr;
                if (n.move_counter >= n.move_target) {
                    n.finishMove();
                    moved = true;
                }
            }
        }
        if (moved) self.rebuildOccupancy();
        return any;
    }

    /// True if any NPC is mid event-walk, jump, or spin ($0908 != 0 path).
    pub fn anyMoving(self: *const NpcSet) bool {
        for (self.npcs) |n| {
            if (n.isEventActive()) return true;
        }
        return false;
    }

    /// CheckMoveNPCs reverse facing: `((dir-1)+2)&3 + 1` (npc.asm @bf20).
    pub fn freeRoamReverseDir(dir: u8) u8 {
        if (dir == 0 or dir > 4) return 0;
        return (((dir -% 1) +% 2) & 3) +% 1;
    }

    /// Perpendicular pair for free-roam 50% turn (npc.asm @be7c / @bec2).
    /// N/S (odd dirs 1,3) → E/W (2,4); E/W → N/S.
    pub fn freeRoamPerpDirs(dir: u8) struct { a: u8, b: u8 } {
        if ((dir & 1) != 0) return .{ .a = 2, .b = 4 };
        return .{ .a = 1, .b = 3 };
    }

    /// CheckMoveNPCs + MoveNPCs free-roam subset (field/npc.asm @be0e / @c00c).
    /// Skips event-owned slots (`move_target != 0`). `z_key`/`can_enter` mirror
    /// `_00bfe3` equality + occupancy; `rng` supplies Rand for turns.
    ///
    /// Decomp timing (critical — missing gates make NPCs ~4× too fast / thrashy):
    /// - CheckMoveNPCs re-decides only when `($08ff & $7f) == 0` (@be33 bit6 clear + @be3d low6 0)
    /// - MoveNPCs steps pixels only when `($08ff & 3) == 0` (@c045)
    /// - `$08ff` advances by speed-class step every field (@c0e1), even while paused
    pub fn tickFreeRoam(
        self: *NpcSet,
        z_key: *const fn (*anyopaque, i32, i32) u8,
        z_ctx: *anyopaque,
        can_enter: *const fn (*anyopaque, i32, i32) bool,
        enter_ctx: *anyopaque,
        rng_next: *const fn (*anyopaque) u8,
        rng_ctx: *anyopaque,
    ) void {
        for (self.npcs) |*n| {
            if (!n.visible or !n.free_roam) continue;
            // Event choreography owns this slot while `$0908` target is set.
            if (n.move_target != 0 or n.jumping or n.spinning) continue;

            const spd: usize = @min(@as(usize, n.speed_class), 3);
            const step_px = move_px_per_frame[spd];
            const step_ctr = move_counter_step[spd];

            // CheckMoveNPCs @be33/@be3d: bit6 clear AND low 6 bits zero ⇒ & $7f == 0.
            if ((n.roam_counter & 0x7F) == 0) {
                self.pickFreeRoamDir(n, z_key, z_ctx, can_enter, enter_ctx, rng_next, rng_ctx);
            }

            // MoveNPCs @c027: `$0902` bit7 (paused) skips pixels — we use move_dir==0.
            // @c045: only step when `$08ff & 3 == 0`.
            if (n.move_dir != 0 and (n.roam_counter & 0x03) == 0) {
                switch (n.move_dir) {
                    1 => {
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.y > 0) n.y -= 1;
                        }
                    },
                    2 => {
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.x < 31) n.x += 1;
                        }
                    },
                    3 => {
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.y < 31) n.y += 1;
                        }
                    },
                    else => {
                        n.move_px +%= step_px;
                        if (n.move_px >= 16) {
                            n.move_px = 0;
                            if (n.x > 0) n.x -= 1;
                        }
                    },
                }
                // @bf96: facing from direction when nonzero.
                n.facing = n.move_dir -% 1;
            }

            // @c0ce: always advance `$08ff` (paused or moving).
            n.roam_counter +%= step_ctr;
        }
        // Always rebuild: free-roam may change facing/dir without a tile step,
        // and pause (move_dir→0) must put the body tile back under the sprite.
        self.rebuildOccupancy();
    }

    fn pickFreeRoamDir(
        self: *NpcSet,
        n: *Npc,
        z_key: *const fn (*anyopaque, i32, i32) u8,
        z_ctx: *anyopaque,
        can_enter: *const fn (*anyopaque, i32, i32) bool,
        enter_ctx: *anyopaque,
        rng_next: *const fn (*anyopaque) u8,
        rng_ctx: *anyopaque,
    ) void {
        const cur_z = z_key(z_ctx, n.x, n.y);
        var dir = n.move_dir;
        if (dir == 0 or dir > 4) dir = n.facing +% 1;
        if (dir == 0 or dir > 4) dir = 3; // default down

        // ~50%: try a perpendicular turn (CheckMoveNPCs @be7c).
        if (rng_next(rng_ctx) >= 0x80) {
            const perp = freeRoamPerpDirs(dir);
            const pick: u8 = if ((rng_next(rng_ctx) & 1) != 0) perp.a else perp.b;
            if (self.roamDestOk(n, pick, cur_z, z_key, z_ctx, can_enter, enter_ctx)) {
                n.move_dir = pick;
                return;
            }
        }

        // Keep current heading if dest ok.
        if (self.roamDestOk(n, dir, cur_z, z_key, z_ctx, can_enter, enter_ctx)) {
            n.move_dir = dir;
            return;
        }

        // Reverse: ((dir-1)+2)&3 + 1 (CheckMoveNPCs @bf20).
        const rev = freeRoamReverseDir(dir);
        if (self.roamDestOk(n, rev, cur_z, z_key, z_ctx, can_enter, enter_ctx)) {
            n.move_dir = rev;
            return;
        }

        // Blocked: pause (ROM sets `$0902` bit7 — we zero move for this tile window).
        n.move_dir = 0;
    }

    fn roamDestOk(
        self: *const NpcSet,
        n: *const Npc,
        dir: u8,
        cur_z: u8,
        z_key: *const fn (*anyopaque, i32, i32) u8,
        z_ctx: *anyopaque,
        can_enter: *const fn (*anyopaque, i32, i32) bool,
        enter_ctx: *anyopaque,
    ) bool {
        const d = dirDelta(dir);
        const tx = @as(i32, n.x) + d.dx;
        const ty = @as(i32, n.y) + d.dy;
        if (tx < 0 or ty < 0 or tx >= map_w or ty >= map_h) return false;
        if (z_key(z_ctx, tx, ty) != cur_z) return false;
        if (!can_enter(enter_ctx, tx, ty)) return false;
        // Occupied by another NPC or player marker.
        if (self.occupiedByNpc(tx, ty)) return false;
        const idx = @as(usize, @intCast(ty)) * map_w + @as(usize, @intCast(tx));
        if (self.occ[idx] == 0xFF) return false;
        return true;
    }

    /// Refresh visibility from NPC switches (after F4/F5 without full reload).
    /// Matches InitNPCs CheckNPCSwitch → $090b: bit set = drawn, clear = hidden.
    pub fn refreshVisibility(self: *NpcSet, npc_switches: []const u8, map_high: bool) void {
        for (self.npcs) |*n| {
            // Switch is authoritative for prop/crystal/door slots after F4/F5.
            n.visible = npcSwitchOn(npc_switches, n.prop_gfx, map_high);
        }
        self.rebuildOccupancy();
    }

    /// Hide every NPC whose prop id matches (EventCmd_f5 crystal/door path).
    pub fn setVisibleByPropId(self: *NpcSet, prop_id: u8, visible: bool) void {
        for (self.npcs) |*n| {
            if (n.prop_gfx == prop_id) n.visible = visible;
        }
        self.rebuildOccupancy();
    }

    pub fn findFacing(self: *const NpcSet, px: i32, py: i32, facing: u8) ?usize {
        // $1705 may hold special poses 4–7; collision/talk uses cardinal only.
        const d: [2]i32 = switch (facing & 3) {
            0 => .{ 0, -1 },
            1 => .{ 1, 0 },
            2 => .{ 0, 1 },
            else => .{ -1, 0 },
        };
        const tx = px + d[0];
        const ty = py + d[1];
        for (self.npcs, 0..) |n, i| {
            // Door/effect NPCs (empty graphics) still block / can be talked to.
            if (n.visible and n.x == tx and n.y == ty) return i;
        }
        return null;
    }
};

/// InitNPCs: movement type from sheet id size class.
fn moveTypeForSheet(sheet: u8) u8 {
    if (sheet < 0x2E) return 0;
    if (sheet < 0x30) return 3;
    if (sheet < 0x46) return 2;
    return 1;
}

/// ROM spacing between successive sheet ids → tile count.
///   $00–$10: 32 tiles (8 poses)  $11–$2F: 16 (4 poses)
///   $30–$45:  8 tiles (2 poses)  $46+   :  4 (1 pose)
fn tilesForSheet(sheet: u8) u8 {
    if (sheet < 0x11) return 32;
    if (sheet < 0x30) return 16;
    if (sheet < 0x46) return 8;
    return 4;
}

/// Load one 8-color MapSpritePal entry into `out`.
fn loadMapSpritePal(r: *const rom_mod.Rom, pal_index: usize, out: *[8]snes.Color) void {
    const off = map_sprite_pal + pal_index * pal_bytes;
    const raw = r.slice(off, pal_bytes) catch {
        @memset(out, snes.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        return;
    };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const w = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
        out[i] = snes.Color.fromSnes(w);
    }
    out[0].a = 0;
}

/// LoadNPCPal: two sets of 2 palettes from MapSpritePal+13×16.
/// Low nibble of map_npc_pal → slots 0–1; high nibble → slots 2–3.
fn loadMapNpcPals(r: *const rom_mod.Rom, map_npc_pal: u8, out: *[4][8]snes.Color) void {
    const lo: usize = map_npc_pal & 0x0F;
    const hi: usize = map_npc_pal >> 4;
    // Each LoadNPCPal(A) starts at (13 + A*2) — A*32 bytes = A*2 palettes of 16 bytes.
    loadPalPair(r, npc_pal_base_index + lo * 2, out, 0);
    loadPalPair(r, npc_pal_base_index + hi * 2, out, 2);
}

fn loadPalPair(r: *const rom_mod.Rom, start_pal: usize, out: *[4][8]snes.Color, slot0: usize) void {
    var s: usize = 0;
    while (s < 2) : (s += 1) {
        const pi = start_pal + s;
        const off = map_sprite_pal + pi * pal_bytes;
        const raw = r.slice(off, pal_bytes) catch {
            @memset(&out[slot0 + s], snes.Color{ .r = 255, .g = 0, .b = 255, .a = 255 });
            continue;
        };
        var c: usize = 0;
        while (c < 8) : (c += 1) {
            const w = std.mem.readInt(u16, raw[c * 2 ..][0..2], .little);
            out[slot0 + s][c] = snes.Color.fromSnes(w);
            out[slot0 + s][c].a = 255;
        }
        out[slot0 + s][0].a = 0;
    }
}

fn npcSwitchOn(switches: []const u8, id: u8, map_high: bool) bool {
    var byte_i: usize = id >> 3;
    if (map_high) byte_i += 0x20;
    if (byte_i >= switches.len) return false;
    const bit: u3 = @truncate(id & 7);
    return (switches[byte_i] & (@as(u8, 1) << bit)) != 0;
}

fn spriteRomOffset(sheet_id: u8) usize {
    const v: u16 = if (sheet_id < 0x11)
        @as(u16, sheet_id) *% 8
    else if (sheet_id < 0x30)
        @as(u16, sheet_id -% 0x11) *% 4
    else if (sheet_id < 0x46)
        @as(u16, sheet_id -% 0x30) *% 2
    else
        sheet_id -% 0x46;
    const base: u16 = if (sheet_id < 0x11)
        0
    else if (sheet_id < 0x30)
        0x3300
    else if (sheet_id < 0x46)
        0x6180
    else
        0x7200;

    var a: u16 = @as(u16, v & 0xFF) << 8;
    a >>= 2;
    const t4a = a;
    a = (a >> 1) +% t4a +% base +% 0x8000;
    return rom_mod.Rom.loromOffset((@as(u24, 0x1B) << 16) | a);
}

fn loadSheetTiles(r: *const rom_mod.Rom, sheet_id: u8, npc: *Npc) !void {
    const n = tilesForSheet(sheet_id);
    const off = spriteRomOffset(sheet_id);
    const raw = try r.slice(off, @as(usize, n) * 24);
    var t: usize = 0;
    while (t < n) : (t += 1) {
        decode3bpp(raw[t * 24 ..][0..24], &npc.tiles[t]);
    }
    npc.tile_count = n;
    npc.pose_count = n / 4;
}

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

/// Pose layout matching PlayerSpriteTiles @c0c4 / DrawNPCs facing×walk index.
/// Facing 0–3 = cardinal walk; 4–7 = special cutscene poses (tiles $10–$1F on 8-pose sheets).
///
/// `full_sheet`: true when sheet has ≥32 tiles (MapSpriteGfx $00–$10 party/armor class).
/// Townsfolk (16 tiles) fall back to cardinal rows for special facings.
fn poseCorners(facing: u8, walk_frame: u8, full_sheet: bool) [4]Corner {
    if (facing >= 4 and facing <= 7) {
        if (full_sheet) {
            // PlayerSpriteTiles special poses ($1705 = 4–7 → tile bases $14/$18/$10/$1C).
            const f = walk_frame & 1;
            const base: u8 = switch (facing) {
                4 => if (f != 0) 0x18 else 0x14, // arms / alternate walk frame
                5 => 0x18, // hang-head / bow
                6 => 0x10,
                else => 0x1C,
            };
            return .{
                .{ .tile = base + 0, .hflip = false },
                .{ .tile = base + 1, .hflip = false },
                .{ .tile = base + 2, .hflip = false },
                .{ .tile = base + 3, .hflip = false },
            };
        }
        // 4-pose sheets: map specials onto cardinal rows (down for hang-head).
        const row: u8 = switch (facing) {
            4 => 0,
            5 => 2,
            6 => 1,
            else => 3,
        };
        return poseCorners(row, 0, false);
    }
    const f = walk_frame & 1;
    return switch (facing & 3) {
        0 => if (f == 0)
            .{
                .{ .tile = 4, .hflip = false },
                .{ .tile = 5, .hflip = false },
                .{ .tile = 6, .hflip = false },
                .{ .tile = 7, .hflip = false },
            }
        else
            .{
                .{ .tile = 4, .hflip = false },
                .{ .tile = 5, .hflip = false },
                .{ .tile = 7, .hflip = true },
                .{ .tile = 6, .hflip = true },
            },
        1 => if (f == 0)
            .{
                .{ .tile = 9, .hflip = true },
                .{ .tile = 8, .hflip = true },
                .{ .tile = 11, .hflip = true },
                .{ .tile = 10, .hflip = true },
            }
        else
            .{
                .{ .tile = 13, .hflip = true },
                .{ .tile = 12, .hflip = true },
                .{ .tile = 15, .hflip = true },
                .{ .tile = 14, .hflip = true },
            },
        2 => if (f == 0)
            .{
                .{ .tile = 0, .hflip = false },
                .{ .tile = 1, .hflip = false },
                .{ .tile = 2, .hflip = false },
                .{ .tile = 3, .hflip = false },
            }
        else
            .{
                .{ .tile = 0, .hflip = false },
                .{ .tile = 1, .hflip = false },
                .{ .tile = 3, .hflip = true },
                .{ .tile = 2, .hflip = true },
            },
        else => if (f == 0)
            .{
                .{ .tile = 8, .hflip = false },
                .{ .tile = 9, .hflip = false },
                .{ .tile = 10, .hflip = false },
                .{ .tile = 11, .hflip = false },
            }
        else
            .{
                .{ .tile = 12, .hflip = false },
                .{ .tile = 13, .hflip = false },
                .{ .tile = 14, .hflip = false },
                .{ .tile = 15, .hflip = false },
            },
    };
}

/// DrawNPCs walk/effect frame from `$7a` (`and #$10 / lsr4` → 0 or 1).
fn frame01From7a(snes_7a: u8) u8 {
    return (snes_7a >> 4) & 1;
}

/// Pick pose index 0 .. pose_count-1 from `$7a` (2-pose sheets use bit4 like walk).
fn multiPoseIndex(snes_7a: u8, pose_count: u8) u8 {
    if (pose_count <= 1) return 0;
    if (pose_count == 2) return frame01From7a(snes_7a);
    // 4 poses: use bits 3–4 of $7a (period 32 fields).
    return (snes_7a >> 3) & 3;
}

/// Draw one NPC. `hide_lower`: MapTileProp hi bit3 / `$090a` — skip bottom 8px
/// (DrawNPCs @bcec sets lower OAM Y to $f8).
pub fn blitNpc(dest: []u8, dest_w: usize, dx: i32, dy: i32, npc: Npc, snes_7a: u8, hide_lower: bool) void {
    if (npc.tile_count == 0 or npc.pose_count == 0) return;

    // Jump arc: subtract NPCJumpYTbl lift from screen Y (DrawNPCs @bc5c, $090c bit0).
    const draw_dy = dy - npc.jumpY();

    // 8-pose party/armor sheets (32 tiles) use PlayerSpriteTiles special rows.
    const full_sheet = npc.tile_count >= 32;

    // move_type 0 (sheets <$2E): facing × walk layout (16/32-tile humanoids).
    // move_type ≠ 0: sequential 16×16 poses (zzz=2, school FX=2, doors=1).
    const corners: [4]Corner = blk: {
        if (npc.move_type == 0) {
            // Spin overrides facing from _00bdfe / _00be06; walk frame forced to 0 (@bbf8).
            if (npc.spinning) {
                break :blk poseCorners(npc.spinFacing(), 0, full_sheet);
            }
            const wf: u8 = if (npc.move_dir != 0 or npc.walk_idle) frame01From7a(snes_7a) else 0;
            break :blk poseCorners(npc.facing, wf, full_sheet);
        }
        // Special facing 4–7 on multi-pose sheets: pick pose row directly.
        const pose: u8 = if (npc.facing >= 4)
            @min(npc.facing -% 4, npc.pose_count -% 1)
        else if (npc.walk_idle)
            multiPoseIndex(snes_7a, npc.pose_count)
        else
            0;
        const p = @min(pose, npc.pose_count -% 1);
        const base: u8 = p *% 4;
        break :blk .{
            .{ .tile = base + 0, .hflip = false },
            .{ .tile = base + 1, .hflip = false },
            .{ .tile = base + 2, .hflip = false },
            .{ .tile = base + 3, .hflip = false },
        };
    };

    // SNES: only color 0 is transparent. Effect sheets (zzz, etc.) often store
    // pure black in slot 1 as well; drawing it opaque boxed the bubbles.
    const skip_black1 = npc.move_type != 0 and paletteSlotIsBlack(npc.pal[1]);

    const offsets = [_]struct { x: i32, y: i32 }{
        .{ .x = 0, .y = 0 },
        .{ .x = 8, .y = 0 },
        .{ .x = 0, .y = 8 },
        .{ .x = 8, .y = 8 },
    };
    for (corners, offsets, 0..) |c, off, i| {
        // Lower two corners (i=2,3) hidden when $090a set.
        if (hide_lower and i >= 2) continue;
        if (c.tile >= npc.tile_count) continue;
        blitTile8(dest, dest_w, dx + off.x, draw_dy + off.y, &npc.tiles[c.tile], &npc.pal, c.hflip, c.vflip, skip_black1);
    }
}

fn paletteSlotIsBlack(c: snes.Color) bool {
    return c.r == 0 and c.g == 0 and c.b == 0;
}

fn blitTile8(
    dest: []u8,
    dest_w: usize,
    dx: i32,
    dy: i32,
    indices: *const [64]u8,
    palette: *const [8]snes.Color,
    hflip: bool,
    vflip: bool,
    skip_black1: bool,
) void {
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            const sx: usize = if (hflip) 7 - col else col;
            const sy: usize = if (vflip) 7 - row else row;
            const idx = indices[sy * 8 + sx];
            if (idx == 0) continue;
            if (skip_black1 and idx == 1) continue;
            const px = dx + @as(i32, @intCast(col));
            const py = dy + @as(i32, @intCast(row));
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            const dh = dest.len / (dest_w * 4);
            if (ux >= dest_w or uy >= dh) continue;
            const c = palette[idx % 8];
            if (c.a == 0) continue;
            const o = (uy * dest_w + ux) * 4;
            dest[o] = c.r;
            dest[o + 1] = c.g;
            dest[o + 2] = c.b;
            dest[o + 3] = 255;
        }
    }
}

/// Resolve talk text: NPC script → event → dialogue.
pub fn talkText(r: *const rom_mod.Rom, npc: Npc, map_id: u16, event_switches: []const u8, buf: []u8) []const u8 {
    if (resolveDialogue(r, npc.prop_gfx, map_id, event_switches, buf)) |s| {
        if (s.len > 0) return s;
    } else |_| {}
    const fallback = "....";
    const n = @min(fallback.len, buf.len);
    @memcpy(buf[0..n], fallback[0..n]);
    return buf[0..n];
}

/// Collect distinct non-empty dialogue lines from every NPC currently on the map.
/// Authoritative ROM corpus for "what people here actually say" (no invented greeter tone).
/// Writes into `buf`; returns the filled slice. Skips "...." and duplicates.
pub fn formatMapDialogueCorpus(
    r: *const rom_mod.Rom,
    npcs: []const Npc,
    map_id: u16,
    event_switches: []const u8,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;
    var count: usize = 0;
    const max_lines: usize = 14;
    var line_buf: [256]u8 = undefined;
    // Simple duplicate filter on first 48 chars of each accepted line.
    var seen: [max_lines][48]u8 = undefined;
    var seen_n: usize = 0;

    for (npcs) |n| {
        if (count >= max_lines) break;
        if (!n.visible or !n.canVoiceChat()) continue;
        const raw = talkText(r, n, map_id, event_switches, &line_buf);
        if (raw.len == 0 or std.mem.eql(u8, raw, "....")) continue;
        // Collapse newlines to spaces for a compact card line.
        var flat: [200]u8 = undefined;
        var fl: usize = 0;
        for (raw) |c| {
            if (fl >= flat.len) break;
            if (c == '\n' or c == '\r') {
                if (fl > 0 and flat[fl - 1] != ' ') {
                    flat[fl] = ' ';
                    fl += 1;
                }
            } else {
                flat[fl] = c;
                fl += 1;
            }
        }
        // Trim trailing space
        while (fl > 0 and flat[fl - 1] == ' ') fl -= 1;
        if (fl == 0) continue;
        const line = flat[0..fl];

        const key_len = @min(line.len, 48);
        var dup = false;
        for (seen[0..seen_n]) |s| {
            if (std.mem.eql(u8, s[0..key_len], line[0..key_len])) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_n < max_lines) {
            @memset(&seen[seen_n], 0);
            @memcpy(seen[seen_n][0..key_len], line[0..key_len]);
            seen_n += 1;
        }

        // Format: - "line…"
        const prefix = "- \"";
        const suffix = "\"\n";
        const need = prefix.len + line.len + suffix.len;
        if (pos + need > buf.len) break;
        @memcpy(buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        @memcpy(buf[pos..][0..line.len], line);
        pos += line.len;
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        count += 1;
    }
    return buf[0..pos];
}

fn resolveDialogue(r: *const rom_mod.Rom, script_id: u8, map_id: u16, switches: []const u8, buf: []u8) ![]const u8 {
    const idx: usize = @as(usize, script_id) * 2;
    const start_rel = try r.readU16Le(npc_script_ptrs + idx);
    const end_rel = try r.readU16Le(npc_script_ptrs + idx + 2);
    const start = npc_script_data + start_rel;
    const end = npc_script_data + end_rel;
    if (end <= start) return error.BadScript;

    var dlg_table: [32]u8 = .{0} ** 32;
    var dlg_n: usize = 0;
    var last_ff: ?usize = null;
    var p = start;
    while (p < end) : (p += 1) {
        if ((try r.readU8(p)) == 0xFF) last_ff = p;
    }
    if (last_ff) |ff| {
        var q = ff + 1;
        while (q < end and dlg_n < dlg_table.len) : (q += 1) {
            dlg_table[dlg_n] = try r.readU8(q);
            dlg_n += 1;
        }
    }

    var bc = start;
    while (bc < end) {
        const b = try r.readU8(bc);
        if (b == 0xFF) {
            if (bc + 1 < end) {
                const event_id = try r.readU8(bc + 1);
                if (event_id != 0) {
                    if (scanEventForDialogue(r, event_id, map_id, dlg_table[0..dlg_n], buf)) |s| return s;
                }
            }
            break;
        }
        if (b == 0xFE) {
            if (bc + 1 >= end) break;
            const sw = try r.readU8(bc + 1);
            if (!switchSet(switches, sw)) {
                bc = try skipFailedEntry(r, bc, end);
                continue;
            }
            bc += 2;
            continue;
        }
        if (switchSet(switches, b)) {
            bc = try skipFailedEntry(r, bc, end);
            continue;
        }
        bc += 1;
    }

    return error.NoDialogue;
}

fn switchSet(switches: []const u8, id: u8) bool {
    const byte_i = id >> 3;
    const bit: u3 = @truncate(id & 7);
    if (byte_i >= switches.len) return false;
    return (switches[byte_i] & (@as(u8, 1) << bit)) != 0;
}

fn skipFailedEntry(r: *const rom_mod.Rom, from: usize, end: usize) !usize {
    var p = from + 1;
    while (p < end) : (p += 1) {
        if ((try r.readU8(p)) == 0xFF) {
            p += 1;
            if (p < end) p += 1;
            return p;
        }
    }
    return end;
}

const DlgBank = enum { map, event1, event2 };

fn eventCmdLen(cmd: u8) u8 {
    return switch (cmd) {
        0xFF => 1,
        0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA => 1,
        0xE2, 0xEB => 3,
        0xFE => 5,
        0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD => 2,
        else => 1,
    };
}

fn scanEventForDialogue(
    r: *const rom_mod.Rom,
    event_id: u8,
    map_id: u16,
    dlg_table: []const u8,
    buf: []u8,
) ?[]const u8 {
    const start_rel = r.readU16Le(event_script_ptrs + @as(usize, event_id) * 2) catch return null;
    const end_rel = r.readU16Le(event_script_ptrs + @as(usize, event_id) * 2 + 2) catch start_rel +% 64;
    const start = event_script_data + start_rel;
    var end = event_script_data + end_rel;
    if (end <= start) end = start + 64;

    var pos = start;
    while (pos < end) {
        const cmd = r.readU8(pos) catch break;
        if (cmd == 0xFF) break;
        if (cmd == 0xEF) {
            const page = r.readU8(pos + 1) catch break;
            if (loadMapDialoguePage(r, map_id, page, buf)) |s| {
                if (s.len > 0) return s;
            } else |_| {}
            pos += 2;
            continue;
        }
        if (cmd == 0xEE) {
            const tidx = r.readU8(pos + 1) catch break;
            if (tidx < dlg_table.len) {
                if (loadMapDialoguePage(r, map_id, dlg_table[tidx], buf)) |s| {
                    if (s.len > 0) return s;
                } else |_| {}
            }
            pos += 2;
            continue;
        }
        if (cmd == 0xF0) {
            const id = r.readU8(pos + 1) catch break;
            if (loadEventDialogue(r, .event1, id, buf)) |s| {
                if (s.len > 0) return s;
            } else |_| {}
            pos += 2;
            continue;
        }
        if (cmd == 0xF1) {
            const id = r.readU8(pos + 1) catch break;
            if (loadEventDialogue(r, .event1, @as(u16, id) + 256, buf)) |s| {
                if (s.len > 0) return s;
            } else |_| {}
            pos += 2;
            continue;
        }
        if (cmd == 0xF6) {
            const id = r.readU8(pos + 1) catch break;
            if (loadEventDialogue(r, .event2, id, buf)) |s| {
                if (s.len > 0) return s;
            } else |_| {}
            pos += 2;
            continue;
        }
        if (cmd == 0xF8) {
            const id = r.readU8(pos + 1) catch break;
            if (loadEventDialogue(r, .event1, @as(u16, id) + 256, buf)) |s| {
                if (s.len > 0) return s;
            } else |_| {}
            pos += 2;
            continue;
        }
        pos += eventCmdLen(cmd);
    }
    return null;
}

fn loadMapDialoguePage(r: *const rom_mod.Rom, map_id: u16, page: u8, buf: []u8) ![]const u8 {
    if (map_id >= 0x180) return error.BadId;
    const ptr = try r.readU16Le(map_dlg_ptrs + @as(usize, map_id) * 2);
    var pos = map_dlg_data + ptr;
    var remaining: u8 = page;
    while (remaining > 0) {
        const b = try r.readU8(pos);
        pos += 1;
        if (b == 0x00) {
            if (pos >= map_dlg_data + 2) {
                const prev = try r.readU8(pos - 2);
                if (prev == 0x03 or prev == 0x04) continue;
            }
            remaining -= 1;
            continue;
        }
    }
    return decodeDialogueBytes(r, pos, buf);
}

fn loadEventDialogue(r: *const rom_mod.Rom, bank: DlgBank, id: u16, buf: []u8) ![]const u8 {
    const ptrs_base: usize = switch (bank) {
        .map => map_dlg_ptrs,
        .event1 => event_dlg1_ptrs,
        .event2 => event_dlg2_ptrs,
    };
    const data_base: usize = switch (bank) {
        .map => map_dlg_data,
        .event1 => event_dlg1_data,
        .event2 => event_dlg2_data,
    };
    const max_id: u16 = switch (bank) {
        .map => 0x180,
        .event1 => 0x200,
        .event2 => 0x100,
    };
    if (id >= max_id) return error.BadId;
    const ptr = try r.readU16Le(ptrs_base + @as(usize, id) * 2);
    return decodeDialogueBytes(r, data_base + ptr, buf);
}

fn decodeDialogueBytes(r: *const rom_mod.Rom, start_pos: usize, buf: []u8) ![]const u8 {
    var pos = start_pos;
    const dte = try r.slice(dte_table, 0x100);
    var out_i: usize = 0;
    while (out_i + 4 < buf.len) {
        const b = try r.readU8(pos);
        pos += 1;
        if (b == 0x00 or b == 0x06) break;
        if (b == 0x01 or b == 0x09) {
            if (out_i > 0 and buf[out_i - 1] != '\n') {
                buf[out_i] = '\n';
                out_i += 1;
            }
            continue;
        }
        if (b == 0x02) {
            const n = try r.readU8(pos);
            pos += 1;
            var i: u8 = 0;
            while (i < n and out_i < buf.len) : (i += 1) {
                buf[out_i] = ' ';
                out_i += 1;
            }
            continue;
        }
        if (b == 0x03 or b == 0x05) {
            pos += 1;
            continue;
        }
        // TextCmd_04: character name — next byte is CharacterName slot ($1500 index).
        // window.asm @b308: slot * 6 → copy up to 6 letters (stop at $FF).
        if (b == 0x04) {
            const slot = try r.readU8(pos);
            pos += 1;
            var nbuf: [8]u8 = undefined;
            const name = text_mod.decodeCharNameSlot(r.data, slot, &nbuf);
            const n = @min(name.len, buf.len - out_i);
            @memcpy(buf[out_i..][0..n], name[0..n]);
            out_i += n;
            continue;
        }
        if (b == 0xFF) {
            buf[out_i] = ' ';
            out_i += 1;
            continue;
        }
        if ((b >= 0x8A and b < 0xC0) or (b >= 0xCA and b <= 0xFD)) {
            const di: usize = (@as(usize, b) -% 0x80) * 2;
            if (di + 1 < dte.len) {
                if (decodeChar(dte[di])) |ch| {
                    buf[out_i] = ch;
                    out_i += 1;
                }
                if (out_i < buf.len) {
                    if (decodeChar(dte[di + 1])) |ch| {
                        buf[out_i] = ch;
                        out_i += 1;
                    }
                }
            }
            continue;
        }
        if (decodeChar(b)) |ch| {
            buf[out_i] = ch;
            out_i += 1;
        }
    }
    while (out_i > 0 and (buf[out_i - 1] == ' ' or buf[out_i - 1] == '\n')) out_i -= 1;
    return buf[0..out_i];
}

fn decodeChar(b: u8) ?u8 {
    return switch (b) {
        0x42...0x5B => 'A' + (b - 0x42),
        0x5C...0x75 => 'a' + (b - 0x5C),
        0x80...0x89 => '0' + (b - 0x80),
        0xC0 => '\'',
        0xC1 => '.',
        0xC2 => '-',
        0xC3 => '.',
        0xC4 => '!',
        0xC5 => '?',
        0xC6 => '%',
        0xC7 => '/',
        0xC8 => ':',
        0xC9 => ',',
        0xFF => ' ',
        else => null,
    };
}

// --- Event actor opcodes 0–F (EventCmd_e9 / applyEventOpcode) ---

test "applyEventOpcode walk face jump spin special 0-F" {
    const gpa = std.testing.allocator;
    var npcs = try gpa.alloc(Npc, 1);
    defer gpa.free(npcs);
    npcs[0] = .{
        .prop_gfx = 0,
        .sheet_id = 0,
        .x = 5,
        .y = 5,
        .facing = 0,
        .walk_idle = false,
        .pal_slot = 0,
        .move_type = 0,
        .visible = true,
    };
    var set: NpcSet = .{
        .npcs = npcs,
        .allocator = gpa,
    };
    // Slot 0, action 2 = walk down
    set.applyEventOpcode(0x02);
    try std.testing.expectEqual(@as(u8, 3), set.npcs[0].move_dir); // down
    try std.testing.expectEqual(@as(u8, 2), set.npcs[0].facing);
    try std.testing.expect(set.npcs[0].isEventActive());

    // Face left (action 7)
    set.applyEventOpcode(0x07);
    try std.testing.expectEqual(@as(u8, 3), set.npcs[0].facing);
    try std.testing.expectEqual(@as(u8, 0), set.npcs[0].move_dir);

    // Toggle visibility (8)
    set.applyEventOpcode(0x08);
    try std.testing.expect(!set.npcs[0].visible);
    set.applyEventOpcode(0x08);
    try std.testing.expect(set.npcs[0].visible);

    // Jump (9)
    set.npcs[0].facing = 1; // right → hop walk
    set.applyEventOpcode(0x09);
    try std.testing.expect(set.npcs[0].jumping);
    try std.testing.expectEqual(@as(u8, 2), set.npcs[0].move_dir);

    // Spin (A)
    set.applyEventOpcode(0x0A);
    try std.testing.expect(set.npcs[0].spinning);
    try std.testing.expect(!set.npcs[0].jumping);

    // Spin+jump (B)
    set.applyEventOpcode(0x0B);
    try std.testing.expect(set.npcs[0].spinning);
    try std.testing.expect(set.npcs[0].jumping);

    // Special poses C–F → facing 5/4/6/7
    set.applyEventOpcode(0x0C);
    try std.testing.expectEqual(@as(u8, 5), set.npcs[0].facing);
    set.applyEventOpcode(0x0D);
    try std.testing.expectEqual(@as(u8, 4), set.npcs[0].facing);
    set.applyEventOpcode(0x0E);
    try std.testing.expectEqual(@as(u8, 6), set.npcs[0].facing);
    set.applyEventOpcode(0x0F);
    try std.testing.expectEqual(@as(u8, 7), set.npcs[0].facing);
}

test "freeRoam reverse and perp dirs CheckMoveNPCs" {
    try std.testing.expectEqual(@as(u8, 3), NpcSet.freeRoamReverseDir(1)); // N→S
    try std.testing.expectEqual(@as(u8, 4), NpcSet.freeRoamReverseDir(2)); // E→W
    try std.testing.expectEqual(@as(u8, 1), NpcSet.freeRoamReverseDir(3)); // S→N
    try std.testing.expectEqual(@as(u8, 2), NpcSet.freeRoamReverseDir(4)); // W→E
    const ns = NpcSet.freeRoamPerpDirs(1);
    try std.testing.expectEqual(@as(u8, 2), ns.a);
    try std.testing.expectEqual(@as(u8, 4), ns.b);
    const ew = NpcSet.freeRoamPerpDirs(2);
    try std.testing.expectEqual(@as(u8, 1), ew.a);
    try std.testing.expectEqual(@as(u8, 3), ew.b);
}

test "tickFreeRoam event ownership skips free-roam" {
    const gpa = std.testing.allocator;
    var npcs = try gpa.alloc(Npc, 1);
    defer gpa.free(npcs);
    npcs[0] = .{
        .prop_gfx = 0,
        .sheet_id = 0,
        .x = 5,
        .y = 5,
        .facing = 0,
        .walk_idle = false,
        .pal_slot = 0,
        .move_type = 0,
        .visible = true,
        .free_roam = true,
        .move_target = 0x40, // event walk owns slot
        .move_dir = 2,
    };
    var set: NpcSet = .{ .npcs = npcs, .allocator = gpa };
    const Ctx = struct {
        fn z(_: *anyopaque, _: i32, _: i32) u8 {
            return 0;
        }
        fn enter(_: *anyopaque, _: i32, _: i32) bool {
            return true;
        }
        fn rng(_: *anyopaque) u8 {
            return 0; // always keep heading path
        }
    };
    var dummy: u8 = 0;
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    // Event-owned: dir unchanged, no tile step from free-roam
    try std.testing.expectEqual(@as(u8, 2), set.npcs[0].move_dir);
    try std.testing.expectEqual(@as(u8, 5), set.npcs[0].x);
}

// Free-roamers keep move_dir set as walk intent; body tile must stay solid.
test "rebuildOccupancy free-roam body solid, dest only mid-step" {
    const gpa = std.testing.allocator;
    var npcs = try gpa.alloc(Npc, 1);
    defer gpa.free(npcs);
    npcs[0] = .{
        .prop_gfx = 0,
        .sheet_id = 0,
        .x = 5,
        .y = 5,
        .facing = 1,
        .walk_idle = false,
        .pal_slot = 0,
        .move_type = 0,
        .visible = true,
        .free_roam = true,
        .move_dir = 2, // facing/walking right
        .move_px = 0, // at rest on tile
    };
    var set: NpcSet = .{ .npcs = npcs, .allocator = gpa };
    set.rebuildOccupancy();
    // Body occupied
    try std.testing.expect(set.occupiedByNpc(5, 5));
    // Tile in front must NOT be a phantom block while at rest
    try std.testing.expect(!set.occupiedByNpc(6, 5));

    // Mid-step: reserve destination too
    set.npcs[0].move_px = 8;
    set.rebuildOccupancy();
    try std.testing.expect(set.occupiedByNpc(5, 5));
    try std.testing.expect(set.occupiedByNpc(6, 5));
}

// MoveNPCs @c045: class-0 free-roam is 1px only when `$08ff&3==0` → 64 fields/tile.
test "tickFreeRoam speed 0 is 1px per 4 fields (decomp @c045)" {
    const gpa = std.testing.allocator;
    var npcs = try gpa.alloc(Npc, 1);
    defer gpa.free(npcs);
    npcs[0] = .{
        .prop_gfx = 0,
        .sheet_id = 0,
        .x = 5,
        .y = 5,
        .facing = 1, // right
        .walk_idle = false,
        .pal_slot = 0,
        .move_type = 0,
        .visible = true,
        .free_roam = true,
        .speed_class = 0,
        .move_dir = 2, // right
        .roam_counter = 1, // avoid re-decide (needs &7f==0)
    };
    var set: NpcSet = .{ .npcs = npcs, .allocator = gpa };
    const Ctx = struct {
        fn z(_: *anyopaque, _: i32, _: i32) u8 {
            return 0;
        }
        fn enter(_: *anyopaque, _: i32, _: i32) bool {
            return true;
        }
        fn rng(_: *anyopaque) u8 {
            return 0; // keep heading (< $80 → no perp try)
        }
    };
    var dummy: u8 = 0;

    // Frame with counter=1: no pixel step (&3!=0), counter → 2
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    try std.testing.expectEqual(@as(u8, 0), set.npcs[0].move_px);
    try std.testing.expectEqual(@as(u8, 2), set.npcs[0].roam_counter);

    // counter=2,3: still no step
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    try std.testing.expectEqual(@as(u8, 0), set.npcs[0].move_px);
    try std.testing.expectEqual(@as(u8, 4), set.npcs[0].roam_counter);

    // counter=4 (&3==0): +1 px
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    try std.testing.expectEqual(@as(u8, 1), set.npcs[0].move_px);
    try std.testing.expectEqual(@as(u8, 5), set.npcs[0].x); // still same tile

    // 15 more pixel steps (every 4 fields) → one tile right
    var frames: usize = 0;
    while (set.npcs[0].x == 5 and frames < 200) : (frames += 1) {
        set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    }
    try std.testing.expectEqual(@as(u8, 6), set.npcs[0].x);
    // 15 remaining px × 4 fields = 60, plus the one step already done before loop setup;
    // from px=1, need 15 more steps = 60 frames after the first step at counter=4.
    try std.testing.expectEqual(@as(usize, 60), frames);
}

// CheckMoveNPCs re-decides only every 128 counter units (`& $7f == 0`), not 64.
test "tickFreeRoam re-decide gate is every 128 counter units" {
    const gpa = std.testing.allocator;
    var npcs = try gpa.alloc(Npc, 1);
    defer gpa.free(npcs);
    npcs[0] = .{
        .prop_gfx = 0,
        .sheet_id = 0,
        .x = 10,
        .y = 10,
        .facing = 2,
        .walk_idle = false,
        .pal_slot = 0,
        .move_type = 0,
        .visible = true,
        .free_roam = true,
        .speed_class = 0,
        .move_dir = 3, // down
        .roam_counter = 64, // bit6 set — must NOT re-decide
    };
    var set: NpcSet = .{ .npcs = npcs, .allocator = gpa };
    // RNG always requests a perp turn to east if re-decide runs.
    const Ctx = struct {
        fn z(_: *anyopaque, _: i32, _: i32) u8 {
            return 0;
        }
        fn enter(_: *anyopaque, _: i32, _: i32) bool {
            return true;
        }
        fn rng(_: *anyopaque) u8 {
            return 0xFF; // >= $80 → try perp
        }
    };
    var dummy: u8 = 0;
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    // At counter 64: no re-decide; still heading down.
    try std.testing.expectEqual(@as(u8, 3), set.npcs[0].move_dir);
    try std.testing.expectEqual(@as(u8, 65), set.npcs[0].roam_counter);

    // Advance to counter 128 without changing dir via blocked paths: force counter.
    set.npcs[0].roam_counter = 128;
    set.npcs[0].move_dir = 3;
    set.tickFreeRoam(Ctx.z, &dummy, Ctx.enter, &dummy, Ctx.rng, &dummy);
    // Re-decide fires; rng >= $80 picks perp (E/W). Not still forced to 3 only.
    // (May be 2 or 4 depending on second rng bit — both are perp to S.)
    const d = set.npcs[0].move_dir;
    try std.testing.expect(d == 2 or d == 4);
}
