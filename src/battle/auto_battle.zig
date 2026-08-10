//! Auto-battle scripts — battle/init.asm @8954 + char.asm GetAutoCmd @a4d9.
//!
//! When BattleProp.battle_flags ($29a2) bit $20 is set and the battle id is in
//! AutoBattleTbl, party commands are driven by a byte script instead of the menu.
//!
//! Script pairs (battle_data.asm):
//!   $00, spell_id  — use magic
//!   $01, item_id   — use item
//!   $C0+cmd, arg   — use command (cmd = byte−$C0); $CE = kick → all mons
//!   $FF            — end / loop to start
const std = @import("std");

/// AutoBattleTbl @fe0d — battles with auto-battle scripts (16-bit battle ids).
pub const auto_battle_tbl = [_]u16{
    0x00EB, // intro 1 (fire bomb)
    0x00F5, // intro 2 (lit-bolt)
    0x00EE, // tellah vs edward / mirror script
    0x00F0, // yang
    0x00F3, // tellah vs golbez
    0x00FD, // edge vs rubicante
    0x01B3, // fusoya+golbez vs zemus 1
    0x01B4, // fusoya+golbez vs zemus 2
};

/// NoFanfareTbl @fe67
pub const no_fanfare_tbl = [_]u16{ 0x00DC, 0x00DD, 0x00E1, 0x00E7, 0x01A7, 0x01AF, 0x01B6 };

/// NoWinAnimTbl @fe76
pub const no_win_anim_tbl = [_]u16{ 0x00EB, 0x00F5, 0x00F0, 0x00FA, 0x01A9, 0x00FE, 0x00F3, 0x01B4, 0x01B7 };

/// NoUpdateBattleTbl @fd00 — do not write battle HP back to field party
pub const no_update_tbl = [_]u16{ 0x00EB, 0x00F5, 0x00F0, 0x00F6, 0x00FA, 0x01A9, 0x00FE, 0x00F3 };

pub fn inTbl(id: u16, tbl: []const u16) bool {
    const v = id & 0x1FF;
    for (tbl) |x| if ((x & 0x1FF) == v) return true;
    return false;
}

/// AutoBattle_0000..0007 (party script then optional Golbez script after $FF).
const scripts = [_][]const u8{
    // 0: intro 1
    &[_]u8{ 0x01, 0xC0, 0xFF },
    // 1: intro 2
    &[_]u8{ 0x01, 0xC2, 0xFF },
    // 2: cecil vs mirror
    &[_]u8{ 0xC0, 0x00, 0xFF },
    // 3: yang
    &[_]u8{ 0xCE, 0x00, 0xC0, 0x00, 0xFF },
    // 4: tellah vs golbez
    &[_]u8{ 0x00, 0x26, 0x00, 0x1F, 0x00, 0x25, 0x00, 0x22, 0x00, 0x2F, 0xFF },
    // 5: edge vs rubicante
    &[_]u8{ 0xC0, 0x00, 0x00, 0x42, 0xFF },
    // 6: fusoya (then golbez after first FF)
    &[_]u8{
        0x00, 0x07, 0x00, 0x01, 0x00, 0x0B, 0x00, 0x0B, 0xFF,
        // golbez
        0x00, 0x1F, 0x00, 0x22, 0x00, 0x25, 0xD0, 0x00, 0xFF,
    },
    // 7: fusoya 2 + golbez
    &[_]u8{
        0x00, 0x2F, 0x00, 0x0C, 0xFF,
        0x00, 0x2F, 0x01, 0xC8, 0xFF,
    },
};

/// $388b — auto-battle active when battle_flags & $20 and id in table.
pub const flag_mask: u8 = 0x20;

/// One decoded step from GetAutoCmd.
pub const Step = union(enum) {
    fight,
    kick,
    twin,
    magic: u8,
    item: u8,
    /// Unknown command id (raw $00–$1F) — host may no-op / requeue.
    command: u8,
};

