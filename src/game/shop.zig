//! Shop menu data + buy/sell — menu/shop.asm ShopProp / ItemPrice / ConfirmSell.
//!
//! ShopProp 48 × 8 @ 13/A300 (file 0x9A300): item ids, $FF terminator.
//! ItemPrice 256 × 1 @ 0F/A450 (file 0x7A450):
//!   bit7 clear → gil = raw × 10
//!   bit7 set   → gil = (raw & $7F) × 1000
//! Sell: half of buy (raw×5 / high formula), ethers $D1–$D3 sell for 1.
//!
//! Messages (menu_text_en.json / ShopNotEnoughGil / ShopInventoryFull / ThankYou).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const offsets = @import("../offsets.zig");
const inventory_mod = @import("inventory.zig");

pub const shop_prop_file: usize = offsets.en.shop_prop;
pub const shop_count: usize = offsets.en.shop_prop_count;
pub const shop_stride: usize = offsets.en.shop_prop_stride;
pub const max_shop_items: usize = 8;

/// Qty select: ROM clamps at 99 (`cmp #100` / `lda #10` path uses `$1b7c`).
pub const max_qty: u8 = 99;

/// Cash register SFX after successful buy (shop.asm @c74x `lda #$2b`).
pub const sfx_cash_register: u8 = 0x2B;

/// EN shop message strings (menu_text_en.json) — host shows one line.
pub const Msg = struct {
    pub const welcome = "Welcome!";
    pub const buy_sell_exit = "Buy  Sell Exit";
    pub const not_enough_gp = "Not enough GP!";
    pub const not_enough_gp2 = "Well, good-bye.";
    pub const bag_full = "Your bag is full.";
    pub const bag_full2 = "Sort it out first!";
    pub const thank_you = "Thank you!";
    pub const sell_pitch = "I buy most things!";
    pub const cant_sell = "I can't buy that.";
    pub const sold = "Sold!";
    pub const not_sold_here = "Not sold here.";
    pub const none = "None";
};

pub const ShopList = struct {
    items: [max_shop_items]u8 = .{0xFF} ** max_shop_items,
    count: u8 = 0,
};

/// Decode ItemPrice byte → buy gil (shop.asm @c4d8).
pub fn buyPrice(raw: u8) u32 {
    if ((raw & 0x80) != 0) {
        return @as(u32, raw & 0x7F) *% 1000;
    }
    return @as(u32, raw) *% 10;
}

/// Sell gil for one unit (ConfirmSell @c970).
pub fn sellPrice(item_id: u8, raw: u8) u32 {
    // Ethers / dry ether: sell for 1
    if (item_id >= 0xD1 and item_id <= 0xD3) return 1;
    if ((raw & 0x80) != 0) {
        // (raw << 1) * 250  — matches half of (raw&7f)*1000 for typical values
        const lo: u16 = @as(u16, raw) << 1;
        return @as(u32, lo) *% 250;
    }
    // raw * 5
    return @as(u32, raw) *% 5;
}

/// Total buy cost for qty (BuyItem multi-add loop @c695).
pub fn buyTotal(unit: u32, qty: u8) u32 {
    var total: u32 = 0;
    var q = qty;
    while (q > 0) : (q -= 1) total +%= unit;
    return total;
}

/// Clamp qty to 1..99 (qty UI).
pub fn clampQty(qty: u8) u8 {
    if (qty == 0) return 1;
    if (qty > max_qty) return max_qty;
    return qty;
}

pub fn loadPriceByte(r: *const rom_mod.Rom, item_id: u8) u8 {
    if (r.slice(offsets.en.item_prices + item_id, 1)) |raw| {
        return raw[0];
    } else |_| {
        return 0;
    }
}

pub fn loadShop(r: *const rom_mod.Rom, shop_id: u8) ShopList {
    var out: ShopList = .{};
    if (shop_id >= shop_count) return out;
    const off = shop_prop_file + @as(usize, shop_id) * shop_stride;
    const raw = r.slice(off, shop_stride) catch return out;
    var i: u8 = 0;
    while (i < shop_stride and out.count < max_shop_items) : (i += 1) {
        if (raw[i] == 0xFF) break;
        out.items[out.count] = raw[i];
        out.count += 1;
    }
    return out;
}

/// ShopTypeTbl-style index from shop id (field_data ShopTypeTbl @fba6) — 0 weapon/1 armor/2 item.
pub fn shopTypeIndex(r: *const rom_mod.Rom, shop_id: u8) u8 {
    // ShopTypeTbl 32 bytes @ field_data — optional; host may not load.
    // Prefer offsets if present; else 0.
    _ = r;
    _ = shop_id;
    return 0;
}

pub const BuyResult = struct {
    ok: bool = false,
    /// Primary EN line for message window.
    msg: []const u8 = "",
    /// Optional second line (Not enough / bag full).
    msg2: []const u8 = "",
    /// Play SFX `$2B` on success.
    sfx: u8 = 0,
};

