; LandscapeGridProbe.ahk
; RE diagnostic — investigate the TerrainMetadata `GridLandscapeData` StdVector<byte> (@0xE8, absolute
; AreaInstance+0x9A0) to find out whether it carries the map's "explored / fog-of-war" per-cell state.
;
; It sits right next to the known `GridWalkableData` (@0xD0) and is the same StdVector<byte> shape, but
; is never read by the tool. Fog-of-war is DYNAMIC — it flips as the player reveals the map — so the
; definitive test is: SNAPSHOT the grid, walk to uncover new territory, then DIFF. If cells changed
; (especially clustered around where you moved), it is the explored grid; if nothing changed, it is
; static data (a second walkability / terrain-type layer, not fog).
;
; Bridge: `LandscapeGridSnapshot` / `LandscapeGridDiff`; UI buttons in the RE-tools row. Writes
; logs\InGameStateMonitor.landscape_probe.log + a summary MsgBox. Reuses _AIP_ResolveAreaInstance from
; AreaInstanceProbe.

; Seeds the snapshot globals (init gotcha).
LoadLandscapeGridProbe()
{
    global g_lgpBuf := 0            ; Buffer copy of GridLandscapeData at snapshot time
    global g_lgpSize := 0
    global g_lgpBpr := 0
    global g_lgpAreaHash := 0
    global g_lgpFirst := 0          ; the vector's first-ptr at snapshot (info only)
    global g_lgpPgx := 0            ; player grid X/Y at snapshot (to correlate changes with the path)
    global g_lgpPgy := 0
    global g_lgpTick := 0
}

; Reads a StdVector<byte> at TerrainMetadata+firstOff into Map(first,last,size,buf) — mirrors the
; walkable-grid read in ReadTerrainData. Returns 0 if the vector is empty/implausible.
_LgpReadVec(area, firstOff)
{
    global g_reader
    base := area + PoE2Offsets.AreaInstance["TerrainMetadata"]
    first := g_reader.Mem.ReadPtr(base + firstOff)
    last  := g_reader.Mem.ReadPtr(base + firstOff + 8)
    if (!first || !last || last <= first)
        return 0
    size := last - first
    if (size < 64 || size > 32 * 1024 * 1024)
        return 0
    buf := g_reader.Mem.ReadBytes(first, size, true)
    if !(buf is Buffer) || buf.Size < 64
        return 0
    return Map("first", first, "last", last, "size", size, "buf", buf)
}

