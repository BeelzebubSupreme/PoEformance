; LootTradePricing.ahk
; Official PoE2 trade-API (trade2) price layer for UNIQUE items — fills the gap poe.ninja
; leaves on Standard (no unique prices there). Docks into the value-aware loot radar: when
; poe.ninja cannot price a dropped unique, its English name (resolved from the item's
; ItemVisualIdentity via the reader) is queued and priced through the trade API, cached for
; a long TTL, and read back like any other price.
;
; SECURITY-FIRST (the user explicitly wants security over functionality):
;   * OFF by default. Nothing hits GGG until the user enables it AND saves a session.
;   * All secrets (POESESSID, cf_clearance, User-Agent) live in ONE gitignored file
;     (config\poe_trade_auth.txt). This module only ever passes the file PATH to the child
;     and never logs / echoes / pushes the secret values (the header exposes only hasAuth).
;   * The network + auth happen in a PowerShell child (tools\poe2_trade_prices.ps1) so the
;     radar hot path is never blocked, with a hard min interval between calls, 429/Retry-After
;     handling, and a "blocked" status + cooldown on Cloudflare/auth failures (no hammering).
;   * On-demand + heavily cached: only uniques poe.ninja missed are queued; positive AND
;     negative results are cached so worthless uniques are not re-queried.
;
; Globals are seeded in LoadLootTradePricing() (NOT via top-level initializers — see the
; AHK v2 module-init gotcha in CLAUDE.md). Included by InGameStateMonitor.ahk.

; ── Init ───────────────────────────────────────────────────────────────────────
; Seeds all globals (defaults first, unconditionally), loads the on-disk cache, and detects
; whether a saved session exists. Called once at startup before the main script's return.
; NOTE: this module is #Include'd at the BOTTOM of the main script, so top-level global
; initializers would NOT run (AHK v2 init gotcha) — every global is seeded HERE instead.
LoadLootTradePricing()
{
    ; Tunables
    global g_ltTradeMaxQueue := 40       ; cap pending names (avoid runaway enqueue)
    global g_ltTradeCooldownMs := 300000 ; pause draining for 5 min after a blocked/error run

    global g_ltTradeEnabled := false
    global g_ltTradeLeague := "Standard"
    global g_ltTradeTtlHours := 24       ; positive-result cache lifetime
    global g_ltTradeNegTtlHours := 12    ; negative-result (no listings) cache lifetime
    global g_ltTradeConfigFile := _ConfigPath()
    global g_ltTradeAuthFile  := A_ScriptDir "\config\poe_trade_auth.txt"
    global g_ltTradeCacheFile := A_ScriptDir "\data\trade_prices.tsv"
    global g_ltTradeNamesFile := A_ScriptDir "\config\trade_names.txt"
    global g_ltTradeOutFile   := A_ScriptDir "\config\trade_out.tsv"
    global g_ltTradeScript    := A_ScriptDir "\tools\poe2_trade_prices.ps1"
    ; Runtime (never persisted to INI)
    global g_ltTradePrices := Map()   ; normName -> Map("ex","epoch","count")
    global g_ltTradeQueue  := Map()   ; normName -> displayName (pending)
    global g_ltTradeStatus := "idle"  ; "idle"|"syncing"|"ready"|"blocked"|"error"
    global g_ltTradeError  := ""
    global g_ltTradeHasAuth := false
    global g_ltTradeRefreshPid := 0
    global g_ltTradeStartTick := 0
    global g_ltTradeCooldownUntil := 0

    global g_ltLeague
    f := g_ltTradeConfigFile
    try {
        g_ltTradeEnabled    := (IniRead(f, "LootTradePricing", "enabled", g_ltTradeEnabled ? "1" : "0") = "1")
        defLeague           := (IsSet(g_ltLeague) && g_ltLeague != "") ? g_ltLeague : g_ltTradeLeague
        g_ltTradeLeague     := IniRead(f, "LootTradePricing", "league", defLeague)
        g_ltTradeTtlHours   := Integer(IniRead(f, "LootTradePricing", "ttlHours", g_ltTradeTtlHours))
        g_ltTradeNegTtlHours := Integer(IniRead(f, "LootTradePricing", "negTtlHours", g_ltTradeNegTtlHours))
    } catch as ex {
        LogError("LoadLootTradePricing", ex)
    }
    _LtTradeClamp()
    _LtTradeLoadCache()
    g_ltTradeHasAuth := _LtTradeAuthPresent()
}

