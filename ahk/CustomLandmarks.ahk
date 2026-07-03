; CustomLandmarks.ahk
; Port of Sikaka/POE2Radar's CustomLandmarkData: curated human-readable labels for
; terrain-tile locations (boss arenas + rewards, waypoints, area-transition
; destinations), keyed by area code -> tile-path pattern -> label. Loaded once from
; data/custom_landmarks.json. The tile paths we already read in the tgt-scan
; (PoE2EntityReader._ProcessTgtScanBatch's `tgtPath`, e.g.
; "Metadata/Terrain/Woods/Slash/HagWitchArena_01.tdtx") are matched by SUBSTRING
; against the (normalized) patterns; lookup is area-specific first, then the global
; "*" bucket. Rendered as a label on the radar POI (see RadarOverlay).
;
; Data credit: the landmark labels ship from Sikaka/POE2Radar (CustomLandmarks.json).
; Globals are seeded in LoadCustomLandmarks() (AHK v2 init gotcha).

; Seeds globals, loads the [CustomLandmarks] config + the JSON lookup. Called once
; at startup by the main script. No return.
LoadCustomLandmarks()
{
    global g_clmEnabled := true
    global g_clmConfigFile := A_ScriptDir "\poeformance_config.ini"
    global g_clmFile := A_ScriptDir "\data\custom_landmarks.json"
    global g_clmData := Map()          ; areaCodeLower -> Map(fullTileKeyLower -> label)  (coordinate-exact)
    global g_clmPathOnly := Map()      ; areaCodeLower -> Map(pathLower -> label)  (rare coordless keys)
    global g_clmPaths := Map()         ; pathLower -> true  (cheap candidate pre-filter for the reader)
    global g_clmCount := 0             ; total pattern count (surfaced in the header)

    try g_clmEnabled := (IniRead(g_clmConfigFile, "CustomLandmarks", "enabled", g_clmEnabled ? "1" : "0") = "1")
    _ClmLoadData()
}

; Parses data/custom_landmarks.json into a COORDINATE-EXACT lookup. Each JSON key is
; "<path>.tdtx:<A>-y:<B>" where A/B are the tile's sub-cell (TileIdX/TileIdY) — the
; SAME numbers the reader reads per tile. We keep the whole key (normalized ".tdtx"
; -> ".tdt", lowercased) and match it exactly, so a landmark pinned to ONE sub-cell
; no longer matches every reused instance of that tile file (e.g. a "BossWall01" wall
; placed all over the map). The 2 rare coordless keys go into a path-only fallback.
; Also builds g_clmPaths (the set of landmark tile paths) for a cheap reader pre-filter.
; No params / no return.
_ClmLoadData()
{
    global g_clmFile, g_clmData, g_clmPathOnly, g_clmPaths, g_clmCount
    g_clmData := Map()
    g_clmPathOnly := Map()
    g_clmPaths := Map()
    g_clmCount := 0
    try
    {
        if !FileExist(g_clmFile)
            return
        raw := FileRead(g_clmFile, "UTF-8")
        parsed := JsonFull_Parse(raw)
        if !(parsed && Type(parsed) = "Map")
            return
        for areaCode, tiles in parsed
        {
            if !(tiles && Type(tiles) = "Map")
                continue
            areaLower := StrLower("" areaCode)
            if !g_clmData.Has(areaLower)
                g_clmData[areaLower] := Map()
            if !g_clmPathOnly.Has(areaLower)
                g_clmPathOnly[areaLower] := Map()
            for key, label in tiles
            {
                full := StrLower(Trim(StrReplace("" key, ".tdtx", ".tdt")))
                if (full = "")
                    continue
                ; The path part is everything before the ":<A>-y:<B>" coord suffix
                ; (metadata paths carry no ':', so the first ':' is the split).
                ci := InStr(full, ":")
                pathPart := ci ? SubStr(full, 1, ci - 1) : full
                if (ci)
                    g_clmData[areaLower][full] := "" label       ; coordinate-exact key
                else
                    g_clmPathOnly[areaLower][pathPart] := "" label  ; rare coordless entry
                g_clmPaths[pathPart] := true
                g_clmCount += 1
            }
        }
    }
}

