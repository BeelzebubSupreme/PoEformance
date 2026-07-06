; LandscapeGridProbe.ahk
; RE diagnostic — hunt the map's "explored / fog-of-war" per-cell state among the terrain byte grids.
;
; TerrainMetadata (AreaInstance+0x8B8) holds FOUR parallel `StdVector<byte>` grids, each 0x18 apart:
;   GridWalkableData  @0xD0   (known: walkability nibbles — control)
;   GridLandscapeData @0xE8   (measured STATIC: terrain-type nibbles 0-5, mostly 0x55 — not fog)
;   GridLayer3        @0x100  (extra PoE2 layer — explored-grid candidate)
;   GridLayer4        @0x118  (extra PoE2 layer — explored-grid candidate)
; Fog-of-war is DYNAMIC, so the test is SNAPSHOT → walk → DIFF: whichever grid's cells FLIP as you
; uncover new map (clustered around your path) is the explored grid. A grid that never changes is
; static terrain data. This probe snapshots + diffs ALL FOUR at once so one walk checks every candidate.
;
; Bridge: `LandscapeGridSnapshot` / `LandscapeGridDiff`; UI buttons in the RE-tools row. Writes
; logs\InGameStateMonitor.landscape_probe.log + a summary MsgBox. Reuses _AIP_ResolveAreaInstance.

; Seeds the snapshot globals (init gotcha).
LoadLandscapeGridProbe()
{
    global g_lgpLayers := []        ; [ Map("name","key","buf"|0,"size") ] captured at snapshot
    global g_lgpBpr := 0
    global g_lgpAreaHash := 0
    global g_lgpPgx := 0
    global g_lgpPgy := 0
}

