//! LoadEquipProp + UpdateCharStats — battle/equip.asm (attack + armor defense).
//!
//! EquipProp 8 bytes @ 0F/9100 (file 0x79100):
//!   [0] flags — bit5 ($20) no back-row penalty; bit7 magnetic
//!       armor: mddddddd metallic + mag.def %
//!   [1] attack (weapon) / defense (armor/shield)
//!   [2] hit% (weapon) / defense % (armor) — low 7
//!   [3] weapon spellcast / armor mag.def base
//!   [4] bit7 shield; low 7 ElementStatus index
//!   [5] creature type bonus
//!   [6] class bits
//!   [7] stat bonus bits
//!
//! Empty armor slots load as item $60 (init.asm LoadEquipProp).
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const status_mod = @import("status.zig");

/// Empty armor placeholder id (init.asm @8ee3).
pub const empty_armor_id: u8 = 0x60;

pub const Hands = struct {
    left: u8 = 0,
    right: u8 = 0,
    handedness: u8 = 0,
};

/// Helmet / armor / accessory ($2030–$2032).
pub const ArmorSlots = struct {
    head: u8 = 0,
    body: u8 = 0,
    arms: u8 = 0, // accessory
};

pub const EquipProp = struct {
    flags: u8,
    /// Attack power (weapon) or defense power (armor/shield).
    attack: u8,
    /// Hit% or defense % (low 7).
    hit: u8,
    /// Mag.def base (armor) / spellcast (weapon).
    mag_def_base: u8 = 0,
    elem_index: u8,
    extra: u8,
    class0: u8,
    class1: u8,
    no_row_penalty: bool,
    /// $2784 bit7 — shield in hand.
    is_shield: bool = false,
    /// Expanded from ElementStatus[elem_index].
    element: u8 = 0,
    status1: u8 = 0,
    status2: u8 = 0,

    pub fn load(r: *const rom_mod.Rom, item_id: u8) ?EquipProp {
        if (item_id == 0) {
            // Unarmed slot 0
            const raw0 = r.slice(offsets.en.equip_properties, 8) catch return null;
            return .{
                .flags = raw0[0],
                .attack = raw0[1],
                .hit = raw0[2] & 0x7F,
                .mag_def_base = raw0[3],
                .elem_index = 0,
                .extra = 0,
                .class0 = 0,
                .class1 = 0,
                .no_row_penalty = false,
            };
        }
        if (item_id >= offsets.en.equip_property_count) return null;
        const off = offsets.en.equip_properties + @as(usize, item_id) * offsets.en.equip_property_stride;
        const raw = r.slice(off, 8) catch return null;
        var ep: EquipProp = .{
            .flags = raw[0],
            .attack = raw[1],
            .hit = raw[2] & 0x7F,
            .mag_def_base = raw[3],
            .elem_index = raw[4] & 0x7F,
            .extra = raw[5],
            .class0 = raw[6],
            .class1 = raw[7],
            .no_row_penalty = (raw[0] & 0x20) != 0,
            .is_shield = (raw[4] & 0x80) != 0,
        };
        const es = status_mod.expandElementStatus(r, ep.elem_index);
        ep.element = es.elem;
        ep.status1 = es.s1;
        ep.status2 = es.s2;
        return ep;
    }

    /// Mag.def % from armor flags low 7 (or full flags & $7F).
    pub fn magDefRate(self: EquipProp) u8 {
        return self.flags & 0x7F;
    }
};

pub fn isWeapon(id: u8) bool {
    return id != 0 and id < 0x4D;
}
pub fn isBow(id: u8) bool {
    return id >= 0x4D and id < 0x54;
}
pub fn isArrow(id: u8) bool {
    return id >= 0x54 and id < 0x61;
}
/// Armor/accessory range (and empty $60).
pub fn isArmorSlot(id: u8) bool {
    return id >= empty_armor_id;
}

