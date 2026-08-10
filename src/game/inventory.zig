//! Party inventory ($1440, 48 slots × {id, qty}).
//!
//! Key/event items are $EC–$FA (Pass, Baron Key, Magma, Luca, Tower, …).
//! GiveItem / TakeItem / FindItem mirror field/trigger.asm.
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");

pub const slot_count: usize = 48;
/// First event/key item id (menu treats $EC+ specially).
pub const key_item_min: u8 = 0xEC;
/// Last standard key item before sort/trash markers.
pub const key_item_max: u8 = 0xFA;

pub const ItemId = enum(u8) {
    none = 0,
    pass = 0xEC,
    whistle = 0xED,
    package = 0xEE,
    baron_key = 0xEF,
    sand_ruby = 0xF0,
    earth_crystal = 0xF1,
    magma_key = 0xF2,
    luca_key = 0xF3,
    twin_harp = 0xF4,
    darkness_crystal = 0xF5,
    rat_tail = 0xF6,
    adamant = 0xF7,
    pan = 0xF8,
    pink_tail = 0xF9,
    tower_key = 0xFA,
    _,
};

pub const Slot = struct {
    id: u8 = 0,
    qty: u8 = 0,
};

pub const Inventory = struct {
    slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,

    pub fn clear(self: *Inventory) void {
        self.slots = [_]Slot{.{}} ** slot_count;
    }

    pub fn isKeyItem(id: u8) bool {
        return id >= key_item_min and id <= key_item_max;
    }

    /// Quantity of `id` across all stacks (0 if absent).
    pub fn count(self: *const Inventory, id: u8) u16 {
        if (id == 0) return 0;
        var total: u16 = 0;
        for (self.slots) |s| {
            if (s.id == id) total += s.qty;
        }
        return total;
    }

    pub fn has(self: *const Inventory, id: u8) bool {
        return self.count(id) > 0;
    }

    /// GiveItem: stack up to 99; arrows $54–$5F grant 10. Returns false if inventory full.
    pub fn give(self: *Inventory, id: u8) bool {
        if (id == 0 or id == 0xFF) return false;
        var add: u8 = 1;
        if (id >= 0x54 and id < 0x60) add = 10;

        // Existing stack with room
        for (&self.slots) |*s| {
            if (s.id == id and s.qty < 99) {
                const room: u8 = 99 - s.qty;
                const n = @min(add, room);
                s.qty += n;
                add -= n;
                if (add == 0) return true;
            }
        }
        // New slot(s)
        while (add > 0) {
            const empty = self.findEmpty() orelse return false;
            const n = @min(add, @as(u8, 99));
            self.slots[empty] = .{ .id = id, .qty = n };
            add -= n;
        }
        return true;
    }

    /// Remove one (or all of a key item stack). Returns false if not found.
    pub fn take(self: *Inventory, id: u8) bool {
        if (id == 0) return false;
        for (&self.slots) |*s| {
            if (s.id != id or s.qty == 0) continue;
            if (s.qty <= 1 or isKeyItem(id)) {
                s.* = .{};
            } else {
                s.qty -= 1;
            }
            return true;
        }
        return false;
    }

    fn findEmpty(self: *const Inventory) ?usize {
        for (self.slots, 0..) |s, i| {
            if (s.id == 0) return i;
        }
        return null;
    }

    /// ItemName[0] icon tile index in WindowGfx (DrawInventoryItemText).
    pub fn itemIcon(r: *const rom_mod.Rom, id: u8) u8 {
        if (id == 0) return 0xFF;
        const base = offsets.en.item_names + @as(usize, id) * offsets.en.item_name_stride;
        const raw = r.slice(base, 1) catch return 0xFF;
        return raw[0];
    }

    /// Decode item name from ROM (icon byte + 8 chars).
    pub fn itemName(r: *const rom_mod.Rom, id: u8, buf: []u8) []const u8 {
        if (id == 0 or buf.len == 0) {
            if (buf.len > 0) {
                buf[0] = '?';
                return buf[0..1];
            }
            return "";
        }
        const base = offsets.en.item_names + @as(usize, id) * offsets.en.item_name_stride;
        const raw = r.slice(base, offsets.en.item_name_stride) catch {
            const fb = "???";
            const n = @min(fb.len, buf.len);
            @memcpy(buf[0..n], fb[0..n]);
            return buf[0..n];
        };
        // raw[0] = icon; raw[1..] = name chars (FF padding)
        var out_i: usize = 0;
        var i: usize = 1;
        while (i < raw.len and out_i < buf.len) : (i += 1) {
            const ch = decodeItemChar(raw[i]) orelse continue;
            if (ch == ' ' and out_i == 0) continue;
            buf[out_i] = ch;
            out_i += 1;
        }
        while (out_i > 0 and buf[out_i - 1] == ' ') out_i -= 1;
        if (out_i == 0) {
            const fb = "Item";
            const n = @min(fb.len, buf.len);
            @memcpy(buf[0..n], fb[0..n]);
            return buf[0..n];
        }
        return buf[0..out_i];
    }

    fn decodeItemChar(b: u8) ?u8 {
        return switch (b) {
            0x42...0x5B => 'A' + (b - 0x42),
            0x5C...0x75 => 'a' + (b - 0x5C),
            0x80...0x89 => '0' + (b - 0x80),
            0xC0 => '\'',
            0xC1 => '.',
            0xC2 => '-',
            0xC4 => '!',
            0xC5 => '?',
            0xFF => ' ',
            0x00 => null,
            else => null,
        };
    }
};

test "inventory give has take key item" {
    var inv: Inventory = .{};
    try std.testing.expect(!inv.has(@intFromEnum(ItemId.baron_key)));
    try std.testing.expect(inv.give(@intFromEnum(ItemId.baron_key)));
    try std.testing.expect(inv.has(@intFromEnum(ItemId.baron_key)));
    try std.testing.expect(inv.take(@intFromEnum(ItemId.baron_key)));
    try std.testing.expect(!inv.has(@intFromEnum(ItemId.baron_key)));
}

test "inventory stack potions" {
    var inv: Inventory = .{};
    _ = inv.give(0xCE); // Cure1
    _ = inv.give(0xCE);
    try std.testing.expectEqual(@as(u16, 2), inv.count(0xCE));
}
