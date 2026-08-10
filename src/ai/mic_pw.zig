//! Session microphone via PipeWire CLI (`pw-record`), not SDL.
//!
//! SDL capture on Bluetooth headsets forces A2DP→HFP and often kills the game's
//! SDL playback. `pw-record` uses normal system routing (same as other apps).
const std = @import("std");
const Io = std.Io;

pub const Mic = struct {
    path: []const u8 = "/tmp/ff4_vad.raw",
    child: ?std.process.Child = null,
    file_off: u64 = 0,
    running: bool = false,

    pub fn deinit(self: *Mic, io: Io) void {
        self.stop(io);
    }

    pub fn stop(self: *Mic, io: Io) void {
        if (self.child) |*ch| {
            // Child.kill() already waits until the process is reaped and clears id.
            // Calling wait() after that hits assert(child.id != null).
            if (ch.id != null) {
                ch.kill(io);
            }
            self.child = null;
        }
        self.running = false;
        self.file_off = 0;
    }

    pub fn start(self: *Mic, io: Io) !void {
        self.stop(io);

        const fd = try std.posix.openat(
            std.posix.AT.FDCWD,
            self.path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        );
        _ = std.c.close(fd);
        self.file_off = 0;

        var argv = [_][]const u8{
            "pw-record",
            "--rate",     "16000",
            "--channels", "1",
            "--format",   "s16",
            "--raw",
            "--latency",  "20ms",
            self.path,
        };
        self.child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        self.running = true;
    }

    /// Cheap: advance `file_off` to EOF without reading/converting samples.
    /// Use when not listening so the raw file doesn't force huge backlog reads.
    pub fn discard(self: *Mic) void {
        if (!self.running) return;
        const fd = std.posix.openat(std.posix.AT.FDCWD, self.path, .{ .ACCMODE = .RDONLY }, 0) catch return;
        defer _ = std.c.close(fd);
        const end = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end < 0) return;
        self.file_off = @intCast(end);
    }

    /// Append newly written s16le mono samples. Returns new sample count.
    /// Cap is small (~40ms @ 16 kHz) so one poll never stalls the game loop.
    pub fn poll(self: *Mic, allocator: std.mem.Allocator, out: *std.ArrayList(i16)) !usize {
        if (!self.running) return 0;

        const fd = std.posix.openat(std.posix.AT.FDCWD, self.path, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
        defer _ = std.c.close(fd);

        // Size via lseek end
        const end = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end < 0) return 0;
        const size: u64 = @intCast(end);
        if (size <= self.file_off) return 0;

        // If we fell far behind (e.g. after a long voice turn), skip to near-live
        // instead of chewing through seconds of stale PCM.
        const lag = size - self.file_off;
        const max_lag: u64 = 32 * 1024; // ~1s @ 16k mono s16
        if (lag > max_lag) {
            self.file_off = size - max_lag;
            self.file_off &= ~@as(u64, 1);
        }

        const off_set = std.c.lseek(fd, @intCast(self.file_off), std.c.SEEK.SET);
        if (off_set < 0) return 0;

        var avail: usize = @intCast(size - self.file_off);
        avail &= ~@as(usize, 1);
        if (avail == 0) return 0;

        // ~40ms @ 16 kHz mono s16 = 1280 samples = 2560 bytes
        const max_bytes: usize = 4 * 1024;
        if (avail > max_bytes) avail = max_bytes;
        avail &= ~@as(usize, 1);

        const bytes = try allocator.alloc(u8, avail);
        defer allocator.free(bytes);
        var got: usize = 0;
        while (got < avail) {
            const n = std.posix.read(fd, bytes[got..]) catch break;
            if (n == 0) break;
            got += n;
        }
        got &= ~@as(usize, 1);
        self.file_off += got;

        const n_samp = got / 2;
        try out.ensureUnusedCapacity(allocator, n_samp);
        var i: usize = 0;
        while (i < n_samp) : (i += 1) {
            const s = std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little);
            out.appendAssumeCapacity(s);
        }
        return n_samp;
    }
};
