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
                        rpt .= Format("   cell#{} +0x{:X} -> 0x{:X}: {}`n", cell["i"] - runStart, cell["i"] * 8, cell["p"], _VrDerefCell(g_reader, cell["p"]))
                        if (++shown >= 14)
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
    try MsgBox("Vaal Ruins ptr/struct probe written to:`n" outPath "`n`nRun it in the temple with the board populated, then send the log.", "Vaal Ruins ptr probe", 0x40)
}
