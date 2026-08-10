//! Local STT / LLM / TTS — Gemma (libllama ROCm) + Kokoro (PyTorch ROCm worker).
//!
//!   Mic WAV  →  vendor/whisper/whisper-cli              →  text
//!   text     →  libllama (GPU, kept warm)               →  reply
//!   reply    →  kokoro_rocm_worker.py (PyTorch ROCm)    →  WAV
const std = @import("std");
const Io = std.Io;
const voice_profile = @import("voice_profile.zig");
const lore = @import("lore.zig");
const npc_mod = @import("../map/npc.zig");

const c = @cImport({
    @cInclude("ai/llm_host.h");
    @cInclude("ai/tts_host.h");
});

pub const Paths = struct {
    root: []const u8,
    llm_model: []const u8 = "models/llm/gemma-4-E2B-it-Q4_0.gguf",
    whisper_cli: []const u8 = "vendor/whisper/whisper-cli",
    whisper_model: []const u8 = "models/whisper/ggml-base.en.bin",
    /// Directory with model.onnx, voices.bin, tokens.txt, espeak-ng-data/.
    kokoro_dir: []const u8 = "models/kokoro-en-v0_19",
    // Legacy Piper paths kept so old download scripts / docs stay valid.
    piper_bin: []const u8 = "vendor/piper/piper",
    piper_lib: []const u8 = "vendor/piper",
    piper_voices: []const u8 = "models/piper/voices",

    pub fn resolve(self: Paths, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(rel)) return try allocator.dupe(u8, rel);
        return std.fs.path.join(allocator, &.{ self.root, rel });
    }
};

/// In-process LLM handle (model stays resident).
pub const Llm = struct {
    ptr: ?*c.Ff4Llm = null,

    pub fn deinit(self: *Llm) void {
        if (self.ptr) |p| {
            c.ff4_llm_destroy(p);
            self.ptr = null;
        }
    }

    pub fn ok(self: *const Llm) bool {
        return self.ptr != null and c.ff4_llm_ok(self.ptr) != 0;
    }

    pub fn backendInfo(self: *const Llm) []const u8 {
        if (self.ptr == null) return "not loaded";
        return std.mem.span(c.ff4_llm_backend_info(self.ptr));
    }

    /// Load GGUF with GPU offload. `progress` is 0..1 stage string for UI.
    pub fn load(
        self: *Llm,
        paths: Paths,
        progress: ?*const fn (f32, []const u8, ?*anyopaque) void,
        user: ?*anyopaque,
    ) !void {
        self.deinit();
        const model = try paths.resolve(std.heap.page_allocator, paths.llm_model);
        defer std.heap.page_allocator.free(model);

        const model_z = try std.heap.page_allocator.dupeZ(u8, model);
        defer std.heap.page_allocator.free(model_z);

        g_progress_fn = progress;
        g_progress_user = user;
        self.ptr = c.ff4_llm_create(model_z.ptr, cProgressBridge, null);
        g_progress_fn = null;
        g_progress_user = null;

        if (self.ptr == null or c.ff4_llm_ok(self.ptr) == 0) return error.LlmLoadFailed;
    }

    pub fn generate(self: *Llm, allocator: std.mem.Allocator, system: []const u8, user_msg: []const u8) ![]u8 {
        if (!self.ok()) return error.LlmNotReady;
        var out_buf: [1024]u8 = undefined;
        const sys_z = try allocator.dupeZ(u8, system);
        defer allocator.free(sys_z);
        const user_z = try allocator.dupeZ(u8, user_msg);
        defer allocator.free(user_z);
        // Keep replies short — long budgets encourage monologue loops on small models.
        const n = c.ff4_llm_generate(self.ptr, sys_z.ptr, user_z.ptr, &out_buf, out_buf.len, 64);
        if (n < 0) return error.LlmGenerateFailed;
        return try allocator.dupe(u8, out_buf[0..@intCast(n)]);
    }
};

var g_progress_fn: ?*const fn (f32, []const u8, ?*anyopaque) void = null;
var g_progress_user: ?*anyopaque = null;

fn cProgressBridge(progress: f32, stage: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = user;
    if (g_progress_fn) |f| {
        const s = if (stage != null) std.mem.span(stage) else "Loading";
        f(progress, s, g_progress_user);
    }
    return 1;
}

