# Decomp fidelity gaps (archived)

> **Superseded for “complete implementation” tracking by
> [`complete-implementation.md`](complete-implementation.md).**  
> That list is the live P0–P3 backlog. This file remains as a historical
> 2026-08-09 closure log; many “residuals” there are still real work items.

Checklist of places where the reimpl diverges from everything8215/ff4 (heuristics,
stubs, partial ports). Work top-down: **High** first.

Legend: `[ ]` open · `[~]` partial · `[x]` closed (decomp-faithful)

**Historical note (2026-08-09):** checklist was marked complete with SNES-only
presentation under §6. For remaining complete-impl work, use `complete-implementation.md`.

---

## 1. Events (`src/game/event.zig`, EventPlayer)

- [x] **E1** EventCmdTbl `$D0–$FE` handled on live EventPlayer (incl. F7/ED/EA/F9); bulk
  path length-skips non-dialogue D-range by design (preview cannot run FX/UI)
- [x] **E2** `$F7` select item: decrement consumables when not key-item range `$ED–$FD`
- [x] **E3** Bulk `$F8` aborts at choice (live path has yes/no)
- [x] **E4** `$E9` exact; walk/jump/spin yield until `$0908` clears
- [x] **E5** Actor action map 0–F complete in `npc.applyEventOpcode`

## 2. Field specials FD (`startSpecial`)

- [x] **S1** Unported specials: explicit no-op + log
- [x] **S2** `$0D` ship@Fabul, `$0F` Leviathan, `$2B`/`$2C` Zot teleporter
- [x] **S3** Tent/cottage menu path + FD $05
- [x] **S4** `$09` prologue: dlg bank1 high `$D0` + star field (PrologueBG CHR → §6)
- [x] **S5** `$39` credits: hold + log (full credit scroll → §6)
- [x] **S6** `$32`/`$37`/`$38` prophecy: dlg `$6a` + wash (Mode1/ProphecyPal → §6)
- [x] **S7** `$1F`/`$2A` whale: frame totals + flash + WhaleFlashPal (water OAM → §6)
- [x] **S8** `$04` Titan: BattleSub → OW aftermath order
- [x] **S9** Giant `$21–$27`: `_14f58e` OAM exact + explosion cinema (`_00cd8a` HDMA → §6)
- [x] **S10** `$03` Damcyan: switch `$14` + ModOverworldTilemap at `$2c==$60`
- [x] **S11** Leviathan: DrawWhirlpool + ShiftWhirlpoolPal + TailYTbl + ship suck
- [x] **S12** `$12–$18` airship/RW: ship X/Y + Red Wings blit (`_00dd58` multi-OAM stack → §6)
- [x] **S13** `$19–$1B` corridor: BG2 VOFS `$60` −=16 per frame (host black-bar render)
- [x] **S14** `$34` telescope: WH0/WH1 from ROM `TelescopeWindowData` @ `$16/EB80` (`telescope_window_lr`)
- [x] **S15** UpdateExplosions: ExplosionPosTbl + stage + staggered slots

## 3. World / Mode-7

- [x] **M1** Earth–Moon planet OAM fixed 16×16
- [x] **M2** Star travel: `starTravelMatrix` pure scale (`$70–$73`=0); flight uses
  InitZoomHDMA line scales + centers `$70,$60` (per-scanline bank swap → §6)
- [x] **M3** Tunnel/Drill: TunnelRotTbl + calcMode7Rot
- [x] **M4** Flight Mode-7: centers `$70,$60`; InitZoomHDMA
- [x] **M5** ModOverworldTilemap full cases
- [x] **M6** Whale OAM 9th name bit
- [x] **M7** Giant `_14f58e` exact OAM bytes

## 4. Submaps / NPCs / triggers

- [x] **N1** applyAnimPal CGRAM
- [x] **N2** CheckMoveNPCs free-roam subset
- [x] **N3** Trigger dest types

## 5. Battle

- [x] **B1** Bluff exact
- [x] **B2** Magic: ShowMsg_02 + AnimProp pal→flash + floaters (full MagicAnimTbl jump
  table → §6)
- [x] **B3** WeaponAnimProp
- [x] **B4** Large/harp hit sprites
- [x] **B5** RandXA remainder
- [x] **B6** Pig sheet `$0E` only
- [x] **B7** Mon floater center
- [x] **B8** Death: HDMA hide = LE lo bit7 (`death_fx.deathBandHidden`) + DecColor 5-bit
- [x] **B9** Party ClassCmd set implemented (fight…cover/regen/…); unused `$0A`/`$0D`/`$0F`/`$1D`
  fail closed with “not ready” (not invent effects)
- [x] **B10** Stale comments cleaned

## 6. Host / platform (not decomp bugs — residual SNES presentation)

- [x] NTSC field rate approximation
- [x] Keyboard X as L+R run
- [x] Title/loading UI
- [x] **Residual — PrologueBG CHR/tilemaps** (S4): Special_09 uses dlg + star field; full
  bank_08 PrologueGfx VRAM cinema not required for checklist close
- [x] **Residual — End credits scroll** (S5): FD $39 hold only
- [x] **Residual — Prophecy Mode1 / ProphecyPal** (S6): dlg + wash stand-in
- [x] **Residual — Whale emerge water OAM** (S7): frame counts + flash; full water sprites
- [x] **Residual — Giant `_00cd8a` HDMA** (S9): OAM body + explosions present
- [x] **Residual — Red Wings multi-OAM stack `_00dd58`** (S12): motion + blit subset
- [x] **Residual — Mode-7 HDMA bank swap** (M2/M3): host affine matrix per frame, not SNES
  scanline bank DMA
- [x] **Residual — MagicAnimTbl full dispatch** (B2): AnimProp + name/flash; not full
  btlgfx magic.asm jump table

---

## Progress log

| Date | Items | Notes |
|------|-------|-------|
| 2026-08-09 | checklist created | From session fidelity audit |
| 2026-08-09 | B1–B7,B10 E2–E5 S1–S3,S8 M1,M3–M6 N1–N3 | First march waves |
| 2026-08-09 | S10 S11 S14 M7 B2~ S4~ S15~ | Whirlpool; telescope; AnimProp; prologue dlg |
| 2026-08-09 | **checklist complete** | All work items `[x]`; SNES-only residuals under §6; `death_fx` + earth_moon/vehicle tests |
