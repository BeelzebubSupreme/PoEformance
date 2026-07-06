; RadarOverlay.ahk
; Transparent, click-through overlay — draws entity dots on the mini-map and the large map.
;
; ── Coordinate transformation (ported from Radar.cs / GameHelper2) ─────────────────────
;   Camera angle: 38.7°
;   Projection formula:
;     mapScale   = 240 / zoom  (large map: zoom *= LARGE_MAP_ZOOM_FACTOR = 0.1738)
;     projCos    = mapDiagonal * cos(38.7°) / mapScale
;     projSin    = mapDiagonal * sin(38.7°) / mapScale
;     gridDelta  = (worldPosition - playerWorldPosition) / WORLD_TO_GRID_RATIO
;     screenDelta.x = (gridDelta.x - gridDelta.y) * projCos
;     screenDelta.y = (gridDelta.z - gridDelta.x - gridDelta.y) * projSin
;     dotScreenPos  = mapCenter + screenDelta
;
; ── UI position calculation (ported from UiElement.cs / GameHelper2) ──────────────────
;   GetUnscaledPosition(): walk up the parent chain, accumulating relativePosition.
;   Final result: unscaledPos * GameWindowScale(scaleIndex, localMultiplier)
;     Game design reference resolution: 2560×1600
;     scaleFactorX = windowWidth  / 2560
;     scaleFactorY = windowHeight / 1600
;     scaleIndex 1 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorX
;     scaleIndex 2 → uiScaleX = localMult * scaleFactorY, uiScaleY = localMult * scaleFactorY
;     scaleIndex 3 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorY  (UI default)
;
; ── Map types ───────────────────────────────────────────────────────────────────────────
;   MiniMap:   stored position = TOP-LEFT     → center = pos + size/2 + defaultShift + shift
;   LargeMap:  stored position = MAP CENTER   → center = pos + defaultShift + shift
;              mapDiagonal = sqrt(windowWidth² + windowHeight²)  (rawsz=0 → window as equivalent)

class RadarOverlay extends GdiOverlayBase
{
    ; Transparency color: near black (0x000000 is ignored by some systems)
    static TRANSPARENT_BACKGROUND := 0x010101

    ; Camera-angle constants for 38.7°
    static CAMERA_COS := 0.78094   ; cos(38.7° in radians)
    static CAMERA_SIN := 0.62470   ; sin(38.7° in radians)

    ; Zoom correction factor for the large map (from RadarSettings.cs, default = 0.1738)
    static LARGE_MAP_ZOOM_FACTOR := 0.1738

    ; Conversion factor WorldPosition → GridPosition (from Radar.cs: ratio = 10.86957)
    static WORLD_TO_GRID_RATIO := 10.86957

    ; HUD clip masks (design px @ the 2560×1600 UI reference). The game draws its corner HUD
    ; (orbs, skill/flask bars, XP bar, area & quest panel) on top of its own map; our
    ; always-on-top overlay would otherwise paint the maphack outline / dots over it. The
    ; large-map layer is clipped to EXCLUDE every rectangle below, so the visible map area
    ; becomes a rectangle minus these corners. Dimensions scale UNIFORMLY by
    ; gameWindowHeight/1600 at render time (PoE2 HUD scales with height, so corner masks keep
    ; their size on ultrawide instead of stretching). Tune each entry in-game; empty the array
    ; to disable all masking.
    ;   "anchor": "bottom" = full-width strip along the bottom edge (its "w" is ignored)
    ;             "bl"/"br"/"tr"/"tl" = pinned to that corner, extending inward by w×h design px
    ; Multiple entries may share an anchor — their union is excluded, so each bottom corner
    ; is an L-shape: a tall narrow rect over the orb plus a lower wider rect over the flask /
    ; skill bar that extends further toward the screen centre.
    static MAP_HUD_MASKS := [
        Map("anchor", "bottom", "w",   0, "h",  30),   ; XP bar (spans the full window width)
        Map("anchor", "bl",     "w", 600, "h", 410),   ; life orb (tall corner)
        Map("anchor", "bl",     "w", 950, "h", 270),   ; flask / utility bar (lower, reaches inward)
        Map("anchor", "br",     "w", 600, "h", 410),   ; mana / spirit orb (tall corner)
        Map("anchor", "br",     "w", 950, "h", 270),   ; skill gem bar (lower, reaches inward)
        Map("anchor", "tr",     "w", 400, "h", 500)]   ; area info + quest tracker

    ; Dot colors (GDI expects BGR, not RGB)
    static COLOR_ENEMY_NORMAL := 0x0000FF   ; red    (normal enemies)
    static COLOR_ENEMY_RARE   := 0xFF00FF   ; magenta (rare enemies)
    static COLOR_ENEMY_BOSS   := 0x00FFFF   ; yellow (Unique/Boss)
    static COLOR_MINION       := 0x0080FF   ; orange (own minions)
    static COLOR_NPC          := 0x00FF80   ; green
    static COLOR_CHEST        := 0xFFFF00   ; cyan   (Chests/Strongboxes)
    static COLOR_PLAYER       := 0xFFFFFF   ; white

    ; Maximum world-unit radius drawn on the radar. Entities beyond this distance are skipped.
    ; 6000 world units ≈ 552 grid units — matches the outer scoring penalty in the entity sampler.
    static RADAR_MAX_WORLD_DIST_SQ := 36000000   ; 6000^2
    ; Extended range for important sleeping entities (Boss, Waypoint, AreaTransition, etc.)
    static RADAR_MAX_WORLD_DIST_SQ_EXTENDED := 400000000  ; 20000^2

    ; Colors for structural entity types
    static COLOR_WAYPOINT       := 0xFFD700   ; gold
    static COLOR_AREATRANSITION := 0x00BFFF   ; deep sky blue
    static COLOR_CHECKPOINT     := 0x7FFF00   ; chartreuse
    static COLOR_LANDMARK       := 0x20B0FF   ; amber (curated custom landmarks)
    ; Per-route colour cycle for the optional "walkable path to each landmark"
    ; feature (BGR). Bright + mutually distinct so overlapping routes stay legible.
    static CLM_PATH_PALETTE := [0x00A5FF, 0x50FF50, 0xF0C000, 0xFF50FF, 0x50FFFF
                              , 0x6060FF, 0xC0FF00, 0xFF00A0, 0x00FF9B, 0xFF8C40]
    static COLOR_MAPHACK        := 0x909090   ; neutral gray (BGR) — matches game map outlines
    static COLOR_UNEXPLORED     := 0x201818   ; very dark cool-gray (BGR) — unexplored-area dark wash
    static UNEXP_VISIT_R        := 22         ; radius (in half-res bitmap cells) revealed around player
    ; Terrain-layer scroll cache (see _DrawMapLayersCached): the maphack/unexplored layers are rendered
    ; once into a padded off-screen cache via the expensive rotated PlgBlt, then copied to the
    ; back-buffer each frame with a cheap translated TransparentBlt. MARGIN = how far (screen px)
    ; the view may scroll before a rebuild; KEY = a colour no layer uses, treated as transparent.
    static MASK_CACHE_MARGIN    := 128
    static MASK_CACHE_KEY       := 0xFF00FF   ; magenta (BGR) — transparent key, unused by any layer

    ; Creates the transparent, click-through overlay GUI window and initialises all GDI state fields.
    __New()
    {
        ; GdiOverlayBase owns the transparent click-through window, the double
        ; buffer, the pen/brush caches, the bg-clear brush and the Show/Hide/blit
        ; plumbing. RadarOverlay only adds its own state below.
        super.__New(255)
        this.Name := "radar"
        this.highlightedEntityPath := ""   ; path of entity selected in the Entities tab — drawn with a line on the radar
        this._lastMiniMapDiagonal := 0   ; cached minimap diagonal used for large-map projection
        ; Last valid player world position — reused for a short grace window when a
        ; snapshot briefly lacks worldPosition (GC / pointer race), so the whole
        ; overlay (map + dots + status text) doesn't blink out for that frame.
        this._lastPlayerPos       := 0    ; Map("x","y","h") or 0 when never seen
        this._lastPlayerPosTick   := 0    ; A_TickCount of the last valid position

        ; Entity-group filters (all visible by default)
        this.ShowEnemyNormal := true
        this.ShowEnemyRare   := true
        this.ShowEnemyBoss   := true
        this.ShowMinions     := true
        this.ShowNpcs        := true
        this.ShowChests      := true
        this.DebugMode       := true

        ; Terrain walkability data (set from snapshot each render frame).
        this._terrain             := 0
        ; Shared pathfinder instance (used for A* paths and line-of-sight).
        this._pathfinder          := TerrainPathfinder()
        ; Cached A* path: array of [gridX, gridY] absolute coordinates.
        this._pathGridCoords      := []
        ; Cache-invalidation keys for the path.
        this._pathHlEntity        := ""
        this._pathPlayerGX        := -999999
        this._pathPlayerGY        := -999999
        this._pathEntityGX        := -999999
        this._pathEntityGY        := -999999
        this._pathLastComputeTick := 0
        ; Highlighted entity world position — written by _RenderMapLayer, read by Render().
        this._hlEntityWorldX      := 0
        this._hlEntityWorldY      := 0
        ; Color for path/dot of the highlighted entity (determined from entity type each frame).
        this._hlEntityColor       := 0x00FFFF   ; default cyan

        ; Zone navigation: auto-paths to discovered AreaTransitions from deep scan
        this._navTargets          := []    ; Array of Maps from zone scan (path, type, worldX/Y, gridX/Y)
        this._navPathCoords       := []    ; A* path to nearest AreaTransition [gx, gy] pairs
        this._navTargetIdx        := -1    ; index in _navTargets of current path target
        this._navPlayerGX         := -999999
        this._navPlayerGY         := -999999

        ; Combat path overlay: written by CombatAutomation when LoS to the
        ; current target is blocked. Same shape as _navPathCoords — Array of
        ; [gx, gy] pairs from player to enemy. Rendered as a red polyline so
        ; the user sees the route the bot has chosen around obstacles. Empty
        ; when combat is idle OR when direct LoS is available.
        this._combatPathCoords    := []

        ; Exploration overlay: written by ExplorationModule each AutoPilot
        ; tick. _explorePathCoords is the A* route (Array of [gx, gy]) to the
        ; current scouting target; _exploreTargetGX/GY is that target cell
        ; (grid coords, -1 = none). Rendered as a cyan polyline + ring so the
        ; user can see exactly where the bot is heading and along which path.
        this._explorePathCoords   := []
        this._exploreTargetGX     := -1
        this._exploreTargetGY     := -1

        ; Combat target marker: written by CombatAutomation each tick while
        ; engaged ([gx, gy] grid coords of the current enemy, -1 = none).
        ; Rendered as a red ring + crosshair next to the red combat path.
        this._combatTargetGX      := -1
        this._combatTargetGY      := -1
        this._navLastComputeTick  := 0
        this._navAreaHash         := 0xFFFFFFFF
        this._navEnabled          := true  ; toggle from config

        ; Range circles: array of Maps with "range" (world units), "color" (BGR), "label" (text)
        ; Set externally via SetRangeCircles(); drawn as isometric ellipses around the player.
        this._rangeCircles        := []
        this._rangeCirclesEnabled := true   ; toggle from config — gates the entire range-circle render

        ; Map hack: pre-rendered walkable terrain border bitmap
        this._mapHackEnabled      := true  ; toggle from config
        this._mapHackDC           := 0     ; memory DC holding the solid-color source bitmap
        this._mapHackBmp          := 0     ; source bitmap handle (solid maphack color)
        this._mapHackMask         := 0     ; monochrome mask bitmap (1=border, 0=skip)
        this._mapHackW            := 0     ; bitmap width (gridW / STEP)
        this._mapHackH            := 0     ; bitmap height (totalRows / STEP)
        this._mapHackStep         := 4     ; grid sampling step
        this._mapHackGridW        := 0     ; grid width covered by bitmap
        this._mapHackGridH        := 0     ; grid height covered by bitmap
        this._mapHackTerrainSz    := 0     ; terrain data size — only updated on successful generate
        this._mapHackRetryTick    := 0     ; tick of last regenerate attempt (for retry throttle)

        ; Terrain-layer scroll cache (see _DrawMapLayersCached). Composited maphack+unexplored layers
        ; rendered once per scroll-margin into a padded off-screen DC, then blitted per frame.
        this._maskCacheDC     := 0         ; padded cache memory DC (window + 2*MARGIN)
        this._maskCacheBmp    := 0         ; cache bitmap handle
        this._maskCacheW      := 0         ; current cache bitmap width  (= bufW + 2*MARGIN)
        this._maskCacheH      := 0         ; current cache bitmap height (= bufH + 2*MARGIN)
        this._maskCacheOX     := 0.0       ; player grid X when the cache was built (scroll origin)
        this._maskCacheOY     := 0.0       ; player grid Y when the cache was built
        this._maskCacheCos    := 0.0       ; projection cos at build time (rebuild on change)
        this._maskCacheSin    := 0.0       ; projection sin at build time
        this._maskCacheLayers := ""        ; which layers are baked ("u"/"h"/"uh") — rebuild on change
        this._maskCacheValid  := false     ; false → force a rebuild next frame

        this._mapHackMaskDebug    := false ; red outlines of the HUD clip masks (off — debug)

        ; Unexplored-area wash (maphack): a subtle dark stipple over walkable cells the player has
        ; NOT been near yet, so on the revealed map you can see where you still haven't explored.
        ; No game "explored" grid exists, so we self-track a VISITED grid (one byte per bitmap cell,
        ; marked in a disc around the player each frame) — unexplored = walkable AND not visited. The
        ; mask starts as the whole walkable area (nothing visited) and is incrementally CLEARED as the
        ; player moves. Overlay is colour-key + one global alpha (no per-pixel alpha), so "dim not
        ; hide" is a stipple, not a low-alpha blend.
        this._unexploredOn        := false ; toggle from config (off by default)
        this._unexpColor          := RadarOverlay.COLOR_UNEXPLORED ; wash colour (BGR); config-driven
        this._unexpSpacing        := 2     ; dot spacing (1=solid, higher=sparser/lighter); config-driven
        this._mapUnexpColorDC     := 0     ; solid dark-wash colour source bitmap DC
        this._mapUnexpColorBmp    := 0
        this._mapUnexpMask        := 0     ; 1-bit mask: 1 = walkable & unexplored (stippled)
        this._visitedBuf          := 0     ; Buffer(bmpW*bmpH): 1 = a walkable cell the player reached
        this._visitedW            := 0
        this._visitedH            := 0
        this._unexpDirty          := false ; visited changed → composite cache needs a (throttled) rebuild
        this._unexpCacheTick      := 0     ; last time the dirty flag forced a cache rebuild
        this._lastVisitCx         := -999999 ; last player bitmap cell (skip the disc scan while unchanged)
        this._lastVisitCy         := -999999

        ; Debug lines — collected each Render() when DebugMode is on, pushed to WebView
        ; (Debug tab) instead of being drawn on the overlay so they're copyable.
        this._debugLines := Map()
        ; Cache for path-based entity classification flags to avoid repeated StrLower/InStr
        ; work in the per-frame render hot path.
        this._pathTypeCache := Map()

        ; ── Batch-draw queues ────────────────────────────────────────────────────────────
        ; Draw calls are collected and executed at the end of the frame in a single batch
        ; — reduces kernel-mode switches by 80–95 %.
        ;   Key encoding for _dotBatch / _dotTopBatch:  colorBGR | (radius << 24)
        ;   Key encoding for _lineBatch:                colorBGR | (width  << 24)
        this._dotBatch    := Map()   ; normal entity dots (all color groups)
        this._dotTopBatch := Map()   ; highlight dot — rendered after _dotBatch (on top)
        this._lineBatch   := Map()   ; line segments: one array per color/width group
        this._textBatch   := []      ; text entries: [x, y, text, colorBGR]
        this._iconBatch   := []      ; icon blits: [iconKey, x, y, w, h] (value-aware loot)
        this._lrvFrameDrops := []    ; valued ground drops this frame: [sx, sy, parts, valueEx, isLargeMap]
    }

