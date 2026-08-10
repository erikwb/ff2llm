//! Fat Chocobo inventory ($1340) — menu/fat_choco.asm FatChocoGiveItem / FatChocoTakeItem.
//!
//! Storage: `$7e` (126) slots of {id, qty} at WRAM $1340.
//! Give: party bag $1440 → fat bag; reject empty / $19 / $C8 / key≥$EE; stack to 99.
//! Take: fat bag → party; fail if party full (48 slots, "organize your bag").
const std = @import("std");
const inventory_mod = @import("inventory.zig");

/// Fat chocobo inventory capacity (`$7e` in FatChocoGiveItem loop).
pub const slot_count: usize = 0x7E;

pub const Slot = inventory_mod.Slot;

pub const Bag = struct {
    slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,

    pub fn clear(self: *Bag) void {
        self.slots = [_]Slot{.{}} ** slot_count;
    }

    /// Bytes for save (id,qty × N).
    pub fn asBytes(self: *const Bag) []const u8 {
        return std.mem.sliceAsBytes(self.slots[0..]);
    }

    pub fn asBytesMut(self: *Bag) []u8 {
        return std.mem.sliceAsBytes(self.slots[0..]);
    }

    pub fn fromBytes(self: *Bag, raw: []const u8) void {
        const dest = self.asBytesMut();
        const n = @min(raw.len, dest.len);
        @memcpy(dest[0..n], raw[0..n]);
    }
};

/// FatChocoGiveItem rejects (menu/fat_choco.asm @cfb7): empty, $19, $C8, id ≥ $EE.
pub fn canGiveItemId(id: u8) bool {
    if (id == 0 or id == 0x19 or id == 0xC8) return false;
    if (id >= 0xEE) return false; // key items / event
    return true;
}

pub const GiveResult = enum {
    ok,
    /// Item type not accepted (key / $19 / $C8 / empty).
    reject_item,
    /// Fat bag full and no stack room (Msg5 "i can't eat any more").
    fat_full,
    /// Party slot empty / missing.
    no_party_item,
};

pub const TakeResult = enum {
    ok,
    /// Fat slot empty.
    empty,
    /// Party inventory full (Msg6 "organize your bag!").
    party_full,
};

/// Move one party bag stack at `party_slot` into fat bag (whole qty).
/// Mirrors FatChocoGiveItem: find matching stack with room < 99, else empty fat slot.
pub fn giveFromParty(fat: *Bag, party: *inventory_mod.Inventory, party_slot: usize) GiveResult {
    if (party_slot >= inventory_mod.slot_count) return .no_party_item;
    const ps = &party.slots[party_slot];
    if (ps.id == 0 or ps.qty == 0) return .no_party_item;
    if (!canGiveItemId(ps.id)) return .reject_item;

    // Prefer merge into existing fat stack with room
    var empty_i: ?usize = null;
    var i: usize = 0;
    while (i < slot_count) : (i += 1) {
        const fs = &fat.slots[i];
        if (fs.id == 0) {
            if (empty_i == null) empty_i = i;
            continue;
        }
        if (fs.id == ps.id) {
            const sum: u16 = @as(u16, fs.qty) +% @as(u16, ps.qty);
            if (sum < 100) { // cmp #$64 → room if sum ≤ 99
                fs.qty = @intCast(sum);
                ps.* = .{};
                return .ok;
            }
        }
    }
    if (empty_i) |ei| {
        fat.slots[ei] = .{ .id = ps.id, .qty = ps.qty };
        ps.* = .{};
        return .ok;
    }
    return .fat_full;
}

/// Move fat bag slot into party (whole stack). FatChocoTakeItem @d01a.
pub fn takeToParty(fat: *Bag, party: *inventory_mod.Inventory, fat_slot: usize) TakeResult {
    if (fat_slot >= slot_count) return .empty;
    const fs = &fat.slots[fat_slot];
    if (fs.id == 0 or fs.qty == 0) return .empty;

    // Find empty party slot ($30 = 48)
    var i: usize = 0;
    while (i < inventory_mod.slot_count) : (i += 1) {
        if (party.slots[i].id == 0) {
            party.slots[i] = .{ .id = fs.id, .qty = fs.qty };
            fs.* = .{};
            return .ok;
        }
    }
    return .party_full;
}

