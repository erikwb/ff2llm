//! Character/monster status bytes — battle WRAM $2003–$2006 (init.asm / fight.asm / magic.asm).
//!
//! Bit layouts from decomp (DisableCmdStatusTbl, DoFightCmd, SetMagicStatus):
//!
//! $2003 status1:
//!   bit0 poison  bit1 blind  bit2 mute  bit3 pig
//!   bit4 mini    bit5 toad   bit6 stone bit7 dead
//!
//! $2004 status2:
//!   bit2 berserk  bit3 charm  (sleep/paralyze also live here; see magic.asm)
//!
//! $2005:
//!   bit4 defend ($2705 bit4 in fight.asm)
//!
//! $2006:
//!   bits2–3 image charges  bit4 barrier
const std = @import("std");

pub const Status1 = struct {
    pub const poison: u8 = 0x01;
    pub const blind: u8 = 0x02;
    pub const mute: u8 = 0x04;
    pub const pig: u8 = 0x08;
    pub const mini: u8 = 0x10;
    pub const toad: u8 = 0x20;
    pub const stone: u8 = 0x40;
    pub const dead: u8 = 0x80;
    /// KO for targeting / end checks.
    pub const ko: u8 = stone | dead;
    /// Toad or mini — zero defense mult / disable weapons (fight.asm @c5e4).
    pub const toad_mini: u8 = toad | mini;
    /// Field/battle form bits that change character graphics.
    pub const form_bits: u8 = toad | mini | pig;
};

/// Battle InitCharGfx (sprite.asm @e08a): pig ($2003 bit3) → BattleCharGfx $0E;
/// else class id `$2001 & $1f`. Toad/mini keep the class sheet; UpdateCharSpritesheet
/// selects tile banks via MSB offsets ($20 toad / $10 mini / $40 pig) on that sheet.
pub fn battleCharGfxId(class_id: u8, status1: u8) u8 {
    if ((status1 & Status1.pig) != 0) return 0x0E;
    return class_id & 0x1F;
}

pub const Status2 = struct {
    /// Gradual petrify stages live in low bits (timer effect 4).
    pub const petrify_stage: u8 = 0x03;
    pub const berserk: u8 = 0x04;
    pub const charm: u8 = 0x08;
    /// Sleep / paralyze (timer.asm TimerEffect_01 clears with AND #$CF).
    pub const sleep: u8 = 0x10;
    pub const paralyze: u8 = 0x20;
    /// Float (DisableCmdStatusTbl kick uses bit6; magic.asm AND #$BF).
    pub const float_bit: u8 = 0x40;
    pub const control: u8 = sleep | paralyze | berserk | charm;
};

pub const Status3 = struct {
    /// Jump in air (cmd.asm Cmd_06 ORA #$02).
    pub const jumping: u8 = 0x02;
    /// Twin charging (Cmd_10 ORA #$04 on $2005).
    pub const twin: u8 = 0x04;
    /// Focus charging (Cmd_0d ORA #$08 on $2005).
    pub const focus: u8 = 0x08;
    pub const defend: u8 = 0x10;
    /// Stop (timer.asm clear AND #$BF).
    pub const stop: u8 = 0x40;
};

pub const Status4 = struct {
    pub const image_mask: u8 = 0x0C;
    /// Cover target (Cmd_13 ORA #$02).
    pub const covered: u8 = 0x02;
    /// Reflect / wall (TimerEffect_05 clear AND #$DF → bit5).
    pub const reflect: u8 = 0x20;
    pub const barrier: u8 = 0x10;
    /// Sap (timer.asm clear AND #$BF).
    pub const sap: u8 = 0x40;
    pub const hide: u8 = 0x80;
};