/// In-process Kokoro TTS handle (model stays resident after load).
pub const Tts = struct {
    ptr: ?*c.Ff4Tts = null,

    pub fn deinit(self: *Tts) void {
        if (self.ptr) |p| {
            c.ff4_tts_destroy(p);
            self.ptr = null;
        }
    }

    pub fn ok(self: *const Tts) bool {
        return self.ptr != null and c.ff4_tts_ok(self.ptr) != 0;
    }

    pub fn info(self: *const Tts) []const u8 {
        if (self.ptr == null) return "not loaded";
        return std.mem.span(c.ff4_tts_info(self.ptr));
    }

    pub fn load(self: *Tts, paths: Paths) !void {
        self.deinit();
        const dir = try paths.resolve(std.heap.page_allocator, paths.kokoro_dir);
        defer std.heap.page_allocator.free(dir);
        const dir_z = try std.heap.page_allocator.dupeZ(u8, dir);
        defer std.heap.page_allocator.free(dir_z);
        self.ptr = c.ff4_tts_create(dir_z.ptr);
        if (self.ptr == null or c.ff4_tts_ok(self.ptr) == 0) return error.TtsLoadFailed;
        std.log.info("audio: TTS ready — {s}", .{self.info()});
    }

    pub fn synthesize(
        self: *Tts,
        profile: voice_profile.VoiceProfile,
        text: []const u8,
        out_wav: []const u8,
    ) !void {
        if (!self.ok()) return error.TtsNotReady;

        // Sanitize to printable ASCII + spaces (Kokoro is English-focused).
        var clean_buf: [2048]u8 = undefined;
        var n: usize = 0;
        for (text) |ch| {
            if (n + 1 >= clean_buf.len) break;
            if (ch == '\n' or ch == '\r' or ch == '\t') {
                clean_buf[n] = ' ';
                n += 1;
            } else if (ch >= 32 and ch < 127) {
                clean_buf[n] = ch;
                n += 1;
            }
        }
        // Trim trailing spaces.
        while (n > 0 and clean_buf[n - 1] == ' ') n -= 1;
        if (n == 0) return error.TtsFailed;

        const text_z = try std.heap.page_allocator.dupeZ(u8, clean_buf[0..n]);
        defer std.heap.page_allocator.free(text_z);
        const wav_z = try std.heap.page_allocator.dupeZ(u8, out_wav);
        defer std.heap.page_allocator.free(wav_z);

        const rc = c.ff4_tts_synthesize(
            self.ptr,
            text_z.ptr,
            @intCast(profile.speaker),
            profile.speed,
            wav_z.ptr,
        );
        if (rc != 0) return error.TtsFailed;
        if (!fileExists(out_wav)) return error.TtsFailed;
    }
};

pub const TalkRequest = struct {
    npc: npc_mod.Npc,
    map_id: u16,
    canon_line: []const u8 = "",
    player_text: []const u8,
    /// Prior turns with this same NPC ("Player: …\nYou: …\n") for follow-ups.
    chat_history: []const u8 = "",
    /// Event switch bytes for story-phase gating (spoilers).
    event_switch: []const u8 = &.{},
    on_overworld: bool = false,
    world_x: i32 = 0,
    world_y: i32 = 0,
    /// Key-item possession for story phase (inventory).
    keys: lore.KeyBits = .{},
    /// Party leader + companions (Cecil's rank, etc.).
    party: lore.PartySnapshot = .{},
    /// Other NPCs' ROM dialogue on this map (authoritative local voice).
    map_chatter: []const u8 = "",
    /// Repo root for loading data/lore/excerpts/*.txt script dumps.
    repo_root: []const u8 = ".",
};

pub const TalkResult = struct {
    reply: []u8,
    wav_path: []u8,
    profile_model: []const u8,
    speaker: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TalkResult) void {
        self.allocator.free(self.reply);
        self.allocator.free(self.wav_path);
        self.* = undefined;
    }
};

