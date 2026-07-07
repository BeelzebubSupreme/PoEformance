# Reader-split architecture

Status: **stages 1–4 shipped + wired (opt-in).** SharedMem + seqlock, the anim-fishing
out-of-process sampler, the persistent reader process, the radar-snapshot wire format, Main's
consume-with-fallback path, and the inspector's on-demand full component list (stage 4) are all
implemented and toggleable in-app (`readerProcess` / `readerConsume`, default off). This document
is the original design/plan; the per-stage "shipped" notes below record what actually landed.

## Why (the real motivation)

AutoHotkey v2 is single-threaded. Every `ReadProcessMemory` (RPM) call, every component decode,
every GDI blit and every WebView push runs on **one** timer tick (`UpdateRadarFast`, ~50–100 ms).
So each new memory read competes with rendering and input for the same frame budget — which is why
every read has had to be individually justified and optimised.

A profiling pass (v0.45.13.192–199) already removed the worst offenders with cheap, single-process
fixes:

| Fix | Before | After |
|---|---|---|
| `read.world` — double player-stats read + throttle | 112 ms | 2–3 ms |
| `radar.mask` — maphack blit → offset-scroll cache | 55 ms | 7–9 ms |
| `read.entities` — junk pre-filter (skip decode of effects/projectiles) | decode.new 39 ms / tail 1.5 s | 25 ms / tail 0.4 s |

That took a dense-combat tick from ~224 ms with 1.8 s freezes down to ~90 ms with ~400 ms hitches.
Good — but every one of those wins required *re-thinking a mem read*.

**The split is not about the current numbers. It is about headroom.** The goal is to stop having
to re-optimise the whole tick every time a feature wants more reads. Planned features that each
need many *continuous* reads:

- **Detailed DPS meter** — which skill dealt how much, when; high-frequency life/ES-delta sampling.
- **Death recap** — a rolling history of incoming hits/debuffs: "what actually killed me?"
- …and more, all read-heavy.

These are impossible on a shared render thread and natural in a dedicated reader. The DPS meter is
the poster child: it needs 20–60 Hz sampling + a rolling buffer, which would blow the frame budget
on the main thread but runs independently in its own process.

## The architecture

Multiple processes from **one codebase** (same repo, same `#Include`s, different entry points):

```
┌─────────────────────────────┐        shared memory        ┌──────────────────────────────┐
│ Main  (InGameStateMonitor)  │  ◀── snapshot (double-buf) ─│ Reader "radar"               │
│  - WebView2 / GDI overlays  │                             │  - owns RPM + base scan      │
│  - hotkeys, BridgeDispatch  │  ── commands (WM_COPYDATA)─▶│  - bfs + decode + cheap      │
│  - AutoPilot / StashMover   │                             │  - publishes the snapshot    │
│  - THIN consumer + actor    │                             └──────────────────────────────┘
│  - a few tiny local reads   │        shared memory        ┌──────────────────────────────┐
│    (player pos, W2S matrix) │  ◀── digest ───────────────│ Sampler "dps" (later)        │
└─────────────────────────────┘                             │  - owns raw high-freq reads  │
                                                            │  - owns history + attribution│
                                                            │  - publishes a compact digest│
                                                            └──────────────────────────────┘
```

Key roles:

- **Main** — never blocks on a heavy read again. It consumes finished snapshots/digests from
  shared memory, renders, and acts (clicks, keys). It keeps only a handful of *tiny,
  latency-critical* local reads (see below).
- **Reader "radar"** — owns the process attach (the 48 MB module scan + `EnsureConnected`), the
  entity BFS, decode, and cheap-update. Publishes the radar snapshot. This is the ~40 ms of
  `read.entities` moving off Main.
