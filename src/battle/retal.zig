//! Monster retaliation stack — attack.asm AddRetal / ShiftRetalStack.
//!
//! Per mon (0..7):
//!   $35f7,x size: $FF = empty; else index of latest entry 0..3
//!   $2b78 + mon×32: up to 4 entries × 4 bytes
//!     [0] attacker ($cd: party 0..4 or $80|mon_i)
//!     [1] command ($35ff, e.g. $C0 fight / $C2 magic)
//!     [2] 0
//!     [3] element ($3600)
//!
//! Used by AICond_07 (latest) and AICond_08 (scan all). DoRetal scripts are separate.
//! DoRetal status gate: retal.asm @c1a5.
const std = @import("std");
const obj_mod = @import("obj.zig");
const status_mod = @import("status.zig");

/// DoRetal @c1a5: mon may counter only if not dead/stone, not sleep/para/berserk/charm, not stop.
pub fn canRetaliate(status: status_mod.Status) bool {
    if ((status.s1 & 0xC0) != 0) return false; // dead/stone
    if ((status.s2 & 0x3C) != 0) return false; // sleep/para/berserk/charm (and bits in 0x3C)
    if ((status.s3 & 0x40) != 0) return false; // stop
    return true;
}

// --- DoRetal control flow (retal.asm @c16c) ---

/// Entry gate: DoRetal @c16c–@c18a.
/// - `$34c4` mon target (party hit mon) required
/// - `$3877` multi-action depth must be 0 (skip retal during multi)
/// - `$34c5` / `$38b2` mon target mask nonzero
pub fn shouldRunDoRetal(target_is_mon: bool, multi_depth: u8, mon_target_mask: u8) bool {
    if (!target_is_mon) return false;
    if (multi_depth != 0) return false;
    return mon_target_mask != 0;
}

/// Build mon target mask bit for mon index 0..7 — bit7 = mon0 (retal.asm @c19f asl scan).
pub fn monBit(mon_i: usize) u8 {
    if (mon_i >= 8) return 0;
    return @as(u8, 0x80) >> @intCast(mon_i);
}

/// Absolute mon slot (5..12) → mask bit.
pub fn monSlotToMaskBit(abs_slot: usize) u8 {
    if (abs_slot < obj_mod.party_slots) return 0;
    return monBit(abs_slot - obj_mod.party_slots);
}

/// First mon index 0..7 in mask (high bit first, @c19f).
pub fn firstMonInMask(mask: u8) ?usize {
    var m = mask;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if ((m & 0x80) != 0) return i;
        m <<= 1;
    }
    return null;
}

/// Clear mon_i bit from mask (after processing that mon).
pub fn clearMonInMask(mask: u8, mon_i: usize) u8 {
    return mask & ~monBit(mon_i);
}

/// One mon eligible for DoRetal loop body (@c1a5–@c1e0): has_retal + canRetaliate.
pub fn monEligibleForRetal(has_retal: bool, status: status_mod.Status, present: bool, hp: u16) bool {
    if (!present or hp == 0) return false;
    if (!has_retal) return false;
    return canRetaliate(status);
}

/// SkipMultiAttackRetal (@c45e): if script contains `$FC`, rewrite head to `$E1,$00,$FC,$FF`
/// (do-nothing + end multi). Pure check for host script rewrite.
pub fn scriptHasMultiEnd(script: []const u8) bool {
    for (script) |b| {
        if (b == 0xFF) break;
        if (b == 0xFC) return true;
    }
    return false;
}

/// Rewrite retal multi-action script per SkipMultiAttackRetal (@c471).
/// Writes `$E1, $00, $FC, $FF` into `out` (4 bytes). Returns length 4.
pub fn skipMultiAttackRetalScript(out: *[4]u8) usize {
    out[0] = 0xE1; // do nothing
    out[1] = 0x00;
    out[2] = 0xFC; // end multi
    out[3] = 0xFF;
    return 4;
}

pub const max_entries: u8 = 4;

pub const Entry = struct {
    /// ROM $cd encoding: party slot 0..4, or $80 | mon_index.
    attacker: u8 = 0,
    cmd: u8 = 0,
    element: u8 = 0,
};

