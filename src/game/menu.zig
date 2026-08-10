//! Field main menu — menu/menu.asm MainMenuMain + MainMenuTbl.
//!
//! Options (MainOptionsWindow / menu_text_en.json):
//!   Item, Magic, Equip, Status, Order, Row, Config, Save
//! Layout from menu_data.asm def_window coords (tile units on 256×224).
const std = @import("std");
const rom_mod = @import("../rom.zig");
const window = @import("../battle/window.zig");
const cursor_mod = @import("../battle/cursor.zig");
const font_mod = @import("../gfx/font.zig");
const inventory_mod = @import("inventory.zig");
const audio_mod = @import("../audio/audio.zig");
const field_item = @import("field_item.zig");
const state_mod = @import("state.zig");
const shop_mod = @import("shop.zig");
const equip_class = @import("equip_class.zig");
const save_mod = @import("save.zig");
const cmd_magic = @import("../battle/cmd_magic.zig");
const offsets = @import("../offsets.zig");
const text_mod = @import("../text.zig");
const portraits_mod = @import("portraits.zig");
const L = @import("menu_layout.zig");

/// MainMenuTbl indices (menu.asm @8887).
pub const MainOption = enum(u8) {
    item = 0,
    magic = 1,
    equip = 2,
    status = 3,
    order = 4,
    row = 5,
    config = 6,
    save = 7,

    pub fn label(self: MainOption) []const u8 {
        return switch (self) {
            .item => "Item",
            .magic => "Magic",
            .equip => "Equip",
            .status => "Status",
            .order => "Order",
            .row => "Row",
            .config => "Config",
            .save => "Save",
        };
    }
};

pub const Screen = enum {
    main,
    item,
    /// ConfigMenu subset: battle speed $16ac (0..5).
    config,
    /// Shop buy list (event $ED).
    shop,
    /// Party target for item use.
    item_target,
    /// Status: SelectChar (party pick on main layout).
    status,
    /// Status detail: StatusWindow + StatusPortraitWindow (status.asm after SelectChar).
    status_view,
    /// Magic spell list (view).
    magic,
    /// Equip: party → slot → bag item.
    equip_party,
    equip_slot,
    equip_bag,
    /// Order: pick two party slots to swap.
    order,
    /// Save slot select 0..3.
    save,
};

