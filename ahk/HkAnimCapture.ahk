; HkAnimCapture.ahk
; Live "what are nearby enemies playing right now" capture for the Macro Engine's enemyAnim
; condition. The user arms this from the condition editor, stands near a monster/boss, watches it
; attack, and clicks the animation that lit up to add it — no ids or names needed.
;
; TWO capture backends:
;   "proc"  (preferred) — an out-of-process SAMPLER (poef_fisher.ahk) does the 10 ms animationId
;           reads and accumulates the table; the main app just publishes the monster address list
;           (it already has the radar snapshot, so that is free) and renders the digest the fisher
;           writes back via shared memory. The main tick stays at its NORMAL cadence — overlays keep
;           rendering, nothing is hijacked. This is the first user of the reader-split infrastructure
;           (ahk/SharedMem.ahk + ahk/HkFishProtocol.ahk; see docs/reader-split.md, sampler pattern).
;   "inproc" (fallback) — the legacy TURBO path: if shared memory / the fisher can't start, capture
;           takes over the radar tick with a stripped 10 ms loop (StartHkAnimCapture bumps the timer,
;           HkAnimFishTick runs before any overlay/feature). Never worse than before the split.
;
; Reuses the hot-path Actor offset + the CustomHotkeys sample helpers (_HotkeysAwakeSample /
; _HotkeysIsTargetable). Pushes updateAnimCapture([...]) to the WebView. Included by
; InGameStateMonitor.ahk. No persistence — a transient tool.

; Seeds all globals (init gotcha) and creates the shared block the fisher attaches to. No persistence.
LoadHkAnimCapture()
{
    global g_hkAnimCapOn := false        ; armed only while the editor panel is open
    global g_hkAnimCapSeen := Map()      ; animId -> Map(count, last, dist)  (inproc accumulator)
    global g_hkAnimCapArea := 0          ; area hash the current capture belongs to

    ; Fishing (turbo / inproc fallback) state — none persisted.
    global g_hkFishAddrs := []           ; [{addr, dist}] monster Actor components to poll
    global g_hkFishLastHeavy := 0        ; last full-snapshot refresh tick (inproc)
    global g_hkFishLastPush := 0         ; last WebView push tick (inproc)
    global g_hkFishIntervalMs := 10      ; radar-tick period while fishing inproc (fast)
    global g_hkFishHeavyMs := 300        ; how often to (re)publish the monster list
    global g_hkFishPushMs := 45          ; UI push cadence
    global g_hkFishNormalMs := 50        ; the normal radar-tick period to restore on inproc stop

    ; Out-of-process (proc) backend state.
    global g_hkFishMode := ""            ; "" | "proc" | "inproc"
    global g_hkFishBlk := 0              ; SharedMemBlock (Main owns it)
    global g_hkFishLockA := 0            ; seqlock: Main writes the address list
    global g_hkFishLockB := 0            ; seqlock: Main reads the counts
    global g_hkFishProcPid := 0          ; spawned fisher pid (0 = none)
    global g_hkFishAreaGen := 0          ; area generation (bumped on area change, proc mode)
    global g_hkFishPubTick := 0          ; throttle: address-list publish
    global g_hkFishReadTick := 0         ; throttle: counts read + UI push

    ; Create the shared block once (tiny, always ready). If it fails, proc mode is simply
    ; unavailable and StartHkAnimCapture falls back to the inproc turbo path.
    try
    {
        g_hkFishBlk := SharedMemBlock(HkFishProto.NAME, HkFishProto.SIZE)
        g_hkFishBlk.Clear()
        g_hkFishBlk.PutU32(HkFishProto.O_MAGIC, HkFishProto.MAGIC)
        g_hkFishBlk.PutU32(HkFishProto.O_VERSION, HkFishProto.VERSION)
        g_hkFishLockA := SeqLock(g_hkFishBlk, HkFishProto.O_SEQA)
        g_hkFishLockB := SeqLock(g_hkFishBlk, HkFishProto.O_SEQB)
    }
    catch
        g_hkFishBlk := 0

    ; Make sure a lingering fisher can never outlive us.
    try OnExit(_HkFishOnExit)
}

