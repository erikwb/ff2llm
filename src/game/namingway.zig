//! Namingway menu pure logic — menu/namingway.asm + name.asm (EN).
//!
//! Flow (NamingwayMenu @ba1a):
//! 1. NamingwayYesNo — Yes/No cursor `$1b48` (0=Yes change name, 1=No)
//! 2. NameSelectChar — party slot `$1b4a`, skip empty (`$1000&$3f==0`)
//! 3. NameMenu — edit 6-tile name at `$1b0a`, confirm via END (`$1b06==NUM_ALPHA`)
//! 4. Copy buffer back to WRAM `$1500 + CharNameTbl[id-1]*6`
//!
//! CharacterName: 14 × 6 tiles @ ROM 0F/A710 → host `NameBank`.
const std = @import("std");
const offsets = @import("../offsets.zig");
const text_mod = @import("../text.zig");
const rom_mod = @import("../rom.zig");

pub const name_len: usize = 6;
pub const name_slot_count: usize = text_mod.char_name_count; // 14
/// EN NameMenu: alphabet 0 = Latin grid, 1 = END (`NUM_ALPHA = 1`).
pub const num_alpha_en: u8 = 1;
pub const alpha_cols: usize = 10;
pub const alpha_rows: usize = 8;

/// WRAM `$1500` CharacterName bank (14 names × 6 tiles, `$FF` pad).
pub const NameBank = struct {
    slots: [name_slot_count][name_len]u8 = [_][name_len]u8{[_]u8{0xFF} ** name_len} ** name_slot_count,

    /// New Game: copy CharacterName ROM table (`_01979b` mvn).
    pub fn loadFromRom(self: *NameBank, r: *const rom_mod.Rom) void {
        const raw = r.slice(text_mod.char_name_rom, name_slot_count * name_len) catch return;
        var i: usize = 0;
        while (i < name_slot_count) : (i += 1) {
            @memcpy(self.slots[i][0..], raw[i * name_len ..][0..name_len]);
        }
    }

    pub fn get(self: *const NameBank, slot: u8) [name_len]u8 {
        if (slot >= name_slot_count) return [_]u8{0xFF} ** name_len;
        return self.slots[slot];
    }

    pub fn set(self: *NameBank, slot: u8, name: *const [name_len]u8) void {
        if (slot >= name_slot_count) return;
        self.slots[slot] = name.*;
    }

    /// Decode slot to ASCII (trim `$FF`).
    pub fn decodeAscii(self: *const NameBank, slot: u8, buf: []u8) []const u8 {
        if (slot >= name_slot_count) return buf[0..0];
        return text_mod.decodeFixed(self.slots[slot][0..], buf);
    }
};

/// CharNameTbl index for 1-based char id (`$1000&$1F`) — menu.asm @8457.
pub fn nameSlotForCharId(char_id: u8) ?u8 {
    return offsets.en.charNameIndex(char_id);
}

/// EN Latin grid (menu_text_en.json LATIN_ALPHA_STR1..8) — 8×10 tiles as ASCII for host.
/// Empty cells (`\\pad`) are 0 so GetAlphaLetter returns Z.
pub const latin_grid: [alpha_rows][alpha_cols]u8 = .{
    .{ 'A', 'B', 'C', 'D', 'E', 'a', 'b', 'c', 'd', 'e' },
    .{ 'F', 'G', 'H', 'I', 'J', 'f', 'g', 'h', 'i', 'j' },
    .{ 'K', 'L', 'M', 'N', 'O', 'k', 'l', 'm', 'n', 'o' },
    .{ 'P', 'Q', 'R', 'S', 'T', 'p', 'q', 'r', 's', 't' },
    .{ 'U', 'V', 'W', 'X', 'Y', 'u', 'v', 'w', 'x', 'y' },
    .{ 'Z', '0', '1', '2', '3', 'z', '!', '?', '%', '/' },
    .{ '4', '5', '6', '7', '8', ':', 0, 0, 0, 0 },
    .{ '9', '\'', '.', '-', 0, 0, 0, 0, 0, 0 }, // … omitted as 0
};

