//! Field menu geometry — exclusively from decomp menu_data.asm / *.asm cursors.
//!
//! ## Field `def_window left,top,width,height`
//! Width/height are **interior** fill counts (DrawWindowTiles: L + width middles + R).
//! `WindowChrome.drawEx` takes **total** tiles = interior + 2.
//!
//! ## `def_ptxt` / GetDakuten (EN)
//! Glyphs land on the **kana** row (+1 tile / +8 px). Use `ptxtY(row)` for labels.
//! Direct digit writes (DrawNum*) use tilemap Y as-is (`tmXY`).

const window = @import("../battle/window.zig");

pub const dakuten_kana_dy: i32 = 8;

pub fn fieldTotal(interior: u8) u8 {
    return interior + 2;
}

pub fn ptxtX(col: u8) i32 {
    return @as(i32, col) * 8;
}

pub fn ptxtY(row: u8) i32 {
    return @as(i32, row) * 8 + dakuten_kana_dy;
}

/// Tilemap buffer offset → pixel (32 tiles/row = 64 bytes).
pub fn tmXY(off: u16) struct { x: i32, y: i32 } {
    return .{
        .x = @as(i32, @intCast((off % 64) / 2)) * 8,
        .y = @as(i32, @intCast(off / 64)) * 8,
    };
}

pub fn drawDef(
    chrome: *const window.WindowChrome,
    pixels: []u8,
    dest_w: usize,
    left: u8,
    top: u8,
    interior_w: u8,
    interior_h: u8,
) void {
    chrome.drawEx(
        pixels,
        dest_w,
        @as(i32, left) * 8,
        @as(i32, top) * 8,
        fieldTotal(interior_w),
        fieldTotal(interior_h),
        .field,
    );
}

// =============================================================================
// Main menu (menu_data.asm Main* + menu.asm MainMenuMain)
// =============================================================================

pub const main_char = struct {
    pub const left: u8 = 0;
    pub const top: u8 = 0;
    pub const iw: u8 = 22;
    pub const ih: u8 = 26;
};

pub const main_options = struct {
    pub const left: u8 = 22;
    pub const top: u8 = 0;
    pub const iw: u8 = 7;
    pub const ih: u8 = 17;
    pub const label_col: u8 = 24;
    /// def_ptxt rows 1,3,5,7,9,11,13,15
    pub const label_row0: u8 = 1;
    pub const label_row_step: u8 = 2;
    pub fn labelY(sel: u8) i32 {
        return ptxtY(label_row0 + sel * label_row_step);
    }
};

pub const main_gil = struct {
    pub const left: u8 = 21;
    pub const top: u8 = 23;
    pub const iw: u8 = 8;
    pub const ih: u8 = 3;
    /// DrawTimeGil: number bg_pos 21,24; "G" GilPosText 27,25
    pub const num_col: u8 = 21;
    pub const num_row: u8 = 24;
    pub const g_col: u8 = 27;
    pub const g_row: u8 = 25;
};

pub const main_time = struct {
    pub const left: u8 = 22;
    pub const top: u8 = 19;
    pub const iw: u8 = 7;
    pub const ih: u8 = 2;
    /// TimePosText def_ptxt 23,17
    pub const label_col: u8 = 23;
    pub const label_row: u8 = 17;
};

/// MainMenuMain @8813
pub const main_cursor_x: i32 = 0xB0;
pub fn mainCursorY(sel: u8) i32 {
    return @as(i32, sel) * 16 + 0x10;
}

/// SelectChar @8a69 — y = display_order*40+$10 (CharOrderTbl order index).
pub const party_cursor_x: i32 = 0x02;
pub const char_order_tbl = [_]u8{ 1, 3, 0, 4, 2 };

pub fn partyCursorY(raw_slot: u8) i32 {
    var order: u8 = 0;
    while (order < char_order_tbl.len) : (order += 1) {
        if (char_order_tbl[order] == raw_slot) return @as(i32, order) * 40 + 0x10;
    }
    return @as(i32, raw_slot) * 40 + 0x10;
}

