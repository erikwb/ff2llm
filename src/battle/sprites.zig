//! Battle sprite loaders — ports of btlgfx/ppu.asm LoadMonsterGfx / InitCharGfx
//! and LoadBattleBGGfx + LoadBattleBGTiles (tile → RGBA, no PPU).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const snes = @import("../gfx/snes.zig");
const weapon_hit = @import("weapon_hit.zig");

pub const view_w: i32 = 256;
pub const view_h: i32 = 224;

pub const MonsterSprite = struct {
    /// Pixel width/height of composed sprite.
    w: u16 = 0,
    h: u16 = 0,
    /// RGBA8888 buffer (w*h*4), owned by Scene.
    pixels: []u8 = &.{},
    /// Palette index used (for debugging).
    pal_idx: u8 = 0,
};

/// CharTileTbl pose ids (btlgfx_data.asm @f961).
/// Baked into CharSprite: normal sheet poses $00–$0B + mini/toad subset for status.
/// Full table through $24 is exported for lookup/tests (golbez/special sheets separate).
pub const CharPose = enum(u8) {
    standing = 0,
    ready = 1,
    running = 2,
    kneeling = 3,
    right_arm_up = 4,
    left_arm_down = 5,
    left_arm_up = 6, // casting / strike
    hit = 7,
    victory = 8,
    dead = 9,
    chant1 = 10, // $0a
    chant2 = 11, // $0b casting alt
    // Mini sheet poses (CharTileTbl $0C–$15) — status mini
    mini_standing = 12,
    mini_ready = 13,
    mini_running = 14,
    mini_kneeling = 15,
    mini_attacking = 16,
    mini_hit = 17,
    mini_victory = 18,
    mini_dead = 19,
    mini_chant1 = 20,
    mini_chant2 = 21,
    // Toad sheet poses (CharTileTbl $16–$1D)
    toad_standing = 22,
    toad_ready = 23,
    toad_running = 24,
    toad_kneeling = 25,
    toad_attacking = 26,
    toad_hit = 27,
    toad_victory = 28,
    toad_dead = 29,
    // $1E hidden — empty tiles; not baked as drawable
};

/// Poses baked into each CharSprite (standing…toad_dead).
pub const char_pose_count: usize = 30;

/// Full CharTileTbl row count through special $24 (btlgfx_data.asm @f961).
pub const char_tile_tbl_full_count: usize = 37;

/// CharPoseOffsetTbl @f83c — offset group id per pose ($00 normal, $02 dead, $04 mini/toad, $06 special).
pub const char_pose_offset_id: [char_tile_tbl_full_count]u8 = .{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // $00–$07
    0x00, 0x02, 0x00, 0x00, 0x04, 0x04, 0x04, 0x04, // $08–$0F
    0x04, 0x04, 0x04, 0x00, 0x04, 0x04, 0x04, 0x04, // $10–$17
    0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x00, 0x00, // $18–$1F
    0x00, 0x00, 0x00, 0x02, 0x06, // $20–$24
};

/// CharTileTbl — 6 tile indices per pose, decomp btlgfx_data.asm @f961.
/// $FF = empty tile slot (mini/toad use lower body only).
pub const char_tile_tbl_full: [char_tile_tbl_full_count][6]u8 = .{
    .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 }, // $00 standing
    .{ 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b }, // $01 ready
    .{ 0x00, 0x01, 0x02, 0x03, 0x0c, 0x0d }, // $02 running
    .{ 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13 }, // $03 kneeling
    .{ 0x00, 0x01, 0x14, 0x03, 0x15, 0x0d }, // $04 right arm up
    .{ 0x00, 0x01, 0x16, 0x17, 0x18, 0x19 }, // $05 left arm down
    .{ 0x00, 0x1a, 0x02, 0x1b, 0x1c, 0x1d }, // $06 left arm up
    .{ 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23 }, // $07 hit
    .{ 0x24, 0x25, 0x26, 0x27, 0x28, 0x29 }, // $08 victory
    .{ 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f }, // $09 dead
    .{ 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e }, // $0a chant 1
    .{ 0x39, 0x3a, 0x3f, 0x3c, 0x3d, 0x3e }, // $0b chant 2
    .{ 0xff, 0xff, 0xff, 0xff, 0x40, 0xff }, // $0c mini normal
    .{ 0xff, 0xff, 0xff, 0xff, 0x41, 0xff }, // $0d mini ready
    .{ 0xff, 0xff, 0xff, 0xff, 0x42, 0xff }, // $0e mini running
    .{ 0xff, 0xff, 0xff, 0xff, 0x43, 0xff }, // $0f mini kneeling
    .{ 0xff, 0xff, 0xff, 0xff, 0x44, 0xff }, // $10 mini attacking
    .{ 0xff, 0xff, 0xff, 0xff, 0x45, 0xff }, // $11 mini hit
    .{ 0xff, 0xff, 0xff, 0xff, 0x46, 0xff }, // $12 mini victory
    .{ 0xff, 0xff, 0xff, 0xff, 0x47, 0x48 }, // $13 mini dead
    .{ 0xff, 0xff, 0xff, 0xff, 0x49, 0xff }, // $14 mini chant 1
    .{ 0xff, 0xff, 0xff, 0xff, 0x50, 0xff }, // $15 mini chant 2
    .{ 0xff, 0xff, 0xff, 0xff, 0x51, 0xff }, // $16 toad normal
    .{ 0xff, 0xff, 0xff, 0xff, 0x52, 0xff }, // $17 toad ready
    .{ 0xff, 0xff, 0xff, 0xff, 0x53, 0xff }, // $18 toad running
    .{ 0xff, 0xff, 0xff, 0xff, 0x54, 0xff }, // $19 toad kneeling
    .{ 0xff, 0xff, 0xff, 0xff, 0x55, 0xff }, // $1a toad attacking
    .{ 0xff, 0xff, 0xff, 0xff, 0x56, 0xff }, // $1b toad hit
    .{ 0xff, 0xff, 0xff, 0xff, 0x57, 0xff }, // $1c toad victory
    .{ 0xff, 0xff, 0xff, 0xff, 0x58, 0x59 }, // $1d toad dead
    .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, // $1e hidden
    .{ 0x00, 0x01, 0x02, 0x03, 0x06, 0x07 }, // $1f running (golbez/anna)
    .{ 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d }, // $20 chant 1 (golbez)
    .{ 0x08, 0x09, 0x0e, 0x0b, 0x0c, 0x0d }, // $21 chant 2 (golbez)
    .{ 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14 }, // $22 casting (golbez)
    .{ 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a }, // $23 dead (golbez)
    .{ 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 }, // $24 special (6 of 8; tiles 37,38 extra in ROM)
};

