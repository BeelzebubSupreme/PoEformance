; ExploredTracker.ahk
; Always-on exploration-coverage tracker — INDEPENDENT of AutoPilot.
;
; The AutoPilot ExplorationModule only updates g_exploreCurrentPercent while the
; bot is actively exploring. For the on-map Loot bar we want a coverage figure
; during normal manual play too, so this is a self-contained, lightweight tracker
; that mirrors the ExplorationModule's proven approach:
;   - mark a disc of walkable coarse cells around the player as visited each tick;
;   - flood-fill the REACHABLE region from the player's cell (time-sliced,
;     height-gated) and re-base the percentage on that region — NOT on the whole
;     terrain grid. Dividing by every walkable cell would sit at ~1% forever,
;     because PoE2's walkable grid includes huge unreachable areas outside the
;     playable zone (and, on multi-level maps, every floor).
; Exposes visited/reachable as g_mapExploredPercent (0-100), reset per area.
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

; Core tracker: area-init + per-tick visited-disc mark + reachable-region flood
; fill + region-rebased percentage.
_RunExploredTracker(radarSnap)
{
    global g_mapExploredPercent
    static _visited := 0            ; Buffer — byte per coarse cell (0/1 visited)
    static _totalWalkable := 0      ; walkable coarse cells in the area (pre-region)
    static _visitedWalkable := 0    ; visited walkable cells (region-filtered once built)
    static _terrainSz := 0          ; cache key for area-change detection
    static _STEP := 4               ; coarse step (4x4 grid cells per coarse cell)
    static _coarseW := 0, _coarseH := 0, _bpr := 0, _rows := 0
    static _lastTick := 0
    ; Reachable-region flood fill (from the player's seed cell) — the denominator.
    static _regionMap := 0          ; Buffer — byte per coarse cell (1 = reachable)
    static _regionQ := []
    static _regionQHead := 1
    static _regionDone := false
    static _regionWalkable := 0     ; reachable walkable cells (the real denominator)
    static _regionVisitedCnt := 0   ; already-visited cells found inside the region
    static _DIRX := [1, -1, 0, 0]
    static _DIRY := [0, 0, 1, -1]

    ; Self-throttle once the region is built (coverage changes slowly; ~300 ms is
    ; plenty). While the region is still flooding, run every tick so it completes
    ; in ~1 s instead of dragging out at the throttled rate.
    now := A_TickCount
    if (_regionDone && _lastTick != 0 && (now - _lastTick) < 300)
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
        ; Reset reachability state — rebuilt from the player's new position.
        _regionMap := 0
        _regionQ := []
        _regionQHead := 1
        _regionDone := false
        _regionWalkable := 0
        _regionVisitedCnt := 0
        g_mapExploredPercent := 0
    }
    if (_totalWalkable = 0)
        return

    ; Terrain-height context — gates the region flood across floor seams so a
    ; multi-level zone doesn't count every stacked floor (same as ExplorationModule).
    heightCtx := GetTerrainHeightContext(radarSnap)
    hzOk := (heightCtx && IsObject(heightCtx) && heightCtx["val"] = "ok")
    hzPending := (heightCtx && IsObject(heightCtx) && heightCtx["val"] = "pending")

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
                                        ; Once the region is known, only in-region cells count.
                                        if (!_regionDone || (_regionMap && NumGet(_regionMap.Ptr, cellIdx, "UChar") = 1))
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

    ; ── Reachable-region flood fill (time-sliced BFS from the player cell) ──
    if (!_regionDone && !hzPending)
    {
        if (!_regionMap)
        {
            _regionMap := Buffer(_coarseW * _coarseH, 0)
            if (pcX >= 0 && pcX < _coarseW && pcY >= 0 && pcY < _coarseH)
            {
                seedIdx := pcY * _coarseW + pcX
                NumPut("UChar", 1, _regionMap.Ptr, seedIdx)
                _regionQ.Push(seedIdx)
                if _IsGridCellWalkable(pcX * _STEP, pcY * _STEP, buf, dsz, _bpr, gridW, _rows)
                {
                    _regionWalkable++
                    if (NumGet(_visited.Ptr, seedIdx, "UChar") = 1)
                        _regionVisitedCnt++
                }
            }
        }
        budgetEnd := A_TickCount + 20
        while (_regionQHead <= _regionQ.Length)
        {
            if (Mod(_regionQHead, 128) = 0 && A_TickCount >= budgetEnd)
                break
            cellIdx := _regionQ[_regionQHead]
            _regionQHead++
            cx := Mod(cellIdx, _coarseW)
            cy := cellIdx // _coarseW
            curH := hzOk ? TerrainHeightAt(heightCtx, cx * _STEP, cy * _STEP) : 0
            k := 1
            while (k <= 4)
            {
                nx := cx + _DIRX[k]
                ny := cy + _DIRY[k]
                k++
                if (nx < 0 || nx >= _coarseW || ny < 0 || ny >= _coarseH)
                    continue
                nIdx := ny * _coarseW + nx
                if (NumGet(_regionMap.Ptr, nIdx, "UChar") != 0)
                    continue
                if !_IsGridCellWalkable(nx * _STEP, ny * _STEP, buf, dsz, _bpr, gridW, _rows)
                    continue
                ; Seam gate: reject a >80-unit height jump over the 4-cell hop so
                ; the flood doesn't leak onto a different floor at a staircase.
                if (hzOk && Abs(TerrainHeightAt(heightCtx, nx * _STEP, ny * _STEP) - curH) > 80)
                    continue
                NumPut("UChar", 1, _regionMap.Ptr, nIdx)
                _regionQ.Push(nIdx)
                _regionWalkable++
                if (NumGet(_visited.Ptr, nIdx, "UChar") = 1)
                    _regionVisitedCnt++
            }
        }
        if (_regionMap && _regionQHead > _regionQ.Length)
        {
            _regionDone := true
            _regionQ := []   ; release queue memory
            _regionQHead := 1
            if (_regionWalkable > 0)
            {
                ; Re-base: the denominator is now the reachable area, and the
                ; visited count is the already-visited cells inside it.
                _totalWalkable := _regionWalkable
                _visitedWalkable := Min(_regionVisitedCnt, _regionWalkable)
            }
        }
    }

    ; ── Percentage — only once the region is built (0 hides it on the bar) ──
    if (_regionDone && _totalWalkable > 0)
        g_mapExploredPercent := Round(Min(_visitedWalkable, _totalWalkable) / _totalWalkable * 100, 1)
    else
        g_mapExploredPercent := 0
}
