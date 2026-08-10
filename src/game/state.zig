//! Field game state: overworld + sub-maps, triggers, NPCs, party, inventory.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const data_mod = @import("../data.zig");
const overworld_mod = @import("../map/overworld.zig");
const submap_mod = @import("../map/submap.zig");
const npc_mod = @import("../map/npc.zig");
const vehicle_mod = @import("../map/vehicle.zig");
const earth_moon_mod = @import("../map/earth_moon.zig");
const ui_mod = @import("../gfx/ui.zig");
const ai_local = @import("../ai/local.zig");
const voice_profile = @import("../ai/voice_profile.zig");
const lore_mod = @import("../ai/lore.zig");
const map_names = @import("../ai/map_names.zig");
const triggers_mod = @import("../map/triggers.zig");
const inventory_mod = @import("inventory.zig");
const fat_choco_mod = @import("fat_choco.zig");
const event_mod = @import("event.zig");
const party_mod = @import("party.zig");
const field_fx_mod = @import("field_fx.zig");
const special_ids_mod = @import("special_ids.zig");
const dlg_auto_mod = @import("dlg_auto.zig");
const namingway_mod = @import("namingway.zig");
const init_new_game_mod = @import("init_new_game.zig");
const solo_battle_mod = @import("../battle/solo_battle.zig");
const cmd_magic_mod = @import("../battle/cmd_magic.zig");
const status_mod = @import("../battle/status.zig");



/// Overworld tile outside Baron castle (post-intro free roam).
pub const new_game_overworld_x: i32 = 102;
pub const new_game_overworld_y: i32 = 158;

/// WipeScanlineTbl @ field_data.asm $fb1e — 32 × (half_width, half_height) for iris window.
/// Index = wipe $79 step (0..31). Used by UpdateWipeNMI WH0/WH1 + VTimer.
const wipe_scanline_tbl = [_]u8{
    0x7F, 0x6E, 0x7E, 0x6E, 0x7E, 0x6E, 0x7D, 0x6D, 0x7C, 0x6C, 0x7B, 0x6B, 0x79, 0x6A, 0x77, 0x68,
    0x75, 0x66, 0x72, 0x64, 0x70, 0x61, 0x6C, 0x5F, 0x69, 0x5C, 0x66, 0x59, 0x62, 0x55, 0x5E, 0x52,
    0x59, 0x4E, 0x55, 0x4A, 0x50, 0x46, 0x4B, 0x42, 0x46, 0x3D, 0x41, 0x39, 0x3B, 0x34, 0x36, 0x2F,
    0x30, 0x2A, 0x2A, 0x25, 0x24, 0x20, 0x1E, 0x1A, 0x18, 0x15, 0x12, 0x10, 0x0C, 0x0A, 0x06, 0x05,
};

pub const FieldMode = enum { overworld, submap };

pub const PartyMember = struct {
    id: u8 = 0,
    /// Battle class / ClassCmd index (often matches gfx id early game).
    class_id: u8 = 0,
    /// BattleCharGfx id.
    gfx_id: u8 = 0,
    level: u8 = 1,
    hp: u16 = 0,
    max_hp: u16 = 0,
    mp: u16 = 0,
    max_mp: u16 = 0,
    strength: u8 = 0,
    agility: u8 = 0,
    vitality: u8 = 0,
    wisdom: u8 = 0,
    will: u8 = 0,
    /// Hands ($2033/$2035) — item ids; 0 = empty.
    left_hand: u8 = 0,
    right_hand: u8 = 0,
    /// Helmet / armor / accessory ($1030–$1032).
    head: u8 = 0,
    body: u8 = 0,
    arms: u8 = 0,
    /// Accumulated experience ($1037, 24-bit in ROM; we keep u32).
    exp: u32 = 0,
    /// Field status1/2 ($1003/$1004) — poison etc. after battle / status items.
    status1: u8 = 0,
    status2: u8 = 0,
    /// $1000 bits 6–7 handedness (CharProp / DrawMenuText HandednessText).
    /// $00 right, $40 left, $80/$C0 both — index into HandednessText is (flags>>3).
    handedness: u8 = 0,
    present: bool = false,
};

