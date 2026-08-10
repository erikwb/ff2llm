//! ff4 — native engine scaffold for Final Fantasy II (US) / Final Fantasy IV (SNES).
//!
//! Requires a legally obtained ROM. No game assets are redistributed.
const std = @import("std");
const Io = std.Io;

const rom_mod = @import("rom.zig");
const data_mod = @import("data.zig");
const damage = @import("battle/damage.zig");
const game_app = @import("game/app.zig");

// Re-export modules for `zig test` on the root module.
pub const rom = rom_mod;
pub const text = @import("text.zig");
pub const offsets = @import("offsets.zig");
pub const data = data_mod;
pub const battle_damage = damage;
pub const snes_gfx = @import("gfx/snes.zig");

// Pull in unit tests from imported modules when running `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("game/inventory.zig");
    _ = @import("game/event.zig");
    _ = @import("battle/item_prop.zig");
    _ = @import("battle/cmd_item.zig");
    _ = @import("battle/prop.zig");
    _ = @import("battle/encounter.zig");
}

const usage =
    \\ff4 — Final Fantasy II/IV native reimplementation
    \\
    \\Usage:
    \\  ff4 play <rom>                 Play (SDL overworld + battles)
    \\  ff4 verify <rom>
    \\  ff4 dump <rom> monsters [limit]
    \\  ff4 dump <rom> items [limit]
    \\  ff4 dump <rom> characters
    \\  ff4 dump <rom> spells [limit]
    \\  ff4 dump <rom> commands
    \\  ff4 rip <rom> <outdir>
    \\  ff4 sim-damage --atk N --def N [--hits N] ...
    \\  ff4 help
    \\
    \\Play controls (keyboard):
    \\  Arrows / WASD  move
    \\  Z / Enter      confirm (dialogue / doors / battle commands)
    \\  Face NPC       open mic — speak freely; they answer when you pause
    \\  Esc            cancel listen / close dialogue / title
    \\  X / Tab / M    field: main menu (SNES X); battle: flee (L+R)
    \\  K              debug: give Baron Key (item gates)
    \\
    \\Play controls (gamepad — Xbox layout names):
    \\  D-pad / left stick   move
    \\  A (south)            confirm / advance dialogue
    \\  B (east) / Start     cancel / close dialogue / title
    \\  Select+Y             debug Baron Key (same as K)
    \\
    \\Notes:
    \\  - Needs SDL3. Accepts .smc or headerless 1 MiB LoROM.
    \\  - English US dumps (CRC 0x65D0A825 / 0x23084FCD).
    \\  - Do not redistribute extracted game data.
    \\  - Voice: face an NPC and talk (VAD). Run from repo root (models/ + vendor/).
    \\  - Mic opens once at startup so Bluetooth stays on HFP duplex (no mid-game A2DP kill).
    \\  - LLM is in-process libllama (ROCm). System: pacman -S llama-cpp ggml.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.next(); // argv0

    const cmd = args.next() orelse {
        try printStdout(io, "{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        try printStdout(io, "{s}", .{usage});
        return;
    }

    if (std.mem.eql(u8, cmd, "play")) {
        const path = args.next() orelse return fail(io, "play: missing <rom>");
        try game_app.run(io, gpa, path);
        return;
    }

    if (std.mem.eql(u8, cmd, "verify")) {
        const path = args.next() orelse return fail(io, "verify: missing <rom>");
        try cmdVerify(io, gpa, path);
        return;
    }

    if (std.mem.eql(u8, cmd, "dump")) {
        const path = args.next() orelse return fail(io, "dump: missing <rom>");
        const what = args.next() orelse return fail(io, "dump: missing table name");
        const limit_str = args.next();
        const limit: ?usize = if (limit_str) |s| try std.fmt.parseInt(usize, s, 10) else null;
        try cmdDump(io, gpa, path, what, limit);
        return;
    }

    if (std.mem.eql(u8, cmd, "rip")) {
        const path = args.next() orelse return fail(io, "rip: missing <rom>");
        const outdir = args.next() orelse return fail(io, "rip: missing <outdir>");
        try cmdRip(io, gpa, path, outdir);
        return;
    }

    if (std.mem.eql(u8, cmd, "sim-damage")) {
        try cmdSimDamage(io, &args);
        return;
    }

    try fail(io, "unknown command (try: ff4 help)");
}

