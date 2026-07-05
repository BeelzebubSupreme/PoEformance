# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.13.177`.

## Language

**All written output must be in English.** That includes:

- Source code (variable names, function names, file names)
- Code comments (block comments, line comments, docstrings)
- Git commit messages
- Pull-request titles, descriptions, review comments
- Issue text on GitHub
- Any other artifact that ends up on GitHub or in the repo

Chat replies inside the editor may use whatever language the user is
writing in (German is fine), but the moment something gets committed
or posted to GitHub, switch to English.

The user is a native German speaker but explicitly wants the project
to stay in English so future contributors / public review aren't
blocked by language. Don't ask for translation help — just translate
inline when authoring commit messages, PR bodies, etc.

## Working rules

- **Never guess.** When unclear, first check the C# reference project (below); ask a
  clarifying question before doing extensive work.
- **Plan first** for larger tasks, then break them into small, verifiable steps.
- **Performance matters** — keep the per-frame render / radar hot path (every ~50–100 ms)
  as cheap as possible.
- Keep files small; split into new `*.ahk` modules via `#Include` when a single file grows
  substantially.
- New functions get a short 2-3 line comment explaining purpose, parameters, and return value.
- Variable names follow the existing camelCase / snake_case style of surrounding code.
- The user often cannot runtime-test (the game is ~140 GB). When a change can only be
  verified in-game, say so and list exactly what to check.
- **Bump the version after every change.** Increment the last segment of the version
  number on each adjustment — in **all three** of `InGameStateMonitor.ahk`
  (`POEFORMANCE_VERSION := "x.y.z.N"`), `CLAUDE.md` (the `Version` line above), and
  `README.md` (the `version-vX.Y.Z.N` badge), e.g. `0.45.12.2` → `0.45.12.3`. Keep all
  three in sync. **The dev branch owns the version** — it is the single source of truth.
  Always count up from the dev branch's own latest value; never reset it to match
  `master`. `master` is not bumped independently, so on merge the dev-branch version
  always wins (resolve any version-line conflict by taking the dev-branch value).
- **Always end a reply that committed & pushed with the exact pull command** so the
  user can grab it locally, e.g. `git pull origin <current-dev-branch>`. Every time a
  change is pushed — no exceptions. The user merges the dev branch onto `master`
  themselves later, so only ever hand them the dev-branch pull — never merge to
  `master` or push there yourself.
  **Never add the current AI Session to the end of the commit message** — Skip the entire line (e.g. "https://claude.ai/code/session_123456789abcdef")

### Completion-summary format (lean, GitHub-ready)
When wrapping up a task, output the summary as ONE copyable raw GitHub-flavored
markdown block (a fenced ```` ```markdown ```` code block), so it can be pasted
straight into a PR/issue/commit. Because it is destined for GitHub, write it in
**English** (per the Language rules above). Use this fixed, lean structure and
show only the sections that have content — never pad with empty headings:

- **Summary** — one sentence on what was achieved.
- **Changes** — bullet list, `path/file.ext:line — what & why`.
- **Advices** — everything the needs to know about how the changes work.
- **Open / Next steps** only when actually relevant. Any prose outside the block
(chat commentary) may stay German.

## Project structure & conventions

- **Entry point:** `InGameStateMonitor.ahk` (repo root). Run with **AutoHotkey v2**.
- **All other `.ahk` files live in `ahk/`.**
- **UI:** `ui/index.html` — one self-contained file with a single inline `<script>`,
  rendered in a WebView2 control.
- **Sounds:** alert `.wav` files live in the root **`wav/`** folder.
- **Logs:** `.log` files live in the root **`logs/`** folder.
- **Data:** `.tsv` files needed for translating internal strings by using a dictionary live in the root **`data/`** folder.
- **Tools:** `.py` files needed for building the dictionaries live in the root **`tools/`** folder.
  (All repo folders are lowercase except `Lib/` — keep new paths lowercase, or a
  `Tools/` vs `tools/` case-collision breaks checkout on case-insensitive Windows/macOS.)

### Include conventions
- `InGameStateMonitor.ahk` includes with the `ahk/` prefix, e.g. `#Include ahk/RadarOverlay.ahk`.
- Files inside `ahk/` include each other with bare names, e.g. `#Include EntityFacts.ahk`.

### ⚠️ AHK v2 gotcha — module init (read before adding globals)
Feature modules are `#Include`d at the **bottom** of `InGameStateMonitor.ahk` (after the
auto-execute `return`, ~line 437). Function/class definitions still work, but **top-level
`global x := value` initializers in those modules never run.**

→ **Initialize every module global inside a `Load…()` / init function the main script calls
before its `return`** (see `LoadEntityGroups()`, `LoadEntityAlertsConfig()` around line ~295).
Seed defaults **unconditionally** (defaults first, then optionally overlay from INI). The
symptom of getting this wrong is the runtime error *"This global variable has not been
assigned a value."*

### Persistence (self-persist pattern, like LootPickup)
Each module owns its INI section: Groups → `poeformance_config.ini [Groups]`;
Alerts → `alerts.ini [Alerts]`.

### AHK ↔ WebView bridge
- AHK → JS: `PushHeaderToWebView()` builds a JSON header and calls `updateHeader(...)`.
- JS → AHK: UI calls `ahkCall(name, ...args)`, dispatched in `ahk/BridgeDispatch.ahk`.

### Line endings (preserve per file when editing)
- **CRLF:** `BridgeDispatch.ahk`, `WebViewBridge.ahk`. **LF:** everything else.

### Static verification (no game needed)
- AHK: brace balance per file; confirm edit anchors match exactly once.
- UI: extract the inline `<script>` and run `node --check`; keep `<div>` balance unchanged.

## Feature update — path-based Groups + Alert engine + overlay base

### New files (`ahk/`)
- **EntityFacts.ahk** — `ExtractMetaGroup(path)`, `ReadEntityRarityId(decoded)` (max of flat +
  nested `mods`/`objectmagicproperties`), `RarityIdToName(id)`. Used by SnapshotSerializers,
  EntityGroups, EntityAlerts.
- **EntityGroups.ahk** — `g_entityGroups`; resolve group by path/metaGroup,
  `GroupColorToBgr(#RRGGBB)`, `_ApplyEntityGroups`, `BuildGroupsHeaderJson`,
  `Save/LoadEntityGroups` (self-persist `[Groups]`).
- **EntityAlerts.ahk** — per-tick alert engine off the radar snapshot, run after AutoPilot,
  outside the "claim the tick" chain. Town/hideout suppression, per-area reset via
  `currentAreaHash`, severity ranking, zone-entry + proximity (cooldown) timing, and
  banner / sound / window-flash / radar-highlight / log outputs. WAV list from `wav/`.
  Self-persist `[Alerts]` in `alerts.ini`.
- **EntityJunkFilter.ahk** — global path-based junk suppressor ported from the C#
  `JunkFilter` (6 categories: cosmetic / engine / daemon / pets / markers / hideout doodads;
  "weapons/" deliberately dropped). `IsJunkEntity(path)` is hooked once at the sample chokepoint
  (`CollectEntityMapCandidates`, before `candidates.Push`) so radar / browser / trees /
  exports / AutoPilot all skip junk. Master + per-category + per-pattern toggles + custom
  terms; active patterns precomputed in `g_junkActive` via `RebuildJunkActive()` (cheap
  case-insensitive `InStr` per entity). `_ApplyJunkSetting` / `BuildJunkFilterHeaderJson` /
  `Save/LoadEntityJunkFilter` (self-persist `[JunkFilter]`). Dispatch `SetJunk` (keys
  `enabled` | `cat:<key>` bulk enable/disable-all | `pat:<pattern>` | `custom`); header key
  `junkFilter`; UI is a wrapping row (`.ent-boxes`) of collapsible boxes at the top of the
  **Entities** tab: Entity Classes (the global type filter, moved here from Config) and
  Junk Filter (`#ent-junkbox`). The Junk Filter box holds ALL of it: the built-in categories
  (`#junk-cats`, incl. the hideout-doodad category) **and** the Custom Terms section (add box +
  deletable chips) in its body — the former standalone Hideout / Custom Terms boxes are gone.
  Each junk category renders (via `junkCatRow`) as a collapsible `<details class="junk-cat">`
  with a cube/diamond caret (closed/open); the same caret is on each top box's
  `.ent-junkbox-sum` (its master toggle is a compact variant so the collapsed box matches its
  siblings). Categories have NO on/off slider of their own: the summary holds the name (in a
  `.junk-cat-titlerow`) plus a one-line `.junk-cat-desc` explanation (from `_junkCatInfo`) —
  both in the summary so the description stays visible whether the category is collapsed or
  expanded; the cube/diamond caret is centred over the whole summary. The body is a wrap of per-pattern `.filter-pill` buttons
  (each toggles its own pattern via `pat:`, pill colour conveys state) followed by a trailing `.junk-all`
  "enable/disable all" button that bulk-flips every pattern in the category (`cat:<key>`, a
  shortcut over the per-pattern flags — there is no separate category gate). A `.ent-junk-sep`
  spacer sits between the last category (Hideout) and the Custom Terms section. Only the Junk
  Filter box master switch gates the whole feature.
  Open categories are remembered in `_junkOpenCats` (updated from each `<details>`' `ontoggle`)
  and `junkRenderCats` only rewrites a host's innerHTML when the markup changed — so the
  periodic header push no longer snaps expanded categories shut. The fast radar path builds the awake
  sample from `_radarEntityCache` in `UpdateRadarFast` (not `CollectEntityMapCandidates`), so the
  junk filter is ALSO applied there at the awake-sample build. Default ON, all categories on.
- **GdiOverlayBase.ahk** — reusable transparent, click-through, always-on-top GDI layer
  (cached pens/brushes/fonts, double-buffered blit). Used only by NotificationOverlay so far;
  VitalsOverlay / RadarOverlay are NOT yet migrated to it.
- **NotificationOverlay.ahk** — `extends GdiOverlayBase`; map-independent banner layer.
  `SetBanner(text, ms, colorBGR)`; `Tick()` self-resolves the PoE window, foreground-gated,
  hides when idle.

### Edited files
- **SnapshotSerializers.ahk** — rarity via `ReadEntityRarityId`; emit `metaGroup` + `metaCategory` + `group` per entity.
- **PoE2MemoryReader.ahk** — expose `currentAreaHash` in the radar snapshot Map.
- **AutoFlask.ahk** — `g_notifyOverlay` in the UpdateRadarFast globals; after `TryAutoPilot`,
  call `TryEntityAlerts(radarSnap)` and `g_notifyOverlay.Tick()`.
- **BridgeDispatch.ahk** — `SetGroups` and `SetAlert` cases (apply, persist, refresh header).
- **WebViewBridge.ahk** — add `groups` + `alerts` to the header push.
- **RadarOverlay.ahk** — group-color override: a matching path group wins over the type color.
- **TreeViewWatchlistPanel.ahk** — include EntityFacts / EntityGroups / EntityAlerts.
- **InGameStateMonitor.ahk** — include GdiOverlayBase + NotificationOverlay; `g_notifyOverlay := 0`;
  extend `g_cfgOpenSections` default with `al-conditions,al-timing,al-output`;
  call `LoadEntityGroups()` + `LoadEntityAlertsConfig()` at startup.
- **ui/index.html** — Groups tab (editor, filter, colored pill, shared GGPK color picker,
  pill toggles) and Alerts tab (collapsible Config-style sections, conditional visibility,
  pill toggles, WAV dropdown). The GGPK maphack picker `openColorPicker(which, opts)` was
  generalized so Groups reuses it.

### UI conventions
- Collapsible sections: `.cfg-section > <details> > <summary><div class="cfg-header">` with
  `.cfg-subsection` / `.cfg-row` / `.cfg-label` inside.
- Boolean options use the themed pill toggle (`<label class="toggle"> … <span class="toggle-slider">`).
- Theme text font is `var(--codex-serif)` (labels 13px, `var(--codex-text)`).
- Section open/closed state persists via `_cfgSectionIds` + `syncCfgSections()` → `g_cfgOpenSections`.

### Recent bugfix
- `LoadEntityAlertsConfig()` now seeds all 24 alert globals (and `g_alertsConfigFile`)
  unconditionally before reading the INI — fixes "global not assigned" on a fresh install
  (see the AHK v2 init gotcha).

## Local HTTP API + MCP server (AI assistant integration)

Opt-in feature that lets an external Model-Context-Protocol server (and thus an AI
assistant) read live game data and change settings. Inspired by
NattKh/POE2Radar's `mcp-server` — but PoEformance had no HTTP server, so this adds
both halves.

- **`ahk/LocalApiServer.ahk`** — a tiny HTTP server on `127.0.0.1` (default port
  7777). Winsock + `WSAAsyncSelect`; socket events arrive as window messages on a
  hidden Gui and are dispatched via `OnMessage` on the main thread, so the radar
  hot path is never blocked and reads of `g_radarLastSnap` stay consistent.
  Off by default. `LoadLocalApiConfig()` seeds all globals **and** the `LOCALAPI_*`
  Winsock constants unconditionally (init gotcha). Self-persists `[LocalApi]`
  (`enabled`, `port`) in `poeformance_config.ini`. Endpoints: `GET /state`,
  `GET /entities`, `GET|POST /api/groups`, `GET|POST /api/alerts`,
  `GET|POST /api/config`, `GET|POST|DELETE /api/watchlist`, `GET /api/names`.
  Reads pull from the snapshot / existing `_Build*Json`; writes route through the
  existing bridge commands (`_DispatchBridgeCall`) so side effects + persistence
  match the UI exactly.
- **`mcp-server/`** — Node MCP server (`index.js`, `package.json`, `README.md`)
  that proxies the HTTP API. Tools: `game_state`, `get_entities`, `get_groups`/
  `set_groups`/`add_group`/`remove_group`, `get_alerts`/`set_alert`,
  `get_config`/`update_config`, watchlist tools, `search_names`. Run `npm install`
  in `mcp-server/`; `node_modules` is gitignored.
- **Wiring:** `InGameStateMonitor.ahk` includes the module, seeds
  `g_localApiEnabled`/`g_localApiPort`, calls `LoadLocalApiConfig()`, and
  `StartLocalApiServer()`/`StopLocalApiServer()` (OnExit). `BridgeDispatch.ahk` has
  a `ToggleLocalApi` case; `WebViewBridge.ahk` pushes `localApi`/`localApiPort` in
  the header; `ui/index.html` has the toggle in **Config → General → Integrations**
  (section id `integrations`).
- **Verified in-game (2026-06-24):** the Winsock listener binds, `OnMessage` fires for the
  hidden Gui, request/response round-trips work, and the config toggle starts/stops the server.
  The listener only starts at app launch, so toggling on requires a restart.

## AutoPilot navigation (v0.45.12.0) — distance-field architecture

Modeled on `myrahz/Radar` (`PathFinder.cs`): never follow a stored path.

**Verified in-game (2026-06-24):** exploration + combat navigation work end-to-end (click
projection / anchor gating, per-tick distance-field pathing, arrival + stuck handling).

- **`Lib/TerrainPathfinder.ahk` — `DField*` methods:** per target, a
  Dijkstra/A* cost field is flooded FROM the target (time-sliced,
  `DFieldExpand(budgetMs, pgx, pgy)`, Chebyshev heuristic toward the player,
  same walkable + height rules as `FindPath`). Every click tick reads a
  FRESH path from the CURRENT player position by walking downhill
  (`DFieldPathFrom`) — stale paths / index stalls / backward clicks are
  impossible by construction. `DFieldDistCells` = live remaining distance
  (arrival check + watchdog metric).
- **`ahk/ClickNav.ahk` (new, stateless):** shared projection/click toolkit
  for exploration AND combat. `NavAnchor` — the player must project near
  the screen centre (else the matrix is stale → no clicks at all,
  reason `cam-bad`) and its w sign defines "in front of the camera".
  `NavProject` (unclamped, visSign rejection), `NavRayClamp`
  (direction-true edge clamping along the player ray — never per-axis),
  `NavValidateClick` (avoid-zone kinds + HUD rescue + near veto),
  `NavPickClickPoint` (~35 cells along the fresh path, backing off toward
  the player), `NavClickAt`.
- **CombatAutomation:** anchor gate per tick; walk-engage aims ~25 cells
  along the per-tick A* path with the PLAYER's Z. (The old farthest-LoS
  waypoint used the enemy's Z and no w-sign check — waypoints behind the
  camera plane projected point-MIRRORED and the bot walked away from
  enemies in stutter steps.)
- **ExplorationModule:** plan/frontier/sticky-target/floor-gate/region kept;
  the whole stored-path block (snap-forward, LOOKAHEAD scans, near-skip
  gate, direct-click fallback) is gone. New reasons: `routing(…)` while the
  field floods (stuck detection paused then), `cam-bad(…)`,
  `ui-blocked(… d=N prj/hud/map/ent/near)`, `click(… d=N ahead=M)`.

## LootTracker (map-run / session loot tracker) — port of GameHelper2 `yokkenUA/LootTracker`

Reimplements the C# plugin in AHK v2 + WebView. Times each map run (paused in
town/hideout, resumed by instance hash), diffs the backpack against a per-run baseline
for net loot, prices it via poe.ninja (Exalted/Divine), tallies kills per rarity, and
keeps an on-disk session history. Reuses the existing inventory reader / radar snapshot /
area-state instead of re-reading memory.

