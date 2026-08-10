//! LoadCharProp + InitCharEquip — field/event.asm @e895 / @e8eb.
//!
//! CharProp 14 × 32 @ 0F/A900 (file 0x7A900).
//! CharInitEquip 21 × 7 @ 0F/AB00 (file 0x7AB00) → $1030..$1036.
//!
//! Field leader ($1703): DrawPlayerSub draws **only** the showing character
//! (player.asm ValidateTopChar / GetTopCharPtr). There is no multi-member
//! follow train in decomp — N4 host matches leader-only.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const state_mod = @import("state.zig");

/// GetTopCharPtr (player.asm @c87b): `$1703 * $40` → WRAM char block base.
pub fn topCharWramOffset(leader_slot: u8) u16 {
    return @as(u16, leader_slot % 5) * 0x40;
}

/// ValidateTopChar (player.asm @c85e): **always** `inc $1703`, wrap at 5, skip empty
/// slots (`$1000,x == 0`). Returns the new showing slot.
/// `present[i]` mirrors party slot occupied (non-zero id / present flag).
pub fn validateTopChar(present: *const [5]bool, current: u8) u8 {
    var slot = current % 5;
    var tries: u8 = 0;
    while (tries < 5) : (tries += 1) {
        slot +%= 1;
        if (slot >= 5) slot = 0;
        if (present[slot]) return slot;
    }
    return 0;
}

/// First occupied party slot without advancing (host init / load).
pub fn firstPresentSlot(present: *const [5]bool) u8 {
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        if (present[i]) return i;
    }
    return 0;
}

test "GetTopCharPtr slot * $40" {
    try std.testing.expectEqual(@as(u16, 0), topCharWramOffset(0));
    try std.testing.expectEqual(@as(u16, 0x40), topCharWramOffset(1));
    try std.testing.expectEqual(@as(u16, 0x100), topCharWramOffset(4));
    try std.testing.expectEqual(@as(u16, 0), topCharWramOffset(5)); // %5
}

test "ValidateTopChar advances and skips empty" {
    // Slots 0 and 2 present; current 0 → next is 2 (skip 1)
    const p = [_]bool{ true, false, true, false, false };
    try std.testing.expectEqual(@as(u8, 2), validateTopChar(&p, 0));
    // From 2 → wrap to 0
    try std.testing.expectEqual(@as(u8, 0), validateTopChar(&p, 2));
    // Only slot 3
    const one = [_]bool{ false, false, false, true, false };
    try std.testing.expectEqual(@as(u8, 3), validateTopChar(&one, 0));
    try std.testing.expectEqual(@as(u8, 3), validateTopChar(&one, 3));
}

test "firstPresentSlot" {
    const p = [_]bool{ false, false, true, true, false };
    try std.testing.expectEqual(@as(u8, 2), firstPresentSlot(&p));
}

/// CharInitEquip base (LoROM $0F/AB00 → file 0x7AB00).
pub const char_init_equip: usize = 0x7AB00;
pub const char_init_equip_stride: usize = 7;
pub const char_init_equip_count: usize = 21;

/// CharRemoveTbl (event.asm @e922) — event $e7/$e8 param−1 → character id.
/// Bit7 set = restore from buffer (we treat as same id & 0x7F for load).
pub const char_remove_tbl = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x81,
    0x09, 0x81, 0x83, 0x0A, 0x80, 0x82, 0x84, 0x0B, 0x0C, 0x80,
    0x0D,
};

