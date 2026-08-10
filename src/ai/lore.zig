//! Final Fantasy IV (US: Final Fantasy II) location + story cards for NPC chat.
//!
//! Strategy for small models (Gemma E2B): never dump a full walkthrough.
//! Inject a **short place card** (where you are, what locals know, hard forbids)
//! plus a **story phase** from key items / event flags so NPCs don't spoil the future
//! but *do* know the present world accurately.
//!
//! Map names: `map_names.zig` from aexoden/rosa `data/maps/ff2us.txt` (US SNES).
//! Fact blocks are keyed off those official names — not hand-maintained id lists.
//!
//! Also provides Whisper **initial prompt** vocabulary so STT hears Mysidia, Baron, etc.
const std = @import("std");
const map_names = @import("map_names.zig");

/// Bias whisper.cpp toward FF4 names (`whisper-cli --prompt`).
/// Keep under ~224 tokens; prose style works better than a bare word list.
pub const stt_initial_prompt =
    \\Final Fantasy. Places: Baron, Baron Castle, Baron Town, Mist, Kaipo, Damcyan, Fabul, Mysidia, Troia, Agart, Eblan, Mt. Ordeals, Tower of Zot, Tower of Babil, Underworld, Dwarven Castle, Red Wings.
    \\People: Cecil, Kain, Rosa, Rydia, Tellah, Edward, Yang, Palom, Porom, Cid, Edge, Golbez, King of Baron.
    \\
;

/// Common STT mishearings → canonical spelling (applied after Whisper).
const stt_fixups = [_]struct { bad: []const u8, good: []const u8 }{
    // Mysidia
    .{ .bad = "my city a", .good = "Mysidia" },
    .{ .bad = "my city of", .good = "Mysidia" },
    .{ .bad = "miss idea", .good = "Mysidia" },
    .{ .bad = "missidia", .good = "Mysidia" },
    .{ .bad = "mycidia", .good = "Mysidia" },
    .{ .bad = "my cydia", .good = "Mysidia" },
    .{ .bad = "macidia", .good = "Mysidia" },
    // Baron / castle
    .{ .bad = "barren", .good = "Baron" },
    .{ .bad = "barron", .good = "Baron" },
    .{ .bad = "the barren", .good = "Baron" },
    .{ .bad = "bearing castle", .good = "Baron Castle" },
    .{ .bad = "baron castle", .good = "Baron Castle" },
    // Other places
    .{ .bad = "kai po", .good = "Kaipo" },
    .{ .bad = "kaipo", .good = "Kaipo" },
    .{ .bad = "dam cyan", .good = "Damcyan" },
    .{ .bad = "damcyon", .good = "Damcyan" },
    .{ .bad = "fabulous", .good = "Fabul" }, // careful: only when standalone-ish
    .{ .bad = "fabul", .good = "Fabul" },
    .{ .bad = "troy a", .good = "Troia" },
    .{ .bad = "troya", .good = "Troia" },
    .{ .bad = "a guard", .good = "Agart" }, // weak; prefer longer
    .{ .bad = "agart", .good = "Agart" },
    .{ .bad = "eblin", .good = "Eblan" },
    .{ .bad = "eblon", .good = "Eblan" },
    .{ .bad = "eblan", .good = "Eblan" },
    .{ .bad = "babel", .good = "Babil" },
    .{ .bad = "babil", .good = "Babil" },
    .{ .bad = "mount ordeals", .good = "Mt. Ordeals" },
    .{ .bad = "mt ordeals", .good = "Mt. Ordeals" },
    .{ .bad = "tower of zot", .good = "Tower of Zot" },
    .{ .bad = "tower of bought", .good = "Tower of Zot" },
    // People
    .{ .bad = "cecil", .good = "Cecil" },
    .{ .bad = "kain", .good = "Kain" },
    .{ .bad = "cane", .good = "Kain" },
    .{ .bad = "rosa", .good = "Rosa" },
    .{ .bad = "rydia", .good = "Rydia" },
    .{ .bad = "radio", .good = "Rydia" },
    .{ .bad = "tellah", .good = "Tellah" },
    .{ .bad = "yang", .good = "Yang" },
    .{ .bad = "palom", .good = "Palom" },
    .{ .bad = "porom", .good = "Porom" },
    .{ .bad = "golbez", .good = "Golbez" },
    .{ .bad = "goldbez", .good = "Golbez" },
    .{ .bad = "red wings", .good = "Red Wings" },
};

/// Apply case-insensitive whole-phrase replacements for FF4 names.
/// Caller owns returned slice (may equal `input` if unchanged — always newly allocated).
pub fn fixupSttTranscript(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, input);
    errdefer allocator.free(out);

    // Longer bad phrases first (already ordered roughly).
    for (stt_fixups) |pair| {
        out = try replaceIgnoreCase(allocator, out, pair.bad, pair.good);
    }
    return out;
}

