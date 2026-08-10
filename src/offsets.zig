//! File offsets into the *headerless* 1 MiB English FF2 ROM image.
//!
//! Derived from everything8215/ff4 (LoROM map) and verified against
//! Final Fantasy II 1.1 (U), CRC32 0x23084FCD.
//!
//! Japanese versions share most structural layouts; a few English-only
//! tables (e.g. battle command names) sit at slightly different addresses.
const std = @import("std");

pub const en = struct {
    // --- Battle / monster tables (bank $0E) ---
    /// Battle/formation properties (512 × 8). See everything8215/ff4 battle props.
    pub const battle_properties: usize = 0x70000; // 512 * 8
    pub const battle_property_count: usize = 512;
    pub const battle_property_stride: usize = 8;

    // Random battles — field/rand_battle.asm (CPU $0E/C300…)
    /// Overworld battle rate grid 8×8 (region from world x/y).
    pub const overworld_battle_rate: usize = 0x74300; // 64 bytes
    /// Sub-map battle rate per map_id (0 if no random fights — towns/castles).
    pub const sub_battle_rate: usize = 0x74342; // 512 bytes
    pub const underground_battle_rate: usize = 0x74340; // 1 byte
    pub const moon_battle_rate: usize = 0x74341; // 1 byte
    /// Overworld battle group id per region (8×8).
    pub const overworld_battle_grp: usize = 0x74542; // 64 bytes
    pub const underground_battle_grp: usize = 0x74582; // 16 bytes
    pub const moon_battle_grp: usize = 0x74592; // 4 bytes
    /// Sub-map battle group id per map_id.
    pub const sub_battle_grp: usize = 0x74596; // 512 bytes
    /// World formation table: group×8 + slot → battle id (low 8 bits).
    pub const world_battles: usize = 0x74796; // 16 groups × 8
    pub const world_battle_groups: usize = 16;
    /// Sub-map formation table (continues groups for dungeons).
    pub const sub_battles: usize = 0x74816;
    pub const sub_battle_groups: usize = 240; // generous; ROM packs many groups

    pub const monster_positions: usize = 0x71000; // 256 * 8
    /// MonsterCursor 91 × 16 @ 0E/BAC0 (neighbor graph for targeting).
    pub const monster_cursor: usize = 0x73AC0;
    pub const monster_cursor_count: usize = 91;
    pub const monster_cursor_stride: usize = 16;
    pub const monster_names: usize = 0x71800; // 224 * 8
    pub const monster_name_count: usize = 224;
    pub const monster_name_stride: usize = 8;

    pub const monster_items: usize = 0x71F00; // 64 * 4
    pub const monster_gil: usize = 0x72000; // 224 * 2
    pub const monster_exp: usize = 0x721C0; // 224 * 2
    pub const monster_stats: usize = 0x72380; // 224 * 3 (atk/def/mdef parameter triples)
    pub const monster_stat_count: usize = 224;
    pub const monster_stat_stride: usize = 3;

    pub const monster_agility: usize = 0x72620; // 64 * 2
    pub const monster_agility_count: usize = 64;

    pub const monster_prop_ptrs: usize = 0x726A0; // 224 * 2, CPU ptrs in bank $0E
    pub const monster_count: usize = 224;

    // --- Names & equipment (bank $0F) ---
    pub const item_names: usize = 0x78000; // 256 * 9 (icon + 8 chars)
    pub const item_name_count: usize = 256;
    pub const item_name_stride: usize = 9;

    pub const spell_names: usize = 0x78900; // 72 * 6
    pub const spell_name_count: usize = 72;
    pub const spell_name_stride: usize = 6;

    pub const attack_names: usize = 0x78AB0; // 184 * 8
    pub const attack_name_count: usize = 184;
    pub const attack_name_stride: usize = 8;

    /// WeaponMagicHits 96 × 1 @ 0F/9070 (file 0x79070) — hits when weapon casts spell.
    pub const weapon_magic_hits: usize = 0x79070;
    pub const weapon_magic_hits_count: usize = 96;

    pub const equip_properties: usize = 0x79100; // 176 * 8
    pub const equip_property_count: usize = 176;
    pub const equip_property_stride: usize = 8;

    pub const item_properties: usize = 0x79680; // 48 * 6
    pub const item_property_count: usize = 48;
    pub const item_property_stride: usize = 6;

    pub const attack_properties: usize = 0x797A0; // 256 * 6
    pub const attack_property_count: usize = 256;
    pub const attack_property_stride: usize = 6;

    pub const item_prices: usize = 0x7A450; // 256 * 1 (encoded)
    /// ItemClasses 32 × 2 @ 0F/A550 (file 0x7A550) — job equip masks.
    pub const item_classes: usize = 0x7A550;
    pub const item_classes_count: usize = 32;
    /// ShopProp 48 × 8 @ 13/A300 (file 0x9A300).
    pub const shop_prop: usize = 0x9A300;
    pub const shop_prop_count: usize = 48;
    pub const shop_prop_stride: usize = 8;

    pub const character_names: usize = 0x7A710; // 14 * 6
    pub const character_name_count: usize = 14;
    pub const character_name_stride: usize = 6;

    /// CharNameTbl (menu.asm @8457 / btlgfx @fb3f).
    /// `$1000&$1F` is **1-based** character id; DrawCharName does `dec` then this table
    /// yields the name-slot index into CharacterName (0=Cecil, 1=Kain, …).
    pub const char_name_tbl = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x03, 0x00, 0x03, 0x06, 0x09, 0x01, 0x05,
        0x02, 0x0A, 0x0B, 0x01, 0x0C, 0x0D,
    };

    /// Map battle/field char id ($1000&$1F) → index in CharacterName / GameData.characters.
    pub fn charNameIndex(char_id: u8) ?u8 {
        const id = char_id & 0x3F;
        if (id == 0) return null;
        const i: usize = id -% 1;
        if (i >= char_name_tbl.len) return null;
        return char_name_tbl[i];
    }

    pub const character_titles: usize = 0x7A764; // 14 * 6

    /// English command name table (JP map lists 0x7A7B8; EN is shifted).
    pub const battle_command_names: usize = 0x7A7C6; // 32 * 5
    pub const battle_command_name_count: usize = 32;
    pub const battle_command_name_stride: usize = 5;

    pub const character_properties: usize = 0x7A900; // 14 * 32
    pub const character_property_count: usize = 14;
    pub const character_property_stride: usize = 32;

    pub const level_up_ptrs: usize = 0x7B500;
    pub const level_up_data: usize = 0x7B528;

    /// SpellListTbl 16 × 3 @ 13/FDDD (file 0x9FDDD) — white/black/call list ids per char.
    pub const spell_list_tbl: usize = 0x9FDDD;
    pub const spell_list_tbl_count: usize = 16;
    /// SpellListInit 13 × 24 @ 0F/C8C0 (file 0x7C8C0) — spell ids per list.
    pub const spell_list_init: usize = 0x7C8C0;
    pub const spell_list_init_count: usize = 13;
    pub const spell_list_init_stride: usize = 24;

    /// SummonBookTbl 10 bytes @ 13/FEEC (file 0x9FEEC) — RandSummon attacks; bit7 = single target.
    pub const summon_book_tbl: usize = 0x9FEEC;
    pub const summon_book_count: usize = 10;
    /// Summon book inventory item id ($CA).
    pub const summon_book_item: u8 = 0xCA;

    /// BattleSpeedTbl 6 bytes @ 13/FF06 (file 0x9FF06): frames-1 per logic tick.
    /// BattleMain: reload = tbl[setting] + 1 → {1,2,4,6,8,11}. Default config $16ac = 2.
    pub const battle_speed_tbl: usize = 0x9FF06;
    pub const battle_speed_tbl_len: usize = 6;
    pub const battle_speed_default: u8 = 2;

    /// MsgDurTbl 6 × u16 frames @ 0D/F800 (file 0x6F800) — WaitMsgAuto uses $16ad.
    /// Values: $20,$40,$60,$80,$A0,$C0. Default $16ad = 2 → 96 frames.
    pub const msg_dur_tbl: usize = 0x6F800;
    pub const msg_dur_tbl_len: usize = 6;
    pub const msg_speed_default: u8 = 2;
    /// Embedded MsgDurTbl (words LE).
    pub const msg_dur_embed = [_]u16{ 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0 };

    // --- Battle graphics (btlgfx/*) — LoROM file offsets ---
    /// BattleBGProp 17 × 4 @ 0D/FCCB (top, middle, bottom layout, tile offset).
    pub const battle_bg_prop: usize = 0x6FCCB;
    pub const battle_bg_prop_count: usize = 17;
    pub const battle_bg_prop_stride: usize = 4;

    /// BattleBGGfxPtrs 17 × 2 @ 16/FDB4 — pointers into bank $1C.
    pub const battle_bg_gfx_ptrs: usize = 0xB7DB4;
    /// BattleBGGfx bank base (CPU $1C8000 → file 0xE0000); gfx starts at $1CA800.
    pub const battle_bg_gfx_bank: usize = 0xE0000;

    /// BattleBGTopTiles 11 × 256 @ 16/ED80.
    pub const battle_bg_top_tiles: usize = 0xB6D80;
    pub const battle_bg_top_stride: usize = 256;
    /// BattleBGBtmTiles 7 × 64 @ 16/F880 (64-byte pattern, repeated for 10 rows).
    pub const battle_bg_btm_tiles: usize = 0xB7880;
    pub const battle_bg_btm_stride: usize = 64;

    /// BattleBGPal 23 × 32 (16 colors × 2) @ 0F/D200.
    pub const battle_bg_pal: usize = 0x7D200;
    pub const battle_bg_pal_count: usize = 23;
    pub const battle_bg_pal_stride: usize = 32;

    /// MonsterGfxProp 256 × 4 @ 0F/CA00.
    pub const monster_gfx_prop: usize = 0x7CA00;
    pub const monster_gfx_prop_count: usize = 256;
    pub const monster_gfx_prop_stride: usize = 4;

    /// MonsterGfxSize 43 × 2 (w,h in tiles) @ 0D/FF5E.
    pub const monster_gfx_size: usize = 0x6FF5E;
    pub const monster_gfx_size_count: usize = 43;

    /// MonsterPal 240 × 16 bytes (8 colors × 2, 3bpp) @ 1C/EE00.
    pub const monster_pal: usize = 0xE6E00;
    pub const monster_pal_count: usize = 240;
    pub const monster_pal_stride: usize = 16;

    /// MonsterGfx banks $09–$0D (file bases for CPU $x8000).
    pub const monster_gfx_bank: [5]usize = .{ 0x48000, 0x50000, 0x58000, 0x60000, 0x68000 };

    /// BattleCharGfx 17 × $800 @ 1A/8000 (file 0xD0000).
    pub const battle_char_gfx: usize = 0xD0000;
    pub const battle_char_gfx_stride: usize = 0x800;
    pub const battle_char_gfx_count: usize = 17;

    /// BattleCharPal 16 × 32 @ 1C/FD00.
    pub const battle_char_pal: usize = 0xE7D00;
    pub const battle_char_pal_count: usize = 16;
    pub const battle_char_pal_stride: usize = 32;
};

