//! Field event script executor (subset of field/event.asm).
//!
//! Enough for item-gated doors/keys: dialogue, give/take item, F7 item select,
//! event/NPC switches, map change, party add/remove, and a stepped player for
//! long cutscenes (intro event $10). Actor choreography (low opcodes) is timed-skip.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const inventory_mod = @import("inventory.zig");
const party_mod = @import("party.zig");
const state_mod = @import("state.zig");
const npc_mod = @import("../map/npc.zig");
const cmd_magic_mod = @import("../battle/cmd_magic.zig");
const text_mod = @import("../text.zig");

const event_script_ptrs: usize = 0x90000;
const event_script_data: usize = 0x90200;
const npc_script_ptrs: usize = 0x99800;
const npc_script_data: usize = 0x99C00;
const map_dlg_ptrs: usize = 0x88000;
const map_dlg_data: usize = 0x88300;
const event_dlg1_ptrs: usize = 0x80000;
const event_dlg1_data: usize = 0x80400;
const event_dlg2_ptrs: usize = 0x9A500;
const event_dlg2_data: usize = 0x9A700;
const dte_table: usize = 0x99700;
/// TriggerScriptPtrs @ $12F260 → file 0x97260; data @ $12F460 → 0x97460.
const trigger_script_ptrs: usize = 0x97260;
const trigger_script_data: usize = 0x97460;

/// Intro event after New Game (field.asm: `lda #$10` / ExecEvent).
pub const intro_event_id: u8 = 0x10;

pub const EventResult = struct {
    /// Dialogue to show (may be empty).
    dialogue: []const u8 = "",
    /// NPC switches changed — caller should reload NPCs.
    npc_dirty: bool = false,
    /// Optional map warp from FE command.
    warp: ?Warp = null,
    /// Event command $ED shop id (null = no shop).
    shop_id: ?u8 = null,
    /// Party roster changed (e7/e8).
    party_dirty: bool = false,
    /// Game SFX id to play (0 = none).
    sfx: u8 = 0,
    /// Song id to play (0xFF = none).
    song: u8 = 0xFF,
    /// Event ran to completion (or aborted on failed item select).
    ok: bool = true,
};

pub const Warp = struct {
    /// Submap id, or world id when `to_world` is set.
    map_id: u16 = 0,
    x: u8 = 0,
    y: u8 = 0,
    facing: u8 = 2,
    /// FE map byte ≥ $FB → overworld/under/moon.
    to_world: bool = false,
    world_id: u8 = 0,
    /// FE flags bit5 ($20) → $ca: skip WipeOut/WipeIn, use FadeOut if bright (event.asm @f073).
    no_wipe: bool = false,
    /// Stack-pop / return: load target without pushStack (field.asm exit path).
    skip_stack_push: bool = false,
    /// FE flags low 5 bits on world load → board vehicle (EventCmd_fe @f0c4).
    /// 0=none, 1=choco … 7=ship (same ids as `$1704`).
    vehicle_id: u8 = 0,
};

pub const EventCtx = struct {
    rom: *const rom_mod.Rom,
    event_switch: []u8,
    npc_switch: []u8,
    inventory: *inventory_mod.Inventory,
    map_id: u16,
    /// Optional party for e7/e8 (intro / story events) and status/HP/MP cmds.
    party: ?[]state_mod.PartyMember = null,
    /// Party gil ($16a0, 24-bit) for $e5/$e6 give/take GP / inn $dc.
    gil: ?*u32 = null,
    /// Runtime spell lists for EventCmd_e2 (give spell).
    spell_lists: ?*cmd_magic_mod.SpellLists = null,
    /// EventCmd_dd: host should call setFieldLeaderByCharId with this (null = none).
    set_leader_char_id: ?u8 = null,
    /// Map NPCs — event $EB / $00–$BF choreography targets (InitNPCs slots).
    npcs: ?*npc_mod.NpcSet = null,
    /// Dialogue output buffer (caller owns).
    dlg_buf: []u8,
    dlg_len: usize = 0,
    npc_dirty: bool = false,
    party_dirty: bool = false,
    warp: ?Warp = null,
    /// Event command $ED shop id.
    shop_id: ?u8 = null,
    sfx: u8 = 0,
    song: u8 = 0xFF,
    /// EventCmd_da fired this step — host starts FadeIn or FadeOut from current brightness.
    fade_toggle: bool = false,
    /// EventCmd_d0 — toggle screen shake ($e3).
    shake_toggle: bool = false,
    /// EventCmd_d1 — flash screen (invert pal / white flash).
    flash: bool = false,
    /// EventCmd_d2 — mosaic pixelation anim (EventMosaicTbl, 64 frames).
    mosaic: bool = false,
    /// EventCmd_d3 — earth↔moon travel mini-scene.
    earth_moon: bool = false,
    /// EventCmd_d4 fat chocobo / $d9 namingway (0=none, 1=fat, 2=namingway).
    menu_fx: u8 = 0,
    /// EventCmd_d5 — secret door open anim.
    secret_door: bool = false,
    /// EventCmd_d6 — one-shot quake pulse.
    quake_pulse: bool = false,
    /// EventCmd_d7 — toggle run/walk speed flag ($ac).
    speed_toggle: bool = false,
    /// EventCmd_d8 — fade out music slow ($85).
    song_fade_out: bool = false,
    /// EventCmd_fd special id (null = none). Host runs special.asm table.
    special_id: ?u8 = null,
    /// Player control for $C0–$CF (field/event.asm _00e4a9). Host fills from GameState.
    player_facing: ?*u8 = null,
    player_hidden: ?*bool = null,
    /// $d8 spin flag (EventCmd $CF toggle). DrawPlayerSub forces $1705=$08 while set.
    player_spin: ?*bool = null,
    /// `$cf` (EventCmd $CE): freeze facing while walking (joypad + NPC event walks).
    party_follow: ?*bool = null,
    /// Set to 1–4 to start a 1-tile scripted player walk (up/right/down/left).
    player_walk_dir: ?*u8 = null,
    /// When F7 runs: if true, auto-select the required item when present (no menu UI yet).
    auto_use_key: bool = true,
    /// NPC dialogue table ($0a49): map-dlg page ids after the last $FF in the NPC script
    /// (event id of that last entry is skipped). Used by event command $EE.
    npc_dlg_table: []const u8 = &.{},

    fn setDlg(self: *EventCtx, text: []const u8) void {
        const n = @min(text.len, self.dlg_buf.len);
        // decodeDlg often writes into dlg_buf already — never memcpy overlapping regions.
        if (n > 0 and !slicesOverlap(self.dlg_buf, text)) {
            @memcpy(self.dlg_buf[0..n], text[0..n]);
        }
        self.dlg_len = n;
    }

    fn appendDlg(self: *EventCtx, text: []const u8) void {
        if (text.len == 0) return;
        if (self.dlg_len > 0 and self.dlg_len < self.dlg_buf.len) {
            self.dlg_buf[self.dlg_len] = '\n';
            self.dlg_len += 1;
        }
        const room = self.dlg_buf.len - self.dlg_len;
        const n = @min(text.len, room);
        if (n > 0 and !slicesOverlap(self.dlg_buf[self.dlg_len..], text)) {
            @memcpy(self.dlg_buf[self.dlg_len..][0..n], text[0..n]);
            self.dlg_len += n;
        } else if (n > 0 and slicesOverlap(self.dlg_buf, text)) {
            // Already in buffer (decode wrote here); just extend len if needed.
            self.dlg_len = @max(self.dlg_len, n);
        }
    }
};

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a0 = @intFromPtr(a.ptr);
    const a1 = a0 + a.len;
    const b0 = @intFromPtr(b.ptr);
    const b1 = b0 + b.len;
    return a0 < b1 and b0 < a1;
}

