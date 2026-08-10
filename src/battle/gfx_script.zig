//! Battle graphics script buffer ($33c2) — btlgfx ExecGfxScript / DoGfxScriptCmd.
//!
//! Decomp: `btlgfx/btlgfx.asm` `@bef0` ExecGfxScript, `@c8a7` DoGfxScriptCmd,
//! `GfxScriptCmdTbl` @c8bb.
//!
//! Token ranges (ExecGfxScript @bf4f):
//!   $00–$A8  magic animation → DoMagicAnim
//!   $A9–$BF  special animation → DoSpecialAnim_near
//!   $C0–$E7  command animation → DoCmdAnim
//!   $E8–$EF  unused → UnusedGfxScriptCmd2 (consume next byte)
//!   $F0–$FE  DoGfxScriptCmd jump table
//!   $FF      end of script
//!
//! F-range (GfxScriptCmdTbl):
//!   $F0  change boss frame (param: ss_gggggg slot + frame)
//!   $F1  battle dialogue slowest speed + BattleDlg id
//!   $F2  battle dialogue config speed + id
//!   $F3  play song + id
//!   $F4–$F6  unused (consume param)
//!   $F7  darken/lighten battle BG (param bit7 = lighten)
//!   $F8  ShowMsg + type (0–4)
//!   $F9  unused (consume param)
//!   $FA–$FE  unused (no param)
const std = @import("std");
const battle_dlg = @import("battle_dlg.zig");
const rom_mod = @import("../rom.zig");

/// MsgDurTbl @f800 (btlgfx_data.asm) — 16-bit frame counts per message speed 0–5.
/// WaitMsgAuto: slowest ($F1) forces speed 5; $F2 uses config $16ad.
pub const msg_dur_tbl: [6]u16 = .{ 0x0020, 0x0040, 0x0060, 0x0080, 0x00A0, 0x00C0 };

/// ShowMsg type ($F8 param) — ShowMsgTbl @c99c.
pub const ShowMsgType = enum(u8) {
    attacker_name = 0, // unused in ROM
    target_name = 1, // unused in ROM
    attack_name = 2,
    battle_msg = 3,
    damage_numerals = 4,
};

/// Classified script token (ExecGfxScript ranges).
pub const TokenKind = enum {
    magic_anim, // $00–$A8
    special_anim, // $A9–$BF
    cmd_anim, // $C0–$E7
    unused_param, // $E8–$EF or $F4–$F6 or $F9
    unused_nop, // $FA–$FE
    boss_frame, // $F0
    dialogue, // $F1 / $F2
    song, // $F3
    darken_bg, // $F7
    show_msg, // $F8
    end, // $FF
};

pub const Effect = union(enum) {
    end,
    /// DoMagicAnim id ($00–$A8).
    magic_anim: u8,
    /// DoSpecialAnim id ($A9–$BF).
    special_anim: u8,
    /// DoCmdAnim id ($C0–$E7); table index = id − $C0.
    cmd_anim: u8,
    /// $F0 ChangeBossFrame: monster slot (bits 6–7) + frame id (bits 0–5).
    boss_frame: struct { mon_slot: u8, frame: u8 },
    dialogue: struct { id: u8, slow: bool },
    song: u8,
    /// $F7: bit7 set → lighten, else darken.
    darken_bg: struct { lighten: bool },
    show_msg: ShowMsgType,
    /// Consumed unused command (no host side-effect).
    skipped: u8,
};

/// Classify one script byte — pure ExecGfxScript @bf4f ranges.
pub fn classify(b: u8) TokenKind {
    if (b == 0xFF) return .end;
    if (b < 0xA9) return .magic_anim;
    if (b < 0xC0) return .special_anim;
    if (b < 0xE8) return .cmd_anim;
    if (b < 0xF0) return .unused_param;
    return switch (b) {
        0xF0 => .boss_frame,
        0xF1, 0xF2 => .dialogue,
        0xF3 => .song,
        0xF4, 0xF5, 0xF6, 0xF9 => .unused_param,
        0xF7 => .darken_bg,
        0xF8 => .show_msg,
        else => .unused_nop, // $FA–$FE
    };
}