; Bridge: arm the capture. Clears any previous run; prefers the out-of-process fisher, falls back to
; the in-process turbo path. Called when the user opens the live panel.
StartHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkAnimCapArea
    global g_hkFishAddrs, g_hkFishLastHeavy, g_hkFishLastPush
    global g_hkFishMode, g_hkFishBlk, g_hkFishIntervalMs, g_hkFishPubTick, g_hkFishReadTick
    g_hkAnimCapSeen := Map()
    g_hkAnimCapArea := 0
    g_hkFishAddrs := []
    g_hkFishLastHeavy := 0
    g_hkFishLastPush := 0
    g_hkFishPubTick := 0
    g_hkFishReadTick := 0
    g_hkAnimCapOn := true

    if (IsObject(g_hkFishBlk) && _HkFishSpawnProcess())
    {
        g_hkFishMode := "proc"
        ; Publish config and raise the run flag; the fisher (already spawned) will pick it up.
        try
        {
            g_hkFishBlk.PutU32(HkFishProto.O_ANIMOFF, PoE2Offsets.Actor["AnimationId"])
            g_hkFishBlk.PutU32(HkFishProto.O_MAINHEART, A_TickCount)
            g_hkFishBlk.PutU32(HkFishProto.O_RUN, 1)
        }
        ; NOTE: the radar tick is deliberately NOT sped up — overlays keep rendering normally.
    }
    else
    {
        g_hkFishMode := "inproc"
        try SetTimer(UpdateRadarFast, g_hkFishIntervalMs)   ; legacy turbo tick
    }
}

; Bridge: disarm + clear. Stops whichever backend is running and restores the normal state.
StopHkAnimCapture()
{
    global g_hkAnimCapOn, g_hkAnimCapSeen, g_hkFishAddrs, g_hkFishNormalMs
    global g_hkFishMode, g_hkFishBlk
    g_hkAnimCapOn := false
    g_hkAnimCapSeen := Map()
    g_hkFishAddrs := []

    if (g_hkFishMode = "proc")
    {
        if IsObject(g_hkFishBlk)
            try g_hkFishBlk.PutU32(HkFishProto.O_RUN, 0)   ; fisher self-exits
        _HkFishKillProcess()                               ; fallback kill
    }
    else if (g_hkFishMode = "inproc")
    {
        try SetTimer(UpdateRadarFast, g_hkFishNormalMs)   ; restore the normal tick
    }
    g_hkFishMode := ""
}

; ── Out-of-process (proc) backend ────────────────────────────────────────────────────────────────

; Called EVERY normal radar tick from UpdateRadarFast (no-op unless armed in proc mode). Publishes
; the monster address list (throttled; free because Main already has radarSnap), keeps the Main
; heartbeat fresh, and reads + renders the fisher's accumulated counts. No tick hijack.
TryHkAnimFishPublish(radarSnap)
{
    global g_hkAnimCapOn, g_hkFishMode, g_hkFishBlk
    global g_hkFishPubTick, g_hkFishReadTick, g_hkFishHeavyMs, g_hkFishPushMs
    if !(g_hkAnimCapOn && g_hkFishMode = "proc" && IsObject(g_hkFishBlk))
        return
    now := A_TickCount

    g_hkFishBlk.PutU32(HkFishProto.O_MAINHEART, now)   ; cheap every tick → fisher detects a Main crash

    if ((now - g_hkFishPubTick) >= g_hkFishHeavyMs)
    {
        g_hkFishPubTick := now
        _HkFishPublishAddrs(radarSnap)
    }
    if ((now - g_hkFishReadTick) >= g_hkFishPushMs)
    {
        g_hkFishReadTick := now
        _HkFishReadAndPush(now)
    }
}

; Publishes the current monster Actor-component addresses (+ distances) into Region A under seqlock A,
; bumping the area generation on a zone change so the fisher forgets old animations.
_HkFishPublishAddrs(radarSnap)
{
    global g_hkFishBlk, g_hkFishLockA, g_hkFishAreaGen, g_hkAnimCapArea
    inGs := (radarSnap && radarSnap is Map && radarSnap.Has("inGameState")) ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    hash := (area && IsObject(area) && area.Has("currentAreaHash")) ? area["currentAreaHash"] : 0
    if (hash != g_hkAnimCapArea)
    {
        g_hkAnimCapArea := hash
        g_hkFishAreaGen += 1
    }

    mons := _HkFishCollectMonsters(radarSnap)
    n := Min(mons.Length, HkFishProto.MAX_ADDRS)
    g_hkFishLockA.WriteBegin()
    g_hkFishBlk.PutU32(HkFishProto.O_AREAGEN, g_hkFishAreaGen)
    g_hkFishBlk.PutU32(HkFishProto.O_ADDRCNT, n)
    Loop n
    {
        m := mons[A_Index]
        i := A_Index - 1
        g_hkFishBlk.PutI64(HkFishProto.O_ADDRS + i * 8, m["addr"])
        d := m.Has("dist") ? m["dist"] : -1
        g_hkFishBlk.PutI32(HkFishProto.O_DISTS + i * 4, (d < 0) ? -1 : Round(d))
    }
    g_hkFishLockA.WriteEnd()
}

