# Battle module — ROM reimplementation

This is **not** an “FF4-style” invention. Logic and tables track
[everything8215/ff4](https://github.com/everything8215/ff4) (`battle/*`,
`field/rand_battle.asm`). When behavior is unclear, read the decomp first.

## Entry / loop (battle.asm)

| Decomp | Our code | Role |
|--------|----------|------|
| `Battle_ext` / `ExecBattle` | `host.enter` | Enter battle from field |
| `InitBattle` | `init.initBattle` | Load BattleProp, positions, objects |
| `BattleMain` | `host.tick` | Frame loop (speed table, pause) |
| `DecTimers` | `timer.decTimers` | Action/stop/poison/… timers |
| `CheckBattleEnd` | `host.checkEnd` | Victory / wipe / run |
| `GetPendingAction` | `timer.getPendingAction` | Next ready unit |
| `DoAction` / `ActionTbl` | `host.doAction` | Char menu / mon AI / attack / timer |
| `GetCharAttack` | `char.getCharAttack` | Open menu / queue command |
| `GetMonsterAttack` | `ai.getMonsterAttack` | Queue monster command (default Fight) |
| `GetDefaultAITarget` | `ai.getDefaultAITargetParty` | Random living party target |
| `DoAttack` / `ExecCmd` | `host.startPartyFight` / mon | Resolve Fight etc. |
| `Cmd_00` DoFightCmd | `cmd_fight.doFight` | Physical attack |
| `Cmd_01` item | `cmd_item.doItem` | ItemProp + RestoreHP/MP/… |
| `Cmd_24` run | `cmd_run.tryRun` | Flee |
| `CalcTimerDur` / `ApplySpeedMod` | `timer_dur` | Action AT from max agility |
| `LoadEquipProp` / `UpdateCharStats` | `equip.calcCombatStats` | Hands → atk/hit/mult |
| `MonsterCursor` / `MoveTargetCursor` | `host.mon_cursor` + `moveTarget` | Target graph |
| `WinUpdate` | `win.onVictory` | Gil/exp (partial) |
| `ExecBtlGfx` | `gfx.present` + `sprites.Scene` | BG + mon/char tiles from ROM |

## Field → battle id (field/rand_battle.asm)

`encounter.zig` ports `CheckBattle` / `ChooseRandBattle` / rate & group tables.
Field stores `$1800` battle id (+ `$1801` hi / `$1802` bg flags) then calls battle.

## BattleProp (8 bytes @ `0E/8000`)

Loaded to `$299c` in decomp (`InitBattle`):

| Offset | Meaning |
|--------|---------|
| 0 | Flags (bit3 = forced back attack) |
| 1–3 | Monster **types** (0xFF empty) |
| 4 | Counts: 2 bits × 3 types (MSB first) |
| 5 | MonsterPos table index |
| 6 | Song / auto-battle / etc. |
| 7 | MonsterCursor table index |

Monster slots (up to 8) are filled by expanding types×counts (dup merge like ROM).

## Object slots (WRAM mirror)

| Slots | Use |
|-------|-----|
| 0–4 | Party characters |
| 5–12 | Monsters (up to 8) |

Properties live in a packed struct approximating `$2000,x` character/monster blocks
(subset: hp, max_hp, level, agility, atk/def indices, status, row, type id).

## Graphics (btlgfx)

| Decomp | Our code |
|--------|----------|
| `LoadBattleBGGfx` + `LoadBattleBGTiles` | `sprites.loadBattleBg` (18-row WRAM layout, tile=`entry&$3F`, dual pal, V-flip) |
| `LoadMonsterGfx` | `sprites.loadMonster` |
| `InitCharGfx` + `CharTileTbl` poses | `sprites.loadChar` (standing..dead) |
| `MonsterPos` / `UpdateMonsterPos` | `prop.applyPositions` (nibble XY) |
| `StepForwardToAttack` / fight hit flash | `host.AnimState` + `gfx.present` |
| `WeaponHitAnim` flash + spark | impact frame spark + 16-frame flash |
| `MonsterDeathAnim` ($30 frames) | dissolve + fade, then hide |
| Victory pose (`CharTileTbl` $08) | after last kill |
| `WorldBattleBGTbl` from tile prop_hi | `encounter.worldBattleBg` |
| `WindowGfx` / `BorderTilesTbl` / `MenuWindowTbl` | `window.WindowChrome` |
| `ClassCmd` + `BattleCmdName` | command list + names from ROM |
| L+R flee | `Host.tryFlee` (keyboard X) |
| `BattleSongTbl` / `PlayBattleSong` | song from BattleProp byte6 bits 2–3 |
| System SFX $12/$13/$14, hit $2a | `playSystemSfx` / `playSfx` |
| Hand cursor tile $4a (MiscBattleGfx) | `cursor.HandCursor` + `CmdCursorYTbl` |
| `FightMenuCmd` → cursor type $04 | target select before attack |
| `UpdateCursor_04` / `MoveTargetCursor` | D-pad cycles living monsters; B cancels |
| `ShowMsg_04` / `DrawDmgNumerals` | bounce damage numbers + Miss |
| `DoFightCmd` row/hit/crit | back-row hit/def, crit, equip ATK from EquipProp |
| Ready pose on AT wait | CharTileTbl $01 while menu open |
| Parry / defend | doubles defense until next action |

