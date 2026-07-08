# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.13.291`.

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
- When a change can only be verified in-game, say so and list exactly what to check.
- **Bump the version after every change.** Increment the last segment of the version
  number on each adjustment — in **all three** of `InGameStateMonitor.ahk`
  (`POEFORMANCE_VERSION := "x.y.z.N"`), `CLAUDE.md` (the `Version` line above), and
  `README.md` (the `version-vX.Y.Z.N` badge), e.g. `0.45.12.2` → `0.45.12.3`. Keep all
  three in sync. **The dev branch owns the version** — it is the single source of truth.
  Always count up from the dev branch's own latest value; never reset it to match
  `master`. `master` is not bumped independently, so on merge the dev-branch version
  always wins (resolve any version-line conflict by taking the dev-branch value).
  A **merge driver automates this for LOCAL merges**: `.gitattributes` maps the three
  version files to `merge=poever` (`tools/git-merge-version.py`), which keeps the higher
  version on a version-only conflict (direction-independent). It needs a one-time local
  setup — `sh tools/setup-git-merge-driver.sh` (or `tools\setup-git-merge-driver.bat`) —
  since the driver definition lives in `.git/config`, not the repo. GitHub's web "Merge"
  button does NOT run merge drivers, so merge LOCALLY to benefit
  (`git checkout master && git merge <dev-branch> && git push`).
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

## Custom landmark labels on the radar (shipped 0.45.13.123)

Draws curated, human-readable labels on the radar for known terrain tiles — boss arenas (with
their reward, e.g. "Beira of the Rotten (10% Cold Res)"), named POIs, and area-transition
destinations. Ports `CustomLandmarkData.cs`: a big JSON keyed by area code → tile-path pattern
→ label, matched by SUBSTRING against the tile paths we already scan.

- **`data/custom_landmarks.json` (committed source data)** — the full label map: 91 area codes,
272 entries, plus a global `*` bucket. Keys look like
`"Metadata/Terrain/Woods/Slash/HagWitchArena_01.tdtx:5-y:0"` → `"Beira of the Rotten (10% Cold Res)"`.
  Tracked (NOT gitignored).
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

Implementation (`ahk/UiTreeBrowser.ahk`): `UiTree_ScaleCtx(reader, hwnd)` (client rect + cull +
v1/v2, one cheap ReadInt; cull sanity-clamped to 0), `_UiScalePair(idx, mult, sc)`,
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
**Hotfix 0.45.13.142 — hover-price died; hardened against bad memory scale data:** first
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
**UI Browser hover highlight (0.45.13.143):** hovering a node in the CHILDREN list (and in
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
**Header-sync isolation + JS→AHK error log (0.45.13.147):** follow-up to a "Vitals Life/
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
**RESULT (confirmed in-game 2026-07-04):** the max size is NOT on the Stack component
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

## Actor animationId decode + offset-drift investigation (WIP, 0.45.13.176–178)

Surface the Actor component's `animationId` as a readable name in the Entity Inspector, and
chase down why it (and the whole Actor block) stopped tracking the character.

- **Readable name (0.45.13.175–176):** the Actor whitelist already emits `animationId`; the
  inspector now resolves it via `ANIM_NAMES` in `eiPrettyValue` → `"<id> · <name>"` (or
  `"<id> · (unknown)"`). The name table `ui/animation_names.js` is now generated from the
  hand-maintained **`ahk/AnimationID.ahk`** (1084 CastType entries, up to 0x43B) instead of the
  older GameHelper2 `Animation.cs` — `tools/poe_tools.py gen-anim` reads the local file.
- **Live-refresh fix (0.45.13.177):** the inspector's lazy-decode cache was only invalidated on
  range-exit, so a decoded Actor froze on the value read at click time. `updateEntityInspector`
  now silently re-decodes every currently-EXPANDED lazy component each snapshot
  (`_eiRefreshExpandedLazy`, `refreshInFlight`-guarded), and the AHK `_DecodeComponentOnDemand`
  re-reads live — so expanded fields update continuously. This did NOT fix `animationId`: it
  stays frozen while acting → the value at `Actor+0x8A0` no longer changes.
- **CONCLUSION: Actor offset drift.** Like the W2S-matrix (−8) and AreaInstance (+0x18) drifts, a
  patch shifted the Actor struct, so `PoE2Offsets.Actor["AnimationId"] = 0x8A0` (from the owner's
  CE inspector / CT) now points at a stale field. The counts (ActiveSkills/Cooldowns/Deployed)
  read plausibly, so it may be a small local shift rather than a whole-struct move.
- **`ahk/ActorProbe.ahk` (RE aid, 0.45.13.178):** `ActorProbeRun` resolves the local player's
  Actor component and TIME-SAMPLES a 4 KB int32 window (`Actor+0x000..0xFFC`) ~60×/80 ms while
  the user runs/casts, tracking distinct values per offset. It reports the offsets that CHANGED,
  ranked with an animation-id band first (non-negative, ≤8192, ≤32 distinct — the animationId is
  the low-int one cycling 0=Idle/4=Run/skill ids), flags the current `0x8A0`, and cross-checks the
  known vector-count offsets to tell a local shift from a whole-struct move. Writes
  `logs\InGameStateMonitor.actor_probe.log`. Bridge `ActorProbeRun`; UI "🎭 Probe Actor" in the
  RE-tools row. Reuses `_AIP_ResolveAreaInstance` + `_AIP_WriteProbeLog`.
- **FIXED — animationId 0x8A0 → 0x8B0 (+0x10) (0.45.13.179):** the probe (owner run) proved it.
  Old `0x8A0` was FROZEN at 0 while acting; `+0x8B0` cycled through Idle(0) / FixedRun(195) /
  DodgeRoll(268) / DodgeRollBack(402) / SprintEnd(872) AND the cast skills' CastTypes
  (OrbOfStorms 474 / Flamewall 472 / SparkAdditive 299) — i.e. the primary current-animation field
  (the separate `0x380` cluster held only locomotion-LAYER anims like FixedRunLayerBaseSwitched, so
  it is NOT the field). `PoE2Offsets.Actor["AnimationId"] := 0x8B0`. The **vector offsets were NOT
  moved**: ActiveSkills@0xB08 (42) and Cooldowns@0xB20 (4) still read clean plausible counts at the
  old offsets (a whole-struct shift would read garbage there), and DeployedEnts="?" only means the
  vector is empty (0 deployed → begin=end=0), not a wrong offset — so only the animationId field's
  location changed. `ActorProbe` stays as the re-drift aid; it reads the offset dynamically so it
  keeps working after the fix.
- **Pending in-game verification (owner):** Entity Inspector → player → Actor → `animationId` should
  now show Idle standing, "Fixed Run" moving, and the skill name while casting.
- **Vector offsets under review (0.45.13.180):** owner reports ActiveSkills=42 (char has only 9
  skills) and a Cooldowns count frozen at 4 — so ActiveSkills/Cooldowns/DeployedEntities may have
  drifted too (or 42 is the full granted-skill table + 4 is legitimately the count of cooldown-capable
  skills; unconfirmed). `ActorProbe.ahk` gained `ActorVectorProbeRun` (bridge `ActorVectorProbeRun`,
  UI "🧬 Probe Actor Vectors"): reads each vector at the CURRENT offset AND current+0x10, DECODES the
  first entries (ActiveSkills→detailsPtr→castType/cdMs; Cooldowns→datId/maxUses/cdList secs;
  Deployed→entityId/datId/type), and scans 0xAE0..0xC48 for vector-shaped pointer pairs — so the
  correct offset is chosen by CONTENT (valid detail pointers + sane castTypes), not a plausible-looking
  count. Pending: owner runs it in-game, sends `logs\InGameStateMonitor.actor_vector_probe.log`; then
  re-base `PoE2Offsets.Actor` ActiveSkills/Cooldowns/DeployedEntities (+their `*Last`) if the +0x10
  variant decodes cleanly and the current one is garbage.
- **RESULT — vectors are CORRECT, not drifted (0.45.13.181):** owner ran `ActorVectorProbeRun`.
  ActiveSkills@0xB08 decoded 42 entries with 10/10 valid detailsPtrs, while +0x10 gave count=155587
  and garbage → **0xB08 is right**; 42 is the actor's full granted-skill table (not the 9 equipped
  gems). Cooldowns@0xB20 decoded 4 entries with real datId/maxUses and clean cdMs (8000/10000 ms) →
  **0xB20 is right**; the count legitimately stays 4 (number of cooldown-capable skills; the live
  timers live inside each entry's `cdList`, not in the list size). DeployedEntities was empty (no
  minions/totems out) so unverifiable now — left as-is. **So only `animationId` drifted (+0x10, already
  fixed); the vector offsets stay.** Fixed the Section-A `Format` bug (`{:<n}` → `{:-n}`; AHK left-align
  is `-`, not `<`). Open follow-up (out of scope, not the reported issue): the sampled ActiveSkills
  entries decoded `castType=0/useStage=0/cdMs=0` — either those first table rows are non-cast granted
  effects, or `ActiveSkillDetails` inner offsets (CastType 0x0C / TotalCooldownTimeInMs 0xE8) also
  drifted; verify against a known equipped skill before trusting per-skill castType.

## Animated component: .ao model path (shipped 0.45.13.182)

Owner-supplied offsets to read the loaded **.ao model file path** off the Animated component —
it distinguishes otherwise-identical entities that share a metadata path but load different
models (e.g. the different ExpeditionMarker flag variants). Chain: `Animated+0x358` → model-info
object → `+0x18` → file record (FileInfoValue) → `+0x08` StdWString = the .ao path.

- **`PoE2Offsets.ahk`:** `Animated["ModelInfoPtr"] = 0x358`; new `AnimatedModelInfo["ModelFileRecordPtr"]
  = 0x18`; new generic `FileInfoValue["Name"] = 0x08`.
