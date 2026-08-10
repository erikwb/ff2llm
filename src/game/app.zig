//! SDL3 field engine: overworld, towns/castles, NPCs, battle.
const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const rom_mod = @import("../rom.zig");
const data_mod = @import("../data.zig");
const offsets = @import("../offsets.zig");
const sprites_mod = @import("../map/sprites.zig");
const vehicle_mod = @import("../map/vehicle.zig");
const earth_moon_mod = @import("../map/earth_moon.zig");
const snes = @import("../gfx/snes.zig");
const npc_mod = @import("../map/npc.zig");
const damage = @import("../battle/damage.zig");
const encounter_mod = @import("../battle/encounter.zig");
const battle_host = @import("../battle/host.zig");
const battle_gfx = @import("../battle/gfx.zig");
const game_state = @import("state.zig");
const field_menu = @import("menu.zig");
const title_mod = @import("title.zig");
const ui_mod = @import("../gfx/ui.zig");
const audio_mod = @import("../audio/audio.zig");
const ai_local = @import("../ai/local.zig");
const mic_pw = @import("../ai/mic_pw.zig");
const pad_mod = @import("pad.zig");

/// SNES internal resolution — all game logic/painting is in this space.
/// SDL scales it up for larger displays; never stretch non-uniformly.
const view_w: i32 = 256;
const view_h: i32 = 224;
/// Default window = 4× integer scale (1024×896). User can resize; we letterbox.
const scale: i32 = 4;
const win_w: i32 = view_w * scale;
const win_h: i32 = view_h * scale;

// NTSC Super Famicom field rate (approx). Used to drive a virtual $7a like the NMI.
// Exact common value: 60.0988 Hz → ~16_639_267 ns/field.
const ntsc_field_ns: u64 = 16_639_267;

const UiState = enum { title, field, menu, battle, game_over };

const LoadUi = struct {
    pixels: []u8,
    texture: *c.SDL_Texture,
    renderer: *c.SDL_Renderer,
    progress: f32 = 0,
    stage: [64]u8 = undefined,
    stage_len: usize = 0,

    fn setStage(self: *LoadUi, s: []const u8) void {
        const n = @min(s.len, self.stage.len);
        @memcpy(self.stage[0..n], s[0..n]);
        self.stage_len = n;
    }

    fn draw(self: *LoadUi) void {
        @memset(self.pixels, 0);
        fillRect(self.pixels, 0, 0, view_w, view_h, 8, 8, 24);
        drawText(self.pixels, 40, 70, "LOADING AI MODELS", 220, 200, 120);
        drawText(self.pixels, 40, 90, "Gemma 4  ·  ROCm GPU", 140, 160, 200);
        // Progress track
        fillRect(self.pixels, 32, 120, view_w - 64, 14, 20, 20, 40);
        const fill_w: i32 = @intFromFloat(@as(f32, @floatFromInt(view_w - 68)) * @min(self.progress, 1.0));
        if (fill_w > 0) fillRect(self.pixels, 34, 122, fill_w, 10, 80, 180, 120);
        var pct_buf: [16]u8 = undefined;
        const pct = std.fmt.bufPrint(&pct_buf, "{d}%", .{@as(u32, @intFromFloat(self.progress * 100.0))}) catch "?";
        drawText(self.pixels, 110, 140, pct, 200, 200, 200);
        if (self.stage_len > 0) {
            drawText(self.pixels, 32, 160, self.stage[0..self.stage_len], 160, 160, 180);
        }
        drawText(self.pixels, 32, 200, "IN-PROCESS LIBLLAMA (NO SERVER)", 100, 100, 120);
        _ = c.SDL_UpdateTexture(self.texture, null, self.pixels.ptr, view_w * 4);
        _ = c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderTexture(self.renderer, self.texture, null, null);
        _ = c.SDL_RenderPresent(self.renderer);
        // Keep window responsive during long load
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {}
    }
};

