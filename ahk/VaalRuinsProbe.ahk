; VaalRuinsProbe.ahk
; RE diagnostic: hunt the live Vaal Ruins (Incursion2) TEMPLE BOARD in memory so
; the Route Planner can read the current run instead of manual entry.
;
; What we're looking for: the board is a 9x9 grid (81 cells); each cell holds a
; ROOM (the incursion2rooms row index 0..36, or an empty marker). So the board
; should appear in memory as a run of ~81 small ints, most in [0..36], with a
; handful of real rooms (>=3) among Path(1)/Nothing(0) fillers. The 6 offered
; room cards would be a short run of the same indices.
;
; The board is NOT in the UI tree (only tooltip text) — the desktop RE established
; it lives in ServerData. This scans ServerData, PlayerServerData, InGameState and
; the AreaInstance for board-shaped int runs (byte / int16 / int32 element sizes),
; decoding each candidate to room names. Run it WHILE STANDING IN A VAAL RUINS
; TEMPLE with the console/board populated. Writes logs\...vaal_ruins_probe.log.
;
; Reuses _SmResolveServerData (StashMover). Included by InGameStateMonitor.ahk.

; Room index -> id (incursion2rooms row order; kept in sync with data/incursion2_rooms.tsv).
_VrRoomName(idx)
{
    static NAMES := ["Nothing","Path","PoweredPath","Garrison","Commander","Armoury"
        , "Smithy","Generator","ViperSpymaster","ViperLegionBarracks","SynthfleshLab"
        , "FleshSurgeon","TranscendentBarracks","AlchemyLab","Thaumaturge","GolemWorks"
        , "Corruption","Vault","SacrificialChamber","SacrificeRoom","Architect","Entrance"
        , "CurrencyReward","LineageSupportReward","SocketableReward","TabletReward"
        , "UniqueReward","AccessChamber","Atziri","UnsocketingReward","DeadSpymaster"
        , "BiomeWater","BiomeMountain","BiomeGrass","BiomeForest","BiomeSwamp","BiomeDesert"]
    return (idx >= 0 && idx < NAMES.Length) ? NAMES[idx + 1] : ("#" idx)
}

; Scan one memory region for board-shaped runs of small ints at a given element
; size. A run = consecutive elements whose value is in [0..MAXIDX]; reported when
; it is long enough AND carries at least one "real" room (index >= 3) so we skip
; the endless Path/zero filler runs. Appends findings to the report string (byref).
; Params: reader, base, len (bytes to read), elemSize (1/2/4), label, &rpt.
_VrScanRegion(reader, base, len, elemSize, label, &rpt)
{
    static MAXIDX := 40, MINRUN := 18, REALIDX := 3
    if !reader.IsProbablyValidPointer(base)
        return
    blk := reader.Mem.ReadBytes(base, len)
    if !blk
        return
    typ := (elemSize = 1) ? "UChar" : (elemSize = 2) ? "Short" : "Int"
    n := len // elemSize
    hits := []            ; [{off, count, real, vals}]
    runStart := -1, runReal := 0, runVals := ""
    i := 0
    while (i < n)
    {
        v := NumGet(blk.Ptr, i * elemSize, typ)
        ok := (v >= 0 && v <= MAXIDX)
        if (ok)
        {
            if (runStart < 0)
            {
                runStart := i, runReal := 0, runVals := ""
            }
            if (v >= REALIDX)
                runReal += 1
            if (StrLen(runVals) < 400)
                runVals .= v " "
        }
        else
        {
            if (runStart >= 0 && (i - runStart) >= MINRUN && runReal >= 2)
                hits.Push(Map("off", runStart * elemSize, "count", i - runStart, "real", runReal, "vals", runVals))
            runStart := -1
        }
        i += 1
    }
    if (runStart >= 0 && (n - runStart) >= MINRUN && runReal >= 2)
        hits.Push(Map("off", runStart * elemSize, "count", n - runStart, "real", runReal, "vals", runVals))

    if (hits.Length = 0)
        return
    ; Sort by run length desc; report the top few (the board is the long one ~81).
    _VrSortByCount(hits)
    rpt .= Format("`n[{} @0x{:X}  elem={}B]  {} candidate run(s)`n", label, base, elemSize, hits.Length)
    shown := 0
    for h in hits
    {
        rpt .= Format("   +0x{:X}  len={}  real={}`n", h["off"], h["count"], h["real"])
        ; Decode the first ~24 indices to room names for eyeballing.
        decoded := "", cnt := 0
        for _, tok in StrSplit(Trim(h["vals"]), " ")
        {
            if (tok = "")
                continue
            decoded .= _VrRoomName(tok + 0) " "
            if (++cnt >= 24)
            {
                decoded .= "…"
                break
            }
        }
        rpt .= "      " decoded "`n"
        if (++shown >= 6)
        {
            rpt .= "   … (more runs truncated)`n"
            break
        }
    }
}