; Best-effort current player grid position (from the live render component), or Map("ok",false).
_LgpPlayerGrid(area)
{
    global g_reader
    try
    {
        pInfo := area + PoE2Offsets.AreaInstance["PlayerInfo"]
        raw := g_reader.Mem.ReadPtr(pInfo + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
        lp := g_reader.ResolveEntityPointer(raw)
        rc := g_reader.ReadPlayerRenderComponent(lp)
        wp := g_reader.ExtractWorldPositionFromRenderComponent(rc)
        if (wp is Map && wp.Has("x"))
        {
            ratio := 250.0 / 0x17
            return Map("ok", true, "gx", wp["x"] / ratio, "gy", wp["y"] / ratio)
        }
    }
    return Map("ok", false)
}

; Byte-value histogram string: total distinct values + the top `topN` (value:count), plus the low/high
; nibble split (walkable is nibble-encoded, so a fog grid could be too).
_LgpHistogram(buf, topN := 10)
{
    counts := Map()
    n := buf.Size
    loop n
    {
        v := NumGet(buf, A_Index - 1, "UChar")
        counts[v] := counts.Has(v) ? counts[v] + 1 : 1
    }
    ; sort values by count desc (small map — simple selection)
    pairs := []
    for v, c in counts
        pairs.Push([v, c])
    ; simple insertion sort by count desc
    i := 2
    while (i <= pairs.Length)
    {
        key := pairs[i], j := i - 1
        while (j >= 1 && pairs[j][2] < key[2])
        {
            pairs[j + 1] := pairs[j]
            j -= 1
        }
        pairs[j + 1] := key
        i += 1
    }
    s := "distinct=" counts.Count "  top: "
    lim := Min(topN, pairs.Length)
    k := 1
    while (k <= lim)
    {
        s .= Format("0x{:02X}", pairs[k][1]) "×" pairs[k][2] "  "
        k += 1
    }
    return s
}

; Bridge LandscapeGridSnapshot: capture GridLandscapeData (+ a GridWalkableData comparison) and log its
; size, value histogram and whether it byte-matches the walkable grid. Stores a copy for the diff.
LandscapeGridProbeSnapshot()
{
    global g_reader, g_radarLastSnap
    global g_lgpBuf, g_lgpSize, g_lgpBpr, g_lgpAreaHash, g_lgpFirst, g_lgpPgx, g_lgpPgy, g_lgpTick
    area := _AIP_ResolveAreaInstance()
    if !area
    {
        try MsgBox("Landscape probe: no live area (get in-game first).", "Landscape grid")
        return
    }
    base := area + PoE2Offsets.AreaInstance["TerrainMetadata"]
    areaHash := g_reader.Mem.ReadUInt(area + PoE2Offsets.AreaInstance["CurrentAreaHash"])
    bpr := g_reader.Mem.ReadInt(base + PoE2Offsets.TerrainMetadata["BytesPerRow"])

    land := _LgpReadVec(area, PoE2Offsets.TerrainMetadata["GridLandscapeData"])
    walk := _LgpReadVec(area, PoE2Offsets.TerrainMetadata["GridWalkableData"])
    if !(land is Map)
    {
        try MsgBox("Landscape probe: GridLandscapeData vector empty/loading — retry in a few seconds.", "Landscape grid")
        return
    }

    ; byte-identical to the walkable grid?
    sameAsWalk := "n/a"
    if (walk is Map && walk["size"] = land["size"])
    {
        diff := 0
        loop land["size"]
        {
            if (NumGet(land["buf"], A_Index - 1, "UChar") != NumGet(walk["buf"], A_Index - 1, "UChar"))
            {
                diff += 1
                if (diff > 4)
                    break
            }
        }
        sameAsWalk := (diff = 0) ? "IDENTICAL to walkable" : "differs from walkable"
    }
    else if (walk is Map)
        sameAsWalk := "different size vs walkable (" walk["size"] ")"

    pg := _LgpPlayerGrid(area)
    g_lgpBuf := land["buf"]
    g_lgpSize := land["size"]
    g_lgpBpr := bpr
    g_lgpAreaHash := areaHash
    g_lgpFirst := land["first"]
    g_lgpPgx := pg["ok"] ? pg["gx"] : 0
    g_lgpPgy := pg["ok"] ? pg["gy"] : 0
    g_lgpTick := A_TickCount

    rows := (bpr > 0) ? land["size"] // bpr : 0
    hist := _LgpHistogram(land["buf"])

    log := "===== Landscape grid SNAPSHOT " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " =====`n"
        . "areaHash=0x" Format("{:X}", areaHash) "`n"
        . "GridLandscapeData: first=0x" Format("{:X}", land["first"]) " size=" land["size"]
            . " bytesPerRow=" bpr " rows=" rows " (gridW=" (bpr * 2) ")`n"
        . "vs walkable: " sameAsWalk "`n"
        . "value histogram: " hist "`n"
        . "player grid: " (pg["ok"] ? Round(g_lgpPgx) "," Round(g_lgpPgy) : "(unknown)") "`n"
        . "→ Now WALK to reveal NEW map area, then click 'Landscape Diff'.`n`n"
    _LgpLog(log)

    try MsgBox("Snapshot taken.`n`n"
        . "GridLandscapeData size: " land["size"] " bytes (" rows " rows × " bpr " bpr)`n"
        . sameAsWalk "`n"
        . "histogram: " hist "`n`n"
        . "Now WALK to uncover NEW area, then click 'Landscape Diff'.`n"
        . "If the grid is 'explored' state, cells will have changed.", "Landscape grid — snapshot")
}

; Bridge LandscapeGridDiff: re-read GridLandscapeData and diff vs the snapshot. Reports changed-cell
; count, a sample of changes (offset old→new + grid cell), the change bounding box, and how far the
; player moved — so a fog grid (cells flipping near the path) is distinguishable from static data.
LandscapeGridProbeDiff()
{
    global g_reader
    global g_lgpBuf, g_lgpSize, g_lgpBpr, g_lgpAreaHash, g_lgpFirst, g_lgpPgx, g_lgpPgy
    if !(g_lgpBuf is Buffer)
    {
        try MsgBox("No snapshot yet — click 'Landscape Snapshot' first.", "Landscape grid")
        return
    }
    area := _AIP_ResolveAreaInstance()
    if !area
    {
        try MsgBox("Landscape diff: no live area.", "Landscape grid")
        return
    }
    areaHash := g_reader.Mem.ReadUInt(area + PoE2Offsets.AreaInstance["CurrentAreaHash"])
    if (areaHash != g_lgpAreaHash)
    {
        try MsgBox("Area changed since snapshot (grids differ per area) — take a fresh snapshot.", "Landscape grid")
        return
    }

    land := _LgpReadVec(area, PoE2Offsets.TerrainMetadata["GridLandscapeData"])
    if !(land is Map) || land["size"] != g_lgpSize
    {
        try MsgBox("Landscape diff: vector size changed / unreadable.", "Landscape grid")
        return
    }

    bpr := g_lgpBpr
    nowBuf := land["buf"]
    oldBuf := g_lgpBuf
    changed := 0
    firstDiffs := ""
    minGX := 0x7FFFFFFF, minGY := 0x7FFFFFFF, maxGX := -1, maxGY := -1
    ; sum of change positions to see whether they cluster near the player
    sumGX := 0, sumGY := 0
    loop g_lgpSize
    {
        off := A_Index - 1
        ov := NumGet(oldBuf, off, "UChar")
        nv := NumGet(nowBuf, off, "UChar")
        if (ov = nv)
            continue
        changed += 1
        ; byte off → grid cell: row = off // bpr, col (byte) = off mod bpr → 2 nibble-cells at 2*col
        row := (bpr > 0) ? off // bpr : 0
        col := (bpr > 0) ? Mod(off, bpr) * 2 : 0
        if (col < minGX)
            minGX := col
        if (col > maxGX)
            maxGX := col
        if (row < minGY)
            minGY := row
        if (row > maxGY)
            maxGY := row
        sumGX += col, sumGY += row
        if (changed <= 24)
            firstDiffs .= Format("  +0x{:X} (cell {2},{3}): 0x{:02X}→0x{:02X}`n", off, col, row, ov, nv)
    }

    pg := _LgpPlayerGrid(area)
    playerNow := pg["ok"] ? (Round(pg["gx"]) "," Round(pg["gy"])) : "(unknown)"
    moved := pg["ok"] ? Round(Sqrt((pg["gx"] - g_lgpPgx)**2 + (pg["gy"] - g_lgpPgy)**2)) : -1
    cenGX := changed ? Round(sumGX / changed) : 0
    cenGY := changed ? Round(sumGY / changed) : 0

    verdict := ""
    if (changed = 0)
        verdict := "NO CHANGE → GridLandscapeData is STATIC here (not fog/explored; likely a 2nd terrain layer)."
    else
        verdict := "CHANGED " changed " bytes → candidate for explored/fog. Check the change box tracks your path."

    log := "----- Landscape grid DIFF " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " -----`n"
        . "changed bytes: " changed " / " g_lgpSize "`n"
        . (changed ? ("change box: cellX " minGX ".." maxGX ", cellY " minGY ".." maxGY "  (centre " cenGX "," cenGY ")`n") : "")
        . "player at snapshot: " Round(g_lgpPgx) "," Round(g_lgpPgy) "  now: " playerNow "  moved≈" moved " cells`n"
        . verdict "`n"
        . (firstDiffs != "" ? ("first changes:`n" firstDiffs) : "")
        . "`n"
    _LgpLog(log)

    ; Refresh the snapshot to the current state so a follow-up walk+diff is incremental.
    g_lgpBuf := nowBuf
    if (pg["ok"])
        g_lgpPgx := pg["gx"], g_lgpPgy := pg["gy"]

    try MsgBox("Diff vs snapshot:`n`n"
        . "changed bytes: " changed " / " g_lgpSize "`n"
        . (changed ? ("change box: X " minGX ".." maxGX ", Y " minGY ".." maxGY " (centre " cenGX "," cenGY ")`n") : "")
        . "player moved ≈ " moved " cells (now " playerNow ")`n`n"
        . verdict "`n`n"
        . "(snapshot advanced to now — walk more and diff again to trace it.)`n"
        . "Full detail in logs\\InGameStateMonitor.landscape_probe.log", "Landscape grid — diff")
}

; Appends a block to the probe log (logs\ folder).
_LgpLog(text)
{
    dir := A_ScriptDir "\logs"
    if !DirExist(dir)
        try DirCreate(dir)
    try FileAppend(text, dir "\InGameStateMonitor.landscape_probe.log", "UTF-8")
}
