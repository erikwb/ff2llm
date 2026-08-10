//! CheckClassEquip + CheckItemEquip — menu/equip.asm @c275 / @bfa6 / @c01a.
//!
//! ItemClasses 32 × 2 @ 0F/A550 (file 0x7A550): job bitmasks.
//! EquipSlotRangeTbl @c0c7, MainHandSlotTbl @bff6, hand two-weapon rules @c046.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const equip = @import("../battle/equip.zig");
const offsets = @import("../offsets.zig");

pub const item_classes_file: usize = offsets.en.item_classes;
pub const item_classes_count: usize = offsets.en.item_classes_count;

/// EquipSlotRangeTbl (equip.asm @c0c7) — min/max item id per UI slot.
/// Order: RH, LH, Head, Body, Arms (EquipSlotPtrTbl $33,$35,$30,$31,$32).
pub const equip_slot_range_tbl = [_][2]u8{
    .{ 0x01, 0x6C }, // 0 R hand
    .{ 0x01, 0x6C }, // 1 L hand
    .{ 0x6D, 0x80 }, // 2 head
    .{ 0x81, 0x9B }, // 3 body
    .{ 0x9C, 0xAF }, // 4 arms
};

/// MainHandSlotTbl @bff6 — UI slot for main hand by handedness index (0..3).
/// Handedness `$1000&$C0` → index via `clc; rol3` ≡ bits 6–7 → 0,1,2,3.
pub const main_hand_slot_tbl = [_]u8{ 2, 1, 0, 2 };

/// Handedness bits (CharProp `$1000` bits 6–7).
/// US party defaults: Cecil etc. `$80` (main = RH slot 0); Kain/Palom `$40` (LH);
/// Yang/Fusoya `$C0` ambidextrous. Rare `$00` → MainHandSlotTbl[0]=2 (unused default).
pub const hand_right: u8 = 0x80; // typical right-hander → main slot 0
pub const hand_left: u8 = 0x40; // → main slot 1
pub const hand_ambi: u8 = 0xC0;

/// True if item id is in inclusive [lo, hi] (CheckItemID @c00a).
pub fn itemIdInRange(id: u8, lo: u8, hi: u8) bool {
    return id >= lo and id <= hi;
}

/// EquipSlotRangeTbl for slot 0..4.
pub fn slotAllowsId(slot: u8, item_id: u8) bool {
    if (item_id == 0) return true; // empty = unequip
    if (slot >= equip_slot_range_tbl.len) return false;
    const r = equip_slot_range_tbl[slot];
    return itemIdInRange(item_id, r[0], r[1]);
}

/// Main hand UI slot from handedness bits (`$1000 & $C0`).
/// ROM: `and #$c0` / if `$c0` ambi → treat both as main; else index = bits>>6 → MainHandSlotTbl.
/// Table `.byte 2,1,0,2`: `$00→2`, `$40→1` (LH), `$80→0` (RH), `$C0` ambi bypass.
pub fn mainHandSlot(handedness: u8) u8 {
    const h = handedness & 0xC0;
    if (h == 0xC0) return 0xFF; // ambi — CheckItemEquip uses main-hand path for both
    const idx: u8 = h >> 6;
    if (idx >= main_hand_slot_tbl.len) return 0;
    return main_hand_slot_tbl[idx];
}

/// True if this equip UI slot is the character's main hand.
pub fn isMainHandSlot(handedness: u8, equip_slot: u8) bool {
    if ((handedness & 0xC0) == 0xC0) return true; // ambi: both hands use main path
    return mainHandSlot(handedness) == equip_slot;
}

/// Weapon/armor category ranges used by CheckItemEquip hand rules.
pub const Range = struct { lo: u8, hi: u8 };
pub const rng_weapon_shield: Range = .{ .lo = 0x00, .hi = 0x5F }; // #$5f00
pub const rng_bow_arrow: Range = .{ .lo = 0x4D, .hi = 0x5F }; // #$5f4d
pub const rng_shield: Range = .{ .lo = 0x61, .hi = 0x6C }; // #$6c61
pub const rng_special_2h: Range = .{ .lo = 0x44, .hi = 0x4C }; // harp/rune/wrench #$4c44
pub const rng_two_hand_wpn: Range = .{ .lo = 0x00, .hi = 0x43 }; // #$4300
pub const rng_bow: Range = .{ .lo = 0x4D, .hi = 0x53 }; // #$534d
pub const rng_arrow: Range = .{ .lo = 0x54, .hi = 0x5F }; // #$5f54
pub const rng_helmet: Range = .{ .lo = 0x6D, .hi = 0x80 };
pub const rng_armor: Range = .{ .lo = 0x81, .hi = 0x9B };
pub const rng_accessory: Range = .{ .lo = 0x9C, .hi = 0xAF };