- **Sampler "dps" (and future samplers)** — the generalisable pattern: a feature that reads a lot
  *continuously* becomes its **own** process that owns its raw reads **and** its computation, and
  publishes only a compact **digest** (e.g. "Spark: 1.2M DPS", "death: 8400 fire from <entity>,
  120 ms pre-death"). Main displays the digest and never touches raw memory for that feature.

**Two AHK processes can both RPM the same PoE process independently** — RPM is a read-only external
call, no lock, no conflict. This is what makes the split possible at all.

## Transport

| Channel | Mechanism | Used for |
|---|---|---|
| Hot data stream | **Shared memory** (memory-mapped file, `CreateFileMapping`/`MapViewOfFile`) | snapshot + digests, many KB, 10–60×/s |
| Control / commands | **WM_COPYDATA** (window message) | Main→Reader: set area-reset, request full-decode of entity X, quit |
| On-demand replies | shared-memory reply slot or WM_COPYDATA | Reader→Main: full component decode for the inspector/hover (rare) |

Not TCP/Winsock for the hot path — the existing `LocalApiServer` proves Winsock works, but the
per-request overhead is too high for a per-frame snapshot. Files/INI are far too slow. Shared
memory is zero-copy RAM shared between processes; it is the only transport fast enough here.

## Shared-memory layout

One named mapping (e.g. `Local\PoEformanceRadar`, a few MB). Conceptual layout:

```
Header (fixed):
  magic                     u32   sanity
  wireVersion               u32   struct-format version — mismatch ⇒ refuse (catches a stale reader)
  epoch                     u32   base-address generation (bumped on PoE restart / pointer re-resolve)
  heartbeatTick             u32   reader liveness (Main watchdogs this)
  activeBuffer / writeSeq   u32   seqlock (odd = mid-write)
  resolvedStatics           …     published pointers (inGameState, areaInstance, …)
  areaHash / isTown / …     …     small area facts

Snapshot buffers  Buffer0 / Buffer1 (double, seqlock):
  seq                       u32   per-buffer sequence (odd = writing)
  playerRec                 …     pos, life, ES, …
  w2sMatrix[16]             f32
  entityCount               u32
  entityRec[N]              …     FLAT fixed-size records (id, pos, rarity, animId, flags, path-idx)
  stringHeap                …     interned paths; entityRec holds an index into this heap

Digest region (per sampler, e.g. dps):
  compact computed results the sampler owns (current DPS per skill, last death recap, …)
  — optionally an append-only event ring the sampler fills and Main drains
```

### The wire format is the real work

`g_radarLastSnap` is a nested AHK `Map` (entities with `decodedComponents` maps, arrays, strings).
That cannot cross a process boundary as-is. It must become a **flat binary contract**:

- **Fixed entity records** — one struct per entity with exactly the hot-path fields. Variable data
  (paths) goes through an **interned string heap**: the reader keeps a persistent `path→index`
  dict so the heap is stable and cheap; each record stores an index.
- **On-demand detail** — full component decode / mods (only the inspector / UI-browser / hover need
  it) is **not** in the hot stream. Main requests "decode entity ptr X" over the command channel;
  the reader replies. The expensive full decode is thus paid only when someone actually looks.

Maintaining this struct in two places (reader writer + Main reader) is the standing maintenance
cost of the split. Document the layout in exactly one place and keep both sides in lock-step via
`wireVersion`.

## Consistency

- **Seqlock double-buffer** (one writer, one reader): reader writes buffer A, bumps `seq`; Main
  reads `seq` → buffer → `seq`, and if `seq` changed (or is odd) it re-reads. Lock-free, correct
  for the single-writer/single-reader case. No tearing.
- **Epoch** — the reader re-resolves base addresses on PoE restart / pointer invalidation and bumps
  `epoch`; Main notices and treats prior pointers as stale.
- **wireVersion** — both sides ship from the same repo, but a *stale running reader* after an update
  must be caught: version mismatch ⇒ Main refuses the mapping and respawns the reader.

## Offsets are NOT a sync problem

`PoE2Offsets` are compile-time constants `#Include`d by both processes. They do **not** cross the
wire — only the flat wire-struct does. So the "two things in sync" burden is just the wire-struct,
not the (large, drift-prone) offset tables. The reader also owns the base-address scan, so all the
pointer-drift handling that already exists stays in one place.

## Latency-critical local reads stay in Main

The split does **not** have to be "all reads in the reader." AutoPilot reads a *fresh* path from the
*current* player position each click tick (the whole point of the distance-field design). Feeding
the player position over IPC with one frame of latency would make clicks land slightly behind.

So Main keeps a handful of **cheap, latency-critical** direct reads — player position, W2S matrix,
area hash (one pointer chain each, effectively free). Only the *expensive bulk* (entity decode,
module scan, inventory) moves to the reader. Both processes RPM-ing PoE is fine.

## Lifecycle

- **Main owns the reader**: `Run(...)` at startup (precedent: `LootPricing` already spawns a hidden
  child via `Run(cmd, A_ScriptDir, "Hide", &pid)` and polls `ProcessExist`), `OnExit` kills it.
- **Single-instance guard** — a named mutex so a restart never leaves two readers RPM-ing.
- **Heartbeat watchdog** — Main watches `heartbeatTick`; if it goes stale (reader hung/crashed),
  Main respawns it. The UI shows "reader: connecting/ok/restarting".
- **Graceful degradation** — while the reader is down/behind, Main shows the last snapshot (stale)
  instead of freezing. This is the core win: a slow/blocked read becomes *staleness*, never a
  frozen UI.

## The sampler pattern (how the DPS meter fits)

Each new read-heavy feature becomes its **own** sampler process built on the same primitives:

1. `#Include` the shared reader modules; attach to PoE (own RPM).
2. Do its raw high-frequency sampling at its own rate (e.g. DPS at 20–60 Hz), keeping its **own**
   rolling buffers / attribution state.
3. Publish only a compact **digest** into a shared-memory region.
4. Main reads the digest and renders it — and **never touches raw memory for that feature**.

For the DPS meter specifically: the sampler owns the incoming-hit history + damage attribution;
Main just shows "Skill X: N DPS" and "death: hit Y, 8400 fire, 120 ms pre-death". All the heavy
buffering lives outside the render thread. Adding the next such feature is then a repeatable move
("new sampler, new wire-struct, consume the digest"), not a per-read optimisation fight.

## Staged rollout

Each stage is independently shippable and reversible.

0. **`docs/reader-split.md`** — this document. ✅
1. **`ahk/SharedMem.ahk`** — the mapping + seqlock primitive (`CreateFileMapping`/`MapViewOfFile`
   via DllCall; write/read double-buffer helpers). **Validate on the anim-fishing pilot**: move the
   live enemy-animation capture (already an isolated, high-rate mode that today *hijacks* the tick)
   into a tiny second process that writes the id→count table into shared memory; Main reads it in
   its normal tick without stripping the overlays. This proves shared memory + lifecycle +
   struct-sync at a low-risk feature before touching the radar.
2. **Reader-process scaffolding** — spawn/kill/watchdog/heartbeat/wireVersion, `epoch`, the header.
3. **Radar snapshot → reader** — move the entity BFS/decode/cheap to the reader; Main consumes the
   flat snapshot; keep the tiny latency-critical local reads. This is the ~40 ms win + turns the
   read tails into staleness.
   - **3a — wire format + pack/unpack + offline harness ✅ (0.45.13.207).** `ahk/PoefRadarProto.ahk`
     (the flat per-entity record layout + snapshot seqlock block) + `ahk/RadarSnapshotWire.ahk`
     (`RadarWirePack` reader-side / `RadarWireUnpack` main-side, incl. the interned UTF-8 string
     heap). Proven lossless by the scratchpad harness `radar_wire_test.ahk` (27 checks: every
     component combo, unicode paths, the three shape nuances, 600→512 truncation + flag, and a
     mid-write seqlock collision → `ok=false`). NOT yet wired into the running app (zero hot-path
     touch) — 3b does that.
   - **3b — reader publishes + parity diagnostic ✅ (0.45.13.208).** `PoE2MemoryReader` gains
     `ReadAwakeEntitiesFlat` (a self-contained copy of the awake-entity scan with its OWN `_flat*`
     cache, no junk filter → publishes everything) + `ReadAwakeFlatForPublish` (resolves area+player
     from a given inGameState addr). The reader (`poef_reader.ahk`) packs it into the radar block
     each tick; Main OWNS the block (`ReaderProcess.ahk` creates + stamps it) and a diagnostic
     `RadarConsumeDiagnose` (bridge `RadarConsumeDiag`, UI "📡 Radar parity") unpacks the reader's
     sample and cross-checks it against Main's live sample (matched-by-id count, path/pos parity,
     "only in main" must be 0). Main's LIVE PATH IS UNTOUCHED — the reader just publishes and Main
     just cross-checks, exactly like stage 2's inGameState cross-check. In-game verification pending.
     `ReadAwakeEntitiesFlat` currently DUPLICATES the live scan's orchestration (reusing the same
     underlying helpers) — the duplication resolves in 3c when Main's inline scan is replaced by
     consuming the reader.
   - **3c — Main consumes with fallback ✅ (0.45.13.210), pending in-game verify.** In-game 3b parity
     confirmed byte-perfect in the settled state (matched N/N, 0 path/pos mismatch, only-in-main 0;
     the nonzero cases were pure temporal skew / one stale publish). 3c adds a SECOND opt-in toggle
     `[Diagnostics] readerConsume` (needs `readerProcess` on): when set, `ReadRadarSnapshot` calls
     `ConsumeReaderRadarSample(currentAreaHash)` — a FRESHNESS gate (reader `O_RDHEART` age < 300 ms)
     + AREA gate — and on success rebuilds the awake sample from the reader's records (junk-filtered
     Main-side) and SKIPS its own BFS/decode/cheap (the ~40 ms win), wrapped in `if (!consumed)`. Any
     failure → `consumed=false` → Main runs its own scan exactly as today (never worse). zoneScan
     refine + `_FilterStaleRadarEntities` (feeds LootTracker kills; live-re-reads Targetable from the
     carried component address so death detection stays fresh) run on the reconstructed sample.
     `RadarTimings["consumed"]` flags which path ran.