// --- TreasureMenu packing (menu/treasure.asm @d7b0) ---

/// Pack treasure payload `$1804..$180b` (8 item ids) into list entries {id, qty}.
/// Arrows `$54`–`$5F` → qty 10; others qty 1; 0 → empty.
pub const TreasureEntry = struct { id: u8 = 0, qty: u8 = 0 };

pub fn packTreasureList(item_ids: []const u8, out: []TreasureEntry) usize {
    var n: usize = 0;
    for (item_ids) |id| {
        if (n >= out.len) break;
        if (id == 0) {
            out[n] = .{};
            n += 1;
            continue;
        }
        const qty: u8 = if (id >= 0x54 and id < 0x60) 10 else 1;
        out[n] = .{ .id = id, .qty = qty };
        n += 1;
    }
    return n;
}

/// Grant packed treasure into party inventory (GiveItem-style per entry).
pub fn grantTreasure(party: *inventory_mod.Inventory, entries: []const TreasureEntry) u8 {
    var given: u8 = 0;
    for (entries) |e| {
        if (e.id == 0) continue;
        var left = e.qty;
        while (left > 0) {
            // give() always adds arrow-as-10 if id in range — for treasure already qty=10
            // once per arrow type is correct (TreasureMenu puts qty 10 once).
            if (!party.give(e.id)) break;
            if (e.id >= 0x54 and e.id < 0x60) {
                left = 0; // one give() already stacked 10
            } else {
                left -%= 1;
            }
            given +%= 1;
        }
    }
    return given;
}

test "canGiveItemId rejects key and specials" {
    try std.testing.expect(canGiveItemId(0x01));
    try std.testing.expect(!canGiveItemId(0));
    try std.testing.expect(!canGiveItemId(0x19));
    try std.testing.expect(!canGiveItemId(0xC8));
    try std.testing.expect(!canGiveItemId(0xEE));
    try std.testing.expect(!canGiveItemId(0xFA));
}

test "give and take round-trip" {
    var fat: Bag = .{};
    var party: inventory_mod.Inventory = .{};
    party.slots[0] = .{ .id = 0xCE, .qty = 3 }; // potion-ish consumable
    try std.testing.expect(giveFromParty(&fat, &party, 0) == .ok);
    try std.testing.expectEqual(@as(u8, 0), party.slots[0].id);
    try std.testing.expectEqual(@as(u8, 0xCE), fat.slots[0].id);
    try std.testing.expectEqual(@as(u8, 3), fat.slots[0].qty);
    try std.testing.expect(takeToParty(&fat, &party, 0) == .ok);
    try std.testing.expectEqual(@as(u8, 0xCE), party.slots[0].id);
    try std.testing.expectEqual(@as(u8, 0), fat.slots[0].id);
}

test "give rejects key item" {
    var fat: Bag = .{};
    var party: inventory_mod.Inventory = .{};
    party.slots[0] = .{ .id = 0xEF, .qty = 1 }; // baron key
    try std.testing.expect(giveFromParty(&fat, &party, 0) == .reject_item);
}

test "take fails when party full" {
    var fat: Bag = .{};
    var party: inventory_mod.Inventory = .{};
    fat.slots[0] = .{ .id = 0xCE, .qty = 1 };
    for (&party.slots) |*s| s.* = .{ .id = 0x01, .qty = 1 };
    try std.testing.expect(takeToParty(&fat, &party, 0) == .party_full);
}

test "packTreasureList arrows qty 10" {
    const ids = [_]u8{ 0x54, 0xCE, 0x00 };
    var out: [8]TreasureEntry = undefined;
    const n = packTreasureList(&ids, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 0x54), out[0].id);
    try std.testing.expectEqual(@as(u8, 10), out[0].qty);
    try std.testing.expectEqual(@as(u8, 1), out[1].qty);
    try std.testing.expectEqual(@as(u8, 0), out[2].id);
}