fn eventCmdLen(cmd: u8) u8 {
    return switch (cmd) {
        0xFF => 1,
        0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA => 1,
        0xE2, 0xEB => 3,
        0xFE => 5,
        // $ED handled specially (shop) but still 2 bytes
        0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD => 2,
        else => 1,
    };
}

const gil_cap: u32 = 9_999_999;

/// Status1 dead flag ($1003 bit7) — DE/DF skip dead chars (bmi in event.asm).
fn partyIsDead(m: state_mod.PartyMember) bool {
    return (m.status1 & 0x80) != 0;
}

/// EventCmd_de: restore HP — param $FE = full; else +param×10 (capped at max).
fn eventRestoreHp(party: []state_mod.PartyMember, param: u8) void {
    const full = param == 0xFE;
    const add: u16 = if (full) 0 else @as(u16, param) *% 10;
    for (party) |*m| {
        if (!m.present or partyIsDead(m.*)) continue;
        if (full) {
            m.hp = m.max_hp;
        } else {
            m.hp = @min(m.max_hp, m.hp +% add);
        }
    }
}

/// EventCmd_df: restore MP — same encoding as DE.
fn eventRestoreMp(party: []state_mod.PartyMember, param: u8) void {
    const full = param == 0xFE;
    const add: u16 = if (full) 0 else @as(u16, param) *% 10;
    for (party) |*m| {
        if (!m.present or partyIsDead(m.*)) continue;
        if (full) {
            m.mp = m.max_mp;
        } else {
            m.mp = @min(m.max_mp, m.mp +% add);
        }
    }
}

/// EventCmd_db: eor status1 for all present chars.
fn eventToggleStatus(party: []state_mod.PartyMember, mask: u8) void {
    for (party) |*m| {
        if (!m.present) continue;
        m.status1 ^= mask;
    }
}

/// EventCmd_e3: clear status — AND with param (bits set in param are kept).
fn eventClearStatus(party: []state_mod.PartyMember, keep_mask: u8) void {
    for (party) |*m| {
        if (!m.present) continue;
        m.status1 &= keep_mask;
    }
}

/// EventCmd_e4: set status — ORA param.
fn eventSetStatus(party: []state_mod.PartyMember, mask: u8) void {
    for (party) |*m| {
        if (!m.present) continue;
        m.status1 |= mask;
    }
}

/// EventCmd_e5: give GP = param × 100 (cap 9,999,999).
fn eventGiveGil(gil: *u32, param: u8) void {
    const add: u32 = @as(u32, param) *% 100;
    gil.* = @min(gil.* +% add, gil_cap);
}

/// EventCmd_e6: take GP = param × 100 (floor 0).
fn eventTakeGil(gil: *u32, param: u8) void {
    const sub: u32 = @as(u32, param) *% 100;
    gil.* = if (gil.* > sub) gil.* - sub else 0;
}

/// InnGilTbl (event.asm @ed0b).
const inn_gil_tbl = [_]u16{ 50, 100, 200, 400, 500, 600, 700, 300, 1200 };

/// EventCmd_dc inn pay. Returns false if short on gil.
pub fn eventInnPayPub(gil: *u32, price_idx: u8) bool {
    const idx = @min(@as(usize, price_idx), inn_gil_tbl.len - 1);
    const cost: u32 = inn_gil_tbl[idx];
    if (gil.* < cost) return false;
    gil.* -= cost;
    return true;
}

fn eventInnPay(gil: *u32, price_idx: u8) bool {
    return eventInnPayPub(gil, price_idx);
}

fn switchBit(switches: []const u8, id: u8) bool {
    const byte_i = id >> 3;
    const bit: u3 = @truncate(id & 7);
    if (byte_i >= switches.len) return false;
    return (switches[byte_i] & (@as(u8, 1) << bit)) != 0;
}

fn setSwitchBit(switches: []u8, id: u8, on: bool) void {
    const byte_i = id >> 3;
    const bit: u3 = @truncate(id & 7);
    if (byte_i >= switches.len) return;
    const mask: u8 = @as(u8, 1) << bit;
    if (on) {
        switches[byte_i] |= mask;
    } else {
        switches[byte_i] &= ~mask;
    }
}

/// GetNPCSwitchOffset (event.asm @f414): high map bank adds +$20 to byte index.
fn setNpcSwitchBit(switches: []u8, id: u8, on: bool, map_high: bool) void {
    var byte_i: usize = id >> 3;
    if (map_high) byte_i += 0x20;
    if (byte_i >= switches.len) return;
    const bit: u3 = @truncate(id & 7);
    const mask: u8 = @as(u8, 1) << bit;
    if (on) {
        switches[byte_i] |= mask;
    } else {
        switches[byte_i] &= ~mask;
    }
}

/// Apply F4/F5 to switch bits + live NPC visibility (crystal hide, doors, etc.).
fn applyNpcSwitchCmd(ctx: *EventCtx, id: u8, on: bool) void {
    const map_high = ctx.map_id >= 256;
    setNpcSwitchBit(ctx.npc_switch, id, on, map_high);
    ctx.npc_dirty = true;
    // Immediate hide/show so crystal disappears mid-event without waiting for host refresh.
    if (ctx.npcs) |ns| {
        for (ns.npcs) |*n| {
            if (n.prop_gfx == id) n.visible = on;
        }
    }
}

/// Resolve which event id an NPC script runs (ExecNPCScript condition walk).
pub fn resolveNpcEventId(r: *const rom_mod.Rom, script_id: u8, event_switches: []const u8) ?u8 {
    const idx: usize = @as(usize, script_id) * 2;
    const start_rel = r.readU16Le(npc_script_ptrs + idx) catch return null;
    const end_rel = r.readU16Le(npc_script_ptrs + idx + 2) catch return null;
    const start = npc_script_data + start_rel;
    const end = npc_script_data + end_rel;
    if (end <= start) return null;

    var bc = start;
    while (bc < end) {
        const b = r.readU8(bc) catch break;
        if (b == 0xFF) {
            if (bc + 1 < end) {
                const event_id = r.readU8(bc + 1) catch break;
                if (event_id != 0) return event_id;
            }
            return null;
        }
        if (b == 0xFE) {
            // Pass if event switch ON
            if (bc + 1 >= end) break;
            const sw = r.readU8(bc + 1) catch break;
            if (!switchBit(event_switches, sw)) {
                bc = skipNpcEntry(r, bc, end) catch break;
                continue;
            }
            bc += 2;
            continue;
        }
        // Pass if event switch OFF
        if (switchBit(event_switches, b)) {
            bc = skipNpcEntry(r, bc, end) catch break;
            continue;
        }
        bc += 1;
    }
    return null;
}

fn skipNpcEntry(r: *const rom_mod.Rom, from: usize, end: usize) !usize {
    var p = from + 1;
    while (p < end) : (p += 1) {
        if ((try r.readU8(p)) == 0xFF) {
            p += 1;
            if (p < end) p += 1;
            return p;
        }
    }
    return end;
}