4. **On-demand decode channel** — WM_COPYDATA request/reply for the inspector/hover full decode.
5. **DPS sampler** — the first real payoff of the infrastructure: the detailed DPS meter / death
   recap as its own sampler process.

## Stage 3 design — moving the radar snapshot (the high-stakes step)

This is the step that touches the one structure EVERYTHING consumes (`g_radarLastSnap`: RadarOverlay,
AutoPilot/Combat/Exploration, EntityAlerts, LootTracker, LootRadarValue, the Entities browser, …). A
wrong move here breaks the whole tool, so the design is built around three safety principles.

### Safety principle 1 — reconstruct the shape; consumers do NOT change
Dozens of consumers read the nested Map shape
(`g_radarLastSnap["inGameState"]["areaInstance"]["awakeEntities"]["sample"][i]["entity"]
["decodedComponents"]["render"]["worldPosition"]["x"]`, …). We do NOT rewrite them. The reader
publishes FLAT records; **Main reconstructs the exact same nested-Map shape from those records** and
assigns it to `g_radarLastSnap`. Only the SOURCE of the snapshot changes (from Main's own
`ReadRadarSnapshot` to "rebuild from the reader's flat records") — every consumer is byte-for-byte
untouched. The reconstruction is pure Main-side CPU (Maps from a buffer, no RPM); the RPM+decode it
replaces was the expensive part, so it is a net win. Hot consumers can later be adapted to read the
flat records directly — an optimisation, not a prerequisite.