pub fn run(io: Io, gpa: std.mem.Allocator, rom_path: []const u8) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD)) {
        std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    var pad: pad_mod.Pad = .{};
    defer pad.deinit();
    pad.openFirst();

    // Resizable: bigger monitors welcome. Logical 256×224 + letterbox keeps
    // square pixels and lined-up UI (no non-uniform stretch).
    const window = c.SDL_CreateWindow(
        "Final Fantasy II — ff4 native",
        win_w,
        win_h,
        c.SDL_WINDOW_RESIZABLE,
    );
    if (window == null) return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, view_w, view_h);

    const renderer = c.SDL_CreateRenderer(window, null);
    if (renderer == null) return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderVSync(renderer, 1);
    // LETTERBOX: max uniform scale that fits the window, black bars on sides/ends.
    // Prefer this over STRETCH (distorts) and over INTEGER_SCALE alone when the
    // window is between integer multiples (still sharp with nearest sampling).
    _ = c.SDL_SetRenderLogicalPresentation(renderer, view_w, view_h, c.SDL_LOGICAL_PRESENTATION_LETTERBOX);

    const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, view_w, view_h);
    if (texture == null) return error.SdlTexture;
    defer c.SDL_DestroyTexture(texture);
    _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);

    const pixels = try gpa.alloc(u8, @intCast(view_w * view_h * 4));
    defer gpa.free(pixels);

    var load_ui: LoadUi = .{
        .pixels = pixels,
        .texture = texture.?,
        .renderer = renderer.?,
    };
    load_ui.setStage("Reading ROM...");
    load_ui.progress = 0.02;
    load_ui.draw();

    var r = try rom_mod.load(io, gpa, rom_path);
    defer r.deinit();
    load_ui.setStage("Extracting tables...");
    load_ui.progress = 0.08;
    load_ui.draw();

    var gd = try data_mod.extract(gpa, &r);
    defer gd.deinit();
    var ui_gfx: ui_mod.UiGfx = .{};
    ui_gfx.load(&r);

    // BGM via pw-cat first (no mic yet → usually stays on A2DP during GGUF load).
    // Mic opens *after* the model so capture + HFP flip don't fight GPU load.
    load_ui.setStage("Booting SPC audio (pw-cat)...");
    load_ui.progress = 0.12;
    load_ui.draw();
    var audio = try audio_mod.Audio.init(io, gpa, r.data);
    defer audio.deinit();
    audio.playSong(audio_mod.song_prelude);
    audio.keepAlive();
    if (audio.enabled) {
        std.log.info("audio: boot playback ready (pw-cat)", .{});
    } else {
        std.log.warn("audio: playback disabled at boot", .{});
    }

    // Field leader sheet — reloaded when party/top char changes (ValidateTopChar / e7).
    var party = try sprites_mod.SpriteSheet.load(gpa, &r, 0, sprites_mod.fieldPalIndex(0));
    defer party.deinit();
    var party_gfx_loaded: u8 = 0;
    var party_pal_loaded: u8 = sprites_mod.fieldPalIndex(0);

    // Repo root = process cwd (run from project root so models/ and vendor/ resolve).
    const repo_root: []const u8 = ".";
    const paths = ai_local.Paths{ .root = repo_root };

    // --- Prewarm in-process Gemma on ROCm (libllama) with progress bar ---
    var llm: ai_local.Llm = .{};
    defer llm.deinit();
    {
        const Ctx = struct {
            ui: *LoadUi,
            audio: *audio_mod.Audio,
            last_pump_ns: u64 = 0,
            fn cb(p: f32, stage: []const u8, user: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(user.?));
                // Map model load into 0.18..0.92 of overall bar
                self.ui.progress = 0.18 + p * 0.74;
                self.ui.setStage(stage);
                self.ui.draw();
                // Throttle audio pump — llama progress can fire hundreds of times/sec.
                const now = c.SDL_GetTicksNS();
                if (now -% self.last_pump_ns >= 40 * std.time.ns_per_ms) {
                    self.last_pump_ns = now;
                    self.audio.keepAlive();
                }
            }
        };
        var ctx: Ctx = .{ .ui = &load_ui, .audio = &audio };
        load_ui.setStage("Loading Gemma 4 (GPU)...");
        load_ui.progress = 0.18;
        load_ui.draw();
        // Keep Prelude flowing while the model loads (same issue as voice STT/LLM).
        audio.startBgPump();
        llm.load(paths, Ctx.cb, &ctx) catch |err| {
            std.log.warn("LLM prewarm failed: {s} (voice chat disabled)", .{@errorName(err)});
            load_ui.setStage("LLM unavailable — voice off");
            load_ui.progress = 0.92;
            load_ui.draw();
            c.SDL_Delay(400);
        };
        if (llm.ok()) {
            std.log.info("LLM ready: {s}", .{llm.backendInfo()});
            load_ui.setStage("Warming sampler...");
            load_ui.progress = 0.93;
            load_ui.draw();
            if (llm.generate(gpa, "Reply with the word Ready only.", "Hi")) |warm| {
                gpa.free(warm);
            } else |_| {}
        }
        audio.stopBgPump();
        audio.resyncClock();
        audio.keepAlive();
    }

    // Kokoro TTS worker — warm on CPU (fast lines; does not peg the ROCm GPU).
    var tts: ai_local.Tts = .{};
    defer tts.deinit();
    {
        load_ui.setStage("Loading Kokoro TTS...");
        load_ui.progress = 0.94;
        load_ui.draw();
        tts.load(paths) catch |err| {
            std.log.warn("TTS prewarm failed: {s} (NPC speech disabled)", .{@errorName(err)});
            load_ui.setStage("TTS unavailable — speech off");
            load_ui.progress = 0.95;
            load_ui.draw();
            c.SDL_Delay(300);
        };
    }

    // Mic after model load. Only do the long BT settle+rebind when BlueZ is
    // actually the default device — otherwise pw-record is just a normal mic
    // and thrashing playback is pure downside.
    var mic: mic_pw.Mic = .{};
    defer mic.deinit(io);
    {
        const bt = pipewireLooksBluetooth(io, gpa);
        load_ui.setStage(if (bt) "Opening mic (BT duplex)..." else "Opening mic...");
        load_ui.progress = 0.96;
        load_ui.draw();
        audio.keepAlive();
        mic.start(io) catch |err| {
            std.log.warn("pw-record start failed: {s}", .{@errorName(err)});
        };
        if (bt) {
            // Capture can flip AirPods A2DP→HFP; wait for WirePlumber then rebind.
            var tick: u8 = 0;
            while (tick < 10) : (tick += 1) {
                load_ui.setStage("Settling BT audio...");
                load_ui.progress = 0.96 + @as(f32, @floatFromInt(tick)) * 0.003;
                load_ui.draw();
                audio.keepAlive();
                c.SDL_Delay(150);
            }
            _ = audio.rebindPlayback();
            audio.playSong(audio_mod.song_prelude);
            audio.keepAlive();
            std.log.info("audio: mic up + playback rebound (Bluetooth default sink/source)", .{});
        } else {
            // Local/USB/HDMI: brief settle only so pw-record is live; no rebind.
            c.SDL_Delay(100);
            audio.keepAlive();
            std.log.info("audio: mic up (no Bluetooth — skipped HFP settle/rebind)", .{});
        }
        mic.discard();
    }
    load_ui.progress = 1.0;
    load_ui.setStage("Done");
    load_ui.draw();
    c.SDL_Delay(150);

    var ui: UiState = .title;
    var title_scr: title_mod.TitleScreen = .{};
    title_scr.init(gpa, &r);
    defer title_scr.deinit();
    // Placeholder until player picks a title option (Baron skip is free-roam default).
    var gs = try game_state.GameState.initBaronSkip(gpa, &r, &gd);
    defer gs.deinit();
    var last_audio_song: u8 = 0xFF;
    // ShowTitle: song $15 Prelude (title_en.asm @85fa).
    audio.playSong(audio_mod.song_prelude);
    last_audio_song = audio_mod.song_prelude;

    // Virtual SNES $7a — incremented once per NTSC field (field.asm NMI `inc $7a`).
    var snes_7a: u8 = 0;
    var player_atk: u16 = 30;
    var last_ns: u64 = c.SDL_GetTicksNS();
    var time_accum_ns: u64 = 0;

    // VehicleGfx for DrawRedWings (Special_00/01) and world vehicles.
    var vehicle_spr: vehicle_mod.VehicleSprites = .{};
    vehicle_spr.load(&r) catch {};
    // Earth/moon planet tiles for D3 travel cinema (LoadEarthMoonGfx).
    var planet_spr: earth_moon_mod.PlanetSprites = .{};
    planet_spr.load();

    // Battle host = ExecBattle / BattleMain reimplementation (see src/battle/README.md).
    var btl = battle_host.Host{};
    defer btl.deinitScene();
    var lcg = damage.Lcg.init(0xC0FFEE);

    // Field main menu (menu/menu.asm MainMenuMain).
    var fmenu: field_menu.FieldMenu = .{};
    fmenu.load(&r);

    var prev_confirm = false;
    var prev_up = false;
    var prev_down = false;
    var prev_left = false;
    var prev_right = false;
    var prev_escape = false;
    var prev_debug_key = false;
    var prev_flee = false;

    var rec_samples: std.ArrayList(i16) = .empty;
    defer rec_samples.deinit(gpa);
    var voice_busy = false;
    var vad_speaking = false;
    var vad_speech_samples: usize = 0;
    var vad_silence_samples: usize = 0;
    var vad_noise_ema: f32 = 400.0;
    var was_facing_npc = false;

    const sample_rate: usize = 16000;
    const vad_start_ms: usize = 120; // need this much speech to start capture
    const vad_end_ms: usize = 750; // silence after speech ends turn
    const vad_min_utt_ms: usize = 350; // ignore clicks
    const vad_max_utt_ms: usize = 12000;
    const vad_start_samp = sample_rate * vad_start_ms / 1000;
    const vad_end_samp = sample_rate * vad_end_ms / 1000;
    const vad_min_utt = sample_rate * vad_min_utt_ms / 1000;
    const vad_max_utt = sample_rate * vad_max_utt_ms / 1000;

    var running = true;
    while (running) {
        // KEY_DOWN / button-down edges survive long blocking voice turns (events
        // queue while STT/LLM/TTS runs — hold-edge alone can miss dismiss presses).
        var confirm_keydown = false;
        var escape_keydown = false;
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) running = false;
            if (ev.type == c.SDL_EVENT_GAMEPAD_ADDED or ev.type == c.SDL_EVENT_GAMEPAD_REMOVED) {
                pad.handleDevice(ev.type, ev.gdevice.which);
            }
            if (ev.type == c.SDL_EVENT_KEY_DOWN and !ev.key.repeat) {
                const sc = ev.key.scancode;
                if (sc == c.SDL_SCANCODE_RETURN or sc == c.SDL_SCANCODE_Z or sc == c.SDL_SCANCODE_SPACE)
                    confirm_keydown = true;
                if (sc == c.SDL_SCANCODE_ESCAPE) escape_keydown = true;
            }
            if (ev.type == c.SDL_EVENT_GAMEPAD_BUTTON_DOWN) {
                if (ev.gbutton.button == c.SDL_GAMEPAD_BUTTON_SOUTH) confirm_keydown = true;
                if (ev.gbutton.button == c.SDL_GAMEPAD_BUTTON_EAST or ev.gbutton.button == c.SDL_GAMEPAD_BUTTON_START)
                    escape_keydown = true;
            }
        }

        // Advance a virtual SNES field clock from wall time (not SDL loop rate).
        // Original: NMI does `inc $7a` once per field (field.asm ~@9450).
        const now_ns: u64 = c.SDL_GetTicksNS();
        time_accum_ns +%= now_ns -% last_ns;
        last_ns = now_ns;
        // Cap catch-up so a long stall doesn't fast-forward animations
        if (time_accum_ns > ntsc_field_ns * 6) time_accum_ns = ntsc_field_ns * 6;

        var fields_this_pass: u32 = 0;
        while (time_accum_ns >= ntsc_field_ns) : (fields_this_pass += 1) {
            time_accum_ns -= ntsc_field_ns;
            snes_7a +%= 1;
        }

        const kb = c.SDL_GetKeyboardState(null);
        const hold_up = kb[@intCast(c.SDL_SCANCODE_UP)] or kb[@intCast(c.SDL_SCANCODE_W)] or pad.up();
        const hold_down = kb[@intCast(c.SDL_SCANCODE_DOWN)] or kb[@intCast(c.SDL_SCANCODE_S)] or pad.down();
        const hold_left = kb[@intCast(c.SDL_SCANCODE_LEFT)] or kb[@intCast(c.SDL_SCANCODE_A)] or pad.left();
        const hold_right = kb[@intCast(c.SDL_SCANCODE_RIGHT)] or kb[@intCast(c.SDL_SCANCODE_D)] or pad.right();
        const hold_confirm = kb[@intCast(c.SDL_SCANCODE_RETURN)] or kb[@intCast(c.SDL_SCANCODE_Z)] or kb[@intCast(c.SDL_SCANCODE_SPACE)] or pad.confirm();
        const hold_escape = kb[@intCast(c.SDL_SCANCODE_ESCAPE)] or pad.cancel();
        // Debug: grant Baron Key + story flag (until Yang event is playable).
        const hold_debug_key = kb[@intCast(c.SDL_SCANCODE_K)] or pad.debugKey();
        // L+R flee in ROM; here X in battle. On field, X opens main menu (SNES X).
        const hold_x = kb[@intCast(c.SDL_SCANCODE_X)] or kb[@intCast(c.SDL_SCANCODE_TAB)] or kb[@intCast(c.SDL_SCANCODE_M)];
        const hold_flee = hold_x;

        const press_confirm = (hold_confirm and !prev_confirm) or confirm_keydown;
        const press_up = hold_up and !prev_up;
        const press_down = hold_down and !prev_down;
        const press_left = hold_left and !prev_left;
        const press_right = hold_right and !prev_right;
        const press_escape = (hold_escape and !prev_escape) or escape_keydown;
        const press_debug_key = hold_debug_key and !prev_debug_key;
        const press_flee = hold_flee and !prev_flee;
        const press_menu = hold_x and !prev_flee;
        prev_confirm = hold_confirm;
        prev_up = hold_up;
        prev_down = hold_down;
        prev_left = hold_left;
        prev_right = hold_right;
        prev_escape = hold_escape;
        prev_debug_key = hold_debug_key;
        prev_flee = hold_flee;

        if (press_escape) {
            if (vad_speaking) {
                rec_samples.clearRetainingCapacity();
                vad_speaking = false;
                vad_speech_samples = 0;
                vad_silence_samples = 0;
                gs.setMsg("Cancelled");
            } else if (gs.eventYesNoOpen()) {
                // Esc = No on inn/F8 prompts — handled in tickEvent (do not dismiss only).
                audio.stopSpeech();
            } else if (gs.namingwayOpen()) {
                // Namingway B/Esc = cancel / backspace (tickNamingway).
                audio.stopSpeech();
            } else if (gs.dlg_open) {
                gs.closeDlg();
                audio.stopSpeech();
                // Esc closes the box; event script still waits on confirm to resume.
                // (Same as ROM: cancel doesn't skip cutscene dialogue.)
            } else if (ui == .menu) {
                fmenu.cancel();
                if (!fmenu.open) ui = .field;
            } else if (ui == .battle and btl.phase == .menu and (btl.menu_mode == .item or btl.menu_mode == .target or btl.menu_mode == .cover_target or btl.menu_mode == .magic)) {
                // B/Esc: leave item/magic/target/cover → command list (not title).
                btl.menuCancel();
            } else if (ui == .field or ui == .battle or ui == .game_over) {
                if (ui == .battle) btl.deinitScene();
                ui = .title;
            } else {
                running = false;
            }
        }

        // Event dialogue confirm is edge-triggered once per OS frame and must not
        // depend on the NTSC field clock or VAD (high refresh can yield fields_this_pass=0;
        // ambient mic noise must not freeze cutscenes on F0 multi-page boxes).
        //
        // `field_confirm` is shared: once Space/Z dismisses dialogue or advances an event,
        // the same press must not also open tryTalk() (infinite talk loop).
        var field_confirm = press_confirm;
        var event_confirm = press_confirm;
        // Namingway (EventCmd_d9): pad routed to session before generic dialogue confirm.
        if (ui == .field and !fmenu.open and gs.namingwayOpen() and
            (press_confirm or press_escape or press_left or press_right or press_up or press_down))
        {
            gs.tickNamingway(press_confirm, press_escape, press_left, press_right, press_up, press_down);
            event_confirm = false;
            field_confirm = false;
        } else if (ui == .field and !fmenu.open and gs.eventYesNoOpen() and (press_confirm or press_escape)) {
            // Yes/No (inn/F8): handle confirm/cancel once per OS frame outside field clock.
            gs.tickEvent(press_confirm, press_escape);
            event_confirm = false;
            field_confirm = false;
            if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
            if (gs.consumeSong()) |sid| {
                audio.playSong(sid);
                last_audio_song = sid;
            }
        } else if (ui == .field and !fmenu.open and gs.dlg_open and field_confirm and !gs.eventActive()) {
            // Free-roam / voice dialogue: dismiss on Space *before* field clock / VAD
            // so a long TTS block cannot leave confirm stranded for a frame.
            field_confirm = false;
            event_confirm = false;
            const still_open = gs.advanceDlg();
            if (!still_open) audio.stopSpeech();
        } else if (ui == .field and !fmenu.open and gs.eventActive() and gs.dlg_open and event_confirm and !gs.dlg_auto_scroll) {
            gs.tickEvent(true, false);
            event_confirm = false;
            field_confirm = false;
            if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
            if (gs.consumeSong()) |sid| {
                audio.playSong(sid);
                last_audio_song = sid;
            }
            // Dismissing dialogue can fall through into EventCmd_ec same step.
            if (gs.consumeEventBattle()) |bid| {
                const bg: u8 = switch (gs.mode) {
                    .overworld => blk: {
                        const phi: u8 = if (gs.ow) |*ow| ow.propHiAt(gs.pos_x, gs.pos_y) else 0x40;
                        break :blk encounter_mod.worldBattleBg(phi);
                    },
                    .submap => encounter_mod.submapBattleBg(&r, gs.map_id),
                };
                btl.enter(
                    gpa,
                    &r,
                    &gd,
                    bid,
                    bg,
                    &gs.inventory,
                    &gs.party,
                    gs.world_id == 2,
                    gs.battle_speed,
                    gs.msg_speed,
                    gs.battle_mode,
                    gs.party_row,
                ) catch {
                    gs.resumeAfterEventBattle();
                };
                btl.spell_lists = &gs.spell_lists;
                btl.chrome.applyWindowColor(gs.window_color);
                if (gs.eventWaitingOnBattle()) {
                    audio.playSfx(audio_mod.sfx_battle_enter);
                    if (btl.song_id != audio_mod.battle_song_none) {
                        audio.playSong(btl.song_id);
                        last_audio_song = btl.song_id;
                    }
                    ui = .battle;
                    gs.move_dir = 0;
                    gs.move_px = 0;
                }
            }
        }

        // One MovePlayer-equivalent tick per emulated NTSC field.
        if (fields_this_pass > 0) {
            const step: u8 = @truncate(@min(fields_this_pass, 4)); // cap catch-up
            var s: u8 = 0;
            // Edge confirm only once per OS frame (avoid auto-dismiss multi-field catch-up).
            while (s < step) : (s += 1) {
                // Reconstruct per-field $7a (pre-advanced by `step` above for this pass).
                const field_7a: u8 = snes_7a -% @as(u8, @truncate(step - 1 - s));
                if (ui == .field and !fmenu.open) {
                    // Wipe/fade/mosaic/flash/cinematics advance every field.
                    gs.tickTransition();
                    // Field anim once per NTSC field (WaitFrame path in field.asm):
                    // UpdateWaterAnim/TfrWaterGfx on overworld; UpdateBG2Scroll + TfrBGAnimGfx on submap.
                    // Runs during cinema too (Red Wings flyby still animates water).
                    switch (gs.mode) {
                        .overworld => {
                            // UpdateWaterLavaAnim (field.asm @8e47) + UpdateLavaPal / UpdateZoomPal.
                            if (gs.ow) |*ow| {
                                ow.tickWaterLavaAnim();
                                // UpdateZoomPal (A = altitude level 0..$10, not raw `$ad`).
                                ow.applyZoomPal(gs.zoomPalLevel());
                                // UpdateLavaPal (pal_anim.asm @c4cd) — underground lava glow.
                                ow.applyLavaPal(snes_7a);
                                // UpdateBabilPal — Tower of Babil flash on OW/under (`$1288&$04` = switch $42).
                                ow.applyBabilPal(snes_7a, gs.eventSwitchOn(0x42));
                            }
                        },
                        .submap => {
                            if (gs.sub) |*sm| {
                                sm.tickBg2Scroll(field_7a);
                                sm.tickAnim(field_7a);
                                // UpdateAnimPal — tower/zot/babil/giant/cave light cycles.
                                sm.applyAnimPal(snes_7a);
                            }
                        },
                    }
                    // Apply BGM gain from song fade (D8 / FD $3d/$3e).
                    audio.bgm_gain_num = gs.bgm_gain_num;
                    audio.bgm_gain_den = gs.bgm_gain_den;
                    if (gs.consumeSong()) |sid| {
                        if (sid == 0xFE) {
                            audio.stop();
                            last_audio_song = 0xFF;
                        } else {
                            audio.playSong(sid);
                            last_audio_song = sid;
                        }
                    }
                    // Door open / event SFX must still fire during wipe/cinema.
                    if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
                    if (gs.isTransitioning()) {
                        // Hold player + events mid-iris / cinema (ROM WaitVblankEvent).
                        continue;
                    }
                    if (gs.eventActive()) {
                        // Intro / cutscene: never blocked by VAD/voice (player can't talk mid-event).
                        // While blocked on EventCmd_ec battle, skip ticks until battle ends.
                        if (!gs.eventWaitingOnBattle()) {
                            // Yes/No: confirm=Yes, Esc=No (edge this field only).
                            const event_cancel = press_escape and gs.eventYesNoOpen();
                            gs.tickEvent(event_confirm, event_cancel);
                            event_confirm = false;
                            // GoUpTunnel: DrillAnim after event $C6 ends.
                            gs.afterEventIdle();
                            if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
                            if (gs.consumeSong()) |sid| {
                                if (sid == 0xFE) {
                                    audio.stop();
                                    last_audio_song = 0xFF;
                                } else {
                                    audio.playSong(sid);
                                    last_audio_song = sid;
                                }
                            }
                            // EventCmd_ec → forced formation (airship intro fights, etc.)
                            if (gs.consumeEventBattle()) |bid| {
                                const bg: u8 = switch (gs.mode) {
                                    .overworld => blk: {
                                        const phi: u8 = if (gs.ow) |*ow| ow.propHiAt(gs.pos_x, gs.pos_y) else 0x40;
                                        break :blk encounter_mod.worldBattleBg(phi);
                                    },
                                    .submap => encounter_mod.submapBattleBg(&r, gs.map_id),
                                };
                                btl.enter(
                                    gpa,
                                    &r,
                                    &gd,
                                    bid,
                                    bg,
                                    &gs.inventory,
                                    &gs.party,
                                    gs.world_id == 2,
                                    gs.battle_speed,
                                    gs.msg_speed,
                                    gs.battle_mode,
                                    gs.party_row,
                                ) catch {
                                    // Bad formation — skip so the cutscene does not soft-lock.
                                    gs.resumeAfterEventBattle();
                                    continue;
                                };
                                btl.spell_lists = &gs.spell_lists;
                                btl.chrome.applyWindowColor(gs.window_color);
                                audio.playSfx(audio_mod.sfx_battle_enter);
                                if (btl.song_id != audio_mod.battle_song_none) {
                                    audio.playSong(btl.song_id);
                                    last_audio_song = btl.song_id;
                                }
                                ui = .battle;
                                gs.move_dir = 0;
                                gs.move_px = 0;
                            }
                        }
                        continue;
                    }
                    if (vad_speaking or voice_busy) continue;
                    const was_moving = gs.isMoving();
                    const prev_x = gs.pos_x;
                    const prev_y = gs.pos_y;
                    gs.tickVehicleAnim(snes_7a);
                    gs.afterEventIdle(); // deferred DrillAnim if event ended outside event branch
                    try gs.tickMovement(hold_up, hold_down, hold_left, hold_right);
                    gs.tickFreeRoamNpcs();
                    gs.updateSaveEnabled();
                    if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
                    if (gs.consumeSong()) |sid| {
                        audio.playSong(sid);
                        last_audio_song = sid;
                    }
                    // FD specials (e.g. Special_04 Titan) may queue a formation outside EventCmd_ec.
                    if (gs.consumeEventBattle()) |bid| {
                        const bg: u8 = switch (gs.mode) {
                            .overworld => blk: {
                                const phi: u8 = if (gs.ow) |*ow| ow.propHiAt(gs.pos_x, gs.pos_y) else 0x40;
                                break :blk encounter_mod.worldBattleBg(phi);
                            },
                            .submap => encounter_mod.submapBattleBg(&r, gs.map_id),
                        };
                        btl.enter(
                            gpa,
                            &r,
                            &gd,
                            bid,
                            bg,
                            &gs.inventory,
                            &gs.party,
                            gs.world_id == 2,
                            gs.battle_speed,
                            gs.msg_speed,
                            gs.battle_mode,
                            gs.party_row,
                        ) catch {};
                        btl.spell_lists = &gs.spell_lists;
                        btl.chrome.applyWindowColor(gs.window_color);
                        audio.playSfx(audio_mod.sfx_battle_enter);
                        if (btl.song_id != audio_mod.battle_song_none) {
                            audio.playSong(btl.song_id);
                            last_audio_song = btl.song_id;
                        }
                        ui = .battle;
                        gs.move_dir = 0;
                        gs.move_px = 0;
                        continue;
                    }
                    // Tile commit → CheckBattle (rand_battle.asm @8b3c).
                    // `$1704 != 0` → no random battles (mounted).
                    if ((gs.pos_x != prev_x or gs.pos_y != prev_y) and gs.vehicle == 0) {
                        const roll = lcg.nextByte();
                        const slot = lcg.nextByte();
                        const enc: ?encounter_mod.Encounter = switch (gs.mode) {
                            .overworld => blk: {
                                // $a2 = WorldTileProp high byte at player feet.
                                const phi: u8 = if (gs.ow) |*ow| ow.propHiAt(gs.pos_x, gs.pos_y) else 0x40;
                                break :blk encounter_mod.tryOverworld(&r, gs.pos_x, gs.pos_y, phi, roll, slot);
                            },
                            .submap => encounter_mod.trySubmap(&r, gs.map_id, roll, slot),
                        };
                        if (enc) |e| {
                            // $38ef moon AI scripts when on moon world (world_id 2).
                            btl.enter(
                                gpa,
                                &r,
                                &gd,
                                e.battle_id,
                                e.bg_flags,
                                &gs.inventory,
                                &gs.party,
                                gs.world_id == 2,
                                gs.battle_speed,
                                gs.msg_speed,
                                gs.battle_mode,
                                gs.party_row,
                            ) catch {};
                            btl.spell_lists = &gs.spell_lists;
                            btl.chrome.applyWindowColor(gs.window_color);
                            // BattleWorld/BattleSub: lda #$3f / PlaySfx before ExecBattle.
                            audio.playSfx(audio_mod.sfx_battle_enter);
                            // PlayBattleSong (battle.asm @8219) from BattleProp flags.
                            if (btl.song_id != audio_mod.battle_song_none) {
                                audio.playSong(btl.song_id);
                                last_audio_song = btl.song_id;
                            }
                            ui = .battle;
                            gs.move_dir = 0;
                            gs.move_px = 0;
                        }
                    }
                    _ = was_moving;
                } else if (ui == .battle) {
                    // BattleMain tick (DecTimers / GetPendingAction / …)
                    btl.tick(btl.battleRng());
                    // Drain battle SFX (system + game).
                    if (btl.consumeSysSfx()) |sid| audio.playSystemSfx(sid);
                    if (btl.consumeSfx()) |sid| audio.playSfx(sid);
                    // Mid-fight `$F3` / victory fanfare `$08` (`$38be`/`$38bd`).
                    if (btl.consumeSongChange()) |sid| {
                        if (sid != audio_mod.battle_song_none) {
                            audio.playSong(sid);
                            last_audio_song = sid;
                        } else {
                            audio.stop();
                            last_audio_song = 0xFF;
                        }
                    }

                    if (btl.pollFinished()) {
                        // RestoreCharProp always (win.asm @f18b) — including NoUpdate battles.
                        btl.syncPartyOut(&gs.party);
                        // Field toad/mini/pig sheets may change after battle status writeback.
                        gs.party_sprite_dirty = true;
                        if (btl.end_flags.defeated) {
                            btl.deinitScene();
                            ui = .game_over;
                        } else {
                            if (btl.end_flags.victory and btl.shouldWinUpdate()) {
                                // WinUpdate only when `$a8` bit4 set (not NoUpdateBattleTbl).
                                const rew = btl.calcRewardsWithDrops(&gd);
                                // Cap party gil at 9,999,999 — win.asm / field gil cap
                                const win_mod = @import("../battle/win.zig");
                                gs.gil = win_mod.addGil(gs.gil, rew.gil);
                                btl.gil_gained = rew.gil;
                                btl.exp_gained = rew.exp;
                                btl.items_gained_n = rew.drops.count;
                                @memcpy(btl.items_gained[0..rew.drops.count], rew.drops.items[0..rew.drops.count]);
                                var di: u8 = 0;
                                while (di < rew.drops.count) : (di += 1) {
                                    _ = gs.inventory.give(rew.drops.items[di]);
                                }
                                var living: u8 = 0;
                                for (gs.party) |m| {
                                    if (m.present and m.hp > 0) living += 1;
                                }
                                if (living == 0) living = 1;
                                const share = @import("../battle/win.zig").expPerMember(rew.exp, living);
                                const levelup = @import("../battle/levelup.zig");
                                var total_lv: u8 = 0;
                                var rb: u8 = btl.rng.nextByte();
                                for (&gs.party) |*m| {
                                    if (!m.present or m.hp == 0) continue;
                                    total_lv +%= levelup.grantExpAndLevel(&r, m, share, rb);
                                    rb +%= 13;
                                }
                                var buf: [96]u8 = undefined;
                                const msg = if (rew.drops.count > 0 and total_lv > 0)
                                    std.fmt.bufPrint(&buf, "Won! +{d}G +{d}EXP Lv+{d} item×{d}", .{ rew.gil, rew.exp, total_lv, rew.drops.count }) catch "Won!"
                                else if (rew.drops.count > 0)
                                    std.fmt.bufPrint(&buf, "Won! +{d} G  +{d} EXP  item×{d}", .{ rew.gil, rew.exp, rew.drops.count }) catch "Won!"
                                else if (total_lv > 0)
                                    std.fmt.bufPrint(&buf, "Won! +{d}G +{d}EXP Lv+{d}", .{ rew.gil, rew.exp, total_lv }) catch "Won!"
                                else
                                    std.fmt.bufPrint(&buf, "Won! +{d} G  +{d} EXP", .{ rew.gil, rew.exp }) catch "Won!";
                                gs.setMsg(msg);
                            }
                            btl.deinitScene();
                            // EventCmd_ec: resume cutscene after victory/flee (intro airship fights).
                            if (gs.eventWaitingOnBattle()) {
                                gs.resumeAfterEventBattle();
                            }
                            // Restore field BGM after battle (force re-select).
                            // During cutscenes keep whatever FA set — do not force world/map song.
                            last_audio_song = 0xFF;
                            ui = .field;
                            if (!gs.eventActive() and !gs.cinemaActive()) {
                                playFieldSong(&audio, &gs, &last_audio_song);
                            }
                        }
                    }
                }
            }
        }

        // APU → pw-cat (realtime-paced)
        audio.pump();

        // Edge-triggered UI once per OS frame (not per field)
        switch (ui) {
            .title => {
                if (title_scr.phase == .menu) {
                    if (press_up) title_scr.up();
                    if (press_down) title_scr.down();
                }
                if (press_confirm) {
                    if (title_scr.confirm()) |choice| {
                        switch (choice) {
                            .quit => running = false,
                            else => {
                                if (try title_mod.beginFromChoice(gpa, &r, &gd, choice)) |new_gs| {
                                    gs.deinit();
                                    gs = new_gs;
                                    const ld = gs.leader();
                                    player_atk = @as(u16, ld.strength) *% 3 + 10;
                                    btl = .{};
                                    snes_7a = 0;
                                    ui = .field;
                                    last_audio_song = 0xFF;
                                    const ids = gs.fieldSpriteIds();
                                    party.reload(&r, ids.gfx, ids.pal) catch {};
                                    party_gfx_loaded = ids.gfx;
                                    party_pal_loaded = ids.pal;
                                    gs.party_sprite_dirty = false;
                                    // SoftReset intro: event FA owns BGM ($2C Red Wings, etc.).
                                    // PlayMapSong only when no live event (LoadMap path).
                                    if (!gs.eventActive()) {
                                        playFieldSong(&audio, &gs, &last_audio_song);
                                    }
                                }
                            },
                        }
                    }
                }
            },
            .field => {
                // Cutscenes: EventPlayer owns confirm (handled above / field ticks).
                // Don't open menu or VAD-listen mid-intro.
                if (gs.eventActive()) {
                    // Dialogue confirm already applied before the field loop.
                    // Do not fall through to tryTalk with the same Space press.
                    field_confirm = false;
                } else if (press_menu and !gs.dlg_open) {
                    fmenu.openMenu();
                    // field.asm LoadWindowPal: stx $16aa → fill color.
                    fmenu.applyWindowColor(gs.window_color);
                    ui = .menu;
                } else if (gs.dlg_open) {
                    if (field_confirm) {
                        field_confirm = false;
                        // Last page / dismiss → cut NPC voice with the box.
                        const still_open = gs.advanceDlg();
                        if (!still_open) {
                            audio.stopSpeech();
                            // After dialogue, EventCmd_ed may have queued a shop
                            if (gs.consumeShop()) |sid| {
                                fmenu.openShop(&r, sid);
                                ui = .menu;
                            }
                        }
                    }
                    // Never stop the session mic — start/stop thrash kills BT BGM.
                    // Dialogue already gates want_listen so VAD won't self-trigger.
                    if (!voice_busy) {
                        rec_samples.clearRetainingCapacity();
                        vad_speaking = false;
                        vad_speech_samples = 0;
                        vad_silence_samples = 0;
                    }
                } else if (field_confirm) {
                    field_confirm = false;
                    gs.tryTalk();
                    if (gs.consumeSfx()) |sfx| audio.playSfx(sfx);
                    // Monster-in-a-box treasure (or shop with no prior dialogue).
                    if (gs.consumeEventBattle()) |bid| {
                        const bg: u8 = encounter_mod.submapBattleBg(&r, gs.map_id);
                        btl.enter(
                            gpa,
                            &r,
                            &gd,
                            bid,
                            bg,
                            &gs.inventory,
                            &gs.party,
                            gs.world_id == 2,
                            gs.battle_speed,
                            gs.msg_speed,
                            gs.battle_mode,
                            gs.party_row,
                        ) catch {};
                        btl.spell_lists = &gs.spell_lists;
                        btl.chrome.applyWindowColor(gs.window_color);
                        audio.playSfx(audio_mod.sfx_battle_enter);
                        if (btl.song_id != audio_mod.battle_song_none) {
                            audio.playSong(btl.song_id);
                            last_audio_song = btl.song_id;
                        }
                        ui = .battle;
                        gs.move_dir = 0;
                        gs.move_px = 0;
                    } else if (!gs.dlg_open) {
                        if (gs.consumeShop()) |sid| {
                            fmenu.openShop(&r, sid);
                            ui = .menu;
                        }
                    }
                } else if (press_debug_key) {
                    gs.debugGiveKeyItem(0xEF);
                }

                // --- VAD: only humans/talkable beings (not doors, fires, props) ---
                // Never arm the mic during cutscenes — ambient noise froze event ticks.
                const facing_speaker = !gs.eventActive() and gs.facingVoiceNpc() != null;
                const want_listen = facing_speaker and llm.ok() and tts.ok() and !gs.dlg_open and !voice_busy;

                if (want_listen) {
                    if (!was_facing_npc) {
                        mic.discard(); // drop stale buffer from walking around
                        rec_samples.clearRetainingCapacity();
                        vad_speaking = false;
                        vad_speech_samples = 0;
                        vad_silence_samples = 0;
                        if (mic.running) {
                            gs.setMsg("Listening — speak");
                        } else if (llm.ok()) {
                            gs.setMsg("Mic unavailable");
                        }
                    }

                    var mic_fresh: std.ArrayList(i16) = .empty;
                    defer mic_fresh.deinit(gpa);
                    _ = mic.poll(gpa, &mic_fresh) catch 0;

                    if (mic_fresh.items.len > 0) {
                        const rms = sampleRms(mic_fresh.items);
                        if (!vad_speaking) {
                            vad_noise_ema = vad_noise_ema * 0.95 + rms * 0.05;
                        }
                        const thresh = @max(vad_noise_ema * 3.2, 600.0);
                        const is_speech = rms > thresh;
                        const count = mic_fresh.items.len;

                        if (!vad_speaking) {
                            if (is_speech) {
                                vad_speech_samples +%= count;
                                if (vad_speech_samples >= vad_start_samp) {
                                    vad_speaking = true;
                                    vad_silence_samples = 0;
                                    rec_samples.clearRetainingCapacity();
                                    rec_samples.appendSlice(gpa, mic_fresh.items) catch {};
                                    gs.setMsg("Hearing you...");
                                }
                            } else {
                                vad_speech_samples = 0;
                            }
                        } else {
                            if (rec_samples.items.len + count <= vad_max_utt) {
                                rec_samples.appendSlice(gpa, mic_fresh.items) catch {};
                            }
                            if (is_speech) {
                                vad_silence_samples = 0;
                            } else {
                                vad_silence_samples +%= count;
                            }

                            const long_enough = rec_samples.items.len >= vad_min_utt;
                            const ended = long_enough and vad_silence_samples >= vad_end_samp;
                            const too_long = rec_samples.items.len >= vad_max_utt;
                            if (ended or too_long) {
                                vad_speaking = false;
                                vad_speech_samples = 0;
                                vad_silence_samples = 0;
                                voice_busy = true;
                                std.log.info("audio: VAD end → voice turn ({d} samples)", .{rec_samples.items.len});
                                gs.setMsg("...");
                                presentHudFrame(renderer.?, texture.?, pixels, &gs, &party, snes_7a, &ui_gfx);
                                audio.keepAlive();
                                runVoiceTurn(
                                    io,
                                    gpa,
                                    &gs,
                                    repo_root,
                                    &llm,
                                    &tts,
                                    rec_samples.items,
                                    &audio,
                                    renderer.?,
                                    texture.?,
                                    pixels,
                                    &party,
                                    snes_7a,
                                    &ui_gfx,
                                ) catch |err| {
                                    std.log.err("audio: voice turn error: {s}", .{@errorName(err)});
                                    var buf: [48]u8 = undefined;
                                    const m = std.fmt.bufPrint(&buf, "Voice err: {s}", .{@errorName(err)}) catch "Voice err";
                                    gs.setMsg(m);
                                };
                                // Cheap skip of audio captured during STT/LLM/TTS.
                                mic.discard();
                                voice_busy = false;
                                rec_samples.clearRetainingCapacity();
                                // Only re-arm mic for actual speakers (not doors/fires).
                                if (llm.ok() and gs.facingVoiceNpc() != null and !gs.dlg_open) {
                                    gs.setMsg("Listening — speak");
                                }
                            }
                        }
                    }
                } else {
                    // Not listening: no per-frame I/O. Discard only on the edge
                    // when we walk away (file can grow; next face seeks to EOF).
                    if (was_facing_npc and !facing_speaker) {
                        mic.discard();
                        // Clear "Listening" when leaving a speaker (or stepping onto a prop).
                        if (gs.msgSlice().len == 0 or std.mem.eql(u8, gs.msgSlice(), "Listening — speak") or std.mem.eql(u8, gs.msgSlice(), "Hearing you...")) {
                            gs.setMsg("");
                        }
                    }
                    // Facing a door/fire/chest/prop: ROM A-talk still works; no mic, no LISTEN HUD.
                    if (vad_speaking or rec_samples.items.len > 0) {
                        rec_samples.clearRetainingCapacity();
                        vad_speaking = false;
                        vad_speech_samples = 0;
                        vad_silence_samples = 0;
                    }
                }
                was_facing_npc = facing_speaker;

                // PlayMapSong only when free-roaming. InitWorld skips it while $b1
                // (event) is set — intro FA $2C must stay through Red Wings (no world BGM).
                if (!gs.eventActive() and !gs.cinemaActive()) {
                    playFieldSong(&audio, &gs, &last_audio_song);
                }
            },
            .menu => {
                // MainMenuMain input loop
                const cfg = field_menu.FieldMenu.ConfigFields{
                    .battle_speed = &gs.battle_speed,
                    .msg_speed = &gs.msg_speed,
                    .stereo_mono = &gs.stereo_mono,
                    .window_color = &gs.window_color,
                    .window_color_r = &gs.window_color_r,
                    .window_color_g = &gs.window_color_g,
                    .window_color_b = &gs.window_color_b,
                };
                if (press_up) fmenu.up(&gs.inventory, gs.party[0..]);
                if (press_down) fmenu.down(&gs.inventory, gs.party[0..]);
                if (press_left) fmenu.left(&gs.inventory, cfg, &gs.party_row);
                if (press_right) fmenu.right(&gs.inventory, cfg, &gs.party_row);
                if (press_confirm) fmenu.confirm(&gs.inventory, &gs.party_row, cfg, gs.party[0..], &r, &gs.gil, &gs);
                if (fmenu.consumeSysSfx()) |sid| audio.playSystemSfx(sid);
                if (fmenu.consumeSfx()) |sid| audio.playSfx(sid);
                if (!fmenu.open) {
                    // CheckMenu @8241: `$1a03` menu event → ExecEvent after FadeInMenu.
                    _ = gs.consumeMenuEvent();
                    ui = .field;
                }
            },
            .battle => {
                // GetCharAttack / UpdateCursor_04 target select
                if (btl.phase == .menu) {
                    if (press_up) btl.menuUp();
                    if (press_down) btl.menuDown();
                    if (press_left) btl.menuLeft();
                    if (press_right) btl.menuRight();
                    if (press_confirm) btl.confirmMenu(btl.battleRng());
                    // ROM: hold L+R to run — keyboard X stand-in (command list only)
                    if (press_flee and btl.menu_mode == .command) btl.tryFlee(btl.battleRng());
                }
                if (btl.consumeSysSfx()) |sid| audio.playSystemSfx(sid);
                if (btl.consumeSfx()) |sid| audio.playSfx(sid);
            },
            .game_over => {
                if (press_confirm) {
                    title_scr.phase = .splash;
                    title_scr.sel = 0;
                    ui = .title;
                    audio.playSong(audio_mod.song_prelude);
                    last_audio_song = audio_mod.song_prelude;
                }
            },
        }

        // --- draw ---
        @memset(pixels, 0);
        switch (ui) {
            .title => title_scr.present(pixels, @intCast(view_w), @intCast(view_h)),
            .field => {
                // Reload field leader sprite when party roster/class changes.
                {
                    const ids = gs.fieldSpriteIds();
                    if (gs.party_sprite_dirty or ids.gfx != party_gfx_loaded or ids.pal != party_pal_loaded) {
                        party.reload(&r, ids.gfx, ids.pal) catch {};
                        party_gfx_loaded = ids.gfx;
                        party_pal_loaded = ids.pal;
                        gs.party_sprite_dirty = false;
                    }
                }
                // EventCmd_d0 continuous shake + D6 one-shot quake (+8 scroll).
                const shake_on = gs.screen_shake or gs.quake_frames > 0;
                const shake_x: i32 = if (shake_on and (snes_7a & 4) != 0) 8 else 0;
                const shake_y: i32 = if (shake_on and (snes_7a & 8) != 0) 8 else 0;
                // UpdateScrollSub/World: camera top-left from player (N7 door/stairs/shop).
                const cam = @import("../map/submap.zig").cameraTopLeft(gs.pos_x, gs.pos_y, gs.mode == .submap);
                const cam_x = cam.x;
                const cam_y = cam.y;
                const fine = gs.scrollFine();
                const fx = fine.x + shake_x;
                const fy = fine.y + shake_y;
                // SNES field layers: BG2 → BG1 low-pri → sprites → BG1 high-pri
                // (tilemap word bit13). Walls/bed tops/arches occlude characters.
                // Earth↔Moon star travel / telescope (DrawStars + planet OAM).
                if ((gs.cinema_kind == 2 or gs.cinema_kind == 11) and gs.cinema_space) {
                    @memset(pixels, 0);
                    // `$5c` Mode-7 scroll shifts the starfield + planet (vehicle.asm `_00a465`).
                    const scroll_y: i32 = if (gs.cinema_kind == 2) @as(i32, gs.cinema_scroll_y) else 0;
                    earth_moon_mod.drawStars(pixels, @intCast(view_w), @intCast(view_h), gs.cinema_star_seed, 96);
                    const psize = earth_moon_mod.planetSize(gs.cinema_zoom, @min(view_w, view_h));
                    // Planet sits near center; scroll pulls it (Mode-7 center track stand-in).
                    const py_off = @divTrunc(scroll_y, 4);
                    planet_spr.blitPlanet(
                        pixels,
                        @intCast(view_w),
                        @intCast(view_h),
                        view_w / 2,
                        view_h / 2 + py_off,
                        psize,
                        gs.cinema_to_moon,
                    );
                    // Special_34: circular telescope window (HDMA window stand-in).
                    if (gs.cinema_kind == 11) {
                        applyTelescopeWindow(pixels, @intCast(view_w), @intCast(view_h));
                    }
                    // Prophecy specials: wash with ProphecyPal-ish blue ramp.
                    if (gs.cinema_special_id == 0x32 or gs.cinema_special_id == 0x37 or gs.cinema_special_id == 0x38) {
                        applyProphecyWash(pixels, snes_7a);
                    }
                } else switch (gs.mode) {
                    .overworld => {
                        if (gs.ow) |*ow| {
                            // Mode-7 altitude: InitZoomHDMA center scale (airship / whale).
                            // Tunnel rot: pass TunnelRotTbl angle for affine stand-in.
                            const tun_rot: u8 = if (gs.vehicle_anim.kind == .tunnel_down or gs.vehicle_anim.kind == .tunnel_up or gs.vehicle_anim.kind == .drill_anim)
                                gs.vehicle_anim.tunnel_rot
                            else
                                0;
                            ow.renderZoomed(
                                pixels,
                                @intCast(view_w),
                                @intCast(view_h),
                                cam_x,
                                cam_y,
                                fx,
                                fy,
                                gs.mode7Zoom(),
                                gs.vehicle == vehicle_mod.id_whale,
                                tun_rot,
                            );
                        }
                    },
                    .submap => {
                        if (gs.sub) |*sm| {
                            sm.clearBackdrop(pixels);
                            sm.renderBackground(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fx, fy);
                        }
                    },
                }
                // Sprites between low and high BG (DrawNPCs / DrawPlayerSub).
                if (gs.mode == .submap and !((gs.cinema_kind == 2 or gs.cinema_kind == 11) and gs.cinema_space)) {
                    if (gs.npcs) |*ns| {
                        for (ns.npcs) |n| {
                            if (!n.visible) continue;
                            const hide_lo = if (gs.sub) |*sm| sm.spriteHideLowerBody(n.x, n.y) else false;
                            if (gs.sub) |*sm| {
                                if (sm.spriteFullyHidden(n.x, n.y, gs.party_z)) continue;
                            }
                            const nf = n.moveFine();
                            const sx = (n.x - cam_x) * 16 - fx + nf.x;
                            const sy = (n.y - cam_y) * 16 - 2 - fy + nf.y;
                            if (sx < -16 or sy < -16 or sx > view_w or sy > view_h) continue;
                            const walk_7a: u8 = if (n.move_dir != 0) snes_7a | 0x08 else snes_7a;
                            npc_mod.blitNpc(pixels, @intCast(view_w), sx, sy, n, walk_7a, hide_lo);
                        }
                    }
                }
                // Player stays screen-centered (map scrolls underfoot), as on SNES.
                // Event $C8/$C9 hide ($d3). Red Wings cinema (kind 1): DrawRedWings fleet.
                // Mounted: DrawWorldSprites vehicle at center (DrawChoco / DrawEnterprise…).
                const hide_player = gs.player_hidden or gs.cinema_kind == 1 or gs.cinema_kind == 13 or gs.cinema_kind == 14 or gs.cinema_kind == 19 or ((gs.cinema_kind == 2 or gs.cinema_kind == 11) and gs.cinema_space);
                if (gs.cinema_kind == 1) {
                    vehicle_spr.blitRedWings(pixels, @intCast(view_w), snes_7a);
                } else if ((gs.cinema_kind == 2 or gs.cinema_kind == 11) and gs.cinema_space) {
                    // Stars + planet already painted; no field sprites.
                } else if (gs.mode == .overworld) {
                    // Parked vehicles via CalcVehicleSpritePos (ZoomVehicleTbl + `$ad`).
                    const draw_parked = struct {
                        fn one(
                            vs: *const vehicle_mod.VehicleSprites,
                            pix: []u8,
                            dw: usize,
                            g: *const game_state.GameState,
                            ffx: i32,
                            ffy: i32,
                            vis: u8,
                            vx: u8,
                            vy: u8,
                            world: u8,
                            vid: u8,
                            frame: u8,
                        ) void {
                            if (vis == 0) return;
                            if (world != g.world_id) return;
                            if (g.vehicle == vid) return;
                            // DrawChoco (sprite.asm @b3f5): parked choco only when `$ad==$10` (foot zoom).
                            if ((vid == vehicle_mod.id_chocobo or vid == vehicle_mod.id_black_chocobo) and g.mode7Zoom() != 0x10)
                                return;
                            const mask: i32 = if (g.ow) |*ow| ow.size_mask else 0xFF;
                            const pos = vehicle_mod.calcVehicleSpritePos(
                                vx,
                                vy,
                                g.pos_x,
                                g.pos_y,
                                ffx,
                                ffy,
                                g.mode7Zoom(),
                                mask,
                            ) orelse return;
                            vs.blitParked(pix, dw, pos.x, pos.y, vid, 2, frame);
                        }
                    }.one;
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.choco_vis, gs.choco_x, gs.choco_y, 0, vehicle_mod.id_chocobo, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.bk_choco_vis, gs.bk_choco_x, gs.bk_choco_y, 0, vehicle_mod.id_black_chocobo, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.hover_vis, gs.hover_x, gs.hover_y, gs.hover_world, vehicle_mod.id_hovercraft, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.enterprise_vis, gs.enterprise_x, gs.enterprise_y, gs.enterprise_world, vehicle_mod.id_enterprise, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.falcon_vis, gs.falcon_x, gs.falcon_y, gs.falcon_world, vehicle_mod.id_falcon, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.whale_vis, gs.whale_x, gs.whale_y, gs.whale_world, vehicle_mod.id_whale, snes_7a);
                    draw_parked(&vehicle_spr, pixels, @intCast(view_w), &gs, fx, fy, gs.ship_vis, gs.ship_x, gs.ship_y, gs.world_id, vehicle_mod.id_ship, snes_7a);

                    if (!hide_player) {
                        // LandChoco flee: choco at screen `$1710/$1711`, player on foot.
                        if (gs.vehicle_anim.kind == .choco_flee) {
                            const spr_x: i32 = 7 * 16 + shake_x;
                            const spr_y: i32 = 6 * 16 - 2 + shake_y;
                            // DrawPlayerWorld @b3a0: forest `$a2&$08` hides lower half.
                            const hide_lo = gs.spriteHideLowerBody(gs.pos_x, gs.pos_y);
                            party.blit(pixels, @intCast(view_w), spr_x, spr_y, gs.drawFacing(), gs.walkFrame(), hide_lo);
                            vehicle_spr.blitParked(
                                pixels,
                                @intCast(view_w),
                                @as(i32, gs.vehicle_anim.flee_sx) + shake_x,
                                @as(i32, gs.vehicle_anim.flee_sy) + shake_y,
                                vehicle_mod.id_chocobo,
                                gs.drawFacing(),
                                snes_7a,
                            );
                        } else if (gs.isMounted() or gs.vehicleAnimActive()) {
                            const vid = if (gs.vehicle != 0) gs.vehicle else vehicle_mod.id_enterprise;
                            // `$06fd` airship anim speed: higher altitude → lower mask (faster flap).
                            const anim_spd: u8 = @min(gs.vehicleAlt(), 0x0F);
                            // Special_35 LoadWhaleFlashPal while sinking.
                            if (vid == vehicle_mod.id_whale and gs.cinema_special_id == 0x35) {
                                const alt: i32 = @intCast(gs.vehicleAlt());
                                vehicle_spr.blitWhaleEx(
                                    pixels,
                                    @intCast(view_w),
                                    0x60,
                                    0x60 - alt,
                                    gs.drawFacing() & 3,
                                    .flash,
                                    snes_7a,
                                );
                            } else {
                                vehicle_spr.blitRidden(
                                    pixels,
                                    @intCast(view_w),
                                    vid,
                                    gs.drawFacing(),
                                    snes_7a,
                                    gs.isMoving() or gs.vehicleAnimActive(),
                                    gs.vehicleAlt(),
                                    anim_spd,
                                );
                            }
                            // ShowVehicleSmoke / UpdateExplosions (ExplosionPosTbl burst).
                            if (gs.vehicle_anim.kind == .show_smoke) {
                                drawVehicleSmoke(
                                    pixels,
                                    0x70 + shake_x,
                                    0x70 + shake_y,
                                    gs.vehicle_anim.smoke_timer,
                                    snes_7a,
                                    &vehicle_spr,
                                );
                            }
                        } else {
                            const spr_x: i32 = 7 * 16 + shake_x;
                            const spr_y: i32 = 6 * 16 - 2 + shake_y;
                            // DrawPlayerWorld: `$a2 & #$08` → lower OAM priority 0 (legs in trees).
                            const hide_lo = gs.spriteHideLowerBody(gs.pos_x, gs.pos_y);
                            party.blit(pixels, @intCast(view_w), spr_x, spr_y, gs.drawFacing(), gs.walkFrame(), hide_lo);
                        }
                    }
                } else if (!hide_player) {
                    const under = if (gs.sub) |*sm| sm.spriteFullyHidden(gs.pos_x, gs.pos_y, gs.party_z) else false;
                    if (!under) {
                        const hide_lo = gs.spriteHideLowerBody(gs.pos_x, gs.pos_y);
                        const spr_x: i32 = 7 * 16 + shake_x;
                        const spr_y: i32 = 6 * 16 - 2 + shake_y;
                        party.blit(pixels, @intCast(view_w), spr_x, spr_y, gs.drawFacing(), gs.walkFrame(), hide_lo);
                    }
                }
                // Giant of Babil / explosion specials — `_00cd8a` giant body + UpdateExplosions.
                if (gs.cinema_kind == 12) {
                    const bx = @as(i32, gs.cinema_boom_x) + shake_x;
                    const by = @as(i32, gs.cinema_boom_y) + shake_y;
                    // `_00cd8a` / `_14f58e` 6-tile body; often DrawWhale underneath.
                    if ((gs.cinema_special_id >= 0x21 and gs.cinema_special_id <= 0x27) or gs.cinema_special_id == 0x40) {
                        vehicle_spr.blitWhale(pixels, @intCast(view_w), bx - 0x10, by - 0x08, 2);
                        drawGiantBody(pixels, @intCast(view_w), bx, by, &vehicle_spr);
                    }
                    if (gs.cinema_smoke > 0) {
                        drawUpdateExplosions(
                            pixels,
                            bx,
                            by,
                            gs.cinema_smoke,
                            snes_7a,
                            8, // `$0acf` slot count in many giant specials
                            false, // fire pal (MapSpritePal+31)
                            &vehicle_spr,
                        );
                    }
                }
                // Special_03: Damcyan Red Wings flyby + bombs.
                if (gs.cinema_kind == 13 and gs.cinema_phase == 1) {
                    vehicle_spr.blitDamcyanRedWings(
                        pixels,
                        @intCast(view_w),
                        @as(i32, gs.cinema_ship_x) + shake_x,
                        @as(i32, gs.cinema_ship_y) + shake_y,
                        snes_7a,
                    );
                    if (gs.cinema_smoke > 0) {
                        drawUpdateExplosions(
                            pixels,
                            @as(i32, gs.cinema_boom_x) + shake_x,
                            @as(i32, gs.cinema_boom_y) + shake_y,
                            gs.cinema_smoke,
                            snes_7a,
                            12,
                            false,
                            &vehicle_spr,
                        );
                    }
                }
                // Special_10/$11: Leviathan whirlpool at ($10,$58) + ship.
                if (gs.cinema_kind == 14) {
                    // LoadOverworldLeviathan: whirlpool base $2c=$10, $2e=$58.
                    drawWhirlpool(pixels, @intCast(view_w), 0x10 + shake_x, 0x58 + shake_y, snes_7a, &vehicle_spr);
                    // Ship sucked toward pool; tail bob from LeviathanTailYTbl.
                    const tail_i: usize = @as(usize, snes_7a >> 2) & 0x0F;
                    const tail_y: i32 = vehicle_mod.leviathan_tail_y_tbl[tail_i];
                    vehicle_spr.blitParked(
                        pixels,
                        @intCast(view_w),
                        @as(i32, gs.cinema_ship_x) + shake_x,
                        @as(i32, gs.cinema_ship_y) + shake_y + (tail_y - 0x70),
                        vehicle_mod.id_ship,
                        1,
                        snes_7a,
                    );
                }
                // Special_12–$14 / $17–$18: Red Wings + enterprise.
                if (gs.cinema_kind == 15 or gs.cinema_kind == 16 or gs.cinema_kind == 17 or gs.cinema_kind == 18) {
                    vehicle_spr.blitDamcyanRedWings(
                        pixels,
                        @intCast(view_w),
                        @as(i32, gs.cinema_ship_x) + shake_x,
                        @as(i32, gs.cinema_ship_y) + shake_y,
                        snes_7a,
                    );
                }
                // Special_19–$1B: crushing corridor bars.
                if (gs.cinema_kind == 19) {
                    drawCrushingCorridor(pixels, @intCast(view_w), @intCast(view_h), @intCast(gs.cinema_ship_y));
                }
                // High-priority BG1 over sprites (arches, wall tops, bed headboards, grass tops).
                if (gs.mode == .submap) {
                    if (gs.sub) |*sm| {
                        sm.renderForeground(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fx, fy);
                    }
                }
                const ld = gs.leader();
                drawHud(pixels, ld.hp, ld.max_hp, gs.pos_x, gs.pos_y, gs.locationLabel(), gs.msgSlice(), gs.mode == .submap, gs.map_id);
                if (vad_speaking) {
                    // Red mic indicator while capturing speech
                    fillRect(pixels, view_w - 20, 6, 12, 12, 220, 40, 40);
                    drawText(pixels, view_w - 78, 8, "SPEAKING", 255, 120, 120);
                } else if (was_facing_npc and llm.ok() and tts.ok() and !gs.dlg_open and !voice_busy) {
                    fillRect(pixels, view_w - 20, 6, 12, 12, 40, 180, 80);
                    drawText(pixels, view_w - 70, 8, "LISTEN", 120, 220, 140);
                }
                // Floor damage `$c4` invert (InvertPal / MovePlayer @a878).
                if (gs.map_invert) applyMapInvert(pixels);
                // Screen FX: mosaic → wipe iris → INIDISP brightness, then dialogue on top.
                applyScreenMosaic(pixels, gs.mosaicBlockSize());
                applyScreenWipe(pixels, &gs);
                applyScreenFade(pixels, gs.display_brightness);
                if (gs.flash_frames > 0) applyScreenFlash(pixels);
                // Dialogue after fade so boxes stay readable (OpenDlgWindow is above field).
                if (gs.dlg_open) {
                    ui_gfx.drawDialogue(pixels, @intCast(view_w), @intCast(view_h), gs.dlgSlice(), gs.dlg_page);
                    if (gs.eventYesNoOpen()) {
                        drawText(pixels, 72, @intCast(view_h - 20), "Z/Enter: Yes   Esc: No", 220, 220, 180);
                    }
                }
            },
            .menu => {
                // Draw field under menu, then MainMenuMain windows.
                // UpdateScrollSub/World: camera top-left from player (N7 door/stairs/shop).
                const cam = @import("../map/submap.zig").cameraTopLeft(gs.pos_x, gs.pos_y, gs.mode == .submap);
                const cam_x = cam.x;
                const cam_y = cam.y;
                const fine = gs.scrollFine();
                switch (gs.mode) {
                    .overworld => {
                        if (gs.ow) |*ow| {
                            ow.render(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fine.x, fine.y);
                        }
                    },
                    .submap => {
                        if (gs.sub) |*sm| {
                            sm.tickAnim(snes_7a);
                            sm.render(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fine.x, fine.y);
                        }
                    },
                }
                // DrawMainMenu: full party + portraits + gil (menu.asm DrawCharsMainMenu).
                fmenu.present(
                    pixels,
                    @intCast(view_w),
                    &gs.inventory,
                    gs.gil,
                    &r,
                    gs.battle_speed,
                    gs.msg_speed,
                    gs.stereo_mono,
                    gs.window_color_r,
                    gs.window_color_g,
                    gs.window_color_b,
                    gs.party[0..],
                    gs.party_row,
                    &gs.spell_lists,
                );
            },
            .battle => {
                battle_gfx.present(pixels, &btl, if (btl.scene.loaded) &btl.scene else null);
            },
            .game_over => drawCentered(pixels, "GAME OVER — Enter"),
        }

        _ = c.SDL_UpdateTexture(texture, null, pixels.ptr, view_w * 4);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, texture, null, null);
        _ = c.SDL_RenderPresent(renderer);

        // If we're ahead of NTSC, sleep the remainder (keeps $7a real-time even without vsync).
        if (fields_this_pass == 0 and time_accum_ns < ntsc_field_ns) {
            const sleep_ns = ntsc_field_ns - time_accum_ns;
            if (sleep_ns > 100_000) c.SDL_DelayNS(sleep_ns / 2);
        }
    }
}