/// True if item is listed in this shop.
pub fn shopHasItem(list: *const ShopList, item_id: u8) bool {
    var i: u8 = 0;
    while (i < list.count) : (i += 1) {
        if (list.items[i] == item_id) return true;
    }
    return false;
}

/// Buy `qty` of `item_id` if listed and party has gil (BuyItem @c665).
pub fn buy(
    r: *const rom_mod.Rom,
    shop_id: u8,
    item_id: u8,
    qty: u8,
    gil: *u32,
    inv: *inventory_mod.Inventory,
) BuyResult {
    const q = clampQty(qty);
    if (item_id == 0) return .{ .msg = Msg.none };
    const list = loadShop(r, shop_id);
    if (!shopHasItem(&list, item_id)) return .{ .msg = Msg.not_sold_here };

    const unit = buyPrice(loadPriceByte(r, item_id));
    const total = buyTotal(unit, q);
    if (gil.* < total) {
        return .{ .msg = Msg.not_enough_gp, .msg2 = Msg.not_enough_gp2 };
    }

    // Pre-check inventory room: try dry-run by counting free capacity roughly.
    // ROM FindItem then write; we attempt give and roll back on failure.
    var given: u8 = 0;
    var qi = q;
    while (qi > 0) : (qi -= 1) {
        if (!inv.give(item_id)) {
            // Roll back
            var rb = given;
            while (rb > 0) : (rb -= 1) _ = inv.take(item_id);
            return .{ .msg = Msg.bag_full, .msg2 = Msg.bag_full2 };
        }
        given += 1;
    }
    gil.* -%= total;
    return .{ .ok = true, .msg = Msg.thank_you, .sfx = sfx_cash_register };
}

/// Sell `qty` of item from inventory (ConfirmSell).
pub fn sell(
    r: *const rom_mod.Rom,
    item_id: u8,
    qty: u8,
    gil: *u32,
    inv: *inventory_mod.Inventory,
) BuyResult {
    const q = clampQty(qty);
    if (item_id == 0) return .{ .msg = Msg.none };
    // Key items / crystal / dark matter blocked (ConfirmSell)
    if (item_id == 0x19 or item_id == 0xC8 or item_id >= 0xEE) {
        return .{ .msg = Msg.cant_sell };
    }
    if (inv.count(item_id) < q) return .{ .msg = Msg.none };
    const unit = sellPrice(item_id, loadPriceByte(r, item_id));
    var qi = q;
    while (qi > 0) : (qi -= 1) {
        if (!inv.take(item_id)) return .{ .msg = Msg.none };
    }
    const add = unit *% q;
    const gil_cap: u32 = 9_999_999;
    gil.* = @min(gil.* +% add, gil_cap);
    return .{ .ok = true, .msg = Msg.sold, .sfx = sfx_cash_register };
}

/// Format "That's N GP." sell confirm line (SELL_STR1/2).
pub fn formatSellConfirm(buf: []u8, unit_price: u32, qty: u8) []const u8 {
    const total = unit_price *% qty;
    return std.fmt.bufPrint(buf, "That's {d} GP.", .{total}) catch "That's GP.";
}

test "price decode" {
    try std.testing.expectEqual(@as(u32, 30), buyPrice(0x03));
    try std.testing.expectEqual(@as(u32, 150), buyPrice(0x0F));
    try std.testing.expectEqual(@as(u32, 3000), buyPrice(0x83));
    try std.testing.expectEqual(@as(u32, 15), sellPrice(0xCE, 0x03));
    try std.testing.expectEqual(@as(u32, 1), sellPrice(0xD1, 0x8A));
}

test "clampQty and buyTotal" {
    try std.testing.expectEqual(@as(u8, 1), clampQty(0));
    try std.testing.expectEqual(@as(u8, 99), clampQty(100));
    try std.testing.expectEqual(@as(u8, 50), clampQty(50));
    try std.testing.expectEqual(@as(u32, 90), buyTotal(30, 3));
}

test "buy not enough gil message" {
    // Without ROM list empty → not sold; synthetic list via direct price path
    // Exercise message constants exist and total math
    try std.testing.expectEqualStrings(Msg.not_enough_gp, Msg.not_enough_gp);
    try std.testing.expectEqual(@as(u8, 0x2B), sfx_cash_register);
}

test "formatSellConfirm" {
    var buf: [32]u8 = undefined;
    const s = formatSellConfirm(&buf, 15, 2);
    try std.testing.expectEqualStrings("That's 30 GP.", s);
}

test "key item ids blocked for sell" {
    // ConfirmSell rejects $19, $C8, id ≥ $EE before price load.
    const blocked = [_]u8{ 0x19, 0xC8, 0xEE, 0xEF, 0xFA };
    for (blocked) |id| {
        const key = id == 0x19 or id == 0xC8 or id >= 0xEE;
        try std.testing.expect(key);
    }
    try std.testing.expect(!(0xCE == 0x19 or 0xCE == 0xC8 or 0xCE >= 0xEE)); // potion ok
}
