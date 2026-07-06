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
    ; Dynamic-allocation scan (explored-grid hunt beyond the terrain layers)
    global g_lscanCands := []       ; [ Map("name","addr","size","csum") ] StdVector-shaped candidates
    global g_lscanAreaHash := 0
    global g_lscanPgx := 0
    global g_lscanPgy := 0
}

; True if p looks like a heap pointer (above the low reserved range, below the module/code range).
_LscanHeapPtr(p)
{
    global g_reader
    return (p > 0x10000 && p < 0x7FF000000000 && g_reader.IsProbablyValidPointer(p))
}

; Reads a StdVector<byte> at `first` into a Buffer, capped at 8 MB. Returns 0 on failure. (The cap is
; inlined — a top-level `global := value` in this #Include'd-at-bottom module would never run: init gotcha.)
_LscanRead(first, size)
{
    global g_reader
    buf := g_reader.Mem.ReadBytes(first, Min(size, 8 * 1024 * 1024), true)
    return (buf is Buffer && buf.Size >= 8) ? buf : 0
}

; Sampled, position-weighted checksum of a byte Buffer — folds ~16k evenly-spaced bytes so a change
; anywhere in the covered span flips it.
_LscanChecksumBuf(buf)
{
    n := buf.Size
    step := Max(1, n // 16384)
    sum := 0
    off := 0
    while (off < n)
    {
        sum := Mod(sum + (NumGet(buf, off, "UChar") + 1) * ((off // step) + 1), 0x7FFFFFF7)
        off += step
    }
    return sum
}

; Scans `base` over [0, range) step 8 for StdVector<byte>-shaped fields (first heap-valid, last>first,
; plausible byte size) and pushes Map(name,addr,size,csum) candidates into `out` (deduped by addr,
; capped by maxTotal). `label` tags where each came from.
_LscanScanStruct(base, range, label, out, maxTotal, seen)
{
    global g_reader
    off := 0
    while (off < range)
    {
        if (out.Length >= maxTotal)
            return
        first := g_reader.Mem.ReadPtr(base + off)
        last  := g_reader.Mem.ReadPtr(base + off + 8)
        off += 8
        if !_LscanHeapPtr(first)
            continue
        if (last <= first)
            continue
        size := last - first
        if (size < 4096 || size > 64 * 1024 * 1024)
            continue
        if seen.Has(first)
            continue
        seen[first] := true
        buf := _LscanRead(first, size)
        if !buf
            continue
        ; Keep the bytes (already read for the checksum) so the diff can do a detailed monotonicity +
        ; region analysis — that's the real fog discriminator (fog only accumulates: bytes go one way).
        out.Push(Map("name", label "+0x" Format("{:X}", off - 8), "addr", first, "size", size
            , "csum", _LscanChecksumBuf(buf), "buf", buf))
    }
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

; Resolves the live InGameState address (radar snapshot first, then the reader's cache), or 0.
_LscanInGameState()
{
    global g_reader, g_radarLastSnap
    if IsObject(g_radarLastSnap)
    {
        inGs := g_radarLastSnap.Has("inGameState") ? g_radarLastSnap["inGameState"] : 0
        a := (inGs is Map && inGs.Has("address")) ? inGs["address"] : 0
        if (a && g_reader.IsProbablyValidPointer(a))
            return a
    }
    try
    {
        a := g_reader._radarInGameStateCache
        if (a && g_reader.IsProbablyValidPointer(a))
            return a
    }
    return 0
}

; Bridge LandscapeScanSnapshot: scan AreaInstance + InGameState (directly AND one pointer level deep)
; for StdVector<byte>-shaped allocations and checksum each. Stores them for the diff. The explored/fog
; grid — if it exists as a CPU allocation — is a dynamic one of these whose checksum flips when you
; uncover new map.
LandscapeScanSnapshot()
{
    global g_reader
    global g_lscanCands, g_lscanAreaHash, g_lscanPgx, g_lscanPgy
    area := _AIP_ResolveAreaInstance()
    if !area
    {
        try MsgBox("Scan: no live area (get in-game first).", "Landscape scan")
        return
    }
    inGs := _LscanInGameState()
    areaHash := g_reader.Mem.ReadUInt(area + PoE2Offsets.AreaInstance["CurrentAreaHash"])
    pg := _LgpPlayerGrid(area)

    cands := []
    seen := Map()
    MAXC := 40
    ; Direct scans.
    _LscanScanStruct(area, 0x2400, "area", cands, MAXC, seen)
    if (inGs)
        _LscanScanStruct(inGs, 0x1200, "inGs", cands, MAXC, seen)
    ; One pointer level deep from AreaInstance (the grid may live in a MiniMap/fog SUB-struct).
    subs := 0
    off := 0
    while (off < 0x2400 && cands.Length < MAXC && subs < 24)
    {
        p := g_reader.Mem.ReadPtr(area + off)
        soff := off
        off += 8
        if !_LscanHeapPtr(p) || seen.Has(p)
            continue
        _LscanScanStruct(p, 0x400, "sub@0x" Format("{:X}", soff), cands, MAXC, seen)
        subs += 1
    }

    g_lscanCands := cands
    g_lscanAreaHash := areaHash
    g_lscanPgx := pg["ok"] ? pg["gx"] : 0
    g_lscanPgy := pg["ok"] ? pg["gy"] : 0

    log := "===== Dynamic-alloc SCAN " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " =====`n"
        . "areaHash=0x" Format("{:X}", areaHash) "  candidates=" cands.Length
        . "  player=" (pg["ok"] ? Round(g_lscanPgx) "," Round(g_lscanPgy) : "?") "`n"
    for c in cands
        log .= "  " c["name"] "  addr=0x" Format("{:X}", c["addr"]) "  size=" c["size"] "`n"
    log .= "→ Now WALK to reveal NEW map area, then click 'Scan Diff'.`n`n"
    _LgpLog(log)

    try MsgBox("Scanned " cands.Length " StdVector allocations off AreaInstance/InGameState.`n`n"
        . "Now WALK to uncover NEW area, then click 'Scan Diff'.`n"
        . "Whichever allocation's checksum changed is a dynamic buffer — the fog/explored grid (if it`n"
        . "exists in CPU memory) is a grid-sized one that changes as you explore.", "Landscape scan — snapshot")
}

; Bridge LandscapeScanDiff: re-checksum every scanned allocation and report which ones CHANGED. The
; explored grid is the one that flips consistently with exploration (and is grid-sized).
LandscapeScanDiff()
{
    global g_reader
    global g_lscanCands, g_lscanAreaHash, g_lscanPgx, g_lscanPgy
    if !(g_lscanCands is Array) || g_lscanCands.Length = 0
    {
        try MsgBox("No scan snapshot yet — click 'Scan Snapshot' first.", "Landscape scan")
        return
    }
    area := _AIP_ResolveAreaInstance()
    if area
    {
        areaHash := g_reader.Mem.ReadUInt(area + PoE2Offsets.AreaInstance["CurrentAreaHash"])
        if (areaHash != g_lscanAreaHash)
        {
            try MsgBox("Area changed since scan — take a fresh Scan Snapshot.", "Landscape scan")
            return
        }
    }
    pg := area ? _LgpPlayerGrid(area) : Map("ok", false)
    moved := (pg["ok"]) ? Round(Sqrt((pg["gx"] - g_lscanPgx) ** 2 + (pg["gy"] - g_lscanPgy) ** 2)) : -1

    ; For GRID-SIZED changed candidates, a MONOTONICITY analysis is the fog discriminator: explored
    ; state only accumulates (bytes change in ONE direction and never revert), while animation/render
    ; buffers oscillate (up ≈ down). Sampled (every 24th byte) so it stays fast over multi-MB buffers.
    changedN := 0
    goneN := 0
    detail := ""     ; monotonicity lines for grid-sized (1-8 MB) changed candidates
    for c in g_lscanCands
    {
        newBuf := _LscanRead(c["addr"], c["size"])
        if !newBuf
        {
            goneN += 1
            continue
        }
        csum := _LscanChecksumBuf(newBuf)
        if (csum = c["csum"])
        {
            c["buf"] := newBuf
            continue
        }
        changedN += 1
        ; grid-sized? do the detailed sampled monotonicity diff
        if (c["size"] >= 1024 * 1024 && (c["buf"] is Buffer))
        {
            oldBuf := c["buf"]
            n := Min(oldBuf.Size, newBuf.Size)
            samples := 0, changed := 0, up := 0, down := 0, minO := n, maxO := -1
            off := 0
            while (off < n)
            {
                ov := NumGet(oldBuf, off, "UChar")
                nv := NumGet(newBuf, off, "UChar")
                samples += 1
                if (ov != nv)
                {
                    changed += 1
                    if (nv > ov)
                        up += 1
                    else
                        down += 1
                    if (off < minO)
                        minO := off
                    if (off > maxO)
                        maxO := off
                }
                off += 24
            }
            mono := (changed > 0) ? Round(100 * Max(up, down) / changed) : 0
            detail .= "    " c["name"] " sz=" c["size"]
                . ": sampled Δ=" changed "/" samples "  up=" up " down=" down " (mono " mono "%)"
                . "  offBox 0x" Format("{:X}", minO) "..0x" Format("{:X}", maxO) "`n"
        }
        c["buf"] := newBuf
    }
    if (pg["ok"])
        g_lscanPgx := pg["gx"], g_lscanPgy := pg["gy"]

    log := "----- Dynamic-alloc SCAN DIFF " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " -----`n"
        . "moved≈" moved " cells   changed=" changedN " / " g_lscanCands.Length (goneN ? ("  gone=" goneN) : "") "`n"
        . "grid-sized (≥1MB) changed — monotonicity (fog = high mono%, one-directional):`n"
        . (detail != "" ? detail : "    (none)`n")
        . "`n"
    _LgpLog(log)

    try MsgBox("Scan diff (moved≈" moved " cells): " changedN "/" g_lscanCands.Length " changed.`n`n"
        . "Grid-sized candidates — MONOTONICITY (fog only accumulates → mono near 100%, up>>down):`n`n"
        . (detail != "" ? detail : "(no grid-sized allocation changed)")
        . "`n`nA candidate with mono≈100% (nearly all up) that grows toward where you walked is the`n"
        . "explored grid. Oscillating ones (up≈down) are render/animation buffers.`n"
        . "Full detail in logs\\InGameStateMonitor.landscape_probe.log", "Landscape scan — diff")
}

; Appends a block to the probe log (logs\ folder).
_LgpLog(text)
{
    dir := A_ScriptDir "\logs"
    if !DirExist(dir)
        try DirCreate(dir)
    try FileAppend(text, dir "\InGameStateMonitor.landscape_probe.log", "UTF-8")
}