fn setMsg(buf: *[64]u8, len: *usize, msg: []const u8) void {
    const n = @min(msg.len, buf.len);
    @memcpy(buf.*[0..n], msg[0..n]);
    len.* = n;
}

/// True if PipeWire/Pulse default sink or source looks like BlueZ (AirPods etc.).
/// Used only to decide whether mic-open needs an HFP settle + BGM rebind.
fn pipewireLooksBluetooth(io: std.Io, gpa: std.mem.Allocator) bool {
    const checks = [_][]const []const u8{
        &.{"pactl", "get-default-sink"},
        &.{"pactl", "get-default-source"},
    };
    for (checks) |argv| {
        const result = std.process.run(gpa, io, .{
            .argv = argv,
            .stdout_limit = .limited(512),
            .stderr_limit = .limited(256),
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        // bluez_output.… / bluez_input.… / bluez_sink.…
        if (std.ascii.indexOfIgnoreCase(result.stdout, "bluez") != null) return true;
    }
    return false;
}

fn sampleRms(samples: []const i16) f32 {
    if (samples.len == 0) return 0;
    var acc: f64 = 0;
    for (samples) |s| {
        const v: f64 = @floatFromInt(s);
        acc += v * v;
    }
    return @floatCast(@sqrt(acc / @as(f64, @floatFromInt(samples.len))));
}

/// One quick field frame so "..." / Listening shows before a blocking voice turn.
fn presentHudFrame(
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    pixels: []u8,
    gs: *game_state.GameState,
    party: *sprites_mod.SpriteSheet,
    snes_7a: u8,
    ui_gfx: *const ui_mod.UiGfx,
) void {
    @memset(pixels, 0);
    const cam = @import("../map/submap.zig").cameraTopLeft(gs.pos_x, gs.pos_y, gs.mode == .submap);
    const cam_x = cam.x;
    const cam_y = cam.y;
    const fine = gs.scrollFine();
    switch (gs.mode) {
        .overworld => if (gs.ow) |*ow| ow.render(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fine.x, fine.y),
        .submap => {
            if (gs.sub) |*sm| {
                sm.tickAnim(snes_7a);
                sm.clearBackdrop(pixels);
                sm.renderBackground(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fine.x, fine.y);
            }
            if (gs.npcs) |*ns| {
                for (ns.npcs) |n| {
                    if (!n.visible) continue;
                    const hide_lo = if (gs.sub) |*sm| sm.spriteHideLowerBody(n.x, n.y) else false;
                    if (gs.sub) |*sm| {
                        if (sm.spriteFullyHidden(n.x, n.y, gs.party_z)) continue;
                    }
                    const nf = n.moveFine();
                    const sx = (n.x - cam_x) * 16 - fine.x + nf.x;
                    const sy = (n.y - cam_y) * 16 - 2 - fine.y + nf.y;
                    if (sx < -16 or sy < -16 or sx > view_w or sy > view_h) continue;
                    const walk_7a: u8 = if (n.move_dir != 0) snes_7a | 0x08 else snes_7a;
                    npc_mod.blitNpc(pixels, @intCast(view_w), sx, sy, n, walk_7a, hide_lo);
                }
            }
            if (gs.sub) |*sm| {
                if (!sm.spriteFullyHidden(gs.pos_x, gs.pos_y, gs.party_z)) {
                    const hide_lo = sm.spriteHideLowerBody(gs.pos_x, gs.pos_y);
                    party.blit(pixels, @intCast(view_w), 7 * 16, 6 * 16 - 2, gs.drawFacing(), gs.walkFrame(), hide_lo);
                }
                sm.renderForeground(pixels, @intCast(view_w), @intCast(view_h), cam_x, cam_y, fine.x, fine.y);
            }
        },
    }
    if (gs.mode == .overworld and !gs.isMounted() and !gs.player_hidden) {
        // DrawPlayerWorld forest occlusion (prop hi bit3).
        const hide_lo = gs.spriteHideLowerBody(gs.pos_x, gs.pos_y);
        party.blit(pixels, @intCast(view_w), 7 * 16, 6 * 16 - 2, gs.drawFacing(), gs.walkFrame(), hide_lo);
    }
    const ld = gs.leader();
    drawHud(pixels, ld.hp, ld.max_hp, gs.pos_x, gs.pos_y, gs.locationLabel(), gs.msgSlice(), gs.mode == .submap, gs.map_id);
    applyScreenMosaic(pixels, gs.mosaicBlockSize());
    applyScreenWipe(pixels, gs);
    applyScreenFade(pixels, gs.display_brightness);
    if (gs.flash_frames > 0) applyScreenFlash(pixels);
    if (gs.dlg_open) ui_gfx.drawDialogue(pixels, @intCast(view_w), @intCast(view_h), gs.dlgSlice(), gs.dlg_page);
    _ = c.SDL_UpdateTexture(texture, null, pixels.ptr, view_w * 4);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_RenderTexture(renderer, texture, null, null);
    _ = c.SDL_RenderPresent(renderer);
}

/// STT → Gemma (in-process) → Kokoro (in-process) → show dialogue + play WAV.
fn runVoiceTurn(
    io: std.Io,
    gpa: std.mem.Allocator,
    gs: *game_state.GameState,
    repo_root: []const u8,
    llm: *ai_local.Llm,
    tts: *ai_local.Tts,
    samples: []const i16,
    audio: *audio_mod.Audio,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    pixels: []u8,
    party: *sprites_mod.SpriteSheet,
    snes_7a: u8,
    ui_gfx: *const ui_mod.UiGfx,
) !void {
    std.log.info("audio: voice turn begin ({d} samples, ~{d} ms)", .{
        samples.len,
        samples.len * 1000 / 16000,
    });
    audio.keepAlive();

    if (samples.len < 16000 / 4) {
        std.log.warn("audio: utterance too short ({d} samples)", .{samples.len});
        gs.setMsg("Too short — try again");
        return;
    }

    const wav_in = "/tmp/ff4_mic.wav";
    try ai_local.writeWav(wav_in, samples, 16000);
    audio.keepAlive();

    // Pump BGM on a side thread while STT/LLM/Kokoro block this thread.
    audio.startBgPump();
    defer audio.stopBgPump();

    const paths = ai_local.Paths{ .root = repo_root };
    gs.setMsg("Hearing...");
    presentHudFrame(renderer, texture, pixels, gs, party, snes_7a, ui_gfx);
    const transcript = ai_local.transcribe(gpa, io, paths, wav_in) catch |err| {
        std.log.err("audio: STT error: {s}", .{@errorName(err)});
        gs.setMsg("STT failed");
        return err;
    };
    defer gpa.free(transcript);

    if (transcript.len == 0) {
        std.log.warn("audio: empty transcript — no TTS", .{});
        gs.setMsg("Didn't catch that");
        return;
    }

    var heard: [64]u8 = undefined;
    const hm = std.fmt.bufPrint(&heard, "You: {s}", .{transcript}) catch "You: ...";
    gs.setMsg(hm);
    presentHudFrame(renderer, texture, pixels, gs, party, snes_7a, ui_gfx);

    gs.setMsg("Thinking...");
    presentHudFrame(renderer, texture, pixels, gs, party, snes_7a, ui_gfx);
    const out = gs.voiceTalk(gpa, io, repo_root, llm, tts, transcript) catch |err| {
        std.log.err("audio: voiceTalk error: {s}", .{@errorName(err)});
        // Prefer the state message ("That can't talk." / "Nobody there.") when set.
        if (err == error.NotASpeaker) {
            if (gs.msgSlice().len == 0) gs.setMsg("That can't talk.");
            return err;
        }
        if (err == error.NoNpc) {
            if (gs.msgSlice().len == 0) gs.setMsg("Nobody there.");
            return err;
        }
        gs.setMsg("Reply failed");
        return err;
    };
    defer gpa.free(out.wav_path);

    std.log.info("audio: NPC reply ready → {s}", .{out.wav_path});

    // Open dialogue, queue speech, return to the game loop.
    // Speech drains via audio.pump() each frame — music + input stay live.
    if (gs.dlg_len > 0) {
        gs.openVoiceDlg();
        gs.setMsg("");
    } else {
        gs.setMsg("Speaking...");
    }
    presentHudFrame(renderer, texture, pixels, gs, party, snes_7a, ui_gfx);

    audio.playNpcSpeech(out.wav_path) catch |err| {
        std.log.warn("audio: TTS queue failed ({s}): {s} — paplay fallback", .{ out.wav_path, @errorName(err) });
        // Blocking fallback only if mix queue failed.
        audio.playWavSystem(io, out.wav_path) catch |err2| {
            std.log.warn("audio: TTS paplay failed: {s}", .{@errorName(err2)});
            gs.setMsg("TTS play failed");
        };
    };
    audio.resyncClock();
    // Do not wait for speech — caller clears voice_busy and the main loop
    // handles confirm/escape/dialogue while tts_q drains.
}

fn putPixel(pixels: []u8, x: i32, y: i32, r: u8, g: u8, b: u8) void {
    if (x < 0 or y < 0 or x >= view_w or y >= view_h) return;
    const o: usize = @intCast((y * view_w + x) * 4);
    pixels[o] = r;
    pixels[o + 1] = g;
    pixels[o + 2] = b;
    pixels[o + 3] = 255;
}

fn fillRect(pixels: []u8, x: i32, y: i32, w: i32, h: i32, r: u8, g: u8, b: u8) void {
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) putPixel(pixels, x + dx, y + dy, r, g, b);
    }
}