- **`PoE2ComponentDecoders.ahk` (`DecodeAnimatedComponentBasic`):** walks the chain and adds
  `modelPath` to the returned Map (empty string if unresolved). NOT on the radar hot path —
  `DecodeSampleEntityComponentsRadar` doesn't decode Animated at all; this runs only in the full
  `DecodeSampleEntityComponents` (inspector/browser) pass, so the extra StdWString read is off the
  per-frame tick.
- **`SnapshotSerializers.ahk`:** `modelPath` added to the `animated` inspector whitelist → shows in
  the Entity Inspector's Animated component (row omitted when empty).
- **Pending in-game verification:** open the Entity Inspector on an Animated entity (e.g. an
  ExpeditionMarker) → the Animated component should list `modelPath` = its `.ao` file; two entities
  with the same metadata path but different flags should differ here. Available for entity
  differentiation (grouping/labels) if wanted later.

## Enemy animationId in the radar hot path (shipped 0.45.13.184)

The Actor `animationId` was only read in the full (inspector/browser) decode, not per-frame. Now
each cached MONSTER entity's animationId is refreshed live on the radar tick so combat/consumers
can react to the enemy's current animation / cast.

- **Where:** `PoE2EntityReader.UpdateCachedEntityRadar` — the cheap per-tick cache update (Phase 3
  of the `PoE2MemoryReader` radar cache; new/changed entities full-decode in Phase 2, existing ones
  cheap-update here every tick round-robin). The existing monster-gated component pass (which already
  finds Targetable) was extended to ALSO grab the Actor component in the SAME in-memory loop and do a
  single `ReadInt` of `Actor.AnimationId` (0x8B0). Stored under `decodedComponents["actor"]
  ["animationId"]` — same key as the full decode, so consumers read it uniformly.
- **Cost:** gated to `metadata/monsters/` paths (items/terrain/effects/chests skip it); one extra
  `ReadInt` per monster per cheap-update, reusing the already-cached component list (no extra
  component lookup / RPM beyond the one int). Off entirely for non-monsters.
- **Consumption:** available on every awake monster sample at
  `entry["entity"]["decodedComponents"]["actor"]["animationId"]` (AHK snapshot). Also serializes into
  the Entities-tab inspector (the `actor` whitelist), so a monster's Actor row shows the live
  animationId — a convenient in-game verification.
- **Pending in-game verification:** watch a monster's Actor → animationId in the inspector while it
  idles/moves/casts → it should change (0=Idle, movement, skill CastTypes). Decode the number via
  `ui/animation_names.js` if needed.

## Enemy-animation MACRO CONDITION (shipped 0.45.13.186)

Consumes the hot-path enemy animationId as a new **Macro Engine condition** rather than a standalone
feature. Rationale (owner): the reaction is primarily for MANUAL play (and may also fire under
AutoPilot), so it belongs in the Macro Engine's boolean condition tree — where the user attaches ANY
action (a dodge/guard/defensive key, a flask, a chain) — not under Automation. The standalone
`CombatReaction` feature shipped at 0.45.13.185 was REMOVED and replaced by this.

- **Condition type `enemyAnim` (`ahk/CustomHotkeys.ahk`):** `_HotkeysIsCondType` + `_HotkeysEvalLeaf`
  gain `enemyAnim`; `_HotkeysCheckEnemyAnim(a, snap)` returns true iff any hostile monster within the
  configured radius is CURRENTLY playing one of the leaf's animation ids. Mirrors
  `_HotkeysCheckMonsterCount`'s monster gate (path `metadata/monsters/`, targetable, not friendly)
  and its radius modes (world units via `worldRadius` / `radius` px `player`|`cursor`, reusing
  `_HotkeysPxOrigin`/`_HotkeysPxDist`); the animation match reads
  `decodedComponents["actor"]["animationId"]`. Leaf fields: `animIds` (comma id list, parsed by
  `_HotkeysParseIdSet` → id-set), `radiusMode`, `worldRadius`/`radius`. Debug: an `enemyAnim` branch
  in `_HotkeysBuildDebugRecord` draws the range circle + a live `MATCH / no match` line.
- **UI (`ui/index.html`):** `enemyAnim` added to `HK_COND_TYPES`, the add-condition `<option>` list,
  `HK_ACT_LABELS`, `hkActionDefaults` (`{animIds:'', radiusMode:'world', worldRadius:1200, radius:120,
  debug:0, circleColor:'#FF6A6A'}`), a `hkRenderCondLeaf` `case 'enemyAnim'` (IDs text via `hkCTxt` +
  radius + radiusMode), `animIds` added to `hkSetCond`'s text-key list, and the debug range-circle
  swatch now shows for `enemyAnim` too. No new persistence path — it rides the existing hotkey config.
- **Name-based picker (0.45.13.187):** nobody knows the 1084 numeric ids by heart, and a flat
  dropdown is unusable — so the condition's animation field is a **typeahead by NAME** (chips), not a
  raw id box. `hkAnimPicker` renders the selected animations as removable name chips + a search input
  bound to a shared `<datalist id="anim-names-list">` built once from `ANIM_NAMES` (id→name, from
  `ui/animation_names.js`) as `"<Name> — #<id>"` options. `hkAnimAdd` accepts a datalist pick, a bare
  id, an exact name, or a comma list of those (parses the trailing `#<id>`, else numeric, else
  `hkAnimNameToId`); `hkAnimRemove` drops a chip. The leaf still stores `animIds` as a comma id
  string (AHK unchanged). `hkBuildAnimDatalist()` runs on `load` + lazily in the picker. Parsing
  validated against the real 1084-entry map (name / raw / datalist / mixed list all resolve).
- **Collecting ids for a specific boss attack:** still discoverable via the Entities tab → a monster
  → Actor → `animationId` while it attacks; but for anything with a known name you now just search it.
  Attach the hotkey's normal key action (dodge / guard / flask) as the reaction.
- **Live capture (0.45.13.188) — `ahk/HkAnimCapture.ahk`:** the discovery killer. A "👁 live" toggle on
  the enemyAnim leaf arms capture; the user stands near the monster/boss, lets it attack, and clicks
  the animation that lit up — no ids or names needed. `TryHkAnimCapture(radarSnap)` (from
  `UpdateRadarFast`, NO-OP unless armed) scans the awake sample for hostile monsters and accumulates
  each `decodedComponents["actor"]["animationId"]` into `g_hkAnimCapSeen` (id→count/last/nearest-dist),
  resets on area change, prunes entries older than 8 s, and pushes `updateAnimCapture([{id,count,dist,
  age}])` to the WebView ~4 Hz. Bridge `HkAnimCaptureStart`/`HkAnimCaptureStop`; `LoadHkAnimCapture()`
  seeds globals (no persistence — transient tool). UI: `hkAnimCapToggle` arms one leaf at a time (also
  stopped on macro-tab exit + on deleting the armed leaf); `updateAnimCapture` renders a clickable
  live strip under the leaf (name via `ANIM_NAMES`, ×count · dist, a red "fresh" glow when age<700 ms),
  each row calling `hkAnimAddId` to add its id. Verified in the browser preview: leaf render (chips +
  search + live button), the strip populates/sorts/labels (known + unknown ids, fresh glow), and the
  empty state — end to end.
