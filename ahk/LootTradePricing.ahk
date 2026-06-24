; LootTradePricing.ahk
; Official PoE2 trade-API (trade2) price layer for UNIQUE items — fills the gap poe.ninja
; leaves on Standard (no unique prices there). Docks into the value-aware loot radar: when
; poe.ninja cannot price a dropped unique, its English name (resolved from the item's
; ItemVisualIdentity via the reader) is queued, priced through the trade API, cached for a
; long TTL, and read back like any other price.
;
; TRANSPORT = Tier 2 (PoeTradeSession.ahk): the actual trade search/fetch run as same-origin
; fetch() calls INSIDE a logged-in WebView2 on pathofexile.com. So the request uses the
; browser's own cookies (POESESSID / cf_clearance), User-Agent and TLS fingerprint — Cloudflare
; is satisfied and NO secret ever leaves the browser (we store / read / log nothing). This
; module only owns the config, the on-demand queue, the long-TTL cache, currency conversion to
; Exalted, and the rate limiting.
;
; SECURITY-FIRST: OFF by default. Nothing happens until enabled AND the user opens + signs into
; the trade session window once (the session lives only in the gitignored WebView2 profile).
;
; Globals are seeded in LoadLootTradePricing() (NOT via top-level initializers — AHK v2
; module-init gotcha; this file is #Include'd at the bottom). Included by InGameStateMonitor.

; ── Init ───────────────────────────────────────────────────────────────────────
LoadLootTradePricing()
{
    ; Tunables
    global g_ltTradeMaxQueue := 40        ; cap pending names (avoid runaway enqueue)
    global g_ltTradeCooldownMs := 300000  ; pause draining for 5 min after a blocked/error result
    global g_ltTradeMinIntervalMs := 3500 ; min spacing between trade queries (rate-limit safety)

    global g_ltTradeEnabled := false
    global g_ltTradeLeague := "Standard"
    global g_ltTradeTtlHours := 24        ; positive-result cache lifetime
    global g_ltTradeNegTtlHours := 12     ; negative-result (no listings) cache lifetime
    global g_ltTradeConfigFile := _ConfigPath()
    global g_ltTradeCacheFile := A_ScriptDir "\data\trade_prices.tsv"
    ; Runtime
    global g_ltTradePrices := Map()    ; normName -> Map("ex","epoch","count","name")
    global g_ltTradeQueue  := Map()    ; normName -> displayName (pending)
    global g_ltTradePendingById := Map()  ; query id -> displayName (in flight)
    global g_ltTradeStatus := "idle"   ; "idle"|"signin"|"syncing"|"ready"|"blocked"|"error"
    global g_ltTradeError  := ""
    global g_ltTradeBusy := false
    global g_ltTradeSeq := 0
    global g_ltTradeLastSendTick := 0
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
}

; Persists the trade-pricing settings to [LootTradePricing] (no secrets exist to persist).
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

; Header JSON — status + whether the session window is open. No secrets exist to expose.
BuildLootTradePricingHeaderJson()
{
    global g_ltTradeEnabled, g_ltTradeLeague, g_ltTradeTtlHours, g_ltTradeNegTtlHours
    global g_ltTradeStatus, g_ltTradeError, g_ltTradePrices, g_ltTradeQueue
    j := "{"
    j .= '"enabled":'  (g_ltTradeEnabled ? "true" : "false")
    j .= ',"league":'  _LtTradeJStr(g_ltTradeLeague)
    j .= ',"ttlHours":' (g_ltTradeTtlHours + 0)
    j .= ',"negTtlHours":' (g_ltTradeNegTtlHours + 0)
    j .= ',"sessionOpen":' (PoeTradeSessionOpen() ? "true" : "false")
    j .= ',"sessionReady":' (PoeTradeSessionReady() ? "true" : "false")
    j .= ',"status":'  _LtTradeJStr(g_ltTradeStatus)
    j .= ',"error":'   _LtTradeJStr(g_ltTradeError)
    j .= ',"cacheCount":' (g_ltTradePrices.Count + 0)
    j .= ',"queueCount":' (g_ltTradeQueue.Count + 0)
    j .= "}"
    return j
}

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

; Opens / focuses the trade session window (bridge "PoeTradeOpen"). The user signs in once.
LtTradeOpenSession()
{
    global g_ltTradeLeague, g_ltTradeCooldownUntil
    g_ltTradeCooldownUntil := 0   ; a manual open clears any block cooldown
    PoeTradeSessionShow(g_ltTradeLeague)
    try SetTimer(PushHeaderToWebView, -50)
}

; ── Cache (tab-separated: normName \t exOrEmpty \t epoch \t count \t displayName) ─────
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
        if (c.Length < 4 || c[1] = "")
            continue
        ex    := (c[2] != "" && IsNumber(c[2])) ? c[2] + 0.0 : 0.0
        epoch := (c[3] != "" && IsNumber(c[3])) ? Integer(c[3]) : 0
        cnt   := (c.Has(4) && c[4] != "" && IsNumber(c[4])) ? Integer(c[4]) : 0
        nm    := c.Has(5) ? c[5] : ""
        g_ltTradePrices[c[1]] := Map("ex", ex, "epoch", epoch, "count", cnt, "name", nm)
    }
}

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