; Reads the fisher's accumulated counts (seqlock B) and pushes them to the WebView. On a mid-write
; collision Read returns "" → we simply skip this push (staleness, never a torn table).
_HkFishReadAndPush(now)
{
    global g_hkFishBlk, g_hkFishLockB
    rows := g_hkFishLockB.Read(() => _HkFishCopyRows(g_hkFishBlk))
    if (rows = "")
        return
    survivors := []
    for _, r in rows
        survivors.Push(Map("id", r.id, "count", r.count, "dist", r.dist, "age", now - r.last))
    _HkAnimEmit(survivors)
}

; Seqlock copy-out for the counts table: returns [{id,count,last,dist}, ...].
_HkFishCopyRows(blk)
{
    n := blk.GetU32(HkFishProto.O_ROWCNT)
    if (n > HkFishProto.MAX_ROWS)
        n := HkFishProto.MAX_ROWS
    out := []
    Loop n
    {
        base := HkFishProto.O_ROWS + (A_Index - 1) * HkFishProto.ROW_SIZE
        out.Push({ id:    blk.GetU32(base + HkFishProto.R_ANIM)
                 , count: blk.GetU32(base + HkFishProto.R_COUNT)
                 , last:  blk.GetU32(base + HkFishProto.R_LAST)
                 , dist:  blk.GetI32(base + HkFishProto.R_DIST) })
    }
    return out
}

; Spawns poef_fisher.ahk (hidden). Kills any prior fisher first and clears the run/heartbeat flags
; so the fresh process starts from a clean state. Returns true if a pid was obtained.
_HkFishSpawnProcess()
{
    global g_hkFishProcPid, g_hkFishBlk
    _HkFishKillProcess()
    try
    {
        g_hkFishBlk.PutU32(HkFishProto.O_RUN, 0)
        g_hkFishBlk.PutU32(HkFishProto.O_FISHHEART, 0)
    }
    script := A_ScriptDir "\poef_fisher.ahk"
    if !FileExist(script)
        return false
    pid := 0
    try Run(Format('"{1}" "{2}"', A_AhkPath, script), A_ScriptDir, "Hide", &pid)
    catch
        return false
    if !pid
        return false
    g_hkFishProcPid := pid
    return true
}

; Kills the spawned fisher if still running.
_HkFishKillProcess()
{
    global g_hkFishProcPid
    if (g_hkFishProcPid && ProcessExist(g_hkFishProcPid))
        try ProcessClose(g_hkFishProcPid)
    g_hkFishProcPid := 0
}

; OnExit: never let a fisher outlive the main app.
_HkFishOnExit(*)
{
    global g_hkFishBlk
    if IsObject(g_hkFishBlk)
        try g_hkFishBlk.PutU32(HkFishProto.O_RUN, 0)
    _HkFishKillProcess()
}

; ── In-process (inproc) fallback: the legacy turbo path ──────────────────────────────────────────

; The turbo fishing tick — entered from UpdateRadarFast (which returns early, so no GDI / secondary
; features run) ONLY when g_hkFishMode = "inproc". Heavy monster-list refresh is throttled; the
; animationId reads run every tick for maximum sample rate.
HkAnimFishTick()
{
    global g_reader, g_radarLastSnap, g_hkAnimCapSeen, g_hkAnimCapArea
    global g_hkFishAddrs, g_hkFishLastHeavy, g_hkFishLastPush, g_hkFishHeavyMs, g_hkFishPushMs
    if !IsObject(g_reader)
        return
    now := A_TickCount

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
            if (hash != g_hkAnimCapArea)
            {
                g_hkAnimCapSeen := Map()
                g_hkAnimCapArea := hash
            }
            g_hkFishAddrs := _HkFishCollectMonsters(snap)
        }
    }

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

    if ((now - g_hkFishLastPush) >= g_hkFishPushMs)
    {
        g_hkFishLastPush := now
        _HkAnimCapturePush(now)
    }
}

; Collects the pollable monster Actor-component addresses from a snapshot: hostile, targetable,
; non-friendly monsters with a resolvable Actor component. Returns [{addr, dist}]. Shared by both
; backends (proc publishes this; inproc polls it directly).
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

; Builds the inproc recent-animation list (prunes entries older than 8 s) and emits it.
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
    _HkAnimEmit(survivors)
}

; Shared: sort a survivors list most-recent-first (age ascending) and push updateAnimCapture([...]).
_HkAnimEmit(survivors)
{
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
