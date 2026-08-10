//! Map each NPC to a stable Kokoro speaker + speaking style.
//!
//! Engine: hexgrad Kokoro-82M via PyTorch ROCm worker (11 English voices).
//!
//! Strategy (not generic one-voice-fits-all):
//! 1. **Archetype** from sprite sheet / palette / move class → preferred speaker
//!    and LLM persona tags (guard, elder, townsfolk, …).
//! 2. **Gender** from the decoded 16×16 sprite silhouette + palette (dress flare,
//!    hair crown, hair hue) — picks male vs female Kokoro pools.
//! 3. **Individuality**: hash of (map, prop_gfx, sheet) rotates speakers within
//!    the gender/role pool so two guards still sound different.
//! 4. **Prosody**: speed from age & temperament (speed >1 faster, <1 slower).
//!
//! Kokoro-en speaker map (sid → name):
//!   0 af, 1 af_bella, 2 af_nicole, 3 af_sarah, 4 af_sky,
//!   5 am_adam, 6 am_michael, 7 bf_emma, 8 bf_isabella, 9 bm_george, 10 bm_lewis

const std = @import("std");
const npc_mod = @import("../map/npc.zig");

pub const Archetype = enum {
    dark_knight,
    soldier,
    guard,
    townsman,
    townswoman,
    elder,
    child,
    merchant,
    scholar,
    sailor,
    monk,
    noble,
    mysterious,
    generic,
};

/// Best-effort presentation gender from the sprite art (not a ROM flag).
pub const Gender = enum {
    male,
    female,
    unknown,
};

/// How the NPC should sound when spoken through in-process Kokoro.
pub const VoiceProfile = struct {
    /// Engine label (always "kokoro" for logging / TalkResult).
    model: []const u8 = "kokoro",
    /// Kokoro speaker id (0–10 for kokoro-en-v0_19).
    speaker: u32 = 0,
    /// Speech rate: 1.0 normal; >1 faster; <1 slower (passed to OfflineTts).
    speed: f32 = 1.0,
    /// Kept for compatibility with older call sites; maps to 1/speed for Piper fallback.
    length_scale: f32 = 1.0,
    noise_scale: f32 = 0.667,
    noise_w: f32 = 0.8,
    /// Short tags for the LLM system prompt.
    persona: []const u8,
    archetype: Archetype,
    gender: Gender = .unknown,
};

/// Build a profile for this NPC on this map. Pure function — no I/O.
pub fn profileFor(npc: npc_mod.Npc, map_id: u16) VoiceProfile {
    return profileForDialogue(npc, map_id, "");
}

/// Like `profileFor`, but refine role from the ROM's canonical dialogue line + map.
/// Townspeople are **not** named in the ROM — only script id, graphics, and lines.
pub fn profileForDialogue(npc: npc_mod.Npc, map_id: u16, canon_line: []const u8) VoiceProfile {
    const gender = estimateGender(npc);
    var arch = classify(npc, gender);
    arch = refineFromDialogue(arch, canon_line);
    arch = refineFromMap(arch, map_id, canon_line);
    const h = hashNpc(npc, map_id);

    // Base persona + preferred speaker from archetype, then rotate within pool.
    var p = baseForArchetype(arch);
    p.gender = gender;
    p.model = "kokoro";
    p.speaker = pickKokoroSpeaker(arch, gender, h);

    // Light speed jitter (±3%) so identical roles aren't lockstep.
    const rate_jitter: f32 = 0.97 + @as(f32, @floatFromInt(h % 7)) * 0.01; // 0.97–1.03
    p.speed *= rate_jitter;

    // Elderly slightly slower; children a touch faster.
    if (arch == .elder) p.speed *= 0.92;
    if (arch == .child) p.speed *= 1.08;

    p.speed = clampf(p.speed, 0.85, 1.20);
    // length_scale kept as inverse of speed for any legacy readers.
    p.length_scale = 1.0 / p.speed;
    return p;
}

