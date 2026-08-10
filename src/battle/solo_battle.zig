//! Solo / fixed-party event battles — field/event.asm EventCmd_ec @e619–@e750.
//!
//! When `$1800` matches SoloBattleTbl, the field party is thinned to the
//! designated character(s) (Tellah vs Golbez, Edward vs hag, etc.) before
//! BattleSub, then restored by RestorePartyAfterSoloBattle.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const state_mod = @import("../game/state.zig");
const party_mod = @import("../game/party.zig");

/// SoloBattleTbl @e79e (13 battles).
pub const solo_battle_tbl = [_]u16{
    0x00F7, 0x00F8, 0x00F9, 0x00F1, 0x00EE, 0x00F6, 0x00EF, 0x00F0,
    0x00F3, 0x00FD, 0x01A8, 0x01B3, 0x01B4,
};

/// SoloBattleCharTbl @e791 — character id ($1000&$1F) for each solo battle.
/// Index $0B also keeps SoloBattleCharTbl[$0C] via +1 compare (Fusoya+Golbez).
pub const solo_battle_chars = [_]u8{
    0x03, 0x03, 0x03, 0x01, 0x04, 0x0B, 0x05, 0x07,
    0x0C, 0x12, 0x11, 0x13, 0x15,
};

/// Snapshot of party ids/slots before solo filter (RestorePartyAfterSoloBattle).
pub const Backup = struct {
    party: [5]state_mod.PartyMember = [_]state_mod.PartyMember{.{}} ** 5,
    active: bool = false,
    /// SoloBattle index 0..12 ($e4 & $7F).
    index: u8 = 0,
};

/// Returns solo-battle table index if `battle_id` is scripted, else null.
pub fn soloIndex(battle_id: u16) ?u8 {
    const id = battle_id & 0x1FF;
    for (solo_battle_tbl, 0..) |bid, i| {
        if (bid == id) return @intCast(i);
    }
    return null;
}

/// EventCmd_ec solo path: save party, hide non-solo members, max HP/MP for keepers.
/// If the solo character is missing from the party, LoadCharProp them into slot 0
/// (events normally $e7 them first; free-roam skips may not).
pub fn apply(r: *const rom_mod.Rom, party: []state_mod.PartyMember, battle_id: u16) Backup {
    const idx = soloIndex(battle_id) orelse return .{};
    var bak: Backup = .{ .active = true, .index = idx };
    @memcpy(bak.party[0..], party[0..5]);

    // Index $0B: Fusoya + Golbez special load (event.asm @e6ed).
    // ROM copies slots then LoadCharProp #$0D / RestoreCharProp #$01 — host loads
    // CharProp rows for Fusoya ($13) and Golbez ($15) and compacts to the front.
    if (idx == 0x0B) {
        clearParty(party);
        if (loadSoloMember(r, 0x13)) |f| { // Fusoya
            party[0] = f;
            maxHpMp(&party[0]);
        }
        if (loadSoloMember(r, 0x15)) |g| { // Golbez
            party[1] = g;
            maxHpMp(&party[1]);
        }
        return bak;
    }

    // Index $0C ($01B4): normal loop only keeps $15 (Golbez). Auto-battle still
    // has a Fusoya script, but GetAutoCmd only uses it if Fusoya is present —
    // ROM leaves party as Golbez-only after the filter. Match that.

    const want_a = solo_battle_chars[idx];

    var kept: bool = false;
    var i: usize = 0;
    while (i < party.len) : (i += 1) {
        if (!party[i].present) continue;
        const cid = party[i].id & 0x1F;
        // When SoloBattleCharTbl[y] == $03 (battles 0–2): only hide Rydia
        // (event.asm @e6d6) — other party members stay (Cecil vs soldiers).
        if (want_a == 0x03) {
            if (cid == 0x03) party[i] = .{};
            continue;
        }
        if (idsMatch(cid, want_a)) {
            // Canonical story id for this solo fight (e.g. Tellah $04 → $0C).
            party[i].id = want_a;
            maxHpMp(&party[i]);
            kept = true;
        } else {
            party[i] = .{}; // hide
        }
    }

    if (!kept) {
        // Solo character not in roster — LoadCharProp (events usually $e7 first).
        clearParty(party);
        if (loadSoloMember(r, want_a)) |m| {
            party[0] = m;
            maxHpMp(&party[0]);
        }
    } else {
        compactPresent(party);
    }
    return bak;
}

