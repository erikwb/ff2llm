//! SNES LoROM loader and Final Fantasy II (US) / FF4 identification.
const std = @import("std");
const Io = std.Io;

pub const smc_header_size: usize = 512;
pub const expected_rom_size: usize = 1024 * 1024; // 1 MiB LoROM image

/// Known good CRC32 values for the headerless (no SMC) image.
pub const KnownVersion = enum {
    ff2_us_1_0,
    ff2_us_1_1,
    ff4_jp_1_0,
    ff4_jp_1_1,
    unknown,

    pub fn name(self: KnownVersion) []const u8 {
        return switch (self) {
            .ff2_us_1_0 => "Final Fantasy II 1.0 (U)",
            .ff2_us_1_1 => "Final Fantasy II 1.1 (U)",
            .ff4_jp_1_0 => "Final Fantasy IV 1.0 (J)",
            .ff4_jp_1_1 => "Final Fantasy IV 1.1 (J)",
            .unknown => "unknown",
        };
    }

    pub fn isEnglish(self: KnownVersion) bool {
        return self == .ff2_us_1_0 or self == .ff2_us_1_1;
    }
};

pub const known_crc32 = struct {
    pub const ff2_us_1_0: u32 = 0x65D0A825;
    pub const ff2_us_1_1: u32 = 0x23084FCD;
    pub const ff4_jp_1_0: u32 = 0x21027C5D;
    pub const ff4_jp_1_1: u32 = 0xCAA15E97;
};

pub fn versionFromCrc(crc: u32) KnownVersion {
    return switch (crc) {
        known_crc32.ff2_us_1_0 => .ff2_us_1_0,
        known_crc32.ff2_us_1_1 => .ff2_us_1_1,
        known_crc32.ff4_jp_1_0 => .ff4_jp_1_0,
        known_crc32.ff4_jp_1_1 => .ff4_jp_1_1,
        else => .unknown,
    };
}

pub const Header = struct {
    title: [21]u8,
    map_mode: u8,
    cart_type: u8,
    rom_size_code: u8,
    sram_size_code: u8,
    country: u8,
    license: u8,
    version: u8,
    checksum_complement: u16,
    checksum: u16,
    reset_vector: u16,
    nmi_vector: u16,

    pub fn titleSlice(self: *const Header) []const u8 {
        var end: usize = self.title.len;
        while (end > 0 and (self.title[end - 1] == ' ' or self.title[end - 1] == 0)) : (end -= 1) {}
        return self.title[0..end];
    }
};

pub const Rom = struct {
    /// Full file bytes (may include 512-byte SMC header). Owned.
    file_bytes: []u8,
    /// Slice into file_bytes pointing at the raw SNES image (no SMC header).
    data: []u8,
    has_smc_header: bool,
    crc32: u32,
    version: KnownVersion,
    header: Header,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Rom) void {
        self.allocator.free(self.file_bytes);
        self.* = undefined;
    }

    /// Read a byte range from the headerless ROM image.
    pub fn slice(self: *const Rom, offset: usize, len: usize) error{OutOfRange}![]const u8 {
        if (offset > self.data.len or len > self.data.len - offset) return error.OutOfRange;
        return self.data[offset .. offset + len];
    }

    pub fn readU8(self: *const Rom, offset: usize) error{OutOfRange}!u8 {
        if (offset >= self.data.len) return error.OutOfRange;
        return self.data[offset];
    }

    pub fn readU16Le(self: *const Rom, offset: usize) error{OutOfRange}!u16 {
        const s = try self.slice(offset, 2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    /// Convert a 24-bit SNES LoROM CPU address to a file offset in the headerless image.
    pub fn loromOffset(cpu_addr: u24) usize {
        const bank: u32 = cpu_addr >> 16;
        const addr: u32 = cpu_addr & 0xFFFF;
        return ((bank & 0x7F) << 15) | (addr & 0x7FFF);
    }

    pub fn readAtCpu(self: *const Rom, cpu_addr: u24, len: usize) error{OutOfRange}![]const u8 {
        return self.slice(loromOffset(cpu_addr), len);
    }
};

/// Load a ROM from disk. Accepts headered (.smc) or headerless (.sfc) images.
pub fn load(io: Io, gpa: std.mem.Allocator, path: []const u8) !Rom {
    const file_bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 * 1024 * 1024));
    errdefer gpa.free(file_bytes);

    if (file_bytes.len < expected_rom_size) return error.FileTooSmall;

    const has_smc = file_bytes.len == expected_rom_size + smc_header_size;
    const headerless_len = if (has_smc) file_bytes.len - smc_header_size else file_bytes.len;

    if (headerless_len != expected_rom_size) {
        // Still allow exact 1 MiB without header, or 1 MiB + 512.
        if (!(file_bytes.len == expected_rom_size or has_smc)) return error.UnexpectedSize;
    }

    const data: []u8 = if (has_smc)
        file_bytes[smc_header_size..]
    else
        file_bytes;

    if (data.len < expected_rom_size) return error.FileTooSmall;

    const crc = std.hash.Crc32.hash(data[0..expected_rom_size]);
    const header = try parseHeader(data[0..expected_rom_size]);

    return .{
        .file_bytes = file_bytes,
        .data = data[0..expected_rom_size],
        .has_smc_header = has_smc,
        .crc32 = crc,
        .version = versionFromCrc(crc),
        .header = header,
        .allocator = gpa,
    };
}

fn parseHeader(data: []const u8) error{BadHeader}!Header {
    // LoROM internal header at $00:FFC0 → file 0x7FC0
    const base: usize = 0x7FC0;
    if (data.len < base + 0x40) return error.BadHeader;

    var title: [21]u8 = undefined;
    @memcpy(title[0..], data[base .. base + 21]);

    return .{
        .title = title,
        .map_mode = data[base + 21],
        .cart_type = data[base + 22],
        .rom_size_code = data[base + 23],
        .sram_size_code = data[base + 24],
        .country = data[base + 25],
        .license = data[base + 26],
        .version = data[base + 27],
        .checksum_complement = std.mem.readInt(u16, data[base + 28 ..][0..2], .little),
        .checksum = std.mem.readInt(u16, data[base + 30 ..][0..2], .little),
        .nmi_vector = std.mem.readInt(u16, data[0x7FEA..][0..2], .little),
        .reset_vector = std.mem.readInt(u16, data[0x7FFC..][0..2], .little),
    };
}

test "lorom offset for known regions" {
    // $0E9800 monster names → file 0x71800
    try std.testing.expectEqual(@as(usize, 0x71800), Rom.loromOffset(0x0E9800));
    // $0F8000 item names → file 0x78000
    try std.testing.expectEqual(@as(usize, 0x78000), Rom.loromOffset(0x0F8000));
    // $0FA7C6 battle command names (EN) → file 0x7A7C6
    try std.testing.expectEqual(@as(usize, 0x7A7C6), Rom.loromOffset(0x0FA7C6));
}