; Persists the trade-pricing settings (never the secrets) to [LootTradePricing].
SaveLootTradePricing()
{
    global g_ltTradeEnabled, g_ltTradeLeague, g_ltTradeTtlHours, g_ltTradeNegTtlHours, g_ltTradeConfigFile
    f := g_ltTradeConfigFile
    try {
        IniWrite(g_ltTradeEnabled ? "1" : "0", f, "LootTradePricing", "enabled")
        IniWrite(g_ltTradeLeague, f, "LootTradePricing", "league")
        IniWrite(g_ltTradeTtlHours, f, "LootTradePricing", "ttlHours")
        IniWrite(g_ltTradeNegTtlHours, f, "LootTradePricing", "negTtlHours")
    } catch as ex {
        LogError("SaveLootTradePricing", ex)
    }
}

_LtTradeClamp()
{
    global g_ltTradeTtlHours, g_ltTradeNegTtlHours
    if !IsSet(g_ltTradeTtlHours)
        g_ltTradeTtlHours := 24
    if !IsSet(g_ltTradeNegTtlHours)
        g_ltTradeNegTtlHours := 12
    g_ltTradeTtlHours    := Max(1, Min(720, Integer(g_ltTradeTtlHours)))
    g_ltTradeNegTtlHours := Max(1, Min(720, Integer(g_ltTradeNegTtlHours)))
}

; Applies one setting from the UI/bridge.
_LtTradeApplySetting(key, val)
{
    global g_ltTradeEnabled, g_ltTradeLeague, g_ltTradeTtlHours, g_ltTradeNegTtlHours
    switch key
    {
        case "enabled":
            g_ltTradeEnabled := _LtTradeTruthy(val)
        case "league":
            g_ltTradeLeague := Trim(val "")
        case "ttlHours":
            g_ltTradeTtlHours := Integer(_LtTradeNum(val))
        case "negTtlHours":
            g_ltTradeNegTtlHours := Integer(_LtTradeNum(val))
    }
    _LtTradeClamp()
}

_LtTradeTruthy(v)
{
    if (v = true || v = 1)
        return true
    s := StrLower(Trim(v ""))
    return (s = "1" || s = "true" || s = "yes" || s = "on")
}
_LtTradeNum(v)
{
    if (v = "")
        return 0
    try return (v + 0)
    return 0
}

; Header JSON — exposes status + whether a session is saved, but NEVER the secret values.
BuildLootTradePricingHeaderJson()
{
    global g_ltTradeEnabled, g_ltTradeLeague, g_ltTradeTtlHours, g_ltTradeNegTtlHours
    global g_ltTradeHasAuth, g_ltTradeStatus, g_ltTradeError, g_ltTradePrices, g_ltTradeQueue
    j := "{"
    j .= '"enabled":'  (g_ltTradeEnabled ? "true" : "false")
    j .= ',"league":'  _LtTradeJStr(g_ltTradeLeague)
    j .= ',"ttlHours":' (g_ltTradeTtlHours + 0)
    j .= ',"negTtlHours":' (g_ltTradeNegTtlHours + 0)
    j .= ',"hasAuth":' (g_ltTradeHasAuth ? "true" : "false")
    j .= ',"status":'  _LtTradeJStr(g_ltTradeStatus)
    j .= ',"error":'   _LtTradeJStr(g_ltTradeError)
    j .= ',"cacheCount":' (g_ltTradePrices.Count + 0)
    j .= ',"queueCount":' (g_ltTradeQueue.Count + 0)
    j .= "}"
    return j
}

; Minimal JSON string encoder for header values.
_LtTradeJStr(s)
{
    s := s ""
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", " ")
    s := StrReplace(s, "`n", " ")
    s := StrReplace(s, "`t", " ")
    return '"' s '"'
}

