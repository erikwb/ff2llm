//! ExecBtlGfx presentation — ROM tiles/sprites via sprites.Scene + host state.
const std = @import("std");
const host_mod = @import("host.zig");
const obj_mod = @import("obj.zig");
const sprites = @import("sprites.zig");
const inventory_mod = @import("../game/inventory.zig");
const item_prop = @import("item_prop.zig");
const window = @import("window.zig");
const cursor_mod = @import("cursor.zig");
const weapon_hit = @import("weapon_hit.zig");
const status_mod = @import("status.zig");

const view_w: i32 = sprites.view_w;
const view_h: i32 = sprites.view_h;

fn px(pixels: []u8, x: i32, y: i32, r: u8, g: u8, b: u8) void {
    if (x < 0 or y < 0 or x >= view_w or y >= view_h) return;
    const o: usize = @intCast((y * view_w + x) * 4);
    pixels[o] = r;
    pixels[o + 1] = g;
    pixels[o + 2] = b;
    pixels[o + 3] = 255;
}

fn rect(pixels: []u8, x: i32, y: i32, w: i32, h: i32, r: u8, g: u8, b: u8) void {
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) px(pixels, x + dx, y + dy, r, g, b);
    }
}

fn text(pixels: []u8, h: *const host_mod.Host, x: i32, y: i32, s: []const u8) void {
    if (h.font.loaded) {
        h.font.drawAscii(pixels, @intCast(view_w), x, y, s);
        return;
    }
    // Fallback if font failed to load
    var cx = x;
    for (s) |ch| {
        _ = ch;
        cx += 4;
    }
}

/// Battle inventory list — UpdateCursor_05 layout (2 cols × 5 rows).
/// Item line: [icon] name : qty (DrawInventoryItemText).
fn drawBattleInventory(pixels: []u8, h: *const host_mod.Host, chrome: *const window.WindowChrome) void {
    const iw = window.inv_window;
    if (chrome.loaded) {
        chrome.drawEx(pixels, @intCast(view_w), iw.x_px, iw.y_px, iw.w, iw.h, .battle);
    } else {
        rect(pixels, iw.x_px, iw.y_px, @as(i32, iw.w) * 8, @as(i32, iw.h) * 8, 0, 0, 128);
    }

    const inv = h.inv orelse return;
    const rom = h.rom orelse return;
    const atk = &h.objs.objs[h.menu_slot];
    var list: [50]usize = undefined;
    const n = host_mod.battleItemList(inv, atk.left_hand, atk.right_hand, h.rom, &list);

    var vis_row: u8 = 0;
    while (vis_row < 5) : (vis_row += 1) {
        const abs_row: u8 = h.item_scroll + vis_row;
        var col: u8 = 0;
        while (col < 2) : (col += 1) {
            const li: u16 = @as(u16, abs_row) * 2 + col;
            if (li >= n) continue;
            const bag_i = list[li];
            const from_hand = bag_i == host_mod.hand_left_slot or bag_i == host_mod.hand_right_slot;
            const id: u8 = if (bag_i == host_mod.hand_left_slot)
                atk.left_hand
            else if (bag_i == host_mod.hand_right_slot)
                atk.right_hand
            else
                inv.slots[bag_i].id;
            const qty: u8 = if (from_hand) 1 else inv.slots[bag_i].qty;
            const cx = cursor_mod.inv_cursor_x[col];
            const cy = cursor_mod.inv_cursor_y[vis_row];
            const ty = cy + cursor_mod.inv_text_dy;
            // Icon tile (ItemName[0]) then name
            var ix = cx + 8;
            if (h.font.loaded) {
                const icon = inventory_mod.Inventory.itemIcon(rom, id);
                if (icon != 0 and icon != 0xFF) {
                    h.font.drawRaw(pixels, @intCast(view_w), ix, ty, &[_]u8{icon});
                    ix += 8;
                }
            }
            const tx = ix;
            var nbuf: [12]u8 = undefined;
            const name = inventory_mod.Inventory.itemName(rom, id, &nbuf);
            const usable = from_hand or item_prop.ItemProp.isBattleItem(id);
            if (h.font.loaded) {
                if (usable) {
                    h.font.drawAscii(pixels, @intCast(view_w), tx, ty, name);
                } else {
                    h.font.drawAsciiPal(pixels, @intCast(view_w), tx, ty, name, @import("../gfx/font.zig").pal_gray);
                }
                const name_w: i32 = @intCast(name.len * 8);
                h.font.drawRaw(pixels, @intCast(view_w), tx + name_w, ty, &[_]u8{0xC8});
                h.font.drawNumber(pixels, @intCast(view_w), tx + name_w + 8, ty, qty, 1);
            } else {
                text(pixels, h, tx, ty, name);
            }
        }
    }

    const sel_col: u8 = h.item_list_i % 2;
    const sel_row_abs: u8 = h.item_list_i / 2;
    const sel_vis: i32 = @as(i32, sel_row_abs) - @as(i32, h.item_scroll);
    if (sel_vis >= 0 and sel_vis < 5) {
        const hx = cursor_mod.inv_cursor_x[sel_col];
        const hy = cursor_mod.inv_cursor_y[@intCast(sel_vis)];
        h.hand.blit(pixels, @intCast(view_w), hx, hy);
    }
}

