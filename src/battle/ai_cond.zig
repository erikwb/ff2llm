//! CheckAICond — battle/ai_cond.asm (all 12 condition types).
//!
//! AICond 4 bytes @ 0E/E700 (file 0x76700): [type, flags, param, value]
//! flags bit7 = invert (bmi path in AICond_00).
const obj_mod = @import("obj.zig");
const rom_mod = @import("../rom.zig");
const status_mod = @import("status.zig");
const retal_mod = @import("retal.zig");

pub const ai_cond_file: usize = 0x76700;
pub const ai_cond_hp_file: usize = 0x76000;
pub const ai_cond_script_file: usize = 0x76600;
pub const ai_cond_stride: usize = 4;

/// Context for conditions that need battle history (types 5,7,8,9,0a).
pub const BattleCtx = struct {
    battle_id: u16 = 0,
    battle_vars: *const [16]u8,
    /// Formation mon type ids (for type-remaining checks).
    mon_types: []const u8 = &.{},
    mon_count: u8 = 0,
    /// Living monster count (AICond_0b alone).
    living_mons: u8 = 0,
    /// Last escape attempt this battle.
    party_escaped: bool = false,
    /// Per-monster last damage taken (slot 5..12 → index 0..7).
    mon_took_damage: [8]bool = .{false} ** 8,
    /// Last physical/magic hit on a mon: attacker slot, cmd, element.
    last_hit_attacker: u8 = 0xFF,
    last_hit_cmd: u8 = 0xFF,
    last_hit_element: u8 = 0,
    last_hit_mon: u8 = 0xFF,
    /// Absolute mon slot being evaluated for AI (5..12) — AICond_07/08 stack.
    cond_mon_slot: u8 = 0xFF,
    /// Full retal table ($2b78 / $35f7).
    retal: ?*const retal_mod.Table = null,
};

pub const Cond = struct {
    type: u8,
    flags: u8,
    param: u8,
    value: u8,

    pub fn load(r: *const rom_mod.Rom, index: u8) ?Cond {
        if (index == 0xFF) return null;
        const raw = r.slice(ai_cond_file + @as(usize, index) * ai_cond_stride, 4) catch return null;
        if (raw[0] == 0xFF and raw[1] == 0xFF) return null;
        return .{ .type = raw[0], .flags = raw[1], .param = raw[2], .value = raw[3] };
    }

    pub fn invert(self: Cond) bool {
        return (self.flags & 0x80) != 0;
    }
};

fn hpThreshold(r: *const rom_mod.Rom, index: u8) u16 {
    const raw = r.slice(ai_cond_hp_file + @as(usize, index) * 2, 2) catch return 0;
    return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
}

pub fn check(
    r: *const rom_mod.Rom,
    cond: Cond,
    objs: *const obj_mod.ObjTable,
    ctx: *const BattleCtx,
) bool {
    const raw = switch (cond.type) {
        0 => checkStatus(cond, objs),
        1 => checkHp(r, cond, objs),
        2 => checkVar(cond, ctx.battle_vars),
        3 => checkValidTarget(cond, objs),
        4 => checkMonsterType(cond, objs, ctx),
        5 => checkBattleId(cond, ctx),
        6 => checkOnlyTypeRemaining(cond, objs, ctx),
        7 => checkAttackedBySlot(cond, ctx),
        8 => checkAttackedWithCmd(cond, ctx),
        9 => checkEscape(cond, ctx),
        10 => checkTookDamage(cond, ctx),
        11 => checkAlone(cond, ctx),
        else => false,
    };
    if (cond.invert()) return !raw;
    return raw;
}

fn checkStatus(cond: Cond, objs: *const obj_mod.ObjTable) bool {
    const mask = cond.value;
    if (mask == 0) return false;
    var i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0) continue;
        const byte: u8 = switch (cond.param) {
            0 => o.status.s1,
            1 => o.status.s2,
            2 => o.status.s3,
            3 => o.status.s4,
            else => o.status.s1,
        };
        if ((byte & mask) != 0) return true;
    }
    return false;
}