; The four terrain byte grids to test (PoE2Offsets.TerrainMetadata keys + a display name).
_LgpLayerDefs()
{
    return [
        Map("key", "GridWalkableData",  "name", "walkable  @0xD0"),
        Map("key", "GridLandscapeData", "name", "landscape @0xE8"),
        Map("key", "GridLayer3",        "name", "layer3    @0x100"),
        Map("key", "GridLayer4",        "name", "layer4    @0x118")
    ]
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
    if (size < 64 || size > 64 * 1024 * 1024)
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

; Byte-value histogram string: total distinct values + the top `topN` (value:count).
_LgpHistogram(buf, topN := 8)
{
    counts := Map()
    n := buf.Size
    loop n
    {
        v := NumGet(buf, A_Index - 1, "UChar")
        counts[v] := counts.Has(v) ? counts[v] + 1 : 1
    }
    pairs := []
    for v, c in counts
        pairs.Push([v, c])
    i := 2
    while (i <= pairs.Length)   ; insertion sort by count desc
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
    s := "distinct=" counts.Count "  top:"
    lim := Min(topN, pairs.Length)
    k := 1
    while (k <= lim)
    {
        s .= Format(" 0x{:02X}×{2}", pairs[k][1], pairs[k][2])
        k += 1
    }
    return s
}

; Bridge LandscapeGridSnapshot: capture ALL FOUR terrain byte grids and log each one's size + value
; histogram. Stores copies for the diff.
LandscapeGridProbeSnapshot()
{
    global g_reader
    global g_lgpLayers, g_lgpBpr, g_lgpAreaHash, g_lgpPgx, g_lgpPgy
    area := _AIP_ResolveAreaInstance()
    if !area
    {
        try MsgBox("Landscape probe: no live area (get in-game first).", "Landscape grid")
        return
    }
    base := area + PoE2Offsets.AreaInstance["TerrainMetadata"]
    areaHash := g_reader.Mem.ReadUInt(area + PoE2Offsets.AreaInstance["CurrentAreaHash"])
    bpr := g_reader.Mem.ReadInt(base + PoE2Offsets.TerrainMetadata["BytesPerRow"])
    pg := _LgpPlayerGrid(area)

    g_lgpLayers := []
    g_lgpBpr := bpr
    g_lgpAreaHash := areaHash
    g_lgpPgx := pg["ok"] ? pg["gx"] : 0
    g_lgpPgy := pg["ok"] ? pg["gy"] : 0

    log := "===== Landscape grids SNAPSHOT " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " =====`n"
        . "areaHash=0x" Format("{:X}", areaHash) "  bytesPerRow=" bpr
        . "  player=" (pg["ok"] ? Round(g_lgpPgx) "," Round(g_lgpPgy) : "?") "`n"
    msg := "Snapshot — 4 terrain grids:`n`n"
    for def in _LgpLayerDefs()
    {
        v := _LgpReadVec(area, PoE2Offsets.TerrainMetadata[def["key"]])
        if !(v is Map)
        {
            g_lgpLayers.Push(Map("name", def["name"], "key", def["key"], "buf", 0, "size", 0))
            log .= def["name"] ": (empty / loading)`n"
            msg .= def["name"] ": (empty)`n"
            continue
        }
        rows := (bpr > 0) ? v["size"] // bpr : 0
        hist := _LgpHistogram(v["buf"])
        g_lgpLayers.Push(Map("name", def["name"], "key", def["key"], "buf", v["buf"], "size", v["size"]))
        log .= def["name"] ": size=" v["size"] " rows=" rows "  " hist "`n"
        msg .= def["name"] ": " v["size"] "B  " hist "`n"
    }
    log .= "→ Now WALK to reveal NEW map area, then click 'Landscape Diff'.`n`n"
    _LgpLog(log)
    msg .= "`nNow WALK to uncover NEW area, then click 'Landscape Diff'."
    try MsgBox(msg, "Landscape grids — snapshot")
}

; Bridge LandscapeGridDiff: re-read all four grids and diff vs the snapshot. Whichever CHANGED as you
; explored is the fog/explored candidate; the change box shows whether it tracks your path.
LandscapeGridProbeDiff()
{
    global g_reader
    global g_lgpLayers, g_lgpBpr, g_lgpAreaHash, g_lgpPgx, g_lgpPgy
    if !(g_lgpLayers is Array) || g_lgpLayers.Length = 0
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
        try MsgBox("Area changed since snapshot — take a fresh snapshot.", "Landscape grid")
        return
    }
    bpr := g_lgpBpr

    pg := _LgpPlayerGrid(area)
    playerNow := pg["ok"] ? (Round(pg["gx"]) "," Round(pg["gy"])) : "?"
    moved := pg["ok"] ? Round(Sqrt((pg["gx"] - g_lgpPgx) ** 2 + (pg["gy"] - g_lgpPgy) ** 2)) : -1

    log := "----- Landscape grids DIFF " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " -----`n"
        . "player snap " Round(g_lgpPgx) "," Round(g_lgpPgy) " → now " playerNow "  moved≈" moved " cells`n"
    msg := "Diff vs snapshot (moved≈" moved " cells):`n`n"
    anyChanged := false

    for saved in g_lgpLayers
    {
        if !(saved["buf"] is Buffer)
        {
            log .= saved["name"] ": (n/a)`n"
            msg .= saved["name"] ": (n/a)`n"
            continue
        }
        v := _LgpReadVec(area, PoE2Offsets.TerrainMetadata[saved["key"]])
        if !(v is Map) || v["size"] != saved["size"]
        {
            log .= saved["name"] ": size changed / unreadable`n"
            msg .= saved["name"] ": size changed`n"
            continue
        }
        oldBuf := saved["buf"], nowBuf := v["buf"]
        changed := 0
        minGX := 0x7FFFFFFF, minGY := 0x7FFFFFFF, maxGX := -1, maxGY := -1
        sample := ""
        loop saved["size"]
        {
            off := A_Index - 1
            ov := NumGet(oldBuf, off, "UChar")
            nv := NumGet(nowBuf, off, "UChar")
            if (ov = nv)
                continue
            changed += 1
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
            if (changed <= 12)
                sample .= Format("      +0x{:X} (cell {2},{3}) 0x{:02X}→0x{:02X}`n", off, col, row, ov, nv)
        }
        saved["buf"] := nowBuf   ; advance snapshot so a follow-up walk+diff is incremental
        if (changed > 0)
        {
            anyChanged := true
            box := "X " minGX ".." maxGX ", Y " minGY ".." maxGY
            log .= "*** " saved["name"] ": CHANGED " changed " bytes  box " box "`n" sample
            msg .= "*** " saved["name"] ": CHANGED " changed " (box " box ")`n"
        }
        else
        {
            log .= saved["name"] ": no change`n"
            msg .= saved["name"] ": no change`n"
        }
    }
    if (pg["ok"])
        g_lgpPgx := pg["gx"], g_lgpPgy := pg["gy"]

    verdict := anyChanged
        ? "→ A grid CHANGED — likely the explored/dynamic layer. Check its change box tracks your path."
        : "→ NO grid changed. Explored state is NOT in these terrain layers — look at InGameState/MiniMap next."
    log .= verdict "`n`n"
    _LgpLog(log)
    msg .= "`n" verdict "`n`n(snapshot advanced — walk more + diff to trace.)"
    try MsgBox(msg, "Landscape grids — diff")
}

; Appends a block to the probe log (logs\ folder).
_LgpLog(text)
{
    dir := A_ScriptDir "\logs"
    if !DirExist(dir)
        try DirCreate(dir)
    try FileAppend(text, dir "\InGameStateMonitor.landscape_probe.log", "UTF-8")
}
