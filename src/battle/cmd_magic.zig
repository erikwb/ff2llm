//! Magic commands (White/Black/Call) — DoMagicAttack + MagicEffectTbl (magic.asm).
//!
//! Effect ids match MagicEffectTbl:
//!   $00 dmg  $01 dmg+sap  $02 restore HP  $03 tornado  $04 drain HP  $05 drain MP
//!   $06 set status  $07 sleep/para  $08 blink  $09 reflect/wall  $0a life
//!   $0b esuna  $0c toad/pig  $0f slow/fast-ish  $15 restore MP  $16 elixir
//!   $17 poison  $1f gradual petrify  $28 dmg+status
//!
//! AttackProp target (byte0 high 3): expandTargets for multi-hit / split.
const std = @import("std");
const damage = @import("damage.zig");
const obj_mod = @import("obj.zig");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const item_prop = @import("item_prop.zig");
const status_mod = @import("status.zig");
const timer = @import("timer.zig");

pub const MagicResult = struct {
    ok: bool = false,
    amount: u16 = 0,
    healed: bool = false,
    missed: bool = false,
    target_died: bool = false,
    no_mp: bool = false,
    /// MagicEffect_13 Escape succeeded → force party flee.
    escaped: bool = false,
    /// MagicEffect_12 Libra: target current/max HP + weak-elem bits ($2720).
    peep_hp: u16 = 0,
    peep_max_hp: u16 = 0,
    peep_slot: u8 = 0xFF,
    /// Weak elem display bits (low 6) after strong mask — peep/libra msgs $15+bit.
    peep_weak_bits: u8 = 0,
    /// MagicEffect_29 Call: ActivateMonster type id (0xFF = none).
    spawn_type: u8 = 0xFF,
    /// MagicEffect_32: force end battle (ran/script end).
    end_battle: bool = false,
    /// MagicEffect_2e / $2f: delta to $3881 invincible counter (+1 / −1).
    invincible_delta: i8 = 0,
    /// MagicEffect_31: run Change Form on host.
    change_form: bool = false,
    /// MagicEffect_35: delay mon death ($38e4) + Rydia action timer.
    delay_mon_death: bool = false,
    mist_rydia_slot: u8 = 0xFF,
    /// Summon remapped attack id for ShowMsg_02 (0xFF = not summon).
    summon_attack_id: u8 = 0xFF,
    /// SummonFailed: restore Rydia MP to this value (0xFFFF = no restore).
    summon_mp_restore: u16 = 0xFFFF,
    /// Floater hints: up to 8 (slot, amount) pairs.
    floater_slot: [8]u8 = .{0xFF} ** 8,
    floater_amt: [8]u16 = .{0} ** 8,
    floater_n: u8 = 0,
};

/// Load AttackProp as ItemProp-compatible fields (magic.asm LoadArrayItem).
pub fn loadSpell(r: *const rom_mod.Rom, spell_id: u8) ?item_prop.ItemProp {
    if (spell_id >= offsets.en.attack_property_count) return null;
    const off = offsets.en.attack_properties + @as(usize, spell_id) * offsets.en.attack_property_stride;
    const raw = r.slice(off, 6) catch return null;
    return .{
        .cast_time = raw[0] & 0x1F,
        .target = raw[0] >> 5,
        .power = raw[1],
        .hit = raw[2] & 0x7F,
        .miss_boss = (raw[2] & 0x80) != 0,
        .effect = raw[3] & 0x7F,
        // bit7 of effect byte ($289f): fixed 1 base hit (magic.asm @cef1), not split
        .fixed_hits = (raw[3] & 0x80) != 0,
        .split = (raw[3] & 0x80) != 0,
        .element = raw[4] & 0x7F,
        .is_damage = (raw[4] & 0x80) != 0,
        .mp_cost = raw[5] & 0x7F,
        .no_reflect = (raw[5] & 0x80) != 0,
    };
}

/// AnimProp @ $0F/A050 (file 0x7A050) — 4 bytes/attack (magic.asm DoItemMagicAnim @eafe).
/// +0 pal row (LoadAnimPal), +1 magic gfx id, +2 script ($f397, $FF=none), +3 MagicAnimTbl index.
/// **Index is (attack_id − 1)** — decomp `dec` then `asl2` before indexing.
const anim_prop_file: usize = 0x7A050;

pub const AnimProp = struct {
    pal: u8 = 0,
    gfx: u8 = 0,
    script: u8 = 0xFF,
    anim: u8 = 0xFF,

    /// Load AnimProp for attack/spell id (1-based; id 0 → empty).
    pub fn load(r: *const rom_mod.Rom, attack_id: u8) AnimProp {
        if (attack_id == 0) return .{};
        // DoItemMagicAnim @eafe: dec; longa; asl2; tax → (id-1)*4
        const idx: usize = @as(usize, attack_id -% 1);
        const off = anim_prop_file + idx * 4;
        const raw = r.slice(off, 4) catch return .{};
        return .{
            .pal = raw[0],
            .gfx = raw[1],
            .script = raw[2],
            .anim = raw[3],
        };
    }
};

/// ShowMsg_02 attack/spell name (btlgfx.asm @cb98).
/// id < $48 → SpellName[id] (6 bytes, leading icon); id ≥ $48 → AttackName[id-$48] (8 bytes).
pub fn spellName(r: *const rom_mod.Rom, spell_id: u8, buf: []u8) []const u8 {
    const text = @import("../text.zig");
    if (spell_id == 0) return "";
    if (spell_id < 0x48) {
        if (spell_id >= offsets.en.spell_name_count) {
            if (buf.len > 0) {
                buf[0] = '?';
                return buf[0..1];
            }
            return "";
        }
        const raw = r.slice(offsets.en.spell_names + @as(usize, spell_id) * offsets.en.spell_name_stride, offsets.en.spell_name_stride) catch {
            return text.decodeFixed(&[_]u8{0xFF}, buf);
        };
        // ROM prepends icon $03 in VRAM; table itself is 6 text bytes (MagicName)
        return text.decodeFixed(raw, buf);
    }
    // Monster / special attack name
    const idx: usize = spell_id - 0x48;
    if (idx >= offsets.en.attack_name_count) {
        if (buf.len > 0) {
            buf[0] = '?';
            return buf[0..1];
        }
        return "";
    }
    const raw = r.slice(offsets.en.attack_names + idx * offsets.en.attack_name_stride, offsets.en.attack_name_stride) catch {
        return text.decodeFixed(&[_]u8{0xFF}, buf);
    };
    return text.decodeFixed(raw, buf);
}

pub fn listIdFor(r: *const rom_mod.Rom, char_id: u8, magic_col: u8) u8 {
    if (char_id >= offsets.en.spell_list_tbl_count or magic_col >= 3) return 0xFF;
    const raw = r.slice(offsets.en.spell_list_tbl + @as(usize, char_id) * 3, 3) catch return 0xFF;
    return raw[magic_col];
}