/// DrawCharBlock1..5 name bases (dakuten row) — col 7.
pub const char_name_base_y = [_]i32{ 11 * 8, 1 * 8, 21 * 8, 6 * 8, 16 * 8 };
pub const char_name_x: i32 = 7 * 8;
pub const char_level_x: i32 = 9 * 8;
pub const char_level_num_x: i32 = 19 * 8;
pub const char_hp_num_x: i32 = 12 * 8;
pub const char_slash_x: i32 = 16 * 8;
pub const char_hp_max_x: i32 = 17 * 8;

// =============================================================================
// Item (item.asm / menu_data Inventory*)
// =============================================================================

pub const inv = struct {
    pub const left: u8 = 1;
    pub const top: u8 = 0;
    pub const iw: u8 = 27;
    /// ROM height 48 (scroll); visible clip to 224px → 28 total tiles from y=0.
    pub const vis_total_h: u8 = 28;
};

pub const item_label_left = struct {
    pub const left: u8 = 1;
    pub const top: u8 = 0;
    pub const iw: u8 = 7;
    pub const ih: u8 = 3;
    pub const ptxt_col: u8 = 3;
    pub const ptxt_row: u8 = 1;
};

pub const item_label_right = struct {
    pub const left: u8 = 22;
    pub const top: u8 = 0;
    pub const iw: u8 = 7;
    pub const ih: u8 = 3;
};

pub const item_desc = struct {
    pub const left: u8 = 9;
    pub const top: u8 = 0;
    pub const iw: u8 = 19;
    pub const ih: u8 = 3;
};

/// DrawItemCursors @a105
pub const item_cursor_x = [_]i32{ 0x04, 0x70 };
pub const item_cursor_y0: i32 = 0x36;
/// Icon column = cursor_x + 16 (one hand width).
pub fn itemTextX(col: u8) i32 {
    return item_cursor_x[col] + 16;
}

pub const item_whom = struct {
    /// ItemWhomPosText def_ptxt 10,1
    pub const ptxt_col: u8 = 10;
    pub const ptxt_row: u8 = 1;
    /// ItemCharSelectWindowLeft/Right
    pub const left_l: u8 = 1;
    pub const left_t: u8 = 5;
    pub const left_iw: u8 = 14;
    pub const left_ih: u8 = 21;
    pub const right_l: u8 = 14;
    pub const right_t: u8 = 5;
    pub const right_iw: u8 = 14;
    pub const right_ih: u8 = 21;
};

// =============================================================================
// Equip (equip.asm / EquipWindow)
// =============================================================================

pub const equip = struct {
    pub const left: u8 = 1;
    pub const top: u8 = 0;
    pub const iw: u8 = 27;
    pub const ih: u8 = 11;
    /// EQUIP_PTXT_X EN = 13
    pub const label_col: u8 = 13;
    pub const item_col: u8 = 18; // tilemap $xx64
    pub const cursor_x: i32 = 0x58; // EN @bdfa
    pub fn slotGlyphY(slot: u8) i32 {
        return ptxtY(1 + slot * 2);
    }
    pub fn cursorY(slot: u8) i32 {
        return @as(i32, slot) * 16 + 0x10;
    }
};

// =============================================================================
// Status (status.asm)
// =============================================================================

pub const status = struct {
    /// StatusWindow def_window 0,1,29,24 (menu_data.asm @de01) — BG1, no V-scroll.
    pub const win_l: u8 = 0;
    pub const win_t: u8 = 1;
    pub const win_iw: u8 = 29;
    pub const win_ih: u8 = 24;
    /// StatusPortraitWindow def_window 18,6,11,4 (@de05) — BG2.
    pub const port_l: u8 = 18;
    pub const port_t: u8 = 6;
    pub const port_iw: u8 = 11;
    pub const port_ih: u8 = 4;
    /// StatusLabelPosText def_ptxt 24,7,{STATUS_STR,0} (@de09) — BG2.
    pub const label_col: u8 = 24;
    pub const label_row: u8 = 7;
    /// DrawPortrait ldy #$0898 → OAM X=$98 Y=$08 (sprites ignore BG scroll).
    pub const portrait_x: i32 = 0x98;
    pub const portrait_y: i32 = 0x08;
    /// STATUS_LEVEL_X EN = 11
    pub const level_col: u8 = 11;
    pub const exp_num_off: u16 = 0x0226;
    pub const next_exp_off: u16 = 0x02e6;

    /// BG2 VOFS after TransformWindow (status.asm @a952–@a95f + menu.asm TransformWindow).
    ///
    /// status.asm sets both BG2-V and BG4-V rates before the morph:
    ///   `lda #$0c / sta $c2`  — 12 scroll frames
    ///   `lda #$04 / sta $b1 / sta $a5` — rate high bytes at $b0 (BG4 V) and $a4 (BG2 V)
    ///   → rate word $0400 (system.asm UpdateScrollRegs: $8d/$8e = BG2VOFS)
    ///
    /// UpdateBGScroll adds the 16-bit rate into the 16-bit position at $8c each frame
    /// while `$c2` > 0, so VOFS low ($8d) advances by **4 px/frame**.
    ///
    /// TransformWindow keeps looping while `$c2 != 0` even after window edges match
    /// (`lda $01c2 / bne @8526`), so all **12** frames run.
    /// Final BG2 VOFS = 12 × 4 = **48**. Screen Y for BG2 tiles = tileY − 48.
    ///
    /// StatusPortraitWindow top tile 6 → screen y = 0; total h 6 tiles → y 0..48,
    /// sitting under the portrait sprite at OAM y=$08 and clear of Exp. (BG1 y=56).
    pub const bg2_vofs: i32 = 48;
};