/// Encode one ASCII character to EN font tile (text.zig inverse of decodeByte).
pub fn encodeAsciiByte(ch: u8) u8 {
    return switch (ch) {
        'A'...'Z' => 0x42 + (ch - 'A'),
        'a'...'z' => 0x5C + (ch - 'a'),
        '0'...'9' => 0x80 + (ch - '0'),
        '\'' => 0xC0,
        '.' => 0xC1,
        '-' => 0xC2,
        '/' => 0xC3,
        '!' => 0xC4,
        '?' => 0xC5,
        '%' => 0xC6,
        ':' => 0xC8,
        ' ' => 0xFF,
        else => 0xFF,
    };
}

/// Letter at (row,col) as ROM tile, or 0 if empty pad.
pub fn alphaLetterTile(row: u8, col: u8) u8 {
    if (row >= alpha_rows or col >= alpha_cols) return 0;
    const ch = latin_grid[row][col];
    if (ch == 0) return 0;
    return encodeAsciiByte(ch);
}

pub const Phase = enum {
    /// Yes / No on "change name?"
    yes_no,
    /// Pick party member
    select_char,
    /// Letter grid + END
    edit_name,
    /// Confirmed write-back done
    done,
    /// Declined or B-cancel without rename
    cancelled,
};

pub const Session = struct {
    phase: Phase = .yes_no,
    /// `$1b48` — 0=Yes, 1=No
    yes_cursor: u8 = 0,
    /// `$1b4a` party slot 0..4
    party_slot: u8 = 0,
    /// `$1b06` — 0=Latin, 1=END (EN)
    alpha_sel: u8 = 0,
    /// Letter grid cursor col/row (`$1b00` / `$1b01` stand-in)
    letter_col: u8 = 0,
    letter_row: u8 = 0,
    /// `$1b08` — index of last filled letter, or 0xFF if empty
    name_pos: u8 = 0xFF,
    /// `$1b0a` working name
    edit: [name_len]u8 = [_]u8{0xFF} ** name_len,
    /// Backup for RevertName (`$1b11`)
    backup: [name_len]u8 = [_]u8{0xFF} ** name_len,
    /// Name bank slot written on confirm
    target_name_slot: u8 = 0,

    /// Start NamingwayYesNo after EventCmd_d9.
    pub fn begin(self: *Session) void {
        self.* = .{};
        self.phase = .yes_no;
    }

    /// Present mask: party[i] occupied when `present[i]`.
    pub fn startSelectChar(self: *Session, present: *const [5]bool) void {
        self.phase = .select_char;
        self.party_slot = firstPresent(present) orelse 0;
    }

    /// Load edit buffer from name bank for char id; enter NameMenu.
    pub fn startEdit(self: *Session, bank: *const NameBank, char_id: u8) bool {
        const slot = nameSlotForCharId(char_id) orelse return false;
        self.target_name_slot = slot;
        self.edit = bank.get(slot);
        self.backup = self.edit;
        self.name_pos = lastFilledIndex(&self.edit);
        self.alpha_sel = 0;
        self.letter_col = 0;
        self.letter_row = 0;
        self.phase = .edit_name;
        return true;
    }

    /// Yes/No: left/right toggles `$1b48`.
    pub fn toggleYesNo(self: *Session) void {
        if (self.phase != .yes_no) return;
        self.yes_cursor ^= 1;
    }

    /// A on yes_no: Yes → select_char; No → cancelled.
    pub fn confirmYesNo(self: *Session, present: *const [5]bool) void {
        if (self.phase != .yes_no) return;
        if (self.yes_cursor != 0) {
            self.phase = .cancelled;
            return;
        }
        self.startSelectChar(present);
    }

    pub fn cancelYesNo(self: *Session) void {
        if (self.phase != .yes_no) return;
        self.phase = .cancelled;
    }

    /// Left/right on select_char — skip empty (NameSelectChar @bb52/@bb74).
    pub fn nextChar(self: *Session, present: *const [5]bool) void {
        if (self.phase != .select_char) return;
        self.party_slot = stepPresent(present, self.party_slot, 1);
    }

    pub fn prevChar(self: *Session, present: *const [5]bool) void {
        if (self.phase != .select_char) return;
        self.party_slot = stepPresent(present, self.party_slot, -1);
    }

    pub fn cancelSelect(self: *Session) void {
        if (self.phase != .select_char) return;
        self.phase = .cancelled;
    }

    /// A on select → startEdit (caller supplies char_id for slot).
    pub fn confirmSelect(self: *Session, bank: *const NameBank, char_id: u8) bool {
        if (self.phase != .select_char) return false;
        return self.startEdit(bank, char_id);
    }

    /// Up/down alphabet: 0 ↔ END (EN NUM_ALPHA=1).
    pub fn nextAlpha(self: *Session) void {
        if (self.phase != .edit_name) return;
        if (self.alpha_sel >= num_alpha_en) self.alpha_sel = 0 else self.alpha_sel += 1;
    }

    pub fn prevAlpha(self: *Session) void {
        if (self.phase != .edit_name) return;
        if (self.alpha_sel == 0) self.alpha_sel = num_alpha_en else self.alpha_sel -= 1;
    }

    /// Move letter cursor; skip empty cells (GetAlphaLetter==0).
    pub fn moveLetter(self: *Session, dcol: i8, drow: i8) void {
        if (self.phase != .edit_name or self.alpha_sel != 0) return;
        var c: i8 = @intCast(self.letter_col);
        var r: i8 = @intCast(self.letter_row);
        var tries: u8 = 0;
        while (tries < 80) : (tries += 1) {
            c += dcol;
            r += drow;
            if (c < 0 or c >= alpha_cols or r < 0 or r >= alpha_rows) {
                // Leave grid toward AlphaSelect (name.asm left/right edge)
                if (dcol != 0) {
                    self.alpha_sel = num_alpha_en;
                    return;
                }
                if (r < 0) r = @intCast(alpha_rows - 1);
                if (r >= alpha_rows) r = 0;
                if (c < 0) c = @intCast(alpha_cols - 1);
                if (c >= alpha_cols) c = 0;
            }
            const tile = alphaLetterTile(@intCast(r), @intCast(c));
            if (tile != 0) {
                self.letter_col = @intCast(c);
                self.letter_row = @intCast(r);
                return;
            }
        }
    }

    /// A while on letter grid: append tile (NameInput @9d0a).
    pub fn appendLetter(self: *Session) void {
        if (self.phase != .edit_name or self.alpha_sel != 0) return;
        const tile = alphaLetterTile(self.letter_row, self.letter_col);
        if (tile == 0) return;
        const next: u8 = if (self.name_pos == 0xFF) 0 else self.name_pos +% 1;
        if (next >= name_len) return;
        self.name_pos = next;
        self.edit[next] = tile;
    }

    /// B: clear last letter (NameInput @9d2c).
    pub fn backspace(self: *Session) void {
        if (self.phase != .edit_name) return;
        if (self.name_pos == 0xFF) return;
        self.edit[self.name_pos] = 0xFF;
        if (self.name_pos == 0) self.name_pos = 0xFF else self.name_pos -= 1;
    }

    /// A on END: confirm write if name non-empty, else RevertName + cancel.
    /// Returns true if bank was written.
    pub fn confirmEnd(self: *Session, bank: *NameBank) bool {
        if (self.phase != .edit_name) return false;
        if (self.alpha_sel != num_alpha_en) return false;
        if (self.name_pos == 0xFF) {
            // Empty → RevertName then exit without write
            self.edit = self.backup;
            self.phase = .cancelled;
            return false;
        }
        bank.set(self.target_name_slot, &self.edit);
        self.phase = .done;
        return true;
    }

    pub fn active(self: *const Session) bool {
        return self.phase == .yes_no or self.phase == .select_char or self.phase == .edit_name;
    }
};