/// Rows used when baking CharSprite (matches CharPose 0..29).
const char_tile_tbl = char_tile_tbl_full[0..char_pose_count].*;

/// Tile row for any CharTileTbl pose id ($00–$24).
pub fn charTileRow(pose_id: u8) [6]u8 {
    if (pose_id >= char_tile_tbl_full_count) return char_tile_tbl_full[0];
    return char_tile_tbl_full[pose_id];
}

/// CharPoseOffsetTbl id for pose ($00 / $02 / $04 / $06).
pub fn poseOffsetId(pose_id: u8) u8 {
    if (pose_id >= char_tile_tbl_full_count) return 0;
    return char_pose_offset_id[pose_id];
}

/// Map status bits → CharPose base (standing/ready family). Pig uses sheet $0E elsewhere.
pub fn poseForStatus(base: CharPose, mini: bool, toad: bool) CharPose {
    if (toad) {
        return switch (base) {
            .ready => .toad_ready,
            .running => .toad_running,
            .kneeling => .toad_kneeling,
            .hit => .toad_hit,
            .victory => .toad_victory,
            .dead => .toad_dead,
            .left_arm_up, .right_arm_up, .left_arm_down => .toad_attacking,
            .chant1, .chant2 => .toad_standing, // no toad chant tiles beyond ready set
            else => .toad_standing,
        };
    }
    if (mini) {
        return switch (base) {
            .ready => .mini_ready,
            .running => .mini_running,
            .kneeling => .mini_kneeling,
            .hit => .mini_hit,
            .victory => .mini_victory,
            .dead => .mini_dead,
            .left_arm_up, .right_arm_up, .left_arm_down => .mini_attacking,
            .chant1 => .mini_chant1,
            .chant2 => .mini_chant2,
            else => .mini_standing,
        };
    }
    return base;
}

// --- UpdateCharSpritesheet / CharAnimPoseTbl (sprite.asm @e03a / btlgfx_data @fb81) ---

/// Spritesheet bank base added to pose cmd before CharAnimPoseTbl (@e3ba).
pub const SheetBank = enum(u8) {
    normal = 0x00,
    mini = 0x10,
    toad = 0x20,
    /// Golbez / Anna extra sheets (InitCharGfx gfx ≥ $0F).
    golbez_anna = 0x30,
    pig = 0x40,
};

/// CharTileTbl pose for hide (all `$ff` tiles).
pub const pose_hidden: u8 = 0x1E;

/// First BattleCharGfx id that uses GetExtraCharGfxPtr (sprite.asm @e0ab).
pub const extra_char_gfx_min: u8 = 0x0F;
/// ExtraCharGfxPtrs has 2 entries: $0F Golbez, $10 Anna.
pub const extra_char_gfx_count: u8 = 2;

/// ExtraCharGfxPtrs @fc86 — offset from BattleCharGfx base (words).
/// BattleCharGfx_000f / _0010 relative = id × $800.
pub const extra_char_gfx_offs = [_]u16{
    0x0F * @as(u16, offsets.en.battle_char_gfx_stride), // $0F Golbez
    0x10 * @as(u16, offsets.en.battle_char_gfx_stride), // $10 Anna
};

pub fn isExtraCharGfx(gfx_id: u8) bool {
    return gfx_id >= extra_char_gfx_min and gfx_id < extra_char_gfx_min + extra_char_gfx_count;
}

/// GetExtraCharGfxPtr (sprite.asm @e0f1): file offset of sheet within BattleCharGfx bank.
pub fn extraCharGfxFileOff(gfx_id: u8) ?usize {
    if (!isExtraCharGfx(gfx_id)) return null;
    const i: usize = gfx_id - extra_char_gfx_min;
    return offsets.en.battle_char_gfx + @as(usize, extra_char_gfx_offs[i]);
}

/// UpdateCharSpritesheet bank select (sprite.asm @e03a).
/// Priority: toad `$20` / mini `$10` (status `$30`) → pig `$08` → gfx≥$0F → `$30` → normal.
pub fn spritesheetBank(status1: u8, battle_gfx_id: u8) SheetBank {
    const form = status1 & 0x30; // toad $20 | mini $10
    if (form != 0) {
        if ((form & 0x20) != 0) return .toad;
        return .mini;
    }
    if ((status1 & 0x08) != 0) return .pig; // Status1.pig
    if (battle_gfx_id >= extra_char_gfx_min) return .golbez_anna;
    return .normal;
}