fn replaceIgnoreCase(allocator: std.mem.Allocator, hay: []u8, needle: []const u8, repl: []const u8) ![]u8 {
    if (needle.len == 0 or hay.len < needle.len) return hay;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, hay.len);

    var i: usize = 0;
    while (i < hay.len) {
        if (i + needle.len <= hay.len and asciiEqlIgnoreCase(hay[i .. i + needle.len], needle)) {
            // Prefer word-ish boundaries so "fabulous" alone isn't always Fabul —
            // still apply if at start/end or surrounded by non-letters.
            const left_ok = i == 0 or !std.ascii.isAlphabetic(hay[i - 1]);
            const right_ok = i + needle.len >= hay.len or !std.ascii.isAlphabetic(hay[i + needle.len]);
            if (left_ok and right_ok) {
                try result.appendSlice(allocator, repl);
                i += needle.len;
                continue;
            }
        }
        try result.append(allocator, hay[i]);
        i += 1;
    }

    allocator.free(hay);
    return try result.toOwnedSlice(allocator);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ─── Story phase (global progress, not spoilers for unvisited arcs) ─────────

pub const StoryPhase = enum {
    /// Opening: Mist mission / Baron still home. Cecil as Dark Knight of Baron.
    opening,
    /// Package / early road to Mist.
    mist_road,
    /// After Mist tragedy; desert / Kaipo / Damcyan arc possible.
    desert,
    /// Fabul, Leviathan, Mysidia, Mt. Ordeals — Cecil's turn toward paladin.
    ordeals,
    /// Baron return / key / waterway / reclaiming castle themes.
    baron_return,
    /// Troia / Tower of Zot / Earth Crystal.
    troia_zot,
    /// Magma stone / Agart well / Underworld.
    underworld,
    /// Tower of Babil, Eblan, sealed cave, Giant arc.
    babil,
    /// Lunar path / endgame rumors allowed where locals would know.
    lunar,
};

/// Bit flags for key items (inventory $EC–$FA).
pub const KeyBits = struct {
    pass: bool = false, // $EC
    whistle: bool = false, // $ED
    package: bool = false, // $EE
    baron_key: bool = false, // $EF
    sand_ruby: bool = false, // $F0
    earth_crystal: bool = false, // $F1
    magma_key: bool = false, // $F2
    luca_key: bool = false, // $F3
    twin_harp: bool = false, // $F4
    darkness_crystal: bool = false, // $F5
    rat_tail: bool = false, // $F6
    adamant: bool = false, // $F7
    pan: bool = false, // $F8
    pink_tail: bool = false, // $F9
    tower_key: bool = false, // $FA

    pub fn fromHas(has: *const fn (*anyopaque, u8) bool, ctx: *anyopaque) KeyBits {
        return .{
            .pass = has(ctx, 0xEC),
            .whistle = has(ctx, 0xED),
            .package = has(ctx, 0xEE),
            .baron_key = has(ctx, 0xEF),
            .sand_ruby = has(ctx, 0xF0),
            .earth_crystal = has(ctx, 0xF1),
            .magma_key = has(ctx, 0xF2),
            .luca_key = has(ctx, 0xF3),
            .twin_harp = has(ctx, 0xF4),
            .darkness_crystal = has(ctx, 0xF5),
            .rat_tail = has(ctx, 0xF6),
            .adamant = has(ctx, 0xF7),
            .pan = has(ctx, 0xF8),
            .pink_tail = has(ctx, 0xF9),
            .tower_key = has(ctx, 0xFA),
        };
    }
};

pub fn storyPhase(event_switch: []const u8, keys: KeyBits) StoryPhase {
    // Highest progress first.
    if (keys.darkness_crystal or keys.tower_key or keys.pan or keys.adamant)
        return .lunar;
    if (keys.luca_key or keys.twin_harp)
        return .babil;
    if (keys.magma_key)
        return .underworld;
    if (keys.earth_crystal)
        return .troia_zot;
    // Event switch 5 = Baron Key (also keys.baron_key).
    const sw5 = event_switch.len > 0 and (event_switch[0] & (@as(u8, 1) << 5)) != 0;
    if (keys.baron_key or sw5)
        return .baron_return;
    if (keys.sand_ruby)
        return .desert;
    // Package is often held early; sand_ruby is clearer desert marker.
    // Mist road: still opening if no sand ruby / only package.
    if (keys.package and !keys.sand_ruby and !keys.baron_key)
        return .mist_road;
    // Mt. Ordeals / Mysidia often before sand ruby is spent — hard without more flags.
    // If we have pass (hovercraft) we're in desert region play.
    if (keys.pass and !keys.sand_ruby)
        return .desert;
    return .opening;
}

