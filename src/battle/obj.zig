//! Battle object slots — subset of $2000,x character/monster blocks (init.asm).
//!
//! Slots 0–4 party, 5–12 monsters (8).
const std = @import("std");
const data_mod = @import("../data.zig");
const prop = @import("prop.zig");
const rom_mod = @import("../rom.zig");
const equip = @import("equip.zig");
const status_mod = @import("status.zig");

pub const party_slots: usize = 5;
pub const mon_slots: usize = 8;
pub const total_slots: usize = party_slots + mon_slots;

pub const Obj = struct {
    present: bool = false,
    type_id: u8 = 0,
    name: []const u8 = "",
    level: u8 = 1,
    hp: u16 = 0,
    max_hp: u16 = 0,
    mp: u16 = 0,
    max_mp: u16 = 0,
    strength: u8 = 1,
    agility: u8 = 1,
    /// Intellect ($2017) — Bluff raises this (magic accuracy).
    intellect: u8 = 0,
    /// Physical attack power ($201d after UpdateCharStats).
    attack: u16 = 10,
    defense: u16 = 5,
    /// Defense rate for CalcHits defend side ($2729).
    /// InitMonster writes rate then power both to $202A (ROM bug) so rate stays 0
    /// unless ChangeMonsterStat $EA fills $2029 correctly.
    defense_rate: u8 = 0,
    defense_mult: u8 = 1,
    /// Mag.def multiplier / rate / power ($2022 / $2023 / $2024).
    /// Init same double-store bug as phys def: rate never lands on $2023.
    mdef_mult: u8 = 0,
    mdef_rate: u8 = 0,
    mdef: u16 = 0,
    /// Spirit ($2018) — white-magic hit/hits base (party will).
    spirit: u8 = 0,
    /// Vitality / stamina ($2016) — defense formula.
    vitality: u8 = 0,
    /// Hit rate 0..=99 ($201c). No invented default — 0 means always miss.
    hit_rate: u8 = 0,
    /// Attack multiplier / base hits ($201b).
    attack_mult: u8 = 2,
    crit_rate: u8 = 1,
    crit_bonus: u8 = 0,
    /// Attack element ($2019).
    attack_element: u8 = 0,
    /// Status inflicted on physical hit ($201e/$201f).
    inflict_s1: u8 = 0,
    inflict_s2: u8 = 0,
    /// Elemental affinities (target).
    weak_elem: u8 = 0,
    strong_elem: u8 = 0,
    immune_elem: u8 = 0,
    very_weak_elem: u8 = 0,
    /// Status immunity ($272b/$272c).
    immune_s1: u8 = 0,
    immune_s2: u8 = 0,
    /// Boss flag ($2070 bit7).
    is_boss: bool = false,
    /// Creature type bits ($2040 mon / race).
    creature_type: u8 = 0,
    /// Attack strong vs creature ($269a) from weapon EquipProp byte5.
    creature_atk: u8 = 0,
    /// Defense strong vs creature ($2727) from armor.
    creature_def: u8 = 0,
    /// Monster item set index (low 6 of prop drop byte) for Steal.
    item_set: u8 = 0,
    /// AIAction script index (0xFF = none → default fight).
    ai_action_id: u8 = 0xFF,
    /// $38aa: mon has retaliation scripts (prop $28a5 bit2) — DoRetal gate.
    has_retal: bool = false,
    /// Row: 0 front, 1 back ($2001 bit7 in ROM).
    row: u8 = 0,
    /// $2003–$2006 status.
    status: status_mod.Status = .{},
    /// Weapon has no back-row penalty (e.g. bow/long) — $2001 bit5.
    no_row_penalty: bool = false,
    dual_wield: bool = false,
    /// Cover: slot covering this unit (0xFF = none). Coverer has pending cover.
    cover_by: u8 = 0xFF,
    /// Cover: who we are covering (for Cecil Cmd_13).
    covering_slot: u8 = 0xFF,
    /// Slot index 0..12 for first-party-slot hit bonus.
    slot_index: u8 = 0,
    /// Sprite top-left in screen pixels (DrawMonster / CharSpriteDefault*).
    screen_x: u8 = 0,
    screen_y: u8 = 0,
    /// Composed sprite size in pixels (from MonsterGfxSize / char 16×24).
    sprite_w: u16 = 16,
    sprite_h: u16 = 24,
    /// Hands ($2033 / $2035) — item ids.
    left_hand: u8 = 0,
    right_hand: u8 = 0,
    /// Helmet / armor / accessory ($2030–$2032).
    head: u8 = 0,
    body: u8 = 0,
    arms: u8 = 0,
    /// Character / class id for SpellListTbl + ClassCmd (party only).
    char_id: u8 = 0,
    class_id: u8 = 0,
    /// BattleCharGfx id (party only).
    gfx_id: u8 = 0,
    /// Base timer duration ($2060) before speed mod.
    base_timer: u16 = 1,
    /// Speed modifier ($203b), default $10.
    speed_mod: u16 = 16,
    action_timer: u16 = 0,
    action_ready: bool = false,
    /// Status timers (reload value stored for poison re-queue).
    poison_timer: u16 = 0,
    poison_reload: u16 = 0,
    stop_timer: u16 = 0,
    sap_timer: u16 = 0,
    sap_reload: u16 = 0,
    doom_timer: u16 = 0,
    /// Gradual petrify re-arm (TimerEffect_04).
    petrify_timer: u16 = 0,
    petrify_reload: u16 = 0,
    /// Reflect duration (TimerEffect_05).
    reflect_timer: u16 = 0,
    /// Jump: land after this many action ticks (Cmd_06 sets ~4).
    jump_timer: u16 = 0,
    /// Pending jump2 attack target when landing.
    jump_target: u8 = 0xFF,
    is_monster: bool = false,

    pub fn blind(self: Obj) bool {
        return self.status.isBlind();
    }
    pub fn defending(self: Obj) bool {
        return self.status.isDefending();
    }
    pub fn setDefending(self: *Obj, on: bool) void {
        self.status.setDefend(on);
    }
    pub fn jumping(self: Obj) bool {
        return self.status.isJumping();
    }

    /// UpdateMonsterPos cursor X — hand points at monster (sprite_x − 8).
    pub fn monCursorX(self: Obj) i32 {
        const sx: i32 = self.screen_x;
        return sx -% 8;
    }

    /// UpdateMonsterPos cursor Y: sprite_y + height_tiles*4 − 4.
    pub fn monCursorY(self: Obj) i32 {
        const ht: i32 = if (self.sprite_h >= 8)
            @divTrunc(@as(i32, @intCast(self.sprite_h)), 8)
        else
            4;
        return @as(i32, self.screen_y) + ht * 4 - 4;
    }

    /// Damage floater / hit spark origin.
    /// Monsters: UpdateMonsterPos cursor (sprite_x−8, y+height*4−4) is the ROM
    /// target point used near ShowMsg_04 / hit positions ($f043 family).
    /// Party: geometric mid-sprite (char default tables already place feet).
    pub fn centerX(self: Obj) i32 {
        if (self.is_monster) {
            // Hand/cursor X is left of body; numerals sit slightly right of that.
            return self.monCursorX() + 8;
        }
        return @as(i32, self.screen_x) + @divTrunc(@as(i32, @intCast(self.sprite_w)), 2);
    }
    pub fn centerY(self: Obj) i32 {
        if (self.is_monster) return self.monCursorY();
        return @as(i32, self.screen_y) + @divTrunc(@as(i32, @intCast(self.sprite_h)), 2);
    }
};