/// Decode $F0 param: ssgggggg → slot (0–3) + frame (0–63). ChangeBossFrame @cca8.
pub fn decodeBossFrameParam(p: u8) struct { mon_slot: u8, frame: u8 } {
    return .{
        .mon_slot = p >> 6,
        .frame = p & 0x3F,
    };
}

/// Message hold frames for dialogue: slowest → speed 5 ($00C0), else config speed index 0–5.
pub fn dialogueWaitFrames(slow: bool, config_speed: u8) u16 {
    if (slow) return msg_dur_tbl[5];
    const i = @min(config_speed, 5);
    return msg_dur_tbl[i];
}

/// Multi-frame graphics script runner (ExecGfxScript state).
/// Host steps `tick` once per field; waits use MsgDurTbl / fixed anim holds.
pub const Vm = struct {
    /// Script bytes (typically WRAM $33c2 mirror).
    script: []const u8 = &.{},
    /// Byte index into script ($3f pointer).
    pc: usize = 0,
    /// Frames remaining before next opcode (WaitX / WaitMsgAuto).
    wait: u16 = 0,
    done: bool = true,
    /// Last side-effects for host paint (boss frames per mon slot 0–3).
    boss_frame: [4]u8 = .{0xFF} ** 4,
    song_id: ?u8 = null,
    darken: bool = false,
    lighten: bool = false,

    pub fn start(self: *Vm, script: []const u8) void {
        self.* = .{
            .script = script,
            .pc = 0,
            .wait = 0,
            .done = script.len == 0,
            .boss_frame = .{0xFF} ** 4,
            .song_id = null,
            .darken = false,
            .lighten = false,
        };
        if (script.len == 0) self.done = true;
    }

    pub fn active(self: *const Vm) bool {
        return !self.done;
    }

    /// Advance one field. Returns the effect applied this tick (or null while waiting / idle).
    /// Matches ExecGfxScript: process one token, then GetNextGfxScriptByte loop —
    /// long waits (dialogue) are multi-tick on host.
    pub fn tick(self: *Vm, config_msg_speed: u8) ?Effect {
        if (self.done) return null;
        if (self.wait > 0) {
            self.wait -= 1;
            return null;
        }
        if (self.pc >= self.script.len) {
            self.done = true;
            return .end;
        }
        const b = self.script[self.pc];
        self.pc += 1;
        const kind = classify(b);
        switch (kind) {
            .end => {
                self.done = true;
                return .end;
            },
            .magic_anim => {
                // DoMagicAnim runs to completion in ROM; host holds a short present window.
                self.wait = 8;
                return .{ .magic_anim = b };
            },
            .special_anim => {
                self.wait = 8;
                return .{ .special_anim = b };
            },
            .cmd_anim => {
                // DoCmdAnim (step-forward etc.) — host already has fight anim path.
                self.wait = 16;
                return .{ .cmd_anim = b };
            },
            .unused_param => {
                // UnusedGfxScriptCmd2 @c8e9: GetNextGfxScriptByte then rts.
                if (self.pc < self.script.len) self.pc += 1;
                return .{ .skipped = b };
            },
            .unused_nop => {
                return .{ .skipped = b };
            },
            .boss_frame => {
                const p = self.nextByte();
                const df = decodeBossFrameParam(p);
                if (df.mon_slot < 4) self.boss_frame[df.mon_slot] = df.frame;
                return .{ .boss_frame = .{ .mon_slot = df.mon_slot, .frame = df.frame } };
            },
            .dialogue => {
                const id = self.nextByte();
                const slow = b == 0xF1;
                self.wait = dialogueWaitFrames(slow, config_msg_speed);
                return .{ .dialogue = .{ .id = id, .slow = slow } };
            },
            .song => {
                const id = self.nextByte();
                self.song_id = id;
                return .{ .song = id };
            },
            .darken_bg => {
                const p = self.nextByte();
                const lighten = (p & 0x80) != 0;
                if (lighten) {
                    self.lighten = true;
                    self.darken = false;
                } else {
                    self.darken = true;
                    self.lighten = false;
                }
                return .{ .darken_bg = .{ .lighten = lighten } };
            },
            .show_msg => {
                const t = self.nextByte();
                const mt: ShowMsgType = if (t <= 4) @enumFromInt(t) else .battle_msg;
                // Numerals / names: short hold (ShowMsg_04 is draw-only; names wait via WaitMsg).
                self.wait = if (mt == .damage_numerals) 0 else 16;
                return .{ .show_msg = mt };
            },
        }
    }

    fn nextByte(self: *Vm) u8 {
        if (self.pc >= self.script.len) return 0;
        const p = self.script[self.pc];
        self.pc += 1;
        return p;
    }

    /// Drain entire script into `out` (synchronous interpret; no multi-frame waits).
    pub fn runAll(self: *Vm, out: []Effect) usize {
        var n: usize = 0;
        while (!self.done and n < out.len) {
            // Skip waits for bulk decode
            if (self.wait > 0) {
                self.wait = 0;
                continue;
            }
            if (self.tick(5)) |e| {
                out[n] = e;
                n += 1;
                if (e == .end) break;
            } else if (self.done) break;
        }
        return n;
    }
};