fn phaseFacts(phase: StoryPhase) []const u8 {
    return switch (phase) {
        .opening =>
        \\STORY NOW (opening): Cecil is Dark Knight of Baron and Captain of the Red Wings (Mysidia crystal mission / tensions with the King may be brewing).
        \\Castle soldiers KNOW him by face and rank — "Captain", "sir". He belongs in Castle Baron; he is not a stranger or tourist.
        \\DO NOT mention: Golbez, Zot, underworld, dwarves, Babil, Giant, moon, Zeromus.
        ,
        .mist_road =>
        \\STORY NOW (mist road): The King has stripped Cecil of Red Wings command and ordered him to deliver a package to Mist (with Kain) at dawn.
        \\Castle soldiers STILL KNOW him — he is Captain Cecil / the Dark Knight, not a nameless traveler. Formal, clipped, maybe uneasy about the demotion.
        \\He may still walk the castle (rest, speak to comrades). Do not treat him as an outsider barred from the fortress. Do not use shop/inn greeter talk.
        \\DO NOT mention: underworld, moon, Giant of Babil, Zeromus. Mist's fate: only if this place lived it.
        ,
        .desert =>
        \\STORY NOW (desert arc): After Mist's tragedy. Kaipo / Antlion / Damcyan / Fabul possible. Cecil is no longer a simple "loyal captain on leave" — war and crystal theft are rumored.
        \\DO NOT invent moon/underworld details.
        ,
        .ordeals =>
        \\STORY NOW (ordeals era): Mysidia / Mt. Ordeals — light vs dark, trials of the paladin. Cecil may be turning from Dark Knight toward Holy Knight.
        \\DO NOT spoil underworld empire or lunar core unless speaker is a sage who would know legends only.
        ,
        .baron_return =>
        \\STORY NOW (Baron return): Baron Key / old waterway / false king / reclaiming Baron. Castle may be compromised; not the friendly home of the opening.
        \\DO NOT spoil lunar finale. Underworld only as vague "depths of the earth" rumor if relevant.
        ,
        .troia_zot =>
        \\STORY NOW (Troia/Zot): Earth Crystal arc, Magus Sisters, crystals contested. Heroes are known travelers of renown in some courts.
        \\DO NOT invent moon base details.
        ,
        .underworld =>
        \\STORY NOW (underworld): Magma path open. Dwarves, dark crystals, Babil loom. Surface towns know little of dwarf politics.
        ,
        .babil =>
        \\STORY NOW (Babil/Eblan): Tower of Babil, Eblan, sealed forces. Golbez and empire are known threats to the informed.
        ,
        .lunar =>
        \\STORY NOW (late/lunar): Lunar paths, final evil may be spoken of by sages. Common villagers still know mostly local life.
        ,
    };
}

/// Display name for a party member.
/// `id` is `$1000&$1F` (1-based CharProp id). Uses CharNameTbl like DrawCharName.
pub fn characterName(id: u8) []const u8 {
    const offsets = @import("../offsets.zig");
    const slot = offsets.en.charNameIndex(id) orelse return "a traveler";
    return switch (slot) {
        0 => "Cecil",
        1 => "Kain",
        2 => "Rydia",
        3 => "Tellah",
        4 => "Edward",
        5 => "Rosa",
        6 => "Yang",
        7 => "Palom",
        8 => "Porom",
        9 => "Cid",
        10 => "Edge",
        11 => "FuSoYa",
        12 => "Golbez",
        13 => "Anna",
        else => "a traveler",
    };
}

/// One party slot for voice prompts.
pub const PartyMemberBrief = struct {
    id: u8,
    present: bool,
};

/// Compact party for voice prompts (ids only; names resolved here).
pub const PartySnapshot = struct {
    /// Character ids for present members, leader first. Empty slots ignored.
    ids: [5]u8 = .{0} ** 5,
    n: u8 = 0,

    pub fn fromPresent(members: []const PartyMemberBrief) PartySnapshot {
        var p: PartySnapshot = .{};
        for (members) |m| {
            if (!m.present) continue;
            if (p.n >= p.ids.len) break;
            p.ids[p.n] = m.id;
            p.n += 1;
        }
        if (p.n == 0) {
            // New game always has Cecil as leader.
            p.ids[0] = 0;
            p.n = 1;
        }
        return p;
    }
};

fn cecilTitle(phase: StoryPhase) []const u8 {
    return switch (phase) {
        .opening => "Cecil Harvey — Dark Knight of Baron, Captain of the Red Wings (known by face to castle soldiers)",
        .mist_road => "Cecil Harvey — Dark Knight; the King stripped his Red Wings command and ordered him to Mist with a package (castle staff still know him as Captain)",
        .desert => "Cecil — once Captain of Baron's Red Wings, now a man on a harder road after Mist",
        .ordeals => "Cecil — warrior between dark and light (path toward Holy Knight / Paladin)",
        .baron_return, .troia_zot, .underworld, .babil, .lunar => "Cecil — Holy Knight / the captain who left Baron's dark path (known to many by reputation)",
    };
}

