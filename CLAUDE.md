# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.13.113`.

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
- **Pending (needs the owner):** run "🧭 Scan matrix offset" near a monster and read
  `autopilot_matrixscan_*.txt`. The winning `base+0xOFF [layout]` gives the corrected
  `PoE2Offsets.WorldData["W2SMatrix"]` (and whether a pointer-deref / transpose is needed); apply
  that, then AutoPilot projection is fixed.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
