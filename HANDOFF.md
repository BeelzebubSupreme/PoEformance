# Session handoff — where to pick up

**Read this first, then read the matching CLAUDE.md sections for full detail.**

- **Branch:** `PoEfdev/autopilot-pathing` (dev branch — owns the version; merge onto `master` locally later).
- **Version:** `0.45.13.329`
- **Sync on the other machine:** `git pull origin PoEfdev/autopilot-pathing`, then reload the AHK tool.
- Repo layout is the two-folder workflow (master reference clone + this dev clone). Only ever push the dev branch; never push to `master`/upstream. See the memory `two-folder-git-workflow`.

---

## Shipped this session (0.45.13.322 → .329)

### AutoPilot exploration — re-exploring / circling (VERIFIED FIXED in-game)
- `.327` — region-completion no longer does a full plan rebuild; it **filters the plan in place**
  (keeps tour order + forward progress) and recounts coverage fresh. Confirmed in the status log:
  clean single tour, coverage climbs monotonically, no backward jumps.
- `.328` — follow-up: `_FindNearestFrontier`/`_CheckFrontierCell` now **reject off-floor frontiers**
  so the bot stops standing still grinding an unreachable upper storey (`off-floor-skip` stall).
  → **Pending owner re-test** on a multi-level map (should have no long off-floor stalls).
- CLAUDE.md: "Exploration: region-completion plan rebuild…" + "reject off-floor frontiers".

### Loot filter (`.329`)
- **Gems now picked up** — new "Gems" pickup category (default ON), matched by path
  (`Metadata/Items/Gem[s]/…`). Fixes "not picking up skill/support gems" (they carried no rarity
  → were classified Normal → filtered).
- **"picking up magic" = defaults, not a bug** — config had no `[LootPickup]` section, so Magic was
  ON by default. Owner just needs to uncheck Magic (now persists).
- Pickup status log now shows the item base-name: `pickup(<rarity> … [<BaseName>])` — a built-in
  diagnostic for any remaining mis-classification.
- → **Pending owner re-test:** uncheck Magic (confirm `[LootPickup]` gets written), confirm gems
  collected (`pickup(Gems …)`). If normal/magic still get grabbed, the `[BaseName]` tag pins whether
  it's a `ReadItemRarity` offset drift (Mods 0x94 / OMP 0x144) vs. just the default.
- CLAUDE.md: "Loot filter: Gems category + Magic-on-by-default diagnosis".

### Combat auto-config / skill-bar mapping
- `.322–.323` — fast-poll **learner**: the skill-bar slot's ActiveSkill ptr (+0x2F0) is only live
  WHILE a skill is mid-cast, so a throttled learner missed it. Now caches the 8 slot addrs and
  fast-polls +0x2F0 every ~150 ms → learns each skill as it's cast. Persists to `[SkillBarLearned]`.
  Owner confirmed auto-config works after this.
- `.326` — **seamless auto-apply**: `g_combatRotationAuto` (default ON) rebuilds the rotation as
  skills are learned, no button click; a hand-edit latches `g_combatRotationUserEdited` to stop
  overwriting (auto-config click re-enables). This is the **public-grade solution**.

---

## OPEN THREAD — instant (zero-play) skill→key mapping hunt (owner opted "keep hunting")

Goal: map skill-bar slot → skill WITHOUT needing the learner (truly instant). Status: **ruled out**
the UI tree, player entity, Actor, all components, GameUI, ActiveSkillsDat ptr, and PlayerServerData
(no equipped-skill pointers anywhere; the UI slot only holds the transient cast ptr + graphics).

**Best remaining lead (from the last `SkillGemProbe` run):** skill gems ARE in **position-ordered
inventories** — e.g. inv id=47 held gems at x=0..4 (`SkillGemEntangle`, `SkillGemContagion`, …), and
the **gem base path IS the skill** (no granted-effect resolution needed). BUT:
1. inv 47 didn't match the *active* bar (looked like a stored/weapon-set loadout) — PoE2 weapon-swap
   means multiple gem loadouts; need to correlate which is live.
2. Inventory type labels are wrong (id 47 mislabeled "HeistNpcEquipment2").
3. Position → keyboard key still unmapped (5 gems at x=0..4 vs 8 bar slots incl. 3 mouse).

**Next concrete step IF continuing:** one probe that resolves every gem-inventory's positions→skill
names, reads the live UI bar keys (`ReadSkillBarHotkeys`), and cross-references to (a) identify the
active-bar inventory and (b) derive position→key. If clean → hardcode it, drop the learner. If tangled
by weapon sets → the learner stays the answer (it already works). **Owner leaned toward "the learner
is fine" being an acceptable fallback.** RE tools: `🎯 Skill-bar Array Hunt`, `💎 Skill-gem / Server
Probe`, `🔗 Skill↔Slot Link` (all in the RE-tools row). CLAUDE.md: "Combat rotation: seamless
auto-apply + skill-bar link hunt".

---

## Non-code context
- **Camera zoom** is applied to the GGPK (character.ot + all camerazoom scene nodes = 1.9×) via the
  owner's own `ggpk-tools/PoePatcher`. The pulsing fix is done. Don't re-apply; use the UI toggle to
  change/revert. `oo2core.dll` is user-supplied and intentionally NOT in git.
- Owner runs a 3rd-party "POE 2 Assistant" bundle separately (its `DrYmEydV.exe` launcher) — unrelated
  to this repo; flagged as untrusted but owner confirmed they use it.

## Testing / tooling reminders (from CLAUDE.md)
- Validate AHK via **PowerShell**, not git-bash: `cmd /c '"…AutoHotkey64.exe" /ErrorStdOut /validate "…InGameStateMonitor.ahk" & echo EXITCODE=%errorlevel%'` (exit 0 = OK). Git-bash mangles `/ErrorStdOut` and hangs on a modal.
- Never `Stop-Process AutoHotkey64` (can kill the owner's running tool).
- UI: extract inline `<script>` and `node --check`. Bump version in all three files each change.