/// CharAnimPoseTbl @fb81: 5 banks × 16 pose cmds × 4 anim frames → CharTileTbl pose id.
/// Bank order: normal `$00`, mini `$10`, toad `$20`, golbez `$30`, pig `$40`.
pub const char_anim_pose_tbl: [5][16][4]u8 = .{
    // normal $00
    .{
        .{ 0x1e, 0x1e, 0x1e, 0x1e },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x01, 0x01, 0x01, 0x01 },
        .{ 0x00, 0x02, 0x00, 0x02 },
        .{ 0x03, 0x03, 0x03, 0x03 },
        .{ 0x04, 0x04, 0x02, 0x02 },
        .{ 0x06, 0x06, 0x05, 0x05 },
        .{ 0x07, 0x07, 0x07, 0x07 },
        .{ 0x00, 0x08, 0x00, 0x08 },
        .{ 0x09, 0x09, 0x09, 0x09 },
        .{ 0x0a, 0x0b, 0x0a, 0x0b },
        .{ 0x0a, 0x0a, 0x0a, 0x0a },
        .{ 0x08, 0x08, 0x08, 0x08 },
        .{ 0x04, 0x04, 0x04, 0x04 },
        .{ 0x24, 0x24, 0x24, 0x24 },
        .{ 0x24, 0x24, 0x24, 0x24 },
    },
    // mini $10
    .{
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x0c, 0x0c, 0x0c, 0x0c },
        .{ 0x0d, 0x0d, 0x0d, 0x0d },
        .{ 0x0e, 0x0c, 0x0e, 0x0c },
        .{ 0x0f, 0x0f, 0x0f, 0x0f },
        .{ 0x10, 0x10, 0x0e, 0x0e },
        .{ 0x10, 0x10, 0x0e, 0x0e },
        .{ 0x11, 0x11, 0x11, 0x11 },
        .{ 0x0c, 0x12, 0x0c, 0x12 },
        .{ 0x13, 0x13, 0x13, 0x13 },
        .{ 0x14, 0x15, 0x14, 0x15 },
        .{ 0x14, 0x14, 0x14, 0x14 },
        .{ 0x0c, 0x0c, 0x0c, 0x0c },
        .{ 0x10, 0x10, 0x10, 0x10 },
        .{ 0x0c, 0x0c, 0x0c, 0x0c },
        .{ 0x0c, 0x0c, 0x0c, 0x0c },
    },
    // toad $20
    .{
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x16, 0x16, 0x16, 0x16 },
        .{ 0x17, 0x17, 0x17, 0x17 },
        .{ 0x16, 0x18, 0x16, 0x18 },
        .{ 0x19, 0x19, 0x19, 0x19 },
        .{ 0x1a, 0x1a, 0x18, 0x18 },
        .{ 0x1a, 0x1a, 0x18, 0x18 },
        .{ 0x1b, 0x1b, 0x1b, 0x1b },
        .{ 0x16, 0x1c, 0x16, 0x1c },
        .{ 0x1d, 0x1d, 0x1d, 0x1d },
        .{ 0x16, 0x16, 0x16, 0x16 },
        .{ 0x16, 0x16, 0x16, 0x16 },
        .{ 0x16, 0x16, 0x16, 0x16 },
        .{ 0x1a, 0x1a, 0x1a, 0x1a },
        .{ 0x16, 0x16, 0x16, 0x16 },
        .{ 0x16, 0x16, 0x16, 0x16 },
    },
    // golbez/anna $30
    .{
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x1f, 0x00, 0x1f },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x1f, 0x1f, 0x1f, 0x1f },
        .{ 0x00, 0x22, 0x00, 0x22 },
        .{ 0x23, 0x23, 0x23, 0x23 },
        .{ 0x20, 0x21, 0x20, 0x21 },
        .{ 0x20, 0x20, 0x20, 0x20 },
        .{ 0x22, 0x22, 0x22, 0x22 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
    },
    // pig $40
    .{
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x00, 0x00, 0x00, 0x00 },
        .{ 0x01, 0x01, 0x01, 0x01 },
        .{ 0x00, 0x02, 0x00, 0x02 },
        .{ 0x03, 0x03, 0x03, 0x03 },
        .{ 0x04, 0x04, 0x02, 0x02 },
        .{ 0x06, 0x06, 0x05, 0x05 },
        .{ 0x07, 0x07, 0x07, 0x07 },
        .{ 0x00, 0x08, 0x00, 0x08 },
        .{ 0x09, 0x09, 0x09, 0x09 },
        .{ 0x01, 0x01, 0x01, 0x01 },
        .{ 0x00, 0x08, 0x00, 0x08 },
        .{ 0x08, 0x08, 0x08, 0x08 },
        .{ 0x04, 0x04, 0x04, 0x04 },
        .{ 0x08, 0x08, 0x08, 0x08 },
        .{ 0x08, 0x08, 0x08, 0x08 },
    },
};

/// CharAnimPoseTbl lookup: `pose_cmd` 0..15, `frame` 0..3 → CharTileTbl pose id.
pub fn charAnimPose(bank: SheetBank, pose_cmd: u8, frame: u8) u8 {
    const bi: usize = switch (bank) {
        .normal => 0,
        .mini => 1,
        .toad => 2,
        .golbez_anna => 3,
        .pig => 4,
    };
    const pc: usize = @min(@as(usize, pose_cmd), 15);
    const fr: usize = @min(@as(usize, frame), 3);
    return char_anim_pose_tbl[bi][pc][fr];
}

/// Map host CharPose (logical) → CharAnimPoseTbl pose_cmd (1=stand … 9=dead, 10=chant).
/// Hidden → cmd 0 → pose `$1e`.
pub fn poseCmdForCharPose(pose: CharPose) u8 {
    return switch (pose) {
        .standing => 1,
        .ready => 2,
        .running => 3,
        .kneeling => 4,
        .right_arm_up => 5,
        .left_arm_down => 6,
        .left_arm_up => 6,
        .hit => 7,
        .victory => 8,
        .dead => 9,
        .chant1, .chant2 => 10,
        // Mini/toad use bank remap; keep base cmd from family
        .mini_standing, .toad_standing => 1,
        .mini_ready, .toad_ready => 2,
        .mini_running, .toad_running => 3,
        .mini_kneeling, .toad_kneeling => 4,
        .mini_attacking, .toad_attacking => 5,
        .mini_hit, .toad_hit => 7,
        .mini_victory, .toad_victory => 8,
        .mini_dead, .toad_dead => 9,
        .mini_chant1, .mini_chant2 => 10,
    };
}

/// Resolve CharTileTbl pose id for draw: bank from status/gfx + anim frame.
pub fn resolveCharTilePose(status1: u8, battle_gfx_id: u8, pose: CharPose, frame: u8) u8 {
    const bank = spritesheetBank(status1, battle_gfx_id);
    const cmd = poseCmdForCharPose(pose);
    return charAnimPose(bank, cmd, frame);
}

const TileOff = struct { x: i8, y: i8 };

/// CharSpriteOffsetTbl $00 normal 2×3 (btlgfx_data.asm @f861) — (x,y) per tile.
const pose_off_normal = [_]TileOff{
    .{ .x = 0, .y = 0 },
    .{ .x = 8, .y = 0 },
    .{ .x = 0, .y = 8 },
    .{ .x = 8, .y = 8 },
    .{ .x = 0, .y = 16 },
    .{ .x = 8, .y = 16 },
};

/// CharSpriteOffsetTbl $02 dead 3×2 (laying) — relative x can be −8.
const pose_off_dead = [_]TileOff{
    .{ .x = -8, .y = 8 },
    .{ .x = 0, .y = 8 },
    .{ .x = 8, .y = 8 },
    .{ .x = -8, .y = 16 },
    .{ .x = 0, .y = 16 },
    .{ .x = 8, .y = 16 },
};