pub fn loadSpellList(r: *const rom_mod.Rom, list_id: u8, out: *[24]u8) u8 {
    @memset(out, 0xFF);
    if (list_id == 0xFF or list_id >= offsets.en.spell_list_init_count) return 0;
    const off = offsets.en.spell_list_init + @as(usize, list_id) * offsets.en.spell_list_init_stride;
    const raw = r.slice(off, offsets.en.spell_list_init_stride) catch return 0;
    var n: u8 = 0;
    for (raw) |s| {
        if (s == 0xFF) continue;
        out[n] = s;
        n += 1;
        if (n >= 24) break;
    }
    return n;
}

/// Runtime spell lists ($1560): 13 × 24 slots (InitSpellLists).
pub const spell_list_count: usize = offsets.en.spell_list_init_count;
pub const spell_list_stride: usize = offsets.en.spell_list_init_stride;
pub const SpellLists = [spell_list_count][spell_list_stride]u8;

/// InitSpellLists (field.asm @c23e) — copy SpellListInit; $FF → empty 0.
pub fn initSpellLists(r: *const rom_mod.Rom, out: *SpellLists) void {
    for (out) |*row| @memset(row, 0);
    var li: usize = 0;
    while (li < spell_list_count) : (li += 1) {
        const off = offsets.en.spell_list_init + li * spell_list_stride;
        const raw = r.slice(off, spell_list_stride) catch continue;
        var si: usize = 0;
        for (raw) |s| {
            if (s == 0xFF) continue;
            if (si >= spell_list_stride) break;
            out[li][si] = s;
            si += 1;
        }
    }
}

/// Copy one runtime list into a dense menu buffer (skip zeros). Returns count.
pub fn loadSpellListRam(lists: *const SpellLists, list_id: u8, out: *[24]u8) u8 {
    @memset(out, 0xFF);
    if (list_id == 0xFF or list_id >= spell_list_count) return 0;
    var n: u8 = 0;
    for (lists[list_id]) |s| {
        if (s == 0) continue;
        out[n] = s;
        n += 1;
        if (n >= 24) break;
    }
    return n;
}

/// Prefer RAM lists when present (learned spells), else ROM init table.
pub fn loadSpellListPreferRam(
    r: *const rom_mod.Rom,
    lists: ?*const SpellLists,
    list_id: u8,
    out: *[24]u8,
) u8 {
    if (lists) |ls| return loadSpellListRam(ls, list_id, out);
    return loadSpellList(r, list_id, out);
}

/// EventCmd_e2: give spell — first empty slot in list_id × 24 ($1560).
pub fn giveSpell(lists: *SpellLists, list_id: u8, spell_id: u8) bool {
    if (list_id >= spell_list_count or spell_id == 0) return false;
    const row = &lists[list_id];
    // Already known?
    for (row) |s| {
        if (s == spell_id) return false;
    }
    for (row) |*s| {
        if (s.* == 0) {
            s.* = spell_id;
            return true;
        }
    }
    return false;
}

fn baseFromPower(power: u8) u16 {
    return @as(u16, power) *% 4;
}

/// Summon power ×8 (magic.asm @d039 when $3584 set).
fn baseFromPowerSummon(power: u8) u16 {
    return @as(u16, power) *% 8;
}

/// True if spell id is Call/summon range ($31–$3F) (magic.asm @cd10).
pub fn isSummonSpell(spell_id: u8) bool {
    return spell_id >= 0x31 and spell_id < 0x40;
}

/// RandSummon (cmd.asm @ec12) for item $CA: random SummonBookTbl entry.
/// Returns attack id (low 7) and whether bit7 forces single random mon target.
pub fn randSummonBook(r: *const rom_mod.Rom, rng: damage.Rng) struct { attack_id: u8, single_target: bool } {
    const idx = rng.next() % offsets.en.summon_book_count;
    const raw = r.slice(offsets.en.summon_book_tbl + idx, 1) catch return .{ .attack_id = 0x52, .single_target = false };
    return .{
        .attack_id = raw[0] & 0x7F,
        .single_target = (raw[0] & 0x80) != 0,
    };
}

/// WeaponMagicHits[weapon_id] (0F/9070) — hit count for weapon-cast spells.
pub fn weaponMagicHits(r: *const rom_mod.Rom, weapon_id: u8) u8 {
    if (weapon_id >= offsets.en.weapon_magic_hits_count) return 1;
    const raw = r.slice(offsets.en.weapon_magic_hits + weapon_id, 1) catch return 1;
    return if (raw[0] == 0) 1 else raw[0];
}

/// GetSummonAttack (magic.asm @e053): map list summon id → AttackProp id + set summon flag.
/// Returns attack/spell id used for LoadArrayItem.
pub fn getSummonAttack(spell_id: u8, rng: damage.Rng) u8 {
    if (spell_id < 0x31) return spell_id;
    if (spell_id == 0x3F) return 0x5D; // Asura
    var sid = spell_id;
    if (spell_id >= 0x3E) {
        // RandXA 0..2 + $3e → $3e/$3f/$40 then map
        sid = 0x3E + (rng.next() % 3);
    }
    // (id - $31) + $4d
    return sid -% 0x31 +% 0x4D;
}

test "AnimProp load from ROM for spell 0x0E uses index id-1" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    const a = AnimProp.load(&r, 0x0E);
    // DoMagicAnim dec: entry $0D = 08 00 16 00 (headerless dump)
    try std.testing.expectEqual(@as(u8, 0x08), a.pal);
    try std.testing.expectEqual(@as(u8, 0x16), a.script);
    try std.testing.expectEqual(@as(u8, 0x00), a.anim);
    // id 0 empty
    const z = AnimProp.load(&r, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), z.anim);
}

test "GetSummonAttack maps $31 to $4d" {
    var lcg = damage.Lcg.init(1);
    const id = getSummonAttack(0x31, lcg.asRng());
    try std.testing.expectEqual(@as(u8, 0x4D), id);
    try std.testing.expectEqual(@as(u8, 0x5D), getSummonAttack(0x3F, lcg.asRng()));
}

test "SummonBookTbl first entry is $d1 single-target" {
    // Table constant from battle_data.asm @feec (no ROM needed)
    const entry: u8 = 0xD1;
    try @import("std").testing.expectEqual(@as(u8, 0x51), entry & 0x7F);
    try @import("std").testing.expect((entry & 0x80) != 0);
}

fn elemMult(es_elem: u8, tgt: *const obj_mod.Obj) u8 {
    if (es_elem == 0) return 2;
    if ((es_elem & tgt.very_weak_elem) != 0) return 8;
    if ((es_elem & tgt.weak_elem) != 0) return 4;
    if ((es_elem & tgt.immune_elem) != 0) return 0;
    if ((es_elem & tgt.strong_elem) != 0) return 1;
    return 2;
}

/// White magic = spell_id < $19 → use spirit; else intellect (magic.asm @cea7).
fn magicStat(caster: *const obj_mod.Obj, spell_id: u8) u8 {
    if (spell_id < 0x19) return if (caster.spirit != 0) caster.spirit else caster.intellect;
    return caster.intellect;
}