/// Execute event script `event_id`. Mutates switches / inventory via ctx.
pub fn execEvent(ctx: *EventCtx, event_id: u8) EventResult {
    const start_rel = ctx.rom.readU16Le(event_script_ptrs + @as(usize, event_id) * 2) catch {
        return .{ .ok = false };
    };
    const end_rel = ctx.rom.readU16Le(event_script_ptrs + @as(usize, event_id) * 2 + 2) catch start_rel +% 64;
    var pos = event_script_data + start_rel;
    var end = event_script_data + end_rel;
    if (end <= pos) end = pos + 256;

    var aborted = false;
    // Must fit long multi-page map/event dialogue (DecodeDlgText loops until $00).
    var scratch: [2048]u8 = undefined;

    while (pos < end and !aborted) {
        const cmd = ctx.rom.readU8(pos) catch break;
        if (cmd == 0xFF) break;

        switch (cmd) {
            // Give item
            0xE0 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                _ = ctx.inventory.give(id);
                pos += 2;
            },
            // Take item
            0xE1 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                _ = ctx.inventory.take(id);
                pos += 2;
            },
            // EventCmd_db: toggle status1
            0xDB => {
                const mask = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| eventToggleStatus(p, mask);
                pos += 2;
            },
            // EventCmd_dc: inn (auto-pay; abort script if short)
            0xDC => {
                const idx = ctx.rom.readU8(pos + 1) catch break;
                pos += 2;
                if (ctx.gil) |g| {
                    if (!eventInnPay(g, idx)) {
                        if (loadEventDlg(ctx.rom, .event1, 0x19, &scratch)) |s| ctx.setDlg(s);
                        aborted = true;
                        pos = end;
                        break;
                    }
                }
            },
            // EventCmd_dd: set player graphic / top char by id
            0xDD => {
                const cid = ctx.rom.readU8(pos + 1) catch break;
                ctx.set_leader_char_id = cid;
                ctx.party_dirty = true;
                pos += 2;
            },
            // EventCmd_de / df: restore HP / MP
            0xDE => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| eventRestoreHp(p, param);
                pos += 2;
            },
            0xDF => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| eventRestoreMp(p, param);
                pos += 2;
            },
            // EventCmd_e2: give spell (list_id, spell_id)
            0xE2 => {
                const list_id = ctx.rom.readU8(pos + 1) catch break;
                const spell_id = ctx.rom.readU8(pos + 2) catch break;
                if (ctx.spell_lists) |sl| _ = cmd_magic_mod.giveSpell(sl, list_id, spell_id);
                pos += 3;
            },
            // EventCmd_e3 / e4: clear / set status1
            0xE3 => {
                const mask = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| eventClearStatus(p, mask);
                pos += 2;
            },
            0xE4 => {
                const mask = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| eventSetStatus(p, mask);
                pos += 2;
            },
            // EventCmd_e5 / e6: give / take GP (×100)
            0xE5 => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.gil) |g| eventGiveGil(g, param);
                pos += 2;
            },
            0xE6 => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.gil) |g| eventTakeGil(g, param);
                pos += 2;
            },
            // NPC dialogue EE: index into $0a49 table → map dialogue page (GetDlgPtr0)
            0xEE => {
                const idx = ctx.rom.readU8(pos + 1) catch break;
                const page: u8 = if (idx < ctx.npc_dlg_table.len)
                    ctx.npc_dlg_table[idx]
                else
                    0;
                if (loadMapDlg(ctx.rom, ctx.map_id, page, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                pos += 2;
            },
            // Map dialogue EF (literal page id)
            0xEF => {
                const page = ctx.rom.readU8(pos + 1) catch break;
                if (loadMapDlg(ctx.rom, ctx.map_id, page, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                pos += 2;
            },
            // Event dlg bank1 low
            0xF0 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                if (loadEventDlg(ctx.rom, .event1, id, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                pos += 2;
            },
            // Event dlg bank1 high (+256)
            0xF1 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                if (loadEventDlg(ctx.rom, .event1, @as(u16, id) + 256, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                pos += 2;
            },
            // Set event switch
            0xF2 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                setSwitchBit(ctx.event_switch, id, true);
                pos += 2;
            },
            // Clear event switch
            0xF3 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                setSwitchBit(ctx.event_switch, id, false);
                pos += 2;
            },
            // Set NPC switch
            0xF4 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                applyNpcSwitchCmd(ctx, id, true);
                pos += 2;
            },
            // Clear NPC switch (hide crystal / unlock door NPCs)
            0xF5 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                applyNpcSwitchCmd(ctx, id, false);
                pos += 2;
            },
            // Event dlg bank2
            0xF6 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                if (loadEventDlg(ctx.rom, .event2, id, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                pos += 2;
            },
            // Select item (key-item gates): auto-use if present
            0xF7 => {
                const want = ctx.rom.readU8(pos + 1) catch break;
                const ok = if (ctx.auto_use_key) ctx.inventory.has(want) else false;
                if (!ok) {
                    // ROM shows event dlg $14 ("That's not it" / wrong item) then aborts to terminator.
                    if (loadEventDlg(ctx.rom, .event1, 0x14, &scratch)) |s| {
                        ctx.setDlg(s);
                    } else {
                        ctx.setDlg("Locked.");
                    }
                    aborted = true;
                    // Skip to end
                    pos = end;
                    break;
                }
                // EventCmd_f7 @edc6: key items $ED–$FD and $EC not consumed; else dec qty.
                const item = want;
                if (item != 0xEC and !(item >= 0xED and item <= 0xFD)) {
                    _ = ctx.inventory.take(item);
                }
                pos += 2;
            },
            // Yes/no — bulk preview path only shows text; live EventPlayer handles confirm/cancel.
            // Do not auto-advance as “always yes” (fidelity-gaps E3).
            0xF8 => {
                const id = ctx.rom.readU8(pos + 1) catch break;
                if (loadEventDlg(ctx.rom, .event1, @as(u16, id) + 256, &scratch)) |s| {
                    ctx.setDlg(s);
                }
                // Abort bulk preview at choice (cannot collect Yes/No without UI).
                aborted = true;
                pos = end;
            },
            // Event command $ED: open shop (field/event.asm @e5e6)
            0xED => {
                const sid = ctx.rom.readU8(pos + 1) catch break;
                ctx.shop_id = sid;
                pos += 2;
            },
            // $E7: add character to party
            0xE7 => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| {
                    if (party_mod.addFromEvent(ctx.rom, p, param)) ctx.party_dirty = true;
                }
                pos += 2;
            },
            // $E8: remove character from party
            0xE8 => {
                const param = ctx.rom.readU8(pos + 1) catch break;
                if (ctx.party) |p| {
                    if (party_mod.removeByEventParam(p, param)) ctx.party_dirty = true;
                }
                pos += 2;
            },
            // EventCmd_ea: play song (fade in) — same host path as FA for bulk preview.
            0xEA => {
                ctx.song = ctx.rom.readU8(pos + 1) catch 0xFF;
                pos += 2;
            },
            // EventCmd_f9: COLDATA flash — no multi-frame in bulk; skip length only.
            0xF9 => {
                pos += 2;
            },
            // $FA = PlaySongEvent, $FB = PlaySfx (field/event.asm @e7e1 / @e7f7)
            0xFA => {
                ctx.song = ctx.rom.readU8(pos + 1) catch 0xFF;
                pos += 2;
            },
            0xFB => {
                ctx.sfx = ctx.rom.readU8(pos + 1) catch 0;
                pos += 2;
            },
            // Change map FE (EventCmd_fe @f039)
            0xFE => {
                if (pos + 4 < end) {
                    const map_b = ctx.rom.readU8(pos + 1) catch break;
                    const xb = ctx.rom.readU8(pos + 2) catch break;
                    const yb = ctx.rom.readU8(pos + 3) catch break;
                    const fl = ctx.rom.readU8(pos + 4) catch 0;
                    ctx.warp = parseFeWarp(map_b, xb, yb, fl);
                }
                pos += 5;
            },
            // Pause, status, battle, choreography, etc. — skip by length
            else => {
                const len = eventCmdLen(cmd);
                if (len == 0) break;
                pos += len;
            },
        }
    }

    return .{
        .dialogue = ctx.dlg_buf[0..ctx.dlg_len],
        .npc_dirty = ctx.npc_dirty,
        .party_dirty = ctx.party_dirty,
        .shop_id = ctx.shop_id,
        .warp = ctx.warp,
        .sfx = ctx.sfx,
        .song = ctx.song,
        .ok = !aborted,
    };
}

