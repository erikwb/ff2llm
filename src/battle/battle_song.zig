//! Battle BGM / victory fanfare — init.asm `$38e5` song bits + CheckFanfare @87d8.
//!
//! Victory path (battle.asm @8728):
//! ```
//! jsr CheckFanfare          ; $a9=1 if battle id in NoFanfareTbl
//! lda $a9 / bne @8738       ; in table → always queue fanfare
//! lda $38e5 / and #$0c / cmp #$0c / beq @8740  ; song index 3 → skip fanfare
//! @8738: lda #$08 / sta $38be / inc $38bd     ; victory fanfare song
//! ```
//!
//! Despite the English symbol name, **membership in NoFanfareTbl forces fanfare**
//! (skips the “no battle music” early-out). Absence + song bits `$0c` silences.
//!
//! Mid-fight: GfxScript `$F3` + id → `$38be`/`$38bd` (host: song_id + dirty).
const std = @import("std");
const auto_battle = @import("auto_battle.zig");

/// Victory fanfare song id written to `$38be` (@8738).
pub const victory_fanfare_song: u8 = 0x08;

/// BattleProp / `$38e5` bits 2–3: song index 0–2 = BattleSongTbl, 3 = silence.
pub fn songIndex(battle_flags: u8) u8 {
    return (battle_flags >> 2) & 3;
}

/// True when `$38e5 & $0c == $0c` (no battle music).
pub fn noBattleMusic(battle_flags: u8) bool {
    return songIndex(battle_flags) == 3;
}

/// CheckFanfare + @8728 gate: should queue victory fanfare `$08`.
pub fn shouldPlayVictoryFanfare(battle_id: u16, battle_flags: u8) bool {
    const in_tbl = auto_battle.inTbl(battle_id, &auto_battle.no_fanfare_tbl);
    // a9 != 0 → @8738 always
    if (in_tbl) return true;
    // a9 == 0 and no battle music → skip
    if (noBattleMusic(battle_flags)) return false;
    return true;
}

/// Song id after victory resolution (fanfare `$08`, or none `$FF`).
pub fn victorySongId(battle_id: u16, battle_flags: u8) u8 {
    if (shouldPlayVictoryFanfare(battle_id, battle_flags)) return victory_fanfare_song;
    return 0xFF;
}

/// CheckWinAnim: battle id in NoWinAnimTbl → skip long victory gfx.
pub fn shouldSkipWinAnim(battle_id: u16) bool {
    return auto_battle.inTbl(battle_id, &auto_battle.no_win_anim_tbl);
}

test "songIndex and noBattleMusic from flags bits 2-3" {
    try std.testing.expectEqual(@as(u8, 0), songIndex(0x00));
    try std.testing.expectEqual(@as(u8, 1), songIndex(0x04));
    try std.testing.expectEqual(@as(u8, 2), songIndex(0x08));
    try std.testing.expectEqual(@as(u8, 3), songIndex(0x0C));
    try std.testing.expect(noBattleMusic(0x0C));
    try std.testing.expect(!noBattleMusic(0x04));
}

test "CheckFanfare: NoFanfareTbl forces fanfare even with silent flags" {
    // 0x00DC is in no_fanfare_tbl; flags $0c = silent battle music
    try std.testing.expect(shouldPlayVictoryFanfare(0x00DC, 0x0C));
    try std.testing.expectEqual(victory_fanfare_song, victorySongId(0x00DC, 0x0C));
}

test "CheckFanfare: not in table + silent → no fanfare" {
    try std.testing.expect(!shouldPlayVictoryFanfare(0x0001, 0x0C));
    try std.testing.expectEqual(@as(u8, 0xFF), victorySongId(0x0001, 0x0C));
}

test "CheckFanfare: not in table + has music → fanfare" {
    try std.testing.expect(shouldPlayVictoryFanfare(0x0001, 0x00));
    try std.testing.expectEqual(victory_fanfare_song, victorySongId(0x0001, 0x04));
}

test "CheckWinAnim NoWinAnimTbl" {
    try std.testing.expect(shouldSkipWinAnim(0x00F3)); // tellah vs golbez
    try std.testing.expect(!shouldSkipWinAnim(0x0001));
}

test "victory_fanfare_song is $08" {
    try std.testing.expectEqual(@as(u8, 0x08), victory_fanfare_song);
}