pub const GameState = struct {
    mode: FieldMode = .overworld,
    /// 0=OW, 1=under, 2=moon when on world; unused in submap mode.
    world_id: u8 = 0,
    map_id: u16 = 0,
    pos_x: i32 = new_game_overworld_x,
    pos_y: i32 = new_game_overworld_y,
    facing: u8 = 2,
    /// Event $C8/$C9: hide player sprite ($d3).
    player_hidden: bool = false,
    /// Event $CF: spin flag ($d8). DrawPlayerSub forces pose 8 while set.
    player_spin: bool = false,
    /// `$cf` (EventCmd $CE toggle): when set, walking does not update facing
    /// (CheckPlayerMoveSub skips `$1705` write; NPC event walks skip `$0909` write).
    party_follow: bool = false,
    /// $d2 — current z-level mask (UpdateLocalTiles / CheckPlayerMoveSub).
    /// Bits 0–1 from standing tile prop lo; used for bridge hide tests.
    party_z: u8 = 0x03,

    /// Movement matches field/move.asm MovePlayer:
    /// $ab direction: 0=none, 1=up, 2=right, 3=down, 4=left
    /// scroll 1 px/frame on foot (PlayerMoveRateTbl[0]=1), tile updates every 16 px.
    move_dir: u8 = 0,
    /// Pixels progressed within the current 16px step (0..15).
    move_px: u8 = 0,
    /// Party animation counter $7b — incremented every field while moving.
    party_frame: u8 = 0,

    event_switch: [0x20]u8 = .{0} ** 0x20,
    npc_switch: [0x40]u8 = .{0} ** 0x40,
    /// Treasure switches $12a0–$12df (64 bytes).
    treasure_switch: [0x40]u8 = .{0} ** 0x40,
    party: [5]PartyMember = [_]PartyMember{.{}} ** 5,
    /// $1703 — party slot drawn as field leader (EventCmd_dd / ValidateTopChar).
    field_leader_slot: u8 = 0,
    /// Runtime spell lists $1560 (13×24) — InitSpellLists + EventCmd_e2.
    spell_lists: cmd_magic_mod.SpellLists = undefined,
    inventory: inventory_mod.Inventory = .{},
    /// Fat chocobo storage `$1340` (menu/fat_choco.asm) — 126×{id,qty}.
    fat_choco: fat_choco_mod.Bag = .{},
    gil: u32 = 0,
    /// Config $16ac battle speed index 0..5 (BattleSpeedTbl). Default 2 → reload 4.
    battle_speed: u8 = 2,
    /// Config $16ad battle message speed 0..5 (MsgDurTbl). Default 2 → 96 frames.
    msg_speed: u8 = 2,
    /// Config $16be: 0 = Wait (ATB pauses on menu), 1 = Active (ATB continues). Default 0 (InitRAM).
    /// Not shown on US SIMPLE_CONFIG screen; kept for battle ATB.
    battle_mode: u8 = 0,
    /// Config $16b6 stereo/mono (0 stereo, 1 mono). SIMPLE_CONFIG Sound row.
    stereo_mono: u8 = 0,
    /// Config $16aa window fill color (SNES BGR555). Default WindowPal[1] = $4000.
    window_color: u16 = 0x4000,
    /// Working components $1ba8–$1baa (0..31) while Config is open; synced from/to $16aa.
    window_color_r: u8 = 0,
    window_color_g: u8 = 0,
    window_color_b: u8 = 16,
    /// Config $16a8 party row: 0 = slots 0–2 front / 3–4 back; nonzero = swapped (init.asm InitCharRows).
    party_row: u8 = 0,
    /// One-shot SFX request for the app audio layer (0 = none).
    pending_sfx: u8 = 0,
    /// `$1a02` — tent/save enabled (on foot overworld, or submap save-point tile).
    save_enabled: bool = false,
    /// Field free-roam NPC RNG (CheckMoveNPCs `Rand`); not battle RNGTbl.
    field_rng: u32 = 0xA5A5A5A5,

    // --- Vehicles ($1704 + parked slots $170f–$172b) — field/vehicle.asm ---
    /// `$1704`: 0 none, 1 choco, 2 bk choco, 3 hover, 4 enterprise, 5 falcon, 6 whale, 7 ship.
    vehicle: u8 = 0,
    /// `$ac` speed class → PlayerMoveRateTbl (UpdatePlayerSpeed / Board*).
    move_speed_class: u8 = 0,
    /// Parked chocobo `$170f` / `$1710–$1711` (vis: 0=off, 1=parked).
    choco_vis: u8 = 0,
    choco_x: u8 = 0,
    choco_y: u8 = 0,
    /// Black chocobo `$1712` / `$1713–$1714` / `$1715` hook state.
    bk_choco_vis: u8 = 0,
    bk_choco_x: u8 = 0,
    bk_choco_y: u8 = 0,
    bk_choco_hook: u8 = 0,
    /// Hovercraft `$1718` / `$1719–$171a` / `$171b` world.
    hover_vis: u8 = 0,
    hover_x: u8 = 0,
    hover_y: u8 = 0,
    hover_world: u8 = 0,
    /// Enterprise `$171c` / `$171d–$171e` / `$171f`.
    enterprise_vis: u8 = 0,
    enterprise_x: u8 = 0,
    enterprise_y: u8 = 0,
    enterprise_world: u8 = 0,
    /// Falcon `$1720` / `$1721–$1722` / `$1723`.
    falcon_vis: u8 = 0,
    falcon_x: u8 = 0,
    falcon_y: u8 = 0,
    falcon_world: u8 = 0,
    /// Big whale `$1724` / `$1725–$1726` / `$1727`.
    whale_vis: u8 = 0,
    whale_x: u8 = 0,
    whale_y: u8 = 0,
    whale_world: u8 = 0,
    /// Ship `$1728` / `$172a–$172b` (word pos).
    ship_vis: u8 = 0,
    ship_x: u8 = 0,
    ship_y: u8 = 0,
    /// Board/land cutscene anim (Animate4/8 loops in vehicle.asm).
    vehicle_anim: vehicle_mod.Anim = .{},
    /// `$06d0` — enterprise is holding hovercraft on hook.
    holding_hover: bool = false,
    /// Pending dismount after land anim completes (park coords filled at start).
    vehicle_land_pending: bool = false,
    /// Vehicle id being landed (needed when LandChoco zeros `$1704` mid-flee).
    vehicle_land_id: u8 = 0,
    /// Whale land: run ExecTriggerScript `$52` after dismount (WhaleButton @a851).
    pending_whale_script: bool = false,
    /// `$ce` tunnel: after tunnel anim, warp OW↔under (field.asm @811a).
    pending_tunnel: enum { none, down, up } = .none,
    /// GoUpTunnel: DrillAnim after event `$C6` finishes (when `$3d` && !`$30`).
    pending_drill_up: bool = false,
    /// `$ad` Mode-7 zoom (UpdateZoomPal / airship altitude).
    /// InitMapRAM default `$10` (field.asm @8583) — foot orthographic; airship uses `$10+$b7`.
    mode7_zoom: u8 = 0x10,
    /// `$c1` nonzero after DoFloorDmg damaged someone (MovePlayer invert gate).
    floor_dmg_active: bool = false,
    /// `$c4` map palette invert toggle (floor damage flash).
    map_invert: bool = false,
    /// Event $ED shop: set after NPC talk; app opens shop UI. 0xFF = none.
    pending_shop: u8 = 0xFF,
    /// `$1a03` menu event → ExecEvent id (Exit $86 / Warp $87 / Sight $FB). 0 = none.
    pending_menu_event: u8 = 0,
    /// Stepped cutscene player (intro event $10 after New Game).
    event_player: event_mod.EventPlayer = .{},
    /// Pending song from event player (0xFF = none).
    pending_song: u8 = 0xFF,
    /// Forced battle from EventCmd_ec (null = none). App enters battle then calls clearEventBattle.
    pending_event_battle: ?u16 = null,
    /// SoloBattle backup for EventCmd_ec (RestorePartyAfterSoloBattle).
    solo_battle_bak: solo_battle_mod.Backup = .{},

    /// $80 — script brightness for EventCmd_da (in vs out). WipeIn does NOT write this.
    fade_brightness: u8 = 15,
    /// INIDISP-equivalent drawn brightness 0..15. WipeIn forces $0F without changing $80.
    display_brightness: u8 = 15,
    /// Active fade: 0 = none, 1 = fade in, 2 = fade out.
    fade_dir: u8 = 0,
    /// Frame counter for fade rate mask (EventCmd_da uses mask $07).
    fade_timer: u8 = 0,
    /// Rate mask: brightness steps when (timer & mask) == 0 after increment. ROM DA uses 7.
    fade_rate_mask: u8 = 7,

    /// Screen wipe (iris) for EventCmd_fe / door triggers — WipeOut/WipeIn + WipeScanlineTbl.
    /// 0 = idle, 1 = wipe out (closing), 2 = wipe in (opening).
    wipe_phase: u8 = 0,
    /// Wipe frame $79: out 0→$1F, in $1F→0 (32 steps).
    wipe_step: u8 = 0,
    /// Warp waiting for WipeOut (or FadeOut when no_wipe) to finish.
    pending_wipe_warp: ?event_mod.Warp = null,

    /// EventCmd_d0 — screen shake toggle ($e3).
    screen_shake: bool = false,
    /// EventCmd_d1 — remaining white-flash frames (ROM: 2× invert-pal vblanks).
    flash_frames: u8 = 0,
    /// EventCmd_d2 — mosaic anim frame 0=off, 1..$40 running (EventMosaicTbl).
    mosaic_frame: u8 = 0,
    /// EventCmd_d6 — remaining one-shot quake frames (+8 scroll).
    quake_frames: u8 = 0,
    /// EventCmd_d7 — $ac movement speed flag (0=normal, 1=fast in events).
    event_fast_move: bool = false,
    /// Song volume fade: 0=idle, 1=slow out to silence, 2=to half, 3=restore full.
    song_fade_mode: u8 = 0,
    song_fade_timer: u8 = 0,
    /// Target BGM gain num/den after fade (app reads these).
    bgm_gain_num: i32 = 1,
    bgm_gain_den: i32 = 2,

    /// EventCmd_fd / D3 cinematic mini-scenes (special.asm + vehicle.asm).
    /// 0=none, 1=red wings, 2=earth-moon, 3=tent, 4=heal sparkle, 5=mist fx,
    /// 6=tunnel, 7=menu fat choco, 8=menu namingway, 9=secret door, 10=generic hold,
    /// 11=telescope, 12=giant explosions, 13=Damcyan attack,
    /// 14=Leviathan, 15=RW approach, 16=RW depart, 17=Zot approach,
    /// 18=RW chase enterprise, 19=crushing corridor.
    cinema_kind: u8 = 0,
    cinema_phase: u8 = 0,
    cinema_timer: u16 = 0,
    /// Special_00 vs Special_01 (FD id) — different hold lengths and end behavior.
    cinema_special_id: u8 = 0,
    /// Giant cinema: UpdateExplosions timer (`$0ad2`) for DrawVehicleSmoke stand-in.
    cinema_smoke: u16 = 0,
    /// Explosion center screen XY (`$0ad4/$0ad5`, often $60,$50).
    cinema_boom_x: u8 = 0x60,
    cinema_boom_y: u8 = 0x50,
    /// During Red Wings: force north scroll (Special sets $05=$08 / JOY_UP).
    /// When false (Special_01 final 64f), ships stay drawn but map stops.
    cinema_force_scroll: bool = false,
    /// Earth↔Moon (kind 2): `$6e` Mode-7 zoom stand-in during star travel.
    cinema_zoom: u16 = 0,
    /// True = EarthToMoon (planet tiles 4–7); false = MoonToEarth (0–3).
    cinema_to_moon: bool = true,
    /// Space sequence active — app draws stars + planet instead of world map.
    cinema_space: bool = false,
    /// Star field RNG seed (re-rolled like DrawStars each frame via field_rng).
    cinema_star_seed: u32 = 1,
    /// Earth↔Moon `$5c` scroll (decrements every 8 frames in `_00a465`).
    cinema_scroll_y: i16 = 0,
    /// Special_03 `$2c` ship X (starts `$0100`, decrements to `$ffde`).
    cinema_ship_x: i16 = 0,
    /// Special_03 `$2e` ship Y base (`$0010`).
    cinema_ship_y: i16 = 0,

    ow: ?overworld_mod.Overworld = null,
    sub: ?submap_mod.SubMap = null,
    npcs: ?npc_mod.NpcSet = null,
    world_triggers: []triggers_mod.Trigger = &.{},
    map_triggers: []triggers_mod.Trigger = &.{},

    /// Map stack for exits (return to previous map).
    /// Facing matches PushMapStack ($1705 packed into high bits of X on submap).
    stack: [16]struct { mode: FieldMode, world: u8, map: u16, x: i32, y: i32, facing: u8 } = undefined,
    stack_len: usize = 0,

    status_msg: [64]u8 = undefined,
    status_msg_len: usize = 0,
    /// Full decoded dialogue (may span many DecodeDlgText pages).
    dlg_buf: [2048]u8 = undefined,
    dlg_len: usize = 0,
    dlg_open: bool = false,
    /// Current 4-line page (OpenDlgWindow waits for key between pages).
    dlg_page: usize = 0,
    /// `$cb` auto-scrolling dialogue (Special_09 / OpenDlgWindow).
    dlg_auto_scroll: bool = false,
    /// Auto-scroll `$07` remaining page units (dlg_auto.page_units_init).
    dlg_auto_units: u8 = 0,
    /// Auto-scroll frame counter stand-in for `$7a`.
    dlg_auto_frame: u8 = 0,
    /// Dialogue box opened by voice/TTS (not event script). Space dismisses even mid-speech.
    voice_dlg: bool = false,

    /// WRAM `$1500` CharacterName bank (Namingway / TextCmd_04 / menus).
    char_names: namingway_mod.NameBank = .{},
    /// EventCmd_d9 Namingway session (active until done/cancelled).
    namingway: namingway_mod.Session = .{},

    /// After a warp, ignore arrival triggers until the player leaves the entry tile
    /// (SNES uses $d6 edge-detect so you don't immediately re-enter a door).
    suppress_arrival: bool = false,
    entry_x: i32 = 0,
    entry_y: i32 = 0,
    /// One-shot: next enterSubmap skips pushStack (stack-pop return).
    suppress_stack_push: bool = false,

    /// NPC $0a49 dialogue table for stepped EventPlayer (EE) — filled on talk start.
    npc_dlg_table_buf: [32]u8 = undefined,
    npc_dlg_table_len: usize = 0,
    /// App should reload field party sprite (e7/e8 / top char).
    party_sprite_dirty: bool = false,

    /// Voice multi-turn memory for the *current* speaker (map + prop_gfx + tile).
    /// ROM townspeople have no personal names — identity key is placement/script.
    voice_chat_map: u16 = 0xffff,
    voice_chat_prop: u8 = 0xff,
    voice_chat_x: u8 = 0xff,
    voice_chat_y: u8 = 0xff,
    /// "Player: …\nYou: …\n" rolling transcript for follow-up questions.
    voice_chat_hist: [2048]u8 = undefined,
    voice_chat_hist_len: usize = 0,

    allocator: std.mem.Allocator,
    rom: *const rom_mod.Rom = undefined,

    pub fn deinit(self: *GameState) void {
        if (self.ow) |*o| o.deinit();
        if (self.sub) |*s| s.deinit();
        if (self.npcs) |*n| n.deinit();
        if (self.world_triggers.len != 0) self.allocator.free(self.world_triggers);
        if (self.map_triggers.len != 0) self.allocator.free(self.map_triggers);
        self.* = undefined;
    }

    pub fn clearVoiceChat(self: *GameState) void {
        self.voice_chat_map = 0xffff;
        self.voice_chat_prop = 0xff;
        self.voice_chat_x = 0xff;
        self.voice_chat_y = 0xff;
        self.voice_chat_hist_len = 0;
    }

    fn voiceChatMatches(self: *const GameState, map_id: u16, npc: npc_mod.Npc) bool {
        return self.voice_chat_map == map_id and
            self.voice_chat_prop == npc.prop_gfx and
            self.voice_chat_x == npc.x and
            self.voice_chat_y == npc.y;
    }

    fn ensureVoiceChatNpc(self: *GameState, map_id: u16, npc: npc_mod.Npc) void {
        if (self.voiceChatMatches(map_id, npc)) return;
        self.voice_chat_map = map_id;
        self.voice_chat_prop = npc.prop_gfx;
        self.voice_chat_x = npc.x;
        self.voice_chat_y = npc.y;
        self.voice_chat_hist_len = 0;
    }

    /// Append one exchange; drop oldest lines if the buffer is full.
    fn appendVoiceChatTurn(self: *GameState, player_text: []const u8, reply: []const u8) void {
        var line: [512]u8 = undefined;
        const chunk = std.fmt.bufPrint(&line, "Player: {s}\nYou: {s}\n", .{
            truncateForHist(player_text, 160),
            truncateForHist(reply, 220),
        }) catch return;

        // Need room for `chunk` — drop whole lines from the front until it fits.
        while (self.voice_chat_hist_len + chunk.len > self.voice_chat_hist.len) {
            if (self.voice_chat_hist_len == 0) break;
            const drop = std.mem.indexOfScalar(u8, self.voice_chat_hist[0..self.voice_chat_hist_len], '\n') orelse self.voice_chat_hist_len;
            const n = @min(drop + 1, self.voice_chat_hist_len);
            const rest = self.voice_chat_hist_len - n;
            if (rest > 0) {
                std.mem.copyForwards(u8, self.voice_chat_hist[0..rest], self.voice_chat_hist[n..self.voice_chat_hist_len]);
            }
            self.voice_chat_hist_len = rest;
        }
        if (chunk.len > self.voice_chat_hist.len) {
            // Single turn larger than buffer — keep the tail.
            const start = chunk.len - self.voice_chat_hist.len;
            @memcpy(self.voice_chat_hist[0..], chunk[start..]);
            self.voice_chat_hist_len = self.voice_chat_hist.len;
            return;
        }
        @memcpy(self.voice_chat_hist[self.voice_chat_hist_len..][0..chunk.len], chunk);
        self.voice_chat_hist_len += chunk.len;
    }

    fn voiceChatHistSlice(self: *const GameState) []const u8 {
        return self.voice_chat_hist[0..self.voice_chat_hist_len];
    }

    /// True New Game: InitNewGame + InitCharProp + intro event $10 (field.asm SoftReset).
    /// Does not skip to overworld — the event script warps through opening maps.
    pub fn initNewGame(gpa: std.mem.Allocator, r: *const rom_mod.Rom, gd: *const data_mod.GameData) !GameState {
        _ = gd;
        const ng = init_new_game_mod.softResetNewGameDefaults();
        var gs: GameState = .{
            .allocator = gpa,
            .rom = r,
            .pos_x = 0,
            .pos_y = 0,
            .mode = .submap,
            .map_id = 0,
            .world_id = ng.world_id,
            .facing = 2,
            .vehicle = 0,
            .field_leader_slot = ng.field_leader,
            .stack_len = 0,
            // Parked vehicles / whale hidden (InitNewGame stz `$170f`…`$172b`).
            .choco_vis = 0,
            .bk_choco_vis = 0,
            .hover_vis = 0,
            .enterprise_vis = 0,
            .falcon_vis = 0,
            .whale_vis = 0,
            .ship_vis = 0,
        };

        try gs.loadInitSwitches(r);
        // Inventory bag end markers `$149c`… (InitNewGame @82e6).
        init_new_game_mod.applyBagEndMarkers(&gs.inventory);

        // InitCharProp: Cecil only + CharInitEquip row 0
        if (party_mod.initMainChar(r)) |cecil| {
            gs.party[0] = cecil;
        }
        gs.field_leader_slot = ng.field_leader;
        cmd_magic_mod.initSpellLists(r, &gs.spell_lists);
        // CharacterName → `$1500` (New Game `_01979b`).
        gs.char_names.loadFromRom(r);

        // Load OW data (needed when intro FE exits to world) but stay off-map until event warps.
        gs.ow = try overworld_mod.Overworld.load(gpa, r);
        gs.syncOverworldEventTiles();
        gs.world_triggers = try triggers_mod.loadWorldTriggers(gpa, r, gs.world_id);

        // SoftReset (field.asm @8040): after InitNewGame/InitCharProp —
        //   lda #$0f / sta $80  (full brightness), then lda #$10 / jsr ExecEvent.
        // Do **not** black the screen here — that made New Game look dead until FD $00
        // Red Wings (which does setScreenOff itself before its fade-in).
        if (!gs.event_player.start(r, ng.intro_event)) {
            // Event $10 ptr missing: fall back free-roam so New Game is never a hard black void.
            gs.mode = .overworld;
            gs.pos_x = new_game_overworld_x;
            gs.pos_y = new_game_overworld_y;
            gs.setScreenFull();
            return gs;
        }
        gs.setScreenFull();
        gs.wipe_phase = 0;
        gs.cinema_kind = 0;
        gs.setMsg("");
        return gs;
    }

    /// Debug / skip: overworld outside Baron with Cecil + Kain fully equipped.
    /// Matches post-intro free roam without replaying cutscenes.
    pub fn initBaronSkip(gpa: std.mem.Allocator, r: *const rom_mod.Rom, gd: *const data_mod.GameData) !GameState {
        _ = gd;
        var gs: GameState = .{
            .allocator = gpa,
            .rom = r,
            .pos_x = new_game_overworld_x,
            .pos_y = new_game_overworld_y,
            .mode = .overworld,
            .facing = 2,
        };

        try gs.loadInitSwitches(r);

        if (party_mod.initMainChar(r)) |cecil| {
            gs.party[0] = cecil;
        }
        gs.field_leader_slot = 0;
        cmd_magic_mod.initSpellLists(r, &gs.spell_lists);
        gs.char_names.loadFromRom(r);
        // Kain: event param 2 → CharRemoveTbl[1] = id 1, equip row 1
        _ = party_mod.addFromEvent(r, gs.party[0..], 2);

        // Starting consumables (intro would grant some; keep bag usable for battles).
        _ = gs.inventory.give(0xCE);
        _ = gs.inventory.give(0xCE);
        _ = gs.inventory.give(0xCE);
        _ = gs.inventory.give(0xCF);
        _ = gs.inventory.give(0xD1);

        gs.ow = try overworld_mod.Overworld.load(gpa, r);
        gs.syncOverworldEventTiles();
        gs.world_triggers = try triggers_mod.loadWorldTriggers(gpa, r, gs.world_id);
        // Wild chocobos are not present at new-game OW spawn; they appear via field events.
        gs.updateSaveEnabled();
        gs.setMsg("Outside Baron");
        return gs;
    }

    pub fn loadInitSwitches(self: *GameState, r: *const rom_mod.Rom) !void {
        // InitNewGame @82c6 / @82d6 — InitNPCSwitch + InitEventSwitch.
        try init_new_game_mod.loadInitSwitches(r, &self.npc_switch, &self.event_switch, null);
    }

    pub fn eventActive(self: *const GameState) bool {
        return self.event_player.active;
    }

    pub fn eventWaitingOnDialogue(self: *const GameState) bool {
        return self.event_player.active and (self.event_player.blocked == .dialogue or self.event_player.blocked == .yes_no);
    }

    pub fn eventWaitingOnBattle(self: *const GameState) bool {
        return self.event_player.active and self.event_player.blocked == .battle;
    }

    /// Pop pending EventCmd_ec battle (null if none).
    /// Applies SoloBattleTbl party filter (event.asm @e668) before the id is returned.
    pub fn consumeEventBattle(self: *GameState) ?u16 {
        const id = self.pending_event_battle orelse return null;
        self.pending_event_battle = null;
        // EventCmd_ec solo character battles: thin roster before BattleSub.
        self.solo_battle_bak = solo_battle_mod.apply(self.rom, self.party[0..], id);
        if (self.solo_battle_bak.active) self.party_sprite_dirty = true;
        return id;
    }

    /// After a forced event battle ends (victory/flee), resume the cutscene script.
    /// Special_04: post-BattleSub LoadOverworld + sand bombs (special.asm @d56e–@d5f0).
    pub fn resumeAfterEventBattle(self: *GameState) void {
        // RestorePartyAfterSoloBattle @e74b
        if (self.solo_battle_bak.active) {
            solo_battle_mod.restore(self.party[0..], self.solo_battle_bak);
            self.solo_battle_bak = .{};
            self.party_sprite_dirty = true;
        }
        if (self.event_player.blocked == .battle) {
            self.event_player.clearBlock();
        }
        // Titan aftermath only when FD $04 queued the battle (not EventCmd_ec alone).
        if (self.cinema_special_id == 0x04) {
            self.enterWorld(0, 0x63, 0x77) catch {};
            self.mode7_zoom = 0x20;
            self.queueSfx(0x42); // PlaySong-ish id used mid-aftermath in decomp ($1e01)
            // $0ad2 starts $40; hold explosions then fade (giant cinema approx).
            self.startGiantCinema(0x50, true, 0x70, 0x70);
        }
    }

    pub fn isFading(self: *const GameState) bool {
        return self.fade_dir != 0;
    }

    pub fn isWiping(self: *const GameState) bool {
        return self.wipe_phase != 0;
    }

    /// Transition busy (fade or iris wipe) — hold the event script.
    pub fn isTransitioning(self: *const GameState) bool {
        return self.isFading() or self.isWiping() or self.cinemaActive();
    }

    /// Screen fully on: $80 and INIDISP both $0F (normal free roam / end of FadeIn).
    pub fn setScreenFull(self: *GameState) void {
        self.fade_brightness = 15;
        self.display_brightness = 15;
        self.fade_dir = 0;
    }

    /// Screen off: $80 and INIDISP both 0 (SoftReset / after FadeOut / no_wipe load).
    pub fn setScreenOff(self: *GameState) void {
        self.fade_brightness = 0;
        self.display_brightness = 0;
        self.fade_dir = 0;
    }

    /// WipeIn end: INIDISP=$0F, $80 untouched (field.asm @9298).
    pub fn setDisplayOnKeepScript(self: *GameState) void {
        self.display_brightness = 15;
        self.fade_dir = 0;
    }

    /// Start FadeIn ($80 0→15) or FadeOut (15→0). Rate mask like ROM $07.
    /// Updates both $80 and INIDISP (display_brightness) together.
    pub fn startFade(self: *GameState, fade_in: bool) void {
        self.fade_dir = if (fade_in) 1 else 2;
        self.fade_timer = 0;
        self.fade_rate_mask = 3; // slightly snappier than ROM $07; still multi-step
        if (fade_in) {
            self.setScreenOff();
            self.fade_dir = 1;
        } else {
            self.setScreenFull();
            self.fade_dir = 2;
        }
    }

    /// One field of FadeIn/FadeOut (field.asm @8db0 / @8dd1).
    pub fn tickFade(self: *GameState) void {
        if (self.fade_dir == 0) return;
        self.fade_timer +%= 1;
        if ((self.fade_timer & self.fade_rate_mask) != 0) return;
        if (self.fade_dir == 1) {
            if (self.fade_brightness < 15) self.fade_brightness += 1;
            self.display_brightness = self.fade_brightness;
            if (self.fade_brightness >= 15) self.setScreenFull();
        } else {
            if (self.fade_brightness > 0) self.fade_brightness -= 1;
            self.display_brightness = self.fade_brightness;
            if (self.fade_brightness == 0) self.setScreenOff();
        }
    }

    /// Begin iris wipe-out for a map load (field.asm WipeOut @923f — 32 frames).
    pub fn startWipeOut(self: *GameState, w: event_mod.Warp) void {
        self.pending_wipe_warp = w;
        self.wipe_phase = 1; // out
        self.wipe_step = 0;
        self.move_dir = 0;
        self.move_px = 0;
    }

    /// All map changes (EventCmd_fe, door triggers, stack pop) go through this.
    /// Default: WipeOut → load → WipeIn. FE flags bit5 (`no_wipe`): FadeOut → load (stay dark).
    /// Same path for intro, mid-game events, and field doors — do not bypass.
    pub fn beginMapTransition(self: *GameState, w: event_mod.Warp) void {
        if (w.no_wipe) {
            self.pending_wipe_warp = w;
            self.move_dir = 0;
            self.move_px = 0;
            // Use $80 (script brightness) like EventCmd_da / _00f172.
            if (self.fade_brightness > 0) {
                self.startFade(false);
            } else {
                self.applyEventWarp(w) catch {
                    self.setMsg("Map load failed");
                };
                self.pending_wipe_warp = null;
                self.setScreenOff(); // stay dark until DA FadeIn
            }
        } else {
            self.startWipeOut(w);
        }
    }

    /// One field of WipeOut/WipeIn (field.asm @923f / @9269).
    /// WipeOut: $79 0→$1F; WipeIn: $79 $1F→0.
    /// ROM WipeIn sets INIDISP=$0F but leaves $80 unchanged — DA then often FadeIn.
    pub fn tickWipe(self: *GameState) void {
        switch (self.wipe_phase) {
            1 => { // WipeOut
                if (self.wipe_step < 0x1F) {
                    self.wipe_step += 1;
                } else {
                    // Fully closed — load map, then open.
                    if (self.pending_wipe_warp) |w| {
                        self.applyEventWarp(w) catch {
                            self.setMsg("Map load failed");
                        };
                        self.pending_wipe_warp = null;
                    }
                    self.wipe_phase = 2; // WipeIn
                    self.wipe_step = 0x1F;
                    // Iris interior lit; $80 unchanged (setDisplayOnKeepScript).
                    self.setDisplayOnKeepScript();
                }
            },
            2 => { // WipeIn
                if (self.wipe_step > 0) {
                    self.wipe_step -= 1;
                } else {
                    self.wipe_phase = 0;
                    self.wipe_step = 0;
                    // Match WipeIn @9298: force screen on without writing $80.
                    self.setDisplayOnKeepScript();
                }
            },
            else => {
                self.wipe_phase = 0;
            },
        }
    }

    /// Half-width / half-height of the visible iris at `wipe_step` (WipeScanlineTbl).
    pub fn wipeWindowHalf(self: *const GameState) struct { x: u8, y: u8 } {
        const s: usize = @min(@as(usize, self.wipe_step), 31);
        return .{
            .x = wipe_scanline_tbl[s * 2],
            .y = wipe_scanline_tbl[s * 2 + 1],
        };
    }

    /// Mosaic pixel block size from EventCmd_d2 anim (0 = off). SNES size nibble + 1.
    pub fn mosaicBlockSize(self: *const GameState) u8 {
        return field_fx_mod.mosaicBlockSizeFromFrame(self.mosaic_frame);
    }

    pub fn cinemaActive(self: *const GameState) bool {
        return self.cinema_kind != 0;
    }

    /// Advance fade / wipe / flash / mosaic / cinematics for one field.
    /// Call every field from the main loop (with or without EventPlayer).
    pub fn tickTransition(self: *GameState) void {
        if (self.flash_frames > 0) self.flash_frames -= 1;
        if (self.quake_frames > 0) self.quake_frames -= 1;
        // Always advance mosaic — must not stall behind cinema/wipe early-returns.
        // EventCmd_d2: `$79` 0..$3F then clear (field_fx.advanceMosaicFrame).
        if (self.mosaic_frame > 0) {
            self.mosaic_frame = field_fx_mod.advanceMosaicFrame(self.mosaic_frame);
        }
        // Auto-scroll dialogue (`$cb`) advances every field (Special_09 / OpenDlgWindow).
        if (self.dlg_auto_scroll and self.dlg_open) {
            const still = self.tickDlgAutoScroll();
            if (!still and self.event_player.blocked == .dialogue) {
                self.event_player.clearBlock();
            }
        }
        // Song volume ramp (D8 slow out / FD $3d half / $3e full).
        // FadeOutSongSlow ($85) only ducks the *current* track; a later FA / PlayMapSong
        // must cancel this and restore gain (otherwise intro goes silent after D8→FA).
        if (self.song_fade_mode != 0) {
            self.song_fade_timer +%= 1;
            if (self.song_fade_timer >= 4) {
                self.song_fade_timer = 0;
                switch (self.song_fade_mode) {
                    1 => { // EventCmd_d8 / FadeOutSongSlow SPC $85 stand-in (field_fx)
                        const cur: u8 = if (self.bgm_gain_num > 0)
                            @intCast(@min(self.bgm_gain_num, 255))
                        else
                            0;
                        const step = field_fx_mod.stepSongFadeSlow(cur);
                        if (!step.done) {
                            self.bgm_gain_num = step.num;
                            self.bgm_gain_den = 16;
                        } else {
                            self.song_fade_mode = 0;
                            // Only stop if nothing else queued a new song this fade.
                            if (self.pending_song == 0xFF) self.pending_song = 0xFE;
                        }
                    },
                    2 => { // half volume
                        self.bgm_gain_num = 1;
                        self.bgm_gain_den = 4;
                        self.song_fade_mode = 0;
                    },
                    3 => { // restore default
                        self.bgm_gain_num = 1;
                        self.bgm_gain_den = 2;
                        self.song_fade_mode = 0;
                    },
                    else => self.song_fade_mode = 0,
                }
            }
        }
        // Priority: wipe > cinema > fade (wipe is map load; must finish).
        if (self.isWiping()) {
            self.tickWipe();
            return;
        }
        if (self.cinemaActive()) {
            self.tickCinema();
            return;
        }
        if (self.isFading()) {
            self.tickFade();
            if (!self.isFading()) {
                if (self.pending_wipe_warp) |w| {
                    self.applyEventWarp(w) catch {
                        self.setMsg("Map load failed");
                    };
                    self.pending_wipe_warp = null;
                    // no_wipe FE: stay dark ($80 + INIDISP) until DA FadeIn.
                    self.setScreenOff();
                }
            }
        }
    }

    /// Start a timed cinematic (EventCmd_fd / D3 / D4 / D9 / D5).
    pub fn startCinema(self: *GameState, kind: u8, hold_frames: u16) void {
        self.cinema_kind = kind;
        self.cinema_phase = 0;
        self.cinema_timer = hold_frames;
        self.move_dir = 0;
        self.move_px = 0;
    }

    /// EventCmd_fd dispatcher (special.asm) — practical ports of common specials.
    pub fn startSpecial(self: *GameState, id: u8) void {
        switch (id) {
            // Special_00 / Special_01: LoadOverworldIntro + DrawRedWings flyby.
            // special.asm @daa3 / @db01 — exact positions, timings, forced JOY_UP ($05=$08).
            // LoadOverworld → InitWorld: PlayMapSong is skipped while $b1 (event) is set.
            // Intro already played FA $2C; do not queue overworld/vehicle BGM here.
            // Do **not** set player_hidden ($d3); draw skips leader while cinema_kind==1.
            0x00, 0x01 => {
                // Special_00: ($e1,$fe); Special_01: ($65,$00). Vehicle $1704=enterprise.
                const x: u8 = if (id == 0) 0xE1 else 0x65;
                const y: u8 = if (id == 0) 0xFE else 0x00;
                self.enterWorld(0, x, y) catch {};
                // Cancel any map-song request from the mode switch; keep event FA track.
                self.pending_song = 0xFF;
                self.setScreenOff();
                self.cinema_special_id = id;
                self.cinema_force_scroll = true;
                // Hold length is set in phase 1 after fade-in (480 / 272 frames).
                self.startCinema(1, 0);
            },
            // Bomb ring / mist dragon / similar attack FX
            0x02, 0x07, 0x08 => {
                self.screen_shake = true;
                self.flash_frames = 4;
                self.mosaic_frame = 1;
                self.startCinema(5, 48);
            },
            // Special_04 (special.asm @d55b): BattleSub $EC first, then LoadOverworld
            // ($63,$77) + fade-in + sand explosions ($0ad2 countdown). Do not start
            // aftermath until resumeAfterEventBattle (BattleSub returns).
            0x04 => {
                self.cinema_special_id = id;
                self.pending_event_battle = 0x00EC;
                // Special blocks the event script until BattleSub + aftermath (like EC).
                if (self.event_player.active) {
                    self.event_player.blocked = .battle;
                    self.event_player.last_battle_id = 0x00EC;
                }
            },
            // Special_05: tent/cabin OAM hold (special.asm @d3bf). Heal is done by
            // menu item effect / event $77–$78 before FD — special only draws tent sprite.
            0x05 => {
                self.cinema_special_id = id;
                self.startCinema(3, 40);
            },
            // Special_06: restore sparkle ring (special.asm @d9d6) — angle spiral FX, not heal.
            // Menu/event must have restored HP/MP already; show flash hold only.
            0x06 => {
                self.cinema_special_id = id;
                self.flash_frames = 6;
                self.startCinema(4, 36);
            },
            // Special_09 (special.asm @d3f2): PrologueGfx/Pal + auto-scroll dlg bank1 high $D0.
            // `$cb=1` then OpenDlgWindow (all pages) then stz `$cb`. Host: dlg_auto_scroll.
            // Full PrologueBG CHR/tilemaps still residual; host: stars + dlg $D0 + fade hold.
            0x09 => {
                self.cinema_special_id = id;
                self.setScreenOff();
                self.cinema_space = true;
                self.cinema_to_moon = true;
                self.cinema_zoom = 16;
                self.cinema_star_seed = self.field_rng;
                self.startCinema(11, 0); // telescope-like star field
                self.cinema_timer = 0;
                // GetDlgPtr1H $d0 — prologue text with auto-scroll (`sta $cb` / `stz $cb`).
                self.openEventDlgAuto(0xD0 + 256, "Long ago...");
                self.startFade(true);
            },
            // Return previous map / world (LoadMapStack)
            0x0A, 0x1D => {
                _ = self.popMapStack() catch {};
            },
            // Special_0b (special.asm @d361): stx $172c then LoadMapStack — clear to stack base.
            0x0B => {
                if (self.stack_len > 0) {
                    const e = self.stack[0];
                    self.stack_len = 0;
                    self.move_dir = 0;
                    self.move_px = 0;
                    if (e.mode == .overworld) {
                        self.beginMapTransition(.{
                            .to_world = true,
                            .world_id = e.world,
                            .x = @intCast(e.x),
                            .y = @intCast(e.y),
                            .facing = e.facing & 3,
                            .skip_stack_push = true,
                        });
                    } else {
                        self.beginMapTransition(.{
                            .to_world = false,
                            .map_id = e.map,
                            .x = @intCast(e.x),
                            .y = @intCast(e.y),
                            .facing = e.facing & 3,
                            .skip_stack_push = true,
                        });
                    }
                } else {
                    self.beginMapTransition(.{
                        .to_world = true,
                        .world_id = 0,
                        .x = @intCast(new_game_overworld_x),
                        .y = @intCast(new_game_overworld_y),
                        .skip_stack_push = true,
                    });
                }
            },
            // Special_0e: tunnel open/close FX (special.asm) — shake + mosaic hold.
            0x0E => {
                self.screen_shake = true;
                self.mosaic_frame = 1;
                self.queueSfx(0x5E);
                self.startCinema(6, 64);
            },
            // Special_2d: BoardWhale at whale pos (controls in big whale).
            0x2D => {
                self.stack_len = 0; // stx $172c — reset map stack
                const wx = self.whale_x;
                const wy = self.whale_y;
                const ww = self.whale_world;
                self.enterWorld(ww, wx, wy) catch {};
                self.vehicle = vehicle_mod.id_whale;
                self.whale_vis = 0;
                self.updatePlayerSpeed();
                self.vehicle_anim.begin(.air_liftoff);
                self.queueVehicleSong();
            },
            // Special_2e: hide enterprise.
            0x2E => {
                self.enterprise_vis = 0;
            },
            // Special_2f / $30: crystal / post-Giant travel to/from moon (EarthToMoon path).
            0x2F, 0x30 => {
                if (id == 0x30) {
                    // Whale lands on moon at ($13,$27) after travel.
                    self.whale_x = 0x13;
                    self.whale_y = 0x27;
                    self.whale_world = 2;
                    self.whale_vis = 1;
                }
                self.startCinema(2, 0);
            },
            // Special_34: telescope — circular window + LoadEarthMoonGfx stars/planet.
            0x34 => {
                self.setScreenOff();
                self.cinema_space = true;
                self.cinema_to_moon = true;
                self.cinema_zoom = 12;
                self.cinema_star_seed = self.field_rng;
                self.startCinema(11, 0);
            },
            // Special_33: sight / dwarven bread — brief invert flash.
            0x33 => {
                self.flash_frames = 8;
                self.map_invert = true;
                self.startCinema(10, 20);
            },
            // Music half / fade in
            0x3D => {
                self.song_fade_mode = 2;
                self.song_fade_timer = 0;
            },
            0x3E => {
                self.song_fade_mode = 3;
                self.song_fade_timer = 0;
            },
            // Soft reset → leave event
            0x3C => {
                self.event_player.stop();
                self.setScreenFull();
                self.setMsg("Reset.");
            },
            // Special_03: Red Wings attack Damcyan (special.asm @d5f6).
            0x03 => {
                self.cinema_special_id = id;
                self.queueSong(0x3E);
                self.mode7_zoom = 0x10;
                self.cinema_ship_x = 0x100;
                self.cinema_ship_y = 0x10;
                self.cinema_smoke = 0;
                self.cinema_boom_x = 0x80;
                self.cinema_boom_y = 0x50;
                self.startCinema(13, 0);
            },
            // Special_31: CPU core destroyed — flash + explosions at core.
            0x31 => {
                self.cinema_special_id = id;
                self.flash_frames = 8;
                self.queueSfx(0x23);
                self.startGiantCinema(0x80, true, 0x60, 0x48);
            },
            // Special_3f: init characters for final battle (paladin Cecil HP=1, others dead).
            0x3F => {
                for (&self.party) |*m| {
                    if (!m.present) continue;
                    m.status2 = 0;
                    // `$1000&$1f == $0b` → paladin Cecil.
                    if (m.id == 0x0B or m.class_id == 0x0B) {
                        m.status1 = 0;
                        m.hp = 1;
                    } else {
                        m.status1 = 0x80; // dead
                        m.hp = 0;
                    }
                }
            },
            // Special_20: Giant of Babil 1 — whale to (40,232), board+land (special.asm @c8df).
            0x20 => {
                self.cinema_special_id = id;
                // `$1708` return/earth slot → (0x28,0xE8); party to whale then land there.
                const wx = self.whale_x;
                const wy = self.whale_y;
                const ww = self.whale_world;
                self.enterWorld(ww, wx, wy) catch {};
                self.vehicle = vehicle_mod.id_whale;
                self.whale_vis = 0;
                self.updatePlayerSpeed();
                // Land at Giant approach tile.
                self.pos_x = 0x28;
                self.pos_y = 0xE8;
                self.whale_x = 0x28;
                self.whale_y = 0xE8;
                self.whale_world = self.world_id;
                self.whale_vis = 1;
                self.vehicle = 0;
                self.updatePlayerSpeed();
                self.queueSfx(0x23);
                self.startGiantCinema(48, false, 0x60, 0x50);
            },
            // Special_21: white flash + multi-burst explosions (~255f + steps).
            0x21 => {
                self.cinema_special_id = id;
                self.flash_frames = 16;
                self.map_invert = true;
                self.queueSfx(0x23);
                self.startGiantCinema(0x100, true, 0x60, 0x50);
            },
            // Special_22 / $23: long explosion pans (frame counts from $89 loops).
            0x22 => {
                self.cinema_special_id = id;
                self.queueSong(0x2C); // PlaySongEvent $2c mid-sequence
                self.queueSfx(0x23);
                self.startGiantCinema(0x140, true, 0x60, 0x50);
            },
            0x23 => {
                self.cinema_special_id = id;
                self.queueSfx(0x23);
                self.startGiantCinema(0x1C0, true, 0x60, 0x50);
            },
            // Special_24 / $25 / $26 / $27: more explosion stages.
            0x24 => {
                self.cinema_special_id = id;
                self.startGiantCinema(0x200, true, 0x70, 0x58);
            },
            0x25, 0x26, 0x27 => {
                self.cinema_special_id = id;
                self.startGiantCinema(0x180, true, 0x70, 0x58);
            },
            // Special_40: giant destroyed — explosions + fade to black.
            0x40 => {
                self.cinema_special_id = id;
                self.startGiantCinema(0x180, true, 0x70, 0x58);
            },
            // Special_29: big whale emerges (~$30×8 frames).
            0x29 => {
                self.cinema_special_id = id;
                self.whale_vis = 1;
                self.queueSfx(0x23);
                self.screen_shake = true;
                self.startCinema(10, 0x30 * 8);
            },
            // Special_35: whale returns to ocean — sink + hide.
            0x35 => {
                self.cinema_special_id = id;
                self.screen_shake = true;
                self.vehicle_anim.begin(.air_land);
                self.vehicle = vehicle_mod.id_whale;
                self.startCinema(10, 0x24 * 4);
                // After cinema generic ends, hide whale — flag via special id check in tick.
            },
            // Special_36: dwarf tanks attack — shake + sfx hold.
            0x36 => {
                self.cinema_special_id = id;
                self.screen_shake = true;
                self.queueSfx(0x23);
                self.flash_frames = 4;
                self.startCinema(10, 90);
            },
            // Special_3b: enterprise rescue — show enterprise, brief fly-in.
            0x3B => {
                self.cinema_special_id = id;
                self.enterprise_vis = 1;
                self.enterprise_x = @intCast(self.pos_x & 0xFF);
                self.enterprise_y = @intCast((self.pos_y -% 2) & 0xFF);
                self.enterprise_world = self.world_id;
                self.queueSfx(0x18);
                self.startCinema(10, 60);
            },
            // Special_32 / $37 / $38: prophecy / solar (special.asm @c770).
            // Full path: Mode 1 BG + WindowGfx + dlg bank1 high $6a pages + ProphecyPal.
            // Host: space stars + prophecy wash; open event dlg $6a (first prophecy page).
            0x32, 0x37, 0x38 => {
                self.cinema_special_id = id;
                self.flash_frames = 8;
                self.cinema_space = true;
                self.cinema_to_moon = true;
                self.cinema_zoom = 20;
                self.cinema_star_seed = self.field_rng;
                self.startCinema(11, 0);
                self.cinema_timer = 0;
                // GetDlgPtr1H $6a — first prophecy text page (EN multi-page).
                self.openEventDlg(0x6A + 256, "The prophecy...");
            },
            // Special_39: end credits — full credit sequence is S5; hold + log only.
            0x39 => {
                self.cinema_special_id = id;
                std.log.info("special: credits FD $39 (hold; full credits sequence unported)", .{});
                self.startCinema(10, 180);
            },
            // Special_0c: multi-point explosion ring (8 bursts from `_14fc56`).
            0x0C => {
                self.cinema_special_id = id;
                self.queueSfx(0x23);
                // Cycle boom centers through the 8-point table during giant cinema.
                self.cinema_boom_x = 0x40;
                self.cinema_boom_y = 0x40;
                self.startGiantCinema(0x100, true, 0x40, 0x40);
            },
            // Special_10 / $11: Leviathan attack — LoadOverworldLeviathan + whirlpool.
            0x10, 0x11 => {
                self.cinema_special_id = id;
                // LoadOverworldLeviathan: pos ($a8,$90), vehicle=ship, $ad=$10.
                self.enterWorld(0, 0xA8, 0x90) catch {};
                self.vehicle = vehicle_mod.id_ship;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x10;
                self.screen_shake = true;
                self.queueSfx(0x23);
                // Whirlpool base ($10,$58); ship OAM starts near that for suck-in.
                self.cinema_ship_x = if (id == 0x10) 0x10 else 0x40;
                self.cinema_ship_y = 0x58;
                self.startCinema(14, 0xC0);
            },
            // Special_12: Red Wings approach enterprise ($2c $100→$70).
            0x12 => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x20;
                self.cinema_ship_x = 0x100;
                self.cinema_ship_y = 0x70;
                self.startCinema(15, 0xD0); // approach
            },
            // Special_13: Red Wings depart ($2c $70→left).
            0x13 => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x20;
                self.cinema_ship_x = 0x70;
                self.cinema_ship_y = 0x70;
                self.startCinema(16, 0xD0); // depart
            },
            // Special_14: first Zot approach — rise + fade.
            0x14 => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x20;
                self.cinema_ship_x = 0x70;
                self.cinema_ship_y = 0x78;
                self.startCinema(17, 0xD0);
            },
            // Special_15: LandEnterprise.
            0x15 => {
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.vehicle_anim.begin(.air_land);
                self.vehicle_land_pending = true;
            },
            // Special_16: Red Wings bomb enterprise area.
            0x16 => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x20;
                self.queueSfx(0x23);
                self.startGiantCinema(0x100, true, 0x70, 0x70);
            },
            // Special_17 / $18: Red Wings chase enterprise (scroll + fade).
            0x17, 0x18 => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_enterprise;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x20;
                self.cinema_force_scroll = true;
                self.cinema_ship_x = 0x90;
                self.cinema_ship_y = 0x60;
                self.startCinema(18, if (id == 0x17) 0xC0 else 0xB6);
            },
            // Special_19–$1B (special.asm @cff6): crushing corridor.
            // Sets BG2 VOFS from $60: $2e0 ($19/$1a) or $1e0 ($1b); one-shot −16 write.
            // Host stores initial BG2 VOFS in cinema_scroll_y for render squeeze.
            0x19, 0x1A, 0x1B => {
                self.cinema_special_id = id;
                self.screen_shake = true;
                self.queueSfx(0x5E);
                // $60 word: $02e0 or $01e0 → pixel VOFS (signed-ish host use).
                self.cinema_scroll_y = if (id == 0x1B) 0x1E0 else 0x2E0;
                self.cinema_ship_y = if (id == 0x1B) 0x1E else 0x2E;
                self.startCinema(19, 0x60);
            },
            // Special_1c / $28: park enterprise on OW / under.
            0x1C => {
                self.enterprise_vis = 1;
                self.enterprise_world = 0;
                self.enterprise_x = 0x66; // ($66,$9e)
                self.enterprise_y = 0x9E;
            },
            0x28 => {
                self.enterprise_vis = 1;
                self.enterprise_world = 1;
                self.enterprise_x = 0x66; // ($66,$52) dwarf castle
                self.enterprise_y = 0x52;
            },
            // Special_1e / $3a: explosion at fixed screen point (CPU / Cid bomb).
            0x1E => {
                self.cinema_special_id = id;
                self.queueSfx(0x23);
                self.startGiantCinema(0x60, true, 0x70, 0x10);
            },
            0x3A => {
                self.cinema_special_id = id;
                self.queueSfx(0x23);
                self.flash_frames = 8;
                self.startGiantCinema(0x80, true, 0x70, 0x70);
            },
            // Special_1f (special.asm @ce76): _00cf98 setup, then $32 frames of water
            // flash sprites, then $64 frames of DrawWhale + LoadWhaleFlashPal.
            // Total hold ≈ ($32+$64)*8 WaitFrame pairs when and #$07 — use $32+$64 fields.
            0x1F => {
                self.cinema_special_id = id;
                self.vehicle = vehicle_mod.id_whale;
                self.whale_vis = 0;
                self.updatePlayerSpeed();
                self.vehicle_anim.begin(.air_liftoff);
                self.screen_shake = true;
                self.flash_frames = 8;
                self.map_invert = false;
                // Phase length: emerge water ($32) + whale rise ($64) = $96.
                self.startCinema(10, 0x32 + 0x64);
            },
            // Special_2a (special.asm @cf23): similar emerge with flash pal copy.
            0x2A => {
                self.cinema_special_id = id;
                self.whale_vis = 1;
                self.vehicle = vehicle_mod.id_whale;
                self.updatePlayerSpeed();
                self.screen_shake = true;
                self.flash_frames = 8;
                self.startCinema(10, 0x64);
            },
            // Special_0d: show ship at Fabul (special.asm @d342).
            // $1728=1, $1729 word = $38DE → (x=$DE,y=$38) = (222,56).
            0x0D => {
                self.ship_vis = 1;
                self.ship_x = 0xDE;
                self.ship_y = 0x38;
            },
            // Special_0f: Leviathan attack variant (LoadOverworldLeviathan + 0x200 frames).
            0x0F => {
                self.cinema_special_id = id;
                self.enterWorld(0, 0xA8, 0x90) catch {};
                self.vehicle = vehicle_mod.id_ship;
                self.updatePlayerSpeed();
                self.mode7_zoom = 0x10;
                self.screen_shake = true;
                self.queueSfx(0x23);
                self.cinema_ship_x = 0x28;
                self.cinema_ship_y = 0x58;
                self.startCinema(14, 0x200);
            },
            // Special_2b: enter Tower of Zot teleporter — shrink/fade beam (~$78 frames).
            0x2B => {
                self.cinema_special_id = id;
                self.setScreenOff();
                self.startCinema(10, 0x78);
            },
            // Special_2c: exit Tower of Zot teleporter — grow/brighten beam (~$78 frames).
            0x2C => {
                self.cinema_special_id = id;
                self.setScreenOff();
                self.startCinema(10, 0x78);
            },
            // Outside ROM table (id > $40): brief hold only — see special_ids.endKind.
            // Do not invent FX — log id for tracking. Never soft-lock the EventPlayer.
            else => {
                std.debug.assert(special_ids_mod.endKind(id) == .unported_hold);
                std.log.info("special: unported FD ${x:0>2} (no-op hold)", .{id});
                self.cinema_special_id = id;
                self.startCinema(10, 16);
            },
        }
    }

    /// Giant of Babil explosion cinemas (Special_21–27, $40).
    fn startGiantCinema(self: *GameState, frames: u16, explosions: bool, bx: u8, by: u8) void {
        self.cinema_boom_x = bx;
        self.cinema_boom_y = by;
        self.cinema_smoke = if (explosions) 0x28 else 0;
        self.screen_shake = true;
        self.startCinema(12, frames);
    }

    fn tickCinema(self: *GameState) void {
        // Shared phases: 0=fade out, 1=hold, 2=fade in / finish
        switch (self.cinema_kind) {
            1 => self.tickCinemaRedWings(),
            2 => self.tickCinemaEarthMoon(),
            11 => self.tickCinemaTelescope(),
            12 => self.tickCinemaGiant(),
            13 => self.tickCinemaDamcyan(),
            14 => self.tickCinemaLeviathan(),
            15, 16, 17 => self.tickCinemaShipFly(),
            18 => self.tickCinemaChase(),
            19 => self.tickCinemaCorridor(),
            3, 4, 5, 6, 7, 8, 9, 10 => self.tickCinemaGeneric(),
            else => {
                self.cinema_kind = 0;
            },
        }
    }

    /// Special_10/$11: Leviathan — shake, suck ship toward whirlpool.
    fn tickCinemaLeviathan(self: *GameState) void {
        self.screen_shake = true;
        if (self.cinema_timer > 0) {
            self.cinema_timer -= 1;
            // Pull ship toward center (suck-in for $11 is stronger).
            const pull: i16 = if (self.cinema_special_id == 0x11) 2 else 1;
            if (self.cinema_ship_x < 0x70) self.cinema_ship_x += pull else if (self.cinema_ship_x > 0x70) self.cinema_ship_x -= pull;
            if (self.cinema_ship_y < 0x70) self.cinema_ship_y += 1 else if (self.cinema_ship_y > 0x70) self.cinema_ship_y -= 1;
            if ((self.cinema_timer & 0x1F) == 0) self.queueSfx(0x23);
            return;
        }
        self.screen_shake = false;
        self.cinema_kind = 0;
        self.cinema_phase = 0;
        self.setScreenFull();
    }

    /// Special_12/$13/$14: Red Wings vs enterprise X/Y motion.
    fn tickCinemaShipFly(self: *GameState) void {
        if (self.cinema_timer > 0) {
            self.cinema_timer -= 1;
            switch (self.cinema_kind) {
                15 => {
                    // Approach: $2c → $70
                    if (self.cinema_ship_x > 0x70) self.cinema_ship_x -= 1;
                },
                16 => {
                    // Depart: after half, $2c → left
                    if (self.cinema_timer < 0x80 and self.cinema_ship_x > -0x10)
                        self.cinema_ship_x -= 1;
                },
                17 => {
                    // Zot: rise ($2e down toward $10) + dim
                    if (self.cinema_ship_y > 0x10) self.cinema_ship_y -= 1;
                    if (self.cinema_timer < 0x10) {
                        const b: u8 = @truncate(self.cinema_timer);
                        if (b < self.fade_brightness) self.fade_brightness = b;
                    }
                },
                else => {},
            }
            return;
        }
        self.cinema_kind = 0;
        self.cinema_phase = 0;
        self.setScreenFull();
    }

    /// Special_17/$18: chase — force scroll + Red Wings offset.
    fn tickCinemaChase(self: *GameState) void {
        self.cinema_force_scroll = true;
        // Nudge ship X for wing formation.
        if ((self.cinema_timer & 7) == 0) {
            if (self.cinema_special_id == 0x18) self.cinema_ship_x +%= 1 else self.cinema_ship_x -%= 1;
        }
        if (self.cinema_timer > 0) {
            self.cinema_timer -= 1;
            // Fade out last 16 frames.
            if (self.cinema_timer < 0x10) {
                const b: u8 = @truncate(self.cinema_timer);
                if (b < self.fade_brightness) self.fade_brightness = b;
            }
            // Force south scroll for chase (Special_17 down).
            if (self.mode == .overworld and self.cinema_special_id == 0x17) {
                self.facing = 2;
                if (self.move_dir != 2) {
                    self.move_dir = 2;
                    self.move_px = 0;
                }
                self.move_px +%= 4;
                if (self.move_px >= 16) {
                    self.pos_y = (self.pos_y + 1) & 0xFF;
                    self.move_px = 0;
                }
            }
            return;
        }
        self.cinema_force_scroll = false;
        self.cinema_kind = 0;
        self.move_dir = 0;
        self.setScreenFull();
    }

    /// Special_19–$1B: crushing corridor — `_00d02f` BG2 VOFS $60 −= 16 each wait.
    fn tickCinemaCorridor(self: *GameState) void {
        self.screen_shake = true;
        if (self.cinema_timer > 0) {
            self.cinema_timer -= 1;
            // special.asm @d02f: lda $60; sbc #16 → BG2VOFS each frame of the hold.
            if (self.cinema_scroll_y >= 16) self.cinema_scroll_y -= 16;
            // ship_y tracks bar gap for host black-bar render (from initial /16).
            const gap: i32 = @divTrunc(@as(i32, self.cinema_scroll_y), 16);
            self.cinema_ship_y = @intCast(@min(gap, 0xFF));
            return;
        }
        self.screen_shake = false;
        self.cinema_kind = 0;
        self.cinema_scroll_y = 0;
        self.setScreenFull();
    }

    /// Special_03: zoom up → Red Wings fly left + bombs → ruin Damcyan → zoom down.
    fn tickCinemaDamcyan(self: *GameState) void {
        switch (self.cinema_phase) {
            0 => {
                // @d621: `$ad` $10→$20 (every 4 fields).
                self.cinema_timer +%= 1;
                if ((self.cinema_timer & 3) == 0) {
                    if (self.mode7_zoom < 0x20) self.mode7_zoom +%= 1;
                }
                if (self.mode7_zoom >= 0x20) {
                    self.cinema_phase = 1;
                    self.cinema_timer = 0;
                }
            },
            1 => {
                // @d643: ships move left; bombs when $2c in $40..$90; ruin at $60.
                if (self.cinema_smoke > 0) self.cinema_smoke -%= 1;
                const x = self.cinema_ship_x;
                if (x >= 0x40 and x < 0x90) {
                    if ((x & 7) == 0) {
                        self.queueSfx(0x23);
                        self.cinema_smoke = 0x28;
                        self.cinema_boom_x = @intCast(@as(u8, @truncate(@as(u16, @bitCast(x)))));
                        self.cinema_boom_y = 0x50;
                        self.flash_frames = 2;
                        self.map_invert = true;
                    }
                }
                // DrawDestroyedDamcyan when $2c == $60 (special.asm @d758).
                // ROM writes DestroyedDamcyanTiles to VRAM; host sets switch $14 so
                // ModOverworldTilemap patches cells ($e7/$e8, $39/$3a) → $2d–$3e.
                if (x == 0x60) {
                    const bi: usize = 0x14 >> 3;
                    const bit: u3 = @truncate(0x14 & 7);
                    self.event_switch[bi] |= @as(u8, 1) << bit;
                    self.syncOverworldEventTiles();
                }
                // Decrement $2c every other field (`$7a&1`).
                self.cinema_timer +%= 1;
                if ((self.cinema_timer & 1) != 0) {
                    self.cinema_ship_x -%= 1;
                }
                // End when past left edge (~$ffde path → use x < -0x20).
                if (self.cinema_ship_x < -0x20) {
                    self.cinema_phase = 2;
                    self.cinema_timer = 0;
                    self.cinema_smoke = 0;
                    self.queueSong(0x23);
                }
            },
            else => {
                // @d733: `$ad` $20→$10.
                self.cinema_timer +%= 1;
                if ((self.cinema_timer & 3) == 0) {
                    if (self.mode7_zoom > 0x10) self.mode7_zoom -%= 1;
                }
                if (self.mode7_zoom <= 0x10) {
                    self.cinema_kind = 0;
                    self.cinema_phase = 0;
                    self.cinema_special_id = 0;
                    self.map_invert = false;
                    self.setScreenFull();
                }
            },
        }
    }

    /// `_14fc56` boom centers for Special_0c multi-burst.
    const multi_boom_xy = [_][2]u8{
        .{ 0x40, 0x40 }, .{ 0xA0, 0xA0 }, .{ 0x30, 0x80 }, .{ 0x80, 0x20 },
        .{ 0xC0, 0xB0 }, .{ 0x20, 0x20 }, .{ 0xA0, 0x80 }, .{ 0x80, 0x30 },
    };

    /// Giant of Babil / explosion specials — shake, periodic SFX $23, UpdateExplosions.
    fn tickCinemaGiant(self: *GameState) void {
        self.screen_shake = true;
        // Retrigger smoke bursts every 32 frames (Special_24 plays sfx every $40).
        if (self.cinema_smoke > 0) {
            self.cinema_smoke -%= 1;
        }
        if (self.cinema_timer > 0 and (self.cinema_timer & 0x3F) == 0) {
            self.queueSfx(0x23);
            self.cinema_smoke = 0x28;
            self.flash_frames = 2;
            // Special_0c: walk boom center around `_14fc56`.
            if (self.cinema_special_id == 0x0C) {
                const step: usize = @min((0x100 - self.cinema_timer) / 0x20, multi_boom_xy.len - 1);
                self.cinema_boom_x = multi_boom_xy[step][0];
                self.cinema_boom_y = multi_boom_xy[step][1];
            }
        }
        // Special_40: dim out in last 16 frames.
        if (self.cinema_special_id == 0x40 and self.cinema_timer < 0x10) {
            const b: u8 = @truncate(self.cinema_timer);
            if (b < self.fade_brightness) {
                self.fade_brightness = b;
            }
        }
        if (self.cinema_timer > 0) {
            self.cinema_timer -= 1;
            return;
        }
        self.screen_shake = false;
        self.cinema_smoke = 0;
        self.cinema_kind = 0;
        self.cinema_phase = 0;
        if (self.cinema_special_id == 0x40) {
            self.setScreenOff();
        } else {
            self.setScreenFull();
        }
    }

    fn tickCinemaRedWings(self: *GameState) void {
        // Special_00/01 (special.asm @daa3/@db01):
        //   LoadOverworldIntro → fade in (IncBrightness) while DrawRedWings+$05=JOY_UP
        //   → hold (480 / 272 frames) with scroll → [Special_01: 64f stop] → fade out
        // DrawRedWings each frame: CheckPlayerMoveWorld + MovePlayer with $ac=2 (4 px/field).
        // Leaves $80=0 for following FE WipeIn+DA.
        self.tickRedWingsScroll();
        switch (self.cinema_phase) {
            0 => {
                // IncBrightness: step every 8 fields until $80==$0F
                if (self.display_brightness < 15) {
                    if (!self.isFading()) self.startFade(true);
                    self.tickFade();
                } else {
                    self.cinema_phase = 1;
                    // Special_00: 480 frames; Special_01: 272 frames of forced scroll.
                    self.cinema_timer = if (self.cinema_special_id == 0) 480 else 272;
                    self.cinema_force_scroll = true;
                }
            },
            1 => {
                if (self.cinema_timer > 0) {
                    self.cinema_timer -= 1;
                } else if (self.cinema_special_id == 1) {
                    // Special_01: 64 frames stopped ($05=0) before fade-out.
                    self.cinema_phase = 2;
                    self.cinema_timer = 64;
                    self.cinema_force_scroll = false;
                } else {
                    self.cinema_phase = 3;
                    self.cinema_force_scroll = true; // keep scrolling during fade-out
                    self.startFade(false);
                }
            },
            2 => {
                // Special_01 stop-hold only
                if (self.cinema_timer > 0) {
                    self.cinema_timer -= 1;
                } else {
                    self.cinema_phase = 3;
                    self.cinema_force_scroll = false;
                    // Special_01 @db4e: FadeOutSongSlow before brightness fade.
                    self.song_fade_mode = 1;
                    self.song_fade_timer = 0;
                    self.bgm_gain_num = 16;
                    self.bgm_gain_den = 16;
                    self.startFade(false);
                }
            },
            else => {
                if (self.isFading()) {
                    self.tickFade();
                } else {
                    self.cinema_kind = 0;
                    self.cinema_phase = 0;
                    self.cinema_force_scroll = false;
                    self.move_dir = 0;
                    self.move_px = 0;
                    self.setScreenOff(); // $80=0 for following FE WipeIn + DA FadeIn
                }
            },
        }
    }

    /// DrawRedWings movement: $05=JOY_UP, $ac=2 → PlayerMoveRateTbl[2]=4 px/field north.
    /// Airship (enterprise) over ocean — no foot passability check (VehiclePassBit).
    fn tickRedWingsScroll(self: *GameState) void {
        if (!self.cinema_force_scroll) return;
        if (self.mode != .overworld) return;
        // PlayerMoveRateTbl[2] = 4; direction up = 1.
        const speed: u8 = 4;
        self.facing = 0; // north
        if (self.move_dir != 1) {
            self.move_dir = 1;
            self.move_px = 0;
        }
        self.party_frame +%= 1;
        self.move_px +%= speed;
        if (self.move_px >= 16) {
            self.pos_y = (self.pos_y - 1) & 0xFF;
            self.move_px = 0;
        }
    }

    fn tickCinemaEarthMoon(self: *GameState) void {
        // EarthToMoon / MoonToEarth (vehicle.asm @a365 / @a3b3):
        // fade out → star travel (_00a465/_00a4ef) → LoadMoon/OW → fade in (_00a437).
        switch (self.cinema_phase) {
            0 => {
                // Direction from current world; lock before swap.
                self.cinema_to_moon = self.world_id != 2;
                if (self.mosaic_frame == 0) self.mosaic_frame = 1;
                if (!self.isFading() and self.fade_brightness > 0) self.startFade(false);
                if (self.isFading()) self.tickFade();
                if (!self.isFading() and self.fade_brightness == 0) {
                    // Enter space: DrawStars sequence. `$5c = $ff98` (signed −104).
                    self.cinema_space = true;
                    self.cinema_timer = 0;
                    self.cinema_zoom = earth_moon_mod.starTravelZoom(0);
                    self.cinema_star_seed = self.field_rng;
                    self.cinema_scroll_y = -0x68; // $ff98
                    self.cinema_phase = 1;
                    self.setScreenFull(); // stars drawn at full bright
                }
            },
            1 => {
                // _00a465 first loop: $79 0→$60, zoom=($79>>2)+9, $5c-- every 8f
                self.cinema_star_seed = self.field_rng;
                _ = self.fieldRand();
                self.cinema_zoom = earth_moon_mod.starTravelZoom(@truncate(self.cinema_timer));
                if ((self.cinema_timer & 7) == 0) self.cinema_scroll_y -%= 1;
                self.cinema_timer +%= 1;
                if (self.cinema_timer >= 0x60) {
                    self.cinema_timer = 0x5F;
                    self.cinema_phase = 2;
                }
            },
            2 => {
                // _00a465 second loop: $79 $5f→0
                self.cinema_star_seed = self.field_rng;
                _ = self.fieldRand();
                self.cinema_zoom = earth_moon_mod.starTravelZoom(@truncate(self.cinema_timer));
                if ((self.cinema_timer & 7) == 0) self.cinema_scroll_y -%= 1;
                if (self.cinema_timer == 0) {
                    self.cinema_timer = 0xDF;
                    self.cinema_scroll_y = -0x68; // reset for _00a4ef
                    self.cinema_phase = 3;
                } else {
                    self.cinema_timer -%= 1;
                }
            },
            3 => {
                // _00a4ef: $79 $df→0, $6e = $79*2 (deep zoom out)
                self.cinema_star_seed = self.field_rng;
                _ = self.fieldRand();
                self.cinema_zoom = @as(u16, @truncate(self.cinema_timer)) << 1;
                if (self.cinema_timer == 0) {
                    // LoadMoon / LoadOverworld
                    if (self.cinema_to_moon) {
                        // EarthToMoon: party to whale moon pos `$170c` / `$1725` when set.
                        const mx: u8 = if (self.whale_world == 2) self.whale_x else 0x13;
                        const my: u8 = if (self.whale_world == 2) self.whale_y else 0x27;
                        self.enterWorld(2, mx, my) catch {};
                        self.mode7_zoom = 0x30;
                    } else {
                        // MoonToEarth: restore `$1708` earth pos if we had whale/OW coords.
                        const ex: u8 = if (self.whale_world == 0) self.whale_x else @intCast(new_game_overworld_x & 0xFF);
                        const ey: u8 = if (self.whale_world == 0) self.whale_y else @intCast(new_game_overworld_y & 0xFF);
                        self.enterWorld(0, ex, ey) catch {};
                        self.mode7_zoom = 0x30;
                    }
                    self.cinema_space = false;
                    self.cinema_phase = 4;
                    self.cinema_timer = 0;
                    self.mosaic_frame = 1;
                    self.startFade(true);
                } else {
                    self.cinema_timer -%= 1;
                }
            },
            else => {
                // _00a437: fade-in settle (~$28 frames of mosaic/fade).
                if (self.isFading()) self.tickFade();
                if (!self.isFading() and self.mosaic_frame == 0) {
                    self.cinema_kind = 0;
                    self.cinema_phase = 0;
                    self.cinema_space = false;
                    self.cinema_zoom = 0;
                    self.setScreenFull();
                }
            },
        }
    }

    /// Special_34 telescope (@c61d): fade-in → star/planet window → wait → fade-out.
    fn tickCinemaTelescope(self: *GameState) void {
        self.cinema_space = true;
        self.cinema_to_moon = true;
        self.cinema_star_seed = self.field_rng;
        _ = self.fieldRand();
        // Gentle zoom pulse while viewing.
        self.cinema_zoom = 10 + @as(u16, @truncate((self.cinema_timer >> 2) & 7));
        switch (self.cinema_phase) {
            0 => {
                // Fade in 16 frames ($24 0→$10).
                if (self.fade_brightness < 15) {
                    if (!self.isFading()) self.startFade(true);
                    if (self.isFading()) self.tickFade();
                } else {
                    self.cinema_phase = 1;
                    self.cinema_timer = 180; // wait ~3s or until any later input clears
                }
            },
            1 => {
                // Hold; auto-dismiss after timer (ROM waits for keypress).
                if (self.cinema_timer > 0) {
                    self.cinema_timer -= 1;
                } else {
                    self.cinema_phase = 2;
                    self.startFade(false);
                }
            },
            else => {
                if (self.isFading()) self.tickFade();
                if (!self.isFading() and self.fade_brightness == 0) {
                    self.cinema_kind = 0;
                    self.cinema_phase = 0;
                    self.cinema_space = false;
                    self.cinema_zoom = 0;
                    self.setScreenFull();
                }
            },
        }
    }

    fn tickCinemaGeneric(self: *GameState) void {
        const kind = self.cinema_kind;
        switch (self.cinema_phase) {
            0 => {
                if (kind == 6 or kind == 5) self.screen_shake = true;
                if (self.cinema_timer > 0) {
                    self.cinema_timer -= 1;
                } else {
                    self.cinema_phase = 1;
                    if (kind == 6 or kind == 5) self.screen_shake = false;
                    if (kind == 3 or kind == 7 or kind == 8) {
                        if (self.fade_brightness < 15) self.startFade(true);
                    }
                }
            },
            else => {
                if (self.isFading()) {
                    self.tickFade();
                } else {
                    // Special_35: whale returns to ocean — clear vehicle + hide.
                    if (self.cinema_special_id == 0x35) {
                        if (self.vehicle == vehicle_mod.id_whale) self.vehicle = 0;
                        self.whale_vis = 0;
                        self.updatePlayerSpeed();
                    }
                    self.screen_shake = false;
                    self.cinema_kind = 0;
                    self.cinema_phase = 0;
                    self.cinema_special_id = 0;
                    self.setMsg("");
                }
            },
        }
    }

    /// One field of scripted foot movement during events (no input).
    /// Returns true if still mid-step.
    /// Caller (tickEvent) advances `party_frame` once per field.
    pub fn tickScriptedMove(self: *GameState) bool {
        if (self.move_dir == 0) return false;
        const speed: u8 = if (self.event_fast_move) 2 else 1;
        self.move_px +%= speed;
        if (self.move_px >= 16) {
            const d = dirDelta(self.move_dir);
            switch (self.mode) {
                .overworld => {
                    self.pos_x = (self.pos_x + d.dx) & 0xFF;
                    self.pos_y = (self.pos_y + d.dy) & 0xFF;
                },
                .submap => {
                    self.pos_x += d.dx;
                    self.pos_y += d.dy;
                },
            }
            self.move_px = 0;
            self.move_dir = 0;
            self.updatePartyZ();
            return false;
        }
        return true;
    }

    /// Start a 1-tile scripted walk (event $C0–$C3). dir: 1=up 2=right 3=down 4=left.
    ///
    /// During events (`$b1`), CheckTilePass returns passable always — walls/NPCs do not
    /// block. We still refuse true OOB on 32×32 submaps (impassable fill soft-lock).
    /// Facing: updated unless `$cf` (party_follow) is set (same as joypad path).
    pub fn startScriptedWalk(self: *GameState, dir: u8) void {
        if (dir < 1 or dir > 4) return;
        if (self.move_dir != 0) {
            _ = self.tickScriptedMove();
            while (self.move_dir != 0) _ = self.tickScriptedMove();
        }
        // `$cf`: keep current facing while moving (event.asm NPC walk @e38a / move.asm joypad).
        if (!self.party_follow) {
            self.facing = facingFromDir(dir);
        }
        const dest = self.destTile(dir);
        // Submap OOB: don't step into impassable fill (ROM uses MapSizeMask; we clamp).
        if (self.mode == .submap) {
            if (dest.x < 0 or dest.y < 0 or dest.x >= 32 or dest.y >= 32) {
                self.move_dir = 0;
                self.move_px = 0;
                return;
            }
        }
        // Event choreography: no canWalk / NPC block (CheckTilePass early-out on $b1).
        self.move_dir = dir;
        self.move_px = 0;
    }

    /// Snap party back onto the map if a cutscene left them out of bounds.
    fn clampToMap(self: *GameState) void {
        if (self.mode != .submap) return;
        const sm = self.sub orelse return;
        var x = std.math.clamp(self.pos_x, 0, 31);
        var y = std.math.clamp(self.pos_y, 0, 31);
        // If the edge cell is solid, step toward the map center until passable.
        var guard: u8 = 0;
        while (guard < 32) : (guard += 1) {
            const lo = sm.propLoAt(x, y);
            if ((lo & 0x07) != 0x07) break;
            if (x < 16) x += 1 else if (x > 16) x -= 1;
            if (y < 16) y += 1 else if (y > 16) y -= 1;
        }
        self.pos_x = x;
        self.pos_y = y;
    }

    /// Advance intro/cutscene one field. Call only when eventActive.
    /// `confirm` advances blocked dialogue / Yes on yes-no prompts.
    /// `cancel` selects No on yes-no prompts (inn $DC / F8).
    /// Screen transitions are advanced by `tickTransition` (call that first each field).
    pub fn tickEvent(self: *GameState, confirm: bool, cancel: bool) void {
        if (!self.event_player.active) return;

        // $7b advances every event field so spin ($d8) and walk frames keep cycling.
        self.party_frame +%= 1;

        // EventCmd_d9 Namingway: hold script until session finishes.
        if (self.namingway.active()) return;

        // Scripted player walk: hold event until the tile step finishes.
        if (self.move_dir != 0) {
            _ = self.tickScriptedMove();
            if (self.npcs) |*ns| {
                if (ns.anyMoving()) _ = ns.tickMoves();
            }
            if (self.move_dir != 0) return;
        }

        // Hold script while fade / iris wipe / cinema / mosaic runs.
        // Warp block is cleared only after the transition is fully idle.
        if (self.isTransitioning() or self.mosaic_frame != 0) {
            if (self.npcs) |*ns| {
                if (ns.anyMoving()) _ = ns.tickMoves();
            }
            return;
        }

        // Transition finished — unstick FE warp wait before more opcodes.
        if (self.event_player.blocked == .warp) {
            self.event_player.clearBlock();
        }

        if (self.event_player.blocked == .yes_no) {
            if (!confirm and !cancel) return;
            const kind = self.event_player.yes_no_kind;
            const said_yes = confirm and !cancel;
            self.closeDlg();
            if (said_yes) {
                switch (kind) {
                    .inn => {
                        // Pay; short gil → msg $19 and abort.
                        if (event_mod.eventInnPayPub(&self.gil, self.event_player.inn_price_idx)) {
                            self.event_player.clearBlock();
                        } else {
                            self.openEventDlg(0x19, "Not enough gil.");
                            self.event_player.abortScript();
                            return;
                        }
                    },
                    .f8, .none => {
                        self.event_player.clearBlock();
                    },
                }
            } else {
                // No: come-again $1B for inn; abort remainder (FindEventTerminator).
                if (kind == .inn) {
                    self.openEventDlg(0x1B, "Please come again.");
                }
                self.event_player.abortScript();
                return;
            }
        } else if (self.event_player.blocked == .dialogue) {
            // Auto-scroll (`$cb`): pages advance in tickTransition; hold block while open.
            if (self.dlg_auto_scroll) {
                if (self.dlg_open) return;
                self.event_player.clearBlock();
                return;
            }
            if (!confirm) return;
            // Multi-page: advanceDlg may keep box open (F0 $20 crew exchange = 2 pages).
            if (self.dlg_open) {
                const still = self.advanceDlg();
                if (still) return;
            } else {
                // Box closed (e.g. Esc) while still blocked — treat confirm as dismiss.
                self.closeDlg();
            }
            self.event_player.clearBlock();
        } else if (self.event_player.blocked == .battle) {
            // Host owns the battle; do not advance the script until resumeAfterEventBattle.
            return;
        }

        var walk_req: u8 = 0;
        // `$cf` → NPC event walks keep facing (event.asm @e38a).
        if (self.npcs) |*ns| ns.hold_facing = self.party_follow;
        var ctx = event_mod.EventCtx{
            .rom = self.rom,
            .event_switch = self.event_switch[0..],
            .npc_switch = self.npc_switch[0..],
            .inventory = &self.inventory,
            .map_id = self.map_id,
            .party = self.party[0..],
            .gil = &self.gil,
            .spell_lists = &self.spell_lists,
            .npcs = if (self.npcs) |*ns| ns else null,
            .dlg_buf = &self.dlg_buf,
            .npc_dlg_table = self.npc_dlg_table_buf[0..self.npc_dlg_table_len],
            .player_facing = &self.facing,
            .player_hidden = &self.player_hidden,
            .player_spin = &self.player_spin,
            .party_follow = &self.party_follow,
            .player_walk_dir = &walk_req,
        };
        const y = self.event_player.tick(&ctx);
        // F2/F3 may open Mist pass / Damcyan ruins / Agart hole mid-script.
        self.syncOverworldEventTiles();
        if (walk_req != 0) self.startScriptedWalk(walk_req);
        if (ctx.set_leader_char_id) |cid| {
            _ = self.setFieldLeaderByCharId(cid);
        }
        switch (y) {
            .running => {},
            .dialogue, .yes_no => {
                // Only open/reset page when the player actually yielded a new string.
                // If still blocked with empty ctx (shouldn't happen), keep the open box.
                if (ctx.dlg_len > 0) {
                    self.dlg_len = ctx.dlg_len;
                    self.dlg_open = true;
                    self.dlg_page = 0;
                } else if (!self.dlg_open) {
                    // No text and nothing on screen — don't soft-lock the script.
                    self.event_player.clearBlock();
                }
            },
            .warp => {
                // EventCmd_fe (event.asm @f039):
                //   submap dest (map < $fb) → jsr PushMapStack then load
                //   world dest ($fb+) → no push
                // Intro still clears stack on event $10 done (soft-reset free roam).
                if (self.event_player.last_warp) |w| {
                    var ww = w;
                    // World FE: enterWorld replaces field; no return push.
                    if (ww.to_world) ww.skip_stack_push = true;
                    // Submap FE: leave skip_stack_push false → enterSubmap pushes.
                    self.beginMapTransition(ww);
                }
            },
            .battle => {
                // EventCmd_ec — queue formation; app transitions to battle UI.
                self.pending_event_battle = self.event_player.last_battle_id;
                self.dlg_open = false;
            },
            .done => {
                self.dlg_open = false;
                // $C8 hide is only cleared by $C9 in-script, or when free roam resumes.
                self.player_hidden = false;
                self.player_spin = false;
                // Cardinal facing only — cutscene poses 4–7 / spin 8 must not stick for free roam.
                if (self.facing > 3) self.facing = 2;
                self.setScreenFull();
                self.wipe_phase = 0;
                self.cinema_kind = 0;
                self.move_dir = 0;
                self.move_px = 0;
                // Scripted walks that ignored walls (pre-fix) or long east walks can leave
                // the party outside 0..31 on maps with impassable fill (Kaipo inn $39).
                self.clampToMap();
                // Re-apply NPC visibility after cutscene (F4/F5 crystal hide, doors).
                if (self.npcs) |*ns| {
                    const map_high = self.map_id >= 256 or (if (self.sub) |*sm| (sm.prop.tilemap_msb & 0x80) != 0 else false);
                    ns.refreshVisibility(self.npc_switch[0..], map_high);
                }
                // Intro-only post-script (event $10 SoftReset path).
                if (self.event_player.event_id == event_mod.intro_event_id) {
                    // Cutscene FEs must not leave a polluted map stack (free-roam exits
                    // would pop back into mid-intro rooms).
                    self.stack_len = 0;
                    self.facing = 2;
                    self.setMsg("The journey begins.");
                    if (self.mode == .submap and self.sub == null) {
                        self.enterWorld(0, new_game_overworld_x, new_game_overworld_y) catch {};
                    }
                }
            },
        }
        if (ctx.sfx != 0) self.queueSfx(ctx.sfx);
        // EventCmd_fa: play song — cancels D8 fade and restores audible gain.
        if (ctx.song != 0xFF) self.queueSong(ctx.song);
        // EventCmd_da: FadeIn if $80==0, else FadeOut (field.asm @ea4c) — all events.
        if (ctx.fade_toggle) {
            if (self.fade_brightness == 0) {
                self.startFade(true);
            } else {
                self.startFade(false);
            }
        }
        // EventCmd_d0–d9 / fd screen FX from EventPlayer.
        if (ctx.shake_toggle) self.screen_shake = !self.screen_shake;
        if (ctx.flash) self.flash_frames = field_fx_mod.flash_hold_frames;
        if (ctx.mosaic) self.mosaic_frame = 1;
        if (ctx.quake_pulse) self.quake_frames = 8;
        if (ctx.speed_toggle) self.event_fast_move = !self.event_fast_move;
        // EventCmd_d8: FadeOutSongSlow — only ducks current track; FA must cancel (see queueSong).
        if (ctx.song_fade_out) {
            // FadeOutSongSlow (field.asm @8d53 → SPC $85); host gain ramp.
            self.song_fade_mode = 1;
            self.song_fade_timer = 0;
            self.bgm_gain_num = field_fx_mod.song_fade_slow_start_num;
            self.bgm_gain_den = 16;
        }
        if (ctx.earth_moon) self.startCinema(2, 0);
        // EventCmd_d5: open secret door (event.asm @ee9f) — find $60 near player,
        // rewrite 2×2 to $64–$67, PlaySfx $31, one field. No multi-frame cinema.
        if (ctx.secret_door) {
            if (self.sub) |*sm| {
                _ = sm.openSecretDoorNear(self.pos_x, self.pos_y);
            }
            self.queueSfx(0x31);
        }
        if (ctx.menu_fx == 1) {
            self.setMsg("Fat Chocobo!");
            self.startFade(false);
            self.startCinema(7, 48);
        } else if (ctx.menu_fx == 2) {
            // EventCmd_d9 → NamingwayMenu (namingway.asm @ba1a).
            self.namingway.begin();
            self.setMsg("Change a name?");
            self.startFade(false);
            // No cinema hold — tickEvent gates on namingway.active().
        }
        if (ctx.special_id) |sid| self.startSpecial(sid);
        // EventCmd_ed from live EventPlayer (bulk path sets via applyEventResult).
        if (ctx.shop_id) |sid| self.pending_shop = sid;
        if (ctx.party_dirty) {
            self.party_sprite_dirty = true;
            // After $e7/$e8 roster changes: keep $1703 valid without forced cycle.
            self.ensureFieldLeader();
        }
        if (ctx.npc_dirty) {
            // Prefer visibility refresh so $EB choreography positions aren't wiped.
            if (self.npcs) |*ns| {
                const map_high = self.map_id >= 256 or (if (self.sub) |*sm| (sm.prop.tilemap_msb & 0x80) != 0 else false);
                ns.refreshVisibility(self.npc_switch[0..], map_high);
            } else {
                self.reloadNpcs() catch {};
            }
        }
    }

    /// Field leader for sprite load: gfx + PlayerPalTbl palette index.
    /// LoadPlayerGfx (player.asm @c88b) — see field_fx.fieldGfxId.
    pub fn fieldSpriteIds(self: *const GameState) struct { gfx: u8, pal: u8 } {
        const m = self.leader();
        const sprites = @import("../map/sprites.zig");
        const s1 = m.status1;
        const gfx = field_fx_mod.fieldGfxId(m.gfx_id, s1);
        // Form sheets: host uses palette 0; normal class uses PlayerPalTbl.
        const pal: u8 = if (field_fx_mod.fieldFormOverride(s1))
            0
        else
            sprites.fieldPalIndex(m.class_id);
        return .{ .gfx = gfx, .pal = pal };
    }

    /// ValidateTopChar (player.asm @c85e): advance $1703 to next present party slot.
    pub fn validateFieldLeader(self: *GameState) void {
        var present: [5]bool = .{false} ** 5;
        var i: usize = 0;
        while (i < 5) : (i += 1) present[i] = self.party[i].present;
        self.field_leader_slot = party_mod.validateTopChar(&present, self.field_leader_slot);
        self.party_sprite_dirty = true;
    }

    /// Ensure $1703 points at a present slot without advancing (load / init).
    pub fn ensureFieldLeader(self: *GameState) void {
        var present: [5]bool = .{false} ** 5;
        var i: usize = 0;
        while (i < 5) : (i += 1) present[i] = self.party[i].present;
        if (self.party[self.field_leader_slot % 5].present) return;
        self.field_leader_slot = party_mod.firstPresentSlot(&present);
        self.party_sprite_dirty = true;
    }

    /// EventCmd_dd: set field leader by character id ($1000&$1F).
    pub fn setFieldLeaderByCharId(self: *GameState, char_id: u8) bool {
        const want = char_id & 0x1F;
        for (self.party, 0..) |m, i| {
            if (!m.present) continue;
            if ((m.id & 0x1F) == want) {
                self.field_leader_slot = @intCast(i);
                self.party_sprite_dirty = true;
                return true;
            }
        }
        return false;
    }

    fn applyEventWarp(self: *GameState, w: event_mod.Warp) !void {
        self.move_dir = 0;
        self.move_px = 0;
        // Stack-pop return: don't push the map we're leaving (field.asm exit path).
        const prev_skip = self.suppress_stack_push;
        self.suppress_stack_push = w.skip_stack_push;
        defer self.suppress_stack_push = prev_skip;
        if (w.to_world) {
            try self.enterWorld(w.world_id, w.x, w.y);
            // LoadMapStack restores facing on submap; world path keeps stack facing if set.
            self.facing = w.facing & 3;
            // EventCmd_fe @f0c4: board vehicle from flags (clears vehicle if 0).
            if (w.vehicle_id != 0) {
                self.applyWarpVehicle(w.vehicle_id);
            } else {
                // FE submap→world without vehicle clears `$1704` (event.asm @f0c4).
                self.vehicle = 0;
                self.move_speed_class = 0;
                // WorldSongTbl (field PlayMapSong)
                if (w.world_id < 3) {
                    const ws = [_]u8{ 0x0D, 0x06, 0x31 };
                    self.queueSong(ws[w.world_id]);
                }
            }
        } else {
            // Leaving for a submap dismounts (FE stz $1704 before LoadMap).
            self.vehicle = 0;
            self.move_speed_class = 0;
            try self.enterSubmap(w.map_id, w.x, w.y, w.facing);
            // Sub-map BGM from MapProp byte7 (unless event FA already queued one this tick)
            if (self.sub) |*sm| {
                if (sm.prop.song != 0 and self.pending_song == 0xFF)
                    self.queueSong(sm.prop.song);
            }
        }
    }

    /// Queue a BGM id (EventCmd_fa / PlayMapSong). Cancels D8 fade and restores gain
    /// so the new track is audible after FadeOutSongSlow.
    pub fn queueSong(self: *GameState, song_id: u8) void {
        if (song_id == 0 or song_id == 0xFF) return;
        self.pending_song = song_id;
        self.song_fade_mode = 0;
        self.song_fade_timer = 0;
        self.bgm_gain_num = 1;
        self.bgm_gain_den = 2;
    }

    pub fn consumeSong(self: *GameState) ?u8 {
        if (self.pending_song == 0xFF) return null;
        const s = self.pending_song;
        self.pending_song = 0xFF;
        return s;
    }

    pub fn leader(self: *const GameState) *const PartyMember {
        const slot = self.field_leader_slot % 5;
        if (self.party[slot].present) return &self.party[slot];
        // Fallback: first present member.
        for (&self.party) |*m| {
            if (m.present) return m;
        }
        return &self.party[0];
    }
    pub fn leaderMut(self: *GameState) *PartyMember {
        const slot = self.field_leader_slot % 5;
        if (self.party[slot].present) return &self.party[slot];
        for (&self.party) |*m| {
            if (m.present) return m;
        }
        return &self.party[0];
    }

    pub fn setMsg(self: *GameState, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_msg_len = n;
    }
    pub fn msgSlice(self: *const GameState) []const u8 {
        return self.status_msg[0..self.status_msg_len];
    }

    /// Human-readable location for HUD (rosa US map names). Always available.
    pub fn locationLabel(self: *const GameState) []const u8 {
        return switch (self.mode) {
            .overworld => switch (self.world_id) {
                1 => "Underworld",
                2 => "Lunar Overworld",
                else => "Overworld",
            },
            .submap => map_names.nameFor(self.map_id) orelse "Unknown Map",
        };
    }

    fn setLocationMsg(self: *GameState) void {
        self.setMsg(self.locationLabel());
    }
    pub fn dlgSlice(self: *const GameState) []const u8 {
        return self.dlg_buf[0..self.dlg_len];
    }

    pub fn dlgPageCount(self: *const GameState) usize {
        return ui_mod.dialoguePageCount(self.dlgSlice());
    }

    pub fn canWalk(self: *const GameState, nx: i32, ny: i32) bool {
        return switch (self.mode) {
            .overworld => blk: {
                const ow = self.ow orelse break :blk false;
                if (self.vehicle != 0) {
                    break :blk ow.canVehiclePass(nx, ny, self.vehicle);
                }
                break :blk ow.canWalk(self.pos_x, self.pos_y, nx, ny);
            },
            .submap => if (self.sub) |*sm| sm.canWalk(self.pos_x, self.pos_y, nx, ny) else false,
        };
    }

    /// PlayerMoveRateTbl[PlayerSpeedTbl[vehicle]] (move.asm / field.asm).
    pub fn movePixelRate(self: *const GameState) u8 {
        const cls = @min(self.move_speed_class, 3);
        return vehicle_mod.player_move_rate_tbl[cls];
    }

    /// True when mounted (`$1704 != 0`) — hide foot sprite, draw vehicle.
    pub fn isMounted(self: *const GameState) bool {
        return self.vehicle != 0;
    }

    /// UpdatePlayerSpeed: `$ac` = PlayerSpeedTbl[`$1704`].
    pub fn updatePlayerSpeed(self: *GameState) void {
        const v = self.vehicle;
        if (v < vehicle_mod.player_speed_tbl.len) {
            self.move_speed_class = vehicle_mod.player_speed_tbl[v];
        } else {
            self.move_speed_class = 0;
        }
    }

    /// Board vehicle id (BoardChoco / BoardHover / … + liftoff anims).
    /// `from_event`: FE acquire path may ShowVehicleSmoke before liftoff (BoardEnterprise @a241).
    pub fn boardVehicle(self: *GameState, id: u8) void {
        self.boardVehicleEx(id, false);
    }

    pub fn boardVehicleEx(self: *GameState, id: u8, from_event: bool) void {
        if (id == 0 or id > 7) return;
        self.vehicle = id;
        switch (id) {
            vehicle_mod.id_chocobo => self.choco_vis = 1,
            vehicle_mod.id_black_chocobo => {
                self.bk_choco_vis = 1;
                if (self.bk_choco_hook == 0) {
                    self.bk_choco_x = @intCast(self.pos_x & 0xFF);
                    self.bk_choco_y = @intCast(self.pos_y & 0xFF);
                }
                self.bk_choco_hook +%= 1;
                self.vehicle_anim.begin(.bk_liftoff);
            },
            vehicle_mod.id_hovercraft => {
                self.hover_vis = 1;
                self.hover_world = self.world_id;
                // BoardHover @a17f: smoke when `$b1` (event), else just board anim.
                if (from_event) {
                    self.vehicle_anim.begin(.show_smoke);
                } else {
                    self.vehicle_anim.begin(.hover_board);
                }
            },
            vehicle_mod.id_enterprise => {
                self.enterprise_vis = 1;
                self.enterprise_world = self.world_id;
                self.facing = 3;
                if (from_event) {
                    self.vehicle_anim.begin(.show_smoke); // → air_liftoff in tick
                } else {
                    self.vehicle_anim.begin(.air_liftoff);
                }
            },
            vehicle_mod.id_falcon => {
                self.falcon_vis = 1;
                self.falcon_world = self.world_id;
                self.facing = 3;
                if (from_event) {
                    self.vehicle_anim.begin(.show_smoke);
                } else {
                    self.vehicle_anim.begin(.air_liftoff);
                }
            },
            vehicle_mod.id_whale => {
                self.whale_vis = 1;
                self.whale_world = self.world_id;
                self.facing = 3;
                self.vehicle_anim.begin(.air_liftoff);
            },
            vehicle_mod.id_ship => self.ship_vis = 1,
            else => {},
        }
        self.updatePlayerSpeed();
        self.save_enabled = false;
        self.queueVehicleSong();
    }

    fn queueVehicleSong(self: *GameState) void {
        const v = self.vehicle;
        if (v == 0) {
            const song: u8 = switch (self.mode) {
                .overworld => if (self.world_id < 3)
                    ([_]u8{ 0x0D, 0x06, 0x31 })[self.world_id]
                else
                    0x0D,
                .submap => if (self.sub) |*sm| sm.prop.song else 0,
            };
            if (song != 0) self.queueSong(song);
            return;
        }
        if (vehicle_mod.songForVehicle(v)) |song| {
            self.queueSong(song);
        }
    }

    /// True while board/land anim blocks free roam (vehicle.asm Animate loops).
    pub fn vehicleAnimActive(self: *const GameState) bool {
        return self.vehicle_anim.active();
    }

    /// Altitude `$b5`/`$b6`/`$b7` for ridden sprite Y.
    pub fn vehicleAlt(self: *const GameState) u8 {
        if (self.vehicle_anim.active()) return self.vehicle_anim.alt;
        // Cruising airship / bk choco / hover keep last altitude when anim ends at high alt.
        return switch (self.vehicle) {
            vehicle_mod.id_black_chocobo => 0x10,
            vehicle_mod.id_hovercraft => 0x04,
            vehicle_mod.id_enterprise, vehicle_mod.id_falcon, vehicle_mod.id_whale => 0x10,
            else => 0,
        };
    }

    /// `$ad` Mode-7 zoom value (InitMapRAM / LoadOverworld default `$10` on foot).
    pub fn mode7Zoom(self: *const GameState) u8 {
        if (self.mode != .overworld) return 0x10;
        // GoDownTunnel / TunnelAnim write `$ad` from `$79` each frame.
        if (self.vehicle_anim.tunnel_ad != 0xFF) return self.vehicle_anim.tunnel_ad;
        return switch (self.vehicle) {
            vehicle_mod.id_enterprise, vehicle_mod.id_falcon => blk: {
                // LiftoffEnterprise: `$ad = $b7 + $10`.
                break :blk 0x10 +% self.vehicleAlt();
            },
            vehicle_mod.id_whale => 0x20 +% self.vehicleAlt(),
            // Foot / choco / hover / ship: stored `$ad` (normally `$10` → zoom bank level 0).
            else => self.mode7_zoom,
        };
    }

    /// A register for UpdateZoomPal: altitude `$b7` 0..$10 (not raw `$ad`).
    /// Foot → 0; full cruise → $10 (table last entry).
    pub fn zoomPalLevel(self: *const GameState) u8 {
        if (self.mode != .overworld) return 0;
        return switch (self.vehicle) {
            vehicle_mod.id_enterprise, vehicle_mod.id_falcon, vehicle_mod.id_whale => @min(self.vehicleAlt(), 0x10),
            else => if (self.vehicle_anim.kind == .air_liftoff or self.vehicle_anim.kind == .air_land)
                @min(self.vehicle_anim.alt, 0x10)
            else if (self.vehicle_anim.kind == .tunnel_down or self.vehicle_anim.kind == .tunnel_up)
                // GoDownTunnel: UpdateZoomPal from `$b7`/`$b8` (our `alt`).
                @min(self.vehicle_anim.alt, 0x10)
            else
                0,
        };
    }

    /// One field of vehicle board/land anim. Call from field tick with `$7a`.
    pub fn tickVehicleAnim(self: *GameState, snes_7a: u8) void {
        if (!self.vehicle_anim.active()) return;
        const can_land = self.vehicleLandCheck();
        var face = self.facing;
        const rb = self.fieldRand();
        const kind_before = self.vehicle_anim.kind;
        const still = vehicle_mod.tickAnim(&self.vehicle_anim, snes_7a, can_land, &face, rb);
        self.facing = face;

        // GoDownTunnel mid-sequence: LoadUnderground after rotation phase (@95b0).
        if (self.vehicle_anim.tunnel_do_swap) {
            self.vehicle_anim.tunnel_do_swap = false;
            self.applyTunnelDown();
            // applyTunnelDown clears pending; keep phase-2 anim running.
            if (self.vehicle_anim.kind != .tunnel_down) {
                self.vehicle_anim.begin(.tunnel_down);
                self.vehicle_anim.phase = 2;
                self.vehicle_anim.timer = 0x2F;
                self.vehicle_anim.tunnel_ad = 0x20;
                if (0x2F < vehicle_mod.tunnel_y_tbl.len)
                    self.vehicle_anim.alt = vehicle_mod.tunnel_y_tbl[0x2F];
            }
        }

        // Failed land → re-liftoff: do not dismount when liftoff ends.
        if (self.vehicle_anim.reject_land) {
            self.vehicle_anim.reject_land = false;
            self.vehicle_land_pending = false;
        }

        // Grab/drop hover: toggle `$06d0` at timer $20 (GrabHover @a755 / DropHover @a726).
        if (self.vehicle_anim.kind == .grab_hover and vehicle_mod.hoverHookToggleFrame(self.vehicle_anim.timer)) {
            self.holding_hover = true;
        }
        if (self.vehicle_anim.kind == .drop_hover and vehicle_mod.hoverHookToggleFrame(self.vehicle_anim.timer)) {
            self.holding_hover = false;
            self.hover_x = @intCast(self.pos_x & 0xFF);
            self.hover_y = @intCast(self.pos_y & 0xFF);
            self.hover_world = self.world_id;
            self.hover_vis = 1;
        }

        if (still) return;

        // Anim finished — complete land if that was a land sequence.
        if (self.vehicle_land_pending) {
            self.vehicle_land_pending = false;
            self.finishLand();
        }

        // Tunnel anim done. GoDownTunnel already LoadUnderground mid-sequence;
        // only TunnelAnim/GoUpTunnel warps on finish (field.asm @9627).
        if (kind_before == .tunnel_down) {
            self.pending_tunnel = .none;
            self.facing = 3;
        } else if (kind_before == .tunnel_up) {
            self.applyTunnelUp();
        }

        // Smoke finished → liftoff / hover board (ShowVehicleSmoke then Board*).
        if (kind_before == .show_smoke) {
            if (self.vehicle == vehicle_mod.id_hovercraft) {
                self.vehicle_anim.begin(.hover_board);
            } else if (self.vehicle >= vehicle_mod.id_enterprise and self.vehicle <= vehicle_mod.id_falcon) {
                self.vehicle_anim.begin(.air_liftoff);
            }
        }
    }

    /// GoDownTunnel dest: under ($71,$10), world 1 (field.asm @95b0).
    fn applyTunnelDown(self: *GameState) void {
        const v = self.vehicle;
        self.enterWorld(1, 0x71, 0x10) catch {};
        self.vehicle = v;
        self.updatePlayerSpeed();
        self.facing = 3;
        if (v == vehicle_mod.id_enterprise) {
            self.enterprise_world = 1;
            if (self.holding_hover) self.hover_world = 1;
        } else if (v == vehicle_mod.id_falcon) {
            self.falcon_world = 1;
        }
        // LoadUnderground: full tilemap + assets (field.asm @853c).
        if (self.ow) |*ow| {
            ow.switchWorld(self.rom, 1) catch {};
            self.syncOverworldEventTiles();
        }
        self.queueVehicleSong();
        self.pending_tunnel = .none;
    }

    /// GoUpTunnel @9627: TunnelAnim → optional event $C6 → DrillAnim.
    fn applyTunnelUp(self: *GameState) void {
        self.pending_tunnel = .none;
        // if switch $30 clear and $3d set → ExecEvent $C6 (story), then DrillAnim.
        if (!self.eventSwitchOn(0x30) and self.eventSwitchOn(0x3D)) {
            if (self.event_player.start(self.rom, 0xC6)) {
                self.pending_drill_up = true;
                return;
            }
        }
        self.doDrillAnimWarp();
    }

    /// DrillAnim @9690 — LoadOverworld at Agart hole ($6A,$D4), then reverse-spin + climb.
    fn doDrillAnimWarp(self: *GameState) void {
        const v = self.vehicle;
        self.enterWorld(0, 0x6A, 0xD4) catch {};
        self.vehicle = v;
        self.updatePlayerSpeed();
        self.facing = 3;
        if (v == vehicle_mod.id_enterprise) {
            self.enterprise_world = 0;
            if (self.holding_hover) self.hover_world = 0;
        } else if (v == vehicle_mod.id_falcon) {
            self.falcon_world = 0;
        }
        if (self.ow) |*ow| {
            ow.switchWorld(self.rom, 0) catch {};
            self.syncOverworldEventTiles();
        }
        self.queueVehicleSong();
        self.pending_drill_up = false;
        // Post-warp DrillAnim rotation + altitude climb (@96d7).
        self.vehicle_anim.begin(.drill_anim);
    }

    /// Call when EventPlayer becomes idle — completes deferred DrillAnim.
    pub fn afterEventIdle(self: *GameState) void {
        if (self.pending_drill_up and !self.event_player.active) {
            self.doDrillAnimWarp();
        }
    }

    fn vehicleLandCheck(self: *const GameState) bool {
        const ow = self.ow orelse return false;
        return switch (self.vehicle) {
            vehicle_mod.id_black_chocobo => ow.canLandBlackChoco(self.pos_x, self.pos_y),
            vehicle_mod.id_hovercraft => ow.canLandFoot(self.pos_x, self.pos_y),
            vehicle_mod.id_enterprise, vehicle_mod.id_falcon, vehicle_mod.id_whale => blk: {
                if (!ow.canLandAirship(self.pos_x, self.pos_y)) break :blk false;
                // Can't land on hover / other airships (LandEnterprise @a672+).
                const px: u8 = @intCast(self.pos_x & 0xFF);
                const py: u8 = @intCast(self.pos_y & 0xFF);
                if (self.hover_vis != 0 and !self.holding_hover and self.hover_world == self.world_id and self.hover_x == px and self.hover_y == py)
                    break :blk false;
                if (self.vehicle != vehicle_mod.id_falcon and self.falcon_vis != 0 and self.falcon_world == self.world_id and self.falcon_x == px and self.falcon_y == py)
                    break :blk false;
                if (self.vehicle != vehicle_mod.id_enterprise and self.enterprise_vis != 0 and self.enterprise_world == self.world_id and self.enterprise_x == px and self.enterprise_y == py)
                    break :blk false;
                if (self.vehicle != vehicle_mod.id_whale and self.whale_vis != 0 and self.whale_world == self.world_id and self.whale_x == px and self.whale_y == py)
                    break :blk false;
                break :blk true;
            },
            else => true,
        };
    }

    fn finishLand(self: *GameState) void {
        const px: u8 = @intCast(self.pos_x & 0xFF);
        const py: u8 = @intCast(self.pos_y & 0xFF);
        // LandChoco zeros `$1704` mid-flee — use saved land id.
        const v = if (self.vehicle != 0) self.vehicle else self.vehicle_land_id;
        self.vehicle_land_id = 0;
        switch (v) {
            vehicle_mod.id_chocobo => {
                // LandChoco @a103: stz $170f
                self.choco_vis = 0;
            },
            vehicle_mod.id_black_chocobo => {
                self.bk_choco_x = px;
                self.bk_choco_y = py;
                self.bk_choco_vis = 1;
                if (self.bk_choco_hook >= 2) {
                    self.bk_choco_hook = 0;
                    self.bk_choco_vis = 0;
                }
            },
            vehicle_mod.id_hovercraft => {
                self.hover_x = px;
                self.hover_y = py;
                self.hover_world = self.world_id;
                self.hover_vis = 1;
            },
            vehicle_mod.id_enterprise => {
                self.enterprise_x = px;
                self.enterprise_y = py;
                self.enterprise_world = self.world_id;
                self.enterprise_vis = 1;
            },
            vehicle_mod.id_falcon => {
                self.falcon_x = px;
                self.falcon_y = py;
                self.falcon_world = self.world_id;
                self.falcon_vis = 1;
            },
            vehicle_mod.id_whale => {
                self.whale_x = px;
                self.whale_y = py;
                self.whale_world = self.world_id;
                self.whale_vis = 1;
                if (!self.eventActive()) self.pending_whale_script = true;
            },
            else => {},
        }
        self.vehicle = 0;
        self.move_speed_class = 0;
        self.facing = 2;
        self.save_enabled = true;
        // InitMapRAM / after land: `$ad = $10` (foot orthographic Mode-7 bank level 0).
        self.mode7_zoom = 0x10;
        self.queueVehicleSong();

        if (self.pending_whale_script) {
            self.pending_whale_script = false;
            // WhaleButton @a851: ExecTriggerScript $52 when not mid-acquire ($b1).
            _ = self.runEventFromTriggerScript(field_fx_mod.whale_land_trigger_script);
        }
    }

    /// ExecTriggerScript by id (resolve → EventPlayer).
    fn runEventFromTriggerScript(self: *GameState, script_id: u8) bool {
        const eid = event_mod.resolveTriggerEventId(self.rom, script_id, self.event_switch[0..]) orelse return false;
        if (eid == 0) return false;
        return self.event_player.start(self.rom, eid);
    }

    /// ChangeVehicle (vehicle.asm @9e3b): A while idle on world — board or land.
    pub fn tryChangeVehicle(self: *GameState) bool {
        if (self.mode != .overworld) return false;
        if (self.vehicle_anim.active()) return false;
        if (self.move_dir != 0) return false;

        // Tunnel boxes first (enterprise/falcon only, event switches $30/$3d).
        if (self.tryTunnelSwitch()) return true;

        if (self.vehicle != 0) return self.tryLandVehicle();
        return self.tryBoardNearbyVehicle();
    }

    /// ChangeVehicle @9e5a: OW Agart hole ↔ under hole when riding enterprise/falcon.
    fn tryTunnelSwitch(self: *GameState) bool {
        if (self.vehicle != vehicle_mod.id_enterprise and self.vehicle != vehicle_mod.id_falcon) return false;
        // Need event switch $3d OR $30 (tunnel unlocked).
        if (!self.eventSwitchOn(0x3D) and !self.eventSwitchOn(0x30)) return false;

        const x: u8 = @intCast(self.pos_x & 0xFF);
        const y: u8 = @intCast(self.pos_y & 0xFF);

        if (self.world_id == 0) {
            // Overworld → underground: x $69..$6B, y $D3..$D5
            if (x >= 0x69 and x < 0x6C and y >= 0xD3 and y < 0xD6) {
                self.pending_tunnel = .down;
                self.vehicle_anim.begin(.tunnel_down);
                return true;
            }
        } else if (self.world_id == 1) {
            // Underground → overworld: x $70..$72, y $0F..$11
            if (x >= 0x70 and x < 0x73 and y >= 0x0F and y < 0x12) {
                self.pending_tunnel = .up;
                self.vehicle_anim.begin(.tunnel_up);
                return true;
            }
        }
        return false;
    }

    fn tryBoardNearbyVehicle(self: *GameState) bool {
        const px: u8 = @intCast(self.pos_x & 0xFF);
        const py: u8 = @intCast(self.pos_y & 0xFF);
        // ChangeVehicle board order (vehicle.asm @9edd–@9f6b). No ship (FE only).
        if (self.world_id == 0 and self.choco_vis != 0 and self.choco_x == px and self.choco_y == py) {
            self.boardVehicle(vehicle_mod.id_chocobo);
            return true;
        }
        if (self.world_id == 0 and self.bk_choco_vis != 0 and self.bk_choco_x == px and self.bk_choco_y == py) {
            self.boardVehicle(vehicle_mod.id_black_chocobo);
            return true;
        }
        if (self.hover_vis != 0 and self.hover_world == self.world_id and self.hover_x == px and self.hover_y == py) {
            self.boardVehicle(vehicle_mod.id_hovercraft);
            return true;
        }
        if (self.enterprise_vis != 0 and self.enterprise_world == self.world_id and self.enterprise_x == px and self.enterprise_y == py) {
            self.boardVehicle(vehicle_mod.id_enterprise);
            return true;
        }
        if (self.falcon_vis != 0 and self.falcon_world == self.world_id and self.falcon_x == px and self.falcon_y == py) {
            self.boardVehicle(vehicle_mod.id_falcon);
            return true;
        }
        if (self.whale_vis != 0 and self.whale_world == self.world_id and self.whale_x == px and self.whale_y == py) {
            self.boardVehicle(vehicle_mod.id_whale);
            return true;
        }
        return false;
    }

    fn tryLandVehicle(self: *GameState) bool {
        const ow = self.ow orelse return false;
        const px: u8 = @intCast(self.pos_x & 0xFF);
        const py: u8 = @intCast(self.pos_y & 0xFF);

        switch (self.vehicle) {
            vehicle_mod.id_chocobo => {
                // LandChoco @a07b: need `$a1&$01`, then flee anim with `$1704=0`.
                if (!ow.canLandFoot(self.pos_x, self.pos_y)) return false;
                self.vehicle_land_id = vehicle_mod.id_chocobo;
                self.choco_vis = 2; // fleeing (DrawChoco `$170f==2`)
                self.vehicle = 0; // stz $1704 at @a0be — player on foot during flee
                self.move_speed_class = 0;
                self.vehicle_land_pending = true;
                self.vehicle_anim.beginChocoFlee(self.fieldRand(), self.fieldRand());
                self.facing = if (self.vehicle_anim.flee_dx >= 0) 1 else 3;
                return true;
            },
            vehicle_mod.id_black_chocobo => {
                self.vehicle_land_id = self.vehicle;
                self.vehicle_land_pending = true;
                self.vehicle_anim.begin(.bk_land);
                return true;
            },
            vehicle_mod.id_hovercraft => {
                if (!ow.canLandFoot(self.pos_x, self.pos_y)) return false;
                self.vehicle_land_id = self.vehicle;
                self.vehicle_land_pending = true;
                self.vehicle_anim.begin(.hover_land);
                return true;
            },
            vehicle_mod.id_enterprise => {
                // LandEnterprise @a60b: if holding hover → DropHover; else maybe GrabHover
                if (self.holding_hover) {
                    const tile_ok = (ow.propLoAt(self.pos_x, self.pos_y) & vehicle_mod.drop_hover_tile_bit) != 0;
                    if (vehicle_mod.canDropHover(
                        true,
                        tile_ok,
                        px,
                        py,
                        self.world_id,
                        self.falcon_vis,
                        self.falcon_world,
                        self.falcon_x,
                        self.falcon_y,
                        self.whale_vis,
                        self.whale_world,
                        self.whale_x,
                        self.whale_y,
                    )) {
                        self.vehicle_anim.begin(.drop_hover);
                        return true;
                    }
                    return false;
                }
                if (vehicle_mod.canGrabHover(
                    self.eventSwitchOn(vehicle_mod.grab_hover_event_switch),
                    false,
                    self.hover_vis,
                    self.hover_world,
                    self.hover_x,
                    self.hover_y,
                    self.enterprise_world,
                    px,
                    py,
                )) {
                    self.vehicle_anim.begin(.grab_hover);
                    self.hover_vis = 0;
                    return true;
                }
                self.vehicle_land_id = self.vehicle;
                self.vehicle_land_pending = true;
                self.vehicle_anim.begin(.air_land);
                return true;
            },
            vehicle_mod.id_falcon, vehicle_mod.id_whale => {
                self.vehicle_land_id = self.vehicle;
                self.vehicle_land_pending = true;
                self.vehicle_anim.begin(.air_land);
                return true;
            },
            // Ship: ChangeVehicle has no exit branch (falls to rts) — events only.
            vehicle_mod.id_ship => return false,
            else => return false,
        }
    }

    pub fn eventSwitchOn(self: *const GameState, id: u8) bool {
        const bi: usize = id >> 3;
        if (bi >= self.event_switch.len) return false;
        const bit: u3 = @truncate(id & 7);
        return (self.event_switch[bi] & (@as(u8, 1) << bit)) != 0;
    }

    pub fn isMoving(self: *const GameState) bool {
        return self.move_dir != 0;
    }

    /// Refresh `$d2` from the tile underfoot (CheckPlayerMoveSub @a959–@a964).
    /// If not on a bridge tile (lo bit2), z = lo & 3; else keep previous.
    pub fn updatePartyZ(self: *GameState) void {
        if (self.mode != .submap) {
            self.party_z = 0x03;
            return;
        }
        const sm = self.sub orelse return;
        const lo = sm.propLoAt(self.pos_x, self.pos_y);
        // ROM: if ($a1 & $04) keep $d2; else $d2 = $a1 & $03
        if ((lo & 0x04) == 0) {
            self.party_z = lo & 0x03;
        }
    }

    /// DrawPlayerSub / DrawPlayerWorld: `$a2 & #$08` (prop hi bit3) → hide lower OAM.
    /// Submap: MapTileProp; overworld: WorldTileProp (forest canopy occlusion).
    pub fn spriteHideLowerBody(self: *const GameState, tile_x: i32, tile_y: i32) bool {
        return switch (self.mode) {
            .submap => if (self.sub) |*sm| sm.spriteHideLowerBody(tile_x, tile_y) else false,
            .overworld => if (self.ow) |*ow| ow.spriteHideLowerBody(tile_x, tile_y) else false,
        };
    }

    /// Draw pose for blit: `$1705`, or 8 while `$d8` spin is set (DrawPlayerSub @b20f).
    pub fn drawFacing(self: *const GameState) u8 {
        if (self.player_spin) return 8;
        return self.facing;
    }

    /// Refresh `$1a02` from current tile (CheckTriggerSub / CheckTriggerWorld).
    pub fn updateSaveEnabled(self: *GameState) void {
        // ChangeVehicle / Board* stz $1a02 while mounted.
        if (self.vehicle != 0) {
            self.save_enabled = false;
            return;
        }
        self.save_enabled = switch (self.mode) {
            .overworld => true,
            .submap => if (self.sub) |*sm| sm.isSavePoint(self.pos_x, self.pos_y) else false,
        };
    }

    fn fieldRand(self: *GameState) u8 {
        // Numerical Recipes LCG (same as battle.damage.Lcg).
        self.field_rng = self.field_rng *% 1664525 +% 1013904223;
        return @truncate(self.field_rng >> 24);
    }

    /// DoPoisonDmg + DoFloorDmg (trigger.asm @97b3 / @97ff).
    /// Called when starting a free-roam step (CheckPlayerMoveSub @aa36 / world @ac6b).
    fn doPoisonAndFloorDmg(self: *GameState) void {
        // DoPoisonDmg: skip when $1704 vehicle ≠ 0.
        if (self.vehicle != 0) {
            self.floor_dmg_active = false;
            return;
        }
        var any_poison: bool = false;
        for (&self.party) |*m| {
            if (!field_fx_mod.poisonDmgEligible(m.present and m.id != 0, m.status1)) continue;
            any_poison = true;
            m.hp = field_fx_mod.applyPoisonHp(m.hp);
        }
        // SFX $7A when any poisoned party member and not mid-event ($b1).
        if (any_poison and !self.eventActive()) {
            self.queueSfx(field_fx_mod.sfx_poison_dmg);
        }

        // DoFloorDmg: stz $c1; if `$a2&$01` damage party.
        self.floor_dmg_active = false;
        const on_floor = switch (self.mode) {
            .submap => if (self.sub) |*sm| sm.isDamageFloor(self.pos_x, self.pos_y) else false,
            .overworld => false,
        };
        if (!on_floor) return;

        var any_floor: bool = false;
        for (&self.party) |*m| {
            if (!field_fx_mod.floorDmgEligible(m.present and m.id != 0, m.status1, m.status2)) continue;
            any_floor = true;
            m.hp = field_fx_mod.applyFloorHp(m.hp);
        }
        // `$c1` = damaged-char count (we only need nonzero for MovePlayer invert).
        self.floor_dmg_active = any_floor;
        if (any_floor) self.queueSfx(field_fx_mod.sfx_floor_dmg);
    }

    /// MovePlayer @a878: if `$c1` and `($7b&$08)==0`, `inc $c4` (palette invert).
    fn tickFloorInvert(self: *GameState) void {
        if (!self.floor_dmg_active or self.move_dir == 0) return;
        if ((self.party_frame & 0x08) == 0) {
            self.map_invert = !self.map_invert;
        }
    }

    /// CheckMoveNPCs free-roam for visible wanderers (skipped during events).
    pub fn tickFreeRoamNpcs(self: *GameState) void {
        if (self.mode != .submap) return;
        if (self.eventActive() or self.dlg_open) return;
        const ns = if (self.npcs) |*n| n else return;
        const sm = if (self.sub) |*s| s else return;

        const ZCtx = struct {
            sm: *const submap_mod.SubMap,
            fn key(ctx: *anyopaque, x: i32, y: i32) u8 {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                return c.sm.npcRoamZKey(x, y);
            }
        };
        var zc: ZCtx = .{ .sm = sm };

        const EnterCtx = struct {
            sm: *const submap_mod.SubMap,
            fn ok(ctx: *anyopaque, x: i32, y: i32) bool {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                // Impassable fill / solid: prop_lo & $07 == $07 (canWalk dest test).
                if (x < 0 or y < 0 or x >= 32 or y >= 32) return false;
                return (c.sm.propLoAt(x, y) & 0x07) != 0x07;
            }
        };
        var ec: EnterCtx = .{ .sm = sm };

        const RngCtx = struct {
            gs: *GameState,
            fn next(ctx: *anyopaque) u8 {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                return c.gs.fieldRand();
            }
        };
        var rc: RngCtx = .{ .gs = self };

        ns.tickFreeRoam(ZCtx.key, &zc, EnterCtx.ok, &ec, RngCtx.next, &rc);
    }

    /// Walk / spin frame for DrawPlayer.
    /// Normal: `$7b&$08` while moving. Spin (`$d8` / pose 8): `($7b+$10)>>3 & 3`.
    pub fn walkFrame(self: *const GameState) u8 {
        if (self.player_spin or self.facing == 8) {
            // DrawPlayerSub @b220: ($7b + $10) >> 3 & 3
            return ((self.party_frame +% 0x10) >> 3) & 3;
        }
        if (self.move_dir == 0) return 0;
        return if ((self.party_frame & 0x08) != 0) 1 else 0;
    }

    /// Fine scroll (0..15) for map rendering — map scrolls opposite the party.
    /// Player stays screen-centered; positive fine shifts tiles left/up.
    pub fn scrollFine(self: *const GameState) struct { x: i32, y: i32 } {
        const p: i32 = self.move_px;
        return switch (self.move_dir) {
            1 => .{ .x = 0, .y = -p }, // up: map moves down
            2 => .{ .x = p, .y = 0 }, // right: map moves left
            3 => .{ .x = 0, .y = p }, // down: map moves up
            4 => .{ .x = -p, .y = 0 }, // left: map moves right
            else => .{ .x = 0, .y = 0 },
        };
    }

    fn dirFromHold(up: bool, down: bool, left: bool, right: bool) u8 {
        // Priority matches CheckPlayerMoveSub: right, left, down, up
        if (right) return 2;
        if (left) return 4;
        if (down) return 3;
        if (up) return 1;
        return 0;
    }

    fn dirDelta(dir: u8) struct { dx: i32, dy: i32 } {
        return switch (dir) {
            1 => .{ .dx = 0, .dy = -1 },
            2 => .{ .dx = 1, .dy = 0 },
            3 => .{ .dx = 0, .dy = 1 },
            4 => .{ .dx = -1, .dy = 0 },
            else => .{ .dx = 0, .dy = 0 },
        };
    }

    fn facingFromDir(dir: u8) u8 {
        // Our facing: 0=up, 1=right, 2=down, 3=left (matches $1705 in game for 0-3)
        return switch (dir) {
            1 => 0,
            2 => 1,
            3 => 2,
            4 => 3,
            else => 2,
        };
    }

    fn destTile(self: *const GameState, dir: u8) struct { x: i32, y: i32 } {
        const d = dirDelta(dir);
        return switch (self.mode) {
            .overworld => blk: {
                // MapSizeMask (move.asm @ad0b) via Overworld.size_mask.
                const mask: i32 = if (self.ow) |*ow| ow.size_mask else 0xFF;
                break :blk .{
                    .x = (self.pos_x + d.dx) & mask,
                    .y = (self.pos_y + d.dy) & mask,
                };
            },
            .submap => .{
                .x = self.pos_x + d.dx,
                .y = self.pos_y + d.dy,
            },
        };
    }

    fn wrapWorldPos(self: *const GameState, c: i32) i32 {
        const mask: i32 = if (self.ow) |*ow| ow.size_mask else 0xFF;
        return c & mask;
    }

    /// CheckNPCBlock (move.asm @aa94): `$7f4c00` bit7 at dest blocks free roam.
    /// Bridge exception: moving onto bridge while not on lower z skips NPC block.
    fn blockedByNpc(self: *const GameState, dir: u8, x: i32, y: i32) bool {
        if (self.mode != .submap) return false;
        const sm = self.sub orelse return false;
        // Moving to bridge tile while party z is upper (not 1): no NPC collision.
        const dest_lo = sm.propLoAt(x, y);
        if ((dest_lo & 0x04) != 0 and self.party_z != 1) {
            return false;
        }
        const ns = self.npcs orelse return false;
        _ = dir;
        return ns.occupiedByNpc(x, y);
    }

    /// One NTSC field of movement (MovePlayer + CheckPlayerMove).
    /// On foot speed = PlayerMoveRateTbl[0] = 1 pixel/field.
    pub fn tickMovement(self: *GameState, hold_up: bool, hold_down: bool, hold_left: bool, hold_right: bool) !void {
        if (self.dlg_open or self.eventActive() or self.vehicle_anim.active()) {
            // Board/land anim owns the field (vehicle.asm Animate loops).
            if (self.vehicle_anim.active()) {
                self.move_dir = 0;
                self.move_px = 0;
            } else {
                self.move_dir = 0;
                self.move_px = 0;
            }
            return;
        }

        const speed: u8 = self.movePixelRate();

        // ClearPlayerNPCMap at start of CheckPlayerMoveSub.
        if (self.npcs) |*ns| ns.clearPlayerMarker();

        if (self.move_dir != 0) {
            // MovePlayer: floor invert before party_frame++ uses current $7b.
            self.tickFloorInvert();
            // Mid-step: always finish the 16px scroll (smoother than mid-tile cancel).
            self.party_frame +%= 1;
            self.move_px +%= speed;
            if (self.move_px >= 16) {
                const d = dirDelta(self.move_dir);
                self.pos_x = switch (self.mode) {
                    .overworld => self.wrapWorldPos(self.pos_x + d.dx),
                    .submap => self.pos_x + d.dx,
                };
                self.pos_y = switch (self.mode) {
                    .overworld => self.wrapWorldPos(self.pos_y + d.dy),
                    .submap => self.pos_y + d.dy,
                };
                self.move_px = 0;
                self.updatePartyZ();
                self.updateSaveEnabled();

                // Clear warp suppress once we leave the entry tile
                if (self.suppress_arrival and (self.pos_x != self.entry_x or self.pos_y != self.entry_y)) {
                    self.suppress_arrival = false;
                }

                // Triggers / exit tiles on the square we just entered.
                if (!self.suppress_arrival) {
                    if (try self.checkTileArrival(self.pos_x, self.pos_y)) {
                        self.move_dir = 0;
                        self.updatePlayerOccupancy(0);
                        return;
                    }
                }

                // Chain into next tile if still holding a valid direction.
                const want = dirFromHold(hold_up, hold_down, hold_left, hold_right);
                if (want != 0 and self.canStartMove(want)) {
                    // CheckPlayerMoveSub @aa36: poison/floor on each new step start.
                    self.doPoisonAndFloorDmg();
                    self.tryOpenDoor(want);
                    self.move_dir = want;
                    if (!self.party_follow) {
                        self.facing = facingFromDir(want);
                    }
                    self.updatePlayerOccupancy(want);
                } else {
                    self.move_dir = 0;
                    self.updatePlayerOccupancy(0);
                }
            } else {
                // Still mid-step: keep $FF on destination.
                self.updatePlayerOccupancy(self.move_dir);
            }
            return;
        }

        // Idle: start a step if D-pad held toward a passable tile.
        const want = dirFromHold(hold_up, hold_down, hold_left, hold_right);
        if (want == 0) {
            self.updatePlayerOccupancy(0);
            return;
        }
        // `$cf`: do not update `$1705` from joypad while set (CheckPlayerMoveSub).
        if (!self.party_follow) {
            self.facing = facingFromDir(want);
        }
        if (!self.canStartMove(want)) {
            self.updatePlayerOccupancy(0);
            return;
        }

        // CheckPlayerMoveSub @aa36: poison/floor when a step begins from idle.
        self.doPoisonAndFloorDmg();

        // OpenDoor (move.asm @aa40): walking N/S into closed door $70/$71 → open gfx + SFX $45.
        self.tryOpenDoor(want);

        self.move_dir = want;
        self.move_px = 0;
        self.updatePlayerOccupancy(want);
        // First field of movement also advances scroll (MovePlayer runs same frame $ab is set).
        self.party_frame +%= 1;
        self.move_px = speed;
    }

    /// OpenDoor (move.asm @aa40): N/S into closed door $70/$71.
    /// Cell id stays $70/$71 (triggers/exit bits intact); GetDoorTiles patches gfx to $6F.
    /// Only when `$ab` is N/S (`lda $ab / lsr / bcc`).
    fn tryOpenDoor(self: *GameState, dir: u8) void {
        if (self.mode != .submap) return;
        // N/S only (odd dirs after the ROM's lsr test).
        if (dir != 1 and dir != 3) return;
        const dest = self.destTile(dir);
        if (self.sub) |*sm| {
            if (sm.openDoorAt(dest.x, dest.y)) {
                self.queueSfx(0x45); // PlaySfx $45
            }
        }
    }

    fn canStartMove(self: *const GameState, dir: u8) bool {
        const dest = self.destTile(dir);
        if (!self.canWalk(dest.x, dest.y)) return false;
        if (self.blockedByNpc(dir, dest.x, dest.y)) return false;
        if (self.blockedByParkedVehicle(dest.x, dest.y)) return false;
        return true;
    }

    /// CheckVehicleBlock (move.asm @ac7d): foot/choco/hover can't step onto other vehicles.
    fn blockedByParkedVehicle(self: *const GameState, x: i32, y: i32) bool {
        if (self.mode != .overworld) return false;
        // Airships / whale ignore most vehicle collision (ROM @ad03 early for veh≥4).
        if (self.vehicle >= vehicle_mod.id_enterprise) return false;
        const px: u8 = @intCast(x & 0xFF);
        const py: u8 = @intCast(y & 0xFF);
        // Chocobo blocked by hovercraft.
        if (self.vehicle == vehicle_mod.id_chocobo or self.vehicle == 0) {
            if (self.hover_vis != 0 and self.hover_world == self.world_id and self.hover_x == px and self.hover_y == py)
                return true;
        }
        // Hover / foot / choco: block on black choco, enterprise, falcon, whale.
        if (self.vehicle <= vehicle_mod.id_hovercraft) {
            if (self.bk_choco_vis != 0 and self.world_id == 0 and self.bk_choco_x == px and self.bk_choco_y == py)
                return true;
            if (self.enterprise_vis != 0 and self.enterprise_world == self.world_id and self.enterprise_x == px and self.enterprise_y == py)
                return true;
            if (self.falcon_vis != 0 and self.falcon_world == self.world_id and self.falcon_x == px and self.falcon_y == py)
                return true;
            if (self.whale_vis != 0 and self.whale_world == self.world_id and self.whale_x == px and self.whale_y == py)
                return true;
        }
        return false;
    }

    /// ClearPlayerNPCMap then SetPlayerNPCMap ($FF at dest or idle tile).
    fn updatePlayerOccupancy(self: *GameState, moving_dir: u8) void {
        const ns = if (self.npcs) |*n| n else return;
        ns.clearPlayerMarker();
        if (moving_dir == 0) {
            ns.placePlayer(self.pos_x, self.pos_y);
            return;
        }
        const dest = self.destTile(moving_dir);
        // Bridge skip: same as SetPlayerNPCMap when dest is bridge and z mismatch.
        if (self.sub) |*sm| {
            const lo = sm.propLoAt(dest.x, dest.y);
            if ((lo & 0x04) != 0 and ((lo & 0x03) & self.party_z) == 0) return;
        }
        ns.placePlayer(dest.x, dest.y);
    }

    /// After committing a tile step: coordinate triggers, then exit-tile → map stack.
    /// Mirrors CheckTriggerSub (trigger.asm): trigger bit → table; else exit bit → $d1 pop.
    fn checkTileArrival(self: *GameState, x: i32, y: i32) !bool {
        if (self.mode == .overworld) {
            return try self.applyTransition(triggers_mod.findAt(self.world_triggers, x, y), true);
        }

        // Out of 0..31 bounds → previous map (CheckTriggerSub @9c04)
        if (x < 0 or y < 0 or x >= 32 or y >= 32) {
            return try self.popMapStack();
        }

        const sm = self.sub orelse return false;

        // Save point (prop_lo bit3) before trigger/exit — CheckTriggerSub @9c21.
        // Direct ExecEvent $76 (F6 dialogue "You may save"), not trigger-table.
        if (sm.isSavePoint(x, y)) {
            self.save_enabled = true;
            if (!self.event_player.active) {
                if (self.event_player.start(self.rom, 0x76)) return true;
            }
            return false;
        }

        // Coordinate trigger table (doors/warps). Prefer table over exit bit
        // when both apply (CheckTriggerSub: bmi → table, else exit).
        if (sm.isTriggerTile(x, y)) {
            if (try self.applyTransition(triggers_mod.findAt(self.map_triggers, x, y), false)) {
                return true;
            }
        } else if (try self.applyTransition(triggers_mod.findAt(self.map_triggers, x, y), false)) {
            // Also honor table entries even without the flag (some doors)
            return true;
        }

        // Exit tile (prop_hi bit4) → previous map ($d1 / stack pop)
        if (sm.isExitTile(x, y)) {
            return try self.popMapStack();
        }
        return false;
    }

    fn applyTransition(self: *GameState, t: ?triggers_mod.Trigger, from_world: bool) !bool {
        const trig = t orelse return false;
        // from_world: `$1700` for worldDestMapId; current map_id for submap high-bank retain.
        const tr = triggers_mod.resolve(
            trig,
            if (from_world) self.world_id else null,
            self.map_id,
        );
        switch (tr) {
            .none => return false,
            .event => |ev| {
                // Sub-map $FF / world event: run event script (item gates, story).
                return self.runEvent(ev);
            },
            .enter_submap => |e| {
                // Building doors / stairs: OpenDoor sfx $45 (move.asm) + WipeOut (trigger.asm).
                if (!from_world) self.queueSfx(0x45);
                self.beginMapTransition(.{
                    .to_world = false,
                    .map_id = e.map_id,
                    .x = e.x,
                    .y = e.y,
                    .facing = e.facing,
                });
                return true;
            },
            .enter_world => |e| {
                // trigger.asm @9cc2: `$FB–$FD` → stx $172c (clear map stack) then world load.
                triggers_mod.applyStackSideEffect(tr, &self.stack_len);
                self.beginMapTransition(.{
                    .to_world = true,
                    .world_id = e.world,
                    .x = e.x,
                    .y = e.y,
                    .facing = 2,
                });
                return true;
            },
        }
    }

    fn pushStack(self: *GameState) void {
        if (self.stack_len >= self.stack.len) return;
        self.stack[self.stack_len] = .{
            .mode = self.mode,
            .world = self.world_id,
            .map = self.map_id,
            .x = self.pos_x,
            .y = self.pos_y,
            // PushMapStack: submap packs $1705 into high 2 bits of dest X.
            .facing = self.facing & 3,
        };
        self.stack_len += 1;
    }

    /// Pop map stack (exit tile / $d1 path in field.asm) — WipeOut like trigger exits.
    fn popMapStack(self: *GameState) !bool {
        if (self.stack_len == 0) {
            // Nowhere to return — if on a submap, bail to overworld spawn
            if (self.mode == .submap) {
                self.beginMapTransition(.{
                    .to_world = true,
                    .world_id = 0,
                    .x = @intCast(new_game_overworld_x),
                    .y = @intCast(new_game_overworld_y),
                });
                return true;
            }
            return false;
        }
        self.stack_len -= 1;
        const e = self.stack[self.stack_len];
        self.move_dir = 0;
        self.move_px = 0;
        if (e.mode == .overworld) {
            self.beginMapTransition(.{
                .to_world = true,
                .world_id = e.world,
                .x = @intCast(e.x),
                .y = @intCast(e.y),
                .facing = e.facing & 3,
            });
            return true;
        }
        // Return to previous submap via wipe (applyEventWarp reloads map).
        // LoadMapStack restores $1705 from packed facing bits.
        self.beginMapTransition(.{
            .to_world = false,
            .map_id = e.map,
            .x = @intCast(e.x),
            .y = @intCast(e.y),
            .facing = e.facing & 3,
            .skip_stack_push = true,
        });
        return true;
    }

    pub fn enterSubmap(self: *GameState, map_id: u16, x: u8, y: u8, facing: u8) !void {
        // PushMapStack (trigger.asm + EventCmd_fe @f03f for submap dests).
        // suppress_stack_push: stack-pop return, world FE, special 0x0B, etc.
        // Intro pollution is cleared on event $10 .done (stack_len = 0), not here.
        if (!self.suppress_stack_push) {
            self.pushStack();
        }
        self.suppress_stack_push = false;
        self.move_dir = 0;
        self.move_px = 0;

        if (self.sub) |*s| s.deinit();
        if (self.npcs) |*n| n.deinit();
        if (self.map_triggers.len != 0) {
            self.allocator.free(self.map_triggers);
            self.map_triggers = &.{};
        }

        self.sub = try submap_mod.SubMap.load(self.allocator, self.rom, map_id);
        // npcMSB (map prop bit7 of byte10) or map_id >= 256 → second NPC switch/prop bank
        const map_high = map_id >= 256 or (self.sub.?.prop.tilemap_msb & 0x80) != 0;
        self.npcs = try npc_mod.NpcSet.load(
            self.allocator,
            self.rom,
            self.sub.?.prop.npc_index,
            self.npc_switch[0..],
            map_high,
            self.sub.?.prop.npc_pal,
        );
        self.map_triggers = try triggers_mod.loadMapTriggers(self.allocator, self.rom, map_id);

        self.mode = .submap;
        self.map_id = map_id;
        self.pos_x = x;
        self.pos_y = y;
        self.facing = facing;
        self.suppress_arrival = true;
        self.entry_x = x;
        self.entry_y = y;
        self.updatePartyZ();
        self.updateSaveEnabled();
        if (self.npcs) |*ns| ns.placePlayer(self.pos_x, self.pos_y);
        // Leaving a map ends that room's voice threads.
        self.clearVoiceChat();
        self.setLocationMsg();
        self.initMapTreasures();
    }

    pub fn enterWorld(self: *GameState, world: u8, x: u8, y: u8) !void {
        if (self.sub) |*s| {
            s.deinit();
            self.sub = null;
        }
        if (self.npcs) |*n| {
            n.deinit();
            self.npcs = null;
        }
        if (self.map_triggers.len != 0) {
            self.allocator.free(self.map_triggers);
            self.map_triggers = &.{};
        }

        self.mode = .overworld;
        const world_changed = self.world_id != world;
        self.world_id = world;
        self.pos_x = x;
        self.pos_y = y;
        self.move_dir = 0;
        self.move_px = 0;
        // LoadOverworld path leaves `$ad=$10` unless already mounted (vehicle path sets later).
        if (self.vehicle == 0) self.mode7_zoom = 0x10;
        // Do not clear map stack — PushMapStack/LoadMapStack keep deeper entries.
        // Intro / new-game paths clear stack explicitly.
        self.suppress_arrival = true;
        self.entry_x = x;
        self.entry_y = y;
        // LoadOverworld / LoadUnderground / LoadMoon when `$1700` changes.
        if (world_changed) {
            if (self.ow) |*ow| {
                ow.switchWorld(self.rom, world) catch {};
                self.syncOverworldEventTiles();
            }
            // WorldTriggers1/2/3 — CheckTriggerWorld indexes by `$1700`.
            try self.reloadWorldTriggers();
        }
        self.updateSaveEnabled();
        self.clearVoiceChat();
        self.setLocationMsg();
    }

    /// Reload WorldTriggers for current `world_id` (OW / under / moon tables).
    fn reloadWorldTriggers(self: *GameState) !void {
        if (self.world_triggers.len != 0) {
            self.allocator.free(self.world_triggers);
            self.world_triggers = &.{};
        }
        self.world_triggers = try triggers_mod.loadWorldTriggers(self.allocator, self.rom, self.world_id);
    }

    /// ModOverworldTilemap after load / switch changes (Damcyan, Mist, Agart hole).
    pub fn syncOverworldEventTiles(self: *GameState) void {
        if (self.ow) |*ow| {
            ow.applyEventTileMods(self.event_switch[0..]);
        }
    }

    pub fn tryTalk(self: *GameState) void {
        // ChangeVehicle (world A button) before talk/treasure (field CheckPlayerMoveWorld).
        if (self.mode == .overworld) {
            if (self.tryChangeVehicle()) return;
            return;
        }
        if (self.mode != .submap) return;
        // CheckTreasure before NPCs (trigger.asm CheckTreasureNPC).
        if (self.tryOpenTreasure()) return;
        const ns = self.npcs orelse {
            self.setMsg("Nobody there.");
            return;
        };
        const idx = ns.findFacing(self.pos_x, self.pos_y, self.facing) orelse {
            self.setMsg("Nobody there.");
            return;
        };
        // Full NPC script → event (locked doors, shops, story NPCs).
        self.runNpcEvent(ns.npcs[idx].prop_gfx);
    }

    /// Treasure count: next MapProp.treasure_off − this (field.asm @83ef).
    fn treasureCount(self: *const GameState) u8 {
        const sm = self.sub orelse return 0;
        const off = sm.prop.treasure_off;
        const next_id = self.map_id + 1;
        if (next_id >= 383) return 0;
        const pr = self.rom.slice(0xA9C84 + @as(usize, next_id) * 13, 13) catch return 0;
        return pr[12] -% off;
    }

    fn treasureSwitchOn(self: *const GameState, treasure_idx: u8) bool {
        var byte_i: usize = treasure_idx >> 3;
        if (self.map_id >= 256) byte_i += 0x20;
        if (byte_i >= self.treasure_switch.len) return false;
        const bit: u3 = @truncate(treasure_idx & 7);
        return (self.treasure_switch[byte_i] & (@as(u8, 1) << bit)) != 0;
    }

    /// SetTreasureSwitch: set bit; return true if already open.
    fn setTreasureSwitch(self: *GameState, treasure_idx: u8) bool {
        var byte_i: usize = treasure_idx >> 3;
        if (self.map_id >= 256) byte_i += 0x20;
        if (byte_i >= self.treasure_switch.len) return true;
        const bit: u3 = @truncate(treasure_idx & 7);
        const mask: u8 = @as(u8, 1) << bit;
        const was = (self.treasure_switch[byte_i] & mask) != 0;
        self.treasure_switch[byte_i] |= mask;
        return was;
    }

    /// InitTreasures: $78 → $77 for looted chests.
    fn initMapTreasures(self: *GameState) void {
        const sm = if (self.sub) |*s| s else return;
        const n = self.treasureCount();
        const base = sm.prop.treasure_off;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (i >= self.map_triggers.len) break;
            const t = self.map_triggers[i];
            if (t.dest_map != 0xFE) continue;
            if (!self.treasureSwitchOn(base +% i)) continue;
            if (t.x >= 32 or t.y >= 32) continue;
            const idx: usize = @as(usize, t.y) * 32 + t.x;
            if (sm.cells[idx] == 0x78) sm.cells[idx] = 0x77;
        }
    }

    /// CheckTreasure (@9877): face adjacent treasure trigger.
    fn tryOpenTreasure(self: *GameState) bool {
        const sm = if (self.sub) |*s| s else return false;
        const n = self.treasureCount();
        if (n == 0) return false;

        const d: struct { dx: i32, dy: i32 } = switch (self.facing & 3) {
            0 => .{ .dx = 0, .dy = -1 },
            1 => .{ .dx = 1, .dy = 0 },
            2 => .{ .dx = 0, .dy = 1 },
            else => .{ .dx = -1, .dy = 0 },
        };
        const tx = self.pos_x + d.dx;
        const ty = self.pos_y + d.dy;
        if (tx < 0 or ty < 0 or tx >= 32 or ty >= 32) return false;

        var ti: u8 = 0;
        while (ti < n) : (ti += 1) {
            if (ti >= self.map_triggers.len) return false;
            const t = self.map_triggers[ti];
            if (t.dest_map != 0xFE) continue;
            if (t.x != @as(u8, @intCast(tx)) or t.y != @as(u8, @intCast(ty))) continue;

            const treasure_id = sm.prop.treasure_off +% ti;
            const already = self.setTreasureSwitch(treasure_id);
            const cell_i: usize = @as(usize, @intCast(ty)) * 32 + @as(usize, @intCast(tx));
            if (already) {
                if (sm.cells[cell_i] == 0x77) self.setMsg("Nothing here.");
                return true;
            }

            // Closed chest $78 → open $77 + SFX $30; otherwise pot SFX $37.
            if (sm.cells[cell_i] == 0x78) {
                sm.cells[cell_i] = 0x77;
                self.queueSfx(0x30);
            } else {
                self.queueSfx(0x37);
            }

            // dest_x = flags ($09), dest_y = data ($08)
            // Monster chest: battle id = (flags&$1F) + ($1701<<5) + $C0 (trigger.asm @9952).
            const flags = t.dest_x;
            const data = t.dest_y;
            if ((flags & 0x40) != 0) {
                const map_hi: u16 = (self.map_id >> 8) & 1;
                const bid: u16 = @as(u16, flags & 0x1F) + (map_hi << 5) + 0xC0;
                self.pending_event_battle = bid;
                self.setMsg("Monsters!");
                return true;
            }
            if ((flags & 0x80) != 0) {
                if (self.inventory.give(data)) {
                    var name_buf: [16]u8 = undefined;
                    const name = inventory_mod.Inventory.itemName(self.rom, data, &name_buf);
                    var msg: [40]u8 = undefined;
                    const m = std.fmt.bufPrint(&msg, "Got {s}", .{name}) catch "Got item";
                    self.setMsg(m);
                } else {
                    self.setMsg("Inventory full!");
                }
                return true;
            }
            const mult: u32 = if ((data & 0x80) != 0) 1000 else 10;
            const amt: u32 = @as(u32, data & 0x7F) * mult;
            self.gil = @min(self.gil +% amt, 9999999);
            var gmsg: [32]u8 = undefined;
            const gm = std.fmt.bufPrint(&gmsg, "Got {d} Gil", .{amt}) catch "Got Gil";
            self.setMsg(gm);
            return true;
        }
        return false;
    }

    /// NPC the player is facing, if any (includes props/doors for ROM talk).
    pub fn facingNpc(self: *const GameState) ?npc_mod.Npc {
        if (self.mode != .submap) return null;
        const ns = self.npcs orelse return null;
        const idx = ns.findFacing(self.pos_x, self.pos_y, self.facing) orelse return null;
        return ns.npcs[idx];
    }

    /// Apply FE world vehicle after map load (EventCmd_fe @f0c4).
    pub fn applyWarpVehicle(self: *GameState, vehicle_id: u8) void {
        if (vehicle_id == 0) {
            self.vehicle = 0;
            self.move_speed_class = 0;
            return;
        }
        // Ship facing from FE flags already in facing; BoardShip keeps facing.
        // FE path: smoke then liftoff for hover/airships (Board* with `$b1`).
        self.boardVehicleEx(vehicle_id, true);
        // Parked position = current party tile while mounted.
        const px: u8 = @intCast(self.pos_x & 0xFF);
        const py: u8 = @intCast(self.pos_y & 0xFF);
        switch (vehicle_id) {
            vehicle_mod.id_chocobo => {
                self.choco_x = px;
                self.choco_y = py;
            },
            vehicle_mod.id_black_chocobo => {
                self.bk_choco_x = px;
                self.bk_choco_y = py;
            },
            vehicle_mod.id_hovercraft => {
                self.hover_x = px;
                self.hover_y = py;
            },
            vehicle_mod.id_enterprise => {
                self.enterprise_x = px;
                self.enterprise_y = py;
            },
            vehicle_mod.id_falcon => {
                self.falcon_x = px;
                self.falcon_y = py;
            },
            vehicle_mod.id_whale => {
                self.whale_x = px;
                self.whale_y = py;
            },
            vehicle_mod.id_ship => {
                self.ship_x = px;
                self.ship_y = py;
            },
            else => {},
        }
    }

    /// Facing target that can hold a *voice* conversation (humanoid speaker).
    pub fn facingVoiceNpc(self: *const GameState) ?npc_mod.Npc {
        const n = self.facingNpc() orelse return null;
        if (!n.canVoiceChat()) return null;
        return n;
    }

    /// Voice conversation: player_text (from STT) → Gemma reply + Kokoro WAV.
    /// Shows reply in the dialogue box. Returns path to WAV (caller plays/frees via gpa.free).
    pub fn voiceTalk(
        self: *GameState,
        gpa: std.mem.Allocator,
        io: std.Io,
        repo_root: []const u8,
        llm: *ai_local.Llm,
        tts: *ai_local.Tts,
        player_text: []const u8,
    ) !struct { wav_path: []u8, reply: []const u8 } {
        const npc = self.facingVoiceNpc() orelse {
            if (self.facingNpc() != null) {
                self.setMsg("That can't talk.");
                return error.NotASpeaker;
            }
            self.setMsg("Nobody there.");
            return error.NoNpc;
        };
        // Ground the model with the ROM line (read-only — don't re-run events/item grants).
        var canon_buf: [256]u8 = undefined;
        const canon = npc_mod.talkText(self.rom, npc, self.map_id, self.event_switch[0..], &canon_buf);
        const canon_line = if (std.mem.eql(u8, canon, "....")) "" else canon;

        // Same speaker → keep history for follow-ups; new speaker → fresh thread.
        self.ensureVoiceChatNpc(self.map_id, npc);
        const history = self.voiceChatHistSlice();

        const paths = ai_local.Paths{ .root = repo_root };
        const InvCtx = struct {
            inv: *const inventory_mod.Inventory,
            fn has(ctx: *anyopaque, id: u8) bool {
                const ic: *@This() = @ptrCast(@alignCast(ctx));
                return ic.inv.has(id);
            }
        };
        var inv_ctx: InvCtx = .{ .inv = &self.inventory };
        const keys = lore_mod.KeyBits.fromHas(InvCtx.has, &inv_ctx);

        // Snapshot party for "who is talking to you" (Cecil's rank, companions).
        var party_slots: [5]lore_mod.PartyMemberBrief = undefined;
        for (self.party, 0..) |m, i| {
            party_slots[i] = .{ .id = m.id, .present = m.present };
        }
        const party = lore_mod.PartySnapshot.fromPresent(party_slots[0..]);

        // Live ROM dump of what people on this map say (not invented greeter rules).
        var chatter_buf: [1200]u8 = undefined;
        const map_chatter: []const u8 = if (self.npcs) |ns|
            npc_mod.formatMapDialogueCorpus(self.rom, ns.npcs, self.map_id, self.event_switch[0..], &chatter_buf)
        else
            "";

        const result = try ai_local.voiceTalk(gpa, io, paths, llm, tts, .{
            .npc = npc,
            .map_id = self.map_id,
            .canon_line = canon_line,
            .player_text = player_text,
            .chat_history = history,
            .event_switch = self.event_switch[0..],
            .on_overworld = self.mode == .overworld,
            .world_x = self.pos_x,
            .world_y = self.pos_y,
            .keys = keys,
            .party = party,
            .map_chatter = map_chatter,
            .repo_root = repo_root,
        });
        // Copy reply into the dialogue buffer; caller opens the box and paints
        // a frame *before* TTS so text and speech appear together.
        const n = @min(result.reply.len, self.dlg_buf.len);
        if (n > 0) @memcpy(self.dlg_buf[0..n], result.reply[0..n]);
        self.dlg_len = n;
        self.dlg_page = 0;
        self.dlg_open = false;

        // Remember this exchange for the next follow-up with the same NPC.
        self.appendVoiceChatTurn(player_text, self.dlgSlice());

        const profile = voice_profile.profileForDialogue(npc, self.map_id, canon_line);
        var msg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "[{s} spk{d}]", .{ profile.model, profile.speaker }) catch "";
        if (m.len > 0) self.setMsg(m);

        // result.reply owned by result — transfer: we copied to dlg_buf, free reply, keep wav.
        const wav = result.wav_path;
        gpa.free(result.reply);
        return .{ .wav_path = wav, .reply = self.dlgSlice() };
    }

    pub fn closeDlg(self: *GameState) void {
        self.dlg_open = false;
        self.dlg_len = 0;
        self.dlg_page = 0;
        self.dlg_auto_scroll = false;
        self.dlg_auto_units = 0;
        self.dlg_auto_frame = 0;
        self.voice_dlg = false;
    }

    /// Show a free-roam / voice-chat reply in the dialogue box (not EventPlayer).
    pub fn openVoiceDlg(self: *GameState) void {
        self.dlg_open = true;
        self.dlg_page = 0;
        // Never inherit `$cb` auto-scroll from a prior cutscene — that blocks
        // the normal Space/confirm dismiss path for event boxes and confuses TTS.
        self.dlg_auto_scroll = false;
        self.dlg_auto_units = 0;
        self.dlg_auto_frame = 0;
        self.voice_dlg = true;
    }

    /// Load event bank-1 dialogue page (or fallback ASCII) into the open box.
    fn openEventDlg(self: *GameState, page: u16, fallback: []const u8) void {
        self.openEventDlgInner(page, fallback, false);
    }

    /// OpenDlgWindow with `$cb` auto-scroll (Special_09).
    fn openEventDlgAuto(self: *GameState, page: u16, fallback: []const u8) void {
        self.openEventDlgInner(page, fallback, true);
    }

    fn openEventDlgInner(self: *GameState, page: u16, fallback: []const u8, auto_scroll: bool) void {
        var scratch: [2048]u8 = undefined;
        if (event_mod.loadEventDlg1(self.rom, page, &scratch)) |s| {
            const n = @min(s.len, self.dlg_buf.len);
            if (n > 0) @memcpy(self.dlg_buf[0..n], s[0..n]);
            self.dlg_len = n;
        } else {
            const n = @min(fallback.len, self.dlg_buf.len);
            if (n > 0) @memcpy(self.dlg_buf[0..n], fallback[0..n]);
            self.dlg_len = n;
        }
        self.dlg_open = true;
        self.dlg_page = 0;
        self.dlg_auto_scroll = auto_scroll;
        if (auto_scroll) {
            self.dlg_auto_units = dlg_auto_mod.page_units_init;
            self.dlg_auto_frame = 0;
        } else {
            self.dlg_auto_units = 0;
            self.dlg_auto_frame = 0;
        }
    }

    /// One field of auto-scroll wait. Returns true if dialogue still open (caller holds block).
    fn tickDlgAutoScroll(self: *GameState) bool {
        if (!self.dlg_open or !self.dlg_auto_scroll) return self.dlg_open;
        self.dlg_auto_frame +%= 1;
        const r = dlg_auto_mod.tickAutoScrollWait(self.dlg_auto_frame, self.dlg_auto_units);
        self.dlg_auto_units = r.units;
        if (!r.page_done) return true;
        // Page wait finished → DecodeDlgText next page or close (OpenDlgWindow @b344).
        if (self.advanceDlg()) {
            self.dlg_auto_units = dlg_auto_mod.page_units_init;
            return true;
        }
        // Closed last page — clear `$cb`.
        self.dlg_auto_scroll = false;
        return false;
    }

    /// True while EventPlayer waits on Yes/No (inn / F8).
    pub fn eventYesNoOpen(self: *const GameState) bool {
        return self.event_player.active and self.event_player.blocked == .yes_no;
    }

    /// True while Namingway menu session is interactive.
    pub fn namingwayOpen(self: *const GameState) bool {
        return self.namingway.active();
    }

    /// Namingway pad: dpad + confirm/cancel (namingway.asm frame loops).
    pub fn tickNamingway(
        self: *GameState,
        press_confirm: bool,
        press_cancel: bool,
        press_left: bool,
        press_right: bool,
        press_up: bool,
        press_down: bool,
    ) void {
        if (!self.namingway.active()) return;
        var present: [5]bool = .{false} ** 5;
        var i: usize = 0;
        while (i < 5) : (i += 1) present[i] = self.party[i].present and (self.party[i].id & 0x3F) != 0;

        switch (self.namingway.phase) {
            .yes_no => {
                if (press_left or press_right) self.namingway.toggleYesNo();
                if (press_confirm) {
                    self.namingway.confirmYesNo(&present);
                    if (self.namingway.phase == .select_char) {
                        self.setMsg("Whose name?");
                    } else if (self.namingway.phase == .cancelled) {
                        self.setMsg("That's better.");
                    }
                }
                if (press_cancel) {
                    self.namingway.cancelYesNo();
                    self.setMsg("That's better.");
                }
            },
            .select_char => {
                if (press_left) self.namingway.prevChar(&present);
                if (press_right) self.namingway.nextChar(&present);
                if (press_cancel) {
                    self.namingway.cancelSelect();
                    self.setMsg("That's better.");
                }
                if (press_confirm) {
                    const slot = self.namingway.party_slot % 5;
                    const cid = self.party[slot].id;
                    if (self.namingway.confirmSelect(&self.char_names, cid)) {
                        var nbuf: [8]u8 = undefined;
                        const nm = self.char_names.decodeAscii(self.namingway.target_name_slot, &nbuf);
                        self.setMsg(nm);
                    }
                }
            },
            .edit_name => {
                if (self.namingway.alpha_sel == 0) {
                    if (press_left) self.namingway.moveLetter(-1, 0);
                    if (press_right) self.namingway.moveLetter(1, 0);
                    if (press_up) self.namingway.moveLetter(0, -1);
                    if (press_down) self.namingway.moveLetter(0, 1);
                    if (press_confirm) self.namingway.appendLetter();
                    if (press_cancel) self.namingway.backspace();
                } else {
                    // END selected
                    if (press_up or press_down) self.namingway.nextAlpha();
                    if (press_left or press_right) self.namingway.alpha_sel = 0;
                    if (press_confirm) {
                        if (self.namingway.confirmEnd(&self.char_names)) {
                            self.setMsg("That's better.");
                        } else {
                            self.setMsg("That's better.");
                        }
                    }
                    if (press_cancel) {
                        self.namingway.backspace();
                    }
                }
                // Allow switching to END via down from last? nextAlpha on up/down when not moving letter:
                if (press_up and self.namingway.alpha_sel == 0 and self.namingway.letter_row == 0) {
                    // optional: stay on grid
                }
            },
            .done, .cancelled => {},
        }
    }

    /// Confirm while dialogue is open (OpenDlgWindow @b344): next page or close.
    /// Returns true if the window is still open.
    /// Voice/TTS boxes page the same way as ROM dialogue; callers stop speech only
    /// when this returns false (last page dismissed).
    pub fn advanceDlg(self: *GameState) bool {
        if (!self.dlg_open) return false;
        const pages = self.dlgPageCount();
        if (self.dlg_page + 1 < pages) {
            self.dlg_page += 1;
            return true;
        }
        self.closeDlg();
        return false;
    }

    /// Pop pending SFX id (0 if none). Door open uses $45 (move.asm OpenDoor).
    pub fn consumeSfx(self: *GameState) ?u8 {
        if (self.pending_sfx == 0) return null;
        const s = self.pending_sfx;
        self.pending_sfx = 0;
        return s;
    }

    pub fn queueSfx(self: *GameState, id: u8) void {
        self.pending_sfx = id;
    }

    /// Debug/test: grant a key item and set the matching story flag when known.
    /// Baron Key ($EF) sets event switch 5 so door scripts take the unlock path.
    pub fn debugGiveKeyItem(self: *GameState, id: u8) void {
        _ = self.inventory.give(id);
        if (id == @intFromEnum(inventory_mod.ItemId.baron_key)) {
            // Event that gives Baron Key also does F2 $05.
            const byte_i: usize = 5 >> 3;
            const bit: u3 = @truncate(5 & 7);
            self.event_switch[byte_i] |= @as(u8, 1) << bit;
        }
        var name_buf: [16]u8 = undefined;
        const name = inventory_mod.Inventory.itemName(self.rom, id, &name_buf);
        var msg: [48]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "Got {s}", .{name}) catch "Got item";
        self.setMsg(m);
    }

    /// Talk / trigger events: always use stepped EventPlayer (wipe, multi-page dlg, FE, EC).
    fn runNpcEvent(self: *GameState, script_id: u8) void {
        if (self.event_player.active) return; // already in a cutscene
        const n = event_mod.fillNpcDlgTable(self.rom, script_id, &self.npc_dlg_table_buf);
        self.npc_dlg_table_len = n;
        const eid = event_mod.resolveNpcEventId(self.rom, script_id, self.event_switch[0..]) orelse {
            // No event branch — static "...."
            const msg = "....";
            const m = @min(msg.len, self.dlg_buf.len);
            @memcpy(self.dlg_buf[0..m], msg[0..m]);
            self.dlg_len = m;
            self.dlg_open = true;
            self.dlg_page = 0;
            return;
        };
        _ = self.event_player.start(self.rom, eid);
    }

    /// Map/world trigger $FF path → stepped EventPlayer (same as talk).
    /// Returns true if an event was started (map change happens asynchronously via FE).
    fn runEvent(self: *GameState, script_id: u8) bool {
        if (self.event_player.active) return true;
        self.npc_dlg_table_len = 0;
        const eid = event_mod.resolveTriggerEventId(self.rom, script_id, self.event_switch[0..]) orelse {
            return false;
        };
        if (eid == 0) return false;
        return self.event_player.start(self.rom, eid);
    }

    /// CheckMenu post-menu `$1a03` → ExecEvent (field.asm @8241). Direct event id
    /// (not trigger-switch resolve) for Warp `$87` / Exit `$86` / Sight `$FB`.
    pub fn consumeMenuEvent(self: *GameState) bool {
        const eid = self.pending_menu_event;
        if (eid == 0) return false;
        self.pending_menu_event = 0;
        if (self.event_player.active) return true;
        self.npc_dlg_table_len = 0;
        return self.event_player.start(self.rom, eid);
    }

    /// Legacy sync apply (tests / debug). Prefer EventPlayer for gameplay.
    fn applyEventResult(self: *GameState, result: event_mod.EventResult) bool {
        if (result.dialogue.len > 0) {
            self.dlg_len = result.dialogue.len;
            self.dlg_open = true;
            self.dlg_page = 0;
        }
        if (result.npc_dirty) {
            self.queueSfx(0x45);
            self.reloadNpcs() catch {};
        }
        if (result.party_dirty) self.party_sprite_dirty = true;
        if (result.shop_id) |sid| {
            self.pending_shop = sid;
        }
        if (result.sfx != 0) self.queueSfx(result.sfx);
        if (result.song != 0xFF) self.queueSong(result.song);
        if (result.warp) |w| {
            self.beginMapTransition(w);
            return true;
        }
        return false;
    }

    pub fn consumeShop(self: *GameState) ?u8 {
        if (self.pending_shop == 0xFF) return null;
        const s = self.pending_shop;
        self.pending_shop = 0xFF;
        return s;
    }

    fn reloadNpcs(self: *GameState) !void {
        if (self.mode != .submap) return;
        const sm = self.sub orelse return;
        if (self.npcs) |*n| n.deinit();
        const map_high = self.map_id >= 256 or (sm.prop.tilemap_msb & 0x80) != 0;
        self.npcs = try npc_mod.NpcSet.load(
            self.allocator,
            self.rom,
            sm.prop.npc_index,
            self.npc_switch[0..],
            map_high,
            sm.prop.npc_pal,
        );
    }
};

fn truncateForHist(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}