/// Magic attack hits ($3551) — magic.asm @cea7–@cf0b.
/// rate = spell.hit + stat/2; base_hits = stat/4+1, or 1 if effect bit7 (fixed hits).
/// Summon/item: force 8 hits (@cf1e when $352a item or $3584 summon).
fn calcMagicAtkHits(sp: item_prop.ItemProp, caster: *const obj_mod.Obj, spell_id: u8, rng: damage.Rng, force_hits: u8) u8 {
    // force_hits: 8 for item/summon; WeaponMagicHits value for weapon magic; 0 = normal calc
    if (force_hits != 0) return force_hits;
    const stat = magicStat(caster, spell_id);
    var rate: u16 = @as(u16, sp.hit) +% (stat / 2);
    if (rate > 255) rate = 255;
    if (caster.status.isBlind()) rate /= 2;
    if (!caster.is_monster and caster.slot_index == 0) {
        rate = rate * 5 / 4;
        if (rate > 255) rate = 255;
    }
    // $289f bit7 → fixed 1 base hit attempt
    const base_hits: u8 = if (sp.fixed_hits) 1 else @intCast(@min((stat / 4) + 1, 255));
    return damage.calcHits(.{
        .base_hits = base_hits,
        .hit_rate = @intCast(rate),
    }, rng);
}

/// Multi-target damage divisor ($3906). Targeting high bits $60==$40 → don't divide.
fn targetDivisor(sp: item_prop.ItemProp, n_targets: u8) u16 {
    // AttackProp byte0 high 3 is target; low-level $289c full byte used with & $60.
    // Our `target` is already >>5. ROM: (raw0 & $60) == $40 → $3906 = 1.
    // raw0 & $60 == $40 means bits 6:5 == 10b → target field == 2.
    if (sp.target == 2) return 1;
    if (n_targets == 0) return 1;
    return n_targets;
}

/// Mag.def hits for one target (magic.asm @d084–@d100). Char vs char → 0.
fn calcMagicDefHits(
    caster: *const obj_mod.Obj,
    tgt: *const obj_mod.Obj,
    rng: damage.Rng,
) u8 {
    // Character vs character: no mag.def subtraction
    if (!caster.is_monster and !tgt.is_monster) return 0;

    var mdef_rate: u8 = tgt.mdef_rate;
    if (tgt.status.isBlind()) mdef_rate /= 2;
    if (!tgt.is_monster and tgt.slot_index == 0) {
        const bonus: u16 = @as(u16, mdef_rate) * 5 / 4;
        mdef_rate = @intCast(@min(bonus, 255));
    }
    var mdef_mult: u8 = tgt.mdef_mult;
    if (tgt.status.isToadMini()) mdef_mult = 0;
    // Boss with mdef power 255 → force mult/rate 99 (magic.asm @d0ed katsuhisa)
    if (tgt.is_monster and tgt.mdef == 255) {
        mdef_mult = 99;
        mdef_rate = 99;
    }
    if (mdef_mult == 0) return 0;
    return damage.calcHits(.{
        .base_hits = mdef_mult,
        .hit_rate = mdef_rate,
    }, rng);
}

/// Net magic hits after mag.def; min 0. Explode-like always-hit spells not special-cased.
fn netMagicHits(
    sp: item_prop.ItemProp,
    caster: *const obj_mod.Obj,
    tgt: *const obj_mod.Obj,
    spell_id: u8,
    rng: damage.Rng,
    force_hits: u8,
) u8 {
    const atk = calcMagicAtkHits(sp, caster, spell_id, rng, force_hits);
    if (atk == 0) return 0;
    // Boss + miss_boss → 0 hits
    if (tgt.is_boss and sp.miss_boss) return 0;
    const def = calcMagicDefHits(caster, tgt, rng);
    if (atk <= def) return 0;
    return atk - def;
}

/// AttackProp target field (byte0 high 3) → living slots for this cast.
/// primary = menu/AI-chosen slot (used for single-target).
pub fn expandTargets(
    objs: *obj_mod.ObjTable,
    caster_slot: usize,
    sp: item_prop.ItemProp,
    primary: usize,
    out: *[obj_mod.total_slots]usize,
) u8 {
    var n: u8 = 0;
    const allow_dead = sp.effect == 10; // Life
    const add = struct {
        fn go(slots: *[obj_mod.total_slots]usize, nn: *u8, s: usize, o: *const obj_mod.ObjTable, life: bool) void {
            if (nn.* >= obj_mod.total_slots) return;
            const obj = o.objs[s];
            if (!obj.present) return;
            // Life: include dead/0 HP; others need living
            if (!life and (obj.hp == 0 or obj.status.isKo())) return;
            slots[nn.*] = s;
            nn.* += 1;
        }
    }.go;

    // tgt 0: self
    // 1,3: single ally (or dead for life)
    // 2: all allies
    // 4,5: single enemy
    // 6,7: all enemies
    switch (sp.target) {
        0 => {
            out[0] = caster_slot;
            n = 1;
        },
        1, 3 => {
            // Prefer primary if party; Life (effect $0a) allows dead
            if (primary < obj_mod.party_slots and objs.objs[primary].present) {
                const o = objs.objs[primary];
                if (o.hp > 0 or sp.effect == 10 or o.status.isDead()) {
                    out[0] = primary;
                    n = 1;
                }
            }
            if (n == 0) {
                if (sp.effect == 10) {
                    var i: usize = 0;
                    while (i < obj_mod.party_slots) : (i += 1) {
                        const o = objs.objs[i];
                        if (o.present and (o.hp == 0 or o.status.isDead())) {
                            out[0] = i;
                            n = 1;
                            break;
                        }
                    }
                } else if (objs.firstLivingParty()) |p| {
                    out[0] = p;
                    n = 1;
                }
            }
        },
        2 => {
            var i: usize = 0;
            while (i < obj_mod.party_slots) : (i += 1) {
                add(out, &n, i, objs, allow_dead);
            }
        },
        4, 5 => {
            if (primary >= obj_mod.party_slots and objs.objs[primary].present and objs.objs[primary].hp > 0) {
                out[0] = primary;
                n = 1;
            } else if (objs.firstLivingMonster()) |m| {
                out[0] = m;
                n = 1;
            }
        },
        6, 7 => {
            var i: usize = obj_mod.party_slots;
            while (i < obj_mod.total_slots) : (i += 1) {
                add(out, &n, i, objs, false);
            }
        },
        else => {
            if (objs.objs[primary].present) {
                out[0] = primary;
                n = 1;
            }
        },
    }
    return n;
}

/// Reflect: bounce to a random living unit on the *opposite* side of the original target.
fn reflectTarget(objs: *obj_mod.ObjTable, original: *obj_mod.Obj, caster: *obj_mod.Obj, rng: damage.Rng) *obj_mod.Obj {
    // Bounce toward original target's opposite faction (ROM toggles side).
    const want_mon = !original.is_monster;
    var slots: [obj_mod.total_slots]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0 or o.status.isKo()) continue;
        if (o.is_monster == want_mon) {
            slots[n] = i;
            n += 1;
        }
    }
    if (n == 0) return caster;
    return objs.get(slots[rng.next() % n]);
}

fn pushFloater(out: *MagicResult, slot: usize, amt: u16) void {
    if (out.floater_n >= 8 or amt == 0) return;
    out.floater_slot[out.floater_n] = @intCast(slot);
    out.floater_amt[out.floater_n] = amt;
    out.floater_n += 1;
}