; ── Secret (session) handling ───────────────────────────────────────────────────
; Writes the gitignored auth file from the UI. The values are written to disk and NEVER
; logged / echoed / pushed back. Empty fields are simply omitted. Returns nothing.
SetPoeTradeAuth(poesessid, cfClearance, userAgent)
{
    global g_ltTradeAuthFile, g_ltTradeHasAuth
    sess := Trim(poesessid "")
    cf   := Trim(cfClearance "")
    ua   := Trim(userAgent "")

    dir := RegExReplace(g_ltTradeAuthFile, "[\\/][^\\/]+$", "")
    if (dir != "" && !DirExist(dir))
        try DirCreate(dir)

    body := "# PoEformance trade auth — DO NOT COMMIT (this folder is gitignored).`n"
          . "# Refresh CF_CLEARANCE + USER_AGENT from your browser if pricing reports 'blocked'.`n"
    if (sess != "")
        body .= "POESESSID=" sess "`n"
    if (cf != "")
        body .= "CF_CLEARANCE=" cf "`n"
    if (ua != "")
        body .= "USER_AGENT=" ua "`n"

    try {
        if FileExist(g_ltTradeAuthFile)
            FileDelete(g_ltTradeAuthFile)
        FileAppend(body, g_ltTradeAuthFile, "UTF-8")
    } catch as ex {
        LogError("SetPoeTradeAuth", ex)   ; ex.Message must never include the secret (it won't)
    }
    g_ltTradeHasAuth := _LtTradeAuthPresent()
}

; Deletes the saved session file.
ClearPoeTradeAuth()
{
    global g_ltTradeAuthFile, g_ltTradeHasAuth
    try {
        if FileExist(g_ltTradeAuthFile)
            FileDelete(g_ltTradeAuthFile)
    }
    g_ltTradeHasAuth := false
}

; True when the auth file exists and contains a POESESSID line. Reads the file but stores
; nothing — only a boolean leaves this function.
_LtTradeAuthPresent()
{
    global g_ltTradeAuthFile
    if !FileExist(g_ltTradeAuthFile)
        return false
    try {
        raw := FileRead(g_ltTradeAuthFile, "UTF-8")
        return (InStr(raw, "POESESSID=") > 0)
    }
    return false
}

; ── Cache ────────────────────────────────────────────────────────────────────────
; Cache file: tab-separated  <normName>\t<exOrEmpty>\t<epoch>\t<count>\t<displayName>
_LtTradeLoadCache()
{
    global g_ltTradePrices, g_ltTradeCacheFile
    g_ltTradePrices := Map()
    if !FileExist(g_ltTradeCacheFile)
        return
    try raw := FileRead(g_ltTradeCacheFile, "UTF-8")
    catch
        return
    Loop Parse, raw, "`n", "`r"
    {
        line := A_LoopField
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue
        c := StrSplit(line, "`t")
        if (c.Length < 4)
            continue
        nk := c[1]
        if (nk = "")
            continue
        ex    := (c[2] != "" && IsNumber(c[2])) ? c[2] + 0.0 : 0.0
        epoch := (c[3] != "" && IsNumber(c[3])) ? Integer(c[3]) : 0
        cnt   := (c.Has(4) && c[4] != "" && IsNumber(c[4])) ? Integer(c[4]) : 0
        nm    := c.Has(5) ? c[5] : ""
        g_ltTradePrices[nk] := Map("ex", ex, "epoch", epoch, "count", cnt, "name", nm)
    }
}

; Persists the whole (small) cache to disk.
_LtTradeSaveCache()
{
    global g_ltTradePrices, g_ltTradeCacheFile
    out := "#meta`t" _LtTradeEpoch() "`n"
    for nk, e in g_ltTradePrices
        out .= nk "`t" (e["ex"] > 0 ? e["ex"] : "") "`t" e["epoch"] "`t" e["count"] "`t" (e.Has("name") ? e["name"] : "") "`n"
    try {
        if FileExist(g_ltTradeCacheFile)
            FileDelete(g_ltTradeCacheFile)
        FileAppend(out, g_ltTradeCacheFile, "UTF-8")
    } catch as ex {
        LogError("_LtTradeSaveCache", ex)
    }
}

_LtTradeEpoch()
{
    return DateDiff(A_NowUTC, "19700101000000", "Seconds")
}

; Normalize a unique name the same way the PowerShell child does (lowercase, alnum only).
_LtTradeNorm(name)
{
    return RegExReplace(StrLower(name ""), "[^a-z0-9]", "")
}

; Cache freshness: positive entries live ttlHours, negative entries negTtlHours.
_LtTradeFresh(e)
{
    global g_ltTradeTtlHours, g_ltTradeNegTtlHours
    if !(e && IsObject(e) && e.Has("epoch"))
        return false
    ageH := (_LtTradeEpoch() - e["epoch"]) / 3600.0
    ttl := (e["ex"] > 0) ? g_ltTradeTtlHours : g_ltTradeNegTtlHours
    return (ageH <= ttl)
}

; Looks up a fresh trade price for a unique name. Returns true + sets unit (Exalted) when a
; fresh POSITIVE price is cached. A fresh negative entry returns false (caller won't re-queue).
LtTradePriceForName(name, &unit)
{
    global g_ltTradePrices
    unit := 0.0
    nk := _LtTradeNorm(name)
    if (nk = "" || !g_ltTradePrices.Has(nk))
        return false
    e := g_ltTradePrices[nk]
    if !_LtTradeFresh(e)
        return false
    if (e["ex"] > 0) {
        unit := e["ex"]
        return true
    }
    return false   ; fresh negative — priced as "no listings"
}

; True when this unique name is already covered by a fresh cache entry (positive or negative).
_LtTradeCached(name)
{
    global g_ltTradePrices
    nk := _LtTradeNorm(name)
    return (nk != "" && g_ltTradePrices.Has(nk) && _LtTradeFresh(g_ltTradePrices[nk]))
}

; Enqueues a unique name for background trade pricing. No-op unless the feature is enabled,
; a session is saved, the name isn't already fresh-cached, and the queue has room. Schedules
; a (debounced) drain.
LtTradeEnqueue(name)
{
    global g_ltTradeEnabled, g_ltTradeHasAuth, g_ltTradeQueue, g_ltTradeMaxQueue
    if !(g_ltTradeEnabled && g_ltTradeHasAuth)
        return
    nm := Trim(name "")
    if (nm = "")
        return
    nk := _LtTradeNorm(nm)
    if (nk = "" || g_ltTradeQueue.Has(nk) || _LtTradeCached(nm))
        return
    if (g_ltTradeQueue.Count >= g_ltTradeMaxQueue)
        return
    g_ltTradeQueue[nk] := nm
    SetTimer(_LtTradeDrain, -800)
}

; ── Background refresh (spawn PowerShell child, poll, merge) ─────────────────────
; Drains the queue: writes the pending names, spawns the child, and starts polling. Safe to
; call repeatedly; honours the syncing flag and the post-failure cooldown.
_LtTradeDrain()
{
    global g_ltTradeEnabled, g_ltTradeHasAuth, g_ltTradeQueue, g_ltTradeStatus
    global g_ltTradeScript, g_ltTradeAuthFile, g_ltTradeNamesFile, g_ltTradeOutFile
    global g_ltTradeLeague, g_ltTradeRefreshPid, g_ltTradeStartTick, g_ltTradeCooldownUntil, g_ltTradeError

    if !(g_ltTradeEnabled && g_ltTradeHasAuth)
        return
    if (g_ltTradeStatus = "syncing")
        return
    if (g_ltTradeQueue.Count = 0)
        return
    if (A_TickCount < g_ltTradeCooldownUntil)
        return
    if !FileExist(g_ltTradeScript)
    {
        g_ltTradeStatus := "error"
        g_ltTradeError  := "helper missing: " g_ltTradeScript
        _LtTradeAfter()
        return
    }

    ; Write up to 6 queued names (the child caps internally too).
    names := ""
    n := 0
    for nk, nm in g_ltTradeQueue
    {
        names .= nm "`n"
        if (++n >= 6)
            break
    }
    dir := RegExReplace(g_ltTradeNamesFile, "[\\/][^\\/]+$", "")
    if (dir != "" && !DirExist(dir))
        try DirCreate(dir)
    try {
        if FileExist(g_ltTradeNamesFile)
            FileDelete(g_ltTradeNamesFile)
        FileAppend(names, g_ltTradeNamesFile, "UTF-8")
        if FileExist(g_ltTradeOutFile)
            FileDelete(g_ltTradeOutFile)
    } catch as ex {
        g_ltTradeStatus := "error"
        g_ltTradeError  := "queue write failed: " ex.Message
        _LtTradeAfter()
        return
    }

    league := (g_ltTradeLeague != "") ? g_ltTradeLeague : "Standard"
    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' g_ltTradeScript '"'
        . ' -League "' league '" -AuthFile "' g_ltTradeAuthFile '"'
        . ' -NamesFile "' g_ltTradeNamesFile '" -Out "' g_ltTradeOutFile '"'
    pid := 0
    try
        Run(cmd, A_ScriptDir, "Hide", &pid)
    catch as ex
    {
        g_ltTradeStatus := "error"
        g_ltTradeError  := "spawn failed: " ex.Message
        _LtTradeAfter()
        return
    }

    g_ltTradeStatus := "syncing"
    g_ltTradeError  := ""
    g_ltTradeRefreshPid := pid
    g_ltTradeStartTick  := A_TickCount
    SetTimer(_LtTradePoll, 750)
}

; Poll timer: waits for the child to exit (120 s watchdog), merges its output into the cache,
; flips the status, and removes the processed names from the queue. Self-stops.
_LtTradePoll()
{
    global g_ltTradeRefreshPid, g_ltTradeStartTick, g_ltTradeStatus, g_ltTradeError
    global g_ltTradeOutFile, g_ltTradeQueue, g_ltTradeCooldownUntil, g_ltTradeCooldownMs

    if (g_ltTradeRefreshPid && ProcessExist(g_ltTradeRefreshPid))
    {
        if (A_TickCount - g_ltTradeStartTick > 120000)
        {
            try ProcessClose(g_ltTradeRefreshPid)
            SetTimer(_LtTradePoll, 0)
            g_ltTradeRefreshPid := 0
            g_ltTradeStatus := "error"
            g_ltTradeError  := "timed out"
            g_ltTradeCooldownUntil := A_TickCount + g_ltTradeCooldownMs
            _LtTradeAfter()
        }
        return
    }
    SetTimer(_LtTradePoll, 0)
    g_ltTradeRefreshPid := 0

    status := "ready", err := ""
    processed := []
    if FileExist(g_ltTradeOutFile)
    {
        parsed := _LtTradeMergeOut(g_ltTradeOutFile, &status, &err, &processed)
        if !parsed
        {
            status := (status = "" ? "error" : status)
            if (err = "")
                err := "empty/garbled trade output"
        }
    }
    else
    {
        status := "error"
        err := "no output (helper failed — check PowerShell / network)"
    }

    ; Remove handled names from the queue. On a hard block/error nothing was processed, so the
    ; names stay queued but a cooldown prevents immediate re-spawning (no hammering).
    for _, nk in processed
        if g_ltTradeQueue.Has(nk)
            g_ltTradeQueue.Delete(nk)

    g_ltTradeStatus := status
    g_ltTradeError  := err
    if (status = "blocked" || status = "error")
        g_ltTradeCooldownUntil := A_TickCount + g_ltTradeCooldownMs

    _LtTradeSaveCache()
    _LtTradeAfter()

    ; More queued and not blocked? Drain again shortly.
    if (status = "ready" && g_ltTradeQueue.Count > 0)
        SetTimer(_LtTradeDrain, -1500)
}

; Parses the child Out delta into the cache. ByRef status/err (from #meta) and processed
; (array of norm keys written). Returns true if the file parsed (even with 0 rows).
_LtTradeMergeOut(path, &status, &err, &processed)
{
    global g_ltTradePrices
    status := "", err := "", processed := []
    try raw := FileRead(path, "UTF-8")
    catch
        return false
    if (StrLen(raw) < 5)
        return false
    now := _LtTradeEpoch()
    sawMeta := false
    Loop Parse, raw, "`n", "`r"
    {
        line := A_LoopField
        if (line = "")
            continue
        c := StrSplit(line, "`t")
        kind := c.Has(1) ? c[1] : ""
        if (kind = "#meta")
        {
            sawMeta := true
            status := c.Has(3) ? c[3] : ""
            err    := c.Has(4) ? c[4] : ""
        }
        else if (kind = "P")
        {
            nk := c.Has(2) ? c[2] : ""
            if (nk = "")
                continue
            ex  := (c.Has(3) && c[3] != "" && IsNumber(c[3])) ? c[3] + 0.0 : 0.0
            cnt := (c.Has(4) && c[4] != "" && IsNumber(c[4])) ? Integer(c[4]) : 0
            nm  := c.Has(5) ? c[5] : ""
            g_ltTradePrices[nk] := Map("ex", ex, "epoch", now, "count", cnt, "name", nm)
            processed.Push(nk)
        }
    }
    return sawMeta
}

; Post-refresh hook: refresh the WebView header so the UI shows the new status/cache count.
_LtTradeAfter()
{
    try SetTimer(PushHeaderToWebView, -50)
}
