//! Auto-scrolling dialogue — `$cb` flag (window.asm OpenDlgWindow @b344 / Special_09).
//!
//! When `$cb != 0`:
//! - Skip WaitKeyUp/WaitKeyDown between DecodeDlgText pages
//! - `$07 = $10` page units; each WaitVblankLong: if `($7a & $1f)==0` then `dec $07`
//! - Line scroll: if `($7a & $07)==0` then `inc $bb` (BG3 VOFS; host residual)
//! - When `$07` hits 0 → next DecodeDlgText page (or CloseDlgWindow)
//!
//! Normal path (`$cb==0`): each wait does `$bb+=4` and `dec $07` (16 waits/page).
const std = @import("std");

/// OpenDlgWindow `@b367`: `lda #$10 / sta $07`.
pub const page_units_init: u8 = 0x10;

/// Auto path: `$7a & $1f == 0` → dec `$07` (every 32 frames).
pub const unit_period: u8 = 0x20;

/// Auto path: `$7a & $07 == 0` → inc `$bb` (every 8 frames).
pub const line_period: u8 = 0x08;

/// Fields to advance one DecodeDlgText page under auto-scroll: 16 × 32 = 512.
pub const fields_per_page: u16 = @as(u16, page_units_init) * @as(u16, unit_period);

/// Pure tick of the auto-scroll wait loop body (one WaitVblankLong).
/// `frame` is `$7a` after `inc $7a` (or host party_frame stand-in).
/// Returns updated units, whether a line-scroll happened, and whether the page wait finished.
pub fn tickAutoScrollWait(frame: u8, units_left: u8) struct {
    units: u8,
    line_scroll: bool,
    page_done: bool,
} {
    if (units_left == 0) return .{ .units = 0, .line_scroll = false, .page_done = true };
    var units = units_left;
    const line = (frame & (line_period - 1)) == 0;
    if ((frame & (unit_period - 1)) == 0) {
        units -%= 1;
    }
    return .{ .units = units, .line_scroll = line, .page_done = units == 0 };
}

/// Normal (key-wait) path body: always dec units once per wait.
pub fn tickKeyWait(units_left: u8) struct { units: u8, page_done: bool } {
    if (units_left == 0) return .{ .units = 0, .page_done = true };
    const u = units_left -% 1;
    return .{ .units = u, .page_done = u == 0 };
}

test "auto-scroll page finishes after 16 unit periods" {
    var units: u8 = page_units_init;
    var frame: u8 = 0;
    var waits: usize = 0;
    while (true) {
        // Host/ROM: $7a increments each vblank; sample after inc.
        frame +%= 1;
        const r = tickAutoScrollWait(frame, units);
        units = r.units;
        waits += 1;
        if (r.page_done) break;
        try std.testing.expect(waits < 600);
    }
    // 16 decrements at frames where frame&$1f==0 → first at frame 32, last at 512.
    try std.testing.expectEqual(@as(usize, 512), waits);
    try std.testing.expectEqual(@as(u8, 0), units);
}

test "key-wait page is 16 waits" {
    var units: u8 = page_units_init;
    var n: usize = 0;
    while (true) {
        const r = tickKeyWait(units);
        units = r.units;
        n += 1;
        if (r.page_done) break;
    }
    try std.testing.expectEqual(@as(usize, 16), n);
}

test "line scroll every 8 frames during auto" {
    // frame 8: line; frame 16: line; frame 7: no
    try std.testing.expect(tickAutoScrollWait(8, 16).line_scroll);
    try std.testing.expect(tickAutoScrollWait(16, 16).line_scroll);
    try std.testing.expect(!tickAutoScrollWait(7, 16).line_scroll);
    try std.testing.expect(!tickAutoScrollWait(9, 16).line_scroll);
}

test "fields_per_page constant" {
    try std.testing.expectEqual(@as(u16, 512), fields_per_page);
}