pub fn inRange(id: u8, r: Range) bool {
    return itemIdInRange(id, r.lo, r.hi);
}

/// Result of CheckItemEquip (hand two-weapon half).
pub const HandEquipResult = enum {
    ok,
    /// Show EquipTwoHandWindow (`$eb` set) — incompatible pair.
    two_hand_conflict,
    /// Wrong category for off-hand / main-hand rules.
    reject,
};

/// CheckItemEquip hand rules after class/slot range pass (@bfba–@c0c5).
/// `equip_slot` 0=RH 1=LH; `other_hand_id` is the item already in the other hand (0=empty).
pub fn checkHandPair(
    equip_slot: u8,
    new_id: u8,
    other_hand_id: u8,
    handedness: u8,
) HandEquipResult {
    if (equip_slot > 1) return .ok; // head/body/arms handled by range only
    if (new_id == 0) return .ok;
    if (new_id >= 0xB0) return .reject;

    const ambi = (handedness & 0xC0) == 0xC0;
    const main = isMainHandSlot(handedness, equip_slot);

    // Category gate (@bfda / @bfe3): main → $00–$5F; off → bows/arrows or shields.
    // Shields $61–$6C allowed on main via separate CheckItemID in ROM fallthrough paths;
    // slot range already limits hands to $01–$6C.
    if (main or ambi) {
        if (!inRange(new_id, rng_weapon_shield) and !inRange(new_id, rng_shield))
            return .reject;
    } else {
        if (!inRange(new_id, rng_bow_arrow) and !inRange(new_id, rng_shield))
            return .reject;
    }

    // Other hand empty → always ok for pair rules
    if (other_hand_id == 0) return .ok;

    // --- pair rules with occupied other hand (@c046) ---
    // Special 2H tools $44–$4C vs anything → two_hand_conflict
    if (inRange(new_id, rng_special_2h) or inRange(other_hand_id, rng_special_2h)) {
        if (inRange(new_id, rng_special_2h) and inRange(other_hand_id, rng_special_2h))
            return .two_hand_conflict;
        if (inRange(new_id, rng_special_2h) or inRange(other_hand_id, rng_special_2h))
            return .two_hand_conflict;
    }

    // Two-hand weapon $00–$43
    if (inRange(new_id, rng_two_hand_wpn)) {
        if (ambi) {
            // Other must also be two-hand weapon
            if (inRange(other_hand_id, rng_two_hand_wpn)) return .ok;
            // else fall to shield pairing
            if (inRange(other_hand_id, rng_shield)) return .ok;
            return .two_hand_conflict;
        }
        // Non-ambi: other must be shield
        if (inRange(other_hand_id, rng_shield)) return .ok;
        return .two_hand_conflict;
    }
    if (inRange(other_hand_id, rng_two_hand_wpn)) {
        // Equipping something with 2H already held: must be shield (or 2H if ambi)
        if (inRange(new_id, rng_shield)) return .ok;
        if (ambi and inRange(new_id, rng_two_hand_wpn)) return .ok;
        return .two_hand_conflict;
    }

    // Shield + non-2H already handled; shield with non-weapon fails below
    if (inRange(new_id, rng_shield)) {
        if (inRange(other_hand_id, rng_two_hand_wpn)) return .ok;
        // shield + shield / shield + 1H weapon: reject pair
        return .two_hand_conflict;
    }

    // Bow + arrows
    if (inRange(new_id, rng_bow)) {
        if (inRange(other_hand_id, rng_arrow)) return .ok;
        return .two_hand_conflict;
    }
    if (inRange(new_id, rng_arrow)) {
        if (inRange(other_hand_id, rng_bow)) return .ok;
        return .two_hand_conflict;
    }
    if (inRange(other_hand_id, rng_bow) or inRange(other_hand_id, rng_arrow)) {
        return .two_hand_conflict;
    }

    // Two 1H weapons: ok for ambi or dual
    if (inRange(new_id, rng_weapon_shield) and inRange(other_hand_id, rng_weapon_shield))
        return .ok;

    return .ok;
}

