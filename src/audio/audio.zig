//! Game audio: PipeWire (`pw-cat`) output + FF4 APU host (snes_spc) + TTS mix.
//!
//! SDL playback is silent on Bluetooth HFP/HSP duplex (AirPods after mic open).
//! `paplay` / `pw-cat` work on that same sink — so BGM is raw s16le stereo
//! written to `pw-cat --playback` stdin. Capture stays on `pw-record` (mic_pw).
const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("audio/host.h");
});

/// Output format for the shared playback stream (pw-cat resamples to the sink).
pub const out_rate: u32 = 32000;
pub const out_channels: u32 = 2;

pub const Audio = struct {
    host: ?*c.Ff4Audio = null,
    /// Live `pw-cat --playback` process; stdin receives interleaved s16 stereo.
    pw: ?std.process.Child = null,
    enabled: bool = false,
    /// Scratch for pulling APU samples into the stream.
    scratch: []i16 = &.{},
    /// Unsent PCM after a partial write / EAGAIN. APU+TTS only advance when
    /// samples enter this buffer; they are never dropped on a failed write.
    pending: []i16 = &.{},
    pending_off: usize = 0,
    pending_len: usize = 0,
    /// Queued TTS as interleaved stereo s16 @ out_rate (mixed over BGM).
    tts_q: std.ArrayList(i16) = .empty,
    tts_pos: usize = 0,
    /// True from playMonoS16 until TTS samples are fully mixed *and* flushed.
    tts_hold: bool = false,
    /// When true, main pw-cat stream carries TTS only (APU advanced but muted).
    tts_solo: bool = false,
    allocator: std.mem.Allocator = undefined,
    io: Io = undefined,
    /// Wall-clock pacing so we never write faster than realtime into pw-cat
    /// (blocking fill during GGUF load hung the whole boot thread).
    last_pump_ns: u64 = 0,
    /// Lead buffer we try to keep ahead of wall clock (ms).
    lead_ms: i32 = 150,
    /// Don't thrash-rebind pw-cat more than once per second.
    last_rebind_ns: u64 = 0,
    /// BGM scale: out = bgm * num / den. Default half volume so dialogue/SFX cut through.
    bgm_gain_num: i32 = 1,
    bgm_gain_den: i32 = 2,
    /// Background pump thread keeps BGM alive during STT/LLM/Piper (main thread blocked).
    pump_mutex: Io.Mutex = .init,
    pump_thread: ?std.Thread = null,
    pump_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(io: Io, gpa: std.mem.Allocator, rom_data: []const u8) !Audio {
        var self: Audio = .{
            .allocator = gpa,
            .io = io,
            .scratch = try gpa.alloc(i16, 4096),
            .pending = try gpa.alloc(i16, 4096),
            .tts_q = .empty,
            .pump_run = std.atomic.Value(bool).init(false),
        };
        errdefer self.deinit();

        self.host = c.ff4_audio_create(rom_data.ptr, rom_data.len);
        if (self.host == null) {
            std.log.warn("ff4_audio_create failed", .{});
            return self;
        }
        if (c.ff4_audio_init(self.host) != 0) {
            std.log.warn("ff4_audio_init (SPC boot) failed", .{});
            c.ff4_audio_destroy(self.host);
            self.host = null;
            return self;
        }

        if (!self.openPlayback()) {
            std.log.warn("audio: pw-cat playback open failed", .{});
            return self;
        }
        std.log.info("audio: SPC booted, BGM via pw-cat @ {d} Hz stereo", .{out_rate});
        return self;
    }

    /// Start (or restart) `pw-cat` writing to the default PipeWire sink.
    fn openPlayback(self: *Audio) bool {
        self.closePlayback();

        var argv = [_][]const u8{
            "pw-cat",
            "--playback",
            "--raw",
            "--rate",       "32000",
            "--channels",   "2",
            "--format",     "s16",
            "--latency",    "80ms",
            "--media-role", "Game",
            "-",
        };
        self.pw = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.log.warn("pw-cat spawn failed: {s}", .{@errorName(err)});
            return false;
        };
        // Non-blocking stdin so a full pipe never freezes GGUF load / the game loop.
        if (self.pw.?.stdin) |*stdin| {
            const fd = stdin.handle;
            // Linux: F_GETFL=3, F_SETFL=4, O_NONBLOCK=0o4000
            const flags = std.c.fcntl(fd, 3);
            if (flags >= 0) _ = std.c.fcntl(fd, 4, flags | 0o4000);
            stdin.flags.nonblocking = true;
        }
        self.enabled = true;
        self.pending_off = 0;
        self.pending_len = 0;
        self.last_pump_ns = c.SDL_GetTicksNS();
        // Prime a small lead so music starts without waiting a full buffer.
        _ = self.writeMs(self.lead_ms);
        std.log.info("audio: playback → pw-cat (PipeWire default sink)", .{});
        return true;
    }

    fn closePlayback(self: *Audio) void {
        if (self.pw) |*ch| {
            if (ch.stdin) |f| {
                f.close(self.io);
                ch.stdin = null;
            }
            // kill() waits/reaps; do not wait() again.
            if (ch.id != null) ch.kill(self.io);
            self.pw = null;
        }
        self.enabled = false;
        self.pending_off = 0;
        self.pending_len = 0;
    }

    pub fn deinit(self: *Audio) void {
        self.stopBgPump();
        self.closePlayback();
        if (self.host) |h| {
            c.ff4_audio_destroy(h);
            self.host = null;
        }
        if (self.scratch.len != 0) {
            self.allocator.free(self.scratch);
            self.scratch = &.{};
        }
        if (self.pending.len != 0) {
            self.allocator.free(self.pending);
            self.pending = &.{};
        }
        self.tts_q.deinit(self.allocator);
    }

    /// After a long blocking call (STT/LLM), snap the pacing clock so we don't
    /// try to "catch up" by racing the APU (that caused 2× music + silent TTS).
    pub fn resyncClock(self: *Audio) void {
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        self.last_pump_ns = c.SDL_GetTicksNS();
    }

    /// Run BGM pumping on a side thread while the main thread does STT/LLM/Piper.
    /// Stop before playNpcSpeech (that path takes the mutex for exclusive write).
    pub fn startBgPump(self: *Audio) void {
        if (!self.enabled) return;
        if (self.pump_run.load(.acquire)) return;
        self.pump_run.store(true, .release);
        self.pump_thread = std.Thread.spawn(.{}, bgPumpMain, .{self}) catch |err| {
            self.pump_run.store(false, .release);
            std.log.warn("audio: bg pump thread failed: {s}", .{@errorName(err)});
            return;
        };
        std.log.info("audio: bg pump started (BGM during AI)", .{});
    }

    pub fn stopBgPump(self: *Audio) void {
        if (!self.pump_run.load(.acquire) and self.pump_thread == null) return;
        self.pump_run.store(false, .release);
        if (self.pump_thread) |t| {
            t.join();
            self.pump_thread = null;
        }
        std.log.info("audio: bg pump stopped", .{});
    }

    fn bgPumpMain(self: *Audio) void {
        while (self.pump_run.load(.acquire)) {
            self.pump_mutex.lockUncancelable(self.io);
            self.pumpRealtimeUnlocked();
            self.pump_mutex.unlock(self.io);
            c.SDL_Delay(8);
        }
    }

    /// Restart pw-cat (e.g. after a sink profile change). Safe to call often.
    /// Does not pump — caller should keepAlive() after a successful rebind.
    pub fn rebindPlayback(self: *Audio) bool {
        if (!self.openPlayback()) {
            std.log.warn("audio rebind: pw-cat open failed", .{});
            return false;
        }
        return true;
    }

    /// Set pw-cat stdin blocking/non-blocking.
    fn setPipeBlocking(self: *Audio, blocking: bool) void {
        const ch = if (self.pw) |*child| child else return;
        const stdin_ptr = if (ch.stdin) |*s| s else return;
        const fd = stdin_ptr.handle;
        const flags = std.c.fcntl(fd, 3); // F_GETFL
        if (flags < 0) return;
        if (blocking) {
            _ = std.c.fcntl(fd, 4, flags & ~@as(c_int, 0o4000)); // clear O_NONBLOCK
            stdin_ptr.flags.nonblocking = false;
        } else {
            _ = std.c.fcntl(fd, 4, flags | 0o4000);
            stdin_ptr.flags.nonblocking = true;
        }
    }

    /// Queue NPC speech to mix under BGM. Non-blocking: returns immediately;
    /// the main loop (or bg pump) drains `tts_q` via `pump()` so music and
    /// gameplay stay live while they talk.
    pub fn playNpcSpeech(self: *Audio, path: []const u8) !void {
        if (!self.enabled or self.pw == null) return error.AudioDisabled;
        // AI bg pump owns the stream during STT/LLM — take it back for the game loop.
        self.stopBgPump();
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);

        try self.playWavPath(path);
        if (self.tts_q.items.len == 0) return error.AudioDisabled;

        // Always mix with BGM (never solo-mute music).
        self.tts_solo = false;
        self.last_pump_ns = c.SDL_GetTicksNS();

        const frames = self.tts_q.items.len / out_channels;
        const dur_ms = @divTrunc(frames * 1000, out_rate);
        std.log.info("audio: NPC speech queued {d} ms (mixed with BGM) ({s})", .{ dur_ms, path });
    }

    /// True while mixed TTS still has samples to play.
    pub fn speechPlaying(self: *const Audio) bool {
        return self.ttsPlaying();
    }

    /// Cut NPC speech immediately (e.g. player dismissed the dialogue box).
    /// Music continues; only the TTS queue and any pending mixed chunk are cleared.
    pub fn stopSpeech(self: *Audio) void {
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        self.tts_q.clearRetainingCapacity();
        self.tts_pos = 0;
        self.tts_hold = false;
        self.tts_solo = false;
        // Drop unsent mixed audio so a half-mixed speech chunk doesn't linger.
        self.pending_off = 0;
        self.pending_len = 0;
        std.log.info("audio: NPC speech stopped (dialogue dismissed)", .{});
    }

    /// Blocking flush of pending (used when pipe is in blocking mode).
    fn flushPendingBlocking(self: *Audio) i32 {
        if (self.pending_off >= self.pending_len) return 0;
        const stdin = if (self.pw) |*ch| ch.stdin orelse return -1 else return -1;
        const bytes = std.mem.sliceAsBytes(self.pending[self.pending_off..self.pending_len]);
        stdin.writeStreamingAll(self.io, bytes) catch return -1;
        const n = self.pending_len - self.pending_off;
        self.pending_off = 0;
        self.pending_len = 0;
        return samplesToMs(n);
    }

    /// Legacy side-channel player (fallback only).
    pub fn playWavSystem(self: *Audio, io: Io, path: []const u8) !void {
        var argv = [_][]const u8{ "paplay", path };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch blk: {
            var argv2 = [_][]const u8{ "pw-cat", "--playback", path };
            break :blk try std.process.spawn(io, .{
                .argv = &argv2,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
        };
        const prev_n = self.bgm_gain_num;
        const prev_d = self.bgm_gain_den;
        self.bgm_gain_num = 1;
        self.bgm_gain_den = 20;
        defer {
            self.bgm_gain_num = prev_n;
            self.bgm_gain_den = prev_d;
        }
        // Blocking wait — BGM may underrun; speech is the priority.
        self.pumpTo(100);
        const term = try child.wait(io);
        self.resyncClock();
        if (term != .exited or term.exited != 0) return error.SystemPlayFailed;
    }

    pub fn playSong(self: *Audio, song_id: u8) void {
        if (!self.enabled or self.host == null) return;
        c.ff4_audio_play_song(self.host, song_id);
    }

    pub fn playSfx(self: *Audio, sfx_id: u8) void {
        if (!self.enabled or self.host == null) return;
        c.ff4_audio_play_sfx(self.host, sfx_id);
    }

    /// System SFX $10..$1E (cursor move $14, confirm $13, error $12).
    pub fn playSystemSfx(self: *Audio, sfx_id: u8) void {
        if (!self.enabled or self.host == null) return;
        c.ff4_audio_play_system_sfx(self.host, sfx_id);
    }

    pub fn stop(self: *Audio) void {
        if (!self.enabled or self.host == null) return;
        c.ff4_audio_stop(self.host);
    }

    /// Queue mono s16 PCM (any rate) for playback on the main device, mixed over BGM.
    /// Replaces any still-playing TTS.
    pub fn playMonoS16(self: *Audio, mono: []const i16, src_rate: u32) !void {
        if (!self.enabled or self.pw == null or mono.len == 0) return error.AudioDisabled;
        if (src_rate == 0) return error.AudioDisabled;

        self.tts_q.clearRetainingCapacity();
        self.tts_pos = 0;
        self.tts_hold = true;

        // Linear resample mono → stereo @ out_rate.
        const n_out: usize = @as(usize, @intFromFloat(@as(f64, @floatFromInt(mono.len)) * @as(f64, @floatFromInt(out_rate)) / @as(f64, @floatFromInt(src_rate))));
        if (n_out == 0) {
            self.tts_hold = false;
            return error.AudioDisabled;
        }

        try self.tts_q.ensureTotalCapacity(self.allocator, n_out * 2);
        var i: usize = 0;
        while (i < n_out) : (i += 1) {
            const src_f = @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(src_rate)) / @as(f64, @floatFromInt(out_rate));
            const idx0: usize = @intFromFloat(src_f);
            const idx1 = @min(idx0 + 1, mono.len - 1);
            const frac = src_f - @as(f64, @floatFromInt(idx0));
            const s0: f64 = @floatFromInt(mono[idx0]);
            const s1: f64 = @floatFromInt(mono[idx1]);
            const sample: i16 = @intFromFloat(s0 * (1.0 - frac) + s1 * frac);
            // Light boost only — heavy gain clips and sounds metallic/robotic.
            const boosted: i32 = @divTrunc(@as(i32, sample) * 5, 4); // 1.25×
            const clamped: i16 = @intCast(std.math.clamp(boosted, -32768, 32767));
            try self.tts_q.append(self.allocator, clamped);
            try self.tts_q.append(self.allocator, clamped);
        }
        // Peak for diagnostics (silent WAVs / failed decode).
        var peak: i32 = 0;
        for (mono) |s| {
            const a: i32 = if (s < 0) -@as(i32, s) else s;
            peak = @max(peak, a);
        }
        std.log.info("audio: queued TTS {d} mono @ {d} Hz → {d} stereo frames (peak={d})", .{ mono.len, src_rate, n_out, peak });
        if (peak < 200) std.log.warn("audio: TTS peak very low — may be inaudible", .{});
    }

    /// True while mixed TTS is still draining (queue or unsent mixed PCM).
    pub fn ttsPlaying(self: *const Audio) bool {
        return self.tts_hold;
    }

    fn updateTtsHold(self: *Audio) void {
        if (!self.tts_hold) return;
        if (self.tts_pos < self.tts_q.items.len) return;
        if (self.pending_off < self.pending_len) return;
        self.tts_hold = false;
    }

    /// Load a PCM WAV (mono or stereo s16) and queue for playback. Scans for `data` chunk.
    pub fn playWavPath(self: *Audio, path: []const u8) !void {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.c.close(fd);

        // Read whole file (TTS clips are small).
        var file_buf: std.ArrayList(u8) = .empty;
        defer file_buf.deinit(self.allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = try std.posix.read(fd, &tmp);
            if (n == 0) break;
            try file_buf.appendSlice(self.allocator, tmp[0..n]);
        }
        const data = file_buf.items;
        if (data.len < 44) return error.BadWav;
        if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.BadWav;

        var channels: u16 = 1;
        var rate: u32 = 22050;
        var bits: u16 = 16;
        var pcm_off: ?usize = null;
        var pcm_len: usize = 0;

        var pos: usize = 12;
        while (pos + 8 <= data.len) {
            const id = data[pos .. pos + 4];
            const chunk_sz = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const body = pos + 8;
            if (body + chunk_sz > data.len) break;
            if (std.mem.eql(u8, id, "fmt ") and chunk_sz >= 16) {
                channels = std.mem.readInt(u16, data[body + 2 ..][0..2], .little);
                rate = std.mem.readInt(u32, data[body + 4 ..][0..4], .little);
                bits = std.mem.readInt(u16, data[body + 14 ..][0..2], .little);
            } else if (std.mem.eql(u8, id, "data")) {
                pcm_off = body;
                pcm_len = chunk_sz;
                break;
            }
            pos = body + chunk_sz + (chunk_sz & 1); // word-align
        }

        const off = pcm_off orelse return error.BadWav;
        if (bits != 16) return error.BadWav;
        if (channels != 1 and channels != 2) return error.BadWav;

        const n_samp = pcm_len / 2;
        const pcm_bytes = data[off .. off + pcm_len];
        // Copy to aligned buffer (WAV body may be unaligned).
        const samples = try self.allocator.alloc(i16, n_samp);
        defer self.allocator.free(samples);
        var si: usize = 0;
        while (si < n_samp) : (si += 1) {
            samples[si] = std.mem.readInt(i16, pcm_bytes[si * 2 ..][0..2], .little);
        }

        if (channels == 1) {
            try self.playMonoS16(samples, rate);
        } else {
            // Downmix stereo → mono then resample
            const mono = try self.allocator.alloc(i16, n_samp / 2);
            defer self.allocator.free(mono);
            var i: usize = 0;
            while (i < mono.len) : (i += 1) {
                const l: i32 = samples[i * 2];
                const r: i32 = samples[i * 2 + 1];
                mono[i] = @intCast(@divTrunc(l + r, 2));
            }
            try self.playMonoS16(mono, rate);
        }
    }

    /// Block until TTS queue is drained (keeps BGM+voice pumping on pw-cat).
    pub fn waitTts(self: *Audio) void {
        if (!self.enabled) return;
        // STT/LLM may have stalled the pacing clock for seconds — snap so we
        // play voice in realtime instead of dumping the whole clip at once.
        self.resyncClock();
        while (self.ttsPlaying()) {
            self.pumpRealtime();
            c.SDL_Delay(8);
        }
        // Small tail so the last phoneme isn't cut by an underrun.
        self.pumpRealtime();
        c.SDL_Delay(40);
        self.pumpRealtime();
    }

    /// Keep BGM flowing during a long blocking call (GGUF load, STT, LLM).
    /// Only writes audio matching wall-clock elapsed time + a small lead —
    /// never floods the pipe (that used to hang boot on "Loading GGUF").
    pub fn keepAlive(self: *Audio) void {
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        self.pumpRealtimeUnlocked();
    }

    /// Write up to `target_ms` of mixed APU(+TTS) audio (best-effort, non-blocking).
    pub fn pumpTo(self: *Audio, target_ms: i32) void {
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        const wrote = self.writeMs(target_ms);
        if (wrote > 0) {
            self.last_pump_ns +%= @as(u64, @intCast(wrote)) * std.time.ns_per_ms;
        }
    }

    /// Pump APU (+ TTS) → pw-cat paced to wall clock. Call once per frame.
    pub fn pump(self: *Audio) void {
        // Skip if bg pump owns the stream (avoid double-write races).
        if (self.pump_run.load(.acquire)) return;
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        self.pumpRealtimeUnlocked();
    }

    fn pumpRealtime(self: *Audio) void {
        self.pump_mutex.lockUncancelable(self.io);
        defer self.pump_mutex.unlock(self.io);
        self.pumpRealtimeUnlocked();
    }

    /// Catch up audio to now + lead_ms without ever blocking the caller for long.
    /// Caller must hold pump_mutex.
    fn pumpRealtimeUnlocked(self: *Audio) void {
        if (!self.enabled or self.pw == null) return;
        const now = c.SDL_GetTicksNS();
        if (self.last_pump_ns == 0) {
            self.last_pump_ns = now;
            _ = self.writeMs(self.lead_ms);
            return;
        }

        // Always try to finish any unsent PCM first (even if we're "ahead").
        {
            const flushed = self.flushPending();
            if (flushed > 0) {
                self.last_pump_ns +%= @as(u64, @intCast(flushed)) * std.time.ns_per_ms;
            } else if (flushed < 0) {
                self.tryRebind();
                return;
            }
            self.updateTtsHold();
            // Still holding unsent audio — don't render more APU/TTS this tick.
            if (self.pending_off < self.pending_len) return;
        }

        // Target: keep `lead_ms` of audio queued ahead of wall clock.
        const lead_ns: u64 = @as(u64, @intCast(self.lead_ms)) * std.time.ns_per_ms;
        const target = now +% lead_ns;
        if (self.last_pump_ns >= target) return;

        const need_ns = target -% self.last_pump_ns;
        // Cap catch-up so a long stall doesn't render huge APU runs in one frame.
        const need_ms: i32 = @intCast(@min(need_ns / std.time.ns_per_ms, 40));
        if (need_ms < 5) return;

        const wrote = self.writeMs(need_ms);
        if (wrote > 0) {
            self.last_pump_ns +%= @as(u64, @intCast(wrote)) * std.time.ns_per_ms;
            if (self.last_pump_ns > target) self.last_pump_ns = target;
        }
    }

    fn tryRebind(self: *Audio) void {
        const now = c.SDL_GetTicksNS();
        if (now -% self.last_rebind_ns <= std.time.ns_per_s) return;
        self.last_rebind_ns = now;
        _ = self.openPlayback();
    }

    /// Render and write up to `ms` of audio in chunks. Returns ms actually written.
    fn writeMs(self: *Audio, ms: i32) i32 {
        if (!self.enabled or self.pw == null or ms <= 0) return 0;
        var remaining = ms;
        var written: i32 = 0;
        var guard: u32 = 0;
        while (remaining > 0 and guard < 32) : (guard += 1) {
            const chunk: i32 = @min(remaining, 20);
            const n = self.pumpOnceMs(chunk);
            if (n < 0) {
                self.tryRebind();
                return written;
            }
            if (n == 0) break; // pipe full — pending holds unsent PCM
            written += n;
            remaining -= n;
        }
        return written;
    }

    /// Samples → milliseconds @ out_rate stereo.
    fn samplesToMs(n_samp: usize) i32 {
        if (n_samp == 0) return 0;
        const ms = @divTrunc(
            @as(i32, @intCast(n_samp)) * 1000,
            @as(i32, @intCast(out_rate * out_channels)),
        );
        return @max(ms, 1);
    }

    /// Non-blocking write of pending[pending_off..pending_len].
    /// Returns ms written, 0 if nothing/EAGAIN, -1 if pipe dead.
    fn flushPending(self: *Audio) i32 {
        if (self.pending_off >= self.pending_len) return 0;
        const stdin = if (self.pw) |*ch| ch.stdin orelse return -1 else return -1;

        const bytes = std.mem.sliceAsBytes(self.pending[self.pending_off..self.pending_len]);
        const n = std.c.write(stdin.handle, bytes.ptr, bytes.len);
        if (n < 0) {
            const e = std.posix.errno(@as(isize, -1));
            if (e == .AGAIN) return 0;
            if (e == .PIPE or e == .CONNRESET) return -1;
            return 0;
        }
        if (n == 0) return 0;
        // Only whole samples (2 bytes); leave an odd trailing byte unconsumed.
        const wrote: usize = @as(usize, @intCast(n)) & ~@as(usize, 1);
        if (wrote == 0) return 0;
        const samp_wrote = wrote / 2;
        self.pending_off += samp_wrote;
        if (self.pending_off >= self.pending_len) {
            self.pending_off = 0;
            self.pending_len = 0;
        }
        return samplesToMs(samp_wrote);
    }

    /// Render `ms` of audio into pending (if empty), then flush.
    /// Returns ms written this call, 0 if pipe full, -1 if pipe dead.
    /// Critical: APU/TTS only advance when filling pending; failed writes never
    /// drop rendered samples (that caused silent TTS + permanent 2× music).
    fn pumpOnceMs(self: *Audio, ms: i32) i32 {
        if (!self.enabled or self.pw == null) return -1;

        // Finish previous chunk before rendering more.
        if (self.pending_off < self.pending_len) {
            return self.flushPending();
        }

        var need_samples: i32 = @divTrunc(
            @as(i32, @intCast(out_rate)) * @as(i32, @intCast(out_channels)) * ms,
            1000,
        );
        if (need_samples < 64) need_samples = 64;
        if (need_samples & 1 != 0) need_samples += 1;
        if (need_samples > @as(i32, @intCast(self.scratch.len))) {
            need_samples = @intCast(self.scratch.len & ~@as(usize, 1));
        }
        if (need_samples > @as(i32, @intCast(self.pending.len))) {
            need_samples = @intCast(self.pending.len & ~@as(usize, 1));
        }

        // APU fill (silence if no host)
        if (self.host) |h| {
            c.ff4_audio_render(h, self.scratch.ptr, need_samples);
        } else {
            @memset(std.mem.sliceAsBytes(self.scratch[0..@intCast(need_samples)]), 0);
        }

        // Apply global BGM gain (ducked while system TTS player runs).
        if (self.bgm_gain_num != self.bgm_gain_den) {
            const n_g: usize = @intCast(need_samples);
            var gi: usize = 0;
            while (gi < n_g) : (gi += 1) {
                const v: i32 = @divTrunc(@as(i32, self.scratch[gi]) * self.bgm_gain_num, self.bgm_gain_den);
                self.scratch[gi] = @intCast(std.math.clamp(v, -32768, 32767));
            }
        }

        // Mix speech over BGM (music stays audible ~50% under voice).
        if (self.tts_pos < self.tts_q.items.len) {
            const n_mix: usize = @intCast(need_samples);
            var i: usize = 0;
            while (i < n_mix and self.tts_pos < self.tts_q.items.len) : (i += 1) {
                const voice: i32 = self.tts_q.items[self.tts_pos];
                self.tts_pos += 1;
                const bgm: i32 = @divTrunc(@as(i32, self.scratch[i]) * 1, 2);
                self.scratch[i] = @intCast(std.math.clamp(bgm + voice, -32768, 32767));
            }
        }

        // Commit to pending — only now is APU/TTS "spent".
        @memcpy(self.pending[0..@intCast(need_samples)], self.scratch[0..@intCast(need_samples)]);
        self.pending_len = @intCast(need_samples);
        self.pending_off = 0;

        const n = self.flushPending();
        self.updateTtsHold();
        return n;
    }
};