; Targeted pass: find DISTINCTIVE board rooms (index 19..28 = SacrificeRoom /
; Architect / the reward vaults / AccessChamber / Atziri — rare in random memory
; and present on a real endgame board) and dump the FULL decoded window around each
; so the actual board layout + stride are visible (the survey pass truncates at 24).
; Params: reader, base, len, elemSize (1/2/4), label, &rpt.
_VrTargeted(reader, base, len, elemSize, label, &rpt)
{
    if !reader.IsProbablyValidPointer(base)
        return
    blk := reader.Mem.ReadBytes(base, len)
    if !blk
        return
    typ := (elemSize = 1) ? "UChar" : (elemSize = 2) ? "Short" : "Int"
    n := len // elemSize
    hits := []
    i := 0
    while (i < n)
    {
        v := NumGet(blk.Ptr, i * elemSize, typ)
        if (v >= 19 && v <= 28)          ; SacrificeRoom(19)..Atziri(28)
            hits.Push(i)
        i += 1
    }
    if (hits.Length = 0)
        return
    header := false, lastRep := -9999, shown := 0
    for _, pos in hits
    {
        if (pos - lastRep < 40)          ; collapse hits inside the same window
            continue
        lastRep := pos
        if (!header)
        {
            rpt .= Format("`n[{} @0x{:X}  elem={}B]  {} distinctive-room hit(s)`n", label, base, elemSize, hits.Length)
            header := true
        }
        ws := Max(0, pos - 8), we := Min(n, pos + 80)
        decoded := "", j := ws
        while (j < we)
        {
            decoded .= _VrRoomName(NumGet(blk.Ptr, j * elemSize, typ)) " "
            j += 1
        }
        rpt .= Format("   @+0x{:X} (idx {}, val={}):`n      {}`n", pos * elemSize, pos, _VrRoomName(NumGet(blk.Ptr, pos * elemSize, typ)), decoded)
        if (++shown >= 8)
        {
            rpt .= "   … (more windows truncated)`n"
            break
        }
    }
}

_VrSortByCount(arr)   ; insertion sort desc by ["count"] — small N
{
    i := 2
    while (i <= arr.Length)
    {
        cur := arr[i], j := i - 1
        while (j >= 1 && arr[j]["count"] < cur["count"])
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := cur
        i += 1
    }
}

