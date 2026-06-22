; LootPricing.ahk
; poe.ninja price layer for the LootTracker feature (ported from the GameHelper2
; LootTracker plugin's PriceCache.cs). Provides language-independent item pricing:
; items read off memory are matched to poe.ninja by their internal art id (the dds
; basename), not their localized name, so it works on any client language.
;
; The actual HTTP fetch + JSON reduction runs in a SEPARATE PowerShell child process
; (tools\poe_ninja_prices.ps1) so the radar hot path is never blocked by a network
; call or a multi-MB JSON parse. The child writes a small TSV
; (data\loot_prices.tsv) that this module loads cheaply. Spawn → poll ProcessExist →
; load TSV. PowerShell ships with Windows 10/11; if it is missing the status goes to
; "error" and pricing simply degrades to "unpriced" everywhere.
;
; Globals are seeded in LoadLootPricing() (NOT via top-level initializers — see the
; AHK v2 module-init gotcha in CLAUDE.md). Included by InGameStateMonitor.ahk.

; ── Configuration / state globals (seeded in LoadLootPricing) ──────────────────
global g_ltPricesByArt   := Map()   ; normalized art-id  -> unit price in Exalted
global g_ltNamesByArt    := Map()   ; normalized art-id  -> poe.ninja English name
global g_ltPricesByName  := Map()   ; normalized name    -> unit price in Exalted
global g_ltMetaToArt     := Map()   ; BaseItemType last-segment -> art-id bridge
global g_ltDivToEx       := 0.0     ; 1 Divine in Exalted units (0 = unknown)
global g_ltPriceStatus   := "idle"  ; "idle" | "syncing" | "ready" | "error"
global g_ltPriceError    := ""
global g_ltLastSyncEpoch := 0       ; unix seconds of last successful sync (0 = never)
global g_ltPriceCacheFile := ""
global g_ltMetaArtFile    := ""
global g_ltPriceScript    := ""
; Refresh (child-process) bookkeeping
global g_ltRefreshPid       := 0
global g_ltRefreshOut       := ""
global g_ltRefreshFinal     := ""
global g_ltRefreshStartTick := 0

; ── Init ───────────────────────────────────────────────────────────────────────
; Seeds all pricing globals (defaults first, unconditionally), loads the metaId->art
; bridge + any on-disk price cache, and kicks an initial refresh if the cache is
; missing or stale. Called once at startup before the main script's return.
LoadLootPricing()
{
    global g_ltPricesByArt, g_ltNamesByArt, g_ltPricesByName, g_ltMetaToArt
    global g_ltDivToEx, g_ltPriceStatus, g_ltPriceError, g_ltLastSyncEpoch
    global g_ltPriceCacheFile, g_ltMetaArtFile, g_ltPriceScript
    global g_ltRefreshPid, g_ltRefreshOut, g_ltRefreshFinal, g_ltRefreshStartTick
    global g_ltLeague, g_ltCacheTtlMin, g_ltEnabled

    g_ltPricesByArt   := Map()
    g_ltNamesByArt    := Map()
    g_ltPricesByName  := Map()
    g_ltMetaToArt     := Map()
    g_ltDivToEx       := 0.0
    g_ltPriceStatus   := "idle"
    g_ltPriceError    := ""
    g_ltLastSyncEpoch := 0
    g_ltPriceCacheFile := A_ScriptDir "\data\loot_prices.tsv"
    g_ltMetaArtFile    := A_ScriptDir "\data\meta_art_map.json"
    g_ltPriceScript    := A_ScriptDir "\tools\poe_ninja_prices.ps1"
    g_ltRefreshPid       := 0
    g_ltRefreshOut       := ""
    g_ltRefreshFinal     := ""
    g_ltRefreshStartTick := 0

    _LtLoadMetaArtMap()

    ; Load any on-disk cache so prices are available immediately (even if stale).
    fresh := _LtLoadPriceTsv(g_ltPriceCacheFile)

    ; Kick a background refresh when the feature is on and there is no cache (or it has
    ; aged past the TTL). When the feature is off we leave the disk cache as-is; enabling
    ; it later triggers a refresh via the per-tick TTL check.
    ttlMin := (IsSet(g_ltCacheTtlMin) && g_ltCacheTtlMin > 0) ? g_ltCacheTtlMin : 60
    ageOk := fresh && g_ltLastSyncEpoch > 0
        && ((_LtNowEpoch() - g_ltLastSyncEpoch) <= (ttlMin * 60))
    if (!ageOk && IsSet(g_ltEnabled) && g_ltEnabled)
        StartLootPriceRefresh()
}

; Loads the metaId->art bridge shipped beside the dictionaries (data\meta_art_map.json).
; A missing/garbled file is non-fatal: pricing then falls back to metaId == art for
; every item (still correct for the majority).
_LtLoadMetaArtMap()
{
    global g_ltMetaToArt, g_ltMetaArtFile
    g_ltMetaToArt := Map()
    try
    {
        if !FileExist(g_ltMetaArtFile)
            return
        content := FileRead(g_ltMetaArtFile, "UTF-8")
        parsed := JsonFull_Parse(content)
        if (parsed && Type(parsed) = "Map")
            g_ltMetaToArt := parsed
    }
}

; ── TSV cache (written by the PowerShell helper) ───────────────────────────────
; Format (tab-separated):
;   #meta  <divToEx>  <epochSeconds>  <errorsOrEmpty>
;   A      <normArtKey>   <priceOrEmpty>   <nameOrEmpty>
;   N      <normName>     <price>
; Returns true if the file existed and parsed into a populated table.
_LtLoadPriceTsv(path)
{
    global g_ltPricesByArt, g_ltNamesByArt, g_ltPricesByName, g_ltDivToEx, g_ltLastSyncEpoch, g_ltPriceError
    if !FileExist(path)
        return false
    try
        raw := FileRead(path, "UTF-8")
    catch
        return false
    if (StrLen(raw) < 5)
        return false

    art   := Map()
    names := Map()
    byName := Map()
    div := 0.0
    epoch := 0
    metaErr := ""

    Loop Parse, raw, "`n", "`r"
    {
        line := A_LoopField
        if (line = "")
            continue
        cols := StrSplit(line, "`t")
        kind := cols.Has(1) ? cols[1] : ""
        if (kind = "#meta")
        {
            div   := (cols.Has(2) && cols[2] != "") ? cols[2] + 0 : 0.0
            epoch := (cols.Has(3) && cols[3] != "") ? Integer(cols[3]) : 0
            metaErr := cols.Has(4) ? cols[4] : ""
        }
        else if (kind = "A")
        {
            key := cols.Has(2) ? cols[2] : ""
            if (key = "")
                continue
            pr  := cols.Has(3) ? cols[3] : ""
            nm  := cols.Has(4) ? cols[4] : ""
            if (pr != "" && IsNumber(pr))
                art[key] := pr + 0
            if (nm != "")
                names[key] := nm
        }
        else if (kind = "N")
        {
            key := cols.Has(2) ? cols[2] : ""
            pr  := cols.Has(3) ? cols[3] : ""
            if (key != "" && pr != "" && IsNumber(pr))
                byName[key] := pr + 0
        }
    }

    if (art.Count = 0 && byName.Count = 0)
        return false

    g_ltPricesByArt   := art
    g_ltNamesByArt    := names
    g_ltPricesByName  := byName
    g_ltDivToEx       := div
    g_ltLastSyncEpoch := epoch
    ; Surface any poe.ninja partial-failure note the helper recorded (e.g. a renamed
    ; league slug or unreachable overview type) so the UI can hint at why prices are thin.
    if (metaErr != "")
        g_ltPriceError := metaErr
    return true
}

; ── Refresh (spawn PowerShell helper, poll, load) ──────────────────────────────
; Fire-and-forget. Spawns the helper to fetch + reduce poe.ninja into the TSV, then
; polls for the child to exit. Safe to call repeatedly: a second call while a refresh
; is in flight returns immediately.
StartLootPriceRefresh()
{
    global g_ltPriceStatus, g_ltPriceError, g_ltPriceScript, g_ltPriceCacheFile
    global g_ltRefreshPid, g_ltRefreshOut, g_ltRefreshFinal, g_ltRefreshStartTick
    global g_ltLeague

    if (g_ltPriceStatus = "syncing")
        return
    if !FileExist(g_ltPriceScript)
    {
        g_ltPriceStatus := "error"
        g_ltPriceError  := "helper missing: " g_ltPriceScript
        return
    }

    league := (IsSet(g_ltLeague) && g_ltLeague != "") ? g_ltLeague : "Standard"
    tmpFile := g_ltPriceCacheFile ".tmp"
    try FileDelete(tmpFile)

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' g_ltPriceScript '"'
        . ' -League "' league '" -Out "' tmpFile '"'
    pid := 0
    try
        Run(cmd, A_ScriptDir, "Hide", &pid)
    catch as ex
    {
        g_ltPriceStatus := "error"
        g_ltPriceError  := "spawn failed: " ex.Message
        return
    }

    g_ltPriceStatus     := "syncing"
    g_ltPriceError      := ""
    g_ltRefreshPid      := pid
    g_ltRefreshOut      := tmpFile
    g_ltRefreshFinal    := g_ltPriceCacheFile
    g_ltRefreshStartTick := A_TickCount
    SetTimer(_LtPricePoll, 500)
}

; Poll timer: waits for the helper process to exit (or a 120 s watchdog), then loads
; the freshly written TSV and flips the status. Self-stops.
_LtPricePoll()
{
    global g_ltPriceStatus, g_ltPriceError, g_ltRefreshPid, g_ltRefreshOut, g_ltRefreshFinal
    global g_ltRefreshStartTick

    if (g_ltRefreshPid && ProcessExist(g_ltRefreshPid))
    {
        if (A_TickCount - g_ltRefreshStartTick > 120000)
        {
            try ProcessClose(g_ltRefreshPid)
            SetTimer(_LtPricePoll, 0)
            g_ltPriceStatus := "error"
            g_ltPriceError  := "timed out"
            _LtAfterRefresh()
        }
        return
    }

    SetTimer(_LtPricePoll, 0)
    g_ltRefreshPid := 0

    if FileExist(g_ltRefreshOut)
    {
        try FileMove(g_ltRefreshOut, g_ltRefreshFinal, true)
        if _LtLoadPriceTsv(g_ltRefreshFinal)
        {
            g_ltPriceStatus := "ready"
            g_ltPriceError  := ""
        }
        else
        {
            g_ltPriceStatus := "error"
            if (g_ltPriceError = "")
                g_ltPriceError := "empty/garbled price data"
        }
    }
    else if (g_ltPriceStatus != "error")
    {
        g_ltPriceStatus := "error"
        g_ltPriceError  := "no output (helper failed — check league / network / PowerShell)"
    }
    _LtAfterRefresh()
}

; Post-refresh hook: refresh the header so the UI shows the new status/rate.
_LtAfterRefresh()
{
    try SetTimer(PushHeaderToWebView, -50)
}

; ── Pricing lookups (ported from PriceCache.cs / LootTrackerCore.cs) ───────────
; Lowercase + drop everything that isn't a-z 0-9. Matches the helper's normalization
; so the art-id / name keys agree on both sides.
_LtNormalize(s)
{
    if (s = "")
        return ""
    return RegExReplace(StrLower(s), "[^a-z0-9]", "")
}

; Resolve an item's metadata path to the art id poe.ninja prices by:
;   1. exact metaId (last path segment) in the bridge;
;   2. else the metaId's non-numeric stem in the bridge -> that art + the trailing
;      number (the item's LEVEL for leveled families, e.g. SkillGemUncut18);
;   3. else the bare last segment (correct for most items).
_LtPriceKey(path)
{
    global g_ltMetaToArt
    seg := _LtLastSegment(path)
    if (g_ltMetaToArt.Has(seg))
        return g_ltMetaToArt[seg]

    s := StrLen(seg)
    while (s > 0)
    {
        c := SubStr(seg, s, 1)
        if (c >= "0" && c <= "9")
            s -= 1
        else
            break
    }
    if (s > 0 && s < StrLen(seg))
    {
        stem := SubStr(seg, 1, s)
        if (g_ltMetaToArt.Has(stem))
            return g_ltMetaToArt[stem] SubStr(seg, s + 1)
    }
    return seg
}

; poe.ninja's tablet "variant" label for an in-game rarity index.
_LtRarityVariant(rarity)
{
    switch rarity
    {
        case 1: return "Magic"
        case 2: return "Rare"
        case 3: return "Unique"
        default: return "Normal"
    }
}

; Resolve one inventory key (see LootTrackerInventory _LtBuildItemKey) to its unit
; Exalted price and display label. Uniques are matched on their rendered icon art id
; only (their base metapath is shared by every unique on that base); everything else
; tries the per-rarity art key, then the bare art id. Returns true if priced.
;   unit  (ByRef) -> unit price in Exalted (0 when unpriced)
;   label (ByRef) -> human display label (poe.ninja name, else the art id)
_LtTryPriceItem(itemKey, &unit, &label)
{
    global g_ltPricesByArt, g_ltNamesByArt
    unit := 0.0
    label := ""

    parts := _LtSplitItemKey(itemKey)
    rarity := parts[1], path := parts[2], renderArt := parts[3]

    ; Uniques: match on the unique-specific rendered art id; DON'T fall back to the
    ; base art (that's the base/Normal price and would badly misvalue the unique).
    if (rarity = 3 && renderArt != "")
    {
        nk := _LtNormalize(renderArt)
        priced := false
        if (g_ltPricesByArt.Has(nk) && g_ltPricesByArt[nk] > 0)
        {
            unit := g_ltPricesByArt[nk]
            priced := true
        }
        label := (g_ltNamesByArt.Has(nk) && g_ltNamesByArt[nk] != "") ? g_ltNamesByArt[nk] : renderArt
        if !priced
            unit := 0.0
        return priced
    }

    art := _LtPriceKey(path)
    variantKey := _LtNormalize(art _LtRarityVariant(rarity))
    artKey := _LtNormalize(art)

    priced := false
    if (g_ltPricesByArt.Has(variantKey) && g_ltPricesByArt[variantKey] > 0)
    {
        unit := g_ltPricesByArt[variantKey]
        priced := true
    }
    else if (g_ltPricesByArt.Has(artKey) && g_ltPricesByArt[artKey] > 0)
    {
        unit := g_ltPricesByArt[artKey]
        priced := true
    }
    else
        unit := 0.0

    if (g_ltNamesByArt.Has(variantKey) && g_ltNamesByArt[variantKey] != "")
        label := g_ltNamesByArt[variantKey]
    else if (g_ltNamesByArt.Has(artKey) && g_ltNamesByArt[artKey] != "")
        label := g_ltNamesByArt[artKey]
    else
        label := art

    return priced
}

; ── Small helpers ──────────────────────────────────────────────────────────────
_LtLastSegment(path)
{
    i := InStr(path, "/", false, -1)   ; last '/'
    if (i > 0 && i < StrLen(path))
        return SubStr(path, i + 1)
    return path
}

; Unix seconds for "now" (UTC).
_LtNowEpoch()
{
    return DateDiff(A_NowUTC, "19700101000000", "Seconds")
}