/// RestorePartyAfterSoloBattle @e74b — put saved ids back (full member snapshot).
pub fn restore(party: []state_mod.PartyMember, bak: Backup) void {
    if (!bak.active) return;
    @memcpy(party[0..5], bak.party[0..]);
}

fn maxHpMp(m: *state_mod.PartyMember) void {
    m.hp = m.max_hp;
    m.mp = m.max_mp;
    m.status1 = 0;
    m.status2 = 0;
}

fn clearParty(party: []state_mod.PartyMember) void {
    for (party) |*m| m.* = .{};
}

fn compactPresent(party: []state_mod.PartyMember) void {
    var tmp: [5]state_mod.PartyMember = [_]state_mod.PartyMember{.{}} ** 5;
    var w: usize = 0;
    for (party) |m| {
        if (m.present and w < 5) {
            tmp[w] = m;
            w += 1;
        }
    }
    @memcpy(party[0..5], tmp[0..]);
}

/// Tellah story ids: $04 first join, $0A second, $0C third (Zot / Golbez fight).
fn idsMatch(have: u8, want: u8) bool {
    const a = have & 0x1F;
    const b = want & 0x1F;
    if (a == b) return true;
    // Treat Tellah variants as the same person for solo filter.
    const tellah = [_]u8{ 0x04, 0x0A, 0x0C };
    var ha = false;
    var hb = false;
    for (tellah) |t| {
        if (a == t) ha = true;
        if (b == t) hb = true;
    }
    return ha and hb;
}

/// CharProp row + equip index for a solo battle character id.
fn loadSoloMember(r: *const rom_mod.Rom, char_id: u8) ?state_mod.PartyMember {
    const cid = char_id & 0x1F;
    // Map appearance id → CharProp row (14-entry base table).
    const row: u8 = switch (cid) {
        0x01 => 0, // Cecil DK
        0x02 => 1, // Kain
        0x03 => 2, // Rydia child
        0x04, 0x0A, 0x0C => 3, // Tellah (all appearances)
        0x05 => 4, // Edward
        0x06 => 5, // Rosa
        0x07 => 6, // Yang
        0x08 => 7, // Palom
        0x09 => 8, // Porom
        0x0B => 9, // Cecil paladin
        0x0E => 10, // Cid
        0x11 => 2, // Adult Rydia (job patched in loadMember)
        0x12 => 11, // Edge
        0x13 => 12, // Fusoya
        0x15 => 13, // Golbez-ish / last row
        else => cid,
    };
    var m = party_mod.loadMember(r, row, equipIndexForCharId(cid)) orelse return null;
    m.id = cid; // preserve SoloBattleCharTbl id (Tellah $0C etc.)
    return m;
}

fn equipIndexForCharId(char_id: u8) u8 {
    for (party_mod.char_remove_tbl, 0..) |raw, i| {
        if ((raw & 0x7F) == (char_id & 0x1F)) return @intCast(i);
    }
    // Tellah 3rd appearance $0C → equip row for first Tellah if not in table match.
    if (char_id == 0x0C or char_id == 0x0A) {
        for (party_mod.char_remove_tbl, 0..) |raw, i| {
            if ((raw & 0x7F) == 0x04) return @intCast(i);
        }
    }
    return char_id & 0x1F;
}

test "tellah vs golbez is solo index 8" {
    try std.testing.expectEqual(@as(?u8, 8), soloIndex(0x00F3));
    try std.testing.expectEqual(@as(u8, 0x0C), solo_battle_chars[8]);
}