/// EventCmd_fe bytes → Warp (submap or world).
fn parseFeWarp(map_b: u8, xb: u8, yb: u8, fl: u8) Warp {
    // Bit5 of flags → $ca (no iris wipe; EventCmd_fe @f073 / @f0a9).
    const no_wipe = (fl & 0x20) != 0;
    if (map_b >= 0xFB) {
        // World: map_b − $FB → 0 OW / 1 under / 2 moon (field.asm @f087)
        // Low 5 bits of flags = vehicle to board after load (@f0c4).
        // Ship path also packs facing in flags bits 3–4 (`and #$18 / lsr3`).
        const veh = fl & 0x1F;
        const face: u8 = if (veh == 7) (fl >> 3) & 3 else 2;
        return .{
            .to_world = true,
            .world_id = map_b -% 0xFB,
            .map_id = 0,
            .x = xb,
            .y = yb,
            .facing = face,
            .no_wipe = no_wipe,
            .vehicle_id = veh,
        };
    }
    var map_id: u16 = map_b;
    // Bit7 of flags byte → high map bank ($1701)
    if ((fl & 0x80) != 0) map_id |= 0x100;
    return .{
        .to_world = false,
        .map_id = map_id,
        .x = xb & 0x3F,
        .y = yb,
        .facing = xb >> 6,
        .no_wipe = no_wipe,
    };
}

/// Load $0a49 dialogue table from an NPC script (ExecNPCScript @f2ed).
/// Bytes after the last $FF, skipping that entry's event id.
fn loadNpcDlgTable(r: *const rom_mod.Rom, script_id: u8, out: []u8) usize {
    const idx: usize = @as(usize, script_id) * 2;
    const start_rel = r.readU16Le(npc_script_ptrs + idx) catch return 0;
    const end_rel = r.readU16Le(npc_script_ptrs + idx + 2) catch return 0;
    const start = npc_script_data + start_rel;
    const end = npc_script_data + end_rel;
    if (end <= start or start >= r.data.len) return 0;

    var last_ff: ?usize = null;
    var p = start;
    const limit = @min(end, r.data.len);
    while (p < limit) : (p += 1) {
        if ((r.readU8(p) catch break) == 0xFF) last_ff = p;
    }
    const ff = last_ff orelse return 0;
    // Skip $FF and its event id (same as inx after finding FF, then inx before copy).
    var q = ff + 2;
    var n: usize = 0;
    while (q < limit and n < out.len) : (q += 1) {
        out[n] = r.readU8(q) catch break;
        n += 1;
    }
    return n;
}

/// Talk to NPC: resolve script → load dlg table → exec event (sync helper / tests).
pub fn execNpcTalk(ctx: *EventCtx, script_id: u8) EventResult {
    var table_buf: [32]u8 = undefined;
    const table_n = loadNpcDlgTable(ctx.rom, script_id, &table_buf);
    ctx.npc_dlg_table = table_buf[0..table_n];

    const eid = resolveNpcEventId(ctx.rom, script_id, ctx.event_switch) orelse {
        ctx.setDlg("....");
        return .{ .dialogue = ctx.dlg_buf[0..ctx.dlg_len], .ok = false };
    };
    return execEvent(ctx, eid);
}

/// Map trigger dest $FF: ExecTriggerScript (same condition language as NPC scripts).
pub fn execTriggerScript(ctx: *EventCtx, script_id: u8) EventResult {
    const eid = resolveTriggerEventId(ctx.rom, script_id, ctx.event_switch) orelse {
        return .{ .ok = true };
    };
    if (eid == 0) return .{ .ok = true };
    return execEvent(ctx, eid);
}

/// Fill NPC $0a49 dialogue table for stepped EventPlayer (EE commands).
pub fn fillNpcDlgTable(r: *const rom_mod.Rom, script_id: u8, out: []u8) usize {
    return loadNpcDlgTable(r, script_id, out);
}

pub fn resolveTriggerEventId(r: *const rom_mod.Rom, script_id: u8, event_switches: []const u8) ?u8 {
    const idx: usize = @as(usize, script_id) * 2;
    const start_rel = r.readU16Le(trigger_script_ptrs + idx) catch return null;
    const end_rel = r.readU16Le(trigger_script_ptrs + idx + 2) catch return null;
    // Pointers are relative to TriggerScript data base (make_ptr_tbl_rel).
    const start = trigger_script_data + start_rel;
    const end = trigger_script_data + end_rel;
    if (end <= start or start >= r.data.len) return null;

    var bc = start;
    const limit = @min(end, r.data.len);
    while (bc < limit) {
        const b = r.readU8(bc) catch break;
        if (b == 0xFF) {
            if (bc + 1 < limit) {
                const event_id = r.readU8(bc + 1) catch break;
                return event_id;
            }
            return null;
        }
        if (b == 0xFE) {
            if (bc + 1 >= limit) break;
            const sw = r.readU8(bc + 1) catch break;
            if (!switchBit(event_switches, sw)) {
                bc = skipNpcEntry(r, bc, limit) catch break;
                continue;
            }
            bc += 2;
            continue;
        }
        if (switchBit(event_switches, b)) {
            bc = skipNpcEntry(r, bc, limit) catch break;
            continue;
        }
        bc += 1;
    }
    return null;
}

// --- Dialogue loaders (shared encoding with npc.zig) ---

const DlgBank = enum { event1, event2 };

fn loadMapDlg(r: *const rom_mod.Rom, map_id: u16, page: u8, buf: []u8) ?[]const u8 {
    if (map_id >= 0x180) return null;
    const ptr = r.readU16Le(map_dlg_ptrs + @as(usize, map_id) * 2) catch return null;
    var pos = map_dlg_data + ptr;
    var remaining: u8 = page;
    while (remaining > 0) {
        const b = r.readU8(pos) catch return null;
        pos += 1;
        if (b == 0x00) {
            if (pos >= map_dlg_data + 2) {
                const prev = r.readU8(pos - 2) catch 0;
                if (prev == 0x03 or prev == 0x04) continue;
            }
            remaining -= 1;
        }
    }
    return decodeDlg(r, pos, buf);
}

fn loadEventDlg(r: *const rom_mod.Rom, bank: DlgBank, id: u16, buf: []u8) ?[]const u8 {
    const ptrs: usize = switch (bank) {
        .event1 => event_dlg1_ptrs,
        .event2 => event_dlg2_ptrs,
    };
    const data: usize = switch (bank) {
        .event1 => event_dlg1_data,
        .event2 => event_dlg2_data,
    };
    const max: u16 = switch (bank) {
        .event1 => 0x200,
        .event2 => 0x100,
    };
    if (id >= max) return null;
    const ptr = r.readU16Le(ptrs + @as(usize, id) * 2) catch return null;
    return decodeDlg(r, data + ptr, buf);
}