; Normalize a unique name the same way poe.ninja keys are normalized (lowercase, alnum only).
_LtTradeNorm(name)
{
    return RegExReplace(StrLower(name ""), "[^a-z0-9]", "")
}

_LtTradeFresh(e)
{
    global g_ltTradeTtlHours, g_ltTradeNegTtlHours
    if !(e && IsObject(e) && e.Has("epoch"))
        return false
    ageH := (_LtTradeEpoch() - e["epoch"]) / 3600.0
    ttl := (e["ex"] > 0) ? g_ltTradeTtlHours : g_ltTradeNegTtlHours
    return (ageH <= ttl)
}

; Fresh POSITIVE cached price for a unique name -> true + unit (Exalted). Fresh negative -> false.
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
    return false
}

_LtTradeCached(name)
{
    global g_ltTradePrices
    nk := _LtTradeNorm(name)
    return (nk != "" && g_ltTradePrices.Has(nk) && _LtTradeFresh(g_ltTradePrices[nk]))
}

; Enqueues a unique name for background trade pricing. No-op unless enabled, not already
; fresh-cached, and the queue has room. Schedules a (debounced) drain.
LtTradeEnqueue(name)
{
    global g_ltTradeEnabled, g_ltTradeQueue, g_ltTradeMaxQueue
    if !g_ltTradeEnabled
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

; ── Drain (drive the WebView session) ────────────────────────────────────────────
; Sends the next queued name to the logged-in trade window. Opens the window on demand (the
; user signs in once); enforces the min interval + post-failure cooldown; one query in flight.
_LtTradeDrain()
{
    global g_ltTradeEnabled, g_ltTradeQueue, g_ltTradeBusy, g_ltTradeStatus, g_ltTradeError
    global g_ltTradeLeague, g_ltTradeSeq, g_ltTradePendingById, g_ltTradeLastSendTick
    global g_ltTradeCooldownUntil, g_ltTradeMinIntervalMs, g_notifyOverlay

    if (!g_ltTradeEnabled || g_ltTradeQueue.Count = 0 || g_ltTradeBusy)
        return
    if (A_TickCount < g_ltTradeCooldownUntil)
        return

    ; Open the session window on demand and wait for the helper to come up.
    if !PoeTradeSessionOpen()
    {
        g_ltTradeStatus := "signin"
        g_ltTradeError  := "sign in to PoE in the opened window"
        PoeTradeSessionShow(g_ltTradeLeague)
        if IsObject(g_notifyOverlay)
            try g_notifyOverlay.SetBanner("PoE trade pricing — please sign in once in the opened window", 4000)
        try SetTimer(PushHeaderToWebView, -50)
        return   ; resumes when the helper signals ready
    }
    if !PoeTradeSessionReady()
    {
        g_ltTradeStatus := "signin"
        SetTimer(_LtTradeDrain, -2000)   ; poll until the page helper is up
        return
    }

    ; Rate-limit spacing.
    dt := A_TickCount - g_ltTradeLastSendTick
    if (dt < g_ltTradeMinIntervalMs)
    {
        SetTimer(_LtTradeDrain, -(g_ltTradeMinIntervalMs - dt + 50))
        return
    }

    ; Pop the next name and send it.
    nk := "", nm := ""
    for k, v in g_ltTradeQueue
    {
        nk := k, nm := v
        break
    }
    if (nk = "")
        return
    g_ltTradeQueue.Delete(nk)

    g_ltTradeSeq += 1
    id := g_ltTradeSeq
    g_ltTradePendingById[id] := nm
    g_ltTradeBusy := true
    g_ltTradeLastSendTick := A_TickCount
    g_ltTradeStatus := "syncing"
    g_ltTradeError := ""
    if !PoeTradeSend(id, nm, g_ltTradeLeague)
    {
        ; Send failed — requeue and back off briefly.
        g_ltTradePendingById.Delete(id)
        g_ltTradeQueue[nk] := nm
        g_ltTradeBusy := false
        g_ltTradeStatus := "error"
        g_ltTradeError := "could not reach the trade window"
        g_ltTradeCooldownUntil := A_TickCount + 5000
    }
    try SetTimer(PushHeaderToWebView, -50)
}

; Result handler (called by PoeTradeSession's message handler).
;   ok=false + status 401/403/0 -> Cloudflare/login wall: mark blocked, raise window, cooldown.
;   ok=true                     -> convert listings to Exalted, cache positive/negative.
_LtTradeOnResult(id, ok, status, listings, err)
{
    global g_ltTradePendingById, g_ltTradeQueue, g_ltTradePrices, g_ltTradeBusy
    global g_ltTradeStatus, g_ltTradeError, g_ltTradeCooldownUntil, g_ltTradeCooldownMs
    global g_ltTradeMinIntervalMs, g_ltTradeLeague

    g_ltTradeBusy := false
    if !g_ltTradePendingById.Has(id)
        return
    nm := g_ltTradePendingById[id]
    g_ltTradePendingById.Delete(id)
    nk := _LtTradeNorm(nm)

    if !ok
    {
        if (status = 401 || status = 403 || status = 0)
        {
            ; Login / Cloudflare wall — surface it and stop hammering. Requeue this name.
            g_ltTradeStatus := "blocked"
            g_ltTradeError  := "sign-in needed (status " status ") — sign in again in the trade window"
            if (nk != "")
                g_ltTradeQueue[nk] := nm
            g_ltTradeCooldownUntil := A_TickCount + g_ltTradeCooldownMs
            try PoeTradeSessionShow(g_ltTradeLeague)
        }
        else
        {
            g_ltTradeStatus := "error"
            g_ltTradeError  := "query failed (" (err != "" ? err : status) ")"
            ; Transient — requeue and brief cooldown.
            if (nk != "")
                g_ltTradeQueue[nk] := nm
            g_ltTradeCooldownUntil := A_TickCount + 15000
        }
        try SetTimer(PushHeaderToWebView, -50)
        SetTimer(_LtTradeDrain, -(g_ltTradeMinIntervalMs))
        return
    }

    ; Clean result — price it (empty listings => negative cache).
    rp := _LtTradeRobustPrice(listings)
    now := _LtTradeEpoch()
    g_ltTradePrices[nk] := Map("ex", rp["ex"], "epoch", now, "count", rp["count"], "name", nm)
    g_ltTradeStatus := "ready"
    g_ltTradeError := ""
    _LtTradeSaveCache()
    try SetTimer(PushHeaderToWebView, -50)
    SetTimer(_LtTradeDrain, -(g_ltTradeMinIntervalMs))
}

; Converts one listing currency amount to Exalted using the poe.ninja rates already loaded.
; Unknown currencies return 0 (the caller drops them so a unique is never mis-valued).
_LtTradeListingToEx(amount, currency)
{
    global g_ltDivToEx, g_ltPricesByName
    amt := (amount = "" || !IsNumber(amount)) ? 0.0 : amount + 0.0
    if (amt <= 0)
        return 0.0
    cur := StrLower(Trim(currency ""))
    if (cur = "exalted" || cur = "exalt" || cur = "ex")
        return amt
    if (cur = "divine" || cur = "div")
        return (IsSet(g_ltDivToEx) && g_ltDivToEx > 0) ? amt * g_ltDivToEx : 0.0
    ; Other currencies: map the trade id to the poe.ninja English name and look up its ex price.
    alias := Map("chaos","Chaos Orb", "regal","Regal Orb", "vaal","Vaal Orb"
        , "annul","Orb of Annulment", "exalted","Exalted Orb", "divine","Divine Orb"
        , "alch","Orb of Alchemy", "chance","Orb of Chance", "mirror","Mirror of Kalandra")
    if (alias.Has(cur) && IsSet(g_ltPricesByName))
    {
        pk := _LtNormalize(alias[cur])
        if (g_ltPricesByName.Has(pk) && g_ltPricesByName[pk] > 0)
            return amt * g_ltPricesByName[pk]
    }
    return 0.0
}

; Robust price from listing Maps {amount,currency}: median of the cheapest few (in Exalted).
; Returns Map("ex", price, "count", usedCount). 0/0 when there are no priceable listings.
_LtTradeRobustPrice(listings)
{
    vals := []
    if (IsObject(listings) && Type(listings) = "Array")
    {
        for _, ln in listings
        {
            if !(ln && IsObject(ln))
                continue
            amt := ln.Has("amount") ? ln["amount"] : 0
            cur := ln.Has("currency") ? ln["currency"] : ""
            ex := _LtTradeListingToEx(amt, cur)
            if (ex > 0)
                vals.Push(ex)
        }
    }
    n := vals.Length
    if (n = 0)
        return Map("ex", 0.0, "count", 0)
    _LtTradeSortAsc(vals)
    take := Min(8, n)
    mid := (take // 2) + 1   ; 1-based median index of the cheapest `take`
    return Map("ex", Round(vals[mid] + 0.0, 3), "count", take)
}

; Tiny in-place ascending insertion sort (lists are short).
_LtTradeSortAsc(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        cur := arr[i]
        j := i - 1
        while (j >= 1 && arr[j] > cur)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := cur
        i += 1
    }
}
