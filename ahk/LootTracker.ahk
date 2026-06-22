; LootTracker.ahk
; Map-run / session loot tracker (ported from the GameHelper2 LootTracker plugin's
; LootTrackerCore.cs). Times each map run, diffs the backpack against a per-run
; baseline to compute net loot, prices it via poe.ninja (Exalted / Divine), tallies
; kills per rarity, and keeps a browsable on-disk session history.
;
; Architecture mirrors the existing per-tick modules: TryLootTrackerTick(radarSnap)
; runs from UpdateRadarFast right after TryEntityAlerts, OUTSIDE the "claim the tick"
; chain, so it never blocks automation. The run state machine is a cheap per-tick
; area-hash edge detector; the inventory diff + kill scan + live-view rebuild are each
; throttled. The two on-screen bars (LootTrackerOverlay.ahk) and the WebView Loot tab
; render from g_ltLiveView, rebuilt at ~4 Hz here.
;
; Globals are seeded in LoadLootTracker() (NOT via top-level initializers — see the
; AHK v2 module-init gotcha in CLAUDE.md). Self-persists [LootTracker] in
; poeformance_config.ini. Included by InGameStateMonitor.ahk.

; ── Configuration (super-globals; mutated via _LtApplySetting / config load) ──
global g_ltEnabled         := false   ; master on/off for the whole feature
global g_ltShowKills       := true    ; show per-rarity kill counts on the map strip
global g_ltHistorySize     := 50      ; completed-map rows kept in the live session
global g_ltMaxSessions     := 30      ; finished sessions kept on disk
global g_ltLeague          := "Standard"   ; poe.ninja PoE2 league slug (set per league)
global g_ltCacheTtlMin     := 60      ; minutes a cached price set stays valid (5-60)
global g_ltCompactHeight   := 115     ; px height of the hideout compact bar
global g_ltBarOpacity      := 0.55    ; 0..1 background opacity of both bars
global g_ltBarOnRight      := true    ; map strip side (true = right)
global g_ltBarBottomOffset := 40      ; px the bars sit up from the game-window bottom
global g_ltUiScale         := 1.0     ; manual multiplier on the bars' auto UI scale
global g_ltConfigFile      := ""

; ── Run / session state (seeded in LoadLootTracker) ──
global g_ltCurrent          := 0      ; current MapRun Map, or 0
global g_ltCompleted        := []     ; Array of MapRun Maps (includes current)
global g_ltRunStartTick     := 0      ; A_TickCount the timer started; 0 = paused
global g_ltBaseline         := 0      ; inventory snapshot taken on map entry
global g_ltBaselinePending  := false  ; capture the baseline on the first readable frame
global g_ltLastZoneHash     := 0      ; last area hash reacted to (edge detector)
global g_ltSessionStartTick := 0
global g_ltSessionStartStamp := ""    ; A_Now at session start (history record / filename)
global g_ltOnMap            := false
global g_ltLiveLegDelta     := Map()  ; throttled in-progress leg delta (snapshot - baseline)
global g_ltNextLiveSnapTick := 0
global g_ltNextViewTick     := 0
global g_ltLastLivePushTick := 0
global g_ltNextPriceCheckTick := 0
global g_ltLiveView         := Map()  ; cached display model for overlays + WebView
global g_ltLastReason       := "init" ; per-tick diagnostic (why nothing is tracked)
; Freshly-read world-area (town/hideout/name) — read directly here rather than trusting
; the radar snapshot's once-per-zone cache, which can latch the PREVIOUS area's flags if
; its single read lands before the game's area pointer settles (mirrors AutoFlask).
global g_ltWad     := 0
global g_ltWadTick := 0
global g_ltWadHash := 0
global g_ltDiagBp  := -1  ; last inventory snapshot backpack item-key count (-1 = read failed, 0 = empty)
global g_ltDiag2   := ""  ; loot-diff diagnostic string (bp / gained / priced / unpriced)
global g_ltDiagInv := ""  ; per-inventory summary (id(grid)=itemCount …) from the last read
global g_ltDiagCalls := 0 ; how many times _LtSnapshotInventory ran (must climb if the live read is alive)
global g_ltLastErr := ""  ; last swallowed per-tick exception (Type: message [Lnn]) for the UI
global g_ltDiagKills := "" ; kill-scan diagnostic (mons / any / tal / alive / dead)