/// Magic list — 3 cols × 5 rows (MagicListCursorXTbl / ListCursorYTbl).
fn drawBattleMagic(pixels: []u8, h: *const host_mod.Host, chrome: *const window.WindowChrome) void {
    const iw = window.inv_window; // same strip width as inventory
    if (chrome.loaded) {
        chrome.drawEx(pixels, @intCast(view_w), iw.x_px, iw.y_px, iw.w, iw.h, .battle);
    } else {
        rect(pixels, iw.x_px, iw.y_px, @as(i32, iw.w) * 8, @as(i32, iw.h) * 8, 0, 0, 128);
    }
    const rom = h.rom orelse return;
    const cmd_magic = @import("cmd_magic.zig");

    var vis_row: u8 = 0;
    while (vis_row < 5) : (vis_row += 1) {
        const abs_row: u8 = h.magic_scroll + vis_row;
        var col: u8 = 0;
        while (col < 3) : (col += 1) {
            const li: u16 = @as(u16, abs_row) * 3 + col;
            if (li >= h.magic_count) continue;
            const spell_id = h.magic_list[li];
            const cx = cursor_mod.magic_cursor_x[col];
            const cy = cursor_mod.magic_cursor_y[vis_row];
            const tx = cx + cursor_mod.magic_text_dx;
            const ty = cy + cursor_mod.magic_text_dy;
            var nbuf: [12]u8 = undefined;
            const name = cmd_magic.spellName(rom, spell_id, &nbuf);
            // MP cost after name if spell loads
            if (h.font.loaded) {
                h.font.drawAscii(pixels, @intCast(view_w), tx, ty, name);
                if (cmd_magic.loadSpell(rom, spell_id)) |sp| {
                    const nw: i32 = @intCast(name.len * 8);
                    h.font.drawNumber(pixels, @intCast(view_w), tx + nw + 8, ty, sp.mp_cost, 1);
                }
            } else {
                text(pixels, h, tx, ty, name);
            }
        }
    }

    const sel_col: u8 = h.magic_sel % 3;
    const sel_row_abs: u8 = h.magic_sel / 3;
    const sel_vis: i32 = @as(i32, sel_row_abs) - @as(i32, h.magic_scroll);
    if (sel_vis >= 0 and sel_vis < 5) {
        h.hand.blit(pixels, @intCast(view_w), cursor_mod.magic_cursor_x[sel_col], cursor_mod.magic_cursor_y[@intCast(sel_vis)]);
    }
}