; Orchestrator (bridge "VaalRuinsProbe"): resolve the candidate regions and scan
; each for board-shaped int runs at every element size. No params, no return.
VaalRuinsProbeRun()
{
    global g_reader
    if !IsObject(g_reader)
    {
        try MsgBox("Game not connected.", "Vaal Ruins probe", 0x10)
        return
    }

    rpt := "Vaal Ruins (Incursion2) board probe`n"
    rpt .= "Looking for a ~81-int run (9x9 grid) of room indices 0..36.`n"
    rpt .= "Room index legend: 0=Nothing 1=Path 3=Garrison 4=Commander 8=Spymaster "
        . "17=Vault 21=Entrance 27=AccessChamber 28=Atziri (see data/incursion2_rooms.tsv).`n"

    regions := []
    ; ServerData + the player's ServerData sub-struct (where the board is believed to live).
    sdPtr := 0
    try sdPtr := _SmResolveServerData()
    if g_reader.IsProbablyValidPointer(sdPtr)
    {
        regions.Push(Map("name", "ServerData", "base", sdPtr, "len", 0xC000))
        pdv := 0, pdPtr := 0
        try pdv := g_reader.Mem.ReadInt64(sdPtr + PoE2Offsets.ServerData["PlayerServerData"])
        if (pdv > 0)
            try pdPtr := g_reader.Mem.ReadPtr(pdv)
        if g_reader.IsProbablyValidPointer(pdPtr)
            regions.Push(Map("name", "PlayerServerData", "base", pdPtr, "len", 0xC000))
    }
    ; InGameState (some league state hangs here).
    igs := 0
    try igs := g_reader._radarInGameStateCache
    if g_reader.IsProbablyValidPointer(igs)
        regions.Push(Map("name", "InGameState", "base", igs, "len", 0x8000))

    if (regions.Length = 0)
        rpt .= "`n(could not resolve any region — get in-game first)`n"

    rpt .= "`n===== SURVEY (board-shaped small-int runs) =====`n"
    for rg in regions
        for _, es in [1, 2, 4]
            _VrScanRegion(g_reader, rg["base"], rg["len"], es, rg["name"], &rpt)

    ; Targeted: dump the full window around every distinctive board room (Architect /
    ; reward vaults / Atziri, idx 19..28) — the real board shows up here even when the
    ; placed rooms sit past the survey preview's 24-value cutoff.
    rpt .= "`n===== TARGETED (windows around distinctive rooms idx 19..28) =====`n"
    for rg in regions
        for _, es in [1, 2, 4]
            _VrTargeted(g_reader, rg["base"], rg["len"], es, rg["name"], &rpt)

    outDir := A_ScriptDir "\logs"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\InGameStateMonitor.vaal_ruins_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "`n" rpt "`n`n", outPath, "UTF-8")
    try MsgBox("Vaal Ruins board probe written to:`n" outPath "`n`nRun this while standing in a Vaal Ruins temple with the board populated, then send the log.", "Vaal Ruins probe", 0x40)
}

; True if v looks like a user-space HEAP pointer (the game's allocations sit around
; 0x1xx..0x7FE xxxxxxxx). Used to detect the board's cell-POINTER array.
_VrIsHeap(v) => (v >= 0x10000000000 && v < 0x7FF000000000)

; From a cell-object pointer, dump the int32 fields in [0..40] (room-index / tier
; candidates) and the first few sub-pointers, so the cell struct's room field can
; be worked out. Returns a one-line string. Params: reader, ptr.
_VrDerefCell(reader, ptr)
{
    if !reader.IsProbablyValidPointer(ptr)
        return "(bad ptr)"
    blk := reader.Mem.ReadBytes(ptr, 0x80)
    if !blk
        return "(unread)"
    smalls := "", ptrs := "", o := 0
    while (o + 4 <= 0x80)
    {
        iv := NumGet(blk.Ptr, o, "Int")
        if (iv >= 0 && iv <= 40)
            smalls .= Format("@+0x{:X}={}({}) ", o, iv, _VrRoomName(iv))
        o += 4
    }
    o := 0
    while (o + 8 <= 0x80)
    {
        pv := NumGet(blk.Ptr, o, "Int64")
        if (_VrIsHeap(pv))
            ptrs .= Format("@+0x{:X}=0x{:X} ", o, pv)
        o += 8
    }
    return "ints[" Trim(smalls) "]  ptrs[" Trim(ptrs) "]"
}

