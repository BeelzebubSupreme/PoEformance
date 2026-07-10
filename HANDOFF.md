# Session handoff — where to pick up

**Read this first, then the matching CLAUDE.md / CHANGELOG.md sections for detail.**

- **Branch:** `PoEfdev/autopilot-pathing` (dev branch — owns the version; only ever push this, never `master`/upstream).
- **Version:** `0.45.13.336`
- **Sync on the other machine:** `git pull origin PoEfdev/autopilot-pathing`, then reload the AHK tool.
- **Upstream:** imm0r **merged our feature work** (camera-zoom, data-dict regen, autopilot/combat) into `imm0r/PoEformance`. We keep developing on the dev branch as before.

---

## Shipped THIS session (0.45.13.330 → .335) — ALL need in-game verification

- **`.330` Combat Assist mode** — "you move (WASD), the tool targets + fires + auto-dodges." Independent toggle `g_combatAssistMode` (bridge `ToggleCombatAssist`); runs combat with every click-to-move suppressed. **TEST:** enable, run a map on WASD — it should aim + fire but never steer you.
- **`.331` Blank/disconnected-launch fix + GGPK auto-refresh crash-loop fix.** Top Refresh is now a full reconnect+re-push; `PageReady` re-pushes state; GGPK auto-refresh only runs while the game is CLOSED. **TEST:** launch several times (no blank UI; if blank, one Refresh click recovers; no ~8 s freeze; error.log clean of the poe-data-extract crash).
- **`d56542c` Serpentine exploration + denser sampling** — fixes "random running / backtrack to start." **TEST:** watch a full clear — methodical back-and-forth sweep, starts near entry, no trek-back.
- **`.333` "🌳 Dump UI Tree" RE probe** — NOTE: redundant with the existing `debug/ui_tree_*.tsv` dumper; can retire later.
- **`.334/.335` Vaal Ruins Route Planner prototype** — see below.

## Vaal Ruins Route Planner (IN PROGRESS — advisory only, no memory writes)

- **Solver core: DONE + tested (9/9).** Doorway-matching connectivity BFS, dead-room detection, weighted scorer (connectedValue/synergy/survivability/targetReach/crystalEff/expansion), 3 presets, placement ranking, greedy hand planner. **Canonical copy is INLINED in `ui/vaal_ruins_planner.html`** (the standalone `temple_solver.js` lived in a session scratchpad and does NOT transfer — the repo prototype carries the solver).
- **Manual prototype: `ui/vaal_ruins_planner.html`** — open in a browser. Grid editor + solver output (connectivity highlight, DEAD-room flags, score breakdown, presets, auto-plan over a hand). Hand accepts room names. **Free 4-way doorway toggle is a STOPGAP.**
- **Key RE findings:**
  - Mechanic is internally **Incursion** (Vaal Ruins = reworked Temple of Atzoatl).
  - Budget counter UI element: `incursion_temple_tokens` shows `N/60`.
  - `DoryaniIncursionHub` / `AlvaIncursionHub` / `HubInteractible` in the UI tree are **UI elements, not world entities** → "Dump Components" returns blank on them.
  - Board data is **NOT in the UI tree** (only tooltip text) → it lives in **ServerData**.
  - GameHelper2 reference has **no** incursion code (no shortcut).
  - Tiles have **fixed doorway patterns per room (+ likely rotation)**, not free 4-way — the connection rules still need a real data source.
- **Next steps (two tracks):**
  1. **GGPK static extraction (recommended first):** add an incursion-room extractor/inspector to `ggpk-tools/PoeDataExtract` (like the `.tsv` dictionaries) to pull each room's door pattern / tier / value from a PoE1-style `IncursionRoom` table. Find the table name first via the extractor's `inspect` verb. This answers "how do the tiles connect."
  2. **ServerData Incursion probe:** RE the live board (rooms / positions / tiers / doorways) using the `N/60` token as the live anchor in the Memory Dissector.
  3. Then **inline the prototype into `ui/index.html` as a tab** and wire the memory adapter behind the existing solver interface.

## Open / unconfirmed threads

- **Chest bug:** rare chests reportedly not opening (magic is skipped by design — `rareOnly` default). Suspect the **rarity offset drifted after the 4.5.4.3 patch** → `ReadEntityRarityId` returns the wrong id for rare chests ([ahk/ChestOpen.ahk:325](ahk/ChestOpen.ahk)). Cross-check: do rare-monster rings still render? UNTESTED.
- **Instant skill→key mapping hunt** (carried from prior session; owner leaned "the learner is fine"): skill gems live in position-ordered inventories and the gem base path IS the skill, but PoE2 weapon-swap means multiple loadouts and position→key is unmapped. If revisited: one probe that resolves every gem-inventory position→skill, reads live bar keys, and correlates the active bar. RE tools: `🎯 Skill-bar Array Hunt`, `💎 Skill-gem / Server Probe`, `🔗 Skill↔Slot Link`.

## Non-code context
- **Camera zoom** is applied to the GGPK via `ggpk-tools/PoePatcher` (native, reversible via the UI toggle). `oo2core.dll` is user-supplied and intentionally NOT in git.
- Owner is a native German speaker; **repo/commits/PRs stay English**, chat may be German.

## Testing / tooling reminders
- **Validate AHK via PowerShell, not git-bash** — git-bash mangles the `/validate` flag into a bogus path (`C:/Program Files/Git/validate`) and pops a modal. Use: `& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "/ErrorStdOut" "/validate" "<file>"`. Also: validating a single `#Include` module standalone raises false `LocalSameAsGlobal`/VarUnset warnings for cross-module functions (e.g. `LogError`) — not real errors.
- Never `Stop-Process AutoHotkey64` (can kill the owner's running tool).
- UI: extract inline `<script>` and `node --check`; keep `<div>` balance unchanged. Preserve line endings (CRLF: BridgeDispatch.ahk, WebViewBridge.ahk; LF: everything else). Bump the version in all three files each change.

---

## What to tell the other PC
```
git pull origin PoEfdev/autopilot-pathing
```
Then reload the AHK tool. To use the Vaal Ruins planner, open `ui/vaal_ruins_planner.html` in a browser.