fn clampf(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn hashNpc(npc: npc_mod.Npc, map_id: u16) u32 {
    // FNV-1a 32-bit over identity fields.
    var h: u32 = 2166136261;
    inline for (.{
        @as(u32, map_id),
        @as(u32, npc.prop_gfx),
        @as(u32, npc.sheet_id),
        @as(u32, npc.pal_slot),
        @as(u32, npc.x),
        @as(u32, npc.y),
    }) |v| {
        h ^= v;
        h *%= 16777619;
    }
    return h;
}

/// Sheets that are clearly female-presenting in FF4 US MapSpriteGfx art
/// (dress/gown silhouette and/or known female character graphics).
/// Curated from decoded 16×16 front poses + FF4 cast knowledge.
/// Default for everything else is **male** (this game's NPC cast is mostly men).
const female_sheets = [_]u8{
    // Gown / dress silhouette (flare ≫ 1.15 on front pose)
    0x0C, // long hair + flared lower body
    0x14, // townswoman dress (strong skirt flare)
    0x15, // townswoman / girl dress
    0x1C, // bonnet + dress
    0x1E, // dancer / short dress
    0x26, // capped woman / matron
    0x27, // dress + hair
    // Known female-leaning mid sheets (white-mage / Rosa-adjacent robes)
    0x03, // full hair volume + slight flare (Rosa-class)
    0x0B, // long hair humanoid
};

/// Estimate presentation gender. **Defaults to male.**
///
/// Order:
/// 1. Explicit female sheet IDs (documented art / visual pass)
/// 2. Strict dress-flare check (bottom much wider than torso) only
/// 3. Else male (including armor, townsmen, elders, soldiers, unknown)
///
/// No ROM gender bit exists; animals/effects still return male default for voice
/// (better than a random female voice on a chest or zzz bubble that talks).
pub fn estimateGender(npc: npc_mod.Npc) Gender {
    const s = npc.sheet_id;

    // Explicit female sheet table first.
    for (female_sheets) |fs| {
        if (s == fs) return .female;
    }

    // Non-humanoid / tiny sheets → male default (voice pool), not "unknown woman".
    if (npc.move_type != 0 or npc.tile_count < 8 or npc.pose_count == 0) return .male;
    if (s >= 0x30) return .male;

    // Armor / party / soldier block: always male unless listed above.
    if (s <= 0x0A) return .male;
    if (s >= 0x16 and s <= 0x1B) return .male; // common townsmen / workers
    if (s >= 0x1D and s <= 0x1D) return .male;
    if (s >= 0x1F and s <= 0x25) return .male; // elders/scholars mostly male art
    if (s >= 0x28 and s <= 0x2F) return .male; // kids/sailors/monks — default boy/man

    // Remaining civilian-ish sheets: only female on *strong* dress flare.
    if (npc.tile_count >= 8) {
        var idx_map: [16][16]u8 = .{.{0} ** 16} ** 16;
        composeFrontPose(npc, &idx_map);
        const flare = dressFlare(idx_map);
        // Require clear skirt (was 1.12 before and false-positived everyone).
        if (flare >= 1.22) return .female;
    }

    return .male;
}

/// Bottom-row width / mid-torso width of the opaque silhouette.
fn dressFlare(idx_map: [16][16]u8) f32 {
    var row_width: [16]u32 = .{0} ** 16;
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        var left: i32 = 16;
        var right: i32 = -1;
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            if (idx_map[y][x] == 0) continue;
            if (@as(i32, @intCast(x)) < left) left = @intCast(x);
            if (@as(i32, @intCast(x)) > right) right = @intCast(x);
        }
        if (right >= left) row_width[y] = @intCast(right - left + 1);
    }
    var mid_w: f32 = 0;
    var bot_w: f32 = 0;
    var n_mid: f32 = 0;
    var n_bot: f32 = 0;
    y = 5;
    while (y <= 10) : (y += 1) {
        if (row_width[y] > 0) {
            mid_w += @floatFromInt(row_width[y]);
            n_mid += 1;
        }
    }
    y = 11;
    while (y < 16) : (y += 1) {
        if (row_width[y] > 0) {
            bot_w += @floatFromInt(row_width[y]);
            n_bot += 1;
        }
    }
    if (n_mid > 0) mid_w /= n_mid;
    if (n_bot > 0) bot_w /= n_bot;
    if (mid_w < 0.5) return 1.0;
    return bot_w / mid_w;
}

/// Front/down pose: tiles 0–3 of a standard humanoid sheet (facing south idle).
fn composeFrontPose(npc: npc_mod.Npc, out: *[16][16]u8) void {
    // Down-facing idle corners match poseCorners(facing=2, walk=0).
    const corners = [_]u8{ 0, 1, 2, 3 };
    const offs = [_]struct { x: usize, y: usize }{
        .{ .x = 0, .y = 0 },
        .{ .x = 8, .y = 0 },
        .{ .x = 0, .y = 8 },
        .{ .x = 8, .y = 8 },
    };
    for (corners, offs) |tile_i, off| {
        if (tile_i >= npc.tile_count) continue;
        const tile = npc.tiles[tile_i];
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                out[off.y + row][off.x + col] = tile[row * 8 + col];
            }
        }
    }
}