/// Draw one battle frame (ExecBtlGfx subset).
pub fn present(pixels: []u8, h: *const host_mod.Host, scene: ?*const sprites.Scene) void {
    // Background
    if (scene) |sc| {
        if (sc.loaded and sc.bg.len == pixels.len) {
            @memcpy(pixels, sc.bg);
        } else {
            const my = window.menu_strip_y;
            rect(pixels, 0, 0, view_w, my, 40, 70, 120);
            rect(pixels, 0, my, view_w, view_h - my, 50, 90, 50);
        }
    } else {
        const my = window.menu_strip_y;
        rect(pixels, 0, 0, view_w, my, 40, 70, 120);
        rect(pixels, 0, my, view_w, view_h - my, 50, 90, 50);
    }
    if (h.flash > 0) {
        // Flash overlay
        var y: i32 = 0;
        while (y < view_h) : (y += 1) {
            var x: i32 = 0;
            while (x < view_w) : (x += 1) {
                const o: usize = @intCast((y * view_w + x) * 4);
                pixels[o] = @min(255, pixels[o] +% 40);
            }
        }
    }

    // Monsters
    var i: usize = obj_mod.party_slots;
    var mon_i: usize = 0;
    while (i < obj_mod.total_slots) : (i += 1) {
        const o = h.objs.objs[i];
        const dying = h.monDying(mon_i);
        // Keep drawing hp==0 while dissolving; hide once present cleared.
        if (!o.present or (o.hp == 0 and !dying)) {
            mon_i += 1;
            continue;
        }
        var sx: i32 = @intCast(o.screen_x);
        var sy: i32 = @intCast(o.screen_y);
        // UpdateMonsterEntry: H-scroll (ground) or V-scroll (flying) during entry.
        if (h.mon_entry_active) {
            if (h.mons_flying) {
                sy += h.mon_entry_scroll;
            } else {
                sx += h.mon_entry_scroll;
            }
        }
        if (h.anim.kind == .mon_fight and h.anim.attacker == i) {
            sx += h.anim.mon_dx;
        }
        const flash_tgt = h.anim.hit_flash > 0 and h.anim.target == i and (h.anim.hit_flash & 1) != 0;
        var drew = false;
        if (scene) |sc| {
            if (mon_i < sc.monsters.len) {
                const m = sc.monsters[mon_i];
                if (m.pixels.len > 0) {
                    if (dying) {
                        blitMonsterDeath(pixels, sx, sy, m.pixels, m.w, m.h, h.anim.death_t, h.rom);
                    } else {
                        sprites.blitRgbaFlash(pixels, @intCast(view_w), sx, sy, m.pixels, m.w, m.h, flash_tgt);
                    }
                    drew = true;
                }
            }
        }
        if (!drew and !dying) rect(pixels, sx, sy, 28, 28, 160, 60, 60);
        mon_i += 1;
    }

    // Party characters — CharSpriteDefaultX/Y (obj.screen_x/y); HP text in party window
    i = 0;
    while (i < obj_mod.party_slots) : (i += 1) {
        const o = h.objs.objs[i];
        if (!o.present) continue;
        // CmdAnim_06: after takeoff `sta $efc4` 0 → pose $1e hide (sprite.asm @e38f).
        // Mid-air jumper is not drawn until Jump2 lands.
        if (o.status.isJumping()) continue;
        var sx: i32 = @intCast(o.screen_x);
        const sy: i32 = @intCast(o.screen_y);
        if (h.anim.kind == .party_fight and h.anim.attacker == i) {
            sx += h.anim.char_dx;
        }
        const flash_tgt = h.anim.hit_flash > 0 and h.anim.target == i and (h.anim.hit_flash & 1) != 0;
        var drew = false;
        if (scene) |sc| {
            if (i < sc.chars.len) {
                const ch = sc.chars[i];
                const pose: sprites.CharPose = blk: {
                    // Dead / stone: CharPose $09 / kneeling (sprite.asm UpdateCharPose).
                    // Toad/mini: CharTileTbl $16+ / $0C+ via poseForStatus (btlgfx_data @f961).
                    const mini = (o.status.s1 & status_mod.Status1.mini) != 0;
                    const toad = (o.status.s1 & status_mod.Status1.toad) != 0;
                    const base: sprites.CharPose = base: {
                        if (o.hp == 0 or o.status.isDead()) break :base .dead;
                        if (o.status.isStone()) break :base .kneeling;
                        if (h.anim.kind == .victory) break :base .victory;
                        if (h.anim.kind == .party_fight and h.anim.attacker == i) break :base h.anim.char_pose;
                        if (h.anim.kind == .gfx_script and h.anim.attacker == i) break :base h.anim.char_pose;
                        if (h.anim.hit_pose_timer > 0 and h.anim.hit_pose_slot == i) break :base .hit;
                        // Ready pose while waiting for command (GetCharAttack menu open)
                        if (h.phase == .menu and h.menu_slot == i) break :base .ready;
                        break :base .standing;
                    };
                    break :blk sprites.poseForStatus(base, mini, toad);
                };
                const frame = ch.pixelsFor(pose);
                if (frame.len > 0) {
                    const sz = ch.sizeFor(pose);
                    sprites.blitRgbaFlash(
                        pixels,
                        @intCast(view_w),
                        sx + sz.ox,
                        sy + sz.oy,
                        frame,
                        sz.w,
                        sz.h,
                        flash_tgt,
                    );
                    drew = true;
                }
            }
        }
        if (!drew) rect(pixels, sx, sy, 16, 24, 80, 120, 200);
        // No ATB gauges: SNES FF4 has none (timers are invisible; Wait/Active only).
    }

    // DrawWeaponHit (sprite.asm @e63d) — SwordWhipHitFrameTbl sequence + hit CHR.
    if (h.anim.spark_t > 0) {
        drawWeaponHit(pixels, h, h.anim.spark_x, h.anim.spark_y, h.anim.spark_t);
    }

    // --- ROM menu windows (MenuWindowTbl + WindowGfx + BorderTilesTbl set 0) ---
    // Inventory replaces mon/party/cmd strip while open (Tfr inventory tilemap).
    const chrome = &h.chrome;
    const show_main_strip = !(h.phase == .menu and (h.menu_mode == .item or h.menu_mode == .magic));
    const mn = window.mon_name_window;
    const pw = window.party_window;
    if (show_main_strip) {
        if (chrome.loaded) {
            chrome.drawEx(pixels, @intCast(view_w), mn.x_px, mn.y_px, mn.w, mn.h, .battle);
            chrome.drawEx(pixels, @intCast(view_w), pw.x_px, pw.y_px, pw.w, pw.h, .battle);
        } else {
            rect(pixels, mn.x_px, mn.y_px, @as(i32, mn.w) * 8, @as(i32, mn.h) * 8, 0, 0, 128);
            rect(pixels, pw.x_px, pw.y_px, @as(i32, pw.w) * 8, @as(i32, pw.h) * 8, 0, 0, 128);
        }

        // Monster names (MenuText_0000) — first content row is one tile below border.
        {
            var my: i32 = 0;
            var mi: usize = obj_mod.party_slots;
            while (mi < obj_mod.total_slots) : (mi += 1) {
                const o = h.objs.objs[mi];
                if (!o.present or o.hp == 0) continue;
                const nm = if (o.name.len > 8) o.name[0..8] else o.name;
                text(pixels, h, mn.text_x, mn.text_y0 + my * mn.text_dy, nm);
                my += 1;
                if (my >= 5) break;
            }
        }

        // Party names + HP (DrawCharHP) — CharOrderTbl display order (btlgfx @a1c8).
        {
            const char_order = [_]usize{ 1, 3, 0, 4, 2 };
            var pr: i32 = 0;
            for (char_order) |pi| {
                if (pi >= obj_mod.party_slots) continue;
                const o = h.objs.objs[pi];
                if (!o.present) continue;
                const nm = if (o.name.len > 6) o.name[0..6] else o.name;
                const bx = pw.text_x;
                const by = pw.text_y0 + pr * pw.row_dy;
                text(pixels, h, bx, by, nm);
                if (h.font.loaded) {
                    h.font.drawNumber(pixels, @intCast(view_w), bx, by + 8, o.hp, 5);
                    h.font.drawRaw(pixels, @intCast(view_w), bx + 5 * 8, by + 8, &[_]u8{0xC7});
                    h.font.drawNumber(pixels, @intCast(view_w), bx + 6 * 8, by + 8, o.max_hp, 5);
                } else {
                    var buf: [24]u8 = undefined;
                    const hp = std.fmt.bufPrint(&buf, "{d}/{d}", .{ o.hp, o.max_hp }) catch "";
                    text(pixels, h, bx, by + 8, hp);
                }
                pr += 1;
            }
        }
    }

    // Command window + inventory / magic (DrawCmdWindow / UpdateCursor_05 / magic list)
    if (h.phase == .menu) {
        const cw = window.cmd_window;

        if (h.menu_mode == .item) {
            drawBattleInventory(pixels, h, chrome);
        } else if (h.menu_mode == .magic) {
            drawBattleMagic(pixels, h, chrome);
        } else if (h.menu_mode == .command or h.menu_mode == .target) {
            // Command list stays visible during target select.
            if (chrome.loaded) {
                chrome.drawEx(pixels, @intCast(view_w), cw.x_px, cw.y_px, cw.w, cw.h, .battle);
            } else {
                rect(pixels, cw.x_px, cw.y_px, @as(i32, cw.w) * 8, @as(i32, cw.h) * 8, 0, 0, 128);
            }
            var ci: u8 = 0;
            while (ci < h.cmd_count) : (ci += 1) {
                const cmd = h.cmd_list[ci];
                // CmdCursorYTbl = hand top; text at y+4 centers 8px glyph in 16px hand.
                const hand_y: i32 = if (ci < cursor_mod.cmd_cursor_y.len)
                    cursor_mod.cmd_cursor_y[ci]
                else
                    cursor_mod.cmd_cursor_y[cursor_mod.cmd_cursor_y.len - 1] + @as(i32, ci - 4) * 12;
                var nbuf: [12]u8 = undefined;
                const name = if (h.rom) |rom| window.commandName(rom, cmd, &nbuf) else "???";
                text(pixels, h, cw.text_x, hand_y + cursor_mod.cmd_text_dy, name);
            }
        }

        if (h.menu_mode == .command) {
            const cy: i32 = if (h.menu_sel < cursor_mod.cmd_cursor_y.len)
                cursor_mod.cmd_cursor_y[h.menu_sel]
            else
                cursor_mod.cmd_cursor_y[0];
            h.hand.blit(pixels, @intCast(view_w), cursor_mod.cmd_cursor_x, cy);
        } else if (h.menu_mode == .target) {
            const t = h.objs.objs[h.target_slot];
            if (t.present and t.hp > 0) {
                h.hand.blit(pixels, @intCast(view_w), t.monCursorX(), t.monCursorY());
            }
        } else if (h.menu_mode == .cover_target) {
            // Hand on covered ally (char sprite position)
            const t = h.objs.objs[h.target_slot];
            if (t.present and t.hp > 0) {
                const hx: i32 = @as(i32, t.screen_x) - 8;
                const hy: i32 = @as(i32, t.screen_y) + 4;
                h.hand.blit(pixels, @intCast(view_w), hx, hy);
            }
        }
    }

    // Message windows (DrawFull / Left / Right MsgWindow) — only while hold is live.
    // CloseMsgWindow clears msg_len when msg_timer hits 0; also require timer/phase so
    // a stale msg_len after a non-message path never leaves chrome up forever.
    // Damage hits use ShowMsg_04 numerals, not this window.
    if (h.msg_len > 0 and (h.phase == .message or h.msg_timer > 0)) {
        const tx: i32 = switch (h.msg_kind) {
            .full => window.msg_window.text_x,
            .left => window.msg_window_left.text_x,
            .right => window.msg_window_right.text_x,
        };
        const ty: i32 = switch (h.msg_kind) {
            .full => window.msg_window.text_y,
            .left => window.msg_window_left.text_y,
            .right => window.msg_window_right.text_y,
        };
        if (chrome.loaded) {
            // Interior-only fill + transparent border-0 so blue never bleeds north of frame.
            chrome.drawMsg(pixels, @intCast(view_w), h.msg_kind);
        } else {
            const mw = window.msg_window;
            rect(pixels, mw.x_px + 8, mw.y_px + 8, @as(i32, mw.w) * 8 - 16, @as(i32, mw.h) * 8 - 16, 0, 0, 128);
        }
        // Ink-only glyphs: window fill is already blue; avoid font cell plate over border.
        if (h.font.loaded) {
            h.font.drawAsciiInk(pixels, @intCast(view_w), tx, ty, h.msgSlice());
        } else {
            text(pixels, h, tx, ty, h.msgSlice());
        }
    }

    // Damage numerals (DrawDmgNumerals bounce)
    h.floaters.draw(pixels, @intCast(view_w), &h.font);
}