### New files (`ahk/`)
- **LootTracker.ahk** — run state machine + per-tick entry `TryLootTrackerTick(radarSnap)`
  (runs in `UpdateRadarFast` right after `TryEntityAlerts`, self-throttled), session
  totals, valuation, the cached display model `g_ltLiveView` (rebuilt ~4 Hz, read by the
  overlays + WebView), `BuildLootHeaderJson` (settings), `PushLootLiveToWebView` (1 Hz live
  push → JS `updateLootLive`), `_LtApplySetting`, self-persist `[LootTracker]` in
  `poeformance_config.ini`. Seeds ALL run + kill globals in `LoadLootTracker()`.
- **LootTrackerInventory.ahk** — backpack (inventoryId==1) snapshot → `Map(itemKey→count)`
  via `ReadAllPlayerInventories` (deduped by item entity ptr — the reader returns one entry
  per occupied slot). Composite key `<rarityDigit><US><path>[<US><renderArt>]` (US=`Chr(31)`,
  a **function-local**, never a module global — init gotcha). `_LtDiff`/`_LtMergeInto`/`_LtValueOf`.
- **LootTrackerKills.ahk** — per-run kill tally that **mirrors the radar reader's own
  death detection** instead of re-scanning the sample. The reader filters dead entities
  OUT of `awakeEntities.sample` before LootTracker sees it (corpses must not show on the
  radar), so deaths are never observable there — every sample-based heuristic
  (`life.isAlive`, IsTargetable, despawn) read `dead=0`. Fix: `PoE2MemoryReader` keeps a
  per-area `_radarKillsByRarity` `[N,M,R,U]` tally, incremented by `_RecordRadarKill` at
  the two blacklist sites in `_FilterStaleRadarEntities` (signal-5 targetable-dead timer +
  the hard-dead signals 1/2/3, monster-gated to entities we saw alive). Friendly monsters
  (own minions / spectres / totems / allies) are tracked in `_friendlyAddrs` and skipped,
  matching the C# reference's `MonsterFriendly` exclusion. The counter resets
  on area change; `_LtScanKills` accumulates per-area DELTAS into `g_ltCurrent["kills"]`
  (`g_ltKillLastR` baseline, re-zeroed on every zone transition via `_LtResetKillTally`),
  throttled ~150 ms.
- **LootTrackerSessions.ahk** — JSON session history in `sessions/` (`session_<A_Now>.json`,
  JsonFull), trim to `maxSessions`, summary/detail/delete + WebView pushes.
- **LootPricing.ahk** — poe.ninja price layer. The HTTP fetch + multi-MB JSON reduction runs
  in a **PowerShell child process** (`tools/poe_ninja_prices.ps1`) so the radar hot path is
  never blocked; the child writes a small TSV (`data/loot_prices.tsv`) loaded cheaply.
  Spawn → poll `ProcessExist` → load TSV. `metaId→art` bridge `data/meta_art_map.json`,
  `_LtPriceKey`/`_LtTryPriceItem`/`_LtRarityVariant` (per-rarity tablet + unique render-art
  keys). Seeds globals in `LoadLootPricing()` (gates the startup refresh on `g_ltEnabled`).
- **LootTrackerOverlay.ahk** — two `GdiOverlayBase` subclasses registered with the
  `OverlayManager`: `LootMapStripOverlay` (slim strip on maps) + `LootCompactBarOverlay`
  (hideout session bar, hidden while a large panel is open via `panelVisibility.anyPanelOpen`).
  Bypass the play gate like NotificationOverlay; render from `g_ltLiveView` (live timer fresh
  each frame). Text/glyph only — no PNG icons (GdiOverlayBase has no image blit).

### Edited files
- **InGameStateMonitor.ahk** — `#Include` the modules (overlay before `OverlayManager`);
  `LoadLootTracker()` + `LoadLootPricing()` before `LoadOverlaySystem()`; version bump.
- **OverlayManager.ahk** — register the two loot bars.
- **PoE2MemoryReader.ahk** — per-area `_radarKillsByRarity` tally + `_RecordRadarKill`,
  populated from `_FilterStaleRadarEntities` (exposes the radar's own kill detection so
  LootTracker can count kills the sample can't reveal).
- **AutoFlask.ahk** — `TryLootTrackerTick(radarSnap)` after `TryEntityAlerts`.
- **BridgeDispatch.ahk** — `SetLootConfig` / `LootNewSession` / `LootRefreshPrices` /
  `LootLoadSessions` / `LootSessionDetail` / `LootDeleteSession` / `LootRequestLive`.
- **WebViewBridge.ahk** — `loot` settings block in the header push.
- **ui/index.html** — new **Loot** tab (live readout, session table, **valuable-drops
  breakdown** `#lt-items`, settings, price status, session history) + `lootSyncFromHeader` /
  `updateLootLive` / `updateLootSessions` / `updateLootSessionDetail`.

### Valuable-drops breakdown (session item list)
- `_LtAggregateSessionGained()` folds every run's banked `gained` + the current run's live
  leg (`g_ltLiveLegDelta`) into one `Map(itemKey→count)`; `_LtBuildItemRows()` prices each
  via `_LtTryPriceItem`, keeps the net-positive PRICED rows worth ≥ 0.5 ex (so nothing
  that would render as "0 ex" clutters the list), sorts by total value desc, caps to 60. Pushed as `items` in `_LtLiveViewJson` and rendered
  as a 4-col `lt-tbl` (Item · × · Each · Total) in `updateLootLive`. Unpriced items
  (most rares/magics — poe.ninja has no price) are omitted by design.

### Shipped data / gitignore
- `data/meta_art_map.json` (the 1446-entry metaId→art bridge) is committed source data.
- `sessions/` and `data/loot_prices.tsv*` are user-specific/generated → gitignored.

### Verified in-game (2026-06-24)
- Confirmed: the PowerShell fetch (league slug, network, PS), TSV parse, Divine→Exalted rate;
  the inventory diff / kill counts; run resume-by-hash; the two bars' placement/auto-hide;
  session save/load. Prices default OFF (feature `enabled=false`).
- The on-screen bars anchor to the game-window bottom + offset (no XP-bar fingerprint walk
  yet — a possible later refinement, like the C# original's `TryGetExperienceBarRectByFp`).

## StashMover ("dump backpack to open container")

Simulates Ctrl+Click on every backpack item so the game moves them into whatever
container is currently open (stash tab, vendor sell window, trade window, gambling
window). Triggered by a configurable hotkey AND an on-screen overlay button drawn
next to the inventory grid. All data is already reverse-engineered: backpack items +
grid cells from `ReadAllPlayerInventories` (id==1), and the inventory grid's screen
rectangle from the UI tree.

### New file
- **`ahk/StashMover.ahk`** — self-contained module.
  - Geometry: `_SmInventoryGridRect()` BFS-finds the `InventoryPanel` UiElement under
    the GameUi root (`_UiBrowser_GetGameUiPtr`), reads `UiTree_GetScreenPos` +
    `UnscaledSize`, and converts to ABSOLUTE screen pixels via `NavClientRect`
    (`screenPx = clientOrigin + uiPos * clientHeight/1600`), mirroring the conversion
    in `UiBrowserHandler`. Cell pitch = panel size / backpack `totalBoxesX/Y`; the
    per-item click point is the geometric centre of its `slotStart..slotEnd` rect.
    Manual `offsetX/offsetY` (px) calibration is added to the origin for fine-tuning.
  - Click engine: NON-BLOCKING sequencer — Ctrl held down (`keybd_event` VK 0xA2,
    UIPI-bypass), one item per `_SmStep` timer tick (`SetCursorPos` + short left
    `mouse_event` click), re-armed after `perItemDelayMs`; aborts + releases Ctrl on
    focus loss. Click points are precomputed up front (grid cells are stable as items
    leave) and deduped by item pointer. Activates the PoE window first on the hotkey
    path; the overlay button is `WS_EX_NOACTIVATE` so it never steals foreground.
  - Overlay button: a lazily-built always-on-top, NOACTIVATE Gui (`_SmEnsureGui`) —
    styled like a main header pill ("Radar on"): a dark parchment `Text` face
    (`Background251812`) inset 2px inside the Gui's gilded background (gold `C8A85A`
    border, gold-hi `F0D68A` small-caps label), slim (`_SmBtnW()/_SmBtnH()` = 150×24,
    functions not module globals — init gotcha). Clickable via the Text's Click event
    (`SS_NOTIFY`); a per-context icon + uppercase caption ("▼ DUMP → STASH" gold /
    "$ SELL → VENDOR" amber / "↔ MOVE → TRADE" — `_SmUpdateButtonText` recolours the
    Gui frame + text, amber for a vendor as a "this SELLS" cue). `StashMoverTick(radarSnap)`
    (from `UpdateRadarFast` after `TryLootTrackerTick`) positions it just ABOVE the
    inventory grid, aligned to its left edge (the margin between the equipment panel and
    the backpack grid), and shows/hides it on `_SmActive()` + the matching side enabled +
    game-focus + grid-visibility.
  - Config (per-side split): the feature is split into a STASH half and a SELL half,
    each independently toggleable (`g_smStashEnabled` / `g_smSellEnabled`;
    `_SmActive()` = either on). The options the two sides do NOT share are per-side:
    enable, ignore filter, `perItemMs`, `settleMs`, `offsetX`, `offsetY` (e.g.
    `g_smStashPerItemMs` vs `g_smSellPerItemMs`). Shared: `hotkey`, `showButton`,
    `jitter`. The sell side always sells only normal/magic/rare GEAR — the old
    per-category sell toggles are gone (see below).
    Self-persists `[StashMover]` (`stashEnabled`, `sellEnabled`, `hotkey`, `showButton`,
    `jitter`, `stash*`/`sell*` timing+offsets, `stashIgnore`, `sellIgnore`);
    `LoadStashMover()` seeds ALL globals unconditionally (init gotcha) and migrates the
    pre-split keys (`enabled`/`allowSell`/`perItemDelayMs`/…/`ignore`) as the defaults so
    an existing install carries over. A run picks its side from the detected destination
    via `_SmSideForKind(kind)` (vendor→sell, else stash) and copies that side's timing
    into the run-state `g_smRunPerItemMs`/`g_smRunSettleMs`. Default OFF, hotkey empty.
  - Ignore filters (one per side): `g_smStashIgnore` / `g_smSellIgnore`
    Map(base-type path → display name), built from the live inventory.
    `_SmPushInventory(side)` (bridge `StashRequestInventory side`) reads the backpack
    deduped by path and pushes `updateStashInventory` (with the side echoed back);
    clicking an item toggles `SetStashIgnore(side,path,name,on)`. Persisted in
    `stashIgnore`/`sellIgnore` (RS/US-delimited via `_SmIgnoreSerialize/Deserialize`),
    echoed in the header `stashIgnore`/`sellIgnore` arrays so chips survive a refresh.
    `_SmShouldSkip(item,now,side)` drops the active side's ignored items from the dump.
  - Safety: quest items are ALWAYS auto-skipped (`_SmIsQuestItem` path match — a shipped
    default filter, no toggle; shown as a non-removable 🔒 chip in both ignore lists).
    After a run, `_SmVerify()` (scheduled ~5×perItemDelay after the last
    click so the server inventory has settled) re-reads the backpack; item ptrs still
    present = "failed", recorded in `g_smFailed[ptr]=tick` and skipped for
    `g_smFailCooldownMs` (8 s) so a repeated trigger can't re-hammer an un-stashable
    item. If NOTHING moved it warns (stash full / not stashable) instead of silently
    retrying. Stale failed entries are pruned at each dump start.
  - Randomness (`jitter`, default ON): each click lands at a random offset inside its
    cell (±~12% of a cell), the inter-click delay is `perItemDelay × rand(0.75..1.45)`,
    the settle is `× rand(0.6..1.4)`, and the mouse-down hold is `rand(6..14) ms`.
  - Destination context (stash vs vendor vs trade): same Ctrl+Click action works for
    all of them; `_SmDetectContext()` only refines the label/verb + the sell guard.
    Confirmed in-game (2026-06-23 via the diagnostic): PoE2 uses ONE shared
    trade/stash window with StringId **`NPCBuyWindow`**, hierarchically visible only
    while a stash OR vendor is open. It's a **vendor** when an **`NPCHeader`** is
    visible inside it (an NPC is trading), otherwise the player's **stash**. (The old
    inventory-id-27 signal was wrong — every inventory, incl. id 27, is always
    enumerated, so it always read "stash".) A `_SmScanContextUi()` keyword scan
    (`sell`/`buy`/`vendor`/`purchase`/`gamble`→vendor, `trade`→trade) is the fallback
    for other container windows; else "unknown" (still acts, generic label). Context is
    cached ~700 ms (`_SmRefreshContext`/`_SmCurrentCtx`) for the per-tick button
    caption, detected fresh once per dump. The overlay button reads "Dump → Stash" / "Sell → Vendor" /
    "Move → Trade" / "Dump items"; the result tooltip verb is Stashed/Sold/Moved.
    Selling is gated by the SELL side being enabled: a vendor maps to side "sell", and
    if `g_smSellEnabled` is off the run refuses ("auto selling is disabled") — the new
    per-side replacement for the old `allowSell` switch. Likewise a stash/unknown maps
    to side "stash" and needs `g_smStashEnabled`. Header exposes `context`; the UI shows
    a "Detected destination" readout (vendor shown in amber as it SELLS).
  - Sell side = GEAR only (no per-category toggles): the old `sellGear/Uniques/Currency
    /Maps` pills are removed. Each item is classified by `_SmItemCategory` into `map`
    (path `/maps/` waystones) > `currency` (rarityId 5) > `unique` (rarityId 3/4) >
    `gear` (everything else); the `side="sell"` branch of `_SmShouldSkip` skips anything
    that isn't `gear` (reason "filter"). So only normal/magic/rare gear is auto-sold;
    quest items, uniques, currency and maps/waystones are always kept — shown as
    non-removable 🔒 default chips (JS `_smDefaultChips.sell`) in the sell "Kept base
    types" list (the stash list shows only the 🔒 Quest items chip). The filter is NOT
    applied on side "stash" (stash/trade/unknown dump everything, minus ignore/quest/failed).
  - The "Detected destination" readout refreshes via `_SmRefreshContext(radarSnap)`
    in `StashMoverTick` BEFORE the focus gate (so it updates while the user is in the
    tool), cheap-gated on `panelVisibility.anyPanelOpen`, throttled ~700 ms, pushing
    the header on a kind change. `StashMoverDiagnose()` (bridge `StashMoverDiag`, UI
    "🔍 Diagnose destination") MsgBoxes the live signals — open inventory ids (+grid),
    top-level panel StringIds (visible/hidden), keyword-matched visible StringIds, and
    the detected kind — the RE aid for pinning the real stash/vendor signals in-game.

### Edited files
- **InGameStateMonitor.ahk** — `#Include ahk/StashMover.ahk`; `LoadStashMover()` at
  startup; `RegisterStashMoverHotkey()` after `RegisterCombatHotkey()`; version bump.
- **AutoFlask.ahk** — `StashMoverTick(radarSnap)` after `TryLootTrackerTick`.
- **BridgeDispatch.ahk** — `SetStashMover` (apply → persist → re-bind hotkey),
  `StashMoveDump` (manual trigger), `StashRequestInventory side`, `SetStashIgnore side`,
  `ClearStashIgnore side` (the ignore cases now carry a "stash"/"sell" side arg).
- **WebViewBridge.ahk** — `stashMover` block (incl. the `stashIgnore`/`sellIgnore`
  arrays) in the header push.