// =============================================================================
// Number drawing (menu.asm) — NEVER apply dakuten_kana_dy to these.
//
// DrawNum2 @8369: 2-tile field at tilemap off Y. Tens at Y, ones at Y+2.
//   Leading blank $FF if value < 10. → left X = tmXY(off).x, min_width 2.
//
// DrawNum4 / _018383: 4-tile field at Y..Y+6. Leading $FF blanks.
//   → left X = tmXY(off).x, min_width 4.
//
// DrawNum7 @8fa6: HexToDec7 then write RTL from (Y+14).
//   Ones at byte off+14; MSD at off+2. 7-tile field cols from off.
//   → left X = drawNum7LeftX(off), min_width 7.
//
// CopyText @8798: raw tiles at bg_pos, NO GetDakuten (row = def row exactly).
//   BATTLE_NUM_STR "1 2 3 4 5 6" → digit every 2 tiles (16 px).
// =============================================================================

/// DrawNum7: pixel X of leftmost digit of the 7-tile field.
pub fn drawNum7LeftX(tilemap_off: u16) i32 {
    // leftmost byte offset = tilemap_off + 14 - 12 = tilemap_off + 2
    return tmXY(tilemap_off + 2).x;
}

/// DrawNum2/4: pixel X of left edge of field (tilemap off is first digit slot).
pub fn drawNumLeftX(tilemap_off: u16) i32 {
    return tmXY(tilemap_off).x;
}

/// DrawNum*: pixel Y — same as tile row (no dakuten).
pub fn drawNumY(tilemap_off: u16) i32 {
    return tmXY(tilemap_off).y;
}

/// CopyText / BattleNumText pitch: one digit + one space = 2 tiles.
pub const battle_num_pitch_px: i32 = 16;

// =============================================================================
// Magic (magic.asm / MagicListWindow / MagicTypeWindow)
// =============================================================================

pub const magic_list = struct {
    pub const left: u8 = 1;
    pub const top: u8 = 8;
    pub const iw: u8 = 28;
    pub const ih: u8 = 17;
};

pub const magic_type = struct {
    pub const left: u8 = 22;
    pub const top: u8 = 2;
    pub const iw: u8 = 7;
    pub const ih: u8 = 7;
    /// Type select cursor @b0bb: x=$08, y=$1b81*16+$10
    pub const cursor_x: i32 = 0x08;
    pub fn typeCursorY(col: u8) i32 {
        return @as(i32, col) * 16 + 0x10;
    }
};

/// Magic list column X from _01b211: $10, $58, $a0
pub const magic_list_col_x = [_]i32{ 0x10, 0x58, 0xA0 };
/// Spell row pitch 16; first row near list window top interior (~$50-ish from shop analogy).
/// From magic list scroll: use cursor y = row*16 + $50 (SelectItemBuy pattern for lists at y=8 window).
/// Actual spell cursor: _01b36d — derive from type window flow; list uses:
///   often y = vis_row*12 or 16. Port from common: list top tile 8 → first text ~ y 80 ($50).
pub const magic_list_cursor_y0: i32 = 0x50;
pub const magic_list_row_pitch: i32 = 16;

