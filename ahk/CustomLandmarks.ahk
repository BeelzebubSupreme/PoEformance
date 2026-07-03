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
    global g_clmData := Map()          ; areaCodeLower -> [ [patternLower, label], ... ]
    global g_clmCount := 0             ; total pattern count (surfaced in the header)

    try g_clmEnabled := (IniRead(g_clmConfigFile, "CustomLandmarks", "enabled", g_clmEnabled ? "1" : "0") = "1")
    _ClmLoadData()
}

; Parses data/custom_landmarks.json into g_clmData with the reference's
; normalization: strip the "…:x-y:y" tile-coord suffix at the first ':', map
; ".tdtx" -> ".tdt" (so ".tdt" is a substring of both), lowercase for
; case-insensitive InStr matching. No params / no return.
_ClmLoadData()
{
    global g_clmFile, g_clmData, g_clmCount
    g_clmData := Map()
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
            list := []
            for key, label in tiles
            {
                pat := "" key
                ci := InStr(pat, ":")
                if ci
                    pat := SubStr(pat, 1, ci - 1)
                pat := StrLower(Trim(StrReplace(pat, ".tdtx", ".tdt")))
                if (pat = "")
                    continue
                list.Push([pat, "" label])
                g_clmCount += 1
            }
            g_clmData[StrLower("" areaCode)] := list
        }
    }
}

; Returns the human-readable landmark label for a tile path in an area, or "".
; Case-insensitive SUBSTRING match: the area's own patterns first, then the global
; "*" bucket (mirrors the reference TryMatch). Params: areaCode (world-area Id, e.g.
; "G1_2"), tilePath (the tgt tile path). Gated by the caller on g_clmEnabled.
CustomLandmarkMatch(areaCode, tilePath)
{
    global g_clmData
    if !(IsSet(g_clmData) && g_clmData.Count && tilePath != "")
        return ""
    tpl := StrLower(tilePath)

    ac := StrLower("" areaCode)
    if (ac != "" && g_clmData.Has(ac))
    {
        for _, pair in g_clmData[ac]
            if InStr(tpl, pair[1])
                return pair[2]
    }
    if g_clmData.Has("*")
    {
        for _, pair in g_clmData["*"]
            if InStr(tpl, pair[1])
                return pair[2]
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