/// Transcribe 16-bit PCM WAV with whisper.cpp.
pub fn transcribe(allocator: std.mem.Allocator, io: Io, paths: Paths, wav_path: []const u8) ![]u8 {
    const whisper = try paths.resolve(allocator, paths.whisper_cli);
    defer allocator.free(whisper);
    const model = try paths.resolve(allocator, paths.whisper_model);
    defer allocator.free(model);
    const whisper_dir = std.fs.path.dirname(whisper) orelse ".";

    if (!fileExists(whisper)) {
        std.log.err("audio: whisper binary missing: {s}", .{whisper});
        return error.WhisperMissing;
    }
    if (!fileExists(model)) {
        std.log.err("audio: whisper model missing: {s}", .{model});
        return error.WhisperMissing;
    }

    const prev_ld = if (std.c.getenv("LD_LIBRARY_PATH")) |p| std.mem.span(p) else "";
    // Shared libs live under whisper-bin-ubuntu-x64 (symlink target of whisper-cli).
    const bin_dir = try paths.resolve(allocator, "vendor/whisper/whisper-bin-ubuntu-x64");
    defer allocator.free(bin_dir);
    const ld = try std.fmt.allocPrint(allocator, "LD_LIBRARY_PATH={s}:{s}:{s}", .{ bin_dir, whisper_dir, prev_ld });
    defer allocator.free(ld);

    // -nt = no timestamps, -np = results only on stdout.
    // --prompt biases decoding toward FF4 place/person names (Mysidia, Baron, …).
    var argv = [_][]const u8{
        "env",    ld,
        whisper,  "-m",     model,
        "-f",     wav_path,
        "-nt",    "-np",    "-l",   "en",
        "--prompt", lore.stt_initial_prompt,
    };

    std.log.info("audio: STT start ({s})", .{wav_path});
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| {
        std.log.err("audio: whisper spawn/run failed: {s}", .{@errorName(err)});
        return error.WhisperMissing;
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const ok_exit = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok_exit) {
        const tail = if (result.stderr.len > 400) result.stderr[result.stderr.len - 400 ..] else result.stderr;
        std.log.err("audio: whisper failed term={any} stderr_tail={s}", .{ result.term, tail });
        return error.WhisperFailed;
    }

    var text = try cleanTranscript(allocator, result.stdout);
    if (text.len == 0) {
        // Some builds put the only line on stderr; try scraping that too.
        const alt = try cleanTranscript(allocator, result.stderr);
        allocator.free(text);
        if (alt.len == 0) {
            std.log.warn("audio: STT empty (stdout_len={d} stderr_len={d})", .{ result.stdout.len, result.stderr.len });
            return alt;
        }
        text = alt;
    }

    // Lexicon fixups for stubborn mishearings (after Whisper prompt bias).
    const fixed = try lore.fixupSttTranscript(allocator, text);
    allocator.free(text);
    std.log.info("audio: STT ok: \"{s}\"", .{fixed});
    return fixed;
}

fn cleanTranscript(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        // Skip whisper diagnostics
        if (std.mem.startsWith(u8, t, "whisper_")) continue;
        if (std.mem.startsWith(u8, t, "system_info")) continue;
        if (std.mem.startsWith(u8, t, "main:")) continue;
        if (std.mem.startsWith(u8, t, "ggml_")) continue;
        if (std.mem.startsWith(u8, t, "read_audio")) continue;
        if (std.mem.startsWith(u8, t, "load:")) continue;
        // Timestamp lines like [00:00.000 --> 00:01.000] text
        if (std.mem.startsWith(u8, t, "[")) {
            if (std.mem.indexOf(u8, t, "]")) |br| {
                t = std.mem.trim(u8, t[br + 1 ..], " \t");
                if (t.len == 0) continue;
            } else continue;
        }
        if (list.items.len > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, t);
    }
    const joined = try list.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, joined, " \t\"'");
    if (trimmed.len == 0) {
        allocator.free(joined);
        return try allocator.dupe(u8, "");
    }
    if (trimmed.ptr == joined.ptr and trimmed.len == joined.len) return joined;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(joined);
    return out;
}