pub const magic_mp = struct {
    /// MPNeededPosText EN def_ptxt 2,4
    pub const col: u8 = 2;
    pub const row: u8 = 4;
};

// =============================================================================
// Shop (shop.asm)
// =============================================================================

pub const shop = struct {
    pub const gil_l: u8 = 17;
    pub const gil_t: u8 = 4;
    pub const gil_iw: u8 = 11;
    pub const gil_ih: u8 = 3;
    pub const choice_l: u8 = 1;
    pub const choice_t: u8 = 4;
    pub const choice_iw: u8 = 15;
    pub const choice_ih: u8 = 3;
    pub const type_l: u8 = 1;
    pub const type_t: u8 = 0;
    pub const type_iw: u8 = 6;
    pub const type_ih: u8 = 2;
    pub const msg_l: u8 = 8;
    pub const msg_t: u8 = 0;
    pub const msg_iw: u8 = 20;
    pub const msg_ih: u8 = 2;
    pub const list_l: u8 = 1;
    pub const list_t: u8 = 8;
    pub const list_iw: u8 = 20;
    pub const list_ih: u8 = 17;
    pub const char_l: u8 = 22;
    pub const char_t: u8 = 8;
    pub const char_iw: u8 = 7;
    pub const char_ih: u8 = 11;
    /// Buy/Sell mode cursor EN: x = sel*40+$08, y=$30 (@c37c)
    pub const mode_cursor_y: i32 = 0x30;
    pub fn modeCursorX(sel: u8) i32 {
        return @as(i32, sel) * 40 + 0x08;
    }
    /// SelectItemBuy: x=$10, y=sel*16+$50
    pub const buy_cursor_x: i32 = 0x10;
    pub fn buyCursorY(sel: u8) i32 {
        return @as(i32, sel) * 16 + 0x50;
    }
    /// SelectItemSell: y=row*16+$58; x=col?$78:$08
    pub const sell_cursor_x = [_]i32{ 0x08, 0x78 };
    pub fn sellCursorY(row: u8) i32 {
        return @as(i32, row) * 16 + 0x58;
    }
    /// ShopWelcomePosText 10,1; Buy/Sell BUY_SELL_X=3 EN, row 5
    pub const welcome_col: u8 = 10;
    pub const welcome_row: u8 = 1;
    pub const buy_sell_col: u8 = 3;
    pub const buy_sell_row: u8 = 5;
    pub const gil_label_col: u8 = 27;
    pub const gil_label_row: u8 = 5;
};

// =============================================================================
// Config (config.asm + menu_data.asm, SIMPLE_CONFIG=1 — US / LANG_EN)
// =============================================================================