/// EventCmd_d2 / wipe mosaic — block-pixelate the whole framebuffer (hMOSAIC size nibble).
fn applyScreenMosaic(pixels: []u8, block: u8) void {
    if (block <= 1) return;
    const mos: i32 = block;
    var by: i32 = 0;
    while (by < view_h) : (by += mos) {
        var bx: i32 = 0;
        while (bx < view_w) : (bx += mos) {
            const so: usize = @intCast((by * view_w + bx) * 4);
            if (so + 3 >= pixels.len) continue;
            const r = pixels[so];
            const g = pixels[so + 1];
            const b = pixels[so + 2];
            var py: i32 = by;
            while (py < by + mos and py < view_h) : (py += 1) {
                var px: i32 = bx;
                while (px < bx + mos and px < view_w) : (px += 1) {
                    const o: usize = @intCast((py * view_w + px) * 4);
                    if (o + 3 >= pixels.len) continue;
                    pixels[o] = r;
                    pixels[o + 1] = g;
                    pixels[o + 2] = b;
                }
            }
        }
    }
}

/// EventCmd_d1 flash — invert RGB (ROM TfrInvertPal for 2 vblanks).
fn applyScreenFlash(pixels: []u8) void {
    var o: usize = 0;
    while (o + 3 < pixels.len) : (o += 4) {
        pixels[o] = 255 -% pixels[o];
        pixels[o + 1] = 255 -% pixels[o + 1];
        pixels[o + 2] = 255 -% pixels[o + 2];
    }
}