/// Pick a real US SNES script excerpt file (under data/lore/excerpts/) for place+phase.
/// These are cut from the SineNomine GameFAQs US SNES script dump — not invented rules.
pub fn excerptRelPath(phase: StoryPhase, place_name: []const u8) ?[]const u8 {
    const p = place_name;
    const baron = std.mem.indexOf(u8, p, "Baron") != null;
    const mist = std.mem.indexOf(u8, p, "Mist") != null;
    const kaipo = std.mem.indexOf(u8, p, "Kaipo") != null or std.mem.indexOf(u8, p, "desert") != null;
    const damcyan = std.mem.indexOf(u8, p, "Damcyan") != null;
    const fabul = std.mem.indexOf(u8, p, "Fabul") != null;
    const mysidia = std.mem.indexOf(u8, p, "Mysidia") != null;
    const ordeals = std.mem.indexOf(u8, p, "Ordeals") != null;

    return switch (phase) {
        .opening, .mist_road => blk: {
            if (baron) break :blk "data/lore/excerpts/baron_castle_opening.txt";
            if (mist) break :blk "data/lore/excerpts/mist_opening.txt";
            break :blk "data/lore/excerpts/baron_castle_opening.txt"; // early game default beat
        },
        .desert => blk: {
            if (damcyan) break :blk "data/lore/excerpts/damcyan.txt";
            if (fabul) break :blk "data/lore/excerpts/fabul.txt";
            if (kaipo or mist) break :blk "data/lore/excerpts/kaipo_desert.txt";
            break :blk "data/lore/excerpts/kaipo_desert.txt";
        },
        .ordeals, .baron_return => blk: {
            if (ordeals or mysidia) break :blk "data/lore/excerpts/mysidia_ordeals.txt";
            if (baron) break :blk "data/lore/excerpts/baron_castle_opening.txt";
            break :blk "data/lore/excerpts/mysidia_return.txt";
        },
        else => blk: {
            if (fabul) break :blk "data/lore/excerpts/fabul.txt";
            if (damcyan) break :blk "data/lore/excerpts/damcyan.txt";
            if (mysidia or ordeals) break :blk "data/lore/excerpts/mysidia_ordeals.txt";
            break :blk null;
        },
    };
}

/// Load up to `max_bytes` of a lore excerpt (UTF-8 text). Caller frees non-empty result.
/// Returns empty slice (do not free) on missing file.
pub fn loadExcerpt(allocator: std.mem.Allocator, io: std.Io, root: []const u8, rel: []const u8, max_bytes: usize) []u8 {
    const path = std.fs.path.join(allocator, &.{ root, rel }) catch return &[_]u8{};
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes)) catch return &[_]u8{};
}

// ─── Places ─────────────────────────────────────────────────────────────────

pub const Place = struct {
    name: []const u8,
    region: []const u8,
    facts: []const u8,
    forbid: []const u8,
};

fn P(name: []const u8, region: []const u8, facts: []const u8, forbid: []const u8) Place {
    return .{ .name = name, .region = region, .facts = facts, .forbid = forbid };
}

/// Overworld regions by approximate US map coordinates (from world trigger table).
fn placeOverworld(x: i32, y: i32) Place {
    // Baron capital approach
    if (x >= 95 and x <= 110 and y >= 150 and y <= 165)
        return baronFields();
    // Mist mountains
    if (x >= 90 and x <= 105 and y >= 110 and y <= 130)
        return P("the mountain approaches of Mist", "east of Baron", mistFacts(), mistForbid());
    // Kaipo desert
    if (x >= 115 and x <= 140 and y >= 95 and y <= 115)
        return P("the desert near Kaipo", "eastern desert", kaipoFacts(), desertForbid());
    // Fabul / east mountains
    if (x >= 90 and x <= 110 and y >= 75 and y <= 95)
        return P("the coasts and peaks near Fabul", "eastern kingdom of Fabul", fabulFacts(), fabulForbid());
    // Mysidia south
    if (x >= 145 and x <= 165 and y >= 190 and y <= 210)
        return P("the approaches to Mysidia", "southern shores", mysidiaFacts(), mysidiaForbid());
    // Troia east
    if (x >= 200 and x <= 230 and y >= 120 and y <= 145)
        return P("the wooded approaches to Troia", "eastern forests", troiaFacts(), troiaForbid());
    // Agart
    if (x >= 30 and x <= 45 and y >= 75 and y <= 90)
        return P("the hills of Agart", "southwestern mountains", agartFacts(), agartForbid());
    // Eblan
    if (x >= 95 and x <= 115 and y >= 205 and y <= 225)
        return P("the volcanic coasts of Eblan", "southwestern isles", eblanFacts(), eblanForbid());
    // Damcyan-ish central desert castle area (76,132)
    if (x >= 70 and x <= 90 and y >= 115 and y <= 140)
        return P("the desert around Damcyan", "northern desert", damcyanFacts(), desertForbid());

    return P(
        "the open wilds of the Blue Planet",
        "overworld",
        "You are outdoors between settlements. Name only landmarks a traveler here would know.",
        "Do not invent towns within a day's walk unless they are famous regional neighbors. No moon base tours.",
    );
}

/// Resolve place from engine `map_id` using the rosa US map-name table.
pub fn placeFromMapId(map_id: u16) Place {
    if (map_names.nameFor(map_id)) |official| {
        return placeFromOfficialName(official, map_id);
    }
    return P(
        "a place on the Blue Planet",
        "Final Fantasy IV world",
        bluePlanetBasics(),
        \\Speak only as a local of *this* place. If you do not know a distant land, say so.
        \\Do not invent distances. Do not dump the entire plot.
    );
}