### Safety principle 2 — move ONLY the entity scan first, not "everything"
The measured cost is almost entirely `read.entities` (~40 ms; the BFS + decode + cheap-update). The
rest of `ReadRadarSnapshot` is now cheap (`read.world`≈2 ms, `read.ui`≈2 ms, `read.filter`≈4 ms,
terrain cached ≈0, zoneScan throttled/area-gated). So the FIRST cut moves ONLY the awake-entity scan
into the reader; **Main keeps everything else local** (player, area facts, matrix, terrain, zoneScan,
UI). Main's `tick.read` drops ~49 → ~9 ms with a far smaller, safer change than moving the whole
snapshot. Terrain/zoneScan/on-demand can migrate in later cuts.

This requires a refactor: extract the awake-entity scan (currently inline in `ReadRadarSnapshot`,
`PoE2MemoryReader.ahk` ~3211–3560) into a reusable method, e.g. `ReadAwakeEntitiesFlat(areaInstance)`
→ an array of flat records, callable by BOTH the reader (publishes it) and, transitionally, Main
(fallback). The zone-scan / terrain / area code stays where it is.

### Safety principle 3 — opt-in with a guaranteed fallback (never worse)
Gated on the same `[Diagnostics] readerProcess` toggle. When the reader snapshot is fresh + area-hash
matches, Main uses it; otherwise (reader down/stale/area-mismatch/wireVersion-mismatch) **Main falls
back to its own `ReadRadarSnapshot`** exactly as today. So the worst case is current behaviour. This
is the same posture that made the anim-fishing pilot safe (proc → inproc fallback).