/// Scale framebuffer toward black for INIDISP brightness 0..15 (EventCmd_da).
fn applyScreenFade(pixels: []u8, brightness: u8) void {
    if (brightness >= 15) return;
    if (brightness == 0) {
        @memset(pixels, 0);
        var i: usize = 3;
        while (i < pixels.len) : (i += 4) pixels[i] = 255;
        return;
    }
    var o: usize = 0;
    while (o + 3 < pixels.len) : (o += 4) {
        pixels[o] = @intCast(@as(u16, pixels[o]) * brightness / 15);
        pixels[o + 1] = @intCast(@as(u16, pixels[o + 1]) * brightness / 15);
        pixels[o + 2] = @intCast(@as(u16, pixels[o + 2]) * brightness / 15);
    }
}

/// EventCmd_fe screen wipe — iris window + mosaic pixelation.
/// field.asm WipeOut/WipeIn, WipeScanlineTbl, UpdateWipeNMI ($0677 → hMOSAIC).
fn applyScreenWipe(pixels: []u8, gs: *const game_state.GameState) void {
    if (!gs.isWiping()) return;
    const half = gs.wipeWindowHalf();
    const cx: i32 = view_w / 2;
    const cy: i32 = view_h / 2;
    const hx: i32 = half.x;
    const hy: i32 = half.y;
    const x0: i32 = @max(cx - hx, 0);
    const x1: i32 = @min(cx + hx, view_w);
    const y0: i32 = @max(cy - hy, 0);
    const y1: i32 = @min(cy + hy, view_h);

    // Mosaic size from wipe step: ($79 >> 1) << 4 | 3 → size nibble = step/2 (field.asm @9204).
    // SNES mosaic block size is (size+1) pixels; we sample that block's top-left.
    const mos: i32 = @as(i32, gs.wipe_step >> 1) + 1; // 1..16

    // Pixelate the visible iris, then black outside (window + forced blank).
    // Work bottom-up/right so we can read original block origins after writes… use a
    // two-pass: first mosaic inside the rect, then black the exterior.
    if (mos > 1 and x1 > x0 and y1 > y0) {
        var by: i32 = y0;
        while (by < y1) : (by += mos) {
            var bx: i32 = x0;
            while (bx < x1) : (bx += mos) {
                const so: usize = @intCast((by * view_w + bx) * 4);
                if (so + 3 >= pixels.len) continue;
                const r = pixels[so];
                const g = pixels[so + 1];
                const b = pixels[so + 2];
                var py: i32 = by;
                while (py < by + mos and py < y1) : (py += 1) {
                    var px: i32 = bx;
                    while (px < bx + mos and px < x1) : (px += 1) {
                        const o: usize = @intCast((py * view_w + px) * 4);
                        if (o + 3 >= pixels.len) continue;
                        pixels[o] = r;
                        pixels[o + 1] = g;
                        pixels[o + 2] = b;
                        pixels[o + 3] = 255;
                    }
                }
            }
        }
    }

    var y: i32 = 0;
    while (y < view_h) : (y += 1) {
        var x: i32 = 0;
        while (x < view_w) : (x += 1) {
            if (x >= x0 and x < x1 and y >= y0 and y < y1) continue;
            const o: usize = @intCast((y * view_w + x) * 4);
            if (o + 3 >= pixels.len) continue;
            pixels[o] = 0;
            pixels[o + 1] = 0;
            pixels[o + 2] = 0;
            pixels[o + 3] = 255;
        }
    }
}