fn lastFilledIndex(name: *const [name_len]u8) u8 {
    var last: u8 = 0xFF;
    var i: u8 = 0;
    while (i < name_len) : (i += 1) {
        if (name[i] != 0xFF) last = i;
    }
    return last;
}

fn firstPresent(present: *const [5]bool) ?u8 {
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        if (present[i]) return i;
    }
    return null;
}

fn stepPresent(present: *const [5]bool, from: u8, dir: i8) u8 {
    var slot = from % 5;
    var tries: u8 = 0;
    while (tries < 5) : (tries += 1) {
        if (dir >= 0) {
            slot +%= 1;
            if (slot >= 5) slot = 0;
        } else {
            if (slot == 0) slot = 4 else slot -= 1;
        }
        if (present[slot]) return slot;
    }
    return from % 5;
}

test "CharNameTbl Cecil Kain Rosa" {
    try std.testing.expectEqual(@as(?u8, 0), nameSlotForCharId(1)); // Cecil
    try std.testing.expectEqual(@as(?u8, 1), nameSlotForCharId(2)); // Kain
    try std.testing.expectEqual(@as(?u8, 3), nameSlotForCharId(4)); // Rosa (tbl[3]=3)
    try std.testing.expect(nameSlotForCharId(0) == null);
}

test "encode/decode round-trip Cecil tiles" {
    const tiles = [_]u8{
        encodeAsciiByte('C'),
        encodeAsciiByte('e'),
        encodeAsciiByte('c'),
        encodeAsciiByte('i'),
        encodeAsciiByte('l'),
        0xFF,
    };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("Cecil", text_mod.decodeFixed(tiles[0..], &buf));
}