- **ui/index.html** — "📦 Stash Mover" section in **Config → Automation**, FIRST
  (before AutoPilot; the orphaned retired-AutoFlask box was removed). Split into two
  equal columns (`.sm-cols` > `.sm-col`, `border-left` divider): LEFT = stashing,
  RIGHT = auto-selling. Each side is its OWN collapsible top box (`<details class="sm-sub
  sm-top" open>` with a gilded `.sm-top-title` summary — "📥 Auto Stashing" / "🛒 Auto
  Selling"), and a third full-width collapsible "⚙️ Shared Options" box sits below the
  columns. Each side box holds its enable toggle, an "Ignore filter" `<details>`
  (`sm-<side>-inv-list` / `sm-<side>-ignore-list`, requested per side via
  `StashRequestInventory '<side>'`) and a "Randomization" `<details>` whose body is a
  single `.sm-rnd-row` (`justify-content:space-between`): per-item + settle delay pinned
  LEFT (`.sm-rnd-group`), grid offset X + Y pinned RIGHT, each a compact stacked
  label-over-input `.sm-rnd-cell`. The sell-category pills are GONE (sell = gear only;
  uniques/currency/maps are non-removable 🔒 default chips in the sell ignore list).
  Shared box: Show overlay button, Randomise toggle, Hotkey, Detected destination,
  Dump/Diagnose. JS: `stashMoverSyncFromHeader` (per-side keys + both ignore arrays),
  `stashRenderIgnore(side)` (prepends `_smDefaultChips[side]` 🔒 chips), `updateStashInventory`
  (reads `d.side`), `smInvToggle(side,i)`, `smIgnoreRemove(side,i)`; `_smIgnore`/`_smInvItems`
  are `{stash,sell}` objects. Settings use the Config-native `.cfg-row`/`.cfg-label`
  layout — NOT the alerts-scoped `.al-*` classes (only styled under `#panel-alerts`).
  The hotkey uses a capture button (`smCaptureHotkey` → reuses the Hotkeys-tab
  `#hk-capture` overlay + `hkKeyName`; builds an AHK hotkey string), not a text field.

### Verified in-game (2026-06-24)
- Confirmed: the `InventoryPanel` StringId resolves and its rect matches the grid; the NOACTIVATE
  button receives clicks without stealing focus, the Ctrl-held click sequence moves items, and the
  timing (`perItemDelayMs`/`settleDelayMs`) is reliable. Remaining tuning notes: the UI→pixel scale
  on non-16:10 windows (height-scale on both axes, no letterbox cull, matching `UiBrowserHandler`;
  a horizontal-cull/per-axis-scale refinement may still be wanted); destination detection is lenient
  (grid-visible + has items); `id==27` is read only as a stash hint.

## Open / pending (needs the game running)

- Verify real alert matches; banner position/size; WAV playback; `FlashWindowEx` struct; the
  `currentAreaHash` zone-change signal; group colors on radar dots.
- Optional deferred refactor: migrate **VitalsOverlay**, then **RadarOverlay**, onto `GdiOverlayBase`.

## Value-aware loot radar (WIP) — `ahk/LootRadarValue.ahk`

Goal: price GROUND loot via the existing poe.ninja layer and surface it — a value label
on each ground-item radar dot, a "valuable nearby" ranked overlay list, and a
banner/sound alert above a threshold. Scope: Currency, Uniques, Waystones,
Fragments/Tablets, Div-Cards (rares stay unpriced, like the LootTracker breakdown).

- **RE: SOLVED (in-game 2026-06-23).** A ground drop is a `Metadata/MiscellaneousObjects/WorldItem`
  WRAPPER entity (rarity 0, no art) whose `WorldItem` component points at **+0x28** to the inner
  ITEM entity (path/rarity/Mods/RenderItem). Chain: wrapper → WorldItem comp → +0x28 → inner.
  `_LrvResolveInnerItem()` finds the comp via `ReadEntityComponentLookupBasic` and tries 0x28
  first (then a 0x08..0xA0 sweep fallback). The inner item then prices via the existing reads
  (`ReadItemRarity` + `ReadItemArtPath` → `_LtArtIdFromDds` → `_LtBuildItemKey` → `_LtTryPriceItem`).
- **poe.ninja coverage caveat:** unique prices only exist on a live temp league. On **Standard**
  poe.ninja returns empty `lines` for unique item types (valid types, no 404 — just no data), so
  uniques stay untagged on Standard; currency/fragments/runes/essences DO price. The fetch
  (`tools/poe_ninja_prices.ps1`) now also requests UniqueWeapons/Armours/Accessories/Flasks.
- **Step 1 (shipped):** the engine + config + alert. `LoadLootRadarValue()` / `[LootRadarValue]`
  (`enabled`, `alertEnabled`, `minLabelEx`, `alertEx`). `TryLootRadarValue(radarSnap)` (in
  `UpdateRadarFast` after `TryLootTrackerTick`, throttled ~4 Hz, per-area reset via
  `currentAreaHash`) prices ground drops × stack count, caches `g_lrvAnnot[wrapperAddr]` and a
  sorted `g_lrvNearby`, and fires a one-shot `NotifyOverlay.SetBanner` per area when a drop ≥
  `alertEx`. `LrvLabelFor(addr)` exposes the value label for the radar dot. Bridge
  `SetLootRadarValue`; header `lootRadarValue`; UI section Config → Overlay (`det-lootvalue`).
  `LootValueDiagnose()` (Actions button) stays as the verification aid.
- **Currency-image value labels (shipped 0.45.13.32):** the value is NEVER shown as a
  "1ex / 1div" text — it is the matching currency ORB image. `LrvValueParts(ex)` splits a
  value into `Map("icon","exalted"|"divine","num","12")` (Divine once `g_ltDivToEx`>0 and
  `ex≥rate`, else Exalted; `_LrvFmtNum` keeps it short). `LrvIconPartsFor(addr)` is the
  per-dot accessor (same gating as `LrvLabelFor`). Orb PNGs ship in `img/currency/`
  (`exalted.png`, `divine.png`, `chaos.png`; 64×64 RGBA, fetched from poecdn) and are
  committed source data.
  - **`ahk/OverlayImage.ahk` (new):** tiny persistent GDI+ image layer — `LoadOverlayIcons()`
    starts GDI+ once + loads the PNGs into `g_oiBitmaps`; `DrawOverlayIcon(hdc,key,x,y,w,h)`
    + `DrawOverlayIconsBatch(hdc,batch)` blit (source-over alpha) onto any GDI memDC;
    `OverlayIconReady(key)` gates the image-vs-text choice; `StopOverlayIcons()` on exit.
    Degrades to no-op (text fallback) if GDI+/an asset is missing. Wired in
    `InGameStateMonitor.ahk` (`#Include` first in the overlay block, `LoadOverlayIcons()`
    before `LoadOverlaySystem()`, `OnExit StopOverlayIcons`).
  - **`GdiOverlayBase.ahk`:** new `_DrawIcon(key,x,y,w,h)` → `DrawOverlayIcon(this.memDC,…)`.
- **Step 2 (shipped 0.45.13.32) — `ahk/LootValueOverlay.ahk`:** `LootValueOverlay extends
  GdiOverlayBase`, registered in `OverlayManager`. Reads the sorted `g_lrvNearby`, draws a
  ranked "valuable nearby" list (title + up to `g_lrvListMax` rows) anchored left/mid-screen;
  each row = orb image + amount + item name, then a dim tail with the live distance ("Nm") and an
  8-way direction arrow (`_LrvArrowGlyph` from the radar-supplied iso screen delta `LrvSetDir`).
  Gated on `g_lrvEnabled && g_lrvShowList`, foreground, and hidden while a big panel is open.
  Config: `g_lrvShowList`/`g_lrvListMax`, `g_lrvShowDist`/`g_lrvShowArrow` (list distance + arrow,
  both default on), and the on-map label look `g_lrvMapIconSize`/`g_lrvMapFontSize`/`g_lrvMapColor`
  (icon stays gold; only the amount text takes the color). All persisted in `[LootRadarValue]`,
  in the header + UI (one combined row + a live preview).
- **Step 3 (shipped 0.45.13.32) — `RadarOverlay.ahk`:** ground `WorldItem` wrappers (otherwise
  filtered out of the entity draw) are intercepted right after projection; a valued drop
  (`LrvIconPartsFor(addr)`) is collected per frame and drawn in `_FlushLootValues` (value-priority
  + overlap de-clutter). Two on-map styles (`g_lrvMapOnOrb`, default on): **on-orb** — the orb sits
  on the drop with the value as a bottom-right badge (replaces the dot); **beside** — a gold marker
  dot + amount + orb to the right. Both: an 8-way black outline on the amount (`_DrawTextOutlined`)
  AND the orb (`_OrbOutline`, black silhouettes via `OverlayImage`'s color matrix), togglable via
  `g_lrvMapOutline` with `g_lrvMapOutlineWidth` (0 = auto); high-value drops (≥ `alertEx`) get a
  pulsing halo (`g_lrvMapPulse`). The amount/orb size/colour come from `g_lrvMapFontSize`/
  `g_lrvMapIconSize`/`g_lrvMapColor`; `_LootOverlaps` de-clutters. Text fallback when the orb
  icons are unavailable.
- **Verified in-game (2026-06-24, steps 2&3):** orb images render on the radar dots + the
  "valuable nearby" list, scaling/anchor correct, list hides behind big panels. Confirmed on
  Standard with live unique prices via the trade API.

## Trade-API unique pricing — Tier 2, in-browser (shipped 0.45.13.34)

Official PoE2 trade-API (`trade2`) price layer for UNIQUES, to fill the gap poe.ninja leaves
on Standard (no unique prices). Docks into the value-aware loot radar: when poe.ninja can't
price a dropped unique, `_LrvPriceInner` resolves its English name via the reader
(`ReadUniqueIviId` → `GetUniqueNameByIvi`, from `data/unique_ivi_name_map.tsv` — works on a
localized client), checks the trade cache, and otherwise enqueues it for background pricing.

- **RE confirmed (2026-06-24):** name bridge already in `PoE2InventoryReader` (`ReadUniqueIviId`
  reads the ItemVisualIdentity Id at Base+0x30; `GetUniqueNameByIvi` → English name). Trade
  contract: `POST /api/trade2/search/poe2/<League>` then `GET /api/trade2/fetch/<ids>?query=<id>&realm=poe2`.
  The endpoints are **Cloudflare-gated** — a POESESSID alone usually 403s; `cf_clearance` + the
  matching browser User-Agent + (often) the browser's TLS fingerprint are also required. A
  separate HTTP client (PowerShell/.NET) therefore can't reliably replay the cookies.
- **Transport = Tier 2 = `ahk/PoeTradeSession.ahk` (chosen for reliability + security):** a
  dedicated WebView2 window (`WebViewGui`, own gitignored profile `config/wv2_poe`) navigated to
  the PoE2 trade site. The search/fetch run as **same-origin `fetch()` INSIDE that logged-in
  browser** via an injected helper (`AddScriptToExecuteOnDocumentCreatedAsync`), so the request
  carries the browser's own cookies/UA/TLS → Cloudflare is satisfied and **no secret ever leaves
  the browser** (we read/store/log nothing; the session lives only in the WebView2 profile).
  AHK↔page bridge: `PostWebMessageAsJson({cmd:"tradeQuery",id,name,league})` →
  helper posts back `{id,ok,status,listings:[{amount,currency}]}` → `_PoeTradeOnMessage` →
  `_LtTradeOnResult`. The window opens on demand (user signs in once; `tradeHelperReady` resumes
  the drain). NOTE: the `Cookie`/`CookieManager` route was available but deliberately NOT used —
  Tier 2 keeps the secrets in the browser entirely.
- **`ahk/LootTradePricing.ahk`** owns config + queue + cache + currency conversion + rate limit:
  `[LootTradePricing]` (`enabled`,`league`,`ttlHours`=24/`negTtlHours`=12). `LtTradeEnqueue` (only
  uniques poe.ninja missed, dedup, cap `g_ltTradeMaxQueue`), `_LtTradeDrain` (one query in flight,
  ≥3.5 s spacing `g_ltTradeMinIntervalMs`, 5-min `g_ltTradeCooldownMs` after a blocked/error
  result), `_LtTradeOnResult` (401/403/0 → `blocked`+raise window+requeue; else convert+cache).
  Conversion `_LtTradeListingToEx` uses the poe.ninja rates already loaded (`g_ltDivToEx` +
  `g_ltPricesByName`); `_LtTradeRobustPrice` = median of the cheapest ≤8 listings. Positive AND
  negative results cached (`data/trade_prices.tsv`, gitignored) so worthless uniques aren't
  re-queried. `LtTradePriceForName` is the fresh-cache lookup `_LrvPriceInner` reads.
- **Wiring:** `LoadPoeTradeSession()` + `LoadLootTradePricing()` at startup. Bridge
  `SetLootTradePricing` / `PoeTradeOpen` / `PoeTradeClose` / `LootTradePriceNow`; header
  `lootTradePricing` (`enabled,league,ttlHours,negTtlHours,sessionOpen,sessionReady,status,error,
  cacheCount,queueCount` — no secrets exist to expose); UI: advanced `<details>` in `det-lootvalue`
  (security note, enable, league, "Open PoE trade session" + "Price queued now", status). The old
  Tier-1 PowerShell child + secret-file inputs were removed.
- **Verified in-game (2026-06-24):** a second `WebViewGui` opens with its own profile, the user
  signs in once, the injected helper's same-origin fetch passes Cloudflare, the `{id,ok,listings}`
  round-trip works, the response shape (`result` / `listing.price.{amount,currency}`) matches,
  currency ids convert, and the rate-limit/cooldown behave. Confirmed pricing uniques on Standard
  (where poe.ninja has no unique data).

## UI-item hover RE + Price-on-hover (shipped 0.45.13.71)

The world-entity hover chains (`HoverTracker` tracker+0x648 / `MouseOver`
inGameState→0x300→0x3F0→0xA8) only resolve AreaInstance entities — they do NOT see UI /
inventory / stash items. Two flat-scan probes proved PoE2 exposes **no flat "UIHover" slot**
pointing at the hovered UiElement (only whole panels are flat-referenced, never the item
leaf). Solved with a **deterministic UI tree-descent** + the item-slot's own item pointer.

- **RE finding (confirmed in-game 2026-06-25):** an item-slot `UiElement` holds a direct
  pointer to the item ENTITY at **+0x4F8** (`PoE2Offsets.UiElementBase.ItemPtr`). Source:
  `coussiraty/CoreExile2` `GameHelper/Sdk/InventoryAdapters.cs` (`ItemPointerOffset = 0x4F8`);
  their `Self`(0x08)/`Children`(0x10)/`Flags`(0x180) UiElement offsets match ours exactly, and
  the +0x4F8 pointer verified live (a hovered Rare gloves resolved to its real
  `Metadata/Items/Armours/Gloves/...` entity). The inner item then reads with the existing
  item reads (`ReadItemRarity`/`ReadItemArtPath`/`ReadItemModsAndMagicProperties`).
- **`ahk/UiTreeBrowser.ahk`** — `_UiHitGeom` (lean header-only geometry read) +
  `UiTree_HitTest(reader, rootPtr, uiX, uiY, maxDepth)`: descend from a root, at each level
  following the deepest VISIBLE child whose absolute UI-space rect contains the cursor.
  Position accumulation mirrors `UiTree_GetScreenPos` (parent `PositionModifier` when the
  child's `shouldModify` flag is set, then the child's relative pos); topmost (last) match
  wins. Returns the element-address chain root→leaf.
- **`ahk/UiHoverProbe.ahk`** — RE diagnostic (`Ctrl+Alt+Shift+H`): descends from the GameUI
  root to the hovered element, reports the chain + tries +0x4F8 on each chain element to resolve
  the item. Kept as the verification aid.
- **`ahk/UiHoverPrice.ahk` (the feature)** — price-on-hover. `TryUiHoverPrice(radarSnap)`
  (in `UpdateRadarFast` after `TryLootRadarValue`, throttled ~5 Hz, gated on panel-open +
  game-foreground) resolves the hovered item (`_UhpResolveHoveredItem`: descent → first chain
  element with a `Metadata/Items` pointer at +0x4F8 → rarity + stack + the slot's screen rect),
  prices it via the existing value layer (`_LrvPriceInner` × stack → `LrvValueParts`), and caches
  the renderable result in `g_uhpHover` (re-price only on item change / while still unpriced).
  `UiHoverPriceOverlay extends GdiOverlayBase` (registered in `OverlayManager`) draws a small
  currency-orb + amount badge at the slot's top-right corner (orb via `OverlayImage`, text
  fallback). Only PRICED items ≥ `minEx` show a badge — unpriceable rares/magics show nothing,
  like the rest of the value layer. Self-persists `[UiHoverPrice]` (`enabled`, `minEx`).
  Bridge `SetUiHoverPrice`; header `uiHoverPrice`; UI section Config → Overlay (`det-uihoverprice`,
  below the Loot Value Radar). Default OFF.
- **Verified in-game (2026-06-25):** hovering a priced item (currency / unique / waystone /
  fragment) in the inventory or a stash tab shows the orb + value badge on its slot; the
  descent + +0x4F8 resolve and the value layer round-trip work end-to-end. Remaining tuning
  notes (optional): badge placement/scale on very large stash vs tiny inventory cells, and
  overlap with the game's own item tooltip.

## Skill-node UI icons (shipped 0.45.13.73)

Replaces the generic emoji / inline-SVG icons in front of every nav chip + section
heading with **PoE2 passive-tree node icons** — thousands available (no duplicates) and
each carries a built-in allocated/unallocated look used as an on/off state.

- **Source:** GGG's official `grindinggear/poe2-skilltree-export` (free, authoritative):
  `skills.webp` (allocated art) + `skills-disabled.webp` (unallocated) + `frame.webp`
  (per-type node frames), each with a TexturePacker JSON. 676 icons (222 normal 34×34,
  421 notable 49×49, 33 keystone 68×69).
- **`tools/build_skillnode_icons.py`** — composites each chosen icon (art + frame) into a
  uniform 64×64 PNG pair in `img/skillnodes/`: `<name>.png` (allocated: active art +
  allocated frame) and `<name>_off.png` (unallocated). Reads the slot→icon map from
  `tools/skillnode_map.json`. Downloads the source sheets to `tools/.skilltree_cache/`
  (gitignored) on first run, or `--src DIR` for a local copy. Re-run after editing the map.
- **Mapping** lives in two synced places: `tools/skillnode_map.json` (build input) and the
  `SNODE_MAP` object in `ui/index.html` (runtime). Keys: `cat:<id>` / `tab:<id>` /
  `cfgtab:<id>` (nav) and `sec:<id>` (sections, `<id>` = a `det-*` id or a `data-snodekey`).
- **UI wiring (`ui/index.html`):** `snodeInit()` (run on `load`) resolves each slot to its
  DOM element, drops the old SVG/emoji and injects a `<span class="snode">` whose
  `--on`/`--off` art the CSS swaps: **sections** show allocated art while OPEN
  (`details[open] > summary > .snode`), **nav chips** while ACTIVE (`.cat.active`/`.tab.active`).
  Nested sub-sections without a `det-*` id (Stash Mover sides, AutoPilot/LootValue
  sub-groups) carry a `data-snodekey="<id>"` marker. Section icons load from `../img/skillnodes/`.
- **Header standardization (same change):** one uniform collapsible-section rhythm — the
  `.snode` left-icon inset + the gold cube→diamond caret right inset are now consistent for
  flat AND boxed sections. Fixes the Stash Mover / junk-cat boxes that felt "imported from
  another tool" (icon jammed left, caret jammed right) via `.sm-sub`/`.sm-top`/`.junk-cat`
  summary-padding + caret-inset overrides at the end of the main `<style>`.
- **Pending in-game verification:** icon legibility at the real WebView size; the on/off
  swap on section open/close + tab switch; that `../img/skillnodes/` resolves in WebView2.

## Free overlay positioning (shipped 0.45.13.84)

Generalizes the Vitals bars' drag-to-place into a reusable layer so every GDI info
overlay can be positioned freely (the Vitals bars keep their own, unchanged system).

- **`ahk/GdiOverlayBase.ahk`** — opt-in `Placeable` flag + the lifted Vitals drag
  machinery: `_Placed(ctx, defX, defY, w, h)` (stored `xPct`/`yPct` top-left override wins
  over the overlay's built-in default anchor, clamped into the game window — so **nothing
  moves until the user drags it**), per-overlay edit mode (`_EnsureOverlayEditStyle` flips
  `WS_EX_TRANSPARENT` + hooks WM_LBUTTONDOWN; `_OvDragTick` 10 ms poll-drag updating
  `g_ovPlace[name]`), an edit-mode force-show with a labelled grab frame
  (`_OvDrawEditChrome`) + a placeholder rect (`_OvPlaceholderRect`) for content-less
  overlays. `Update()` caches the game-window rect on placeable overlays and bypasses
  ShouldShow while editing.
- **`ahk/OverlayPlacement.ahk` (new)** — `g_ovPlace` (name→`{xPct,yPct}` overrides, only
  when moved) + `g_ovEdit` (name→drag mode). `OverlayPlaceableList()` is the single source
  of truth (debug / lootvalue / lootstrip / lootcompact / notification / focus).
  `SetOverlayEdit` / `SetOverlayPos` / `ResetOverlayPos` / `SetFocusOverlayEnabled`,
  `BuildOverlayPlacementHeaderJson`, self-persist `[OverlayPlacement]`. Seeded by
  `LoadOverlayPlacement()` (init gotcha).
- **Converted overlays** (set `Placeable` + wrap the Layout return in `_Placed`):
  DebugOverlay, NotificationOverlay, LootValueOverlay, LootMapStripOverlay,
  LootCompactBarOverlay. The legacy loot **anchor knobs** (`g_ltBarOnRight` /
  `g_ltBarBottomOffset`) stay only as the bars' DEFAULT anchor — their UI controls are gone.
- **FocusOverlay REMOVED (0.45.13.85):** the "Einzeiler links oben" focused-entity TEST
  overlay was a debug leftover stuck on with no findable off-switch. Fully deleted —
  `ahk/FocusOverlay.ahk`, its `#Include` + OverlayManager registration + `g_focusOverlay` /
  `g_focusOverlayEnabled` globals, the `ToggleFocusOverlay` + `SetFocusOverlay` bridge cases,
  the buried "🎯 Focus Overlay" tree button, and `BuildFocusLines` / `ToggleFocusOverlay` in
  `EntityFocus.ahk`. **`EntityFocus.ahk` is kept** — its resolver helpers
  (`_FocusResolveMouseOverEntity` / `MouseOverLifeLine` / `_FocusLeaf`) are still used by
  DebugOverlay's hovered-entity status line (`ctx.reader` stays for that read).
- **Wiring:** `InGameStateMonitor.ahk` includes the module, declares `g_ovPlace`/`g_ovEdit`,
  calls `LoadOverlayPlacement()` before `LoadOverlaySystem()`. `BridgeDispatch.ahk` cases
  `SetOverlayEdit`/`SetOverlayPos`/`ResetOverlayPos`; `WebViewBridge.ahk` pushes `overlayPlacement`.
- **UI (`ui/index.html`):** **Config → Overlay → "Overlay Placement"** (`det-overlay-placement`)
  — one JS-rendered row per overlay (name · 📍 Move drag toggle · X/Y % · Reset),
  `OV_PLACEABLE` + `overlayPlaceRender`/`overlayPlaceSync` + `ovMove`/`ovPos`/`ovReset`.
  The Loot tab's old "Anchor bars to right" + "Bottom offset" rows were removed (replaced by
  free positioning).
- **Pending in-game verification:** drag + click-through flip per overlay; the
  X/Y % round-trip + persistence across restart; that the old focus one-liner is gone;
  banner placeholder grab-size while no banner is active.

## Ritual reward value badges (shipped 0.45.13.91)

Persistent currency-orb value badges on every Ritual ("Favours") reward cell at once, so
the worth of each reward is visible without hovering. The reward cells carry the item entity
at **+0x4F8** (`UiElementBase.ItemPtr`) exactly like inventory/stash slots (confirmed
in-game via the UI-browser readout below) — but the cursor hit-test can't reach them (it
dead-ends on the full-screen `notification_display` layer), so price-on-hover never fires
there; this is the persistent, all-at-once alternative.