/// DrawWhirlpool (special.asm @d2ae) + ShiftWhirlpoolPal (@d30a).
/// 4×4 large sprites from WhirlpoolSpriteTbl; pal rotates every 4 frames.
fn drawWhirlpool(
    pixels: []u8,
    dest_w: usize,
    base_x: i32,
    base_y: i32,
    snes_7a: u8,
    vs: *const vehicle_mod.VehicleSprites,
) void {
    // `$79` advances when `$7a&3==0` → phase ≈ `$7a>>2` mod 6.
    var pal: [8]snes.Color = undefined;
    vehicle_mod.shiftWhirlpoolPal(snes_7a >> 2, &pal);
    // ROM walks $0c,$0e in 16px steps: col 0,16,32,48 then next row.
    var i: usize = 0;
    var col: i32 = 0;
    var row: i32 = 0;
    while (i < vehicle_mod.whirlpool_sprite_tbl.len) : (i += 1) {
        const e = vehicle_mod.whirlpool_sprite_tbl[i];
        const tile = e[0];
        const attr = e[1];
        const hflip = (attr & 0x40) != 0;
        const vflip = (attr & 0x80) != 0;
        const ox = base_x + col;
        const oy = base_y + row;
        // 16×16 large sprite = 4× 8×8 (t, t+1, t+16, t+17)
        const names = [_]u8{ tile, tile +% 1, tile +% 16, tile +% 17 };
        const qxy = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 8 }, .{ .x = 8, .y = 8 },
        };
        for (names, qxy) |nm, q| {
            var qx = q.x;
            var qy = q.y;
            if (hflip) qx = 8 - q.x;
            if (vflip) qy = 8 - q.y;
            vehicle_mod.blitVehicleTilePal(vs, pixels, dest_w, ox + qx, oy + qy, nm, hflip, &pal);
        }
        col += 0x10;
        if (col >= 0x40) {
            col = 0;
            row += 0x10;
        }
    }
}