/// Public: event bank-1 dialogue (inn msgs $19/$1A/$1B, etc.).
pub fn loadEventDlg1(r: *const rom_mod.Rom, id: u16, buf: []u8) ?[]const u8 {
    return loadEventDlg(r, .event1, id, buf);
}

fn decodeDlg(r: *const rom_mod.Rom, start_pos: usize, buf: []u8) ?[]const u8 {
    var pos = start_pos;
    const dte = r.slice(dte_table, 0x100) catch return null;
    var out_i: usize = 0;
    while (out_i + 4 < buf.len) {
        const b = r.readU8(pos) catch break;
        pos += 1;
        if (b == 0x00 or b == 0x06) break;
        if (b == 0x01 or b == 0x09) {
            if (out_i > 0 and buf[out_i - 1] != '\n') {
                buf[out_i] = '\n';
                out_i += 1;
            }
            continue;
        }
        if (b == 0x02) {
            const n = r.readU8(pos) catch break;
            pos += 1;
            var i: u8 = 0;
            while (i < n and out_i < buf.len) : (i += 1) {
                buf[out_i] = ' ';
                out_i += 1;
            }
            continue;
        }
        if (b == 0x03 or b == 0x05) {
            pos += 1;
            continue;
        }
        // TextCmd_04: character name — next byte is CharacterName slot ($1500 index).
        // window.asm @b308: slot * 6 → copy up to 6 letters (stop at $FF).
        if (b == 0x04) {
            const slot = r.readU8(pos) catch break;
            pos += 1;
            var nbuf: [8]u8 = undefined;
            const name = text_mod.decodeCharNameSlot(r.data, slot, &nbuf);
            const n = @min(name.len, buf.len - out_i);
            @memcpy(buf[out_i..][0..n], name[0..n]);
            out_i += n;
            continue;
        }
        if (b == 0xFF) {
            buf[out_i] = ' ';
            out_i += 1;
            continue;
        }
        if ((b >= 0x8A and b < 0xC0) or (b >= 0xCA and b <= 0xFD)) {
            const di: usize = (@as(usize, b) -% 0x80) * 2;
            if (di + 1 < dte.len) {
                if (decodeChar(dte[di])) |ch| {
                    buf[out_i] = ch;
                    out_i += 1;
                }
                if (out_i < buf.len) {
                    if (decodeChar(dte[di + 1])) |ch| {
                        buf[out_i] = ch;
                        out_i += 1;
                    }
                }
            }
            continue;
        }
        if (decodeChar(b)) |ch| {
            buf[out_i] = ch;
            out_i += 1;
        }
    }
    while (out_i > 0 and (buf[out_i - 1] == ' ' or buf[out_i - 1] == '\n')) out_i -= 1;
    return buf[0..out_i];
}

fn decodeChar(b: u8) ?u8 {
    return switch (b) {
        0x42...0x5B => 'A' + (b - 0x42),
        0x5C...0x75 => 'a' + (b - 0x5C),
        0x80...0x89 => '0' + (b - 0x80),
        0xC0 => '\'',
        0xC1 => '.',
        0xC2 => '-',
        0xC3 => '.',
        0xC4 => '!',
        0xC5 => '?',
        0xC6 => '%',
        0xC7 => '/',
        0xC8 => ':',
        0xC9 => ',',
        0xFF => ' ',
        else => null,
    };
}

test "switch bit set clear" {
    var sw: [4]u8 = .{0} ** 4;
    try std.testing.expect(!switchBit(sw[0..], 5));
    setSwitchBit(sw[0..], 5, true);
    try std.testing.expect(switchBit(sw[0..], 5));
    setSwitchBit(sw[0..], 5, false);
    try std.testing.expect(!switchBit(sw[0..], 5));
}

// --- Stepped cutscene player (intro event $10) --------------------------------

/// Yield reason from one EventPlayer step.
pub const PlayerYield = enum {
    /// Still running; call tick again next field.
    running,
    /// Dialogue in ctx.dlg_buf — wait for player confirm then resume().
    dialogue,
    /// Yes/No prompt (inn $DC / F8) — confirm=yes, cancel=no.
    yes_no,
    /// Map change in last_warp — apply then resume().
    warp,
    /// EventCmd_ec forced battle — host runs battle then resume().
    battle,
    /// Script finished (or aborted).
    done,
};

/// Pending yes/no handler while blocked == .yes_no.
pub const YesNoKind = enum { none, inn, f8 };