pub const CombatStats = struct {
    attack: u16,
    hit_rate: u8,
    attack_mult: u8,
    no_row_penalty: bool,
    dual_wield: bool,
    /// Combined weapon attack element ($2019).
    attack_element: u8 = 0,
    /// Status inflicted on hit ($201e/$201f / fight $269e/$269f).
    inflict_s1: u8 = 0,
    inflict_s2: u8 = 0,
    /// Crit rate / bonus after equip.asm dual/bow adjustments.
    crit_rate: u8 = 1,
    crit_bonus: u8 = 0,
    /// Per-hand attack (for dual display).
    left_atk: u8 = 0,
    right_atk: u8 = 0,
    /// Weapon creature-type bonus ($269a / EquipProp byte5) vs mon $2040.
    creature_atk: u8 = 0,
    /// Armor creature defense ($2727).
    creature_def: u8 = 0,
};

/// UpdateCharStats attack/hit/mult/element/status for non-Yang characters.
pub fn calcCombatStats(
    r: ?*const rom_mod.Rom,
    hands: Hands,
    level: u8,
    strength: u8,
    agility: u8,
) CombatStats {
    const lv4: u16 = level / 4;
    const st4: u16 = strength / 4;
    var mult: u16 = @as(u16, strength) / 8 + @as(u16, agility) / 16 + 1;
    if (mult < 1) mult = 1;
    if (mult > 16) mult = 16;

    var left_w: u8 = hands.left;
    var right_w: u8 = hands.right;
    if (left_w != 0 and !isWeapon(left_w) and !isBow(left_w) and !isArrow(left_w)) left_w = 0;
    if (right_w != 0 and !isWeapon(right_w) and !isBow(right_w) and !isArrow(right_w)) right_w = 0;

    var left_eq: ?EquipProp = null;
    var right_eq: ?EquipProp = null;
    if (r) |rom| {
        if (left_w != 0) left_eq = EquipProp.load(rom, left_w);
        if (right_w != 0) right_eq = EquipProp.load(rom, right_w);
    }

    const has_left = left_eq != null;
    const has_right = right_eq != null;
    const dual = has_left and has_right and isWeapon(left_w) and isWeapon(right_w);
    const bow_pair = (has_left and has_right) and
        ((isBow(left_w) and isArrow(right_w)) or (isArrow(left_w) and isBow(right_w)));

    var atk: u16 = 0;
    var hit: u16 = 0;
    var no_row = false;
    var elem: u8 = 0;
    var inf1: u8 = 0;
    var inf2: u8 = 0;
    var left_atk: u8 = 0;
    var right_atk: u8 = 0;
    var crit_rate: u8 = 1 + level / 20;
    var crit_bonus: u8 = level;
    var creat_atk: u8 = 0;
    const creat_def: u8 = 0;

    if (!has_left and !has_right) {
        var unarmed_hit: u8 = 50;
        if (r) |rom| {
            if (EquipProp.load(rom, 0)) |u| unarmed_hit = u.hit;
        }
        hit = @as(u16, unarmed_hit) +% lv4;
        atk = lv4 +% st4;
    } else if (bow_pair) {
        const bow_eq = if (isBow(left_w)) left_eq.? else right_eq.?;
        const arr_eq = if (isArrow(left_w)) left_eq.? else right_eq.?;
        atk = @as(u16, bow_eq.attack) / 2 +% @as(u16, arr_eq.attack) +% st4;
        hit = @as(u16, bow_eq.hit) +% lv4;
        no_row = true;
        elem = bow_eq.element | arr_eq.element;
        inf1 = bow_eq.status1 | arr_eq.status1;
        inf2 = bow_eq.status2 | arr_eq.status2;
        creat_atk = bow_eq.extra | arr_eq.extra;
        if (crit_rate > 0x21) crit_rate = 0x21;
        crit_rate = @intCast(@min(@as(u16, crit_rate) *% 3, 99));
        crit_bonus = @intCast(@min(@as(u16, crit_bonus) +% arr_eq.attack, 255));
    } else if (dual) {
        const la = @as(u16, left_eq.?.attack) +% lv4 +% st4;
        const ra = @as(u16, right_eq.?.attack) +% lv4 +% st4;
        atk = la +% ra;
        left_atk = left_eq.?.attack;
        right_atk = right_eq.?.attack;
        const lh = @as(u16, left_eq.?.hit) +% lv4;
        const rh = @as(u16, right_eq.?.hit) +% lv4;
        hit = (lh +% rh) / 2;
        no_row = left_eq.?.no_row_penalty or right_eq.?.no_row_penalty;
        elem = left_eq.?.element | right_eq.?.element;
        inf1 = left_eq.?.status1 | right_eq.?.status1;
        inf2 = left_eq.?.status2 | right_eq.?.status2;
        creat_atk = left_eq.?.extra | right_eq.?.extra;
        crit_rate = @intCast(@min(@as(u16, crit_rate) *% 2, 99));
        crit_bonus = @intCast(@min(@as(u16, crit_bonus) +% left_eq.?.attack / 2, 255));
    } else {
        const eq = if (has_left) left_eq.? else right_eq.?;
        const wid = if (has_left) left_w else right_w;
        if (isWeapon(wid) or isBow(wid)) {
            atk = @as(u16, eq.attack) +% lv4 +% st4;
            hit = @as(u16, eq.hit) +% lv4;
            no_row = eq.no_row_penalty;
            elem = eq.element;
            inf1 = eq.status1;
            inf2 = eq.status2;
            creat_atk = eq.extra;
            if (has_left) left_atk = eq.attack else right_atk = eq.attack;
        } else {
            // Shield/non-weapon in hand: unarmed attack (creature_def from calcDefenseStats)
            atk = lv4 +% st4;
            hit = 50 +% lv4;
        }
    }

    if (hit > 99) hit = 99;
    if (atk > 255) atk = 255;

    return .{
        .attack = if (atk == 0) 1 else atk,
        .hit_rate = @intCast(hit),
        .attack_mult = @intCast(mult),
        .no_row_penalty = no_row,
        .dual_wield = dual,
        .attack_element = elem,
        .inflict_s1 = inf1,
        .inflict_s2 = inf2,
        .crit_rate = crit_rate,
        .crit_bonus = crit_bonus,
        .left_atk = left_atk,
        .right_atk = right_atk,
        .creature_atk = creat_atk,
        .creature_def = creat_def,
    };
}