fn fail(io: Io, msg: []const u8) !void {
    try printStderr(io, "error: {s}\n", .{msg});
    std.process.exit(1);
}

fn printStdout(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn cmdVerify(io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
    var r = try rom_mod.load(io, gpa, path);
    defer r.deinit();

    try printStdout(io,
        \\ROM:      {s}
        \\Size:     {d} bytes ({s})
        \\Title:    {s}
        \\CRC32:    0x{X:0>8}
        \\Version:  {s}
        \\Country:  {d}
        \\ROM ver:  {d}
        \\Reset:    ${X:0>4}
        \\NMI:      ${X:0>4}
        \\
    , .{
        path,
        r.data.len,
        if (r.has_smc_header) "SMC header stripped" else "headerless",
        r.header.titleSlice(),
        r.crc32,
        r.version.name(),
        r.header.country,
        r.header.version,
        r.header.reset_vector,
        r.header.nmi_vector,
    });

    if (r.version == .unknown) {
        try printStdout(io, "warning: CRC not in known set; extractors assume English layout.\n", .{});
    } else if (!r.version.isEnglish()) {
        try printStdout(io, "warning: Japanese ROM — English name tables may not match.\n", .{});
    } else {
        try printStdout(io, "status:   OK (known English image)\n", .{});
    }
}

fn cmdDump(io: Io, gpa: std.mem.Allocator, path: []const u8, what: []const u8, limit: ?usize) !void {
    var r = try rom_mod.load(io, gpa, path);
    defer r.deinit();

    var gd = try data_mod.extract(gpa, &r);
    defer gd.deinit();

    if (std.mem.eql(u8, what, "monsters")) {
        const n = @min(limit orelse gd.monsters.len, gd.monsters.len);
        try printStdout(io, "id  name            lv  hp    gil   exp   atk(a,b,c)     agi\n", .{});
        for (gd.monsters[0..n]) |m| {
            try printStdout(io, "{d:3} {s:<15} {d:2}  {d:5} {d:5} {d:5} ({d:3},{d:3},{d:3})  {d}-{d}{s}\n", .{
                m.id,
                m.name,
                m.level,
                m.hp,
                m.gil,
                m.exp,
                m.attack_params.a,
                m.attack_params.b,
                m.attack_params.c,
                m.agility_min,
                m.agility_max,
                if (m.is_boss) " BOSS" else "",
            });
        }
        return;
    }

    if (std.mem.eql(u8, what, "items")) {
        const n = @min(limit orelse gd.items.len, gd.items.len);
        for (gd.items[0..n]) |it| {
            if (it.name.len == 0) continue;
            try printStdout(io, "{d:3}  icon=0x{X:0>2}  {s}\n", .{ it.id, it.icon, it.name });
        }
        return;
    }

    if (std.mem.eql(u8, what, "characters") or std.mem.eql(u8, what, "chars")) {
        try printStdout(io, "id name     lv   hp/mhp    mp/mmp   str agi vit wis wil\n", .{});
        for (gd.characters) |c| {
            try printStdout(io, "{d:2} {s:<8} {d:2}  {d:4}/{d:<4}  {d:3}/{d:<3}  {d:3} {d:3} {d:3} {d:3} {d:3}\n", .{
                c.id,
                c.name,
                c.level,
                c.hp,
                c.max_hp,
                c.mp,
                c.max_mp,
                c.strength,
                c.agility,
                c.vitality,
                c.wisdom,
                c.will,
            });
        }
        return;
    }

    if (std.mem.eql(u8, what, "spells")) {
        const n = @min(limit orelse gd.spell_names.len, gd.spell_names.len);
        for (gd.spell_names[0..n], 0..) |name, i| {
            if (name.len == 0) continue;
            try printStdout(io, "{d:3}  {s}\n", .{ i, name });
        }
        return;
    }

    if (std.mem.eql(u8, what, "commands") or std.mem.eql(u8, what, "cmds")) {
        for (gd.command_names, 0..) |name, i| {
            try printStdout(io, "{d:2}  {s}\n", .{ i, name });
        }
        return;
    }

    try fail(io, "dump: unknown table (monsters|items|characters|spells|commands)");
}

fn cmdRip(io: Io, gpa: std.mem.Allocator, path: []const u8, outdir: []const u8) !void {
    var r = try rom_mod.load(io, gpa, path);
    defer r.deinit();

    var gd = try data_mod.extract(gpa, &r);
    defer gd.deinit();

    // Ensure output directory exists
    Io.Dir.cwd().createDirPath(io, outdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    // Write a simple JSON-ish dump (hand-rolled to avoid extra deps)
    const monsters_path = try std.fmt.allocPrint(gpa, "{s}/monsters.json", .{outdir});
    defer gpa.free(monsters_path);
    try writeMonstersJson(io, gpa, monsters_path, gd.monsters);

    const chars_path = try std.fmt.allocPrint(gpa, "{s}/characters.json", .{outdir});
    defer gpa.free(chars_path);
    try writeCharactersJson(io, gpa, chars_path, gd.characters);

    const items_path = try std.fmt.allocPrint(gpa, "{s}/items.json", .{outdir});
    defer gpa.free(items_path);
    try writeItemsJson(io, gpa, items_path, gd.items);

    const meta_path = try std.fmt.allocPrint(gpa, "{s}/rom.json", .{outdir});
    defer gpa.free(meta_path);
    try writeRomMeta(io, gpa, meta_path, &r);

    try printStdout(io, "ripped to {s}/ (monsters.json, characters.json, items.json, rom.json)\n", .{outdir});
    try printStdout(io, "remember: do not redistribute extracted game data\n", .{});
}

fn writeFile(io: Io, gpa: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    _ = gpa;
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn writeMonstersJson(io: Io, gpa: std.mem.Allocator, path: []const u8, monsters: []const data_mod.Monster) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "[\n");
    for (monsters, 0..) |m, i| {
        try list.print(gpa,
            \\  {{"id":{d},"name":"{s}","level":{d},"boss":{s},"hp":{d},"gil":{d},"exp":{d},"atk":[{d},{d},{d}],"agi":[{d},{d}]}}
        , .{
            m.id,
            m.name,
            m.level,
            if (m.is_boss) "true" else "false",
            m.hp,
            m.gil,
            m.exp,
            m.attack_params.a,
            m.attack_params.b,
            m.attack_params.c,
            m.agility_min,
            m.agility_max,
        });
        if (i + 1 < monsters.len) try list.appendSlice(gpa, ",\n") else try list.appendSlice(gpa, "\n");
    }
    try list.appendSlice(gpa, "]\n");
    try writeFile(io, gpa, path, list.items);
}

fn writeCharactersJson(io: Io, gpa: std.mem.Allocator, path: []const u8, characters: []const data_mod.Character) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "[\n");
    for (characters, 0..) |c, i| {
        try list.print(gpa,
            \\  {{"id":{d},"name":"{s}","level":{d},"hp":{d},"max_hp":{d},"mp":{d},"max_mp":{d},"str":{d},"agi":{d},"vit":{d},"wis":{d},"wil":{d}}}
        , .{ c.id, c.name, c.level, c.hp, c.max_hp, c.mp, c.max_mp, c.strength, c.agility, c.vitality, c.wisdom, c.will });
        if (i + 1 < characters.len) try list.appendSlice(gpa, ",\n") else try list.appendSlice(gpa, "\n");
    }
    try list.appendSlice(gpa, "]\n");
    try writeFile(io, gpa, path, list.items);
}