/// Match fact/forbid blocks from the official map name (keyword), keep exact name for the prompt.
fn placeFromOfficialName(official: []const u8, map_id: u16) Place {
    _ = map_id;
    const n = official;

    // Baron castle vs town (must be before generic "Baron")
    if (std.mem.indexOf(u8, n, "Castle Baron") != null)
        return baronCastlePlace(n);
    if (std.mem.indexOf(u8, n, "Town of Baron") != null or std.mem.indexOf(u8, n, "Black Magic Class") != null or std.mem.indexOf(u8, n, "White Magic Class") != null or std.mem.indexOf(u8, n, "Training Room") != null)
        return baronTownPlace(n);

    if (hasAny(n, &.{ "Village Mist", "Misty Cave", "Mist " }) or std.mem.eql(u8, n, "Village Mist Clearing"))
        return P(n, "mountains east of Baron", mistFacts(), mistForbid());
    if (hasAny(n, &.{ "Kaipo", "Watery Pass", "Waterfalls", "Antlion" }))
        return P(n, "eastern desert / waterways", kaipoFacts(), desertForbid());
    if (hasAny(n, &.{ "Mysidia", "House of Wishes", "Serpent Road" }) and std.mem.indexOf(u8, n, "Baron") == null)
        return P(n, "city of mages, southern coast", mysidiaFacts(), mysidiaForbid());
    if (hasAny(n, &.{"Silvera"}))
        return P(n, "northern mining village of the small folk", silveraFacts(), silveraForbid());
    if (hasAny(n, &.{ "Toroia", "Toroian", "Cave Magnes" }))
        return P(n, "forest kingdom of water, greenery, and the Clerics", troiaFacts(), troiaForbid());
    if (hasAny(n, &.{"Agart"}))
        return P(n, "mountain village with the great well", agartFacts(), agartForbid());
    if (hasAny(n, &.{"Tomra", "Kokkol"}))
        return P(n, "Underworld dwarf town", "Dwarves of Tomra / Kokkol the smith — underworld life, not Agart on the surface.", "Do not claim this is Agart or Baron.");
    if (hasAny(n, &.{"Chocobo"}))
        return P(n, "woodland refuge", "Wild and black chocobos; quiet travel stops.", "No capital politics here.");
    if (hasAny(n, &.{"Fabul", "Mt.Hobs", "Mt. Hobs"}))
        return P(n, "mountain kingdom of monks", fabulFacts(), fabulForbid());
    if (hasAny(n, &.{"Damcyan"}))
        return P(n, "desert castle of bards", damcyanFacts(), desertForbid());
    if (hasAny(n, &.{ "Eblan", "Eblana", "Pass to Bab-il" }))
        return P(n, "realm of ninja, near Babil", eblanFacts(), eblanForbid());
    if (hasAny(n, &.{"Ordeals"}))
        return P(n, "holy mountain of trials", ordealsFacts(), ordealsForbid());
    if (hasAny(n, &.{ "Castle of Dwarves", "Dwarf", "Underworld" }) or hasAny(n, &.{"Sealed Cave", "Sylvan Cave", "Land of Monsters", "Town of Monsters"}))
        return P(n, "Underworld", underworldFacts(), underworldForbid());
    if (hasAny(n, &.{ "Tower of Zot", "Grotto Adamant" }))
        return P(n, "skies above the surface world", zotFacts(), zotForbid());
    if (hasAny(n, &.{ "Bab-il", "Babil", "Giant of Bab" }))
        return P(n, "spire linking surface and depths", babilFacts(), babilForbid());
    if (hasAny(n, &.{ "Lunar", "Hummingway", "Bahamut", "Big Whale" }))
        return P(n, "the Moon", lunarFacts(), lunarForbid());
    if (hasAny(n, &.{"Airship", "Ship (", "Port of"}))
        return P(n, "travel / airship", "You are aboard or beside a vessel of the age of airships.", "Do not invent full plots of every kingdom.");

    // Named but no hub match — still inject the exact map name.
    return P(
        n,
        "Final Fantasy IV world",
        bluePlanetBasics(),
        \\Speak as someone who is in this exact map. Prefer the map name over inventing a different town.
        \\Do not invent distances. Do not dump the entire plot.
    );
}

fn hasAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |nd| {
        if (std.mem.indexOf(u8, hay, nd) != null) return true;
    }
    return false;
}

fn baronCastlePlace(official: []const u8) Place {
    return P(
        official,
        "Kingdom of Baron — Castle Baron",
        \\You are INSIDE CASTLE BARON — throne, barracks, Red Wings — a military fortress.
        \\You are NOT in Town of Baron, NOT in a shop, NOT at an inn front desk.
        \\Locals say "Salute!", speak of the King, and of this castle. Town of Baron is outside under the walls (short walk).
        \\Sovereign = King of Baron (never call a man "the Baron"). Mist is a mountain village far east.
    ,
        \\FORBIDDEN: "welcome to Baron Town", "welcome to the shop", "welcome to the inn", "come on in!", tourist greeter talk.
        \\FORBIDDEN: "the Baron" as a person. You serve Castle Baron.
    );
}