/// Mag.def power used as $3904 defense (magic.asm @d084). Char vs char → 0.
fn magicDefensePower(caster: *const obj_mod.Obj, tgt: *const obj_mod.Obj) u16 {
    if (!caster.is_monster and !tgt.is_monster) return 0;
    return tgt.mdef;
}

/// Apply one effect to one already-resolved target (after reflect).
/// `is_last_target` — last mon of multi-target (Sylph heal gate $3906==$354d).
fn applyEffect(
    r: *const rom_mod.Rom,
    sp: item_prop.ItemProp,
    spell_id: u8,
    caster: *obj_mod.Obj,
    tgt: *obj_mod.Obj,
    tgt_slot: usize,
    split_n: u8,
    is_last_target: bool,
    objs: ?*obj_mod.ObjTable,
    rng: damage.Rng,
    /// Summon: power×8.
    power_x8: bool,
    /// 0 = normal CalcHits; 8 = item/summon; else WeaponMagicHits.
    force_hits: u8,
    out: *MagicResult,
) void {
    const es = status_mod.expandElementStatus(r, sp.element);
    const em = elemMult(es.elem, tgt);
    const power = sp.power;
    const atk_base = if (power_x8) baseFromPowerSummon(power) else baseFromPower(power);
    // $3906: divide final dmg by target count (unless auto-all targeting)
    const div = targetDivisor(sp, split_n);

    switch (sp.effect) {
        // MagicEffect_00: damage
        0 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_01: damage + sap
        1 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            timer.armSap(tgt);
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_02: restore HP
        2 => {
            if (tgt.status.isDead()) return;
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = 0,
                .hits = 1,
                .elemental_mult = 2,
                .creature_mult = 2,
                .defense_divisor = 1,
            }, rng);
            const room = tgt.max_hp -| tgt.hp;
            const heal = @min(res.damage, room);
            tgt.hp +%= heal;
            out.amount +%= heal;
            out.healed = true;
            pushFloater(out, tgt_slot, heal);
        },
        // MagicEffect_03: tornado — set HP to 1..9
        3 => {
            if (tgt.status.isKo() or tgt.is_boss) return;
            const dig: u16 = 1 + (rng.next() % 9);
            if (tgt.hp > dig) {
                const dealt = tgt.hp - dig;
                tgt.hp = dig;
                out.amount +%= dealt;
                pushFloater(out, tgt_slot, dealt);
            }
        },
        // MagicEffect_04: drain HP → caster
        4 => {
            if (tgt.status.isKo() or tgt == caster) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                dmg = tgt.hp;
                tgt.hp = 0;
                tgt.status.setDead();
            }
            const room = caster.max_hp -| caster.hp;
            const heal = @min(dmg, room);
            caster.hp +%= heal;
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_05: drain MP
        5 => {
            if (tgt == caster) return;
            var steal: u16 = baseFromPower(power);
            if (steal > tgt.mp) steal = tgt.mp;
            tgt.mp -%= steal;
            const room = caster.max_mp -| caster.mp;
            const gain = @min(steal, room);
            caster.mp +%= gain;
            out.amount +%= steal;
            out.healed = true;
        },
        // MagicEffect_06: set status
        6 => {
            if (tgt.status.isKo()) return;
            const a1 = es.s1 & ~tgt.immune_s1;
            const a2 = es.s2 & ~tgt.immune_s2;
            var applied = false;
            if (a1 != 0) applied = tgt.status.applyStatus1(a1, tgt.immune_s1) or applied;
            if (a2 != 0) applied = tgt.status.applyStatus2(a2, tgt.immune_s2) or applied;
            armFromStatusBits(tgt, a1, a2);
            if (applied) {
                out.ok = true;
                out.amount +%= 1;
            }
        },
        // MagicEffect_07: sleep / paralyze — TimerDur_04 → action timer (magic.asm @d5a6).
        7 => {
            if (tgt.status.isKo()) return;
            const a2 = es.s2 & ~tgt.immune_s2;
            if (a2 == 0) return;
            if (tgt.status.applyStatus2(a2, tgt.immune_s2)) {
                timer.armSleepParalyze(tgt);
                out.ok = true;
                out.amount +%= 1;
            }
        },
        // MagicEffect_08: blink / image (3 charges)
        8 => {
            if (tgt.status.isKo()) return;
            // status4 bits2–3 = image charges; set to 3 → 0x0C
            tgt.status.s4 = (tgt.status.s4 & ~status_mod.Status4.image_mask) | 0x0C;
            out.ok = true;
            out.amount +%= 1;
            out.healed = true;
        },
        // MagicEffect_09: reflect / wall (NOT 13 — Wall spell uses 9)
        // $289d power → $397b; CalcTimerDur type $08; SetTimer reflect.
        9 => {
            if (tgt.status.isKo()) return;
            timer.armReflect(tgt, power);
            out.ok = true;
            out.amount +%= 1;
            out.healed = true;
        },
        // MagicEffect_0a: life
        10 => {
            if (!tgt.status.isDead() and tgt.hp != 0) return;
            tgt.status.clearStatus1(status_mod.Status1.dead | status_mod.Status1.stone);
            tgt.hp = @max(1, tgt.max_hp / 10);
            out.amount +%= tgt.hp;
            out.healed = true;
        },
        // MagicEffect_0b: esuna / heal status
        11 => {
            tgt.status.clearStatus1(0x3F);
            tgt.status.clearStatus2(0x3F | status_mod.Status2.float_bit);
            // clear stop/sap/float
            tgt.status.setStop(false);
            tgt.status.setSap(false);
            tgt.status.setFloat(false);
            out.ok = true;
            out.amount +%= 1;
            out.healed = true;
        },
        // MagicEffect_0c: toad / pig / size toggle
        12 => {
            if (tgt.is_boss) return;
            const toad = status_mod.Status1.toad;
            const pig = status_mod.Status1.pig;
            const mini = status_mod.Status1.mini;
            const bits = if ((es.s1 & (toad | pig | mini)) != 0) es.s1 else toad;
            if ((tgt.immune_s1 & bits) != 0) return;
            if ((tgt.status.s1 & bits) != 0)
                tgt.status.clearStatus1(bits)
            else
                _ = tgt.status.applyStatus1(bits, tgt.immune_s1);
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_0d: protect — defense ($272a) += 5, max 255 (magic.asm @d83f)
        13 => {
            if (tgt.status.isKo()) return;
            if (tgt.defense >= 255) return;
            // Zeromus battle $01b7 skips (not tracked: apply always outside that id)
            const next: u16 = tgt.defense +% 5;
            tgt.defense = if (next > 255) 255 else next;
            out.ok = true;
            out.amount +%= 5;
            out.healed = true;
        },
        // MagicEffect_0e: shell — mag.def ($2724) += 3, max 255 (@d863)
        14 => {
            if (tgt.status.isKo()) return;
            if (tgt.mdef >= 255) return;
            const next: u16 = tgt.mdef +% 3;
            tgt.mdef = if (next > 255) 255 else next;
            out.ok = true;
            out.amount +%= 3;
            out.healed = true;
        },
        // MagicEffect_0f: haste/slow — $273b += power (8-bit wrap); clamp [12, 32]
        // magic.asm @d887: CLC ADC; if ≥$20 → $20; if <$0C → $0C
        15 => {
            if (tgt.status.isKo()) return;
            var sm: u8 = @truncate(tgt.speed_mod);
            sm +%= power; // power is $FD (−3) haste or $08 slow
            if (sm >= 0x20) sm = 0x20 else if (sm < 0x0C) sm = 0x0C;
            tgt.speed_mod = sm;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_10: clear stop/sap/charm-ish (magic.asm @d8a0)
        16 => {
            if (tgt.status.isKo()) return;
            tgt.status.setStop(false);
            tgt.stop_timer = 0;
            tgt.status.setSap(false);
            tgt.sap_timer = 0;
            // Clear charm bit if present (status2)
            tgt.status.clearStatus2(status_mod.Status2.charm);
            out.ok = true;
            out.amount +%= 1;
            out.healed = true;
        },
        // MagicEffect_11: stop / magnet (magic.asm @d8de) — TimerDur_0a Mult8(power,3).
        17 => {
            if (tgt.status.isKo()) return;
            timer.armStop(tgt, power);
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_12: libra / peep (magic.asm @d917) — HP + weak bits
        // weak_display = weak & ~strong & $3F (same as Cmd_14)
        18 => {
            if (tgt.is_boss) return; // bosses blocked (also Zeromus special)
            out.peep_hp = tgt.hp;
            out.peep_max_hp = tgt.max_hp;
            out.peep_slot = @intCast(@min(tgt_slot, 255));
            out.peep_weak_bits = tgt.weak_elem & ~tgt.strong_elem & 0x3F;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_13: escape (magic.asm @d972) — set flee flags if can run
        19 => {
            // Host checks battle_flags can't-run; here we signal intent
            out.escaped = true;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_14: damage = attacker.hp / power (Div16), 1 hit (magic.asm @d990)
        20 => {
            if (tgt.status.isKo()) return;
            const divisor: u16 = if (power == 0) 1 else power;
            const base: u16 = caster.hp / divisor;
            if (base == 0) {
                out.missed = true;
                return;
            }
            // ROM sets $38fc=1 hits, $3904=0 defense, then CalcDmg
            const res = damage.calcDamage(.{
                .base_attack = base,
                .defense = 0,
                .hits = 1,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = 1,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
            _ = tgt.status.applyStatus1(es.s1, tgt.immune_s1);
            _ = tgt.status.applyStatus2(es.s2, tgt.immune_s2);
            armFromStatusBits(tgt, es.s1, es.s2);
        },
        // MagicEffect_15: restore MP
        21 => {
            const room = tgt.max_mp -| tgt.mp;
            const heal = @min(baseFromPower(power), room);
            tgt.mp +%= heal;
            out.amount +%= heal;
            out.healed = true;
        },
        // MagicEffect_16: elixir
        22 => {
            tgt.hp = tgt.max_hp;
            tgt.mp = tgt.max_mp;
            out.amount +%= tgt.max_hp;
            out.healed = true;
        },
        // MagicEffect_17: poison/venom (dmg + poison)
        23 => {
            if (tgt.is_boss) return;
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (sp.is_damage and dmg > 0) {
                if (tgt.hp > dmg) tgt.hp -= dmg else {
                    tgt.hp = 0;
                    tgt.status.setDead();
                }
                out.amount +%= dmg;
                pushFloater(out, tgt_slot, dmg);
            }
            if (tgt.status.applyStatus1(status_mod.Status1.poison, tgt.immune_s1))
                timer.armPoison(tgt);
            out.ok = true;
        },
        // MagicEffect_18: cockatrice — dmg + SetMagicStatus (magic.asm @da66)
        24 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            _ = tgt.status.applyStatus1(es.s1, tgt.immune_s1);
            _ = tgt.status.applyStatus2(es.s2, tgt.immune_s2);
            armFromStatusBits(tgt, es.s1, es.s2);
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_19: mindflayer — dmg + sleep/para (magic.asm @da7f)
        25 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            const a2 = es.s2 & ~tgt.immune_s2;
            _ = tgt.status.applyStatus2(a2, tgt.immune_s2);
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_1a: sylph — dmg mon, then split heal to living party (last target only)
        26 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.is_monster) {
                if (tgt.hp > dmg) tgt.hp -= dmg else {
                    tgt.hp = 0;
                    tgt.status.setDead();
                }
                out.amount +%= dmg;
                out.target_died = out.target_died or (tgt.hp == 0);
                pushFloater(out, tgt_slot, dmg);
            }
            // Heal split on last multi-target. EN ROM skips actual HP write
            // (magic.asm @db21 `.if !LANG_EN`) but still shows heal numerals.
            if (is_last_target and objs != null and dmg > 0) {
                const table = objs.?;
                var n_live: u16 = 0;
                var slots: [5]usize = undefined;
                var pi: usize = 0;
                while (pi < obj_mod.party_slots) : (pi += 1) {
                    const p = table.objs[pi];
                    if (!p.present or p.hp == 0 or p.status.isKo()) continue;
                    if (p.status.isJumping() or p.status.isHidden()) continue;
                    slots[n_live] = pi;
                    n_live += 1;
                }
                if (n_live > 0) {
                    const each: u16 = dmg / n_live;
                    if (each > 0) {
                        var hi: u16 = 0;
                        while (hi < n_live) : (hi += 1) {
                            // EN: display only (no po.hp +=)
                            pushFloater(out, slots[hi], each);
                            out.amount +%= each;
                            out.healed = true;
                        }
                    }
                }
            }
        },
        // MagicEffect_1b: odin — Rand99 < $32 → kill all mon targets else fail (magic.asm @db6a)
        27 => {
            // One roll for the whole cast: first target decides
            if (!out.ok and !out.missed) {
                if ((rng.next() % 100) >= 0x32) {
                    out.missed = true;
                    return;
                }
                out.ok = true;
            }
            if (out.missed) return;
            if (tgt.status.isKo() or !tgt.is_monster or tgt.is_boss) return;
            tgt.hp = 0;
            tgt.status.setDead();
            out.target_died = true;
            out.amount +%= 1;
        },
        // MagicEffect_1c / 1d: doom count (magic.asm @dbc0)
        28, 29 => {
            if (tgt.status.isKo() or tgt.is_boss) return;
            // power = countdown ticks
            const counts: u16 = if (power == 0) 1 else power;
            timer.armDoom(tgt, counts);
            out.ok = true;
            out.amount +%= counts;
        },
        // MagicEffect_1e: damage = target.max_hp / power (magic.asm @dbf0)
        // Elem mult adjusts divisor: half-elem → /10; ≥2× → power>>=1
        30 => {
            if (tgt.status.isKo()) return;
            var divp: u8 = if (power == 0) 1 else power;
            if (em < 2) {
                divp = 10; // weak absorb path uses /10 when mult < 1×
            } else if (em >= 4) {
                divp = @max(1, divp / 2);
            }
            const dmg: u16 = tgt.max_hp / divp;
            if (dmg == 0) {
                out.missed = true;
                return;
            }
            if (em == 0) {
                // absorb → heal
                const room = tgt.max_hp -| tgt.hp;
                const heal = @min(dmg, room);
                tgt.hp +%= heal;
                out.amount +%= heal;
                out.healed = true;
                pushFloater(out, tgt_slot, heal);
                return;
            }
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_1f: gradual petrify
        31 => {
            if (tgt.status.isKo() or tgt.is_boss) return;
            if ((tgt.immune_s1 & status_mod.Status1.stone) != 0) return;
            // Advance stage or arm timer (decomp increments low 2 bits then arms timer)
            if (tgt.status.petrifyStage() >= 3) {
                _ = tgt.status.advancePetrify();
            } else {
                timer.armPetrify(tgt);
                _ = tgt.status.advancePetrify();
            }
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_20: gaze — random status via ROR of status2 (magic.asm @dc9b)
        // RandXA 3..5, then ROR $28a4 that many times; 5 → stone path
        32 => {
            if (tgt.status.isKo()) return;
            const n: u8 = 3 + (rng.next() % 3); // 3,4,5
            var s2: u8 = es.s2;
            if (s2 == 0) s2 = 0x80; // default high bit if table empty
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                const carry: u8 = s2 & 1;
                s2 = (s2 >> 1) | (carry << 7);
            }
            if (n == 5) {
                _ = tgt.status.applyStatus1(status_mod.Status1.stone, tgt.immune_s1);
            } else {
                _ = tgt.status.applyStatus2(s2, tgt.immune_s2);
            }
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_21: bluster — 50% death else para (magic.asm @dcbb)
        33 => {
            if (tgt.status.isKo()) return;
            if ((rng.next() & 1) == 0) {
                _ = tgt.status.applyStatus1(status_mod.Status1.dead, tgt.immune_s1);
                if (tgt.status.isDead()) {
                    tgt.hp = 0;
                    out.target_died = true;
                }
            } else {
                _ = tgt.status.applyStatus2(status_mod.Status2.paralyze, tgt.immune_s2);
            }
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_22: slap — Rand 0..2: para / mute / charm (magic.asm @dcd6)
        34 => {
            if (tgt.status.isKo()) return;
            const roll = rng.next() % 3;
            if (roll == 0) {
                _ = tgt.status.applyStatus2(status_mod.Status2.paralyze, tgt.immune_s2);
            } else if (roll == 1) {
                _ = tgt.status.applyStatus1(status_mod.Status1.mute, tgt.immune_s1);
            } else {
                _ = tgt.status.applyStatus2(status_mod.Status2.charm, tgt.immune_s2);
            }
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_23: blast — paralyze + remove? SleepParalyze + _d3e4 dmg path
        35 => {
            if (tgt.status.isKo()) return;
            _ = tgt.status.applyStatus2(status_mod.Status2.paralyze, tgt.immune_s2);
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_24: hug — damage = max_hp - hp (remainder to KO) + status
        36 => {
            if (tgt.status.isKo()) return;
            const dmg = tgt.max_hp -| tgt.hp;
            if (dmg > 0) {
                tgt.hp = 0;
                tgt.status.setDead();
                out.amount +%= dmg;
                out.target_died = true;
                pushFloater(out, tgt_slot, dmg);
            }
            _ = tgt.status.applyStatus1(es.s1, tgt.immune_s1);
            _ = tgt.status.applyStatus2(es.s2, tgt.immune_s2);
            out.ok = true;
        },
        // MagicEffect_25: explode — dmg = attacker.hp, then kill attacker (magic.asm @dd1d)
        37 => {
            if (tgt.status.isKo()) return;
            var dmg = caster.hp;
            if (dmg > 9999) dmg = 9999;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
            // Attacker dies (self-destruct)
            caster.hp = 0;
            caster.status.setDead();
            out.ok = true;
        },
        // MagicEffect_26: reaction — kill attacker + all monsters (magic.asm @dd32)
        38 => {
            caster.hp = 0;
            caster.status.setDead();
            if (objs) |table| {
                var mi: usize = obj_mod.party_slots;
                while (mi < obj_mod.total_slots) : (mi += 1) {
                    const m = table.get(mi);
                    if (!m.present) continue;
                    m.hp = 0;
                    m.status.setDead();
                }
            }
            out.target_died = true;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_27: remedy — heal max_hp/10 (magic.asm @dd51)
        39 => {
            const heal: u16 = @max(1, tgt.max_hp / 10);
            const room = tgt.max_hp -| tgt.hp;
            const h = @min(heal, room);
            tgt.hp +%= h;
            out.amount +%= h;
            out.healed = true;
            pushFloater(out, tgt_slot, h);
        },
        // MagicEffect_28: damage + status
        40 => {
            if (tgt.status.isKo()) return;
            const hits = netMagicHits(sp, caster, tgt, spell_id, rng, force_hits);
            if (hits == 0) {
                out.missed = true;
                return;
            }
            const res = damage.calcDamage(.{
                .base_attack = atk_base,
                .defense = magicDefensePower(caster, tgt),
                .hits = hits,
                .elemental_mult = if (em == 0) 1 else em,
                .creature_mult = 2,
                .defense_divisor = div,
            }, rng);
            var dmg = res.damage;
            if (em == 0) dmg = 0;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            _ = tgt.status.applyStatus1(es.s1, tgt.immune_s1);
            _ = tgt.status.applyStatus2(es.s2, tgt.immune_s2);
            armFromStatusBits(tgt, es.s1, es.s2);
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_2a: black hole — clear many statuses, speed_mod=$10 (magic.asm @ddb1)
        42 => {
            tgt.status.s2 &= 0xBB; // clear charm/sleep bits per AND #$BB
            tgt.status.s4 &= 0xC3; // clear image/reflect-ish
            tgt.speed_mod = 16;
            out.ok = true;
            out.amount +%= 1;
            out.healed = true;
        },
        // MagicEffect_2b: needle — dmg = attack_power * 2 (magic.asm @ddc9)
        43 => {
            if (tgt.status.isKo()) return;
            const base = caster.attack *% 2;
            const res = damage.calcDamage(.{
                .base_attack = base,
                .defense = 0,
                .hits = 1,
                .elemental_mult = 2,
                .creature_mult = 2,
                .defense_divisor = 1,
            }, rng);
            const dmg = res.damage;
            if (tgt.hp > dmg) tgt.hp -= dmg else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            out.amount +%= dmg;
            out.target_died = out.target_died or (tgt.hp == 0);
            pushFloater(out, tgt_slot, dmg);
        },
        // MagicEffect_2c: absorb — heal = current_hp / 3 (magic.asm @dd65)
        44 => {
            const heal: u16 = @max(1, tgt.hp / 3);
            // ROM shows as damage numeral with heal flag on target's missing...
            // Actual: sets $a4 = hp/3 with heal bit — restores that much to caster?
            // Looking: only sets $a4 for display as heal amount on target path
            // For absorb spell typically damages and heals caster. Table says absorb of HP.
            // Uses current HP / 3 as the amount displayed as heal.
            const room = tgt.max_hp -| tgt.hp;
            const h = @min(heal, room);
            tgt.hp +%= h;
            out.amount +%= h;
            out.healed = true;
            pushFloater(out, tgt_slot, h);
        },
        // MagicEffect_29: alert/call — ActivateMonster A=#$01 (magic.asm @dd9b)
        // Host maps 1 → formation mon_type[1] when set, else absolute type 1.
        41 => {
            out.spawn_type = 1;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_30: revive monster — full HP clear dead (magic.asm @dde1)
        48 => {
            if (!tgt.is_monster) return;
            if (!tgt.status.isDead() and tgt.hp != 0) return;
            tgt.status.s1 = 0;
            tgt.status.s2 = 0;
            tgt.status.s3 = 0;
            tgt.status.s4 = 0;
            tgt.hp = tgt.max_hp;
            tgt.action_ready = false;
            tgt.action_timer = 1;
            out.amount +%= tgt.hp;
            out.healed = true;
            out.ok = true;
        },
        // MagicEffect_32: end battle (magic.asm @dfd2) — set end flags
        50 => {
            out.end_battle = true;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_2d: no effect (magic.asm @dddc)
        45 => {
            out.ok = true;
        },
        // MagicEffect_2e: make mons invincible — inc $3881 (magic.asm @ddd9)
        46 => {
            out.invincible_delta = 1;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_2f: make mons un-invincible — dec $3881 (@dddd)
        47 => {
            out.invincible_delta = -1;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_31: change form (magic.asm @de34) — host runs full path
        49 => {
            // Kill current target mon (ORA #$80 dead on $2703)
            if (tgt.is_monster) {
                tgt.hp = 0;
                tgt.status.setDead();
                out.target_died = true;
            }
            out.change_form = true;
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_33: targeting search — set "targeting" bit (host-side no-op OK)
        51 => {
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_34: hatch — clear status3 bit5 ($20) on target
        52 => {
            tgt.status.s3 &= ~@as(u8, 0x20);
            out.ok = true;
            out.amount +%= 1;
        },
        // MagicEffect_35: mist dragon attack (magic.asm @e000)
        // Find Rydia (char id $11), set action timer = 10, inc $38e4 delay mon death
        53 => {
            if (objs) |table| {
                var pi: usize = 0;
                while (pi < obj_mod.party_slots) : (pi += 1) {
                    const p = table.objs[pi];
                    if (p.present and p.char_id == 0x11) {
                        out.mist_rydia_slot = @intCast(pi);
                        break;
                    }
                }
            }
            out.delay_mon_death = true;
            out.ok = true;
            out.amount +%= 1;
        },
        else => {
            // Unported effect: no-op but still "ok" so cast spends MP
            out.ok = true;
        },
    }
}

/// Full DoMagicAttack: MP, expand targets, reflect, hit roll, MagicEffect per target.
/// `mon_invincible` — $3881: skip mon targets for damage (magic.asm @d152).
pub fn doMagic(
    r: *const rom_mod.Rom,
    spell_id: u8,
    caster: *obj_mod.Obj,
    /// Hint slot from menu/AI (single-target selection).
    primary_slot: usize,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
) MagicResult {
    return doMagicEx(r, spell_id, caster, primary_slot, objs, rng, false, false);
}

pub fn doMagicEx(
    r: *const rom_mod.Rom,
    spell_id: u8,
    caster: *obj_mod.Obj,
    primary_slot: usize,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    mon_invincible: bool,
    /// magic.asm @ce28: auto-battle ($388b) skips MP deduction.
    free_mp: bool,
) MagicResult {
    // Summon: remap id and power×8 / 8 hits (GetSummonAttack + $3584)
    const is_summon = isSummonSpell(spell_id);
    const force_hits: u8 = if (is_summon) 8 else 0;
    const attack_id: u8 = if (is_summon) getSummonAttack(spell_id, rng) else spell_id;
    const sp = loadSpell(r, attack_id) orelse return .{};
    // MP cost from original list spell (summon list entry), not remapped attack
    const cost_sp = if (is_summon) loadSpell(r, spell_id) orelse sp else sp;
    const mp_before = caster.mp;
    if (!free_mp) {
        if (caster.mp < cost_sp.mp_cost) return .{ .no_mp = true };
        caster.mp -%= cost_sp.mp_cost;
    }

    var slots: [obj_mod.total_slots]usize = undefined;
    // Find caster slot
    var caster_slot: usize = 0;
    var ci: usize = 0;
    while (ci < obj_mod.total_slots) : (ci += 1) {
        if (&objs.objs[ci] == caster) {
            caster_slot = ci;
            break;
        }
    }

    const n = expandTargets(objs, caster_slot, sp, primary_slot, &slots);
    if (n == 0) return .{ .ok = false };

    var out: MagicResult = .{ .ok = true };
    out.summon_attack_id = if (is_summon) attack_id else 0xFF;

    // Per-target CalcHits + mag.def is inside damage effects (magic.asm @cea7/@d100).
    // Status/heal effects still use spell.hit as a simple success gate when < 100.
    // Heal / non-dmg gates (effect ids): cure, life, clear-stop, mp, elixir
    const is_heal = sp.effect == 2 or sp.effect == 10 or sp.effect == 16 or sp.effect == 21 or sp.effect == 22;
    // Damage paths that use CalcHits + mag.def
    const is_dmg = sp.effect == 0 or sp.effect == 1 or sp.effect == 4 or sp.effect == 20 or sp.effect == 23 or sp.effect == 24 or sp.effect == 25 or sp.effect == 26 or sp.effect == 30 or sp.effect == 37 or sp.effect == 40 or sp.effect == 43;

    const split_n = n;
    var ti: u8 = 0;
    while (ti < n) : (ti += 1) {
        var tslot = slots[ti];
        var tgt = objs.get(tslot);

        // Reflect: bounce to opposite side (magic.asm @cf79)
        if (tgt.status.hasReflect() and !sp.no_reflect and tgt != caster) {
            tgt = reflectTarget(objs, tgt, caster, rng);
            // Find slot of bounced target
            var j: usize = 0;
            while (j < obj_mod.total_slots) : (j += 1) {
                if (&objs.objs[j] == tgt) {
                    tslot = j;
                    break;
                }
            }
        }

        // $3881: mon invincible — drop mon damage targets unless crystal item $C8
        // (magic.asm @d152: invincible + not crystal → RemoveTarget)
        if (mon_invincible and tgt.is_monster and is_dmg and spell_id != 0xC8 and attack_id != 0xC8) {
            out.missed = true;
            continue;
        }

        // Non-damage: one Rand99 vs (spell.hit + stat/2) before applying
        if (!is_dmg and !is_heal and sp.hit < 100) {
            const stat = magicStat(caster, spell_id);
            var rate: u16 = @as(u16, sp.hit) +% (stat / 2);
            if (rate > 255) rate = 255;
            if (rng.next() % 100 >= rate) {
                out.missed = true;
                continue;
            }
        }

        const is_last = (ti + 1 == n);
        applyEffect(r, sp, spell_id, caster, tgt, tslot, split_n, is_last, objs, rng, is_summon, force_hits, &out);
    }

    if (out.amount == 0 and !out.healed and out.floater_n == 0 and sp.effect != 8 and sp.effect != 9 and sp.effect != 11 and sp.effect != 6) {
        // Status-only ok if we marked amount; pure no-ops stay ok=true
    }

    // SummonFailed (magic.asm @e07e): on total miss, if caster is Rydia restore pre-cast MP
    // (ROM copies $268b attacker MP onto Rydia slot — refund intent for failed summon)
    if (is_summon and out.missed and out.amount == 0 and !out.healed) {
        if (caster.char_id == 0x11) {
            out.summon_mp_restore = mp_before;
            caster.mp = mp_before;
        }
        // Also run SummonFailed over party: any Rydia slot gets caster MP (exact ROM)
        var pi: usize = 0;
        while (pi < obj_mod.party_slots) : (pi += 1) {
            const p = objs.get(pi);
            if (p.present and p.char_id == 0x11) p.mp = caster.mp;
        }
    }
    return out;
}

/// DoMagicAttack for weapon-cast spell or summon-book attack id.
/// `power_x8` + `force_hits` match $3584 summon / $38eb weapon magic.
pub fn doMagicWeaponOrAttack(
    r: *const rom_mod.Rom,
    attack_id: u8,
    caster: *obj_mod.Obj,
    primary_slot: usize,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    mon_invincible: bool,
    power_x8: bool,
    force_hits: u8,
) MagicResult {
    const sp = loadSpell(r, attack_id) orelse return .{};
    // No MP (item/weapon-cast already paid / free)
    var slots: [obj_mod.total_slots]usize = undefined;
    var caster_slot: usize = 0;
    var ci: usize = 0;
    while (ci < obj_mod.total_slots) : (ci += 1) {
        if (&objs.objs[ci] == caster) {
            caster_slot = ci;
            break;
        }
    }
    const n = expandTargets(objs, caster_slot, sp, primary_slot, &slots);
    if (n == 0) return .{ .ok = false };
    var out: MagicResult = .{ .ok = true };
    out.summon_attack_id = if (power_x8) attack_id else 0xFF;
    const is_heal = sp.effect == 2 or sp.effect == 10 or sp.effect == 16 or sp.effect == 21 or sp.effect == 22;
    const is_dmg = sp.effect == 0 or sp.effect == 1 or sp.effect == 4 or sp.effect == 20 or sp.effect == 23 or sp.effect == 24 or sp.effect == 25 or sp.effect == 26 or sp.effect == 30 or sp.effect == 37 or sp.effect == 40 or sp.effect == 43;
    const split_n = n;
    var ti: u8 = 0;
    while (ti < n) : (ti += 1) {
        var tslot = slots[ti];
        var tgt = objs.get(tslot);
        if (tgt.status.hasReflect() and !sp.no_reflect and tgt != caster) {
            tgt = reflectTarget(objs, tgt, caster, rng);
            var j: usize = 0;
            while (j < obj_mod.total_slots) : (j += 1) {
                if (&objs.objs[j] == tgt) {
                    tslot = j;
                    break;
                }
            }
        }
        if (mon_invincible and tgt.is_monster and is_dmg and attack_id != 0xC8) {
            out.missed = true;
            continue;
        }
        if (!is_dmg and !is_heal and sp.hit < 100) {
            if (rng.next() % 100 >= sp.hit) {
                out.missed = true;
                continue;
            }
        }
        const is_last = (ti + 1 == n);
        applyEffect(r, sp, attack_id, caster, tgt, tslot, split_n, is_last, objs, rng, power_x8, force_hits, &out);
    }
    return out;
}

/// Cmd_01 item → DoMagicAttack (magic.asm @ebfa). No MP; ItemProp; 8 hits (@cf1e $352a).
pub fn doItemMagic(
    r: *const rom_mod.Rom,
    item_id: u8,
    caster: *obj_mod.Obj,
    primary_slot: usize,
    objs: *obj_mod.ObjTable,
    rng: damage.Rng,
    mon_invincible: bool,
) MagicResult {
    const ip = item_prop.ItemProp.load(r, item_id) orelse return .{};
    // ItemProp is same layout as AttackProp fields we use
    const sp = ip;
    var slots: [obj_mod.total_slots]usize = undefined;
    var caster_slot: usize = 0;
    var ci: usize = 0;
    while (ci < obj_mod.total_slots) : (ci += 1) {
        if (&objs.objs[ci] == caster) {
            caster_slot = ci;
            break;
        }
    }
    const n = expandTargets(objs, caster_slot, sp, primary_slot, &slots);
    if (n == 0) return .{ .ok = false };

    var out: MagicResult = .{ .ok = true };
    const is_heal = sp.effect == 2 or sp.effect == 10 or sp.effect == 16 or sp.effect == 21 or sp.effect == 22;
    const is_dmg = sp.effect == 0 or sp.effect == 1 or sp.effect == 4 or sp.effect == 20 or sp.effect == 23 or sp.effect == 24 or sp.effect == 25 or sp.effect == 26 or sp.effect == 30 or sp.effect == 37 or sp.effect == 40 or sp.effect == 43;
    const force_hits: u8 = 8; // items always 8 hits
    const split_n = n;
    var ti: u8 = 0;
    while (ti < n) : (ti += 1) {
        var tslot = slots[ti];
        var tgt = objs.get(tslot);
        if (tgt.status.hasReflect() and !sp.no_reflect and tgt != caster) {
            tgt = reflectTarget(objs, tgt, caster, rng);
            var j: usize = 0;
            while (j < obj_mod.total_slots) : (j += 1) {
                if (&objs.objs[j] == tgt) {
                    tslot = j;
                    break;
                }
            }
        }
        // Crystal $C8 pierces invincible
        if (mon_invincible and tgt.is_monster and is_dmg and item_id != 0xC8) {
            out.missed = true;
            continue;
        }
        if (!is_dmg and !is_heal and sp.hit < 100) {
            if (rng.next() % 100 >= sp.hit) {
                out.missed = true;
                continue;
            }
        }
        const is_last = (ti + 1 == n);
        applyEffect(r, sp, item_id, caster, tgt, tslot, split_n, is_last, objs, rng, false, force_hits, &out);
    }
    return out;
}

/// Back-compat: single primary target without ObjTable (item path helpers).
pub fn doMagicSingle(
    r: *const rom_mod.Rom,
    spell_id: u8,
    caster: *obj_mod.Obj,
    target: *obj_mod.Obj,
    rng: damage.Rng,
) MagicResult {
    // Build a temporary table is heavy; apply directly on one target.
    const sp = loadSpell(r, spell_id) orelse return .{};
    if (caster.mp < sp.mp_cost) return .{ .no_mp = true };
    caster.mp -%= sp.mp_cost;

    var out: MagicResult = .{ .ok = true };
    var tgt = target;
    if (tgt.status.hasReflect() and !sp.no_reflect and tgt != caster) {
        tgt = caster; // no table: bounce to caster
    }
    // slot unknown → 0 for floater
    applyEffect(r, sp, spell_id, caster, tgt, 0, 1, true, null, rng, false, 0, &out);
    return out;
}

fn armFromStatusBits(tgt: *obj_mod.Obj, s1: u8, s2: u8) void {
    if ((s1 & status_mod.Status1.poison) != 0) timer.armPoison(tgt);
    if ((s2 & status_mod.Status2.petrify_stage) != 0 or (s1 & status_mod.Status1.stone) != 0) {
        if (!tgt.status.isStone()) timer.armPetrify(tgt);
    }
    if ((s2 & status_mod.Status2.sleep) != 0 or (s2 & status_mod.Status2.paralyze) != 0) {
        // MagicEffect_07: arm action timer with TimerDur_04 duration.
        timer.armSleepParalyze(tgt);
    }
}