/// Heuristic sprite → social role. Sheet ids are from NPCGfxID / MapSpriteGfx classes.
/// These are **not** official ROM labels — FF4 stores no "name" or "job" field on map NPCs.
/// Cast members (Cecil, Baigan, …) use special event scripts; random townsfolk are anonymous.
fn classify(npc: npc_mod.Npc, gender: Gender) Archetype {
    const s = npc.sheet_id;
    const pal = npc.pal_slot;

    // Tiny / effect sheets — treat as mysterious if somehow talkable.
    if (s >= 0x46) return .mysterious;
    // 2-pose sheets often animals/effects/specials.
    if (s >= 0x30 and s < 0x46) {
        return if (pal == 0) .mysterious else .scholar;
    }

    // Full character sheets $00–$10 and walk-cycle $11–$2F.
    // Approximate FF4 US MapSpriteGfx conventions (armor vs robe vs dress).
    if (s <= 0x05) return .dark_knight; // armored / DK-like party-class art
    if (s >= 0x06 and s <= 0x0A) return .soldier;
    if (s >= 0x0B and s <= 0x10) return .guard;

    // Civilians: gender from sheet table / dress flare (defaults male).
    if (s >= 0x11 and s <= 0x1A) {
        return if (gender == .female) .townswoman else .townsman;
    }
    if (s >= 0x1B and s <= 0x20) return .merchant;
    if (s >= 0x21 and s <= 0x24) {
        return if (gender == .female) .townswoman else .scholar;
    }
    if (s >= 0x25 and s <= 0x28) return .elder;
    if (s >= 0x29 and s <= 0x2B) return .child;
    if (s >= 0x2C and s <= 0x2D) return .sailor;
    if (s >= 0x2E and s <= 0x2F) return .monk;

    // Unknown mid-range: male default; female only if sheet analysis said so.
    if (gender == .female) return .townswoman;
    return .townsman;
}

/// Override sheet heuristics when the ROM dialogue clearly marks a job.
fn refineFromDialogue(arch: Archetype, canon: []const u8) Archetype {
    if (canon.len == 0) return arch;
    // Case-insensitive substring checks on US dialogue.
    if (containsIgnoreCase(canon, "salute") or containsIgnoreCase(canon, "captain") or
        containsIgnoreCase(canon, "sir!") or containsIgnoreCase(canon, "my lord"))
        return .soldier;
    // Castle gossip about the King / "this castle" → soldier, not shopkeep.
    if (containsIgnoreCase(canon, "this castle") or containsIgnoreCase(canon, "our king") or
        containsIgnoreCase(canon, "his majesty") or containsIgnoreCase(canon, "the king"))
        return .soldier;
    if (containsIgnoreCase(canon, "buy") or containsIgnoreCase(canon, "sell") or
        containsIgnoreCase(canon, "gil") or containsIgnoreCase(canon, "wares") or
        containsIgnoreCase(canon, "shop") or containsIgnoreCase(canon, "customers"))
        return .merchant;
    if (containsIgnoreCase(canon, "inn") or containsIgnoreCase(canon, "room for the night"))
        return .merchant;
    // "take a rest" alone is common barracks talk — only inn if paired with money/room.
    if (containsIgnoreCase(canon, "rest") and (containsIgnoreCase(canon, "gil") or containsIgnoreCase(canon, "night")))
        return .merchant;
    if (containsIgnoreCase(canon, "spell") or containsIgnoreCase(canon, "magic") or
        containsIgnoreCase(canon, "white mage") or containsIgnoreCase(canon, "black mage"))
        return .scholar;
    if (containsIgnoreCase(canon, "your majesty") or containsIgnoreCase(canon, "my king"))
        return if (arch == .dark_knight) arch else .guard;
    if (containsIgnoreCase(canon, "child") or containsIgnoreCase(canon, "mommy") or
        containsIgnoreCase(canon, "daddy") or containsIgnoreCase(canon, "play"))
        return .child;
    return arch;
}