/// MonsterDeathHDMATbl @ LoROM $13/F99D (file 0x9F99D).
const mon_death_hdma_file: usize = 0x9F99D;
const death_fx = @import("death_fx.zig");

/// Load 16-bit entry for frame `phase` (ROM preferred, else embed).
fn deathHdmaWord(rom: ?*const @import("../rom.zig").Rom, phase: u8) u16 {
    const idx: usize = @as(usize, phase) * 2;
    if (rom) |r| {
        if (r.slice(mon_death_hdma_file + idx, 2)) |raw| {
            return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
        } else |_| {}
    }
    return death_fx.deathHdmaWordEmbed(phase);
}

/// MonsterDeathAnim — UpdateMonsterDeathHDMA (@fae5) + DecColor (@bd43).
/// Hide = LE low-byte bit7 (`death_fx.deathBandHidden`); second HDMA loop mirrors
/// the same flags bottom-up (display-equivalent single pass).
fn blitMonsterDeath(dest: []u8, dx: i32, dy: i32, src: []const u8, sw: u16, sh: u16, death_t: u8, rom: ?*const @import("../rom.zig").Rom) void {
    if (src.len == 0 or sw == 0 or sh == 0) return;
    const phase: u8 = death_t;
    const steps: u8 = phase;

    var y: i32 = 0;
    while (y < sh) : (y += 1) {
        const band: u8 = @intCast(@min(@divTrunc(y * 16, @as(i32, @intCast(sh))), 15));
        const word = deathHdmaWord(rom, phase +% band);
        if (death_fx.deathBandHidden(word)) continue;

        var x: i32 = 0;
        while (x < sw) : (x += 1) {
            const ox = dx + x;
            const oy = dy + y;
            if (ox < 0 or oy < 0 or ox >= view_w or oy >= view_h) continue;
            const si: usize = @intCast((y * @as(i32, @intCast(sw)) + x) * 4);
            if (si + 3 >= src.len) continue;
            if (src[si + 3] == 0) continue;
            const di: usize = @intCast((oy * @as(i32, @intCast(view_w)) + ox) * 4);
            const r5: u5 = @truncate(src[si] >> 3);
            const g5: u5 = @truncate(src[si + 1] >> 3);
            const b5: u5 = @truncate(src[si + 2] >> 3);
            const r2 = death_fx.decColor5(r5, steps);
            const g2 = death_fx.decColor5(g5, steps);
            const b2 = death_fx.decColor5(b5, steps);
            dest[di] = @as(u8, r2) << 3;
            dest[di + 1] = @as(u8, g2) << 3;
            dest[di + 2] = @as(u8, b2) << 3;
            dest[di + 3] = 255;
        }
    }
}

/// DrawWeaponHit using SwordWhipHitFrameTbl + WeaponHitFrame_* + LoadHitGfx tiles.
/// `t` counts down from 16 (WeaponHitAnim `$4e` 0..$0f ≈ remaining).
fn drawWeaponHit(pixels: []u8, h: *const host_mod.Host, cx: i16, cy: i16, t: u8) void {
    const hit = &h.scene.hit_gfx;
    if (!hit.loaded) return;
    // `$4e` advances 0→$10; we have remaining t, so step = (16-t)>>1 into 0..7.
    const elapsed: u8 = if (t < 16) 16 -% t else 0;
    const step: u8 = @min(elapsed >> 1, 7);
    // SwordWhipHitFrameTbl row = WeaponAnimProp+2 (LoadWeaponAnim $53) when ≤7.
    const row = h.anim.hit_frame_row;
    const frame_id = weapon_hit.swordWhipFrame(row, step);
    if (frame_id == 0x20) return; // blank in SwordWhipHitFrameTbl
    hit.drawFrame(pixels, view_w, cx, cy, frame_id, 0, false);
}