; Cheap yes/no: could this tile path EVER carry a landmark label (ignoring the
; coordinate)? Lets the reader skip the per-instance coord match for the vast
; majority of tiles. Param: tilePath (the tgt tile path). Returns bool.
CustomLandmarkPathCandidate(tilePath)
{
    global g_clmPaths
    if !(IsSet(g_clmPaths) && g_clmPaths.Count && tilePath != "")
        return false
    return g_clmPaths.Has(StrLower(StrReplace(tilePath, ".tdtx", ".tdt")))
}

; Returns the human-readable landmark label for a SPECIFIC tile instance, or "".
; COORDINATE-EXACT match on "<path>:<TileIdX>-y:<TileIdY>" — the area's own keys
; first, then the global "*" bucket; both tile-coord orderings are tried (the reader
; swaps X/Y on odd rotation, and the reference's orientation is not guaranteed). Falls
; back to a path-only match for the 2 coordless keys. Params: areaCode (world-area Id,
; e.g. "G1_2"), tilePath, tileIdX, tileIdY (the tile's sub-cell). Gated by the caller.
CustomLandmarkMatch(areaCode, tilePath, tileIdX, tileIdY)
{
    global g_clmData, g_clmPathOnly
    if !(IsSet(g_clmData) && tilePath != "")
        return ""
    p  := StrLower(StrReplace(tilePath, ".tdtx", ".tdt"))
    k1 := p ":" tileIdX "-y:" tileIdY
    k2 := p ":" tileIdY "-y:" tileIdX
    ac := StrLower("" areaCode)

    ; Coordinate-exact: area-specific first, then global "*".
    for _, key in [ac, "*"]
    {
        if (key = "" || !g_clmData.Has(key))
            continue
        am := g_clmData[key]
        if am.Has(k1)
            return am[k1]
        if am.Has(k2)
            return am[k2]
    }
    ; Path-only fallback for the rare coordless keys.
    for _, key in [ac, "*"]
    {
        if (key = "" || !g_clmPathOnly.Has(key))
            continue
        pm := g_clmPathOnly[key]
        if pm.Has(p)
            return pm[p]
    }
    return ""
}

; True when landmark labels should be drawn (feature enabled). Lets callers that
; can't add a `global` line (e.g. deep in RadarOverlay.Render) gate cheaply.
CustomLandmarksOn()
{
    global g_clmEnabled
    return (IsSet(g_clmEnabled) && g_clmEnabled) ? true : false
}

; Applies one setting from the UI/bridge. No return.
_ClmApplySetting(key, val)
{
    global g_clmEnabled
    if (key = "enabled")
        g_clmEnabled := (val = true || val = 1 || val = "1" || val = "true")
}

; Persists [CustomLandmarks].
SaveCustomLandmarks()
{
    global g_clmEnabled, g_clmConfigFile
    try IniWrite(g_clmEnabled ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "enabled")
}

; Builds the header JSON object (settings) for the WebView push. Caller prepends the key.
BuildCustomLandmarksHeaderJson()
{
    global g_clmEnabled, g_clmCount
    return '{"enabled":' ((IsSet(g_clmEnabled) && g_clmEnabled) ? "true" : "false")
        . ',"count":' ((IsSet(g_clmCount) ? g_clmCount : 0) + 0) "}"
}

; One-shot diagnostic: dumps every matched landmark POI in the current zone with its
; world position + distance from the player, so a "label sits at the wrong spot"
; report can be root-caused without the game running here. Writes debug\custom_landmarks_diag_*.txt
; (readable in Config -> Data & Logs) + a MsgBox summary. Triggered by the UI button
; (bridge CustomLandmarkDiag). No params / no return.
CustomLandmarkDiagnose()
{
    global g_reader, g_radarLastSnap, g_clmCount

    snap := (IsSet(g_radarLastSnap) && IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    inGs := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
    {
        try MsgBox("Custom Landmarks Diagnose: no radar snapshot yet (enter a zone first).", "Custom Landmarks", 0x40)
        return
    }

    ; Player world position.
    pwp := 0
    pr := area.Has("playerRenderComponent") ? area["playerRenderComponent"] : 0
    if (pr && IsObject(pr) && pr.Has("worldPosition"))
        pwp := pr["worldPosition"]
    px := (pwp && IsObject(pwp) && pwp.Has("x")) ? pwp["x"] : 0
    py := (pwp && IsObject(pwp) && pwp.Has("y")) ? pwp["y"] : 0

    areaCode := ""
    try areaCode := (IsObject(g_reader) && g_reader.HasOwnProp("_radarWorldAreaCache")
        && IsObject(g_reader._radarWorldAreaCache) && g_reader._radarWorldAreaCache.Has("id"))
        ? g_reader._radarWorldAreaCache["id"] : ""

    totalTilesX := 0, totalTiles := 0
    try totalTilesX := (IsObject(g_reader) && g_reader.HasOwnProp("_tgtScanTotalTilesX")) ? g_reader._tgtScanTotalTilesX : 0
    try totalTiles  := (IsObject(g_reader) && g_reader.HasOwnProp("_tgtScanTotalTiles"))  ? g_reader._tgtScanTotalTiles  : 0

    zsr := area.Has("zoneScanResults") ? area["zoneScanResults"] : 0

    out := "=== Custom Landmarks Diagnose  (" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") ") ===`n`n"
    out .= "area code (worldAreaDat id): '" areaCode "'`n"
    out .= "player world pos: x=" Round(px) " y=" Round(py) "`n"
    out .= "terrain grid: totalTilesX=" totalTilesX "  totalTiles=" totalTiles
         . (totalTilesX ? ("  => impliedRows=" Round(totalTiles / totalTilesX)) : "") "`n"
    out .= "loaded landmark patterns: " (IsSet(g_clmCount) ? g_clmCount : 0) "`n`n"

    n := 0, labelled := 0, msgLines := ""
    if (zsr && Type(zsr) = "Array")
    {
        out .= "POIs with a curated label (path | type | tileWorld x,y | dist | refined):`n"
        for _, t in zsr
        {
            if !(t && IsObject(t))
                continue
            lbl := t.Has("label") ? t["label"] : ""
            if (lbl = "")
                continue
            labelled += 1
            wx := t.Has("worldX") ? t["worldX"] : 0
            wy := t.Has("worldY") ? t["worldY"] : 0
            gx := t.Has("gridX") ? t["gridX"] : 0
            gy := t.Has("gridY") ? t["gridY"] : 0
            ty := t.Has("type") ? t["type"] : ""
            ref := (t.Has("refined") && t["refined"]) ? "REFINED" : "tile-idx"
            pth := t.Has("path") ? t["path"] : ""
            short := pth
            sl := InStr(short, "/",, -1)
            if (sl > 0)
                short := SubStr(short, sl + 1)
            ddx := wx - px, ddy := wy - py
            dist := Round(Sqrt(ddx * ddx + ddy * ddy))
            line := "  " lbl "`n"
                  . "     " short "  [" ty "]`n"
                  . "     grid(" Round(gx) "," Round(gy) ")  world(" Round(wx) "," Round(wy) ")  dist=" dist "  " ref "`n"
            out .= line
            n += 1
            if (n <= 12)
                msgLines .= "• " lbl "  d=" dist "m  " ref " (" ty ")`n"
        }
        if (labelled = 0)
            out .= "  (none — no landmark matched in this zone)`n"
    }
    else
        out .= "zoneScanResults: (not an array / empty)`n"

    out .= "`nInterpretation:`n"
    out .= "  - If the game shows a transition NEARBY but its dist here is huge, the tile-index`n"
    out .= "    world pos is wrong (needs the entity-refined position or a corrected grid formula).`n"
    out .= "  - REFINED = position came from a live entity (accurate); tile-idx = computed from`n"
    out .= "    the tile's index in the terrain grid (only source for pure terrain landmarks).`n"

    dir := A_ScriptDir "\debug"
    if !DirExist(dir)
        try DirCreate(dir)
    file := dir "\custom_landmarks_diag_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try
    {
        FileAppend(out, file, "UTF-8")
        wrote := true
    }

    summary := "Custom Landmarks Diagnose`n`n"
             . "area='" areaCode "'  player=(" Round(px) "," Round(py) ")`n"
             . "labelled POIs: " labelled "`n`n"
             . (msgLines != "" ? msgLines : "(no landmark matched in this zone)`n")
             . (wrote ? ("`nWritten to:`n" file "`n(open in Config -> Data & Logs)") : "`n(could not write debug file)")
    try MsgBox(summary, "Custom Landmarks Diagnose", 0x40)
}

; Deep RE probe for the landmark POSITION bug: re-walks the raw terrain tile vector,
; finds every tile whose path could be a landmark, and dumps ALL its occurrences with
; the array index, the row-major world pos (current formula), the tile sub-cell
; (TileIdX/Y) + rotation, the distance from the player, AND a hex/int/float dump of the
; SubTileDetailsPtr target (the prime suspect for the real per-tile position). Purpose:
; confirm whether a landmark path appears multiple times (a decorative copy near the
; array START + the real one further in) and locate the true world-position field.
; Writes debug\custom_landmarks_posprobe_*.txt + a MsgBox summary. No params / no return.
CustomLandmarkPosProbe()
{
    global g_reader, g_radarLastSnap

    if !(IsObject(g_reader) && g_reader.HasOwnProp("Mem") && IsObject(g_reader.Mem))
    {
        try MsgBox("Landmark Pos Probe: game not connected.", "Landmark Pos Probe", 0x40)
        return
    }
    snap := (IsSet(g_radarLastSnap) && IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    inGs := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    areaAddr := (area && IsObject(area) && area.Has("address")) ? area["address"] : 0
    if !areaAddr
    {
        try MsgBox("Landmark Pos Probe: no area snapshot yet (enter a zone first).", "Landmark Pos Probe", 0x40)
        return
    }

    mem := g_reader.Mem
    terrainBase := areaAddr + PoE2Offsets.AreaInstance["TerrainMetadata"]
    totalTilesX := mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesX"])
    totalTilesY := mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesY"])
    vecFirst := mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"])
    vecLast  := mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"] + 8)
    if !(g_reader.IsProbablyValidPointer(vecFirst) && vecLast > vecFirst && totalTilesX > 0)
    {
        try MsgBox("Landmark Pos Probe: terrain vector unreadable.", "Landmark Pos Probe", 0x40)
        return
    }
    tsize := 0x38
    totalTiles := Floor((vecLast - vecFirst) / tsize)
    if (totalTiles < 1 || totalTiles > 200000)
    {
        try MsgBox("Landmark Pos Probe: tile count out of range (" totalTiles ").", "Landmark Pos Probe", 0x40)
        return
    }

    pr := area.Has("playerRenderComponent") ? area["playerRenderComponent"] : 0
    pwp := (pr && IsObject(pr) && pr.Has("worldPosition")) ? pr["worldPosition"] : 0
    px := (pwp && pwp.Has("x")) ? pwp["x"] : 0
    py := (pwp && pwp.Has("y")) ? pwp["y"] : 0

    buf := mem.ReadBytes(vecFirst, totalTiles * tsize, true)
    if !buf
    {
        try MsgBox("Landmark Pos Probe: bulk tile read failed.", "Landmark Pos Probe", 0x40)
        return
    }

    offSub := PoE2Offsets.TileStruct["SubTileDetailsPtr"]
    offTgt := PoE2Offsets.TileStruct["TgtFilePtr"]
    offIdX := PoE2Offsets.TileStruct["TileIdX"]
    offIdY := PoE2Offsets.TileStruct["TileIdY"]
    offRot := PoE2Offsets.TileStruct["RotationSelector"]
    tileToGrid := 0x17
    ratio := 250.0 / 0x17

    pathCache := Map()   ; tgtFilePtr -> path (dedupe the slow string reads)
    hits := []           ; each: Map(idx, path, tIdX, tIdY, rot, wX, wY, dist, subPtr, subInfo)

    scanned := 0
    Loop totalTiles
    {
        idx := A_Index - 1
        b := idx * tsize
        tgtPtr := NumGet(buf.Ptr, b + offTgt, "Ptr")
        if !g_reader.IsProbablyValidPointer(tgtPtr)
            continue
        if pathCache.Has(tgtPtr)
            path := pathCache[tgtPtr]
        else
        {
            path := g_reader.ReadStdWStringAt(tgtPtr + PoE2Offsets.TgtFile["TgtPath"], 260)
            pathCache[tgtPtr] := path
        }
        if (path = "" || !CustomLandmarkPathCandidate(path))
            continue

        subPtr := NumGet(buf.Ptr, b + offSub, "Ptr")
        tIdX := NumGet(buf.Ptr, b + offIdX, "UChar")
        tIdY := NumGet(buf.Ptr, b + offIdY, "UChar")
        rot  := NumGet(buf.Ptr, b + offRot, "UChar")
        gX := Mod(idx, totalTilesX) * tileToGrid
        gY := Floor(idx / totalTilesX) * tileToGrid
        wX := gX * ratio
        wY := gY * ratio
        ddx := wX - px, ddy := wY - py
        dist := Round(Sqrt(ddx * ddx + ddy * ddy))

        ; Dump the SubTileDetails target as int32[0..7] + float[0..7] — hunt for the
        ; real per-tile world position (spread values near the player's ~(px,py)).
        subInfo := ""
        if g_reader.IsProbablyValidPointer(subPtr)
        {
            sb := mem.ReadBytes(subPtr, 48, true)
            if sb
            {
                ints := "", flts := ""
                Loop 8
                {
                    o := (A_Index - 1) * 4
                    ints .= NumGet(sb.Ptr, o, "Int") " "
                    flts .= Round(NumGet(sb.Ptr, o, "Float"), 1) " "
                }
                subInfo := "int[" Trim(ints) "]  flt[" Trim(flts) "]"
            }
        }

        short := path
        sl := InStr(short, "/",, -1)
        if (sl > 0)
            short := SubStr(short, sl + 1)

        hits.Push(Map("idx", idx, "short", short, "tIdX", tIdX, "tIdY", tIdY, "rot", rot
            , "wX", Round(wX), "wY", Round(wY), "dist", dist
            , "subPtr", subPtr, "subInfo", subInfo))
        scanned += 1
        if (scanned >= 120)
            break
    }

    out := "=== Custom Landmarks POSITION Probe  (" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") ") ===`n`n"
    out .= "player world pos: x=" Round(px) " y=" Round(py) "`n"
    out .= "terrain grid: totalTilesX=" totalTilesX " totalTilesY=" totalTilesY " totalTiles=" totalTiles "`n"
    out .= "landmark-candidate tile occurrences (capped 120): " hits.Length "`n"
    out .= "ratio (grid->world) = " Round(ratio, 4) "  tileToGrid=" tileToGrid "`n`n"
    out .= "Legend: idx=array index | rowMajor(x,y)=CURRENT formula pos | d=dist from player`n"
    out .= "        tileId=(TileIdX,TileIdY) sub-cell | sub=SubTileDetailsPtr dump`n"
    out .= "Look for: does one path appear at MANY idx? which occurrence's dist is small`n"
    out .= "        (= the real one near the player)? do the sub floats hold ~(" Round(px) "," Round(py) ")?`n`n"

    for _, h in hits
    {
        out .= "idx=" h["idx"] "  '" h["short"] "'  tileId(" h["tIdX"] "," h["tIdY"] ") rot=" h["rot"] "`n"
        out .= "    rowMajor(" h["wX"] "," h["wY"] ")  d=" h["dist"]
             . "  sub=" (h["subPtr"] ? Format("0x{:X}", h["subPtr"]) : "0") "`n"
        if (h["subInfo"] != "")
            out .= "    " h["subInfo"] "`n"
    }
    if (hits.Length = 0)
        out .= "(no landmark-candidate tiles found — pattern set may not match this area's tiles)`n"

    dir := A_ScriptDir "\debug"
    if !DirExist(dir)
        try DirCreate(dir)
    file := dir "\custom_landmarks_posprobe_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try
    {
        FileAppend(out, file, "UTF-8")
        wrote := true
    }

    summary := "Landmark Position Probe`n`n"
             . "player=(" Round(px) "," Round(py) ")  tiles=" totalTiles " (" totalTilesX "x" totalTilesY ")`n"
             . "landmark-candidate occurrences: " hits.Length "`n`n"
             . (wrote ? ("Written to:`n" file "`n`n(open in Config -> Data & Logs and send it to me)")
                      : "(could not write debug file)")
    try MsgBox(summary, "Landmark Position Probe", 0x40)
}