- **Turbo fishing path (0.45.13.189):** short animations (a 200–400 ms slam) can slip past the normal
  round-robin sample, and the 50 ms tick's GDI + secondary reads block the single AHK thread. So while
  armed, capture TAKES OVER the radar tick with a stripped fast loop: `StartHkAnimCapture` bumps the
  `UpdateRadarFast` timer to `g_hkFishIntervalMs` (10 ms) and the tick early-branches to
  `HkAnimFishTick()` (returns before ANY GDI overlay / AutoPilot / loot / alerts / stash / … run).
  `HkAnimFishTick` refreshes the monster Actor-address list only ~every `g_hkFishHeavyMs` (300 ms) via
  one `ReadRadarSnapshot()` (`_HkFishCollectMonsters` → hostile/targetable/non-friendly monsters'
  Actor comp addr + dist), and EVERY tick reads each animationId DIRECTLY (`Mem.ReadInt(addr +
  Actor.AnimationId)`) into `g_hkAnimCapSeen` — a ~10 ms sample rate that reliably catches brief
  animations (they also linger 8 s in the feed so there's time to click). UI push stays throttled
  (`g_hkFishPushMs` 45 ms). `StopHkAnimCapture` restores the normal `g_hkFishNormalMs` (50 ms) tick.
  Overlays freeze on their last frame during fishing (acceptable for a brief, deliberate mode).
  **Pending in-game verification:** arm 👁, stand at a boss, let it do a quick attack → the brief
  animation should still appear (and glow "fresh"); confirm the overlays resume and the tick returns
  to normal on stop.
- **Live-capture UX fixes (0.45.13.190):** three issues with the feed, all rooted in the old
  full-`innerHTML`-rewrite every push. (1) On STOP the results now FREEZE instead of vanishing —
  `_hkAnimCap` gains `live`+`rows`; a stopped strip stays visible (grey "frozen" style, a "captured
  (stopped)" label + a "✕ clear" button) and its rows remain clickable until cleared or you leave the
  macro tab. (2) Clicks now register — the feed is patched by an INCREMENTAL, keyed-by-id DOM update
  (`_hkAnimCapPatch`, called from `hkRender` + each push) so a row's `<button>` element is STABLE
  (never recreated mid-frame); rows fire on `onmousedown` (atomic) so a press lands even if a push
  arrives immediately. (3) No duplicates — one DOM element per id (keyed) + a defensive dedupe-by-id
  when storing the pushed rows. The strip is now a static shell (`_hkAnimCapStripHtml`: label + clear +
  a `.hk-anim-cap-rows` container) that the patch fills. Verified end-to-end in the browser preview:
  dedupe (4 rows w/ a dup → 3 buttons), element stability across pushes, click-to-add (live AND
  frozen), freeze-on-stop, and clear.
- **Removed:** `ahk/CombatReaction.ahk` + its wiring (`#Include`, `LoadCombatReaction`,
  `TryCombatReaction`, `SetCombatReaction`, the `combatReaction` header, the Automation → AutoPilot
  "⚔️ Combat Reaction" UI section + `combatReactionSyncFromHeader`).
- **Pending in-game verification:** add an `enemyAnim` condition to a macro (IDs = a monster's attack
  animationId, radius, a dodge/guard key action), stand near that monster → the macro fires on that
  animation and not otherwise; the 🐞 debug shows the range circle + live MATCH state.

## Performance pass + reader-split foundation (0.45.13.192–202)

A measure-first performance investigation that removed the worst per-tick costs with cheap,
single-process fixes, then laid the foundation for a multi-process architecture. **Full design +
rationale: `docs/reader-split.md`.** Motivation for the split is HEADROOM for future read-heavy
features (a detailed DPS meter / death recap especially), NOT the current numbers.

### Profiler tooling (how to measure — use this before "optimising" any read)

- `ahk/Profiler.ahk` — QPC per-label timing, disabled by default (near-zero when off). Two-click
  flow: **Shift+F3** (or click the ⏱ status pill) starts a measurement window, press again to stop.
  On stop it appends the table to `logs\InGameStateMonitor.profiler.log` (readable in **Data &
  Logs**), with a header stamping area + `awake=<sampleCount>` + `raw=<mapSize>`. This file dump is
  what makes real-play measurement possible (the game is foreground, not the WebView).
- Per-tick sub-markers already exist and are the map of the tick: `tick.read` (=`read.state/world/
  ui/entities/sleep/filter`), `tick.overlays` (per-overlay `ov.*` + `radar.mask.*`), `tick.autopilot
  /alerts/loot`. `read.world` and `read.entities` are further split (`read.world.terrain/area/matrix/
  player`; `read.ent.zonescan/bfs/decode.new/decode.changed/cheap`). **Lesson, twice proven: an
  "expensive marker" is often a bug/redundancy, not a fundamental cost — sub-mark and MEASURE before
  building a fix** (the terrain hypothesis for read.world was wrong; it was a double stats read).

### Shipped single-process fixes (do not regress these)

- **read.world 112→2 ms** — `PoE2PlayerReader.BuildVitalsResult` read the player Stats component
  TWICE per vitals tick (once for Rage, once for Spirit), each doing two full stats-array scans.
  Fix: read it ONCE (dedup) + `_CachedPlayerStatsComponent()` (~500 ms TTL, keyed on the player
  pointer; rage/spirit change slowly, Life/Mana/ES stay fresh).
- **radar.mask 55→8 ms** — the maphack/walk mask blit (`_BlitMaskLayer` PlgBlt) is a per-frame
  rotated software blit filling the window. The projection (cos/sin) is frame-CONSTANT — only the
  player position moves — so `RadarOverlay._DrawMapLayersCached` renders the composited layers ONCE
  into a padded off-screen cache (window + 2×`MASK_CACHE_MARGIN`) via PlgBlt, then per frame copies
  it with a translated `msimg32\TransparentBlt` (key 0xFF00FF; offset = the player screen delta).
  Rebuild only on scroll past the margin / projection change / terrain regen. `_DrawMapLayersDirect`
  is the fallback (never worse than the old path).
- **read.entities junk pre-filter** — in dense combat ~half the awake map is junk (effects/
  projectiles: `raw=182` vs `awake=96`) that was fully decoded then dropped by the sample-build
  junk filter. Fix: in Phase 2, a cheap `ReadEntityIdentityBasic` (id+flags+path) runs before the
  full `ReadEntityBasic`; junk paths skip the decode + caching and their id→rawPtr is remembered in
  `_radarJunkIds` (Phase 1 then skips them with no RPM; rawPtr guard handles recycled ids). Cleared
  on area change + on any junk-filter change (`RebuildJunkActive` reaches into `g_reader`). Safe: the
  SAME `IsJunkEntity` already ran at sample-build, so nothing is newly hidden. Cut decode.new ~35 %,
  cheap ~50 %, and the read tail 1.5 s → 0.4 s.

### Reader-split infrastructure (stage 1 — SHIPPED + proven; stages 2–5 pending)

The generalisable transport for moving reads off the render thread. See `docs/reader-split.md` for
the staged plan (2 = reader-process scaffolding, 3 = radar snapshot to the reader, 4 = on-demand
decode channel, 5 = DPS sampler).

- **`ahk/SharedMem.ahk`** — `SharedMemBlock(name, bytes)` = named pagefile-backed file mapping
  (`CreateFileMapping(-1,…)`/`MapViewOfFile`; one process creates, others open the same name; isOwner
  from `ERROR_ALREADY_EXISTS`). `Put/Get` U32/I32/I64/F32 + `PutBytes/GetBytes` + `Clear`. `SeqLock
  (block, seqOffset)` — single-writer/single-reader: `WriteBegin/WriteEnd` bracket a write (seq odd
  while writing), `Read(copyFn)` retries until a stable EVEN sequence around the copy and returns ""
  on a mid-write collision (→ use last value; STALENESS, never a torn payload). Pure DllCall, no
  deps, classes-only (safe to #Include anywhere). Verified cross-process (torn=0 over ~62k reads
  while a writer wrote ~300k times).
- **The sampler pattern** — each read-heavy feature becomes its OWN process that owns its raw
  high-frequency reads + computation and publishes a compact DIGEST via shared memory; the main app
  renders the digest and never touches raw memory for that feature. Offsets stay compile-time
  `#Include` (only the wire-struct needs sync, guarded by a `VERSION`/`MAGIC`). A_TickCount is
  system-wide, so heartbeats/ages are consistent across processes. Absolute addresses one process
  reads are valid in another's handle (same target process).

### First sampler: anim-fishing out-of-process (0.45.13.202)

The live enemy-animation capture (Macro Engine `enemyAnim`) moved off the render thread — it used to
HIJACK the radar tick into a 10 ms turbo loop that froze every overlay.

- **`ahk/HkFishProtocol.ahk`** — the shared wire layout, #Include'd by BOTH sides. Region A
  (Main→Fisher) = monster Actor-component addresses + distances; Region B (Fisher→Main) = animId→
  {count,last,dist} rows; a control header (run flag, `Actor.AnimationId` offset, both heartbeats);
  two seqlocks.
- **`poef_fisher.ahk`** (repo-root entry point) — the lean sampler process: only SharedMem + the
  protocol + `ProcessMemory` (its OWN PoE handle). Every ~10 ms it reads the published addresses and
  each monster's animationId, accumulates the table, publishes it back. Exits on run=0 or a stale
  Main heartbeat; silent on transient errors.
- **`ahk/HkAnimCapture.ahk`** — TWO backends. `"proc"` (preferred): publishes the address list
  (free — Main already has the radar snapshot) via `TryHkAnimFishPublish(radarSnap)` in the NORMAL
  tick flow and renders the digest, NO tick hijack → overlays keep rendering. `"inproc"` (fallback):
  the unchanged legacy turbo path (`HkAnimFishTick`, timer bumped), used only if shared memory / the
  fisher can't start → never worse than before. Main owns the block (`LoadHkAnimCapture`), spawns/
  kills/heartbeats the fisher, `OnExit` guarantees no orphan. `AutoFlask.ahk` hijack branch now fires
  only in inproc mode.
- **Verified in-game (2026-07-05):** the fisher process starts on arm / stops on disarm, reads enemy
  animationIds correctly, the round-trip digest is bug-free, and (the whole point) the main tick keeps
  rendering the overlays during fishing. The Stage-1 foundation (shared memory + seqlock + lifecycle
  + the sampler pattern) is thus proven end-to-end on a real feature.

### Stage 3a: the radar-snapshot wire format + offline harness (0.45.13.207)

The high-stakes step — moving the radar snapshot to the reader — starts with the WIRE FORMAT, proven
losslessly offline BEFORE any hot-path wiring (safety principle 3: never worse). Full design +
record contract in `docs/reader-split.md` (Stage 3 design). This cut adds the format only; it is NOT
yet #Included by the running app, so it touches zero hot-path code.

- **`ahk/PoefRadarProto.ahk` (new)** — the shared byte layout for the radar snapshot block (a SEPARATE
  named mapping `Local\PoEformanceRadarSnap` from the stage-2 status block). A fixed header + one
  seqlock-guarded payload: `MAX_RECORDS`=512 flat per-entity records (`RECORD_SIZE`=120 B) + a
  `HEAP_BYTES`=128 KB interned UTF-8 string heap (paths). Each record carries exactly the leaf fields
  a full 21-file consumer audit found are read off `decodedComponents` on the radar path — render
  (worldX/Y/Z, terrainHeight; gridPosition derived), life (curHP/maxHP/isAlive/lifeCurrentPercentMax),
  positioned (reaction → isFriendly), rarityId, chest (opened/labelVis/strongbox bits), targetable
  (a BARE BOOL on the radar path), actor (animationId) — plus the Targetable/Actor **component
  addresses** for consumers that walk `entity["components"]` for a live re-read. A `R_PRESENCE`
  bitfield gates which components are present. Classes-only (safe to #Include anywhere).
- **`ahk/RadarSnapshotWire.ahk` (new)** — `RadarWirePack(blk, lock, sample, px,py,pz, areaHash)`
  (reader side: serialise the awake sample under the seqlock, dedup paths into the heap, flag
  truncation past 512) and `RadarWireUnpack(blk, lock)` (main side: copy the block out under the
  seqlock — staleness on a mid-write collision, never torn — then RECONSTRUCT the exact nested-Map
  `awakeEntities.sample` shape so NO consumer changes, safety principle 1). Handles the three shape
  nuances the audit pinned: targetable rebuilt as a bare bool (defensive against a Map form), life
  populated in BOTH flat (`curHP`/`maxHP`) and nested (`life["life"]["current"/"max"]`) forms, and a
  minimal `entity["components"]` = `[{name:"Targetable",address},{name:"Actor",address}]` rebuilt for
  the live-re-read walkers (CombatAutomation / ExplorationModule / HkAnimCapture / EntityFocus /
  PoE2MemoryReader). Deep inspector fields (`components` full array, `mods`, deep dumps) are NOT
  carried — not hot-path; they stay on Main's own on-demand read (stage 4). Reconstruction fills
  `componentCount`/`namedComponentCount`/`decodedComponentCount` best-effort so those consumers never
  error (minimal numbers, not the full decode — an accepted degradation for the opt-in path).
- **`ahk/SharedMem.ahk`** — added `PutU8`/`GetU8`/`PutU16`/`GetU16` (byte/word accessors the record
  bytes + heap length-prefixes need).
- **Offline harness (scratchpad `radar_wire_test.ahk`)** — the doc's testing strategy: builds synthetic
  sample entries covering every component combo (full monster, opened strongbox, friendly minion,
  currency ground item, empty/invalid entity, targetable-as-Map), packs → unpacks → asserts every
  carried leaf survived. **27/27 pass**, incl. unicode paths, gridPosition derivation, 600→512
  truncation + the truncated flag, and a forced mid-write (odd seq) read returning `ok=false`. Not
  committed (harnesses live in scratchpad, like `ui_scale_test.ahk`). AHK v2 lesson re-confirmed: the
  interpreter refuses function definitions interspersed between top-level executable statements —
  group all `func(){}` defs before the executable body (or the whole script fails to load with no
  runtime error / OnError never fires).
  
### Stage 3b: reader publishes the awake sample + parity diagnostic (0.45.13.208)

The reader now PACKS the awake-entity sample into the radar block each tick, and Main cross-checks it
against its own live sample — the gate before stage 3c flips Main to CONSUME it. Same safe posture as
stage 2: the reader independently produces data, a diagnostic proves parity; **Main's live  path is
untouched** (it just reads the block on demand for the check).

- **`ahk/PoE2MemoryReader.ahk` — `ReadAwakeEntitiesFlat(areaInstanceData, currentAreaHash, playerOrigin)`
  (new):** a SELF-CONTAINED copy of ReadRadarSnapshot's awake-entity scan (BFS → decode new/changed →
  cheap-update → build sample) with its OWN cache state (`_flat*` props, separate from the live
  `_radar*` cache so it never touches Main's hot path) and a generous decode budget (the reader has no
  render competing). It does NOT apply the junk filter — the reader publishes everything and Main
  derives the junk verdict on consume (config-dependent data stays in Main). Mirrors the live scan's
  phases so the published sample matches what Main builds. **Currently DUPLICATES the live
  orchestration** (reusing the same helpers `ScanEntityMapIdsAndPtrs`/`ReadEntityBasic`/
  `UpdateCachedEntityRadar`/…); the duplication resolves in 3c when Main's inline scan is replaced by
  consuming the reader.
- **`ahk/PoE2MemoryReader.ahk` — `ReadAwakeFlatForPublish(inGameStateAddress)` (new):** resolves
  area+player from a given inGameState addr (the reader already has it from its lightweight
  `ReadAutoFlaskSnapshot`, so this avoids re-running the 12-state resolve) and returns
  `Map(sample, areaHash, playerX/Y/Z)` for the wire pack.
- **`poef_reader.ahk`:** #Includes `PoefRadarProto` + `RadarSnapshotWire`, opens the radar block by
  name, and each in-game tick calls `ReadAwakeFlatForPublish` → `RadarWirePack` (guarded so a transient
  read never crashes the reader or blocks its status heartbeat) + writes `O_RDHEART`.
- **`ahk/ReaderProcess.ahk`:** Main OWNS the radar block — `LoadReaderProcess` creates it + stamps
  MAGIC/VERSION (alongside the stage-2 status block). New `RadarConsumeDiagnose()` unpacks the reader's
  latest sample and cross-checks it vs Main's live `g_radarLastSnap` sample: matched-by-id count, path
  mismatch, world-X mismatch, "only in reader" (= junk Main filters, expected) and "only in main"
  (must be 0 — Main should never have an entity the reader lacks) + areaHash MATCH + a frame counter
  that must increase between clicks.
- **`ahk/SharedMem.ahk` / `ahk/PoefRadarProto.ahk`:** `O_RDHEART` added to the radar block header
  (reader heartbeat) so the diagnostic can show the publish liveness.
- **Wiring:** `BridgeDispatch` case `RadarConsumeDiag` → `RadarConsumeDiagnose`; UI **Config → Debug →
  Diagnostic Actions**, next to "🔌 Reader status", a "📡 Radar parity" button (in the reader-process
  help block).
- **Static verification:** the full reader stack (`poef_reader.ahk` include chain) parse-loads clean
  (offline harness `ld_reader.ahk` confirms both new methods exist on the class), the reader entry
  point loads and self-exits correctly when Main's run flag isn't set, and all edited files brace-check.
- **Pending in-game verification:** enable "🔌 Reader process", get in-game, click "📡 Radar parity"
  repeatedly — the frame counter should climb, areaHash should MATCH, matched-by-id should be most of
  Main's sample, path/pos mismatches 0, and "only in main" 0 (the reader's extra entries are the junk
  Main filters). That confirms the reader builds the same awake sample Main does, gating stage 3c.
- **Verified in-game (2026-07-05, stage 3b):** parity is byte-perfect in the SETTLED state — a stable
  area with a fresh reader heartbeat gave matched 25/25, path mismatch 0, pos mismatch 0, only-in-main
  0, areaHash MATCH. The nonzero mismatches seen while moving/in combat (a few pos/only-in-main) are
  pure TEMPORAL SKEW (two async scans sampling at slightly different instants), and one sample with a
  ~20 s stale heartbeat was a frozen publish — both are exactly what stage 3c's freshness gate handles.

### Stage 3c: Main consumes the reader's sample, with fallback (0.45.13.210)

The payoff: when the reader is publishing a FRESH sample for the current area, Main skips its own
~40 ms entity scan and rebuilds the awake sample from the reader's flat records. A SECOND opt-in
toggle keeps it separable from 3b so the parity check can gate it.

- **`ahk/PoE2MemoryReader.ahk` (`ReadRadarSnapshot`):** right after the zoneScan block, a consume
  branch: if `ReaderConsumeEnabled()` and `ConsumeReaderRadarSample(currentAreaHash)` returns a fresh
  same-area snapshot, Main builds `awakeSample` (junk-filtered Main-side) + `currentEntities` +
  `fullAwakeRawPtrs` (from the FULL reader set incl. junk, so the stale filter's network-bubble check
  still works) from the reader's records and sets `consumed=true`. The whole existing scan
  (BFS/decode/cheap/build) is wrapped in `if (!consumed) { … }`, so on ANY failure (consume off,
  reader off/stale/area-mismatch, mid-write unpack) Main runs its own scan exactly as today (never
  worse). The Main-side zoneScan accumulation + `_FilterStaleRadarEntities` then run on the
  reconstructed sample unchanged — and the filter LIVE-RE-READS the Targetable byte from the carried
  component address, so dead-entity detection + LootTracker kill counting stay fresh even though the
  reader's decoded targetable may lag. `RadarTimings["consumed"]` (0/1) flags which path ran.
- **`ahk/ReaderProcess.ahk`:** `ReaderConsumeEnabled()` (both toggles on + block exists),
  `ConsumeReaderRadarSample(currentAreaHash)` (freshness gate `O_RDHEART` age < 300 ms + area gate →
  RadarWireUnpack, else 0), `SetReaderConsume` (persist `[Diagnostics] readerConsume`),
  `BuildReaderConsumeHeaderJson`. `LoadReaderProcess` seeds `g_rpConsume` + reads the INI.
- **Wiring:** `BridgeDispatch` case `SetReaderConsume`; `WebViewBridge` pushes `readerConsume`; UI
  **Config → Debug → Diagnostic Actions**, a "📥 Consume reader sample (split stage 3c)" toggle under
  the reader-process one (+ `reader-consume` in the header sync). Default OFF.
- **Why a second toggle:** enabling `readerProcess` alone stays at 3b (publish + parity diagnostic, no
  behaviour change); `readerConsume` additionally flips Main to consume — so the owner verifies parity
  first, then A/B tests consume vs. Main's own scan.
- **Static verification:** `PoE2MemoryReader.ahk` braces balanced (370/370) + full reader stack
  parse-loads; `ReaderProcess`/`WebViewBridge` balanced; UI inline script `node --check` clean.
- **Verified in-game (2026-07-06, MapRiverhold A/B):** functional PASS — no visual regression,
  LootTracker kills keep counting, clean toggle-off. Profiler proved the mechanism: consume ran ~95 %
  of ticks (`read.ent.decode.new` 4/82 calls) and **`read.entities` dropped 59 ms → 4.9 ms**. BUT the
  owner's A/B exposed a regression (fixed 0.45.13.213): consuming made `read.sleep` balloon 0 → 35.7 ms
  (206 ms spikes), so `tick.read` only fell 65 → 46 ms instead of ~10 ms. Cause: the consume branch
  hardcoded `isZoneLoading := false`, which runs the sleeping-entity scan every tick; Main's own path
  keeps `isZoneLoading` TRUE in junk-heavy maps (its cacheFillRatio stays < 0.90 because junk inflates
  mapSize) and thus SKIPS sleeping. First fix (0.45.13.211) computed `isZoneLoading` from a fill ratio
  but was still insufficient (re-measure: `read.sleep` only 35 → 29.7 ms) because the consume `mapSize`
  used the PUBLISHED record count, and the reader OMITS junk that fails to decode (projectiles/effects),
  so that count ≈ the non-junk awake count → ratio ≈ 1.0 → sleeping still ran every tick. Second fix
  (0.45.13.212): the reader also publishes its RAW awake-map BFS count (`PoefRadarProto.O_RAWCOUNT`,
  set from `ReadAwakeEntitiesFlat`'s `_flatRawCount`), and the consume branch uses
  `Max(rawCount, currentEntities.Count)` as mapSize — so the ratio (non-junk decoded / raw awake)
  matches Main's own `cacheFillRatio`. Wire change is backward-compatible (a reserved header slot; a
  stale reader writing 0 falls back to the record count). That correctly made CONSUME ticks skip
  sleeping (5 µs), but re-measure showed ~18 % of ticks were reader-consume FALLBACKS (freshness/area
  gate) whose `isZoneLoading` flips FALSE and fires the sleeping scan at full cost — and that scan
  traverses the whole sleeping std::map (100s of ms even for an 8-entity sample in a dense area), so
  ~49 fallback ticks × ~200 ms averaged read.sleep back to 35 ms. Third fix (0.45.13.213): **throttle
  the sleeping scan to ~750 ms** (`_radarSleepingCache` / `_radarSleepingTick`, invalidated on area
  change) — sleeping entities are static so the refresh is imperceptible, but it bounds `read.sleep`
  regardless of how `isZoneLoading` flaps (helps the non-consume path too). **Re-measure confirmed
  (0.45.13.213, MapRiverhold):** `read.sleep` 35.7 → 4.2 ms, `tick.read` 50.7 → 24 ms. The remaining
  cost is the reader-consume FALLBACK rate — 16 % of ticks (`read.ent.decode.new` 86/546) ran Main's
  full ~50 ms scan (a dense-map reader hitch missed the 300 ms freshness window). Fix (0.45.13.214):
  raised `RP_CONSUME_MAX_AGE` 300 → 500 ms so one reader hitch is tolerated (a 500 ms-old radar sample
  is acceptable; AutoPilot re-reads player pos + targetable live). Expected: fallback down, `tick.read`
  toward ~10-15 ms. If fallback stays high, the reader tick itself needs slimming (it also runs
  `ReadAutoFlaskSnapshot` each tick) or the sleeping scan moves to the reader too.
- **Reader-tick slimming + sleeping in the reader (0.45.13.215–216):** two follow-ups to push more
  ticks onto the cheap consume path and drop Main's residual `read.sleep`.
  - **0.45.13.215 — cache the reader's inGameState resolve.** `poef_reader.ahk` called
    `ReadAutoFlaskSnapshot` (the 12-state ~15-RPM resolve loop) every 50 ms tick just to get the
    inGameState address for the publish scan. Now it caches the resolve and re-runs it at most every
    ~500 ms; the publish scan reuses the cached address and self-guards on an invalid areaInstance (a
    stale address just yields no publish → Main falls back). Invalidated on reconnect.
  - **0.45.13.216 — publish SLEEPING entities from the reader.** The sleeping std::map scan (100s of ms
    in a dense area) was the residual `read.sleep`. New `PoefRadarProto.P_SLEEPING` record bit;
    `_ReaderSleepingSample` (reader-side, THROTTLED ~750 ms per area so the reader tick stays tight)
    reads the sleeping sample and `ReadAwakeFlatForPublish` appends it to the published records tagged
    `_sleeping`; `RadarWirePack` sets the bit, `RadarWireUnpack` SPLITS records into `sample` (awake) +
    `sleepingSample`. Main's consume routes `sleepingSample` straight into `sleepingEntities` and NEVER
    scans the sleeping map on a consume tick (fallback ticks still scan locally, throttled). Verified
    offline: `radar_wire_test.ahk` 29/29 (awake/sleeping split) + `h_sleep.ahk` linear split test.
  - **Pending in-game verification:** re-measure — fallback rate (`read.ent.decode.new` calls /
    `read.entities` calls) should fall and `read.sleep` should approach ~0 on consume ticks, pushing
    `tick.read` toward ~10-15 ms; confirm sleeping NPCs / radar dots still appear.

### Stage 4: on-demand full component list for the Entities inspector (0.45.13.217)

Fixes the one real degradation of consume mode: the reconstructed snapshot entry carries only a MINIMAL
`components` array ({Targetable, Actor}) + the radar-decoded `decodedComponents`, so the Entities
inspector would LIST only those and couldn't reach the deeper components (Buffs / Stats / Mods / NPC /
…). The design's literal Stage 4 was a WM_COPYDATA request/reply to the reader — but Main keeps its OWN
PoE handle (for the latency-critical local reads) and each reconstructed entry carries the real entity
ADDRESS, so Main can re-read the full entity LOCALLY. No IPC needed; the WM_COPYDATA channel would be
premature complexity.