fn writeItemsJson(io: Io, gpa: std.mem.Allocator, path: []const u8, items: []const data_mod.ItemName) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "[\n");
    var first = true;
    for (items) |it| {
        if (it.name.len == 0) continue;
        if (!first) try list.appendSlice(gpa, ",\n");
        first = false;
        try list.print(gpa,
            \\  {{"id":{d},"name":"{s}","icon":{d}}}
        , .{ it.id, it.name, it.icon });
    }
    try list.appendSlice(gpa, "\n]\n");
    try writeFile(io, gpa, path, list.items);
}

fn writeRomMeta(io: Io, gpa: std.mem.Allocator, path: []const u8, r: *const rom_mod.Rom) !void {
    var buf: [512]u8 = undefined;
    const contents = try std.fmt.bufPrint(&buf,
        \\{{"title":"{s}","crc32":"0x{X:0>8}","version":"{s}","smc_header":{s},"size":{d}}}
        \\
    , .{
        r.header.titleSlice(),
        r.crc32,
        r.version.name(),
        if (r.has_smc_header) "true" else "false",
        r.data.len,
    });
    try writeFile(io, gpa, path, contents);
}

fn cmdSimDamage(io: Io, args: *std.process.Args.Iterator) !void {
    var base_attack: u16 = 100;
    var defense: u16 = 20;
    var hits: u8 = 1;
    var hit_rate: u8 = 99;
    var base_hits: u8 = 1;
    var is_crit = false;
    var crit_bonus: u8 = 0;
    var elem: u8 = 2;
    var ctype: u8 = 2;
    var seed: u32 = 1;
    var use_hit_calc = false;

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--atk")) {
            base_attack = try std.fmt.parseInt(u16, args.next() orelse return fail(io, "--atk needs value"), 10);
        } else if (std.mem.eql(u8, a, "--def")) {
            defense = try std.fmt.parseInt(u16, args.next() orelse return fail(io, "--def needs value"), 10);
        } else if (std.mem.eql(u8, a, "--hits")) {
            hits = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--hits needs value"), 10);
        } else if (std.mem.eql(u8, a, "--hit-rate")) {
            hit_rate = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--hit-rate needs value"), 10);
            use_hit_calc = true;
        } else if (std.mem.eql(u8, a, "--base-hits")) {
            base_hits = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--base-hits needs value"), 10);
            use_hit_calc = true;
        } else if (std.mem.eql(u8, a, "--crit")) {
            is_crit = true;
        } else if (std.mem.eql(u8, a, "--crit-bonus")) {
            crit_bonus = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--crit-bonus needs value"), 10);
        } else if (std.mem.eql(u8, a, "--elem")) {
            elem = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--elem needs value"), 10);
        } else if (std.mem.eql(u8, a, "--type")) {
            ctype = try std.fmt.parseInt(u8, args.next() orelse return fail(io, "--type needs value"), 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            seed = try std.fmt.parseInt(u32, args.next() orelse return fail(io, "--seed needs value"), 10);
        } else {
            try fail(io, "sim-damage: unknown flag");
        }
    }

    var lcg = damage.Lcg.init(seed);
    const rng = lcg.asRng();

    if (use_hit_calc) {
        hits = damage.calcHits(.{ .base_hits = base_hits, .hit_rate = hit_rate }, rng);
    }

    const result = damage.calcDamage(.{
        .base_attack = base_attack,
        .defense = defense,
        .hits = hits,
        .elemental_mult = elem,
        .creature_mult = ctype,
        .is_crit = is_crit,
        .crit_bonus = crit_bonus,
    }, rng);

    try printStdout(io,
        \\sim-damage
        \\  attack={d}  defense={d}  hits={d}  crit={s}  elem={d}  type={d}  seed={d}
        \\  varied_attack={d}
        \\  damage={d}
        \\
    , .{
        base_attack,
        defense,
        hits,
        if (is_crit) "yes" else "no",
        elem,
        ctype,
        seed,
        result.varied_attack,
        result.damage,
    });
}