    ; Pulls the radar's per-frame config straight from the toggle globals (the
    ; overlay owns reading its own settings, so the driver no longer pokes a dozen
    ; properties every tick). Also applies the highlighted-entity auto-expire.
    _SyncConfig(snapshot)
    {
        global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
        global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
        global g_debugMode, g_zoneNavEnabled, g_mapHackEnabled, g_rangeCirclesEnabled
        global g_radarAlpha, g_highlightedEntityPath, g_maphackMaskDebug
        global g_mapHackUnexplored, g_mapHackUnexploredColor, g_mapHackUnexploredSpacing

        this._unexploredOn := IsSet(g_mapHackUnexplored) ? g_mapHackUnexplored : false
        ; Wash colour — a change only needs the solid colour-source bitmap refilled (cheap), NOT a full
        ; regen, so it doesn't reset the explored (visited) progress.
        newUnexpColor := IsSet(g_mapHackUnexploredColor) ? GroupColorToBgr(g_mapHackUnexploredColor) : RadarOverlay.COLOR_UNEXPLORED
        if (newUnexpColor != this._unexpColor)
        {
            this._unexpColor := newUnexpColor
            if (this._mapUnexpColorDC && this._mapHackW > 0)
            {
                rct := Buffer(16, 0)
                NumPut("Int", this._mapHackW, rct, 8)
                NumPut("Int", this._mapHackH, rct, 12)
                ub := DllCall("CreateSolidBrush", "UInt", this._unexpColor, "Ptr")
                DllCall("FillRect", "Ptr", this._mapUnexpColorDC, "Ptr", rct, "Ptr", ub)
                DllCall("DeleteObject", "Ptr", ub)
                this._maskCacheValid := false
            }
        }
        ; Dot spacing — baked into the 1-bit mask stipple, so a change forces a maphack-bitmap regen
        ; (rare, user-triggered; it does reset the explored progress, which is acceptable for tuning).
        newUnexpSpacing := IsSet(g_mapHackUnexploredSpacing) ? Max(1, Min(8, g_mapHackUnexploredSpacing)) : 2
        if (newUnexpSpacing != this._unexpSpacing)
        {
            this._unexpSpacing := newUnexpSpacing
            this._DestroyMapHackBitmap()   ; regenerated next frame with the new stipple
        }
        this.ShowEnemyNormal := g_radarShowEnemyNormal
        this.ShowEnemyRare   := g_radarShowEnemyRare
        this.ShowEnemyBoss   := g_radarShowEnemyBoss
        this.ShowMinions     := g_radarShowMinions
        this.ShowNpcs        := g_radarShowNpcs
        this.ShowChests      := g_radarShowChests
        this.DebugMode       := g_debugMode
        this._navEnabled     := g_zoneNavEnabled
        this._mapHackEnabled := g_mapHackEnabled
        this._mapHackMaskDebug := IsSet(g_maphackMaskDebug) ? g_maphackMaskDebug : false
        this._rangeCirclesEnabled := IsSet(g_rangeCirclesEnabled) ? g_rangeCirclesEnabled : true
        if (IsSet(g_radarAlpha) && this._alpha != g_radarAlpha)
            this.SetAlpha(g_radarAlpha)

        ; Auto-expire entity tracking once the target is finished (opened
        ; chest/strongbox or dead monster) so the tracking line/label stop
        ; pinning a completed objective.
        if (IsSet(g_highlightedEntityPath) && g_highlightedEntityPath != ""
            && _TrackedEntityExpired(snapshot, g_highlightedEntityPath))
            g_highlightedEntityPath := ""
        this.highlightedEntityPath := IsSet(g_highlightedEntityPath) ? g_highlightedEntityPath : ""
    }

    ; ── Overlay contract (driven by OverlayManager) ─────────────────────────
    ; Visibility: the radar follows the shared play-overlay gate, plus the user's
    ; radar on/off toggle (g_radarEnabled).
    ShouldShow(ctx)
    {
        global g_radarEnabled, g_atlasOverlayEnabled, g_atlasRender
        ; Atlas overlay: the world-atlas is a fullscreen panel, so the shared play
        ; gate is closed while it's open — but we still want to draw the node graph
        ; over it. Show (foreground only) whenever the atlas snapshot is populated.
        ; The map layers stay gated on ctx.gate["allowed"] in Draw, so only the
        ; atlas layer (_FinishFrame -> _RenderAtlas) renders here.
        if (IsSet(g_atlasOverlayEnabled) && g_atlasOverlayEnabled
            && IsSet(g_atlasRender) && (g_atlasRender is Map)
            && (ctx.gameActive || ctx.keepWhenBackground))
            return true
        radarOn := (IsSet(g_radarEnabled) ? g_radarEnabled : true)
        if !radarOn
            return false
        if ctx.gate["allowed"]
            return true
        ; Also render on the play area (foreground only) when a debug-enabled hotkey
        ; wants a range circle, so the combat/aim radius shows even with the large map
        ; closed. The map layers stay gated on ctx.gate["allowed"] (see Draw), so this
        ; only adds the circle, never the maphack/dots.
        return (ctx.gameActive || ctx.keepWhenBackground) && this._HasHotkeyDebugCircle()
    }

    ; True if any debug-enabled hotkey action currently requests a screen-space range
    ; circle (monsterCount / aim). Keeps the radar alive for that circle even when the
    ; play-overlay gate (large map) is closed.
    _HasHotkeyDebugCircle()
    {
        global g_hkDebugItems
        if !(IsSet(g_hkDebugItems) && g_hkDebugItems is Array)
            return false
        for _, rec in g_hkDebugItems
        {
            if !(rec is Map)
                continue
            if ((rec.Has("circleCursorPx") && rec["circleCursorPx"] > 0)
                || (rec.Has("circlePlayerPx") && rec["circlePlayerPx"] > 0)
                || (rec.Has("circlePlayerWorld") && rec["circlePlayerWorld"] > 0)
                || (rec.Has("circleCursorWorld") && rec["circleCursorWorld"] > 0))
                return true
        }
        return false
    }

    ; Layout: the radar draws across the whole game window.
    Layout(ctx)
    {
        if (ctx.gwW < 100 || ctx.gwH < 100)
            return 0
        return Map("x", ctx.gwX, "y", ctx.gwY, "w", ctx.gwW, "h", ctx.gwH)
    }

    ; Draw entry point: pulls per-frame config from the globals, then draws all
    ; map layers. The window placement, buffer sizing and back-buffer clear are
    ; handled by GdiOverlayBase.Update() before this runs; the final blit happens
    ; after it returns. _FinishFrame() does the atlas + batch flush + UI highlight.
    ; gameWindowX/Y/Width/Height mirror the rect for the unchanged body below.
    Draw(ctx, rect)
    {
        global Profiler
        this._SyncConfig(ctx.snapshot)
        snapshot         := ctx.snapshot
        gameWindowX      := rect["x"]
        gameWindowY      := rect["y"]
        gameWindowWidth  := rect["w"]
        gameWindowHeight := rect["h"]

        ; Extract data from the snapshot
        inGameState    := (snapshot && snapshot.Has("inGameState"))           ? snapshot["inGameState"]                 : 0
        uiElements     := (inGameState && inGameState.Has("importantUiElements")) ? inGameState["importantUiElements"]  : 0
        areaInstance   := (inGameState && inGameState.Has("areaInstance"))    ? inGameState["areaInstance"]             : 0
        playerRender   := (areaInstance && areaInstance.Has("playerRenderComponent")) ? areaInstance["playerRenderComponent"] : 0
        miniMapData    := (uiElements && uiElements.Has("miniMapData"))       ? uiElements["miniMapData"]               : 0
        largeMapData   := (uiElements && uiElements.Has("largeMapData"))      ? uiElements["largeMapData"]              : 0

        ; Update terrain data from snapshot (re-read only when area hash changes in the reader).
        if (areaInstance && areaInstance.Has("terrain") && areaInstance["terrain"])
        {
            this._terrain := areaInstance["terrain"]
            this._pathfinder.SetTerrain(this._terrain)
        }
        terrainError := (areaInstance && areaInstance.Has("terrainError")) ? areaInstance["terrainError"] : ""

        ; Regenerate maphack bitmap when terrain data changes (new area loaded)
        ; or when the bitmap got destroyed (e.g. by an aborted previous generate).
        ;
        ; sizeChanged and "generate" are intentionally split across two ticks:
        ;   1. zone-change tick — destroy the stale bitmap, commit the new size,
        ;      and request immediate regen. Render() continues; _RenderMapHack
        ;      returns early because DC/Mask are gone, so this frame paints
        ;      WITHOUT any maphack outlines.
        ;   2. next tick — bitmap is missing, retry threshold cleared, generate
        ;      runs (1–2 s blocking call). On return the new bitmap is drawn.
        ;
        ; Without this split the destroy+generate ran in the same tick: the
        ; previous frame (with the OLD zone's outlines) stayed on screen for
        ; the full 1–2 s of generation. Now it's gone within one 50 ms tick.
        if (this._terrain)
        {
            curSz := this._terrain["dataSize"]
            sizeChanged := (curSz != this._mapHackTerrainSz)
            bitmapMissing := !this._mapHackDC || !this._mapHackMask
            retryReady := bitmapMissing && (A_TickCount - this._mapHackRetryTick) > 2000

            if (sizeChanged)
            {
                ; Tick 1: drop the old zone's bitmap immediately so it can't be
                ; blitted to the back buffer this frame. Commit the new size to
                ; suppress repeated sizeChanged triggers, and clear the retry
                ; tick so generation fires on the very next tick.
                if (this._mapHackDC || this._mapHackMask)
                    this._DestroyMapHackBitmap()
                this._mapHackTerrainSz := curSz
                this._mapHackRetryTick := 0
            }
            else if (retryReady)
            {
                ; Tick 2 (or any subsequent tick where bitmap is missing and
                ; throttle has elapsed): build the new bitmap. Blocks the tick
                ; for 1–2 s — acceptable because no maphack is on screen during
                ; that window thanks to the destroy from tick 1.
                this._mapHackRetryTick := A_TickCount
                Profiler.Begin("radar.maphackGen")
                this._GenerateMapHackBitmap()
                Profiler.End("radar.maphackGen")
                ; Re-commit size only on success — failed generates leave the
                ; retry primed for the next throttle window.
                if (this._mapHackDC && this._mapHackMask)
                    this._mapHackTerrainSz := curSz
            }
        }
        else
        {
            ; Terrain became unavailable between zones (loading screen, area
            ; ptr transitionally null). Drop the old bitmap immediately so the
            ; previous zone's outlines don't linger over the new map.
            if (this._mapHackDC || this._mapHackMask)
            {
                this._DestroyMapHackBitmap()
                this._mapHackTerrainSz := 0
                this._mapHackRetryTick := 0
            }
        }

        hasPlayerPosition   := (playerRender && playerRender.Has("worldPosition"))
        awakeEntityCount    := (areaInstance && areaInstance.Has("awakeEntities") && areaInstance["awakeEntities"].Has("sampleCount"))
                               ? areaInstance["awakeEntities"]["sampleCount"] : "?"

        ; ── Status (debug only) — collected for the WebView Debug tab, no overlay draw ──
        dbgX := 0   ; kept for backward-compatible math; no longer used for text
        this._debugLines := Map()   ; reset each frame
        if this.DebugMode
        {
            miniMapSize    := miniMapData  ? (Round(miniMapData["sizeW"])  "x" Round(miniMapData["sizeH"]))  : "no-mm"
            largeMapSize   := largeMapData ? (Round(largeMapData["sizeW"]) "x" Round(largeMapData["sizeH"])) : "no-lm"
            miniMapVisible := miniMapData  ? (miniMapData["isVisible"]  ? "V" : "H") : "-"
            largeMapVisible := largeMapData ? (largeMapData["isVisible"] ? "V" : "H") : "-"
            miniMapPos     := miniMapData  ? (Round(miniMapData["unscaledPosX"]) "," Round(miniMapData["unscaledPosY"])) : "-"
            terrDbg := this._terrain
                ? ("terr:" this._terrain["dataSize"] " gW=" this._terrain["gridWidth"] " gH=" this._terrain["totalRows"]
                   " bpr=" this._terrain["bytesPerRow"] (terrainError != "" ? " [" terrainError "]" : ""))
                : ("terr:NIL" (terrainError != "" ? " (" terrainError ")" : ""))
            mhDbg := " mh:" ((this._mapHackDC && this._mapHackMask) ? "OK" : "NIL")
                . "(sz=" this._mapHackTerrainSz " w=" this._mapHackW " h=" this._mapHackH ")"
            this._debugLines["status"] := "area:" (areaInstance?"OK":"NIL")
                . " pr:" (hasPlayerPosition?"OK":"NIL") " ent:" awakeEntityCount
                . " mm:" miniMapSize "[" miniMapVisible "]" " upos:" miniMapPos
                . " lm:" largeMapSize "[" largeMapVisible "]"
                . " " terrDbg . mhDbg
        }

        ; Reuse the last valid player position for a short grace window when this
        ; snapshot briefly lacks worldPosition (GC / pointer race). Without this the
        ; whole overlay — map, dots AND the status strings drawn below — blinks out
        ; for that single frame, which looks like the overlay is flickering.
        static _POS_GRACE_MS := 800
        if hasPlayerPosition
        {
            pwp := playerRender["worldPosition"]
            this._lastPlayerPos := Map("x", pwp["x"], "y", pwp["y"]
                , "h", playerRender.Has("terrainHeight") ? playerRender["terrainHeight"] : 0.0)
            this._lastPlayerPosTick := A_TickCount
        }
        else if (this._lastPlayerPos && (A_TickCount - this._lastPlayerPosTick) <= _POS_GRACE_MS)
        {
            ; Within grace — render this frame with the cached position.
            hasPlayerPosition := true
        }

        if !hasPlayerPosition
        {
            this._DrawDot(20, 8, 0x0000FF, 5)   ; blue dot = no player found
            this._FinishFrame(gameWindowWidth, gameWindowHeight)
            return
        }

        playerWorldPosition := (playerRender && playerRender.Has("worldPosition"))
                             ? playerRender["worldPosition"] : this._lastPlayerPos
        playerWorldX        := playerWorldPosition["x"]
        playerWorldY        := playerWorldPosition["y"]
        playerTerrainHeight := playerWorldPosition.Has("h") ? playerWorldPosition["h"]
                             : (playerRender.Has("terrainHeight") ? playerRender["terrainHeight"] : 0.0)

        ; Cache the minimap diagonal even when the minimap is currently invisible
        ; (the large map needs it, but is often open while the minimap is hidden).
        if miniMapData
        {
            sfX := gameWindowWidth  / 2560.0
            sfY := gameWindowHeight / 1600.0
            si  := miniMapData["scaleIdx"]
            lm  := miniMapData["localMult"]
            s   := (si = 1 || si = 3) ? lm * sfX : (si = 2) ? lm * sfY : lm
            mmW := miniMapData["sizeW"] * s
            mmH := miniMapData["sizeH"] * s
            if (mmW > 20 && mmH > 20)
                this._lastMiniMapDiagonal := Sqrt(mmW * mmW + mmH * mmH)
        }

        ; Map layers only render under the full play-overlay gate. When ShouldShow let
        ; the radar through purely for a hotkey-debug circle (gate closed, map shut),
        ; mapAllowed is false so we skip the maphack/dots and draw only the circle below.
        mapAllowed := (ctx.gate is Map && ctx.gate.Has("allowed")) ? ctx.gate["allowed"] : true

        if (mapAllowed && miniMapData && miniMapData["isVisible"])
        {
            Profiler.Begin("radar.mini")
            try this._RenderMapLayer(miniMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, false)
            catch
                this._DrawDot(40, 8, 0x00FF00, 4)   ; green dot = MiniMap error
            Profiler.End("radar.mini")
        }

        if (mapAllowed && largeMapData && largeMapData["isVisible"])
        {
            Profiler.Begin("radar.large")
            try this._RenderMapLayer(largeMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, true)
            catch
                this._DrawDot(56, 8, 0x00FFFF, 4)   ; cyan dot = large-map error
            Profiler.End("radar.large")
        }

        ; ── Path recompute (A*) when highlighted entity changes or player/entity moves ──
        if (this.highlightedEntityPath != "" && this._hlEntityWorldX != 0)
        {
            pGX := Round(playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            pGY := Round(playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            eGX := Round(this._hlEntityWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            eGY := Round(this._hlEntityWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            now := A_TickCount
            recompute := (this.highlightedEntityPath != this._pathHlEntity)
                      || (this._pathGridCoords.Length = 0 && (now - this._pathLastComputeTick) > 2000)
                      || ((now - this._pathLastComputeTick) > 500
                          && (Abs(pGX - this._pathPlayerGX) > 5
                           || Abs(pGY - this._pathPlayerGY) > 5
                           || Abs(eGX - this._pathEntityGX) > 5
                           || Abs(eGY - this._pathEntityGY) > 5))
            if recompute
            {
                this._pathGridCoords      := this._pathfinder.FindPath(pGX, pGY, eGX, eGY)
                this._pathPlayerGX        := pGX
                this._pathPlayerGY        := pGY
                this._pathEntityGX        := eGX
                this._pathEntityGY        := eGY
                this._pathHlEntity        := this.highlightedEntityPath
                this._pathLastComputeTick := A_TickCount
            }
            ; Always collect path status when entity is highlighted (shown in WebView debug tab)
            if this.DebugMode
            {
                this._debugLines["path"] := "path: pG=" pGX "," pGY " eG=" eGX "," eGY
                    . " pts=" this._pathGridCoords.Length
                    . " terrain=" (this._terrain ? "OK" : "NIL")
                    . " dbg=" this._pathfinder.LastDebug
            }
        }
        else if (this.highlightedEntityPath = "")
            this._pathGridCoords := []

        ; ── Zone navigation: auto-path to nearest AreaTransition (continuous accumulation) ──
        zoneScanResults := (areaInstance && areaInstance.Has("zoneScanResults")) ? areaInstance["zoneScanResults"] : []
        zoneScanDone    := (areaInstance && areaInstance.Has("zoneScanDone"))    ? areaInstance["zoneScanDone"]    : false
        zoneScanMs      := (areaInstance && areaInstance.Has("zoneScanTimingMs")) ? areaInstance["zoneScanTimingMs"] : 0
        if !(Type(zoneScanResults) = "Array")
            zoneScanResults := []

        ; Keep the render's POI list current regardless of nav — the custom-landmark
        ; labels (drawn later) read from _navTargets too. Nav AUTO-PATHING (below)
        ; stays gated on _navEnabled.
        prevTargetCount := this._navTargets.Length
        this._navTargets := zoneScanResults
        targetsChanged := (zoneScanResults.Length != prevTargetCount)

        if (this._navEnabled && zoneScanResults.Length > 0)
        {
            pGX := Round(playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            pGY := Round(playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            now := A_TickCount

            ; Collect all AreaTransition targets with distances
            atCandidates := []
            for idx, target in this._navTargets
            {
                if (target["type"] != "AreaTransition")
                    continue
                dx := target["gridX"] - pGX
                dy := target["gridY"] - pGY
                d := dx * dx + dy * dy
                atCandidates.Push(Map("idx", idx, "dist", d))
            }

            ; Skip the nearest AreaTransition (entry point) and target the farthest remaining
            ; With ≤1 AT we still navigate to it (no alternative)
            bestIdx := -1
            if (atCandidates.Length = 1)
            {
                bestIdx := atCandidates[1]["idx"]
            }
            else if (atCandidates.Length >= 2)
            {
                ; Find farthest AT — usually the zone exit we're looking for
                bestDist := -1
                for _, c in atCandidates
                {
                    if (c["dist"] > bestDist) {
                        bestDist := c["dist"]
                        bestIdx := c["idx"]
                    }
                }
            }

            ; Recompute navigation path when player moves or new targets discovered
            if (bestIdx > 0)
            {
                recompute := targetsChanged
                          || (bestIdx != this._navTargetIdx)
                          || (this._navPathCoords.Length = 0 && (now - this._navLastComputeTick) > 3000)
                          || ((now - this._navLastComputeTick) > 1000
                              && (Abs(pGX - this._navPlayerGX) > 8
                               || Abs(pGY - this._navPlayerGY) > 8))
                if recompute
                {
                    t := this._navTargets[bestIdx]
                    tGX := Round(t["gridX"])
                    tGY := Round(t["gridY"])
                    this._navPathCoords      := this._pathfinder.FindPath(pGX, pGY, tGX, tGY)
                    this._navTargetIdx       := bestIdx
                    this._navPlayerGX        := pGX
                    this._navPlayerGY        := pGY
                    this._navLastComputeTick := A_TickCount
                }
            }
        }
        else if (!this._navEnabled)
        {
            this._navPathCoords := []
            this._navTargetIdx  := -1
        }

        ; Debug: collect zone scan status for the WebView debug tab
        if (this.DebugMode)
        {
            if (zoneScanResults.Length > 0 || zoneScanDone)
            {
                atCount := 0
                for _, t in zoneScanResults
                    if (t["type"] = "AreaTransition")
                        atCount += 1
                this._debugLines["nav"] := "nav: accum=" zoneScanResults.Length " AT=" atCount
                    . " path=" this._navPathCoords.Length " initMs=" zoneScanMs
            }
            else if (this._navEnabled)
            {
                this._debugLines["nav"] := "nav: scanning..."
            }
        }

        this._FinishFrame(gameWindowWidth, gameWindowHeight)

        ; Hotkey-debug range circles (monsterCount / aim) — drawn last so they sit on
        ; top, on the play area, regardless of map state (see ShouldShow's circle gate).
        this._RenderHotkeyCircles()
    }

    ; Finishes the frame on the back-buffer: atlas overlay, flush of all queued
    ; draw ops, then the optional UI-Browser highlight rect (topmost layer).
    ; GdiOverlayBase.Update() performs the actual blit right after Draw() returns,
    ; so this no longer blits itself — it is the single flush point per frame.
    _FinishFrame(gameWindowWidth, gameWindowHeight)
    {
        global Profiler
        ; Atlas overlay (dormant until g_atlasRender is populated by the reader).
        Profiler.Begin("radar.atlas")
        this._RenderAtlas()
        Profiler.End("radar.atlas")
        ; Flush all queued draw operations before the optional highlight rect.
        Profiler.Begin("radar.flush")
        this._FlushBatch()
        Profiler.End("radar.flush")

        global g_uiBrowserHighlight, g_uiBrowserHoverHighlight
        if IsObject(g_uiBrowserHighlight)
        {
            ; The highlight arrives in ABSOLUTE screen px (UiTree_ScreenRectOf,
            ; scale-aware); the memDC is window-local → shift by the overlay
            ; window origin (_lastX/_lastY = this frame's Layout position).
            hx := Round(g_uiBrowserHighlight["x"] - this._lastX)
            hy := Round(g_uiBrowserHighlight["y"] - this._lastY)
            hw := Round(g_uiBrowserHighlight["w"])
            hh := Round(g_uiBrowserHighlight["h"])
            if (hw > 4 && hh > 4 && hx < gameWindowWidth && hy < gameWindowHeight)
                this._DrawRect(hx, hy, hw, hh, 0x0000FF, 3)
        }
        ; Blue mouse-over rect (children-list hover in the UI Browser) — drawn
        ; after the red selection rect so it stays visible when they overlap.
        if IsObject(g_uiBrowserHoverHighlight)
        {
            hx := Round(g_uiBrowserHoverHighlight["x"] - this._lastX)
            hy := Round(g_uiBrowserHoverHighlight["y"] - this._lastY)
            hw := Round(g_uiBrowserHoverHighlight["w"])
            hh := Round(g_uiBrowserHoverHighlight["h"])
            if (hw > 4 && hh > 4 && hx < gameWindowWidth && hy < gameWindowHeight)
                this._DrawRect(hx, hy, hw, hh, 0xFF0000, 3)   ; BGR → blue
        }
    }

    ; Renders entity dots onto one map layer using isometric projection and the game's UI scale math.
    ; Params: isLargeMap - switches between large-map center/window-diagonal vs. mini-map top-left formulas.
    ; Draws entities onto one map layer (mini-map or large map).
    _RenderMapLayer(mapData, playerWorldX, playerWorldY, playerTerrainHeight,
                    areaInstance, gameWindowWidth, gameWindowHeight, isLargeMap)
    {
        global Profiler, g_reader, g_llcEnabled, g_llcRects, g_llcPad
        ; ── Compute UI scaling (per GameWindowScale.cs) ──────────────────────────────────
        ; The game uses 2560×1600 as the design reference resolution for all UI positions.
        ; scaleFactorX/Y convert unscaled UI coordinates into real pixel coordinates.
        scaleFactorX    := gameWindowWidth  / 2560.0
        scaleFactorY    := gameWindowHeight / 1600.0
        scaleIndex      := mapData["scaleIdx"]
        localMultiplier := mapData["localMult"]

        if      scaleIndex = 1
            uiScaleX := localMultiplier * scaleFactorX, uiScaleY := localMultiplier * scaleFactorX
        else if scaleIndex = 2
            uiScaleX := localMultiplier * scaleFactorY, uiScaleY := localMultiplier * scaleFactorY
        else if scaleIndex = 3
            uiScaleX := localMultiplier * scaleFactorX, uiScaleY := localMultiplier * scaleFactorY
        else
            uiScaleX := localMultiplier,                uiScaleY := localMultiplier

        ; ── Map position on screen ───────────────────────────────────────────────────────
        ; MiniMap: unscaledPos = TOP-LEFT → mapCenter = pos + size/2 + shifts
        ; LargeMap: the position traversal already yields the map center (the large map
        ;           is positioned relative to the screen center in the UI tree → no +size/2)
        mapElementScreenX := mapData["unscaledPosX"] * uiScaleX
        mapElementScreenY := mapData["unscaledPosY"] * uiScaleY

        ; ── Map size and center on screen ────────────────────────────────────────────────
        mapScreenWidth  := mapData["sizeW"] * uiScaleX
        mapScreenHeight := mapData["sizeH"] * uiScaleY

        if isLargeMap
        {
            ; Large map: position traversal gives the center → only add the shifts.
            ; The stored element size is often 0 → use window size as a display fallback.
            mapCenterX := mapElementScreenX + mapData["defaultShiftX"] + mapData["shiftX"]
            mapCenterY := mapElementScreenY + mapData["defaultShiftY"] + mapData["shiftY"]
            if (!(mapScreenWidth > 20) || !(mapScreenHeight > 20)) {
                mapScreenWidth  := gameWindowWidth
                mapScreenHeight := gameWindowHeight
            }
        }
        else
        {
            if (!(mapScreenWidth > 20) || !(mapScreenHeight > 20))
                return
            ; MiniMap: position is top-left → center = pos + size/2 + shifts.
            mapCenterX := mapElementScreenX + mapScreenWidth  / 2 + mapData["defaultShiftX"] + mapData["shiftX"]
            mapCenterY := mapElementScreenY + mapScreenHeight / 2 + mapData["defaultShiftY"] + mapData["shiftY"]
        }

        if (mapCenterX < -mapScreenWidth  || mapCenterX > gameWindowWidth  + mapScreenWidth
         || mapCenterY < -mapScreenHeight || mapCenterY > gameWindowHeight + mapScreenHeight)
            return

        ; ── Diagonal for projection scaling ──────────────────────────────────────────────
        ; MiniMap: diagonal of the actual map element.
        ; LargeMap: UnscaledSize=0 in memory → use the minimap diagonal (cached in Render()).
        ;           Combined without LARGE_MAP_ZOOM_FACTOR, because that factor scales the
        ;           window diagonal down to the minimap diagonal — when using the minimap
        ;           diagonal directly it is no longer needed.
        if isLargeMap
            mapDiagonal := (this._lastMiniMapDiagonal > 0)
                ? this._lastMiniMapDiagonal
                : Sqrt(gameWindowWidth * gameWindowWidth + gameWindowHeight * gameWindowHeight)
        else
            mapDiagonal := Sqrt(mapScreenWidth * mapScreenWidth + mapScreenHeight * mapScreenHeight)

        ; ── Zoom value for radar projection ──────────────────────────────────────────────
        ; LARGE_MAP_ZOOM_FACTOR is ONLY needed when the window diagonal is used.
        ; With the minimap diagonal directly → use the raw zoom value (no factor).
        mapZoom := mapData["zoom"]
        if (!(mapZoom > 0) || mapZoom > 20)
            mapZoom := 0.5

        ; ── DEBUG: collect per-map info for the WebView debug tab ────────────────
        if this.DebugMode
        {
            mapKey := isLargeMap ? "mapL" : "mapM"
            this._debugLines[mapKey] := (isLargeMap?"L":"M")
                . " ctr=" Round(mapCenterX) "," Round(mapCenterY)
                . " spos=" Round(mapElementScreenX) "," Round(mapElementScreenY)
                . " rawsz=" Round(mapData["sizeW"]) "x" Round(mapData["sizeH"])
                . " sz=" Round(mapScreenWidth) "x" Round(mapScreenHeight)
                . " si=" mapData["scaleIdx"] " dep=" mapData["chainDepth"]
                . " z=" Round(mapZoom, 3)
        }

        ; ── Projection factors for the radar coordinate transformation ───────────────────
        baseMapScale := 240.0 / mapZoom
        projectionCos := mapDiagonal * RadarOverlay.CAMERA_COS / baseMapScale
        projectionSin := mapDiagonal * RadarOverlay.CAMERA_SIN / baseMapScale

        ; ── HUD clip masks (large map only) ──────────────────────────────────────────────
        ; Exclude each corner/edge HUD rectangle so the maphack outline / dots never paint
        ; over the game's orbs, skill/flask/XP bars or the area & quest panel (the game draws
        ; that HUD on top of its map; our overlay is always-on-top). GDI clips PlgBlt and every
        ; dot/line below to the remaining region for the rest of the method; the clip is cleared
        ; unconditionally at the end (cannot leak a frame). Result: a non-rectangular map area.
        if isLargeMap
        {
            for _, mask in RadarOverlay.MAP_HUD_MASKS
            {
                r := this._HudMaskRect(mask, gameWindowWidth, gameWindowHeight, scaleFactorY)
                if !r
                    continue
                DllCall("ExcludeClipRect", "Ptr", this.memDC,
                    "Int", r[1], "Int", r[2], "Int", r[1] + r[3], "Int", r[2] + r[4])
            }
            ; Keep the game's on-screen loot labels readable: refresh their rects (throttled,
            ; LootLabelClear.ahk) and exclude each from the maphack blit, just like the HUD
            ; masks above — so the wall bitmap never paints over the loot text.
            if (IsSet(g_llcEnabled) && g_llcEnabled)
            {
                try LootLabelRectsRefresh(g_reader, gameWindowWidth, gameWindowHeight)
                if (IsObject(g_llcRects))
                {
                    pad := IsSet(g_llcPad) ? g_llcPad : 5
                    for _, lr in g_llcRects
                        DllCall("ExcludeClipRect", "Ptr", this.memDC,
                            "Int", lr[1] - pad, "Int", lr[2] - pad,
                            "Int", lr[1] + lr[3] + pad, "Int", lr[2] + lr[4] + pad)
                }
            }
        }

        ; ── Maphack / unexplored-wash overlays (large map only, before entities) ──
        ; The unexplored wash goes under the wall-border outline. Both layers share one scroll cache:
        ; rendered once via the expensive rotated PlgBlt, then copied per frame with a cheap
        ; translated TransparentBlt (rotation is frame-constant; only the player position moves).
        if isLargeMap
        {
            ; Mark the area around the player as explored (clears the unexplored wash there).
            this._UpdateUnexploredVisited(playerWorldX, playerWorldY)
            this._DrawMapLayersCached(this._mapHackEnabled, this._unexploredOn,
                mapCenterX, mapCenterY, playerWorldX, playerWorldY, projectionCos, projectionSin)
        }

        ; Player dot at the map center
        this._DrawDot(Round(mapCenterX), Round(mapCenterY), RadarOverlay.COLOR_PLAYER, isLargeMap ? 4 : 2)

        ; ── Range circles (config toggle + only when entries are set) ──
        if (this._rangeCirclesEnabled)
        {
            for _, rc in this._rangeCircles
            {
                if (rc.Has("range") && rc["range"] > 0)
                    this._DrawRangeCircle(rc["range"], mapCenterX, mapCenterY,
                        projectionCos, projectionSin,
                        rc.Has("color") ? rc["color"] : 0x00FFFF,
                        rc.Has("label") ? rc["label"] : "")
            }
        }

        ; (Hotkey-debug range circles are drawn once per frame from Draw() via
        ; _RenderHotkeyCircles — independent of the map layers, so they show even
        ; when the large map is closed.)

        ; ── Draw entities ────────────────────────────────────────────────────────────────
        awakeEntities   := (areaInstance && areaInstance.Has("awakeEntities"))    ? areaInstance["awakeEntities"]    : 0
        sleepingEntities := (areaInstance && areaInstance.Has("sleepingEntities")) ? areaInstance["sleepingEntities"] : 0

        statTotal     := 0
        statNoDecoded := 0
        statNoRender  := 0
        statFiltered  := 0
        statDead      := 0
        statDrawn     := 0
        firstEntityPath := ""

        ; Track selected entity screen position for post-loop line drawing
        hlScreenX := -1, hlScreenY := -1, hlDistM := -1, hlName := ""

        ; Collect filter stats from awake entities (filter signals 1-5 + blacklist)
        fs := (awakeEntities && awakeEntities.Has("filterStats")) ? awakeEntities["filterStats"] : 0

        for _, entitySource in [awakeEntities, sleepingEntities]
        {
            if !(entitySource && entitySource.Has("sample"))
                continue
            for _, sampleEntry in entitySource["sample"]
            {
                if !(sampleEntry && sampleEntry.Has("entity"))
                    continue
                entity := sampleEntry["entity"]
                statTotal += 1

                if (firstEntityPath = "" && entity.Has("path"))
                    firstEntityPath := SubStr(entity["path"], 1, 40)

                ; Skip stale/removed entities (flags bit-0 set = invalid in game engine)
                if (entity.Has("isValid") && !entity["isValid"]) {
                    statDead += 1
                    continue
                }

                decodedComponents := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
                if !decodedComponents {
                    statNoDecoded += 1
                    continue
                }

                renderComponent := decodedComponents.Has("render") ? decodedComponents["render"] : 0
                if !(renderComponent && renderComponent.Has("worldPosition")) {
                    statNoRender += 1
                    continue
                }

                ; Path filter: only show monsters, player characters, NPCs and chests.
                ; Resolve via cached classification to avoid repeated StrLower/InStr per frame.
                entityPath := entity.Has("path") ? entity["path"] : ""
                pathFlags := this._GetPathTypeFlags(entityPath)
                isMonster        := pathFlags["isMonster"]
                isCharacter      := pathFlags["isCharacter"]
                isNpcPath        := pathFlags["isNpcPath"]
                isChestPath      := pathFlags["isChestPath"]
                isAreaTransition := pathFlags["isAreaTransition"]
                isWaypoint       := pathFlags["isWaypoint"]
                isCheckpoint     := pathFlags["isCheckpoint"]
                isBossPath       := pathFlags["isBossPath"]
                isImportantSleep := pathFlags["isImportantSleep"]

                entityWorldPos      := renderComponent["worldPosition"]
                entityTerrainHeight := renderComponent.Has("terrainHeight") ? renderComponent["terrainHeight"] : 0.0

                ; Hard distance cutoff: 6000 world units for normal entities, 20000 for important types.
                wdx := entityWorldPos["x"] - playerWorldX
                wdy := entityWorldPos["y"] - playerWorldY
                distSq := wdx * wdx + wdy * wdy
                maxDistSq := isImportantSleep ? RadarOverlay.RADAR_MAX_WORLD_DIST_SQ_EXTENDED : RadarOverlay.RADAR_MAX_WORLD_DIST_SQ
                if (distSq > maxDistSq) {
                    statFiltered += 1
                    continue
                }

                ; Convert world delta → grid delta
                gridDeltaX := (entityWorldPos["x"] - playerWorldX)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaY := (entityWorldPos["y"] - playerWorldY)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaZ := (entityTerrainHeight - playerTerrainHeight) / RadarOverlay.WORLD_TO_GRID_RATIO

                ; Isometric radar projection (camera angle 38.7°)
                screenDeltaX := (gridDeltaX - gridDeltaY) * projectionCos
                screenDeltaY := (gridDeltaZ - gridDeltaX - gridDeltaY) * projectionSin

                dotScreenX := Round(mapCenterX + screenDeltaX)
                dotScreenY := Round(mapCenterY + screenDeltaY)

                ; ── Value-aware loot (step 3): valued ground drops get a currency-orb label.
                ; WorldItem wrappers are otherwise filtered out of the entity draw below, so
                ; handle them here with the same projection, then skip the rest per entity.
                if (pathFlags["isWorldItem"])
                {
                    _lrvAddr := entity.Has("address") ? entity["address"] : 0
                    if (_lrvAddr)
                    {
                        ; Stash the on-screen direction (player→drop) for the list's arrow.
                        LrvSetDir(_lrvAddr, screenDeltaX, screenDeltaY)
                        _lrvParts := LrvIconPartsFor(_lrvAddr)
                        if (_lrvParts)
                        {
                            ; Collect now; drawn value-priority + de-cluttered in _FlushLootValues().
                            this._lrvFrameDrops.Push([dotScreenX, dotScreenY, _lrvParts, LrvValueExFor(_lrvAddr), isLargeMap])
                            statDrawn += 1
                        }
                    }
                    continue
                }

                ; Capture highlighted entity screen position early — bypass all visibility filters
                if (this.highlightedEntityPath != "" && entity.Has("path") && entity["path"] = this.highlightedEntityPath)
                {
                    hlScreenX := dotScreenX
                    hlScreenY := dotScreenY
                    hlDistM   := Round(Sqrt(wdx*wdx + wdy*wdy) / RadarOverlay.WORLD_TO_GRID_RATIO)
                    hlName    := entity.Has("displayName") ? entity["displayName"]
                                 : SubStr(entity["path"], InStr(entity["path"], "/",, -1)+1)
                    ; Store world position for pathfinding trigger in Render()
                    this._hlEntityWorldX := entityWorldPos["x"]
                    this._hlEntityWorldY := entityWorldPos["y"]
                    ; Determine entity type color now (before filter continues may skip color computation below)
                    _hlPos  := decodedComponents.Has("positioned") ? decodedComponents["positioned"] : 0
                    _hlFr   := _hlPos && _hlPos.Has("isFriendly") && _hlPos["isFriendly"]
                    _hlCh   := isChestPath
                    _hlMn   := isMonster && _hlFr
                    _hlNpc  := isNpcPath || isCharacter || (_hlFr && !isMonster)
                    _hlEn   := !_hlFr && !_hlCh
                    _hlRar  := decodedComponents.Has("rarityId") ? decodedComponents["rarityId"] : 0
                    this._hlEntityColor := isAreaTransition ? RadarOverlay.COLOR_AREATRANSITION
                        : isWaypoint  ? RadarOverlay.COLOR_WAYPOINT
                        : isCheckpoint ? RadarOverlay.COLOR_CHECKPOINT
                        : _hlCh ? RadarOverlay.COLOR_CHEST
                        : _hlMn   ? RadarOverlay.COLOR_MINION
                        : _hlNpc  ? RadarOverlay.COLOR_NPC
                        : (_hlEn && _hlRar = 3) ? RadarOverlay.COLOR_ENEMY_BOSS
                        : (_hlEn && _hlRar = 2) ? RadarOverlay.COLOR_ENEMY_RARE
                        :                         RadarOverlay.COLOR_ENEMY_NORMAL
                }

                if !(isMonster || isCharacter || isNpcPath || isChestPath || isAreaTransition || isWaypoint || isCheckpoint) {
                    statFiltered += 1
                    continue
                }

                ; Skip only if the life component was successfully decoded AND explicitly reports dead.
                ; If life component is absent (failed plausibility) we allow through — radar decode
                ; now scans all components, so a missing life key means the address was unreadable.
                lifeComponent := decodedComponents.Has("life") ? decodedComponents["life"] : 0
                if (lifeComponent && Type(lifeComponent) = "Map"
                    && lifeComponent.Has("isAlive") && !lifeComponent["isAlive"]) {
                    statDead += 1
                    continue
                }

                ; Skip already-opened chests — they stay valid in the AwakeMap but are no longer
                ; relevant and cause persistent "ghost" dots on the radar.
                if (isChestPath) {
                    chestComp := decodedComponents.Has("chest") ? decodedComponents["chest"] : 0
                    if (chestComp && Type(chestComp) = "Map" && chestComp.Has("isOpened") && chestComp["isOpened"]) {
                        statFiltered += 1
                        continue
                    }
                }

                ; Classify the entity type
                positionedComponent := decodedComponents.Has("positioned") ? decodedComponents["positioned"] : 0
                isFriendly := positionedComponent && positionedComponent.Has("isFriendly") && positionedComponent["isFriendly"]

                isChest  := isChestPath
                isMinion := isMonster && isFriendly
                isNpc    := isNpcPath || isCharacter || (isFriendly && !isMonster)
                isEnemy  := !isFriendly && !isChest && !isAreaTransition && !isWaypoint && !isCheckpoint

                ; Rarity from Mods/ObjectMagicProperties (0=Normal,1=Magic,2=Rare,3=Unique/Boss)
                rarityId := decodedComponents.Has("rarityId") ? decodedComponents["rarityId"] : 0
                isEnemyBoss   := isEnemy && (rarityId = 3)           ; Unique — bosses
                isEnemyRare   := isEnemy && (rarityId = 2)           ; Rare
                isEnemyNormal := isEnemy && !isEnemyBoss && !isEnemyRare

                ; Apply entity-group filters
                if (isChest && !this.ShowChests) {
                    statFiltered += 1
                    continue
                }
                if (isMinion && !this.ShowMinions) {
                    statFiltered += 1
                    continue
                }
                if (isNpc && !this.ShowNpcs) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyNormal && !this.ShowEnemyNormal) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyRare && !this.ShowEnemyRare) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyBoss && !this.ShowEnemyBoss) {
                    statFiltered += 1
                    continue
                }

                ; Dot color by entity type
                dotColor := isAreaTransition ? RadarOverlay.COLOR_AREATRANSITION
                          : isWaypoint       ? RadarOverlay.COLOR_WAYPOINT
                          : isCheckpoint     ? RadarOverlay.COLOR_CHECKPOINT
                          : isChest          ? RadarOverlay.COLOR_CHEST
                          : isMinion         ? RadarOverlay.COLOR_MINION
                          : isNpc            ? RadarOverlay.COLOR_NPC
                          : isEnemyBoss      ? RadarOverlay.COLOR_ENEMY_BOSS
                          : isEnemyRare      ? RadarOverlay.COLOR_ENEMY_RARE
                          :                    RadarOverlay.COLOR_ENEMY_NORMAL
                ; Group color override — a matching path group wins over the type color
                if (entityPath != "") {
                    _grp := ResolveEntityGroupByPath(entityPath)
                    if (_grp)
                        dotColor := GroupColorToBgr(_grp["color"])
                }

                dotRadius := (isAreaTransition || isWaypoint || isCheckpoint) ? (isLargeMap ? 6 : 4)
                           : (isLargeMap ? 4 : 3)
                ; Skip normal dot draw for highlighted entity — it will be drawn last, on top
                if !(this.highlightedEntityPath != "" && entity.Has("path") && entity["path"] = this.highlightedEntityPath)
                    this._DrawDot(dotScreenX, dotScreenY, dotColor, dotRadius)
                statDrawn += 1
            }
        }

        ; ── Highlighted entity: draw path or straight line, then dot on top ──────
        if (hlScreenX >= 0)
        {
            hlColor   := this._hlEntityColor   ; entity-type color (set when entity was found above)
            lineWidth := isLargeMap ? 2 : 1
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO

            ; Use cached A* path segments if available for this entity, else straight line.
            ; Polyline: builds the POINT buffer once → 1 syscall instead of 4×n syscalls.
            pathCoords := this._pathGridCoords
            if (pathCoords.Length >= 2 && this._pathHlEntity = this.highlightedEntityPath)
            {
                n       := pathCoords.Length
                pathPts := Buffer(n * 8, 0)
                for i, pt in pathCoords
                {
                    dGX := pt[1] - playerGX
                    dGY := pt[2] - playerGY
                    NumPut("Int", Round(mapCenterX + (dGX - dGY)     * projectionCos), pathPts, (i-1)*8)
                    NumPut("Int", Round(mapCenterY + (0-dGX-dGY)     * projectionSin), pathPts, (i-1)*8+4)
                }
                pen    := this._GetPen(hlColor, lineWidth)
                oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
                DllCall("Polyline", "Ptr", this.memDC, "Ptr", pathPts, "Int", n)
                DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
            }
            else
                this._DrawLine(Round(mapCenterX), Round(mapCenterY), hlScreenX, hlScreenY, hlColor, lineWidth)

            hlRadius := isLargeMap ? 7 : 5
            this._DrawTopDot(hlScreenX, hlScreenY, hlColor, hlRadius)
            ; Label: entity short name + distance
            labelText := (hlName != "" ? hlName : "?") . (hlDistM >= 0 ? " (" hlDistM "m)" : "")
            this._DrawText(hlScreenX + hlRadius + 3, hlScreenY - 6, labelText, hlColor)
        }

        ; ── Zone scan entities: draw discovered sleeping entities from deep scan ──
        ; Draw when nav is on (all POI dots + filenames) OR custom landmarks are on
        ; (only the curated landmark labels). clmOn gates the landmark half so the
        ; toggle is instant without a rescan.
        clmOn := CustomLandmarksOn()
        if ((this._navEnabled || clmOn) && this._navTargets.Length > 0)
        {
            navOn     := this._navEnabled
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO

            ; De-dupe curated landmark labels. One boss arena / wall / POI spans MANY
            ; terrain tiles that all carry the SAME label (Sikaka's map is per-tile),
            ; so without this a single landmark stacks its label dozens of times across
            ; the map. Pre-pass: keep only the tile nearest the player per unique label;
            ; that representative tile is the one allowed to draw the label + dot.
            lmRep := Map()   ; label -> Map("idx", nearestIdx, "dsq", distSq)
            if (clmOn)
            {
                for idx, target in this._navTargets
                {
                    lmLabel := target.Has("label") ? target["label"] : ""
                    if (lmLabel = "")
                        continue
                    ldGX := target["gridX"] - playerGX
                    ldGY := target["gridY"] - playerGY
                    ldSq := ldGX * ldGX + ldGY * ldGY
                    if (!lmRep.Has(lmLabel) || ldSq < lmRep[lmLabel]["dsq"])
                        lmRep[lmLabel] := Map("idx", idx, "dsq", ldSq)
                }
            }

            ; Snap curated TRANSITION landmarks onto the real portal. Sikaka pins a
            ; transition label (e.g. "The Bone Pits") to the terrain GATE STRUCTURE,
            ; whose sub-cell can sit ~1000m+ from the clickable portal ENTITY the nav
            ; already marks — so the same exit shows twice at two distances. Here each
            ; labelled AreaTransition/Waypoint/Checkpoint tile is moved onto the nearest
            ; REFINED same-type entity (the live portal) within a radius, and that
            ; portal's redundant filename is suppressed. navSnap: landmark idx -> grid
            ; pos; navClaimed: portal idx -> true.
            navSnap := Map()
            navClaimed := Map()
            navPortal := Map()   ; landmark idx -> true when it snapped to a real exit (vs a POI)
            if (clmOn)
            {
                ; Radius (world units) → grid² threshold. Transition-TYPE curated tiles
                ; pin to a big gate STRUCTURE (large offset like Bone Pits ~1350) → a
                ; generous radius. Other curated tiles (entrance/passage Landmarks like
                ; Ardura Caravan / Lightless Passage) only snap to a CLOSE portal so real
                ; POIs / bosses that aren't at an exit (e.g. a Memorial) stay on their
                ; own tile — they simply have no portal within the small radius.
                ratio := RadarOverlay.WORLD_TO_GRID_RATIO
                radTransG := 3000.0 / ratio
                radOtherG := 1000.0 / ratio
                radTransSq := radTransG * radTransG
                radOtherSq := radOtherG * radOtherG
                ; Build a spatial hash of AreaTransition targets once, then query only
                ; nearby buckets per landmark (instead of scanning all _navTargets).
                bucketCell := radTransG
                portalBuckets := this._BuildAreaTransitionBuckets(this._navTargets, bucketCell)
                for li, lt in this._navTargets
                {
                    llabel := lt.Has("label") ? lt["label"] : ""
                    if (llabel = "")
                        continue
                    ltype := lt["type"]
                    lpath := lt.Has("path") ? lt["path"] : ""
                    isTransType := (ltype = "AreaTransition" || ltype = "Waypoint" || ltype = "Checkpoint")
                    bestPi := -1, bestPd := (isTransType ? radTransSq : radOtherSq)
                    lbx := Floor(lt["gridX"] / bucketCell)
                    lby := Floor(lt["gridY"] / bucketCell)
                    searchG := (isTransType ? radTransG : radOtherG)
                    searchB := Max(1, Ceil(searchG / bucketCell))
                    Loop (searchB * 2 + 1)
                    {
                        bucketOffsetX := A_Index - (searchB + 1)
                        Loop (searchB * 2 + 1)
                        {
                            bucketOffsetY := A_Index - (searchB + 1)
                            key := (lbx + bucketOffsetX) "|" (lby + bucketOffsetY)
                            if (!portalBuckets.Has(key))
                                continue
                            bucketIdx := portalBuckets[key]
                            for _, pi in bucketIdx
                            {
                                if (pi = li)
                                    continue
                                pt := this._navTargets[pi]
                                ; The real portal has a DIFFERENT tile path than the curated
                                ; landmark (whose own gate/structure spans many SAME-path tiles);
                                ; that difference — not the `refined` flag — is what separates the
                                ; clickable portal from the landmark's own decoration tiles (and
                                ; it also catches portals the entity-refine never reached).
                                if (lpath != "" && pt.Has("path") && pt["path"] = lpath)
                                    continue
                                pdx := pt["gridX"] - lt["gridX"]
                                pdy := pt["gridY"] - lt["gridY"]
                                pd := pdx * pdx + pdy * pdy
                                if (pd < bestPd)
                                {
                                    bestPd := pd
                                    bestPi := pi
                                }
                            }
                        }
                    }
                    if (bestPi > 0)
                    {
                        navSnap[li] := Map("gx", this._navTargets[bestPi]["gridX"], "gy", this._navTargets[bestPi]["gridY"])
                        navClaimed[bestPi] := true
                        navPortal[li] := true   ; snapped to a real AreaTransition → this is an EXIT
                    }
                }

                ; Walkable nudge: a curated landmark whose tile sits on UNWALKABLE
                ; terrain (a decorative feature off the playable area, e.g. "Fossilised
                ; Memorial") and did NOT snap to a portal is pulled onto the nearest
                ; reachable ground so its marker lands where you can actually stand.
                ; target["gridX"]/gridY are already walkable-grid cell coords.
                if (this._pathfinder && this._pathfinder.HasTerrain())
                {
                    for li, lt in this._navTargets
                    {
                        if (navSnap.Has(li))
                            continue
                        llabel := lt.Has("label") ? lt["label"] : ""
                        if (llabel = "")
                            continue
                        wgx := Round(lt["gridX"])
                        wgy := Round(lt["gridY"])
                        if this._pathfinder.IsWalkable(wgx, wgy)
                            continue   ; already on reachable ground
                        near := this._pathfinder.NearestWalkable(wgx, wgy, 75)
                        if (near)
                            navSnap[li] := Map("gx", near[1], "gy", near[2])
                    }
                }
            }

            lmDrawn := []   ; display positions of the drawn landmarks (for the optional path lines)

            ; Landmark-path context (resolved once): when routes are on, each
            ; ROUTE-ELIGIBLE landmark gets its own palette colour, shared by its
            ; dot + label + route so they read as one. Eligibility = passes the
            ; exit/POI filter AND is within the range cap.
            clmPathsMode := clmOn && CustomLandmarkPathsOn() && this._pathfinder.HasTerrain()
            clmPO := clmPathsMode ? CustomLandmarkPathOpts() : 0
            clmCapSq := 0.0
            if (clmPathsMode)
            {
                clmCapG  := clmPO["maxDist"] / RadarOverlay.WORLD_TO_GRID_RATIO
                clmCapSq := clmCapG * clmCapG
            }
            lmColorN := 0

            ; Off-screen landmark labels get pinned to the map edge (large map only —
            ; the minimap's projection legitimately runs far past the window, so edge
            ; clamping there would be nonsense). Lets the user see where a route leads
            ; when its destination sits outside the drawn map.
            clmEdge := clmOn && isLargeMap && CustomLandmarkEdgeLabelsOn()

            for idx, target in this._navTargets
            {
                lmLabel := target.Has("label") ? target["label"] : ""
                clmShow := (clmOn && lmLabel != "")
                ; Is this the representative (nearest) tile for its label?
                isRep    := clmShow && lmRep.Has(lmLabel) && (lmRep[lmLabel]["idx"] = idx)
                isPureLm := (target["type"] = "Landmark")   ; landmark with no nav value

                ; Landmarks-only (nav off): only representative landmark tiles draw.
                if (!navOn)
                {
                    if (!isRep)
                        continue
                }
                ; Nav on: a pure-landmark DUPLICATE (same label, not the representative)
                ; carries no nav value → suppress so identical labels/dots don't stack.
                else if (isPureLm && clmShow && !isRep)
                    continue

                ; A snapped transition landmark draws at its real portal's position.
                srcGX := navSnap.Has(idx) ? navSnap[idx]["gx"] : target["gridX"]
                srcGY := navSnap.Has(idx) ? navSnap[idx]["gy"] : target["gridY"]
                dGX := srcGX - playerGX
                dGY := srcGY - playerGY
                tSX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                tSY := Round(mapCenterY + (0 - dGX - dGY) * projectionSin)

                tType := target["type"]
                tColor := (tType = "AreaTransition") ? RadarOverlay.COLOR_AREATRANSITION
                        : (tType = "Waypoint")       ? RadarOverlay.COLOR_WAYPOINT
                        : (tType = "Checkpoint")     ? RadarOverlay.COLOR_CHECKPOINT
                        : (tType = "Boss")           ? RadarOverlay.COLOR_ENEMY_BOSS
                        : (tType = "NPC")            ? RadarOverlay.COLOR_NPC
                        : (tType = "Landmark")       ? RadarOverlay.COLOR_LANDMARK
                        :                              0xFFFFFF
                tRadius := (tType = "AreaTransition" || tType = "Waypoint") ? (isLargeMap ? 7 : 5)
                         : (isLargeMap ? 5 : 3)

                ; Route-eligible landmark → its own palette colour (dot + label +
                ; route all share it). 0 = not route-eligible (keep normal colours).
                lmRouteColor := 0
                if (clmShow && isRep && clmPathsMode)
                {
                    routeElig := (navPortal.Has(idx) ? clmPO["toExits"] : clmPO["toPois"])
                    if (routeElig && (dGX * dGX + dGY * dGY) <= clmCapSq)
                    {
                        lmColorN += 1
                        lmRouteColor := RadarOverlay.CLM_PATH_PALETTE[Mod(lmColorN - 1, RadarOverlay.CLM_PATH_PALETTE.Length) + 1]
                    }
                }

                ; Draw a ring (hollow) for zone-scan entities so they're visually distinct from live entities
                this._DrawDot(tSX, tSY, (lmRouteColor != 0 ? lmRouteColor : tColor), tRadius)

                distWorld := Round(Sqrt(dGX * dGX + dGY * dGY) * RadarOverlay.WORLD_TO_GRID_RATIO)
                if (clmShow && isRep)
                {
                    ; Curated landmark name (boss + reward / POI / transition dest),
                    ; drawn once at the nearest tile. Outlined so it stays readable
                    ; over the maphack walls. Tinted to its route colour when routes are on.
                    lmLabelText  := lmLabel " (" distWorld "m)"
                    lmLabelColor := (lmRouteColor != 0 ? lmRouteColor : RadarOverlay.COLOR_LANDMARK)
                    ; If the destination is outside the drawn map, pin the label to the
                    ; window edge along the player→landmark ray (with an off-screen arrow)
                    ; so you can still tell where the route / landmark leads.
                    lmOff := (tSX < 6 || tSX > gameWindowWidth - 6 || tSY < 6 || tSY > gameWindowHeight - 6)
                    if (clmEdge && lmOff)
                        this._DrawEdgeLabel(mapCenterX, mapCenterY, tSX, tSY,
                            gameWindowWidth, gameWindowHeight, lmLabelText, lmLabelColor, isLargeMap)
                    else
                        this._DrawTextOutlined(tSX + tRadius + 3, tSY - 6, lmLabelText, lmLabelColor, 0, 1)
                    lmDrawn.Push(Map("gx", srcGX, "gy", srcGY, "exit", navPortal.Has(idx), "color", lmRouteColor))
                }
                else if (navOn && (tType = "AreaTransition" || tType = "Waypoint") && !navClaimed.Has(idx))
                {
                    ; Skipped when a curated landmark snapped onto this portal — its
                    ; human-readable name replaces this raw filename.
                    shortName := target["path"]
                    lastSlash := InStr(shortName, "/",, -1)
                    if (lastSlash > 0)
                        shortName := SubStr(shortName, lastSlash + 1)
                    this._DrawText(tSX + tRadius + 3, tSY - 6,
                        shortName " (" distWorld "m)", tColor)
                }
            }

            ; ── Optional: walkable A* path from the player to each landmark ──
            ; Recompute is THROTTLED (A* is costly) + cached by _clmPathCache; the
            ; draw runs every frame off the cache. Each route carries its landmark's
            ; own palette colour (shared with that landmark's dot + label), a
            ; configurable width + range, an exit/POI filter and optional direction
            ; chevrons. Drawn UNDER the gold nav / red combat paths.
            if (clmPathsMode && lmDrawn.Length > 0)
            {
                if !this.HasOwnProp("_clmPathCache")
                {
                    this._clmPathCache := []
                    this._clmPathTick  := 0
                    this._clmPathPGX   := -999999
                    this._clmPathPGY   := -999999
                    this._clmPathSig   := ""
                }
                pGXi := Round(playerGX)
                pGYi := Round(playerGY)
                nowT := A_TickCount
                ; Re-run A* on player move / timer OR when the exit/POI filter or range
                ; changed (so toggling an option updates without waiting for the timer).
                clmSig := clmPO["toExits"] "|" clmPO["toPois"] "|" clmPO["maxDist"] "|" lmDrawn.Length
                if ((nowT - this._clmPathTick) > 1500 || clmSig != this._clmPathSig
                    || Abs(pGXi - this._clmPathPGX) > 12 || Abs(pGYi - this._clmPathPGY) > 12)
                {
                    fresh := []
                    for _, lm in lmDrawn
                    {
                        ; Only route-eligible landmarks got a colour assigned (0 = filtered
                        ; out by the exit/POI toggle or the range cap → no route).
                        if (lm["color"] = 0)
                            continue
                        route := this._pathfinder.FindPath(pGXi, pGYi, Round(lm["gx"]), Round(lm["gy"]))
                        if (route && route.Length >= 2)
                            fresh.Push(Map("route", route, "color", lm["color"]))
                    }
                    this._clmPathCache := fresh
                    this._clmPathTick  := nowT
                    this._clmPathPGX   := pGXi
                    this._clmPathPGY   := pGYi
                    this._clmPathSig   := clmSig
                }
                lmPathWidth := Max(1, clmPO["width"] + (isLargeMap ? 1 : 0))
                lmArrows    := clmPO["arrows"]
                arrowSpace  := isLargeMap ? 110 : 85
                arrowLen    := isLargeMap ? 8 : 6
                for _, lmpEntry in this._clmPathCache
                {
                    lmp := lmpEntry["route"]
                    ln  := lmp.Length
                    if (ln < 2)
                        continue
                    lmPathColor := lmpEntry["color"]
                    lmPts := Buffer(ln * 8, 0)
                    for i, pt in lmp
                    {
                        pdGX := pt[1] - playerGX
                        pdGY := pt[2] - playerGY
                        NumPut("Int", Round(mapCenterX + (pdGX - pdGY) * projectionCos), lmPts, (i-1)*8)
                        NumPut("Int", Round(mapCenterY + (0-pdGX-pdGY) * projectionSin), lmPts, (i-1)*8+4)
                    }
                    pen    := this._GetPen(lmPathColor, lmPathWidth)
                    oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
                    DllCall("Polyline", "Ptr", this.memDC, "Ptr", lmPts, "Int", ln)
                    DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
                    ; Direction chevrons spaced by SCREEN distance along the polyline
                    ; (not point count — smoothed paths have few, far-apart points, so a
                    ; per-point step drew nothing). A running accumulator places a ">"
                    ; every arrowSpace px, interpolated inside long segments, pointing the
                    ; way the route runs (player → landmark = increasing index).
                    if (lmArrows)
                    {
                        acc := arrowSpace * 0.6   ; first chevron a little in from the player
                        px  := NumGet(lmPts, 0, "Int")
                        py  := NumGet(lmPts, 4, "Int")
                        k   := 2
                        while (k <= ln)
                        {
                            cx := NumGet(lmPts, (k-1)*8, "Int")
                            cy := NumGet(lmPts, (k-1)*8+4, "Int")
                            sdx := cx - px
                            sdy := cy - py
                            slen := Sqrt(sdx*sdx + sdy*sdy)
                            if (slen > 0.5)
                            {
                                ux := sdx / slen
                                uy := sdy / slen
                                acc += slen
                                while (acc >= arrowSpace)
                                {
                                    back := acc - arrowSpace
                                    this._DrawArrowHead(Round(cx - ux*back), Round(cy - uy*back),
                                        sdx, sdy, arrowLen, lmPathColor, lmPathWidth)
                                    acc -= arrowSpace
                                }
                            }
                            px := cx
                            py := cy
                            k  += 1
                        }
                    }
                }
            }
        }

        ; ── Navigation path: A* path to nearest AreaTransition ──
        ; Polyline: 1 syscall for the entire path instead of 4×n syscalls.
        navCoords := this._navPathCoords
        if (this._navEnabled && navCoords.Length >= 2)
        {
            navColor  := 0x00D7FF   ; gold (BGR)
            navWidth  := isLargeMap ? 3 : 2
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            n         := navCoords.Length
            navPts    := Buffer(n * 8, 0)
            for i, pt in navCoords
            {
                dGX := pt[1] - playerGX
                dGY := pt[2] - playerGY
                NumPut("Int", Round(mapCenterX + (dGX - dGY)   * projectionCos), navPts, (i-1)*8)
                NumPut("Int", Round(mapCenterY + (0-dGX-dGY)   * projectionSin), navPts, (i-1)*8+4)
            }
            pen    := this._GetPen(navColor, navWidth)
            oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memDC, "Ptr", navPts, "Int", n)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        }

        ; ── Combat path: A* route to the currently targeted enemy ─────────
        ; Same projection as the nav path. Drawn in red on top so it visually
        ; dominates if both paths happen to overlap. Empty (and so skipped) when
        ; combat is idle or LoS to the target is direct.
        combatCoords := this._combatPathCoords
        if (combatCoords.Length >= 2)
        {
            combatColor := 0x3030FF   ; red (BGR)
            combatWidth := isLargeMap ? 3 : 2
            playerGX    := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY    := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            cn          := combatCoords.Length
            combatPts   := Buffer(cn * 8, 0)
            for i, pt in combatCoords
            {
                dGX := pt[1] - playerGX
                dGY := pt[2] - playerGY
                NumPut("Int", Round(mapCenterX + (dGX - dGY) * projectionCos), combatPts, (i-1)*8)
                NumPut("Int", Round(mapCenterY + (0-dGX-dGY) * projectionSin), combatPts, (i-1)*8+4)
            }
            pen    := this._GetPen(combatColor, combatWidth)
            oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memDC, "Ptr", combatPts, "Int", cn)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        }

        ; ── Combat target marker (current enemy) ──────────────────────────
        ; Red ring + crosshair at the enemy the bot is engaging — same style
        ; as the exploration target so the user can always see where the bot
        ; wants to go/attack. Gated on the combat state; coordinates are
        ; written by CombatAutomation each tick (-1 clears). g_autoPilotState
        ; is declared global in the exploration block above.
        if (IsSet(g_autoPilotState) && g_autoPilotState = "combat" && this._combatTargetGX >= 0)
        {
            ctColor  := 0x3030FF   ; red (BGR)
            playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            dGX := this._combatTargetGX - playerGX
            dGY := this._combatTargetGY - playerGY
            ctX := Round(mapCenterX + (dGX - dGY) * projectionCos)
            ctY := Round(mapCenterY + (0-dGX-dGY) * projectionSin)
            r   := isLargeMap ? 8 : 5
            this._DrawRectOutline(ctX - r, ctY - r, r * 2, r * 2, ctColor, 2)
            this._DrawLine(ctX - r - 3, ctY, ctX + r + 3, ctY, ctColor, 1)
            this._DrawLine(ctX, ctY - r - 3, ctX, ctY + r + 3, ctColor, 1)
        }

        ; ── Exploration path + target (AutoPilot scouting) ────────────────
        ; Same projection as the nav/combat paths. Cyan polyline for the A*
        ; route the explorer is following, plus a hollow ring at the current
        ; target cell. Gated on the explore state so a stale route is never
        ; drawn while combat/loot owns the tick; coordinates are written by
        ; ExplorationModule each tick (empty/-1 clears them).
        global g_autoPilotState
        if (IsSet(g_autoPilotState) && g_autoPilotState = "explore")
        {
            exploreColor := 0xFFC000   ; light blue (BGR)
            playerGX     := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY     := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO

            exploreCoords := this._explorePathCoords
            if (exploreCoords.Length >= 2)
            {
                en        := exploreCoords.Length
                explorePts := Buffer(en * 8, 0)
                for i, pt in exploreCoords
                {
                    dGX := pt[1] - playerGX
                    dGY := pt[2] - playerGY
                    NumPut("Int", Round(mapCenterX + (dGX - dGY) * projectionCos), explorePts, (i-1)*8)
                    NumPut("Int", Round(mapCenterY + (0-dGX-dGY) * projectionSin), explorePts, (i-1)*8+4)
                }
                pen    := this._GetPen(exploreColor, isLargeMap ? 3 : 2)
                oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
                DllCall("Polyline", "Ptr", this.memDC, "Ptr", explorePts, "Int", en)
                DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
            }

            ; Target cell — hollow ring + crosshair so it stands out from dots.
            if (this._exploreTargetGX >= 0)
            {
                dGX := this._exploreTargetGX - playerGX
                dGY := this._exploreTargetGY - playerGY
                etX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                etY := Round(mapCenterY + (0-dGX-dGY) * projectionSin)
                r   := isLargeMap ? 8 : 5
                this._DrawRectOutline(etX - r, etY - r, r * 2, r * 2, exploreColor, 2)
                this._DrawLine(etX - r - 3, etY, etX + r + 3, etY, exploreColor, 1)
                this._DrawLine(etX, etY - r - 3, etX, etY + r + 3, exploreColor, 1)
            }
        }

        ; Debug entity-filter stats — collected for the WebView debug tab.
        if this.DebugMode
        {
            entKey := isLargeMap ? "entL" : "entM"
            this._debugLines[entKey] := (isLargeMap?"L":"M")
                . "-ent: tot=" statTotal " noD=" statNoDecoded " noR=" statNoRender
                . " flt=" statFiltered " dead=" statDead " drawn=" statDrawn
                . " p0=" firstEntityPath
            if fs
            {
                preFlt  := fs.Has("preFilter")  ? fs["preFilter"]  : "?"
                postFlt := fs.Has("postFilter") ? fs["postFilter"] : "?"
                fltKey := isLargeMap ? "fltL" : "fltM"
                this._debugLines[fltKey] := "flt: s1=" fs["s1"] " s2=" fs["s2"]
                    . " s3=" fs["s3"] " s4=" fs["s4"] " s5=" fs["s5"] " s6=" fs["s6"]
                    . " bl=" fs["bl"] " blTot=" fs["blTotal"]
                    . " pre=" preFlt " post=" postFlt
            }
        }

        ; Release any clip region set above (HUD masks) so it never affects a later draw into
        ; the back-buffer. SelectClipRgn(NULL) is a harmless no-op when none was set.
        DllCall("SelectClipRgn", "Ptr", this.memDC, "Ptr", 0)

        ; Debug: outline every HUD clip mask in red (unclipped, on top of the maphack) so the
        ; user can see exactly where MAP_HUD_MASKS clips while tuning the values. Large map only.
        if (isLargeMap && this._mapHackMaskDebug)
        {
            for _, mask in RadarOverlay.MAP_HUD_MASKS
            {
                r := this._HudMaskRect(mask, gameWindowWidth, gameWindowHeight, scaleFactorY)
                if r
                    this._DrawRectOutline(r[1], r[2], r[3], r[4], 0x0000FF, 2)   ; red (BGR)
            }
        }

        ; Draw THIS layer's valued loot labels (value-priority, de-cluttered). Done per layer so
        ; the overlap suppression never mixes the mini-map and large-map projections (both layers
        ; can render in one frame). Queued into the shared batches, flushed in _FinishFrame.
        this._FlushLootValues()
    }

    ; Computes the on-screen rectangle for one HUD clip mask: design px scaled uniformly by
    ; gameWindowHeight/1600 (sY) and pinned to its anchor corner/edge. Returns [x, y, w, h] in
    ; window pixels, or 0 when the mask has no area. Shared by the clip loop and the debug outline.
    _HudMaskRect(mask, gw, gh, sY)
    {
        mh := Round(mask["h"] * sY)
        if (mh <= 0)
            return 0
        if (mask["anchor"] = "bottom")
            return [0, gh - mh, gw, mh]
        mw := Round(mask["w"] * sY)
        if (mw <= 0)
            return 0
        mx := (mask["anchor"] = "br" || mask["anchor"] = "tr") ? gw - mw : 0
        my := (mask["anchor"] = "bl" || mask["anchor"] = "br") ? gh - mh : 0
        return [mx, my, mw, mh]
    }

    ; Returns cached path classification flags used by the hot render loop.
    _GetPathTypeFlags(entityPath)
    {
        if (entityPath = "")
            return Map(
                "isMonster", false, "isCharacter", false, "isNpcPath", false, "isChestPath", false,
                "isAreaTransition", false, "isWaypoint", false, "isCheckpoint", false, "isBossPath", false,
                "isImportantSleep", false, "isWorldItem", false
            )

        if this._pathTypeCache.Has(entityPath)
            return this._pathTypeCache[entityPath]

        entityPathLower := StrLower(entityPath)
        isMonster        := InStr(entityPathLower, "metadata/monsters/")
        isCharacter      := InStr(entityPathLower, "metadata/characters/")
        isNpcPath        := InStr(entityPathLower, "metadata/npc/")
        isChestPath      := InStr(entityPathLower, "/chests/") || InStr(entityPathLower, "strongbox")
        isAreaTransition := InStr(entityPathLower, "areatransition")
        isWaypoint       := InStr(entityPathLower, "waypoint")
        isCheckpoint     := InStr(entityPathLower, "checkpoint")
        isBossPath       := isMonster && (InStr(entityPathLower, "boss") || InStr(entityPathLower, "unique"))
        isImportantSleep := isAreaTransition || isWaypoint || isCheckpoint || isBossPath || isNpcPath
        ; Ground loot wrapper (value-aware loot radar, step 3). Cached here so the per-frame
        ; entity loop avoids a StrLower+InStr per entity.
        isWorldItem      := InStr(entityPathLower, "worlditem") || InStr(entityPathLower, "metadata/items/")

        flags := Map(
            "isMonster", isMonster,
            "isCharacter", isCharacter,
            "isNpcPath", isNpcPath,
            "isChestPath", isChestPath,
            "isAreaTransition", isAreaTransition,
            "isWaypoint", isWaypoint,
            "isCheckpoint", isCheckpoint,
            "isBossPath", isBossPath,
            "isImportantSleep", isImportantSleep,
            "isWorldItem", !!isWorldItem
        )
        this._pathTypeCache[entityPath] := flags
        return flags
    }

    ; ── GDI drawing helpers ──────────────────────────────────────────────────────────────
    ; _GetPen / _GetBrush are inherited from GdiOverlayBase (same cached impl).

    ; ── Batch collector methods ──────────────────────────────────────────────────────────
    ; These methods do NOT draw immediately — they collect draw operations in RAM.
    ; _FlushBatch() executes all collected ops in one batch (once per frame).

    ; Queues a filled circle into the normal dot batch (drawn before the highlight dot).
    _DrawDot(centerX, centerY, colorBGR, radius := 3)
    {
        key := colorBGR | (radius << 24)
        if !this._dotBatch.Has(key)
            this._dotBatch[key] := []
        this._dotBatch[key].Push([centerX, centerY])
    }

    ; Queues a filled circle into the top-priority dot batch (drawn after _dotBatch → always on top).
    ; Used exclusively for the highlighted entity dot so it appears above all other dots.
    _DrawTopDot(centerX, centerY, colorBGR, radius := 3)
    {
        key := colorBGR | (radius << 24)
        if !this._dotTopBatch.Has(key)
            this._dotTopBatch[key] := []
        this._dotTopBatch[key].Push([centerX, centerY])
    }

    ; Queues a line segment into the line batch.
    _DrawLine(x1, y1, x2, y2, colorBGR, penWidth := 1)
    {
        key := colorBGR | (penWidth << 24)
        if !this._lineBatch.Has(key)
            this._lineBatch[key] := []
        this._lineBatch[key].Push([x1, y1, x2, y2])
    }

    ; Draws a small ">" chevron IMMEDIATELY at (sx,sy) pointing in direction (dx,dy)
    ; — used to show which way a landmark route runs. Params: tip screen pos, a
    ; direction vector (need not be unit), barb length px, colour (BGR), pen width.
    ; No return.
    _DrawArrowHead(sx, sy, dx, dy, len, colorBGR, width := 1)
    {
        mag := Sqrt(dx * dx + dy * dy)
        if (mag < 0.001)
            return
        ux := dx / mag, uy := dy / mag
        px := -uy, py := ux                      ; perpendicular
        b1x := sx - Round(len * (ux * 0.80 + px * 0.60)), b1y := sy - Round(len * (uy * 0.80 + py * 0.60))
        b2x := sx - Round(len * (ux * 0.80 - px * 0.60)), b2y := sy - Round(len * (uy * 0.80 - py * 0.60))
        pts := Buffer(3 * 8, 0)
        NumPut("Int", b1x, pts, 0),  NumPut("Int", b1y, pts, 4)
        NumPut("Int", sx,  pts, 8),  NumPut("Int", sy,  pts, 12)
        NumPut("Int", b2x, pts, 16), NumPut("Int", b2y, pts, 20)
        pen    := this._GetPen(colorBGR, width)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", 3)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
    }

    ; Draws an off-screen landmark's label pinned to the window edge, so you can still
    ; tell where a route/landmark leads when its destination is outside the drawn map.
    ; The anchor is where the ray from the player (cx,cy) to the target (tSX,tSY) exits
    ; an inset window rect; an arrow head sits on the edge pointing off-screen and the
    ; label is placed just inside, fully within the window. Text width is ESTIMATED from
    ; the character count (measuring the batched font here is not worth the round-trip).
    _DrawEdgeLabel(cx, cy, tSX, tSY, winW, winH, text, colorBGR, isLargeMap)
    {
        m := 6
        rx1 := m, ry1 := m, rx2 := winW - m, ry2 := winH - m
        dx := tSX - cx, dy := tSY - cy
        if (dx = 0 && dy = 0)
            return
        ; First inset-rect boundary the outward ray crosses (player is normally inside).
        tHit := 1.0
        if (dx > 0)
            tHit := Min(tHit, (rx2 - cx) / dx)
        else if (dx < 0)
            tHit := Min(tHit, (rx1 - cx) / dx)
        if (dy > 0)
            tHit := Min(tHit, (ry2 - cy) / dy)
        else if (dy < 0)
            tHit := Min(tHit, (ry1 - cy) / dy)
        if (tHit <= 0 || tHit > 1)
            tHit := 1.0
        ex := Round(cx + tHit * dx)
        ey := Round(cy + tHit * dy)
        ; Guard degenerate cases (player itself off-screen) so the arrow stays visible.
        ex := Max(rx1, Min(ex, rx2))
        ey := Max(ry1, Min(ey, ry2))
        ; Arrow on the edge, pointing off-screen (the route's direction).
        this._DrawArrowHead(ex, ey, dx, dy, isLargeMap ? 11 : 9, colorBGR, isLargeMap ? 3 : 2)
        ; Label just inside the edge; estimate its box so it stays fully on-screen.
        tw := StrLen(text) * (isLargeMap ? 8 : 7) + 6
        th := isLargeMap ? 18 : 15
        lx := (ex > (rx1 + rx2) // 2) ? (ex - 16 - tw) : (ex + 16)
        ly := ey - (th // 2)
        lx := Max(rx1 + 2, Min(lx, rx2 - tw))
        ly := Max(ry1 + 2, Min(ly, ry2 - th))
        this._DrawTextOutlined(lx, ly, text, colorBGR, 0, 1)
    }

    ; Builds a spatial hash of AreaTransition nav targets for fast local lookup.
    ; Params: navTargets (Array), cellSize (grid units). Returns: Map bucketKey -> [targetIdx...].
    _BuildAreaTransitionBuckets(navTargets, cellSize)
    {
        buckets := Map()
        for idx, target in navTargets
        {
            if (target["type"] != "AreaTransition")
                continue
            key := this._ClmBucketKey(target["gridX"], target["gridY"], cellSize)
            if (!buckets.Has(key))
                buckets[key] := []
            buckets[key].Push(idx)
        }
        return buckets
    }

    ; Converts a grid coordinate to a deterministic spatial-hash bucket key.
    ; Params: gx, gy (grid coords), cellSize (grid units). Returns: "bucketX|bucketY".
    _ClmBucketKey(gx, gy, cellSize)
    {
        return Floor(gx / cellSize) "|" Floor(gy / cellSize)
    }

    ; Queues a text draw into the text batch. Optional font handle (5th element) lets a few
    ; entries (the loot value labels) render at a custom size; 0 = the DC's default font.
    _DrawText(screenX, screenY, text, colorBGR, font := 0)
    {
        this._textBatch.Push([screenX, screenY, text, colorBGR, font])
    }

    ; Queues an icon blit (drawn after dots, before text). iconKey resolves via OverlayImage.
    ; silhouette=true paints the icon's shape solid black (an outline-halo pass for the orb).
    _DrawIconBatched(iconKey, x, y, w, h, silhouette := false)
    {
        this._iconBatch.Push([iconKey, x, y, w, h, silhouette])
    }

    ; Queues outlined text: a black halo (8 offset copies) then the colored fill on top, all in
    ; the text batch with the given font. Keeps small on-map labels legible over any background.
    _DrawTextOutlined(x, y, text, fillCol, font, ow := 1)
    {
        oc := 0x000000
        this._DrawText(x - ow, y, text, oc, font)
        this._DrawText(x + ow, y, text, oc, font)
        this._DrawText(x, y - ow, text, oc, font)
        this._DrawText(x, y + ow, text, oc, font)
        this._DrawText(x - ow, y - ow, text, oc, font)
        this._DrawText(x + ow, y - ow, text, oc, font)
        this._DrawText(x - ow, y + ow, text, oc, font)
        this._DrawText(x + ow, y + ow, text, oc, font)
        this._DrawText(x, y, text, fillCol, font)
    }

    ; Value-aware loot (step 3): paints the valued ground drops collected this frame. The marker
    ; dot is ALWAYS drawn (so every drop stays visible); the currency orb image + amount label is
    ; drawn highest-value first and SKIPPED when it would overlap an already-placed label — so a
    ; dense cluster no longer turns the amounts into an unreadable mush. Queued into the shared
    ; batches, so it must run just before _FlushBatch().
    _FlushLootValues()
    {
        global g_lrvMapIconSize, g_lrvMapFontSize, g_lrvMapColor
        global g_lrvMapOutline, g_lrvMapOutlineWidth, g_lrvMapPulse, g_lrvMapOnOrb, g_lrvAlertEx
        drops := this._lrvFrameDrops
        this._lrvFrameDrops := []
        if (drops.Length = 0)
            return
        this._SortByValueExDesc(drops)        ; readable labels go to the most valuable drops

        ; User-configurable look (Config → Overlay → Loot value radar).
        dotCol  := 0x5AA8C8                     ; gold marker dot (beside style only)
        txtCol  := GroupColorToBgr(IsSet(g_lrvMapColor) ? g_lrvMapColor : "#C8A85A")
        iconSz  := (IsSet(g_lrvMapIconSize) ? g_lrvMapIconSize : 18)
        fontPx  := (IsSet(g_lrvMapFontSize) ? g_lrvMapFontSize : 14)
        font    := this._GetFont(-fontPx, 600)
        gap     := 3
        outline := (!IsSet(g_lrvMapOutline) || g_lrvMapOutline)
        ow      := (IsSet(g_lrvMapOutlineWidth) && g_lrvMapOutlineWidth > 0) ? g_lrvMapOutlineWidth : Max(2, Round(fontPx / 7))
        pulseOn := (!IsSet(g_lrvMapPulse) || g_lrvMapPulse)
        onOrb   := (!IsSet(g_lrvMapOnOrb) || g_lrvMapOnOrb)   ; orb sits ON the drop, value as a badge
        alertEx := (IsSet(g_lrvAlertEx) ? g_lrvAlertEx : 0)
        pulse   := 0.5 + 0.5 * Sin(A_TickCount / 220.0)       ; 0..1 wall-clock pulse phase

        placed := []                           ; [x1, y1, x2, y2] of labels already drawn this frame
        for _, d in drops
        {
            sx := d[1], sy := d[2], parts := d[3], valueEx := d[4]
            high   := (pulseOn && alertEx > 0 && valueEx >= alertEx)
            hasOrb := (parts && IsObject(parts) && OverlayIconReady(parts["icon"]))
            num    := (parts && IsObject(parts) && parts.Has("num")) ? parts["num"] : ""

            if (onOrb && hasOrb)
            {
                ; ── Orb-as-marker: the orb REPLACES the dot entirely. The value is a badge at the
                ; lower-right, LEFT-anchored so longer numbers grow rightward (never cover the orb).
                ; High-value: the ORB ITSELF pulses (no halo/dot behind it). ──
                isz := high ? iconSz + Round(iconSz * 0.18 * pulse) : iconSz
                ix := sx - isz // 2, iy := sy - isz // 2
                tm := this._MeasureText(font, num)
                numW := tm["w"], numH := tm["h"]
                nx := sx + iconSz // 5                          ; left-anchored → grows right
                ny := sy + iconSz // 2 - Round(numH * 0.72)     ; sit low (lower-right, overhanging)
                bx1 := Min(ix, nx), by1 := Min(iy, ny)
                bx2 := Max(ix + isz, nx + numW), by2 := Max(iy + isz, ny + numH)
                if this._LootOverlaps(placed, bx1, by1, bx2, by2)
                    continue
                placed.Push([bx1, by1, bx2, by2])
                if (outline)
                    this._OrbOutline(parts["icon"], ix, iy, isz, ow)
                this._DrawIconBatched(parts["icon"], ix, iy, isz, isz)
                if (outline)
                    this._DrawTextOutlined(nx, ny, num, txtCol, font, ow)
                else
                    this._DrawText(nx, ny, num, txtCol, font)
                continue
            }

            ; ── Beside-marker: gold dot on the drop, amount + orb to the right (or text only). ──
            dotR := d[5] ? 4 : 3
            if (high)
                this._DrawDot(sx, sy, 0x80E0FF, dotR + 2 + Round(5 * pulse))
            this._DrawDot(sx, sy, dotCol, dotR)
            if !(parts && IsObject(parts))
                continue
            tm := this._MeasureText(font, num)
            numW := tm["w"], numH := tm["h"]
            half := Max(numH, iconSz) // 2
            tx := sx + 7, iconX := tx + numW + gap
            bx2 := hasOrb ? (iconX + iconSz) : (tx + numW)
            if this._LootOverlaps(placed, tx, sy - half, bx2, sy + half)
                continue
            placed.Push([tx, sy - half, bx2, sy + half])
            iy := sy - iconSz // 2
            if (hasOrb)
            {
                if (outline)
                    this._OrbOutline(parts["icon"], iconX, iy, iconSz, ow)
                this._DrawIconBatched(parts["icon"], iconX, iy, iconSz, iconSz)
                if (outline)
                    this._DrawTextOutlined(tx, sy - numH // 2, num, txtCol, font, ow)
                else
                    this._DrawText(tx, sy - numH // 2, num, txtCol, font)
            }
            else
            {
                ; Text fallback so the value still reads when the orb image is unavailable.
                unit := (parts.Has("icon") && parts["icon"] = "divine") ? " div" : " ex"
                if (outline)
                    this._DrawTextOutlined(tx, sy - numH // 2, num unit, txtCol, font, ow)
                else
                    this._DrawText(tx, sy - numH // 2, num unit, txtCol, font)
            }
        }
    }

    ; AABB overlap test against the label boxes already placed this frame.
    _LootOverlaps(placed, x1, y1, x2, y2)
    {
        for _, p in placed
            if (x1 < p[3] && x2 > p[1] && y1 < p[4] && y2 > p[2])
                return true
        return false
    }

    ; 8-direction black silhouette halo behind an orb (the image equivalent of a text outline).
    _OrbOutline(iconKey, x, y, sz, ow)
    {
        this._DrawIconBatched(iconKey, x - ow, y, sz, sz, true)
        this._DrawIconBatched(iconKey, x + ow, y, sz, sz, true)
        this._DrawIconBatched(iconKey, x, y - ow, sz, sz, true)
        this._DrawIconBatched(iconKey, x, y + ow, sz, sz, true)
        this._DrawIconBatched(iconKey, x - ow, y - ow, sz, sz, true)
        this._DrawIconBatched(iconKey, x + ow, y - ow, sz, sz, true)
        this._DrawIconBatched(iconKey, x - ow, y + ow, sz, sz, true)
        this._DrawIconBatched(iconKey, x + ow, y + ow, sz, sz, true)
    }

    ; Insertion-sorts the frame drops by valueEx (element [4]) descending — tiny list.
    _SortByValueExDesc(arr)
    {
        i := 2
        while (i <= arr.Length)
        {
            cur := arr[i]
            j := i - 1
            while (j >= 1 && arr[j][4] < cur[4])
            {
                arr[j + 1] := arr[j]
                j -= 1
            }
            arr[j + 1] := cur
            i += 1
        }
    }

    ; ── Batch flush ──────────────────────────────────────────────────────────────────────
    ; Renders all queued draw operations in one pass — called once per frame before _Blit().
    ;
    ; Flush order (correct layering):
    ;   1. Lines       — sit below the dots
    ;   2. Normal dots (entity dots, player dot, zone-scan dots)
    ;   3. Top dot     — highlighted entity always on top
    ;   4. Text        — labels always at the very top
    ;
    ; Dot-batch technique: BeginPath → n×Ellipse → EndPath → StrokeAndFillPath
    ;   → 2 SelectObject + 1 BeginPath + n×Ellipse + 1 EndPath + 1 StrokeAndFillPath
    ;   instead of 5 DllCalls × n per color group.
    ;
    ; Line technique: PolyPolyline with n×2-point segments
    ;   → 1 SelectObject + 1 PolyPolyline instead of 4 DllCalls × n.
    _FlushBatch()
    {
        dc := this.memDC

        ; ── 1. Lines ─────────────────────────────────────────────────────────────────────
        for key, segs in this._lineBatch
        {
            n := segs.Length
            if !n
                continue
            color  := key & 0xFFFFFF
            width  := (key >> 24) & 0xFF
            pen    := this._GetPen(color, width)
            oldPen := DllCall("SelectObject", "Ptr", dc, "Ptr", pen, "Ptr")

            ; PolyPolyline: all segments as 2-point polylines in one syscall
            pts    := Buffer(n * 16, 0)    ; n segments × 2 POINTs × 8 bytes
            counts := Buffer(n * 4,  0)    ; n DWORD counts of 2 each
            i := 0
            for seg in segs
            {
                NumPut("Int", seg[1], pts, i * 16)
                NumPut("Int", seg[2], pts, i * 16 + 4)
                NumPut("Int", seg[3], pts, i * 16 + 8)
                NumPut("Int", seg[4], pts, i * 16 + 12)
                NumPut("UInt", 2, counts, i * 4)
                i++
            }
            DllCall("PolyPolyline", "Ptr", dc, "Ptr", pts, "Ptr", counts, "UInt", n)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldPen)
        }
        this._lineBatch.Clear()

        ; ── 2. + 3. Dots (normal, then top) ──────────────────────────────────────────────
        this._FlushDotLayer(this._dotBatch)
        this._dotBatch.Clear()
        this._FlushDotLayer(this._dotTopBatch)
        this._dotTopBatch.Clear()

        ; ── 3b. Icons (value-aware loot orbs) — above dots, below text ─────────────────────
        if (this._iconBatch.Length > 0)
        {
            DrawOverlayIconsBatch(dc, this._iconBatch)
            this._iconBatch := []
        }

        ; ── 4. Text ──────────────────────────────────────────────────────────────────────
        ; SetBkMode once per frame — all TextOut calls benefit from it
        DllCall("SetBkMode", "Ptr", dc, "Int", 1)   ; TRANSPARENT
        ; Optional per-entry font (5th element) — used by the loot value labels. Select on change
        ; and restore the DC's original font at the end.
        curFont := 0, savedFont := 0
        for t in this._textBatch
        {
            f := (t.Length >= 5) ? t[5] : 0
            if (f != curFont)
            {
                if (f)
                {
                    sel := DllCall("SelectObject", "Ptr", dc, "Ptr", f, "Ptr")
                    if (!savedFont)
                        savedFont := sel
                }
                else if (savedFont)
                    DllCall("SelectObject", "Ptr", dc, "Ptr", savedFont)
                curFont := f
            }
            DllCall("SetTextColor", "Ptr", dc, "UInt", t[4])
            DllCall("TextOutW", "Ptr", dc, "Int", t[1], "Int", t[2], "Str", t[3], "Int", StrLen(t[3]))
        }
        if (savedFont && curFont)
            DllCall("SelectObject", "Ptr", dc, "Ptr", savedFont)
        this._textBatch := []
    }

    ; Internal: renders one dot-batch Map (used for both normal and top-priority dots).
    ; Technique: BeginPath + n×Ellipse + EndPath + StrokeAndFillPath per color/radius group.
    _FlushDotLayer(batch)
    {
        dc := this.memDC
        for key, dots in batch
        {
            color  := key & 0xFFFFFF
            radius := (key >> 24) & 0xFF
            pen    := this._GetPen(color)
            brush  := this._GetBrush(color)
            oldPen   := DllCall("SelectObject", "Ptr", dc, "Ptr", pen,   "Ptr")
            oldBrush := DllCall("SelectObject", "Ptr", dc, "Ptr", brush, "Ptr")
            DllCall("BeginPath", "Ptr", dc)
            for dot in dots
                DllCall("Ellipse", "Ptr", dc,
                    "Int", dot[1] - radius, "Int", dot[2] - radius,
                    "Int", dot[1] + radius, "Int", dot[2] + radius)
            DllCall("EndPath", "Ptr", dc)
            DllCall("StrokeAndFillPath", "Ptr", dc)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldPen)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldBrush)
        }
    }

    ; Draws a hollow rectangle outline on the back-buffer; uses NULL_BRUSH to avoid filling the interior.
    ; Not batched — called at most once per frame (UI Browser highlight).
    _DrawRect(screenX, screenY, width, height, colorBGR, penWidth := 1)
    {
        pen       := this._GetPen(colorBGR, penWidth)
        nullBrush := DllCall("GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH
        oldPen    := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen,       "Ptr")
        oldBrush  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memDC,
                "Int", screenX, "Int", screenY, "Int", screenX + width, "Int", screenY + height)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldBrush)
    }

    ; ── Range circle API ─────────────────────────────────────────────────────────────────

    ; Sets (or clears) range circles to draw around the player.
    ; circles: Array of Maps, each with "range" (world units), "color" (BGR), "label" (string).
    ; Pass an empty array [] to clear.
    SetRangeCircles(circles)
    {
        this._rangeCircles := circles
    }

    ; Draws an isometric range ellipse around the player.
    ; rangeWorld: radius in world units.  mapCenterX/Y: player screen position.
    ; projectionCos/Sin: current projection factors.  colorBGR: line color.  label: optional text.
    ; Uses Polyline (1 GDI call for all 49 segments) instead of 48 individual _DrawLine calls.
    _DrawRangeCircle(rangeWorld, mapCenterX, mapCenterY, projectionCos, projectionSin, colorBGR, label := "")
    {
        gridR    := rangeWorld / RadarOverlay.WORLD_TO_GRID_RATIO
        segments := 48
        step     := 6.2831853 / segments   ; 2π / 48
        n        := segments + 1           ; closed loop: last point = first point
        pts      := Buffer(n * 8, 0)       ; n POINTs × 8 Byte
        topSX    := 0, topSY := 999999

        Loop n
        {
            angle := (A_Index - 1) * step
            gx    := gridR * Cos(angle)
            gy    := gridR * Sin(angle)
            sx    := Round(mapCenterX + (gx - gy)       * projectionCos)
            sy    := Round(mapCenterY + (0 - gx - gy)   * projectionSin)
            NumPut("Int", sx, pts, (A_Index - 1) * 8)
            NumPut("Int", sy, pts, (A_Index - 1) * 8 + 4)
            if (sy < topSY)
                topSX := sx, topSY := sy
        }

        pen    := this._GetPen(colorBGR, 2)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)

        if (label != "")
            this._DrawText(topSX - StrLen(label) * 3, topSY - 14, label, colorBGR)
    }

    ; Draws the screen-space range circle(s) requested by debug-enabled hotkey actions
    ; (monsterCount / aim): a ring at the cursor or at the player's projected screen
    ; position, read from g_hkDebugItems. Called once per frame from Draw(), independent
    ; of the map layers, so the combat/aim radius shows even with the large map closed.
    ; The matching debug TEXT lives in the DebugOverlay's "HOTKEYS" section.
    _RenderHotkeyCircles()
    {
        global g_hkDebugItems
        if !(IsSet(g_hkDebugItems) && g_hkDebugItems is Array && g_hkDebugItems.Length)
            return

        COL_CUR := 0xC0A8FF    ; cursor / player range circle (pinkish, BGR)

        for _, rec in g_hkDebugItems
        {
            if !(rec is Map)
                continue
            ; Per-action circle color from the UI picker (BGR); 0 → the default.
            col := (rec.Has("color") && rec["color"]) ? rec["color"] : COL_CUR
            ; Cursor pixel circle (screen cursor → client coords).
            if (rec.Has("circleCursorPx") && rec["circleCursorPx"] > 0)
            {
                cx := 0, cy := 0
                CoordMode("Mouse", "Screen")
                MouseGetPos(&cx, &cy)
                ccx := cx - this._lastX, ccy := cy - this._lastY
                r := rec["circleCursorPx"]
                this._DrawPixelCircle(ccx, ccy, r, col)
                this._DrawCircleLabel(ccx, ccy, r, rec)
            }
            ; Player pixel circle (player projected to screen → client coords).
            if (rec.Has("circlePlayerPx") && rec["circlePlayerPx"] > 0)
            {
                ps := this._PlayerScreenPos()
                if (ps)
                {
                    pcx := ps["x"] - this._lastX, pcy := ps["y"] - this._lastY
                    r := rec["circlePlayerPx"]
                    this._DrawPixelCircle(pcx, pcy, r, col)
                    this._DrawCircleLabel(pcx, pcy, r, rec)
                }
            }
            ; World-radius ground rings (zoom-independent) — isometric ground ellipses
            ; around the player's / cursor's ON-SCREEN position, using the same ground
            ; projection the radar uses for dots (no W2S matrix). "circlePlayerWorld" is
            ; centred on the player; "circleCursorWorld" on the mouse cursor (experimental).
            if (rec.Has("circlePlayerWorld") && rec["circlePlayerWorld"] > 0)
            {
                ps := this._PlayerScreenPos()
                if (ps)
                    this._DrawWorldRing(ps["x"] - this._lastX, ps["y"] - this._lastY,
                        rec["circlePlayerWorld"], col, rec)
            }
            if (rec.Has("circleCursorWorld") && rec["circleCursorWorld"] > 0)
            {
                mcx := 0, mcy := 0
                CoordMode("Mouse", "Screen")
                MouseGetPos(&mcx, &mcy)
                this._DrawWorldRing(mcx - this._lastX, mcy - this._lastY,
                    rec["circleCursorWorld"], col, rec)
            }
        }
    }


    ; Draws the world-radius <worldR> range as an isometric ground ellipse around the
    ; SCREEN point (centerX, centerY) (client coords), then labels it at the lower-right of
    ; its footprint. Used by the monsterCount "range" modes (centre = the player's or the
    ; cursor's on-screen position). It maps the flat ground circle to screen with the SAME
    ; isometric projection the radar uses for entity dots — camera angle 38.7°, world→screen
    ; scale = g_combatW2SScale · windowWidth / 1920 — instead of the W2S matrix, which proved
    ; unreliable for points away from the player (the matrix ring came out invisible, and the
    ; earlier affine approximation blew up into a starburst). Tune the scale via the Combat
    ; "world-to-screen scale" slider; it is zoom-independent in world units.
    _DrawWorldRing(centerX, centerY, worldR, colorBGR, rec)
    {
        global g_combatW2SScale
        scale := (IsSet(g_combatW2SScale) && g_combatW2SScale > 0) ? g_combatW2SScale : 0.20
        sx := scale * (this._lastW / 1920.0)        ; world ±x/±y → screen-x basis
        sy := sx * RadarOverlay.CAMERA_SIN          ; isometric vertical squash (sin 38.7°)
        if (sx <= 0)
            return
        segs := 72
        step := 6.2831853 / segs
        pts := Buffer((segs + 1) * 8, 0)
        maxX := -2147483647, maxY := -2147483647
        Loop (segs + 1)
        {
            t  := (A_Index - 1) * step
            dx := worldR * Cos(t)
            dy := worldR * Sin(t)
            px := Round(centerX + (dx - dy) * sx)   ; ground-plane → screen (same as radar dots)
            py := Round(centerY - (dx + dy) * sy)
            NumPut("Int", px, pts, (A_Index - 1) * 8), NumPut("Int", py, pts, (A_Index - 1) * 8 + 4)
            if (px > maxX)
                maxX := px
            if (py > maxY)
                maxY := py
        }
        pen := this._GetPen(colorBGR, 2)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", segs + 1)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        this._DrawCircleLabelAt(maxX + 6, maxY, rec)   ; lower-right of the ellipse footprint
    }

    ; Draws a range-debug record's text (label + lines, e.g. monster counts) anchored at
    ; the lower-right of a pixel ring (~4 o'clock / 120° clockwise from the top).
    ; cx,cy = ring centre (client coords), r = ring radius (px).
    _DrawCircleLabel(cx, cy, r, rec)
    {
        this._DrawCircleLabelAt(Round(cx + r * 0.866) + 6, Round(cy + r * 0.5), rec)
    }

    ; Draws a range-debug record's text (label + lines) starting at (ax,ay) in client
    ; coords. Shared by the pixel-ring and world-ring labels. This is the spatial
    ; counterpart to the DebugOverlay's "HOTKEYS" panel, which skips range-based records
    ; precisely because their text lives here at the circle.
    _DrawCircleLabelAt(ax, ay, rec)
    {
        font := this._GetFont(-13, 600, "Segoe UI")
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        pitch := 15
        this._DrawText(ax, ay, rec.Has("label") ? rec["label"] : "?", 0x55FFFF)
        ay += pitch
        if (rec.Has("lines") && rec["lines"] is Array)
        {
            for _, ln in rec["lines"]
            {
                ; Lines are usually strings; tolerate [text, tag] pairs (buff/charge
                ; lists) although those records carry no circle and never reach here.
                this._DrawText(ax, ay, (ln is Array) ? (ln.Length >= 1 ? ln[1] : "") : ln, 0xB8DCE8)
                ay += pitch
            }
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }

    ; Draws the Atlas overlay from the global g_atlasRender snapshot (built by the
    ; Atlas reader once node offsets are confirmed). Inert while g_atlasRender is
    ; 0. Expected shape (all coords in SCREEN space):
    ;   g_atlasRender := Map(
    ;     "nodes", [ Map("x","y","name","biomeId","content"(array of tag strings),"flags"), ... ],
    ;     "connections", [ Map("x1","y1","x2","y2"), ... ],
    ;     "path", [ Map("x","y"), ... ]   ; e.g. player → selected map
    ;   )
    _RenderAtlas()
    {
        global g_atlasRender
        if !(IsSet(g_atlasRender) && g_atlasRender is Map)
            return
        nodes := g_atlasRender.Has("nodes") ? g_atlasRender["nodes"] : 0
        if !(nodes is Array) || !nodes.Length
            return

        ox := this._lastX, oy := this._lastY
        COL_CONN := 0x707070    ; node-graph connections (grey, BGR)
        COL_NAME := 0x8AD6F0    ; map names (gold-ish, BGR)
        COL_PATH := 0xFFC040    ; player → target route (cyan, BGR)
        COL_CONTENT := 0x40A0FF ; content markers (orange, BGR)

        ; Node-graph connections (under everything else).
        conns := g_atlasRender.Has("connections") ? g_atlasRender["connections"] : 0
        if (conns is Array)
        {
            for c in conns
            {
                if (c is Map && c.Has("x1"))
                    this._DrawLine(Round(c["x1"] - ox), Round(c["y1"] - oy),
                        Round(c["x2"] - ox), Round(c["y2"] - oy), COL_CONN, 2)
            }
        }

        ; Per-node: biome ring, name label, content badges.
        for nd in nodes
        {
            if !(nd is Map && nd.Has("x"))
                continue
            sx := Round(nd["x"] - ox), sy := Round(nd["y"] - oy)

            ; Always-on node marker, colored by atlas state so every node is
            ; visible. Status byte bits: bit1 = completed (blue), bit0 = accessible
            ; (green), otherwise locked (grey).
            st := nd.Has("status") ? nd["status"] : 0
            mkCol := (st & 0x02) ? 0xE0A040 : (st & 0x01) ? 0x40E0A0 : 0x808080
            this._DrawPixelCircle(sx, sy, 4, mkCol)

            bi := AtlasBiome(nd.Has("biomeId") ? nd["biomeId"] : -1)
            if (bi && bi["show"])
                this._DrawPixelCircle(sx, sy, 14, bi["color"])

            nm := nd.Has("name") ? nd["name"] : ""
            ; Hop pill "N→": maps to clear from the accessible frontier to reach a
            ; locked node (0 = accessible/completed, no pill).
            hops := nd.Has("hops") ? nd["hops"] : 0
            if (hops >= 1)
                nm := hops "→ " nm
            if (nm != "")
                this._DrawText(sx + 16, sy - 6, nm, COL_NAME)

            ; Content markers (towers/bosses/league mechanics), resolved to display
            ; names by the reader. Stacked below the map name in a content colour.
            if (nd.Has("content") && nd["content"] is Array)
            {
                cby := sy + 8
                for cname in nd["content"]
                {
                    if (cname = "")
                        continue
                    this._DrawText(sx + 16, cby, cname, COL_CONTENT)
                    cby += 14
                }
            }
        }

        ; Optional path from player to a selected map.
        path := g_atlasRender.Has("path") ? g_atlasRender["path"] : 0
        if (path is Array && path.Length >= 2)
        {
            i := 1
            while (i < path.Length)
            {
                a := path[i], b := path[i + 1]
                if (a is Map && b is Map)
                    this._DrawLine(Round(a["x"] - ox), Round(a["y"] - oy),
                        Round(b["x"] - ox), Round(b["y"] - oy), COL_PATH, 2)
                i += 1
            }
        }
    }

    ; Projects the player's world position to screen via the last radar snapshot.
    ; Returns Map("x","y") in screen coordinates, or 0 if unavailable.
    _PlayerScreenPos()
    {
        global g_radarLastSnap
        snap := (IsSet(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
        if !snap
            return 0
        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
            return 0
        inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
        w2sMatrix := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
        area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
        pwp := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0
        if !(pwp && pwp is Map)
            return 0
        pX := pwp.Has("x") ? pwp["x"] : 0
        pY := pwp.Has("y") ? pwp["y"] : 0
        pZ := pwp.Has("z") ? pwp["z"] : 0
        ci := Map("nearestWorldX", pX, "nearestWorldY", pY, "nearestWorldZ", pZ,
            "w2sMatrix", w2sMatrix, "playerWorldX", pX, "playerWorldY", pY, "playerWorldZ", pZ)
        return _WorldToScreen(ci, gameHwnd)
    }

    ; Draws a screen-space (non-isometric) circle of <radiusPx> around (cx,cy).
    _DrawPixelCircle(cx, cy, radiusPx, colorBGR)
    {
        segments := 40
        step := 6.2831853 / segments
        n := segments + 1
        pts := Buffer(n * 8, 0)
        Loop n
        {
            angle := (A_Index - 1) * step
            NumPut("Int", Round(cx + radiusPx * Cos(angle)), pts, (A_Index - 1) * 8)
            NumPut("Int", Round(cy + radiusPx * Sin(angle)), pts, (A_Index - 1) * 8 + 4)
        }
        pen := this._GetPen(colorBGR, 2)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
    }

    ; ── Internal buffer management ───────────────────────────────────────────────────────
    ; _InitBuffers / _Blit are inherited from GdiOverlayBase (same impl).

    ; ── Map Hack: walkable terrain border overlay ──────────────────────────────────

    ; Generates a pre-rendered maphack bitmap pair (color source + monochrome mask)
    ; from the walkable terrain data.  Called once when the area changes.
    ; The mask has 1-bits for border cells (non-walkable cells adjacent to walkable cells)
    ; and 0-bits elsewhere; PlgBlt uses the mask so only borders are drawn.
    _GenerateMapHackBitmap()
    {
        this._DestroyMapHackBitmap()

        terrain := this._terrain
        if !terrain
            return

        buf  := terrain["data"]
        bpr  := terrain["bytesPerRow"]
        rows := terrain["totalRows"]
        gridW := terrain["gridWidth"]
        dsz  := terrain["dataSize"]

        ; Snapshot the terrain identity now — if the player changes zone during
        ; the long generation loop below we want to bail out cleanly instead of
        ; finishing a bitmap that's already stale.
        startDsz := dsz

        STEP := 2
        bmpW := gridW // STEP
        bmpH := rows // STEP
        if (bmpW < 10 || bmpH < 10)
            return
        spc := Max(1, this._unexpSpacing)   ; unexplored-wash dot spacing (1=solid, higher=sparser)

        ; ── Source bitmap: solid maphack color ──
        screenDC := DllCall("GetDC", "Ptr", 0, "Ptr")
        hBmp := DllCall("CreateCompatibleBitmap", "Ptr", screenDC, "Int", bmpW, "Int", bmpH, "Ptr")
        hDC  := DllCall("CreateCompatibleDC", "Ptr", screenDC, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC)
        DllCall("SelectObject", "Ptr", hDC, "Ptr", hBmp)

        brush := DllCall("CreateSolidBrush", "UInt", RadarOverlay.COLOR_MAPHACK, "Ptr")
        rct := Buffer(16, 0)
        NumPut("Int", bmpW, rct, 8)
        NumPut("Int", bmpH, rct, 12)
        DllCall("FillRect", "Ptr", hDC, "Ptr", rct, "Ptr", brush)
        DllCall("DeleteObject", "Ptr", brush)

        ; ── Monochrome mask bitmap via DC (proven approach) ──
        hMask := DllCall("CreateBitmap", "Int", bmpW, "Int", bmpH, "UInt", 1, "UInt", 1, "Ptr", 0, "Ptr")
        maskDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        oldMaskBmp := DllCall("SelectObject", "Ptr", maskDC, "Ptr", hMask, "Ptr")

        blackBrush := DllCall("GetStockObject", "Int", 4, "Ptr")  ; BLACK_BRUSH
        DllCall("FillRect", "Ptr", maskDC, "Ptr", rct, "Ptr", blackBrush)

        ; ── Unexplored-wash mask (1-bit) — 1 wherever the 2×2 block has ANY walkable cell (50%
        ; stippled). Starts covering the WHOLE walkable area (nothing visited yet); cleared cell by
        ; cell as the player moves (_UpdateUnexploredVisited). Built in the same scan below. ──
        hUnexpMask := DllCall("CreateBitmap", "Int", bmpW, "Int", bmpH, "UInt", 1, "UInt", 1, "Ptr", 0, "Ptr")
        unexpMaskDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        oldUnexpBmp := DllCall("SelectObject", "Ptr", unexpMaskDC, "Ptr", hUnexpMask, "Ptr")
        DllCall("FillRect", "Ptr", unexpMaskDC, "Ptr", rct, "Ptr", blackBrush)

        ; Skip outer margin to avoid drawing the terrain boundary rectangle.
        MARGIN := 6

        ; Border detection — byte-wise mixed-region test.
        ;
        ; Each bitmap pixel maps to a 2×2 grid block at (gx, gy)..(gx+1, gy+1).
        ; Each row of that block is encoded as ONE byte (two 4-bit nibbles,
        ; lower=even-x, upper=odd-x). The pixel is a border iff the block
        ; contains BOTH walkable (nibble != 0) AND non-walkable (nibble = 0)
        ; cells — i.e. the boundary between walkable and not runs through
        ; this 2×2 region.
        ;
        ; Reading two bytes and checking a handful of bitwise conditions per
        ; pixel replaces 4-sub-cell × 8-neighbor scans of the previous version
        ; (~36 NumGets per pixel → 2). Total speedup ~10–15×. Visually equivalent
        ; for wall outlines — the previous "non-walkable cell with walkable
        ; neighbor" definition just shifts the highlighted edge inward by one
        ; cell, which at half-grid bitmap resolution is invisible.
        loop bmpH
        {
            by := A_Index - 1
            gy := by * STEP
            if (gy < MARGIN || gy >= rows - MARGIN - 1)
                continue

            ; Abort cleanly if the player changed zones mid-generation: the
            ; terrain buffer in `this._terrain` would now point at the new map
            ; and continuing would produce a mismatched bitmap. Cheap to check
            ; once every 64 rows.
            if (Mod(by, 64) = 0)
            {
                if !(this._terrain && this._terrain["dataSize"] = startDsz)
                {
                    this._DestroyMapHackBitmap()
                    DllCall("SelectObject", "Ptr", maskDC, "Ptr", oldMaskBmp)
                    DllCall("DeleteDC", "Ptr", maskDC)
                    DllCall("SelectObject", "Ptr", unexpMaskDC, "Ptr", oldUnexpBmp)
                    DllCall("DeleteDC", "Ptr", unexpMaskDC)
                    DllCall("DeleteObject", "Ptr", hUnexpMask)
                    return
                }
            }

            row1Base := gy * bpr           ; byte offset for row gy
            row2Base := (gy + 1) * bpr     ; byte offset for row gy+1

            loop bmpW
            {
                bx := A_Index - 1
                gx := bx * STEP
                if (gx < MARGIN || gx >= gridW - MARGIN - 1)
                    continue

                ; One byte per row covers cells (gx, gx+1) because gx is even.
                bIdx := gx >> 1
                i1 := row1Base + bIdx
                i2 := row2Base + bIdx
                if (i1 < 0 || i2 < 0 || i1 >= dsz || i2 >= dsz)
                    continue

                b1 := NumGet(buf, i1, "UChar")
                b2 := NumGet(buf, i2, "UChar")

                ; Unexplored-wash mask: any walkable cell in the 2×2 block, drawn as a dot-grid whose
                ; spacing (this._unexpSpacing) the user tunes — 1 = solid, higher = sparser/lighter.
                ; Starts over the whole walkable area; cleared per cell as the player explores.
                if (b1 != 0 || b2 != 0)   ; any walkable cell in the 2×2 block
                {
                    if (spc <= 1 || (Mod(bx, spc) = 0 && Mod(by, spc) = 0))
                        DllCall("SetPixelV", "Ptr", unexpMaskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)
                }

                if (   (b1 & 0x0F) != 0 && (b1 & 0xF0) != 0
                    && (b2 & 0x0F) != 0 && (b2 & 0xF0) != 0)
                    continue   ; all 4 walkable — open ground, skip

                if (b1 != 0 || b2 != 0)
                {
                    ; Mixed region — at least one walkable AND at least one
                    ; non-walkable cell within the 2×2 block. Fast border path.
                    DllCall("SetPixelV", "Ptr", maskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)
                    continue
                }

                ; All 4 cells non-walkable. Could still be the EDGE of a wall
                ; that's grid-aligned with our 2×2 sampling — adjacent walkable
                ; bytes would not show up via the mixed test. Read the 6
                ; surrounding bytes (left/right rows + above/below) and mark
                ; the pixel as a border if any of them carries a walkable cell.
                isBorder := false

                ; Left column (rows gy, gy+1 at byte index bx-1)
                if (bx > 0)
                {
                    li := row1Base + (bx - 1)
                    if (li >= 0 && li < dsz && NumGet(buf, li, "UChar") != 0)
                        isBorder := true
                    if !isBorder
                    {
                        li := row2Base + (bx - 1)
                        if (li < dsz && NumGet(buf, li, "UChar") != 0)
                            isBorder := true
                    }
                }
                ; Right column
                if (!isBorder && (bx + 1) < bpr)
                {
                    ri := row1Base + (bx + 1)
                    if (ri < dsz && NumGet(buf, ri, "UChar") != 0)
                        isBorder := true
                    if !isBorder
                    {
                        ri := row2Base + (bx + 1)
                        if (ri < dsz && NumGet(buf, ri, "UChar") != 0)
                            isBorder := true
                    }
                }
                ; Top row
                if (!isBorder && gy > 0)
                {
                    ti := (gy - 1) * bpr + bx
                    if (ti >= 0 && ti < dsz && NumGet(buf, ti, "UChar") != 0)
                        isBorder := true
                }
                ; Bottom row
                if (!isBorder && (gy + 2) < rows)
                {
                    bi := (gy + 2) * bpr + bx
                    if (bi < dsz && NumGet(buf, bi, "UChar") != 0)
                        isBorder := true
                }

                if isBorder
                    DllCall("SetPixelV", "Ptr", maskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)
            }
        }

        DllCall("SelectObject", "Ptr", maskDC, "Ptr", oldMaskBmp)
        DllCall("DeleteDC", "Ptr", maskDC)
        DllCall("SelectObject", "Ptr", unexpMaskDC, "Ptr", oldUnexpBmp)
        DllCall("DeleteDC", "Ptr", unexpMaskDC)

        ; ── Unexplored-wash colour source bitmap (solid COLOR_UNEXPLORED) + visited grid ──
        screenDC3 := DllCall("GetDC", "Ptr", 0, "Ptr")
        hUnexpBmp := DllCall("CreateCompatibleBitmap", "Ptr", screenDC3, "Int", bmpW, "Int", bmpH, "Ptr")
        unexpColorDC := DllCall("CreateCompatibleDC", "Ptr", screenDC3, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC3)
        DllCall("SelectObject", "Ptr", unexpColorDC, "Ptr", hUnexpBmp)
        ubrush := DllCall("CreateSolidBrush", "UInt", this._unexpColor, "Ptr")
        DllCall("FillRect", "Ptr", unexpColorDC, "Ptr", rct, "Ptr", ubrush)
        DllCall("DeleteObject", "Ptr", ubrush)
        this._mapUnexpColorDC  := unexpColorDC
        this._mapUnexpColorBmp := hUnexpBmp
        this._mapUnexpMask     := hUnexpMask
        this._visitedBuf := Buffer(bmpW * bmpH, 0)   ; 0 = unvisited; marked as the player moves
        this._visitedW := bmpW
        this._visitedH := bmpH
        this._unexpDirty := false
        this._unexpCacheTick := A_TickCount
        this._lastVisitCx := -999999   ; force a fresh disc scan on the new area
        this._lastVisitCy := -999999

        this._mapHackDC    := hDC
        this._mapHackBmp   := hBmp
        this._mapHackMask  := hMask
        this._mapHackW     := bmpW
        this._mapHackH     := bmpH
        this._mapHackStep  := STEP
        this._mapHackGridW := bmpW * STEP
        this._mapHackGridH := bmpH * STEP
    }

    ; Frees all GDI resources used by the maphack + unexplored-wash bitmaps.
    _DestroyMapHackBitmap()
    {
        if this._mapHackMask {
            DllCall("DeleteObject", "Ptr", this._mapHackMask)
            this._mapHackMask := 0
        }
        if this._mapHackBmp {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            if this._mapHackDC
                DllCall("SelectObject", "Ptr", this._mapHackDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this._mapHackBmp)
            this._mapHackBmp := 0
        }
        if this._mapHackDC {
            DllCall("DeleteDC", "Ptr", this._mapHackDC)
            this._mapHackDC := 0
        }
        ; Unexplored-wash layer + visited grid
        if this._mapUnexpMask {
            DllCall("DeleteObject", "Ptr", this._mapUnexpMask)
            this._mapUnexpMask := 0
        }
        if this._mapUnexpColorBmp {
            stockBmp3 := DllCall("GetStockObject", "Int", 0, "Ptr")
            if this._mapUnexpColorDC
                DllCall("SelectObject", "Ptr", this._mapUnexpColorDC, "Ptr", stockBmp3)
            DllCall("DeleteObject", "Ptr", this._mapUnexpColorBmp)
            this._mapUnexpColorBmp := 0
        }
        if this._mapUnexpColorDC {
            DllCall("DeleteDC", "Ptr", this._mapUnexpColorDC)
            this._mapUnexpColorDC := 0
        }
        this._visitedBuf := 0
        this._visitedW := 0
        this._visitedH := 0
        this._unexpDirty := false
        ; The scroll cache holds a composite of these source bitmaps — force a rebuild once the
        ; new terrain layers are generated (the cache DC itself is kept and reused).
        this._maskCacheValid := false
    }

    ; Blits one pre-rendered terrain layer (srcDC's colour through mask's
    ; 1-bits) onto the back-buffer via PlgBlt with the isometric projection.
    ; Shared by the wall-border maphack and the unexplored-wash overlay —
    ; both bitmaps are generated together so they share W/H/grid dimensions.
    _BlitMaskLayer(srcDC, mask, mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                   projectionCos, projectionSin, targetDC := 0, clipW := 0, clipH := 0)
    {
        if (!srcDC || !mask)
            return
        ; Default target is the back-buffer + its dimensions; the scroll cache passes its own
        ; padded DC and size so the source-rect clipping inverse-maps the correct viewport.
        tgtDC := targetDC ? targetDC : this.memDC
        clipWW := clipW ? clipW : this.bufW
        clipHH := clipH ? clipH : this.bufH

        playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
        playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
        gridW := this._mapHackGridW
        gridH := this._mapHackGridH
        bmpW  := this._mapHackW
        bmpH  := this._mapHackH
        if (bmpW < 1 || bmpH < 1)
            return

        ; Forward affine — source pixel (bx,by) → screen — built from the same 3 grid
        ; corners the entity dots use. Grid (gx,gy) → screen:
        ;   sX = mcX + ((gx-pGX)-(gy-pGY))*pCos,  sY = mcY + (-(gx-pGX)-(gy-pGY))*pSin
        ; Source (0,0)=grid(0,0), (bmpW,0)=grid(gridW,0), (0,bmpH)=grid(0,gridH).
        dGX0 := -playerGX
        dGY0 := -playerGY
        p0x := mapCenterX + (dGX0 - dGY0) * projectionCos
        p0y := mapCenterY + (-dGX0 - dGY0) * projectionSin
        p1x := mapCenterX + ((gridW - playerGX) - dGY0) * projectionCos
        p1y := mapCenterY + (-(gridW - playerGX) - dGY0) * projectionSin
        p2x := mapCenterX + (dGX0 - (gridH - playerGY)) * projectionCos
        p2y := mapCenterY + (-dGX0 - (gridH - playerGY)) * projectionSin

        ; Per-source-pixel screen-space basis vectors (along source X and Y).
        ux := (p1x - p0x) / bmpW, uy := (p1y - p0y) / bmpW
        vx := (p2x - p0x) / bmpH, vy := (p2y - p0y) / bmpH
        det := ux * vy - uy * vx

        ; ── Source-rect clipping ──────────────────────────────────────────────────────
        ; The full bitmap maps to a parallelogram whose bounding box dwarfs the window,
        ; so PlgBlt otherwise iterates millions of off-screen pixels. Inverse-map the 4
        ; window corners into source space, take their bounding box (a superset → no
        ; outline pixels lost), pad it, and blit only that sub-rectangle. Pixel-identical
        ; to the full blit; just skips the invisible majority. Degenerate det → full blit.
        bx0 := 0, by0 := 0, bx1 := bmpW, by1 := bmpH
        if (Abs(det) > 1.0e-9)
        {
            W := clipWW, H := clipHH
            minBx := "", minBy := "", maxBx := "", maxBy := ""
            for _, c in [[0, 0], [W, 0], [0, H], [W, H]]
            {
                sx := c[1] - p0x, sy := c[2] - p0y
                bx := (sx * vy - sy * vx) / det
                by := (ux * sy - uy * sx) / det
                if (minBx = "" || bx < minBx)
                    minBx := bx
                if (maxBx = "" || bx > maxBx)
                    maxBx := bx
                if (minBy = "" || by < minBy)
                    minBy := by
                if (maxBy = "" || by > maxBy)
                    maxBy := by
            }
            pad := 2
            bx0 := Max(0,    Floor(minBx) - pad)
            by0 := Max(0,    Floor(minBy) - pad)
            bx1 := Min(bmpW, Ceil(maxBx)  + pad)
            by1 := Min(bmpH, Ceil(maxBy)  + pad)
            if (bx1 <= bx0 || by1 <= by0)
                return   ; whole map off-screen this frame → nothing to draw
        }

        subW := bx1 - bx0
        subH := by1 - by0

        ; Destination parallelogram for the clipped sub-rect (source corners → screen).
        np0x := Round(p0x + bx0 * ux + by0 * vx), np0y := Round(p0y + bx0 * uy + by0 * vy)
        np1x := Round(p0x + bx1 * ux + by0 * vx), np1y := Round(p0y + bx1 * uy + by0 * vy)
        np2x := Round(p0x + bx0 * ux + by1 * vx), np2y := Round(p0y + bx0 * uy + by1 * vy)

        ; POINT array: 3 × (x, y) = 24 bytes
        pts := Buffer(24, 0)
        NumPut("Int", np0x, pts, 0),  NumPut("Int", np0y, pts, 4)
        NumPut("Int", np1x, pts, 8),  NumPut("Int", np1y, pts, 12)
        NumPut("Int", np2x, pts, 16), NumPut("Int", np2y, pts, 20)

        DllCall("PlgBlt",
            "Ptr", tgtDC,
            "Ptr", pts,
            "Ptr", srcDC,
            "Int", bx0, "Int", by0,
            "Int", subW,
            "Int", subH,
            "Ptr", mask,
            "Int", bx0, "Int", by0)
    }

    ; Draws the walkable + maphack terrain layers through a scroll cache. The layers' rotation and
    ; scale (projectionCos/Sin) are constant frame-to-frame — only the player position changes — so
    ; the composited result is rendered ONCE into a padded off-screen cache via the expensive
    ; rotated PlgBlt (_BlitMaskLayer) and then copied to the back-buffer each frame with a cheap
    ; translated TransparentBlt (offset = the player's screen delta since the cache was built). The
    ; cache is rebuilt only when the view scrolls past the padding margin, the projection changes,
    ; the active layer set changes, or the terrain bitmap is regenerated (which sets _maskCacheValid
    ; := false) — turning a per-frame PlgBlt into an occasional one. Any failure falls back to the
    ; direct per-frame PlgBlt path, so it is never worse than before.
    ; Marks a disc of half-res bitmap cells around the player as VISITED and clears those cells from
    ; the unexplored-wash mask (only cells still washed actually change). Cheap: one byte-check per
    ; disc cell, a SetPixelV only for cells NEWLY entering the visited set; skipped entirely while the
    ; player's bitmap cell is unchanged. Sets _unexpDirty so the composite cache picks it up on its
    ; next throttled rebuild. Uses a temp DC so the mask isn't left selected when the composite reads it.
    _UpdateUnexploredVisited(playerWorldX, playerWorldY)
    {
        if !(this._unexploredOn && this._mapUnexpMask && this._visitedBuf)
            return
        STEP := this._mapHackStep
        if (STEP < 1)
            return
        bw := this._visitedW, bh := this._visitedH
        pcx := Round((playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO) / STEP)
        pcy := Round((playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO) / STEP)
        if (pcx = this._lastVisitCx && pcy = this._lastVisitCy)
            return   ; player hasn't crossed into a new cell → no new visited cells possible
        this._lastVisitCx := pcx, this._lastVisitCy := pcy

        R := RadarOverlay.UNEXP_VISIT_R, R2 := R * R
        buf := this._visitedBuf
        newCells := []
        dy := -R
        while (dy <= R)
        {
            cy := pcy + dy
            if (cy >= 0 && cy < bh)
            {
                rowBase := cy * bw
                dx := -R
                while (dx <= R)
                {
                    if (dx * dx + dy * dy <= R2)
                    {
                        cx := pcx + dx
                        if (cx >= 0 && cx < bw)
                        {
                            idx := rowBase + cx
                            if (NumGet(buf, idx, "UChar") = 0)
                            {
                                NumPut("UChar", 1, buf, idx)
                                newCells.Push(cx, cy)
                            }
                        }
                    }
                    dx += 1
                }
            }
            dy += 1
        }
        if (newCells.Length = 0)
            return

        dc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        if !dc
            return
        old := DllCall("SelectObject", "Ptr", dc, "Ptr", this._mapUnexpMask, "Ptr")
        i := 1
        while (i < newCells.Length)
        {
            DllCall("SetPixelV", "Ptr", dc, "Int", newCells[i], "Int", newCells[i + 1], "UInt", 0x000000)
            i += 2
        }
        DllCall("SelectObject", "Ptr", dc, "Ptr", old)
        DllCall("DeleteDC", "Ptr", dc)
        this._unexpDirty := true
    }

    _DrawMapLayersCached(hackOn, unexpOn, mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                         projectionCos, projectionSin)
    {
        global Profiler
        haveHack := hackOn && this._mapHackDC && this._mapHackMask
        haveUnexp := unexpOn && this._mapUnexpColorDC && this._mapUnexpMask
        if (!haveHack && !haveUnexp)
            return

        ; The unexplored wash shrinks as the player explores; fold those changes into the cache at
        ; most ~every 700 ms (a scroll past the margin also rebuilds and picks them up sooner).
        if (this._unexpDirty && (A_TickCount - this._unexpCacheTick) > 700)
        {
            this._maskCacheValid := false
            this._unexpDirty := false
            this._unexpCacheTick := A_TickCount
        }
        if (this.bufW < 1 || this.bufH < 1)
            return

        MARGIN := RadarOverlay.MASK_CACHE_MARGIN
        KEY    := RadarOverlay.MASK_CACHE_KEY
        cw := this.bufW + 2 * MARGIN
        ch := this.bufH + 2 * MARGIN

        ; (Re)create the cache DC when missing or the back-buffer size changed.
        if (!this._maskCacheDC || this._maskCacheW != cw || this._maskCacheH != ch)
        {
            this._DestroyMaskCache()
            scrDC := DllCall("GetDC", "Ptr", 0, "Ptr")
            this._maskCacheBmp := DllCall("CreateCompatibleBitmap", "Ptr", scrDC, "Int", cw, "Int", ch, "Ptr")
            this._maskCacheDC  := DllCall("CreateCompatibleDC", "Ptr", scrDC, "Ptr")
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", scrDC)
            if (!this._maskCacheDC || !this._maskCacheBmp)
            {
                this._DestroyMaskCache()
                this._DrawMapLayersDirect(haveHack, haveUnexp, mapCenterX, mapCenterY,
                    playerWorldX, playerWorldY, projectionCos, projectionSin)
                return
            }
            DllCall("SelectObject", "Ptr", this._maskCacheDC, "Ptr", this._maskCacheBmp)
            this._maskCacheW := cw, this._maskCacheH := ch
            this._maskCacheValid := false
        }

        playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
        playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
        layerKey := (haveUnexp ? "u" : "") . (haveHack ? "h" : "")

        ; Reuse the cache when the projection and layer set match and the view has scrolled less
        ; than the padding margin. The cached image is a pure translation of the current view, so
        ; the offset (player screen delta) is the same isometric basis the corners use.
        reuse := false
        offX := 0, offY := 0
        cosDrift := Abs(projectionCos - this._maskCacheCos)
        sinDrift := Abs(projectionSin - this._maskCacheSin)
        projSame := (this._maskCacheCos != 0)
            && (cosDrift <= Abs(this._maskCacheCos) * 0.002)
            && (sinDrift <= Abs(this._maskCacheSin) * 0.002)
        if (this._maskCacheValid && projSame && this._maskCacheLayers = layerKey)
        {
            dGX := playerGX - this._maskCacheOX
            dGY := playerGY - this._maskCacheOY
            offX := Round((-dGX + dGY) * projectionCos)
            offY := Round(( dGX + dGY) * projectionSin)
            if (Abs(offX) <= MARGIN && Abs(offY) <= MARGIN)
                reuse := true
        }

        if !reuse
        {
            ; Rebuild: fill with the transparent key, then blit both layers at the padded centre
            ; (+MARGIN) so a ±MARGIN scroll in either axis stays inside the cache bitmap.
            Profiler.Begin("radar.mask.rebuild")
            rct := Buffer(16, 0)
            NumPut("Int", cw, rct, 8), NumPut("Int", ch, rct, 12)
            kbrush := DllCall("CreateSolidBrush", "UInt", KEY, "Ptr")
            DllCall("FillRect", "Ptr", this._maskCacheDC, "Ptr", rct, "Ptr", kbrush)
            DllCall("DeleteObject", "Ptr", kbrush)

            ccx := mapCenterX + MARGIN, ccy := mapCenterY + MARGIN
            ; Unexplored wash goes on the BOTTOM (under the wall outlines).
            if haveUnexp
                this._BlitMaskLayer(this._mapUnexpColorDC, this._mapUnexpMask, ccx, ccy,
                    playerWorldX, playerWorldY, projectionCos, projectionSin, this._maskCacheDC, cw, ch)
            if haveHack
                this._BlitMaskLayer(this._mapHackDC, this._mapHackMask, ccx, ccy,
                    playerWorldX, playerWorldY, projectionCos, projectionSin, this._maskCacheDC, cw, ch)

            this._maskCacheOX := playerGX, this._maskCacheOY := playerGY
            this._maskCacheCos := projectionCos, this._maskCacheSin := projectionSin
            this._maskCacheLayers := layerKey
            this._maskCacheValid := true
            offX := 0, offY := 0
            Profiler.End("radar.mask.rebuild")
        }

        ; Composite the cache onto the back-buffer with the scroll offset. Sample the padded cache
        ; at (MARGIN - off) so the view lands correctly; the HUD/loot ExcludeClipRect on memDC still
        ; protects those regions. On failure, fall back to a direct blit for this frame.
        Profiler.Begin("radar.mask.blit")
        ok := DllCall("msimg32\TransparentBlt"
            , "Ptr", this.memDC, "Int", 0, "Int", 0, "Int", this.bufW, "Int", this.bufH
            , "Ptr", this._maskCacheDC, "Int", MARGIN - offX, "Int", MARGIN - offY
            , "Int", this.bufW, "Int", this.bufH, "UInt", KEY, "Int")
        Profiler.End("radar.mask.blit")
        if !ok
        {
            this._maskCacheValid := false
            this._DrawMapLayersDirect(haveHack, haveUnexp, mapCenterX, mapCenterY,
                playerWorldX, playerWorldY, projectionCos, projectionSin)
        }
    }

    ; Fallback / non-cached path: blit each active terrain layer straight to the back-buffer with
    ; the rotated PlgBlt (unexplored wash under, wall-border on top) — the original per-frame behaviour.
    _DrawMapLayersDirect(haveHack, haveUnexp, mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                         projectionCos, projectionSin)
    {
        if haveUnexp
            this._BlitMaskLayer(this._mapUnexpColorDC, this._mapUnexpMask,
                mapCenterX, mapCenterY, playerWorldX, playerWorldY, projectionCos, projectionSin)
        if haveHack
            this._BlitMaskLayer(this._mapHackDC, this._mapHackMask,
                mapCenterX, mapCenterY, playerWorldX, playerWorldY, projectionCos, projectionSin)
    }

    ; Frees the scroll-cache DC + bitmap and marks it invalid. Called on back-buffer resize and on
    ; overlay destruction; the terrain-bitmap regen path only flips _maskCacheValid (cheap reuse).
    _DestroyMaskCache()
    {
        if this._maskCacheBmp {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            if this._maskCacheDC
                DllCall("SelectObject", "Ptr", this._maskCacheDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this._maskCacheBmp)
            this._maskCacheBmp := 0
        }
        if this._maskCacheDC {
            DllCall("DeleteDC", "Ptr", this._maskCacheDC)
            this._maskCacheDC := 0
        }
        this._maskCacheW := 0, this._maskCacheH := 0
        this._maskCacheValid := false
    }

    ; Hide() and SetAlpha() are inherited from GdiOverlayBase.

    ; Destructor: hide, release the maphack bitmap pair, then let the base free the
    ; cached pens/brushes and the back-buffer.
    __Delete()
    {
        this.Hide()
        this._DestroyMapHackBitmap()
        this._DestroyMaskCache()
        super.__Delete()
    }
}
