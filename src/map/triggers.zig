//! World + sub-map triggers (doors, stairs, exits).
//!
//! Decomp: field/trigger.asm CheckTriggerWorld / CheckTriggerSub.
//! World: WorldTriggers1/2/3 selected by `$1700` via WorldTriggersPtrs.
const std = @import("std");
const rom_mod = @import("../rom.zig");

pub const Trigger = struct {
    x: u8,
    y: u8,
    /// Dest map id low byte, or $FF = event, or (submap only) >= $FB = world layer.
    dest_map: u8,
    dest_x: u8,
    dest_y: u8,
};

pub const Transition = union(enum) {
    none,
    enter_submap: struct { map_id: u16, x: u8, y: u8, facing: u8 },
    enter_world: struct { world: u8, x: u8, y: u8 },
    event: u8,
};

/// WorldTriggersPtrs @ $19FE60 (file 0xCFE60) — 3 relative u16 from WorldTriggers.
/// WorldTriggers data @ $19FE66 (file 0xCFE66): tables 1=OW, 2=under, 3=moon.
const world_triggers_ptrs: usize = 0xCFE60;
const world_triggers_base: usize = 0xCFE66;
/// Exclusive end of bank-19 world_triggers segment (file offset after last byte).
const world_triggers_end: usize = 0xD0000;

/// MapTriggersPtrs @ $158000 (384 entries); MapTriggers1 data @ $158300.
/// Pointers are relative to MapTriggers1 (see CheckTriggerSub).
const map_trigger_ptrs: usize = 0xA8000;
const map_trigger_data: usize = 0xA8300;

/// Load WorldTriggers for one world layer (`$1700`: 0=OW, 1=under, 2=moon).
/// trigger.asm @9d95: `lda $1700 / asl / tax / lda WorldTriggersPtrs,x`.
pub fn loadWorldTriggers(gpa: std.mem.Allocator, r: *const rom_mod.Rom, world_id: u8) ![]Trigger {
    const wi: usize = @min(@as(usize, world_id), 2);
    const rel0 = try r.readU16Le(world_triggers_ptrs + wi * 2);
    const rel1: usize = if (wi < 2)
        try r.readU16Le(world_triggers_ptrs + (wi + 1) * 2)
    else
        world_triggers_end - world_triggers_base;
    if (rel1 < rel0) return try gpa.alloc(Trigger, 0);
    const nbytes = rel1 - rel0;
    const count = nbytes / 5;
    const raw = try r.slice(world_triggers_base + rel0, count * 5);
    const out = try gpa.alloc(Trigger, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const o = i * 5;
        out[i] = .{
            .x = raw[o],
            .y = raw[o + 1],
            .dest_map = raw[o + 2],
            .dest_x = raw[o + 3],
            .dest_y = raw[o + 4],
        };
    }
    return out;
}

pub fn loadMapTriggers(gpa: std.mem.Allocator, r: *const rom_mod.Rom, map_id: u16) ![]Trigger {
    if (map_id >= 0x180) return try gpa.alloc(Trigger, 0);
    const rel = try r.readU16Le(map_trigger_ptrs + @as(usize, map_id) * 2);
    const next = if (map_id + 1 < 0x180)
        try r.readU16Le(map_trigger_ptrs + @as(usize, map_id + 1) * 2)
    else
        rel + 5 * 32;
    if (next < rel) return try gpa.alloc(Trigger, 0);
    const count = (next - rel) / 5;
    const out = try gpa.alloc(Trigger, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const o = map_trigger_data + rel + i * 5;
        const b = try r.slice(o, 5);
        out[i] = .{
            .x = b[0],
            .y = b[1],
            .dest_map = b[2],
            .dest_x = b[3],
            .dest_y = b[4],
        };
    }
    return out;
}

pub fn findAt(triggers: []const Trigger, x: i32, y: i32) ?Trigger {
    const ux: u8 = @truncate(@as(u32, @intCast(x & 0xFF)));
    const uy: u8 = @truncate(@as(u32, @intCast(y & 0xFF)));
    for (triggers) |t| {
        if (t.x == ux and t.y == uy) return t;
    }
    return null;
}

