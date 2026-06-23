# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.13.17`.

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
- **Logs:** `.log` files live in the root **`Logs/`** folder.
- **Data:** `.tsv` files needed for translating internal strings by using a dictionary live in the root **`Data/`** folder.
- **Tools:** `.py` files needed for building the dictionaries live in the root **`Tools/`** folder.

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
  PlayerHUD / RadarOverlay are NOT yet migrated to it.
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
- **Pending (needs the game/Windows):** verify the Winsock listener binds, that
  `OnMessage` fires for the hidden Gui, request/response round-trips, and that the
  config toggle starts/stops the server. The listener only starts at app launch,
  so toggling on requires a restart.

## AutoPilot navigation (v0.45.12.0) — distance-field architecture

Modeled on `myrahz/Radar` (`PathFinder.cs`): never follow a stored path.

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

### Pending (needs the game + Windows)
- Verify the PowerShell fetch (league slug valid, network reachable, PS present), TSV parse,
  Divine→Exalted rate; the inventory diff / kill counts; run resume-by-hash; the two bars'
  placement/auto-hide; session save/load. Prices default OFF (feature `enabled=false`).
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
  - Overlay button: a lazily-built always-on-top, NOACTIVATE Gui (`_SmEnsureGui`);
    `StashMoverTick(radarSnap)` (called from `UpdateRadarFast` after
    `TryLootTrackerTick`) positions it at the grid's top-right and shows/hides it
    based on enable + game-focus + grid-visibility.
  - Config: self-persists `[StashMover]` (`enabled`, `hotkey`, `showButton`,
    `perItemDelayMs`, `settleDelayMs`, `offsetX`, `offsetY`, `skipQuest`, `jitter`,
    `ignore`); `LoadStashMover()` seeds ALL globals unconditionally (init gotcha).
    Default OFF, hotkey empty.
  - Ignore filter: `g_smIgnore` Map(base-type path → display name), built by the
    user from the live inventory. `_SmPushInventory()` (bridge `StashRequestInventory`)
    reads the backpack deduped by path and pushes `updateStashInventory`; clicking an
    item toggles `SetStashIgnore(path,name,on)`. Persisted in `ignore` (RS/US-delimited
    via `_SmIgnoreSerialize/Deserialize`), echoed in the header `ignore` array so chips
    survive a refresh. `_SmShouldSkip(item,now)` drops ignored items from the dump.
  - Safety: quest items are auto-skipped (`_SmIsQuestItem` path match, toggle
    `skipQuest`). After a run, `_SmVerify()` (scheduled ~5×perItemDelay after the last
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
    `allowSell` (default ON) gates the vendor path — off = refuse to act when a vendor
    is open (stash-only safety). Header exposes `allowSell` + `context`; the UI shows a
    "Detected destination" readout (vendor shown in amber as it SELLS).
  - Vendor sell filter: when the destination is a vendor (or "unknown" — a possibly-
    missed vendor, kept safe), each item is classified by `_SmItemCategory` into
    `map` (path `/maps/` waystones) > `currency` (rarityId 5) > `unique` (rarityId 3/4)
    > `gear` (everything else), and skipped (reason "filter") unless its category's
    sell toggle is on. Toggles `sellGear` (default ON), `sellUniques` / `sellCurrency`
    / `sellMaps` (default OFF) — so by default only normal/magic/rare gear is sold and
    uniques, currency and maps are kept. The filter is NOT applied to stash / trade
    (those dump everything, minus ignore/quest/failed). `_SmSellCategoryEnabled` /
    `_SmIsSellingKind` gate it; UI = 4 `.filter-pill`s in the Stash Mover section.
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
  `StashMoveDump` (manual trigger), `StashRequestInventory`, `SetStashIgnore`,
  `ClearStashIgnore`.
- **WebViewBridge.ahk** — `stashMover` block (incl. the `ignore` array) in the header push.
- **ui/index.html** — "📦 Stash Mover" section in **Config → Automation**
  (`det-stashmover`, registered in `_cfgSectionIds`) + `stashMoverSyncFromHeader` +
  the Ignore-filter sub-panel (`updateStashInventory`, `smInvToggle`,
  `smIgnoreRemove`, `stashRenderIgnore`) + the Skip-quest / Randomise / Allow-sell
  toggles + the "Detected destination" readout (from header `context`).

### Pending (needs the game + Windows)
- Verify the `InventoryPanel` StringId resolves and its rect equals the 12×N grid
  (no header/padding) — otherwise nudge `offsetX/offsetY`. Confirm the UI→pixel scale
  on non-16:10 windows (the conversion uses height-scale on both axes, no letterbox
  cull, matching `UiBrowserHandler`; a horizontal-cull/per-axis-scale refinement may
  be needed). Verify the NOACTIVATE button receives clicks without stealing focus, the
  Ctrl-held click sequence actually moves items, and timing (`perItemDelayMs`/
  `settleDelayMs`) is reliable. Destination detection is lenient (grid-visible + has
  items); `id==27` is read only as a stash hint.

## Open / pending (needs the game running)

- Verify real alert matches; banner position/size; WAV playback; `FlashWindowEx` struct; the
  `currentAreaHash` zone-change signal; group colors on radar dots.
- Optional deferred refactor: migrate **PlayerHUD**, then **RadarOverlay**, onto `GdiOverlayBase`.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