pub const Status = struct {
    s1: u8 = 0,
    s2: u8 = 0,
    s3: u8 = 0,
    s4: u8 = 0,

    pub fn isDead(self: Status) bool {
        return (self.s1 & Status1.dead) != 0;
    }
    pub fn isStone(self: Status) bool {
        return (self.s1 & Status1.stone) != 0;
    }
    pub fn isKo(self: Status) bool {
        return (self.s1 & Status1.ko) != 0;
    }
    pub fn isBlind(self: Status) bool {
        return (self.s1 & Status1.blind) != 0;
    }
    pub fn isPoison(self: Status) bool {
        return (self.s1 & Status1.poison) != 0;
    }
    pub fn isToadMini(self: Status) bool {
        return (self.s1 & Status1.toad_mini) != 0;
    }
    pub fn isBerserk(self: Status) bool {
        return (self.s2 & Status2.berserk) != 0;
    }
    pub fn setBerserk(self: *Status, on: bool) void {
        if (on) self.s2 |= Status2.berserk else self.s2 &= ~Status2.berserk;
    }
    pub fn isCharm(self: Status) bool {
        return (self.s2 & Status2.charm) != 0;
    }
    pub fn isFloat(self: Status) bool {
        return (self.s2 & Status2.float_bit) != 0;
    }
    pub fn setFloat(self: *Status, on: bool) void {
        if (on) self.s2 |= Status2.float_bit else self.s2 &= ~Status2.float_bit;
    }
    pub fn isSleep(self: Status) bool {
        return (self.s2 & Status2.sleep) != 0;
    }
    pub fn isParalyze(self: Status) bool {
        return (self.s2 & Status2.paralyze) != 0;
    }
    pub fn isDefending(self: Status) bool {
        return (self.s3 & Status3.defend) != 0;
    }
    pub fn isStopped(self: Status) bool {
        return (self.s3 & Status3.stop) != 0;
    }
    pub fn isJumping(self: Status) bool {
        return (self.s3 & Status3.jumping) != 0;
    }
    pub fn isFocusing(self: Status) bool {
        return (self.s3 & Status3.focus) != 0;
    }
    pub fn isTwinCharging(self: Status) bool {
        return (self.s3 & Status3.twin) != 0;
    }
    pub fn setTwin(self: *Status, on: bool) void {
        if (on) self.s3 |= Status3.twin else self.s3 &= ~Status3.twin;
    }
    pub fn setFocusing(self: *Status, on: bool) void {
        if (on) self.s3 |= Status3.focus else self.s3 &= ~Status3.focus;
    }
    pub fn isSapped(self: Status) bool {
        return (self.s4 & Status4.sap) != 0;
    }
    pub fn isCovered(self: Status) bool {
        return (self.s4 & Status4.covered) != 0;
    }
    pub fn hasBarrier(self: Status) bool {
        return (self.s4 & Status4.barrier) != 0;
    }
    pub fn hasReflect(self: Status) bool {
        return (self.s4 & Status4.reflect) != 0;
    }
    pub fn setReflect(self: *Status, on: bool) void {
        if (on) self.s4 |= Status4.reflect else self.s4 &= ~Status4.reflect;
    }
    pub fn isHidden(self: Status) bool {
        return (self.s4 & Status4.hide) != 0;
    }
    pub fn setHide(self: *Status, on: bool) void {
        if (on) self.s4 |= Status4.hide else self.s4 &= ~Status4.hide;
    }
    /// Gradual petrify stage 0..3 in s2 low bits; 4 → stone.
    pub fn petrifyStage(self: Status) u8 {
        return self.s2 & Status2.petrify_stage;
    }
    pub fn advancePetrify(self: *Status) bool {
        const st = self.petrifyStage() + 1;
        if (st >= 4) {
            self.s2 &= ~Status2.petrify_stage;
            self.s1 |= Status1.stone;
            return true; // fully stoned
        }
        self.s2 = (self.s2 & ~Status2.petrify_stage) | st;
        return false;
    }
    pub fn imageCharges(self: Status) u8 {
        return (self.s4 & Status4.image_mask) >> 2;
    }

    /// Can act this turn? (not KO / sleep / paralyze / stop / mid-jump).
    pub fn canAct(self: Status) bool {
        if (self.isKo()) return false;
        if (self.isSleep() or self.isParalyze()) return false;
        if (self.isStopped()) return false;
        if (self.isJumping()) return false; // mid-air; land via jump2
        return true;
    }

    /// Valid physical/magic target (not already dead/stone; hide skips physical).
    pub fn canTarget(self: Status) bool {
        return !self.isKo() and !self.isHidden();
    }

    pub fn setDead(self: *Status) void {
        self.s1 |= Status1.dead;
    }
    pub fn setDefend(self: *Status, on: bool) void {
        if (on) self.s3 |= Status3.defend else self.s3 &= ~Status3.defend;
    }
    pub fn setJumping(self: *Status, on: bool) void {
        if (on) self.s3 |= Status3.jumping else self.s3 &= ~Status3.jumping;
    }
    // setFocusing defined above with setTwin
    pub fn setStop(self: *Status, on: bool) void {
        if (on) self.s3 |= Status3.stop else self.s3 &= ~Status3.stop;
    }
    pub fn setSap(self: *Status, on: bool) void {
        if (on) self.s4 |= Status4.sap else self.s4 &= ~Status4.sap;
    }
    pub fn setCovered(self: *Status, on: bool) void {
        if (on) self.s4 |= Status4.covered else self.s4 &= ~Status4.covered;
    }
    pub fn clearCharm(self: *Status) void {
        self.s2 &= ~Status2.charm; // fight.asm @c623
    }
    pub fn clearSleepParalyze(self: *Status) void {
        self.s2 &= ~Status2.sleep;
        self.s2 &= ~Status2.paralyze;
    }

    /// Remove one image charge (fight.asm @c59f).
    pub fn consumeImage(self: *Status) void {
        const n = self.imageCharges();
        if (n == 0) return;
        self.s4 = (self.s4 & ~Status4.image_mask) | (@as(u8, n - 1) << 2);
    }

    /// SetMagicStatus2 priority subset — OR bits if not immune.
    pub fn applyStatus1(self: *Status, bits: u8, immune1: u8) bool {
        const add = bits & ~immune1;
        if (add == 0) return false;
        if ((self.s1 & add) == add) return false; // already has
        self.s1 |= add;
        return true;
    }
    pub fn applyStatus2(self: *Status, bits: u8, immune2: u8) bool {
        const add = bits & ~immune2;
        if (add == 0) return false;
        if ((self.s2 & add) == add) return false;
        self.s2 |= add;
        return true;
    }

    /// Clear bits (Esuna / Life / etc.).
    pub fn clearStatus1(self: *Status, bits: u8) void {
        self.s1 &= ~bits;
    }
    pub fn clearStatus2(self: *Status, bits: u8) void {
        self.s2 &= ~bits;
    }
};

const rom_mod = @import("../rom.zig");

/// ElementStatus @ 0F/A590 (file 0x7A590) — 3 bytes: elem, status1, status2.
/// EquipProp/AttackProp store an index; equip.asm Mult8×3 expands it.
pub const element_status_file: usize = 0x7A590;

pub fn expandElementStatus(r: *const rom_mod.Rom, index: u8) struct { s1: u8, s2: u8, elem: u8 } {
    if (index >= 64) return .{ .s1 = 0, .s2 = 0, .elem = 0 };
    const raw = r.slice(element_status_file + @as(usize, index) * 3, 3) catch return .{ .s1 = 0, .s2 = 0, .elem = 0 };
    return .{ .elem = raw[0], .s1 = raw[1], .s2 = raw[2] };
}