pub const State = struct {
    active: bool = false,
    /// Party script bytes (up to first $FF inclusive, or full buf).
    party_script: [32]u8 = .{0xFF} ** 32,
    party_len: u8 = 0,
    /// Golbez script (after first $FF on scripts 6–7).
    golbez_script: [16]u8 = .{0xFF} ** 16,
    golbez_len: u8 = 0,
    /// $38a8 party step index (pairs → asl for byte index).
    party_ptr: u8 = 0,
    /// $38a9 golbez step index.
    golbez_ptr: u8 = 0,

    /// init.asm @8954–@89af: match battle_id, load scripts when flags & $20.
    pub fn initFromBattle(battle_id: u16, battle_flags: u8) State {
        var s: State = .{};
        if ((battle_flags & flag_mask) == 0) return s;
        const id = battle_id & 0x1FF;
        var i: usize = 0;
        while (i < auto_battle_tbl.len) : (i += 1) {
            if (auto_battle_tbl[i] != id) continue;
            s.active = true;
            const raw = scripts[i];
            // Copy party script through first $FF (init.asm @8985).
            var o: u8 = 0;
            var p: usize = 0;
            while (p < raw.len and o < s.party_script.len) {
                const b = raw[p];
                s.party_script[o] = b;
                o += 1;
                p += 1;
                if (b == 0xFF) break;
            }
            s.party_len = o;
            // Golbez script only for table indices 6 and 7 (init.asm X=$0C/$0E).
            if ((i == 6 or i == 7) and p < raw.len) {
                var g: u8 = 0;
                while (p < raw.len and g < s.golbez_script.len) {
                    const b = raw[p];
                    s.golbez_script[g] = b;
                    g += 1;
                    p += 1;
                    if (b == 0xFF) break;
                }
                s.golbez_len = g;
            }
            return s;
        }
        return s;
    }

    /// GetAutoCmd @a4d9 — next step for character (golbez id $15 uses golbez script).
    pub fn nextStep(self: *State, char_id: u8) Step {
        if (!self.active) return .{ .fight = {} };
        const is_golbez = char_id == 0x15;
        if (is_golbez and self.golbez_len > 0) {
            return self.nextFrom(self.golbez_script[0..self.golbez_len], &self.golbez_ptr);
        }
        return self.nextFrom(self.party_script[0..self.party_len], &self.party_ptr);
    }

    fn nextFrom(self: *State, script: []const u8, ptr: *u8) Step {
        _ = self;
        // Loop until non-$FF pair (script restarts at $FF).
        var guard: u8 = 0;
        while (guard < 16) : (guard += 1) {
            const i: usize = @as(usize, ptr.*) * 2;
            if (i >= script.len or script[i] == 0xFF) {
                ptr.* = 0;
                continue;
            }
            const op = script[i];
            const arg: u8 = if (i + 1 < script.len) script[i + 1] else 0;
            ptr.* +%= 1;
            if (op >= 0xC0) {
                const cmd = op -% 0xC0;
                return switch (cmd) {
                    0 => .{ .fight = {} },
                    0x0E => .{ .kick = {} }, // $CE
                    0x10 => .{ .twin = {} }, // $D0
                    else => .{ .command = cmd },
                };
            }
            if (op == 0x01) return .{ .item = arg };
            // $00 = magic
            return .{ .magic = arg };
        }
        return .{ .fight = {} };
    }
};

test "tellah vs golbez is auto-battle" {
    const s = State.initFromBattle(0x00F3, flag_mask);
    try std.testing.expect(s.active);
    try std.testing.expect(s.party_len >= 3);
    var t = s;
    switch (t.nextStep(0x06)) {
        .magic => |id| try std.testing.expectEqual(@as(u8, 0x26), id),
        else => return error.TestUnexpectedResult,
    }
}

test "no flag no auto" {
    const s = State.initFromBattle(0x00F3, 0);
    try std.testing.expect(!s.active);
}