### The flat entity record (hot stream)
Fixed-size record per awake entity; variable data (paths) via an interned string heap (the reader
keeps a persistent `path→index` dict so the heap is stable). Fields = exactly what the hot consumers
read:

    u32  entityId
    i64  entityPtr          ; some consumers key on the address (junk rawPtr, LrvAnnot, on-demand)
    i64  entityRawPtr
    u32  pathIndex          ; → string heap (metadata path); Main derives group/junk/metaGroup from it
    f32  worldX, worldY, worldZ, terrainHeight
    i32  rarityId
    u32  flags              ; bit0 alive, bit1 targetable, bit2 friendly, bit3 monster, …
    i32  animationId        ; hot-path enemy animation
    i32  lifeCur, lifeMax, esCur, esMax
    f32  distance
    i32  priority

~80 bytes × cap 512 records (log truncation if exceeded) + a string heap. The **feature-derived,
config-dependent** data (junk verdict, EntityGroups color, CustomLandmark match, alerts) is NOT in
the record — Main derives it on consume from `pathIndex`, keeping all config logic (which reads
`g_junkActive`, `g_entityGroups`, …) in Main where the config lives. Consequence: the reader decodes
even entities Main will junk-filter — but that decode is now OFF Main's thread entirely, so it costs
Main nothing (the junk pre-filter only helped the reader's own throughput; publishing the junk config
to the reader to restore it is a later refinement). The reader seeds an empty junk config so the
shared scan code runs its pre-filter as a no-op (publishes everything).

### Shared-memory snapshot region
Extends `PoefReaderProto` with a seqlock double-buffer (the header/status from stage 2 stays):

    per buffer (seqlock): frameSeq, areaHash, playerX/Y/Z, recordCount, record[512], stringHeap
    header: + snapshotWireVersion, epoch

Main reads a buffer under the seqlock (staleness on a mid-write collision → reuse last, never torn),
checks `areaHash` against its own current area (skip/last if mismatched — the reader may be one zone
transition ahead/behind), then rebuilds the `awakeEntities.sample` array of nested Maps and splices
it into the otherwise-locally-read snapshot.

### On-demand / secondary reads
The Entities inspector / hover-price do deeper per-entity reads (full component dump, mods). For the
first cut Main does these locally (it keeps its own PoE handle for its local reads anyway). The
WM_COPYDATA on-demand channel (stage 4) can take them over later.

### Field audit result — the record contract (v205)

A full consumer audit (`ahk/*`, ~30 files) crossed with the radar decode's supply gives the leaf
fields the flat record must carry so the reconstructed shape is lossless. **Design decision: carry
the full radar-decode SUPPLY, not the demand subset** — then reconstruction is byte-identical to
today's `ReadRadarSnapshot` output and no missed-demand field can break a consumer.