; Pointer/struct board hunt (bridge "VaalRuinsPtrProbe"). Two hypotheses:
;  (A) the board is an ARRAY OF POINTERS to room-cell objects — a run of int64 that
;      are 0 (empty) or heap pointers (placed), ~81 long with a handful non-null;
;  (B) an inline STRUCT-PER-CELL array — the room index sits at a fixed offset in a
;      fixed-stride struct, so reading int32 at (base + fieldOff + i*stride) yields
;      room indices for consecutive cells.
; Scans ServerData / PlayerServerData / InGameState for both, dereferencing cell
; pointers to expose the room-index field. Writes the same log. No params.
VaalRuinsPtrProbeRun()
{
    global g_reader
    if !IsObject(g_reader)
    {
        try MsgBox("Game not connected.", "Vaal Ruins ptr probe", 0x10)
        return
    }
    rpt := "Vaal Ruins board POINTER/STRUCT hunt`n"

    regions := []
    sdPtr := 0
    try sdPtr := _SmResolveServerData()
    if g_reader.IsProbablyValidPointer(sdPtr)
    {
        regions.Push(Map("name", "ServerData", "base", sdPtr, "len", 0xC000))
        pdv := 0, pdPtr := 0
        try pdv := g_reader.Mem.ReadInt64(sdPtr + PoE2Offsets.ServerData["PlayerServerData"])
        if (pdv > 0)
            try pdPtr := g_reader.Mem.ReadPtr(pdv)
        if g_reader.IsProbablyValidPointer(pdPtr)
            regions.Push(Map("name", "PlayerServerData", "base", pdPtr, "len", 0xC000))
    }
    igs := 0
    try igs := g_reader._radarInGameStateCache
    if g_reader.IsProbablyValidPointer(igs)
        regions.Push(Map("name", "InGameState", "base", igs, "len", 0xC000))

    ; ── (A) pointer-array scan ─────────────────────────────────────────────
    rpt .= "`n===== (A) cell-POINTER arrays (0/heap runs, deref'd) =====`n"
    for rg in regions
    {
        blk := g_reader.Mem.ReadBytes(rg["base"], rg["len"])
        if !blk
            continue
        n := rg["len"] // 8
        runStart := -1, nn := []
        i := 0
        while (i <= n)
        {
            done := (i = n)
            v := done ? 1 : NumGet(blk.Ptr, i * 8, "Int64")
            ok := !done && (v = 0 || _VrIsHeap(v))
            if (ok)
            {
                if (runStart < 0)
                    runStart := i, nn := []
                if (v != 0)
                    nn.Push(Map("i", i, "p", v))
            }
            else
            {
                if (runStart >= 0 && (i - runStart) >= 20 && nn.Length >= 3 && nn.Length <= 60)
                {
                    rpt .= Format("`n[{} +0x{:X}]  span={} cells, {} non-null`n", rg["name"], runStart * 8, i - runStart, nn.Length)
                    shown := 0
                    for _, cell in nn
                    {
                        line := _VrDerefCell(g_reader, cell["p"])
                        ; Flag the board fingerprint: a cell exposing a distinctive
                        ; placed room (Architect / AccessChamber / Atziri / Legion
                        ; Barracks — 9/20/27/28) is very likely the real board.
                        fp := (InStr(line, "(Architect)") || InStr(line, "(Atziri)")
                            || InStr(line, "(AccessChamber)") || InStr(line, "(ViperLegionBarracks)")) ? "  <<< BOARD?" : ""
                        rpt .= Format("   cell#{} +0x{:X} -> 0x{:X}: {}{}`n", cell["i"] - runStart, cell["i"] * 8, cell["p"], line, fp)
                        if (++shown >= 90)
                        {
                            rpt .= "   … (more cells truncated)`n"
                            break
                        }
                    }
                }
                runStart := -1
            }
            i += 1
        }
    }

    ; ── (B) strided-struct scan ────────────────────────────────────────────
    rpt .= "`n===== (B) strided struct arrays (room index at fieldOff, stride) =====`n"
    for rg in regions
    {
        blk := g_reader.Mem.ReadBytes(rg["base"], rg["len"])
        if !blk
            continue
        for _, stride in [8, 12, 16, 20, 24, 32]
        {
            for _, fieldOff in [0, 4, 8]
            {
                bestStart := -1, bestLen := 0, bestReal := 0
                curStart := -1, curReal := 0
                maxI := (rg["len"] - fieldOff - 4) // stride
                i := 0
                while (i <= maxI)
                {
                    done := (i > maxI - 1)
                    v := done ? 999 : NumGet(blk.Ptr, fieldOff + i * stride, "Int")
                    ok := !done && (v >= 0 && v <= 40)
                    if (ok)
                    {
                        if (curStart < 0)
                            curStart := i, curReal := 0
                        if (v >= 3)
                            curReal += 1
                    }
                    else
                    {
                        if (curStart >= 0 && (i - curStart) > bestLen && curReal >= 4)
                            bestStart := curStart, bestLen := i - curStart, bestReal := curReal
                        curStart := -1
                    }
                    i += 1
                }
                ; A real board: ~40-90 cells long, ~5-20 real rooms.
                if (bestLen >= 40 && bestLen <= 100 && bestReal >= 5 && bestReal <= 25)
                {
                    rpt .= Format("`n[{} stride=0x{:X} field=+{}]  base+0x{:X}  cells={}  real={}`n",
                        rg["name"], stride, fieldOff, fieldOff + bestStart * stride, bestLen, bestReal)
                    decoded := "", j := 0
                    while (j < bestLen && j < 90)
                    {
                        decoded .= _VrRoomName(NumGet(blk.Ptr, fieldOff + (bestStart + j) * stride, "Int")) " "
                        j += 1
                    }
                    rpt .= "   " decoded "`n"
                }
            }
        }
    }

    outDir := A_ScriptDir "\logs"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\InGameStateMonitor.vaal_ruins_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " [PTR/STRUCT]`n" rpt "`n`n", outPath, "UTF-8")
    try MsgBox("Vaal Ruins ptr/struct probe written to:`n" outPath "`n`nIMPORTANT: run this with the TEMPLE CONSOLE OPEN (the board visible on screen) — the placed-board grid may only exist in memory while the console is open. Then send the log.", "Vaal Ruins ptr probe", 0x40)
}