fn baronTownPlace(official: []const u8) Place {
    return P(
        official,
        "Kingdom of Baron — Town of Baron",
        \\You are in TOWN OF BARON — inns, shops, houses under the castle walls (or a training room of the capital).
        \\Castle Baron is next door (short walk), not this map unless the name says Castle. Shop hospitality is fine for merchants.
        \\Sovereign = King of Baron (never "the Baron" as a man).
    ,
        \\FORBIDDEN: "the Baron" as a man. FORBIDDEN: saying the castle is far from town.
        \\Do not dump endgame lore unless story phase allows vague war rumors only.
    );
}

pub fn resolvePlace(map_id: u16, on_overworld: bool, world_x: i32, world_y: i32) Place {
    if (on_overworld) return placeOverworld(world_x, world_y);
    return placeFromMapId(map_id);
}

// ─── Fact blocks (shared strings) ───────────────────────────────────────────

fn bluePlanetBasics() []const u8 {
    return
    \\This is the world of FINAL FANTASY IV (called Final Fantasy II in the US SNES release) — a fantasy world, not Earth.
    \\The surface world is the Blue Planet. Kingdoms and cities are PLACES, never people:
    \\  Baron, Fabul, Damcyan, Troia, Eblan, Mysidia, Kaipo, Mist, Agart — all place-names.
    \\Airships of Baron are the Red Wings. Crystals are holy. Magic and steel both shape war.
    ;
}

/// Always injected: naming rules models commonly get wrong.
fn worldGlossary() []const u8 {
    return
    \\NAMING (strict):
    \\- Baron = kingdom AND its capital (castle + town). NEVER "the Baron" as a man. Say "Baron", "the kingdom of Baron", "Baron Castle", or "the King of Baron".
    \\- The ruler is "the King" / "King of Baron" — not "Baron" as a personal name, and not "the Baron".
    \\- Mist, Kaipo, Fabul, Damcyan, Mysidia, Troia, Agart, Eblan = places (towns/kingdoms). Never treat them as people.
    \\- Cecil, Kain, Rosa, Rydia, Tellah, Edward, Yang, Palom, Porom, Cid, Edge, Golbez = people (only name them if a local would).
    \\- Red Wings = Baron's air force (ships), not a person.
    \\- Dark Knight / Dragoon / White Mage = roles or titles, often of Baron's military or clergy.
    \\- Prefer: "in Baron", "to Baron Castle", "our king". Forbidden: "the Baron says", "meet the Baron", "Sir Baron".
    ;
}

fn baronFields() Place {
    return P(
        "the fields outside Baron",
        "Kingdom of Baron (capital plain)",
        \\You stand on the capital plain of the kingdom of Baron. Baron Castle and Baron Town sit side by side — minutes apart on foot.
        \\The King of Baron rules from the castle. The Red Wings (airships) and Dark Knights serve the crown. Kain is a known Dragoon of Baron.
        \\People say "Baron" for this land and city; they never call a man "the Baron".
    ,
        \\NEVER say the castle is far from town. NEVER say "the Baron" meaning a person.
        \\Say "the King", "Baron Castle", or "the kingdom of Baron".
    );
}

/// From rosa names: any map whose title contains "Castle Baron".
pub fn isBaronCastleMap(map_id: u16) bool {
    return map_names.isBaronCastle(map_id);
}

/// Town of Baron streets/shops/houses (not the castle).
pub fn isBaronTownMap(map_id: u16) bool {
    return map_names.isBaronTown(map_id);
}

fn silveraFacts() []const u8 {
    return
    \\Silvera (US name; mythril country of the small folk) — mining village. They dig silver/mythril; travelers look like giants.
    \\Not Troia, not a human capital. Silver mine nearby.
    ;
}
fn silveraForbid() []const u8 {
    return "FORBIDDEN: claiming this is Troia, Baron, or a human city. Do not invent Epopts or clerics here.";
}

fn mistFacts() []const u8 {
    return 
    \\Mist is a mountain village of summoners/calligraphers east of Baron, past caves and peaks.
    \\Rydia of Mist is a child of that tradition. Baron's army has cast a long shadow over this place.
    ;
}
fn mistForbid() []const u8 {
    return "Do not place Mist next door to Baron's inn. Do not casually spoil the Bomb Ring atrocity unless speaking as a survivor of Mist.";
}

fn kaipoFacts() []const u8 {
    return 
    \\Kaipo is an oasis town in the desert — rest, water, and healers. The desert holds Antlion dens and roads to Damcyan.
    \\Hovercraft legends and sand seas define travel here.
    ;
}
fn desertForbid() []const u8 {
    return "No alpine forests inside Kaipo. Damcyan is a desert castle of song, not a port city.";
}