/// Full CheckItemEquip gate: slot range + class + hand pair.
pub fn checkItemEquip(
    r: *const rom_mod.Rom,
    item_id: u8,
    equip_slot: u8,
    class_id: u8,
    handedness: u8,
    other_hand_id: u8,
) HandEquipResult {
    if (item_id == 0) return .ok;
    if (item_id >= 0xB0) return .reject;
    if (!slotAllowsId(equip_slot, item_id)) return .reject;
    if (!canEquip(r, item_id, class_id)) return .reject;
    return checkHandPair(equip_slot, item_id, other_hand_id, handedness);
}

/// True if `class_id` (battle class / job) may equip `item_id`.
pub fn canEquip(r: *const rom_mod.Rom, item_id: u8, class_id: u8) bool {
    // Consumables / non-equip
    if (item_id == 0 or item_id >= 0xB0) return false;
    const ep = equip.EquipProp.load(r, item_id) orelse return false;
    // ROM uses EquipProp+6 low 5 as class table index
    const idx: usize = ep.class0 & 0x1F;
    if (idx >= item_classes_count) return false;
    const raw = r.slice(item_classes_file + idx * 2, 2) catch return false;
    const mask: u16 = @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    // Job bit: class_id 0 → bit0 (ROM: inc then asl loop → shift count = class+1 from 1)
    const job = (class_id & 0x0F);
    const bit: u16 = @as(u16, 1) << @intCast(job);
    return (mask & bit) != 0;
}

test "EquipSlotRangeTbl hands vs head" {
    try std.testing.expect(slotAllowsId(0, 0x01)); // weapon
    try std.testing.expect(slotAllowsId(0, 0x6C)); // shield max
    try std.testing.expect(!slotAllowsId(0, 0x6D)); // helmet
    try std.testing.expect(slotAllowsId(2, 0x6D));
    try std.testing.expect(slotAllowsId(3, 0x81));
    try std.testing.expect(slotAllowsId(4, 0x9C));
    try std.testing.expect(slotAllowsId(0, 0)); // unequip
}

test "MainHandSlotTbl by handedness" {
    // CharProp: Cecil $80 → index 2 → slot 0 RH; Kain $40 → slot 1 LH
    try std.testing.expectEqual(@as(u8, 0), mainHandSlot(hand_right));
    try std.testing.expectEqual(@as(u8, 1), mainHandSlot(hand_left));
    try std.testing.expectEqual(@as(u8, 2), mainHandSlot(0x00));
    try std.testing.expectEqual(@as(u8, 0xFF), mainHandSlot(hand_ambi));
    try std.testing.expect(isMainHandSlot(hand_right, 0));
    try std.testing.expect(!isMainHandSlot(hand_right, 1));
    try std.testing.expect(isMainHandSlot(hand_left, 1));
    try std.testing.expect(isMainHandSlot(hand_ambi, 0));
}

test "checkHandPair bow requires arrows" {
    // Off-hand (slot 1 for right-hander) bow with empty other: ok
    try std.testing.expectEqual(HandEquipResult.ok, checkHandPair(1, 0x4D, 0, hand_right));
    // Bow + arrows
    try std.testing.expectEqual(HandEquipResult.ok, checkHandPair(1, 0x4D, 0x54, hand_right));
    // Bow + shield = conflict
    try std.testing.expectEqual(HandEquipResult.two_hand_conflict, checkHandPair(1, 0x4D, 0x61, hand_right));
    // Off-hand full weapon for right-hander → reject category
    try std.testing.expectEqual(HandEquipResult.reject, checkHandPair(1, 0x10, 0, hand_right));
}

test "checkHandPair two-hand weapon needs shield" {
    // 2H weapon + shield
    try std.testing.expectEqual(HandEquipResult.ok, checkHandPair(0, 0x20, 0x61, hand_right));
    // 2H + 1H weapon
    try std.testing.expectEqual(HandEquipResult.two_hand_conflict, checkHandPair(0, 0x20, 0x10, hand_right));
    // empty other
    try std.testing.expectEqual(HandEquipResult.ok, checkHandPair(0, 0x20, 0, hand_right));
}

test "checkHandPair special $44-$4C conflicts" {
    try std.testing.expectEqual(HandEquipResult.two_hand_conflict, checkHandPair(0, 0x44, 0x10, hand_right));
    try std.testing.expectEqual(HandEquipResult.ok, checkHandPair(0, 0x44, 0, hand_right));
}

test "canEquip empty false" {
    try std.testing.expect(item_classes_count == 32);
    try std.testing.expectEqual(@as(usize, 5), equip_slot_range_tbl.len);
}