; Best-effort world position of a snapshot entity Map (render component, or a
; top-level position). Returns "x,y,z" or "".
_VrEntPos(entity)
{
    dc := (entity.Has("decodedComponents")) ? entity["decodedComponents"] : 0
    wp := 0
    if (dc && dc is Map && dc.Has("render") && dc["render"] is Map && dc["render"].Has("worldPosition"))
        wp := dc["render"]["worldPosition"]
    else if (entity.Has("worldPosition"))
        wp := entity["worldPosition"]
    if (wp && wp is Map)
        return Round(wp.Get("x", 0)) "," Round(wp.Get("y", 0)) "," Round(wp.Get("z", 0))
    if (entity.Has("gridPosition") && entity["gridPosition"] is Map)
        return "grid " Round(entity["gridPosition"].Get("x", 0)) "," Round(entity["gridPosition"].Get("y", 0))
    return ""
}

; Entity-list board hunt (bridge "VaalRuinsEntityProbe"). Hypothesis: the placed
; rooms are WORLD ENTITIES in the temple area (they render as rich icon objects),
; so the radar's own entity snapshot may already carry them. Dumps every distinct
; entity path (+ counts) in the current area, and details any entity whose path
; hints at incursion / temple / vaal / a room / a reward with its position — which
; would let the board be read straight from entities. No params. Uses g_radarLastSnap.
VaalRuinsEntityProbeRun()
{
    global g_radarLastSnap
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
    {
        try MsgBox("No snapshot yet — get in-game, then retry.", "Vaal Ruins entity probe", 0x30)
        return
    }
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs is Map && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area is Map && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake is Map && awake.Has("sample")) ? awake["sample"] : 0
    rpt := "Vaal Ruins ENTITY hunt`n"
    if !(sample && sample is Array)
    {
        rpt .= "(no awake-entity sample)`n"
    }
    else
    {
        counts := Map(), hits := []
        for _, en in sample
        {
            if !(en is Map && en.Has("entity"))
                continue
            entity := en["entity"]
            if !(entity is Map)
                continue
            path := entity.Has("path") ? entity["path"] : ""
            if (path = "")
                continue
            counts[path] := counts.Has(path) ? counts[path] + 1 : 1
            lp := StrLower(path)
            if (InStr(lp, "incursion") || InStr(lp, "temple") || InStr(lp, "vaal")
                || InStr(lp, "atzoatl") || InStr(lp, "architect") || InStr(lp, "atziri"))
                hits.Push(path " @ " _VrEntPos(entity))
        }
        rpt .= "`n=== incursion/temple/vaal-matching entities (" hits.Length ") ===`n"
        for _, h in hits
            rpt .= "   " h "`n"
        rpt .= "`n=== ALL distinct entity paths in area (" counts.Count ") ===`n"
        for p, c in counts
            rpt .= "   x" c "  " p "`n"
    }

    outDir := A_ScriptDir "\logs"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\InGameStateMonitor.vaal_ruins_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " [ENTITY]`n" rpt "`n`n", outPath, "UTF-8")
    try MsgBox("Vaal Ruins entity probe written to:`n" outPath "`n`nRun it in the temple, then send the log.", "Vaal Ruins entity probe", 0x40)
}