pub const config = struct {
    /// ConfigMainWindow def_window 2,4,24,20
    pub const main_l: u8 = 2;
    pub const main_t: u8 = 4;
    pub const main_iw: u8 = 24;
    pub const main_ih: u8 = 20;
    /// EN ConfigLabelWindow 9,1,10,2; ConfigLabelPosText 10,2 Customizer
    pub const label_l: u8 = 9;
    pub const label_t: u8 = 1;
    pub const label_iw: u8 = 10;
    pub const label_ih: u8 = 2;
    pub const title_col: u8 = 10;
    pub const title_row: u8 = 2;

    /// SIMPLE ConfigCursorYTbl @d449: $30,$50,$78,$a0,$b0,$c0
    /// sel 0 btl speed, 1 msg speed, 2 sound, 3–5 window color R/G/B.
    pub const cursor_y_tbl = [_]i32{ 0x30, 0x50, 0x78, 0xA0, 0xB0, 0xC0 };
    pub const row_count: u8 = 6;
    /// Row cursor x: sel < 3 → $18, else $68 (config.asm @d247)
    pub const row_cursor_x0: i32 = 0x18;
    pub const row_cursor_x_color: i32 = 0x68;
    pub fn rowCursorX(sel: u8) i32 {
        return if (sel < 3) row_cursor_x0 else row_cursor_x_color;
    }
    pub fn rowCursorY(sel: u8) i32 {
        const i = @min(sel, row_count - 1);
        return cursor_y_tbl[i];
    }

    /// GetConfigXPos: bit0 clear → $68, set → $a0 (Stereo/Mono)
    pub const toggle_x0: i32 = 0x68;
    pub const toggle_x1: i32 = 0xA0;
    /// Stereo cursor Y under SIMPLE (config.asm @d174)
    pub const stereo_cursor_y: i32 = 0x78;

    /// def_ptxt (SIMPLE_CONFIG menu_data.asm @dd5c–@ddaf) — DrawPosText / dakuten.
    pub const btl_spd_label_col: u8 = 5;
    pub const btl_spd_label_row: u8 = 5;
    pub const msg_spd_label_col: u8 = 5;
    pub const msg_spd_label_row: u8 = 9;
    pub const sound_label_col: u8 = 5;
    pub const sound_label_row: u8 = 14;
    pub const stereo_col: u8 = 15;
    pub const stereo_row: u8 = 14;
    pub const win_color_label_col: u8 = 5;
    pub const win_color_label_row: u8 = 17;
    /// Fast/Slow pairs: btl @ 15,6 / 22,6; msg @ 15,10 / 22,10
    pub const fast_col: u8 = 15;
    pub const slow_col: u8 = 22;
    pub const btl_fast_slow_row: u8 = 6;
    pub const msg_fast_slow_row: u8 = 10;

    /// CopyText BattleNumText @ bg_pos 15,8 and 15,12 — NO dakuten; pitch 2 tiles.
    pub const num_col: u8 = 15;
    pub const btl_num_row: u8 = 8;
    pub const msg_num_row: u8 = 12;

    /// R/G/B letters written to $bb1e / $bb9e / $bc1e → col 15, rows 20/22/24.
    pub const rgb_col: u8 = 15;
    pub const rgb_rows = [_]u8{ 20, 22, 24 };
    /// ColorTicksTbl @ $bb22 / $bba2 / $bc22 → col 17, same rows.
    pub const tick_col: u8 = 17;
    /// Color component cursor: x = comp*2+$86, y = $a0/$b0/$c0 (always drawn).
    pub const color_cursor_x0: i32 = 0x86;
    pub fn colorCursorX(comp: u8) i32 {
        const c: i32 = @min(@as(i32, comp), 31);
        return color_cursor_x0 + c * 2;
    }
    pub fn colorCursorY(rgb_i: u8) i32 {
        // Index 3..5 of cursor_y_tbl ($a0/$b0/$c0). Use usize — `3 + @min(u8,…)`
        // is a checked u8 add in Zig and panics for rgb_i ≥ 1.
        const i: usize = 3 + @as(usize, @min(rgb_i, 2));
        return cursor_y_tbl[i];
    }
};

// =============================================================================
// Save (save.asm / load.asm slot list)
// =============================================================================

pub const save = struct {
    pub const label_col: u8 = 3;
    pub const label_row: u8 = 1;
    /// SaveSlotWindow def_window 0,0,29,5 — each slot band; stacked by DrawSaveSlot.
    pub const slot_l: u8 = 0;
    pub const slot_t0: u8 = 0;
    pub const slot_iw: u8 = 29;
    pub const slot_ih: u8 = 5;
    /// Four SRAM slots + optional new game — host uses 0..3; 40px pitch from SelectChar-like.
    /// Load/save list: DrawSaveSlot advances ~5 tiles each → 40 px.
    pub const slot_pitch_y: i32 = 5 * 8;
    pub const msg_l: u8 = 22;
    pub const msg_t: u8 = 10;
    pub const msg_iw: u8 = 7;
    pub const msg_ih: u8 = 2;
    /// Confirm yes/no cursor x=$b8, y=$30/$40 (ConfirmSaveSlot)
    pub const confirm_cursor_x: i32 = 0xB8;
    pub const confirm_yes_y: i32 = 0x30;
    pub const confirm_no_y: i32 = 0x40;
};

// =============================================================================
// Msg notice (host-only chrome; no ROM field for transient field-menu toast)
// Prefer ItemMsgWindow: 8,10,13,2 when showing item errors.
// =============================================================================

pub const item_msg = struct {
    pub const left: u8 = 8;
    pub const top: u8 = 10;
    pub const iw: u8 = 13;
    pub const ih: u8 = 2;
    pub const text_col: u8 = 9;
    pub const text_row: u8 = 11;
};
