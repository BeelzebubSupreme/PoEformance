; ExploredTracker.ahk
; Always-on exploration-coverage tracker — INDEPENDENT of AutoPilot.
;
; The AutoPilot ExplorationModule only updates g_exploreCurrentPercent while the
; bot is actively exploring. For the on-map Loot bar we want a coverage figure
; during normal manual play too, so this is a self-contained, lightweight tracker:
; each tick it marks a disc of walkable coarse cells around the player as visited
; and exposes the visited/total-walkable ratio as g_mapExploredPercent (0-100).
;
; Cheap: a small (~21x21) disc scan per tick (self-throttled ~300 ms) plus one
; full walkable-cell count per area (on terrain change). Own static state — never
; touches the AutoPilot tracker's buffers.
;
; Included by InGameStateMonitor.ahk.
; Globals declared in InGameStateMonitor.ahk: g_mapExploredPercent

; ── Tracker tick (called from UpdateRadarFast) ────────────────────────────────
; Params: radarSnap - full radar snapshot (needs inGameState.areaInstance.terrain
;                     + playerRenderComponent.worldPosition). No return value.
TryExploredTracker(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _RunExploredTracker(radarSnap)
    catch as ex
        try LogError("TryExploredTracker", ex)
    finally
        _running := false
}

; Core tracker: area-init (count walkable) + per-tick visited-disc mark + percent.
_RunExploredTracker(radarSnap)
{
    global g_mapExploredPercent
    static _visited := 0            ; Buffer — byte per coarse cell (0/1)
    static _totalWalkable := 0      ; walkable coarse cells in the area
    static _visitedWalkable := 0    ; visited walkable cells so far
    static _terrainSz := 0          ; cache key for area-change detection
    static _STEP := 4               ; coarse step (4x4 grid cells per coarse cell)
    static _coarseW := 0, _coarseH := 0, _bpr := 0, _rows := 0
    static _lastTick := 0

    ; Self-throttle — coverage changes slowly; ~300 ms is plenty and keeps the
    ; per-tick cost off the render hot path.
    now := A_TickCount
    if (_lastTick != 0 && (now - _lastTick) < 300)
        return
    _lastTick := now

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    terrain := (area && IsObject(area) && area.Has("terrain") && area["terrain"]) ? area["terrain"] : 0
    if !terrain
        return
    prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if !(prc && IsObject(prc) && prc.Has("worldPosition"))
        return
    pwp := prc["worldPosition"]
    playerWX := pwp.Has("x") ? pwp["x"] : 0
    playerWY := pwp.Has("y") ? pwp["y"] : 0
    if (playerWX = 0 && playerWY = 0)
        return

    ; ── Area change → reinitialize + count total walkable coarse cells ────
    tsz := terrain["dataSize"]
    if (tsz != _terrainSz)
    {
        _terrainSz := tsz
        _bpr  := terrain["bytesPerRow"]
        _rows := terrain["totalRows"]
        gridW := terrain["gridWidth"]
        _coarseW := gridW // _STEP
        _coarseH := _rows // _STEP
        _visited := Buffer(_coarseW * _coarseH, 0)

        buf := terrain["data"], dsz := terrain["dataSize"], count := 0
        cy := 0
        while (cy < _coarseH)
        {
            cx := 0
            while (cx < _coarseW)
            {
                gx := cx * _STEP, gy := cy * _STEP
                if (gx < gridW && gy < _rows)
                {
                    idx := gy * _bpr + (gx >> 1)
                    if (idx < dsz)
                    {
                        byt := NumGet(buf.Ptr, idx, "UChar")
                        if (((byt >> ((gx & 1) * 4)) & 0xF) != 0)
                            count++
                    }
                }
                cx++
            }
            cy++
        }
        _totalWalkable := count
        _visitedWalkable := 0
        g_mapExploredPercent := 0
    }
    if (_totalWalkable = 0)
        return

    ; ── Mark a disc of walkable coarse cells around the player as visited ──
    VISION_RADIUS := 40   ; ~roughly what's on screen (grid cells)
    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    pcX := (Round(playerWX / ratio)) // _STEP
    pcY := (Round(playerWY / ratio)) // _STEP
    vr  := VISION_RADIUS // _STEP
    buf := terrain["data"], dsz := terrain["dataSize"], gridW := _bpr * 2, vrSq := vr * vr

    dy := -vr
    while (dy <= vr)
    {
        cy := pcY + dy
        if (cy >= 0 && cy < _coarseH)
        {
            dx := -vr
            while (dx <= vr)
            {
                if (dx * dx + dy * dy <= vrSq)
                {
                    cx := pcX + dx
                    if (cx >= 0 && cx < _coarseW)
                    {
                        cellIdx := cy * _coarseW + cx
                        if (NumGet(_visited.Ptr, cellIdx, "UChar") = 0)
                        {
                            gx := cx * _STEP, gy := cy * _STEP
                            if (gx < gridW && gy < _rows)
                            {
                                tIdx := gy * _bpr + (gx >> 1)
                                if (tIdx < dsz)
                                {
                                    byt := NumGet(buf.Ptr, tIdx, "UChar")
                                    if (((byt >> ((gx & 1) * 4)) & 0xF) != 0)
                                    {
                                        NumPut("UChar", 1, _visited.Ptr, cellIdx)
                                        _visitedWalkable++
                                    }
                                }
                            }
                        }
                    }
                }
                dx++
            }
        }
        dy++
    }

    g_mapExploredPercent := Round((_visitedWalkable / _totalWalkable) * 100, 1)
}
