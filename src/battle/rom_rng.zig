//! Battle RNG — InitBattle copies RNGTbl → $1900; RandXA / Rand99 (battle.asm).
//!
//! RNGTbl @ 14/EE00 (file 0xA6E00), 256 unique bytes.
//! Index $97 advances each draw (wraps u8).
const rom_mod = @import("../rom.zig");
const damage = @import("damage.zig");

pub const rng_tbl_file: usize = 0xA6E00;

pub const RomRng = struct {
    table: [256]u8 = undefined,
    /// WRAM $97 — table index.
    idx: u8 = 0,
    loaded: bool = false,

    /// Copy RNGTbl from ROM; seed index (InitBattle sums WRAM — we take seed arg).
    pub fn init(r: *const rom_mod.Rom, seed: u8) RomRng {
        var s: RomRng = .{ .idx = seed, .loaded = true };
        if (r.slice(rng_tbl_file, 256)) |raw| {
            @memcpy(&s.table, raw);
        } else |_| {
            // Fallback identity if ROM missing
            for (&s.table, 0..) |*b, i| b.* = @truncate(i);
        }
        return s;
    }

    /// Next table byte and advance index (single Rand step).
    pub fn nextByte(self: *RomRng) u8 {
        if (!self.loaded) {
            self.idx +%= 1;
            return self.idx;
        }
        const v = self.table[self.idx];
        self.idx +%= 1;
        return v;
    }

    /// RandXA (battle.asm @8379): A=hi, X=lo → value in A.
    /// `result = lo + (RNGTbl[idx] % (hi-lo+1))`, then idx++.
    /// Specials: X=$FF → return hi; hi==0 or hi==lo → return hi; hi-lo=$FF → raw table byte.
    pub fn randXA(self: *RomRng, lo: u8, hi: u8) u8 {
        // X=$ff: branch preserves A (hi)
        if (lo == 0xFF) return hi;
        if (hi == 0 or hi == lo) return hi;
        const diff: u8 = hi -% lo;
        // span would be 256 → pure table byte
        if (diff == 0xFF) return self.nextByte();
        const span: u16 = @as(u16, diff) +% 1;
        // Div16 remainder of rng / span  (decomp uses $394b after Div16)
        const t: u16 = self.nextByte();
        return lo +% @as(u8, @intCast(t % span));
    }

    /// Rand99: 0..=99.
    pub fn rand99(self: *RomRng) u8 {
        return self.randXA(0, 99);
    }

    pub fn asRng(self: *RomRng) damage.Rng {
        return .{
            .next_fn = romNext,
            .ctx = self,
        };
    }

    fn romNext(ctx: *anyopaque) u8 {
        const self: *RomRng = @ptrCast(@alignCast(ctx));
        return self.nextByte();
    }
};