/// Crushing corridor: black bars close in from top/bottom (BG2 VOFS stand-in).
fn drawCrushingCorridor(pixels: []u8, dw: usize, dh: usize, gap: i32) void {
    const g = @max(8, @min(@as(i32, @intCast(dh)), gap * 4));
    const mid: i32 = @intCast(dh / 2);
    const top = mid - @divTrunc(g, 2);
    const bot = mid + @divTrunc(g, 2);
    var y: i32 = 0;
    while (y < @as(i32, @intCast(dh))) : (y += 1) {
        if (y >= top and y < bot) continue;
        var x: i32 = 0;
        while (x < @as(i32, @intCast(dw))) : (x += 1) {
            const o: usize = @intCast((y * @as(i32, @intCast(dw)) + x) * 4);
            if (o + 3 >= pixels.len) continue;
            pixels[o] = 0;
            pixels[o + 1] = 0;
            pixels[o + 2] = 0;
            pixels[o + 3] = 255;
        }
    }
}

/// ProphecyPal-ish blue wash (field_data.asm @f996) — tint framebuffer during prophecy FX.
fn applyProphecyWash(pixels: []u8, snes_7a: u8) void {
    // Ramp intensity from `$7a` — deep blue overlay.
    const t: u8 = @truncate((snes_7a & 0x1F) + 8);
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        // Blend toward blue-black: keep some original, boost blue channel.
        const r = pixels[i];
        const g = pixels[i + 1];
        const b = pixels[i + 2];
        pixels[i] = @intCast((@as(u16, r) * 3 + t) / 5);
        pixels[i + 1] = @intCast((@as(u16, g) * 3 + t / 2) / 5);
        pixels[i + 2] = @intCast(@min(255, (@as(u16, b) * 2 + 80 + t) / 3));
    }
}