fn damcyanFacts() []const u8 {
    return 
    \\Damcyan is a desert kingdom/castle famed for music and Edward the bard-prince. Vulnerable to airship assault.
    \\Neighbors: desert routes toward Kaipo and the Antlion's nest.
    ;
}

fn fabulFacts() []const u8 {
    return 
    \\Fabul is a mountain kingdom of monks (Yang is their master). Castle overlooks harsh peaks and sea approaches.
    \\Proud martial culture; crystals and honor matter. Baron's Red Wings are a feared sky power.
    ;
}
fn fabulForbid() []const u8 {
    return "Fabul is not a desert oasis. Do not relocate Yang to Baron's barracks.";
}

fn mysidiaFacts() []const u8 {
    return 
    \\Mysidia is the city of mages on the southern coast — black and white magic, elders, crystal lore.
    \\They distrust dark swords and remember Baron's raids. Mt. Ordeals is the holy trial of light nearby in legend.
    ;
}
fn mysidiaForbid() []const u8 {
    return "Mysidians are not Baron foot soldiers. Do not deny the existence of magic schools here.";
}

fn ordealsFacts() []const u8 {
    return 
    \\Mt. Ordeals is a sacred mountain of trials where light tests the spirit — tied to Mysidian faith and paladin legend.
    ;
}
fn ordealsForbid() []const u8 {
    return "This is not a shopping district. Speak of trials, spirits, and resolve — not inn prices.";
}

fn troiaFacts() []const u8 {
    return 
    \\Troia is a forested kingdom ruled with clerical grace; Earth Crystal and clergy matter. Twin Harp legends, dark caves of Magnes.
    \\Tower of Zot is a feared mage-spire associated with kidnappings and crystal plots.
    ;
}
fn troiaForbid() []const u8 {
    return "Troia is not a dwarf underworld city. No lava streets.";
}

fn zotFacts() []const u8 {
    return 
    \\A tower of sorcery and captivity — Magus Sisters, crystal schemes, and those who serve a dark master of the age.
    ;
}
fn zotForbid() []const u8 {
    return "Do not describe this as a peaceful village market.";
}

fn agartFacts() []const u8 {
    return 
    \\Agart is a highland village known for a bottomless well — said to reach the world's underbelly. Simple folk, deep superstitions.
    ;
}
fn agartForbid() []const u8 {
    return "Do not claim Agart is Baron's capital.";
}