pub const MonStack = struct {
    /// $35f7: $FF empty, else last index 0..3.
    size: u8 = 0xFF,
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    pub fn clear(self: *MonStack) void {
        self.size = 0xFF;
        self.entries = [_]Entry{.{}} ** max_entries;
    }

    pub fn empty(self: MonStack) bool {
        return self.size == 0xFF;
    }

    /// AddRetal push for one mon. Caps at 4 via ShiftRetalStack.
    pub fn push(self: *MonStack, attacker: u8, cmd: u8, element: u8) void {
        var next: u8 = if (self.size == 0xFF) 0 else self.size +% 1;
        if (next >= max_entries) {
            // Shift out oldest (entries 1..3 → 0..2), write at index 3
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                self.entries[i] = self.entries[i + 1];
            }
            next = 3;
        }
        self.size = next;
        self.entries[next] = .{
            .attacker = attacker,
            .cmd = cmd,
            .element = element,
        };
    }

    /// AICond_07: most recent entry.
    pub fn latest(self: *const MonStack) ?Entry {
        if (self.size == 0xFF or self.size >= max_entries) return null;
        return self.entries[self.size];
    }

    /// AICond_08: any entry matches cmd (+ optional element mask).
    pub fn matchCmd(self: *const MonStack, cmd: u8, elem_mask: u8) bool {
        if (self.size == 0xFF) return false;
        // Scan filled entries 0..size inclusive
        const n: usize = @as(usize, self.size) + 1;
        var i: usize = 0;
        while (i < n and i < max_entries) : (i += 1) {
            const e = self.entries[i];
            if (e.cmd != cmd) continue;
            if (elem_mask != 0 and (elem_mask & e.element) == 0) continue;
            return true;
        }
        return false;
    }
};

/// 8 mon stacks ($35f7 / $2b78).
pub const Table = struct {
    stacks: [obj_mod.mon_slots]MonStack = [_]MonStack{.{}} ** obj_mod.mon_slots,

    pub fn clear(self: *Table) void {
        for (&self.stacks) |*s| s.clear();
    }

    /// Encode absolute obj slot as $cd retal attacker byte.
    pub fn encodeAttacker(slot: usize) u8 {
        if (slot < obj_mod.party_slots) return @intCast(slot);
        const mi = slot - obj_mod.party_slots;
        return 0x80 | @as(u8, @intCast(mi & 0x7F));
    }

    /// Decode $cd to absolute obj slot.
    pub fn decodeAttacker(encoded: u8) usize {
        if ((encoded & 0x80) != 0) {
            return obj_mod.party_slots + @as(usize, encoded & 0x7F);
        }
        return @as(usize, encoded);
    }

    /// AddRetal: push to each mon target (absolute slots ≥ party_slots).
    /// Skipped when `delay_mon_death` ($38e4) — caller gates.
    pub fn addRetal(
        self: *Table,
        attacker_slot: usize,
        target_slot: usize,
        cmd: u8,
        element: u8,
    ) void {
        if (target_slot < obj_mod.party_slots) return;
        const mi = target_slot - obj_mod.party_slots;
        if (mi >= obj_mod.mon_slots) return;
        self.stacks[mi].push(encodeAttacker(attacker_slot), cmd, element);
    }

    pub fn stack(self: *const Table, mon_i: usize) *const MonStack {
        return &self.stacks[mon_i];
    }
    pub fn stackMut(self: *Table, mon_i: usize) *MonStack {
        return &self.stacks[mon_i];
    }
};

test "retal push empty to first then second" {
    var s: MonStack = .{};
    try std.testing.expect(s.empty());
    s.push(0, 0xC0, 0x01);
    try std.testing.expectEqual(@as(u8, 0), s.size);
    try std.testing.expectEqual(@as(u8, 0xC0), s.latest().?.cmd);
    s.push(1, 0xC2, 0x02);
    try std.testing.expectEqual(@as(u8, 1), s.size);
    try std.testing.expectEqual(@as(u8, 0xC2), s.latest().?.cmd);
    try std.testing.expect(s.matchCmd(0xC0, 0));
    try std.testing.expect(s.matchCmd(0xC2, 0x02));
    try std.testing.expect(!s.matchCmd(0xC2, 0x01)); // elem mask miss
}

