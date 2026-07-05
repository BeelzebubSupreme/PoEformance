; HkAnimCapture.ahk
; Live "what are nearby enemies playing right now" capture for the Macro Engine's
; enemyAnim condition. The user arms this from the condition editor, stands near a
; monster/boss, watches it attack, and clicks the animation that lit up to add it —
; no need to know ids or names.
;
; TURBO fishing path: while armed, capture takes over the radar tick with a STRIPPED,
; fast loop (StartHkAnimCapture bumps the UpdateRadarFast timer to ~10 ms). It skips
; ALL GDI overlays + every secondary feature (AutoPilot / loot / alerts / stash / …),
; refreshes the monster Actor-address list only ~every 300 ms (the one heavy read),
; and in between reads each target monster's animationId DIRECTLY (one ReadInt) every
; tick. That high sample rate catches very short animations the normal round-robin
; would miss. Disarming restores the normal 50 ms tick.
;
; Reuses the hot-path Actor offset + the CustomHotkeys sample helpers
; (_HotkeysAwakeSample / _HotkeysIsTargetable). Pushes updateAnimCapture([...]) to the
; WebView. Included by InGameStateMonitor.ahk; the fast path is entered from
; UpdateRadarFast when g_hkAnimCapOn is set. No persistence — a transient tool.

; Seeds all globals (init gotcha). No persistence.
LoadHkAnimCapture()
{
    global g_hkAnimCapOn := false        ; armed only while the editor panel is open
    global g_hkAnimCapSeen := Map()      ; animId -> Map(count, last, dist)
    global g_hkAnimCapArea := 0          ; area hash the current capture belongs to

    ; Fishing (turbo) state — none persisted.
    global g_hkFishAddrs := []           ; [{addr, dist}] monster Actor components to poll
    global g_hkFishLastHeavy := 0        ; last full-snapshot refresh tick
    global g_hkFishLastPush := 0         ; last WebView push tick
    global g_hkFishIntervalMs := 10      ; radar-tick period while fishing (fast)
    global g_hkFishHeavyMs := 300        ; how often to rebuild the monster list (heavy read)
    global g_hkFishPushMs := 45          ; UI push cadence (accumulation already caught briefs)
    global g_hkFishNormalMs := 50        ; the normal radar-tick period to restore on stop
}

; Bridge: arm the capture. Clears any previous run and switches the radar tick into
; the fast fishing cadence. Called when the user opens the live panel.
StartHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkAnimCapArea
    global g_hkFishAddrs, g_hkFishLastHeavy, g_hkFishLastPush, g_hkFishIntervalMs
    g_hkAnimCapSeen := Map()
    g_hkAnimCapArea := 0
    g_hkFishAddrs := []
    g_hkFishLastHeavy := 0
    g_hkFishLastPush := 0
    g_hkAnimCapOn := true
    try SetTimer(UpdateRadarFast, g_hkFishIntervalMs)   ; turbo tick
}

; Bridge: disarm + clear, and restore the normal radar-tick cadence.
StopHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkFishAddrs, g_hkFishNormalMs
    g_hkAnimCapOn := false
    g_hkAnimCapSeen := Map()
    g_hkFishAddrs := []
    try SetTimer(UpdateRadarFast, g_hkFishNormalMs)     ; back to the normal tick
}

; The turbo fishing tick — entered from UpdateRadarFast (which returns early, so no
; GDI / secondary features run). Heavy monster-list refresh is throttled; the
; animationId reads run every tick for maximum sample rate.
HkAnimFishTick()
{
    global g_reader, g_radarLastSnap, g_hkAnimCapSeen, g_hkAnimCapArea
    global g_hkFishAddrs, g_hkFishLastHeavy, g_hkFishLastPush, g_hkFishHeavyMs, g_hkFishPushMs
    if !IsObject(g_reader)
        return
    now := A_TickCount

    ; (1) Refresh the monster Actor-address list occasionally (the one heavy read).
    if (g_hkFishAddrs.Length = 0 || (now - g_hkFishLastHeavy) >= g_hkFishHeavyMs)
    {
        g_hkFishLastHeavy := now
        snap := 0
        try snap := g_reader.ReadRadarSnapshot()
        if (snap && snap is Map)
        {
            g_radarLastSnap := snap
            inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
            area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
            hash := (area && IsObject(area) && area.Has("currentAreaHash")) ? area["currentAreaHash"] : 0
            if (hash != g_hkAnimCapArea)     ; new area → forget old animations
            {
                g_hkAnimCapSeen := Map()
                g_hkAnimCapArea := hash
            }
            g_hkFishAddrs := _HkFishCollectMonsters(snap)
        }
    }

    ; (2) Fast: read each monster's animationId DIRECTLY (one ReadInt), accumulate.
    animOff := PoE2Offsets.Actor["AnimationId"]
    for _, m in g_hkFishAddrs
    {
        addr := m["addr"]
        if !g_reader.IsProbablyValidPointer(addr)
            continue
        animId := -1
        try animId := g_reader.Mem.ReadInt(addr + animOff)
        if (animId < 0)
            continue
        rec := g_hkAnimCapSeen.Has(animId) ? g_hkAnimCapSeen[animId] : Map("count", 0, "last", 0, "dist", 999999)
        rec["count"] += 1
        rec["last"] := now
        d := m["dist"]
        if (d >= 0 && d < rec["dist"])
            rec["dist"] := d
        g_hkAnimCapSeen[animId] := rec
    }

    ; (3) Push to the UI at a modest cadence — the accumulation already holds any
    ; brief animation, so the feed doesn't need to update every 10 ms.
    if ((now - g_hkFishLastPush) >= g_hkFishPushMs)
    {
        g_hkFishLastPush := now
        _HkAnimCapturePush(now)
    }
}

; Collects the pollable monster Actor-component addresses from a snapshot: hostile,
; targetable, non-friendly monsters with a resolvable Actor component. Returns
; [{addr, dist}]. Runs only on the throttled heavy refresh.
_HkFishCollectMonsters(snap)
{
    global g_reader
    out := []
    for entry in _HotkeysAwakeSample(snap)
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
        comps := entity.Has("components") ? entity["components"] : 0
        actorAddr := 0
        if (comps && comps is Array)
        {
            for _, c in comps
            {
                if (c && c is Map && c.Has("name") && c.Has("address")
                    && (InStr(c["name"], "Actor") || c["name"] = "Actor"))
                {
                    actorAddr := c["address"]
                    break
                }
            }
        }
        if !(actorAddr && g_reader.IsProbablyValidPointer(actorAddr))
            continue
        out.Push(Map("addr", actorAddr, "dist", entry.Has("distance") ? entry["distance"] : -1))
    }
    return out
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
