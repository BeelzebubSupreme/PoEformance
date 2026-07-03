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