/// CharSpriteOffsetTbl $04 mini/toad 2×3 (x origin +4).
const pose_off_mini = [_]TileOff{
    .{ .x = 4, .y = 0 },
    .{ .x = 12, .y = 0 },
    .{ .x = 4, .y = 8 },
    .{ .x = 12, .y = 8 },
    .{ .x = 4, .y = 16 },
    .{ .x = 12, .y = 16 },
};

fn offsetsForPose(pose_id: u8) []const TileOff {
    return switch (poseOffsetId(pose_id)) {
        0x02 => pose_off_dead[0..],
        0x04 => pose_off_mini[0..],
        else => pose_off_normal[0..],
    };
}

pub const CharSprite = struct {
    w: u16 = 16,
    h: u16 = 24,
    /// Dead pose is wider (3×2); other poses keep 16×24.
    dead_w: u16 = 24,
    dead_h: u16 = 24,
    /// Draw origin offset for dead pose (tiles start at x=−8).
    dead_ox: i16 = -8,
    dead_oy: i16 = 0,
    /// Baked RGBA frames per CharPose (standing..dead).
    poses: [char_pose_count][]u8 = .{&.{}} ** char_pose_count,

    pub fn pixelsFor(self: *const CharSprite, pose: CharPose) []const u8 {
        const p = self.poses[@intFromEnum(pose)];
        if (p.len > 0) return p;
        return self.poses[@intFromEnum(CharPose.standing)];
    }

    pub fn sizeFor(self: *const CharSprite, pose: CharPose) struct { w: u16, h: u16, ox: i16, oy: i16 } {
        const pid = @intFromEnum(pose);
        if (pose == .dead or poseOffsetId(pid) == 0x02)
            return .{ .w = self.dead_w, .h = self.dead_h, .ox = self.dead_ox, .oy = self.dead_oy };
        return .{ .w = self.w, .h = self.h, .ox = 0, .oy = 0 };
    }
};

pub const Scene = struct {
    /// Full-screen battle background RGBA.
    bg: []u8 = &.{},
    monsters: [8]MonsterSprite = [_]MonsterSprite{.{}} ** 8,
    chars: [5]CharSprite = [_]CharSprite{.{}} ** 5,
    /// LoadHitGfx (weapon.asm @d8e3) — sword/default hit type 0.
    hit_gfx: weapon_hit.HitGfx = .{},
    allocator: std.mem.Allocator = undefined,
    loaded: bool = false,

    pub fn deinit(self: *Scene) void {
        if (self.bg.len != 0) self.allocator.free(self.bg);
        for (&self.monsters) |*m| {
            if (m.pixels.len != 0) self.allocator.free(m.pixels);
            m.* = .{};
        }
        for (&self.chars) |*c| {
            for (&c.poses) |*p| {
                if (p.len != 0) self.allocator.free(p.*);
                p.* = &.{};
            }
            c.* = .{};
        }
        self.bg = &.{};
        self.hit_gfx = .{};
        self.loaded = false;
    }

    /// InitGfx subset: BG + monster sprites for types[] + party char graphics.
    pub fn load(
        self: *Scene,
        gpa: std.mem.Allocator,
        r: *const rom_mod.Rom,
        bg_id: u8,
        mon_types: []const u8,
        mon_count: usize,
        char_gfx_ids: []const u8,
    ) !void {
        self.deinit();
        self.allocator = gpa;
        self.bg = try gpa.alloc(u8, @as(usize, @intCast(view_w * view_h * 4)));
        errdefer gpa.free(self.bg);
        @memset(self.bg, 0);

        try loadBattleBg(self.bg, r, bg_id);

        var mi: usize = 0;
        while (mi < mon_count and mi < 8) : (mi += 1) {
            const tid = mon_types[mi];
            if (tid == 0xFF) continue;
            self.monsters[mi] = loadMonster(gpa, r, tid) catch .{};
        }

        var ci: usize = 0;
        while (ci < char_gfx_ids.len and ci < 5) : (ci += 1) {
            const gid = char_gfx_ids[ci];
            if (gid == 0xFF) continue; // empty party slot
            self.chars[ci] = loadChar(gpa, r, gid) catch .{};
        }
        // LoadHitGfx type 0 (WeaponTileOffsetTbl[$98] sword hit bank).
        self.hit_gfx.load(r, 0);
        self.loaded = true;
    }

    /// ActivateMonster gfx: load one mon type into slot (Call/Alert).
    pub fn loadMonsterAt(self: *Scene, r: *const rom_mod.Rom, type_id: u8, mon_i: usize) void {
        if (!self.loaded or mon_i >= 8 or type_id == 0xFF) return;
        if (self.monsters[mon_i].pixels.len != 0) {
            self.allocator.free(self.monsters[mon_i].pixels);
            self.monsters[mon_i] = .{};
        }
        self.monsters[mon_i] = loadMonster(self.allocator, r, type_id) catch .{};
    }

    /// ReloadCharGfx — party slot sheet after toad/pig/mini status change.
    pub fn reloadCharAt(self: *Scene, r: *const rom_mod.Rom, slot: usize, gfx_id: u8) void {
        if (!self.loaded or slot >= 5) return;
        for (&self.chars[slot].poses) |*p| {
            if (p.len != 0) self.allocator.free(p.*);
            p.* = &.{};
        }
        self.chars[slot] = loadChar(self.allocator, r, gfx_id) catch .{};
    }
};

/// Map entry → local graphics index.
/// ROM: vram_tile = (entry & $3F) + 1 + tile_off, CHR starts at tile 1+tile_off
/// so graphics[i] is at vram (1+tile_off+i) → local = entry & $3F.
const MapCell = struct {
    tile: u8,
    pal1: bool,
    flip_v: bool,
};

fn decodeMapEntry(entry: u8) MapCell {
    return .{
        .tile = entry & 0x3F,
        .pal1 = (entry & 0x40) != 0,
        .flip_v = (entry & 0x80) != 0,
    };
}

