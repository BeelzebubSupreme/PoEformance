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
    global g_clmShowPaths := false     ; draw a walkable A* path from the player to each landmark
    global g_clmPathWidth := 2         ; path line width (px)
    global g_clmPathMaxDist := 6000    ; skip landmarks farther than this (world units; A* too costly)
    global g_clmPathToExits := true    ; draw routes to transition/exit landmarks
    global g_clmPathToPois := true      ; draw routes to POI / boss / chest landmarks
    global g_clmPathArrows := true     ; overlay direction chevrons along each route
    global g_clmEdgeLabels := true     ; off-screen landmark labels pinned to the map edge (large map)

    try g_clmEnabled := (IniRead(g_clmConfigFile, "CustomLandmarks", "enabled", g_clmEnabled ? "1" : "0") = "1")
    try g_clmShowPaths := (IniRead(g_clmConfigFile, "CustomLandmarks", "showPaths", g_clmShowPaths ? "1" : "0") = "1")
    try g_clmEdgeLabels := (IniRead(g_clmConfigFile, "CustomLandmarks", "edgeLabels", g_clmEdgeLabels ? "1" : "0") = "1")
    try g_clmPathWidth := Integer(IniRead(g_clmConfigFile, "CustomLandmarks", "pathWidth", g_clmPathWidth))
    try g_clmPathMaxDist := Integer(IniRead(g_clmConfigFile, "CustomLandmarks", "pathMaxDist", g_clmPathMaxDist))
    try g_clmPathToExits := (IniRead(g_clmConfigFile, "CustomLandmarks", "pathToExits", g_clmPathToExits ? "1" : "0") = "1")
    try g_clmPathToPois := (IniRead(g_clmConfigFile, "CustomLandmarks", "pathToPois", g_clmPathToPois ? "1" : "0") = "1")
    try g_clmPathArrows := (IniRead(g_clmConfigFile, "CustomLandmarks", "pathArrows", g_clmPathArrows ? "1" : "0") = "1")
    if (g_clmPathWidth < 1)
        g_clmPathWidth := 1
    if (g_clmPathMaxDist < 500)
        g_clmPathMaxDist := 500
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

; True when a walkable path to each landmark should be drawn. Cheap accessor for
; RadarOverlay.Render (same rationale as CustomLandmarksOn).
CustomLandmarkPathsOn()
{
    global g_clmEnabled, g_clmShowPaths
    return (IsSet(g_clmEnabled) && g_clmEnabled && IsSet(g_clmShowPaths) && g_clmShowPaths) ? true : false
}

; True when an off-screen landmark's label should be clamped to the map edge (along
; the player->landmark direction) so the user can see where a route/landmark leads
; even when its destination is outside the drawn large map. Cheap accessor for
; RadarOverlay.Render (same rationale as CustomLandmarksOn).
CustomLandmarkEdgeLabelsOn()
{
    global g_clmEnabled, g_clmEdgeLabels
    return (IsSet(g_clmEnabled) && g_clmEnabled && IsSet(g_clmEdgeLabels) && g_clmEdgeLabels) ? true : false
}

; Bundles the landmark-path draw options for RadarOverlay.Render (which can't add
; `global` lines). Returns Map(width, maxDist, toExits, toPois, arrows).
CustomLandmarkPathOpts()
{
    global g_clmPathWidth, g_clmPathMaxDist, g_clmPathToExits, g_clmPathToPois, g_clmPathArrows
    return Map(
        "width",   (IsSet(g_clmPathWidth) ? g_clmPathWidth : 2),
        "maxDist", (IsSet(g_clmPathMaxDist) ? g_clmPathMaxDist : 6000),
        "toExits", (IsSet(g_clmPathToExits) ? g_clmPathToExits : true),
        "toPois",  (IsSet(g_clmPathToPois) ? g_clmPathToPois : true),
        "arrows",  (IsSet(g_clmPathArrows) ? g_clmPathArrows : true))
}

; Applies one setting from the UI/bridge. No return.
_ClmApplySetting(key, val)
{
    global g_clmEnabled, g_clmShowPaths, g_clmPathWidth, g_clmPathMaxDist
    global g_clmPathToExits, g_clmPathToPois, g_clmPathArrows, g_clmEdgeLabels
    on := (val = true || val = 1 || val = "1" || val = "true")
    if (key = "enabled")
        g_clmEnabled := on
    else if (key = "showPaths")
        g_clmShowPaths := on
    else if (key = "edgeLabels")
        g_clmEdgeLabels := on
    else if (key = "pathWidth")
        g_clmPathWidth := Max(1, Integer(val))
    else if (key = "pathMaxDist")
        g_clmPathMaxDist := Max(500, Integer(val))
    else if (key = "pathToExits")
        g_clmPathToExits := on
    else if (key = "pathToPois")
        g_clmPathToPois := on
    else if (key = "pathArrows")
        g_clmPathArrows := on
}

; Persists [CustomLandmarks].
SaveCustomLandmarks()
{
    global g_clmEnabled, g_clmShowPaths, g_clmConfigFile
    global g_clmPathWidth, g_clmPathMaxDist, g_clmPathToExits, g_clmPathToPois, g_clmPathArrows, g_clmEdgeLabels
    try IniWrite(g_clmEnabled ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "enabled")
    try IniWrite(g_clmShowPaths ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "showPaths")
    try IniWrite(g_clmEdgeLabels ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "edgeLabels")
    try IniWrite(g_clmPathWidth + 0, g_clmConfigFile, "CustomLandmarks", "pathWidth")
    try IniWrite(g_clmPathMaxDist + 0, g_clmConfigFile, "CustomLandmarks", "pathMaxDist")
    try IniWrite(g_clmPathToExits ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "pathToExits")
    try IniWrite(g_clmPathToPois ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "pathToPois")
    try IniWrite(g_clmPathArrows ? "1" : "0", g_clmConfigFile, "CustomLandmarks", "pathArrows")
}

; Builds the header JSON object (settings) for the WebView push. Caller prepends the key.
BuildCustomLandmarksHeaderJson()
{
    global g_clmEnabled, g_clmShowPaths, g_clmCount
    global g_clmPathWidth, g_clmPathMaxDist, g_clmPathToExits, g_clmPathToPois, g_clmPathArrows, g_clmEdgeLabels
    return '{"enabled":' ((IsSet(g_clmEnabled) && g_clmEnabled) ? "true" : "false")
        . ',"showPaths":' ((IsSet(g_clmShowPaths) && g_clmShowPaths) ? "true" : "false")
        . ',"edgeLabels":' ((IsSet(g_clmEdgeLabels) && g_clmEdgeLabels) ? "true" : "false")
        . ',"pathWidth":' ((IsSet(g_clmPathWidth) ? g_clmPathWidth : 2) + 0)
        . ',"pathMaxDist":' ((IsSet(g_clmPathMaxDist) ? g_clmPathMaxDist : 6000) + 0)
        . ',"pathToExits":' ((IsSet(g_clmPathToExits) && g_clmPathToExits) ? "true" : "false")
        . ',"pathToPois":' ((IsSet(g_clmPathToPois) && g_clmPathToPois) ? "true" : "false")
        . ',"pathArrows":' ((IsSet(g_clmPathArrows) && g_clmPathArrows) ? "true" : "false")
        . ',"count":' ((IsSet(g_clmCount) ? g_clmCount : 0) + 0) "}"
}