fn eblanFacts() []const u8 {
    return 
    \\Eblan is the land of ninja (Edge's home). Castle and caves near the colossal Tower of Babil. Pride, stealth, and revenge against empire.
    ;
}
fn eblanForbid() []const u8 {
    return "Eblan is not Mysidia's magic university.";
}

fn underworldFacts() []const u8 {
    return 
    \\The Underworld: dwarves, dark crystals, magma seas, Castle of Dwarves, and the roots of the Tower of Babil.
    \\King Giott's folk are stout warriors. Surface airships struggle in the heat without preparation.
    ;
}
fn underworldForbid() []const u8 {
    return "Do not describe Troia's green courts as if they were here. No beach resorts in the magma.";
}

fn babilFacts() []const u8 {
    return 
    \\The Tower of Babil pierces surface and underworld — empire, cannons, sealed floors, and war against the free peoples.
    ;
}
fn babilForbid() []const u8 {
    return "This is not a quiet chocobo forest.";
}

fn lunarFacts() []const u8 {
    return 
    \\Lunar paths and the whale that sails the void — final truths of crystal and creation are whispered here.
    \\Speak with awe; few surface peasants have ever seen this.
    ;
}
fn lunarForbid() []const u8 {
    return "Do not claim every Baron innkeep has walked the moon.";
}

// ─── Prompt assembly ────────────────────────────────────────────────────────

/// Fill `buf` with a lore card grounded in ROM + US SNES script dump (not invented tone rules).
/// `map_chatter` = other NPCs' ROM lines on this map. `script_excerpt` = GameFAQs US script slice.
/// `party` = objective party identity (recognition is NOT automatic — use script/ROM cues).
pub fn formatNpcCard(
    buf: []u8,
    map_id: u16,
    on_overworld: bool,
    world_x: i32,
    world_y: i32,
    event_switch: []const u8,
    keys: KeyBits,
    party: PartySnapshot,
    map_chatter: []const u8,
    script_excerpt: []const u8,
) []const u8 {
    const place = resolvePlace(map_id, on_overworld, world_x, world_y);
    const phase = storyPhase(event_switch, keys);
    const pf = phaseFacts(phase);

    var loc_extra: [48]u8 = undefined;
    const loc_s: []const u8 = if (on_overworld)
        (std.fmt.bufPrint(&loc_extra, " overworld ({d},{d})", .{ world_x, world_y }) catch "")
    else
        "";

    const leader_id: u8 = if (party.n > 0) party.ids[0] else 0;
    const leader_name = characterName(leader_id);
    // Char id 1 = Cecil (Dark Knight / later Paladin).
    const leader_title = if (leader_id == 1 or leader_id == 0x11) cecilTitle(phase) else "a known adventurer of this age";

    var party_line: [160]u8 = undefined;
    const party_s = formatPartyLine(&party_line, party);

    const chatter = if (map_chatter.len > 0) map_chatter else "(no other map dialogue decoded)";
    const script = if (script_excerpt.len > 0) script_excerpt else "(no script excerpt for this place/phase yet)";

    // Hard pin first — small models ignore soft rules buried mid-prompt.
    const pin = locationPin(map_id, phase, place.name);

    // Keep dumps short — long greeter corpora make E2B parrot the same lines.
    const script_cap = if (script.len > 900) script[0..900] else script;
    const chatter_cap = if (chatter.len > 500) chatter[0..500] else chatter;

    return std.fmt.bufPrint(buf,
        \\=== LOCAL KNOWLEDGE (authoritative; beats training data) ===
        \\{s}
        \\Where you are: {s} ({s}) map {d}{s}
        \\
        \\Who stands before you:
        \\- Leader: {s} — {s}
        \\- With them: {s}
        \\- Story phase: {s}
        \\Recognition: follow the PIN. Castle Baron military know Cecil (Captain / Dark Knight). Random townsfolk elsewhere often only see armor, not fame.
        \\
        \\Other ROM lines on this map (tone samples — do not copy verbatim as your every reply):
        \\{s}
        \\
        \\US script notes for this place/arc (background only — not your monologue script):
        \\{s}
        \\
        \\Facts for here: {s}
        \\Phase: {s}
        \\Avoid: {s}
        \\=== END ===
    , .{
        pin,
        place.name,
        place.region,
        map_id,
        loc_s,
        leader_name,
        leader_title,
        party_s,
        @tagName(phase),
        chatter_cap,
        script_cap,
        place.facts,
        pf,
        place.forbid,
    }) catch buf[0..0];
}

/// Ultra-short hard constraints first in the card (Gemma ignores soft mid-prompt rules).
fn locationPin(map_id: u16, phase: StoryPhase, place_name: []const u8) []const u8 {
    if (isBaronCastleMap(map_id) or std.mem.indexOf(u8, place_name, "Castle Baron") != null) {
        return switch (phase) {
            .opening =>
            \\!!! PIN (obey first) !!!
            \\LOCATION = CASTLE BARON (fortress). NOT Town of Baron. NOT a shop. NOT an inn.
            \\WHO YOU FACE: CECIL — Dark Knight, Captain of the Red Wings. You KNOW him by face and rank.
            \\Address him as Captain / sir. Never act like you do not know who he is. Never call him a stranger or tourist.
            \\He is allowed in the castle (this is his post). Salute, duty, clipped military speech.
            \\NEVER: "welcome to the shop/town", "come on in we're friendly", "who are you?".
            \\!!!!!!!!!!!!!!!!!!!!!!
            ,
            .mist_road =>
            \\!!! PIN (obey first) !!!
            \\LOCATION = CASTLE BARON. NOT a shop/inn/town greeter.
            \\WHO YOU FACE: CECIL — you KNOW him. He is (was) Captain of the Red Wings, Dark Knight of Baron.
            \\Address: Captain / sir. The King stripped his command and ordered him to Mist with a package at dawn — he may still walk the castle and speak to comrades.
            \\Do NOT pretend you never met him. Do NOT bar him as a nameless outsider. Formal/uneasy military tone is right; tourist hospitality is wrong.
            \\NEVER: "welcome to the shop", "I don't know you", greeter small-talk.
            \\!!!!!!!!!!!!!!!!!!!!!!
            ,
            .baron_return =>
            \\!!! PIN !!! LOCATION=CASTLE BARON. You may know Cecil from the wars; mood is false-king / suspicion — cold, not shop greeter. !!!
            ,
            else =>
            \\!!! PIN !!! LOCATION=CASTLE BARON (military). If the party leader is Cecil, Baron soldiers know that name/rank. NOT a shop. !!!
            ,
        };
    }
    if (isBaronTownMap(map_id) or std.mem.indexOf(u8, place_name, "Town of Baron") != null) {
        return 
        \\!!! PIN !!! LOCATION=TOWN OF BARON (streets/shops/inn under the walls). Castle Baron is next door, not this map. Shop warmth OK for merchants. !!!
        ;
    }
    // Generic pin — exact map name is already in the LOCATION line above.
    return 
    \\!!! PIN !!! Stay in the LOCATION named above (official map name). Do not invent a different town or a shop unless that name says so. !!!
    ;
}

fn formatPartyLine(buf: []u8, party: PartySnapshot) []const u8 {
    if (party.n <= 1) return "none (leader alone)";
    var pos: usize = 0;
    var i: u8 = 1;
    while (i < party.n) : (i += 1) {
        const name = characterName(party.ids[i]);
        if (i > 1) {
            if (pos + 2 > buf.len) break;
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        if (pos + name.len > buf.len) break;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
    }
    return if (pos > 0) buf[0..pos] else "none";
}