/// Frame-stepped event interpreter for long scripts (dialogue + waits + warps + battles).
/// Actor low-opcodes are advanced with a short delay so cutscenes are watchable.
pub const EventPlayer = struct {
    active: bool = false,
    event_id: u8 = 0,
    pos: usize = 0,
    end: usize = 0,
    wait_frames: u16 = 0,
    /// Pause for dialogue / yes-no / warp application / battle.
    blocked: enum { none, dialogue, yes_no, warp, battle } = .none,
    last_warp: ?Warp = null,
    /// Battle formation id from EventCmd_ec (valid while blocked == .battle).
    last_battle_id: u16 = 0,
    last_sfx: u8 = 0,
    last_song: u8 = 0xFF,
    party_dirty: bool = false,
    npc_dirty: bool = false,
    /// Yes/No: kind + inn price index (InnGilTbl).
    yes_no_kind: YesNoKind = .none,
    inn_price_idx: u8 = 0,
    /// Max low-opcode steps per field (choreography skip rate).
    choreo_budget: u8 = 8,
    /// $EB multi-repeat: buffer + remaining passes after the current one.
    /// ROM: for each repeat, run buffer then Wait until $0908 clears (event.asm @e297).
    eb_buf: [128]u8 = undefined,
    eb_len: u8 = 0,
    eb_left: u8 = 0,

    pub fn start(self: *EventPlayer, rom: *const rom_mod.Rom, event_id: u8) bool {
        const start_rel = rom.readU16Le(event_script_ptrs + @as(usize, event_id) * 2) catch return false;
        const end_rel = rom.readU16Le(event_script_ptrs + @as(usize, event_id) * 2 + 2) catch start_rel +% 64;
        self.* = .{
            .active = true,
            .event_id = event_id,
            .pos = event_script_data + start_rel,
            .end = event_script_data + end_rel,
        };
        if (self.end <= self.pos) self.end = self.pos + 256;
        return true;
    }

    pub fn stop(self: *EventPlayer) void {
        self.active = false;
        self.blocked = .none;
    }

    /// After dialogue dismissed, warp applied, or battle finished, continue the script.
    pub fn clearBlock(self: *EventPlayer) void {
        self.blocked = .none;
        self.last_warp = null;
        self.yes_no_kind = .none;
    }

    /// Abort remaining script (FindEventTerminator) — used on yes/no "no" / short gil.
    pub fn abortScript(self: *EventPlayer) void {
        self.pos = self.end;
        self.blocked = .none;
        self.yes_no_kind = .none;
        self.active = false;
    }

    pub fn innCost(self: *const EventPlayer) u32 {
        const idx = @min(@as(usize, self.inn_price_idx), inn_gil_tbl.len - 1);
        return inn_gil_tbl[idx];
    }

    /// One pass of the current $EB buffer (actor ops + embedded high cmds).
    fn runEbPass(self: *EventPlayer, ctx: *EventCtx, scratch: []u8) PlayerYield {
        const n: usize = self.eb_len;
        var bi2: usize = 0;
        while (bi2 < n) {
            const op = self.eb_buf[bi2];
            if (op == 0xFF) break;
            if (op < 0xC0) {
                if (ctx.npcs) |ns| ns.applyEventOpcode(op);
                bi2 += 1;
            } else if (op < 0xD0) {
                applyPlayerOpcode(ctx, op);
                bi2 += 1;
            } else {
                const clen = eventCmdLen(op);
                if (op == 0xF2 and bi2 + 1 < n) {
                    setSwitchBit(ctx.event_switch, self.eb_buf[bi2 + 1], true);
                } else if (op == 0xF3 and bi2 + 1 < n) {
                    setSwitchBit(ctx.event_switch, self.eb_buf[bi2 + 1], false);
                } else if (op == 0xF4 and bi2 + 1 < n) {
                    applyNpcSwitchCmd(ctx, self.eb_buf[bi2 + 1], true);
                    self.npc_dirty = true;
                } else if (op == 0xF5 and bi2 + 1 < n) {
                    applyNpcSwitchCmd(ctx, self.eb_buf[bi2 + 1], false);
                    self.npc_dirty = true;
                } else if (op == 0xF0 and bi2 + 1 < n) {
                    if (loadEventDlg(ctx.rom, .event1, self.eb_buf[bi2 + 1], scratch)) |s| {
                        ctx.setDlg(s);
                        if (s.len > 0) {
                            self.blocked = .dialogue;
                            self.wait_frames = 0;
                            return .dialogue;
                        }
                    }
                } else if (op == 0xF6 and bi2 + 1 < n) {
                    if (loadEventDlg(ctx.rom, .event2, self.eb_buf[bi2 + 1], scratch)) |s| {
                        ctx.setDlg(s);
                        if (s.len > 0) {
                            self.blocked = .dialogue;
                            return .dialogue;
                        }
                    }
                }
                bi2 += if (clen == 0) 1 else clen;
            }
        }
        return .running;
    }

    /// One NTSC field while active and not blocked. Mutates ctx (switches, party, dlg).
    pub fn tick(self: *EventPlayer, ctx: *EventCtx) PlayerYield {
        if (!self.active) return .done;
        if (self.blocked == .dialogue) return .dialogue;
        if (self.blocked == .yes_no) return .yes_no;
        if (self.blocked == .warp) return .warp;
        if (self.blocked == .battle) return .battle;

        if (self.wait_frames > 0) {
            self.wait_frames -= 1;
            // Keep animating in-progress walks during scripted waits.
            if (ctx.npcs) |ns| _ = ns.tickMoves();
            return .running;
        }

        // Event loop waits until all $0908 counters clear before more opcodes
        // (field/event.asm @e31c after MoveNPCs).
        if (ctx.npcs) |ns| {
            if (ns.anyMoving()) {
                _ = ns.tickMoves();
                return .running;
            }
        }

        // $EB multi-repeat: next pass of the same buffer (after previous walk settled).
        if (self.eb_left > 0) {
            var scratch_eb: [2048]u8 = undefined;
            const y = self.runEbPass(ctx, &scratch_eb);
            self.eb_left -= 1;
            if (y != .running) return y;
            if (ctx.npcs) |ns| _ = ns.tickMoves();
            return .running;
        }

        self.last_sfx = 0;
        self.last_song = 0xFF;
        var budget = self.choreo_budget;
        // Scratch for dialogue decode so setDlg never aliases dlg_buf.
        var scratch: [2048]u8 = undefined;

        while (self.pos < self.end and budget > 0) {
            const cmd = ctx.rom.readU8(self.pos) catch {
                self.active = false;
                return .done;
            };
            if (cmd == 0xFF) {
                self.active = false;
                return .done;
            }

            // --- High-level commands ---
            if (cmd >= 0xD0) {
                switch (cmd) {
                    // $EB: batch of opcodes run `repeat` times (field/event.asm @e236)
                    //   EB <repeat> <len> <len bytes…>  — may mix actor $00–$BF and high cmds
                    // Each repeat: run buffer, then wait for NPC walks to finish (@e297).
                    0xEB => {
                        const repeat = ctx.rom.readU8(self.pos + 1) catch 1;
                        const len = ctx.rom.readU8(self.pos + 2) catch 0;
                        self.pos += 3;
                        const n = @min(@as(usize, len), self.eb_buf.len);
                        var bi: usize = 0;
                        while (bi < n) : (bi += 1) {
                            self.eb_buf[bi] = ctx.rom.readU8(self.pos + bi) catch 0;
                        }
                        self.pos += len;
                        self.eb_len = @intCast(n);
                        const times: u8 = if (repeat < 1) 1 else @min(repeat, 32);
                        // First pass now; remaining passes after walks settle.
                        self.eb_left = times -% 1;
                        const y = self.runEbPass(ctx, &scratch);
                        if (y != .running) return y;
                        if (ctx.npcs) |ns| _ = ns.tickMoves();
                        return .running;
                    },
                    0xE0 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        _ = ctx.inventory.give(id);
                        self.pos += 2;
                    },
                    0xE1 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        _ = ctx.inventory.take(id);
                        self.pos += 2;
                    },
                    // EventCmd_db: toggle status1 ($1003 eor param); $cc → sprite reload
                    0xDB => {
                        const mask = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| {
                            eventToggleStatus(p, mask);
                            self.party_dirty = true;
                            ctx.party_dirty = true;
                        }
                        self.pos += 2;
                    },
                    // EventCmd_dc: inn — welcome dlg $1A + Yes/No; pay on yes (event.asm @ec6e).
                    0xDC => {
                        const idx = ctx.rom.readU8(self.pos + 1) catch break;
                        self.pos += 2;
                        self.inn_price_idx = idx;
                        self.yes_no_kind = .inn;
                        if (loadEventDlg(ctx.rom, .event1, 0x1A, &scratch)) |s| {
                            ctx.setDlg(s);
                        } else {
                            ctx.setDlg("Stay the night?");
                        }
                        self.blocked = .yes_no;
                        return .yes_no;
                    },
                    // EventCmd_dd: set showing character by id → $1703
                    0xDD => {
                        const cid = ctx.rom.readU8(self.pos + 1) catch break;
                        ctx.set_leader_char_id = cid;
                        self.party_dirty = true;
                        ctx.party_dirty = true;
                        self.pos += 2;
                    },
                    // EventCmd_de: restore HP (param $FE = full, else +param×10)
                    0xDE => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| eventRestoreHp(p, param);
                        self.pos += 2;
                    },
                    // EventCmd_df: restore MP
                    0xDF => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| eventRestoreMp(p, param);
                        self.pos += 2;
                    },
                    // EventCmd_e2: give spell — list_id, spell_id (3 bytes)
                    0xE2 => {
                        const list_id = ctx.rom.readU8(self.pos + 1) catch break;
                        const spell_id = ctx.rom.readU8(self.pos + 2) catch break;
                        if (ctx.spell_lists) |sl| _ = cmd_magic_mod.giveSpell(sl, list_id, spell_id);
                        self.pos += 3;
                    },
                    // EventCmd_e3: clear status (AND keep-mask)
                    0xE3 => {
                        const mask = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| {
                            eventClearStatus(p, mask);
                            self.party_dirty = true;
                            ctx.party_dirty = true;
                        }
                        self.pos += 2;
                    },
                    // EventCmd_e4: set status (ORA)
                    0xE4 => {
                        const mask = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| {
                            eventSetStatus(p, mask);
                            self.party_dirty = true;
                            ctx.party_dirty = true;
                        }
                        self.pos += 2;
                    },
                    // EventCmd_e5: give GP = param×100
                    0xE5 => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.gil) |g| eventGiveGil(g, param);
                        self.pos += 2;
                    },
                    // EventCmd_e6: take GP = param×100
                    0xE6 => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.gil) |g| eventTakeGil(g, param);
                        self.pos += 2;
                    },
                    0xE7 => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| {
                            if (party_mod.addFromEvent(ctx.rom, p, param)) {
                                self.party_dirty = true;
                                ctx.party_dirty = true;
                            }
                        }
                        self.pos += 2;
                    },
                    0xE8 => {
                        const param = ctx.rom.readU8(self.pos + 1) catch break;
                        if (ctx.party) |p| {
                            if (party_mod.removeByEventParam(p, param)) {
                                self.party_dirty = true;
                                ctx.party_dirty = true;
                            }
                        }
                        self.pos += 2;
                    },
                    // EventCmd_ec: forced battle (formation id = low 8 bits of battle_id).
                    // Intro airship: EC $EB (3× mon $D0), EC $F5 (1× mon $D1).
                    0xEC => {
                        const form = ctx.rom.readU8(self.pos + 1) catch break;
                        self.pos += 2;
                        self.last_battle_id = form;
                        self.blocked = .battle;
                        return .battle;
                    },
                    // Pause: param × 8 frames (EventCmd_e9 @e5xx) — exact, no host cap.
                    0xE9 => {
                        const n = ctx.rom.readU8(self.pos + 1) catch 1;
                        self.pos += 2;
                        self.wait_frames = @as(u16, n) *% 8;
                        return .running;
                    },
                    0xEE => {
                        const idx = ctx.rom.readU8(self.pos + 1) catch break;
                        const page: u8 = if (idx < ctx.npc_dlg_table.len) ctx.npc_dlg_table[idx] else 0;
                        if (loadMapDlg(ctx.rom, ctx.map_id, page, &scratch)) |s| {
                            ctx.setDlg(s);
                            self.pos += 2;
                            if (s.len > 0) {
                                self.blocked = .dialogue;
                                return .dialogue;
                            }
                        } else self.pos += 2;
                    },
                    0xEF => {
                        const page = ctx.rom.readU8(self.pos + 1) catch break;
                        if (loadMapDlg(ctx.rom, ctx.map_id, page, &scratch)) |s| {
                            ctx.setDlg(s);
                            self.pos += 2;
                            if (s.len > 0) {
                                self.blocked = .dialogue;
                                return .dialogue;
                            }
                        } else self.pos += 2;
                    },
                    0xF0 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        if (loadEventDlg(ctx.rom, .event1, id, &scratch)) |s| {
                            ctx.setDlg(s);
                            self.pos += 2;
                            if (s.len > 0) {
                                self.blocked = .dialogue;
                                return .dialogue;
                            }
                        } else self.pos += 2;
                    },
                    0xF1 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        if (loadEventDlg(ctx.rom, .event1, @as(u16, id) + 256, &scratch)) |s| {
                            ctx.setDlg(s);
                            self.pos += 2;
                            if (s.len > 0) {
                                self.blocked = .dialogue;
                                return .dialogue;
                            }
                        } else self.pos += 2;
                    },
                    0xF2 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        setSwitchBit(ctx.event_switch, id, true);
                        self.pos += 2;
                    },
                    0xF3 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        setSwitchBit(ctx.event_switch, id, false);
                        self.pos += 2;
                    },
                    0xF4 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        applyNpcSwitchCmd(ctx, id, true);
                        self.npc_dirty = true;
                        self.pos += 2;
                    },
                    0xF5 => {
                        // Clear NPC switch — hide crystal/door/etc. (event.asm ClearNPCSwitch).
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        applyNpcSwitchCmd(ctx, id, false);
                        self.npc_dirty = true;
                        self.pos += 2;
                    },
                    0xF6 => {
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        if (loadEventDlg(ctx.rom, .event2, id, &scratch)) |s| {
                            ctx.setDlg(s);
                            self.pos += 2;
                            if (s.len > 0) {
                                self.blocked = .dialogue;
                                return .dialogue;
                            }
                        } else self.pos += 2;
                    },
                    0xF8 => {
                        // EventCmd_f8: dialogue + Yes/No ($db); no → FindEventTerminator.
                        const id = ctx.rom.readU8(self.pos + 1) catch break;
                        self.pos += 2;
                        self.yes_no_kind = .f8;
                        if (loadEventDlg(ctx.rom, .event1, @as(u16, id) + 256, &scratch)) |s| {
                            ctx.setDlg(s);
                        } else {
                            ctx.setDlg("Yes or no?");
                        }
                        self.blocked = .yes_no;
                        return .yes_no;
                    },
                    // EventCmd_f7: item select gate (event.asm @ed96).
                    // Auto-use required item when present (no ShowItemWindow UI yet).
                    0xF7 => {
                        const want = ctx.rom.readU8(self.pos + 1) catch break;
                        self.pos += 2;
                        const ok = if (ctx.auto_use_key) ctx.inventory.has(want) else false;
                        if (!ok) {
                            // Wrong/missing item → dlg $14 then FindEventTerminator.
                            if (loadEventDlg(ctx.rom, .event1, 0x14, &scratch)) |s| {
                                ctx.setDlg(s);
                            } else {
                                ctx.setDlg("Locked.");
                            }
                            self.blocked = .dialogue;
                            // Abort remainder after dialogue dismiss.
                            self.pos = self.end;
                            return .dialogue;
                        }
                        // Key items $ED–$FD and $EC not consumed; else dec qty (@edc6).
                        if (want != 0xEC and !(want >= 0xED and want <= 0xFD)) {
                            _ = ctx.inventory.take(want);
                        }
                    },
                    // EventCmd_ed: open shop (event.asm @e5e6).
                    0xED => {
                        const sid = ctx.rom.readU8(self.pos + 1) catch break;
                        ctx.shop_id = sid;
                        self.pos += 2;
                        return .running;
                    },
                    // EventCmd_ea: play song with fade-in (sound cmd $04).
                    0xEA => {
                        const song = ctx.rom.readU8(self.pos + 1) catch 0xFF;
                        self.last_song = song;
                        ctx.song = song;
                        self.pos += 2;
                        return .running;
                    },
                    // EventCmd_f9: COLDATA window flash sequence (event.asm @e9b9).
                    // Full multi-frame COLDATA loop is host FX; flash + short hold.
                    0xF9 => {
                        self.pos += 2;
                        ctx.flash = true;
                        self.wait_frames = 8;
                        return .running;
                    },
                    // $FA PlaySongEvent, $FB PlaySfx (ROM order — was swapped)
                    0xFA => {
                        self.last_song = ctx.rom.readU8(self.pos + 1) catch 0xFF;
                        ctx.song = self.last_song;
                        self.pos += 2;
                        // Yield so host can switch BGM this field (PlaySongEvent is blocking on SNES)
                        return .running;
                    },
                    0xFB => {
                        self.last_sfx = ctx.rom.readU8(self.pos + 1) catch 0;
                        ctx.sfx = self.last_sfx;
                        self.pos += 2;
                        return .running;
                    },
                    0xFD => {
                        // EventCmd_fd: special effect table (special.asm Special_00…).
                        const sid = ctx.rom.readU8(self.pos + 1) catch 0;
                        self.pos += 2;
                        ctx.special_id = sid;
                        return .running;
                    },
                    0xFE => {
                        if (self.pos + 4 < self.end) {
                            const map_b = ctx.rom.readU8(self.pos + 1) catch break;
                            const xb = ctx.rom.readU8(self.pos + 2) catch break;
                            const yb = ctx.rom.readU8(self.pos + 3) catch break;
                            const fl = ctx.rom.readU8(self.pos + 4) catch 0;
                            self.last_warp = parseFeWarp(map_b, xb, yb, fl);
                            ctx.warp = self.last_warp;
                            ctx.map_id = if (self.last_warp.?.to_world) 0 else self.last_warp.?.map_id;
                        }
                        self.pos += 5;
                        self.blocked = .warp;
                        return .warp;
                    },
                    // EventCmd_da: FadeIn if screen dark, FadeOut if bright (field.asm @ea4c).
                    0xDA => {
                        self.pos += 1;
                        ctx.fade_toggle = true;
                        return .running;
                    },
                    // EventCmd_d0: toggle screen shake ($e3 eor #1).
                    0xD0 => {
                        self.pos += 1;
                        ctx.shake_toggle = true;
                        return .running;
                    },
                    // EventCmd_d1: flash screen (2× invert-pal vblanks).
                    0xD1 => {
                        self.pos += 1;
                        ctx.flash = true;
                        // Hold script while flash plays (host uses flash_frames).
                        self.wait_frames = 2;
                        return .running;
                    },
                    // EventCmd_d2: mosaic pixelation (64 fields via EventMosaicTbl).
                    0xD2 => {
                        self.pos += 1;
                        ctx.mosaic = true;
                        return .running;
                    },
                    // EventCmd_d3: EarthToMoon / MoonToEarth (vehicle.asm).
                    0xD3 => {
                        self.pos += 1;
                        ctx.earth_moon = true;
                        return .running;
                    },
                    // EventCmd_d4: Fat Chocobo menu.
                    0xD4 => {
                        self.pos += 1;
                        ctx.menu_fx = 1;
                        return .running;
                    },
                    // EventCmd_d5: open secret door (tile rewrite + anim).
                    0xD5 => {
                        self.pos += 1;
                        ctx.secret_door = true;
                        return .running;
                    },
                    // EventCmd_d6: one-shot scroll quake pulse.
                    0xD6 => {
                        self.pos += 1;
                        ctx.quake_pulse = true;
                        return .running;
                    },
                    // EventCmd_d7: toggle movement speed ($ac).
                    0xD7 => {
                        self.pos += 1;
                        ctx.speed_toggle = true;
                        return .running;
                    },
                    // EventCmd_d8: fade out music slow.
                    0xD8 => {
                        self.pos += 1;
                        ctx.song_fade_out = true;
                        return .running;
                    },
                    // EventCmd_d9: Namingway menu.
                    0xD9 => {
                        self.pos += 1;
                        ctx.menu_fx = 2;
                        return .running;
                    },
                    else => {
                        const len = eventCmdLen(cmd);
                        self.pos += if (len == 0) 1 else len;
                        budget -|= 1;
                    },
                }
                continue;
            }

            // $C0–$CF: player control (not NPC actor)
            if (cmd >= 0xC0 and cmd <= 0xCF) {
                applyPlayerOpcode(ctx, cmd);
                self.pos += 1;
                // Walk ops: wait for the 1-tile step (host holds while isMoving).
                if (cmd < 0xC4) {
                    self.wait_frames = 0;
                    return .running;
                }
                budget -|= 1;
                continue;
            }

            // Bare low opcode outside $EB batch — NPC actor cmd.
            // ROM: after walk/jump/spin starts, event loop waits for $0908 clear
            // (field/event.asm @e31c) — yield so MoveNPCs can settle (E4).
            if (cmd < 0xC0) {
                if (ctx.npcs) |ns| {
                    const action = cmd & 0x0F;
                    ns.applyEventOpcode(cmd);
                    self.pos += 1;
                    // Walk (0–3), jump (9), spin (A), spin+jump (B) block on $0908.
                    if (action < 4 or action == 0x09 or action == 0x0A or action == 0x0B) {
                        return .running;
                    }
                } else {
                    self.pos += 1;
                }
            } else {
                self.pos += 1;
            }
            budget -|= 1;
        }

        if (self.pos >= self.end) {
            self.active = false;
            return .done;
        }
        // Choreo batch done this field — 1 frame breathe between batches
        self.wait_frames = 1;
        return .running;
    }
};