/// World → submap map id: low byte from trigger + `$1701` high bank.
/// trigger.asm @9dd4–@9ddf: leaving under/moon sets `$1701=1` → maps 256–511.
pub fn worldDestMapId(dest_map_lo: u8, world_id: u8) u16 {
    var id: u16 = dest_map_lo;
    if (world_id != 0) id |= 0x100;
    return id;
}

/// Submap→submap dest `$00–$FA`: CheckTriggerSub @9c8a only stores `$1702`;
/// `$1701` is left as-is. Host full id = dest_lo | (current high bank).
pub fn submapDestMapId(dest_map_lo: u8, current_map_id: u16) u16 {
    var id: u16 = dest_map_lo;
    if (current_map_id >= 256) id |= 0x100;
    return id;
}

/// True if dest is world-layer return (`$FB–$FD`); ROM clears `$172c` map stack.
pub fn isWorldReturnDest(dest_map: u8) bool {
    return dest_map >= 0xFB and dest_map <= 0xFD;
}

/// Side effect of a resolved transition on the map stack (host `$172c` / stack_len).
/// CheckTriggerSub @9cc2: enter_world from `$FB–$FD` → `stx $172c` (empty).
pub fn applyStackSideEffect(tr: Transition, stack_len: *usize) void {
    switch (tr) {
        .enter_world => stack_len.* = 0,
        else => {},
    }
}

/// Interpret a trigger as a field transition.
///
/// `from_world_id`: if non-null, trigger is a world-layer entry on that `$1700` world.
/// `current_map_id`: field map id when resolving **submap** triggers (for `$1701` bank).
/// Sub-map dest_map encoding (CheckTriggerSub / rip schema):
/// - $00–$FA: warp to that map id (high bank retained from current map)
/// - $FB–$FD: return to world layer (dest − $FB); stack clear is host apply
/// - $FE: treasure (chest data in dest bytes — not a walk warp)
/// - $FF: trigger script / event (dest_x = script id)
pub fn resolve(t: Trigger, from_world_id: ?u8, current_map_id: u16) Transition {
    if (from_world_id) |wid| {
        if (t.dest_map == 0xFF) return .{ .event = t.dest_x };
        // World trigger: dest_map is submap low id; under/moon OR $100 via $1701.
        return .{
            .enter_submap = .{
                .map_id = worldDestMapId(t.dest_map, wid),
                .x = t.dest_x & 0x3F,
                .y = t.dest_y,
                .facing = t.dest_x >> 6,
            },
        };
    }
    // Sub-map trigger
    if (t.dest_map == 0xFF) return .{ .event = t.dest_x };
    if (t.dest_map == 0xFE) return .none; // treasure — handled by chest logic, not walk
    if (t.dest_map >= 0xFB) {
        return .{
            .enter_world = .{
                .world = t.dest_map -% 0xFB,
                .x = t.dest_x,
                .y = t.dest_y,
            },
        };
    }
    return .{
        .enter_submap = .{
            .map_id = submapDestMapId(t.dest_map, current_map_id),
            .x = t.dest_x & 0x3F,
            .y = t.dest_y,
            .facing = t.dest_x >> 6,
        },
    };
}

test "worldDestMapId under/moon sets high bank" {
    try std.testing.expectEqual(@as(u16, 96), worldDestMapId(96, 0));
    // Moon Lunar's Lair: dest $60 + $1701 → map 352
    try std.testing.expectEqual(@as(u16, 0x160), worldDestMapId(0x60, 2));
    try std.testing.expectEqual(@as(u16, 346), worldDestMapId(0x5A, 2)); // Cave Bahamut
    try std.testing.expectEqual(@as(u16, 0x160), worldDestMapId(0x60, 1)); // under also high
}

