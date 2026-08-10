//! ExecBattle / BattleMain host — battle.asm @8009 / @85d9.
//!
//! Frame loop: speed gate → DecTimers → CheckBattleEnd → menu/AI → DoAttack.
//! Commands: Fight (Cmd_00), Item (Cmd_01), Run (Cmd_24).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const data_mod = @import("../data.zig");
const damage = @import("damage.zig");
const prop = @import("prop.zig");
const obj_mod = @import("obj.zig");
const timer = @import("timer.zig");
const cmd_fight = @import("cmd_fight.zig");
const cmd_run = @import("cmd_run.zig");
const cmd_item = @import("cmd_item.zig");
const inventory_mod = @import("../game/inventory.zig");
const sprites = @import("sprites.zig");
const window = @import("window.zig");
const cursor_mod = @import("cursor.zig");
const audio_mod = @import("../audio/audio.zig");
const font_mod = @import("../gfx/font.zig");
const numerals = @import("numerals.zig");
const timer_dur = @import("timer_dur.zig");
const offsets = @import("../offsets.zig");
const ai_mod = @import("ai.zig");
const ai_cond = @import("ai_cond.zig");
const item_prop = @import("item_prop.zig");
const cmd_magic = @import("cmd_magic.zig");
const win_mod = @import("win.zig");
const battle_msg = @import("battle_msg.zig");
const cmd_steal = @import("cmd_steal.zig");
const rom_rng = @import("rom_rng.zig");
const state_mod = @import("../game/state.zig");
const equip = @import("equip.zig");
const retal_mod = @import("retal.zig");
const status_mod = @import("status.zig");
const cmd_enable = @import("cmd_enable.zig");
const auto_battle_mod = @import("auto_battle.zig");
const battle_dlg = @import("battle_dlg.zig");
const check_end_mod = @import("check_end.zig");
const gfx_script_mod = @import("gfx_script.zig");
const magic_anim_mod = @import("magic_anim.zig");
const fight_anim_mod = @import("fight_anim.zig");
const cmd_special_mod = @import("cmd_special.zig");
const opener_mod = @import("opener.zig");
const anim_script_mod = @import("anim_script.zig");
const boss_frame_mod = @import("boss_frame.zig");
const mon_entry_mod = @import("mon_entry.zig");
const party_sync_mod = @import("party_sync.zig");
const battle_song_mod = @import("battle_song.zig");
const show_msg_mod = @import("show_msg.zig");
const mon_rows_mod = @import("mon_rows.zig");

/// Non-empty inventory bag slots in order (for 2-col battle list).
pub fn filledItemList(inv: *const inventory_mod.Inventory, out: *[48]usize) u8 {
    var n: u8 = 0;
    for (inv.slots, 0..) |s, i| {
        if (s.id == 0 or s.qty == 0) continue;
        out[n] = i;
        n += 1;
        if (n >= 48) break;
    }
    return n;
}

/// Hand equip slots as pseudo bag indices for Item command (cmd.asm $26d0 bit4).
pub const hand_left_slot: usize = 48;
pub const hand_right_slot: usize = 49;

/// Battle item list: castable hand weapons first (id < $B0 + spell), then bag.
/// Hand entries use hand_left_slot / hand_right_slot as "bag" indices.
pub fn battleItemList(
    inv: *const inventory_mod.Inventory,
    left_hand: u8,
    right_hand: u8,
    rom: ?*const rom_mod.Rom,
    out: *[50]usize,
) u8 {
    var n: u8 = 0;
    if (rom) |r| {
        if (handCastable(r, left_hand) and n < 50) {
            out[n] = hand_left_slot;
            n += 1;
        }
        if (handCastable(r, right_hand) and n < 50) {
            out[n] = hand_right_slot;
            n += 1;
        }
    }
    var bag: [48]usize = undefined;
    const bn = filledItemList(inv, &bag);
    var i: u8 = 0;
    while (i < bn and n < 50) : (i += 1) {
        out[n] = bag[i];
        n += 1;
    }
    return n;
}

fn handCastable(r: *const rom_mod.Rom, item_id: u8) bool {
    if (item_id == 0 or item_id >= item_prop.item_prop_base) return false;
    const eq = equip.EquipProp.load(r, item_id) orelse return false;
    return eq.mag_def_base != 0;
}

/// Mirrors $a8 battle end flags (subset).
pub const EndFlags = struct {
    victory: bool = false,
    ran: bool = false,
    defeated: bool = false,

    pub fn any(self: EndFlags) bool {
        return self.victory or self.ran or self.defeated;
    }
};

pub const Phase = enum {
    running,
    menu,
    /// StepForwardToAttack / DoFightAnim / hit flash (btlgfx).
    animating,
    message,
    done,
};

/// ROM command ids (BattleCmdName / ClassCmd). Not a custom enum.
/// $1A = Chang (row), $1B = Parry — see BattleCmdName EN table.
pub const CmdId = struct {
    pub const fight: u8 = 0x00;
    pub const item: u8 = 0x01;
    pub const white: u8 = 0x02;
    pub const black: u8 = 0x03;
    pub const call: u8 = 0x04;
    pub const jump: u8 = 0x06;
    pub const dark: u8 = 0x05; // Dark Wave (EN name "Dummy")
    pub const recall: u8 = 0x07;
    pub const sing: u8 = 0x08;
    pub const hide: u8 = 0x09;
    pub const pray: u8 = 0x0B; // (EN name "Dummy")
    pub const aim: u8 = 0x0C;
    pub const kick: u8 = 0x0E;
    pub const twin: u8 = 0x10;
    pub const bluff: u8 = 0x11;
    pub const cry: u8 = 0x12;
    pub const cover: u8 = 0x13; // Cover — openCoverSelect
    pub const peep: u8 = 0x14; // Search
    pub const dart: u8 = 0x16; // Throw
    pub const sneak: u8 = 0x17; // Steal
    pub const ninja: u8 = 0x18; // Ninjutsu list
    pub const show: u8 = 0x1C; // Appear (after Hide)
    pub const chang: u8 = 0x1A; // row change ("Chang")
    pub const parry: u8 = 0x1B; // defend ("Parry")
    pub const regen: u8 = 0x19; // Fusoya Regen — starts party regen ticks
    pub const end_regen: u8 = 0x22; // pending cmd after regen cast
    pub const salve: u8 = 0x0A; // Cure potion from bag → DoMagicAttack
    pub const focus: u8 = 0x0D; // Focus1 charge → Focus2 fight
    pub const focus2: u8 = 0x1F; // Focus2 resolve
    pub const brace: u8 = 0x0F; // Armor spell $05
};

pub const MenuMode = enum {
    /// ClassCmd list (DrawCmdWindow) — cursor type $01
    command,
    /// Inventory (item command) — cursor type $05
    item,
    /// White/Black/Call spell list — cursor type $06-ish (MagicListCursorXTbl)
    magic,
    /// Fight (and similar) target select — cursor type $04 (UpdateCursor_04)
    target,
    /// Cover (Cmd_13): select ally to protect — party slots only.
    cover_target,
};

/// Physical attack presentation (cmd_anim StepForward + weapon.asm DoFightAnim subset).
pub const AnimKind = enum {
    none,
    /// Party fight: step in → strike pose → damage/flash → step back.
    party_fight,
    /// Monster fight: lunge → damage/flash → retreat.
    mon_fight,
    /// MonsterDeathAnim — $30 frames of dissolve (monster_death.asm).
    mon_death,
    /// Victory pose hold after last enemy falls.
    victory,
    /// ExecGfxScript multi-frame runner (`gfx_script.Vm`) — BtlGfx_05.
    gfx_script,
};

pub const AnimState = struct {
    kind: AnimKind = .none,
    /// Frames elapsed in current kind.
    t: u8 = 0,
    attacker: usize = 0,
    target: usize = 0,
    /// Pending damage applied at impact frame.
    damage: u16 = 0,
    missed: bool = false,
    crit: bool = false,
    target_died: bool = false,
    /// Pixel offset applied when drawing attacker (negative = toward monsters).
    char_dx: i8 = 0,
    mon_dx: i8 = 0,
    /// Char pose while animating (party attacker / hit target).
    char_pose: sprites.CharPose = .standing,
    /// Target flash remaining (white silhouette) — WeaponHitAnim ~$10 frames.
    hit_flash: u8 = 0,
    /// Party target hit pose remaining (UpdateHitCharPose).
    hit_pose_timer: u8 = 0,
    hit_pose_slot: usize = 0,
    /// Monsters dying this death-anim pass (bit i = mon slot i).
    death_mask: u8 = 0,
    /// MonsterDeathAnim frame 0..$2F (dissolve progress).
    death_t: u8 = 0,
    /// Impact spark at target (WeaponHitAnim frames).
    spark_t: u8 = 0,
    spark_x: i16 = 0,
    spark_y: i16 = 0,
    /// SwordWhipHitFrameTbl row from WeaponAnimProp+2 (0..7).
    hit_frame_row: u8 = 0,
};