- **`ahk/WebViewBridge.ahk` — `_RequestEntityComponents(entityAddrHex)`:** re-reads ONE entity's FULL
  component list via `g_reader.ReadEntityBasic(addr)` (non-radar mode → full decode) and pushes
  `{components, componentCount, namedComponentCount}` to JS `eiApplyEntityComponents`. Cheap + rare
  (one entity, only when the user expands it) → never touches the radar hot path. Fires whether or not
  consuming (harmless when not — same data, freshly read). Reuses `_SerializeComponents`.
- **`ahk/BridgeDispatch.ahk`:** case `RequestEntityComponents` → `SetTimer(() => _RequestEntityComponents(args[1]), -1)`.
- **`ui/index.html`:** `_eiState.fullComps` (addr → full-list override, pruned when the entity leaves);
  `eiToggle` calls `ahkCall('RequestEntityComponents', addr)` on expand; `eiApplyEntityComponents`
  stores the override + re-renders; `eiRenderDetail` + `_eiCompAddr` prefer the override (so the full
  list shows AND per-component lazy-decode `_DecodeComponentOnDemand` can address components beyond the
  minimal set). `_eiOv(e)` helper.
- **Why this is the whole job:** the per-component deep decode was ALREADY on-demand + live
  (`_DecodeComponentOnDemand` re-reads a component from its address). The only gap consume opened was
  the LIST of components (their names+addresses); this restores it. `mods` etc. then decode via the
  existing lazy path.