/// Baron Castle maps: humanoid townsfolk sheets are almost always soldiers/court, not shop greeters.
fn refineFromMap(arch: Archetype, map_id: u16, canon: []const u8) Archetype {
    const lore = @import("lore.zig");
    if (!lore.isBaronCastleMap(map_id)) return arch;
    // Already military / special.
    if (arch == .soldier or arch == .guard or arch == .dark_knight or arch == .noble or arch == .merchant)
        return arch;
    // Inn-like lines on a castle map are still rare; "rest" without shop words → soldier.
    if (arch == .townsman or arch == .townswoman or arch == .generic or arch == .sailor) {
        // Explicit shop/customer talk → leave as merchant path (shouldn't happen on 36).
        if (containsIgnoreCase(canon, "customer") or containsIgnoreCase(canon, "shop") or
            containsIgnoreCase(canon, "buy") or containsIgnoreCase(canon, "sell"))
            return .merchant;
        return .soldier;
    }
    return arch;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            const hc = hay[i + j];
            const a = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            const b = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Short noun phrase: what this speaker *is* (for self-knowledge in the prompt).
/// Location is layered on in `systemPrompt` (not hard-coded to Baron).
pub fn roleNoun(arch: Archetype, gender: Gender) []const u8 {
    return switch (arch) {
        .dark_knight => "a Dark Knight — an armored warrior sworn to a crown",
        .soldier => "a soldier on duty (military — not a shopkeeper, not an innkeep)",
        .guard => "a castle guard on duty (military — not a shopkeeper)",
        .townsman => "an ordinary townsman (civilian man who lives here)",
        .townswoman => "an ordinary townswoman (civilian woman who lives here)",
        .elder => if (gender == .female) "an elderly woman of this place" else "an elderly man of this place",
        .child => if (gender == .female) "a young girl who lives here" else "a young boy who lives here",
        .merchant => "a merchant or shopkeeper of this place",
        .scholar => "a scholar, priest, or mage of learning",
        .sailor => "a sailor or road-worn traveler",
        .monk => "a monk or martial devotee",
        .noble => "a noble or court attendant",
        .mysterious => "a strange but living person (never an object or bit of scenery)",
        .generic => "an ordinary living person of this place",
    };
}

fn baseForArchetype(arch: Archetype) VoiceProfile {
    // Persona + default speed; speaker assigned by pickKokoroSpeaker.
    return switch (arch) {
        .dark_knight => .{
            .speed = 0.95,
            .persona = "a grim Dark Knight of Baron; clipped, formal, duty-bound",
            .archetype = arch,
        },
        .soldier => .{
            .speed = 1.02,
            .persona = "a Baron foot soldier; plain-spoken, loyal, a bit rough",
            .archetype = arch,
        },
        .guard => .{
            .speed = 1.0,
            .persona = "a castle or town guard; terse, watchful, follows orders",
            .archetype = arch,
        },
        .townsman => .{
            .speed = 1.0,
            .persona = "a male townsfolk of the kingdom; warm, ordinary, medieval fantasy",
            .archetype = arch,
        },
        .townswoman => .{
            .speed = 0.98,
            .persona = "a woman of the town; kind, practical, medieval fantasy",
            .archetype = arch,
        },
        .elder => .{
            .speed = 0.90,
            .persona = "an elderly villager; slow, wise, reminiscing",
            .archetype = arch,
        },
        .child => .{
            .speed = 1.10,
            .persona = "a child of the town; curious, short sentences, innocent",
            .archetype = arch,
        },
        .merchant => .{
            .speed = 1.05,
            .persona = "a merchant or innkeep; cheerful, salesy but honest",
            .archetype = arch,
        },
        .scholar => .{
            .speed = 0.94,
            .persona = "a scholar or priest; measured, thoughtful, archaic courtesy",
            .archetype = arch,
        },
        .sailor => .{
            .speed = 1.04,
            .persona = "a sailor or traveler; salty, informal, adventurous",
            .archetype = arch,
        },
        .monk => .{
            .speed = 0.92,
            .persona = "a monk or martial devotee; calm, spiritual, few words",
            .archetype = arch,
        },
        .noble => .{
            .speed = 0.96,
            .persona = "a noble or court figure; refined, slightly haughty",
            .archetype = arch,
        },
        .mysterious => .{
            .speed = 0.90,
            .persona = "a mysterious figure; soft, enigmatic, few words",
            .archetype = arch,
        },
        .generic => .{
            .speed = 1.0,
            .persona = "a person of the kingdom of Baron; medieval fantasy, plain speech",
            .archetype = arch,
        },
    };
}

// Kokoro-en-v0_19 speaker pools (integer sids).
const male_us = [_]u32{ 5, 6 }; // am_adam, am_michael
const male_gb = [_]u32{ 9, 10 }; // bm_george, bm_lewis
const female_us = [_]u32{ 1, 2, 3, 4 }; // bella, nicole, sarah, sky (skip generic 0)
const female_gb = [_]u32{ 7, 8 }; // emma, isabella

/// Pick a stable Kokoro speaker id for this NPC.
fn pickKokoroSpeaker(arch: Archetype, gender: Gender, h: u32) u32 {
    const female = (gender == .female or arch == .townswoman);

    if (female) {
        return switch (arch) {
            .elder, .noble, .scholar => pickFrom(&female_gb, h),
            .child => 4, // af_sky — youngest-sounding female
            else => pickFrom(&female_us, h),
        };
    }

    // Male default (including .unknown).
    return switch (arch) {
        .dark_knight => 6, // am_michael — deeper
        .soldier, .guard => pickFrom(&male_us, h),
        .elder, .scholar, .noble, .monk => pickFrom(&male_gb, h),
        .sailor => 10, // bm_lewis
        .child => 5, // am_adam — lighter male
        .merchant, .townsman, .generic, .mysterious => pickFrom(&male_us, h ^ (h >> 4)),
        .townswoman => pickFrom(&female_us, h), // unreachable via female branch, defensive
    };
}

fn pickFrom(pool: []const u32, h: u32) u32 {
    if (pool.len == 0) return 0;
    return pool[h % pool.len];
}

/// System prompt fragment for Gemma (full prompt assembled by local.zig).
fn genderPhrase(g: Gender) []const u8 {
    return switch (g) {
        .male, .unknown => "male",
        .female => "female",
    };
}

pub fn systemPrompt(
    profile: VoiceProfile,
    map_id: u16,
    canon_line: []const u8,
    lore_card: []const u8,
    buf: []u8,
) []const u8 {
    const g = genderPhrase(profile.gender);
    const role = roleNoun(profile.archetype, profile.gender);
    _ = map_id;
    // Keep this tight: small models drown in repeated rules and start looping greeters.
    if (canon_line.len > 0) {
        return std.fmt.bufPrint(buf,
            \\You are one NPC in Final Fantasy IV (US SNES). Speak only as yourself.
            \\
            \\IDENTITY
            \\- You are {s}. Manner: {s} ({s}-presenting).
            \\- Living person — never scenery (door, torch, chest, wall, sparkle).
            \\- No invented personal name. "Who are you?" → answer with your role.
            \\- Beliefs/attitude match your ROM line (anchor, not a script to recite every turn): "{s}"
            \\
            \\HOW TO TALK
            \\- 1–2 short spoken sentences. No stage directions. No wrapping quotes.
            \\- Answer the player's latest question or remark. Do not ignore it.
            \\- Do NOT repeat the same greeting, salute, or catchphrase every turn. Use fresh words.
            \\- Do NOT re-quote your ROM line unless the player asks you to say it / for a formal salute once.
            \\- Do NOT copy other NPCs' lines from the map dump word-for-word.
            \\
            \\WHAT YOU KNOW
            \\- Only your role + LOCAL KNOWLEDGE below. If you would not know, admit ignorance or stay vague in-character.
            \\- No plot spoilers from outside this place/phase. No modern slang. No "as an AI".
            \\- Place-names (Baron, Mist, Fabul, …) are places, never people.
            \\
            \\{s}
        , .{ role, profile.persona, g, canon_line, lore_card }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf,
        \\You are one NPC in Final Fantasy IV (US SNES). Speak only as yourself.
        \\
        \\IDENTITY
        \\- You are {s}. Manner: {s} ({s}-presenting).
        \\- Living person — never scenery (door, torch, chest, wall, sparkle).
        \\- No invented personal name. "Who are you?" → answer with your role.
        \\
        \\HOW TO TALK
        \\- 1–2 short spoken sentences. No stage directions. No wrapping quotes.
        \\- Answer the player's latest question or remark. Do not ignore it.
        \\- Do NOT repeat the same greeting or catchphrase every turn. Use fresh words.
        \\- Do NOT copy other NPCs' lines from the map dump word-for-word.
        \\
        \\WHAT YOU KNOW
        \\- Only your role + LOCAL KNOWLEDGE below. If you would not know, admit ignorance or stay vague in-character.
        \\- No plot spoilers from outside this place/phase. No modern slang. No "as an AI".
        \\- Place-names (Baron, Mist, Fabul, …) are places, never people.
        \\
        \\{s}
    , .{ role, profile.persona, g, lore_card }) catch buf[0..0];
}