## Items

ItemProp @ `0F/9680` (id `$B0+i`). Cmd_01 → DoMagicAttack effects:
Restore HP (`$02`), Life (`$0A`), Heal (`$0B`), Restore MP (`$15`), Elixir (`$16`),
Spell Damage (`$00`). Inventory is shared field `$1440` (`game/inventory.zig`).

## Recent ports

| Decomp | Our code |
|--------|----------|
| `$2003–$2006` status bits | `status.zig` + `Obj.status` |
| `EquipProp` + `ElementStatus` | `equip.zig` element/status inflict, dual/bow crit |
| `DoFightCmd` hits/elem/status | `cmd_fight` net hits, elemental mult, weapon status |
| `AIAction1` / `GetScriptPtr` | `ai.zig` script walk: Fight `$C0`, magic `$C2`, target `$F9` |
| Magic effects 0/2/6/A/B/C/15/17/28 | `cmd_magic.doMagic` |
| `WinUpdate` gil/exp | `win.calcRewards` |

## Recent (this pass)

| Decomp | Our code |
|--------|----------|
| `AICond` 0–3 | `ai_cond.zig` + action pick in `ai.getMonsterAttack` |
| `DoTimerEffect` poison/sap/stop/doom | `timer.decTimers` + arm on status |
| `Cmd_06` / `Cmd_1e` Jump | mon target select `$58`; air time 4 (no speed mod); hide mid-air; land 2× ATK |
| `Cmd_13` Cover | cover_by redirect on hit |
| `LevelUp` / `LevelUpHPMP` | `levelup.grantExpAndLevel` after victory |
| `BossGfxProp` size | boss sprites sized from ROM |
| `BossTilemap` RLE | `sprites.loadBoss` ($FF empty, $FE,nn run) |
| `AICond` 0–11 + script AND | `ai_cond.check` / `checkSetAnd` + `Host.makeBattleCtx` |
| Reflect + gradual petrify | `timer.armReflect/armPetrify`, bounce in `doMagic` |
| Multi-party load + hands | `Host.enter(party)`, `loadPartyMember`, `syncPartyOut` |

## Decomp fidelity checklist

Port named decomp routines; do **not** invent alternate systems.  
Table value ≠ screen behavior — always read the **consumer** (HDMA, VRAM tfr, gfx script).

### Done recently
- [x] Menu strip: HDMA **10** rows @ y=$90 (not full 13-row buffer)
- [x] Window chrome: solid fill + border index-0 → blue (no battlefield bleed)
- [x] Hits: `ShowMsg_04` numerals only (no invented `"Imp 62! Down!"`)

### Priority queue