test "retal shift at 4 entries" {
    var s: MonStack = .{};
    s.push(0, 0x10, 0);
    s.push(1, 0x11, 0);
    s.push(2, 0x12, 0);
    s.push(3, 0x13, 0);
    try std.testing.expectEqual(@as(u8, 3), s.size);
    s.push(4, 0x14, 0); // shifts out 0x10
    try std.testing.expectEqual(@as(u8, 3), s.size);
    try std.testing.expectEqual(@as(u8, 0x14), s.latest().?.cmd);
    try std.testing.expect(!s.matchCmd(0x10, 0));
    try std.testing.expect(s.matchCmd(0x11, 0));
}

test "encode decode attacker" {
    try std.testing.expectEqual(@as(u8, 2), Table.encodeAttacker(2));
    try std.testing.expectEqual(@as(u8, 0x80), Table.encodeAttacker(5));
    try std.testing.expectEqual(@as(usize, 7), Table.decodeAttacker(0x82));
}

test "canRetaliate DoRetal status gates @c1a5" {
    var st: status_mod.Status = .{};
    try std.testing.expect(canRetaliate(st));
    st.s1 = status_mod.Status1.dead;
    try std.testing.expect(!canRetaliate(st));
    st = .{};
    st.s1 = status_mod.Status1.stone;
    try std.testing.expect(!canRetaliate(st));
    st = .{};
    st.s2 = status_mod.Status2.sleep;
    try std.testing.expect(!canRetaliate(st));
    st = .{};
    st.s2 = status_mod.Status2.berserk;
    try std.testing.expect(!canRetaliate(st));
    st = .{};
    st.s3 = status_mod.Status3.stop;
    try std.testing.expect(!canRetaliate(st));
}

test "shouldRunDoRetal gates multi and mon target" {
    try std.testing.expect(shouldRunDoRetal(true, 0, 0x80));
    try std.testing.expect(!shouldRunDoRetal(false, 0, 0x80)); // party target
    try std.testing.expect(!shouldRunDoRetal(true, 1, 0x80)); // multi active $3877
    try std.testing.expect(!shouldRunDoRetal(true, 0, 0)); // empty mask
}

test "mon mask bit scan high-first" {
    try std.testing.expectEqual(@as(u8, 0x80), monBit(0));
    try std.testing.expectEqual(@as(u8, 0x40), monBit(1));
    try std.testing.expectEqual(@as(u8, 0x01), monBit(7));
    try std.testing.expectEqual(@as(?usize, 0), firstMonInMask(0x80));
    try std.testing.expectEqual(@as(?usize, 1), firstMonInMask(0x40));
    try std.testing.expectEqual(@as(?usize, 0), firstMonInMask(0xC0)); // high first
    try std.testing.expectEqual(@as(u8, 0x40), clearMonInMask(0xC0, 0));
    try std.testing.expectEqual(@as(u8, 0x80), monSlotToMaskBit(5)); // mon 0
}

test "monEligibleForRetal requires has_retal" {
    const st: status_mod.Status = .{};
    try std.testing.expect(monEligibleForRetal(true, st, true, 10));
    try std.testing.expect(!monEligibleForRetal(false, st, true, 10));
    try std.testing.expect(!monEligibleForRetal(true, st, true, 0));
}

test "SkipMultiAttackRetal script rewrite" {
    try std.testing.expect(scriptHasMultiEnd(&[_]u8{ 0xC0, 0xFC, 0xFF }));
    try std.testing.expect(!scriptHasMultiEnd(&[_]u8{ 0xC0, 0xFF }));
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), skipMultiAttackRetalScript(&out));
    try std.testing.expectEqual(@as(u8, 0xE1), out[0]);
    try std.testing.expectEqual(@as(u8, 0xFC), out[2]);
    try std.testing.expectEqual(@as(u8, 0xFF), out[3]);
}