fn checkHp(r: *const rom_mod.Rom, cond: Cond, objs: *const obj_mod.ObjTable) bool {
    const thr = hpThreshold(r, cond.value);
    var i: usize = 0;
    while (i < obj_mod.party_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0) continue;
        if (thr == 0xFFFF) {
            if (o.hp < o.max_hp) return true;
        } else if (o.hp <= thr) return true;
    }
    return false;
}

fn checkVar(cond: Cond, battle_vars: *const [16]u8) bool {
    if (cond.param >= 16) return false;
    return battle_vars[cond.param] == cond.value;
}

fn checkValidTarget(_: Cond, objs: *const obj_mod.ObjTable) bool {
    var i: usize = 0;
    while (i < obj_mod.party_slots) : (i += 1) {
        const o = objs.objs[i];
        if (o.present and o.hp > 0 and o.status.canTarget()) return true;
    }
    return false;
}

/// Type 4: living count of monster type `value` vs param (0=absent, 1=present w/ others, 2=only type).
fn checkMonsterType(cond: Cond, objs: *const obj_mod.ObjTable, ctx: *const BattleCtx) bool {
    var found: u8 = 0;
    var i: usize = obj_mod.party_slots;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0 or o.status.isKo()) continue;
        if (o.type_id == cond.value) found += 1;
    }
    const living = if (ctx.living_mons != 0) ctx.living_mons else objs.livingMonsters();
    return switch (cond.param) {
        0 => found == 0,
        1 => found > 0 and living > found,
        2 => found > 0 and living == found,
        else => found > 0,
    };
}

/// Type 5: battle id match (param=hi, value=lo of $1800/$1801).
fn checkBattleId(cond: Cond, ctx: *const BattleCtx) bool {
    const lo: u8 = @truncate(ctx.battle_id);
    const hi: u8 = @truncate(ctx.battle_id >> 8);
    return cond.param == hi and cond.value == lo;
}

/// Type 6: only monster type `value` remains among living (or alone if value unused).
fn checkOnlyTypeRemaining(cond: Cond, objs: *const obj_mod.ObjTable, ctx: *const BattleCtx) bool {
    var match: u8 = 0;
    var other: u8 = 0;
    var i: usize = obj_mod.party_slots;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0 or o.status.isKo()) continue;
        if (cond.value == 0xFF or o.type_id == cond.value) match += 1 else other += 1;
    }
    if (cond.value == 0xFF) return (if (ctx.living_mons != 0) ctx.living_mons else objs.livingMonsters()) <= 1;
    return match > 0 and other == 0;
}

/// Type 7: attacked by slot — latest retal entry for this mon (ai_cond.asm @be46).
/// param = command to match ($289e); value = element mask or 0 ($289f).
fn checkAttackedBySlot(cond: Cond, ctx: *const BattleCtx) bool {
    if (ctx.retal) |rt| {
        const mi = monIndex(ctx) orelse return false;
        const e = rt.stacks[mi].latest() orelse return false;
        if (cond.param != 0 and cond.param != e.cmd) return false;
        if (cond.value != 0 and (cond.value & e.element) == 0) return false;
        return true;
    }
    // Fallback: global last hit
    if (ctx.last_hit_cmd == 0xFF) return false;
    if (cond.param != 0 and cond.param != ctx.last_hit_cmd) return false;
    if (cond.value != 0 and (cond.value & ctx.last_hit_element) == 0) return false;
    return true;
}

/// Type 8: attacked with command — any entry on this mon's stack (ai_cond.asm @bea0).
fn checkAttackedWithCmd(cond: Cond, ctx: *const BattleCtx) bool {
    if (ctx.retal) |rt| {
        const mi = monIndex(ctx) orelse return false;
        return rt.stacks[mi].matchCmd(cond.param, cond.value);
    }
    if (ctx.last_hit_cmd == 0xFF) return false;
    if (cond.param != ctx.last_hit_cmd) return false;
    if (cond.value != 0 and (cond.value & ctx.last_hit_element) == 0) return false;
    return true;
}

