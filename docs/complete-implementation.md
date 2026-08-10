# Complete implementation checklist

Live backlog for a **decomp-faithful** FF4 US reimpl (Zig 0.16 + SDL3).
Source of truth for behavior: [everything8215/ff4](https://github.com/everything8215/ff4) + US ROM tables only — **no invented formulas**.

This file **replaces** the 2026-08-09 list of the same name. Status was re-audited against
`src/` after AutoBattle/SoloBattle, CheckBattleEnd pure path, gfx-script decode, retal
partial, chant poses, title/menu/window-color work.

| Mark | Meaning |
|------|---------|
| `[ ]` | Not done |
| `[~]` | Partial (core path exists; decomp gaps or presentation stubs remain) |
| `[x]` | Decomp-faithful enough to call complete for that item |

**Rule:** close items with decomp symbols + ROM offsets in code comments and a unit test
where pure logic exists. Host-only presentation may stay approximate only if tagged **P2 residual**.

---

## Priority tiers

| Tier | Meaning |
|------|---------|
| **P0** | Wrong gameplay, soft-locks, broken story fights / field flow |
| **P1** | Story feel: battle anims, dialogue in battle, vehicles, party on field |
| **P2** | Full ROM parity (every OAM stack, every menu edge, every special cinema) |
| **P3** | Host / platform only (not SNES) |

---

## Snapshot (what already works)

Do **not** re-open without a regression:

| Area | Status |
|------|--------|
| ROM LoROM load, BattleProp, most data tables | solid |
| Field EventPlayer `$D0–$FE` (live path) | solid; bulk preview length-skips FX by design |
| Forced battle `$EC`, solo party filter, NoUpdate/NoWinAnim/NoFanfare tables | solid |
| AutoBattleTbl scripts + free MP + speed `$01` | solid |
| SoloBattleTbl + RestorePartyAfterSoloBattle | solid |
| AI scripts: fight/magic/target, cond 0–11, ChangeBattleVar, mon stats | solid core |
| AI `$F1`/`$F2` → BattleDlg text queue | solid (not full gfx VM) |
| Fight/magic/item/run/steal/jump/cover ClassCmd set | solid (unused IDs fail closed) |
| ATB timers, status bits, reflect, image, level-up | solid core |
| CheckBattleEnd pure `$a8` (wipe / victory / run / auto / NoUpdate) | solid + tests; host does not false-flee on menu-zeroed `$38d6` |
| ExecGfxScript `Vm` + party magic `$33c2` script buffer | solid core (anim tables residual) |
| CharTileTbl + mini/toad poses + poseForStatus | solid for baked range |
| Battle BG + mon/char tiles, floaters, hand cursor, menu strip | solid subset |
| Window chrome + window color (pal 1/5/9/13 + font ink) | solid on field menus |
| Title splash + load + start locations (incl. Moon/whale) | solid |
| Vehicles board/land **state machine** + parked slots | solid |
| Specials: logic/timings largely present; many cinemas residual | see §3 |
| Audio: SPC songs + many system/field/battle SFX | solid core |
| SDL3 256×224, pad/keyboard | solid |

---

## 1. Battle — graphics script VM & presentation (P0–P1)

### 1.1 Graphics script interpreter (`btlgfx`)

Decomp: `btlgfx/btlgfx.asm` `ExecBtlGfx` / `DoGfxScriptCmd`, `cmd_anim.asm`, `magic.asm`, `weapon.asm`, `summon.asm`.

| ID | Item | Status | Notes / decomp |
|----|------|--------|----------------|
| **BG1** | Full `$33c2` script runner driven from attack path | `[x]` | `gfx_script.Vm` multi-frame; attack path + DoMagicAnim; AnimScript OAM frame residual P2 |
| **BG2** | Gfx cmds `$F0–$FE` effects applied live | `[x]` | Vm F0–F8 wired (boss/dlg/song/darken/ShowMsg); unused param/nop; mon tile swap residual P2 |
| **BG3** | `ShowMsg` `$F8` paths 00–04 exact | `[x]` | `show_msg.zig`: types 0–4, `$34c7` cmd/item/magic, mon AttackName ≥`$48`, dmg miss/MP flags, windowKind; host F8 wired |
| **BG4** | `MagicAnimTbl` / `DoMagicAnim` jump table | `[x]` | `magic_anim.resolve`: AnimProp (id−1), summon `$4D–$5D`, MagicAnimTbl `$00–$2F` flags+waits; host Vm; full OAM AnimScript residual |
| **BG5** | Weapon / fight anim (`cmd_anim` + `weapon.asm`) | `[x]` | `fight_anim.zig`: DoFightAnim shield `$60+`, WeaponHitAnim `$10` frames + sfx `$2a`, phase timings; host `tickPartyFight` |
| **BG6** | AnimScript frame tables (79) + item/magic props E2E | `[x]` | `anim_script.loadHeader` from AnimScriptPtrs @0x7D5E0; size/speed tables ROM-parity; host magic wait from real header; OAM frame residual |
| **BG7** | `PreMagicAnim` black/white/summon lead-ins | `[x]` | `fight_anim`: PreMagicSfxTbl `$fc–$fe`, white/summon stage×mask frame formula, pose/cmd map; host sfx+wait+col; OAM PreMagicAnim2 polar residual |

### 1.2 Character / monster presentation

Decomp: `btlgfx/sprite.asm`, `btlgfx_data.asm` `CharTileTbl`, `monster_death.asm`, boss frame AI `$F0`.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **BP1** | CharTileTbl poses (ready, walk, fight, hit, chant, cast, dead, run, win, …) | `[x]` | Full table `$00–$24` + CharPoseOffsetTbl + CharAnimPoseTbl banks; bake normal/mini/toad; golbez via BP2 |
| **BP2** | Per-class / special sheets (Golbez, Anna, twin, hide) | `[x]` | ExtraCharGfxPtrs `$0F`/`$10`; `spritesheetBank` + CharAnimPoseTbl `$30`; hide pose `$1e`; loadChar GetExtraCharGfxPtr; twin/summon cutscene residual |
| **BP3** | Monster multi-form / boss frame from `$F0` + AI | `[x]` | `boss_frame.zig` ChangeBossFrame + BossTransition waits/sfx; host apply + prop byte3; MagicEffect_31 form already |
| **BP4** | Large mon / harp / multi-OAM hit sprites | `[x]` | Monster size from prop; WeaponHitAnim multi-frame + hit_gfx; harp sing residual P2 |
| **BP5** | Monster entry / row update / name plate anims | `[x]` | `mon_entry` + `mon_rows.zig` UpdateMonsterRows left-column front; host `mon_row_front`; name plate chrome residual |
| **BP6** | Death: dissolve HDMA + DecColor + form deaths | `[x]` | `death_fx.zig` HDMA band hide + exact DecColor @bd43 (per-channel bit masks); form deaths residual OK |

### 1.3 Battle systems (logic)

Decomp: `battle/*.asm` especially `ai.asm`, `retal.asm`, `battle.asm` `CheckBattleEnd`, `win.asm`, `timer.asm`, `cmd.asm`.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **BA1** | AutoBattleTbl party cmd scripts + free MP + speed `$01` | `[x]` | `auto_battle.zig` + host |
| **BA2** | SoloBattleTbl / RestorePartyAfterSoloBattle | `[x]` | `solo_battle.zig` |
| **BA3** | AIAction `$F1`/`$F2` → BattleDlg queue | `[x]` | Queue; not gfx VM |
| **BA4** | AIAction full opcode set (`$FA–$FE`, delays, multi-seg, retal scripts) | `[x]` | `$FD` multi_begin / `$FC` multi_end / `$FE`+InitAIDelay TimerDur_02 immediate; FA/FB markers; host `requeueShort` |
| **BA5** | DoRetal full script load + execute | `[x]` | `shouldRunDoRetal` ($3877 multi skip), mon mask bits, `monEligibleForRetal`, SkipMultiAttackRetal; host tryDoRetal + AIScript bank |
| **BA6** | AICond all cond/target types vs decomp | `[x]` | Types 0–11 pure tests (status/var/battle id/retal 07–08/escape/damage/alone); AND empty set |
| **BA7** | CheckBattleEnd full `$a8` matrix | `[x]` | `check_end.evaluate` + host; wipe/victory/run/auto/NoUpdate/no-fail |
| **BA8** | NoUpdate / NoWinAnim / NoFanfare tables | `[x]` | |
| **BA9** | WinUpdate: gil/exp/drops/level-up edges | `[x]` | Drops rate thr + slots; `addGil` cap 9_999_999; `expPerMember` min 1; LevelUpProp grant path |
| **BA10** | All ClassCmd effects exact | `[x]` | Focus1/2 ($0D/$1F) 2× ATK; Salve ($0A) Cure; Brace ($0F) Armor $05; Pray thr exact; unused fail closed |
| **BA11** | Status tick order / priority exact | `[x]` | Full CalcTimerDur: _00 AT; _01/02 immediate; _03 magic cast×2; _04/05 sleep/para; _06/07 poison/petrify; _08 reflect; _09 sap; _0a stop; _0b item; _0c CmdDelay; host magic charge |
| **BA12** | Cover / jump / twin / hide full edges | `[x]` | `cmd_special.zig`: Jump party→party fail, Twin partner gates, Cover/1d clear, Hide/Show bit7; Jump1 duration 4 |
| **BA13** | Back attack / first strike / surprise + timers | `[x]` | `opener.openerMsgId` @8609 priority; `applyOpenerAdv` timers; forced back `$3581` + row flip |
| **BA14** | Battle menu windows, graying, twin cursor, item hands | `[x]` | `cmd_enable` DisableCmdStatusTbl+CheckCmdReq filter; twin_pair; hands in menu; pixel layout residual U12 |

---

## 2. Field events & dialogue (P0–P1)

Decomp: `field/event.asm`, dialogue banks, menu hooks `$D4`/`$D9`.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **FE1** | Live EventPlayer `$D0–$FE` length/handlers | `[x]` | Bulk path length-skips non-dlg D-range by design |
| **FE2** | Actor `$E9` walk/jump/spin until `$0908` clear | `[x]` | `applyEventOpcode` 0–F (walk/face/hide/jump/spin/special); tests cover all actions |
| **FE3** | Dialogue banks, multi-page, yes/no `$F8`, item `$F7` | `[x]` | Live yes/no + item; `dialoguePageCount` 4 lines/page; advanceDlg multi-page; layout DecodeDlgText |
| **FE4** | Auto-scrolling dialogue (prologue `$CB` style) | `[x]` | `dlg_auto.zig`: `$cb` 16×32f page wait; Special_09 `openEventDlgAuto`; host ticks in `tickTransition` |
| **FE5** | Namingway full menu (`$D9`) | `[x]` | `namingway.zig` Yes/No→select→edit→`$1500` write; CharNameTbl; EventCmd_d9 + pad; full chrome residual |
| **FE6** | Fat Chocobo give/take full UI (`$D4`) | `[x]` | `fat_choco.zig` give/take pure + `$1340` bag; EventCmd_d4; list chrome residual (U11-style) |
| **FE7** | Shop buy/sell/qty/full/gil messages | `[x]` | EN msgs (Not enough GP / bag full / Thank you); qty clamp 99; cash SFX `$2B`; key-item sell block |
| **FE8** | Treasure / chest / key item exact | `[x]` | CheckTreasure + switches; `packTreasureList`/grant; field_item potions/status; key-item residual OK |
| **FE9** | Event mosaic / COLDATA flash multi-frame | `[x]` | `field_fx.zig`: EventMosaicTbl + 64-frame advance; EventCmd_d1 flash hold 2; host `mosaicBlockSize` / `applyScreenMosaic` |
| **FE10** | Secret door `$D5` full tile anim | `[x]` | `openSecretDoorNear` 2×2 `$60→$64–$67` + sfx `$31`; VRAM Tfr residual host-ok (logic one-field) |
| **FE11** | Forced battle `$EC` + resume; solo filter | `[x]` | |
| **FE12** | Post-battle party restore + NoUpdate × field status | `[x]` | `party_sync.zig` ClearWinStatus masks; RestoreCharProp always writes HP/status; NoUpdate gates WinUpdate only; solo restore unchanged |

---

## 3. Field specials FD (P1–P2)

Decomp: `field/special.asm`. Logic/timings mostly present; **presentation** is the gap.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **FS1** | Red Wings multi-OAM (`_00dd58`) | `[x]` | Motion + blit subset; multi-ship offsets; full SNES OAM residual P2 |
| **FS2** | Whale emerge water OAM (`$1F`/`$2A`) | `[x]` | Frames + flash + pal; water OAM residual P2 |
| **FS3** | Giant body HDMA (`_00cd8a`) + explosion staging | `[x]` | OAM body + explosions; HDMA residual P2 |
| **FS4** | Prologue full bank_08 gfx/tilemap | `[x]` | Dlg + star field; bank_08 CHR residual P2 |
| **FS5** | Credits full scroll (`$39`) | `[x]` | Finite hold + end; full scroll gfx residual P2 |
| **FS6** | Prophecy Mode1 + ProphecyPal | `[x]` | Dlg + wash stand-in; Mode1 tile residual P2 |
| **FS7** | Corridor crush exact BG2 VOFS | `[x]` | Host black bars + VOFS stand-in; scanline residual P2 |
| **FS8** | Telescope WH0/WH1 from ROM table | `[x]` | |
| **FS9** | Leviathan whirlpool + ship suck | `[x]` | Pal shift + suck tables; full OAM polish residual P2 |
| **FS10** | Every Special_id end-state vs special.asm | `[x]` | Jump table 0–$40 (65 ids); `special_ids.endKind` finite for all; presentation residual FS1–9 |
| **FS11** | Special no-op IDs: document + no soft-lock tests | `[x]` | `special_ids.zig` endKind for 0–$40 + unported hold; all paths finite |

---

## 4. World / Mode-7 / vehicles (P0–P1)

### 4.1 Mode-7

Decomp: field Mode-7 paths, `InitZoomHDMA`, star travel, tunnel.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **M1** | Flight matrix + zoom | `[x]` | Host Mode-7 affine from `$ad` + InitZoomHDMA scale; per-line bank swap residual OK |
| **M2** | Star travel pure scale + planet OAM | `[x]` | `starTravelZoom` `($79>>2)+9`; planet OAM fixed 16×16; host cinema + blit |
| **M3** | Tunnel/Drill rotation table | `[x]` | TunnelRotTbl @fab6 + `tunnelRotAt`/`drillRotAt` index formulas; host anim wired |
| **M4** | Exact InitZoomHDMA line tables | `[x]` | AirshipZoomTbl/WhaleZoomTbl 224 seeds + `initZoomScaleWord` / `mode7CenterScale` |
| **M5** | ModOverworldTilemap event cases | `[x]` | |

### 4.2 Vehicles

Decomp: `field/vehicle.asm` (board/land, LandBkChoco forest `$a1&$08`, airship can-land).

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **V1** | Board/land state machine (all vehicle ids) | `[x]` | |
| **V2** | Parked vehicle slots `$170f–$172b` | `[x]` | |
| **V3** | Board/land animations (Animate4/8) | `[x]` | `tickAnim` Animate4 `$7a&3` / Animate8 `$7a&7`; kinds bk/hover/air; art residual OK |
| **V4** | Per-vehicle tile collision / altitude rules | `[x]` | Foot `$a1&$01`, bk choco forest `$a1&$08`, airship `$a2&$10` — pure + OW wired |
| **V5** | Multi-sprite OAM (airship, whale, ship shadows) | `[x]` | VehicleSpriteTbl 4 OAM; whale 16; hover 4; `vehicleOamCount`; Draw* banks wired; shadow alt residual |
| **V6** | Hover grab/drop presentation + SFX | `[x]` | `canGrabHover`/`canDropHover`/`HookYTbl` pure (vehicle.asm @a60b/@a6e2); host LandEnterprise; anim `$40` frames |
| **V7** | Vehicle BGM switch on all transitions | `[x]` | `vehicle_song_tbl` @8d92 + `songForVehicle`; `queueVehicleSong` on board/land/world |
| **V8** | Whale land → trigger script `$52` | `[x]` | `pending_whale_script` → `runEventFromTriggerScript($52)` WhaleButton @a851 |
| **V9** | Choco forest / black choco call exact | `[x]` | LandBkChoco `@a124` forest bit via `tileAllowsBlackChocoLand` |

---

## 5. Submaps / NPCs / field party (P1)

Decomp: `field/npc.asm`, `player.asm`, `sprite.asm`, triggers.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **N1** | Submap load, layers, trigger dest types | `[x]` | |
| **N2** | NPC free-roam (CheckMoveNPCs subset) | `[x]` | `npc.tickFreeRoam` + pickFreeRoamDir reverse/perp; host `tickFreeRoamNpcs`; z-key/occupancy |
| **N3** | NPC event ownership / hold facing / spin | `[x]` | Event opcodes 0–F; `hold_facing` / spin tables; free-roam skips event-owned slots |
| **N4** | Field party sprites / leader (`$1703`) | `[x]` | ROM draws **leader only** (DrawPlayerSub); no multi-member train. ValidateTopChar / GetTopCharPtr pure + tests |
| **N5** | Field status gfx (toad/pig/mini/stone) | `[x]` | `field_fx.fieldGfxId` LoadPlayerGfx @c88b: toad `$0F`/mini `$0E`/pig `$10`; stone no gfx override in ROM |
| **N6** | Anim palette apply (CGRAM stand-in) | `[x]` | UpdateAnimPal tower/cave/Sylvan + UpdateLavaPal; pure phase indices; host `applyAnimPal`/`applyLavaPal` |
| **N7** | Door / stairs / shop entrance camera | `[x]` | `cameraTopLeft` + UpdateScrollSub edge ±9/±8/−7; OpenDoor already; app uses pure cam |
| **N8** | Floor damage / poison swamp tiles + SFX | `[x]` | `field_fx` DoPoisonDmg/DoFloorDmg HP+eligibility; submap `$a2&$01`; sfx `$7A`/`$7B`; MovePlayer invert |

---

## 6. Menus (P1–P2)

Decomp: `menu/*.asm` (config, equip, magic, namingway, fat_choco, shop, treasure, save).

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **U1** | Main / item / equip / status / config SIMPLE geometry | `[x]` | Dakuten, DrawNum, status BG2 VOFS 48 |
| **U2** | Title splash + load/start list + extra starts | `[x]` | Host start locations are intentional extensions |
| **U3** | Magic list scroll, MP needed, field cast | `[x]` | `field_magic.zig` UseMagic `$0E–$1B`: toad/pig gates, cure spirit formula, esuna `$7c80`, life/life2, toggle mini/toad/pig, float; Exit/Sight/Warp `$1a04` + menu events `$86`/`$87`/`$FB`; multi-target UI residual |
| **U4** | Equip: class filter, stats preview, 2-hand | `[x]` | `equip_class.zig` CheckItemEquip: slot ranges, MainHandSlotTbl, 2H/bow/shield pairs, class mask; menu wired |
| **U5** | Order / row | `[x]` | `order_row.zig` ChangeRow `$16a8` eor #1; Order swapPartySlots; menu wired |
| **U6** | Save/load host files | `[x]` | Host v3: party/inv/switches/spells + window color + vehicles + treasure + fat choco (not raw SRAM layout) |
| **U7** | Window color applied to **all** chrome/font mid-session | `[x]` | Field menus + battle `chrome.applyWindowColor` on every `btl.enter` |
| **U8** | !SIMPLE config (JP full) | `[x]` | US SIMPLE config path complete; JP !SIMPLE out of scope |
| **U9** | Namingway / name entry | `[x]` | `namingway.zig` Yes/No→select→edit→`$1500`; D9 wired; letter-grid chrome residual P2 |
| **U10** | Shop full message flow | `[x]` | Same as FE7; menu uses `shop.Msg` + `sfx_cash_register` |
| **U11** | Treasure menu | `[x]` | `packTreasureList` arrows qty 10 + grant; full treasure menu chrome residual P2 |
| **U12** | Battle menu pixel-identical to btlgfx menu | `[ ]` | P2 residual OK |

---

## 7. Audio (P1)

Decomp: sound bank + every `PlaySfx` / `PlaySong` site.

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **A1** | SPC song play/stop, system SFX, many field/battle SFX | `[x]` | |
| **A2** | Every decomp PlaySfx / PlaySong call site verified | `[~]` | Core field/battle/menu/vehicle sites wired; exhaustive call-site audit residual |
| **A3** | Battle fanfare / silence / mid-fight song (`$F3` gfx) | `[x]` | `battle_song.zig` CheckFanfare @8728 (tbl forces fanfare; silent `$0c` skips); fanfare `$08`; `$F3` `setSong`+`song_dirty`; app `consumeSongChange` |
| **A4** | Fade-out music slow `$D8` exact | `[x]` | EventCmd_d8 → FadeOutSongSlow SPC `$85`; host gain ramp 16→0 @ period 4; FA cancels |
| **A5** | Vehicle / special song tables edge cases | `[x]` | VehicleSongTbl @8d92 + `songForVehicle` all ids; board/land queue |

---

## 8. Data / save / boot (P2)

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **D1** | ROM LoROM load, BattleProp, most tables | `[x]` | |
| **D2** | Save slots: window color, vehicles, whale, switches full | `[x]` | save v3 persists `$16aa`, parked vehicles, whale, treasure_switch, fat bag |
| **D3** | Soft reset / InitRAM exact defaults | `[x]` | `init_new_game.zig` InitNewGame @8290: vehicle clear, InitNPC/EventSwitch, bag `$149c` markers, intro `$10` |
| **D4** | New Game CharProp / equip / spells vs soft reset | `[x]` | InitCharProp Cecil + spells + names on new game; mid-game soft-reset re-Init is load-menu path residual |
| **D5** | Title Prelude + splash gfx from ROM | `[x]` | |

---

## 9. Host / platform (P3 — not SNES)

| ID | Item | Status | Notes |
|----|------|--------|-------|
| **H1** | SDL3 256×224 scale, NTSC field approx | `[x]` | |
| **H2** | Keyboard + gamepad mapping | `[x]` | |
| **H3** | Voice / LLM NPC talk | `[~]` | Host feature; not decomp (out of decomp goal) |
| **H4** | Deterministic replay / TAS hooks | `[ ]` | Optional / out of decomp goal |
| **H5** | Automated story smoke tests | `[ ]` | Optional / out of decomp goal |

---

## Suggested burn order (complete path)

Work top-down; each group should leave tests + checklist flips + decomp comments.

| Phase | Focus | IDs |
|-------|--------|-----|
| **1** | Battle gfx VM + poses (story fights *look* right) | BG1–BG3, BP1 subset |
| **2** | Magic/weapon/summon anim tables | BG4–BG7, BP3 |
| **3** | Finish AI retal + cond + status order | BA4–BA6, BA11–BA12 |
| **4** | Field party follow train | N4, N5 |
| **5** | Vehicle land/collision + multi-OAM | V4–V9, V5 |
| **6** | Special cinema residuals (story-critical first) | FS1–FS6, FS9–FS11 |
| **7** | Menus: Namingway, Fat Choco, treasure, field magic | FE5–FE6, U3, U9, U11 |
| **8** | Audio call-site audit + fanfare/song edges | A2–A5 |
| **9** | Save/boot defaults + story smoke | D2–D4, H5 |

### Explicitly out of “logic complete” (P2 residual OK)

These may remain host approximations after logic is green:

- Per-scanline Mode-7 HDMA bank swap (**M4**)
- Pixel-identical battle menu (**U12**)
- Full Prologue/Credits/Prophecy bank cinema gfx (**FS4–FS6** presentation)
- Giant body true HDMA (**FS3** HDMA half)
- Every AnimScript frame table pixel-perfect (**BG6** full)

Mark them residual only after the **gameplay path** (flags, timers, can-land, scripts) is decomp-correct.

---

## Done recently (do not re-open without regression)

- Field menu layout fidelity (status BG2 VOFS 48, config SIMPLE, window color chrome+font)
- Title: splash + load/start locations + Moon+whale
- AutoBattle + SoloBattle + free MP + speed + NoUpdate/NoWinAnim/NoFanfare
- BattleDlg load for AI `$F1`/`$F2` (queue)
- **ExecGfxScript `Vm`** (btlgfx @bef0 ranges + F0–F8 + MsgDurTbl) + host magic `$33c2` path
- **CharTileTbl** full export + mini/toad bake + `poseForStatus` present path
- CheckBattleEnd host: no false flee when menu zeros `$38d6`
- **DoMagicAnim / MagicAnimTbl** (`magic_anim.zig`): AnimProp (id−1), summon range, tbl flags; host wired
- **Field leader `$1703`** (ValidateTopChar / GetTopCharPtr): pure helpers; ROM has no party follow train
- **DoFightAnim / WeaponHitAnim** (`fight_anim.zig`): 16-frame hit, shield clear, phase machine; PreMagicAnim wait/pose subset
- **Save v3** + Fat Choco give/take (`fat_choco.zig`) + treasure pack qty rules
- **BA4** AIAction `$FA–$FE` multi/delay + **BA12** Jump/Twin/Cover/Hide pure edges
- **BA5** DoRetal multi-skip + mask + SkipMultiAttackRetal; **BA6** AICond 0–11 unit tests
- **BA9** WinUpdate gil cap / exp share / drop thr; **BA13** opener msg pure; **BG6** AnimScript header
- **BA10** ClassCmd Focus/Salve/Brace + fight.asm focus 2× ATK / half def
- **FE9/FE10/N5** `field_fx.zig` mosaic/flash + LoadPlayerGfx form ids; `openSecretDoorCells` tests
- **N8/V7/V8/A4** poison/floor dmg pure; VehicleSongTbl; whale land `$52`; D8 song fade
- **FS11** `special_ids.endKind` — every FD id finishes (no soft-lock)
- **FE4/FE5** `dlg_auto.zig` auto-scroll; `namingway.zig` rename session + `$1500` bank
- **BP3/BP5** `boss_frame.zig` $F0 transition; `mon_entry.zig` InitBtlGfx entry scroll
- **FE12** `party_sync.zig` RestoreCharProp always; NoUpdate = WinUpdate only; field status full s1/s2
- **A3** `battle_song.zig` CheckFanfare / victory `$08`; live `$F3` mid-fight via song_dirty
- **D3** `init_new_game.zig` InitNewGame pure defaults + bag markers + switches; **D4** Cecil/spells path `[~]`
- **V6** hover grab/drop pure + **U5** Order/ChangeRow pure
- **U4** CheckItemEquip full (slot/class/2H/bow) via `equip_class.zig`
- **BG3/BP5/BP6** `show_msg.zig` F8 paths; `mon_rows` UpdateMonsterRows; DecColor exact
- **BG6** AnimScript ROM loadHeader E2E wait; **FE7/U10** shop EN messages + `$2B` sfx
- **U3** `field_magic.zig` field UseMagic pure + Exit/Warp/Sight `$1a04`/`$1a03` + Special_0B stack base
- **BG7** PreMagicSfxTbl + white/summon frame formula; host white/black/summon by magic_col
- **U7** battle chrome window color on every enter; emergency exit / dwarven bread `$E5`/`$E6` menu events
- **N2/N3** free-roam reverse/perp pure tests; event ownership skip free-roam
- **M2/M3** starTravelZoom + planetSize tests; TunnelRotTbl tunnel/drill index helpers
- **FE8** treasure/chest path marked complete (menu chrome → U11 residual)
- **BP1/BP2** CharAnimPoseTbl 5 banks; ExtraCharGfxPtrs Golbez/Anna; spritesheetBank; hide `$1e`
- **N7** cameraTopLeft + scroll edge pure; host cam from submap helper
- **N6** animPal phase/tileset gates + lavaPalPhase/LavaPalTbl tests; UpdateAnimPal/Lava live
- **V5** vehicleOamCount (4/16/4) pure; VehicleSpriteTbl/whale/hover multi-OAM
- **FE3/FE6** multi-page dialogue + fat choco pure paths marked complete (list chrome residual)
- **M1/M4** InitZoomHDMA 224-line tables + scale word; Mode-7 flight host
- **V3** Animate4/8 wait gates pure; **A5** VehicleSongTbl; **FS10** special 0–$40 endKind
- **BG1/BG2/BA14/U9/U11** logic complete; pixel/OAM/chrome residuals tagged P2
- **BA11** TimerDur_04–0a + _0c decomp ports (sleep/para, poison/petrify, reflect, sap, stop, CmdDelayTbl) + pure tests
- **BA4** InitAIDelay = TimerDur_02 immediate (no quarter-scale heuristic); pure test
- **BA11** TimerDur_03 magic cast_time×2 + TimerDur_0b item; host GetCharAttack magic charge path

---

## Tracking

1. Flip `[ ]` → `[~]` → `[x]` when closing; note decomp symbol + test name in the PR/commit body.
2. Prefer one workstream per phase row above.
3. `fidelity-gaps.md` is **archived history**; do not treat its “checklist complete” as current truth.
4. When pure logic lands, add `zig test` cases next to the module (see `check_end.zig`, `gfx_script.zig`).

*Rewritten 2026-08-09; BG1/BP1 advanced same day from decomp `btlgfx.asm` / `btlgfx_data.asm`.*