/// Fixed header of a monster property record (first 8 of the 20 bytes loaded by the battle module).
pub const MonsterPropHeader = struct {
    level: u8,
    is_boss: bool,
    hp: u16,
    attack_stat_index: u8,
    defense_stat_index: u8,
    mdef_stat_index: u8,
    agility_index: u8,
    item_drop: u8,

    pub fn parse(raw: []const u8) MonsterPropHeader {
        std.debug.assert(raw.len >= 8);
        return .{
            .level = raw[0] & 0x7F,
            .is_boss = (raw[0] & 0x80) != 0,
            .hp = std.mem.readInt(u16, raw[1..3], .little),
            .attack_stat_index = raw[3],
            .defense_stat_index = raw[4],
            .mdef_stat_index = raw[5],
            .agility_index = raw[6] & 0x3F,
            .item_drop = raw[7],
        };
    }
};

/// Triple from the monster attack/defense parameter table.
pub const MonsterStatTriple = struct {
    a: u8,
    b: u8,
    c: u8,

    pub fn parse(raw: *const [3]u8) MonsterStatTriple {
        return .{ .a = raw[0], .b = raw[1], .c = raw[2] };
    }
};

/// Initial character property block (32 bytes in ROM; field/battle use 64-byte blocks).
///
/// ROM templates hold base stats only. Hands ($2033/$2035) live in the 64-byte
/// field block and are set when the character joins (events), not in this table.
/// Battle LoadCharProp copies $1000 → $2000 (64 bytes); LoadEquipProp reads hands.
pub const CharacterProp = struct {
    raw: [32]u8,

    pub fn idFlags(self: CharacterProp) u8 {
        return self.raw[0];
    }
    /// Bits 6–7 of byte0: handedness ($00 right, $40 left, $80/$C0 ambi).
    pub fn handedness(self: CharacterProp) u8 {
        return self.raw[0] & 0xC0;
    }
    pub fn charId(self: CharacterProp) u8 {
        return self.raw[0] & 0x1F;
    }
    /// Job / graphics id ($1001 & $1F) — ClassCmd, BattleCharGfx, field LoadPlayerGfx.
    pub fn jobId(self: CharacterProp) u8 {
        return self.raw[1] & 0x1F;
    }
    pub fn level(self: CharacterProp) u8 {
        return self.raw[2];
    }
    pub fn hp(self: CharacterProp) u16 {
        return std.mem.readInt(u16, self.raw[7..9], .little);
    }
    pub fn maxHp(self: CharacterProp) u16 {
        return std.mem.readInt(u16, self.raw[9..11], .little);
    }
    pub fn mp(self: CharacterProp) u16 {
        return std.mem.readInt(u16, self.raw[11..13], .little);
    }
    pub fn maxMp(self: CharacterProp) u16 {
        return std.mem.readInt(u16, self.raw[13..15], .little);
    }
    /// Strength / agility / vitality / wisdom / will (observed layout).
    pub fn strength(self: CharacterProp) u8 {
        return self.raw[15];
    }
    pub fn agility(self: CharacterProp) u8 {
        return self.raw[16];
    }
    pub fn vitality(self: CharacterProp) u8 {
        return self.raw[17];
    }
    pub fn wisdom(self: CharacterProp) u8 {
        return self.raw[18];
    }
    pub fn will(self: CharacterProp) u8 {
        return self.raw[19];
    }
};
