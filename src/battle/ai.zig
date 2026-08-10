//! GetMonsterAttack — battle/ai.asm action script interpreter (AIAction1 subset).
//!
//! AIAction1 @ 0E/E900 (file 0x76900): FF-terminated scripts indexed by GetScriptPtr
//! (Nth script = skip N FF terminators).
//!
//! Script bytes (GetMonsterAttack @b587–@b67f):
//!   $00–$BF  spell id → command $C2 (magic) + spell
//!   $C0      Fight
//!   $C1–$DF  other battle commands (not fully executed here)
//!   $E1      no action
//!   $E8–$EF  ChangeMonsterStat + param (LoadMonsterStat for E9–EB)
//!   $F4–$F7  ChangeBattleVar + param
//!   $F9      GetAITarget + target id
//!   $FA–$FE  flow control (delay etc.) — stop chain
//!   $FF      end
const obj_mod = @import("obj.zig");
const damage = @import("damage.zig");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const status_mod = @import("status.zig");

/// AIAction1 scripts base (LoROM $0E/E900) — normal worlds.
pub const ai_action1_file: usize = 0x76900;
/// AIAction2 moon scripts (LoROM $0E/B6C0) — when $38ef set from $1801 bit7.
pub const ai_action2_file: usize = 0x736C0;
/// AIScript bank for retaliation (LoROM $0E/E030) — init.asm @91af GetScriptPtr AIScript.
pub const ai_script_file: usize = 0x76030;
const ai_script_bank_size: usize = 0x5D0;
/// Generous cap for walking scripts.
const action_bank_size: usize = 0x700;
const action2_bank_size: usize = 0x400;

pub const MonAction = struct {
    /// $C0 fight, $C2 magic, $E1 none, else command id.
    cmd: u8 = 0xC0,
    /// Spell id when cmd == $C2.
    spell_id: u8 = 0,
    /// Target object slot.
    target_slot: usize = 0,
    no_target: bool = false,
    /// BattleDlg ids from AIAction $F1/$F2 (btlgfx battle dialogue).
    dlg: [8]u8 = .{0xFF} ** 8,
    dlg_n: u8 = 0,
    /// $FD: multi-action chain begun (ai.asm @b5ed — $3877++). Host: mon acts again soon.
    multi_begin: bool = false,
    /// $FC: multi-action segment end (ai.asm @b606 — $3877--).
    multi_end: bool = false,
    /// $FE: delay/yield this step (ai.asm @b5ca clears multi; InitAIDelay).
    delayed: bool = false,

    pub fn pushDlg(self: *MonAction, id: u8) void {
        if (self.dlg_n >= self.dlg.len) return;
        self.dlg[self.dlg_n] = id;
        self.dlg_n += 1;
    }
};

