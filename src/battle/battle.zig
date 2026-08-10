//! Public facade — prefer `host.Host` for ROM battle loop.
//! Kept so older imports still resolve; new code uses host/gfx/prop.
const host = @import("host.zig");

pub const Host = host.Host;
pub const Phase = host.Phase;
pub const CmdId = host.CmdId;
pub const EndFlags = host.EndFlags;
