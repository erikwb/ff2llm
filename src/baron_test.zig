const std = @import("std");
const rom_mod = @import("rom.zig");
const submap = @import("map/submap.zig");
const npc_mod = @import("map/npc.zig");
const triggers = @import("map/triggers.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    std.debug.print("Loading ROM...\n", .{});
    var r = try rom_mod.load(io, gpa, "Final Fantasy II.smc");
    defer r.deinit();

    std.debug.print("Loading submap 36...\n", .{});
    var sm = try submap.SubMap.load(gpa, &r, 36);
    defer sm.deinit();
    std.debug.print("Submap OK tiles={d} form={d} tileset={d}\n", .{ sm.tile_count, sm.prop.bg1_form, sm.prop.tileset });

    var npc_sw: [0x40]u8 = undefined;
    @memcpy(npc_sw[0..], try r.slice(0x97200, 0x40));
    var ev_sw: [0x20]u8 = undefined;
    @memcpy(ev_sw[0..], try r.slice(0x97240, 0x20));

    std.debug.print("Loading NPCs idx={d}...\n", .{sm.prop.npc_index});
    var npcs = try npc_mod.NpcSet.load(gpa, &r, sm.prop.npc_index, npc_sw[0..], false, sm.prop.npc_pal);
    defer npcs.deinit();
    std.debug.print("NPCs OK count={d}\n", .{npcs.npcs.len});
    for (npcs.npcs, 0..) |n, i| {
        var buf: [256]u8 = undefined;
        const text = npc_mod.talkText(&r, n, 36, ev_sw[0..], &buf);
        std.debug.print("  [{d}] gfx={d} sheet={d} poses={d} voice={} ({d},{d}): {s}\n", .{
            i, n.prop_gfx, n.sheet_id, n.pose_count, n.canVoiceChat(), n.x, n.y, text,
        });
    }

    std.debug.print("Loading triggers...\n", .{});
    const tr = try triggers.loadMapTriggers(gpa, &r, 36);
    defer gpa.free(tr);
    std.debug.print("Triggers OK count={d}\n", .{tr.len});

    std.debug.print("ALL OK\n", .{});
}