/// Generate in-character NPC reply with in-process Gemma (libllama).
pub fn generateReply(allocator: std.mem.Allocator, io: Io, llm: *Llm, req: TalkRequest) ![]u8 {
    const profile = voice_profile.profileForDialogue(req.npc, req.map_id, req.canon_line);

    const phase = lore.storyPhase(req.event_switch, req.keys);
    const place = lore.placeFromMapId(req.map_id);

    // Real US SNES script slice for this place/arc (from data/lore/excerpts/).
    var script_excerpt: []const u8 = "";
    var script_owned: ?[]u8 = null;
    defer if (script_owned) |s| allocator.free(s);
    if (lore.excerptRelPath(phase, place.name)) |rel| {
        const loaded = lore.loadExcerpt(allocator, io, req.repo_root, rel, 2400);
        if (loaded.len > 0) {
            script_owned = loaded;
            script_excerpt = loaded;
        }
    }

    // Card = ROM map chatter + script dump + place/phase facts (not invented greeter rules).
    var lore_buf: [5600]u8 = undefined;
    const lore_card = lore.formatNpcCard(
        &lore_buf,
        req.map_id,
        req.on_overworld,
        req.world_x,
        req.world_y,
        req.event_switch,
        req.keys,
        req.party,
        req.map_chatter,
        script_excerpt,
    );

    var sys_buf: [7168]u8 = undefined;
    const sys = voice_profile.systemPrompt(profile, req.map_id, req.canon_line, lore_card, &sys_buf);

    var user_buf: [2560]u8 = undefined;
    const user = blk: {
        if (req.chat_history.len > 0) {
            break :blk std.fmt.bufPrint(&user_buf,
                \\=== ALREADY SAID (do not repeat these lines or rephrase them as a new answer) ===
                \\{s}
                \\=== END ===
                \\
                \\Player now says: {s}
                \\
                \\Respond with NEW wording that answers this turn only.
                \\Obey the PIN. Stay in your role. If you do not know, say so in character.
                \\1–2 short sentences. No recycled salutes/greetings from history.
            , .{ req.chat_history, req.player_text }) catch req.player_text;
        } else {
            break :blk std.fmt.bufPrint(&user_buf,
                \\Player says: {s}
                \\
                \\Answer in character (PIN first). 1–2 short sentences of NEW dialogue — not a stock greeter loop.
                \\If PIN is CASTLE BARON and Cecil leads: you know him (Captain/sir); military tone, not shopkeep.
                \\Only facts from your role + LOCAL KNOWLEDGE. Places are places, not people.
            , .{req.player_text}) catch req.player_text;
        }
    };

    std.log.info("audio: lore map={d} phase={s} card={d}B hist={d}B script={d}B chatter={d}B", .{
        req.map_id,
        @tagName(phase),
        lore_card.len,
        req.chat_history.len,
        script_excerpt.len,
        req.map_chatter.len,
    });
    return llm.generate(allocator, sys, user);
}

fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.c.close(fd);
    return true;
}

/// Full voice turn: player text → reply + wav path in /tmp.
/// Uses in-process Kokoro when `tts` is loaded.
pub fn voiceTalk(
    allocator: std.mem.Allocator,
    io: Io,
    paths: Paths,
    llm: *Llm,
    tts: *Tts,
    req: TalkRequest,
) !TalkResult {
    _ = paths; // TTS is preloaded; STT still uses Paths elsewhere.
    const profile = voice_profile.profileForDialogue(req.npc, req.map_id, req.canon_line);
    const reply = try generateReply(allocator, io, llm, req);
    errdefer allocator.free(reply);

    const wav_path = try std.fmt.allocPrint(allocator, "/tmp/ff4_npc_{d}_{d}.wav", .{ req.npc.prop_gfx, req.map_id });
    errdefer allocator.free(wav_path);

    std.log.info("audio: LLM reply ({d} chars): \"{s}\"", .{ reply.len, reply[0..@min(reply.len, 80)] });
    std.log.info("audio: voice profile sheet={d} gender={s} model={s} spk={d} speed={d:.2}", .{
        req.npc.sheet_id,
        switch (profile.gender) {
            .male => "male",
            .female => "female",
            .unknown => "unknown",
        },
        profile.model,
        profile.speaker,
        profile.speed,
    });
    std.log.info("audio: Kokoro (in-process) → {s}", .{wav_path});
    tts.synthesize(profile, reply, wav_path) catch |err| {
        std.log.err("audio: Kokoro failed: {s}", .{@errorName(err)});
        return err;
    };
    if (!fileExists(wav_path)) {
        std.log.err("audio: Kokoro produced no file {s}", .{wav_path});
        return error.TtsFailed;
    }

    return .{
        .reply = reply,
        .wav_path = wav_path,
        .profile_model = profile.model,
        .speaker = profile.speaker,
        .allocator = allocator,
    };
}

/// Write mono s16le WAV (for mic capture).
pub fn writeWav(path: []const u8, samples: []const i16, sample_rate: u32) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    const data_bytes: u32 = @intCast(samples.len * 2);
    const sr = sample_rate;
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_bytes, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], 1, .little);
    std.mem.writeInt(u32, hdr[24..28], sr, .little);
    std.mem.writeInt(u32, hdr[28..32], sr * 2, .little);
    std.mem.writeInt(u16, hdr[32..34], 2, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_bytes, .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, std.mem.sliceAsBytes(samples));
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}
