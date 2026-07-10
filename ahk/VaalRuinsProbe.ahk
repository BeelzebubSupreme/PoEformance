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

    for rg in regions
        for _, es in [1, 2, 4]
            _VrScanRegion(g_reader, rg["base"], rg["len"], es, rg["name"], &rpt)

    outDir := A_ScriptDir "\logs"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\InGameStateMonitor.vaal_ruins_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "`n" rpt "`n`n", outPath, "UTF-8")
    try MsgBox("Vaal Ruins board probe written to:`n" outPath "`n`nRun this while standing in a Vaal Ruins temple with the board populated, then send the log.", "Vaal Ruins probe", 0x40)
}