Per-entity record fields:
- entry: `id`(u32), `entityPtr`(i64), `entityRawPtr`(i64), `distance`(f32), `priority`(i32)
- entity: `pathIndex`(u32→heap), `flags`(u32) [isValid/entityId/address reconstructed]
- render: `worldX/Y/Z`(f32), `terrainHeight`(f32) [gridPosition reconstructed from world]
- life: `lifeCur/lifeMax`(i32) [isAlive = cur>0; percent reconstructed]
- positioned: `reaction`(u8) [isFriendly reconstructed = (reaction&0x7F)=1]
- rarityId(i32); targetable(u8 bool); actor `animationId`(i32)
- chest: `chestFlags`(u8: isOpened/isLabelVisible/isStrongbox bits) — RadarOverlay hides opened chests
- component addresses for LIVE re-reads (see nuance 1): `targetableAddr`(i64), `actorAddr`(i64)

The inspector / Entities-browser / SnapshotSerializers fields (`components` full array, `mods`,
`componentCount`, `namedComponentCount`, deep component dumps) are NOT hot-path — they stay on Main's
own local/on-demand read (stage 4 channel later), so they are out of the flat record.

### Three shape nuances the converter MUST handle (each a potential tool-breaker)
1. **Raw `components` array** — a few HOT consumers (CombatAutomation ~656 live-rereads the Targetable
   byte; `_HkFishCollectMonsters` finds the Actor address; ExplorationModule ~988) walk
   `entity["components"]` to get a component ADDRESS for a live re-read. Reconstruction must either
   rebuild a minimal `components` array containing those {name,address} entries (from the carried
   `targetableAddr`/`actorAddr`), OR those specific consumers get adapted to read the carried address.
   Recommended: rebuild a minimal components array so consumers stay untouched (principle 1).
2. **Life shape inconsistency** — consumers read BOTH flat `life["current"]` AND nested
   `life["life"]["current"]` (the player path uses the nested form). Reconstruction must populate both.
3. **Targetable bool-vs-Map** — `decodedComponents["targetable"]` is sometimes a bare bool, sometimes
   a Map with `["isTargetable"]`. Reconstruct the shape today's radar decode produces (bool) and
   confirm every consumer handles it (SnapshotSerializers:308 treats it as either).

### Open Stage-3 questions (resolve before/while building)
- Exact `flags` bit assignments + whether lifeCur/Max etc. are all actually read by a hot consumer
  (trim the record to what's used).
- Record cap (512?) + truncation policy (log it; `raw` hit 182 in dense combat, headroom is fine).
- Whether Main re-reads player position locally for click-timing freshness (principle: latency-
  critical tiny reads stay local) or trusts the snapshot's playerX/Y/Z.
- Area-hash gating edge cases across a zone transition (brief entity blank is acceptable).

## Risks / open questions

- **Wire-struct maintenance** — the one real recurring cost; mitigated by `wireVersion` + a single
  documented layout.
- **AHK process/IPC ergonomics** — `CreateFileMapping`/`MapViewOfFile`/`WM_COPYDATA` are all
  DllCall-able; no blocker, but needs careful buffer math (this is why stage 1 pilots it small).
- **Two readers, one target** — confirmed safe (RPM is read-only), but double the attach logic;
  keep it in the shared modules.
- **Testing without the game** — the seqlock + wire pack/unpack can be unit-tested off a synthetic
  buffer (like the earlier `ui_scale_test.ahk` offline harness) before in-game verification.
- **Snapshot size** — cap the entity record count / string heap; `log()` if truncated so "covered
  everything" never silently lies.

## Reference

- Profiling journey that led here: the `Profiler` sub-markers (`read.world.*`, `read.ent.*`,
  `radar.mask.*`) + the `logs/InGameStateMonitor.profiler.log` windows (Shift+F3).
- Spawn precedent: `ahk/LootPricing.ahk` (`Run` + `ProcessExist`).
- Attach machinery to reuse in the reader: `ahk/PoE2MemoryReader.ahk` (base scan, `EnsureConnected`)
  + `ahk/ProcessMemory.ahk` (OpenProcess / RPM).
- Prior IPC in the codebase (not for the hot path): `ahk/LocalApiServer.ahk` (Winsock + WSAAsyncSelect).
