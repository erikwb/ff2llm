//! High-level extraction of FF2/FF4 game tables from a loaded ROM.
const std = @import("std");
const rom_mod = @import("rom.zig");
const text = @import("text.zig");
const offsets = @import("offsets.zig");

pub const Monster = struct {
    id: u16,
    name: []const u8,
    level: u8,
    is_boss: bool,
    hp: u16,
    gil: u16,
    exp: u16,
    attack_stat_index: u8,
    defense_stat_index: u8,
    mdef_stat_index: u8,
    agility_index: u8,
    attack_params: offsets.MonsterStatTriple,
    defense_params: offsets.MonsterStatTriple,
    mdef_params: offsets.MonsterStatTriple,
    agility_min: u8,
    agility_max: u8,
    /// First 20 bytes of the property record (as loaded by the battle module).
    prop_raw: [20]u8,
};

pub const ItemName = struct {
    id: u16,
    name: []const u8,
    icon: u8,
};

pub const Character = struct {
    id: u8,
    name: []const u8,
    level: u8,
    hp: u16,
    max_hp: u16,
    mp: u16,
    max_mp: u16,
    strength: u8,
    agility: u8,
    vitality: u8,
    wisdom: u8,
    will: u8,
};

pub const GameData = struct {
    allocator: std.mem.Allocator,
    monsters: []Monster,
    items: []ItemName,
    characters: []Character,
    spell_names: [][]const u8,
    command_names: [][]const u8,

    pub fn deinit(self: *GameData) void {
        for (self.monsters) |m| self.allocator.free(m.name);
        for (self.items) |it| self.allocator.free(it.name);
        for (self.characters) |c| self.allocator.free(c.name);
        for (self.spell_names) |s| self.allocator.free(s);
        for (self.command_names) |s| self.allocator.free(s);
        self.allocator.free(self.monsters);
        self.allocator.free(self.items);
        self.allocator.free(self.characters);
        self.allocator.free(self.spell_names);
        self.allocator.free(self.command_names);
        self.* = undefined;
    }
};

pub const ExtractError = error{
    OutOfRange,
    OutOfMemory,
    UnsupportedVersion,
};

/// Extract English tables. Requires an English ROM (US 1.0 or 1.1).
pub fn extract(gpa: std.mem.Allocator, r: *const rom_mod.Rom) ExtractError!GameData {
    if (r.version == .ff4_jp_1_0 or r.version == .ff4_jp_1_1) {
        return error.UnsupportedVersion;
    }

    const monsters = try extractMonsters(gpa, r);
    errdefer freeMonsters(gpa, monsters);

    const items = try extractItems(gpa, r);
    errdefer freeItems(gpa, items);

    const characters = try extractCharacters(gpa, r);
    errdefer freeCharacters(gpa, characters);

    const spell_names = try extractFixedNames(
        gpa,
        r,
        offsets.en.spell_names,
        offsets.en.spell_name_count,
        offsets.en.spell_name_stride,
        false,
    );
    errdefer freeNames(gpa, spell_names);

    const command_names = try extractFixedNames(
        gpa,
        r,
        offsets.en.battle_command_names,
        offsets.en.battle_command_name_count,
        offsets.en.battle_command_name_stride,
        false,
    );
    errdefer freeNames(gpa, command_names);

    return .{
        .allocator = gpa,
        .monsters = monsters,
        .items = items,
        .characters = characters,
        .spell_names = spell_names,
        .command_names = command_names,
    };
}

fn freeMonsters(gpa: std.mem.Allocator, monsters: []Monster) void {
    for (monsters) |m| gpa.free(m.name);
    gpa.free(monsters);
}
fn freeItems(gpa: std.mem.Allocator, items: []ItemName) void {
    for (items) |it| gpa.free(it.name);
    gpa.free(items);
}
fn freeCharacters(gpa: std.mem.Allocator, characters: []Character) void {
    for (characters) |c| gpa.free(c.name);
    gpa.free(characters);
}
fn freeNames(gpa: std.mem.Allocator, names: [][]const u8) void {
    for (names) |s| gpa.free(s);
    gpa.free(names);
}