/// World map songs (field.asm WorldSongTbl).
pub const world_songs = [_]u8{ 0x0D, 0x06, 0x31 };

/// Vehicle songs (field.asm VehicleSongTbl) — index by `$1704`.
/// ROM table is 7 bytes (0–6); ship `$07` reuses whale theme.
pub const vehicle_songs = [_]u8{ 0x0D, 0x04, 0x05, 0x0D, 0x18, 0x18, 0x0E, 0x0E };

/// Title / prelude song.
pub const song_prelude: u8 = 0x15;

/// BattleSongTbl (battle_data.asm @ff0c) — index from BattleProp byte6 bits 2–3.
pub const battle_song_tbl = [_]u8{ 0x27, 0x1A, 0x0B };
/// bits==3 → no battle music (keep field song).
pub const battle_song_none: u8 = 0xFF;

/// Common game SFX (ExecSound cmd $02) from decomp call sites.
pub const sfx_door: u8 = 0x45;
pub const sfx_poison: u8 = 0x7A;
pub const sfx_floor_dmg: u8 = 0x7B;
pub const sfx_weapon_hit: u8 = 0x2A; // WeaponHitAnim (btlgfx/weapon.asm)
/// Field battle zoom/blur enter — BattleWorld/BattleSub `lda #$3f` / PlaySfx.
pub const sfx_battle_enter: u8 = 0x3F;

/// System SFX (ExecSound port0 = id, sound.asm $10..$1E).
pub const sys_sfx_cursor_field: u8 = 0x11;
pub const sys_sfx_error: u8 = 0x12;
pub const sys_sfx_confirm: u8 = 0x13; // CancelConfirmSfx
pub const sys_sfx_cursor_move: u8 = 0x14; // CursorMoveSfx2

/// Song id from BattleProp.battle_flags ($29a2 / $38e5 bits 2–3).
pub fn battleSongId(battle_flags: u8) u8 {
    const idx = (battle_flags >> 2) & 3;
    if (idx >= 3) return battle_song_none;
    return battle_song_tbl[idx];
}