/// CharSpriteDefaultXTbl / YTbl (btlgfx_data.asm).
pub const char_default_x = [_]u8{ 0xD0, 0xD0, 0xD0, 0xE0, 0xE0 };
pub const char_default_y = [_]u8{ 0x4C, 0x24, 0x74, 0x38, 0x60 };

pub const ObjTable = struct {
    objs: [total_slots]Obj = [_]Obj{.{}} ** total_slots,
    max_agility: u8 = 1,

    pub fn party(self: *ObjTable, i: usize) *Obj {
        return &self.objs[i];
    }
    pub fn monster(self: *ObjTable, i: usize) *Obj {
        return &self.objs[party_slots + i];
    }
    pub fn get(self: *ObjTable, slot: usize) *Obj {
        return &self.objs[slot];
    }

    pub fn clear(self: *ObjTable) void {
        self.* = .{};
    }

    /// LoadCharProp + LoadEquipProp + UpdateCharStats for one party slot.
    ///
    /// Hands are item ids ($2033/$2035). DK Cecil starts with Darkness ($17)
    /// in the right hand (event equip; not in ROM CharProp).
    pub fn loadPartyMember(
        self: *ObjTable,
        slot: usize,
        r: ?*const rom_mod.Rom,
        name: []const u8,
        char_id: u8,
        class_id: u8,
        gfx_id: u8,
        level: u8,
        hp: u16,
        max_hp: u16,
        mp: u16,
        max_mp: u16,
        strength: u8,
        agility: u8,
        /// Wisdom → intellect $2017; will → spirit $2018.
        wisdom: u8,
        will: u8,
        /// Vitality / stamina ($2016) for defense formula.
        vitality: u8,
        left_hand: u8,
        right_hand: u8,
        head: u8,
        body: u8,
        arms: u8,
    ) void {
        if (slot >= party_slots) return;
        const hands = equip.Hands{
            .left = left_hand,
            .right = right_hand,
            .handedness = 0, // right-handed default
        };
        const armor = equip.ArmorSlots{ .head = head, .body = body, .arms = arms };
        const cs = equip.calcCombatStats(r, hands, level, strength, agility);
        const ds = equip.calcDefenseStats(r, armor, hands, level, agility, vitality, wisdom, will);

        self.objs[slot] = .{
            .present = true,
            .type_id = 0,
            .name = name,
            .char_id = char_id,
            .class_id = class_id,
            .gfx_id = gfx_id,
            .level = level,
            .hp = hp,
            .max_hp = max_hp,
            .mp = mp,
            .max_mp = max_mp,
            .strength = if (strength == 0) 1 else strength,
            .agility = if (agility == 0) 1 else agility,
            .intellect = wisdom,
            .spirit = will,
            .vitality = vitality,
            .attack = cs.attack,
            .defense = ds.defense,
            .defense_rate = ds.defense_rate,
            .defense_mult = ds.defense_mult,
            .mdef = ds.mdef,
            .mdef_rate = ds.mdef_rate,
            .mdef_mult = ds.mdef_mult,
            .hit_rate = cs.hit_rate,
            .attack_mult = cs.attack_mult,
            .crit_rate = cs.crit_rate,
            .crit_bonus = cs.crit_bonus,
            .attack_element = cs.attack_element,
            .inflict_s1 = cs.inflict_s1,
            .inflict_s2 = cs.inflict_s2,
            .strong_elem = ds.strong_elem,
            .immune_elem = ds.immune_elem,
            .immune_s1 = ds.immune_s1,
            .immune_s2 = ds.immune_s2,
            .row = 0,
            .no_row_penalty = cs.no_row_penalty,
            .dual_wield = cs.dual_wield,
            .creature_atk = cs.creature_atk,
            .creature_def = ds.creature_def,
            .left_hand = left_hand,
            .right_hand = right_hand,
            .head = head,
            .body = body,
            .arms = arms,
            .slot_index = @intCast(slot),
            .screen_x = char_default_x[slot],
            .screen_y = char_default_y[slot],
            .sprite_w = 16,
            .sprite_h = 24,
            .is_monster = false,
            .action_timer = 1,
            .action_ready = false,
        };
    }

    /// Back-compat: load only slot 0 (leader).
    pub fn loadPartyLeader(
        self: *ObjTable,
        r: ?*const rom_mod.Rom,
        name: []const u8,
        level: u8,
        hp: u16,
        max_hp: u16,
        mp: u16,
        max_mp: u16,
        strength: u8,
        agility: u8,
        left_hand: u8,
        right_hand: u8,
    ) void {
        self.loadPartyMember(0, r, name, 0, 0, 0, level, hp, max_hp, mp, max_mp, strength, agility, 0, 0, 0, left_hand, right_hand, 0, 0, 0);
    }

    /// Recompute attack/hit/mult + defense from equip (after equip change).
    pub fn recomputeEquip(self: *ObjTable, slot: usize, r: ?*const rom_mod.Rom) void {
        if (slot >= party_slots) return;
        const o = self.get(slot);
        if (!o.present or o.is_monster) return;
        const hands = equip.Hands{ .left = o.left_hand, .right = o.right_hand };
        const armor = equip.ArmorSlots{ .head = o.head, .body = o.body, .arms = o.arms };
        const cs = equip.calcCombatStats(r, hands, o.level, o.strength, o.agility);
        const ds = equip.calcDefenseStats(r, armor, hands, o.level, o.agility, o.vitality, o.intellect, o.spirit);
        o.attack = cs.attack;
        o.hit_rate = cs.hit_rate;
        o.attack_mult = cs.attack_mult;
        o.no_row_penalty = cs.no_row_penalty;
        o.dual_wield = cs.dual_wield;
        o.attack_element = cs.attack_element;
        o.inflict_s1 = cs.inflict_s1;
        o.defense = ds.defense;
        o.defense_rate = ds.defense_rate;
        o.defense_mult = ds.defense_mult;
        o.mdef = ds.mdef;
        o.mdef_rate = ds.mdef_rate;
        o.mdef_mult = ds.mdef_mult;
        o.creature_def = ds.creature_def;
        o.inflict_s2 = cs.inflict_s2;
        o.crit_rate = cs.crit_rate;
        o.crit_bonus = cs.crit_bonus;
        o.creature_atk = cs.creature_atk;
        o.strong_elem = ds.strong_elem;
        o.immune_elem = ds.immune_elem;
        o.immune_s1 = ds.immune_s1;
        o.immune_s2 = ds.immune_s2;
    }

    /// Fill one mon slot from Monster type id (InitMonster + ActivateMonster shared body).
    pub fn fillMonsterSlot(
        self: *ObjTable,
        mon_i: usize,
        tid: u8,
        gd: *const data_mod.GameData,
        screen_x: u8,
        screen_y: u8,
    ) void {
        if (mon_i >= mon_slots) return;
        var o: Obj = .{
            .present = true,
            .type_id = tid,
            .is_monster = true,
            .slot_index = @intCast(party_slots + mon_i),
            .screen_x = screen_x,
            .screen_y = screen_y,
            .sprite_w = 32,
            .sprite_h = 32,
        };
        if (tid < gd.monsters.len) {
            const m = gd.monsters[tid];
            o.name = m.name;
            o.level = m.level;
            o.is_boss = m.is_boss;
            o.hp = if (m.hp == 0) 10 else m.hp;
            o.max_hp = o.hp;
            const amin = if (m.agility_min == 0) 8 else m.agility_min;
            o.agility = amin;
            o.attack_mult = m.attack_params.a;
            o.hit_rate = m.attack_params.b;
            o.attack = m.attack_params.c;
            o.defense_mult = m.defense_params.a;
            o.defense_rate = 0;
            o.defense = m.defense_params.c;
            o.mdef_mult = m.mdef_params.a;
            o.mdef_rate = 0;
            o.mdef = m.mdef_params.c;
            o.crit_rate = 1;
            o.crit_bonus = m.level;
            // Full drop byte ($2073): bits 6–7 rate, 0–5 MonsterItems set
            if (m.prop_raw.len > 7) o.item_set = m.prop_raw[7];
            applyMonsterOptionalProp(&o, m.prop_raw[9..]);
        } else {
            o.name = "???";
            o.hp = 20;
            o.max_hp = 20;
            o.agility = 8;
            o.attack = 12;
            o.defense = 4;
            o.hit_rate = 80;
            o.attack_mult = 1;
        }
        o.action_timer = 1;
        o.action_ready = false;
        self.objs[party_slots + mon_i] = o;
    }

    /// ActivateMonster (magic.asm @df5f): first free mon slot ($29b5==$FF / !present / dead) → type_id.
    /// Returns absolute obj slot index or null if formation full.
    pub fn activateMonster(
        self: *ObjTable,
        type_id: u8,
        gd: *const data_mod.GameData,
    ) ?usize {
        var i: usize = 0;
        while (i < mon_slots) : (i += 1) {
            const o = self.objs[party_slots + i];
            // ROM: first $29b5,x == $FF. We treat missing/dead/ko as free.
            const free = !o.present or o.type_id == 0xFF or o.hp == 0 or o.status.isKo();
            if (!free) continue;
            const x: u8 = if (o.present and o.screen_x != 0) o.screen_x else @intCast(40 + i * 24);
            const y: u8 = if (o.present and o.screen_y != 0) o.screen_y else @intCast(40 + (i % 3) * 32);
            self.fillMonsterSlot(i, type_id, gd, x, y);
            const m = self.get(party_slots + i);
            m.status = .{};
            m.hp = m.max_hp;
            m.action_timer = 1;
            m.action_ready = false;
            return party_slots + i;
        }
        return null;
    }

    /// DeactivateMonster (magic.asm @dfb0): set dead on mons whose type_id is t1 or t2.
    pub fn deactivateMonsterTypes(self: *ObjTable, t1: u8, t2: u8) void {
        var i: usize = 0;
        while (i < mon_slots) : (i += 1) {
            const o = self.get(party_slots + i);
            if (!o.present) continue;
            if (o.type_id == t1 or (t2 != 0xFF and o.type_id == t2)) {
                o.hp = 0;
                o.status.setDead();
            }
        }
    }

    /// Sum of living mon type_ids (change form @de5f: sum non-negative $29b5).
    pub fn sumLivingMonTypeIds(self: *const ObjTable) u16 {
        var s: u16 = 0;
        var i: usize = 0;
        while (i < mon_slots) : (i += 1) {
            const o = self.objs[party_slots + i];
            if (!o.present or o.hp == 0 or o.status.isKo()) continue;
            // ROM: bmi skip — type with bit7 set skipped; else adc
            if ((o.type_id & 0x80) != 0) continue;
            s +%= o.type_id;
        }
        return s;
    }

    /// True if any living mon has this type_id.
    pub fn hasLivingType(self: *const ObjTable, type_id: u8) bool {
        var i: usize = 0;
        while (i < mon_slots) : (i += 1) {
            const o = self.objs[party_slots + i];
            if (o.present and o.hp > 0 and !o.status.isKo() and o.type_id == type_id) return true;
        }
        return false;
    }

    pub fn loadMonsters(
        self: *ObjTable,
        plan: prop.SlotPlan,
        gd: *const data_mod.GameData,
    ) void {
        var i: u8 = 0;
        while (i < plan.count and i < mon_slots) : (i += 1) {
            self.fillMonsterSlot(i, plan.type_id[i], gd, plan.x[i], plan.y[i]);
        }
    }

    pub fn livingMonsters(self: *const ObjTable) u8 {
        var n: u8 = 0;
        var i: usize = party_slots;
        while (i < total_slots) : (i += 1) {
            const o = self.objs[i];
            if (o.present and o.hp > 0 and !o.status.isKo()) n += 1;
        }
        return n;
    }

    pub fn partyWiped(self: *const ObjTable) bool {
        var i: usize = 0;
        while (i < party_slots) : (i += 1) {
            const o = self.objs[i];
            if (o.present and o.hp > 0 and !o.status.isKo()) return false;
        }
        return true;
    }

    pub fn firstLivingMonster(self: *const ObjTable) ?usize {
        var i: usize = party_slots;
        while (i < total_slots) : (i += 1) {
            const o = self.objs[i];
            if (o.present and o.hp > 0 and !o.status.isKo()) return i;
        }
        return null;
    }

    pub fn firstLivingParty(self: *const ObjTable) ?usize {
        var i: usize = 0;
        while (i < party_slots) : (i += 1) {
            if (self.objs[i].present and self.objs[i].hp > 0) return i;
        }
        return null;
    }
};

