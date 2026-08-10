//! InitNewGame — field.asm @8290 pure defaults (SoftReset new game path).
//!
//! Clears world/vehicle RAM (`$1700`…), loads InitNPCSwitch / InitEventSwitch,
//! zeros event-extra `$12a0`, and seeds inventory bag end markers at `$149c`.
//!
//! SoftReset then: InitCharProp (Cecil) + InitSpellLists + ExecEvent `$10`.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const inventory_mod = @import("inventory.zig");

/// InitNPCSwitch file offset (LoROM → `$12e0`, 0x40 bytes).
pub const init_npc_switch_file: usize = 0x97200;
/// InitEventSwitch file offset (LoROM → `$1280`, 0x20 bytes).
pub const init_event_switch_file: usize = 0x97240;

pub const npc_switch_len: usize = 0x40;
pub const event_switch_len: usize = 0x20;
/// `$12a0` clear length (InitNewGame @82e6).
pub const event_extra_len: usize = 0x20;

/// Intro event id after New Game (SoftReset `lda #$10` / ExecEvent).
pub const intro_event_id: u8 = 0x10;

/// World map id `$1700` after InitNewGame (stz).
pub const world_id_clear: u8 = 0;
/// `$1703` field leader slot.
pub const field_leader_clear: u8 = 0;
/// `$172c` map stack pointer.
pub const map_stack_clear: u16 = 0;

/// Inventory end markers @ `$149c`–`$149f` (slots 46–47 of `$1440` bag).
/// `lda #$fe / sta $149c`; `lda #1 / sta $149d`; `lda #$ff / sta $149e`; `lda #1 / sta $149f`.
pub const bag_end_slot_a: usize = 46;
pub const bag_end_slot_b: usize = 47;
pub const bag_end_id_a: u8 = 0xFE;
pub const bag_end_id_b: u8 = 0xFF;
pub const bag_end_qty: u8 = 1;

/// Vehicle / parked-vehicle RAM zeros from InitNewGame (field `$170f`…`$172b`).
pub const VehicleClears = struct {
    /// `$1704` vehicle — not stz'd in InitNewGame body but world spawn is foot.
    /// Host clears vehicle with other new-game state.
    vehicle: u8 = 0,
    choco_vis: u8 = 0, // $170f
    // $1712 black choco etc. — host fields zeroed by defaults
    hover_vis: u8 = 0,
    enterprise_vis: u8 = 0,
    falcon_vis: u8 = 0,
    whale_vis: u8 = 0,
    ship_vis: u8 = 0,
};

/// Pure vehicle/world defaults after InitNewGame (no ROM).
pub fn vehicleClears() VehicleClears {
    return .{};
}

/// Apply bag end markers into inventory (InitNewGame @82e6 tail).
pub fn applyBagEndMarkers(inv: *inventory_mod.Inventory) void {
    inv.clear();
    if (bag_end_slot_a < inventory_mod.slot_count) {
        inv.slots[bag_end_slot_a] = .{ .id = bag_end_id_a, .qty = bag_end_qty };
    }
    if (bag_end_slot_b < inventory_mod.slot_count) {
        inv.slots[bag_end_slot_b] = .{ .id = bag_end_id_b, .qty = bag_end_qty };
    }
}

/// Load InitNPCSwitch + InitEventSwitch; zero the host “extra” switch block if provided.
pub fn loadInitSwitches(
    r: *const rom_mod.Rom,
    npc_out: *[npc_switch_len]u8,
    event_out: *[event_switch_len]u8,
    event_extra_out: ?*[event_extra_len]u8,
) !void {
    const npc = try r.slice(init_npc_switch_file, npc_switch_len);
    @memcpy(npc_out[0..], npc);
    const ev = try r.slice(init_event_switch_file, event_switch_len);
    @memcpy(event_out[0..], ev);
    if (event_extra_out) |ex| {
        @memset(ex[0..], 0);
    }
}

/// SoftReset new-game sequence flags (for tests / host docs).
pub const SoftResetNewGame = struct {
    world_id: u8 = world_id_clear,
    field_leader: u8 = field_leader_clear,
    map_stack: u16 = map_stack_clear,
    intro_event: u8 = intro_event_id,
    /// `$b1` event active during intro
    event_enable: bool = true,
};

pub fn softResetNewGameDefaults() SoftResetNewGame {
    return .{};
}

test "InitNewGame vehicle clears all zero" {
    const v = vehicleClears();
    try std.testing.expectEqual(@as(u8, 0), v.vehicle);
    try std.testing.expectEqual(@as(u8, 0), v.whale_vis);
    try std.testing.expectEqual(@as(u8, 0), v.enterprise_vis);
}

test "bag end markers FE qty1 and FF qty1 at slots 46-47" {
    var inv: inventory_mod.Inventory = .{};
    applyBagEndMarkers(&inv);
    try std.testing.expectEqual(bag_end_id_a, inv.slots[46].id);
    try std.testing.expectEqual(bag_end_qty, inv.slots[46].qty);
    try std.testing.expectEqual(bag_end_id_b, inv.slots[47].id);
    try std.testing.expectEqual(bag_end_qty, inv.slots[47].qty);
    // First 46 slots empty
    try std.testing.expectEqual(@as(u8, 0), inv.slots[0].id);
    try std.testing.expectEqual(@as(u8, 0), inv.slots[45].id);
}

test "softResetNewGameDefaults intro $10" {
    const d = softResetNewGameDefaults();
    try std.testing.expectEqual(@as(u8, 0x10), d.intro_event);
    try std.testing.expectEqual(@as(u8, 0), d.world_id);
    try std.testing.expectEqual(@as(u8, 0), d.field_leader);
    try std.testing.expect(d.event_enable);
}

test "loadInitSwitches from ROM when present" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return; // skip if no ROM
    defer r.deinit();
    var npc: [npc_switch_len]u8 = undefined;
    var ev: [event_switch_len]u8 = undefined;
    var extra: [event_extra_len]u8 = undefined;
    try loadInitSwitches(&r, &npc, &ev, &extra);
    for (extra) |b| try std.testing.expectEqual(@as(u8, 0), b);
    const npc2 = try r.slice(init_npc_switch_file, npc_switch_len);
    try std.testing.expectEqualSlices(u8, npc2, npc[0..]);
    const ev2 = try r.slice(init_event_switch_file, event_switch_len);
    try std.testing.expectEqualSlices(u8, ev2, ev[0..]);
}