; ── Init ─────────────────────────────────────────────────────────────────────
LoadLootTracker()
{
    global g_ltEnabled, g_ltShowKills, g_ltHistorySize, g_ltMaxSessions, g_ltLeague
    global g_ltCacheTtlMin, g_ltCompactHeight, g_ltBarOpacity, g_ltBarOnRight
    global g_ltBarBottomOffset, g_ltUiScale, g_ltConfigFile
    global g_ltCurrent, g_ltCompleted, g_ltRunStartTick, g_ltBaseline, g_ltBaselinePending
    global g_ltLastZoneHash, g_ltSessionStartTick, g_ltSessionStartStamp, g_ltOnMap
    global g_ltLiveLegDelta, g_ltNextLiveSnapTick, g_ltNextViewTick, g_ltLastLivePushTick
    global g_ltNextPriceCheckTick, g_ltLiveView
    global g_ltKillLastR, g_ltNextKillScanTick
    global g_ltLastReason
    global g_ltWad, g_ltWadTick, g_ltWadHash
    global g_ltDiagBp, g_ltDiag2, g_ltDiagInv, g_ltDiagCalls
    global g_ltLastErr, g_ltDiagKills

    ; Defaults — seeded unconditionally so a fresh install never trips the
    ; "global has not been assigned a value" runtime error.
    g_ltConfigFile      := A_ScriptDir "\poeformance_config.ini"
    g_ltEnabled         := false
    g_ltShowKills       := true
    g_ltHistorySize     := 50
    g_ltMaxSessions     := 30
    g_ltLeague          := "Standard"
    g_ltCacheTtlMin     := 60
    g_ltCompactHeight   := 115
    g_ltBarOpacity      := 0.55
    g_ltBarOnRight      := true
    g_ltBarBottomOffset := 40
    g_ltUiScale         := 1.0

    g_ltCurrent          := 0
    g_ltCompleted        := []
    g_ltRunStartTick     := 0
    g_ltBaseline         := 0
    g_ltBaselinePending  := false
    g_ltLastZoneHash     := 0
    g_ltSessionStartTick := A_TickCount
    g_ltSessionStartStamp := A_Now
    g_ltOnMap            := false
    g_ltLiveLegDelta     := Map()
    g_ltNextLiveSnapTick := 0
    g_ltNextViewTick     := 0
    g_ltLastLivePushTick := 0
    g_ltNextPriceCheckTick := 0
    g_ltLiveView         := Map()
    g_ltKillLastR        := [0, 0, 0, 0]
    g_ltNextKillScanTick := 0
    g_ltLastReason       := "init"
    g_ltWad     := 0
    g_ltWadTick := 0
    g_ltWadHash := 0
    g_ltDiagBp  := -1
    g_ltDiag2   := ""
    g_ltDiagInv := ""
    g_ltDiagCalls := 0
    g_ltLastErr := ""
    g_ltDiagKills := ""

    f := g_ltConfigFile
    if !FileExist(f)
        return
    try
    {
        g_ltEnabled         := IniRead(f, "LootTracker", "enabled",      g_ltEnabled ? 1 : 0) + 0 ? true : false
        g_ltShowKills       := IniRead(f, "LootTracker", "showKills",    g_ltShowKills ? 1 : 0) + 0 ? true : false
        g_ltBarOnRight      := IniRead(f, "LootTracker", "barOnRight",   g_ltBarOnRight ? 1 : 0) + 0 ? true : false
        g_ltHistorySize     := _LtClampInt(IniRead(f, "LootTracker", "historySize",     g_ltHistorySize), 5, 500)
        g_ltMaxSessions     := _LtClampInt(IniRead(f, "LootTracker", "maxSessions",     g_ltMaxSessions), 1, 500)
        g_ltCacheTtlMin     := _LtClampInt(IniRead(f, "LootTracker", "cacheTtlMin",     g_ltCacheTtlMin), 5, 1440)
        g_ltCompactHeight   := _LtClampInt(IniRead(f, "LootTracker", "compactHeight",   g_ltCompactHeight), 60, 400)
        g_ltBarBottomOffset := _LtClampInt(IniRead(f, "LootTracker", "barBottomOffset", g_ltBarBottomOffset), 0, 600)
        g_ltBarOpacity      := _LtClampFloat(IniRead(f, "LootTracker", "barOpacity",    g_ltBarOpacity), 0.05, 1.0)
        g_ltUiScale         := _LtClampFloat(IniRead(f, "LootTracker", "uiScale",       g_ltUiScale), 0.5, 3.0)
        lg := IniRead(f, "LootTracker", "league", g_ltLeague)
        if (lg != "")
            g_ltLeague := lg
    }
}