- **Static verification:** `WebViewBridge` braces balanced; UI inline script `node --check` clean.
- **Pending in-game verification:** with consume ON, open the Entities tab, expand an entity → its full
  component list should appear (not just Targetable/Actor) and each component still lazy-decodes on
  click; confirm it matches the consume-OFF inspector.

### Generic fallback decoder for unknown components (0.45.13.218)

The Entities inspector lists every component an entity has, but only ~20 have a specific `Decode…`
handler; the rest (Functions, BaseEvents, InteractionAction, HideoutDoodad, ControlZone, …) showed a
dead "no decoder" row. Now the on-demand decode's `default` case falls back to a GENERIC raw dump so ANY
unknown component is inspectable + reverse-engineerable live.

- **`ahk/PoE2ComponentDecoders.ahk` — `DecodeUnknownComponentBasic(componentPtr, span:=0xA0)`:** reads the
  first `span` bytes and returns string fields: `componentAddr`, `staticPtr` (0x00 — the component's
  TYPE descriptor, identical across all instances of that component → fingerprints the type), `owner`
  (0x08 owner-entity path), and offset-labelled lists of the non-zero `pointers` (plausible ptr at each
  8-aligned slot, its 8 bytes then skipped so it isn't re-read as two ints), `nonzeroInts` and `floats`.
  Content inside each string is offset-ordered (AHK Map iteration order is unspecified, so the ordering
  lives in the strings, not the keys).
- **`ahk/WebViewBridge.ahk`:** `_DecodeComponentOnDemand`'s `default` case calls it; new
  `_SerializeGenericComponent` emits the six fields in a FIXED key order. Flows through the existing
  `eiApplyDecodedComponent` path — the UI renders `Object.entries(decoded)` with no whitelist, so no UI
  change was needed.
- **Use for RE:** click an undecoded component → see its live pointers / ints / floats by offset; from
  there its struct can be worked out and a proper `Decode…ComponentBasic` written + registered in the
  on-demand switch. `staticPtr` confirms two rows are the same component type.
- **Static verification:** braces balanced; `DecodeUnknownComponentBasic` parse-loads in the reader
  stack; `Format` placeholders (`{1:X}`/`{2}`) validated offline.
- **Pointer classification (0.45.13.219):** in-game dumps of BaseEvents / Functions / InteractionActions
  proved these are internal ENGINE dispatch structures (vtables in the `0x7FF6…` module range +
  intrusive linked-list/self-referencing nodes + entity pointers), not named-field data components — so
  a "proper decoder" would only ever surface handler counts, nothing player-meaningful. The genuinely
  useful signal is the EMBEDDED ENTITY POINTERS (e.g. an NPC's BaseEvents references other entities), so
  the generic dump now classifies each pointer: high-canonical (`≥ 0x7FF000000000`) → tagged `(code)`;
  heap pointer → resolved via `ReadEntityIdentityBasic` and, if it yields a real `Metadata/` path,
  listed under a new `entityRefs` field instead of raw. So an unknown component now shows WHICH entities
  it points at, not just addresses.

## Unexplored-area wash on the maphack (shipped 0.45.13.221)

A subtle dark stipple over walkable cells the player hasn't reached yet, so on the revealed (maphack)
large map you can see where you still need to explore. Opt-in toggle **Config → Overlay → "Highlight
Unexplored"** (`[Radar] mapHackUnexplored`, default OFF); large-map + maphack only.

- **No game "explored" grid exists** — the terrain struct exposes the walkable nibble grid but no
  fog-of-war/revealed state (`GridLandscapeData` @0xE8 is defined in `PoE2Offsets` but never read /
  unverified). So "explored" is SELF-TRACKED: `RadarOverlay._visitedBuf` (one byte per half-res bitmap
  cell) is marked in a disc (`UNEXP_VISIT_R`=22 cells) around the player each frame
  (`_UpdateUnexploredVisited`). Unexplored = walkable AND not visited.
- **The overlay is colour-key + one global alpha** (`WinSetTransColor("010101 " alpha)`), NOT per-pixel
  premultiplied alpha — so "dim not hide" is a 50% checkerboard STIPPLE (like the walk-fill debug
  layer), colour `COLOR_UNEXPLORED` (dark), not a low-alpha blend.
- **Render:** built into `_GenerateMapHackBitmap` — a new 1-bit mask `_mapUnexpMask` (starts covering
  the whole walkable area, same stipple as walk-fill) + a solid dark colour source `_mapUnexpColorDC`.
  As the player moves, `_UpdateUnexploredVisited` CLEARS the just-visited cells from the mask (SetPixelV
  black via a temp DC, only cells NEWLY entering the visited disc — cheap; skipped entirely while the
  player's bitmap cell is unchanged) and sets `_unexpDirty`. `_DrawMapLayersCached` blits it on the
  BOTTOM (under walk-fill + wall outlines), adds `u` to the layer-set key, and folds the shrinking wash
  into the scroll cache at most ~every 700 ms (a scroll past the margin rebuilds sooner) so the cheap
  offset-scroll optimisation is preserved. Freed in `_DestroyMapHackBitmap`; reset on area change.
- **Wiring:** `g_mapHackUnexplored` (InGameStateMonitor seed + ConfigManager save/load), RadarOverlay
  `_SyncConfig` → `_unexploredOn`, BridgeDispatch `ToggleMapHackUnexplored`, WebViewBridge header
  `mapHackUnexplored`, UI toggle + `setChk('tog-maphack-unexplored', …)`.
- **Static verification:** RadarOverlay braces 223/223 + all edited files balanced; UI `node --check`
  clean. NOTE: the offline AHK interpreter could not run this round (a stuck AHK process in the sandbox
  blocked even a trivial script — do NOT `Stop-Process AutoHotkey64`, it can kill the owner's running
  tool), so the isolated method harness (`syn_test.ahk`) was not executed; the new `_UpdateUnexplored‌Visited`
  logic was reviewed by hand.
- **Pending in-game verification:** enable it on a large-map maphack — a dark stipple should cover
  walkable areas ahead and CLEAR behind you as you move; explored cells + walls stay clear; the reveal
  radius (`UNEXP_VISIT_R`) and darkness (`COLOR_UNEXPLORED`) are the tuning knobs; confirm no perf
  regression (the wash rides the same scroll cache, refreshed ~1.4×/s).

## GridLandscapeData explored-grid hunt (RE diagnostic, shipped 0.45.13.222)

Chasing the map's real "explored / fog-of-war" per-cell state to replace the unexplored-wash's
self-tracked approximation. The terrain struct (`TerrainMetadata` = AreaInstance+0x8B8) has TWO parallel
`StdVector<byte>` grids: `GridWalkableData` @0xD0 (used) and **`GridLandscapeData` @0xE8** (defined in
`PoE2Offsets`, never read) — same shape, shared `BytesPerRow` @0x130. `GridLandscapeData` is the prime
suspect for the explored grid.

- **`ahk/LandscapeGridProbe.ahk` (new, RE diagnostic):** fog-of-war is DYNAMIC, so the test is
  snapshot→walk→diff. `LandscapeGridProbeSnapshot` reads `GridLandscapeData` (mirrors `ReadTerrainData`'s
  StdVector read at the 0xE8 offset) + captures a copy, its size/rows/bytesPerRow, a byte-value
  histogram, whether it's byte-identical to the walkable grid, and the player grid pos.
  `LandscapeGridProbeDiff` re-reads it and diffs vs the snapshot: changed-byte count, a sample of
  changes (offset, old→new, derived cell x,y), the change bounding box + centre, and how far the player
  moved — so a fog grid (cells flipping near the path) is distinguishable from static data (no change).
  The diff advances the snapshot to "now" so repeated walk+diff traces it. Reuses
  `_AIP_ResolveAreaInstance` (AreaInstanceProbe). Writes `logs\InGameStateMonitor.landscape_probe.log`.
  Bridge `LandscapeGridSnapshot` / `LandscapeGridDiff`; UI "🗺 Landscape Snapshot" / "🗺 Landscape Diff"
  in the RE-tools row; `LoadLandscapeGridProbe()` seeds the snapshot globals.
- **Static verification:** `LandscapeGridProbe.ahk` parse-loads clean; braces balanced; UI `node --check`
  clean.
- **Result 1 (in-game 2026-07-06): `GridLandscapeData` is STATIC** — 0 bytes changed across 76/47/321-cell
  walks; histogram = nibble pairs of values 0-5 (mostly `0x55`) → a terrain-TYPE/height classification
  layer, not boolean explored flags. So NOT the fog grid.
- **Extended to 4 layers (0.45.13.223):** the owner supplied two more `StdVector<byte>` terrain grids —
  `GridLayer3` @0x100 and `GridLayer4` @0x118 (added to `PoE2Offsets.TerrainMetadata`). The four grids
  sit 0x18 apart (walkable @0xD0, landscape @0xE8, layer3 @0x100, layer4 @0x118). The probe now
  snapshots + diffs ALL FOUR at once (`_LgpLayerDefs`) so one walk checks every candidate; the diff
  flags any grid whose cells changed (with its change box) and verdicts "look at InGameState/MiniMap
  next" if none do.
- **Result 2 (in-game 2026-07-06): ALL FOUR terrain grids are STATIC** — 0 bytes changed; layer3/layer4
  are `distinct=1` (uniform 0x55 fill = unused placeholders). So the explored/fog state is DEFINITIVELY
  NOT in the terrain byte grids.
- **Dynamic-allocation scanner (0.45.13.224):** the systematic next step — hunt ANY heap allocation off
  AreaInstance/InGameState that changes as the player explores. `LandscapeScanSnapshot` scans both
  structs (directly, `0..0x2400`/`0..0x1200` step 8, AND one pointer level deep into sub-structs — the
  grid may live in a MiniMap/fog object) for `StdVector<byte>`-shaped fields (heap first, last>first,
  size 4 KB..64 MB), and stores a sampled position-weighted CHECKSUM of each (`_LscanChecksum`: reads
  the vector once, capped 8 MB, folds ~16k evenly-spaced bytes). `LandscapeScanDiff` re-checksums each
  and reports which CHANGED. The fog grid (if it's a CPU allocation) is a grid-sized candidate that
  flips CONSISTENTLY with exploration; erratic ones are other dynamic buffers. Bridge
  `LandscapeScanSnapshot`/`LandscapeScanDiff`; UI "🔎 Scan Snapshot"/"🔎 Scan Diff".
- **CONCLUSION — the hunt is CLOSED, negative (in-game 2026-07-06):** across many snapshot→walk→diff
  rounds with the monotonicity/0→val/span analysis, NO allocation is consistently fog-like. The only
  `<<< FOG-LIKE` flag was a fluke (`area+0x1238`, a REALLOCATING 12-40 KB buffer whose one flagged tick
  had a tiny Δ; every other tick it oscillated at span 94 %). The grid-sized candidates (the ~3.8 MB
  minimap family off a terrain sub-struct) change with `span 99-100 %` — spread over the WHOLE buffer,
  not localised to the path → a minimap RENDER texture, not an accumulating explored state. So,
  systematically ruled out: (1) all 4 terrain byte grids = static; (2) all dynamic CPU allocations off
  AreaInstance/InGameState (direct + 1 level) = oscillating / whole-buffer render buffers. **The
  explored/fog state is NOT a readable CPU grid — it is GPU-side** (consistent with the GGPK shader-patch
  maphack revealing fog via rendering, not via read data; and why GameHelper2 never exposed it). The
  self-tracked visited-grid wash (`0.45.13.221`, "Highlight Unexplored") is therefore the correct, final
  solution — PROVEN best-available, not guessed. `LandscapeGridProbe` is kept as the RE record + a reusable
  grid snapshot/diff + dynamic-allocation scanner for future hunts.

## Map-coverage % on the Loot bar + slider-theme fix (shipped 0.45.13.231)

Two owner-requested tweaks.

- **Themed spacing slider + conditional sub-row (`ui/index.html`):** the unexplored-wash
  dot-spacing control was a raw `<input type="range">` (no theme). Rebuilt as the standard
  Arcane-Codex slider — `.cfg-slider-row > .cfg-label + .slider-wrap(.slider-val bubble +
  input)` with `oninput="_sb(this,'mhunexp-spacing-val',this.value)"` — matching the Combat/
  Exploration sliders. **This is THE slider pattern for the whole UI; reuse it for any new
  slider.** The colour-swatch + spacing sub-row (`#mhunexp-subrow`) is now also gated on the
  "Highlight Unexplored" toggle: hidden by default, `mapHackUnexpSubVis(on)` flips it on the
  toggle's onchange + on header sync (and re-positions the bubble via `_posVal` inside a
  `requestAnimationFrame`, since a `display:none` slider has zero width).
- **Always-on map coverage — REUSE the ExplorationModule measurement (0.45.13.238):** the on-map Loot
  bar shows `" (explored: NN%)"` after the map name (`_LtBuildStripSegments`, reading
  `g_exploreCurrentPercent`; on-map strip bar only, already `g_ltOnMap`-gated). The AutoPilot
  ExplorationModule already computes this correctly (visited-disc mark + reachable-region flood +
  rebase), but only while the bot explores. Instead of a separate tracker, `_RunExploration` got a
  **`measureOnly` mode**: it runs the full measurement (through the region flood + `g_exploreCurrentPercent`)
  then returns BEFORE any navigation/clicking (the target-reached + combat-pause early returns are
  `!measureOnly`-gated; a `measureOnly` return sits right after the region-diag line, recomputing the
  percentage once so the just-completed rebase shows same-tick). `UpdateRadarFast` calls
  `TryExploration(radarSnap, 0, true)` every tick **when AutoPilot is off** (when it's on, the normal
  explore tick updates the same global). One measurement, no duplication.
  - **History / why:** the first attempt was a standalone `ahk/ExploredTracker.ahk` that divided by ALL
    walkable cells → stuck at ~1% (PoE2's walkable grid includes huge unreachable areas + every floor
    on multi-level maps). It was then made to mirror ExplorationModule's reachable-region flood, but a
    subtle in-game divergence (region never completing → readout blank) made the duplication not worth
    it. **`ExploredTracker.ahk` + `g_mapExploredPercent` were deleted** in favour of reusing the proven
    measurement directly. Lesson: there was already a working coverage measurement — reuse it, don't
    reimplement.
  - Verified: full reader/ExplorationModule stack load-checks clean via a PowerShell harness
    (`ld_explore.ahk`) — `TryExploration`/`_RunExploration` now `MaxParams=3`; brace balance holds.
  - **Tooling lesson:** run AutoHotkey through the **PowerShell tool**, not the Bash tool. Git-bash
    mangles a leading-slash switch like `/ErrorStdOut` into a Windows path (`…/Git/ErrorStdOut`), so
    AHK treats it as a missing script file and pops a modal error dialog that HANGS (this looked like
    "AHK execution is broken in the sandbox" — it isn't). `Start-Process AutoHotkey64.exe
    -ArgumentList '/ErrorStdOut', <script> -PassThru` + `WaitForExit(ms)` works. Never `Stop-Process
    AutoHotkey64` (it can kill the owner's running tool).
- **Pending in-game verification:** on a map (AutoPilot off), the on-map Loot bar's name should read
  e.g. `MapRiverhold (explored: 37%)` and climb as you explore, resetting per area; the dot-spacing
  slider should look/behave like the Combat sliders and its row hide when the wash toggle is off.
- **Per-area coverage cache — survive a town round-trip (0.45.13.287):** the coverage tracker reset
  on EVERY terrain change, so leaving an in-progress Atlas map for town (to sell) and returning
  wiped the explored % back to 0. Fix in `ExplorationModule._RunExploration`: the per-area state
  (visited buffer + `_totalWalkable`/`_visitedWalkable` + the full reachability-region flood state +
  coarse dims) is now cached keyed by the AREA INSTANCE HASH (`area["currentAreaHash"]`, `"h"`-prefixed;
  falls back to `"sz"<dataSize>` when the hash is unavailable). On a change: the OLD area's state is
  banked under its key, then if the NEW key has a cached entry whose `terrainSz` matches, it is
  RESTORED (navigation still re-plans from the restored visited map); otherwise fresh init (the
  original allocate-+-count-walkable path, unchanged). So a town→map return continues from where you
  left off. Keying by hash (not dataSize) also fixes a latent bug where two different runs of the same
  map layout shared stale visited state. Cache is capped at 24 areas, insertion-order evicted
  (`_areaCache`/`_areaOrder`/`_AREA_CACHE_CAP`), so a long session can't grow unbounded. Static: full
  include stack parse-loads clean (`/validate` exit 0); braces balanced.
- **Pending in-game verification:** start a map, explore partway (watch the on-map Loot bar %), go to
  town and return via portal — the % should resume at its prior value and keep climbing, not reset to 0.

## Removed the "Walkable Grid (debug)" overlay (0.45.13.234)

The walkable-grid fill diagnostic (blue 50%-stipple over every walkable cell) was superseded by
"Highlight Unexplored" (same walkable-mask source, but a per-cell tunable wash that also clears as
you explore), so per owner request it was removed entirely. Deleted: the `Walkable Grid (debug)`
UI toggle row + its header-sync line; the `ToggleWalkGrid` bridge case; `walkGrid` in the header
push; `g_walkGridEnabled` (InGameStateMonitor global + ConfigManager save/load, INI key `walkGrid`);
and in `RadarOverlay` the whole walk-fill layer — `_walkGridEnabled`, `COLOR_WALKABLE`, the
`_mapWalkColorDC`/`_mapWalkColorBmp`/`_mapWalkMask` bitmaps (creation in `_GenerateMapHackBitmap`,
cleanup in `_DestroyMapHackBitmap`, the mid-gen zone-abort cleanup, and the per-pixel walk
`SetPixelV`), plus the `walkOn`/`haveWalk` params of `_DrawMapLayersCached`/`_DrawMapLayersDirect`
and the `"w"` bit in the scroll-cache `layerKey`. The wall-border maphack + unexplored-wash layers
are untouched (they share the same generation scan and scroll cache). Static: RadarOverlay braces
223/223, `CreateBitmap` 3→2 (walk mask gone), UI `node --check` clean; browser preview confirms the
row is gone and a legacy `walkGrid` header key no longer throws.

## Entities list: ground-item loot labels (shipped 0.45.13.288)

The Entities tab showed the generic "WorldItem" for every ground drop
(`Metadata/MiscellaneousObjects/WorldItem`). Now the Name column shows the drop's
actual, game-style loot label (e.g. "Cannonade Crossbow"), colored by rarity like the
in-game label. Reuses the already-proven inner-item resolution + name composition — no
new memory RE.

- **`ahk/LootRadarValue.ahk` — `LrvWorldItemLabel(wrapperAddr, areaHash, &rarityId)` (new):**
  resolves the wrapper's inner item (`_LrvResolveInnerItem`), reads its mods
  (`g_reader.ReadItemModsAndMagicProperties`), and composes the display name via the SAME
  `ComposeItemDisplayName` the inventory tooltip uses (base name + first prefix/suffix affix
  for magic/rare; unique name via `ReadUniqueIviId`/`GetUniqueNameByIvi`). Currency carries no
  real rarity (mods read → -1) so it is classified as rarity 5 by the `/Currency/` path, like
  the rest of the loot layer. Cached per wrapper address in `g_lrvNameCache`, reset when
  `g_lrvNameCacheHash` (the area hash) changes — ground loot names never change while the item
  exists, so the repeated Entities-tab refresh doesn't re-read memory for the same drop. Misses
  (a just-dropped item whose inner hasn't decoded yet) are NOT cached, so they retry next
  refresh. Independent of `g_lrvEnabled` — the value-radar feature need not be on. Globals
  seeded in `LoadLootRadarValue()` (init gotcha).
- **`ahk/SnapshotSerializers.ahk` (`_BuildEntitiesJson`):** captures `namesAreaHash` from
  `area["currentAreaHash"]`; for `entityType = "WorldItem"` it overrides `displayName` with
  `LrvWorldItemLabel(...)` and, when the inner rarity resolved, overrides `rarId` + the rarity
  string via a new `itemRarityNames` map (item ids, where 5 = Currency — the entity map uses
  5 = "Boss"). Emits `"loot":true/false` per row. The Path/Type columns are unchanged (still
  `…/WorldItem`) — only the Name + its color change.
- **`ui/index.html`:** `.ei-c-name-txt.loot-<0..6>` color classes (normal/magic/rare/unique/
  currency/gem, matched to the in-game label colors); `eiCard` adds `loot-${e.rarityId}` to the
  name span only when `e.loot`. Non-loot rows keep the default color.
- **Note:** the composed name follows the inventory tooltip's logic, which currently drops the
  tier adjective (see `ComposeItemDisplayName`'s comment) — so a magic/rare name can differ
  slightly from the exact in-game string, but base + affix words + rarity color match. Static:
  full AHK stack `/validate` exit 0; UI `node --check` clean.
- **Pending in-game verification:** on a map with ground loot, open Entities → the WorldItem
  rows should show the item names in rarity colors (white/blue/yellow/orange/tan) instead of
  "WorldItem"; confirm names persist while standing still and reset on zone change, and that far
  drops (labels not on screen) still resolve.

## Entity Inspector actions + user-extensible Junk Filter (shipped 0.45.13.289)

Four Entity-Inspector conveniences, the biggest of which makes the Junk Filter
user-extensible (custom patterns per category + user-created categories).

- **Copy path button (`ui/index.html`, `eiBody` Path row):** a small 📋 button after the
  Path value copies the full metadata path to the clipboard (`eiCopyText`, `navigator.clipboard`).
- **Open component in the Memory Dissector (`eiComponentRow`):** a 🔬 button after each
  component's address opens it in **RE → Dissector** — `eiOpenDissect` does `switchTab('dissect')`,
  fills `#dis-addr`, and `ahkCall('DissectGoto', addr)` (reuses the existing dissector nav).
- **Add full path to global Custom terms (`eiBody` actions, next to Copy JSON):** a
  "🚫 Junk (full path)" button appends the entity's full metadata path to the Junk Filter's
  global custom terms (`eiAddPathCustom` → `junkCommitCustom`).
- **Add a group to a junk CATEGORY from the Category row (the big one):** next to Category the
  inspector shows a picker (`eiJunkPickerHtml`) + "🚫 Junk" button. The pattern added is the
  entity's **meta-group** (broad, "as a group", e.g. `leagueincursionnew`). The target category:
  when the path is two-part (metaCategory/metaGroup) the picker pre-selects **`→ <metaCategory>
  (auto)`** (e.g. `MiscellaneousObjects`), auto-creating that user category; otherwise the user
  picks an existing category or **＋ New category…** (reveals a name input). `eiJunkAdd` sends
  `SetJunk('catadd', "<catKey>|<label>|<pattern>")`.

### Junk Filter model extension (`ahk/EntityJunkFilter.ahk`)
The 6 built-in categories had FIXED patterns and custom terms were a single GLOBAL list. Now:
- **`g_junkCatCustom`** (catKey → [pattern,…]) holds user-added patterns per category (built-in
  OR user), toggled via the same `g_junkPatDisabled` set and folded into `g_junkActive` by
  `RebuildJunkActive`. **`g_junkUserCats`** (userKey → label) holds user-created categories.
- **`_ApplyJunkSetting` new keys:** `catadd` (value `catKey|label|pattern`; auto-creates the user
  category, case-insensitive dedup), `catpatdel` (`catKey|pattern`; drops an EMPTIED user
  category), `newcat` (`catKey|label`), `catdel` (`catKey`; user categories only — built-ins are
  permanent). `cat:<key>` (enable/disable-all) now also flips the category's custom patterns.
  **Bridge delimiter is `|`** (never in a path / key / label) — no control char crosses the
  WebView postMessage bridge; user-typed category names are `|`-stripped in JS.
- **Header (`BuildJunkFilterHeaderJson` + `_JunkCatJson`):** each category now also emits
  `custom:[{p,on}]` and `user:<bool>`; user categories are appended after the built-ins. The JS
  `applyJunkFromHeader` exposes `window._junkCatList` (for the inspector picker) and counts
  custom patterns in the `active/total` meta.
- **UI (`junkCatRow`):** renders the custom pills (toggle + ✕ `junkDelCatPat`) after the built-in
  pills; user categories show a "🗑 delete category" button (`junkDelCat`) and an empty-state note.
- **Persistence:** new `[JunkFilter] catPatterns` INI key — one RS-separated record per category,
  each `catKey US label US pat1 US pat2 …` (RS/US = Chr(30)/Chr(31), same proven scheme as
  StashMover). Load rebuilds `g_junkUserCats` (non-built-in keys) + `g_junkCatCustom`.
- **Verified (2026-07-08):** browser-preview drive-through — junk categories render custom pills +
  user category + delete button (meta `7/7`); the inspector picker lists auto/existing/new options
  with the right `catadd` payloads (`miscellaneousobjects|MiscellaneousObjects|leagueincursionnew`,
  `|`-stripped new names), the full-path term appends to global custom, and the dissector button
  emits `DissectGoto`. Offline AHK harness (scratchpad `junk_test.ahk`) — `catadd`/`catpatdel`/
  `catdel` parse, `IsJunkEntity` matches the added group, header JSON valid with `user:true`, and
  a Save→Load round-trip preserves the user category (+ label) and per-category custom patterns.
  Full `/validate` exit 0; UI `node --check` clean.
- **Pending in-game verification:** open an entity in the Entities tab → copy path, add its group
  to a junk category (auto = its meta-category, e.g. a new "MiscellaneousObjects" category), see the
  new pill under that category in the Junk Filter box, confirm the matching entities vanish from the
  radar/list, and that the 🔬 buttons jump to the right address in the Dissector.

## Memory Dissector — power features (shipped 0.45.13.290)

The CE-style Dissector (`ahk/MemoryDissect.ahk` + RE → Dissector tab) grew from a static
8-byte-stride byte viewer into a real RE workbench. Goal: one tool that replaces the one-off
probe scripts (`ActorProbe`, `StackMaxProbe`, `AutoPilotMatrixScan`, …) AND emits a ready-to-paste
`PoE2Offsets` chain. Four capabilities, all opt-in per interaction, none on the render hot path:

- **Live-watch + change highlight (UI-only):** a "Live" toggle + rate select (4/2/1/0.5 Hz) in the
  toolbar drives `setInterval(() => ahkCall('DissectReread'))`. `updateMemDissect` keeps
  `_disPrevHex` (per absolute addr) + `_disChgTick`; a row whose 8 bytes changed since the previous
  refresh gets an inline amber background, alpha faded by age (`DIS_FADE_MS`=1500). Reset when the
  base address changes (navigation), so following a pointer never all-flashes. Live is stopped on
  leaving the tab (`_runTabSideEffects`). This is how you find a drifting/changing offset: enable
  Live, act in-game, watch which row flickers. The per-Reread `LogError` debug spam was removed
  (it fired at up to 4 Hz).
- **Known field names from `PoE2Offsets` ("Type as"):** a struct-template dropdown (populated once
  via `DissectRequestStructs` → `MemDissectStructNames()`, which enumerates every static Map on the
  `PoE2Offsets` class) overlays field names onto the view. `_MemDissectFieldAnnotations(struct)`
  builds a row-offset → "Field(+0xNN) …" map (multiple fields aggregate into their 8-byte row); the
  new **Field** table column shows it (amber). A symbol jump auto-applies a matching template
  (`_MemDissectStructForSymbol`: InGameState/AreaInstance/ServerDataStructure). Pure data, NO RPM.
- **Offset-chain workflow:** the followed pointer path is a breadcrumb. Clicking a pointer cell now
  routes through `DissectFollow off addr` → `MemDissectFollowPointer` (records `{off,addr}` in
  `g_memDissectChain`); a typed address ("Go") is a NEW custom root (`MemDissectGotoCustom`, resets
  chain). `_MemDissectChainString()` renders "AreaInstance → +0x598 → +0x20" (root = symbol or raw
  address), copyable via 📋. The reverse, `MemDissectResolveChain(str)`, parses a typed chain
  ("AreaInstance+0x30+0x18", arrows/spaces tolerated), follows each hop (`ReadInt64` at cur+off),
  jumps to the end and rebuilds the breadcrumb. Back/Forward re-root the breadcrumb to the shown
  address (`_MemDissectRebaseRoot`) — honest rather than a stale path.
- **Value scan (in the current buffer):** `MemDissectScan(value, type)` scans `g_memDissectBuf` at
  EVERY byte offset for i32/u32/f32/i64/hex-bytes/ASCII (`_MemDissectParseHexBytes`/`_MemDissectStrBytes`,
  f32 within 1e-4), returns JSON matches `[{off,at,addr}]` deduped by 8-byte row. `_DissectScanAndPush`
  pushes `updateMemDissectScan` (clickable `+0xNN` chips that scroll+flash the row via `dis-row-<off>`
  ids) then re-pushes the state; matched rows get a left-rail `dis-match` class re-applied on each
  render (`_disScanSet`). Operates on the already-read buffer only — no new reads, low risk.

Wiring: globals `g_memDissectStructName`/`g_memDissectRootSym`/`g_memDissectRootAddr`/`g_memDissectChain`
(InGameStateMonitor). `_BuildMemDissectJson` emits `struct` + `chain` (payload) and `name` (per row).
Bridge cases `DissectFollow` / `DissectSetStruct` / `DissectRequestStructs` / `DissectResolveChain` /
`DissectScan` (existing `DissectGoto` now → `MemDissectGotoCustom`). Verified in the browser preview:
struct dropdown populate + sync, field-name annotation, chain breadcrumb + typed-chain shape, pointer
row carries its offset, live change-flash + navigation reset + timer stop-on-leave, scan chips + row
rail + clear. Static: full `/validate` exit 0; UI `node --check` clean.
- **Pending in-game verification:** with the tool connected, RE → Dissector: Go Symbol (fields should
  name themselves), enable Live and act in-game (changing offsets flash), follow pointers (chain grows,
  📋 copies it), Resolve a typed chain, and Scan a known value (e.g. current area level) to confirm the
  match lands on the right offset.
- **Next candidate (Stage 5, deferred):** inline pointer-target decode (StdWString→text, StdVector→count,
  entity→Metadata path) as an ON-DEMAND per-row expand (the `_DecodeComponentOnDemand` safe pattern),
  NOT on the live-refresh path — the RPM-heavy piece, left out deliberately until the above is proven.

### Usability pass from first in-game test (0.45.13.291)

Owner drove the guided walkthrough and reported real issues; fixed:
- **4-byte row stride** (`g_memDissectStride`, bridge `DissectSetStride`, UI "8-byte/4-byte rows"): many
  `PoE2Offsets` fields sit on 4-byte boundaries (e.g. `CurrentAreaLevel` +0xC4). `_BuildMemDissectJson`
  strides by 4 or 8; the 8-byte views (i64/ptr/f64) guard on `off+8<=bufSize`; `_MemDissectFieldAnnotations`
  aligns names to the stride so a 4-byte field lands on its own row. Header shows "Hex (4B/8B)".
- **Auto-size on "Type as"** (`MemDissectSetStruct` → `_MemDissectStructMaxOffset`/`_MemDissectSnapSize`):
  applying a struct sets the read window to cover its largest field, snapped to a dropdown size and
  **capped at 4 KB for auto** (so a big struct like ServerData@0x21E0 never itself triggers the 8 KB read).
  Size + stride dropdowns now sync from the payload (`d.size`/`d.stride`). Solves "I don't know the size".
- **Field template clears when following a pointer** (`MemDissectFollowPointer` sets `g_memDissectStructName:=""`):
  the old struct's names no longer stick to a deeper pointer target.
- **Back button** (`MemDissectGoto` now reads first, pushes history ONLY on a successful address change):
  a failed pointer read used to push a dead history entry so Back appeared to do nothing.
- **f64 column moved next to f32** (was after Pointer).
- **OPEN — 8 KB size crashed the tool** (owner report, error text pending): the manual 8 KB read path is
  under investigation; auto-size is capped so it can't be reached automatically. Scan is confirmed
  **current-buffer only** (a process-wide scan would be a separate feature). Deferred to a follow-up:
  resizable/hideable columns (reuse the TSV viewer's `.tsv-colsz`/`_tsvColWidths`), and a value-vs-pointer
  type hint in the Field column (ties into Stage 5's inline decode).

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