test "Namingway yes→select→edit→confirm writes bank" {
    var bank: NameBank = .{};
    // Seed Cecil-like name in slot 0
    bank.slots[0] = .{
        encodeAsciiByte('C'),
        encodeAsciiByte('e'),
        encodeAsciiByte('c'),
        encodeAsciiByte('i'),
        encodeAsciiByte('l'),
        0xFF,
    };
    var s: Session = .{};
    s.begin();
    try std.testing.expectEqual(Phase.yes_no, s.phase);
    const present = [_]bool{ true, false, false, false, false };
    s.confirmYesNo(&present);
    try std.testing.expectEqual(Phase.select_char, s.phase);
    try std.testing.expectEqual(@as(u8, 0), s.party_slot);
    try std.testing.expect(s.confirmSelect(&bank, 1)); // char id 1 → slot 0
    try std.testing.expectEqual(Phase.edit_name, s.phase);
    // Append 'X' at (0,0)=A first — move to end row for X: row0 has no X; 'X' is row4 col3
    s.letter_row = 4;
    s.letter_col = 3;
    s.appendLetter();
    // name was Cecil (pos 4); append → pos 5
    try std.testing.expectEqual(@as(u8, 5), s.name_pos);
    try std.testing.expectEqual(encodeAsciiByte('X'), s.edit[5]);
    s.alpha_sel = num_alpha_en;
    try std.testing.expect(s.confirmEnd(&bank));
    try std.testing.expectEqual(Phase.done, s.phase);
    try std.testing.expectEqual(encodeAsciiByte('X'), bank.slots[0][5]);
}

test "Namingway No cancels" {
    var s: Session = .{};
    s.begin();
    s.toggleYesNo();
    try std.testing.expectEqual(@as(u8, 1), s.yes_cursor);
    const present = [_]bool{ true, false, false, false, false };
    s.confirmYesNo(&present);
    try std.testing.expectEqual(Phase.cancelled, s.phase);
}

test "select_char skips empty slots" {
    var s: Session = .{};
    s.begin();
    const present = [_]bool{ true, false, true, false, false };
    s.confirmYesNo(&present);
    try std.testing.expectEqual(@as(u8, 0), s.party_slot);
    s.nextChar(&present);
    try std.testing.expectEqual(@as(u8, 2), s.party_slot);
    s.nextChar(&present);
    try std.testing.expectEqual(@as(u8, 0), s.party_slot);
}

test "latin grid A and Z tiles" {
    try std.testing.expectEqual(encodeAsciiByte('A'), alphaLetterTile(0, 0));
    try std.testing.expectEqual(encodeAsciiByte('Z'), alphaLetterTile(5, 0));
    try std.testing.expectEqual(@as(u8, 0), alphaLetterTile(6, 6)); // pad
}

test "empty END reverts without write" {
    var bank: NameBank = .{};
    bank.slots[0][0] = encodeAsciiByte('A');
    var s: Session = .{};
    s.begin();
    const present = [_]bool{ true, false, false, false, false };
    s.confirmYesNo(&present);
    _ = s.confirmSelect(&bank, 1);
    // Clear name fully
    while (s.name_pos != 0xFF) s.backspace();
    s.alpha_sel = num_alpha_en;
    try std.testing.expect(!s.confirmEnd(&bank));
    try std.testing.expectEqual(Phase.cancelled, s.phase);
    try std.testing.expectEqual(encodeAsciiByte('A'), bank.slots[0][0]);
}
