# ff4

A native reimplementation of **Final Fantasy II** (US SNES) / **Final Fantasy IV**, ported from the community decompilation and documentation—not reverse-engineered from scratch in this tree.

It is a decomp-faithful field and battle host **with AI-driven NPCs**: walk up to someone in Baron, speak, and get an in-character reply grounded in the ROM’s dialogue and story—not a generic chatbot skin on a JRPG.

## Sources

| Resource | Use |
|----------|-----|
| [everything8215/ff4](https://github.com/everything8215/ff4) | Primary SNES decompilation (field, battle, events, data layout) |
| Community FF2US / FF4 reverse-engineering notes | Offsets, text encoding, map and battle tables |

Behavior and data layout track that decomp wherever practical. Divergences are host concerns (SDL, audio I/O, local AI), not invented game rules.

## Supported ROMs

| Version | CRC32 (headerless) |
|---------|--------------------|
| Final Fantasy II 1.0 (U) | `0x65D0A825` |
| Final Fantasy II 1.1 (U) | `0x23084FCD` |
| Final Fantasy IV 1.0 (J) | `0x21027C5D` (identify only) |
| Final Fantasy IV 1.1 (J) | `0xCAA15E97` (identify only) |

English gameplay and extractors target **US Final Fantasy II**. Japanese ROMs may identify but are not fully supported.

**You must supply your own legally obtained ROM.** No ROM or ripped game data is distributed with this project.

## AI NPCs

Talkable, local AI NPCs inside a decomp-faithful FF2 are a first-class part of this project—not a side demo.

NPCs are meant to:

- Stay in role and location (e.g. Castle Baron soldiers vs town greeters)
- Use the game’s own dialogue and story context where we can supply it
- Support spoken conversation (mic in, speech out) on the player’s machine

## Build and run

Requires **Zig 0.16+**, **SDL3**, and a US FF2 ROM.

```bash
zig build
zig build run -- play "Final Fantasy II.smc"
```

## Legal

Original game © Square / Square Enix. Engine source is intended for personal use with a ROM you own. Do not redistribute ROMs or extracted assets.