/// Run one graphics script buffer; collect effects until $FF or cap.
/// Pure decode (no multi-frame waits) — ExecGfxScript command stream.
pub fn interpret(script: []const u8, out: []Effect) usize {
    var vm: Vm = .{};
    vm.start(script);
    return vm.runAll(out);
}

/// Load BattleDlg text for a dialogue effect (for host message queue).
pub fn dialogueText(r: *const rom_mod.Rom, id: u8, buf: []u8) []const u8 {
    return battle_dlg.load(r, id, buf);
}

// --- tests (decomp ranges + param layout) ---

test "classify ExecGfxScript ranges" {
    try std.testing.expect(classify(0x00) == .magic_anim);
    try std.testing.expect(classify(0xA8) == .magic_anim);
    try std.testing.expect(classify(0xA9) == .special_anim);
    try std.testing.expect(classify(0xBF) == .special_anim);
    try std.testing.expect(classify(0xC0) == .cmd_anim);
    try std.testing.expect(classify(0xE7) == .cmd_anim);
    try std.testing.expect(classify(0xE8) == .unused_param);
    try std.testing.expect(classify(0xEF) == .unused_param);
    try std.testing.expect(classify(0xF0) == .boss_frame);
    try std.testing.expect(classify(0xF1) == .dialogue);
    try std.testing.expect(classify(0xF2) == .dialogue);
    try std.testing.expect(classify(0xF3) == .song);
    try std.testing.expect(classify(0xF7) == .darken_bg);
    try std.testing.expect(classify(0xF8) == .show_msg);
    try std.testing.expect(classify(0xF9) == .unused_param);
    try std.testing.expect(classify(0xFA) == .unused_nop);
    try std.testing.expect(classify(0xFE) == .unused_nop);
    try std.testing.expect(classify(0xFF) == .end);
}

test "decodeBossFrameParam slot and frame" {
    // ChangeBossFrame @cca8: lsr6 = slot, and #$3f = frame
    const a = decodeBossFrameParam(0x03);
    try std.testing.expectEqual(@as(u8, 0), a.mon_slot);
    try std.testing.expectEqual(@as(u8, 3), a.frame);
    const b = decodeBossFrameParam(0x80 | 0x05); // slot 2, frame 5
    try std.testing.expectEqual(@as(u8, 2), b.mon_slot);
    try std.testing.expectEqual(@as(u8, 5), b.frame);
    const c = decodeBossFrameParam(0xC0 | 0x3F); // slot 3, frame 63
    try std.testing.expectEqual(@as(u8, 3), c.mon_slot);
    try std.testing.expectEqual(@as(u8, 0x3F), c.frame);
}

test "interpret F1 dialogue and end" {
    const scr = [_]u8{ 0xF1, 0x00, 0xFF };
    var out: [8]Effect = undefined;
    const n = interpret(&scr, &out);
    try std.testing.expect(n >= 2);
    try std.testing.expect(out[0] == .dialogue);
    try std.testing.expectEqual(@as(u8, 0), out[0].dialogue.id);
    try std.testing.expect(out[0].dialogue.slow);
    try std.testing.expect(out[n - 1] == .end);
}