/// GetScriptPtr: find start of Nth FF-terminated script in bank.
pub fn getScriptPtr(bank: []const u8, index: u8) ?[]const u8 {
    if (index == 0xFF or bank.len == 0) return null;
    var i: usize = 0;
    var left: u8 = index;
    if (left == 0) {
        // first script
    } else {
        while (i < bank.len) : (i += 1) {
            if (bank[i] == 0xFF) {
                left -= 1;
                if (left == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (left != 0) return null;
    }
    const start = i;
    while (i < bank.len and bank[i] != 0xFF) : (i += 1) {}
    if (start >= bank.len) return null;
    return bank[start..i]; // without trailing FF
}

/// GetDefaultAITarget for party (ai.asm @bc31).
pub fn getDefaultAITargetParty(
    objs: *const obj_mod.ObjTable,
    rng: damage.Rng,
) ?usize {
    var slots: [obj_mod.party_slots]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < obj_mod.party_slots) : (i += 1) {
        const o = objs.objs[i];
        if (!o.present or o.hp == 0) continue;
        if (o.status.isKo()) continue;
        if (o.jumping()) continue;
        if (o.status.isHidden()) continue;
        slots[n] = i;
        n += 1;
    }
    if (n == 0) return null;
    return slots[rng.next() % n];
}

/// AI target ids $00–$15 char, $26 front row, $27 back, $28 all chars → pick one.
fn resolveAiTarget(objs: *const obj_mod.ObjTable, target_id: u8, rng: damage.Rng) ?usize {
    return switch (target_id) {
        0x00...0x04 => blk: {
            // Character slot by id — map to party slot if present
            const s: usize = target_id;
            if (s < obj_mod.party_slots and objs.objs[s].present and objs.objs[s].hp > 0)
                break :blk s;
            break :blk getDefaultAITargetParty(objs, rng);
        },
        0x26 => blk: { // random front row
            var slots: [5]usize = undefined;
            var n: usize = 0;
            var i: usize = 0;
            while (i < obj_mod.party_slots) : (i += 1) {
                const o = objs.objs[i];
                if (o.present and o.hp > 0 and o.row == 0) {
                    slots[n] = i;
                    n += 1;
                }
            }
            if (n == 0) break :blk getDefaultAITargetParty(objs, rng);
            break :blk slots[rng.next() % n];
        },
        0x27 => blk: { // random back row
            var slots: [5]usize = undefined;
            var n: usize = 0;
            var i: usize = 0;
            while (i < obj_mod.party_slots) : (i += 1) {
                const o = objs.objs[i];
                if (o.present and o.hp > 0 and o.row != 0) {
                    slots[n] = i;
                    n += 1;
                }
            }
            if (n == 0) break :blk getDefaultAITargetParty(objs, rng);
            break :blk slots[rng.next() % n];
        },
        else => getDefaultAITargetParty(objs, rng),
    };
}

/// LoadMonsterStat — MonsterStats[index×3] → $291c/$291d/$291e (init.asm @9489).
fn loadMonsterStat(r: *const rom_mod.Rom, index: u8) struct { a: u8, b: u8, c: u8 } {
    if (index >= offsets.en.monster_stat_count) return .{ .a = 0, .b = 0, .c = 0 };
    const off = offsets.en.monster_stats + @as(usize, index) * offsets.en.monster_stat_stride;
    const raw = r.slice(off, 3) catch return .{ .a = 0, .b = 0, .c = 0 };
    return .{ .a = raw[0], .b = raw[1], .c = raw[2] };
}

/// ChangeMonsterStat ($E8–$EF) — ai.asm @b76f. Mutates mon in place.
fn changeMonsterStat(objs: *const obj_mod.ObjTable, mon_slot: usize, op: u8, val: u8, rom: ?*const rom_mod.Rom) void {
    const mon = @constCast(&objs.objs[mon_slot]);
    switch (op) {
        0xE8 => mon.creature_type = val, // $2040
        0xE9 => {
            // Attack: LoadMonsterStat → $201b/$201c/$201d (raw, no clamps)
            if (rom) |r| {
                const st = loadMonsterStat(r, val);
                mon.attack_mult = st.a;
                mon.hit_rate = st.b;
                mon.attack = st.c;
            }
        },
        0xEA => {
            // Defense: LoadMonsterStat → $2028/$2029/$202a (exact EA path)
            if (rom) |r| {
                const st = loadMonsterStat(r, val);
                mon.defense_mult = st.a;
                mon.defense_rate = st.b;
                mon.defense = st.c;
            }
        },
        0xEB => {
            // Mag.def: ROM stores mult→$2022, rate→$2024, power→$2024 (overwrites rate).
            // Consumers read $2722 mult, $2723 rate, $2724 power — we keep semantic fields.
            if (rom) |r| {
                const st = loadMonsterStat(r, val);
                mon.mdef_mult = st.a;
                mon.mdef_rate = st.b; // intended $2023; ROM never writes rate here
                mon.mdef = st.c; // final $2024 value after double-store
            }
        },
        0xEC => {
            // Speed modifier (ai.asm @b7ff): delta = max(1, val * base_timer * 100 / 1000)
            // signed: bit7 → subtract from $2060 base timer, else add. Min base 1.
            const base = mon.base_timer;
            const v16: u16 = val;
            var product: u32 = @as(u32, v16) *% @as(u32, base);
            product *%= 100;
            var delta: u16 = @intCast(@min(product / 1000, 0xFFFF));
            if (delta == 0) delta = 1;
            if ((val & 0x80) != 0) {
                if (mon.base_timer > delta) mon.base_timer -= delta else mon.base_timer = 1;
            } else {
                mon.base_timer +%= delta;
            }
            mon.speed_mod = val;
        },
        0xED => {
            // Strong/immune elements: always write $2025; bit7 → also $2026 + clear $2025
            if ((val & 0x80) != 0) {
                mon.immune_elem = val;
                mon.strong_elem = 0;
            } else mon.strong_elem = val;
        },
        0xEE => mon.intellect = val,
        0xEF => {
            // Weak/very weak: always $2020; bit7 also $2021
            if ((val & 0x80) != 0) mon.very_weak_elem = val;
            mon.weak_elem = val;
        },
        else => {},
    }
}

/// Interpret one AIAction script into a MonAction.
/// `battle_vars` is $35f3[0..15] for ChangeBattleVar ($F4–$F7).
pub fn interpretAction(
    script: []const u8,
    objs: *const obj_mod.ObjTable,
    mon_slot: usize,
    rng: damage.Rng,
    battle_vars: ?*[16]u8,
    rom: ?*const rom_mod.Rom,
) MonAction {
    var act: MonAction = .{
        .cmd = 0xC0,
        .target_slot = getDefaultAITargetParty(objs, rng) orelse 0,
        .no_target = false,
    };
    if (act.target_slot == 0 and getDefaultAITargetParty(objs, rng) == null) {
        act.no_target = true;
        act.cmd = 0xE1;
        return act;
    }

    var i: usize = 0;
    while (i < script.len) {
        const b = script[i];
        i += 1;
        if (b == 0xFF) break;
        if (b < 0xC0) {
            // Spell id → magic command $C2
            act.cmd = 0xC2;
            act.spell_id = b;
            continue;
        }
        switch (b) {
            0xC0 => act.cmd = 0xC0, // Fight
            0xE1 => {
                act.cmd = 0xE1;
                act.no_target = true;
                return act;
            },
            0xF9 => {
                if (i < script.len) {
                    const tid = script[i];
                    i += 1;
                    if (resolveAiTarget(objs, tid, rng)) |t| act.target_slot = t;
                }
            },
            // $E8–$EF: ChangeMonsterStat + param (ai.asm @b76f)
            0xE8...0xEF => {
                if (i < script.len) {
                    const val = script[i];
                    i += 1;
                    changeMonsterStat(objs, mon_slot, b, val, rom);
                }
            },
            // $F0: boss frame (skip param); $F1/$F2: battle dialogue + id
            0xF0 => {
                if (i < script.len) i += 1;
            },
            0xF1, 0xF2 => {
                // GfxScriptCmd_f1/f2 — next byte is BattleDlg index.
                if (i < script.len) {
                    act.pushDlg(script[i]);
                    i += 1;
                }
            },
            0xF3 => {
                // play song — skip param (host audio not mid-script yet)
                if (i < script.len) i += 1;
            },
            // $F4–$F7: ChangeBattleVar (y = opcode-$F4; param aavvvvvv)
            0xF4...0xF7 => {
                const vi: u8 = b - 0xF4;
                if (i < script.len) {
                    const raw = script[i];
                    i += 1;
                    if (battle_vars) |bv| {
                        if (vi < 16) {
                            const v: u8 = raw & 0x3F;
                            const op: u8 = raw & 0xC0;
                            if (op == 0) {
                                bv[vi] = bv[vi] +% v; // add
                            } else if (op == 0x40) {
                                bv[vi] = bv[vi] -% v; // sub
                            } else {
                                bv[vi] = v; // set
                            }
                        }
                    }
                }
            },
            // $FA: multi-action continue marker — keep parsing (ai.asm @b5a1 / @b621)
            0xFA => {},
            // $FB: multi-action segment marker — keep reading for command (ai.asm @b5b7/@b61f)
            0xFB => {},
            // $FC: end multi-action segment (ai.asm @b606 dec $3877)
            0xFC => {
                act.multi_end = true;
            },
            // $FD: begin multi-action / counter mode (ai.asm @b5ed inc $3877)
            0xFD => {
                act.multi_begin = true;
            },
            // $FE: delay / yield — stop this chain step (ai.asm @b5ca stz $3877)
            0xFE => {
                act.delayed = true;
                act.multi_begin = false;
                break;
            },
            else => {
                if (b >= 0xC0 and b < 0xE0) act.cmd = b;
            },
        }
    }
    if (getDefaultAITargetParty(objs, rng) == null and act.cmd != 0xE1) {
        act.no_target = true;
        act.cmd = 0xE1;
    }
    return act;
}

/// GetMonsterAttack: berserk → fight; else AIAction + AICond sets or fight.
/// `moon_ai` → AIAction2 bank ($38ef / $1801 bit7).
/// `battle_vars` mutated by ChangeBattleVar opcodes in scripts.
pub fn getMonsterAttack(
    r: ?*const rom_mod.Rom,
    objs: *const obj_mod.ObjTable,
    mon_slot: usize,
    rng: damage.Rng,
    ctx: *const @import("ai_cond.zig").BattleCtx,
    battle_vars: ?*[16]u8,
    moon_ai: bool,
) MonAction {
    const mon = &objs.objs[mon_slot];
    const ai_cond = @import("ai_cond.zig");

    if (!mon.status.canAct()) {
        return .{ .cmd = 0xE1, .no_target = true };
    }

    if (mon.status.isBerserk()) {
        if (getDefaultAITargetParty(objs, rng)) |t| {
            return .{ .cmd = 0xC0, .target_slot = t };
        }
        return .{ .cmd = 0xE1, .no_target = true };
    }

    if (r) |rom| {
        if (mon.ai_action_id != 0xFF) {
            if (loadActionBank(rom, moon_ai)) |bank| {
                // Try action ids base..base+3; for n>0 require AICondScript AND set.
                // Skip empty / pure-$E1 scripts so a bad index does not silence all attacks;
                // real "do nothing" still falls through if every script is $E1.
                var try_id: u16 = mon.ai_action_id;
                var n: u8 = 0;
                while (n < 4 and try_id < 256) : (n += 1) {
                    const cid: u8 = @intCast(try_id);
                    const cond_ok = blk: {
                        if (n == 0) break :blk true;
                        var inds: [4]u8 = undefined;
                        const cn = ai_cond.loadCondScript(rom, cid, &inds);
                        if (cn == 0) {
                            if (ai_cond.Cond.load(rom, cid)) |c| {
                                break :blk ai_cond.check(rom, c, objs, ctx);
                            }
                            break :blk false;
                        }
                        break :blk ai_cond.checkSetAnd(rom, inds[0..cn], objs, ctx);
                    };
                    if (cond_ok) {
                        if (getScriptPtr(bank, cid)) |script| {
                            if (script.len == 0) {
                                try_id += 1;
                                continue;
                            }
                            const act = interpretAction(script, objs, mon_slot, rng, battle_vars, r);
                            // Pure "no action" — try alternate script slots before default Fight.
                            if (!(act.no_target or act.cmd == 0xE1)) return act;
                        }
                    }
                    try_id += 1;
                }
            }
        }
    }

    // Default Fight (GetDefaultAITarget) when no usable AI script.
    if (getDefaultAITargetParty(objs, rng)) |t| {
        return .{ .cmd = 0xC0, .target_slot = t };
    }
    return .{ .cmd = 0xE1, .no_target = true };
}

fn loadActionBank(r: *const rom_mod.Rom, moon_ai: bool) ?[]const u8 {
    if (moon_ai) {
        return r.slice(ai_action2_file, action2_bank_size) catch
            r.slice(ai_action1_file, action_bank_size) catch null;
    }
    return r.slice(ai_action1_file, action_bank_size) catch null;
}

/// Load AIScript retal bank (init.asm @91af).
pub fn loadRetalBank(r: *const rom_mod.Rom) ?[]const u8 {
    return r.slice(ai_script_file, ai_script_bank_size) catch null;
}

/// Interpret a retaliation AIScript by index (same bytecode as AIAction).
pub fn getRetalAttack(
    r: *const rom_mod.Rom,
    objs: *const obj_mod.ObjTable,
    mon_slot: usize,
    script_index: u8,
    rng: damage.Rng,
    battle_vars: ?*[16]u8,
) MonAction {
    if (script_index == 0xFF) {
        if (getDefaultAITargetParty(objs, rng)) |t| {
            return .{ .cmd = 0xC0, .target_slot = t };
        }
        return .{ .cmd = 0xE1, .no_target = true };
    }
    const bank = loadRetalBank(r) orelse {
        if (getDefaultAITargetParty(objs, rng)) |t| {
            return .{ .cmd = 0xC0, .target_slot = t };
        }
        return .{ .cmd = 0xE1, .no_target = true };
    };
    const script = getScriptPtr(bank, script_index) orelse {
        if (getDefaultAITargetParty(objs, rng)) |t| {
            return .{ .cmd = 0xC0, .target_slot = t };
        }
        return .{ .cmd = 0xE1, .no_target = true };
    };
    return interpretAction(script, objs, mon_slot, rng, battle_vars, r);
}

const std = @import("std");

test "AIAction FD multi_begin FE delayed FC multi_end" {
    var objs: obj_mod.ObjTable = .{};
    objs.objs[0] = .{ .present = true, .hp = 10, .max_hp = 10, .is_monster = false };
    var lcg = damage.Lcg.init(1);
    const rng = lcg.asRng();

    const scr_fd = [_]u8{ 0xFD, 0xC0, 0xFF };
    const a1 = interpretAction(&scr_fd, &objs, 5, rng, null, null);
    try std.testing.expect(a1.multi_begin);
    try std.testing.expectEqual(@as(u8, 0xC0), a1.cmd);

    const scr_fe = [_]u8{ 0xFE, 0xC0, 0xFF };
    const a2 = interpretAction(&scr_fe, &objs, 5, rng, null, null);
    try std.testing.expect(a2.delayed);
    try std.testing.expect(!a2.multi_begin);

    const scr_fc = [_]u8{ 0xC0, 0xFC, 0xFF };
    const a3 = interpretAction(&scr_fc, &objs, 5, rng, null, null);
    try std.testing.expect(a3.multi_end);
    try std.testing.expectEqual(@as(u8, 0xC0), a3.cmd);

    // FA/FB do not break
    const scr_fa = [_]u8{ 0xFA, 0xFB, 0xC2, 0x0E, 0xFF };
    const a4 = interpretAction(&scr_fa, &objs, 5, rng, null, null);
    try std.testing.expectEqual(@as(u8, 0xC2), a4.cmd);
    try std.testing.expectEqual(@as(u8, 0x0E), a4.spell_id);
}
