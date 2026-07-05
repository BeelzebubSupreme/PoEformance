; HkAnimCapture.ahk
; Live "what are nearby enemies playing right now" capture for the Macro Engine's
; enemyAnim condition. Instead of knowing animation ids, the user arms this from
; the condition editor, stands near a monster/boss, watches it attack, and clicks
; the animation that lit up to add it. Off by default — only accumulates while the
; capture panel is open (armed by HkAnimCaptureStart), so it costs nothing otherwise.
;
; Reuses the hot-path enemy animationId (decodedComponents["actor"]["animationId"])
; and the CustomHotkeys sample helpers (_HotkeysAwakeSample / _HotkeysIsTargetable).
; Pushes updateAnimCapture([...]) to the WebView ~4 Hz. Included by
; InGameStateMonitor.ahk; TryHkAnimCapture(radarSnap) runs from UpdateRadarFast.

; Seeds all globals (init gotcha). No persistence — capture is a transient tool.
LoadHkAnimCapture()
{
    global g_hkAnimCapOn := false        ; armed only while the editor panel is open
    global g_hkAnimCapSeen := Map()      ; animId -> Map(count, last, dist)
    global g_hkAnimCapArea := 0          ; area hash the current capture belongs to
    global g_hkAnimCapLastPush := 0      ; throttle stamp for the WebView push
}

; Bridge: arm the capture (clears any previous run). Called when the user opens
; the live panel on an enemyAnim condition.
StartHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkAnimCapArea, g_hkAnimCapLastPush
    g_hkAnimCapSeen := Map()
    g_hkAnimCapArea := 0
    g_hkAnimCapLastPush := 0
    g_hkAnimCapOn := true
}

; Bridge: disarm + clear. Called when the user closes the live panel / navigates away.
StopHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen
    g_hkAnimCapOn := false
    g_hkAnimCapSeen := Map()
}

; Per-tick accumulator (from UpdateRadarFast). No-op unless armed. Records every
; hostile monster's current animationId into the recency map, resets on area
; change, and pushes the recent set to the WebView ~4 Hz. Cheap: one sample scan
; of cached fields, no RPM.
TryHkAnimCapture(radarSnap)
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkAnimCapArea, g_hkAnimCapLastPush
    if !g_hkAnimCapOn
        return
    if !(IsObject(radarSnap) && radarSnap is Map)
        return

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    hash := (area && IsObject(area) && area.Has("currentAreaHash")) ? area["currentAreaHash"] : 0
    if (hash != g_hkAnimCapArea)
    {
        g_hkAnimCapSeen := Map()     ; new area → forget the old area's animations
        g_hkAnimCapArea := hash
    }

    now := A_TickCount
    for entry in _HotkeysAwakeSample(radarSnap)
    {
        entity := (entry && entry is Map && entry.Has("entity")) ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        if !InStr(entity.Has("path") ? StrLower(entity["path"]) : "", "metadata/monsters/")
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && dc is Map) || !_HotkeysIsTargetable(dc)
            continue
        pos := dc.Has("positioned") ? dc["positioned"] : 0
        if (pos && pos is Map && pos.Has("isFriendly") && pos["isFriendly"])
            continue
        actor := dc.Has("actor") ? dc["actor"] : 0
        if !(actor && actor is Map && actor.Has("animationId"))
            continue
        animId := actor["animationId"]
        dist := entry.Has("distance") ? entry["distance"] : -1

        rec := g_hkAnimCapSeen.Has(animId) ? g_hkAnimCapSeen[animId] : Map("count", 0, "last", 0, "dist", 999999)
        rec["count"] += 1
        rec["last"] := now
        if (dist >= 0 && dist < rec["dist"])
            rec["dist"] := dist
        g_hkAnimCapSeen[animId] := rec
    }

    if (now - g_hkAnimCapLastPush >= 250)
    {
        g_hkAnimCapLastPush := now
        _HkAnimCapturePush(now)
    }
}

; Builds the recent-animation list (prunes entries older than 8 s), sorts it
; most-recent-first, and pushes updateAnimCapture([...]) to the WebView.
_HkAnimCapturePush(now)
{
    global g_hkAnimCapSeen
    survivors := []
    stale := []
    for id, rec in g_hkAnimCapSeen
    {
        age := now - rec["last"]
        if (age > 8000)
            stale.Push(id)
        else
            survivors.Push(Map("id", id, "count", rec["count"], "dist", rec["dist"], "age", age))
    }
    for _, id in stale
        g_hkAnimCapSeen.Delete(id)

    ; Most-recent first (age ascending); insertion sort (list is tiny).
    i := 2
    while (i <= survivors.Length)
    {
        cur := survivors[i], j := i - 1
        while (j >= 1 && survivors[j]["age"] > cur["age"])
        {
            survivors[j + 1] := survivors[j]
            j -= 1
        }
        survivors[j + 1] := cur
        i += 1
    }

    json := "["
    first := true
    for _, r in survivors
    {
        json .= (first ? "" : ",")
             . '{"id":' r["id"] ',"count":' r["count"]
             . ',"dist":' Round(r["dist"]) ',"age":' r["age"] "}"
        first := false
    }
    json .= "]"
    try WebViewExec("updateAnimCapture(" json ")")
}
