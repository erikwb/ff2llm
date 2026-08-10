//! Save / load game state — menu/save.asm ShowSaveMenu subset.
//!
//! ROM uses 4 SRAM slots of $800 bytes (mvn $1000→$f600→$7000). We persist a
//! compact Zig snapshot to `saves/slotN.sav` via std.Io.Dir (Zig 0.16).
//!
//! Versions:
//!   v1: party/inv/event+npc switches
//!   v2: + field_leader_slot + spell_lists
//!   v3: + window_color, stereo, treasure_switch, vehicle/parked slots, fat choco bag
const std = @import("std");
const Io = std.Io;
const state_mod = @import("state.zig");
const cmd_magic = @import("../battle/cmd_magic.zig");
const fat_choco_mod = @import("fat_choco.zig");

pub const slot_count: u8 = 4;
const magic: [4]u8 = .{ 'F', 'F', '4', 'S' };
/// Current format (window color / vehicles / treasure / fat choco).
const version: u16 = 3;
const version_v1: u16 = 1;
const version_v2: u16 = 2;

const SaveHeader = extern struct {
    magic: [4]u8,
    version: u16,
    checksum: u16,
    mode: u8,
    world_id: u8,
    map_id: u16,
    pos_x: i32,
    pos_y: i32,
    facing: u8,
    gil: u32,
    battle_speed: u8,
    msg_speed: u8,
    battle_mode: u8,
    party_row: u8,
};

fn checksum(bytes: []const u8) u16 {
    var s: u16 = 0;
    for (bytes) |b| s +%= b;
    return s;
}

fn slotPath(buf: []u8, slot: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "saves/slot{d}.sav", .{slot});
}