pub const FieldMenu = struct {
    open: bool = false,
    screen: Screen = .main,
    /// $1a76 main cursor 0..7
    sel: u8 = 0,
    /// Item list scroll + cursor
    item_sel: u8 = 0,
    item_scroll: u8 = 0,
    /// Config: selected row (0 = battle speed).
    config_sel: u8 = 0,
    /// Shop id + cursor into shop list.
    shop_id: u8 = 0,
    shop_sel: u8 = 0,
    shop_list: shop_mod.ShopList = .{},
    /// 0 = buy shop stock, 1 = sell inventory.
    shop_mode: u8 = 0,
    /// Pending bag slot while choosing party target for item.
    pending_item_slot: usize = 0,
    item_target_sel: u8 = 0,
    /// Status/magic/equip/order party cursor.
    party_sel: u8 = 0,
    /// Equip slot 0=L-hand 1=R-hand 2=head 3=body 4=arms.
    equip_sel: u8 = 0,
    /// Order: first selected party index 0xFF = none.
    order_a: u8 = 0xFF,
    /// Magic column 0 white / 1 black / 2 call.
    magic_col: u8 = 0,
    magic_sel: u8 = 0,
    magic_list: [24]u8 = .{0xFF} ** 24,
    magic_count: u8 = 0,
    chrome: window.WindowChrome = .{},
    hand: cursor_mod.HandCursor = .{},
    font: font_mod.MenuFont = .{},
    portraits: portraits_mod.Portraits = .{},
    loaded: bool = false,
    pending_sys_sfx: u8 = 0,
    /// Game SFX (shop cash register `$2B`, etc.).
    pending_sfx: u8 = 0,
    msg: [48]u8 = undefined,
    msg_len: usize = 0,

    pub fn openShop(self: *FieldMenu, r: *const rom_mod.Rom, shop_id: u8) void {
        self.open = true;
        self.screen = .shop;
        self.shop_id = shop_id;
        self.shop_list = shop_mod.loadShop(r, shop_id);
        self.shop_sel = 0;
        self.shop_mode = 0;
        self.msg_len = 0;
        self.queueSys(audio_mod.sys_sfx_confirm);
    }

    /// EquipSlotRangeTbl — see equip_class.equip_slot_range_tbl.

    /// menu_text_en.json EQUIP_SLOT*_STR (def_ptxt on EquipWindow).
    fn equipSlotName(slot: u8) []const u8 {
        return switch (slot) {
            0 => "RHand",
            1 => "LHand",
            2 => "Head",
            3 => "Body",
            4 => "Arms",
            else => "?",
        };
    }

    /// EquipSlotPtrTbl @c0d1: $33 RH, $35 LH, $30 head, $31 body, $32 arms.
    fn getEquipId(m: *const state_mod.PartyMember, slot: u8) u8 {
        return switch (slot) {
            0 => m.right_hand,
            1 => m.left_hand,
            2 => m.head,
            3 => m.body,
            4 => m.arms,
            else => 0,
        };
    }

    fn setEquipId(m: *state_mod.PartyMember, slot: u8, id: u8) void {
        switch (slot) {
            0 => m.right_hand = id,
            1 => m.left_hand = id,
            2 => m.head = id,
            3 => m.body = id,
            4 => m.arms = id,
            else => {},
        }
    }

    fn inEquipRange(item_id: u8, slot: u8) bool {
        return equip_class.slotAllowsId(slot, item_id);
    }

    pub fn load(self: *FieldMenu, r: *const rom_mod.Rom) void {
        self.chrome.load(r) catch {};
        self.hand.load(r) catch {};
        self.font.load(r) catch {};
        self.portraits.load(r);
        self.loaded = self.chrome.loaded and self.font.loaded;
    }

    pub fn openMenu(self: *FieldMenu) void {
        self.open = true;
        self.screen = .main;
        self.sel = 0;
        self.msg_len = 0;
        self.queueSys(audio_mod.sys_sfx_confirm);
    }

    /// Apply `$16aa` to chrome + font (shared WindowPal / UpdateWindowColor).
    pub fn applyWindowColor(self: *FieldMenu, color_snes: u16) void {
        self.chrome.applyWindowColor(color_snes);
        self.font.applyWindowColor(color_snes);
    }

    pub fn close(self: *FieldMenu) void {
        self.open = false;
        self.screen = .main;
        self.queueSys(audio_mod.sys_sfx_confirm);
    }

    fn queueSys(self: *FieldMenu, id: u8) void {
        self.pending_sys_sfx = id;
    }

    fn queueSfx(self: *FieldMenu, id: u8) void {
        self.pending_sfx = id;
    }

    pub fn consumeSysSfx(self: *FieldMenu) ?u8 {
        if (self.pending_sys_sfx == 0) return null;
        const s = self.pending_sys_sfx;
        self.pending_sys_sfx = 0;
        return s;
    }

    pub fn consumeSfx(self: *FieldMenu) ?u8 {
        if (self.pending_sfx == 0) return null;
        const s = self.pending_sfx;
        self.pending_sfx = 0;
        return s;
    }

    fn setMsg(self: *FieldMenu, m: []const u8) void {
        const n = @min(m.len, self.msg.len);
        if (n > 0) @memcpy(self.msg[0..n], m[0..n]);
        self.msg_len = n;
    }

    pub fn up(
        self: *FieldMenu,
        inv: *const inventory_mod.Inventory,
        party: ?[]const state_mod.PartyMember,
    ) void {
        if (!self.open) return;
        switch (self.screen) {
            .main => {
                if (self.sel == 0) self.sel = 7 else self.sel -= 1;
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .item => {
                if (self.item_sel >= 2) {
                    self.item_sel -= 2;
                    const row = self.item_sel / 2;
                    if (row < self.item_scroll) self.item_scroll = row;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
                _ = inv;
            },
            .config => {
                // SIMPLE_CONFIG: 6 rows (ConfigCursorYTbl).
                if (self.config_sel > 0) {
                    self.config_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .shop => {
                if (self.shop_sel > 0) {
                    self.shop_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .item_target => {
                self.moveItemTargetSel(party, -1);
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .equip_party, .status, .order => {
                self.movePartySel(party, -1);
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .save => {
                if (self.party_sel > 0) {
                    self.party_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .equip_slot => {
                if (self.equip_sel > 0) {
                    self.equip_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .equip_bag => {
                if (self.item_sel > 0) {
                    self.item_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .magic => {
                if (self.magic_sel > 0) {
                    self.magic_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            // status_view: WaitKeypress only (status.asm @ab70)
            .status_view => {},
        }
    }

    pub fn down(
        self: *FieldMenu,
        inv: *const inventory_mod.Inventory,
        party: ?[]const state_mod.PartyMember,
    ) void {
        if (!self.open) return;
        switch (self.screen) {
            .main => {
                self.sel = (self.sel + 1) % 8;
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .item => {
                const n = countItems(inv);
                if (n == 0) return;
                if (self.item_sel + 2 < n) {
                    self.item_sel += 2;
                } else if (self.item_sel + 1 < n) {
                    self.item_sel += 1;
                } else return;
                const row = self.item_sel / 2;
                const vis_rows: u8 = 11;
                if (row >= self.item_scroll + vis_rows) self.item_scroll = row - vis_rows + 1;
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .config => {
                if (self.config_sel + 1 < L.config.row_count) {
                    self.config_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .shop => {
                const lim: u8 = if (self.shop_mode == 0) self.shop_list.count else countItems(inv);
                if (lim > 0 and self.shop_sel + 1 < lim) {
                    self.shop_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .item_target => {
                self.moveItemTargetSel(party, 1);
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .equip_party, .status, .order => {
                self.movePartySel(party, 1);
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .save => {
                if (self.party_sel + 1 < save_mod.slot_count) {
                    self.party_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .equip_slot => {
                if (self.equip_sel < 4) {
                    self.equip_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .equip_bag => {
                const n = countItems(inv);
                if (n > 0 and self.item_sel + 1 < n) {
                    self.item_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .magic => {
                if (self.magic_count > 0 and self.magic_sel + 1 < self.magic_count) {
                    self.magic_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .status_view => {},
        }
    }

    /// Config fields — SIMPLE_CONFIG rows (US).
    pub const ConfigFields = struct {
        battle_speed: *u8,
        msg_speed: *u8,
        /// $16b6 stereo/mono
        stereo_mono: *u8,
        /// $16aa packed SNES color
        window_color: *u16,
        /// $1ba8–$1baa working RGB while on Config
        window_color_r: *u8,
        window_color_g: *u8,
        window_color_b: *u8,
    };

    pub fn left(
        self: *FieldMenu,
        inv: *const inventory_mod.Inventory,
        cfg: ?ConfigFields,
        party_row: ?*u8,
    ) void {
        if (!self.open) return;
        switch (self.screen) {
            .item => {
                if (self.item_sel % 2 == 1) {
                    self.item_sel -= 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .config => {
                if (cfg) |c| self.adjConfig(c, -1);
            },
            .shop => {
                // L: switch buy/sell
                self.shop_mode ^= 1;
                self.shop_sel = 0;
                self.queueSys(audio_mod.sys_sfx_cursor_move);
                _ = inv;
            },
            .magic => {
                if (self.magic_col > 0) {
                    self.magic_col -= 1;
                    self.magic_sel = 0;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            // ChangeOrderMain @ac08: left/right → eor $16a8 (row) while selecting.
            .order => self.toggleRowFromOrder(party_row),
            else => {},
        }
    }

    pub fn right(
        self: *FieldMenu,
        inv: *const inventory_mod.Inventory,
        cfg: ?ConfigFields,
        party_row: ?*u8,
    ) void {
        if (!self.open) return;
        switch (self.screen) {
            .item => {
                const n = countItems(inv);
                if (n == 0) return;
                if (self.item_sel % 2 == 0 and self.item_sel + 1 < n) {
                    self.item_sel += 1;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .config => {
                if (cfg) |c| self.adjConfig(c, 1);
            },
            .shop => {
                self.shop_mode ^= 1;
                self.shop_sel = 0;
                self.queueSys(audio_mod.sys_sfx_cursor_move);
            },
            .magic => {
                if (self.magic_col < 2) {
                    self.magic_col += 1;
                    self.magic_sel = 0;
                    self.queueSys(audio_mod.sys_sfx_cursor_move);
                }
            },
            .order => self.toggleRowFromOrder(party_row),
            else => {},
        }
    }

    /// Order menu L/R: ChangeRow flip of `$16a8` (order.asm @ac0f).
    fn toggleRowFromOrder(self: *FieldMenu, party_row: ?*u8) void {
        if (party_row) |pr| {
            pr.* = @import("order_row.zig").togglePartyRow(pr.*);
            self.queueSys(audio_mod.sys_sfx_confirm);
            self.setMsg(if (pr.* != 0) "Back row" else "Front row");
        }
    }

    fn adjConfig(self: *FieldMenu, c: ConfigFields, dir: i8) void {
        // SIMPLE_CONFIG left/right (config.asm @d256–@d332).
        switch (self.config_sel) {
            0 => { // $16ac battle speed 0..5
                if (dir < 0 and c.battle_speed.* > 0) c.battle_speed.* -= 1;
                if (dir > 0 and c.battle_speed.* < 5) c.battle_speed.* += 1;
            },
            1 => { // $16ad msg speed 0..5
                if (dir < 0 and c.msg_speed.* > 0) c.msg_speed.* -= 1;
                if (dir > 0 and c.msg_speed.* < 5) c.msg_speed.* += 1;
            },
            2 => { // ToggleStereoMono $16b6
                c.stereo_mono.* ^= 1;
            },
            3 => self.adjWindowColorComp(c, c.window_color_r, dir),
            4 => self.adjWindowColorComp(c, c.window_color_g, dir),
            5 => self.adjWindowColorComp(c, c.window_color_b, dir),
            else => {},
        }
        self.queueSys(audio_mod.sys_sfx_cursor_move);
    }

    /// Color component ±1 (0..$1f), then CalcWindowColor → $16aa + UpdateWindowColor.
    fn adjWindowColorComp(self: *FieldMenu, c: ConfigFields, comp: *u8, dir: i8) void {
        if (dir < 0) {
            if (comp.* > 0) comp.* -= 1 else return;
        } else {
            if (comp.* < 0x1F) comp.* += 1 else return;
        }
        // config.asm @d159–@d162 each frame after component change.
        c.window_color.* = window.WindowChrome.calcWindowColor(
            c.window_color_r.*,
            c.window_color_g.*,
            c.window_color_b.*,
        );
        self.chrome.applyWindowColor(c.window_color.*);
    }

    /// Entering Config: CalcColorComponents from $16aa (config.asm @d188).
    pub fn syncConfigColorFromState(self: *FieldMenu, c: ConfigFields) void {
        const comps = window.WindowChrome.calcColorComponents(c.window_color.*);
        c.window_color_r.* = comps.r;
        c.window_color_g.* = comps.g;
        c.window_color_b.* = comps.b;
        self.chrome.applyWindowColor(c.window_color.*);
    }

    /// `party_row` is config $16a8; `party`/`gs` for field use & save.
    pub fn confirm(
        self: *FieldMenu,
        inv: *inventory_mod.Inventory,
        party_row: ?*u8,
        cfg: ?ConfigFields,
        party: ?[]state_mod.PartyMember,
        rom: ?*const rom_mod.Rom,
        gil: ?*u32,
        gs: ?*state_mod.GameState,
    ) void {
        if (!self.open) return;
        switch (self.screen) {
            .main => {
                const opt: MainOption = @enumFromInt(self.sel);
                switch (opt) {
                    .item => {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .item;
                        self.item_sel = 0;
                        self.item_scroll = 0;
                        self.msg_len = 0;
                    },
                    .config => {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .config;
                        self.config_sel = 0;
                        self.msg_len = 0;
                        // config.asm @d188: ldx $16aa / CalcColorComponents before frame loop.
                        if (cfg) |c| self.syncConfigColorFromState(c);
                    },
                    .status => {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .status;
                        self.party_sel = firstPresentSlot(party);
                        self.msg_len = 0;
                    },
                    .magic => {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .magic;
                        self.party_sel = firstPresentSlot(party);
                        self.magic_col = 0;
                        self.magic_sel = 0;
                        self.msg_len = 0;
                    },
                    .equip => {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .equip_party;
                        self.party_sel = firstPresentSlot(party);
                        self.msg_len = 0;
                    },
                    .order => {
                        // ChangeOrder (order.asm @abf9): SelectChar ×2 then swap.
                        if (countPresent(party) < 2) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            self.setMsg("Need 2 members");
                            return;
                        }
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .order;
                        self.party_sel = firstPresentSlot(party);
                        self.order_a = 0xFF;
                        self.setMsg("Select");
                    },
                    .save => {
                        // ShowSaveMenu: `$1a02` must be set (save point / on foot OW).
                        if (gs) |g| {
                            if (!g.save_enabled) {
                                self.queueSys(audio_mod.sys_sfx_error);
                                self.setMsg("Cannot save here");
                                return;
                            }
                        }
                        self.screen = .save;
                        self.party_sel = 0; // save slot 0..3
                        self.msg_len = 0;
                        self.queueSys(audio_mod.sys_sfx_confirm);
                    },
                    .row => {
                        // ChangeRow @acde: eor #$01 on `$16a8` (InitCharRows).
                        if (party_row) |pr| pr.* = @import("order_row.zig").togglePartyRow(pr.*);
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        if (party_row) |pr| {
                            self.setMsg(if (pr.* != 0) "Back row lead" else "Front row lead");
                        } else {
                            self.setMsg("Row toggled");
                        }
                    },
                }
            },
            .item => {
                const slot = itemSlotAt(inv, self.item_sel) orelse {
                    self.queueSys(audio_mod.sys_sfx_error);
                    self.setMsg("No item");
                    return;
                };
                const id = inv.slots[slot].id;
                // Consumables $CE+ go to party target; equipment can't be "used"
                if (id < 0xCE) {
                    self.setMsg("Can't use here");
                    self.queueSys(audio_mod.sys_sfx_error);
                    return;
                }
                // ItemEffect_e2/$e3 tent/cottage (menu/item.asm @a855): requires `$1a02`
                // (save_enabled), set menu event → field ExecEvent $77/$78 + Special_05.
                // Host: heal party, consume item, FD $05 tent anim, close menu.
                if (id == 0xE2 or id == 0xE3) {
                    if (gs) |g| {
                        if (!g.save_enabled) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            self.setMsg("Cannot rest here");
                            return;
                        }
                        if (!inv.take(id)) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            self.setMsg("No item");
                            return;
                        }
                        if (party) |p| {
                            for (p) |*m| {
                                if (!m.present) continue;
                                m.hp = m.max_hp;
                                // Cottage $E3 restores MP; Tent $E2 HP only (common FF4 rule).
                                if (id == 0xE3) m.mp = m.max_mp;
                            }
                        }
                        g.startSpecial(0x05);
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.open = false;
                        self.msg_len = 0;
                        return;
                    }
                    self.queueSys(audio_mod.sys_sfx_error);
                    self.setMsg("Can't use here");
                    return;
                }
                // ItemEffect_e5 emergency exit / e6 dwarven bread (item.asm @a868/@a871):
                // need `$1a04` bits then menu event id = item − $e1 → ExecEvent $86 / $FB.
                if (id == 0xE5 or id == 0xE6) {
                    if (gs) |g| {
                        const fm = @import("field_magic.zig");
                        const on_sub = g.mode == .submap;
                        const prop_flags: u8 = if (g.sub) |*sm| sm.prop.flags else 0;
                        const flags = fm.computeMenuMapFlags(on_sub, prop_flags, g.vehicle);
                        const need: u8 = if (id == 0xE5) fm.MenuMapFlags.exit else fm.MenuMapFlags.sight;
                        if ((flags & need) == 0) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            self.setMsg("Can't use here");
                            return;
                        }
                        if (!inv.take(id)) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            self.setMsg("No item");
                            return;
                        }
                        // item_id − $e1 → menu event 4 (exit) or 5 (sight)
                        const me: fm.MenuEvent = if (id == 0xE5) .exit else .sight;
                        if (fm.eventIdForMenuEvent(me)) |eid| {
                            g.pending_menu_event = eid;
                            self.queueSys(audio_mod.sys_sfx_confirm);
                            self.open = false;
                            self.msg_len = 0;
                            return;
                        }
                    }
                    self.queueSys(audio_mod.sys_sfx_error);
                    self.setMsg("Can't use here");
                    return;
                }
                self.pending_item_slot = slot;
                self.item_target_sel = 0;
                self.screen = .item_target;
                self.msg_len = 0;
                self.queueSys(audio_mod.sys_sfx_confirm);
            },
            .item_target => {
                const id = inv.slots[self.pending_item_slot].id;
                if (party) |p| {
                    const ti: usize = self.item_target_sel;
                    if (ti >= p.len or !p[ti].present) {
                        self.setMsg("No target");
                        self.queueSys(audio_mod.sys_sfx_error);
                        return;
                    }
                    const ur = field_item.useOnParty(inv, p, ti, id, rom);
                    if (ur.ok) {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.setMsg(ur.msg);
                        self.screen = .item;
                    } else {
                        self.queueSys(audio_mod.sys_sfx_error);
                        self.setMsg(ur.msg);
                    }
                } else {
                    self.setMsg("Can't use here");
                    self.queueSys(audio_mod.sys_sfx_error);
                }
            },
            .shop => {
                if (rom) |r| {
                    if (gil) |g| {
                        if (self.shop_mode == 0) {
                            if (self.shop_sel < self.shop_list.count) {
                                const id = self.shop_list.items[self.shop_sel];
                                const br = shop_mod.buy(r, self.shop_id, id, 1, g, inv);
                                if (br.ok) {
                                    if (br.sfx != 0) self.queueSfx(br.sfx) else self.queueSys(audio_mod.sys_sfx_confirm);
                                    self.setMsg(br.msg);
                                } else {
                                    self.queueSys(audio_mod.sys_sfx_error);
                                    self.setMsg(br.msg);
                                }
                            }
                        } else {
                            // Sell mode: shop_sel indexes filled inventory
                            const bag = itemSlotAt(inv, self.shop_sel) orelse {
                                self.queueSys(audio_mod.sys_sfx_error);
                                self.setMsg("No item");
                                return;
                            };
                            const id = inv.slots[bag].id;
                            const br = shop_mod.sell(r, id, 1, g, inv);
                            if (br.ok) {
                                if (br.sfx != 0) self.queueSfx(br.sfx) else self.queueSys(audio_mod.sys_sfx_confirm);
                                self.setMsg(br.msg);
                                if (self.shop_sel > 0 and self.shop_sel >= countItems(inv))
                                    self.shop_sel -%= 1;
                            } else {
                                self.queueSys(audio_mod.sys_sfx_error);
                                self.setMsg(br.msg);
                            }
                        }
                    }
                }
            },
            .status => {
                // SelectChar A → StatusMenuMain detail (status.asm @a944).
                if (party) |p| {
                    if (slotOccupied(p, self.party_sel)) {
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .status_view;
                        self.msg_len = 0;
                    } else {
                        self.queueSys(audio_mod.sys_sfx_error);
                    }
                }
            },
            .status_view => {
                // WaitKeypress then back (status.asm @ab70) — A/B both leave via cancel path.
                self.queueSys(audio_mod.sys_sfx_confirm);
                self.screen = .status;
                self.msg_len = 0;
            },
            .magic => {
                // Field UseMagic (menu/magic.asm @b53d) — see field_magic.zig.
                if (rom) |r| {
                    if (party) |p| {
                        if (self.party_sel < p.len and p[self.party_sel].present) {
                            const m = &p[self.party_sel];
                            const list_id = cmd_magic.listIdFor(r, m.id, self.magic_col);
                            var list: [24]u8 = .{0xFF} ** 24;
                            var count: u8 = 0;
                            if (list_id != 0xFF and list_id < offsets.en.spell_list_init_count) {
                                const ram = if (gs) |g| &g.spell_lists else null;
                                count = cmd_magic.loadSpellListPreferRam(r, ram, list_id, &list);
                            }
                            if (self.magic_sel < count) {
                                const sid = list[self.magic_sel];
                                if (cmd_magic.loadSpell(r, sid)) |sp| {
                                    const fm = @import("field_magic.zig");
                                    // `$1a04` from CheckMenu (field.asm @8209).
                                    const menu_flags: u8 = if (gs) |g| blk: {
                                        const on_sub = g.mode == .submap;
                                        const prop_flags: u8 = if (g.sub) |*sm| sm.prop.flags else 0;
                                        break :blk fm.computeMenuMapFlags(on_sub, prop_flags, g.vehicle);
                                    } else 0;
                                    const prep = fm.prepareCast(sid, sp.mp_cost, m.mp, m.status1, m.will, false, menu_flags);
                                    switch (prep.result) {
                                        .no_mp => {
                                            self.setMsg("Not enough MP");
                                            self.queueSys(audio_mod.sys_sfx_error);
                                        },
                                        .not_field_spell, .battle_only => {
                                            self.setMsg("Only in battle");
                                            self.queueSys(audio_mod.sys_sfx_error);
                                        },
                                        .status_block => {
                                            self.setMsg("Can't cast");
                                            self.queueSys(audio_mod.sys_sfx_error);
                                        },
                                        .map_flag_block => {
                                            self.setMsg("Can't use here");
                                            self.queueSys(audio_mod.sys_sfx_error);
                                        },
                                        .ok => {
                                            m.mp -%= prep.mp_cost;
                                            if (prep.effect) |fe| {
                                                switch (fe) {
                                                    .cure1, .cure2, .cure3, .cure4 => {
                                                        m.hp = fm.applyCureHp(m.hp, m.max_hp, m.status1, prep.heal);
                                                        self.setMsg("Cast!");
                                                    },
                                                    .esuna => {
                                                        m.status1 = fm.esunaStatus1(m.status1);
                                                        m.status2 = fm.esunaStatus2(m.status2);
                                                        self.setMsg("Esuna");
                                                    },
                                                    .life => {
                                                        if ((m.status1 & 0x80) != 0) {
                                                            m.status1 = fm.life2ClearsDead(m.status1);
                                                            m.hp = fm.lifeHp(m.max_hp, m.will);
                                                        }
                                                        self.setMsg("Life");
                                                    },
                                                    .life2 => {
                                                        m.status1 = fm.life2ClearsDead(m.status1);
                                                        m.hp = m.max_hp;
                                                        self.setMsg("Life2");
                                                    },
                                                    .mini => {
                                                        m.status1 = fm.toggleStatusBit(m.status1, fm.mini_mask);
                                                        self.setMsg("Mini");
                                                    },
                                                    .toad => {
                                                        m.status1 = fm.toggleStatusBit(m.status1, fm.toad_mask);
                                                        self.setMsg("Toad");
                                                    },
                                                    .pig => {
                                                        m.status1 = fm.toggleStatusBit(m.status1, fm.pig_mask);
                                                        self.setMsg("Pig");
                                                    },
                                                    .float => {
                                                        m.status2 = fm.applyFloat(m.status2);
                                                        self.setMsg("Float");
                                                    },
                                                    .exit, .sight, .warp => {
                                                        // `$1a03` menu event → CheckMenu ExecEvent (field.asm @8241).
                                                        if (gs) |g| {
                                                            if (fm.eventIdForMenuEvent(prep.menu_event)) |eid| {
                                                                g.pending_menu_event = eid;
                                                                self.queueSys(audio_mod.sys_sfx_confirm);
                                                                self.open = false;
                                                                self.msg_len = 0;
                                                                return;
                                                            }
                                                        }
                                                        m.mp +%= prep.mp_cost;
                                                        self.setMsg("Can't use here");
                                                        self.queueSys(audio_mod.sys_sfx_error);
                                                        return;
                                                    },
                                                }
                                            }
                                            self.queueSys(audio_mod.sys_sfx_confirm);
                                            if (gs) |g| g.party_sprite_dirty = true;
                                        },
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .save => {
                if (gs) |g| {
                    const slot = self.party_sel;
                    if (slot < save_mod.slot_count) {
                        save_mod.saveSlot(g, slot) catch {
                            self.setMsg("Save failed");
                            self.queueSys(audio_mod.sys_sfx_error);
                            return;
                        };
                        self.setMsg("Game saved");
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        self.screen = .main;
                    }
                } else {
                    self.setMsg("Save failed");
                    self.queueSys(audio_mod.sys_sfx_error);
                }
            },
            .equip_party => {
                if (party) |p| {
                    if (self.party_sel < p.len and p[self.party_sel].present) {
                        self.screen = .equip_slot;
                        self.equip_sel = 0;
                        self.queueSys(audio_mod.sys_sfx_confirm);
                    } else {
                        self.queueSys(audio_mod.sys_sfx_error);
                    }
                }
            },
            .equip_slot => {
                self.screen = .equip_bag;
                self.item_sel = 0;
                self.queueSys(audio_mod.sys_sfx_confirm);
            },
            .equip_bag => {
                if (party) |p| {
                    if (self.party_sel >= p.len or !p[self.party_sel].present) return;
                    const m = &p[self.party_sel];
                    // Empty bag slot = unequip
                    const bag = itemSlotAt(inv, self.item_sel);
                    const new_id: u8 = if (bag) |b| inv.slots[b].id else 0;
                    if (new_id != 0) {
                        const other: u8 = if (self.equip_sel == 0)
                            m.left_hand
                        else if (self.equip_sel == 1)
                            m.right_hand
                        else
                            0;
                        if (rom) |r| {
                            const res = equip_class.checkItemEquip(
                                r,
                                new_id,
                                self.equip_sel,
                                m.class_id,
                                m.handedness,
                                other,
                            );
                            switch (res) {
                                .ok => {},
                                .two_hand_conflict => {
                                    self.setMsg("Two-hand conflict");
                                    self.queueSys(audio_mod.sys_sfx_error);
                                    return;
                                },
                                .reject => {
                                    self.setMsg("Can't equip");
                                    self.queueSys(audio_mod.sys_sfx_error);
                                    return;
                                },
                            }
                        } else if (!equip_class.slotAllowsId(self.equip_sel, new_id)) {
                            self.setMsg("Wrong slot");
                            self.queueSys(audio_mod.sys_sfx_error);
                            return;
                        }
                    }
                    const old = getEquipId(m, self.equip_sel);
                    // Swap: take from bag, put old in bag
                    if (new_id != 0) {
                        if (!inv.take(new_id)) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            return;
                        }
                    }
                    if (old != 0) {
                        if (!inv.give(old)) {
                            // restore
                            if (new_id != 0) _ = inv.give(new_id);
                            self.setMsg("Inventory full");
                            self.queueSys(audio_mod.sys_sfx_error);
                            return;
                        }
                    }
                    setEquipId(m, self.equip_sel, new_id);
                    self.setMsg("Equipped");
                    self.queueSys(audio_mod.sys_sfx_confirm);
                    self.screen = .equip_slot;
                }
            },
            .order => {
                if (party) |p| {
                    if (!slotOccupied(p, self.party_sel)) {
                        self.queueSys(audio_mod.sys_sfx_error);
                        return;
                    }
                    if (self.order_a == 0xFF) {
                        // 1st SelectChar → leave cursor2 on that char (order.asm @ac2e).
                        self.order_a = self.party_sel;
                        self.setMsg("Select");
                        self.queueSys(audio_mod.sys_sfx_confirm);
                    } else if (self.order_a == self.party_sel) {
                        // Same slot twice: re-pick first (order.asm @ac5a bra @ac2e).
                        self.order_a = 0xFF;
                        self.setMsg("Select");
                        self.queueSys(audio_mod.sys_sfx_confirm);
                    } else {
                        // Swap CharProp blocks + controller map (host: party slots only).
                        const a = self.order_a;
                        const b = self.party_sel;
                        if (!@import("order_row.zig").swapPartySlots(state_mod.PartyMember, p, a, b)) {
                            self.queueSys(audio_mod.sys_sfx_error);
                            return;
                        }
                        self.order_a = 0xFF;
                        self.setMsg("Changed");
                        self.queueSys(audio_mod.sys_sfx_confirm);
                        // Field leader sprite may have moved slots.
                        if (gs) |g| g.party_sprite_dirty = true;
                    }
                } else {
                    self.queueSys(audio_mod.sys_sfx_error);
                }
            },
            .config => {
                // Confirm leaves config (settings already applied live via L/R)
                self.queueSys(audio_mod.sys_sfx_confirm);
                self.screen = .main;
                if (cfg) |c| {
                    var buf: [40]u8 = undefined;
                    const sound = if ((c.stereo_mono.* & 1) != 0) "Mono" else "Stereo";
                    const m = std.fmt.bufPrint(&buf, "Spd{d} Msg{d} {s}", .{
                        c.battle_speed.* + 1,
                        c.msg_speed.* + 1,
                        sound,
                    }) catch "OK";
                    self.setMsg(m);
                }
            },
        }
    }

    pub fn cancel(self: *FieldMenu) void {
        if (!self.open) return;
        self.queueSys(audio_mod.sys_sfx_confirm);
        switch (self.screen) {
            .item, .config, .status, .magic, .equip_party, .order, .save => {
                self.screen = .main;
                self.msg_len = 0;
            },
            .status_view => {
                // Close status detail → SelectChar again (status.asm TransformWindow back).
                self.screen = .status;
                self.msg_len = 0;
            },
            .item_target => {
                self.screen = .item;
                self.msg_len = 0;
            },
            .equip_slot => {
                self.screen = .equip_party;
                self.msg_len = 0;
            },
            .equip_bag => {
                self.screen = .equip_slot;
                self.msg_len = 0;
            },
            .shop => self.close(),
            .main => self.close(),
        }
    }

    pub fn present(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        inv: *const inventory_mod.Inventory,
        gil: u32,
        rom: *const rom_mod.Rom,
        battle_speed: u8,
        msg_speed: u8,
        stereo_mono: u8,
        color_r: u8,
        color_g: u8,
        color_b: u8,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
        spell_lists: ?*const cmd_magic.SpellLists,
    ) void {
        if (!self.open) return;
        // Dim field
        var i: usize = 0;
        while (i + 3 < pixels.len) : (i += 4) {
            pixels[i] = pixels[i] / 3;
            pixels[i + 1] = pixels[i + 1] / 3;
            pixels[i + 2] = pixels[i + 2] / 3;
        }

        switch (self.screen) {
            .main => self.drawMain(pixels, dest_w, rom, party, party_row, gil),
            .item => self.drawItem(pixels, dest_w, inv, rom),
            .config => self.drawConfig(pixels, dest_w, battle_speed, msg_speed, stereo_mono, color_r, color_g, color_b),
            .shop => self.drawShop(pixels, dest_w, rom, gil, inv),
            .item_target => self.drawItemTarget(pixels, dest_w, rom, party, party_row),
            .status => self.drawStatusPick(pixels, dest_w, rom, party, party_row),
            .status_view => self.drawStatusView(pixels, dest_w, rom, party),
            .magic => self.drawMagic(pixels, dest_w, rom, party, spell_lists, party_row),
            .equip_party => self.drawPartyPick(pixels, dest_w, rom, party, party_row, "Equip"),
            .equip_slot => self.drawEquipSlots(pixels, dest_w, rom, party),
            .equip_bag => self.drawItem(pixels, dest_w, inv, rom),
            .order => self.drawPartyPick(pixels, dest_w, rom, party, party_row, "Order"),
            .save => self.drawSave(pixels, dest_w),
        }
        if (self.msg_len > 0) {
            // ItemMsgWindow: def_window 8,10,13,2 (also used for transient field notices).
            L.drawDef(&self.chrome, pixels, dest_w, L.item_msg.left, L.item_msg.top, L.item_msg.iw, L.item_msg.ih);
            self.font.drawAscii(
                pixels,
                dest_w,
                L.ptxtX(L.item_msg.text_col),
                L.ptxtY(L.item_msg.text_row),
                self.msg[0..self.msg_len],
            );
        }
    }

    /// DrawMainMenu / DrawCharsMainMenu + DrawAllPortraits (menu.asm @8897 / @8919).
    fn drawMain(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
        gil: u32,
    ) void {
        self.drawCharsAndPortraits(pixels, dest_w, rom, party, party_row);

        L.drawDef(&self.chrome, pixels, dest_w, L.main_options.left, L.main_options.top, L.main_options.iw, L.main_options.ih);
        var o: u8 = 0;
        while (o < 8) : (o += 1) {
            const opt: MainOption = @enumFromInt(o);
            self.font.drawAscii(pixels, dest_w, L.ptxtX(L.main_options.label_col), L.main_options.labelY(o), opt.label());
        }
        self.hand.blit(pixels, dest_w, L.main_cursor_x, L.mainCursorY(self.sel));

        L.drawDef(&self.chrome, pixels, dest_w, L.main_time.left, L.main_time.top, L.main_time.iw, L.main_time.ih);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.main_time.label_col), L.ptxtY(L.main_time.label_row), "Time");

        L.drawDef(&self.chrome, pixels, dest_w, L.main_gil.left, L.main_gil.top, L.main_gil.iw, L.main_gil.ih);
        // DrawNum7 at bg_pos 21,24 (direct digits); GilPosText "G" def_ptxt 27,25 (dakuten glyph).
        self.font.drawNumber(pixels, dest_w, @as(i32, L.main_gil.num_col) * 8, @as(i32, L.main_gil.num_row) * 8, gil, 1);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.main_gil.g_col), L.ptxtY(L.main_gil.g_row), "G");
    }

    /// DrawAllCharBlocks + DrawAllPortraits — every present party slot.
    fn drawCharsAndPortraits(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
    ) void {
        L.drawDef(&self.chrome, pixels, dest_w, L.main_char.left, L.main_char.top, L.main_char.iw, L.main_char.ih);

        const pos_tbl: []const [2]u8 = if (party_row == 0)
            &portraits_mod.portrait_pos_front3
        else
            &portraits_mod.portrait_pos_front2;

        if (party) |p| {
            var slot: u8 = 0;
            while (slot < 5 and slot < p.len) : (slot += 1) {
                const m = &p[slot];
                if (!m.present) continue;
                const px: i32 = pos_tbl[slot][0];
                const py: i32 = pos_tbl[slot][1];
                const job: u8 = if (m.gfx_id != 0) m.gfx_id else m.class_id;
                self.portraits.blit(pixels, dest_w, px, py, job);
                self.drawCharBlock(pixels, dest_w, rom, m, slot);
            }
        }
    }

    /// DrawCharBlock — name (dakuten path) / Level / HP / MP (direct tiles).
    fn drawCharBlock(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        m: *const state_mod.PartyMember,
        slot: u8,
    ) void {
        if (slot >= L.char_name_base_y.len) return;
        const base_y = L.char_name_base_y[slot];
        var nbuf: [8]u8 = undefined;
        const nm = partyMemberName(rom, m.id, &nbuf);
        // DrawCharName → kana row
        self.font.drawAscii(pixels, dest_w, L.char_name_x, base_y + L.dakuten_kana_dy, nm);

        // Level/HP/MP: direct tile writes at name_base+$84 / +$40 (no dakuten).
        const ly = base_y + 16;
        self.font.drawAscii(pixels, dest_w, L.char_level_x, ly, "Level");
        self.font.drawNumber(pixels, dest_w, L.char_level_num_x, ly, m.level, 2);

        const hy = base_y + 24;
        self.font.drawAscii(pixels, dest_w, L.char_level_x, hy, "HP");
        self.font.drawNumber(pixels, dest_w, L.char_hp_num_x, hy, m.hp, 4);
        self.font.drawRaw(pixels, dest_w, L.char_slash_x, hy, &[_]u8{0xC7});
        self.font.drawNumber(pixels, dest_w, L.char_hp_max_x, hy, m.max_hp, 4);

        const my = base_y + 32;
        self.font.drawAscii(pixels, dest_w, L.char_level_x, my, "MP");
        self.font.drawNumber(pixels, dest_w, L.char_hp_num_x, my, m.mp, 4);
        self.font.drawRaw(pixels, dest_w, L.char_slash_x, my, &[_]u8{0xC7});
        self.font.drawNumber(pixels, dest_w, L.char_hp_max_x, my, m.max_mp, 4);
    }

    /// ItemName[0] icon tile (WindowGfx) + 8-char name (DrawItemName / DrawEquipItemName).
    fn drawItemLabel(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        x: i32,
        y: i32,
        item_id: u8,
    ) i32 {
        var tx = x;
        if (item_id != 0) {
            const icon = inventory_mod.Inventory.itemIcon(rom, item_id);
            if (icon != 0 and icon != 0xFF) {
                self.font.drawRaw(pixels, dest_w, tx, y, &[_]u8{icon});
                tx += 8;
            }
            var nbuf: [12]u8 = undefined;
            const name = inventory_mod.Inventory.itemName(rom, item_id, &nbuf);
            self.font.drawAscii(pixels, dest_w, tx, y, name);
            tx += @as(i32, @intCast(name.len)) * 8;
        }
        return tx;
    }

    fn orderIndexOf(party_slot: u8) u8 {
        var order: u8 = 0;
        while (order < L.char_order_tbl.len) : (order += 1) {
            if (L.char_order_tbl[order] == party_slot) return order;
        }
        return party_slot;
    }

    /// Occupied party slot (SelectChar). Use `present` only — Cecil's id nibble can be 0
    /// after some loads; empty seats are `!present`, not id==0.
    fn slotOccupied(party: []const state_mod.PartyMember, slot: u8) bool {
        return slot < party.len and party[slot].present;
    }

    fn countPresent(party: ?[]const state_mod.PartyMember) u8 {
        var n: u8 = 0;
        if (party) |p| {
            for (p) |m| {
                if (m.present) n += 1;
            }
        }
        return n;
    }

    fn firstPresentSlot(party: ?[]const state_mod.PartyMember) u8 {
        if (party) |p| {
            for (L.char_order_tbl) |slot| {
                if (slotOccupied(p, slot)) return slot;
            }
            for (p, 0..) |m, i| {
                if (m.present) return @intCast(i);
            }
        }
        return 0;
    }

    /// Move party cursor in screen order (CharOrderTbl), skipping empty slots.
    fn movePartySel(self: *FieldMenu, party: ?[]const state_mod.PartyMember, delta: i8) void {
        const p = party orelse {
            // No party slice (shouldn't happen on field); fall back to raw 0..4.
            if (delta < 0 and self.party_sel > 0) self.party_sel -= 1;
            if (delta > 0 and self.party_sel < 4) self.party_sel += 1;
            return;
        };
        var oi: i8 = @intCast(orderIndexOf(self.party_sel));
        var steps: u8 = 0;
        while (steps < 5) : (steps += 1) {
            oi += delta;
            if (oi < 0) oi = 4;
            if (oi > 4) oi = 0;
            const slot = L.char_order_tbl[@intCast(oi)];
            if (slotOccupied(p, slot)) {
                self.party_sel = slot;
                return;
            }
        }
    }

    fn moveItemTargetSel(self: *FieldMenu, party: ?[]const state_mod.PartyMember, delta: i8) void {
        // Same display-order walk as party_sel.
        const saved = self.party_sel;
        self.party_sel = self.item_target_sel;
        self.movePartySel(party, delta);
        self.item_target_sel = self.party_sel;
        self.party_sel = saved;
    }

    fn drawShop(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        gil: u32,
        inv: *const inventory_mod.Inventory,
    ) void {
        // shop.asm windows (menu_data Shop*).
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.type_l, L.shop.type_t, L.shop.type_iw, L.shop.type_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.msg_l, L.shop.msg_t, L.shop.msg_iw, L.shop.msg_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.choice_l, L.shop.choice_t, L.shop.choice_iw, L.shop.choice_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.gil_l, L.shop.gil_t, L.shop.gil_iw, L.shop.gil_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.list_l, L.shop.list_t, L.shop.list_iw, L.shop.list_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.shop.char_l, L.shop.char_t, L.shop.char_iw, L.shop.char_ih);

        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.shop.welcome_col), L.ptxtY(L.shop.welcome_row), "May I help you?");
        // BUY_SELL_STR EN "Buy  Sell Exit" at BUY_SELL_X=3, row 5.
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.shop.buy_sell_col), L.ptxtY(L.shop.buy_sell_row), "Buy  Sell Exit");
        self.font.drawNumber(pixels, dest_w, L.ptxtX(18), @as(i32, 5) * 8, gil, 1);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.shop.gil_label_col), L.ptxtY(L.shop.gil_label_row), "G");

        var buf: [32]u8 = undefined;
        if (self.shop_mode == 0) {
            var i: u8 = 0;
            while (i < self.shop_list.count and i < 8) : (i += 1) {
                const id = self.shop_list.items[i];
                const y = L.shop.buyCursorY(i);
                const end_x = self.drawItemLabel(pixels, dest_w, rom, L.shop.buy_cursor_x + 16, y, id);
                const price = shop_mod.buyPrice(shop_mod.loadPriceByte(rom, id));
                const pline = std.fmt.bufPrint(&buf, "{d}", .{price}) catch "?";
                self.font.drawAscii(pixels, dest_w, end_x + 8, y, pline);
            }
            self.hand.blit(pixels, dest_w, L.shop.buy_cursor_x, L.shop.buyCursorY(self.shop_sel));
        } else {
            var list: [48]usize = undefined;
            const n = filledItemList(inv, &list);
            var i: u8 = 0;
            while (i < n and i < 16) : (i += 1) {
                const id = inv.slots[list[i]].id;
                const row: u8 = i / 2;
                const col: u8 = i % 2;
                const y = L.shop.sellCursorY(row);
                const tx = L.shop.sell_cursor_x[col] + 16;
                const end_x = self.drawItemLabel(pixels, dest_w, rom, tx, y, id);
                const price = shop_mod.sellPrice(id, shop_mod.loadPriceByte(rom, id));
                const pline = std.fmt.bufPrint(&buf, "{d}", .{price}) catch "?";
                self.font.drawAscii(pixels, dest_w, end_x + 8, y, pline);
            }
            const srow: u8 = self.shop_sel / 2;
            const scol: u8 = self.shop_sel % 2;
            self.hand.blit(pixels, dest_w, L.shop.sell_cursor_x[scol], L.shop.sellCursorY(srow));
        }
    }

    fn filledItemList(inv: *const inventory_mod.Inventory, out: *[48]usize) u8 {
        var n: u8 = 0;
        for (inv.slots, 0..) |s, i| {
            if (s.id == 0 or s.qty == 0) continue;
            out[n] = i;
            n += 1;
            if (n >= 48) break;
        }
        return n;
    }

    /// Status SelectChar — main party layout + hand (before StatusWindow opens).
    fn drawStatusPick(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
    ) void {
        self.drawCharsAndPortraits(pixels, dest_w, rom, party, party_row);
        L.drawDef(&self.chrome, pixels, dest_w, L.main_options.left, L.main_options.top, L.main_options.iw, L.main_options.ih);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.main_options.label_col), L.main_options.labelY(3), "Status");
        self.hand.blit(pixels, dest_w, L.party_cursor_x, L.partyCursorY(self.party_sel));
    }

    /// StatusMenuMain after SelectChar (status.asm @a952–@ab70).
    /// BG1: StatusWindow + StatusPosText + nums + symbols.
    /// BG2: StatusPortraitWindow + StatusLabelPosText.
    /// Sprite: portrait at OAM ($98,$08).
    fn drawStatusView(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
    ) void {
        const p = party orelse return;
        if (self.party_sel >= p.len or !p[self.party_sel].present) return;
        const m = &p[self.party_sel];

        // --- BG1 StatusWindow (VOFS 0) ---
        L.drawDef(&self.chrome, pixels, dest_w, L.status.win_l, L.status.win_t, L.status.win_iw, L.status.win_ih);

        // --- BG2 StatusPortraitWindow (VOFS = status.bg2_vofs after TransformWindow) ---
        // Screen Y = tile_y - bg2_vofs so the panel sits under the portrait, not on Exp.
        const bg2_dy: i32 = L.status.bg2_vofs;
        self.chrome.drawEx(
            pixels,
            dest_w,
            @as(i32, L.status.port_l) * 8,
            @as(i32, L.status.port_t) * 8 - bg2_dy,
            L.fieldTotal(L.status.port_iw),
            L.fieldTotal(L.status.port_ih),
            .field,
        );

        // --- StatusPosText (DrawPosText / dakuten) ---
        // menu_data.asm @de11 — STATUS_LEVEL_X=11 EN
        self.font.drawAscii(pixels, dest_w, L.ptxtX(11), L.ptxtY(4), "Lv.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(17), L.ptxtY(6), "Exp.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(8), "HP");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(10), "MP");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(2), L.ptxtY(13), "Ability");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(15), "Str.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(17), "Agil.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(19), "Vit.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(21), "Wis.");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(3), L.ptxtY(23), "Will");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(13), "Attack");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(15), "Attack%");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(17), "Defence");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(19), "Defence%");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(21), "Mag Def");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(13), L.ptxtY(23), "Mag Def%");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(23), L.ptxtY(13), "x");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(23), L.ptxtY(17), "x");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(23), L.ptxtY(21), "x");
        if (m.level < 99) {
            self.font.drawAscii(pixels, dest_w, L.ptxtX(17), L.ptxtY(9), "For level up");
        }

        // DrawCharName $0084 / DrawClassName $0106 / Handedness DrawMenuText $0186
        var nbuf: [8]u8 = undefined;
        const nm = partyMemberName(rom, m.id, &nbuf);
        self.font.drawAscii(pixels, dest_w, L.drawNumLeftX(0x0084), L.drawNumY(0x0084) + L.dakuten_kana_dy, nm);

        var cbuf: [8]u8 = undefined;
        const cname = className(rom, m.class_id, &cbuf);
        self.font.drawAscii(pixels, dest_w, L.drawNumLeftX(0x0106), L.drawNumY(0x0106) + L.dakuten_kana_dy, cname);

        // HandednessText @ $0186 (status.asm): index = ($1000 & $c0) >> 3.
        self.drawHandedness(pixels, dest_w, m);

        // --- Numbers (no dakuten): DrawNum2/4/7 at status.asm offsets ---
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x015c), L.drawNumY(0x015c), m.level, 2);

        self.font.drawNumber(pixels, dest_w, L.drawNum7LeftX(0x0226), L.drawNumY(0x0226), m.exp, 7);
        if (m.level < 99) {
            self.font.drawNumber(pixels, dest_w, L.drawNum7LeftX(0x02e6), L.drawNumY(0x02e6), 0, 7);
        }

        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0288), L.drawNumY(0x0288), m.hp, 4);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0292), L.drawNumY(0x0292), m.max_hp, 4);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0308), L.drawNumY(0x0308), m.mp, 4);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0312), L.drawNumY(0x0312), m.max_mp, 4);

        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0412), L.drawNumY(0x0412), m.strength, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0492), L.drawNumY(0x0492), m.agility, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0512), L.drawNumY(0x0512), m.vitality, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0592), L.drawNumY(0x0592), m.wisdom, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0612), L.drawNumY(0x0612), m.will, 2);

        // $1b/$28/$22 mults, $1c/$29/$23 side, $1d/$2a/$24 powers — 0 until equip totals ported
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x03aa), L.drawNumY(0x03aa), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x04aa), L.drawNumY(0x04aa), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x05aa), L.drawNumY(0x05aa), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0434), L.drawNumY(0x0434), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0534), L.drawNumY(0x0534), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x0634), L.drawNumY(0x0634), 0, 2);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x03b2), L.drawNumY(0x03b2), 0, 4);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x04b2), L.drawNumY(0x04b2), 0, 4);
        self.font.drawNumber(pixels, dest_w, L.drawNumLeftX(0x05b2), L.drawNumY(0x05b2), 0, 4);

        // DrawStatusWindowSymbols (status.asm @abc2) — after numbers.
        // $c3 ellipsis between left labels and values (col 8, rows 16/18/20/22/24)
        const ellipsis_rows = [_]u16{ 0x0410, 0x0490, 0x0510, 0x0590, 0x0610 };
        for (ellipsis_rows) |off| {
            self.font.drawRaw(pixels, dest_w, L.drawNumLeftX(off), L.drawNumY(off), &[_]u8{0xC3});
        }
        // $c3 on combat value column starts (overwrites leading blank of DrawNum4)
        const combat_ellip = [_]u16{ 0x03b2, 0x0432, 0x04b2, 0x0532, 0x05b2, 0x0632 };
        for (combat_ellip) |off| {
            self.font.drawRaw(pixels, dest_w, L.drawNumLeftX(off), L.drawNumY(off), &[_]u8{0xC3});
        }
        // $c6 percent after hit/def/magdef % values (col 28, rows 16/20/24)
        const pct_offs = [_]u16{ 0x0438, 0x0538, 0x0638 };
        for (pct_offs) |off| {
            self.font.drawRaw(pixels, dest_w, L.drawNumLeftX(off), L.drawNumY(off), &[_]u8{0xC6});
        }
        // $c7 slash HP/MP
        self.font.drawRaw(pixels, dest_w, L.drawNumLeftX(0x0290), L.drawNumY(0x0290), &[_]u8{0xC7});
        self.font.drawRaw(pixels, dest_w, L.drawNumLeftX(0x0310), L.drawNumY(0x0310), &[_]u8{0xC7});

        // BG2 StatusLabelPosText def_ptxt 24,7 with same VOFS as StatusPortraitWindow.
        self.font.drawAscii(
            pixels,
            dest_w,
            L.ptxtX(L.status.label_col),
            L.ptxtY(L.status.label_row) - bg2_dy,
            "Status",
        );

        // Portrait OAM $0898 — sprites are not BG-scrolled; sits in the shifted window.
        const job: u8 = if (m.gfx_id != 0) m.gfx_id else m.class_id;
        self.portraits.blit(pixels, dest_w, L.status.portrait_x, L.status.portrait_y, job);
    }

    fn drawHandedness(self: *const FieldMenu, pixels: []u8, dest_w: usize, m: *const state_mod.PartyMember) void {
        // lda ($60); and #$c0; lsr3 → index 0,8,16,24 into HandednessText (8 bytes each).
        // menu_text_en: 0=pads, 1=L-Hand, 2=R-Hand, 3=R/L both.
        const s: []const u8 = switch (m.handedness & 0xC0) {
            0x40 => "L-Hand",
            0x80 => "R-Hand",
            0xC0 => "R/L both",
            else => return, // HANDEDNESS1_STR all pad — nothing drawn
        };
        self.font.drawAscii(pixels, dest_w, L.drawNumLeftX(0x0186), L.drawNumY(0x0186) + L.dakuten_kana_dy, s);
    }

    /// ClassName EN @ 0x7A764, stride 7 (DrawClassName @8fc6).
    fn className(rom: *const rom_mod.Rom, class_id: u8, buf: *[8]u8) []const u8 {
        const idx: usize = class_id & 0x0F;
        const base: usize = 0x7A764 + idx * 7;
        const raw = rom.slice(base, 7) catch return "???";
        return text_mod.decodeFixed(raw, buf);
    }

    fn drawMagic(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        spell_lists: ?*const cmd_magic.SpellLists,
        party_row: u8,
    ) void {
        // After TransformWindow: MagicTypeWindow + MagicListWindow; char strip may remain.
        _ = party_row;
        L.drawDef(&self.chrome, pixels, dest_w, L.magic_type.left, L.magic_type.top, L.magic_type.iw, L.magic_type.ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.magic_list.left, L.magic_list.top, L.magic_list.iw, L.magic_list.ih);

        // Type names (EN WhiteMagicStr / Black / Call) in type window — cursor @b0bb.
        const types = [_][]const u8{ "White", "Black", "Call" };
        var ti: u8 = 0;
        while (ti < 3) : (ti += 1) {
            self.font.drawAscii(pixels, dest_w, L.ptxtX(24), L.magic_type.typeCursorY(ti), types[ti]);
        }
        self.hand.blit(pixels, dest_w, L.magic_type.cursor_x, L.magic_type.typeCursorY(self.magic_col));

        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.magic_mp.col), L.ptxtY(L.magic_mp.row), "Need MP");

        var list: [24]u8 = .{0xFF} ** 24;
        var count: u8 = 0;
        if (party) |p| {
            if (self.party_sel < p.len and p[self.party_sel].present) {
                const list_id = cmd_magic.listIdFor(rom, p[self.party_sel].id, self.magic_col);
                if (list_id != 0xFF and list_id < offsets.en.spell_list_init_count) {
                    count = cmd_magic.loadSpellListPreferRam(rom, spell_lists, list_id, &list);
                }
            }
        }
        // 3-column list (_01b211 col X $10/$58/$a0); row pitch 16 from list y0 $50.
        var i: u8 = 0;
        while (i < count and i < 24) : (i += 1) {
            const col: u8 = i % 3;
            const row: u8 = i / 3;
            const x = L.magic_list_col_x[col] + 16;
            const y = L.magic_list_cursor_y0 + @as(i32, row) * L.magic_list_row_pitch;
            var nbuf: [12]u8 = undefined;
            const name = cmd_magic.spellName(rom, list[i], &nbuf);
            self.font.drawAscii(pixels, dest_w, x, y, name);
        }
        if (count > 0 and self.magic_sel < count) {
            const col: u8 = self.magic_sel % 3;
            const row: u8 = self.magic_sel / 3;
            self.hand.blit(
                pixels,
                dest_w,
                L.magic_list_col_x[col],
                L.magic_list_cursor_y0 + @as(i32, row) * L.magic_list_row_pitch,
            );
        }
    }

    fn drawPartyPick(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
        title: []const u8,
    ) void {
        // EquipMenu/ChangeOrder: DrawMainMenu + SelectChar (full options chrome).
        self.drawCharsAndPortraits(pixels, dest_w, rom, party, party_row);
        L.drawDef(&self.chrome, pixels, dest_w, L.main_options.left, L.main_options.top, L.main_options.iw, L.main_options.ih);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.main_options.label_col), L.main_options.labelY(0), title);
        if (self.screen == .order and self.order_a != 0xFF) {
            self.hand.blit(pixels, dest_w, L.party_cursor_x + 8, L.partyCursorY(self.order_a));
        }
        self.hand.blit(pixels, dest_w, L.party_cursor_x, L.partyCursorY(self.party_sel));
    }

    fn drawSave(self: *const FieldMenu, pixels: []u8, dest_w: usize) void {
        // SaveLabelPosText + stacked SaveSlotWindow (0,0,29,5) × slots.
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.save.label_col), L.ptxtY(L.save.label_row), "Save");
        var s: u8 = 0;
        while (s < save_mod.slot_count) : (s += 1) {
            const top: u8 = @intCast(s * 5);
            L.drawDef(&self.chrome, pixels, dest_w, L.save.slot_l, top, L.save.slot_iw, L.save.slot_ih);
            var buf: [24]u8 = undefined;
            const exists = save_mod.slotExists(s);
            const line = std.fmt.bufPrint(&buf, "Slot {d} {s}", .{ s + 1, if (exists) "USED" else "Empty" }) catch "Slot";
            // Empty string position LoadEmptyPosText-ish: col 8 within slot band.
            self.font.drawAscii(pixels, dest_w, L.ptxtX(8), @as(i32, top) * 8 + L.dakuten_kana_dy + 8, line);
        }
        // Hand at left of selected slot band (SelectSaveSlot uses slot sprites; x≈2).
        const cy = @as(i32, self.party_sel) * L.save.slot_pitch_y + 0x10;
        self.hand.blit(pixels, dest_w, L.party_cursor_x, cy);
    }

    fn drawEquipSlots(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
    ) void {
        // SelectEquipSlot (equip.asm @bcf7): EquipWindow + labels + DrawEquipItemName.
        L.drawDef(&self.chrome, pixels, dest_w, L.equip.left, L.equip.top, L.equip.iw, L.equip.ih);
        if (party) |p| {
            if (self.party_sel < p.len and p[self.party_sel].present) {
                const m = &p[self.party_sel];
                // DrawCharName at tilemap $01c6 → col 3, row 7 base → glyph (24, 64).
                var nbuf: [8]u8 = undefined;
                const nm = partyMemberName(rom, m.id, &nbuf);
                self.font.drawAscii(pixels, dest_w, 3 * 8, 7 * 8 + L.dakuten_kana_dy, nm);

                // Portrait stays on field layout (DrawPosPortrait during equip entry).
                const job: u8 = if (m.gfx_id != 0) m.gfx_id else m.class_id;
                self.portraits.blit(pixels, dest_w, 0x10, 0x10, job);

                var s: u8 = 0;
                while (s < 5) : (s += 1) {
                    const gy = L.equip.slotGlyphY(s);
                    // def_ptxt EQUIP_PTXT_X, 1+2s — glyph row matches cursor y.
                    self.font.drawAscii(pixels, dest_w, L.ptxtX(L.equip.label_col), gy, equipSlotName(s));
                    const id = getEquipId(m, s);
                    if (id != 0) {
                        // Icon+name at col 18 (tilemap $xx64 kana row).
                        _ = self.drawItemLabel(pixels, dest_w, rom, L.ptxtX(L.equip.item_col), gy, id);
                    }
                }
                // Cursor: x=$58 EN, y=$1b37*16+$10 (@bdfa) == slotGlyphY.
                self.hand.blit(pixels, dest_w, L.equip.cursor_x, L.equip.cursorY(self.equip_sel));
            }
        }
    }

    fn drawItemTarget(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        rom: *const rom_mod.Rom,
        party: ?[]const state_mod.PartyMember,
        party_row: u8,
    ) void {
        // Item whom: DrawItemCharSelect uses main char blocks + SelectChar cursor.
        self.drawCharsAndPortraits(pixels, dest_w, rom, party, party_row);
        L.drawDef(&self.chrome, pixels, dest_w, L.item_whom.left_l, L.item_whom.left_t, L.item_whom.left_iw, L.item_whom.left_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.item_whom.right_l, L.item_whom.right_t, L.item_whom.right_iw, L.item_whom.right_ih);
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.item_whom.ptxt_col), L.ptxtY(L.item_whom.ptxt_row), "Whom?");
        self.hand.blit(pixels, dest_w, L.party_cursor_x, L.partyCursorY(self.item_target_sel));
    }

    /// Char id ($1000&$1F) → CharacterName via CharNameTbl (DrawCharName).
    /// Prefers WRAM `$1500` bank when provided (Namingway renames); else ROM table.
    fn partyMemberName(rom: *const rom_mod.Rom, char_id: u8, buf: *[8]u8) []const u8 {
        return partyMemberNameBank(rom, null, char_id, buf);
    }

    fn partyMemberNameBank(
        rom: *const rom_mod.Rom,
        bank: ?*const @import("namingway.zig").NameBank,
        char_id: u8,
        buf: *[8]u8,
    ) []const u8 {
        const slot = offsets.en.charNameIndex(char_id) orelse return "???";
        if (bank) |b| {
            const s = b.decodeAscii(slot, buf);
            if (s.len > 0) return s;
        }
        return text_mod.decodeCharNameSlot(rom.data, slot, buf);
    }

    /// ConfigMenuSelect (SIMPLE_CONFIG / US) — config.asm @d1a1.
    fn drawConfig(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        battle_speed: u8,
        msg_speed: u8,
        stereo_mono: u8,
        color_r: u8,
        color_g: u8,
        color_b: u8,
    ) void {
        L.drawDef(&self.chrome, pixels, dest_w, L.config.label_l, L.config.label_t, L.config.label_iw, L.config.label_ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.config.main_l, L.config.main_t, L.config.main_iw, L.config.main_ih);
        // ConfigLabelPosText def_ptxt 10,2 CUSTOMIZER_STR (dakuten).
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.title_col), L.ptxtY(L.config.title_row), "Customizer");

        // DrawWindowText chain after ConfigMainWindow (SIMPLE menu_data.asm @dd5c).
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.btl_spd_label_col), L.ptxtY(L.config.btl_spd_label_row), "Battle Speed");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.fast_col), L.ptxtY(L.config.btl_fast_slow_row), "Fast");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.slow_col), L.ptxtY(L.config.btl_fast_slow_row), "Slow");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.msg_spd_label_col), L.ptxtY(L.config.msg_spd_label_row), "Battle Message");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.fast_col), L.ptxtY(L.config.msg_fast_slow_row), "Fast");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.slow_col), L.ptxtY(L.config.msg_fast_slow_row), "Slow");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.sound_label_col), L.ptxtY(L.config.sound_label_row), "Sound");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.stereo_col), L.ptxtY(L.config.stereo_row), "Stereo Mono");
        self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.win_color_label_col), L.ptxtY(L.config.win_color_label_row), "Window Color");

        // R/G/B tile codes $53/$48/$43 at col 15, rows 20/22/24 (config.asm @d164).
        const rgb_letters = [_]u8{ 'R', 'G', 'B' };
        for (L.config.rgb_rows, 0..) |row, i| {
            self.font.drawAscii(pixels, dest_w, L.ptxtX(L.config.rgb_col), @as(i32, row) * 8, rgb_letters[i .. i + 1]);
        }
        // ColorTicksTbl 1,2,2,2,1,2,2,2,3 at col 17, same rows.
        const ticks = [_]u8{ 1, 2, 2, 2, 1, 2, 2, 2, 3 };
        for (L.config.rgb_rows) |row| {
            self.font.drawRaw(pixels, dest_w, L.ptxtX(L.config.tick_col), @as(i32, row) * 8, &ticks);
        }

        // CopyText BattleNumText @ (15,8) and (15,12); GraySpeedNumeral + white selected.
        self.drawBattleNums(pixels, dest_w, L.config.btl_num_row, battle_speed);
        self.drawBattleNums(pixels, dest_w, L.config.msg_num_row, msg_speed);

        // Stereo cursor always (GetConfigXPos $16b6, y=$78).
        const st_x: i32 = if ((stereo_mono & 1) != 0) L.config.toggle_x1 else L.config.toggle_x0;
        self.hand.blit(pixels, dest_w, st_x, L.config.stereo_cursor_y);

        // Color component cursors always: x=comp*2+$86, y=$a0/$b0/$c0.
        const comps = [_]u8{ color_r, color_g, color_b };
        var ci: u8 = 0;
        while (ci < 3) : (ci += 1) {
            self.hand.blit(pixels, dest_w, L.config.colorCursorX(comps[ci]), L.config.colorCursorY(ci));
        }

        // Row cursor DrawCursor2: x=$18 (rows 0–2) / $68 (color), y=ConfigCursorYTbl[sel].
        const sel = @min(self.config_sel, L.config.row_count - 1);
        self.hand.blit(pixels, dest_w, L.config.rowCursorX(sel), L.config.rowCursorY(sel));
    }

    /// CopyText of BATTLE_NUM_STR "1 2 3 4 5 6" at (15, row) — no dakuten, 16px pitch.
    /// GraySpeedNumeral: all gray palette $04; selected digit palette $00 (asl2 index).
    fn drawBattleNums(self: *const FieldMenu, pixels: []u8, dest_w: usize, tile_row: u8, selected: u8) void {
        const y: i32 = @as(i32, tile_row) * 8;
        const x0: i32 = L.ptxtX(L.config.num_col);
        const sel = @min(selected, 5);
        var i: u8 = 0;
        while (i < 6) : (i += 1) {
            const pal: usize = if (i == sel) font_mod.pal_white else font_mod.pal_gray;
            // Digit tile $80+n (same as drawNumber width 1).
            const code: u8 = 0x80 + (i + 1);
            self.font.drawRawPal(pixels, dest_w, x0 + @as(i32, i) * L.battle_num_pitch_px, y, &[_]u8{code}, pal);
        }
    }

    fn drawItem(
        self: *const FieldMenu,
        pixels: []u8,
        dest_w: usize,
        inv: *const inventory_mod.Inventory,
        rom: *const rom_mod.Rom,
    ) void {
        // InventoryWindow + ItemLabelWindowLeft + ItemLabelWindowRight + ItemDescWindow.
        self.chrome.drawEx(
            pixels,
            dest_w,
            @as(i32, L.inv.left) * 8,
            @as(i32, L.inv.top) * 8,
            L.fieldTotal(L.inv.iw),
            L.inv.vis_total_h,
            .field,
        );
        L.drawDef(&self.chrome, pixels, dest_w, L.item_label_left.left, L.item_label_left.top, L.item_label_left.iw, L.item_label_left.ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.item_label_right.left, L.item_label_right.top, L.item_label_right.iw, L.item_label_right.ih);
        L.drawDef(&self.chrome, pixels, dest_w, L.item_desc.left, L.item_desc.top, L.item_desc.iw, L.item_desc.ih);
        self.font.drawAscii(
            pixels,
            dest_w,
            L.ptxtX(L.item_label_left.ptxt_col),
            L.ptxtY(L.item_label_left.ptxt_row),
            "Item",
        );

        const cols: u8 = 2;
        const vis_rows: u8 = 11;
        const row_pitch: i32 = 16;

        var vis_r: u8 = 0;
        while (vis_r < vis_rows) : (vis_r += 1) {
            var col: u8 = 0;
            while (col < cols) : (col += 1) {
                const idx: u8 = self.item_scroll * cols + vis_r * cols + col;
                const slot_i = itemSlotAt(inv, idx) orelse continue;
                const s = inv.slots[slot_i];
                const ty = L.item_cursor_y0 + @as(i32, vis_r) * row_pitch;
                const end_x = self.drawItemLabel(pixels, dest_w, rom, L.itemTextX(col), ty, s.id);
                self.font.drawRaw(pixels, dest_w, end_x, ty, &[_]u8{0xC8});
                self.font.drawNumber(pixels, dest_w, end_x + 8, ty, s.qty, 2);
            }
        }
        const sel_col: u8 = self.item_sel % cols;
        const sel_row_abs: u8 = self.item_sel / cols;
        const sel_vis: i32 = @as(i32, sel_row_abs) - @as(i32, self.item_scroll);
        if (sel_vis >= 0 and sel_vis < vis_rows) {
            self.hand.blit(
                pixels,
                dest_w,
                L.item_cursor_x[sel_col],
                L.item_cursor_y0 + sel_vis * row_pitch,
            );
        }
    }
};

fn countItems(inv: *const inventory_mod.Inventory) u8 {
    var n: u8 = 0;
    for (inv.slots) |s| {
        if (s.id != 0 and s.qty > 0) n += 1;
    }
    return n;
}

fn itemSlotAt(inv: *const inventory_mod.Inventory, index: u8) ?usize {
    var n: u8 = 0;
    for (inv.slots, 0..) |s, i| {
        if (s.id == 0 or s.qty == 0) continue;
        if (n == index) return i;
        n += 1;
    }
    return null;
}