fn extractMonsters(gpa: std.mem.Allocator, r: *const rom_mod.Rom) ExtractError![]Monster {
    const o = offsets.en;
    const out = try gpa.alloc(Monster, o.monster_count);
    errdefer gpa.free(out);

    var i: usize = 0;
    errdefer for (out[0..i]) |m| gpa.free(m.name);

    while (i < o.monster_count) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name_raw = try r.slice(o.monster_names + i * o.monster_name_stride, o.monster_name_stride);
        const name = try gpa.dupe(u8, text.decodeFixed(name_raw, &name_buf));

        const ptr = try r.readU16Le(o.monster_prop_ptrs + i * 2);
        const prop_off = rom_mod.Rom.loromOffset(@as(u24, 0x0E0000) | ptr);
        const prop_raw_slice = try r.slice(prop_off, 20);
        var prop_raw: [20]u8 = undefined;
        @memcpy(prop_raw[0..], prop_raw_slice);
        const hdr = offsets.MonsterPropHeader.parse(prop_raw[0..8]);

        const atk = try readStatTriple(r, hdr.attack_stat_index);
        const def = try readStatTriple(r, hdr.defense_stat_index);
        const mdf = try readStatTriple(r, hdr.mdef_stat_index);

        var agi_min: u8 = 0;
        var agi_max: u8 = 0;
        if (hdr.agility_index < o.monster_agility_count) {
            const agi = try r.slice(o.monster_agility + @as(usize, hdr.agility_index) * 2, 2);
            agi_min = agi[0];
            agi_max = agi[1];
        }

        out[i] = .{
            .id = @intCast(i),
            .name = name,
            .level = hdr.level,
            .is_boss = hdr.is_boss,
            .hp = hdr.hp,
            .gil = try r.readU16Le(o.monster_gil + i * 2),
            .exp = try r.readU16Le(o.monster_exp + i * 2),
            .attack_stat_index = hdr.attack_stat_index,
            .defense_stat_index = hdr.defense_stat_index,
            .mdef_stat_index = hdr.mdef_stat_index,
            .agility_index = hdr.agility_index,
            .attack_params = atk,
            .defense_params = def,
            .mdef_params = mdf,
            .agility_min = agi_min,
            .agility_max = agi_max,
            .prop_raw = prop_raw,
        };
    }
    return out;
}

fn readStatTriple(r: *const rom_mod.Rom, index: u8) ExtractError!offsets.MonsterStatTriple {
    const o = offsets.en;
    if (index >= o.monster_stat_count) return .{ .a = 0, .b = 0, .c = 0 };
    const raw = try r.slice(o.monster_stats + @as(usize, index) * o.monster_stat_stride, 3);
    return offsets.MonsterStatTriple.parse(raw[0..3]);
}

fn extractItems(gpa: std.mem.Allocator, r: *const rom_mod.Rom) ExtractError![]ItemName {
    const o = offsets.en;
    const out = try gpa.alloc(ItemName, o.item_name_count);
    errdefer gpa.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |it| gpa.free(it.name);

    while (i < o.item_name_count) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const raw = try r.slice(o.item_names + i * o.item_name_stride, o.item_name_stride);
        const name = try gpa.dupe(u8, text.decodeItemName(raw, &name_buf));
        out[i] = .{ .id = @intCast(i), .name = name, .icon = raw[0] };
    }
    return out;
}

fn extractCharacters(gpa: std.mem.Allocator, r: *const rom_mod.Rom) ExtractError![]Character {
    const o = offsets.en;
    const out = try gpa.alloc(Character, o.character_name_count);
    errdefer gpa.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |c| gpa.free(c.name);

    while (i < o.character_name_count) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name_raw = try r.slice(o.character_names + i * o.character_name_stride, o.character_name_stride);
        const name = try gpa.dupe(u8, text.decodeFixed(name_raw, &name_buf));

        const prop_raw = try r.slice(o.character_properties + i * o.character_property_stride, o.character_property_stride);
        var prop: offsets.CharacterProp = .{ .raw = undefined };
        @memcpy(prop.raw[0..], prop_raw);

        out[i] = .{
            .id = @intCast(i),
            .name = name,
            .level = prop.level(),
            .hp = prop.hp(),
            .max_hp = prop.maxHp(),
            .mp = prop.mp(),
            .max_mp = prop.maxMp(),
            .strength = prop.strength(),
            .agility = prop.agility(),
            .vitality = prop.vitality(),
            .wisdom = prop.wisdom(),
            .will = prop.will(),
        };
    }
    return out;
}

fn extractFixedNames(
    gpa: std.mem.Allocator,
    r: *const rom_mod.Rom,
    base: usize,
    count: usize,
    stride: usize,
    skip_icon: bool,
) ExtractError![][]const u8 {
    const out = try gpa.alloc([]const u8, count);
    errdefer gpa.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |s| gpa.free(s);

    while (i < count) : (i += 1) {
        var name_buf: [48]u8 = undefined;
        const raw = try r.slice(base + i * stride, stride);
        const decoded = if (skip_icon)
            text.decodeItemName(raw, &name_buf)
        else
            text.decodeFixed(raw, &name_buf);
        out[i] = try gpa.dupe(u8, decoded);
    }
    return out;
}