fn loadBattleBg(out: []u8, r: *const rom_mod.Rom, bg_id_raw: u8) !void {
    const bg_id: u8 = bg_id_raw & 0x1F;
    const bid = if (bg_id >= offsets.en.battle_bg_prop_count) @as(u8, 0) else bg_id;

    // BattleBGProp: top, middle, bottom layout indices, tile offset (VRAM only).
    const prop = try r.slice(offsets.en.battle_bg_prop + @as(usize, bid) * 4, 4);
    const top_i = prop[0];
    const mid_i = prop[1];
    const btm_i = prop[2];
    _ = prop[3]; // tile_off — absorbed into VRAM base; not used for local tile index

    // LoadBattleBGPal (@f76e): id from $1802; bit5 ($20) → AltBattleBGPalTbl.
    // AltBattleBGPalTbl: 22,0,0,0,17,0,0,18,20,0,0,19,21,0,0,0,0
    const alt_tbl = [_]u8{ 22, 0, 0, 0, 17, 0, 0, 18, 20, 0, 0, 19, 21, 0, 0, 0, 0 };
    var pal_i: usize = bid;
    if ((bg_id_raw & 0x20) != 0 and bid < alt_tbl.len and alt_tbl[bid] != 0) {
        pal_i = alt_tbl[bid];
    }
    pal_i = @min(pal_i, offsets.en.battle_bg_pal_count - 1);
    const pal_raw = try r.slice(offsets.en.battle_bg_pal + pal_i * offsets.en.battle_bg_pal_stride, 32);
    var palette: [16]snes.Color = undefined;
    var pi: usize = 0;
    while (pi < 16) : (pi += 1) {
        const w = std.mem.readInt(u16, pal_raw[pi * 2 ..][0..2], .little);
        palette[pi] = snes.Color.fromSnes(w);
        palette[pi].a = 255; // BG: color 0 is opaque backdrop, not transparent
    }

    // LoadBattleBGGfx: 40 tiles of 3bpp ($28) from BattleBGGfxPtrs[bg].
    const ptrs = try r.slice(offsets.en.battle_bg_gfx_ptrs, 17 * 2);
    const gfx_ptr: usize = @as(usize, ptrs[bid * 2]) | (@as(usize, ptrs[bid * 2 + 1]) << 8);
    const gfx_file = offsets.en.battle_bg_gfx_bank + (gfx_ptr & 0x7FFF);
    const n_gfx: usize = 40;
    var tiles: [40][64]u8 = undefined;
    @memset(std.mem.sliceAsBytes(tiles[0..]), 0);
    var t: usize = 0;
    while (t < n_gfx) : (t += 1) {
        const toff = gfx_file + t * 24;
        if (toff + 24 > r.data.len) break;
        snes.decodeTile3bpp(r.data[toff .. toff + 24][0..24], &tiles[t]);
    }

    // WRAM layout ($6cfd): 18 rows × 32 tiles (LoadBattleBGGfx transfers $0480 bytes).
    // 1) bottom → rows 8–17 (10 rows)
    // 2) top    → rows 0–7
    // 3) middle → rows 8–15 (overwrites bottom) when mid != 0; rows 16–17 keep bottom.
    var map: [18 * 32]MapCell = [_]MapCell{.{ .tile = 0, .pal1 = false, .flip_v = false }} ** (18 * 32);

    if (btm_i < 7) {
        const btm = try r.slice(offsets.en.battle_bg_btm_tiles + @as(usize, btm_i) * 64, 64);
        var r_i: usize = 0;
        while (r_i < 10) : (r_i += 1) {
            var col: usize = 0;
            while (col < 32) : (col += 1) {
                // LoadBattleBGBtmTiles: y wraps with `and #$3f` over 64-byte pattern.
                const entry = btm[((r_i * 32 + col) % 64)];
                map[(8 + r_i) * 32 + col] = decodeMapEntry(entry);
            }
        }
    }

    if (top_i < 11) {
        const top = try r.slice(offsets.en.battle_bg_top_tiles + @as(usize, top_i) * 256, 256);
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            map[i] = decodeMapEntry(top[i]);
        }
    }

    if (mid_i != 0 and mid_i < 11) {
        const mid = try r.slice(offsets.en.battle_bg_top_tiles + @as(usize, mid_i) * 256, 256);
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            map[256 + i] = decodeMapEntry(mid[i]); // rows 8–15
        }
    }

    // Fill screen with backdrop (pal0 color 0).
    {
        var y: i32 = 0;
        while (y < view_h) : (y += 1) {
            var x: i32 = 0;
            while (x < view_w) : (x += 1) {
                const o: usize = @intCast((y * view_w + x) * 4);
                out[o] = palette[0].r;
                out[o + 1] = palette[0].g;
                out[o + 2] = palette[0].b;
                out[o + 3] = 255;
            }
        }
    }

    // Blit 18 rows (144 px). Rows 18–27 stay backdrop (menu / floor under windows).
    var my: usize = 0;
    while (my < 18) : (my += 1) {
        var mx: usize = 0;
        while (mx < 32) : (mx += 1) {
            const cell = map[my * 32 + mx];
            if (cell.tile >= n_gfx) continue;
            const pal_off: usize = if (cell.pal1) 8 else 0;
            snes.blitTileEx(
                out,
                @intCast(view_w),
                @intCast(mx * 8),
                @intCast(my * 8),
                &tiles[cell.tile],
                &palette,
                pal_off,
                false,
                false,
                cell.flip_v,
                false,
            );
        }
    }
}