/// Player event opcodes $C0–$CF (field/event.asm _00e4a9).
///
/// | cmd  | ROM effect |
/// |------|------------|
/// | C0–C3 | walk U/R/D/L (joypad bits → CheckPlayerMove) |
/// | C4–C7 | face → `$1705` = 0–3 |
/// | C8    | hide player (`$d3`=1) |
/// | C9    | show player (`$d3`=0) |
/// | CA–CD | special pose `$1705` = 5/4/6/7 |
/// | CE    | toggle `$cf` (party follow / formation) |
/// | CF    | toggle `$d8` spin; DrawPlayerSub forces `$1705`=$08 while set |
fn applyPlayerOpcode(ctx: *EventCtx, cmd: u8) void {
    if (cmd < 0xC4) {
        // $C0–$C3: walk up/right/down/left (joypad $0800/$0100/$0400/$0200 → dir 1–4).
        const dir: u8 = cmd - 0xC0 + 1;
        // Facing from walk only when `$cf` clear (host startScriptedWalk also checks).
        const freeze = if (ctx.party_follow) |pf| pf.* else false;
        if (!freeze) {
            if (ctx.player_facing) |f| {
                f.* = switch (dir) {
                    1 => 0,
                    2 => 1,
                    3 => 2,
                    else => 3,
                };
            }
        }
        if (ctx.player_walk_dir) |w| w.* = dir;
        return;
    }
    if (cmd < 0xC8) {
        // $C4–$C7: face only → $1705 = 0..3
        if (ctx.player_facing) |f| f.* = cmd - 0xC4;
        return;
    }
    if (cmd == 0xC8) {
        // Hide player ($d3 = 1) — DrawPlayerSub early-out.
        if (ctx.player_hidden) |h| h.* = true;
        return;
    }
    if (cmd == 0xC9) {
        if (ctx.player_hidden) |h| h.* = false;
        return;
    }
    if (cmd >= 0xCA and cmd <= 0xCD) {
        // Special poses → $1705 = $05/$04/$06/$07 (order matches _00e4a9).
        // $CA hang-head / bow, $CB arms, $CC/$CD other cutscene frames.
        // Also clears spin anim timers in ROM (@e52e stz $ab/$02/$03).
        if (ctx.player_facing) |f| {
            f.* = switch (cmd) {
                0xCA => 5,
                0xCB => 4,
                0xCC => 6,
                else => 7,
            };
        }
        return;
    }
    if (cmd == 0xCE) {
        // Toggle `$cf`: freeze facing during walks (not formation drawing).
        if (ctx.party_follow) |pf| {
            pf.* = !pf.*;
            if (ctx.npcs) |ns| ns.hold_facing = pf.*;
        }
        return;
    }
    // $CF: toggle $d8. While set, DrawPlayerSub forces $1705=$08 and cycles faces.
    if (cmd == 0xCF) {
        if (ctx.player_spin) |s| {
            s.* = !s.*;
        } else if (ctx.player_facing) |f| {
            // Fallback when host has no spin flag: encode as pose 8.
            f.* = if (f.* == 8) 2 else 8;
        }
        return;
    }
}