/// Defense / mag.def / creature_def from UpdateCharStats (equip.asm @99a4–@9af3).
pub const DefenseStats = struct {
    defense: u16 = 0,
    defense_rate: u8 = 0,
    defense_mult: u8 = 0,
    mdef: u16 = 0,
    mdef_rate: u8 = 0,
    mdef_mult: u8 = 0,
    creature_def: u8 = 0,
    strong_elem: u8 = 0,
    immune_elem: u8 = 0,
    immune_s1: u8 = 0,
    immune_s2: u8 = 0,
};

fn max99(v: u16) u8 {
    return @intCast(@min(v, 99));
}
fn max255(v: u16) u8 {
    return @intCast(@min(v, 255));
}

/// Port of armor+shield half of UpdateCharStats.
/// `vitality` = stamina ($3968). Empty armor id 0 → treat as $60 when rom present.
pub fn calcDefenseStats(
    r: ?*const rom_mod.Rom,
    armor: ArmorSlots,
    hands: Hands,
    level: u8,
    agility: u8,
    vitality: u8,
    intellect: u8,
    spirit: u8,
) DefenseStats {
    var out: DefenseStats = .{};

    // Load 3 armor pieces (empty → $60)
    var pieces: [3]?EquipProp = .{ null, null, null };
    const ids = [_]u8{ armor.head, armor.body, armor.arms };
    if (r) |rom| {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const id: u8 = if (ids[i] == 0) empty_armor_id else ids[i];
            pieces[i] = EquipProp.load(rom, id);
        }
    }

    // Shields in hands (GetShieldProp)
    var shield_mult: u8 = 0;
    var shield_def: u16 = 0;
    var shield_def_rate: u16 = 0;
    var shield_mdef: u16 = 0;
    var shield_mdef_rate: u16 = 0;
    var shield_creat: u8 = 0;
    var shield_s1: u8 = 0;
    var shield_s2: u8 = 0;
    var shield_elem_l: u8 = 0;
    var shield_elem_r: u8 = 0;

    if (r) |rom| {
        const hand_ids = [_]u8{ hands.left, hands.right };
        for (hand_ids, 0..) |hid, hi| {
            if (hid == 0) continue;
            const eq = EquipProp.load(rom, hid) orelse continue;
            if (!eq.is_shield) continue;
            shield_mult +%= 1;
            shield_def +%= eq.attack;
            shield_def_rate +%= eq.hit;
            shield_mdef +%= eq.mag_def_base;
            shield_mdef_rate +%= eq.magDefRate();
            shield_creat |= eq.extra;
            shield_s1 |= eq.status1;
            shield_s2 |= eq.status2;
            if (hi == 0) shield_elem_l = eq.element else shield_elem_r = eq.element;
        }
    }

    // Creature def: OR of armor creature (byte5) + shields (equip.asm @99a4)
    var creat: u8 = 0;
    for (pieces) |p| {
        if (p) |eq| creat |= eq.extra;
    }
    creat |= shield_creat;
    out.creature_def = creat;

    // Defense mult: (level/16)*shield_mult + agility/8  (@99c0)
    const lv16: u16 = level / 16;
    const def_mult: u16 = lv16 *% shield_mult +% (agility / 8);
    out.defense_mult = max255(def_mult);

    // Defense rate: sum armor def% + shield def% (@99e2) — max 99
    // ROM leaves $aa with immune residue (adamant bug); we sum clean armor+shield.
    var def_rate: u16 = 0;
    for (pieces) |p| {
        if (p) |eq| def_rate +%= eq.hit;
    }
    def_rate +%= shield_def_rate;
    out.defense_rate = max99(def_rate);

    // Defense power: vitality/2 + sum armor def + shields (@9a0e)
    var def_pow: u16 = vitality / 2;
    for (pieces) |p| {
        if (p) |eq| def_pow +%= eq.attack;
    }
    def_pow +%= shield_def;
    out.defense = max255(def_pow);

    // Status immunity from armor + shields
    var is1: u8 = 0;
    var is2: u8 = 0;
    for (pieces) |p| {
        if (p) |eq| {
            is1 |= eq.status1;
            is2 |= eq.status2;
        }
    }
    out.immune_s1 = is1 | shield_s1;
    out.immune_s2 = is2 | shield_s2;

    // Element strong/immune from armor pieces + shields (@9962)
    var strong: u8 = 0;
    var immune: u8 = 0;
    for (pieces) |p| {
        if (p) |eq| {
            if ((eq.element & 0x80) != 0) immune |= eq.element else strong |= eq.element;
        }
    }
    // Shields contribute as elemental resistance list entries
    for ([_]u8{ shield_elem_l, shield_elem_r }) |e| {
        if (e == 0) continue;
        if ((e & 0x80) != 0) immune |= e else strong |= e;
    }
    out.strong_elem = strong;
    out.immune_elem = immune;

    // Mag.def mult: (int+spirit)/32 + agility/32 (@9a81)
    const isum: u16 = @as(u16, intellect) +% spirit;
    out.mdef_mult = max255(isum / 32 +% (agility / 32));

    // Mag.def rate: (int+spirit)/8 + armor mdef% + shield (@9aa7)
    var mrate: u16 = isum / 8;
    for (pieces) |p| {
        if (p) |eq| mrate +%= eq.magDefRate();
    }
    mrate +%= shield_mdef_rate;
    out.mdef_rate = max99(mrate);

    // Mag.def power: sum armor byte3 + shield (@9ad0)
    var mpow: u16 = 0;
    for (pieces) |p| {
        if (p) |eq| mpow +%= eq.mag_def_base;
    }
    mpow +%= shield_mdef;
    out.mdef = max255(mpow);

    return out;
}

test "unarmed combat stats formula" {
    const std = @import("std");
    const cs = calcCombatStats(null, .{}, 10, 13, 10);
    try std.testing.expectEqual(@as(u16, 2 + 3), cs.attack);
    try std.testing.expectEqual(@as(u8, 1 + 0 + 1), cs.attack_mult);
    try std.testing.expect(!cs.dual_wield);
}

test "defense mult no shield is agility/8" {
    const std = @import("std");
    const ds = calcDefenseStats(null, .{}, .{}, 16, 24, 10, 0, 0);
    try std.testing.expectEqual(@as(u8, 24 / 8), ds.defense_mult);
    try std.testing.expectEqual(@as(u16, 10 / 2), ds.defense);
}