const timer_dur = @import("timer_dur.zig");

/// InitMonster optional stream after base prop (init.asm @90f6–@9182).
/// `flags_and_rest` = prop_raw[9..] where [0] is flag byte $28a5.
fn applyMonsterOptionalProp(o: *Obj, flags_and_rest: []const u8) void {
    if (flags_and_rest.len == 0) return;
    const flags = flags_and_rest[0];
    var y: usize = 1; // stream at $28a6

    // bit7: attack element ($2019) + inflict status1/2 ($201e/$201f)
    if ((flags & 0x80) != 0) {
        if (y < flags_and_rest.len) {
            o.attack_element = flags_and_rest[y];
            y += 1;
        }
        if (y < flags_and_rest.len) {
            o.inflict_s1 = flags_and_rest[y];
            y += 1;
        }
        if (y < flags_and_rest.len) {
            o.inflict_s2 = flags_and_rest[y];
            y += 1;
        }
    }
    // bit6: elem → $2025 strong (bit7 clear) or $2026 immune (bit7 set);
    //       then immune status1/2 ($202b/$202c)
    if ((flags & 0x40) != 0) {
        if (y < flags_and_rest.len) {
            const e = flags_and_rest[y];
            y += 1;
            if ((e & 0x80) != 0) o.immune_elem = e else o.strong_elem = e;
        }
        if (y < flags_and_rest.len) {
            o.immune_s1 = flags_and_rest[y];
            y += 1;
        }
        if (y < flags_and_rest.len) {
            o.immune_s2 = flags_and_rest[y];
            y += 1;
        }
    }
    // bit5: elem always → $2020 (weak); bit7 set also → $2021 (very weak)
    if ((flags & 0x20) != 0) {
        if (y < flags_and_rest.len) {
            const e = flags_and_rest[y];
            y += 1;
            if ((e & 0x80) != 0) o.very_weak_elem = e;
            o.weak_elem = e;
            // ROM: if (e & $20) set $2004 charm bit — skip (status side-effect)
        }
    }
    // bit4: race byte → $2012/$2013/$2017(intellect)/$2018(spirit)
    if ((flags & 0x10) != 0) {
        if (y < flags_and_rest.len) {
            const race = flags_and_rest[y];
            y += 1;
            o.intellect = race;
            o.spirit = race;
        }
    }
    // bit3: creature type → $2040
    if ((flags & 0x08) != 0) {
        if (y < flags_and_rest.len) {
            o.creature_type = flags_and_rest[y];
            y += 1;
        }
    }
    // bit2: AIAction script + $38aa retal flag (init.asm @9178)
    if ((flags & 0x04) != 0) {
        o.has_retal = true;
        if (y < flags_and_rest.len) o.ai_action_id = flags_and_rest[y];
    }
}

/// Requeue after action using battle-wide max agility (init.asm base timer).
pub fn requeueActionTimerEx(o: *Obj, max_agility: u8) void {
    timer_dur.requeueAction(o, max_agility);
}