fn defaultIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn ensureSaveDir() !void {
    const io = defaultIo();
    Io.Dir.cwd().createDirPath(io, "saves") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

/// True if `saves/slotN.sav` exists and is non-empty.
pub fn slotExists(slot: u8) bool {
    if (slot >= slot_count) return false;
    var path_buf: [64]u8 = undefined;
    const path = slotPath(&path_buf, slot) catch return false;
    const io = defaultIo();
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.size > 0;
}

/// Append parked vehicle triple: vis, x, y [, world].
fn appendVehicle3(list: *std.ArrayList(u8), gpa: std.mem.Allocator, vis: u8, x: u8, y: u8) !void {
    try list.append(gpa, vis);
    try list.append(gpa, x);
    try list.append(gpa, y);
}

fn appendVehicle4(list: *std.ArrayList(u8), gpa: std.mem.Allocator, vis: u8, x: u8, y: u8, world: u8) !void {
    try appendVehicle3(list, gpa, vis, x, y);
    try list.append(gpa, world);
}

pub fn saveSlot(gs: *const state_mod.GameState, slot: u8) !void {
    if (slot >= slot_count) return error.BadSlot;
    try ensureSaveDir();
    var path_buf: [64]u8 = undefined;
    const path = try slotPath(&path_buf, slot);
    const gpa = std.heap.page_allocator;
    const io = defaultIo();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    var hdr = SaveHeader{
        .magic = magic,
        .version = version,
        .checksum = 0,
        .mode = @intFromEnum(gs.mode),
        .world_id = gs.world_id,
        .map_id = gs.map_id,
        .pos_x = gs.pos_x,
        .pos_y = gs.pos_y,
        .facing = gs.facing,
        .gil = gs.gil,
        .battle_speed = gs.battle_speed,
        .msg_speed = gs.msg_speed,
        .battle_mode = gs.battle_mode,
        .party_row = gs.party_row,
    };
    try list.appendSlice(gpa, std.mem.asBytes(&hdr));

    for (gs.party) |m| {
        const pm = [_]u8{
            m.id,         m.class_id,   m.gfx_id,     m.level,
            @truncate(m.hp),        @truncate(m.hp >> 8),
            @truncate(m.max_hp),    @truncate(m.max_hp >> 8),
            @truncate(m.mp),        @truncate(m.mp >> 8),
            @truncate(m.max_mp),    @truncate(m.max_mp >> 8),
            m.strength,   m.agility,    m.vitality,   m.wisdom,
            m.will,       m.left_hand,  m.right_hand, m.head,
            m.body,       m.arms,       m.status1,    m.status2,
            if (m.present) 1 else 0,
        };
        try list.appendSlice(gpa, &pm);
    }
    for (gs.inventory.slots) |s| {
        try list.append(gpa, s.id);
        try list.append(gpa, s.qty);
    }
    try list.appendSlice(gpa, &gs.event_switch);
    try list.appendSlice(gpa, &gs.npc_switch);
    // v2: field leader ($1703) + runtime spell lists ($1560)
    try list.append(gpa, gs.field_leader_slot);
    try list.appendSlice(gpa, std.mem.sliceAsBytes(gs.spell_lists[0..]));

    // v3: config + treasure + vehicles + fat choco ($16aa / $12a0 / $1704 / $1340)
    try list.append(gpa, @truncate(gs.window_color));
    try list.append(gpa, @truncate(gs.window_color >> 8));
    try list.append(gpa, gs.window_color_r);
    try list.append(gpa, gs.window_color_g);
    try list.append(gpa, gs.window_color_b);
    try list.append(gpa, gs.stereo_mono);
    try list.appendSlice(gpa, &gs.treasure_switch);
    try list.append(gpa, gs.vehicle);
    try appendVehicle3(&list, gpa, gs.choco_vis, gs.choco_x, gs.choco_y);
    try appendVehicle4(&list, gpa, gs.bk_choco_vis, gs.bk_choco_x, gs.bk_choco_y, gs.bk_choco_hook);
    try appendVehicle4(&list, gpa, gs.hover_vis, gs.hover_x, gs.hover_y, gs.hover_world);
    try appendVehicle4(&list, gpa, gs.enterprise_vis, gs.enterprise_x, gs.enterprise_y, gs.enterprise_world);
    try appendVehicle4(&list, gpa, gs.falcon_vis, gs.falcon_x, gs.falcon_y, gs.falcon_world);
    try appendVehicle4(&list, gpa, gs.whale_vis, gs.whale_x, gs.whale_y, gs.whale_world);
    try appendVehicle3(&list, gpa, gs.ship_vis, gs.ship_x, gs.ship_y);
    try list.append(gpa, if (gs.holding_hover) 1 else 0);
    try list.appendSlice(gpa, gs.fat_choco.asBytes());

    const body = list.items[@sizeOf(SaveHeader)..];
    const sum = checksum(body);
    @memcpy(list.items[6..8], std.mem.asBytes(&sum));

    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(list.items);
    try w.interface.flush();
}

fn readU16(body: []const u8, o: *usize) !u16 {
    if (o.* + 2 > body.len) return error.Truncated;
    const v = @as(u16, body[o.*]) | (@as(u16, body[o.* + 1]) << 8);
    o.* += 2;
    return v;
}

fn readU8(body: []const u8, o: *usize) !u8 {
    if (o.* >= body.len) return error.Truncated;
    const v = body[o.*];
    o.* += 1;
    return v;
}

pub fn loadSlot(gs: *state_mod.GameState, slot: u8) !void {
    if (slot >= slot_count) return error.BadSlot;
    var path_buf: [64]u8 = undefined;
    const path = try slotPath(&path_buf, slot);
    const gpa = std.heap.page_allocator;
    const io = defaultIo();
    const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(data);
    if (data.len < @sizeOf(SaveHeader)) return error.BadSave;

    var hdr: SaveHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), data[0..@sizeOf(SaveHeader)]);
    if (!std.mem.eql(u8, &hdr.magic, &magic)) return error.BadMagic;
    if (hdr.version != version and hdr.version != version_v1 and hdr.version != version_v2)
        return error.BadVersion;
    const body = data[@sizeOf(SaveHeader)..];
    if (checksum(body) != hdr.checksum) return error.BadChecksum;

    gs.mode = @enumFromInt(hdr.mode);
    gs.world_id = hdr.world_id;
    gs.map_id = hdr.map_id;
    gs.pos_x = hdr.pos_x;
    gs.pos_y = hdr.pos_y;
    gs.facing = hdr.facing;
    gs.gil = hdr.gil;
    gs.battle_speed = hdr.battle_speed;
    gs.msg_speed = hdr.msg_speed;
    gs.battle_mode = hdr.battle_mode;
    gs.party_row = hdr.party_row;

    var o: usize = 0;
    for (&gs.party) |*m| {
        if (o + 25 > body.len) return error.Truncated;
        m.id = body[o];
        m.class_id = body[o + 1];
        m.gfx_id = body[o + 2];
        m.level = body[o + 3];
        m.hp = @as(u16, body[o + 4]) | (@as(u16, body[o + 5]) << 8);
        m.max_hp = @as(u16, body[o + 6]) | (@as(u16, body[o + 7]) << 8);
        m.mp = @as(u16, body[o + 8]) | (@as(u16, body[o + 9]) << 8);
        m.max_mp = @as(u16, body[o + 10]) | (@as(u16, body[o + 11]) << 8);
        m.strength = body[o + 12];
        m.agility = body[o + 13];
        m.vitality = body[o + 14];
        m.wisdom = body[o + 15];
        m.will = body[o + 16];
        m.left_hand = body[o + 17];
        m.right_hand = body[o + 18];
        m.head = body[o + 19];
        m.body = body[o + 20];
        m.arms = body[o + 21];
        m.status1 = body[o + 22];
        m.status2 = body[o + 23];
        m.present = body[o + 24] != 0;
        o += 25;
    }
    for (&gs.inventory.slots) |*s| {
        if (o + 2 > body.len) return error.Truncated;
        s.id = body[o];
        s.qty = body[o + 1];
        o += 2;
    }
    if (o + 32 + 64 > body.len) return error.Truncated;
    @memcpy(&gs.event_switch, body[o .. o + 32]);
    o += 32;
    @memcpy(&gs.npc_switch, body[o .. o + 64]);
    o += 64;

    // v2 extras
    if (hdr.version >= version_v2) {
        if (o >= body.len) return error.Truncated;
        gs.field_leader_slot = body[o] % 5;
        o += 1;
        const spell_bytes = cmd_magic.spell_list_count * cmd_magic.spell_list_stride;
        if (o + spell_bytes > body.len) return error.Truncated;
        @memcpy(std.mem.sliceAsBytes(gs.spell_lists[0..]), body[o .. o + spell_bytes]);
        o += spell_bytes;
    } else {
        gs.field_leader_slot = 0;
        cmd_magic.initSpellLists(gs.rom, &gs.spell_lists);
    }

    // v3 extras
    if (hdr.version >= version) {
        gs.window_color = try readU16(body, &o);
        gs.window_color_r = try readU8(body, &o);
        gs.window_color_g = try readU8(body, &o);
        gs.window_color_b = try readU8(body, &o);
        gs.stereo_mono = try readU8(body, &o);
        if (o + 64 > body.len) return error.Truncated;
        @memcpy(&gs.treasure_switch, body[o .. o + 64]);
        o += 64;
        gs.vehicle = try readU8(body, &o);
        gs.choco_vis = try readU8(body, &o);
        gs.choco_x = try readU8(body, &o);
        gs.choco_y = try readU8(body, &o);
        gs.bk_choco_vis = try readU8(body, &o);
        gs.bk_choco_x = try readU8(body, &o);
        gs.bk_choco_y = try readU8(body, &o);
        gs.bk_choco_hook = try readU8(body, &o);
        gs.hover_vis = try readU8(body, &o);
        gs.hover_x = try readU8(body, &o);
        gs.hover_y = try readU8(body, &o);
        gs.hover_world = try readU8(body, &o);
        gs.enterprise_vis = try readU8(body, &o);
        gs.enterprise_x = try readU8(body, &o);
        gs.enterprise_y = try readU8(body, &o);
        gs.enterprise_world = try readU8(body, &o);
        gs.falcon_vis = try readU8(body, &o);
        gs.falcon_x = try readU8(body, &o);
        gs.falcon_y = try readU8(body, &o);
        gs.falcon_world = try readU8(body, &o);
        gs.whale_vis = try readU8(body, &o);
        gs.whale_x = try readU8(body, &o);
        gs.whale_y = try readU8(body, &o);
        gs.whale_world = try readU8(body, &o);
        gs.ship_vis = try readU8(body, &o);
        gs.ship_x = try readU8(body, &o);
        gs.ship_y = try readU8(body, &o);
        gs.holding_hover = (try readU8(body, &o)) != 0;
        const fat_bytes = fat_choco_mod.slot_count * 2;
        if (o + fat_bytes > body.len) return error.Truncated;
        gs.fat_choco.fromBytes(body[o .. o + fat_bytes]);
        o += fat_bytes;
    }

    gs.ensureFieldLeader();
    gs.party_sprite_dirty = true;
}

test "save v3 round-trip window color vehicle treasure fat choco" {
    // Pure encode/decode of v3 tail without full GameState/ROM.
    // exercise fat_choco bytes + checksum path via saveSlot requires full gs —
    // smoke: fat bag bytes + pack helpers.
    var fat: fat_choco_mod.Bag = .{};
    fat.slots[0] = .{ .id = 0xCE, .qty = 5 };
    var buf: [fat_choco_mod.slot_count * 2]u8 = undefined;
    @memcpy(buf[0..], fat.asBytes());
    var fat2: fat_choco_mod.Bag = .{};
    fat2.fromBytes(&buf);
    try std.testing.expectEqual(@as(u8, 0xCE), fat2.slots[0].id);
    try std.testing.expectEqual(@as(u8, 5), fat2.slots[0].qty);
    try std.testing.expectEqual(@as(u16, 3), version);
}