; ── BOARD-CELL probe (bridge "VaalRuinsBoardCellProbe") ──────────────────────────
; BREAKTHROUGH: the placed board IS in the UI tree after all. The Temple Console's
; grid container holds 81+ cells whose StringId is literally its coordinate
; "(row, col)" (e.g. "(3, 4)"). Each cell renders its room as a TEXTURE (childCount
; 0, no text), so the room identity is the .dds path the cell references. This probe
; BFS-finds every "(r, c)" cell, reads its referenced strings (the same deref scan
; UiBrowseScanStrings uses), and maps the room-icon .dds to a room name — giving the
; live placed board straight from the console UI. Run WITH THE TEMPLE CONSOLE OPEN.

; Reduce a room-icon texture path to a short room key. Strips folders, the ".dds"
; extension and a leading "RoomHover" prefix. Param: s (a texture path). Returns the
; room key (e.g. "Garrison") or the raw filename if it doesn't match the pattern.
_VrRoomFromTex(s)
{
    n := s
    if (p := InStr(s, "/", false, -1))
        n := SubStr(s, p + 1)
    if (d := InStr(n, ".dds", false))
        n := SubStr(n, 1, d - 1)
    if (StrLower(SubStr(n, 1, 9)) = "roomhover")
        n := SubStr(n, 10)
    return n
}

; Scan one board-cell UiElement for its room-icon texture + a few sample strings.
; Mirrors UiBrowseScanStrings: for each pointer field in elem+0x000..0x400, deref and
; read wstrings at target+0x000..0x140, keeping any that look like a room texture
; (".dds"/"roomhover"/"incursion2") plus up to a few other printable strings so the
; log is conclusive even if the room naming differs. Params: reader, elem (cell addr).
; Returns Map("tex", <best room string or "">, "at", <offset str>, "samples", Array).
_VrCellDds(reader, elem)
{
    tex := "", at := "", samples := [], seen := Map()
    o := 0
    while (o < 0x400)
    {
        p := 0
        try p := reader.Mem.ReadPtr(elem + o)
        o += 8
        if (!reader.IsProbablyValidPointer(p) || p = elem || p >= 0x7FF000000000)
            continue
        po := 0
        while (po < 0x140)
        {
            s := ""
            try s := reader.ReadStdWStringAt(p + po, 128)
            po += 8
            if (s = "" || StrLen(s) < 3 || !_AtlasPrintable(s))
                continue
            ls := StrLower(s)
            if (tex = "" && (InStr(ls, ".dds") || InStr(ls, "roomhover") || InStr(ls, "incursion2")))
            {
                tex := s
                at  := Format("@+0x{:X}->+0x{:X}", o - 8, po)
            }
            ; Collect a few distinct non-coordinate sample strings for diagnostics.
            if (!seen.Has(s) && samples.Length < 6 && !RegExMatch(s, "^\(\d+,\s*\d+\)$"))
            {
                seen[s] := true
                samples.Push(s)
            }
        }
    }
    return Map("tex", tex, "at", at, "samples", samples)
}

