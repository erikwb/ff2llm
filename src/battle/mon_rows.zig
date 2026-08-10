//! UpdateMonsterRows — btlgfx.asm @e988 pure left-column mask for mon name plate / row.
//!
//! Sets `$35eb[x]=$80` then clears to 0 when mon x is rightmost among present types.
//! Host uses `row_front[i]` true when mon should draw name/priority front.
const std = @import("std");

pub const mon_slots: usize = 8;

/// Result: for each mon slot, true = front row (name plate eligible / left-most column set).
/// Decomp: `$35eb,x = 0` means front (leftmost), `$80` means back.
pub fn updateMonsterRows(
    /// Per-slot present (not `$ff` type empty).
    present: *const [mon_slots]bool,
    /// Screen/left X for each mon (`GetMonsterLeftPos` result).
    left_x: *const [mon_slots]i16,
) [mon_slots]bool {
    // Find minimum left_x among present (leftmost column).
    var min_x: i16 = std.math.maxInt(i16);
    var any = false;
    var i: usize = 0;
    while (i < mon_slots) : (i += 1) {
        if (!present[i]) continue;
        any = true;
        if (left_x[i] < min_x) min_x = left_x[i];
    }
    var front: [mon_slots]bool = .{false} ** mon_slots;
    if (!any) return front;

    // Decomp: for each mon, if left_pos-1 >= min_left then clear front flag (back).
    // `dec / cmp $02 / bcc` → if (left-1) < min then keep $80 (back); else front=0.
    // Actually: sta $35eb,$80 initially (back), then if left-1 >= min_x set to 0 (front).
    // Wait: `dec / cmp $02 / bcc @e9c8` then `clr_a / sta $35eb,x`
    // bcc skips clear when (left-1) < min → stays $80 (back).
    // When (left-1) >= min → clear to 0 (front).
    // min is the leftmost mon's left pos. For leftmost mon: left-1 < left = min → bcc → back?
    // That would mark leftmost as BACK. Let me re-read.
    //
    // @e9a8: lda $f333,x ; first non-ff type index as reference?
    // Actually first loop finds first present mon type y, GetMonsterLeftPos → $02 = leftmost reference.
    // Second loop: for each present mon, GetMonsterLeftPos; dec; cmp $02; bcc skip; sta 0.
    // So if (left_pos - 1) >= ref_left → front (0).
    // Leftmost mon: left = ref, left-1 < ref → bcc → stays $80 = NOT front.
    //
    // That seems inverted for "front row". Looking at variable name $35eb and comment
    // "monster rows" — maybe $80 means "draw name" / selected column?
    //
    // From usage: often "front" monsters are those in the left column of multi-column
    // formations (name plate only for front column). Leftmost column should be front.
    //
    // Re-read more carefully:
    // @e997: find first mon with type != $ff, get its left pos into $02
    // @e9b4: for each mon with type != $ff:
    //   get left pos into A
    //   dec A
    //   cmp $02
    //   bcc @e9c8  ; if A < $02 skip
    //   stz $35eb,x
    //
    // First mon in type order sets $02. If formation has mon at x=10 and x=40,
    // ref=$10. Mon at 10: 9 < 10 → skip → $80. Mon at 40: 39 >= 10 → clear → 0.
    // So RIGHT mons get 0, LEFT get $80. So $80 = left column = front for nameplates?
    // Host uses front=true for $80 (left column).

    i = 0;
    while (i < mon_slots) : (i += 1) {
        if (!present[i]) {
            front[i] = false;
            continue;
        }
        // left-1 < min → keep $80 → front for name plate (left column)
        // left-1 >= min → $00 → back
        const adj = left_x[i] -% 1;
        front[i] = adj < min_x;
        // For leftmost: adj = min-1 < min → true. Good.
        // For right: adj = right-1 >= min usually → false. Good.
    }
    return front;
}

/// Simpler host helper: mon is front if its left_x equals the minimum among present.
pub fn isLeftColumn(present: *const [mon_slots]bool, left_x: *const [mon_slots]i16, slot: usize) bool {
    if (slot >= mon_slots or !present[slot]) return false;
    const rows = updateMonsterRows(present, left_x);
    return rows[slot];
}

test "left column mon is front" {
    var present = [_]bool{ true, true, false, false, false, false, false, false };
    var xs = [_]i16{ 40, 80, 0, 0, 0, 0, 0, 0 };
    const rows = updateMonsterRows(&present, &xs);
    try std.testing.expect(rows[0]); // left
    try std.testing.expect(!rows[1]); // right
}

test "single mon is front" {
    var present = [_]bool{ false, true, false, false, false, false, false, false };
    var xs = [_]i16{ 0, 64, 0, 0, 0, 0, 0, 0 };
    const rows = updateMonsterRows(&present, &xs);
    try std.testing.expect(rows[1]);
}

test "empty all back" {
    var present = [_]bool{false} ** 8;
    var xs = [_]i16{0} ** 8;
    const rows = updateMonsterRows(&present, &xs);
    for (rows) |f| try std.testing.expect(!f);
}

test "three column formation" {
    var present = [_]bool{ true, true, true, false, false, false, false, false };
    var xs = [_]i16{ 20, 50, 80, 0, 0, 0, 0, 0 };
    const rows = updateMonsterRows(&present, &xs);
    try std.testing.expect(rows[0]);
    try std.testing.expect(!rows[1]);
    try std.testing.expect(!rows[2]);
}