/// Special_34 telescope window — TelescopeWindowData HDMA geometry (earth_moon.telescopeWindowLR).
fn applyTelescopeWindow(pixels: []u8, dw: usize, dh: usize) void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(dh))) : (y += 1) {
        const wr = earth_moon_mod.telescopeWindowLR(y, @intCast(dh));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(dw))) : (x += 1) {
            // Window: show only when left ≤ x < right (SNES WH0/WH1 clip).
            if (x >= wr.l and x < wr.r) continue;
            const o: usize = @intCast((y * @as(i32, @intCast(dw)) + x) * 4);
            if (o + 3 >= pixels.len) continue;
            pixels[o] = 0;
            pixels[o + 1] = 0;
            pixels[o + 2] = 0;
            pixels[o + 3] = 255;
        }
    }
}

/// InvertPal (pal_anim.asm @c6d5): per CGRAM word `eor #$7fff / and #$7bde / lsr`.
fn applyMapInvert(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r5: u16 = pixels[i] >> 3;
        const g5: u16 = pixels[i + 1] >> 3;
        const b5: u16 = pixels[i + 2] >> 3;
        var w: u16 = r5 | (g5 << 5) | (b5 << 10);
        w ^= 0x7FFF;
        w &= 0x7BDE;
        w >>= 1;
        const r2: u5 = @truncate(w);
        const g2: u5 = @truncate(w >> 5);
        const b2: u5 = @truncate(w >> 10);
        // Expand 5-bit → 8-bit (same as Color.fromSnes).
        pixels[i] = @as(u8, r2) << 3 | @as(u8, r2) >> 2;
        pixels[i + 1] = @as(u8, g2) << 3 | @as(u8, g2) >> 2;
        pixels[i + 2] = @as(u8, b2) << 3 | @as(u8, b2) >> 2;
    }
}

/// ShowVehicleSmoke / UpdateExplosions — DrawExplosion CHR on ExplosionPosTbl.
fn drawVehicleSmoke(
    pixels: []u8,
    cx: i32,
    cy: i32,
    smoke_timer: u16,
    snes_7a: u8,
    vs: *const vehicle_mod.VehicleSprites,
) void {
    drawUpdateExplosions(pixels, cx, cy, smoke_timer, snes_7a, 16, false, vs);
}

/// UpdateExplosions (special.asm @e0b7) — `$0a6d` slots ×4, stage `$0a6d` 0..3 / $ff idle.
/// Host synthesizes slots from ExplosionPosTbl + smoke countdown (`$0ad2` ≈ cinema_smoke).
fn drawUpdateExplosions(
    pixels: []u8,
    cx: i32,
    cy: i32,
    smoke_timer: u16,
    snes_7a: u8,
    slot_count: usize,
    sand: bool,
    vs: *const vehicle_mod.VehicleSprites,
) void {
    // `$0ad2` countdown $40→0; explosions active while nonzero.
    if (smoke_timer == 0) return;
    const remain: i32 = @intCast(@min(smoke_timer, 0x40));
    // Stage from `_00e1b4`: 0..3 cycling every 8 fields (`$7a&7` advances `$0a6d`).
    const stage: u8 = @truncate((@as(u8, @intCast(0x40 -% @min(remain, 0x40))) / 8) & 3);
    const n = @min(slot_count, 16);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Init slots $ff,$fe,$fd… — skip until age makes stage ≥ 0.
        // Slot age offset: first 4 start staggered by 1.
        const slot_delay: i32 = @intCast(i & 3);
        if (remain > 0x38 - slot_delay) continue; // not yet spawned
        const ex: i32 = vehicle_mod.explosion_pos_tbl[i * 2];
        const ey: i32 = vehicle_mod.explosion_pos_tbl[i * 2 + 1];
        // Random offset uses `$0ad0`/`$0ad1` masks in ROM; host uses `$7a`-derived jitter.
        const jx: i32 = @as(i32, (snes_7a +% @as(u8, @truncate(i *% 3))) & 0x0B) - 5;
        const jy: i32 = @as(i32, (snes_7a *% 3 +% @as(u8, @truncate(i))) & 0x0B) - 5;
        const px = cx + ex + jx;
        const py = cy + ey + jy;
        const st: u8 = stage +% @as(u8, @truncate(i & 3));
        vehicle_mod.blitExplosion(vs, pixels, view_w, px, py, st % 4, sand);
    }
}

/// Giant body OAM layout `_14f58e` (field_data.asm @f58e) — 6 × (dx,dy,tile,attr).
/// Tile names are absolute vehicle sheet; attr `$15` (palette / priority). Second
/// table `@f5a6` is hflip mirror; host draws facing-left layout only.
fn drawGiantBody(pixels: []u8, dest_w: usize, base_x: i32, base_y: i32, vs: *const vehicle_mod.VehicleSprites) void {
    // Exact bytes from `_14f58e`:
    const ents = [_]struct { x: i32, y: i32, tile: u8, hflip: bool }{
        .{ .x = 0x00, .y = 0x00, .tile = 0x38, .hflip = false },
        .{ .x = 0x10, .y = 0x00, .tile = 0x3A, .hflip = false },
        .{ .x = 0x00, .y = 0x10, .tile = 0x3C, .hflip = false },
        .{ .x = 0x10, .y = 0x10, .tile = 0x3E, .hflip = false },
        .{ .x = 0x00, .y = 0x20, .tile = 0x50, .hflip = false },
        .{ .x = 0x10, .y = 0x20, .tile = 0x52, .hflip = false },
    };
    for (ents) |e| {
        // Each large sprite = 4 consecutive 8×8 names (t, t+1, t+16, t+17) typical SNES 16².
        const ox = base_x + e.x - 8;
        const oy = base_y + e.y - 16;
        const names = [_]u8{ e.tile, e.tile +% 1, e.tile +% 16, e.tile +% 17 };
        const qxy = [_]struct { x: i32, y: i32 }{
            .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 8 }, .{ .x = 8, .y = 8 },
        };
        for (names, qxy) |nm, q| {
            if (nm >= vehicle_mod.vehicle_tile_count_pub) continue;
            vehicle_mod.blitVehicleTile(vs, pixels, dest_w, ox + q.x, oy + q.y, nm, e.hflip);
        }
    }
}

fn fillDisk(pixels: []u8, cx: i32, cy: i32, radius: i32, r: u8, g: u8, b: u8) void {
    if (radius <= 0) return;
    const r2 = radius *% radius;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx *% dx +% dy *% dy > r2) continue;
            const x = cx + dx;
            const y = cy + dy;
            if (x < 0 or y < 0 or x >= view_w or y >= view_h) continue;
            const o = (@as(usize, @intCast(y)) * view_w + @as(usize, @intCast(x))) * 4;
            if (o + 3 >= pixels.len) continue;
            pixels[o] = r;
            pixels[o + 1] = g;
            pixels[o + 2] = b;
            pixels[o + 3] = 255;
        }
    }
}

fn drawChar(pixels: []u8, x: i32, y: i32, ch: u8, r: u8, g: u8, b: u8) void {
    const glyph: u15 = switch (ch) {
        '0' => 0b111_101_101_101_111,
        '1' => 0b010_110_010_010_111,
        '2' => 0b111_001_111_100_111,
        '3' => 0b111_001_111_001_111,
        '4' => 0b101_101_111_001_001,
        '5' => 0b111_100_111_001_111,
        '6' => 0b111_100_111_101_111,
        '7' => 0b111_001_001_001_001,
        '8' => 0b111_101_111_101_111,
        '9' => 0b111_101_111_001_111,
        'A' => 0b010_101_111_101_101,
        'B' => 0b110_101_110_101_110,
        'C' => 0b011_100_100_100_011,
        'D' => 0b110_101_101_101_110,
        'E' => 0b111_100_110_100_111,
        'F' => 0b111_100_110_100_100,
        'G' => 0b011_100_101_101_011,
        'H' => 0b101_101_111_101_101,
        'I' => 0b111_010_010_010_111,
        'J' => 0b001_001_001_101_010,
        'K' => 0b101_101_110_101_101,
        'L' => 0b100_100_100_100_111,
        'M' => 0b101_111_111_101_101,
        'N' => 0b101_111_111_111_101,
        'O' => 0b010_101_101_101_010,
        'P' => 0b110_101_110_100_100,
        'Q' => 0b010_101_101_111_011,
        'R' => 0b110_101_110_101_101,
        'S' => 0b011_100_010_001_110,
        'T' => 0b111_010_010_010_010,
        'U' => 0b101_101_101_101_111,
        'V' => 0b101_101_101_101_010,
        'W' => 0b101_101_111_111_101,
        'X' => 0b101_101_010_101_101,
        'Y' => 0b101_101_010_010_010,
        'Z' => 0b111_001_010_100_111,
        '!' => 0b010_010_010_000_010,
        '+' => 0b000_010_111_010_000,
        '-' => 0b000_000_111_000_000,
        ' ' => 0,
        ':' => 0b000_010_000_010_000,
        '/' => 0b001_001_010_100_100,
        '\'' => 0b010_010_000_000_000,
        '.' => 0b000_000_000_000_010,
        ',' => 0b000_000_000_010_100,
        '?' => 0b111_001_010_000_010,
        else => 0b111_101_111_101_111,
    };
    var row: i32 = 0;
    while (row < 5) : (row += 1) {
        var col: i32 = 0;
        while (col < 3) : (col += 1) {
            const bit: u4 = @intCast(14 - (row * 3 + col));
            if ((glyph >> bit) & 1 != 0) putPixel(pixels, x + col, y + row, r, g, b);
        }
    }
}

/// PlayMapSong (field.asm): vehicle song if `$1704!=0`, else world / sub-map.
fn playFieldSong(audio: *audio_mod.Audio, gs: *const game_state.GameState, last: *u8) void {
    const song: u8 = blk: {
        if (gs.vehicle != 0 and gs.vehicle < audio_mod.vehicle_songs.len) {
            break :blk audio_mod.vehicle_songs[gs.vehicle];
        }
        break :blk switch (gs.mode) {
            .overworld => brk: {
                const w = gs.world_id;
                if (w < audio_mod.world_songs.len) break :brk audio_mod.world_songs[w];
                break :brk audio_mod.world_songs[0];
            },
            .submap => if (gs.sub) |*sm| sm.prop.song else 0,
        };
    };
    if (song == 0 or song == last.*) return;
    audio.playSong(song);
    last.* = song;
}

fn drawText(pixels: []u8, x: i32, y: i32, text: []const u8, r: u8, g: u8, b: u8) void {
    var cx = x;
    for (text) |ch| {
        const up = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        drawChar(pixels, cx, y, up, r, g, b);
        cx += 4;
    }
}

fn drawHud(
    pixels: []u8,
    hp: u16,
    mhp: u16,
    x: i32,
    y: i32,
    place: []const u8,
    status: []const u8,
    indoor: bool,
    map_id: u16,
) void {
    // Top-left: HP + coords + always-on place name (not overwritten by Listening/etc.).
    fillRect(pixels, 4, 4, 180, 36, 0, 0, 0);
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "HP {d}/{d}", .{ hp, mhp }) catch return;
    drawText(pixels, 6, 6, s, 100, 255, 100);
    const tag = if (indoor) "IN" else "OW";
    const s2 = if (indoor)
        (std.fmt.bufPrint(&buf, "{s}#{d} X{d} Y{d}", .{ tag, map_id, x, y }) catch return)
    else
        (std.fmt.bufPrint(&buf, "{s} X{d} Y{d}", .{ tag, x, y }) catch return);
    drawText(pixels, 6, 14, s2, 180, 180, 200);
    // Truncate long names to fit HUD
    const place_show = if (place.len > 28) place[0..28] else place;
    drawText(pixels, 6, 22, place_show, 255, 220, 120);
    if (status.len > 0) {
        // Don't re-draw place name as the bottom banner if it's the same as location.
        if (!std.mem.eql(u8, status, place)) {
            fillRect(pixels, 4, view_h - 14, view_w - 8, 10, 0, 0, 0);
            drawText(pixels, 6, view_h - 12, status, 255, 255, 180);
        }
    }
}

fn drawCentered(pixels: []u8, text: []const u8) void {
    fillRect(pixels, 0, 0, view_w, view_h, 20, 0, 0);
    const tw: i32 = @intCast(text.len * 4);
    drawText(pixels, @divTrunc(view_w - tw, 2), 110, text, 255, 80, 80);
}