/// Battle host state (reimplementation of battle WRAM control vars we need).
pub const Host = struct {
    active: bool = false,
    phase: Phase = .done,
    objs: obj_mod.ObjTable = .{},
    battle_id: u16 = 0,
    /// $1802 battle BG id (low 5 bits).
    bg_id: u8 = 0,
    prop_flags: u8 = 0,
    /// $3538: frames until next logic tick (BattleSpeedTbl[setting]+1).
    speed_counter: u8 = 1,
    speed_reload: u8 = 4,
    /// Config $16ac battle speed index 0..5.
    battle_speed: u8 = offsets.en.battle_speed_default,
    /// Config $16ad battle message speed 0..5 (MsgDurTbl).
    msg_speed: u8 = offsets.en.msg_speed_default,
    /// Config $16be: 0 = Wait (pause ATB on menu), 1 = Active.
    battle_mode: u8 = 0,
    priority_slot: usize = 0,
    menu_slot: usize = 0,
    menu_mode: MenuMode = .command,
    /// Cursor index into cmd_list (0..cmd_count-1).
    menu_sel: u8 = 0,
    /// Loaded ClassCmd + Parry/Chang for acting character.
    cmd_list: [7]u8 = .{0xFF} ** 7,
    cmd_count: u8 = 0,
    /// Inventory bag slot (0..47) while menu_mode == item.
    item_slot: usize = 0,
    /// Linear index into filled-item list (battle inv 2-col).
    item_list_i: u8 = 0,
    /// First visible row of the 2-col list (ListCursorYTbl has 5 rows).
    item_scroll: u8 = 0,
    /// Spell list while menu_mode == magic (SpellListInit ids).
    magic_list: [24]u8 = .{0xFF} ** 24,
    magic_count: u8 = 0,
    magic_sel: u8 = 0,
    magic_scroll: u8 = 0,
    /// 0=White 1=Black 2=Call (SpellListTbl column).
    magic_col: u8 = 0,
    /// ROM window chrome (WindowGfx).
    chrome: window.WindowChrome = .{},
    /// Hand cursor (MiscBattleGfx tile $4a / name $14a).
    hand: cursor_mod.HandCursor = .{},
    /// Menu/battle 8×8 font (WindowGfx sheet).
    font: font_mod.MenuFont = .{},
    /// BattleProp byte6 → BattleSongTbl (0xFF = no battle music).
    song_id: u8 = 0xFF,
    /// BattleProp.battle_flags (`$38e5` / `$29a2`) — song bits + can't-run etc.
    battle_flags: u8 = 0,
    /// Mid-fight / fanfare: song_id changed; app should PlaySong (GfxScript `$F3` / victory).
    song_dirty: bool = false,
    /// Queued game SFX (cmd $02) — consumed by app each frame.
    pending_sfx: u8 = 0,
    /// Queued system SFX ($10..$1E).
    pending_sys_sfx: u8 = 0,
    /// Target monster (fight) or party/mon (item) slot.
    target_slot: usize = obj_mod.party_slots,
    msg: [96]u8 = undefined,
    msg_len: usize = 0,
    /// DrawFull vs Left/Right attack-name windows (menu.asm Draw*MsgWindow).
    msg_kind: window.MsgKind = .full,
    msg_timer: u8 = 0,
    end_flags: EndFlags = .{},
    gil_gained: u32 = 0,
    exp_gained: u32 = 0,
    /// WinUpdate drops $1804[0..8] (item ids).
    items_gained: [win_mod.max_drops]u8 = .{0} ** win_mod.max_drops,
    items_gained_n: u8 = 0,
    /// Weapon/status bits to apply on fight impact (from calcFight).
    pending_status_s1: u8 = 0,
    pending_status_s2: u8 = 0,
    /// After target select: which cmd to run (fight/sneak/dart/peep).
    pending_cmd: u8 = 0xFF,
    /// GetCharAttack magic charge: spell id per party slot (0xFF = none). TimerDur_03.
    charge_spell: [obj_mod.party_slots]u8 = .{0xFF} ** obj_mod.party_slots,
    /// Target slot for `charge_spell`.
    charge_target: [obj_mod.party_slots]u8 = .{0xFF} ** obj_mod.party_slots,
    /// AI battle variables $35f3[0..15] (ChangeBattleVar / AICond_02).
    battle_vars: [16]u8 = .{0} ** 16,
    flash: u8 = 0,
    anim: AnimState = .{},
    /// ShowMsg_04 damage numerals.
    floaters: numerals.FloaterBank = .{},

    /// Shared field inventory ($1440) — mutated on item use / victory copy.
    inv: ?*inventory_mod.Inventory = null,
    rom: ?*const rom_mod.Rom = null,
    /// Field runtime spell lists ($1560) for learned magic; null → ROM init table.
    spell_lists: ?*const cmd_magic.SpellLists = null,
    /// GameData for ActivateMonster / peep names (set on enter).
    gd: ?*const data_mod.GameData = null,
    /// Twin pair slots $3539 (Palom/Porom/Fusoya/Golbez) — init.asm @959e.
    twin_pair: [2]u8 = .{ 0xFF, 0xFF },
    /// Loaded battle sprites (BG + mon + char). Owned by Host when active.
    scene: sprites.Scene = .{},
    /// Monster type ids for this formation (for gfx reload / gil).
    mon_types: [8]u8 = .{0xFF} ** 8,
    mon_count: u8 = 0,
    /// BattleProp mon_type[3] + counts (Change Form / Call use type indices 0–2 as IDs).
    form_types: [3]u8 = .{0xFF} ** 3,
    form_counts: [3]u8 = .{0} ** 3,
    /// Raw counts byte ($29a0) for Change Form mode bits 1–0.
    form_counts_raw: u8 = 0,
    /// $3881 mon invincible counter (MagicEffect $2e/$2f).
    mon_invincible: u8 = 0,
    /// $38e4 delay monster death (MagicEffect_35 mist dragon).
    delay_mon_death: u8 = 0,
    /// MonsterCursor 16 bytes for this formation ($29cf) — neighbor graph.
    mon_cursor: [16]u8 = .{0xFF} ** 16,
    /// $38ef: use AIAction2 moon scripts ($1801 bit7 / moon world).
    moon_ai: bool = false,
    /// L+R flee counter $38d6 + can't-run (battle.asm).
    run_state: cmd_run.RunState = .{},
    /// Battle RNG (RNGTbl @ $1900 mirror).
    rng: rom_rng.RomRng = .{},
    /// AICond battle history (types 5,7–0a).
    party_escaped: bool = false,
    mon_took_damage: [8]bool = .{false} ** 8,
    last_hit_attacker: u8 = 0xFF,
    last_hit_cmd: u8 = 0xFF,
    last_hit_element: u8 = 0,
    last_hit_mon: u8 = 0xFF,
    /// $38d7: 0 none, 1 first strike, $80 surprised (cleared after opener msg).
    opener_flag: u8 = 0,
    /// $38d8: timer advantage for first-strike / surprise (init.asm @8e1d).
    timer_adv: u8 = 0,
    /// $3581 bit3 — forced or rolled back attack (row flip + msg 4).
    back_attack: bool = false,
    /// Monster retaliation stacks $2b78 / $35f7 (AddRetal).
    retal: retal_mod.Table = .{},
    /// $390a: disable retaliation (some cmds).
    retal_disabled: bool = false,
    /// $3557 SapRegenEffect phase (even/odd main-logic ticks).
    sap_regen_phase: u8 = 0,
    /// $357c: $FF = regen off; else counter 0..4, heal on 5 (timer.asm SapRegen).
    regen_counter: u8 = 0xFF,
    /// $357d: HP healed per regen tick (Cmd_19 sets 10).
    regen_hp: u8 = 0,
    /// $388b + $388c script — AutoBattleTbl scripted party battles (init.asm @8954).
    auto_battle: auto_battle_mod.State = .{},
    /// NoUpdateBattleTbl — skip **WinUpdate** (gil/exp/level/drops) only.
    /// RestoreCharProp still writes HP/MP/status to field (win.asm @f18b).
    no_party_update: bool = false,
    /// NoWinAnimTbl — short victory, no long pose hold.
    no_win_anim: bool = false,
    /// NoFanfareTbl — suppress victory fanfare song.
    no_fanfare: bool = false,
    /// Queued BattleDlg ids from AI $F1/$F2 (shown before mon action).
    dlg_queue: [8]u8 = .{0xFF} ** 8,
    dlg_queue_n: u8 = 0,
    dlg_queue_i: u8 = 0,
    /// Monster action deferred until dialogue queue empties.
    pending_mon_slot: usize = 0xFF,
    pending_mon_cmd: u8 = 0xFF,
    pending_mon_spell: u8 = 0,
    pending_mon_target: usize = 0,
    /// $3877 multi-action depth (ai.asm $FD/$FC) — mon re-acts while > 0.
    mon_multi_depth: u8 = 0,
    /// $33c2 graphics script buffer mirror (attack.asm InitGfxScript / ExecCmd).
    gfx_script_buf: [64]u8 = .{0xFF} ** 64,
    gfx_script_len: usize = 0,
    /// ExecGfxScript runner (btlgfx @bef0).
    gfx_vm: gfx_script_mod.Vm = .{},
    /// Boss frame ids from $F0 (ChangeBossFrame $f2b4,y) — mon slots 0–3.
    boss_frame: [4]u8 = .{0xFF} ** 4,
    /// BossTransition remaining host wait after $F0 (BossTransition @ccca).
    boss_transition_wait: u16 = 0,
    /// $F7 darken battle BG active (host darken overlay).
    bg_darken: bool = false,
    /// InitBtlGfx monster entry (`$f28e`) — UpdateMonsterEntry @8263.
    mon_entry_counter: u8 = 0,
    /// Scroll delta pixels for mon entry blit (BG1 H or V).
    mon_entry_scroll: i16 = 0,
    /// True while entry counter > 0 (blocks player input like `$f44a` clear).
    mon_entry_active: bool = false,
    /// UpdateMonsterRows (@e988): mon slot front (left-column) for name plate.
    mon_row_front: [8]bool = .{false} ** 8,
    /// BattleProp+6 bit6 → `$ed4e&$40` flying entry (InitBtlGfx).
    mons_flying: bool = false,
    /// `$6cc0` back-attack layout for entry invert (kept after `$3581` clear).
    entry_back_attack: bool = false,

    pub fn msgSlice(self: *const Host) []const u8 {
        return self.msg[0..self.msg_len];
    }

    /// MsgDurTbl[$16ad] — WaitMsgAuto frame count (btlgfx @c953). Cap u8 for our timer.
    pub fn msgDuration(self: *const Host) u8 {
        const i: usize = @min(self.msg_speed, offsets.en.msg_dur_tbl_len - 1);
        var frames: u16 = offsets.en.msg_dur_embed[i];
        if (self.rom) |rom| {
            if (rom.slice(offsets.en.msg_dur_tbl + i * 2, 2)) |raw| {
                frames = @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
            } else |_| {}
        }
        // Host msg_timer is u8; MsgDurTbl max $C0 = 192
        return @intCast(@min(frames, 255));
    }

    /// CloseMsgWindow — clear text so chrome is not left up forever.
    pub fn clearMsg(self: *Host) void {
        self.msg_len = 0;
        self.msg_timer = 0;
        self.msg_kind = .full;
    }

    pub fn setMsg(self: *Host, text: []const u8) void {
        self.setMsgKind(text, .full);
    }

    /// ShowMsg_02 attack/command name → DrawAttackNameWindow (right by default).
    pub fn setAttackNameMsg(self: *Host, text: []const u8) void {
        self.setMsgKind(text, .right);
    }

    pub fn setMsgKind(self: *Host, text: []const u8, kind: window.MsgKind) void {
        const n = @min(text.len, self.msg.len);
        if (n > 0) @memcpy(self.msg[0..n], text[0..n]);
        self.msg_len = n;
        self.msg_kind = kind;
        self.msg_timer = self.msgDuration();
    }

    /// ShowMsg_03: load BattleMsg id from ROM into the full message window.
    pub fn setBattleMsg(self: *Host, id: u8) void {
        if (self.rom) |rom| {
            const s = battle_msg.load(rom, id, &self.msg);
            self.msg_len = s.len;
            self.msg_kind = .full;
            self.msg_timer = self.msgDuration();
        } else {
            self.clearMsg();
        }
    }

    /// Wait mode ($16be == 0): ATB pauses while menu open. Active continues.
    pub fn isWaitMode(self: *const Host) bool {
        return self.battle_mode == 0;
    }

    pub fn deinitScene(self: *Host) void {
        self.scene.deinit();
    }

    /// Build AICond BattleCtx from current host state.
    /// `cond_mon_slot` = absolute mon slot for AICond_07/08 stack lookup.
    pub fn makeBattleCtx(self: *const Host) ai_cond.BattleCtx {
        return self.makeBattleCtxFor(0xFF);
    }

    pub fn makeBattleCtxFor(self: *const Host, cond_mon_slot: u8) ai_cond.BattleCtx {
        return .{
            .battle_id = self.battle_id,
            .battle_vars = &self.battle_vars,
            .mon_types = self.mon_types[0..self.mon_count],
            .mon_count = self.mon_count,
            .living_mons = self.objs.livingMonsters(),
            .party_escaped = self.party_escaped,
            .mon_took_damage = self.mon_took_damage,
            .last_hit_attacker = self.last_hit_attacker,
            .last_hit_cmd = self.last_hit_cmd,
            .last_hit_element = self.last_hit_element,
            .last_hit_mon = self.last_hit_mon,
            .cond_mon_slot = cond_mon_slot,
            .retal = &self.retal,
        };
    }

    /// Record last hit for AICond types 7/8/0a + AddRetal (attack.asm @b042).
    /// Skips stack push when delay_mon_death ($38e4) or retal_disabled ($390a).
    fn recordHit(self: *Host, attacker_slot: usize, target_slot: usize, cmd: u8, element: u8, dealt_damage: bool) void {
        self.last_hit_attacker = @intCast(attacker_slot);
        self.last_hit_cmd = cmd;
        self.last_hit_element = element;
        if (target_slot >= obj_mod.party_slots) {
            const mi: u8 = @intCast(target_slot - obj_mod.party_slots);
            self.last_hit_mon = mi;
            if (dealt_damage and mi < 8) self.mon_took_damage[mi] = true;
            // AddRetal after hit (unless mist-delay death or $390a)
            if (!self.retal_disabled and self.delay_mon_death == 0) {
                self.retal.addRetal(attacker_slot, target_slot, cmd, element);
            }
        } else {
            self.last_hit_mon = 0xFF;
        }
    }

    /// InitBattle + multi-party LoadCharProp/LoadEquipProp — $1800 = battle_id.
    /// `moon_ai` sets $38ef (AIAction2) — moon world or $1801 bit7.
    /// Config: $16ac battle_speed, $16ad msg_speed, $16be battle_mode, $16a8 party_row.
    pub fn enter(
        self: *Host,
        gpa: std.mem.Allocator,
        r: *const rom_mod.Rom,
        gd: *const data_mod.GameData,
        battle_id: u16,
        bg_flags: u8,
        inv: *inventory_mod.Inventory,
        party: []const state_mod.PartyMember,
        moon_ai: bool,
        battle_speed: u8,
        msg_speed: u8,
        battle_mode: u8,
        /// Config $16a8 — 0 default rows, nonzero inverted (InitCharRows).
        party_row: u8,
    ) !void {
        self.deinitScene();
        self.* = .{
            .active = true,
            .phase = .running,
            .battle_id = battle_id,
            .bg_id = bg_flags & 0x1F,
            .moon_ai = moon_ai or (battle_id & 0x8000) != 0,
            .rng = rom_rng.RomRng.init(r, @truncate(battle_id ^ bg_flags ^ 0x5A)),
            .gd = gd,
            .battle_speed = @min(battle_speed, 5),
            .msg_speed = @min(msg_speed, 5),
            .battle_mode = if (battle_mode != 0) 1 else 0,
            .priority_slot = 0,
            .inv = inv,
            .rom = r,
        };
        // BattleMain @85d9: $3538 = BattleSpeedTbl[$16ac] + 1
        self.speed_reload = battleSpeedReload(r, self.battle_speed);
        self.speed_counter = self.speed_reload;
        // InitBtlGfx: `$f28e=$16` monster entry (btlgfx @81f8).
        self.mon_entry_counter = mon_entry_mod.entry_counter_init;
        self.mon_entry_scroll = 0;
        self.mon_entry_active = true;
        const bp = try prop.load(r, battle_id);
        self.prop_flags = bp.flags;
        self.battle_flags = bp.battle_flags;
        self.song_id = audio_mod.battleSongId(bp.battle_flags);
        self.song_dirty = self.song_id != audio_mod.battle_song_none;
        // `$ed4e` = BattleProp+6 (battle_flags); bit6 flying monsters.
        self.mons_flying = (bp.battle_flags & mon_entry_mod.flying_bit) != 0;
        // init.asm @8954: battle_flags bit $20 + AutoBattleTbl → load scripts.
        self.auto_battle = auto_battle_mod.State.initFromBattle(battle_id, bp.battle_flags);
        self.no_party_update = auto_battle_mod.inTbl(battle_id, &auto_battle_mod.no_update_tbl);
        self.no_win_anim = auto_battle_mod.inTbl(battle_id, &auto_battle_mod.no_win_anim_tbl);
        self.no_fanfare = auto_battle_mod.inTbl(battle_id, &auto_battle_mod.no_fanfare_tbl);
        var plan = prop.expandSlots(bp);
        prop.applyPositions(r, &plan, bp.pos_index);
        self.objs.clear();

        // Load all present party members (LoadCharProp × 5).
        // char_gfx_ids is **slot-aligned** so scene.chars[i] matches party slot i.
        var char_gfx_ids: [5]u8 = .{0xFF} ** 5;
        var pi: usize = 0;
        while (pi < party.len and pi < obj_mod.party_slots) : (pi += 1) {
            const m = party[pi];
            if (!m.present) continue;
            const name: []const u8 = blk: {
                // Char id is 1-based; CharNameTbl[id-1] → name slot (Cecil=0, Kain=1, …).
                if (offsets.en.charNameIndex(m.id)) |ni| {
                    if (ni < gd.characters.len) break :blk gd.characters[ni].name;
                }
                break :blk "???";
            };
            const rh: u8 = if (m.right_hand != 0) m.right_hand else if (pi == 0) 0x17 else 0; // DK Cecil Darkness default
            self.objs.loadPartyMember(
                pi,
                r,
                name,
                m.id,
                m.class_id,
                m.gfx_id,
                m.level,
                m.hp,
                m.max_hp,
                m.mp,
                m.max_mp,
                m.strength,
                m.agility,
                m.wisdom,
                m.will,
                m.vitality,
                m.left_hand,
                rh,
                m.head,
                m.body,
                m.arms,
            );
            // Carry field status ($1003/$1004) into battle
            const po = self.objs.party(pi);
            po.status.s1 = m.status1;
            po.status.s2 = m.status2;
            if ((m.status1 & status_mod.Status1.poison) != 0) {
                timer.armPoison(po);
            }
            // InitCharGfx: pig/toad/mini override BattleCharGfx id.
            const battle_gfx = status_mod.battleCharGfxId(m.class_id, m.status1);
            po.gfx_id = battle_gfx;
            char_gfx_ids[pi] = battle_gfx;
        }
        // InitCharRows @95ce: $16a8 = 0 → slots 0–2 front, 3–4 back; else inverted
        {
            const invert = party_row != 0;
            var ri: usize = 0;
            while (ri < obj_mod.party_slots) : (ri += 1) {
                const p = self.objs.party(ri);
                if (!p.present) continue;
                // Default: front for 0..2, back for 3..4
                const default_back = ri >= 3;
                p.row = if (invert != default_back) 1 else 0;
            }
        }
        self.objs.loadMonsters(plan, gd);

        // init.asm @9075: auto-battle speed modifier $01 (else $10) on $203B.
        if (self.auto_battle.active) {
            var si: usize = 0;
            while (si < obj_mod.total_slots) : (si += 1) {
                const o = self.objs.get(si);
                if (o.present) o.speed_mod = 1;
            }
        }

        self.mon_count = plan.count;
        @memcpy(self.mon_types[0..plan.count], plan.type_id[0..plan.count]);
        self.form_types = bp.mon_type;
        self.form_counts = bp.mon_count;
        // Rebuild raw counts byte $29a0 (2 bits each, MSB first) for Change Form
        self.form_counts_raw = (bp.mon_count[0] << 6) | (bp.mon_count[1] << 4) | (bp.mon_count[2] << 2);
        self.mon_invincible = 0;
        self.delay_mon_death = 0;

        // Twin pair $3539: Palom($08), Porom($09), Fusoya($13), Golbez($15) (init.asm @959e)
        self.twin_pair = .{ 0xFF, 0xFF };
        var twin_n: usize = 0;
        var ti: usize = 0;
        while (ti < party.len and ti < obj_mod.party_slots) : (ti += 1) {
            if (!party[ti].present) continue;
            const cid = party[ti].id;
            if (cid == 0x08 or cid == 0x09 or cid == 0x13 or cid == 0x15) {
                if (twin_n < 2) {
                    self.twin_pair[twin_n] = @intCast(ti);
                    twin_n += 1;
                }
            }
        }

        // Run counter $38d6 from max mon level + battle_flags bit0 (can't run)
        const max_mlv = cmd_run.maxLivingMonLevel(&self.objs);
        self.run_state = cmd_run.initRunState(max_mlv, bp.battle_flags);

        // MonsterCursor table (battle.asm @81f6)
        const ci: usize = bp.cursor_index;
        if (ci < offsets.en.monster_cursor_count) {
            if (r.slice(offsets.en.monster_cursor + ci * 16, 16)) |raw| {
                @memcpy(&self.mon_cursor, raw);
            } else |_| {
                self.mon_cursor = .{0xFF} ** 16;
            }
        }

        // ClassCmd for first present member; reloaded each turn.
        const leader_class: u8 = if (party.len > 0) party[0].class_id else 0;
        self.cmd_count = window.loadClassCommands(r, leader_class, &self.cmd_list);
        self.menu_sel = 0;

        // Clear retaliation stacks ($35f7 = $FF) — battle.asm InitRAM @8274
        self.retal.clear();
        self.retal_disabled = false;

        // First-strike / surprise / back-attack rolls (init.asm @8c66–@8d44)
        self.rollPreemptive(bp);

        // Init action timers from agility (init.asm base + CalcTimerDur)
        timer_dur.initAllTimers(&self.objs);
        // $38d8 first-strike / surprise bias after base AT (init.asm @8e1d)
        timer_dur.applyOpenerAdv(&self.objs, self.timer_adv);

        // Back attack flips party row bit ($2001 bit7 xor) — init.asm @8e1d
        if (self.back_attack) {
            var ri: usize = 0;
            while (ri < obj_mod.party_slots) : (ri += 1) {
                const p = self.objs.party(ri);
                if (!p.present or p.status.isDead()) continue;
                p.row ^= 1;
            }
        }

        self.chrome.load(r) catch {};
        self.hand.load(r) catch {};
        self.font.load(r) catch {};

        // LoadBattleBG + LoadMonsterGfx + InitCharGfx (all party gfx ids)
        self.scene.load(gpa, r, self.bg_id, self.mon_types[0..self.mon_count], self.mon_count, char_gfx_ids[0..]) catch {
            // Graphics optional for logic tests; keep empty scene.
        };
        // Sync MonsterGfxSize into objs for UpdateMonsterPos cursor Y / floater center.
        self.syncSpriteSizes();

        // BattleMain @8609: opener BattleMsg from $38d7 / $3581, then clear flags.
        if (opener_mod.openerMsgId(self.back_attack, self.opener_flag)) |mid| {
            self.setBattleMsg(mid);
            self.phase = .message;
        } else {
            self.msg_len = 0;
            self.msg_timer = 20; // brief enter pause without invented text
            self.phase = .message;
        }
        // stz $38d7 / stz $3581 after AddMsg1 (battle.asm @1058)
        // Keep `$6cc0` sense for UpdateMonsterEntry invert during entry frames.
        self.entry_back_attack = self.back_attack;
        self.opener_flag = 0;
        self.back_attack = false;
    }

    /// init.asm @8c66–@8d44: average levels → first strike / surprise / optional back.
    ///
    /// Skip when forced back-attack prop, boss ($3582), can't-run ($38e5 bit0), moon ($38ef).
    /// $2002 level averages → RandXA(0,99) vs party avg, Rand99 vs mon avg.
    fn rollPreemptive(self: *Host, bp: prop.BattleProp) void {
        self.opener_flag = 0;
        self.timer_adv = 0;
        self.back_attack = false;

        // Forced back attack from BattleProp flags bit3 → $3581=$08, $38d8=$80
        if (bp.backAttack()) {
            self.back_attack = true;
            self.timer_adv = 0x80;
            return;
        }

        // Boss any mon with $2070 bit7
        var any_boss = false;
        var mi: usize = 0;
        while (mi < obj_mod.mon_slots) : (mi += 1) {
            const m = self.objs.monster(mi);
            if (m.present and m.is_boss) any_boss = true;
        }
        // $38e5 bit0 = can't run; $38ef moon
        if (any_boss or (bp.battle_flags & 0x01) != 0 or self.moon_ai) {
            return;
        }

        // Sum living party levels ($3540==0 slots) then mon levels → Div16 averages
        var party_sum: u16 = 0;
        var party_n: u16 = 0;
        var pi: usize = 0;
        while (pi < obj_mod.party_slots) : (pi += 1) {
            const p = self.objs.party(pi);
            if (!p.present) continue;
            party_sum +%= p.level;
            party_n +%= 1;
        }
        var mon_sum: u16 = 0;
        var mon_n: u16 = 0;
        mi = 0;
        while (mi < obj_mod.mon_slots) : (mi += 1) {
            const m = self.objs.monster(mi);
            if (!m.present) continue;
            mon_sum +%= m.level;
            mon_n +%= 1;
        }
        // Div16: avg = sum/count; 0 divisor → 0
        const avg_party: u8 = if (party_n == 0) 0 else @truncate(party_sum / party_n);
        const avg_mon: u8 = if (mon_n == 0) 0 else @truncate(mon_sum / mon_n);

        // $a9/$aa start at 1; RandXA(0,99) < avg_party → inc party score;
        // Rand99 (0..98 in ROM) < avg_mon → inc mon score.
        var party_score: u8 = 1;
        var mon_score: u8 = 1;
        if (self.rng.randXA(0, 99) < avg_party) party_score +%= 1;
        // Rand99: clr_ax; lda #98; jsr RandXA → 0..=98
        if (self.rng.randXA(0, 98) < avg_mon) mon_score +%= 1;

        if (party_score == mon_score) return;
        if (party_score > mon_score) {
            // First strike: $38d7=1, $38d8=1
            self.opener_flag = 1;
            self.timer_adv = 1;
            return;
        }
        // Surprise: $38d7=$80, $38d8=$80; maybe also back attack
        self.opener_flag = 0x80;
        self.timer_adv = 0x80;
        // if RandXA(0, avg_party) < avg_mon/2 → $3581=$08
        const half_mon: u8 = avg_mon >> 1;
        if (self.rng.randXA(0, avg_party) < half_mon) {
            self.back_attack = true;
        }
    }

    /// RestoreCharProp (win.asm @f18b): copy battle char block → field `$1000`.
    /// Always runs after battle (including NoUpdate); only WinUpdate is gated.
    pub fn syncPartyOut(self: *const Host, party: []state_mod.PartyMember) void {
        var i: usize = 0;
        while (i < party.len and i < obj_mod.party_slots) : (i += 1) {
            if (!party[i].present) continue;
            const o = self.objs.objs[i];
            if (!o.present) continue;
            // Use battle status as restored from `$38bf` (full s1/s2, not ClearWinStatus).
            const slot = party_sync_mod.slotFromBattle(
                o.hp,
                o.mp,
                o.max_hp,
                o.max_mp,
                o.level,
                o.left_hand,
                o.right_hand,
                o.status.s1,
                o.status.s2,
            );
            party[i].hp = slot.hp;
            party[i].mp = slot.mp;
            party[i].max_hp = slot.max_hp;
            party[i].max_mp = slot.max_mp;
            party[i].level = slot.level;
            party[i].left_hand = slot.left_hand;
            party[i].right_hand = slot.right_hand;
            party[i].status1 = slot.status1;
            party[i].status2 = slot.status2;
        }
    }

    /// True when WinUpdate should run (`$a8` bit4) — inverse of NoUpdateBattleTbl.
    pub fn shouldWinUpdate(self: *const Host) bool {
        return !self.no_party_update;
    }

    /// Apply ClearWinStatus masks for victory pose display (temporary).
    pub fn applyClearWinStatusForAnim(self: *Host) void {
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            const o = &self.objs.objs[i];
            if (!o.present) continue;
            o.status.s1 = party_sync_mod.clearWinStatus1(o.status.s1);
            o.status.s2 = party_sync_mod.clearWinStatus2(o.status.s2);
            o.status.s3 = 0;
            o.status.s4 = 0;
        }
    }

    /// Battle RNG as damage.Rng interface.
    pub fn battleRng(self: *Host) damage.Rng {
        return self.rng.asRng();
    }

    /// BattleSpeedTbl[setting]+1 (battle.asm @85d9). setting clamped 0..5.
    pub fn battleSpeedReload(r: ?*const rom_mod.Rom, setting: u8) u8 {
        const i: usize = @min(setting, offsets.en.battle_speed_tbl_len - 1);
        if (r) |rom| {
            if (rom.slice(offsets.en.battle_speed_tbl + i, 1)) |raw| {
                return raw[0] +% 1;
            } else |_| {}
        }
        // Embed: 0,1,3,5,7,10
        const tbl = [_]u8{ 0, 1, 3, 5, 7, 10 };
        return tbl[i] +% 1;
    }

    /// Apply config $16ac (0..5) mid-battle or at enter.
    pub fn setBattleSpeed(self: *Host, setting: u8) void {
        self.battle_speed = @min(setting, 5);
        self.speed_reload = battleSpeedReload(self.rom, self.battle_speed);
        self.speed_counter = self.speed_reload;
    }

    /// One NTSC field tick — BattleMain waits `speed_reload` frames then DecTimers/actions.
    ///
    /// ROM: only Wait-mode menu / pause ($38d9/$38da) freezes DecTimers. Graphics scripts
    /// (our `.animating`) and message holds still run the timer gate + DecTimers so mon ATB
    /// fills during party attack animations.
    pub fn tick(self: *Host, rng: damage.Rng) void {
        if (!self.active or self.phase == .done) return;
        if (self.flash > 0) self.flash -= 1;
        if (self.anim.hit_flash > 0) self.anim.hit_flash -= 1;
        if (self.boss_transition_wait > 0) self.boss_transition_wait -= 1;
        self.floaters.tick();

        // UpdateMonsterEntry (InitBtlGfx @8205) — before player input enabled.
        if (self.mon_entry_active) {
            self.tickMonEntry();
            // Still run anim/msg below only after entry ends; hold ATB while entering.
            if (self.mon_entry_active) return;
        }

        // Per-frame anim step (independent of ATB speed gate).
        if (self.phase == .animating) {
            self.tickAnim(rng);
            // After tickAnim may leave animating; fall through only for timer dec.
            // New actions still blocked while animating (below).
        }

        // Message hold counts every field (not gated by battle speed).
        // When timer hits 0: CloseMsgWindow (clear text) then resume — never leave
        // msg_len set after the hold or the chrome stays forever.
        if (self.phase == .message) {
            if (self.msg_timer > 0) {
                self.msg_timer -= 1;
            } else {
                self.clearMsg();
                if (self.end_flags.any()) {
                    self.phase = .done;
                    self.active = false;
                    return;
                } else if (self.dlg_queue_i < self.dlg_queue_n) {
                    // Next BattleDlg line (AIAction $F1/$F2 chain).
                    self.showNextDlg();
                    return;
                } else if (self.pending_mon_cmd != 0xFF) {
                    // Dialogue finished → execute deferred monster attack.
                    self.phase = .running;
                    self.finishPendingMonAction(rng);
                    return;
                } else {
                    self.phase = .running;
                }
            }
        }

        // Wait mode ($16be==0): PauseBattleWait freezes ATB while menu open.
        // Active mode ($16be==1): ATB continues; menu character is skipped.
        if (self.phase == .menu and self.isWaitMode()) return;

        // $3538 countdown (one dec per rendered frame)
        if (self.speed_counter > 0) self.speed_counter -= 1;
        if (self.speed_counter != 0) return;
        self.speed_counter = self.speed_reload;

        const tr = timer.decTimers(&self.objs);
        // Poison/doom floater (timer expire). Don't interrupt an in-progress anim.
        if (tr.dmg_slot) |ds| {
            const t = self.objs.get(ds);
            self.floaters.spawn(@intCast(t.centerX()), @intCast(t.centerY()), tr.dmg_amount, false, false);
            if (self.phase != .animating) {
                if (tr.dmg_kind == .poison) self.setMsg("Poison!");
                if (tr.dmg_kind == .doom) self.setMsg("Doom!");
                self.phase = .message;
                if (self.msg_timer == 0) self.msg_timer = self.msgDuration();
            }
        }
        // SapRegenEffect (timer.asm @a9ff): every other logic tick
        self.sap_regen_phase +%= 1;
        if (self.sap_regen_phase >= 2) {
            self.sap_regen_phase = 0;
            const sr = timer.sapRegenTick(&self.objs);
            if (sr.dmg_slot) |ds| {
                const t = self.objs.get(ds);
                self.floaters.spawn(@intCast(t.centerX()), @intCast(t.centerY()), sr.dmg_amount, false, false);
                if (self.phase != .message and self.phase != .animating) {
                    self.msg_len = 0;
                    self.msg_timer = 16;
                    self.phase = .message;
                }
            }
            // CheckRegen + party heal every 5 ticks while regen active
            self.tickRegen();
        }
        if (self.checkEnd()) return;

        // No new actions while a fight/death/victory anim or message hold is up.
        // (ROM GetPendingAction only re-enters the active graphics actor.)
        if (self.phase == .animating) return;
        if (self.phase == .message and self.msg_timer > 0) return;
        // Jump land → Jump2 fight
        if (tr.jump_land_slot) |js| {
            self.doJumpLand(js, rng);
            return;
        }

        // Active mode + menu open: skip the unit already selecting a command.
        var search_from = self.priority_slot;
        var attempts: usize = 0;
        const pend = while (attempts < obj_mod.total_slots) : (attempts += 1) {
            if (timer.getPendingAction(&self.objs, search_from)) |p| {
                if (self.phase == .menu and p == self.menu_slot) {
                    // Skip menu actor; try next
                    search_from = (p + 1) % obj_mod.total_slots;
                    continue;
                }
                break p;
            } else break null;
        } else null;
        const ready = pend orelse return;
        self.priority_slot = (ready + 1) % obj_mod.total_slots;
        const o = self.objs.get(ready);

        // Landing jump takes priority over menu
        if (o.status.isJumping() and o.jump_timer == 0) {
            self.doJumpLand(ready, rng);
            return;
        }

        // Twin charge complete → Cmd_20 resolve (not menu)
        if (o.status.isTwinCharging() and !o.is_monster) {
            o.action_ready = false;
            self.doTwinResolve(ready, rng);
            return;
        }

        // Focus1 complete → Cmd_1f Focus2 fight (cmd.asm @e826)
        if (o.status.isFocusing() and !o.is_monster) {
            o.action_ready = false;
            self.doFocusLand(ready, rng);
            return;
        }

        // GetCharAttack magic charge complete → cast stored spell (TimerDur_03 expired).
        if (!o.is_monster and ready < obj_mod.party_slots and self.charge_spell[ready] != 0xFF) {
            o.action_ready = false;
            const sid = self.charge_spell[ready];
            const tslot: usize = self.charge_target[ready];
            self.charge_spell[ready] = 0xFF;
            self.charge_target[ready] = 0xFF;
            self.menu_slot = ready;
            self.target_slot = tslot;
            self.resolvePartyMagic(sid, tslot, rng);
            return;
        }

        o.action_ready = false;

        if (!o.is_monster) {
            // Active mode: another party member ready while menu open — brief requeue
            if (self.phase == .menu) {
                o.action_timer = @max(o.base_timer, 8);
                o.action_ready = false;
                return;
            }
            self.menu_slot = ready;
            // Avenger sword $4C → berserk (char.asm AvengerEffect @a4c8)
            if (o.left_hand == 0x4C or o.right_hand == 0x4C) {
                o.status.setBerserk(true);
            }
            // Edward critical auto-hide (ForceCharActions @ab3a)
            if (self.tryEdwardCriticalHide(ready)) {
                self.requeue(o);
                return;
            }
            // ValidateChar: charm/berserk skip menu — auto physical
            if (o.status.isCharm()) {
                if (self.randomLivingAlly(ready, rng)) |t| {
                    self.target_slot = t;
                    self.startPartyFight(rng);
                } else {
                    self.requeue(o);
                }
                return;
            }
            if (o.status.isBerserk()) {
                if (self.objs.firstLivingMonster()) |t| {
                    self.target_slot = t;
                    self.startPartyFight(rng);
                } else {
                    self.requeue(o);
                }
                return;
            }
            // Auto-battle (char.asm @a4bb): no menu — GetAutoCmd drives the action.
            if (self.auto_battle.active) {
                self.menu_slot = ready;
                self.execAutoBattleStep(rng);
                return;
            }
            self.menu_mode = .command;
            self.menu_sel = 0;
            // GetCharAttack: zero run counter unless mon lv 97–99 (char.asm @a396)
            self.run_state.max_mon_level = cmd_run.maxLivingMonLevel(&self.objs);
            cmd_run.onCharMenuOpen(&self.run_state);
            // ClassCmd + DisableCmdStatusTbl (UpdateEnabledCmds)
            if (self.rom) |rom| {
                self.cmd_count = window.loadClassCommands(rom, o.class_id, &self.cmd_list);
                // Hidden: only Show available (Cmd_09 list rewrite)
                if (o.status.isHidden()) {
                    var hi: u8 = 0;
                    while (hi < self.cmd_count) : (hi += 1) {
                        if (self.cmd_list[hi] == CmdId.hide) self.cmd_list[hi] = CmdId.show;
                    }
                    self.cmd_list[0] = CmdId.show;
                    self.cmd_count = 1;
                } else {
                    self.cmd_count = cmd_enable.filterEnabledCmds(
                        self.cmd_list[0..],
                        self.cmd_count,
                        o.status.s1,
                        o.status.s2,
                        o.left_hand,
                        o.right_hand,
                    );
                }
                if (self.menu_sel >= self.cmd_count and self.cmd_count > 0)
                    self.menu_sel = self.cmd_count - 1;
            }
            if (self.objs.firstLivingMonster()) |t| self.target_slot = t;
            self.phase = .menu;
            return;
        }

        self.startMonFight(ready, rng);
    }

    /// GetAutoCmd @a4d9 + ValidateCmd — scripted party turn (no menu).
    fn execAutoBattleStep(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const step = self.auto_battle.nextStep(attacker.char_id);
        switch (step) {
            .fight => {
                if (self.objs.firstLivingMonster()) |t| {
                    self.target_slot = t;
                    self.startPartyFight(rng);
                } else {
                    self.requeue(attacker);
                }
            },
            .kick => self.execKick(rng),
            .twin => self.execTwin(rng),
            .magic => |spell_id| self.execAutoMagic(spell_id, rng),
            .item => |item_id| self.execAutoItem(item_id, rng),
            .command => |cmd| {
                // Map common auto-battle cmds; unknown → fight fallback.
                if (cmd == 0) {
                    if (self.objs.firstLivingMonster()) |t| {
                        self.target_slot = t;
                        self.startPartyFight(rng);
                    } else self.requeue(attacker);
                } else {
                    self.requeue(attacker);
                }
            },
        }
    }

    /// Auto-battle magic: cast spell_id at first living mon (GetAutoCmd $00 path, $da=$FF).
    /// MP free (magic.asm @ce28 skips cost when $388b set).
    fn execAutoMagic(self: *Host, spell_id: u8, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const rom = self.rom orelse {
            self.requeue(attacker);
            return;
        };
        const tslot = self.objs.firstLivingMonster() orelse self.menu_slot;
        self.target_slot = tslot;
        const mr = cmd_magic.doMagicEx(rom, spell_id, attacker, tslot, &self.objs, rng, self.mon_invincible != 0, true);
        self.recordHit(self.menu_slot, tslot, 0xC2, 0, mr.amount > 0 and !mr.missed);
        self.menu_mode = .command;
        if (mr.no_mp) {
            // Should not happen with free_mp; requeue safely.
            self.requeue(attacker);
            return;
        }
        if (mr.missed and mr.amount == 0) {
            self.setBattleMsg(battle_msg.MsgId.miss);
        } else {
            self.spawnMagicFloaters(mr);
            var nbuf: [12]u8 = undefined;
            const sname = cmd_magic.spellName(rom, spell_id, &nbuf);
            if (sname.len > 0) self.setMsg(sname) else {
                self.msg_len = 0;
                self.msg_timer = 20;
            }
        }
        self.flash = 6;
        self.requeue(attacker);
        self.phase = .message;
        _ = self.checkEnd();
    }

    /// Auto-battle item: use item_id from bag if present (GetAutoCmd $01 path).
    fn execAutoItem(self: *Host, item_id: u8, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const inv = self.inv orelse {
            self.requeue(attacker);
            return;
        };
        // Find bag slot with this id (intro battles stock fire bomb / lit-bolt first).
        var found: ?usize = null;
        var i: usize = 0;
        while (i < inv.slots.len) : (i += 1) {
            if (inv.slots[i].id == item_id and inv.slots[i].qty > 0) {
                found = i;
                break;
            }
        }
        if (found == null) {
            // Script expects the item — grant one so auto-battles still play.
            _ = inv.give(item_id);
            i = 0;
            while (i < inv.slots.len) : (i += 1) {
                if (inv.slots[i].id == item_id and inv.slots[i].qty > 0) {
                    found = i;
                    break;
                }
            }
        }
        if (found) |slot| {
            self.item_slot = slot;
            self.target_slot = self.objs.firstLivingMonster() orelse self.menu_slot;
            self.menu_mode = .item;
            self.execItem(rng);
        } else {
            self.requeue(attacker);
        }
    }

    /// ForceCharActions Edward path: critical (HP < max/4) + not boss + allies alive → Hide.
    fn tryEdwardCriticalHide(self: *Host, slot: usize) bool {
        const o = self.objs.get(slot);
        // char id / class 5 = Edward (Bard)
        if (o.char_id != 0x05 and o.class_id != 0x05) return false;
        // Boss battle: $3582 — any mon is_boss
        var any_boss = false;
        var mi: usize = 0;
        while (mi < obj_mod.mon_slots) : (mi += 1) {
            const m = self.objs.monster(mi);
            if (m.present and m.is_boss) any_boss = true;
        }
        if (any_boss) return false;
        if (!timer.isCriticalHp(o.hp, o.max_hp)) return false;
        if (o.status.isHidden()) return false;
        // Alone: don't hide
        var living_party: u8 = 0;
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            const p = self.objs.objs[i];
            if (p.present and p.hp > 0 and !p.status.isKo()) living_party += 1;
        }
        if (living_party <= 1) return false;
        o.status.setHide(true);
        // Swap Hide → Show in command list when next opened
        self.setMsg("Hide");
        self.phase = .message;
        return true;
    }

    /// CheckRegen + party heal (timer.asm SapRegen @aa85 / battle.asm @ffb4).
    fn tickRegen(self: *Host) void {
        // Disable if Fusoya ($13) present but KO/control
        var fi: usize = 0;
        while (fi < obj_mod.party_slots) : (fi += 1) {
            const f = self.objs.objs[fi];
            if (!f.present) continue;
            if (f.char_id != 0x13 and f.class_id != 0x13) continue;
            if (f.status.isKo() or (f.status.s2 & status_mod.Status2.control) != 0) {
                self.regen_counter = 0xFF;
            }
            break;
        }
        if (self.regen_counter == 0xFF) return;
        self.regen_counter +%= 1;
        if (self.regen_counter < 5) return;
        self.regen_counter = 0;
        timer.partyRegenHeal(&self.objs, self.regen_hp);
    }

    /// Cmd_19 Regen (cmd.asm @e3fd): enable party regen 10 HP / 5 ticks.
    fn execRegen(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        self.regen_counter = 0;
        self.regen_hp = 10;
        self.retal_disabled = true; // inc $390a during setup
        // Pending end-regen is Cmd_22 after a long timer in ROM; we keep regen until Fusoya KO / battle end
        self.retal_disabled = false;
        self.setMsg("Regen");
        self.phase = .message;
        self.requeue(attacker);
    }

    /// Resolve Jump2 land target: keep Jump1 `$ce` if still valid, else Retarget mon.
    fn resolveJumpLandTarget(self: *Host, stored: u8) ?usize {
        if (stored != 0xFF and stored < obj_mod.total_slots) {
            const t = self.objs.objs[stored];
            if (cmd_special_mod.jumpLandTargetOk(
                t.present,
                t.hp,
                t.status.isKo(),
                t.status.isJumping(),
                t.status.isHidden(),
            )) return stored;
        }
        // attack.asm Retarget: first living mon (party→mon jump)
        var i: usize = obj_mod.party_slots;
        while (i < obj_mod.total_slots) : (i += 1) {
            const t = self.objs.objs[i];
            if (cmd_special_mod.jumpLandTargetOk(
                t.present,
                t.hp,
                t.status.isKo(),
                t.status.isJumping(),
                t.status.isHidden(),
            )) return i;
        }
        return null;
    }

    /// Cmd_1e Jump2 (@e9a5): DoFightCmd **while** $2005 jump bit set, then clear.
    fn doJumpLand(self: *Host, slot: usize, rng: damage.Rng) void {
        const o = self.objs.get(slot);
        o.jump_timer = 0;
        const stored = o.jump_target;
        o.jump_target = 0xFF;
        const tslot = self.resolveJumpLandTarget(stored) orelse {
            // No valid target (all dead): clear jump, restore action (Cmd_1e still clears status).
            o.status.setJumping(false);
            self.requeue(o);
            return;
        };
        // Jump still set during DoFightCmd → 2× ATK + no row penalty (fight.asm @c510/@c6d7).
        const tgt = self.objs.get(tslot);
        const fr = cmd_fight.calcFightEx(o, tgt, rng, .{ .mon_invincible = self.mon_invincible != 0 });
        o.status.setJumping(false); // Cmd_1e AND #$FD after fight
        self.pending_status_s1 = fr.status_s1;
        self.pending_status_s2 = fr.status_s2;
        self.anim = .{
            .kind = if (o.is_monster) .mon_fight else .party_fight,
            .t = 0,
            .attacker = slot,
            .target = tslot,
            .damage = fr.damage,
            .missed = fr.missed,
            .crit = fr.crit,
            .char_pose = .left_arm_up,
        };
        self.phase = .animating;
    }

    /// Cmd_06 Jump1 (@e957): set jump status, arm action timer duration 4, pending Jump2.
    fn execJump1(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        const t = self.target_slot;
        if (t >= obj_mod.total_slots) {
            self.queueSysSfx(audio_mod.sys_sfx_error);
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        const tgt = self.objs.get(t);
        if (!cmd_special_mod.jumpTargetsLegal(attacker.is_monster, tgt.is_monster) or
            !cmd_special_mod.jumpLandTargetOk(tgt.present, tgt.hp, tgt.status.isKo(), tgt.status.isJumping(), tgt.status.isHidden()))
        {
            self.queueSysSfx(audio_mod.sys_sfx_error);
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Cmd_06 @e96c: inc $390a (no retal on takeoff script).
        // Jump status + action timer duration 4 (hardcoded, no ApplySpeedMod).
        attacker.status.setJumping(true);
        const air = cmd_special_mod.jump1HostTicks();
        attacker.jump_timer = air;
        attacker.jump_target = @intCast(t);
        attacker.action_ready = false;
        // ROM only enables action timer while airborne (`#$40` mask). Host uses jump_timer.
        attacker.action_timer = 0;
        // ShowMsg_02 → DrawAttackNameWindow (right): BattleCmdName "Jump".
        if (self.rom) |r| {
            var nbuf: [12]u8 = undefined;
            const cname = window.commandName(r, CmdId.jump, &nbuf);
            if (cname.len > 0) {
                self.setAttackNameMsg(cname);
            } else {
                // Brief silent takeoff hold (CmdAnim_06 fly-up residual).
                self.clearMsg();
                self.msg_timer = 12;
            }
        } else {
            self.clearMsg();
            self.msg_timer = 12;
        }
        self.phase = .message;
        self.queueSysSfx(audio_mod.sys_sfx_confirm);
    }

    /// Cmd_1f Focus2: DoFightCmd with focus bit still set for 2× ATK, then clear.
    fn doFocusLand(self: *Host, slot: usize, rng: damage.Rng) void {
        const o = self.objs.get(slot);
        o.jump_timer = 0;
        const tslot = self.objs.firstLivingMonster() orelse {
            o.status.setFocusing(false);
            self.requeue(o);
            return;
        };
        // Keep focusing for calcFightEx (fight.asm @c6d7 and #$0a)
        const tgt = self.objs.get(tslot);
        const fr = cmd_fight.calcFightEx(o, tgt, rng, .{ .mon_invincible = self.mon_invincible != 0 });
        o.status.setFocusing(false); // Cmd_1f AND #$F7
        self.pending_status_s1 = fr.status_s1;
        self.pending_status_s2 = fr.status_s2;
        self.anim = .{
            .kind = .party_fight,
            .t = 0,
            .attacker = slot,
            .target = tslot,
            .damage = fr.damage,
            .missed = fr.missed,
            .crit = fr.crit,
            .char_pose = .left_arm_up,
        };
        self.phase = .animating;
    }

    /// Cmd_0d Focus1: charge timer, set $2005 bit3; Focus2 when action timer expires.
    fn execFocus(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        if (!cmd_special_mod.focus1Ready(attacker.present, attacker.hp)) {
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Cmd_0d @e7f3: $397b=$1f, TimerDur_0c (CmdDelayTbl[$1f]=$82 → 2× base_timer).
        attacker.status.setFocusing(true);
        const charge = timer_dur.cmdDelayHostTicks(0x1F, attacker.base_timer, attacker.speed_mod);
        attacker.action_timer = charge;
        attacker.action_ready = false;
        self.msg_len = 0;
        self.msg_timer = 16;
        self.phase = .message;
        // Focus2 when unit becomes ready again while still focusing
    }

    /// Cmd_0a Salve: consume Cure ($CE) from bag, DoMagicAttack as item Cure.
    fn execSalve(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const inv = self.inv orelse {
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(attacker);
            return;
        };
        var found: ?usize = null;
        var i: usize = 0;
        while (i < inv.slots.len) : (i += 1) {
            if (cmd_special_mod.salveHasCure(inv.slots[i].id, inv.slots[i].qty)) {
                found = i;
                break;
            }
        }
        if (found == null) {
            // BattleMsg $0f — no item / failed
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Consume one Cure
        const slot = found.?;
        if (inv.slots[slot].qty > 1) inv.slots[slot].qty -%= 1 else {
            inv.slots[slot] = .{};
        }
        if (self.rom) |rom| {
            // DoMagicAttack with spell id = item $CE effects via item path
            const mr = cmd_magic.doMagicEx(rom, cmd_special_mod.salve_item_id, attacker, self.menu_slot, &self.objs, rng, false, true);
            self.spawnMagicFloaters(mr);
        }
        self.flash = 4;
        self.msg_len = 0;
        self.msg_timer = 24;
        self.phase = .message;
        self.requeue(attacker);
    }

    /// Cmd_0f Brace: DoMagicAttack spell $05 (Armor/Barrier) on self (cmd.asm @e699).
    fn execBrace(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        if (self.rom) |rom| {
            const mr = cmd_magic.doMagic(rom, cmd_special_mod.brace_spell_id, attacker, self.menu_slot, &self.objs, rng);
            self.spawnMagicFloaters(mr);
        }
        // ROM AddMsg3 $3a after cast (often "no effect" text even when armor applied)
        self.setBattleMsg(battle_msg.MsgId.nothing_happened);
        self.flash = 4;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn tickAnim(self: *Host, rng: damage.Rng) void {
        _ = rng;
        if (self.anim.spark_t > 0) self.anim.spark_t -= 1;
        if (self.anim.hit_pose_timer > 0) self.anim.hit_pose_timer -= 1;
        self.anim.t +%= 1;
        switch (self.anim.kind) {
            .none => {
                self.phase = .running;
            },
            .party_fight => self.tickPartyFight(),
            .mon_fight => self.tickMonFight(),
            .mon_death => self.tickMonDeath(),
            .victory => self.tickVictory(),
            .gfx_script => self.tickGfxScript(),
        }
    }

    /// Begin BtlGfx_05 ExecGfxScript on a copied buffer (attack.asm $33c2).
    pub fn beginGfxScript(self: *Host, script: []const u8) void {
        const n = @min(script.len, self.gfx_script_buf.len);
        if (n > 0) @memcpy(self.gfx_script_buf[0..n], script[0..n]);
        self.gfx_script_len = n;
        self.gfx_vm.start(self.gfx_script_buf[0..n]);
        self.anim = .{
            .kind = .gfx_script,
            .t = 0,
            .char_pose = .chant1,
        };
        self.phase = .animating;
    }

    /// Party ExecCmd prefix (attack.asm @b11c): $F8,$02, cmd+$C0, …
    /// `magic_id`: attack/spell id for DoMagicAnim ($00–$A8); `$FF` = omit (fight-only).
    pub fn buildPartyCmdGfxScript(cmd: u8, magic_id: u8, out: *[16]u8) usize {
        var n: usize = 0;
        out[n] = 0xF8;
        n += 1;
        out[n] = 0x02; // ShowMsg_02 attack name
        n += 1;
        out[n] = 0xC0 +% cmd; // DoCmdAnim
        n += 1;
        if (magic_id != 0xFF) {
            // DoMagicAnim reads this byte as attack id (not AnimProp.script / $f397).
            out[n] = magic_id;
            n += 1;
        }
        out[n] = 0xF8;
        n += 1;
        out[n] = 0x04; // ShowMsg_04 damage numerals
        n += 1;
        out[n] = 0xFF;
        n += 1;
        return n;
    }

    /// AI $F1/$F2 chain → gfx script F1/F2 + ids + FF (for Vm wait / dialogue).
    pub fn buildDlgGfxScript(dlg_ids: []const u8, slow: bool, out: *[32]u8) usize {
        var n: usize = 0;
        for (dlg_ids) |id| {
            if (id == 0xFF) break;
            if (n + 3 > out.len) break;
            out[n] = if (slow) 0xF1 else 0xF2;
            n += 1;
            out[n] = id;
            n += 1;
        }
        if (n < out.len) {
            out[n] = 0xFF;
            n += 1;
        }
        return n;
    }

    fn tickGfxScript(self: *Host) void {
        if (!self.gfx_vm.active()) {
            self.anim.kind = .none;
            self.phase = .running;
            return;
        }
        // Chant pose during magic/cmd anim tokens
        if (self.anim.attacker < obj_mod.party_slots) {
            self.anim.char_pose = if ((self.anim.t & 4) == 0) .chant1 else .chant2;
        }
        const e = self.gfx_vm.tick(self.msg_speed);
        if (e) |effect| {
            self.applyGfxEffect(effect);
        }
        // Mirror boss frames / darken from Vm state every tick
        @memcpy(&self.boss_frame, &self.gfx_vm.boss_frame);
        self.bg_darken = self.gfx_vm.darken;
        if (self.gfx_vm.song_id) |sid| {
            // GfxScript `$F3` mid-fight song (btlgfx DoGfxScriptCmd).
            self.setSong(sid);
        }
        if (!self.gfx_vm.active()) {
            self.anim.kind = .none;
            // MagicAnim_2f etc.: LightenBattleBG after WaitX
            if (self.bg_darken) self.bg_darken = false;
            // If numerals were shown, keep floaters; return to running.
            if (!self.end_flags.any()) self.phase = .running;
        }
    }

    fn applyGfxEffect(self: *Host, effect: gfx_script_mod.Effect) void {
        switch (effect) {
            .dialogue => |d| {
                var buf: [96]u8 = undefined;
                if (self.rom) |rom| {
                    const text = battle_dlg.load(rom, d.id, &buf);
                    if (text.len > 0) self.setMsg(text);
                }
                // Wait is owned by Vm; also set msg_timer for draw.
                const wait = gfx_script_mod.dialogueWaitFrames(d.slow, self.msg_speed);
                self.msg_timer = @intCast(@min(wait, 255));
            },
            .song => |id| {
                self.setSong(id);
            },
            .boss_frame => |bf| {
                // ChangeBossFrame @cca8: store `$f2b4,y` + BossTransition from prop byte3.
                boss_frame_mod.applyFrame(&self.boss_frame, bf.mon_slot, bf.frame);
                if (self.rom) |rom| {
                    const off = boss_frame_mod.bossGfxPropOffset(bf.frame);
                    if (rom.slice(off, 5)) |bp5| {
                        const tr = boss_frame_mod.transitionFromBossPropByte3(bp5[3]);
                        self.boss_transition_wait = boss_frame_mod.transitionWaitFrames(tr);
                        if (tr == .flash) self.queueSfx(boss_frame_mod.flash_sfx);
                        if (tr == .flash or tr == .shake) self.flash = @max(self.flash, 8);
                    } else |_| {}
                }
            },
            .darken_bg => |d| {
                self.bg_darken = !d.lighten;
            },
            .cmd_anim => |id| {
                // Fight cmd $C0 → left_arm_up pose (CmdAnim_00 subset).
                if (id == 0xC0) self.anim.char_pose = .left_arm_up;
            },
            .magic_anim => |mid| {
                // DoMagicAnim: resolve AnimProp + MagicAnimTbl; AnimProp.script → ExecAnimScript header.
                self.anim.char_pose = if (self.anim.t & 4 == 0) .chant1 else .chant2;
                if (self.rom) |rom| {
                    const present = magic_anim_mod.resolve(rom, mid);
                    if (present.flags.darken_bg) self.bg_darken = true;
                    if (present.flags.lighten_bg and present.flags.wait_frames == 0) self.bg_darken = false;
                    if (present.flags.screen_flash) self.flash = @max(self.flash, 10);
                    if (present.flags.hide_chars) {
                        self.anim.char_pose = .standing;
                    }
                    var wait = present.flags.wait_frames;
                    // DefaultMagicAnim: AnimProp.script id → ExecAnimScript header wait (BG6).
                    if (present.flags.use_anim_script and present.prop.script != 0xFF and
                        anim_script_mod.validScriptId(present.prop.script))
                    {
                        // Load real AnimScript header from ROM (magic.asm ExecAnimScript @f6ea).
                        if (anim_script_mod.loadHeader(rom, present.prop.script)) |hdr| {
                            wait = @max(wait, hdr.host_wait_frames);
                        } else {
                            const hdr = anim_script_mod.decodeHeader(0x00, 0x00);
                            wait = @max(wait, hdr.host_wait_frames);
                        }
                    }
                    if (wait > 0) self.gfx_vm.wait = wait;
                }
            },
            .show_msg => |mt| {
                // ShowMsg_00..04 (show_msg.zig / btlgfx @c97f).
                // Type 4: floaters already spawned at impact. Type 2/3: text set by attack path.
                // Classify for residual chrome (windowKind) and suppress text window on numerals.
                const smt: show_msg_mod.MsgType = switch (mt) {
                    .attacker_name => .attacker_name,
                    .target_name => .target_name,
                    .attack_name => .attack_name,
                    .battle_msg => .battle_msg,
                    .damage_numerals => .damage_numerals,
                };
                if (show_msg_mod.windowKind(smt) == .numerals_only) {
                    // DrawDmgNumerals only — clear any accidental full message window.
                    // (msg_timer may still hold for floater lifetime.)
                }
            },
            .end, .special_anim, .skipped => {},
        }
    }

    /// CmdAnim_00 → StepForwardToAttack + DoFightAnim / WeaponHitAnim (fight_anim.zig).
    fn tickPartyFight(self: *Host) void {
        const t = self.anim.t;
        const phase = fight_anim_mod.phaseAt(t);
        self.anim.char_pose = fight_anim_mod.partyFightPose(t);
        self.anim.char_dx = fight_anim_mod.partyFightDx(t);
        if (t == fight_anim_mod.impactFrame()) {
            self.applyPendingHit();
        }
        if (phase == .done) {
            self.anim.char_dx = 0;
            self.anim.char_pose = .standing;
            self.finishFightAnim(self.battleRng());
        }
    }

    fn tickMonFight(self: *Host) void {
        const t = self.anim.t;
        // lunge right toward party
        if (t <= 6) {
            self.anim.mon_dx = @intCast(t * 2);
            return;
        }
        if (t <= 12) {
            self.anim.mon_dx = 12;
            if (t == 8) self.applyPendingHit();
            return;
        }
        if (t <= 18) {
            self.anim.mon_dx = @as(i8, 12) - @as(i8, @intCast((t - 12) * 2));
            return;
        }
        self.anim.mon_dx = 0;
        self.finishFightAnim(self.battleRng());
    }

    fn applyPendingHit(self: *Host) void {
        const tgt = self.objs.get(self.anim.target);
        // Floater / spark at sprite center (ShowMsg_04 near target).
        const sx: i16 = @intCast(tgt.centerX());
        const sy: i16 = @intCast(tgt.centerY());

        // ShowMsg_04 = damage numerals only (DrawDmgNumerals) — not a text window.
        // Image peel already applied in calcFight; miss only shows Miss numerals.
        if (self.anim.missed) {
            self.floaters.spawn(sx, sy, 0, true, false);
            return;
        }

        if (tgt.present and tgt.hp > 0 and self.anim.damage > 0) {
            if (tgt.hp > self.anim.damage) tgt.hp -= self.anim.damage else {
                tgt.hp = 0;
                tgt.status.setDead();
            }
            self.anim.target_died = tgt.hp == 0;
            tgt.status.clearCharm();
            // Weapon status inflict (fight.asm ApplyAttackStatus)
            if (self.pending_status_s1 != 0)
                _ = tgt.status.applyStatus1(self.pending_status_s1, tgt.immune_s1);
            if (self.pending_status_s2 != 0)
                _ = tgt.status.applyStatus2(self.pending_status_s2, tgt.immune_s2);
            const atk = self.objs.get(self.anim.attacker);
            self.recordHit(self.anim.attacker, self.anim.target, 0xC0, atk.attack_element, true);
            self.pending_status_s1 = 0;
            self.pending_status_s2 = 0;
        }
        self.floaters.spawn(sx, sy, self.anim.damage, false, self.anim.crit);
        // WeaponHitAnim (@d0a4): `$4e` 0→$10 (16 frames) + CritFlash + sfx $2a if not miss.
        // LoadWeaponAnim: right then left hand; ignore shields ≥ $60 (DoFightAnim @d007).
        {
            const atk = self.objs.get(self.anim.attacker);
            const wid = fight_anim_mod.pickWeaponItem(atk.right_hand, atk.left_hand);
            if (self.rom) |r| {
                self.scene.hit_gfx.loadForWeapon(r, wid);
            }
            self.anim.hit_frame_row = self.scene.hit_gfx.frame_row;
        }
        self.anim.hit_flash = fight_anim_mod.weapon_hit_frames;
        self.flash = fight_anim_mod.critFlashFrames(self.anim.crit);
        if (fight_anim_mod.shouldPlayHitSfx(self.anim.missed)) {
            self.queueSfx(audio_mod.sfx_weapon_hit);
        }
        self.anim.spark_t = fight_anim_mod.weapon_hit_frames;
        self.anim.spark_x = sx;
        self.anim.spark_y = sy;
        if (!tgt.is_monster) {
            // UpdateHitCharPose duration matches WeaponHitAnim loop
            self.anim.hit_pose_timer = fight_anim_mod.weapon_hit_frames;
            self.anim.hit_pose_slot = self.anim.target;
        }
        // Brief hold for floaters / hit flash — no message window text.
        self.msg_timer = fight_anim_mod.weapon_hit_frames +% 8;
    }

    fn finishFightAnim(self: *Host, rng: damage.Rng) void {
        const attacker_slot = self.anim.attacker;
        const target_slot = self.anim.target;
        const missed = self.anim.missed;
        const party_hit_mon = !self.objs.objs[attacker_slot].is_monster and
            target_slot >= obj_mod.party_slots and !missed and self.anim.damage > 0;

        const attacker = self.objs.get(attacker_slot);
        self.requeue(attacker);

        // Queue MonsterDeathAnim for any monsters that just hit 0 HP.
        // $38e4 delay_mon_death (Mist Dragon effect $35) defers dissolve.
        var death_mask: u8 = 0;
        var i: usize = obj_mod.party_slots;
        while (i < obj_mod.total_slots) : (i += 1) {
            const o = self.objs.objs[i];
            if (o.present and o.hp == 0 and o.is_monster) {
                const mi: u3 = @intCast(i - obj_mod.party_slots);
                death_mask |= @as(u8, 1) << mi;
            }
        }
        if (death_mask != 0) {
            if (self.delay_mon_death > 0) {
                self.delay_mon_death -%= 1;
                // Dead mons stay present until delay expires (no dissolve yet)
            } else {
                self.anim = .{
                    .kind = .mon_death,
                    .t = 0,
                    .death_mask = death_mask,
                    .death_t = 0,
                };
                self.phase = .animating;
                return;
            }
        }

        // DoRetal (retal.asm @c16c): after party hits mon(s); skipped if multi $3877 or delay death.
        if (party_hit_mon and !self.retal_disabled and self.delay_mon_death == 0) {
            if (self.tryDoRetal(target_slot, attacker_slot, rng)) {
                return;
            }
        }

        self.anim = .{};
        // Only open DrawFullMsgWindow when there is real text (BattleMsg / BattleDlg).
        // Hits use ShowMsg_04 numerals + a short msg_timer hold without the window.
        if (self.msg_len > 0) {
            self.phase = .message;
            if (self.msg_timer == 0) self.msg_timer = 30;
        } else if (self.msg_timer > 0) {
            self.phase = .message; // timer-only hold (no chrome if msg_len==0)
        } else {
            self.phase = .running;
        }
        _ = self.checkEnd();
    }

    /// MonsterDeathAnim @e9a9 — 48 frames ($30) dissolve then hide.
    fn tickMonDeath(self: *Host) void {
        self.anim.death_t = self.anim.t;
        // $30 frames
        if (self.anim.t < 0x30) return;

        // Remove dead monsters (mark not present).
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            if ((self.anim.death_mask & (@as(u8, 1) << @intCast(i))) == 0) continue;
            const slot = obj_mod.party_slots + i;
            self.objs.objs[slot].present = false;
            self.objs.objs[slot].hp = 0;
        }

        if (self.objs.livingMonsters() == 0) {
            self.end_flags.victory = true;
            const fanfare = battle_song_mod.victorySongId(self.battle_id, self.battle_flags);
            if (fanfare != 0xFF) {
                self.setSong(fanfare);
            } else if (battle_song_mod.noBattleMusic(self.battle_flags)) {
                self.setSong(audio_mod.battle_song_none);
            }
            if (self.no_win_anim or battle_song_mod.shouldSkipWinAnim(self.battle_id)) {
                self.anim = .{};
                self.msg_len = 0;
                self.msg_timer = 12;
                self.phase = .message;
            } else {
                self.anim = .{
                    .kind = .victory,
                    .t = 0,
                    .char_pose = .victory,
                };
                self.setBattleMsg(battle_msg.MsgId.won);
                self.msg_timer = 50;
                self.phase = .animating;
            }
            return;
        }

        self.anim = .{};
        self.phase = .message;
        if (self.msg_timer == 0) self.msg_timer = 30;
    }

    fn tickVictory(self: *Host) void {
        self.anim.char_pose = .victory;
        // Hold victory pose through message timer.
        if (self.msg_timer > 0) {
            self.msg_timer -= 1;
            return;
        }
        self.anim = .{};
        self.phase = .done;
        self.active = false;
    }

    fn startPartyFight(self: *Host, rng: damage.Rng) void {
        self.startPartyFightEx(rng, false);
    }

    fn startPartyFightAim(self: *Host, rng: damage.Rng) void {
        self.startPartyFightEx(rng, true);
    }

    fn startPartyFightEx(self: *Host, rng: damage.Rng, aim: bool) void {
        const attacker = self.objs.get(self.menu_slot);
        // Cover redirect: if target is covered, hit the coverer (Cmd_13).
        var tslot = self.target_slot;
        const raw_t = self.objs.get(tslot);
        if (raw_t.cover_by != 0xFF) {
            const c = self.objs.get(raw_t.cover_by);
            if (c.present and c.hp > 0) tslot = raw_t.cover_by;
        }
        // attack.asm @af06: jumping/hiding targets are invalid → Retarget.
        {
            const cand = self.objs.get(tslot);
            if (!cmd_special_mod.jumpLandTargetOk(
                cand.present,
                cand.hp,
                cand.status.isKo(),
                cand.status.isJumping(),
                cand.status.isHidden(),
            )) {
                tslot = self.objs.firstLivingMonster() orelse {
                    self.setBattleMsg(battle_msg.MsgId.nothing_happened);
                    self.phase = .message;
                    self.requeue(attacker);
                    return;
                };
            }
        }
        const tgt = self.objs.get(tslot);
        self.target_slot = tslot;
        const fr = cmd_fight.calcFightEx(attacker, tgt, rng, .{
            .aim = aim,
            .mon_invincible = self.mon_invincible != 0,
        });
        self.pending_status_s1 = fr.status_s1;
        self.pending_status_s2 = fr.status_s2;
        self.anim = .{
            .kind = .party_fight,
            .t = 0,
            .attacker = self.menu_slot,
            .target = self.target_slot,
            .damage = fr.damage,
            .missed = fr.missed,
            .crit = fr.crit,
            .char_pose = .ready,
        };
        self.phase = .animating;
    }

    fn execKick(self: *Host, rng: damage.Rng) void {
        self.execMultiPhys(rng, false);
    }

    fn execDark(self: *Host, rng: damage.Rng) void {
        // Cmd_05 Dark Wave: costs HP (max/8) then multi-attack full power
        const attacker = self.objs.get(self.menu_slot);
        var cost: u16 = attacker.max_hp >> 3;
        if (cost < 1) cost = 1;
        if (attacker.hp > cost) attacker.hp -= cost else {
            attacker.hp = 0;
            attacker.status.setDead();
        }
        self.floaters.spawn(@intCast(attacker.centerX()), @intCast(attacker.centerY()), cost, false, false);
        self.execMultiPhys(rng, true);
    }

    fn execMultiPhys(self: *Host, rng: damage.Rng, dark: bool) void {
        const attacker = self.objs.get(self.menu_slot);
        var slots: [8]usize = undefined;
        var dmgs: [8]u16 = undefined;
        const n = if (dark)
            cmd_fight.doDarkWave(attacker, &self.objs, rng, &slots, &dmgs)
        else
            cmd_fight.doKick(attacker, &self.objs, rng, &slots, &dmgs);
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const t = self.objs.get(slots[i]);
            self.floaters.spawn(@intCast(t.centerX()), @intCast(t.centerY()), dmgs[i], false, false);
            // AddRetal per mon hit (kick/dark multi)
            if (dmgs[i] > 0) {
                self.recordHit(self.menu_slot, slots[i], 0xC0, attacker.attack_element, true);
            }
        }
        self.flash = 8;
        self.msg_len = 0;
        self.msg_timer = 30;
        self.phase = .message;
        self.requeue(attacker);
        _ = self.checkEnd();
    }

    fn execPray(self: *Host, rng: damage.Rng) void {
        // Cmd_0b: Rand < $80 → Cure2 $0E; else fail (cmd.asm @e855)
        const attacker = self.objs.get(self.menu_slot);
        if (!cmd_special_mod.praySucceeds(rng.next())) {
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        if (self.rom) |rom| {
            const saved = attacker.mp;
            const mr = cmd_magic.doMagic(rom, cmd_special_mod.pray_spell_id, attacker, self.menu_slot, &self.objs, rng);
            attacker.mp = saved;
            self.spawnMagicFloaters(mr);
            self.msg_len = 0;
            self.msg_timer = 28;
        }
        self.flash = 4;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn execBluff(self: *Host) void {
        // Cmd_11 (cmd.asm @eac6): intellect ($2017) += $10, max $63; AddMsg2 $12.
        const attacker = self.objs.get(self.menu_slot);
        const next: u16 = @as(u16, attacker.intellect) +% 0x10;
        attacker.intellect = if (next > 0x63) 0x63 else @intCast(next);
        // ShowMsg / AddMsg2 index $12 — command feedback from BattleMsg if present.
        self.setBattleMsg(0x12);
        self.msg_timer = 20;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn execCry(self: *Host) void {
        // Cmd_12: monsters with (level+10) ≤ (caster_level+10)/2 → level = 1
        const attacker = self.objs.get(self.menu_slot);
        const thresh: u16 = (@as(u16, attacker.level) +% 10) / 2;
        var i: usize = obj_mod.party_slots;
        while (i < obj_mod.total_slots) : (i += 1) {
            const m = self.objs.get(i);
            if (!m.present or m.hp == 0) continue;
            const ml: u16 = @as(u16, m.level) +% 10;
            if (ml <= thresh) m.level = 1;
        }
        self.msg_len = 0;
        self.msg_timer = 24;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn execRecall(self: *Host, rng: damage.Rng) void {
        // Cmd_07 (cmd.asm @ea1d): RandXA(0, $a0); thresholds pick spell or fail msg $09
        const attacker = self.objs.get(self.menu_slot);
        const roll = rng.next() % 0xA1; // 0..=$a0
        const spell: u8 = if (roll < 0x08)
            0x2A
        else if (roll < 0x10)
            0x26
        else if (roll < 0x18)
            0x27
        else if (roll < 0x20)
            0x2B
        else if (roll < 0x38)
            0x1D
        else if (roll < 0x50)
            0x20
        else if (roll < 0x68)
            0x23
        else if (roll < 0x80)
            0x19
        else {
            // BattleMsg $09 — nothing / failed recall
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        };
        const tslot = self.objs.firstLivingMonster() orelse self.menu_slot;
        if (self.rom) |rom| {
            // Check MP without double-spending on fail
            if (cmd_magic.loadSpell(rom, spell)) |sp| {
                if (attacker.mp < sp.mp_cost) {
                    self.setBattleMsg(battle_msg.MsgId.not_enough_mp);
                    self.phase = .message;
                    self.requeue(attacker);
                    return;
                }
            }
            const mr = cmd_magic.doMagic(rom, spell, attacker, tslot, &self.objs, rng);
            if (mr.no_mp) {
                self.setBattleMsg(battle_msg.MsgId.not_enough_mp);
            } else if (mr.missed) {
                self.setBattleMsg(battle_msg.MsgId.miss);
            } else {
                self.spawnMagicFloaters(mr);
                // ShowMsg_02: attack/spell name in message window (btlgfx.asm @cb98).
                var nbuf: [12]u8 = undefined;
                const sname = cmd_magic.spellName(rom, spell, &nbuf);
                self.setMsg(sname);
            }
        }
        self.flash = 6;
        self.phase = .message;
        self.requeue(attacker);
        _ = self.checkEnd();
    }

    fn execTwin(self: *Host, rng: damage.Rng) void {
        // Cmd_10 (cmd.asm @e441): partner from $3539 twin pair table
        _ = rng;
        const attacker = self.objs.get(self.menu_slot);
        const partner: ?usize = blk: {
            // Prefer registered twin pair
            if (self.twin_pair[0] == self.menu_slot and self.twin_pair[1] < obj_mod.party_slots)
                break :blk self.twin_pair[1];
            if (self.twin_pair[1] == self.menu_slot and self.twin_pair[0] < obj_mod.party_slots)
                break :blk self.twin_pair[0];
            // Fallback: any valid ally (if pair table empty)
            var i: usize = 0;
            while (i < obj_mod.party_slots) : (i += 1) {
                if (i == self.menu_slot) continue;
                const a = self.objs.objs[i];
                if (cmd_special_mod.twinPartnerOk(a.status, a.present, a.hp)) break :blk i;
            }
            break :blk null;
        };
        if (partner) |ps| {
            const a = self.objs.objs[ps];
            if (!cmd_special_mod.twinPartnerOk(a.status, a.present, a.hp)) {
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
                return;
            }
        } else {
            self.setBattleMsg(battle_msg.MsgId.failed); // TwinFailed $11
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Cmd_10 @e441: $397b=$20, TimerDur_0c (CmdDelayTbl[$20]=$81 → 1× base_timer).
        const charge_a = timer_dur.cmdDelayHostTicks(0x20, attacker.base_timer, attacker.speed_mod);
        attacker.status.setTwin(true);
        attacker.jump_target = @intCast(partner.?); // reuse: twin partner slot
        attacker.action_timer = charge_a;
        attacker.action_ready = false;
        const p = self.objs.get(partner.?);
        const charge_p = timer_dur.cmdDelayHostTicks(0x20, p.base_timer, p.speed_mod);
        p.status.setTwin(true);
        p.jump_target = @intCast(self.menu_slot);
        p.action_timer = charge_p;
        p.action_ready = false;
        self.msg_len = 0;
        self.msg_timer = 12;
        self.phase = .running;
    }

    /// Cmd_20 twin resolve when twin charge timer expires.
    fn doTwinResolve(self: *Host, slot: usize, rng: damage.Rng) void {
        const attacker = self.objs.get(slot);
        const partner_slot: usize = if (attacker.jump_target < obj_mod.party_slots)
            attacker.jump_target
        else
            0xFF;
        attacker.status.setTwin(false);
        attacker.jump_target = 0xFF;
        if (partner_slot < obj_mod.party_slots) {
            const p = self.objs.get(partner_slot);
            p.status.setTwin(false);
            p.jump_target = 0xFF;
            // Partner must still be valid
            if (p.status.isKo() or (p.status.s2 & 0x3C) != 0 or p.status.isStopped()) {
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
                if (p.present and p.hp > 0) self.requeue(p);
                return;
            }
        }
        // Palom/Porom special spells $5e when char id $13/$15; else Comet/Flare
        var spell: u8 = 0x40;
        const cid = attacker.char_id;
        if (cid == 0x13 or cid == 0x15) {
            spell = 0x5E;
        } else {
            const roll = rng.next();
            if (roll == 0xFF) {
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
                if (partner_slot < obj_mod.party_slots) self.requeue(self.objs.get(partner_slot));
                return;
            }
            spell = if (roll < 0x40) 0x40 else 0x41;
        }
        if (self.rom) |rom| {
            const saved = attacker.mp;
            const mr = cmd_magic.doMagic(rom, spell, attacker, obj_mod.party_slots, &self.objs, rng);
            attacker.mp = saved;
            self.spawnMagicFloaters(mr);
            var nbuf: [12]u8 = undefined;
            const sname = cmd_magic.spellName(rom, spell, &nbuf);
            if (sname.len > 0) self.setMsg(sname) else {
                self.msg_len = 0;
                self.msg_timer = 36;
            }
        }
        self.flash = 10;
        self.phase = .message;
        self.requeue(attacker);
        if (partner_slot < obj_mod.party_slots) self.requeue(self.objs.get(partner_slot));
        _ = self.checkEnd();
    }

    fn execHide(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        // Cmd_09: $2006 bit7 (status4 hide)
        cmd_special_mod.applyHide(&attacker.status.s4);
        var i: u8 = 0;
        while (i < self.cmd_count) : (i += 1) {
            if (self.cmd_list[i] == CmdId.hide) self.cmd_list[i] = CmdId.show;
        }
        self.msg_len = 0;
        self.msg_timer = 16;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn execShow(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        // Cmd_1c: clear $2006 bit7
        cmd_special_mod.applyShow(&attacker.status.s4);
        var i: u8 = 0;
        while (i < self.cmd_count) : (i += 1) {
            if (self.cmd_list[i] == CmdId.show) self.cmd_list[i] = CmdId.hide;
        }
        self.msg_len = 0;
        self.msg_timer = 16;
        self.phase = .message;
        self.requeue(attacker);
    }

    fn execSing(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        if ((attacker.status.s1 & @import("status.zig").Status1.toad) != 0) {
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Cmd_08 picks random song attack id then DoMagicAttack
        const songs = [_]u8{ 0x29, 0x02, 0x03, 0x0E };
        const roll = rng.next();
        const spell: u8 = if (roll >= 0xC0) songs[0] else if (roll >= 0x80) songs[1] else if (roll >= 0x40) songs[2] else songs[3];
        const tslot = self.objs.firstLivingMonster() orelse self.menu_slot;
        if (self.rom) |rom| {
            const saved_mp = attacker.mp;
            const mr = cmd_magic.doMagic(rom, spell, attacker, tslot, &self.objs, rng);
            attacker.mp = saved_mp;
            if (mr.missed) self.setBattleMsg(battle_msg.MsgId.miss) else {
                self.spawnMagicFloaters(mr);
                self.msg_len = 0;
                self.msg_timer = 28;
            }
        }
        self.flash = 4;
        self.phase = .message;
        self.requeue(attacker);
        _ = self.checkEnd();
    }

    /// Random living party ally excluding `self_slot` (charm auto-target).
    fn randomLivingAlly(self: *const Host, self_slot: usize, rng: damage.Rng) ?usize {
        var slots: [obj_mod.party_slots]usize = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            if (i == self_slot) continue;
            const o = self.objs.objs[i];
            if (o.present and o.hp > 0 and !o.status.isKo()) {
                slots[n] = i;
                n += 1;
            }
        }
        if (n == 0) return null;
        return slots[rng.next() % n];
    }

    /// DoRetal (retal.asm @c16c): mon with has_retal ($38aa) counters via AIScript bank.
    /// Skips when `$3877` multi-action active; SkipMultiAttackRetal neutralizes multi scripts.
    fn tryDoRetal(self: *Host, mon_slot: usize, against_slot: usize, rng: damage.Rng) bool {
        // $34c4 mon target + $3877 multi gate (@c16c–@c18a)
        if (!retal_mod.shouldRunDoRetal(true, self.mon_multi_depth, retal_mod.monSlotToMaskBit(mon_slot)))
            return false;
        if (mon_slot < obj_mod.party_slots or mon_slot >= obj_mod.total_slots) return false;
        const mon = self.objs.get(mon_slot);
        if (!retal_mod.monEligibleForRetal(mon.has_retal, mon.status, mon.present, mon.hp))
            return false;

        // Prefer retal stack latest attacker (AICond_07), else hit source.
        var tslot = against_slot;
        const mi = mon_slot - obj_mod.party_slots;
        if (mi < obj_mod.mon_slots) {
            if (self.retal.stacks[mi].latest()) |e| {
                const decoded = retal_mod.Table.decodeAttacker(e.attacker);
                if (decoded < obj_mod.party_slots) tslot = decoded;
            }
        }
        const tgt = self.objs.get(tslot);
        if (!tgt.present or tgt.hp == 0 or tgt.status.isKo() or tslot >= obj_mod.party_slots) {
            tslot = self.objs.firstLivingParty() orelse return false;
        }
        const raw_t = self.objs.get(tslot);
        if (raw_t.cover_by != 0xFF) {
            const c = self.objs.get(raw_t.cover_by);
            if (c.present and c.hp > 0) tslot = raw_t.cover_by;
        }

        self.retal_disabled = true;
        // Retaliation prefers AIScript bank (init.asm @91af).
        const ctx = self.makeBattleCtxFor(@intCast(mon_slot));
        var act = ai_mod.getMonsterAttack(self.rom, &self.objs, mon_slot, rng, &ctx, &self.battle_vars, self.moon_ai);
        if (self.rom) |rom| {
            if (mon.ai_action_id != 0xFF) {
                var ra = ai_mod.getRetalAttack(rom, &self.objs, mon_slot, mon.ai_action_id, rng, &self.battle_vars);
                // SkipMultiAttackRetal (@c45e): neutralize multi-action retal scripts.
                if (ra.multi_begin or ra.multi_end) {
                    ra.cmd = 0xE1;
                    ra.no_target = true;
                    ra.multi_begin = false;
                    ra.multi_end = false;
                }
                if (!(ra.no_target or ra.cmd == 0xE1)) act = ra;
            }
        }
        if (act.target_slot >= obj_mod.party_slots) act.target_slot = tslot;
        if (act.cmd == 0xE1 or act.no_target) {
            self.retal_disabled = false;
            return false;
        }
        if (act.cmd == 0xC2 and self.rom != null) {
            const rom = self.rom.?;
            var mtslot = act.target_slot;
            if (mtslot >= obj_mod.party_slots) mtslot = tslot;
            const mr = cmd_magic.doMagicEx(rom, act.spell_id, mon, mtslot, &self.objs, rng, false, false);
            self.recordHit(mon_slot, mtslot, 0xC2, 0, mr.amount > 0 and !mr.missed);
            self.flash = 6;
            self.spawnMagicFloaters(mr);
            var nbuf: [12]u8 = undefined;
            const sname = cmd_magic.spellName(rom, act.spell_id, &nbuf);
            if (sname.len > 0) self.setMsg(sname) else {
                self.msg_len = 0;
                self.msg_timer = 20;
            }
            self.phase = .message;
            self.retal_disabled = false;
            _ = self.checkEnd();
            return true;
        }
        // Default / fight path — target the party attacker
        const fr = cmd_fight.calcFightEx(mon, self.objs.get(tslot), rng, .{
            .mon_invincible = false,
        });
        self.pending_status_s1 = fr.status_s1;
        self.pending_status_s2 = fr.status_s2;
        self.anim = .{
            .kind = .mon_fight,
            .t = 0,
            .attacker = mon_slot,
            .target = tslot,
            .damage = fr.damage,
            .missed = fr.missed,
            .crit = fr.crit,
        };
        self.phase = .animating;
        self.retal_disabled = false;
        return true;
    }

    fn startMonFight(self: *Host, mon_slot: usize, rng: damage.Rng) void {
        const mon = self.objs.get(mon_slot);
        // GetMonsterAttack (ai.asm): AIAction script or Fight + GetDefaultAITarget.
        const ctx = self.makeBattleCtxFor(@intCast(mon_slot));
        const act = ai_mod.getMonsterAttack(self.rom, &self.objs, mon_slot, rng, &ctx, &self.battle_vars, self.moon_ai);
        self.applyAiMultiFlags(&act);
        if (act.delayed) {
            // $FE + InitAIDelay (ai.asm @bbde): short requeue, no attack this step.
            if (act.dlg_n > 0) {
                self.queueDlgFromAct(&act);
                self.pending_mon_slot = mon_slot;
                self.pending_mon_cmd = 0xE1;
                self.showNextDlg();
                return;
            }
            self.requeueShort(mon);
            return;
        }
        if (act.no_target or act.cmd == 0xE1) {
            // Dialogue-only or wait scripts: still show dlg then requeue.
            if (act.dlg_n > 0) {
                self.queueDlgFromAct(&act);
                self.pending_mon_slot = mon_slot;
                self.pending_mon_cmd = 0xE1;
                self.showNextDlg();
                return;
            }
            self.finishMonTurn(mon_slot);
            return;
        }
        // AIAction $F1/$F2 battle dialogue before attack (gfx script order).
        if (act.dlg_n > 0) {
            self.queueDlgFromAct(&act);
            self.pending_mon_slot = mon_slot;
            self.pending_mon_cmd = act.cmd;
            self.pending_mon_spell = act.spell_id;
            self.pending_mon_target = act.target_slot;
            self.showNextDlg();
            return;
        }
        self.execMonAction(mon_slot, act.cmd, act.spell_id, act.target_slot, rng);
    }

    /// $FD/$FC multi-action depth (ai.asm $3877).
    fn applyAiMultiFlags(self: *Host, act: *const ai_mod.MonAction) void {
        if (act.multi_begin) self.mon_multi_depth +%= 1;
        if (act.multi_end and self.mon_multi_depth > 0) self.mon_multi_depth -%= 1;
        if (act.delayed) self.mon_multi_depth = 0;
    }

    /// After mon command: if multi depth > 0, InitAIDelay-style short timer so mon acts again.
    fn finishMonTurn(self: *Host, mon_slot: usize) void {
        const mon = self.objs.get(mon_slot);
        if (self.mon_multi_depth > 0) {
            self.requeueShort(mon);
        } else {
            self.requeue(mon);
        }
    }

    /// InitAIDelay (@bbde): `lda #$02` / CalcTimerDur → TimerDur_02 immediate + SetTimer action.
    fn requeueShort(self: *Host, o: *obj_mod.Obj) void {
        _ = self;
        const rom = timer_dur.timerDurImmediate(o.is_monster, o.speed_mod);
        o.action_timer = timer_dur.toHostTicksArm(rom);
        o.action_ready = false;
    }

    fn queueDlgFromAct(self: *Host, act: *const ai_mod.MonAction) void {
        self.dlg_queue_n = 0;
        self.dlg_queue_i = 0;
        var i: u8 = 0;
        while (i < act.dlg_n and i < self.dlg_queue.len) : (i += 1) {
            self.dlg_queue[i] = act.dlg[i];
            self.dlg_queue_n += 1;
        }
    }

    fn showNextDlg(self: *Host) void {
        if (self.dlg_queue_i >= self.dlg_queue_n) {
            self.dlg_queue_n = 0;
            self.dlg_queue_i = 0;
            return;
        }
        const id = self.dlg_queue[self.dlg_queue_i];
        self.dlg_queue_i += 1;
        var buf: [96]u8 = undefined;
        if (self.rom) |rom| {
            const text = battle_dlg.load(rom, id, &buf);
            if (text.len > 0) {
                self.setMsg(text);
                // GfxScriptCmd_f1: slowest MsgDurTbl[5]; $F2 uses config (default slow for AI queue).
                const wait = gfx_script_mod.dialogueWaitFrames(true, self.msg_speed);
                self.msg_timer = @intCast(@min(wait, 255));
                self.phase = .message;
                return;
            }
        }
        // Empty line — skip to next immediately via zero timer
        self.msg_len = 0;
        self.msg_timer = 1;
        self.phase = .message;
    }

    fn finishPendingMonAction(self: *Host, rng: damage.Rng) void {
        const slot = self.pending_mon_slot;
        const cmd = self.pending_mon_cmd;
        const spell = self.pending_mon_spell;
        const tgt = self.pending_mon_target;
        self.pending_mon_cmd = 0xFF;
        self.pending_mon_slot = 0xFF;
        self.dlg_queue_n = 0;
        self.dlg_queue_i = 0;
        if (slot >= obj_mod.total_slots) return;
        if (cmd == 0xE1) {
            self.requeue(self.objs.get(slot));
            return;
        }
        self.execMonAction(slot, cmd, spell, tgt, rng);
    }

    fn execMonAction(self: *Host, mon_slot: usize, cmd: u8, spell_id: u8, target_slot: usize, rng: damage.Rng) void {
        const mon = self.objs.get(mon_slot);
        if (cmd == 0xC2) {
            if (self.rom) |rom| {
                const mr = cmd_magic.doMagicEx(rom, spell_id, mon, target_slot, &self.objs, rng, self.mon_invincible != 0, false);
                self.recordHit(mon_slot, target_slot, 0xC2, 0, mr.amount > 0 and !mr.missed);
                self.flash = 6;
                if (mr.missed) {
                    self.setBattleMsg(battle_msg.MsgId.miss);
                } else {
                    self.spawnMagicFloaters(mr);
                    var nbuf: [12]u8 = undefined;
                    const sname = cmd_magic.spellName(rom, spell_id, &nbuf);
                    if (sname.len > 0) {
                        self.setMsg(sname);
                    } else {
                        self.msg_len = 0;
                        self.msg_timer = 24;
                    }
                }
            }
            self.requeue(mon);
            self.phase = .message;
            _ = self.checkEnd();
            return;
        }
        // Fight $C0 — cover redirect for party targets
        var tslot = target_slot;
        if (tslot < obj_mod.party_slots) {
            const raw_t = self.objs.get(tslot);
            if (raw_t.cover_by != 0xFF) {
                const c = self.objs.get(raw_t.cover_by);
                if (c.present and c.hp > 0) tslot = raw_t.cover_by;
            }
        }
        const party = self.objs.get(tslot);
        const fr = cmd_fight.calcFightEx(mon, party, rng, .{
            .mon_invincible = self.mon_invincible != 0,
        });
        self.pending_status_s1 = fr.status_s1;
        self.pending_status_s2 = fr.status_s2;
        self.anim = .{
            .kind = .mon_fight,
            .t = 0,
            .attacker = mon_slot,
            .target = tslot,
            .damage = fr.damage,
            .missed = fr.missed,
            .crit = fr.crit,
        };
        self.phase = .animating;
    }

    fn requeue(self: *Host, o: *obj_mod.Obj) void {
        obj_mod.requeueActionTimerEx(o, self.objs.max_agility);
    }

    pub fn menuUp(self: *Host) void {
        if (self.phase != .menu) return;
        switch (self.menu_mode) {
            .item => self.moveItemCursor(0, -1),
            .magic => self.moveMagicCursor(0, -1),
            .target => self.moveTarget(-1, 0),
            .cover_target => self.moveCoverTarget(-1),
            .command => {
                if (self.cmd_count == 0) return;
                if (self.menu_sel == 0) self.menu_sel = self.cmd_count - 1 else self.menu_sel -= 1;
                self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
            },
        }
    }
    pub fn menuDown(self: *Host) void {
        if (self.phase != .menu) return;
        switch (self.menu_mode) {
            .item => self.moveItemCursor(0, 1),
            .magic => self.moveMagicCursor(0, 1),
            .target => self.moveTarget(1, 0),
            .cover_target => self.moveCoverTarget(1),
            .command => {
                if (self.cmd_count == 0) return;
                self.menu_sel = (self.menu_sel + 1) % self.cmd_count;
                self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
            },
        }
    }
    pub fn menuLeft(self: *Host) void {
        if (self.phase != .menu) return;
        switch (self.menu_mode) {
            .item => self.moveItemCursor(-1, 0),
            .magic => self.moveMagicCursor(-1, 0),
            .target => self.moveTarget(0, -1),
            .cover_target => self.moveCoverTarget(-1),
            .command => {},
        }
    }
    pub fn menuRight(self: *Host) void {
        if (self.phase != .menu) return;
        switch (self.menu_mode) {
            .item => self.moveItemCursor(1, 0),
            .magic => self.moveMagicCursor(1, 0),
            .target => self.moveTarget(0, 1),
            .cover_target => self.moveCoverTarget(1),
            .command => {},
        }
    }

    /// Battle inventory: 2 columns × 5 visible rows (UpdateCursor_05).
    fn moveItemCursor(self: *Host, dx: i8, dy: i8) void {
        const inv = self.inv orelse return;
        const atk = self.objs.get(self.menu_slot);
        var list: [50]usize = undefined;
        const n = battleItemList(inv, atk.left_hand, atk.right_hand, self.rom, &list);
        if (n == 0) return;

        var i: i32 = self.item_list_i;
        if (dx < 0 and @rem(i, 2) == 1) i -= 1;
        if (dx > 0 and @rem(i, 2) == 0 and i + 1 < n) i += 1;
        if (dy < 0 and i >= 2) i -= 2;
        if (dy > 0 and i + 2 < n) i += 2 else if (dy > 0 and i + 1 < n and @rem(i, 2) == 0) i += 1;

        if (i < 0) i = 0;
        if (i >= n) i = @intCast(n - 1);
        if (@as(u8, @intCast(i)) == self.item_list_i and dx == 0 and dy == 0) return;

        self.item_list_i = @intCast(i);
        self.item_slot = list[@intCast(i)];
        // Keep selected row inside the 5-row window.
        const row: u8 = self.item_list_i / 2;
        if (row < self.item_scroll) self.item_scroll = row;
        if (row >= self.item_scroll + 5) self.item_scroll = row - 4;
        self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
    }

    fn openItemMenu(self: *Host) bool {
        const inv = self.inv orelse return false;
        const atk = self.objs.get(self.menu_slot);
        var list: [50]usize = undefined;
        const n = battleItemList(inv, atk.left_hand, atk.right_hand, self.rom, &list);
        if (n == 0) return false;
        self.item_list_i = 0;
        self.item_scroll = 0;
        self.item_slot = list[0];
        // Prefer first battle-usable bag item or hand-cast entry.
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const slot = list[i];
            const usable = if (slot == hand_left_slot or slot == hand_right_slot)
                true
            else
                item_prop.ItemProp.isBattleItem(inv.slots[slot].id);
            if (usable) {
                self.item_list_i = i;
                self.item_slot = slot;
                self.item_scroll = i / 2;
                if (self.item_scroll > 0 and self.item_scroll + 5 > (n + 1) / 2) {
                    const max_scroll = if ((n + 1) / 2 > 5) @as(u8, @intCast((n + 1) / 2 - 5)) else 0;
                    if (self.item_scroll > max_scroll) self.item_scroll = max_scroll;
                }
                break;
            }
        }
        self.menu_mode = .item;
        self.target_slot = self.menu_slot;
        return true;
    }

    /// Resolve item id for current item_slot (bag or hand equip).
    fn selectedItemId(self: *const Host) u8 {
        const atk = &self.objs.objs[self.menu_slot];
        if (self.item_slot == hand_left_slot) return atk.left_hand;
        if (self.item_slot == hand_right_slot) return atk.right_hand;
        if (self.inv) |inv| {
            if (self.item_slot < inv.slots.len) return inv.slots[self.item_slot].id;
        }
        return 0;
    }

    fn itemIsFromHand(self: *const Host) bool {
        return self.item_slot == hand_left_slot or self.item_slot == hand_right_slot;
    }
    pub fn menuToggle(self: *Host) void {
        self.menuDown();
    }
    pub fn menuCancel(self: *Host) void {
        if (self.phase != .menu) return;
        switch (self.menu_mode) {
            .item, .magic => {
                self.menu_mode = .command;
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
            },
            .target, .cover_target => {
                // B: HideAllTargetCursors, restore command list ($ef91 → $1823=$01)
                self.menu_mode = .command;
                self.pending_cmd = 0xFF;
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
            },
            .command => {},
        }
    }

    /// Magic list: 3 columns × 5 rows (MagicListCursorXTbl / ListCursorYTbl).
    fn moveMagicCursor(self: *Host, dx: i8, dy: i8) void {
        if (self.magic_count == 0) return;
        var i: i32 = self.magic_sel;
        const cols: i32 = 3;
        if (dx < 0 and @rem(i, cols) > 0) i -= 1;
        if (dx > 0 and @rem(i, cols) < cols - 1 and i + 1 < self.magic_count) i += 1;
        if (dy < 0 and i >= cols) i -= cols;
        if (dy > 0 and i + cols < self.magic_count) i += cols else if (dy > 0) {
            // step to last in next partial row
            const next = i + (cols - @rem(i, cols));
            if (next < self.magic_count) i = next else if (i + 1 < self.magic_count) i += 1;
        }
        if (i < 0) i = 0;
        if (i >= self.magic_count) i = self.magic_count - 1;
        if (@as(u8, @intCast(i)) == self.magic_sel) return;
        self.magic_sel = @intCast(i);
        const row: u8 = self.magic_sel / 3;
        if (row < self.magic_scroll) self.magic_scroll = row;
        if (row >= self.magic_scroll + 5) self.magic_scroll = row - 4;
        self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
    }

    fn openMagicMenu(self: *Host, magic_col: u8) bool {
        const rom = self.rom orelse return false;
        // SpellListTbl[char_id][col] — acting party member only (no invented list)
        const actor = &self.objs.objs[self.menu_slot];
        const char_id = actor.char_id;
        const list_id = cmd_magic.listIdFor(rom, char_id, magic_col);
        if (list_id == 0xFF or list_id >= offsets.en.spell_list_init_count) return false;
        self.magic_count = cmd_magic.loadSpellListPreferRam(rom, self.spell_lists, list_id, &self.magic_list);
        // Toad: only spell $19 usable; Pig: only $1A (UpdateEnabledCmds @a20e)
        if ((actor.status.s1 & status_mod.Status1.toad) != 0) {
            self.magic_count = filterSpellList(&self.magic_list, self.magic_count, 0x19);
        } else if ((actor.status.s1 & status_mod.Status1.pig) != 0) {
            self.magic_count = filterSpellList(&self.magic_list, self.magic_count, 0x1A);
        }
        if (self.magic_count == 0) return false;
        self.magic_col = magic_col;
        self.magic_sel = 0;
        self.magic_scroll = 0;
        self.menu_mode = .magic;
        return true;
    }

    /// Keep only `keep_id` entries (toad/pig spell restriction).
    fn filterSpellList(list: *[24]u8, count: u8, keep_id: u8) u8 {
        var w: u8 = 0;
        var r: u8 = 0;
        while (r < count) : (r += 1) {
            if (list[r] == keep_id) {
                list[w] = list[r];
                w += 1;
            }
        }
        return w;
    }

    /// MoveTargetCursor using MonsterCursor graph ($29cf).
    /// Each mon i: raw[i*2] = up:hi down:lo; raw[i*2+1] = left:hi right:lo.
    /// Nibble $F = no further move (cursor.asm).
    fn moveTarget(self: *Host, dy: i8, dx: i8) void {
        if (self.target_slot < obj_mod.party_slots) return;
        var mon_i: usize = self.target_slot - obj_mod.party_slots;
        if (mon_i >= 8) return;

        const dir: enum { up, down, left, right } = blk: {
            if (dy < 0) break :blk .up;
            if (dy > 0) break :blk .down;
            if (dx < 0) break :blk .left;
            if (dx > 0) break :blk .right;
            return;
        };

        // Empty / unloaded table → linear scan among living mons (dy/dx).
        const table_empty = self.mon_cursor[0] == 0xFF and self.mon_cursor[1] == 0xFF;
        if (table_empty) {
            self.moveTargetLinear(if (dy != 0) dy else dx);
            return;
        }

        // Follow graph, skipping dead/missing (up to 8 hops).
        var hops: u8 = 0;
        while (hops < 8) : (hops += 1) {
            const b0 = self.mon_cursor[mon_i * 2];
            const b1 = self.mon_cursor[mon_i * 2 + 1];
            const next_n: u8 = switch (dir) {
                .up => b0 >> 4,
                .down => b0 & 0x0F,
                .left => b1 >> 4,
                .right => b1 & 0x0F,
            };
            if (next_n >= 0x0F) break; // edge
            if (next_n >= 8) break;
            const slot = obj_mod.party_slots + next_n;
            const o = self.objs.objs[slot];
            if (o.present and o.hp > 0) {
                if (slot != self.target_slot) {
                    self.target_slot = slot;
                    self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
                }
                return;
            }
            mon_i = next_n; // hop over dead
        }
    }

    /// Fallback target walk when MonsterCursor is missing.
    fn moveTargetLinear(self: *Host, step: i8) void {
        if (step == 0) return;
        var living: [8]usize = undefined;
        var n: usize = 0;
        var i: usize = obj_mod.party_slots;
        while (i < obj_mod.total_slots) : (i += 1) {
            const m = self.objs.objs[i];
            // Cursor skips jump/hide (same as attack.asm invalid targets).
            if (m.present and m.hp > 0 and !m.status.isKo() and
                !m.status.isJumping() and !m.status.isHidden())
            {
                living[n] = i;
                n += 1;
            }
        }
        if (n <= 1) return;
        var idx: usize = 0;
        for (living[0..n], 0..) |s, k| {
            if (s == self.target_slot) idx = k;
        }
        if (step > 0) {
            idx = (idx + 1) % n;
        } else {
            idx = if (idx == 0) n - 1 else idx - 1;
        }
        self.target_slot = living[idx];
        self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
    }

    /// FightMenuCmd: open target select (cursor type $04), do not attack yet.
    fn openTargetSelect(self: *Host) void {
        if (self.objs.firstLivingMonster()) |t| {
            self.target_slot = t;
        } else {
            self.queueSysSfx(audio_mod.sys_sfx_error);
            return;
        }
        self.menu_mode = .target;
        self.queueSysSfx(audio_mod.sys_sfx_confirm);
    }

    /// Cmd_13: pick living ally other than self to cover.
    fn openCoverSelect(self: *Host) void {
        var found: ?usize = null;
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            if (i == self.menu_slot) continue;
            const a = self.objs.objs[i];
            if (a.present and a.hp > 0 and !a.status.isKo()) {
                found = i;
                break;
            }
        }
        if (found) |s| {
            self.target_slot = s;
            self.menu_mode = .cover_target;
            self.queueSysSfx(audio_mod.sys_sfx_confirm);
        } else {
            self.queueSysSfx(audio_mod.sys_sfx_error);
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(self.objs.get(self.menu_slot));
        }
    }

    fn confirmCover(self: *Host) void {
        const attacker = self.objs.get(self.menu_slot);
        const c = self.target_slot;
        if (c >= obj_mod.party_slots or c == self.menu_slot or
            !self.objs.objs[c].present or self.objs.objs[c].hp == 0)
        {
            self.menu_mode = .command;
            self.queueSysSfx(audio_mod.sys_sfx_error);
            return;
        }
        // Clear previous cover links from this unit
        if (attacker.covering_slot != 0xFF) {
            const prev = self.objs.get(attacker.covering_slot);
            if (prev.cover_by == self.menu_slot) {
                prev.cover_by = 0xFF;
                prev.status.setCovered(false);
            }
        }
        const covered = self.objs.get(c);
        cmd_special_mod.applyCover(
            &attacker.covering_slot,
            &covered.cover_by,
            &covered.status.s4,
            @intCast(self.menu_slot),
            @intCast(c),
        );
        self.queueSysSfx(audio_mod.sys_sfx_confirm);
        self.menu_mode = .command;
        self.phase = .message;
        self.msg_len = 0;
        self.msg_timer = 20;
        self.requeue(attacker);
    }

    fn moveCoverTarget(self: *Host, step: i8) void {
        if (step == 0) return;
        var living: [5]usize = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            if (i == self.menu_slot) continue;
            const a = self.objs.objs[i];
            if (a.present and a.hp > 0 and !a.status.isKo()) {
                living[n] = i;
                n += 1;
            }
        }
        if (n == 0) return;
        var idx: usize = 0;
        for (living[0..n], 0..) |s, k| {
            if (s == self.target_slot) idx = k;
        }
        if (step > 0) idx = (idx + 1) % n else idx = if (idx == 0) n - 1 else idx - 1;
        self.target_slot = living[idx];
        self.queueSysSfx(audio_mod.sys_sfx_cursor_move);
    }

    fn queueSysSfx(self: *Host, id: u8) void {
        self.pending_sys_sfx = id;
    }
    /// InitBtlGfx entry loop — UpdateMonsterEntry one field.
    fn tickMonEntry(self: *Host) void {
        if (!self.mon_entry_active) return;
        const r = mon_entry_mod.tickEntry(self.mon_entry_counter, self.entry_back_attack, self.mons_flying);
        self.mon_entry_counter = r.next_counter;
        self.mon_entry_scroll = r.delta;
        if (r.done) {
            self.mon_entry_active = false;
            self.mon_entry_scroll = 0;
        }
    }

    /// Queue battle BGM change (`$38be`/`$38bd` stand-in). Marks song_dirty for app.
    pub fn setSong(self: *Host, id: u8) void {
        if (self.song_id != id) {
            self.song_id = id;
            self.song_dirty = true;
        } else if (id != audio_mod.battle_song_none) {
            // Same id re-queue still restarts on SNES (inc $38bd); flag dirty.
            self.song_dirty = true;
        }
    }

    /// App: take pending song change (victory fanfare / `$F3` mid-fight).
    pub fn consumeSongChange(self: *Host) ?u8 {
        if (!self.song_dirty) return null;
        self.song_dirty = false;
        return self.song_id;
    }

    fn queueSfx(self: *Host, id: u8) void {
        self.pending_sfx = id;
    }

    pub fn consumeSfx(self: *Host) ?u8 {
        if (self.pending_sfx == 0) return null;
        const s = self.pending_sfx;
        self.pending_sfx = 0;
        return s;
    }
    pub fn consumeSysSfx(self: *Host) ?u8 {
        if (self.pending_sys_sfx == 0) return null;
        const s = self.pending_sys_sfx;
        self.pending_sys_sfx = 0;
        return s;
    }

    /// Selected ClassCmd id (or 0xFF).
    pub fn selectedCmd(self: *const Host) u8 {
        if (self.menu_sel >= self.cmd_count) return 0xFF;
        return self.cmd_list[self.menu_sel];
    }

    /// L+R flee — battle.asm @a07e counter, not a probability roll.
    pub fn tryFlee(self: *Host, rng: damage.Rng) void {
        _ = rng;
        if (self.phase != .menu or self.menu_mode != .command) return;
        const attacker = self.objs.get(self.menu_slot);
        // Always mark escape attempt for AICond_09 (even if failed).
        self.party_escaped = true;
        // Refresh max mon level in case some died mid-battle
        self.run_state.max_mon_level = cmd_run.maxLivingMonLevel(&self.objs);
        if (cmd_run.tryFleeOnce(&self.run_state)) {
            self.end_flags.ran = true;
            self.queueSysSfx(audio_mod.sys_sfx_confirm);
            self.setBattleMsg(battle_msg.MsgId.ran_away);
            self.phase = .message;
        } else {
            self.queueSysSfx(audio_mod.sys_sfx_error);
            // Hard mons (97–99): counter still ticking — no "failed" spam every press
            if (self.run_state.cant_run) {
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
            }
            // else: still holding / decrementing — stay in menu
        }
    }

    /// Per-frame L+R hold while in command menu (optional continuous flee).
    pub fn tickFleeHold(self: *Host, holding_lr: bool) void {
        if (self.phase != .menu or self.menu_mode != .command) return;
        self.run_state.max_mon_level = cmd_run.maxLivingMonLevel(&self.objs);
        if (cmd_run.tickFlee(&self.run_state, holding_lr)) {
            self.party_escaped = true;
            self.end_flags.ran = true;
            self.setBattleMsg(battle_msg.MsgId.ran_away);
            self.phase = .message;
        }
    }

    /// Confirm command (GetCharAttack → target select / DoAttack / item / parry / row).
    pub fn confirmMenu(self: *Host, rng: damage.Rng) void {
        if (self.phase != .menu) return;
        const attacker = self.objs.get(self.menu_slot);

        // Target select A: lock target and execute pending cmd (fight/sneak/dart/peep).
        if (self.menu_mode == .target) {
            const tgt = self.objs.get(self.target_slot);
            if (!tgt.present or tgt.hp == 0) {
                if (self.objs.firstLivingMonster()) |t| {
                    self.target_slot = t;
                } else {
                    self.menu_mode = .command;
                    self.pending_cmd = 0xFF;
                    self.queueSysSfx(audio_mod.sys_sfx_error);
                    return;
                }
            }
            self.queueSysSfx(audio_mod.sys_sfx_confirm);
            self.menu_mode = .command;
            const pc = self.pending_cmd;
            self.pending_cmd = 0xFF;
            switch (pc) {
                CmdId.sneak => self.execSneak(rng),
                CmdId.dart => self.execDart(rng),
                CmdId.peep => self.execPeep(),
                CmdId.aim => self.startPartyFightAim(rng),
                CmdId.jump => self.execJump1(),
                else => self.startPartyFight(rng),
            }
            return;
        }

        // Cover: lock ally and apply Cmd_13
        if (self.menu_mode == .cover_target) {
            self.confirmCover();
            return;
        }

        if (self.menu_mode == .item) {
            if (self.pending_cmd == CmdId.dart) {
                // Dart: item chosen → mon target
                self.menu_mode = .command;
                self.openTargetSelect();
                return;
            }
            self.execItem(rng);
            return;
        }
        if (self.menu_mode == .magic) {
            self.execMagic(rng);
            return;
        }

        const cmd = self.selectedCmd();
        switch (cmd) {
            CmdId.fight => {
                self.pending_cmd = CmdId.fight;
                self.openTargetSelect();
            },
            CmdId.aim => {
                self.pending_cmd = CmdId.aim;
                self.openTargetSelect();
            },
            CmdId.kick => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execKick(rng);
            },
            CmdId.dark => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execDark(rng);
            },
            CmdId.pray => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execPray(rng);
            },
            CmdId.twin => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execTwin(rng);
            },
            CmdId.bluff => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execBluff();
            },
            CmdId.cry => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execCry();
            },
            CmdId.recall => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execRecall(rng);
            },
            CmdId.ninja => {
                // Ninjutsu: open black/ninja spell list (SpellListTbl col 1)
                if (self.openMagicMenu(1)) {
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.hide => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execHide();
            },
            CmdId.show => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execShow();
            },
            CmdId.regen => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execRegen();
            },
            CmdId.sing => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execSing(rng);
            },
            CmdId.sneak => {
                self.pending_cmd = CmdId.sneak;
                self.openTargetSelect();
            },
            CmdId.dart => {
                // Throw: pick inventory weapon first, then mon target.
                if (self.openItemMenu()) {
                    self.pending_cmd = CmdId.dart;
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.peep => {
                self.pending_cmd = CmdId.peep;
                self.openTargetSelect();
            },
            CmdId.item => {
                if (self.openItemMenu()) {
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setMsg("No items!");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.white => {
                if (self.openMagicMenu(0)) {
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setMsg("No magic!");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.black => {
                if (self.openMagicMenu(1)) {
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setMsg("No magic!");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.call => {
                if (self.openMagicMenu(2)) {
                    self.queueSysSfx(audio_mod.sys_sfx_confirm);
                    return;
                }
                self.queueSysSfx(audio_mod.sys_sfx_error);
                self.setMsg("No magic!");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.parry => {
                // Cmd_1b defend: $2005 bit4
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                attacker.setDefending(true);
                self.setMsg("Parrying...");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.chang => {
                // Cmd_1a: flip row bit for ALL party members (cmd.asm @e3d4)
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                var ri: usize = 0;
                while (ri < obj_mod.party_slots) : (ri += 1) {
                    const p = self.objs.get(ri);
                    if (p.present) p.row ^= 1;
                }
                self.setMsg(if (attacker.row == 0) "Front row" else "Back row");
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.jump => {
                // CmdTargetTbl[$06]=$58: mon default + selectable (cursor.asm SelectDefaultTarget).
                self.pending_cmd = CmdId.jump;
                self.openTargetSelect();
            },
            CmdId.cover => {
                // Cmd_13 (cmd.asm cover): select ally ($ce).
                self.openCoverSelect();
            },
            // Cmd_1d: don't cover (clear $2006 bit1 on covered target)
            0x1D => {
                if (attacker.covering_slot != 0xFF) {
                    const c = attacker.covering_slot;
                    if (c < obj_mod.party_slots) {
                        const covered = self.objs.get(c);
                        cmd_special_mod.clearCover(
                            &attacker.covering_slot,
                            &covered.cover_by,
                            &covered.status.s4,
                            @intCast(self.menu_slot),
                        );
                    } else {
                        attacker.covering_slot = 0xFF;
                    }
                }
                self.msg_len = 0;
                self.msg_timer = 16;
                self.phase = .message;
                self.requeue(attacker);
            },
            CmdId.salve => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execSalve(rng);
            },
            CmdId.focus => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execFocus();
            },
            CmdId.brace => {
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                self.execBrace(rng);
            },
            // Remaining unused ClassCmd IDs fail closed (no invented effects).
            else => {
                self.queueSysSfx(audio_mod.sys_sfx_error);
                var nbuf: [12]u8 = undefined;
                const nm = if (self.rom) |rom| window.commandName(rom, cmd, &nbuf) else "???";
                var buf: [48]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "{s} not ready", .{nm}) catch "Not ready";
                self.setMsg(m);
                self.phase = .message;
                self.requeue(attacker);
            },
        }
    }

    fn execSneak(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const target = self.objs.get(self.target_slot);
        const inv = self.inv orelse {
            self.requeue(attacker);
            self.phase = .message;
            return;
        };
        const rom = self.rom orelse {
            self.requeue(attacker);
            return;
        };
        const sr = cmd_steal.doSteal(rom, inv, attacker, target, rng);
        self.setBattleMsg(sr.msg_id);
        if (sr.self_damage > 0) {
            self.floaters.spawn(@intCast(attacker.centerX()), @intCast(attacker.centerY()), sr.self_damage, false, false);
        }
        if (sr.ok and sr.item_id != 0) {
            // Append item name after "Found " if space
            var nbuf: [12]u8 = undefined;
            const iname = inventory_mod.Inventory.itemName(rom, sr.item_id, &nbuf);
            if (self.msg_len + 1 + iname.len <= self.msg.len) {
                if (self.msg_len > 0 and self.msg[self.msg_len - 1] == '.') {
                    // "Found ." → "Found Name"
                    self.msg_len -%= 1;
                }
                @memcpy(self.msg[self.msg_len..][0..iname.len], iname);
                self.msg_len += iname.len;
            }
        }
        self.phase = .message;
        self.requeue(attacker);
        _ = self.checkEnd();
    }

    fn execDart(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const target = self.objs.get(self.target_slot);
        const inv = self.inv orelse {
            self.requeue(attacker);
            return;
        };
        const rom = self.rom orelse {
            self.requeue(attacker);
            return;
        };
        const tr = cmd_steal.doThrow(rom, inv, self.item_slot, attacker, target, rng, self.mon_invincible != 0);
        if (!tr.ok or tr.missed) {
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
        } else {
            self.floaters.spawn(@intCast(target.centerX()), @intCast(target.centerY()), tr.damage, false, false);
            self.msg_len = 0;
            self.msg_timer = 24;
            self.flash = 6;
        }
        self.phase = .message;
        self.requeue(attacker);
        _ = self.checkEnd();
    }

    fn execPeep(self: *Host) void {
        // Cmd_14 / MagicEffect_12 (cmd.asm @e156): HP + weak-elem msgs $15+bit
        const attacker = self.objs.get(self.menu_slot);
        const target = self.objs.get(self.target_slot);
        if (!target.is_monster or target.is_boss) {
            self.setBattleMsg(battle_msg.MsgId.failed);
        } else {
            self.showPeepResult(target.hp, target.max_hp, target.weak_elem & ~target.strong_elem & 0x3F);
        }
        self.phase = .message;
        self.requeue(attacker);
    }

    /// BattleMsg $1e HP + optional $14 none / $15–$1a weak lines.
    fn showPeepResult(self: *Host, hp: u16, max_hp: u16, weak_bits: u8) void {
        var buf: [96]u8 = undefined;
        var len: usize = 0;
        const hp_line = std.fmt.bufPrint(buf[0..], "HP {d}/{d}", .{ hp, max_hp }) catch "HP";
        @memcpy(buf[0..hp_line.len], hp_line);
        len = hp_line.len;
        if (self.rom) |rom| {
            if (weak_bits == 0) {
                // BattleMsg $14 "No weak points found"
                var wbuf: [40]u8 = undefined;
                const w = battle_msg.load(rom, 0x14, &wbuf);
                if (w.len > 0 and len + 1 + w.len < buf.len) {
                    buf[len] = ' ';
                    len += 1;
                    @memcpy(buf[len..][0..w.len], w);
                    len += w.len;
                }
            } else {
                var bit: u8 = 0;
                while (bit < 6) : (bit += 1) {
                    if ((weak_bits & (@as(u8, 1) << @intCast(bit))) == 0) continue;
                    var wbuf: [40]u8 = undefined;
                    const w = battle_msg.load(rom, 0x15 + bit, &wbuf);
                    if (w.len == 0) continue;
                    if (len + 1 + w.len >= buf.len) break;
                    buf[len] = ' ';
                    len += 1;
                    @memcpy(buf[len..][0..w.len], w);
                    len += w.len;
                }
            }
        }
        self.setMsg(buf[0..len]);
    }

    fn execItem(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const inv = self.inv orelse {
            self.menu_mode = .command;
            return;
        };
        const rom = self.rom orelse {
            self.menu_mode = .command;
            return;
        };
        const from_hand = self.itemIsFromHand();
        const item_id = self.selectedItemId();
        if (item_id == 0 or (!from_hand and (self.item_slot >= inv.slots.len or inv.slots[self.item_slot].qty == 0))) {
            self.setMsg("No items!");
            self.phase = .message;
            self.menu_mode = .command;
            self.requeue(attacker);
            return;
        }
        // Cmd_01 status gates (@eba2): KO / sleep·para·charm·berserk / jump·twin·stop
        if ((attacker.status.s1 & 0xC0) != 0 or
            (attacker.status.s2 & 0x3C) != 0 or
            (attacker.status.s3 & 0xC6) != 0)
        {
            self.menu_mode = .command;
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // Primary slot for expandTargets (ItemProp target field selects multi)
        const ip = item_prop.ItemProp.load(rom, item_id);
        var tslot = self.target_slot;
        if (ip) |p| {
            switch (p.target) {
                0 => tslot = self.menu_slot, // self
                1, 3 => {
                    // Single ally; Life prefers dead
                    if (p.effect == 10) {
                        var di: usize = 0;
                        while (di < obj_mod.party_slots) : (di += 1) {
                            const a = self.objs.objs[di];
                            if (a.present and (a.hp == 0 or a.status.isDead())) {
                                tslot = di;
                                break;
                            }
                        }
                    } else if (tslot >= obj_mod.party_slots) {
                        tslot = self.menu_slot;
                    }
                },
                2 => tslot = self.menu_slot, // all allies
                4, 5 => {
                    if (tslot < obj_mod.party_slots)
                        tslot = self.objs.firstLivingMonster() orelse self.menu_slot;
                },
                6, 7 => {
                    tslot = self.objs.firstLivingMonster() orelse self.menu_slot;
                },
                else => {},
            }
        }
        // Hand equip: always weapon-magic path ($26d0 bit4 set) — prefer mon targets
        if (from_hand and tslot < obj_mod.party_slots) {
            tslot = self.objs.firstLivingMonster() orelse tslot;
        }
        // Cmd_01: $CA RandSummon / weapon magic / ItemProp ($26d0 bit4)
        const mr = self.execItemMagic(rom, attacker, item_id, tslot, rng);
        self.menu_mode = .command;
        // Consume bag items only (hand equip never consumed). Crystal $C8 never consumed.
        if (!from_hand and item_id != 0xC8) _ = inv.take(item_id);
        if (mr.missed and mr.amount == 0 and !mr.healed) {
            self.setBattleMsg(battle_msg.MsgId.miss);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        if (!mr.ok and mr.amount == 0 and mr.floater_n == 0) {
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        if (mr.invincible_delta > 0) {
            self.mon_invincible +%= @intCast(mr.invincible_delta);
        } else if (mr.invincible_delta < 0 and self.mon_invincible > 0) {
            self.mon_invincible -%= 1;
        }
        if (mr.change_form) self.doChangeForm();
        if (mr.spawn_type != 0xFF) {
            const tid: u8 = if (mr.spawn_type < 3 and self.form_types[mr.spawn_type] != 0xFF)
                self.form_types[mr.spawn_type]
            else
                mr.spawn_type;
            if (self.gd) |gdata| {
                if (self.objs.activateMonster(tid, gdata)) |slot| {
                    const mi = slot - obj_mod.party_slots;
                    if (mi < 8) {
                        self.mon_types[mi] = tid;
                        if (self.mon_count <= mi) self.mon_count = @intCast(mi + 1);
                    }
                    self.scene.loadMonsterAt(rom, tid, mi);
                    self.syncSpriteSizes();
                }
            }
        }
        self.flash = 4;
        self.spawnMagicFloaters(mr);
        // ShowMsg_02 item name (Cmd_01 $34c7 = $20)
        var nbuf: [16]u8 = undefined;
        const iname = inventory_mod.Inventory.itemName(rom, item_id, &nbuf);
        if (iname.len > 0) self.setMsg(iname) else {
            self.msg_len = 0;
            self.msg_timer = 24;
        }
        self.requeue(attacker);
        self.phase = .message;
        _ = self.checkEnd();
    }

    /// Cmd_01 branches (cmd.asm @eba2):
    ///   $CA → RandSummon; id < $B0 → weapon magic;
    ///   id ≥ $B0 + bag (bit4 clear) → ItemProp; hand equip (bit4 set) → weapon magic.
    fn execItemMagic(
        self: *Host,
        rom: *const rom_mod.Rom,
        attacker: *obj_mod.Obj,
        item_id: u8,
        tslot: usize,
        rng: damage.Rng,
    ) cmd_magic.MagicResult {
        // Summon book (call) $CA — RandSummon @ec12
        if (item_id == offsets.en.summon_book_item) {
            const rs = cmd_magic.randSummonBook(rom, rng);
            var primary = tslot;
            if (rs.single_target) {
                var mons: [8]usize = undefined;
                var n: usize = 0;
                var mi: usize = obj_mod.party_slots;
                while (mi < obj_mod.total_slots) : (mi += 1) {
                    const m = self.objs.objs[mi];
                    if (m.present and m.hp > 0 and !m.status.isKo()) {
                        mons[n] = mi;
                        n += 1;
                    }
                }
                if (n > 0) primary = mons[rng.next() % n];
            } else {
                primary = self.objs.firstLivingMonster() orelse tslot;
            }
            // $3584 summon: power×8, 8 hits
            return cmd_magic.doMagicWeaponOrAttack(rom, rs.attack_id, attacker, primary, &self.objs, rng, self.mon_invincible != 0, true, 8);
        }
        // Weapon magic: id < $B0, or hand-equip (bit4) even if id ≥ $B0
        const from_hand = self.itemIsFromHand();
        if (item_id < item_prop.item_prop_base or from_hand) {
            const eq = equip.EquipProp.load(rom, item_id);
            const spell_id: u8 = if (eq) |e| e.mag_def_base else 0;
            if (spell_id == 0 and !from_hand) {
                return cmd_magic.doItemMagic(rom, item_id, attacker, tslot, &self.objs, rng, self.mon_invincible != 0);
            }
            if (spell_id == 0) {
                return .{ .ok = false, .missed = true };
            }
            const hits = if (item_id < offsets.en.weapon_magic_hits_count)
                cmd_magic.weaponMagicHits(rom, item_id)
            else
                0;
            return cmd_magic.doMagicWeaponOrAttack(rom, spell_id, attacker, tslot, &self.objs, rng, self.mon_invincible != 0, false, hits);
        }
        // Consumable ItemProp (bag, bit4 clear)
        return cmd_magic.doItemMagic(rom, item_id, attacker, tslot, &self.objs, rng, self.mon_invincible != 0);
    }

    fn execMagic(self: *Host, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const rom = self.rom orelse {
            self.menu_mode = .command;
            return;
        };
        if (self.magic_sel >= self.magic_count) {
            self.menu_mode = .command;
            return;
        }
        const spell_id = self.magic_list[self.magic_sel];
        const sp = cmd_magic.loadSpell(rom, spell_id);
        // Primary slot: damage → first mon / target_slot; support → self or target
        var tslot = self.menu_slot;
        if (sp) |p| {
            if (p.is_damage or p.effect == 0 or p.effect == 1 or p.effect == 3 or p.effect == 4 or p.effect == 23 or p.effect == 40) {
                tslot = if (self.target_slot >= obj_mod.party_slots)
                    self.target_slot
                else
                    self.objs.firstLivingMonster() orelse self.menu_slot;
            } else if (p.effect == 10) {
                // Life: first dead ally if any
                var di: usize = 0;
                while (di < obj_mod.party_slots) : (di += 1) {
                    const a = self.objs.objs[di];
                    if (a.present and (a.hp == 0 or a.status.isDead())) {
                        tslot = di;
                        break;
                    }
                }
            }
        }
        // GetCharAttack @a6a1: TimerDur_03 cast_time×2 before DoAttack (unless auto-battle).
        if (sp) |p| {
            if (p.cast_time > 0 and !self.auto_battle.active and self.menu_slot < obj_mod.party_slots) {
                const charge = timer_dur.magicCastHostTicks(p.cast_time, attacker.speed_mod, false);
                self.charge_spell[self.menu_slot] = spell_id;
                self.charge_target[self.menu_slot] = @intCast(@min(tslot, 255));
                attacker.action_timer = charge;
                attacker.action_ready = false;
                self.menu_mode = .command;
                self.phase = .running;
                self.queueSysSfx(audio_mod.sys_sfx_confirm);
                return;
            }
        }
        self.resolvePartyMagic(spell_id, tslot, rng);
    }

    /// Do magic after GetCharAttack charge (or immediately when cast_time 0 / auto).
    fn resolvePartyMagic(self: *Host, spell_id: u8, tslot: usize, rng: damage.Rng) void {
        const attacker = self.objs.get(self.menu_slot);
        const rom = self.rom orelse {
            self.requeue(attacker);
            return;
        };
        const sp = cmd_magic.loadSpell(rom, spell_id);
        const mr = cmd_magic.doMagicEx(rom, spell_id, attacker, tslot, &self.objs, rng, self.mon_invincible != 0, false);
        self.recordHit(self.menu_slot, tslot, 0xC2, if (sp) |p| p.element else 0, mr.amount > 0 and !mr.missed);
        self.menu_mode = .command;
        if (mr.no_mp) {
            self.setBattleMsg(battle_msg.MsgId.not_enough_mp);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // MagicEffect_13 Escape
        if (mr.escaped) {
            if (self.run_state.cant_run) {
                self.setBattleMsg(battle_msg.MsgId.failed);
                self.phase = .message;
                self.requeue(attacker);
                return;
            }
            self.party_escaped = true;
            self.end_flags.ran = true;
            self.setBattleMsg(battle_msg.MsgId.ran_away);
            self.phase = .message;
            return;
        }
        // MagicEffect_12 Libra — HP + weak-elem BattleMsg $14 / $15–$1a
        if (mr.peep_slot != 0xFF) {
            self.showPeepResult(mr.peep_hp, mr.peep_max_hp, mr.peep_weak_bits);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // MagicEffect_32 end battle
        if (mr.end_battle) {
            self.end_flags.ran = true;
            self.phase = .message;
            self.msg_timer = 20;
            return;
        }
        // MagicEffect_2e / $2f invincible counter
        if (mr.invincible_delta > 0) {
            self.mon_invincible +%= @intCast(mr.invincible_delta);
        } else if (mr.invincible_delta < 0) {
            if (self.mon_invincible > 0) self.mon_invincible -%= 1;
        }
        // MagicEffect_31 Change Form
        if (mr.change_form) {
            self.doChangeForm();
            self.flash = 8;
            self.requeue(attacker);
            self.phase = .message;
            self.msg_timer = 30;
            _ = self.checkEnd();
            return;
        }
        // MagicEffect_35 mist dragon: delay mon death + Rydia timer = 10
        if (mr.delay_mon_death) {
            self.delay_mon_death +%= 1;
            if (mr.mist_rydia_slot < obj_mod.party_slots) {
                const ry = self.objs.get(mr.mist_rydia_slot);
                ry.action_timer = 10 * timer_dur.battle_tick_scale;
                ry.action_ready = false;
            }
        }
        // MagicEffect_29 Call/Alert → ActivateMonster (A=1 → form type index 1 or id 1)
        if (mr.spawn_type != 0xFF) {
            const tid: u8 = if (mr.spawn_type < 3 and self.form_types[mr.spawn_type] != 0xFF)
                self.form_types[mr.spawn_type]
            else
                mr.spawn_type;
            if (self.gd) |gdata| {
                if (self.objs.activateMonster(tid, gdata)) |slot| {
                    const mi = slot - obj_mod.party_slots;
                    if (mi < 8) {
                        self.mon_types[mi] = tid;
                        if (self.mon_count <= mi) self.mon_count = @intCast(mi + 1);
                    }
                    if (self.rom) |rr| self.scene.loadMonsterAt(rr, tid, mi);
                    self.syncSpriteSizes();
                    self.flash = 6;
                    self.requeue(attacker);
                    self.phase = .message;
                    self.msg_timer = 24;
                    return;
                }
            }
            self.setBattleMsg(battle_msg.MsgId.failed);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        if (mr.missed) {
            self.setBattleMsg(battle_msg.MsgId.miss);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        if (!mr.ok and mr.amount == 0 and mr.floater_n == 0) {
            self.setBattleMsg(battle_msg.MsgId.nothing_happened);
            self.phase = .message;
            self.requeue(attacker);
            return;
        }
        // PreMagicAnim (cmd_anim @c779) + DoMagicAnim (magic.asm @eac1).
        const name_id = if (mr.summon_attack_id != 0xFF) mr.summon_attack_id else spell_id;
        const present = magic_anim_mod.resolve(rom, name_id);
        // PreMagic id from list column (white/black/call) or summon flag.
        // magic_col 0 white / 1 black / 2 call — menu/magic.asm MagicTypeWindow.
        const pre: fight_anim_mod.PreMagicId = if (present.is_summon or self.magic_col == 2)
            .summon
        else if (self.magic_col == 0)
            .white
        else
            .black;
        self.anim.char_pose = fight_anim_mod.preMagicPose(pre);
        // PreMagicSfxTbl @ea2c
        self.queueSfx(fight_anim_mod.preMagicSfx(pre));
        self.flash = magic_anim_mod.flashFromPal(present.prop.pal);
        if (present.flags.screen_flash) self.flash = @max(self.flash, 10);
        // Darken for summon / black-hole style; lighten applied when gfx Vm ends.
        if (present.flags.darken_bg) self.bg_darken = true;
        self.spawnMagicFloaters(mr);
        // ShowMsg_02 name for HUD while gfx script runs.
        var nbuf: [12]u8 = undefined;
        const sname = cmd_magic.spellName(rom, name_id, &nbuf);
        if (sname.len > 0) {
            self.setMsg(sname);
        } else {
            self.msg_len = 0;
            self.msg_timer = 24;
        }
        // ExecCmd graphics script: $F8,$02, cmd+$C0, [magic id for DoMagicAnim], $F8,$04, $FF
        // Script buffer magic token is attack id ($00–$A8), not AnimProp.script ($f397).
        // DoMagicAnim reads ($3f) as that id then loads AnimProp.
        var gbuf: [16]u8 = undefined;
        const glen = buildPartyCmdGfxScript(0x02, name_id, &gbuf); // cmd $02 = magic
        self.anim.attacker = if (self.menu_slot < obj_mod.party_slots) self.menu_slot else 0;
        // PreMagicAnim2 frame formula + MagicAnimTbl wait_frames
        const pre_w = fight_anim_mod.preMagicWaitFrames(pre);
        const anim_w = present.flags.wait_frames;
        self.msg_timer = @max(self.msg_timer, pre_w +% anim_w);
        self.requeue(attacker);
        self.beginGfxScript(gbuf[0..glen]);
        if (present.flags.darken_bg) self.bg_darken = true;
        _ = self.checkEnd();
    }

    fn spawnMagicFloaters(self: *Host, mr: cmd_magic.MagicResult) void {
        var i: u8 = 0;
        while (i < mr.floater_n) : (i += 1) {
            const s = mr.floater_slot[i];
            if (s >= obj_mod.total_slots) continue;
            const t = self.objs.get(s);
            self.floaters.spawn(@intCast(t.centerX()), @intCast(t.centerY()), mr.floater_amt[i], false, false);
        }
        // Toad/pig/mini toggle may have changed form — ReloadCharGfx.
        self.reloadPartyFormGfx();
    }

    /// ReloadCharGfx for any party member whose sheet id no longer matches status form.
    fn reloadPartyFormGfx(self: *Host) void {
        const rom = self.rom orelse return;
        if (!self.scene.loaded) return;
        var pi: usize = 0;
        while (pi < obj_mod.party_slots) : (pi += 1) {
            const o = self.objs.party(pi);
            if (!o.present) continue;
            const want = status_mod.battleCharGfxId(o.class_id, o.status.s1);
            if (want == o.gfx_id) continue;
            o.gfx_id = want;
            // scene.chars is packed by load order of present members when dense party.
            // Prefer slot index when available; fall back to pi.
            self.scene.reloadCharAt(rom, pi, want);
        }
        self.syncSpriteSizes();
    }

    /// Activate N copies of mon type_id (ActivateMonster loop).
    fn activateN(self: *Host, type_id: u8, n: u8) void {
        if (n == 0 or type_id == 0xFF) return;
        const gdata = self.gd orelse return;
        var k: u8 = 0;
        while (k < n) : (k += 1) {
            if (self.objs.activateMonster(type_id, gdata)) |slot| {
                const mi = slot - obj_mod.party_slots;
                if (mi < 8) {
                    self.mon_types[mi] = type_id;
                    if (self.mon_count <= mi) self.mon_count = @intCast(mi + 1);
                }
                if (self.rom) |rr| self.scene.loadMonsterAt(rr, type_id, mi);
            }
        }
        self.syncSpriteSizes();
    }

    /// MagicEffect_31 Change Form (magic.asm @de34–@df5e).
    fn doChangeForm(self: *Host) void {
        const raw = self.form_counts_raw;
        const c0 = self.form_counts[0];
        const c1 = self.form_counts[1];
        const c2 = self.form_counts[2];
        // Map formation type indices through battle prop mon_type when present
        const t0: u8 = if (self.form_types[0] != 0xFF) self.form_types[0] else 0;
        const t1: u8 = if (self.form_types[1] != 0xFF) self.form_types[1] else 1;
        const t2: u8 = if (self.form_types[2] != 0xFF) self.form_types[2] else 2;

        if ((raw & 0x03) == 0x03) {
            if (self.objs.hasLivingType(t2)) {
                self.objs.deactivateMonsterTypes(t2, 0xFF);
                self.activateN(t0, c0);
                self.activateN(t1, c1);
            } else {
                self.objs.deactivateMonsterTypes(t0, t1);
                self.activateN(t2, c2);
            }
            return;
        }

        const sum = self.objs.sumLivingMonTypeIds();
        if (sum == 0) {
            self.activateN(t1, c1);
            self.activateN(t2, c2);
        } else {
            self.objs.deactivateMonsterTypes(t1, t2);
            self.activateN(t0, c0);
        }
    }

    /// WinUpdate totals for the formation (call with GameData after victory).
    pub fn calcRewards(self: *const Host, gd: *const data_mod.GameData) win_mod.Rewards {
        return win_mod.calcRewards(self.mon_types[0..self.mon_count], self.mon_count, gd);
    }

    /// WinUpdate with item drops (win.asm @ec72). Uses battle RNG for drop rolls.
    pub fn calcRewardsWithDrops(self: *Host, gd: *const data_mod.GameData) win_mod.Rewards {
        const rom = self.rom orelse return self.calcRewards(gd);
        const Ctx = struct {
            rng: *rom_rng.RomRng,
            fn r99(ctx: *anyopaque) u8 {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                return s.rng.randXA(0, 98);
            }
            fn r255(ctx: *anyopaque) u8 {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                return s.rng.nextByte();
            }
        };
        var ctx: Ctx = .{ .rng = &self.rng };
        return win_mod.calcRewardsWithDrops(
            self.mon_types[0..self.mon_count],
            self.mon_count,
            gd,
            rom,
            Ctx.r99,
            Ctx.r255,
            &ctx,
        );
    }

    /// CheckBattleEnd (battle.asm @a015) via pure `check_end.evaluate`.
    pub fn checkEnd(self: *Host) bool {
        if (self.end_flags.any()) return true;
        // Defer while death/victory anim plays.
        if (self.phase == .animating and (self.anim.kind == .mon_death or self.anim.kind == .victory)) {
            return false;
        }
        const flags = check_end_mod.evaluate(.{
            .any_able_party = self.anyAbleParty(),
            .any_mons = self.objs.livingMonsters() > 0,
            .auto_battle = self.auto_battle.active,
            // Ran path: tryFlee/tickFlee set end_flags.ran directly (battle.asm @a07e).
            // Do NOT treat $38d6==0 alone as flee — GetCharAttack zeros the counter
            // on every menu open (char.asm @a396) without ending the battle.
            .run_attempt = false,
            .run_ready = false,
            .cant_run = self.run_state.cant_run,
            .no_fail = false, // $38e5 bit1 not tracked on host yet
            .battle_id = self.battle_id,
            .any_runnable_party = self.anyRunnableParty(),
        });
        if (flags.victory) {
            self.end_flags.victory = true;
            // `$a8` bit4: NoUpdateBattleTbl → skip WinUpdate only (check_end).
            self.no_party_update = !flags.update_party or self.no_party_update;
            self.gil_gained = 0;
            self.exp_gained = 0;
            // CheckFanfare @8728: queue fanfare `$08` or silence (battle_song.zig).
            const fanfare = battle_song_mod.victorySongId(self.battle_id, self.battle_flags);
            if (fanfare != 0xFF) {
                self.setSong(fanfare);
            } else if (battle_song_mod.noBattleMusic(self.battle_flags)) {
                self.setSong(audio_mod.battle_song_none);
            }
            // CheckWinAnim: skip long victory gfx when in NoWinAnimTbl.
            if (self.no_win_anim or battle_song_mod.shouldSkipWinAnim(self.battle_id)) {
                self.msg_len = 0;
                self.msg_timer = 12;
                self.phase = .message;
            } else {
                self.anim = .{ .kind = .victory, .t = 0, .char_pose = .victory };
                self.setBattleMsg(battle_msg.MsgId.won);
                self.msg_timer = 50;
                self.phase = .animating;
            }
            return true;
        }
        if (flags.wiped) {
            self.end_flags.defeated = true;
            self.msg_len = 0;
            self.phase = .message;
            self.msg_timer = 50;
            return true;
        }
        if (flags.ran) {
            self.end_flags.ran = true;
            self.msg_len = 0;
            self.phase = .message;
            self.msg_timer = 20;
            return true;
        }
        return false;
    }

    fn anyAbleParty(self: *const Host) bool {
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            const o = self.objs.objs[i];
            if (!o.present) continue;
            if ((o.status.s1 & 0xC0) != 0) continue; // dead/stone
            if ((o.status.s3 & 0x80) != 0) continue; // hiding
            return true;
        }
        return false;
    }

    fn anyRunnableParty(self: *const Host) bool {
        var i: usize = 0;
        while (i < obj_mod.party_slots) : (i += 1) {
            const o = self.objs.objs[i];
            if (!o.present) continue;
            if ((o.status.s1 & 0xC0) != 0) continue;
            if ((o.status.s2 & 0x30) != 0) continue; // para/sleep
            if ((o.status.s3 & 0xC2) != 0) continue; // mag/stop/jump
            return true;
        }
        return false;
    }

    /// After message timer on terminal outcomes, close battle.
    pub fn pollFinished(self: *Host) bool {
        if (!self.end_flags.any()) return false;
        if (self.phase == .animating and self.anim.kind == .victory) return false;
        if (self.phase == .message and self.msg_timer > 0) return false;
        if (self.phase == .animating and self.anim.kind == .mon_death) return false;
        if (self.active or self.phase != .done) {
            self.phase = .done;
            self.active = false;
        }
        return self.end_flags.any();
    }

    /// True if mon slot i (0..7) is dissolving (MonsterDeathAnim).
    pub fn monDying(self: *const Host, mon_i: usize) bool {
        if (self.anim.kind != .mon_death) return false;
        if (mon_i >= 8) return false;
        return (self.anim.death_mask & (@as(u8, 1) << @intCast(mon_i))) != 0;
    }

    pub fn leader(self: *Host) *obj_mod.Obj {
        return self.objs.get(0);
    }

    /// Copy composed sprite W/H from Scene onto battle objects.
    fn syncSpriteSizes(self: *Host) void {
        if (!self.scene.loaded) return;
        var mi: usize = 0;
        while (mi < 8) : (mi += 1) {
            const m = self.scene.monsters[mi];
            if (m.w == 0 or m.h == 0) continue;
            const o = self.objs.monster(mi);
            if (!o.present) continue;
            o.sprite_w = m.w;
            o.sprite_h = m.h;
        }
        var ci: usize = 0;
        while (ci < obj_mod.party_slots) : (ci += 1) {
            const ch = self.scene.chars[ci];
            if (ch.w == 0) continue;
            const o = self.objs.party(ci);
            if (!o.present) continue;
            o.sprite_w = ch.w;
            o.sprite_h = ch.h;
        }
        self.refreshMonRows();
    }

    /// UpdateMonsterRows (@e988) — left-column front flags for name plates.
    fn refreshMonRows(self: *Host) void {
        var present: [8]bool = .{false} ** 8;
        var xs: [8]i16 = .{0} ** 8;
        var mi: usize = 0;
        while (mi < 8) : (mi += 1) {
            const o = self.objs.monster(mi);
            present[mi] = o.present and o.hp > 0;
            xs[mi] = @intCast(o.screen_x);
        }
        self.mon_row_front = mon_rows_mod.updateMonsterRows(&present, &xs);
    }
};

test "BattleSpeedTbl reload values" {
    // Embed path: setting 0→1, 2→4 (default), 5→11
    try std.testing.expectEqual(@as(u8, 1), Host.battleSpeedReload(null, 0));
    try std.testing.expectEqual(@as(u8, 4), Host.battleSpeedReload(null, 2));
    try std.testing.expectEqual(@as(u8, 11), Host.battleSpeedReload(null, 5));
    try std.testing.expectEqual(@as(u8, 11), Host.battleSpeedReload(null, 99)); // clamp
}

test "buildPartyCmdGfxScript matches ExecCmd prefix" {
    // attack.asm @b11c: F8,02, cmd+$C0, [magic id], F8,04, FF
    var buf: [16]u8 = undefined;
    const n = Host.buildPartyCmdGfxScript(0x00, 0xFF, &buf); // fight, no magic
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u8, 0xF8), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xC0), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xF8), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[4]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[5]);

    const nm = Host.buildPartyCmdGfxScript(0x02, 0x0E, &buf); // magic Cure id $0E
    try std.testing.expectEqual(@as(usize, 7), nm);
    try std.testing.expectEqual(@as(u8, 0xC2), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x0E), buf[3]);
}

test "beginGfxScript runs Vm to end" {
    var h: Host = .{ .active = true, .phase = .running, .msg_speed = 0 };
    var scr = [_]u8{ 0xF0, 0x03, 0xF3, 0x1A, 0xFF };
    h.beginGfxScript(&scr);
    try std.testing.expect(h.phase == .animating);
    try std.testing.expect(h.anim.kind == .gfx_script);
    try std.testing.expect(h.gfx_vm.active());
    // First tick applies boss frame
    h.tickGfxScript();
    try std.testing.expectEqual(@as(u8, 3), h.boss_frame[0]);
    // Song next
    h.tickGfxScript();
    try std.testing.expectEqual(@as(u8, 0x1A), h.song_id);
    // End
    h.tickGfxScript();
    try std.testing.expect(!h.gfx_vm.active());
}

test "buildDlgGfxScript F1 ids" {
    var out: [32]u8 = undefined;
    const ids = [_]u8{ 0x05, 0x06 };
    const n = Host.buildDlgGfxScript(&ids, true, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u8, 0xF1), out[0]);
    try std.testing.expectEqual(@as(u8, 0x05), out[1]);
    try std.testing.expectEqual(@as(u8, 0xF1), out[2]);
    try std.testing.expectEqual(@as(u8, 0x06), out[3]);
    try std.testing.expectEqual(@as(u8, 0xFF), out[4]);
}

test "opener msg priority via opener.openerMsgId" {
    try std.testing.expectEqual(@as(?u8, opener_mod.msg_back), opener_mod.openerMsgId(true, 0x80));
    try std.testing.expectEqual(@as(?u8, opener_mod.msg_surprise), opener_mod.openerMsgId(false, 0x80));
    try std.testing.expectEqual(@as(?u8, opener_mod.msg_first), opener_mod.openerMsgId(false, 1));
    try std.testing.expectEqual(@as(?u8, null), opener_mod.openerMsgId(false, 0));
}

test "mon attacks party after enough ticks without menu freeze" {
    var h: Host = .{
        .active = true,
        .phase = .running,
        .battle_mode = 1, // Active
        .speed_reload = 1,
        .speed_counter = 1,
    };
    h.objs.objs[0] = .{
        .present = true,
        .hp = 200,
        .max_hp = 200,
        .agility = 5,
        .is_monster = false,
        .slot_index = 0,
        .hit_rate = 99,
        .attack_mult = 2,
        .attack = 20,
        .defense = 5,
    };
    h.objs.objs[5] = .{
        .present = true,
        .hp = 100,
        .max_hp = 100,
        .agility = 20, // mon faster
        .is_monster = true,
        .slot_index = 5,
        .ai_action_id = 0xFF,
        .hit_rate = 99,
        .attack_mult = 2,
        .attack = 15,
        .defense = 0,
        .defense_rate = 0,
        .defense_mult = 0,
    };
    timer_dur.initAllTimers(&h.objs);
    // Force mon ready immediately
    h.objs.objs[5].action_timer = 1;
    h.objs.objs[5].action_ready = false;
    h.objs.objs[0].action_timer = 9999;
    h.objs.objs[0].action_ready = false;

    const rng = h.battleRng();

    var saw_mon_fight = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        h.tick(rng);
        if (h.phase == .animating and h.anim.kind == .mon_fight) {
            saw_mon_fight = true;
            break;
        }
        // don't get stuck in message
        if (h.phase == .message and h.msg_timer > 2) h.msg_timer = 1;
    }
    try std.testing.expect(saw_mon_fight);
    const hp_before = h.objs.objs[0].hp;
    // Run anim through impact
    var j: usize = 0;
    while (j < 30) : (j += 1) h.tick(rng);
    // Hit applied or miss floater — mon action completed
    try std.testing.expect(h.objs.objs[0].hp <= hp_before);
}

test "Cmd_06 Jump1 then Cmd_1e land uses stored mon and 2x atk path" {
    var h: Host = .{
        .active = true,
        .phase = .menu,
        .menu_mode = .command,
        .menu_slot = 0,
        .battle_mode = 1,
        .speed_reload = 1,
        .speed_counter = 1,
    };
    h.objs.objs[0] = .{
        .present = true,
        .hp = 200,
        .max_hp = 200,
        .agility = 20,
        .is_monster = false,
        .slot_index = 0,
        .hit_rate = 99,
        .attack_mult = 4,
        .attack = 30,
        .defense = 0,
        .char_id = 1, // Kain-ish
    };
    // Two mons: Jump targets mon slot 6 (second mon), not first
    h.objs.objs[5] = .{
        .present = true,
        .hp = 500,
        .max_hp = 500,
        .agility = 1,
        .is_monster = true,
        .slot_index = 5,
        .defense = 0,
        .defense_rate = 0,
        .defense_mult = 0,
    };
    h.objs.objs[6] = .{
        .present = true,
        .hp = 500,
        .max_hp = 500,
        .agility = 1,
        .is_monster = true,
        .slot_index = 6,
        .defense = 0,
        .defense_rate = 0,
        .defense_mult = 0,
    };
    timer_dur.initAllTimers(&h.objs);
    h.objs.objs[0].action_ready = true;
    h.objs.objs[0].action_timer = 0;
    h.objs.objs[5].action_timer = 9999;
    h.objs.objs[6].action_timer = 9999;

    h.target_slot = 6;
    h.execJump1();
    try std.testing.expect(h.objs.objs[0].status.isJumping());
    try std.testing.expectEqual(@as(u8, 6), h.objs.objs[0].jump_target);
    try std.testing.expectEqual(cmd_special_mod.jump1HostTicks(), h.objs.objs[0].jump_timer);
    try std.testing.expectEqual(@as(u16, 0), h.objs.objs[0].action_timer); // air uses jump_timer only
    // Party→party illegal
    h.objs.objs[0].status.setJumping(false);
    h.objs.objs[0].jump_timer = 0;
    h.target_slot = 0;
    h.execJump1();
    try std.testing.expect(!h.objs.objs[0].status.isJumping());

    // Re-jump at mon 6 and land
    h.target_slot = 6;
    h.execJump1();
    h.objs.objs[0].jump_timer = 0; // force land
    h.clearMsg();
    h.phase = .running;
    const mon6_hp = h.objs.objs[6].hp;
    const mon5_hp = h.objs.objs[5].hp;
    h.doJumpLand(0, h.battleRng());
    try std.testing.expect(!h.objs.objs[0].status.isJumping());
    try std.testing.expectEqual(@as(usize, 6), h.anim.target);
    try std.testing.expect(h.phase == .animating);
    // Damage pending for mon 6 only (impact later); mon 5 untouched so far
    try std.testing.expectEqual(mon5_hp, h.objs.objs[5].hp);
    try std.testing.expectEqual(mon6_hp, h.objs.objs[6].hp); // HP applied at impact
}

test "message hold clears msg_len (CloseMsgWindow)" {
    var h: Host = .{
        .active = true,
        .phase = .message,
        .msg_speed = 0, // MsgDurTbl[0] = $20
        .speed_reload = 99, // freeze ATB so mon/party never act mid-hold
        .speed_counter = 99,
    };
    // Living party + mon so CheckBattleEnd does not wipe/victory mid-hold.
    h.objs.objs[0] = .{
        .present = true,
        .hp = 100,
        .max_hp = 100,
        .slot_index = 0,
        .action_timer = 9999,
        .action_ready = false,
    };
    h.objs.objs[5] = .{
        .present = true,
        .hp = 50,
        .max_hp = 50,
        .is_monster = true,
        .slot_index = 5,
        .action_timer = 9999,
        .action_ready = false,
    };
    h.setMsg("TEST");
    const hold = h.msg_timer;
    try std.testing.expect(h.msg_len == 4);
    try std.testing.expect(hold > 0);
    // Drain message timer (field frames, not battle-speed gated)
    var i: usize = 0;
    while (i < hold) : (i += 1) {
        h.tick(h.battleRng());
    }
    // One more tick to process timer==0 → clearMsg
    h.tick(h.battleRng());
    try std.testing.expectEqual(@as(usize, 0), h.msg_len);
    try std.testing.expectEqual(@as(u8, 0), h.msg_timer);
    try std.testing.expect(h.phase == .running);
}

// Wait mode: after party acts, mon that was already ready must get a turn.
test "wait mode mon acts after party turn when mon already ready" {
    var h: Host = .{
        .active = true,
        .phase = .running,
        .battle_mode = 0, // Wait
        .speed_reload = 1,
        .speed_counter = 1,
    };
    h.objs.objs[0] = .{
        .present = true,
        .hp = 200,
        .max_hp = 200,
        .agility = 16,
        .is_monster = false,
        .slot_index = 0,
        .hit_rate = 99,
        .attack_mult = 2,
        .attack = 20,
        .defense = 0,
        .defense_rate = 0,
        .defense_mult = 0,
        .class_id = 0,
    };
    h.objs.objs[5] = .{
        .present = true,
        .hp = 9999, // survive party hit so mon still acts after
        .max_hp = 9999,
        .agility = 8,
        .is_monster = true,
        .slot_index = 5,
        .ai_action_id = 0xFF,
        .hit_rate = 99,
        .attack_mult = 2,
        .attack = 15,
        .defense = 0,
        .defense_rate = 0,
        .defense_mult = 0,
    };
    timer_dur.initAllTimers(&h.objs);
    // Both ready; party will open menu first if priority starts at 0
    h.objs.objs[0].action_timer = 0;
    h.objs.objs[0].action_ready = true;
    h.objs.objs[5].action_timer = 0;
    h.objs.objs[5].action_ready = true;
    h.priority_slot = 0;

    const rng = h.battleRng();
    h.tick(rng);
    try std.testing.expect(h.phase == .menu);
    try std.testing.expectEqual(@as(usize, 0), h.menu_slot);
    // Mon still ready under Wait freeze
    try std.testing.expect(h.objs.objs[5].action_ready);

    // Party fight → mon target
    h.target_slot = 5;
    h.startPartyFight(rng);
    try std.testing.expect(h.phase == .animating);

    // Run until mon fights (after party anim + msg hold)
    var saw = false;
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        if (h.phase == .animating and h.anim.kind == .mon_fight) {
            saw = true;
            break;
        }
        h.tick(rng);
        if (h.phase == .message and h.msg_timer > 1) h.msg_timer = 1;
    }
    try std.testing.expect(saw);
}

// Full enter() with ROM: mon forced ready should fight.
test "enter battle mon fight with rom" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var r = rom_mod.load(io, gpa, "Final Fantasy II.smc") catch return;
    defer r.deinit();
    var gd = data_mod.extract(gpa, &r) catch return;
    defer gd.deinit();

    var inv: inventory_mod.Inventory = .{};
    var party = [_]state_mod.PartyMember{.{
        .present = true,
        .id = 0,
        .class_id = 0,
        .hp = 200,
        .max_hp = 200,
        .mp = 20,
        .max_mp = 20,
        .level = 10,
        .agility = 5,
        .right_hand = 0x17,
    }};

    var h: Host = .{};
    try h.enter(gpa, &r, &gd, 0, 0, &inv, party[0..], false, 0, 2, 1, 0); // Active
    defer h.deinitScene();

    var mi: usize = obj_mod.party_slots;
    while (mi < obj_mod.total_slots) : (mi += 1) {
        if (h.objs.objs[mi].present) {
            h.objs.objs[mi].action_timer = 1;
            h.objs.objs[mi].action_ready = false;
        }
    }
    var pi: usize = 0;
    while (pi < obj_mod.party_slots) : (pi += 1) {
        if (h.objs.objs[pi].present) {
            h.objs.objs[pi].action_timer = 9999;
            h.objs.objs[pi].action_ready = false;
        }
    }
    h.phase = .running;
    h.msg_timer = 0;
    h.msg_len = 0;

    const rng = h.battleRng();
    var saw = false;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        h.tick(rng);
        if (h.phase == .animating and h.anim.kind == .mon_fight) {
            saw = true;
            break;
        }
        if (h.phase == .message and h.msg_timer > 1) h.msg_timer = 1;
    }
    if (!saw) {
        mi = obj_mod.party_slots;
        while (mi < obj_mod.total_slots) : (mi += 1) {
            const o = h.objs.objs[mi];
            if (!o.present) continue;
            std.debug.print("mon {d}: ready={} t={d} is_mon={} ai={d} hp={d} canAct={}\n", .{
                mi, o.action_ready, o.action_timer, o.is_monster, o.ai_action_id, o.hp, o.status.canAct(),
            });
        }
        std.debug.print("phase={s} anim={s}\n", .{ @tagName(h.phase), @tagName(h.anim.kind) });
    }
    try std.testing.expect(saw);
}

test "victory fanfare CheckFanfare sets song $08" {
    var h: Host = .{
        .active = true,
        .battle_id = 0x0001,
        .battle_flags = 0x00, // has battle music
        .song_id = 0x1A,
    };
    // Living party, no mons → victory
    h.objs.objs[0].present = true;
    h.objs.objs[0].hp = 10;
    h.objs.objs[0].status.s1 = 0;
    // no monsters present
    _ = h.checkEnd();
    try std.testing.expect(h.end_flags.victory);
    try std.testing.expectEqual(battle_song_mod.victory_fanfare_song, h.song_id);
    try std.testing.expect(h.song_dirty);
    try std.testing.expectEqual(@as(?u8, 0x08), h.consumeSongChange());
}

test "GfxScript F3 mid-fight song dirties for app" {
    // Host.applyGfxEffect(.song) / setSong — same path as Vm `$F3` token.
    var h: Host = .{ .active = true, .phase = .running, .song_id = 0x1A };
    h.setSong(0x2C);
    try std.testing.expectEqual(@as(u8, 0x2C), h.song_id);
    try std.testing.expectEqual(@as(?u8, 0x2C), h.consumeSongChange());
    try std.testing.expect(h.consumeSongChange() == null);
}

test "syncPartyOut always writes status even when NoUpdate" {
    // RestoreCharProp always runs; no_party_update only gates WinUpdate.
    var h: Host = .{};
    h.no_party_update = true;
    h.objs.objs[0].present = true;
    h.objs.objs[0].hp = 12;
    h.objs.objs[0].mp = 3;
    h.objs.objs[0].max_hp = 100;
    h.objs.objs[0].max_mp = 20;
    h.objs.objs[0].level = 7;
    h.objs.objs[0].left_hand = 0x60;
    h.objs.objs[0].right_hand = 0;
    h.objs.objs[0].status.s1 = status_mod.Status1.poison | status_mod.Status1.toad;
    h.objs.objs[0].status.s2 = status_mod.Status2.float_bit;

    var party: [5]state_mod.PartyMember = [_]state_mod.PartyMember{.{}} ** 5;
    party[0] = .{
        .present = true,
        .id = 1,
        .hp = 99,
        .mp = 99,
        .max_hp = 99,
        .max_mp = 99,
        .level = 1,
        .status1 = 0,
        .status2 = 0,
    };
    h.syncPartyOut(party[0..]);
    try std.testing.expectEqual(@as(u16, 12), party[0].hp);
    try std.testing.expectEqual(@as(u16, 3), party[0].mp);
    try std.testing.expectEqual(@as(u8, 7), party[0].level);
    try std.testing.expectEqual(status_mod.Status1.poison | status_mod.Status1.toad, party[0].status1);
    try std.testing.expectEqual(status_mod.Status2.float_bit, party[0].status2);
    try std.testing.expect(!h.shouldWinUpdate());
}