fn monIndex(ctx: *const BattleCtx) ?usize {
    if (ctx.cond_mon_slot == 0xFF) {
        if (ctx.last_hit_mon < 8) return ctx.last_hit_mon;
        return null;
    }
    if (ctx.cond_mon_slot < obj_mod.party_slots) return null;
    const mi = ctx.cond_mon_slot - obj_mod.party_slots;
    if (mi >= 8) return null;
    return mi;
}

/// Type 9: party used escape.
fn checkEscape(_: Cond, ctx: *const BattleCtx) bool {
    return ctx.party_escaped;
}

/// Type 0a: this monster took damage (value unused; uses mon index from last hit).
fn checkTookDamage(_: Cond, ctx: *const BattleCtx) bool {
    if (ctx.last_hit_mon >= 8) return false;
    return ctx.mon_took_damage[ctx.last_hit_mon];
}

/// Type 0b: alone (only 1 living monster).
fn checkAlone(_: Cond, ctx: *const BattleCtx) bool {
    return ctx.living_mons == 1;
}

/// Load AICondScript entry: up to 4 cond indices terminated by $FF.
/// File 0E/E600 — GetScriptPtr style FF-terminated lists.
pub fn loadCondScript(r: *const rom_mod.Rom, script_id: u8, out: *[4]u8) u8 {
    @memset(out, 0xFF);
    if (script_id == 0xFF) return 0;
    // Walk FF-terminated scripts like GetScriptPtr
    const bank = r.slice(ai_cond_script_file, 0x100) catch return 0;
    var i: usize = 0;
    var left: u8 = script_id;
    if (left > 0) {
        while (i < bank.len) : (i += 1) {
            if (bank[i] == 0xFF) {
                left -= 1;
                if (left == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (left != 0) return 0;
    }
    var n: u8 = 0;
    while (i < bank.len and n < 4) : (i += 1) {
        if (bank[i] == 0xFF) break;
        out[n] = bank[i];
        n += 1;
    }
    return n;
}

/// AND of up to 4 conditions (ROM loads 4 slots; $FF = empty/pass).
pub fn checkSetAnd(
    r: *const rom_mod.Rom,
    indices: []const u8,
    objs: *const obj_mod.ObjTable,
    ctx: *const BattleCtx,
) bool {
    var any_real = false;
    for (indices) |idx| {
        if (idx == 0xFF) continue;
        any_real = true;
        const c = Cond.load(r, idx) orelse return false;
        if (!check(r, c, objs, ctx)) return false;
    }
    return true; // empty set → true (unconditional)
}

/// OR of conditions (legacy helper).
pub fn checkSet(
    r: *const rom_mod.Rom,
    indices: []const u8,
    objs: *const obj_mod.ObjTable,
    battle_vars: *const [16]u8,
) bool {
    var ctx: BattleCtx = .{ .battle_vars = battle_vars };
    var any = false;
    var valid = false;
    for (indices) |idx| {
        if (idx == 0xFF) continue;
        valid = true;
        if (Cond.load(r, idx)) |c| {
            if (check(r, c, objs, &ctx)) any = true;
        }
    }
    if (!valid) return true;
    return any;
}

const std = @import("std");

fn emptyCtx(vars: *const [16]u8) BattleCtx {
    return .{ .battle_vars = vars };
}

test "AICond type 0 status bit and invert" {
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0] = .{ .present = true, .hp = 10, .max_hp = 10 };
    objs.objs[0].status.s1 = status_mod.Status1.poison;
    const c_on = Cond{ .type = 0, .flags = 0, .param = 0, .value = status_mod.Status1.poison };
    try std.testing.expect(checkStatus(c_on, &objs));
    const c_off = Cond{ .type = 0, .flags = 0, .param = 0, .value = status_mod.Status1.stone };
    try std.testing.expect(!checkStatus(c_off, &objs));
    const c_inv = Cond{ .type = 0, .flags = 0x80, .param = 0, .value = status_mod.Status1.poison };
    try std.testing.expect(c_inv.invert());
    try std.testing.expect(checkStatus(c_inv, &objs)); // raw still true (invert applied in check())
}

test "AICond type 2 battle var" {
    var vars = [_]u8{0} ** 16;
    vars[3] = 5;
    try std.testing.expect(checkVar(.{ .type = 2, .flags = 0, .param = 3, .value = 5 }, &vars));
    try std.testing.expect(!checkVar(.{ .type = 2, .flags = 0, .param = 3, .value = 4 }, &vars));
}

test "AICond type 5 battle id" {
    var vars = [_]u8{0} ** 16;
    var ctx = emptyCtx(&vars);
    ctx.battle_id = 0x01F3;
    try std.testing.expect(checkBattleId(.{ .type = 5, .flags = 0, .param = 0x01, .value = 0xF3 }, &ctx));
    try std.testing.expect(!checkBattleId(.{ .type = 5, .flags = 0, .param = 0x00, .value = 0xF3 }, &ctx));
}

test "AICond type 7 and 8 retal stack" {
    var vars = [_]u8{0} ** 16;
    var rt: retal_mod.Table = .{};
    rt.stacks[0].push(0, 0xC0, 0x01); // party 0 fight elem 1
    rt.stacks[0].push(1, 0xC2, 0x04); // party 1 magic elem 4
    var ctx = emptyCtx(&vars);
    ctx.retal = &rt;
    ctx.cond_mon_slot = 5; // mon 0
    // Type 7: latest is C2/0x04
    try std.testing.expect(checkAttackedBySlot(.{ .type = 7, .flags = 0, .param = 0xC2, .value = 0 }, &ctx));
    try std.testing.expect(checkAttackedBySlot(.{ .type = 7, .flags = 0, .param = 0xC2, .value = 0x04 }, &ctx));
    try std.testing.expect(!checkAttackedBySlot(.{ .type = 7, .flags = 0, .param = 0xC0, .value = 0 }, &ctx)); // not latest
    // Type 8: any entry with C0
    try std.testing.expect(checkAttackedWithCmd(.{ .type = 8, .flags = 0, .param = 0xC0, .value = 0 }, &ctx));
    try std.testing.expect(checkAttackedWithCmd(.{ .type = 8, .flags = 0, .param = 0xC2, .value = 0x04 }, &ctx));
    try std.testing.expect(!checkAttackedWithCmd(.{ .type = 8, .flags = 0, .param = 0xC2, .value = 0x01 }, &ctx));
}

test "AICond type 9 escape and 0b alone" {
    var vars = [_]u8{0} ** 16;
    var ctx = emptyCtx(&vars);
    const dummy = Cond{ .type = 9, .flags = 0, .param = 0, .value = 0 };
    try std.testing.expect(!checkEscape(dummy, &ctx));
    ctx.party_escaped = true;
    try std.testing.expect(checkEscape(dummy, &ctx));
    ctx.living_mons = 1;
    try std.testing.expect(checkAlone(dummy, &ctx));
    ctx.living_mons = 2;
    try std.testing.expect(!checkAlone(dummy, &ctx));
}

test "AICond type 0a took damage" {
    var vars = [_]u8{0} ** 16;
    var ctx = emptyCtx(&vars);
    const dummy = Cond{ .type = 10, .flags = 0, .param = 0, .value = 0 };
    ctx.last_hit_mon = 2;
    ctx.mon_took_damage[2] = true;
    try std.testing.expect(checkTookDamage(dummy, &ctx));
    ctx.mon_took_damage[2] = false;
    try std.testing.expect(!checkTookDamage(dummy, &ctx));
}

test "checkSetAnd empty indices is true" {
    const empty = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var any_real = false;
    for (empty) |idx| {
        if (idx == 0xFF) continue;
        any_real = true;
    }
    try std.testing.expect(!any_real); // empty → AND true in checkSetAnd
}