/// Boss load — exact sources from LoadMonsterGfx boss branch + LoadBossTilemap:
///   • Tile **graphics** from MonsterGfxProp[2..3] (same bank/ptr as normal mon @9007)
///   • **Size** / **palette** / **tilemap** from BossGfxProp (index = MonsterGfxProp[0]&$3F)
///   • Tilemap RLE: $FF empty, $FE,nn run (ppu.asm @8ce1)
fn loadBoss(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    b0: u8,
    mon_pal: u8,
    gfx_b2: u8,
    gfx_b3: u8,
) !MonsterSprite {
    const boss_prop_base: usize = 0x7CE00;
    const boss_ptr_base: usize = 0x74F00; // 0E/CF00 BossTilemapPtrs
    const bi: usize = b0 & 0x3F;
    const bp = try r.slice(boss_prop_base + bi * 5, 5);

    // Size: MonsterGfxSize[BossGfxProp[1] & $3F]
    var tw: u8 = 8;
    var th: u8 = 8;
    const size_i: usize = bp[1] & 0x3F;
    if (size_i < offsets.en.monster_gfx_size_count) {
        const sz = try r.slice(offsets.en.monster_gfx_size + size_i * 2, 2);
        if (sz[0] != 0) tw = sz[0];
        if (sz[1] != 0) th = sz[1];
    }

    // Palette: BossGfxProp[2] (LoadMonsterPal in boss path)
    const boss_pal: u8 = bp[2];
    var palette: [16]snes.Color = .{snes.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 16;
    {
        const pi = @min(if (boss_pal != 0) boss_pal else mon_pal, offsets.en.monster_pal_count - 1);
        const pr = try r.slice(offsets.en.monster_pal + @as(usize, pi) * 16, 16);
        snes.loadPalette(pr, palette[0..8]);
    }

    // Tilemap pointer: BossTilemapPtrs[BossGfxProp[4]]
    const tmap_i: usize = bp[4];
    if (tmap_i >= 57) return error.BadBoss;
    const pref = try r.slice(boss_ptr_base + tmap_i * 2, 2);
    const rel: u16 = @as(u16, pref[0]) | (@as(u16, pref[1]) << 8);
    const map_file = rom_mod.Rom.loromOffset(@as(u24, 0x0E0000) | @as(u24, rel));

    const n_tiles: usize = @as(usize, tw) * @as(usize, th);
    var map = try gpa.alloc(u8, n_tiles);
    defer gpa.free(map);
    @memset(map, 0xFF);
    var mi: usize = 0;
    var src_i: usize = 0;
    var run_empty: u8 = 0;
    while (mi < n_tiles and src_i < 0x1000) {
        if (run_empty > 0) {
            map[mi] = 0xFF;
            mi += 1;
            run_empty -= 1;
            continue;
        }
        const b = r.slice(map_file + src_i, 1) catch break;
        src_i += 1;
        if (b[0] == 0xFF) {
            map[mi] = 0xFF;
            mi += 1;
        } else if (b[0] == 0xFE) {
            const n = r.slice(map_file + src_i, 1) catch break;
            src_i += 1;
            // LoadBossTilemap: FE then count, dec → empty tiles
            run_empty = if (n[0] > 0) n[0] -% 1 else 0;
            map[mi] = 0xFF;
            mi += 1;
        } else {
            map[mi] = b[0];
            mi += 1;
        }
    }

    // Graphics transfer @9007: bank = (MonsterGfxProp[3] & $70) >> 4
    // addr = ((prop[2]|(prop[3]&$0F)<<8) << 3) + $8000 within bank
    // bit7 of prop[3] = 3bpp
    const is_3bpp = (gfx_b3 & 0x80) != 0;
    const bank_i: usize = (gfx_b3 & 0x70) >> 4;
    if (bank_i >= offsets.en.monster_gfx_bank.len) return error.BadBank;
    const ptr12: usize = @as(usize, gfx_b2) | (@as(usize, gfx_b3 & 0x0F) << 8);
    const bank_base = offsets.en.monster_gfx_bank[bank_i];
    const file_off = bank_base + ((0x8000 + (ptr12 << 3)) & 0x7FFF);
    const tile_bytes: usize = if (is_3bpp) 24 else 32;

    const pw: usize = @as(usize, tw) * 8;
    const ph: usize = @as(usize, th) * 8;
    const pixels = try gpa.alloc(u8, pw * ph * 4);
    @memset(pixels, 0);

    var ti: usize = 0;
    while (ti < n_tiles) : (ti += 1) {
        const tidx = map[ti];
        if (tidx == 0xFF) continue;
        // Tile indices are relative to the transferred VRAM block (base tile 0)
        const toff = file_off + @as(usize, tidx) * tile_bytes;
        if (toff + tile_bytes > r.data.len) continue;
        var idx: [64]u8 = undefined;
        if (is_3bpp) {
            snes.decodeTile3bpp(r.data[toff .. toff + 24][0..24], &idx);
        } else {
            snes.decodeTile4bpp(r.data[toff .. toff + 32][0..32], &idx);
        }
        const tx: i32 = @intCast((ti % tw) * 8);
        const ty: i32 = @intCast((ti / tw) * 8);
        snes.blitTile(pixels, pw, tx, ty, &idx, &palette, 0, true);
    }

    return .{
        .w = @intCast(pw),
        .h = @intCast(ph),
        .pixels = pixels,
        .pal_idx = if (boss_pal != 0) boss_pal else mon_pal,
    };
}

/// LoadMonsterGfx for one type id → RGBA sprite (btlgfx/ppu.asm @8eca).
fn loadMonster(gpa: std.mem.Allocator, r: *const rom_mod.Rom, type_id: u8) !MonsterSprite {
    if (type_id >= offsets.en.monster_gfx_prop_count) return error.BadType;
    const raw = try r.slice(offsets.en.monster_gfx_prop + @as(usize, type_id) * 4, 4);
    const b0 = raw[0];
    const pal_idx = raw[1];
    const b2 = raw[2];
    const b3 = raw[3];

    // bit7 boss → LoadBoss path (size/pal/tilemap from BossGfxProp; tiles from prop[2:3])
    if ((b0 & 0x80) != 0) {
        return try loadBoss(gpa, r, b0, pal_idx, b2, b3);
    }

    const is_char = (b0 & 0x40) != 0;
    const size_i: usize = b0 & 0x3F;

    // Enemy character: fixed 2×3 tiles (LoadMonsterGfx @8f13)
    // Normal mon: MonsterGfxSize[size_i]
    var tw: u8 = 2;
    var th: u8 = 3;
    if (!is_char) {
        tw = 4;
        th = 4;
        if (size_i < offsets.en.monster_gfx_size_count) {
            const sz = try r.slice(offsets.en.monster_gfx_size + size_i * 2, 2);
            if (sz[0] != 0) tw = sz[0];
            if (sz[1] != 0) th = sz[1];
        }
    }
    if (tw == 0) tw = 2;
    if (th == 0) th = 2;
    const n_tiles: usize = @as(usize, tw) * @as(usize, th);

    var palette: [16]snes.Color = .{snes.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 16;
    if (is_char) {
        const pi = @min(pal_idx, offsets.en.battle_char_pal_count - 1);
        const pr = try r.slice(offsets.en.battle_char_pal + @as(usize, pi) * 32, 32);
        snes.loadPalette(pr, &palette);
    } else {
        const pi = @min(pal_idx, offsets.en.monster_pal_count - 1);
        const pr = try r.slice(offsets.en.monster_pal + @as(usize, pi) * 16, 16);
        snes.loadPalette(pr, palette[0..8]);
    }

    const is_3bpp = (b3 & 0x80) != 0;
    const bank_i: usize = (b3 & 0x70) >> 4;
    const ptr12: usize = @as(usize, b2) | (@as(usize, b3 & 0x0F) << 8);

    const pw: usize = @as(usize, tw) * 8;
    const ph: usize = @as(usize, th) * 8;
    const pixels = try gpa.alloc(u8, pw * ph * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    if (is_char) {
        // Enemy character: BattleCharGfx[index] 0x800 bytes 4bpp.
        const cgi = b0 & 0x3F;
        if (cgi >= offsets.en.battle_char_gfx_count) return error.BadChar;
        const base = offsets.en.battle_char_gfx + @as(usize, cgi) * offsets.en.battle_char_gfx_stride;
        var ti: usize = 0;
        while (ti < n_tiles) : (ti += 1) {
            const toff = base + ti * 32;
            if (toff + 32 > r.data.len) break;
            var idx: [64]u8 = undefined;
            snes.decodeTile4bpp(r.data[toff .. toff + 32][0..32], &idx);
            const tx: i32 = @intCast((ti % tw) * 8);
            const ty: i32 = @intCast((ti / tw) * 8);
            snes.blitTile(pixels, pw, tx, ty, &idx, &palette, 0, true);
        }
    } else {
        // Normal monster: bank + (ptr12<<3)+$8000 (@9007)
        if (bank_i >= offsets.en.monster_gfx_bank.len) return error.BadBank;
        const bank_base = offsets.en.monster_gfx_bank[bank_i];
        const addr_in_bank = 0x8000 + (ptr12 << 3);
        const file_off = bank_base + (addr_in_bank & 0x7FFF);
        const tile_bytes: usize = if (is_3bpp) 24 else 32;

        var ti: usize = 0;
        while (ti < n_tiles) : (ti += 1) {
            const toff = file_off + ti * tile_bytes;
            if (toff + tile_bytes > r.data.len) break;
            var idx: [64]u8 = undefined;
            if (is_3bpp) {
                snes.decodeTile3bpp(r.data[toff .. toff + 24][0..24], &idx);
            } else {
                snes.decodeTile4bpp(r.data[toff .. toff + 32][0..32], &idx);
            }
            const tx: i32 = @intCast((ti % tw) * 8);
            const ty: i32 = @intCast((ti / tw) * 8);
            snes.blitTile(pixels, pw, tx, ty, &idx, &palette, 0, true);
        }
    }

    return .{
        .w = @intCast(pw),
        .h = @intCast(ph),
        .pixels = pixels,
        .pal_idx = pal_idx,
    };
}

/// InitCharGfx + CharTileTbl: bake poses $00–$1D (normal + mini + toad).
/// Extra gfx `$0F`/`$10` use GetExtraCharGfxPtr + CharAnimPoseTbl bank `$30` rows.
fn loadChar(gpa: std.mem.Allocator, r: *const rom_mod.Rom, gfx_id: u8) !CharSprite {
    // GetExtraCharGfxPtr for ≥$0F; else class sheet id × $800.
    const base: usize = if (extraCharGfxFileOff(gfx_id)) |off|
        off
    else blk: {
        const id = @min(gfx_id, offsets.en.battle_char_gfx_count - 1);
        break :blk offsets.en.battle_char_gfx + @as(usize, id) * offsets.en.battle_char_gfx_stride;
    };
    const pal_id = @min(gfx_id, offsets.en.battle_char_pal_count - 1);
    const pal_raw = try r.slice(offsets.en.battle_char_pal + @as(usize, pal_id) * 32, 32);
    var palette: [16]snes.Color = undefined;
    snes.loadPalette(pal_raw, &palette);

    // Decode full sheet tiles (0x800 / 32 = 64 tiles).
    const sheet_tiles: usize = offsets.en.battle_char_gfx_stride / 32;
    var sheet: [64][64]u8 = undefined;
    @memset(std.mem.sliceAsBytes(sheet[0..]), 0);
    var ti: usize = 0;
    while (ti < sheet_tiles and ti < 64) : (ti += 1) {
        const toff = base + ti * 32;
        if (toff + 32 > r.data.len) break;
        snes.decodeTile4bpp(r.data[toff .. toff + 32][0..32], &sheet[ti]);
    }

    const extra = isExtraCharGfx(gfx_id);
    var cs: CharSprite = .{};
    var pose_i: usize = 0;
    while (pose_i < char_pose_count) : (pose_i += 1) {
        // Extra sheets: CharAnimPoseTbl bank $30 maps logical pose → CharTileTbl row.
        // Normal: bake CharTileTbl rows $00–$1D directly into pose slots.
        const tile_pose: u8 = if (extra)
            resolveCharTilePose(0, gfx_id, @enumFromInt(@as(u8, @intCast(pose_i))), 0)
        else
            @intCast(pose_i);
        const off_id = poseOffsetId(tile_pose);
        const is_dead_layout = off_id == 0x02;
        // Dead: 24×24 buffer with tiles at x∈[-8,16) → store with origin shift +8 so all ≥0.
        const min_x: i32 = if (is_dead_layout) -8 else 0;
        const min_y: i32 = 0;
        const pw: usize = if (is_dead_layout) 24 else 16;
        const ph: usize = 24;
        const pixels = try gpa.alloc(u8, pw * ph * 4);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);
        // Hidden $1e → empty buffer (all FF tiles).
        if (tile_pose != pose_hidden) {
            const tbl = charTileRow(tile_pose);
            const offs = offsetsForPose(tile_pose);
            var slot: usize = 0;
            while (slot < 6) : (slot += 1) {
                const tidx = tbl[slot];
                if (tidx == 0xFF or tidx >= 64) continue;
                const tx: i32 = offs[slot].x - min_x;
                const ty: i32 = offs[slot].y - min_y;
                snes.blitTile(pixels, pw, tx, ty, &sheet[tidx], &palette, 0, true);
            }
        }
        cs.poses[pose_i] = pixels;
        if (is_dead_layout) {
            cs.dead_w = @intCast(pw);
            cs.dead_h = @intCast(ph);
            cs.dead_ox = @intCast(min_x);
            cs.dead_oy = @intCast(min_y);
        }
    }
    return cs;
}

test "CharTileTbl standing and chant rows match decomp" {
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 }, &charTileRow(0x00));
    try std.testing.expectEqualSlices(u8, &.{ 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e }, &charTileRow(0x0a));
    try std.testing.expectEqualSlices(u8, &.{ 0x39, 0x3a, 0x3f, 0x3c, 0x3d, 0x3e }, &charTileRow(0x0b));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0x40, 0xff }, &charTileRow(0x0c));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0x51, 0xff }, &charTileRow(0x16));
}