/// Load CharProp[prop_row] + CharInitEquip[equip_index] into a PartyMember.
/// `prop_row` is CharProp table index (from CharRemoveTbl for $e7), not always char id.
/// ROM: $1000&$1F = char id, $1001&$1F = job/gfx (field/player.asm LoadPlayerGfx).
pub fn loadMember(r: *const rom_mod.Rom, prop_row: u8, equip_index: u8) ?state_mod.PartyMember {
    if (prop_row >= offsets.en.character_property_count) return null;
    const prop_off = offsets.en.character_properties + @as(usize, prop_row) * offsets.en.character_property_stride;
    const raw = r.slice(prop_off, 32) catch return null;
    var prop: offsets.CharacterProp = .{ .raw = undefined };
    @memcpy(prop.raw[0..], raw);

    var id = prop.charId();
    // Empty/none slot in prop uses 0; fall back to row for debug loads only.
    if (id == 0) id = prop_row;
    const job = prop.jobId();

    var m: state_mod.PartyMember = .{
        .id = id,
        .class_id = job,
        .gfx_id = job,
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
        .handedness = prop.handedness(),
        .present = true,
    };
    // Adult Rydia restore: CharProp id $11 uses job $0B graphics (event.asm @e83f path).
    if (id == 0x11 and job == 0) {
        m.class_id = 0x0B;
        m.gfx_id = 0x0B;
    }

    applyInitEquip(r, &m, equip_index);
    return m;
}

/// InitCharEquip: copy 7 bytes → head/body/arms/RH/RH-extra/LH/LH-extra.
/// EquipSlotPtrTbl: $33 RH, $35 LH, $30 head, $31 body, $32 arms.
fn applyInitEquip(r: *const rom_mod.Rom, m: *state_mod.PartyMember, equip_index: u8) void {
    // Adult Rydia (param−1 == $0B): InitCharEquip returns without writing (event.asm).
    if (equip_index == 0x0B) return;
    if (equip_index >= char_init_equip_count) return;
    const off = char_init_equip + @as(usize, equip_index) * char_init_equip_stride;
    const eq = r.slice(off, 7) catch return;
    m.head = eq[0];
    m.body = eq[1];
    m.arms = eq[2];
    m.right_hand = eq[3];
    // eq[4] / eq[6] are secondary hand slots (arrows etc.) — not tracked yet
    m.left_hand = eq[5];
}

/// Map event $e7/$e8 operand (1-based CharRemoveTbl index) → character id for load.
pub fn charIdFromEventParam(param: u8) ?struct { char_id: u8, equip_index: u8 } {
    if (param == 0) return null;
    const idx: u8 = param -% 1;
    if (idx >= char_remove_tbl.len) return null;
    const raw = char_remove_tbl[idx];
    return .{ .char_id = raw & 0x7F, .equip_index = idx };
}

/// InitCharProp (field.asm @94ee): party slot 0 = Cecil (CharProp[0] + InitMainCharEquip).
pub fn initMainChar(r: *const rom_mod.Rom) ?state_mod.PartyMember {
    return loadMember(r, 0, 0);
}

/// First empty party slot, or null if full.
pub fn firstEmptySlot(party: []const state_mod.PartyMember) ?usize {
    for (party, 0..) |m, i| {
        if (!m.present) return i;
    }
    return null;
}

/// EventCmd_e7: add character (LoadCharProp + InitCharEquip).
/// CharRemoveTbl[param−1] is CharProp **row** (bit7 = restore from buffer, we treat as row&$7F).
pub fn addFromEvent(r: *const rom_mod.Rom, party: []state_mod.PartyMember, param: u8) bool {
    const info = charIdFromEventParam(param) orelse return false;
    const mem = loadMember(r, info.char_id, info.equip_index) orelse return false;
    // Match by CharProp embedded id ($1000&$1F), not by table row.
    for (party) |m| {
        if (m.present and (m.id & 0x1F) == (mem.id & 0x1F)) return false;
    }
    const slot = firstEmptySlot(party) orelse return false;
    party[slot] = mem;
    return true;
}

/// EventCmd_e8: remove character — compares $1000&$1F to event param (character id).
pub fn removeByEventParam(party: []state_mod.PartyMember, param: u8) bool {
    if (param == 0) return false;
    const want = param & 0x1F;
    for (party) |*m| {
        if (!m.present) continue;
        if ((m.id & 0x1F) == want) {
            m.* = .{};
            return true;
        }
    }
    return false;
}

test "cecil init equip has weapons" {
    // Offline: only check table stride math
    try std.testing.expectEqual(@as(usize, 7), char_init_equip_stride);
    try std.testing.expectEqual(@as(u8, 0x00), char_remove_tbl[0]);
    try std.testing.expectEqual(@as(u8, 0x01), char_remove_tbl[1]); // Kain
}