- **`ahk/UiBrowserHandler.ahk` + `ui/index.html`:** the UI Browser element-properties panel
  now shows an **"Item (+0x4F8)"** line (resolves the slot's item entity via the existing
  `_UiHoverItemAt`; "(none)" otherwise) — the RE aid that confirmed the ritual cells (and
  works for any window's item slots). Also in Copy Info.
- **`ahk/RitualProbe.ahk` (new, RE diagnostic):** `RitualProbeRun()` does a tree-wide +0x4F8
  item-slot sweep (StringId search was unreliable — it matched the `RitualRuneInteractable`
  tooltip, not the reward grid) and logs every item slot with screen pos/size. Bridge
  `RitualProbeRun`; "🎲 Probe Ritual" button in the RE-tools row.
- **`ahk/RitualValueBadges.ahk` (new, the feature):** the Favours window has no StringId, but
  its child buttons **`tribute_button` / `layby_pay_button`** are unique to it —
  `_RvbFindRitualWindow()` finds either and returns its PARENT (the window).
  `TryRitualValueBadges(radarSnap)` (in `UpdateRadarFast` after `TryUiHoverPrice`, ~4.5 Hz,
  gated on enabled + panel-open + foreground) re-finds the window (cached ~1 s), BFS its
  subtree for +0x4F8 cells, prices each via `_LrvPriceInner` (× stack, cached by itemPtr),
  fills `g_rvbBadges`. `RitualValueBadgeOverlay` (registered in `OverlayManager`) draws an
  orb+amount badge at each valuable cell's top-right within one bounding-box window
  (reuses `OverlayImage` / the value layer). Self-persists `[RitualValueBadges]`
  (`enabled`, `minEx`); **default OFF**; needs Loot pricing enabled or values stay 0.
- **Wiring:** `InGameStateMonitor.ahk` includes both modules + `LoadRitualValueBadges()`;
  `OverlayManager` registers the overlay; `BridgeDispatch` `SetRitualValueBadges`;
  `WebViewBridge` pushes `ritualValueBadges`; UI **Config → Overlay → "💎 Ritual Reward
  Values"** (toggle + min-ex), `ritualValueBadgesSyncFromHeader`.
- **Verified in-game (2026-06-27):** badges render on the reward cells (small 1×1 and large
  2×3), correctly top-right, no clash with the game's own stack-count label.

## Startup-timing trace + in-tool Diagnostic Files viewer (shipped 0.45.13.110)

Two debug-tooling features. Motivation: occasionally (~1 in 4) startup is very slow before the
tool becomes responsive; and diagnostic output is scattered across `logs/`, `debug/`, `data/`.

- **`ahk/StartupTrace.ahk` (new):** opt-in per-step startup timing. `[Diagnostics] startupTrace`
  toggle (PERSISTENT, not one-shot — keep it on across restarts to catch the intermittent slow
  start). `StTraceInit()` runs early in the auto-exec (right after the logs dir is ensured);
  `StTrace(label)` appends `label | +Δms | totalMs` IMMEDIATELY (crash/hang-safe) to
  `logs\InGameStateMonitor.startup_trace.log` using QueryPerformanceCounter. Near-zero cost when
  off (single global check). Marks punctuate the whole startup: every `Load*()` (per-feature),
  hotkeys, `WebViewGui` create/show/navigate, `CheckPoePatchVersion` (PowerShell), error-log init,
  and the first `EnsureConnected`; plus a bracket around `GetModuleSnapshot(true)` inside
  `PoE2MemoryReader._FindStaticAddressesScan` (the 48 MB read is the prime suspect for the
  intermittent stall). `SetStartupTrace`/`BuildStartupTraceHeaderJson`. NOTE: `InitializeErrorLog()`
  (the `===== Start =====` header) runs LATE in startup, so the normal error log never bounded the
  load sequence — that's why this trace starts from the true beginning.
- **`ahk/DiagFiles.ahk` (new):** backend for the unified **Config → "Data & Logs"** browser (the
  old standalone Diagnostic-Files section + the Data TSV dropdown were merged into ONE browser to
  avoid a second file-viewing system). Enumerates `data\*.tsv` + `logs\*` + `debug\*` (data TSVs
  listed ONCE here; shipped `.json` excluded) → `BuildDiagFilesJson` (`{name,rel,folder,size,mtime}`).
  `ReadDiagFile` tail-caps at 256 KB and adds a `tabular` hint (`_DiagIsTabular`: `.tsv` or
  mostly-tab-delimited → Table, else Text); images report size only. `_DiagResolve` constrains ALL
  access to those three folders (rejects `..` / drive-absolute / unknown). `PushDiagFilesToWebView` /
  `PushDiagFileToWebView` (via `WebViewExec`), `DiagOpenFolder`, `DiagDeleteFile`. Reuses
  `_JsStr`/`WebViewExec`.
- **Unified viewer (`ui/index.html`, Config → Data & Logs):** a two-pane browser — a filterable file
  **list** (folder/name/size/date) on the left, a **dual-mode** viewer on the right. TABLE mode
  reuses the proven sortable/searchable/paginated `renderTsvData`/`_tsvRender` (now with
  **drag-to-resize columns** via a `<colgroup>` + `.tsv-colsz` handles + `_tsvColWidths`); TEXT mode
  renders free-form reports (`*_diag_*.txt`, `.log`) with its own search + line pagination. Auto-mode
  by the `tabular` hint + a manual **Table⇄Text** toggle (`dataSetMode`, caches raw content). JS:
  `updateDiagFiles`/`_diagRenderList`/`dataFilterList`, `updateDiagFile`, `_dataParseTsv`,
  `dataRenderText`/`_txtRender`. The sub-tab open + post-TSV-generation refresh call `DiagListFiles`
  (the old `ListTsvFiles`/`ReadTsvFile` + dropdown JS are now unused dead code, pending cleanup).
- **Wiring:** `InGameStateMonitor.ahk` `#Include`s both modules; `StTraceInit()` + the `StTrace`
  marks in the auto-exec. `BridgeDispatch.ahk`: `SetStartupTrace`, `DiagListFiles`, `DiagReadFile`,
  `DiagOpenFolder`, `DiagDeleteFile`. `WebViewBridge.ahk`: `startupTrace` in the header push.
  `ui/index.html`: the "⏱ Startup timing trace" toggle in **Config → Debug → Diagnostic Actions**.
- **Pending in-game verification:** enable the trace, restart until a slow start is captured, read
  `startup_trace.log` in **Data & Logs**, and identify the spiking step; verify Table/Text auto-mode,
  the per-line text search/pagination, and column drag-resize.

## AutoPilot fix + projection diagnostic (issue #158, shipped 0.45.13.111)

Ticket #158 (a non-owner reporter): with AutoPilot on the character "doesn't move" AND on
enemies it "locks up and spams skills on the middle of the screen, not even aimed." Both
symptoms have ONE cause — an empty/invalid `w2sMatrix` reaching the nav consumers. With a
valid matrix `_WorldToScreen` always uses the matrix path (`NavProject`); only an EMPTY
matrix fell through to the **isometric screen-CENTRE fallback** (`winX+winW/2 + …`) → blind
skill-spam at centre. Exploration already fails safe (empty matrix → `NavAnchor` no-proj →
no click → no movement).

- **`ahk/CombatAutomation.ahk` — mandatory projection gate (the fix):** the per-tick combat
  anchor gate (~line 152) USED to be conditional (run `NavAnchor` only when matrix/rect/player
  were present, else fall through to the skill-fire path). Now it is MANDATORY: if
  `navRect && matrix.Length=16 && playerWorldX!=0` is not ALL true, combat sets
  `g_combatLastReason := "cam-bad(no-proj rect=N matLen=N pwx=N)"` and `return true` (holds
  engagement, fires/clicks NOTHING). The dangerous centre-spam is gone regardless of root
  cause; the reason string self-reports which input is missing. `_WorldToScreen`'s iso
  fallback is KEPT (RadarOverlay + CustomHotkeys still call it without an anchor) but is now
  unreachable from combat with a bad matrix.
- **`ahk/CombatAutomation.ahk` — `AutoPilotDiagnose()` + `_ApDiagFinish()` (triage aid):**
  one-shot dump of the whole world→screen chain so the "doesn't move / fires at centre"
  failure can be root-caused WITHOUT reading the live overlay. Reuses `_DetectCombat(snap)`
  for matrix + player + nearest enemy; reports matrix length (0 = read failed → bad pointer /
  version offset shift / camera not ready) / all-zero / the 4×4 values, the player world pos,
  client rect, `NavProjW` (camera w sign), the player's projected screen pos + % offset from
  centre, the `NavAnchor` ok/why/visSign, and the enemy projection. Writes
  `debug\autopilot_diag_*.txt` (readable in **Data & Logs**) + a MsgBox summary. Distinguishes
  the two failure classes: `matLen=0` / no-proj = no matrix (pointer/offset/version), vs.
  `off-center` = matrix present but projecting the player wrong (garbage matrix / wrong player
  pos).
- **Wiring:** `BridgeDispatch.ahk` case `AutoPilotDiag` → `SetTimer(AutoPilotDiagnose, -1)`.
  `ui/index.html`: a "🔍 Diagnose projection" button in **Config → AutoPilot → Live Status**
  (next to the live combat/explore reason readout).
- **Pending in-game verification (needs the reporter):** with AutoPilot on near a monster,
  click "Diagnose projection" and read `autopilot_diag_*.txt` — the matrix length + anchor
  why localize the root cause so the targeted read/offset fix can follow. Confirm the
  centre-spam is gone (combat now idles with `cam-bad(...)` instead of firing) when the
  matrix is bad.
- **Hotfix 0.45.13.112:** `_ApDiagFinish` had an unbraced `if wrote` whose body was a
  multi-line `try MsgBox(...)` followed by `else` → AHK v2 load error "Unexpected Else".
  Braced the `if` body and pre-built the message string (the `StashMoverDiagnose` pattern).
  Lesson: never give an unbraced `if`/`else` a body that is a continued `try` statement.
- **Diagnostic result + root cause (0.45.13.113):** the owner ran `AutoPilotDiagnose` and it
  proved the matrix is NOT empty — it is PRESENT (len 16) and projects the player to dead centre
  (1722,719 vs centre 1720,720), BUT a real enemy 637 world units away projected onto the SAME
  pixel as the player. The matrix's z→w coefficient (M34) read as **-24951** instead of ~±1, so
  `NavProjW≈1.8M` and every nearby world point collapses onto screen centre. That is the true
  cause of BOTH symptoms and it is a **matrix the projection can no longer use** — i.e. the
  camera-matrix offset DID drift with a recent patch (consistent with the +0x18 `AreaInstance`
  drifts already noted in `PoE2Offsets`), despite the initial "not an offset" expectation. The
  mandatory combat gate does NOT catch this (matrix is "valid" len-16 and the player anchors at
  centre), so the next step is finding the corrected offset.
- **`ahk/CombatAutomation.ahk` — `AutoPilotMatrixScan()` (+ `_ApScanRange`/`_ApMatProj`/
  `_ApScanSort`/`_ApDiagFinish2`):** sweeps candidate W2S-matrix offsets to locate the real one.
  Resolves `WorldData` (`g_reader._radarInGameStateCache` → `+0x368`), reads the live player +
  nearest enemy (or a player+500 test point) via `_DetectCombat`, then for every 4-byte offset in
  `WorldData[0x100..0x300]` AND the camera pointer at `WorldData+0xA0` (`[0x00..0x200]`), in BOTH
  row-major and transposed layouts, projects the player and the test point. A hit = player ≤30%
  off centre AND test point >50 px from the player (a non-degenerate matrix). Sorted by screen
  separation; marks the CURRENT `0x1A8` and the `+0x18` (`0x1C0`) candidate. Writes
  `debug\autopilot_matrixscan_*.txt`. Bridge `AutoPilotMatrixScan`; UI "🧭 Scan matrix offset"
  button next to "🔍 Diagnose projection" in Config → AutoPilot → Live Status.
- **FIXED — corrected offset `0x1A8` → `0x1A0` (0.45.13.114):** the scan's clear winner was
  `WorldData+0x1A0 [row]` (sep=1968 px, the highest by far; player projects to x=1720 = dead
  centre; duplicated at `0x1E0`). Reconstructing it confirmed it: at `0x1A0` the W2S w-row
  direction `(0.467, 0.467, 0.751)` is a **unit vector** (0.467²+0.467²+0.751² = 1.0) — a real
  camera forward axis. The old `0x1A8` read was misaligned by 2 floats (−8 bytes), so the large
  translation value `-24951` landed in the w-row's z-slot, blowing `w` up to ~1.8M and collapsing
  every projection onto screen centre. A recent game patch shifted the camera matrix −8 bytes
  (matrix moved from CameraStructure+0x108 to +0x100), so `0x1A8` was correct before the patch and
  wrong after — i.e. it WAS an offset drift after all (same class as the `+0x18` `AreaInstance`
  drifts). Fix: `PoE2Offsets.WorldData["W2SMatrix"] := 0x1A0`; the existing `[row]` layout is
  correct (no transpose / no pointer-deref). Both matrix reads (`PoE2MemoryReader` lines ~1322 and
  ~3075) go through that constant, so the one-line change fixes the whole projection chain. The
  diagnostic tools (`AutoPilotDiagnose` / `AutoPilotMatrixScan`) now read the offset dynamically so
  they stay useful for the next drift; the mandatory combat gate stays as defence-in-depth.
- **Pending in-game verification (owner):** turn AutoPilot on near monsters — the character should
  move along the explored route and skills should aim at enemies (no more centre-fire / standing
  still). Re-run "🔍 Diagnose projection" to confirm an enemy now projects to a DIFFERENT pixel
  than the player.
- **Follow-up — Auto Loot rarity/size fix (0.45.13.115):** once movement worked, Auto Loot still
  never fired unless "Normal" was enabled, and then it grabbed everything as Normal. Cause:
  `LootPickup._RefreshLootCache` read rarity from `decoded["rarityId"]`, which is only set from a
  `Mods`/`ObjectMagicProperties` component — but ground drops are `WorldItem` WRAPPER entities
  (rarity 0, wrapper path); the real rarity + base-item path live on the INNER item. So every drop
  classified as "Normal" (rarity filter dead) and the size lookup used the wrapper path (registry
  miss → 2×2 guess). Fix: new `_LootResolveItemInfo(addr, path, decoded)` resolves the inner item
  ONCE per drop (reusing the value radar's `_LrvResolveInnerItem` → `g_reader.ReadItemRarity`),
  caching only confirmed resolutions (freshly-dropped items retry until the inner decodes), and
  returns the real rarity label + inner path. `_RefreshLootCache` now filters on the true rarity
  and sizes via `ItemSizeRegistry.Get(innerPath)`. Verified in-game: `pickup(...)` fires and the
  per-rarity filter works, so "Normal" can go back OFF and Magic/Rare/Unique/Currency filter
  correctly.
- **Follow-up — pick up by LABEL, not ground (0.45.13.116):** with rarity working, gear pickup was
  unreliable — the bot clicked the item's projected GROUND position, which (a) landed in the
  bottom-HUD avoid zones a lot (`avoid-zone(Magic)` → walk around) and (b) was imprecise (grabbed
  adjacent white drops). In PoE2 gear is picked up by clicking the floating item **label** (the
  interactable, which also sits above the item, clear of the HUD). Fix: new
  `_LootFindLabelNear(reader, targetSx, targetSy, gameHwnd)` — a focused, visibility-pruned DFS
  (reusing `LootLabelClear`/`UiTreeBrowser` helpers) that finds the nearest visible WorldItem label
  (StringId matches `_IsWorldItemPath`, has name text) to the item's ground projection and returns
  its centre in absolute screen px. `_RunLootPickup` now throttles FIRST (so the label DFS runs
  ~once per click, not every tick), clicks the LABEL when found (`clickTag=lbl`) and falls back to
  the ground point otherwise (`grnd`), and the avoid-zone reason now carries the kind
  (`avoid-zone(<rarity> <lbl|grnd>/<hud|map|ent>)`) for tuning. `pickup(...)` shows `lbl`/`grnd`.
- **Follow-up — loot avoid-zone = interactables only (0.45.13.117):** in-game it was better but the
  bot still walked past some drops with `avoid-zone(Rare grnd/hud)` — the ground click was vetoed by
  the (oversized, display-only) HUD box. For LOOT only `ent` zones (transitions / portals /
  waypoints / NPCs / checkpoints, which change zone or open a dialog) are actually dangerous;
  clicking a globe / skill-bar / minimap is harmless in PoE2. `_RunLootPickup` now blocks ONLY
  `azKind = "ent"` and lets hud/map hits fall through to the click. Also widened `_LootFindLabelNear`
  `MAXDIST` 150→220 px (labels float above the item and spread apart in dense loot, so 150 fell back
  to `grnd` too often). Combat/exploration keep the full HUD/map/ent avoid set (a stray HUD click
  there wastes a tick; for loot it doesn't).
- **Pending in-game verification (owner):** with Normal OFF, the bot should now collect blue/yellow
  drops with far fewer skips; `avoid-zone` should only appear as `.../ent` (next to a real portal /
  waypoint). If `grnd` still dominates over `lbl`, the loot-label StringId may not match
  `_IsWorldItemPath` — capture it with the "Loot Label Probe" and widen the predicate.
- **Follow-up — currency classified by PATH (0.45.13.119):** the status log showed gear pickup
  working (`pickup(Rare 2x3/reg …)` → `picked-up(Rare)`) but almost every scan was
  `cache-empty (saw N, 0 passed filter)` and the owner confirmed CURRENCY was never picked up.
  Cause: `_LootResolveItemInfo` classified only by `ReadItemRarity`, but **currency carries no real
  rarity** (no Mods/ObjectMagicProperties → `ReadItemRarity` returns -1), so it fell through to
  "Normal" and — Normal being off — was filtered out (the value-radar / `StashMover._SmItemCategory`
  already knew this: "Currency / maps are matched by PATH first because those classes carry no real
  rarity"). Fix: resolve the inner path FIRST (was nested inside the `rid>=0` branch — a second bug),
  then if it contains `/currency/` classify as **Currency**, else use `ReadItemRarity` (`rid=-1` →
  Normal, the white-gear case). Confirmed inner resolutions (incl. white gear) are now CACHED so the
  common white drops aren't re-resolved every tick. Known gap: fragments / div-cards / essences also
  carry no rarity and aren't under `/currency/`, so they still classify as Normal — handle by path if
  reported.
- **Verified in-game (owner's status log, 0.45.13.119):** currency is collected —
  `pickup(Currency 1x1/reg …)` → `picked-up(Currency)` repeatedly.
- **Follow-up — label-scan deadline 30→50 ms (0.45.13.120):** the same log showed the label click
  (`lbl`) firing only intermittently (mostly `grnd` fallback, so an item took many walk-closer
  ground clicks before it was grabbed) even though item labels were permanently visible. Cause:
  `_LootFindLabelNear`'s 30 ms deadline vs `A_TickCount`'s ~15 ms granularity — the DFS was cut
  short at random before reaching the labels (the same lesson as LootLabelClear's no-op bug).
  Raised to the proven 50 ms (runs only ~once per click, so the cost is negligible).
- **FIXED — pack-wide no-path give-up (0.45.13.121):** the log also showed combat
  `no-path(… hd=88 no-path:exh/tmo)` loops — a 17-strong pack on an unreachable ledge occupied
  combat for minutes. Two compounding flaws: the give-up blacklisted only the ONE nearest entity
  (for 15 s), so the next packmate immediately became the target and burned its own 4 s — and by
  pack member #4 the first blacklist had already expired, restarting the chain. Fix in
  `CombatAutomation`: (a) new `_CombatBlacklistPackNear(radarSnap, cx, cy, radius, ms)` — on
  give-up, EVERY NPC-like entity within 700 world units of the unreachable enemy is blacklisted
  for 30 s (packmates stand together; radius is the tuning knob if a reachable neighbour pack
  ever gets caught, the cost is only a ≤30 s engagement delay); used by BOTH the no-path give-up
  and the immediate off-floor (`|hd|>200`) blacklist. (b) `static _noPathExhSeen` — once the
  streak contains an EXHAUSTED A* result (`no-path:exh` = genuinely cut off, waiting cannot
  help), the give-up fires after 1.5 s instead of 4 s (budget timeouts `tmo` keep the patient
  4 s). Reason strings now carry `bl=N` (pack size blacklisted). Worst case for the log's pack:
  ~68 s before → ~1.5 s now.

## AutoPilot status file-log (shipped 0.45.13.118)

The WebView tool is rarely in the foreground during play, so the live AutoPilot status line
(state + loot/combat/explore reasons) couldn't be watched while playing. `ahk/AutoPilotStatusLog.ahk`
mirrors it into `logs\InGameStateMonitor.autopilot_status.log` for after-the-fact review in
**Config → Data & Logs**.

- Opt-in **persistent** toggle `[Diagnostics] apStatusLog` (default OFF; stays on across restarts,
  like the startup trace). `LoadAutoPilotStatusLog()` seeds all globals (init gotcha) and reads the
  existing file size so rotation accounts for it. Cheap no-op when off (one global check).
- `ApStatusLogTick()` is called at the end of `TryAutoPilot` (after the reasons are computed). It
  appends `HH:mm:ss.mmm | state=… | loot: … | combat: … | explore: …` only when the line CHANGES
  (deduped) and ≤ ~4×/s (throttled), and rotates the file at ~2 MB. `SetAutoPilotStatusLog(on)`
  writes a session marker when enabled.
- Wiring: `#Include ahk/AutoPilotStatusLog.ahk` + `LoadAutoPilotStatusLog()` at startup;
  `TryAutoPilot` calls `ApStatusLogTick()`; `BridgeDispatch` case `SetAutoPilotStatusLog`;
  `WebViewBridge` pushes `apStatusLog`; UI toggle "📝 Log status to file" in **Config → AutoPilot →
  Live Status**.

## Auto-detect price league (shipped 0.45.13.122)

The price league was manually typed (`g_ltLeague`, default "Standard"); a wrong/stale value gave
empty prices. The owner supplied a verified pointer: **`ServerData + 0x21E0`** is a `std::wstring`
holding the active league name — EXACTLY poe.ninja/poe2scout's value (`"Standard"`, `"Hardcore"`,
`"HC Runes of Aldur"`; the HC/SC prefix disambiguates), so it feeds the price layer directly.

- **`PoE2Offsets.ServerDataStructure["League"] = 0x21E0`** (same base as `PlayerInventories` 0x320).
- **`PoE2PlayerComponentsReader.ReadCurrentLeague(areaInstanceAddress)`** — resolves ServerData
  (`PlayerInfo → ServerDataPtr → ResolveServerDataPointer`) and reads the wstring; returns `""` if
  unresolvable.
- **`LootTracker`** — new `g_ltAutoLeague` (default ON, persisted `[LootTracker] autoLeague`) +
  runtime `g_ltDetectedLeague`. `_LtAutoLeagueTick(radarSnap)` (in `TryLootTrackerTick`, throttled
  15 s, acts only on a CHANGE) reads the league and, when it differs, repoints `g_ltLeague` **and**
  `g_ltTradeLeague` (trade API, in lock-step), persists both, and kicks a poe.ninja refresh (only
  when `g_ltEnabled`). Toggling auto on resets `g_ltAutoLeagueNextTick` for an immediate re-detect.
- **Header/UI:** `BuildLootHeaderJson` pushes `autoLeague` + `detectedLeague`; `_LtApplySetting`
  handles the `autoLeague` key; UI **Config → Loot** has an "Auto-detect league" toggle that dims
  the manual `poe.ninja league` field and shows `detected: <league>` when on.
- **Pending in-game verification:** with auto on, the league field should show the character's real
  league (e.g. `detected: HC Runes of Aldur`), prices refetch on a league change, no manual entry.

## Custom landmark labels on the radar (shipped 0.45.13.123) — port of Sikaka/POE2Radar `CustomLandmarkData`

Draws curated, human-readable labels on the radar for known terrain tiles — boss arenas (with
their reward, e.g. "Beira of the Rotten (10% Cold Res)"), named POIs, and area-transition
destinations. Ports `Sikaka/POE2Radar`'s `CustomLandmarkData.cs`: a big JSON keyed by area code →
tile-path pattern → label, matched by SUBSTRING against the tile paths we already scan.

- **`data/custom_landmarks.json` (committed source data)** — the full label map shipped verbatim
  from Sikaka/POE2Radar (`CustomLandmarks.json`): 91 area codes, 272 entries, plus a global `*`
  bucket. Keys look like
  `"Metadata/Terrain/Woods/Slash/HagWitchArena_01.tdtx:5-y:0"` → `"Beira of the Rotten (10% Cold Res)"`.
  Tracked (NOT gitignored). Data credit: Sikaka/POE2Radar.
- **`ahk/CustomLandmarks.ahk` (new)** — the lookup. `LoadCustomLandmarks()` seeds all globals
  (init gotcha) — `g_clmEnabled` (default ON, `[CustomLandmarks] enabled`), `g_clmFile`,
  `g_clmData`, `g_clmCount` — and calls `_ClmLoadData()`. `_ClmLoadData()` parses the JSON with the
  reference's normalization: strip the `…:x-y:y` tile-coord suffix at the first `:`, map
  `.tdtx → .tdt` (so `.tdt` is a substring of both our paths and the keys), lowercase; result is
  `Map(areaCodeLower → [[patternLower,label],…])`. `CustomLandmarkMatch(areaCode, tilePath)` does the
  case-insensitive substring match — the area's own patterns first, then the global `*` bucket —
  and returns the label or `""`. `CustomLandmarksOn()` is a cheap accessor for `RadarOverlay.Render`
  (which can't easily add a `global`). Self-persists via `SaveCustomLandmarks()`;
  `BuildCustomLandmarksHeaderJson()` exposes `enabled` + `count`.
- **Area code** = `worldAreaDat["id"]` (e.g. "G1_2", "MapBluff"), read off the reader's
  `_radarWorldAreaCache["id"]`.
- **`ahk/PoE2EntityReader.ahk` (`_ProcessTgtScanBatch`)** — the tgt-scan already resolves each tile's
  `tgtPath`. It now also computes `clmAreaCode` once per batch, matches every tile via
  `CustomLandmarkMatch`, caches the label alongside the type in `_tgtPathTypeCache` (so a landmark
  tile with no nav-type is still kept), and emits `label` (+ `type` "Landmark" when there's no nav
  type) in each `results[tileKey]`.
- **`ahk/RadarOverlay.ahk`** — new `COLOR_LANDMARK` (amber). The `_navTargets` population is hoisted
  out of the nav gate so landmarks draw even when AutoPilot nav is off; the draw gate is
  `this._navEnabled || CustomLandmarksOn()`. Per target, a non-empty `label` with the feature on
  draws an outlined amber `label " (<dist>m)"`; nav filename labels are unchanged.
- **Wiring:** `InGameStateMonitor.ahk` `#Include ahk/CustomLandmarks.ahk` + `LoadCustomLandmarks()`;
  `BridgeDispatch.ahk` case `SetCustomLandmarks`; `WebViewBridge.ahk` pushes `customLandmarks`; UI
  **Config → Overlay → "🗺️ Custom Landmarks"** (toggle, shows the loaded-label count),
  `customLandmarksSyncFromHeader`. Default ON.
- **Pending in-game verification:** confirm labels render at the right tiles (boss arenas / POIs /
  transitions) for the current area, the amber colour/outline is legible, and toggling off hides them.
- **Label de-dupe fix (0.45.13.124):** first in-game test showed the SAME label stacked many times
  across the map (e.g. a wall/arena tile such as Machinarium `BossWall01` → "Boss" is placed at many
  spots; the zone scan emits ONE POI per tile, so each drew its own "Boss (Nm)" label — a cluttered
  column spanning 300–5000 m). Fix in `RadarOverlay.ahk`: a per-frame pre-pass groups the POIs by
  label and keeps only the tile NEAREST the player per unique label (`lmRep`); only that
  representative draws the label + dot. Nav POIs (AreaTransition/Waypoint filenames) are unaffected;
  a pure-`Landmark` duplicate is suppressed even with zone-nav on so identical dots don't stack.
  So each curated landmark now shows exactly once, at its closest tile.
- **Coordinate-exact matching (0.45.13.125):** de-dupe stopped the stack, but the single remaining
  "Boss" label sat on the wrong tile — the deduped nearest `BossWall01` was a random reused wall, not
  the boss room. Root cause: I matched by PATH substring and STRIPPED the `:<A>-y:<B>` tile-coord
  suffix from each JSON key. That suffix is the tile's sub-cell (`TileIdX`/`TileIdY`) — exactly what
  the reference pins a landmark to, so a reused tile file (a wall placed all over) matched everywhere.
  Fix: `CustomLandmarks.ahk` now keeps the FULL normalized key (`<path>.tdt:<A>-y:<B>`) and matches it
  **exactly** against `<path>:<TileIdX>-y:<TileIdY>` built per tile INSTANCE (both coord orderings
  tried, since the reader swaps X/Y on odd rotation); the 2 rare coordless keys use a path-only
  fallback. `g_clmData` is now `area → Map(fullKey→label)` (+ `g_clmPathOnly`, `g_clmPaths`). New
  `CustomLandmarkPathCandidate(path)` is a cheap pre-filter so the reader only runs the per-instance
  coord match for tiles whose path could ever be a landmark. `PoE2EntityReader._ProcessTgtScanBatch`
  caches `{type, path, clmCand}` per tile FILE and computes the label per INSTANCE after reading the
  tile coords (the label can no longer be cached by `tgtFilePtr`, since it now depends on the coords).
  Exact matching is a strict SUBSET of the old substring match — it can only REMOVE false matches,
  never add wrong ones. The de-dupe stays as a safety net for arenas built from several variant tiles.
- **Position diagnostic (0.45.13.126, WIP):** with coordinate matching correct (in-game it now surfaces
  exactly the two real G4_10 = "The Excavation" landmarks — the Precursor `BossArena` + `DigSite` chest —
  no spam), a NEW issue surfaced: in `G2_5_1` ("Mastodon Badlands") the labels render at huge clustered
  distances (~12000 m, bottom-left) even though the game shows those transitions nearby. Suspected cause:
  the landmark POI world position comes from the tile's INDEX in the terrain grid
  (`gridX := Mod(tileIdx, totalTilesX) * 0x17`, `worldX := gridX * 250/23`), which was never used for
  DISPLAY before — nav AreaTransition/Waypoint POIs always got their position overwritten by the live
  entity's render position (`_zoneScanAccumulated` refine in `PoE2MemoryReader`), so the raw tile-index
  position was never validated. Pure-terrain landmarks (and un-refined far transitions) rely on it.
  `CustomLandmarkDiagnose()` (bridge `CustomLandmarkDiag`, UI "🔍 Diagnose positions" in the Custom
  Landmarks box) dumps every matched landmark's label + tile coords + computed world pos + `refined`
  flag + distance from the player to `debug\custom_landmarks_diag_*.txt`.
- **`CustomLandmarkPosProbe()` (0.45.13.127, RE aid):** deep probe (bridge `CustomLandmarkPosProbe`, UI
  "🧭 Probe tile positions") that re-walks the raw terrain tile vector and dumps every landmark-candidate
  tile occurrence with array index, row-major world pos, sub-cell + rotation, distance, and a `SubTileDetailsPtr`
  int/float dump. It proved the row-major formula is CORRECT: the `AreaTransition_BadlandsToPits`
  (Bone Pits) tiles sit at world ~(12750, 2250-3750), d≈300-2600 (right next to the player), while the
  diagnostic's `zoneScanResults` reported them at ~(750, 0), d≈12700 — so the SCAN was corrupting the
  position, not the formula.
- **FIXED — AHK case-insensitive variable collision (0.45.13.128):** the root cause. In
  `PoE2EntityReader._ProcessTgtScanBatch` the tile-array loop index was named `tileIdx` and the tile's
  sub-cell byte (read from the struct) was named `tileIdX`. **AHK v2 variable names are CASE-INSENSITIVE**,
  so `tileIdx` and `tileIdX` are the SAME variable — the sub-cell read (`tileIdX := NumGet(...)`, value
  0-14) CLOBBERED the loop index, and the position line `gridX := Mod(tileIdx, totalTilesX) * 0x17` then
  computed from the sub-cell instead of the array index → every tile landed at `(subCellX*23, 0)` with
  `gridY` always 0 (hence all landmarks stacked near the origin corner, two different tiles even colliding
  on the same `(92,0)`). Fix: rename the loop index to `tileArrayIdx` (distinct from `tileIdX`). The
  identical latent bug in the dead legacy `ReadTgtTilesLocations` (chunk cursor `tileIdx` vs sub-cell
  `tileIdX`) was renamed to `chunkStart` too. This ALSO fixes nav AreaTransition/Waypoint/Checkpoint POI
  positions (they used the same clobbered value; it was only ever masked by the live-entity refine).
  Lesson: never let two locals differ only by letter case in AHK.
- **Tile-center anchoring (0.45.13.129):** with positions fixed, a small consistent offset remained — the
  POI was anchored at the top-left CORNER of its ~250-unit tile cell. `_ProcessTgtScanBatch` now anchors
  at the cell CENTRE (`gridX := (col + 0.5) * tileToGrid`), removing the ~half-tile (~125-unit) shift
  toward the grid origin.
- **Snap transition labels to the real portal (0.45.13.130):** the remaining offset was structural, not a
  formula bug — Sikaka pins a TRANSITION label (e.g. "The Bone Pits" on `AreaTransition_BadlandsToPits_01`)
  to the terrain GATE STRUCTURE, whose curated sub-cell can sit ~1000m+ from the clickable portal ENTITY
  the nav already marks (so the same exit showed twice: `AreaTransition_Animate (82m)` filename + `The Bone
  Pits (1287m)` curated). Fix in `RadarOverlay` (per-frame pre-pass, gated on `clmOn`): each labelled
  AreaTransition/Waypoint/Checkpoint tile is snapped onto the nearest REFINED same-type entity (the live
  portal) within ~3000 world units (`navSnap`), and that portal's redundant filename is suppressed
  (`navClaimed`). The curated name now lands on the actual portal at the correct distance; if no portal is
  loaded within range it falls back to the tile position. Only transition-TYPE landmarks snap (bosses /
  chests / named POIs sit on their own tiles already). The distinguishing signal is the `refined` flag
  (entity-scan entries have it; raw tgt structure tiles don't).
- **Extended snap to entrance/passage Landmarks (0.45.13.131):** in-game, "The Bone Pits" (type
  `AreaTransition`) snapped perfectly, but entrance/passage exits that Sikaka classifies as type
  `Landmark` did NOT — their paths (`Badlands_Entrance_01` → "The Ardura Caravan", `AbyssHole` →
  "Lightless Passage") carry no "areatransition" keyword, so they stayed on the gate tile beside their
  live portal (`AreaTransition_Animate (47m)` + `The Ardura Caravan (685m)`). Fix: the snap now considers
  EVERY labelled landmark, snapping to the nearest refined transition/waypoint/checkpoint portal — but
  with a TYPE-dependent radius: transition-type tiles get the generous ~3000 m (big gate offset), all
  other tiles only ~1200 m so a real POI / boss that isn't at an exit (e.g. "Fossilised Memorial") finds
  no portal in range and stays on its own tile. `RadarOverlay.WORLD_TO_GRID_RATIO` converts the world
  radius to the grid² threshold.
- **Nearest-walkable nudge (0.45.13.132) — port of coussiraty/CoreExile2 `Pathfinder.TryFindNearestWalkable`:**
  a curated landmark that did NOT portal-snap AND whose tile sits on UNWALKABLE terrain (a decorative
  feature off the playable area — the "Fossilised Memorial" case) is pulled onto the nearest reachable
  ground. `TerrainPathfinder.NearestWalkable(gx, gy, maxRadius:=75)` mirrors the reference: an
  expanding-ring PERIMETER search (only the border of each ring, O(r) per ring) over the walkable nibble
  grid via the existing `IsWalkable`. The overlay's snap pre-pass, after the portal pass, nudges every
  still-unplaced labelled landmark that fails `IsWalkable`. `target["gridX"]/gridY` are already
  walkable-grid cell coords (both = `worldX / WORLD_TO_GRID_RATIO`), so no conversion is needed. Gated on
  `_pathfinder.HasTerrain()`; landmarks already on walkable ground are left untouched.
- **Portal match by DIFFERENT-PATH, not `refined` (0.45.13.133):** "Lightless Passage" (on tile
  `AbyssHole`) still didn't snap — the `refined`-flag requirement was wrong: the real portal
  `LightlessPassageTransition` either isn't a refined entity, or the `AbyssHole` tile itself got refined
  to the hole feature (559 m) not the portal (89 m). The robust distinguisher between the clickable portal
  and the landmark's own gate/structure tiles is that the portal has a DIFFERENT tile path (a gate spans
  many SAME-path tiles), so the snap now matches "nearest transition-type entry whose `path` differs from
  the curated tile's path" and dropped the `refined` gate + the "skip already-refined landmark" guard.
  Non-transition radius tightened 1200 → 1000 m to offset the looser match. Known residual risk: a
  boss/chest/POI within ~1000 m of an unrelated transition could mis-snap — revisit with a path-keyword
  gate (entrance/hole/passage/stairs/…) if it shows up in-game.
- **Portal candidates = AreaTransition only (0.45.13.134):** with the looser different-path match, Lightless
  Passage / Ardura Caravan snapped to the nearby **Checkpoint / Waypoint** instead of the real exit — those
  are intra-zone features that often sit right beside a transition. A destination landmark is reached via an
  AREA TRANSITION, so the portal-candidate filter tightened from any transition-type to
  `pt["type"] = "AreaTransition"` (Waypoint / Checkpoint excluded). Bone Pits' portal
  `AreaTransition_Animate` is still an AreaTransition (folder `AreaTransitions/` → the classifier matches),
  so it keeps working.
- **Classifier keyword `areatransition` → `transition` (0.45.13.135):** Lightless Passage still didn't snap
  because its real exit entity (Entity Inspector: `Name: LightlessPassageTransition, Type: Terrain, Metadata:
  /Terrain/Gallows/Act2/2_5/Objects/LightlessPassageTransition`) lives in an `Objects/` folder, NOT
  `AreaTransitions/` — so the `areatransition` keyword never matched it and it was classified `entType=""`
  (skipped, never in `_navTargets`, no snap candidate). Broadened the transition classifier in all 4 sites
  (`PoE2EntityReader` deep/tgt/legacy scans + `PoE2MemoryReader` entity scan) from `InStr(path,"areatransition")`
  to `InStr(path,"transition")` — catches `AreaTransition_*` AND `*Transition` object exits; `waypoint` /
  `checkpoint` carry no "transition" so they keep their own types. This is the correct semantics (these ARE
  zone exits) and also improves nav/AutoPilot exit detection. Low over-match risk (decorative "transition"
  objects are rare and usually not in the radar sample).
- **Walkable path to each landmark (0.45.13.136, opt-in):** new `[CustomLandmarks] showPaths` toggle
  (default OFF; `g_clmShowPaths`, `CustomLandmarkPathsOn()`, UI "Draw a walkable path to each landmark").
  In `RadarOverlay.Render`, the drawn landmarks' display positions are collected (`lmDrawn`); a THROTTLED
  pass (recompute every 1.5 s or on >12-cell player move, cached in `_clmPathCache`) runs
  `_pathfinder.FindPath(player → landmark)` for each within ~6000 world units (far POIs skipped — A* too
  costly), and the cached routes draw every frame as thin dim-amber polylines UNDER the gold nav / red
  combat paths. Wired via the existing `SetCustomLandmarks` bridge case (`_ClmApplySetting` key
  `showPaths`) + header + `customLandmarksSyncFromHeader`.
- **Landmark-path options (0.45.13.137):** the path feature is now tunable — `[CustomLandmarks]`
  `pathWidth` (px), `pathMaxDist` (world units, the range cap), `pathToExits` / `pathToPois` (an
  exit-vs-POI filter), `pathArrows` (direction chevrons); all in `CustomLandmarkPathOpts()` (a Map read
  once per frame by the overlay), the header, and UI sub-rows under the path toggle. Each route now gets
  its OWN colour from `RadarOverlay.CLM_PATH_PALETTE` (cycled by draw index). The exit/POI split uses the
  new `navPortal[idx]` flag (set when a landmark portal-snapped — those are exits; everything else is a
  POI), recorded on each `lmDrawn` entry. Direction chevrons draw via `_DrawArrowHead(sx, sy, dx, dy, len,
  colour, width)` (immediate 3-point Polyline ">" every ~14 path points, pointing player→landmark since
  `FindPath` returns start→end). The A* recompute also re-runs when the exit/POI/range signature changes
  (not just on the timer), so toggling an option updates immediately.
- **Route-coloured dot/label + visible chevrons (0.45.13.138):** two fixes to the landmark paths.
  (1) The destination DOT and LABEL now share their route's palette colour instead of the generic
  type/amber colour — the colour is assigned ONCE per route-eligible landmark during the draw loop
  (`lmRouteColor`, palette-cycled via `lmColorN`) and reused by `_DrawDot` + `_DrawTextOutlined`, then
  stored on the `lmDrawn` entry (`color`) so the path recompute reads it directly (route colour is no
  longer derived from the cache index — dots, labels and routes now cycle in lock-step). Route eligibility
  (exit/POI filter + range cap) is evaluated up front so a filtered-out landmark keeps its normal colour
  and draws no route (`color = 0`, skipped in the recompute). (2) Direction chevrons were INVISIBLE — the
  old "every 14th path point" spacing drew nothing because `FindPath` smooths the route down to a few
  far-apart points. Replaced with SCREEN-distance spacing: a running accumulator walks the projected
  polyline and drops a `_DrawArrowHead` every ~85–110 px (interpolated INSIDE long segments, first chevron
  0.6× in from the player), pointing the way the route runs.
- **Off-screen landmark labels pinned to the map edge (0.45.13.139):** when a curated landmark's
  destination lies OUTSIDE the drawn large map (e.g. a route leading off the top edge), its label was
  simply invisible. New `RadarOverlay._DrawEdgeLabel(cx, cy, tSX, tSY, winW, winH, text, colour, isLargeMap)`
  clamps the label to the window edge along the player→landmark ray: it intersects that ray with an inset
  window rect (parametric first-boundary crossing, player normally inside), drops a `_DrawArrowHead` on the
  edge pointing off-screen (in the route's direction + route colour), and places the outlined label just
  inside, kept fully on-screen (text width ESTIMATED from character count — measuring the batched font
  isn't worth the DC round-trip). In the landmark draw loop a landmark whose projected `(tSX,tSY)` is
  off-screen (`lmOff`) uses the edge label instead of the normal `tSX+…` placement; it shares the route
  colour so the edge label matches its route. Gated on `clmEdge := clmOn && isLargeMap &&
  CustomLandmarkEdgeLabelsOn()` — **large map only** (the minimap projection legitimately runs far past the
  window, so edge-clamping there would be nonsense). New toggle `[CustomLandmarks] edgeLabels` (default ON;
  `g_clmEdgeLabels`, `CustomLandmarkEdgeLabelsOn()`); bridge key `edgeLabels` via the existing
  `SetCustomLandmarks`; header field `edgeLabels`; UI toggle "Pin off-screen labels to the map edge (large
  map)" under the main Custom Landmarks toggle.
- **Custom Landmarks UI polish (0.45.13.140):** (1) the box now carries a **skill-node icon** like every
  other section — new slot `sec:det-customlandmarks` → `PathfinderMultichoicePath` (a crossroads notable) in
  BOTH `tools/skillnode_map.json` and the runtime `SNODE_MAP`; the icon pair was composited into
  `img/skillnodes/` (the emoji 🗺️ in the header is stripped at runtime by `snodeInit` as usual). (2) The path
  sub-options are compacted onto two rows via CSS grid: "Line width" + "Max distance" share one row
  (left-/right-aligned, 2 cols), and "To exits" + "To POIs" + "Arrows" share one row (left/center/right, 3
  cols) — the long labels were shortened with `title=` tooltips carrying the full meaning. (3) The RE
  diagnostic buttons are **removed** — the "🔍 Diagnose positions" / "🧭 Probe tile positions" UI buttons,
  the `CustomLandmarkDiag` / `CustomLandmarkPosProbe` bridge cases, and the `CustomLandmarkDiagnose` /
  `CustomLandmarkPosProbe` functions in `CustomLandmarks.ahk` (the landmark position bug they helped solve
  is fixed).

## Scale-aware UI→screen conversion (shipped 0.45.13.141) — fixes the "slight offset" on all UI rects/labels

Every UI-rect consumer (UI-browser highlight, hover-price badge, ritual badges, loot-label
clear/click, stash-mover grid) converted UI coords with ONE global scale (`clientH/1600` on
both axes, no cull, no per-element multiplier) — a systematic slight offset on everything.
The C# reference (GameHelper2 `UiElementBase.GetUnScaledPosition` + `GameWindowScale` +
`GameCull`) does three things we didn't:

- **Per-element scale conversion in the parent chain:** each UiElement carries `ScaleIndex`
  (0x18A) + `LocalScaleMultiplier` (0x130); when parent and child differ, the accumulated
  position converts between their scale spaces (`parentPos * parentScale / childScale`, per axis).
- **Per-axis final scale:** `v1 = (clientW − 2·cull)/2560` (width), `v2 = clientH/1600`
  (height); ScaleIndex picks the pair (1→v1/v1, 2→v2/v2, 3→v1/v2, else 1/1) × localMult.
- **Cull + client rect:** screen X shifts by `+cull` (the letterbox bar width, an int at the
  `GameCullSize` static address — our pattern scanner already found it, nobody read it) and the
  origin is the CLIENT area (GetClientRect), never WinGetPos.

Implementation (`ahk/UiTreeBrowser.ahk`): `UiTree_ScaleCtx(reader, hwnd)` (client rect + cull
+ v1/v2, one cheap ReadInt; cull sanity-clamped to 0), `_UiScalePair(idx, mult, sc)`,
`UiTree_GetScreenPos(reader, elem, sc:=0)` (faithful GetUnScaledPosition port; now also returns
the leaf's `scaleIndex`/`localMult`; degrades to the old plain sum without a window),
`UiTree_ScreenRectOf(reader, elem, sc:=0, sizeW:="", sizeH:="")` (absolute screen-px rect =
leaf pos × own pair + cull + client origin), and a scale-aware `UiTree_HitTest(reader, root,
px, py, sc:=0)` — SIGNATURE CHANGE: takes absolute screen px now, not pre-divided UI coords.
Consumers switched to `UiTree_ScreenRectOf`: `UiHoverPrice` (+ hit test in px),
`RitualValueBadges`, `LootLabelClear` (abs px − window origin for the overlay-local rects),
`LootPickup._LootFindLabelNear`, `StashMover._SmInventoryGridRect` (manual offsets kept on
top), `UiBrowserHandler` (props now client-local px + cull; per-element localMult respected).
`g_uiBrowserHighlight` now stores ABSOLUTE screen px; `RadarOverlay._FinishFrame` shifts it by
the overlay window origin (`this._lastX/_lastY`) instead of re-scaling with the WINDOW height.
On a 16:10 window with cull 0 and uniform scale chains the new math reduces exactly to the old
formula — differences appear only where the old math was wrong (mixed scale spaces, non-16:10
aspects, windowed mode, localMult ≠ 1).
**Pending in-game verification:** UI-browser highlight sits exactly on the selected element
(e.g. Guild Stash), hover-price/ritual badges pixel-exact on their cells, loot-label click
accuracy, stash-mover button/grid anchor (existing offsetX/offsetY calibrations may now
double-correct — re-zero them if the grid is offset the other way).
- **Hotfix 0.45.13.142 — hover-price died; hardened against bad memory scale data:** first
  in-game test broke price-on-hover entirely. An OFFLINE harness (fake reader + synthetic
  UiElement tree, 35 checks incl. hand-computed C#-reference values) proved the core math
  correct — so the in-game breakage comes from the MEMORY values, with two prime suspects:
  (a) the `GameCullSize` static was never consumed before, so a mis-resolved pattern
  (garbage cull int) silently poisons `v1` and collapses every width-scaled rect — the
  root is ScaleIndex 3, killing the whole descent; (b) the ScaleIndex/LocalScaleMultiplier
  offsets (0x18A/0x130) are from the 0.4.x reference layout and other UiElement fields HAVE
  drifted in 0.5.x (StringId 0x140→0x098), so they may read garbage. Hardening (all in
  `UiTreeBrowser.ahk`): `UiTree_ScaleCtx` clamps v1 into a plausibility band (0.7–1.3 × v2;
  outside → distrust the cull, then fall back to v1=v2); `_UiScalePair` sanitizes
  localMult (accept 0.2–5.0, else 1.0), unknown ScaleIndex → uniform (v2,v2), and honors a
  `sc["uniform"]` legacy-override flag (exact pre-scale-aware behavior); `UiTree_HitTest`
  retries once in uniform mode when the descent never leaves the root (descent split into
  `_UiHitDescend`). `UiHoverPrice._UhpResolveHoveredItem` retries its hit test + chain scan
  once with `sc["uniform"] := true` when NO item slot was found (partial-chain failures the
  root-level fallback can't see); scan extracted into `_UhpScanChainForItem`. The
  UIHover probe (`Ctrl+Alt+Shift+H`) now prints per-chain-element `scIdx`/`lMult` and the
  ctx `v1/v2/cull` — capture it over an inventory item to see the REAL memory values if
  anything still misbehaves. (0.45.13.146: the probe threads its ONE scale ctx through every
  report line — `_UiHoverChainLine(reader, addr, sc)` — and prints the `scaleMode`, so when
  the hit test flips the uniform fallback the printed positions match the hit geometry.)
  Offline harness lives in the session scratchpad
  (`ui_scale_test.ahk`), validated: uniform 16:10 ≡ old math, 16:9 + client offset, mixed
  scale-space conversion, real cull (+128), poisoned cull (700 → rejected), garbage
  index/mult leaf (→ uniform behavior), partial-chain + uniform retry.
- **UI Browser hover highlight (0.45.13.143):** hovering a node in the CHILDREN list (and in
  the search-results list) draws a BLUE rect (BGR `0xFF0000`) on that element's live screen
  rect, alongside the red selection rect. `ui/index.html`: `onmouseenter`/`onmouseleave` on
  `.uib-child-row` + `.uib-sr-row` → `ahkCall('UiBrowseHover', ptr)` ('' clears; the static
  `#uib-children-list` also clears on `onmouseleave` as a safety net against re-renders).
  `BridgeDispatch` case `UiBrowseHover` → `UiBrowserHoverHighlight(hex)`
  (`UiBrowserHandler.ahk`): resolves the ptr, caches the ABSOLUTE screen-px rect
  (`UiTree_ScreenRectOf`) in `g_uiBrowserHoverHighlight` (0 clears; also cleared by
  `UiBrowserClearHighlight`). `OverlayManager` counts the hover rect toward
  `ctx.inspectOverride`; `RadarOverlay._FinishFrame` draws it after the red rect.

## NPC "Identify Items" hotkey (TEST, shipped 0.45.13.144) — `ahk/NpcIdentify.ahk`

One hotkey (default **F9**, only while PoE2 is focused): in the HIDEOUT, click the NPC
"Doryani" via his floating hideout label, wait for his dialog window to open, then click its
"Identify Items" row. UI paths are owner-provided from the UI Browser (root-relative index
paths) and INI-tunable in `[NpcIdentify]` (`hotkey`, `npcName`, `menuText`, `labelsPath=8,0,0`
[container of ALL hideout labels — the NPC's child index shifts, so the label is found by its
displayed TEXT], `windowPath=23` [NPC dialog window], `menuPath=1,0,2,1,0,0` [window → the
"Identify Items" row]). Flow: hideout gate (`reader._radarWorldAreaCache.isHideout`) → find
the VISIBLE label child by text → `UiTree_ScreenRectOf` + `NavClickAt` centre (char walks,
game opens the dialog) → 150 ms poll (9 s deadline) until `windowPath` is
`UiTree_HierarchicallyVisible` → resolve `menuPath`, require its displayed text to contain
`menuText` (path-drift guard; aborts with the actual text otherwise) → click it. Every gate
aborts with a `ToolTip` reason. The section is written back on load so the keys are
discoverable in `poeformance_config.ini`. Wiring: `#Include ahk/NpcIdentify.ahk`;
`LoadNpcIdentify()` + `RegisterNpcIdentifyHotkey()` at startup (HotIf-gated to the PoE window,
StashMover pattern); bridge case `NpcIdentifyRun`; "🪄 Doryani Identify" button in the RE-tools
row. Verified: full-script `AutoHotkey64.exe /validate` passes.
**Pending in-game verification:** label click walks to Doryani and opens the dialog; the
window/menu paths resolve on the live client; the final click fires identification; tooltip
reasons on each abort gate.

## AutoPilot panel polish (shipped 0.45.13.150)

Four owner-requested tweaks to Automation → AutoPilot:
- **Summary underline incl. status:** `#det-autopilot > summary` draws a bottom-gradient rule
  (junkbox trick, inset 26px past the icon, ending at the right edge) in BOTH open and closed
  state, covering the live-status string next to the caret; the box's open-only `.cfg-header`
  border is disabled (ID-specificity override).
- **Configurable AutoPilot hotkey:** the informational "Hotkey: F10" label is now a capture
  button (StashMover pattern — `apCaptureHotkey`/`apHotkeyApply` trio reusing `#hk-capture` +
  `hkKeyName`; the keydown/mousedown listeners got an `apHotkeyCapturing` branch) plus a ✕
  clear button. New bridge case `SetCombatHotkey` → set `g_combatToggleHotkey`,
  `SaveCombatAutoConfig()`, `RegisterCombatHotkey()` (re-binds/unbinds), header re-push. The
  header sync renders the pretty label via `smPrettyHotkey` and handles "" (→ "none").
- **Live-Status centering:** the Combat/Explore/Loot rows are `.ap-live-row` — a 3-column grid
  (`1fr auto 1fr`: label start / state CENTERED / reason-readout end); flex space-between had
  shifted the middle with the right column's width (the Loot row's "pickup · cache N").
- **Diagnose buttons moved:** "🔍 Diagnose projection" + "🧭 Scan matrix offset" (+ help text)
  moved from AutoPilot → Live Status to **Config → Debug → Diagnostic Actions**.
Verified in the browser preview: middle spans pixel-centered (row/mid centers identical),
underline present open+closed, capture flow (Ctrl+F9 → "Ctrl + F9", Escape cancels), diagnose
buttons present only under `det-debug-actions`.
- **Follow-up (0.45.13.151):** (1) the summary got symmetric vertical padding so the
  heading/status sit on the caret's axis (the one-sided padding-bottom had pushed them above
  the 50%-anchored diamond). (2) Modifier combos (Alt/Shift/Ctrl + key) now work in ALL hotkey
  captures — a held modifier fires its OWN keydown (`key="Alt"`…), which used to hit the
  "unmappable → cancel" path before the real key arrived; pure-modifier presses are now
  ignored while capturing (ap/sm/hkCapture alike). (3) Live Status restyled as a ledger: the
  State row is a 3-column `.ap-live-row` too, with a new right-column `#cfg-autopilot-enabled`
  (enabled/disabled, synced from `d.autoPilot`), and the first three rows carry
  `.ap-live-rule` — a centered 70%-width hairline under the row (the last row goes without).
  Verified in the preview: status center == summary center, Alt+F5 → "Alt + F5",
  Shift+X → "Shift + X", 3 rule lines, state value pixel-centered.
- **Status seeded at startup (0.45.13.152):** the summary/status strings showed the stale
  "idle" seed until the game loop first ran (per-tick reasons only update while connected).
  `InGameStateMonitor` now re-seeds `g_autoPilotReason` / `g_combatLastReason` /
  `g_exploreLastReason` to enabled/disabled from the loaded flag right after the sub-flag
  mirroring, and BOTH AutoPilot toggles (bridge `ToggleAutoPilot` + the hotkey handler) set
  them to "enabled" when switching ON (previously only the OFF branch wrote "disabled").
- **Global row hover highlight (0.45.13.157):** whichever content row the cursor is over
  now gets a subtle warm-gold tint (`background-color: rgba(200,168,90,0.06)` + 3px radius,
  120ms fade) across the whole UI. One curated `:hover` block in the `<style>` covering the
  leaf row classes (`.cfg-row`, `.cfg-slider-row`, `.cfg-sub-row`, `.ap-live-row`, `.hk-row`,
  `.lt-row`, `.re-row`, `.re-hex-row`, `.ovp-row`, `.diag-file-row`, `.dbg-overlay-row`,
  `.junk-pat-row`, `.combat-slot-row`, `.combat-slot-adv-row`, `.sm-rnd-row`, `.ei-prop-row`).
  Nav bars (`.subtab-row`), pill containers (`.filter-row`) and rows that already carry their
  own hover (tables, tree/entity/prop rows, UI-browser rows) are deliberately excluded.
  `background-COLOR` only, so the `.ap-live-rule` ledger hairline (a `background-image`
  gradient) survives underneath. Tuned 0.45.13.158: tint softened `0.06 → 0.03`, and the
  highlighted rows get 8px horizontal padding cancelled by an equal `-8px` margin — the text
  keeps its exact position but the tint's padding box extends 8px past it on each side, so
  text never touches the tint edge (horizontal-only, vertical rhythm untouched). Verified in
  the preview: text position unchanged, tint extends +8px, no horizontal overflow on
  `.cfg-scroll` or the document.
- **AutoPilot page: standard boxes + inline Live Status (0.45.13.155):** the three
  sub-sections became STANDARD category boxes like Overlay's Map Hack/Radar — sibling
  `.cfg-section > <details id="det-ap-combat|det-ap-explore|det-ap-loot">` blocks after
  `#ap-panel`, wired into `syncCfgSections` (ids `ap-combat`/`ap-explore`/`ap-loot` in
  `_cfgSectionIds`; combat/explore keep the `_sbInitAll` ontoggle for their sliders). The
  "Live Status" box was dissolved: its rows (State/Combat/Explore/Loot + the log-to-file
  toggle) sit inline in `#ap-panel` directly under "Pause while a UI panel is open".
  `sec:ap-status` left SNODE_MAP + `tools/skillnode_map.json` (the box summaries keep their
  icons via `data-snodekey`). Verified in the preview: subpanel top level = #ap-panel + 3
  cfg-sections, cfgSections open-state restore works for the new ids, live rows centered,
  icons present.
- **AutoPilot category box removed (0.45.13.154):** with AutoPilot on its own sub-tab the
  outer collapsible box was redundant. The `det-autopilot` details + summary (incl. the
  status string, which lives on in the Live-Status State row) are gone; the content sits in
  `#ap-panel`, which KEEPS the `.cfg-section` class (the nested summaries' caret/flex styling
  is scoped to it) but drops the box chrome via CSS. `_sbInitAll` runs from
  `_runTabSideEffects` on entering the `autopilot` tab (was the removed details' ontoggle);
  the `.ap-live-*` CSS re-scoped `#det-autopilot` → `#ap-panel`; 'autopilot' left
  `_cfgSectionIds`; `sec:det-autopilot` left SNODE_MAP + `tools/skillnode_map.json`; the
  `cfg-autopilot-reason-summary` header sync was removed. NOTE for preview testing: a
  collapsed Launch-preview panel reports `window.innerWidth = 0` and every rect collapses —
  force `body{min-width}` before measuring (this also explains earlier "transient 0-width"
  readings).
- **Closed boxes vertically centered (0.45.13.153):** `.cfg-section` carries 4px top / 10px
  bottom padding (right for an OPEN body) which pushed icon + heading + caret ~3px above the
  middle in every COLLAPSED box; the `.cfg-header`'s own 4px/6px padding added another 1px.
  Both are symmetrized while a box is closed (`:has(> details:not([open]))` → 7px/7px box,
  5px/5px header) with unchanged totals, so collapsed boxes keep their exact height. Verified
  in the preview: header/icon/caret centers == box center for det-vitals-life, det-radar and
  det-autopilot.

## Price liquidity gates (shipped 0.45.13.149) — fixes wildly inflated prices

Report: "völlig überzogene Preise" from poe.ninja / the trade API. Root cause verified against
the LIVE API: the math is correct (exchange `primaryValue` IS in Divine — `divine=1.0`,
`exalted=1/rate` — and `× core.rates.exalted` is right), but poe.ninja's RAW API includes
**illiquid / price-fixed lines its own website hides**. Seen live: a junk unique ("The Gnashing
Sash", `listingCount=3`) at 6257 div → 4.3M ex in our TSV; exchange lines with
`volumePrimaryValue` < 1 divine of total volume priced at fantasy asks. Young/HC leagues are
full of these. The trade API was worse: `_LtTradeRobustPrice`'s "median of the cheapest ≤8"
accepted a SINGLE listing as the market price.

- **`tools/poe_ninja_prices.ps1`** — new params `MinVolume` (default 1.0; exchange lines below
  this `volumePrimaryValue` [divine traded] are skipped) and `MinListings` (default 5; item
  lines below this `listingCount` are skipped). Both fail OPEN when the API omits the field, so
  a schema change can never blank the TSV. Skip count is appended to the `#meta` errors field
  ("thin-market lines skipped: N"). Verified live against "Runes of Aldur": 264 lines skipped,
  Gnashing Sash gone, Mageblood correctly 348 850 ex (= 500 div), Greater Exalted Orb 7.8 ex.
- **`ahk/LootTradePricing.ahk`** — `_LtTradeRobustPrice` returns unpriced (`ex=0`) below 3
  priceable listings; the caller's cache then acts as a negative entry (`LtTradePriceForName`
  gates on `ex > 0`), so the unique stays untagged instead of carrying a troll ask.
- Residual (not a bug): early-league div→ex rates swing hard between snapshots (sparkline
  `totalChange` ±45% on day 1), so absolute ex values move until the economy settles.

## Nav restructure — Overlay + Automation as top-level categories (shipped 0.45.13.145)

Cat bar LEFT: **Game · Overlay · Macro Engine · Automation**; RIGHT: **RE · Config** (RE moved
right; its sub-tab row is right-aligned like Config's). The former Config sub-tabs moved out:
**Overlay** category = sub-tabs *Overlay* + *Vitals*; **Automation** category = sub-tabs
*AutoPilot* + *Stash Mover* (the old single "automation" sub-panel was split into two
`.cfg-subpanel`s, `stashmover` + `autopilot`). Config keeps **General · Debug · Data & Logs**.

**Mechanism — ALIAS tabs, no DOM moves:** lots of CSS is scoped to `#panel-config`
(`.hk-num`, `.vrule`, …), so the content stayed inside `#panel-config`. The new categories'
tabs (`cfgoverlay`, `cfgvitals`, `autopilot`, `stashmover`) are top-level tab KEYS with no own
panel: `switchTab` resolves them via `cfgPanelForTab` to `#panel-config` and flips the mapped
inner sub-panel through the shared `_cfgShowSubpanel(name)` (scoped to `#panel-config
.cfg-subpanel`). `tabCategory`/`lastTabPerCategory` gained the new keys, so the category
highlight/marker machinery is unchanged. `switchConfigSubTab` keeps handling the remaining
real Config sub-tabs and REDIRECTS legacy names (`automation`→`autopilot`,
`overlay`→`cfgoverlay`, `vitals`→`cfgvitals`) to the tab system. Persistence: the
`configSubTab` whitelist shrank to general/debug/data in BOTH `BridgeDispatch.SetConfigSubTab`
and `ConfigManager` (old persisted values fall back to `general`; the header-restore in JS
sanitizes too). Skill-node icons: the orphaned `cfgtab:*` icons were re-keyed
(`cat:overlay`←LifeandMana, `cat:automation`←PhysicalDamageOverTimeNode,
`tab:cfgvitals`←BloodMageNode) + `tab:cfgoverlay`=PressurePoints,
`tab:autopilot`=KeystoneAvatarOfFire, `tab:stashmover`=KeystonePainAttunement (existing
composited PNGs, mirrored in `tools/skillnode_map.json`).
**Pending in-game verification:** category/tab switching incl. the sliding marker on the new
rows, alias tabs showing the right sub-panels, Config remembering general/debug/data, vitals
edit-mode from the new Vitals tab, snode icons on all new nav chips.
- **Header-sync isolation + JS→AHK error log (0.45.13.147):** follow-up to a "Vitals Life/
  Mana/ES boxes missing" report. Browser repro (static `http-server` + driving `updateHeader`
  with a realistic payload) shows the CURRENT code builds and shows all three `det-vitals-*`
  sections — the likely in-app cause is a JS exception in an EARLIER `updateHeader` feature
  block (real data) starving `vitalsSyncFromHeader` (which is the only `renderVitalsBars`
  trigger). Hardening: every feature-sync call in `updateHeader` now runs isolated via
  `_hdrTry(name, fn)` (one throwing block can no longer kill the rest, the error is logged),
  and `_jsReport(msg)` forwards JS errors — incl. `window.onerror` — over the bridge (new
  `JsError` case → `LogError("WebViewJS: …")`), so WebView exceptions finally show up in the
  error log (readable in Config → Data & Logs). Note: the vitals sections may also simply be
  COLLAPSED (their open state persists in `[…] cfgSections`, and the default list doesn't
  include `vitals-life/mana/es`).

## Stack max-size probe (0.45.13.159) — testing Stack +0x20

Owner hypothesis: a stackable item's MAXIMUM stack size lives on the Stack component at
**+0x20** (the known `Count` is +0x18). The C# reference (`StackOffsets`) maps only
`Header`/`UnknownPtr(0x10)`/`Count(0x18)` and notes max size lives elsewhere, so this needs a
live check. `ahk/StackMaxProbe.ahk` (`StackMaxProbeRun`, bridge `StackMaxProbeRun`, UI
"📦 Probe Stack Max" in Config → Debug → Diagnostic Actions) enumerates backpack items via
`ReadAllPlayerInventories`, and for each with a Stack component dumps an interpreted int32
table around the component base (flagging `Count +0x18` and the `+0x20` max-size candidate) +
raw hex, and derefs `UnknownPtr(+0x10)` (the max size may instead live in a referenced
StackData/dat row). Writes `logs\InGameStateMonitor.stack_max_probe.log` (readable in Data &
Logs) + a summary MsgBox. Owner test case: one stack of 19 Scrolls of Wisdom (real max 40).
Reuses `_HPP_HexDump` / `_SmResolveServerData`.
- **RESULT (confirmed in-game 2026-07-04):** the max size is NOT on the Stack component
  directly (its +0x20 is a pointer, +0x28 is ~always 0). It lives in the struct the Stack
  component points to at **+0x10** (a SHARED per-base-type `StackSizeData` descriptor — two
  Scroll-of-Wisdom stacks resolved to the same pointer), at **+0x28**: Scroll of Wisdom read
  40, and across a full currency tab the field only ever yielded the real PoE2 caps
  10/20/30/40. (In that descriptor +0x20=5000 = currency-tab cap and +0x24=100 are other
  fields, not the per-item max.) **Wired 0.45.13.160:** `PoE2Offsets.Stack` renamed
  `UnknownPtr`→`StackSizeDataPtr` (0x10) + new `PoE2Offsets.StackSizeData` (`MaxStack` 0x28);
  `PoE2InventoryReader` reads `stackMax` alongside `stackCount` (deref +0x10 → +0x28);
  `WebViewBridge` emits `smax`; the inventory tooltip shows "Stack Size: 19 / 40".

## Max stack size is container-dependent (0.45.13.164)

Follow-up to the max-stack wiring: the StackSizeData descriptor (shared per base type) holds
THREE caps — +0x20=5000, +0x24=100, +0x28=40 for Scroll of Wisdom — and the CURRENT container
selects which applies. The normal inventory uses +0x28 (40); a **currency stash tab** holds
far more (the owner's tab #143 had a Wisdom stack of 1231, and every currency there with
Count > 100 has +0x20=5000), so it selects **+0x20**. So `stackMax` (the +0x28 read) is only
correct for the backpack.
- **Interim UI fix (shipped):** the inventory tooltip shows "/ max" ONLY when Count ≤ max, so
  the nonsensical "1231 / 40" is gone (it now shows just "1231" until the container cap is
  wired). "19 / 40" in the backpack is unaffected.
- **StackMaxProbe extended:** a CONTAINER-SELECTOR SUMMARY table now prints, per inventory,
  the resolved type + the raw `InventoryStruct` +0x00 (InventoryType) / +0x04 (InventorySlot),
  and per stackable item the base path, Count and the three caps — to pin how the container
  selects the field. `PoE2InventoryReader` now exposes `invStructPtr` per inventory for this.
- **CAP FIELDS confirmed:** the descriptor holds +0x28 = NORMAL cap (backpack AND normal
  stash tabs both cap Wisdom at 40 — in-game "40/40" in a "white" tab) and +0x20 = CURRENCY
  stash tab cap (Wisdom = 5000). +0x24 = 100 unused.
- **SELECTOR still open:** the InventoryStruct +0x00/+0x04 read the SAME value in every
  container (a vtable pointer 0x00007FF6…), AND the backpack + currency tab shared identical
  values while their effective caps differ (40 vs 5000) — so the container-type signal is NOT
  in the first 8 bytes of the inventory struct. The first "inventoryId 1 vs stash tab" rule was
  WRONG: it over-reported normal tabs as 5000. Until a reliable currency-tab signal is found,
  the consumer uses **MaxStack (+0x28) everywhere** — correct for the backpack + normal tabs;
  a currency-tab overflow (Count > 40) is hidden by the UI's "Count ≤ max" guard, so it shows
  just the count, never a wrong "/40". `MaxStackTab` (+0x20) is read + kept for when detection
  lands. **Next:** probe a wider inventory-struct range with a currency tab AND a normal tab
  open to locate the differing field (or read the tab's StashType from the tab-metadata vector).
- **RESOLVED without detection (0.45.13.165):** instead of detecting the container type, the
  consumer shows the SMALLEST descriptor cap that still fits the current Count — normal cap
  (+0x28) when Count ≤ it, else the currency-tab cap (+0x20). Since normal ≤ tab, the backpack
  and normal tabs (Count ≤ normal cap) show the normal cap ("19/40", "40/40"), and only a stack
  that already exceeds it (a currency tab, e.g. 1231) escalates to the tab cap ("1231/5000").
  Safe everywhere (never below Count), no fragile tab-id hardcode (#143 is the owner's tab
  POSITION, not a game constant). Tiny stacks in a currency tab show the normal cap — harmless;
  a StashType signal would refine only that case. Logic in `WebViewBridge` (`stkM28`/`stkM20`).

## Currency tab 1:1 layout — RE + bake (WIP, 0.45.13.166)

The currency stash tab is NOT a normal grid: the inventory struct only exposes a LINEAR slot
index (dims 53×4, all items in row y=0, x = fixed per-currency index 0–52, gaps = group
separators). The real 2D layout lives in the **game UI element tree** — owner-found: the slot
container at UI path `[35][2][0][0][0][1][1][0][0][1][1][0][0][1]` (74 children) has one
UiElement per slot carrying its `UnscaledPos` + `Size` and the item at `+0x4F8` (→ currency
metadata path). Since the layout is game-fixed (identical for everyone), reading it once bakes
it. `ahk/CurrencyLayoutProbe.ahk` (`CurrencyLayoutProbeRun`, bridge `CurrencyLayoutProbeRun`,
UI "🪙 Bake Currency Layout" in Config → Debug) navigates that path, collects every
Metadata/Items/Currency slot's absolute unscaled pos + size, and writes
`data/currency_tab_layout.json` (`{container:{x,y,w,h}, slots:[{path,x,y,w,h}]}`, TRACKED
shipped data) + a readable log. **RESULT (probe run 2026-07-04):** the UI-tree positions turned out to be a wide/scattered
INTERNAL layout (base tier far left, greater/perfect far right ~x3400, families keyed by y),
NOT the compact visual grid — the game re-arranges before drawing, so the raw coords can't
drive a 1:1 render. Instead the visual grid was TRANSCRIBED from a clean currency-tab
screenshot cross-referenced with the probe's count→currency mapping (the count=1 ambiguities
in the abyss/omen rows resolved via the probe's collection order, which matches the visual
left-to-right). **Shipped 0.45.13.167:** `WebViewBridge` emits each item's metadata base name
(`it.mp`, last path segment); `ui/index.html` holds the curated `CURRENCY_TAB_LAYOUT`
(base-name → [col,row], cols 0-2 = tier base/greater/perfect) and `_applyCurrencyLayouts(data)`
rewrites each detected currency tab's item sx/sy onto those cells (+ tab bx/by) BEFORE render,
so the existing grid renderer + patcher draw it 1:1 (unmapped/new currencies park in trailing
rows). Detection: ≥5 items match the layout map. **Refined 0.45.13.168 — dedicated renderer:**
replaced the grid-remap with `_renderCurrencyTab(inv)` (routed via `_renderInvSection` + an
`_invDesc` 'html' desc so it's string-cached, not grid-patched). It absolutely-positions one
slot per curated cell — framing ONLY real slots (no full background grid), with inter-group
pixel gaps (`colGapAfter`/`rowGapAfter`) and the central multi-cell slot (`bigSlots`) + the
extra always-empty frames (`emptySlots`). `_itemVisual(it,w,h)` was factored out of
`_invItemCellHtml` and reused. Verified in the preview: 44 items + 5 empty frames, compact
348×360, gaps applied (col 3 at x=120 = 3·36+12). **Refined 0.45.13.169** per feedback: the bottom two rows are a
GENERIC 7×2 misc-currency grid (not bound to specific currencies) filled by slot order (`it.sx`)
— the abyss/omen entries left the fixed `slots` map; the central slot is a 2×4 slot for the
tab's NON-currency item (weapons/gear; `WebViewBridge` now emits an `it.cur` flag from the
`/Currency/` path) and is HORIZONTALLY CENTERED, as are the two empty frames above it;
Identification moved up a row. Verified: big slot centered (x=138, center 174 == grid 174),
2×4, non-currency item placed there, generics in the bottom grid. **Pending in-game verification:** open the
currency tab in the tool's Inventory tab — it should mirror the game grid; report any
mis-placed slot and I fix its [col,row] in `CURRENCY_TAB_LAYOUT`. The probe stays as the
re-bake aid.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