test "interpret boss frame and song" {
    const scr = [_]u8{ 0xF0, 0x03, 0xF3, 0x1A, 0xFF };
    var out: [8]Effect = undefined;
    const n = interpret(&scr, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(out[0] == .boss_frame);
    try std.testing.expectEqual(@as(u8, 0), out[0].boss_frame.mon_slot);
    try std.testing.expectEqual(@as(u8, 3), out[0].boss_frame.frame);
    try std.testing.expectEqual(@as(u8, 0x1A), out[1].song);
    try std.testing.expect(out[2] == .end);
}

test "interpret magic cmd special and F8 ShowMsg" {
    // Fire-ish magic id, fight cmd anim $C0, ShowMsg_04 numerals, end
    const scr = [_]u8{ 0x10, 0xC0, 0xF8, 0x04, 0xFF };
    var out: [8]Effect = undefined;
    const n = interpret(&scr, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(out[0] == .magic_anim);
    try std.testing.expectEqual(@as(u8, 0x10), out[0].magic_anim);
    try std.testing.expect(out[1] == .cmd_anim);
    try std.testing.expectEqual(@as(u8, 0xC0), out[1].cmd_anim);
    try std.testing.expect(out[2] == .show_msg);
    try std.testing.expect(out[2].show_msg == .damage_numerals);
    try std.testing.expect(out[3] == .end);
}

test "unused F4-F6 consume param; FA no param" {
    const scr = [_]u8{ 0xF4, 0x12, 0xFA, 0xFF };
    var out: [8]Effect = undefined;
    const n = interpret(&scr, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(out[0] == .skipped);
    try std.testing.expect(out[1] == .skipped);
    try std.testing.expect(out[2] == .end);
}

test "F7 darken vs lighten bit7" {
    const dark = [_]u8{ 0xF7, 0x00, 0xFF };
    var out: [4]Effect = undefined;
    _ = interpret(&dark, &out);
    try std.testing.expect(out[0] == .darken_bg);
    try std.testing.expect(!out[0].darken_bg.lighten);

    const light = [_]u8{ 0xF7, 0x80, 0xFF };
    _ = interpret(&light, &out);
    try std.testing.expect(out[0].darken_bg.lighten);
}

test "Vm multi-frame dialogue wait uses MsgDurTbl speed 5" {
    const scr = [_]u8{ 0xF1, 0x02, 0xFF };
    var vm: Vm = .{};
    vm.start(&scr);
    const e = vm.tick(0); // config ignored for slow
    try std.testing.expect(e != null);
    try std.testing.expect(e.? == .dialogue);
    try std.testing.expectEqual(msg_dur_tbl[5], vm.wait);
    // Wait down without advancing pc past end
    var frames: u16 = 0;
    while (vm.wait > 0) : (frames += 1) {
        _ = vm.tick(0);
    }
    try std.testing.expectEqual(msg_dur_tbl[5], frames);
    const end_e = vm.tick(0);
    try std.testing.expect(end_e != null);
    try std.testing.expect(end_e.? == .end);
    try std.testing.expect(vm.done);
}

test "Vm boss_frame state and song_id" {
    const scr = [_]u8{ 0xF0, 0x85, 0xF3, 0x0B, 0xFF }; // slot 2 frame 5
    var vm: Vm = .{};
    vm.start(&scr);
    _ = vm.tick(0);
    try std.testing.expectEqual(@as(u8, 5), vm.boss_frame[2]);
    _ = vm.tick(0);
    try std.testing.expectEqual(@as(u8, 0x0B), vm.song_id.?);
}

test "dialogueWaitFrames MsgDurTbl" {
    try std.testing.expectEqual(@as(u16, 0x00C0), dialogueWaitFrames(true, 0));
    try std.testing.expectEqual(@as(u16, 0x0020), dialogueWaitFrames(false, 0));
    try std.testing.expectEqual(@as(u16, 0x00A0), dialogueWaitFrames(false, 4));
}