; One-shot board reader. BFS the GameUI for "(r, c)" cells, read each cell's room
; texture, log a per-cell list + a rendered grid. No params; writes the log + MsgBox.
VaalRuinsBoardCellProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Board-cell probe: not connected to PoE2.", "Vaal Ruins board cell", 0x10)
        return
    }
    reader := g_reader
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — get in-game, open the Temple Console, then retry.", "Vaal Ruins board cell", 0x10)
        return
    }

    ; ── 1) BFS-collect cells whose StringId is a "(r, c)" coordinate ──
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    cells := []
    queue := [root], visited := Map(), nodes := 0
    deadline := A_TickCount + 12000
    while (queue.Length > 0 && nodes < 24000)
    {
        if (A_TickCount > deadline)
            break
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
        sid := ""
        try sid := reader.ReadStdWStringAt(ptr + sidOff, 32)
        if RegExMatch(sid, "^\((\d+),\s*(\d+)\)$", &mm)
            cells.Push(Map("r", mm[1] + 0, "c", mm[2] + 0, "addr", ptr))
        cf := g["childFirst"], cl := g["childLast"]
        if (reader.IsProbablyValidPointer(cf) && cl > cf)
        {
            n := Min((cl - cf) // A_PtrSize, 512)
            buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
            if buf
            {
                Loop n
                {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }

    ; ── 2) Read each cell's room texture ──
    maxR := 0, maxC := 0, filled := 0
    grid := Map()
    for _, cell in cells
    {
        info := _VrCellDds(reader, cell["addr"])
        cell["tex"] := info["tex"]
        cell["at"]  := info["at"]
        cell["samples"] := info["samples"]
        cell["room"] := (info["tex"] != "") ? _VrRoomFromTex(info["tex"]) : ""
        if (cell["room"] != "")
            filled += 1
        grid[cell["r"] "," cell["c"]] := cell["room"]
        maxR := Max(maxR, cell["r"]), maxC := Max(maxC, cell["c"])
    }

    ; Sort cells by row then col for a stable listing.
    _VrSortCells(cells)

    nl := "`r`n"
    rpt := "=== BOARD-CELL probe (UI grid, StringId '(r, c)') ===" nl
    rpt .= "GameUI root=0x" Format("{:X}", root) "  nodes=" nodes "  cells=" cells.Length "  with-room=" filled nl
    rpt .= "Run with the Temple Console OPEN. Each cell's room = its .dds icon path." nl nl

    rpt .= "--- FILLED cells (room resolved) ---" nl
    for _, cell in cells
    {
        if (cell["room"] = "")
            continue
        rpt .= Format("  ({}, {})  0x{:X}  = {}   [{} {}]", cell["r"], cell["c"], cell["addr"]
                    , cell["room"], cell["at"], cell["tex"]) nl
    }
    if (filled = 0)
        rpt .= "  (none resolved — see sample strings below to find the room field)" nl

    ; Sample strings for the first cells that had strings but no room match — so if
    ; the .dds filter missed, the real referenced strings are visible in the log.
    rpt .= nl "--- sample strings per cell (first 30 cells with any string) ---" nl
    shown := 0
    for _, cell in cells
    {
        if (cell["samples"].Length = 0 || shown >= 30)
            continue
        shown += 1
        line := ""
        for _, s in cell["samples"]
            line .= " | " s
        rpt .= Format("  ({}, {}):{}", cell["r"], cell["c"], line) nl
    }

    ; Rendered grid (room key abbreviated to 4 chars; '.' = empty/unrevealed).
    rpt .= nl "--- GRID (rows 0.." maxR ", cols 0.." maxC ") ---" nl
    r := 0
    while (r <= maxR)
    {
        row := Format("  r{:X} ", r)
        c := 0
        while (c <= maxC)
        {
            v := grid.Has(r "," c) ? grid[r "," c] : ""
            row .= Format("{:-6}", (v = "" ? "." : SubStr(v, 1, 5)))
            c += 1
        }
        rpt .= row nl
        r += 1
    }

    outDir := A_ScriptDir "\logs"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\InGameStateMonitor.vaal_ruins_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " [BOARD-CELL]" nl rpt nl nl, outPath, "UTF-8")
    try MsgBox("Board-cell probe done.`n`nCells found: " cells.Length "`nRooms resolved: " filled
             . "`n`nLog: logs\InGameStateMonitor.vaal_ruins_probe.log`n`n"
             . (filled > 0 ? "Send me the log — I'll read your placed board off it."
                           : "No room textures resolved; the sample-strings section will show me where the room field is."), "Vaal Ruins board cell", 0x40)
}

; Insertion sort of collected cells by row (then col). Param: cells (Array of Maps).
_VrSortCells(cells)
{
    i := 2
    while (i <= cells.Length)
    {
        cur := cells[i], j := i - 1
        while (j >= 1 && (cells[j]["r"] > cur["r"] || (cells[j]["r"] = cur["r"] && cells[j]["c"] > cur["c"])))
        {
            cells[j + 1] := cells[j]
            j -= 1
        }
        cells[j + 1] := cur
        i += 1
    }
}