; Persists the loot-tracker config to poeformance_config.ini ([LootTracker]).
SaveLootTrackerConfig()
{
    global g_ltConfigFile, g_ltEnabled, g_ltShowKills, g_ltHistorySize, g_ltMaxSessions
    global g_ltLeague, g_ltCacheTtlMin, g_ltCompactHeight, g_ltBarOpacity, g_ltBarOnRight
    global g_ltBarBottomOffset, g_ltUiScale
    f := g_ltConfigFile
    try
    {
        IniWrite(g_ltEnabled ? 1 : 0,    f, "LootTracker", "enabled")
        IniWrite(g_ltShowKills ? 1 : 0,  f, "LootTracker", "showKills")
        IniWrite(g_ltBarOnRight ? 1 : 0, f, "LootTracker", "barOnRight")
        IniWrite(g_ltHistorySize,        f, "LootTracker", "historySize")
        IniWrite(g_ltMaxSessions,        f, "LootTracker", "maxSessions")
        IniWrite(g_ltCacheTtlMin,        f, "LootTracker", "cacheTtlMin")
        IniWrite(g_ltCompactHeight,      f, "LootTracker", "compactHeight")
        IniWrite(g_ltBarBottomOffset,    f, "LootTracker", "barBottomOffset")
        IniWrite(g_ltBarOpacity,         f, "LootTracker", "barOpacity")
        IniWrite(g_ltUiScale,            f, "LootTracker", "uiScale")
        IniWrite(g_ltLeague,             f, "LootTracker", "league")
    }
}

; ── Tick entry point ──────────────────────────────────────────────────────────
; Reentrancy-guarded wrapper called from UpdateRadarFast after TryEntityAlerts. Never throws.
TryLootTrackerTick(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _LtRunTick(radarSnap)
    catch as ex
    {
        global g_ltLastErr
        g_ltLastErr := Type(ex) ": " ex.Message " [L" (ex.HasProp("Line") ? ex.Line : "?") "]"
        try LogError("TryLootTrackerTick", ex)
    }
    finally
        _running := false
}