test "submapDestMapId preserves high bank CheckTriggerSub" {
    // On Lunar's Lair (352), dest $60 → 0x160 not 96 (Eblan King)
    try std.testing.expectEqual(@as(u16, 0x160), submapDestMapId(0x60, 352));
    try std.testing.expectEqual(@as(u16, 0x161), submapDestMapId(0x61, 0x160));
    // Low-bank Baron-area maps: dest stays low
    try std.testing.expectEqual(@as(u16, 36), submapDestMapId(36, 0));
    try std.testing.expectEqual(@as(u16, 0x24), submapDestMapId(0x24, 100));
    try std.testing.expect(isWorldReturnDest(0xFB));
    try std.testing.expect(isWorldReturnDest(0xFD));
    try std.testing.expect(!isWorldReturnDest(0xFA));
    try std.testing.expect(!isWorldReturnDest(0xFE));
}

test "resolve world moon cave not Eblan low map" {
    // WorldTriggers3 (28,25) → map $60 → must be 352 not 96 (Eblan King)
    const t = Trigger{ .x = 28, .y = 25, .dest_map = 0x60, .dest_x = 16, .dest_y = 28 };
    const tr = resolve(t, 2, 0);
    switch (tr) {
        .enter_submap => |e| {
            try std.testing.expectEqual(@as(u16, 352), e.map_id);
            try std.testing.expectEqual(@as(u8, 16), e.x);
            try std.testing.expectEqual(@as(u8, 28), e.y);
        },
        else => try std.testing.expect(false),
    }
    // Same trigger on OW would be map 96 (Eblan) — different world table, but bit rule:
    try std.testing.expectEqual(@as(u16, 96), worldDestMapId(0x60, 0));
}

test "resolve submap high-bank door not low namesake" {
    // Floor door on map 352 with dest_map $60 → 0x160 (not Eblan 96)
    const t = Trigger{ .x = 8, .y = 10, .dest_map = 0x60, .dest_x = 0x10, .dest_y = 20 };
    const tr = resolve(t, null, 352);
    switch (tr) {
        .enter_submap => |e| try std.testing.expectEqual(@as(u16, 0x160), e.map_id),
        else => try std.testing.expect(false),
    }
    // Low bank: same bytes → map 96
    const tr_lo = resolve(t, null, 40);
    switch (tr_lo) {
        .enter_submap => |e| try std.testing.expectEqual(@as(u16, 0x60), e.map_id),
        else => try std.testing.expect(false),
    }
}

test "resolve submap FB-FD is world return" {
    const t = Trigger{ .x = 15, .y = 30, .dest_map = 0xFB, .dest_x = 100, .dest_y = 150 };
    const tr = resolve(t, null, 352);
    switch (tr) {
        .enter_world => |e| {
            try std.testing.expectEqual(@as(u8, 0), e.world);
            try std.testing.expectEqual(@as(u8, 100), e.x);
            try std.testing.expectEqual(@as(u8, 150), e.y);
        },
        else => try std.testing.expect(false),
    }
    const t2 = Trigger{ .x = 0, .y = 0, .dest_map = 0xFD, .dest_x = 1, .dest_y = 2 };
    switch (resolve(t2, null, 0)) {
        .enter_world => |e| try std.testing.expectEqual(@as(u8, 2), e.world),
        else => try std.testing.expect(false),
    }
}

test "applyStackSideEffect clears stack on world return" {
    var stack_len: usize = 5;
    const t = Trigger{ .x = 0, .y = 0, .dest_map = 0xFB, .dest_x = 10, .dest_y = 20 };
    const tr = resolve(t, null, 352);
    applyStackSideEffect(tr, &stack_len);
    try std.testing.expectEqual(@as(usize, 0), stack_len);

    // Submap door does not clear stack
    stack_len = 3;
    const door = Trigger{ .x = 1, .y = 1, .dest_map = 0x60, .dest_x = 0, .dest_y = 0 };
    applyStackSideEffect(resolve(door, null, 352), &stack_len);
    try std.testing.expectEqual(@as(usize, 3), stack_len);

    // World→cave does not clear stack (push happens on enterSubmap)
    stack_len = 2;
    applyStackSideEffect(resolve(door, 2, 0), &stack_len);
    try std.testing.expectEqual(@as(usize, 2), stack_len);
}