test "CharPoseOffsetTbl dead and mini ids" {
    try std.testing.expectEqual(@as(u8, 0x00), poseOffsetId(0x00));
    try std.testing.expectEqual(@as(u8, 0x02), poseOffsetId(0x09)); // dead
    try std.testing.expectEqual(@as(u8, 0x04), poseOffsetId(0x0c)); // mini
    try std.testing.expectEqual(@as(u8, 0x04), poseOffsetId(0x16)); // toad
    try std.testing.expectEqual(@as(u8, 0x06), poseOffsetId(0x24)); // special
}

test "poseForStatus maps mini and toad" {
    try std.testing.expect(poseForStatus(.ready, true, false) == .mini_ready);
    try std.testing.expect(poseForStatus(.hit, false, true) == .toad_hit);
    try std.testing.expect(poseForStatus(.victory, false, false) == .victory);
}

test "UpdateCharSpritesheet bank priority" {
    // toad before mini when both? form & $20 first
    try std.testing.expect(spritesheetBank(0x20, 0) == .toad);
    try std.testing.expect(spritesheetBank(0x10, 0) == .mini);
    try std.testing.expect(spritesheetBank(0x08, 0) == .pig);
    try std.testing.expect(spritesheetBank(0, 0x0F) == .golbez_anna);
    try std.testing.expect(spritesheetBank(0, 0x10) == .golbez_anna);
    try std.testing.expect(spritesheetBank(0, 0x01) == .normal);
    // form bits beat golbez
    try std.testing.expect(spritesheetBank(0x20, 0x0F) == .toad);
}