| # | Item | Decomp | Status |
|---|------|--------|--------|
| 1 | Image/barrier → consume image, 255 def hits | `fight.asm` @c59b | **done** |
| 2 | Monster optional prop bits exact (`@90f6`) | `init.asm` InitMonster | **done** (bit3=$2040 creature; bit4=int/spirit; bit5 weak; bit6 strong/immune) |
| 3 | BattleMsg from ROM (`battle_msg.zig`; openers/win/run/mp/miss) | `ShowMsg_03`, `BattleMsgPtrs` | **done** (ShowMsg_02 name window TBD) |
| 4 | `CharOrderTbl` party name/HP order (1,3,0,4,2) | `btlgfx_data` @a1c8 | **done** |
| 5 | Defender slot-0 +25% def rate | `fight.asm` @c5af | **done** |
| 6 | `MagicEffectTbl` + mag.def CalcHits / $2722–$2724 | `magic.asm` @cea7/@d084 | **done** (dmg path; many effects still sparse) |
| 7 | Multi-target + split + reflect opposite side | `DoMagicAttack` | **done** (menu multi-select UI still single primary) |
| 8 | ChangeBattleVar `$F4`–`$F7` (add/sub/set); `$FA`–`$FE` stop | `ai.asm` | **done** |
| 8a | ChangeMonsterStat `$E8`–`$EF` + `LoadMonsterStat` raw | `ai.asm` @b76f / init @9489 | **done** (E9–EB triples; EC base-timer formula; EF always weak) |
| 8b | AIAction2 moon bank (`$0E/B6C0`, `$38ef`) | `battle.asm` @80cb | **done** |
| 9 | ClassCmds incl. Cry/Bluff/Recall/Dark/Pray/Twin/Ninja… | `cmd.asm` | **done** (edge cases remain) |
| 10 | ROM battle RNG (`RNGTbl` @ 0xA6E00) | `RandXA` | **done** |
| 11 | BossGfxProp size/pal/tilemap + MonsterGfxProp tile bank | `LoadBossTilemap` / `@9007` | **done** |
| 12 | Dual-wield | equip combines ATK (ROM is **one** resolve, not 2 swings) | **n/a (correct)** |
| 13 | Creature mult $38ff: char→mon 4× / mon→char ½× | `fight.asm` @c685 | **done** (`creature_atk`∩type / type∩`creature_def`) |
| 14 | Cover select + hit redirect via `cover_by` | `Cmd_13` | **done** |
| 15 | ShowMsg_02 spell/attack names | `GfxScriptCmd_f8` type 2 | **done** (SpellName id<$48 / AttackName id≥$48; no full anim script) |
| 16 | No invented hit/def defaults | `fight.asm` CalcHits | **done** (raw rates; mon init def_rate=0 per ROM double-store bug) |
| 17 | Magic multi-target $3906 divisor + fixed-hits bit7 | `magic.asm` @cef1 / damage Div16 | **done** |
| 18 | UpdateCharStats armor def/mdef/creature_def | `equip.asm` @99a4–@9af3 | **done** (head/body/arms + shields) |
| 19 | L+R flee counter `$38d6` / MonsterRunTbl | `battle.asm` @a07e / `@8210` | **done** (not a random chance) |
| 20 | MagicEffect_0d/0e/0f protect/shell/haste | `magic.asm` @d83f–@d89c | **done** |
| 21 | MagicEffect_10–14, 18–1e (stop/libra/escape/HP-ratio/doom…) | `magic.asm` @d8a0–@dbf0 | **done** |
| 22 | SpellListTbl from acting `char_id` (no invented list) | `SpellListTbl` | **done** |
| 23 | Twin partner checks (`$2004&$3c`, stop) | `cmd.asm` Cmd_10 | **done** |
| 24 | Party vitality on Obj for defense formula | `UpdateCharStats` | **done** |
| 25 | Sylph $1a heal-split / Odin $1b 50% death | `magic.asm` @daa1/@db6a | **done** |
| 26 | Twin Cmd_10 charge → Cmd_20 resolve | `cmd.asm` @e441/@e4e6 | **done** |
| 27 | Libra/Peep weak-elem msgs $14–$1a | `Cmd_14` / `MagicEffect_12` | **done** |
| 28 | MagicEffect $20–$27, $2a–$2c, $30 | `magic.asm` @dc9b+ | **done** |
| 29 | Call/Alert `$29` ActivateMonster | `magic.asm` @dd9b/@df5f | **done** |
| 30 | Twin pair `$3539` Palom/Porom/Fusoya/Golbez | `init.asm` @959e | **done** |
| 31 | MonsterDeathHDMATbl dissolve | `btlgfx` @fae5 / `$13/F99D` | **done** |
| 32 | MagicEffect $32 end battle | `magic.asm` @dfd2 | **done** |
| 33 | MagicEffect $31 Change Form | `magic.asm` @de34–@df5e | **done** |
| 34 | Mon invincible `$3881` ($2e/$2f + fight/magic) | `fight.asm` @c623 / `magic.asm` @d152 | **done** |
| 35 | MagicEffect $33 targeting / $34 hatch | `magic.asm` @dfd8/@dfeb | **done** |
| 36 | GetSummonAttack + power×8 / 8 hits | `magic.asm` @e053/@d039/@cf1e | **done** |
| 37 | Crystal `$C8` pierces mon invincible | `magic.asm` @d152 | **done** |
| 38 | MagicEffect $35 mist dragon delay death | `magic.asm` @e000 | **done** |
| 39 | Call maps A=1 → `form_types[1]` | `ActivateMonster` | **done** |
| 40 | Cmd_01 item → `doItemMagic` (DoMagicAttack) | `cmd.asm` @eba2 | **done** |
| 41 | SummonFailed Rydia MP on total miss | `magic.asm` @e07e | **done** |
| 42 | RandSummon item `$CA` / SummonBookTbl | `cmd.asm` @ec12 | **done** |
| 43 | Weapon magic `$38eb` + WeaponMagicHits | `cmd.asm` @ebd2 | **done** |
| 44 | Sylph EN: heal numerals only (no HP write) | `magic.asm` @db21 LANG_EN | **done** |
| 45 | Cmd_01 status gates + ItemProp multi-target | `cmd.asm` @eba2 / expandTargets | **done** |
| 46 | Throw invincible miss + exact Mult8 formula | `cmd.asm` @e34f | **done** |
| 47 | Cmd_1a row flip all party | `cmd.asm` @e3d4 | **done** |
| 48 | Recall RandXA 0..$a0 thresholds | `cmd.asm` @ea1d | **done** |
| 49 | BattleSpeedTbl exact `$3538` reload | `battle.asm` @85d9 / `$16ac` | **done** |
| 50 | LoadMonsterGfx boss early-out (no dead size path) | `ppu.asm` @8f8a | **done** |
| 51 | First-strike / surprise / back-attack openers | `init.asm` @8c66 / `battle.asm` @8609 | **done** |
| 52 | `$38d8` timer bias + back-attack row flip | `init.asm` @8e1d | **done** |
| 53 | Config `$16ac` battle speed into `Host.enter` | `battle.asm` @85d9 | **done** (field `GameState.battle_speed`) |
| 54 | WinUpdate MonsterItems drops (rate + slot table) | `win.asm` @ed00–@ed5f | **done** |
| 55 | InitCharRows `$16a8` front/back layout | `init.asm` @95ce | **done** |
| 56 | AddRetal stack + AICond_07/08 exact | `attack.asm` @b288 / `ai_cond.asm` | **done** |
| 57 | Avenger `$4C` berserk + auto-fight | `char.asm` AvengerEffect | **done** |
| 58 | Dark Wave quarter vs undead `$2040` bit7 | `fight.asm` multi | **done** |
| 59 | Hand-equip cast (`$26d0` bit4) in Item list | `cmd.asm` @eba2 | **done** |
| 60 | DoRetal subset: `$38aa` mon fight-back | `retal.asm` @c16c | **done** (fight attacker; full scripts later) |
| 61 | Charm auto-attack ally / mute strip magic cmds | `char.asm` ValidateChar / UpdateEnabledCmds | **done** |
| 62 | Config menu battle speed `$16ac` | `config.asm` | **done** |
| 63 | MsgDurTbl `$16ad` message hold frames | `btlgfx` WaitMsgAuto @c953 | **done** |
| 64 | Wait/Active `$16be` (ATB pause on menu) | `btlgfx` PauseBattleWait | **done** |
| 65 | DisableCmdStatusTbl exact cmd filter | `battle_data` @fd19 / `char.asm` | **done** |
| 66 | Edward critical auto-hide (ForceCharActions) | `timer.asm` @ab3a | **done** |
| 67 | SapRegenEffect: sap = 2 HP/tick; timer expire clears | `timer.asm` @a9ff / TimerEffect_02 | **done** |
| 68 | Party Regen Cmd_19 + CheckRegen Fusoya | `cmd.asm` @e3fd / `battle.asm` @ffb4 | **done** |
| 69 | CheckCmdReq dark/sing/aim equip gates | `char.asm` @a27e | **done** |
| 70 | Toad/pig spell list filter; hide-only Show cmd | `char.asm` UpdateEnabledCmds | **done** |
| 71 | Float status2 bit6 + Esuna clear | `magic.asm` / DisableCmd kick | **done** |
| 72 | Field UseItem potions/ethers/elixir/apples | `menu/item.asm` @a706 | **done** (lead party target) |
| 73 | Field status items `$D5–$DC` / Life / Panacea | `item.asm` ItemStatusMaskTbl | **done** |
| 74 | Field item party target select | item menu | **done** |
| 75 | Shop buy + EventCmd `$ED` | `shop.asm` / `event.asm` | **done** |
| 76 | ItemPrice encode (×10 / ×1000) + sell | `shop.asm` @c4d8 | **done** |
| 77 | Shop sell UI (L/R buy/sell mode) | `shop.asm` ConfirmSell | **done** |
| 78 | Field Status / Magic view / Equip / Order | menu equip/status/magic/order | **done** (subset) |
| 79 | DoRetal via GetMonsterAttack + magic/fight | `retal.asm` + AI | **done** (AI script path; dedicated $531f banks optional) |
| 80 | ItemClasses equip check (job mask) | `equip.asm` CheckClassEquip | **done** |
| 81 | Save slots `saves/slotN.sav` | `save.asm` ShowSaveMenu | **done** (4 slots, compact blob) |
| 82 | Field magic cast (heal/esuna) | `menu/magic.asm` UseMagic | **done** (field subset) |
| 83 | Multi-target via AttackProp expandTargets | `magic.asm` | **done** (spell target field 2/6/7) |

### Process
1. Find decomp symbol  
2. Read **callers**, not only data tables  
3. Port that path; mark checklist item done  

Expand by porting the named decomp routine; do not invent alternate systems.
