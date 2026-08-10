//! SDL3 gamepad helper — D-pad + left stick, face buttons, hotplug.
const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// Analog stick deadzone (SDL axis is -32768..32767).
const stick_deadzone: i16 = 12000;

pub const Pad = struct {
    gp: ?*c.SDL_Gamepad = null,
    id: c.SDL_JoystickID = 0,

    pub fn deinit(self: *Pad) void {
        self.close();
    }

    pub fn close(self: *Pad) void {
        if (self.gp) |g| {
            c.SDL_CloseGamepad(g);
            self.gp = null;
            self.id = 0;
        }
    }

    /// Open the first available gamepad (if any).
    pub fn openFirst(self: *Pad) void {
        self.close();
        var count: c_int = 0;
        const ids = c.SDL_GetGamepads(&count);
        if (ids == null or count <= 0) return;
        defer c.SDL_free(ids);

        const first = ids[0];
        self.gp = c.SDL_OpenGamepad(first);
        if (self.gp == null) {
            std.log.warn("gamepad: open failed: {s}", .{c.SDL_GetError()});
            return;
        }
        self.id = first;
        if (c.SDL_GetGamepadName(self.gp)) |name| {
            std.log.info("gamepad: opened {s}", .{name});
        } else {
            std.log.info("gamepad: opened id={d}", .{first});
        }
    }

    /// Handle add/remove from the SDL queue (pass type + joystick id only —
    /// avoids cImport type mismatch with the caller's SDL_Event).
    pub fn handleDevice(self: *Pad, ev_type: u32, which: c.SDL_JoystickID) void {
        if (ev_type == c.SDL_EVENT_GAMEPAD_ADDED) {
            if (self.gp == null) {
                self.gp = c.SDL_OpenGamepad(which);
                if (self.gp != null) {
                    self.id = which;
                    if (c.SDL_GetGamepadName(self.gp)) |name| {
                        std.log.info("gamepad: connected {s}", .{name});
                    }
                }
            }
        } else if (ev_type == c.SDL_EVENT_GAMEPAD_REMOVED) {
            if (self.gp != null and which == self.id) {
                std.log.info("gamepad: disconnected", .{});
                self.close();
                self.openFirst();
            }
        }
    }

    fn btn(self: *const Pad, b: c.SDL_GamepadButton) bool {
        const g = self.gp orelse return false;
        return c.SDL_GetGamepadButton(g, b);
    }

    fn axisPast(self: *const Pad, axis: c.SDL_GamepadAxis, positive: bool) bool {
        const g = self.gp orelse return false;
        const v = c.SDL_GetGamepadAxis(g, axis);
        if (positive) return v > stick_deadzone;
        return v < -stick_deadzone;
    }

    pub fn up(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_DPAD_UP) or self.axisPast(c.SDL_GAMEPAD_AXIS_LEFTY, false);
    }
    pub fn down(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_DPAD_DOWN) or self.axisPast(c.SDL_GAMEPAD_AXIS_LEFTY, true);
    }
    pub fn left(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_DPAD_LEFT) or self.axisPast(c.SDL_GAMEPAD_AXIS_LEFTX, false);
    }
    pub fn right(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT) or self.axisPast(c.SDL_GAMEPAD_AXIS_LEFTX, true);
    }

    /// Confirm / talk / advance (A / Cross / bottom face).
    pub fn confirm(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_SOUTH);
    }
    /// Cancel / menu back (B / Circle / right face) or Start.
    pub fn cancel(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_EAST) or self.btn(c.SDL_GAMEPAD_BUTTON_START);
    }
    /// Debug key grant (Select/Back + Y/North) — same role as keyboard K.
    pub fn debugKey(self: *const Pad) bool {
        return self.btn(c.SDL_GAMEPAD_BUTTON_BACK) and self.btn(c.SDL_GAMEPAD_BUTTON_NORTH);
    }
};