test "CharAnimPoseTbl normal stand and golbez dead" {
    try std.testing.expectEqual(@as(u8, 0x00), charAnimPose(.normal, 1, 0)); // stand
    try std.testing.expectEqual(@as(u8, 0x1e), charAnimPose(.normal, 0, 0)); // hide
    try std.testing.expectEqual(@as(u8, 0x09), charAnimPose(.normal, 9, 0)); // dead
    try std.testing.expectEqual(@as(u8, 0x0c), charAnimPose(.mini, 1, 0));
    try std.testing.expectEqual(@as(u8, 0x16), charAnimPose(.toad, 1, 0));
    try std.testing.expectEqual(@as(u8, 0x23), charAnimPose(.golbez_anna, 9, 0)); // dead
    try std.testing.expectEqual(@as(u8, 0x20), charAnimPose(.golbez_anna, 10, 0)); // chant
    try std.testing.expectEqual(@as(u8, 0x1f), charAnimPose(.golbez_anna, 3, 1)); // run frame1
}

test "ExtraCharGfxPtrs file offsets" {
    try std.testing.expect(isExtraCharGfx(0x0F));
    try std.testing.expect(isExtraCharGfx(0x10));
    try std.testing.expect(!isExtraCharGfx(0x0E));
    try std.testing.expect(!isExtraCharGfx(0x00));
    const g = extraCharGfxFileOff(0x0F).?;
    const a = extraCharGfxFileOff(0x10).?;
    try std.testing.expectEqual(offsets.en.battle_char_gfx + 0x0F * offsets.en.battle_char_gfx_stride, g);
    try std.testing.expectEqual(offsets.en.battle_char_gfx + 0x10 * offsets.en.battle_char_gfx_stride, a);
    try std.testing.expect(extraCharGfxFileOff(0x00) == null);
}

test "resolveCharTilePose golbez dead and hide" {
    try std.testing.expectEqual(@as(u8, 0x23), resolveCharTilePose(0, 0x0F, .dead, 0));
    try std.testing.expectEqual(@as(u8, 0x00), resolveCharTilePose(0, 0, .standing, 0));
    // Hidden via bank normal cmd 0
    try std.testing.expectEqual(@as(u8, 0x1e), charAnimPose(.normal, 0, 0));
}

/// White-flash a sprite in place (hit flash). Copies src→dest with RGB boost.
pub fn blitRgbaFlash(dest: []u8, dest_w: usize, dx: i32, dy: i32, src: []const u8, sw: u16, sh: u16, flash: bool) void {
    if (src.len == 0 or sw == 0 or sh == 0) return;
    var y: i32 = 0;
    while (y < sh) : (y += 1) {
        var x: i32 = 0;
        while (x < sw) : (x += 1) {
            const px = dx + x;
            const py = dy + y;
            if (px < 0 or py < 0 or px >= view_w or py >= view_h) continue;
            const si: usize = @intCast((y * @as(i32, @intCast(sw)) + x) * 4);
            if (si + 3 >= src.len) continue;
            if (src[si + 3] == 0) continue;
            const di: usize = @intCast((py * @as(i32, @intCast(dest_w)) + px) * 4);
            if (flash) {
                dest[di] = 255;
                dest[di + 1] = 255;
                dest[di + 2] = 255;
            } else {
                dest[di] = src[si];
                dest[di + 1] = src[si + 1];
                dest[di + 2] = src[si + 2];
            }
            dest[di + 3] = 255;
        }
    }
}

/// Blit RGBA sprite onto screen buffer.
pub fn blitRgba(dest: []u8, dest_w: usize, dx: i32, dy: i32, src: []const u8, sw: u16, sh: u16) void {
    if (src.len == 0 or sw == 0 or sh == 0) return;
    var y: i32 = 0;
    while (y < sh) : (y += 1) {
        var x: i32 = 0;
        while (x < sw) : (x += 1) {
            const px = dx + x;
            const py = dy + y;
            if (px < 0 or py < 0 or px >= view_w or py >= view_h) continue;
            const si: usize = @intCast((y * @as(i32, @intCast(sw)) + x) * 4);
            if (si + 3 >= src.len) continue;
            if (src[si + 3] == 0) continue;
            const di: usize = @intCast((py * @as(i32, @intCast(dest_w)) + px) * 4);
            dest[di] = src[si];
            dest[di + 1] = src[si + 1];
            dest[di + 2] = src[si + 2];
            dest[di + 3] = 255;
        }
    }
}