_LtRunTick(radarSnap)
{
    global g_ltEnabled, g_ltLastZoneHash, g_ltBaseline, g_ltBaselinePending, g_ltLastReason

    if !g_ltEnabled
    {
        g_ltLastReason := "disabled"
        return
    }
    if !(radarSnap && Type(radarSnap) = "Map")
    {
        g_ltLastReason := "no-snapshot"
        return
    }

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    areaHash := (area && IsObject(area) && area.Has("currentAreaHash")) ? area["currentAreaHash"] : 0
    inGsAddr := (inGs && IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0

    ; Prefer a FRESH world-area read (self-correcting each tick) over the radar
    ; snapshot's once-per-zone cache, which can latch the previous area's flags; fall
    ; back to the snapshot cache only if the fresh read isn't available.
    wad := _LtResolveWorldArea(areaHash, inGsAddr)
    if !(wad && IsObject(wad))
        wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
    hasWad := (wad && IsObject(wad)) ? true : false
    name := (hasWad && wad.Has("name")) ? wad["name"] : ""
    areaId := (hasWad && wad.Has("id")) ? wad["id"] : ""
    isTown    := (hasWad && wad.Has("isTown") && wad["isTown"]) ? true : false
    isHideout := (hasWad && wad.Has("isHideout") && wad["isHideout"]) ? true : false
    areaLevel := radarSnap.Has("areaLevel") ? radarSnap["areaLevel"] : 0
    diag := "name='" name "' id='" areaId "' T=" (isTown ? 1 : 0) " H=" (isHideout ? 1 : 0)

    ; The run state machine needs a real area (nonzero instance hash) AND the world-area
    ; flags (to tell a map from town/hideout). The map NAME is best-effort — worldAreaDat
    ; may briefly be unread on a freshly-loaded zone, so we no longer gate on it (that
    ; silently disabled all tracking when the name came back empty).
    if (areaHash != 0 && hasWad)
    {
        if (areaHash != g_ltLastZoneHash)
        {
            g_ltLastZoneHash := areaHash
            _LtHandleZoneTransition(radarSnap, areaHash, name, isTown, isHideout, areaLevel)
        }

        ; Capture the map-entry baseline on the first frame the inventory reads cleanly.
        if (g_ltBaselinePending)
        {
            snap := 0
            if _LtSnapshotInventory(radarSnap, &snap)
            {
                g_ltBaseline := snap
                g_ltBaselinePending := false
            }
        }

        _LtScanKills(radarSnap)
        g_ltLastReason := ((isTown || isHideout) ? "town/hideout (paused)" : "on-map") " · " diag
    }
    else if (areaHash != 0)
        g_ltLastReason := "waiting for world-area data · " diag
    else
        g_ltLastReason := "loading (hash=0)"

    ; Always refresh + push while enabled, so the session clock advances and the
    ; diagnostics flow even between maps / when no run is active.
    _LtRefreshLiveView(radarSnap)
    _LtMaybePushLive()
    _LtMaybeAutoRefreshPrices()
}

; Frame-edge area transition handler (ported from HandleZoneTransition). Pauses/banks
; the timer, opens or resumes a run by instance hash, folds the leaving leg's loot.
_LtHandleZoneTransition(radarSnap, areaHash, name, isTown, isHideout, areaLevel)
{
    global g_ltOnMap, g_ltCurrent, g_ltRunStartTick, g_ltBaseline, g_ltBaselinePending, g_ltCompleted
    global g_ltLiveLegDelta, g_ltNextLiveSnapTick

    isMap := !isTown && !isHideout
    g_ltOnMap := isMap
    now := A_TickCount

    ; The reader's kill counter resets on every area change, so re-baseline our delta
    ; tracker here too (covers maps, town and hideout) to keep run totals exact.
    _LtResetKillTally()

    if isMap
    {
        _LtBankActiveTime(now)

        if (g_ltCurrent && IsObject(g_ltCurrent) && g_ltCurrent["hash"] = areaHash)
        {
            ; Straight re-entry of the same instance — keep it active.
        }
        else if (existing := _LtFindRun(areaHash))
        {
            ; Returning to a map already in history — resume it by its instance hash.
            g_ltCurrent := existing
        }
        else
        {
            ; A genuinely new map instance — open a run and show it in the table at once.
            ; Fall back to a synthetic name if worldAreaDat hasn't been read yet.
            nm := (name != "") ? name : ("Area " areaLevel)
            g_ltCurrent := Map(
                "name", nm,
                "hash", areaHash,
                "areaLevel", areaLevel,
                "activeMs", 0,
                "gained", Map(),
                "kills", [0, 0, 0, 0])
            g_ltCompleted.Push(g_ltCurrent)
            _LtTrimCompleted()
        }

        g_ltRunStartTick := now
        ; (Re-)baseline once the inventory is readable, so stash items don't count as loss.
        g_ltBaseline := 0
        g_ltBaselinePending := true
        g_ltLiveLegDelta := Map()       ; drop the previous leg's live delta
        g_ltNextLiveSnapTick := 0       ; recompute the live leg promptly
    }
    else if (g_ltCurrent && IsObject(g_ltCurrent))
    {
        ; Left the map into hideout/town: pause + bank time, fold this leg's loot delta.
        _LtBankActiveTime(now)
        if (g_ltBaseline && Type(g_ltBaseline) = "Map")
        {
            snap := 0
            if _LtSnapshotInventory(radarSnap, &snap)
                _LtMergeInto(g_ltCurrent["gained"], _LtDiff(snap, g_ltBaseline))
        }
        g_ltBaselinePending := false
    }
}

; Banks the running segment into the run total and pauses the timer (idempotent).
_LtBankActiveTime(now)
{
    global g_ltCurrent, g_ltRunStartTick
    if (g_ltCurrent && IsObject(g_ltCurrent) && g_ltRunStartTick > 0)
    {
        g_ltCurrent["activeMs"] += now - g_ltRunStartTick
        g_ltRunStartTick := 0
    }
}

; Finds a tracked run by instance hash (newest first), or 0.
_LtFindRun(hash)
{
    global g_ltCompleted
    i := g_ltCompleted.Length
    while (i >= 1)
    {
        if (g_ltCompleted[i]["hash"] = hash)
            return g_ltCompleted[i]
        i -= 1
    }
    return 0
}

; Drops the oldest runs past the history limit, but never the active run.
_LtTrimCompleted()
{
    global g_ltCompleted, g_ltHistorySize, g_ltCurrent
    curHash := (g_ltCurrent && IsObject(g_ltCurrent)) ? g_ltCurrent["hash"] : ""
    while (g_ltCompleted.Length > g_ltHistorySize)
    {
        if (g_ltCompleted[1]["hash"] = curHash)
            break
        g_ltCompleted.RemoveAt(1)
    }
}

; Active time of the current run including the live (unbanked) segment, in ms.
_LtCurrentLiveTimeMs()
{
    global g_ltCurrent, g_ltRunStartTick
    if !(g_ltCurrent && IsObject(g_ltCurrent))
        return 0
    t := g_ltCurrent["activeMs"]
    if (g_ltRunStartTick > 0)
        t += A_TickCount - g_ltRunStartTick
    return t
}

; The run's net gains shown live: folded legs (current.gained) plus the in-progress
; leg (snapshot - baseline), recomputed at most ~2 Hz.
_LtCurrentGainedLive(radarSnap)
{
    global g_ltCurrent, g_ltRunStartTick, g_ltBaseline, g_ltNextLiveSnapTick, g_ltLiveLegDelta
    if !(g_ltCurrent && IsObject(g_ltCurrent))
        return Map()
    if (g_ltRunStartTick > 0 && g_ltBaseline && Type(g_ltBaseline) = "Map")
    {
        now := A_TickCount
        if (now >= g_ltNextLiveSnapTick)
        {
            g_ltNextLiveSnapTick := now + 500
            snap := 0
            if _LtSnapshotInventory(radarSnap, &snap)
                g_ltLiveLegDelta := _LtDiff(snap, g_ltBaseline)
        }
        combined := g_ltCurrent["gained"].Clone()
        _LtMergeInto(combined, g_ltLiveLegDelta)
        return combined
    }
    return g_ltCurrent["gained"]
}

; Aggregates the completed runs (banked time + folded loot; the live leg is excluded
; so the session rate stays stable).
_LtSessionTotals(&totalActiveMs, &totalEx)
{
    global g_ltCompleted
    totalActiveMs := 0
    totalEx := 0.0
    for _, r in g_ltCompleted
    {
        totalActiveMs += r["activeMs"]
        p := 0, u := 0
        totalEx += _LtValueOf(r["gained"], &p, &u)
    }
}

; Rebuilds the cached display model (throttled ~4 Hz). Read by the overlays + WebView.
_LtRefreshLiveView(radarSnap)
{
    global g_ltLiveView, g_ltNextViewTick, g_ltCurrent, g_ltOnMap, g_ltCompleted, g_ltDivToEx
    global g_ltPriceStatus, g_ltPriceError, g_ltLastSyncEpoch, g_ltPricesByArt, g_ltSessionStartTick
    global g_ltDiagBp, g_ltDiag2, g_ltDiagCalls, g_ltRunStartTick, g_ltBaseline, g_ltLastErr, g_ltDiagKills

    now := A_TickCount
    if (now < g_ltNextViewTick)
        return
    g_ltNextViewTick := now + 250

    view := Map()
    hasRun := (g_ltCurrent && IsObject(g_ltCurrent)) ? true : false
    view["hasRun"]  := hasRun
    view["onMap"]   := g_ltOnMap
    view["divRate"] := g_ltDivToEx

    if hasRun
    {
        view["name"]   := g_ltCurrent["name"]
        view["timeMs"] := _LtCurrentLiveTimeMs()
        view["kills"]  := g_ltCurrent["kills"].Clone()
        ; Isolate the inventory diff + valuation: a throw here (which was silently
        ; killing the whole tick) now leaves the timer / session / kills working and
        ; records the exact failure instead of freezing everything.
        gained := Map(), p := 0, u := 0
        try
        {
            gained := _LtCurrentGainedLive(radarSnap)
            view["profitEx"] := _LtValueOf(gained, &p, &u)
        }
        catch as gex
        {
            view["profitEx"] := 0.0
            g_ltLastErr := "loot: " Type(gex) ": " gex.Message " [L" (gex.HasProp("Line") ? gex.Line : "?") "]"
        }
        g_ltDiag2 := "calls=" g_ltDiagCalls " bp=" g_ltDiagBp " gained=" gained.Count
            . " rs=" (g_ltRunStartTick > 0 ? 1 : 0)
            . " bl=" ((g_ltBaseline && Type(g_ltBaseline) = "Map") ? g_ltBaseline.Count : -1)
            . " p=" p " u=" u " | " g_ltDiagKills
    }
    else
    {
        view["name"]     := ""
        view["profitEx"] := 0.0
        view["timeMs"]   := 0
        view["kills"]    := [0, 0, 0, 0]
        g_ltDiag2 := "calls=" g_ltDiagCalls " bp=" g_ltDiagBp " (no active run)"
    }

    totA := 0, totEx := 0.0
    _LtSessionTotals(&totA, &totEx)
    maps := g_ltCompleted.Length
    hours := totA / 3600000.0
    view["maps"]          := maps
    view["sessActiveMs"]  := totA
    view["sessEx"]        := totEx
    view["sessPerHourEx"] := (hours > 0) ? (totEx / hours) : 0.0
    view["avgTimeMs"]     := (maps > 0) ? (totA // maps) : 0
    view["avgEx"]         := (maps > 0) ? (totEx / maps) : 0.0
    view["sessTimeMs"]    := now - g_ltSessionStartTick

    runs := []
    i := g_ltCompleted.Length
    while (i >= 1)
    {
        r := g_ltCompleted[i]
        p := 0, u := 0
        runs.Push(Map("name", r["name"], "timeMs", r["activeMs"], "ex", _LtValueOf(r["gained"], &p, &u)))
        i -= 1
    }
    view["runs"] := runs

    view["priceStatus"]   := g_ltPriceStatus
    view["priceErr"]      := g_ltPriceError
    view["lastSyncEpoch"] := g_ltLastSyncEpoch
    view["itemsCached"]   := g_ltPricesByArt.Count

    g_ltLiveView := view
}

; ── Session reset (New session) ───────────────────────────────────────────────
; Archives the session being ended to disk, then wipes state and restarts the clock.
_LtResetSession()
{
    global g_ltCompleted, g_ltCurrent, g_ltRunStartTick, g_ltBaseline, g_ltBaselinePending
    global g_ltLastZoneHash, g_ltSessionStartTick, g_ltSessionStartStamp, g_ltLiveLegDelta
    global g_ltNextViewTick

    _LtSaveCurrentSession()
    g_ltCompleted        := []
    g_ltCurrent          := 0
    g_ltRunStartTick     := 0
    g_ltBaseline         := 0
    g_ltBaselinePending  := false
    g_ltLastZoneHash     := 0
    g_ltLiveLegDelta     := Map()
    g_ltSessionStartTick := A_TickCount
    g_ltSessionStartStamp := A_Now
    _LtResetKillTally()
    g_ltNextViewTick := 0
}

; Re-fetch prices once the cache ages past the TTL (checked at most once a minute).
_LtMaybeAutoRefreshPrices()
{
    global g_ltNextPriceCheckTick, g_ltPriceStatus, g_ltLastSyncEpoch, g_ltCacheTtlMin
    now := A_TickCount
    if (now < g_ltNextPriceCheckTick)
        return
    g_ltNextPriceCheckTick := now + 60000
    if (g_ltPriceStatus = "syncing")
        return
    ttlMin := (g_ltCacheTtlMin > 0) ? g_ltCacheTtlMin : 60
    ageSec := _LtNowEpoch() - g_ltLastSyncEpoch
    if (g_ltLastSyncEpoch = 0 || ageSec > (ttlMin * 60))
        StartLootPriceRefresh()
}

; ── WebView live push ─────────────────────────────────────────────────────────
_LtMaybePushLive()
{
    global g_ltLastLivePushTick
    now := A_TickCount
    if (now - g_ltLastLivePushTick < 1000)
        return
    g_ltLastLivePushTick := now
    PushLootLiveToWebView()
}

; Serializes g_ltLiveView and pushes it to the Loot tab (updateLootLive in the UI).
PushLootLiveToWebView()
{
    global g_ltLiveView
    try WebViewExec("updateLootLive(" _LtLiveViewJson() ")")
}

_LtLiveViewJson()
{
    global g_ltLiveView, g_ltLastSyncEpoch, g_ltLastReason, g_ltEnabled, g_ltDiag2, g_ltDiagInv, g_ltLastErr
    v := g_ltLiveView
    if !(v && Type(v) = "Map")
        return "{}"

    killsArr := v.Has("kills") ? v["kills"] : [0, 0, 0, 0]
    kj := "[" (killsArr.Has(1) ? killsArr[1] : 0) "," (killsArr.Has(2) ? killsArr[2] : 0)
        . "," (killsArr.Has(3) ? killsArr[3] : 0) "," (killsArr.Has(4) ? killsArr[4] : 0) "]"

    runsJson := "["
    if (v.Has("runs") && Type(v["runs"]) = "Array")
    {
        first := true
        for _, r in v["runs"]
        {
            runsJson .= (first ? "" : ",") "{"
                . '"name":' _JsStr(r["name"])
                . ',"timeMs":' (r["timeMs"] + 0)
                . ',"ex":' _LtNum(r["ex"])
                . "}"
            first := false
        }
    }
    runsJson .= "]"

    ageSec := (g_ltLastSyncEpoch > 0) ? (_LtNowEpoch() - g_ltLastSyncEpoch) : -1

    j := "{"
    j .= '"hasRun":'        (v.Has("hasRun") && v["hasRun"] ? "true" : "false")
    j .= ',"onMap":'        (v.Has("onMap") && v["onMap"] ? "true" : "false")
    j .= ',"name":'         _JsStr(v.Has("name") ? v["name"] : "")
    j .= ',"timeMs":'       ((v.Has("timeMs") ? v["timeMs"] : 0) + 0)
    j .= ',"profitEx":'     _LtNum(v.Has("profitEx") ? v["profitEx"] : 0)
    j .= ',"kills":'        kj
    j .= ',"maps":'         ((v.Has("maps") ? v["maps"] : 0) + 0)
    j .= ',"sessActiveMs":' ((v.Has("sessActiveMs") ? v["sessActiveMs"] : 0) + 0)
    j .= ',"sessEx":'       _LtNum(v.Has("sessEx") ? v["sessEx"] : 0)
    j .= ',"sessPerHourEx":' _LtNum(v.Has("sessPerHourEx") ? v["sessPerHourEx"] : 0)
    j .= ',"avgTimeMs":'    ((v.Has("avgTimeMs") ? v["avgTimeMs"] : 0) + 0)
    j .= ',"avgEx":'        _LtNum(v.Has("avgEx") ? v["avgEx"] : 0)
    j .= ',"sessTimeMs":'   ((v.Has("sessTimeMs") ? v["sessTimeMs"] : 0) + 0)
    j .= ',"divRate":'      _LtNum(v.Has("divRate") ? v["divRate"] : 0)
    j .= ',"runs":'         runsJson
    j .= ',"priceStatus":'  _JsStr(v.Has("priceStatus") ? v["priceStatus"] : "idle")
    j .= ',"priceErr":'     _JsStr(v.Has("priceErr") ? v["priceErr"] : "")
    j .= ',"itemsCached":'  ((v.Has("itemsCached") ? v["itemsCached"] : 0) + 0)
    j .= ',"lastSyncAgo":'  (ageSec + 0)
    j .= ',"reason":'       _JsStr(g_ltLastReason)
    j .= ',"diag2":'        _JsStr(g_ltDiag2)
    j .= ',"diagInv":'      _JsStr(g_ltDiagInv)
    j .= ',"lastErr":'      _JsStr(g_ltLastErr)
    j .= ',"enabled":'      (g_ltEnabled ? "true" : "false")
    j .= "}"
    return j
}

; ── Header settings block (event-driven push, consumed by the Loot tab) ───────
BuildLootHeaderJson()
{
    global g_ltEnabled, g_ltShowKills, g_ltHistorySize, g_ltMaxSessions, g_ltLeague
    global g_ltCacheTtlMin, g_ltCompactHeight, g_ltBarOpacity, g_ltBarOnRight
    global g_ltBarBottomOffset, g_ltUiScale
    j := "{"
    j .= '"enabled":'         (g_ltEnabled ? "true" : "false")
    j .= ',"showKills":'      (g_ltShowKills ? "true" : "false")
    j .= ',"barOnRight":'     (g_ltBarOnRight ? "true" : "false")
    j .= ',"historySize":'    (g_ltHistorySize + 0)
    j .= ',"maxSessions":'    (g_ltMaxSessions + 0)
    j .= ',"cacheTtlMin":'    (g_ltCacheTtlMin + 0)
    j .= ',"compactHeight":'  (g_ltCompactHeight + 0)
    j .= ',"barBottomOffset":' (g_ltBarBottomOffset + 0)
    j .= ',"barOpacity":'     _LtNum(g_ltBarOpacity)
    j .= ',"uiScale":'        _LtNum(g_ltUiScale)
    j .= ',"league":'         _JsStr(g_ltLeague)
    j .= "}"
    return j
}

; ── Bridge apply (one setting key + value from the UI) ────────────────────────
; Returns true when the changed key was "league" (so the caller can re-fetch prices).
_LtApplySetting(key, value)
{
    global g_ltEnabled, g_ltShowKills, g_ltHistorySize, g_ltMaxSessions, g_ltLeague
    global g_ltCacheTtlMin, g_ltCompactHeight, g_ltBarOpacity, g_ltBarOnRight
    global g_ltBarBottomOffset, g_ltUiScale

    b := (value = true || value = 1 || value = "1" || value = "true")
    switch key
    {
        case "enabled":         g_ltEnabled := b
        case "showKills":       g_ltShowKills := b
        case "barOnRight":      g_ltBarOnRight := b
        case "historySize":     g_ltHistorySize := _LtClampInt(value, 5, 500)
        case "maxSessions":     g_ltMaxSessions := _LtClampInt(value, 1, 500)
        case "cacheTtlMin":     g_ltCacheTtlMin := _LtClampInt(value, 5, 1440)
        case "compactHeight":   g_ltCompactHeight := _LtClampInt(value, 60, 400)
        case "barBottomOffset": g_ltBarBottomOffset := _LtClampInt(value, 0, 600)
        case "barOpacity":      g_ltBarOpacity := _LtClampFloat(value, 0.05, 1.0)
        case "uiScale":         g_ltUiScale := _LtClampFloat(value, 0.5, 3.0)
        case "league":
            v := Trim("" value)
            if (v != "")
                g_ltLeague := v
            return true
    }
    return false
}

; ── World-area (town/hideout/name) fresh read ─────────────────────────────────
; Reads the world-area row directly (the same chain the radar cache uses) but on a
; ~250 ms throttle each tick, so a too-early first read right after a zone change
; self-corrects instead of latching the previous area's flags for the whole zone.
; Keeps the last good value if a read momentarily fails. Returns the worldAreaDat Map, or 0.
_LtResolveWorldArea(areaHash, inGsAddr)
{
    global g_ltWad, g_ltWadTick, g_ltWadHash
    now := A_TickCount
    if (areaHash != g_ltWadHash || !(g_ltWad && IsObject(g_ltWad)) || (now - g_ltWadTick) >= 250)
    {
        g_ltWadTick := now
        fresh := _LtReadWorldAreaRaw(inGsAddr)
        if (fresh && IsObject(fresh))
        {
            g_ltWad := fresh
            g_ltWadHash := areaHash
        }
    }
    return g_ltWad
}

; Pointer chain inGameState -> WorldData -> WorldAreaDetails -> row, decoded via the
; reader's ReadWorldAreaDat (id / name / isTown / isHideout). 0 on any bad read.
_LtReadWorldAreaRaw(inGsAddr)
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return 0
    if !inGsAddr
        return 0
    try
    {
        worldData := g_reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["WorldData"])
        if !g_reader.IsProbablyValidPointer(worldData)
            return 0
        wdp := g_reader.Mem.ReadPtr(worldData + PoE2Offsets.WorldData["WorldAreaDetailsPtr"])
        if !g_reader.IsProbablyValidPointer(wdp)
            return 0
        rowPtr := g_reader.Mem.ReadPtr(wdp + PoE2Offsets.WorldData["WorldAreaDetailsRowPtr"])
        return g_reader.ReadWorldAreaDat(rowPtr)
    }
    catch
        return 0
}

; ── Small numeric helpers ─────────────────────────────────────────────────────
; Emits an AHK number as a clean JSON numeric literal (no thousands sep, finite).
_LtNum(x)
{
    n := x + 0
    if !(n = n)            ; NaN guard
        return "0"
    return Round(n, 4) ""
}

_LtClampInt(x, lo, hi)
{
    n := Round(x + 0)
    return (n < lo) ? lo : (n > hi) ? hi : n
}

_LtClampFloat(x, lo, hi)
{
    n := x + 0
    return (n < lo) ? lo : (n > hi) ? hi : n
}
