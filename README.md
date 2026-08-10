# ff4 — native FF2/FF4 scaffold (Zig)

A portable **Zig** reimplementation scaffold for *Final Fantasy II* (US SNES) /
*Final Fantasy IV*. It loads your legally obtained ROM, verifies it, extracts
game tables, and includes a first port of the core **physical damage** math.

This is **not** a complete game yet. It is the foundation for a data-driven
native engine (Linux x86_64/ARM and other Zig targets).

## Requirements

- **Zig 0.16+**
- **SDL3** (`sudo pacman -S sdl3` on Arch/CachyOS)
- Your own **Final Fantasy II (US)** SNES ROM (`.smc` or `.sfc`)

## Quick start

```bash
# from the repo root
zig build

# PLAY (overworld, towns/castles, NPCs, battles)
zig build run -- play "Final Fantasy II.smc"
# Controls: arrows/WASD move · Z/Enter talk/confirm · Esc back/quit
# Walk into door tiles on the overworld to enter maps; doors/stairs inside work too.

# verify your ROM (headered or headerless 1 MiB)
zig build run -- verify "Final Fantasy II.smc"

# dump tables
zig build run -- dump "Final Fantasy II.smc" monsters 20
zig build run -- dump "Final Fantasy II.smc" characters
zig build run -- dump "Final Fantasy II.smc" items 30
zig build run -- dump "Final Fantasy II.smc" commands

# extract JSON for engine use (personal use only — do not redistribute)
zig build run -- rip "Final Fantasy II.smc" data/ripped

# experiment with damage math (ported from battle/damage.asm)
zig build run -- sim-damage --atk 100 --def 20 --hits 2 --seed 42

# unit tests (text codec, LoROM map, damage)
zig build test
```

Installed binary: `zig-out/bin/ff4`.

## Supported ROMs

| Version | CRC32 (headerless) |
|---------|--------------------|
| Final Fantasy II 1.0 (U) | `0x65D0A825` |
| Final Fantasy II 1.1 (U) | `0x23084FCD` |
| Final Fantasy IV 1.0 (J) | `0x21027C5D` (identify only) |
| Final Fantasy IV 1.1 (J) | `0xCAA15E97` (identify only) |

English extractors are verified against **1.1 (U)**. Japanese name tables differ.

## Layout

```
src/
  main.zig           CLI (verify, dump, rip, sim-damage)
  rom.zig            SMC strip, CRC32, LoROM, header
  text.zig           FF2US font / name encoding
  offsets.zig        English ROM table offsets
  data.zig           Structured extractors
  battle/
    damage.zig       CalcHits / CalcDmg port
```

Offsets and structure notes come from community reverse engineering,
especially [everything8215/ff4](https://github.com/everything8215/ff4).

## Legal

- **No ROM or ripped game data is shipped in this repository.**
- You must own a legal copy of the game to use the extractors.
- Do not redistribute extracted JSON, graphics, music, or text.
- Engine source is MIT (see `LICENSE`).

## Roadmap (short)

1. ~~ROM load / verify / dump / rip~~
2. ~~Damage formula scaffold~~
3. ~~Field maps / movement / NPCs / SDL3 / SPC~~
4. ~~Random battles from ROM encounter tables (area-correct formations)~~
5. Full attack power assembly (weapon, level, row, …)
6. Battle AT + turn order, magic, multi-party
7. Richer event scripts / treasures / shops
8. Voice NPC polish

## Battles (ROM reimplementation)

**Goal:** reimplement the SNES battle program’s behavior, not invent an “FF4-style” system.

Reference: [everything8215/ff4](https://github.com/everything8215/ff4) — `battle/battle.asm` (`ExecBattle` / `BattleMain` / `InitBattle`), `battle/init.asm`, `battle/fight.asm`, `field/rand_battle.asm`.

| Layer | Status |
|-------|--------|
| Field encounter roll (rates/groups/formation id) | Ported from `rand_battle.asm` |
| `BattleProp` types×counts + MonsterPos | Ported (`battle/prop.zig`) |
| Object slots, action timers, pending action | Subset of DecTimers / GetPendingAction |
| Fight (CalcHits/CalcDmg) + Run | Partial (`damage.asm`, `Cmd_00` / `Cmd_24`) |
| Magic, items, AI scripts, full status timers | Not yet |
| `ExecBtlGfx` (real sprites/BG/windows) | Placeholder present only |

Module map: `src/battle/README.md`.

## Credits

- Original game © Square / Square Enix
- Disassembly reference: [everything8215/ff4](https://github.com/everything8215/ff4)
  (especially `field/rand_battle.asm`, `field/event.asm`, `battle/*`)
