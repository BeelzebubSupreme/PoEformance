; LootRadarValue.ahk
; Value-aware loot radar — STEP 0: reverse-engineering verification.
;
; Goal of the feature (later): price ground loot via the existing poe.ninja layer and
; paint the value on the radar + a "valuable nearby" list + a threshold alert.
;
; RE finding so far (confirmed in-game 2026-06-23): a ground drop is a WRAPPER entity
; `Metadata/MiscellaneousObjects/WorldItem` whose own components carry NO rarity/art
; (the wrapper reads as rarity 0, no RenderItem). The real item (path, rarity, render
; art) lives on a separate ITEM entity that the wrapper's "WorldItem" component points
; to. So we must: find the wrapper's WorldItem component → read the inner item entity
; pointer from it → then reuse the existing item reads (ReadItemRarity / ReadItemArtPath)
; on that inner entity. This module's diagnostic probes for the inner-item pointer offset
; so we can pin it down, then price uniques with the existing poe.ninja layer.
;
; Included by InGameStateMonitor.ahk.

; Reads an arbitrary entity's metadata path (EntityDetailsPtr → Path). "" on failure.
_LrvEntityPath(ptr)
{
    global g_reader
    if !(IsObject(g_reader) && g_reader.IsProbablyValidPointer(ptr))
        return ""
    try {
        ed := g_reader.Mem.ReadPtr(ptr + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !g_reader.IsProbablyValidPointer(ed)
            return ""
        return g_reader.ReadStdWStringAt(ed + PoE2Offsets.EntityDetails["Path"], 260)
    }
    return ""
}

; Resolves the inner ITEM entity for a ground WorldItem wrapper. Finds the wrapper's
; "WorldItem" component, then probes candidate pointer offsets inside it for an entity
; whose path is "Metadata/Items/…". ByRef: innerPtr, innerPath, off (offset that hit),
; compAddr (WorldItem component address), compNames (all component names, for the report).
; Returns true when an inner item entity was found.
_LrvResolveInnerItem(wrapperAddr, &innerPtr, &innerPath, &off, &compAddr, &compNames)
{
    global g_reader
    innerPtr := 0, innerPath := "", off := -1, compAddr := 0, compNames := ""
    if !(IsObject(g_reader) && wrapperAddr)
        return false

    comps := 0
    try comps := g_reader.ReadEntityComponentLookupBasic(wrapperAddr, 64)
    if (comps && Type(comps) = "Array")
    {
        for _, c in comps
        {
            if !(c && IsObject(c) && c.Has("name"))
                continue
            nm := c["name"]
            compNames .= (compNames = "" ? "" : ", ") nm
            if (compAddr = 0 && InStr(StrLower(nm), "worlditem"))
                compAddr := c.Has("address") ? c["address"] : 0
        }
    }
    if !compAddr
        return false

    ; Confirmed in-game (2026-06-23): the inner item entity pointer sits at WorldItem
    ; component + 0x28. Try that first (cheap), then fall back to a small sweep in case
    ; a patch shifts it — the inner item is identified by a "Metadata/Items/…" path.
    known := 0x28
    cand := 0
    try cand := g_reader.Mem.ReadPtr(compAddr + known)
    if (cand && g_reader.IsProbablyValidPointer(cand))
    {
        p := _LrvEntityPath(cand)
        if (p != "" && InStr(p, "Metadata/Items/"))
        {
            innerPtr := cand, innerPath := p, off := known
            return true
        }
    }

    o := 0x08
    while (o <= 0xA0)
    {
        if (o = known)
        {
            o += 0x08
            continue
        }
        cand := 0
        try cand := g_reader.Mem.ReadPtr(compAddr + o)
        if (cand && g_reader.IsProbablyValidPointer(cand))
        {
            p := _LrvEntityPath(cand)
            if (p != "" && InStr(p, "Metadata/Items/"))
            {
                innerPtr := cand, innerPath := p, off := o
                return true
            }
        }
        o += 0x08
    }
    return false
}

; Prices a resolved inner ITEM entity. Reads its rendered art id via the offset-agnostic
; ReadItemArtPath() and resolves the poe.ninja unit price. ByRef: dds, renderArt, unit,
; label. Returns true when priced. (rarityId/path come from the resolved inner entity.)
_LrvPriceInner(innerPtr, innerPath, rarityId, &dds, &renderArt, &unit, &label)
{
    global g_reader
    dds := "", renderArt := "", unit := 0.0, label := ""
    if (IsObject(g_reader) && innerPtr)
    {
        try dds := g_reader.ReadItemArtPath(innerPtr)
        renderArt := _LtArtIdFromDds(dds . "")
    }
    return _LtTryPriceItem(_LtBuildItemKey(rarityId, innerPath, renderArt), &unit, &label)
}

; ── Config + live annotation engine ───────────────────────────────────────────

; Seeds all LootRadarValue globals (defaults first), then overlays the persisted
; [LootRadarValue] INI section. Called once at startup by the main script.
LoadLootRadarValue()
{
    global g_lrvEnabled := false            ; master switch for the value-aware loot radar
    global g_lrvAlertEnabled := true        ; banner when a drop crosses the alert value
    global g_lrvMinLabelEx := 1.0           ; min total value (ex) for a drop to count as valuable
    global g_lrvAlertEx := 20.0             ; total value (ex) that triggers the banner
    global g_lrvConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_lrvAnnot := Map()              ; wrapper addr -> Map(valueEx,label,rarity,tick)
    global g_lrvNearby := []                ; sorted valuable-nearby list (overlay, step 2)
    global g_lrvAlerted := Map()            ; wrapper addr -> 1 once alerted (per area)
    global g_lrvAreaHash := 0               ; last area hash (per-area reset)
    global g_lrvLastTick := 0               ; throttle stamp

    f := g_lrvConfigFile
    try {
        g_lrvEnabled      := (IniRead(f, "LootRadarValue", "enabled", g_lrvEnabled ? "1" : "0") = "1")
        g_lrvAlertEnabled := (IniRead(f, "LootRadarValue", "alertEnabled", g_lrvAlertEnabled ? "1" : "0") = "1")
        g_lrvMinLabelEx   := _LrvNum(IniRead(f, "LootRadarValue", "minLabelEx", g_lrvMinLabelEx))
        g_lrvAlertEx      := _LrvNum(IniRead(f, "LootRadarValue", "alertEx", g_lrvAlertEx))
    } catch as ex {
        LogError("LoadLootRadarValue", ex)
    }
    _LrvClamp()
}

; Persists the LootRadarValue settings to [LootRadarValue].
SaveLootRadarValue()
{
    global g_lrvEnabled, g_lrvAlertEnabled, g_lrvMinLabelEx, g_lrvAlertEx, g_lrvConfigFile
    f := g_lrvConfigFile
    try {
        IniWrite(g_lrvEnabled ? "1" : "0", f, "LootRadarValue", "enabled")
        IniWrite(g_lrvAlertEnabled ? "1" : "0", f, "LootRadarValue", "alertEnabled")
        IniWrite(g_lrvMinLabelEx, f, "LootRadarValue", "minLabelEx")
        IniWrite(g_lrvAlertEx, f, "LootRadarValue", "alertEx")
    } catch as ex {
        LogError("SaveLootRadarValue", ex)
    }
}

; Tolerant numeric parse — returns a Number, 0.0 on junk.
_LrvNum(v)
{
    if (v = "")
        return 0.0
    try return (v + 0.0)
    return 0.0
}

; Keeps the value thresholds non-negative.
_LrvClamp()
{
    global g_lrvMinLabelEx, g_lrvAlertEx
    g_lrvMinLabelEx := Max(0.0, g_lrvMinLabelEx + 0.0)
    g_lrvAlertEx    := Max(0.0, g_lrvAlertEx + 0.0)
}

; Loose boolean coercion (true/1/"1"/"true"/"yes"/"on").
_LrvTruthy(v)
{
    if (v = true || v = 1)
        return true
    s := StrLower(Trim(v ""))
    return (s = "1" || s = "true" || s = "yes" || s = "on")
}

; Applies one setting from the UI/bridge. Clears the live cache when disabled.
_LrvApplySetting(key, val)
{
    global g_lrvEnabled, g_lrvAlertEnabled, g_lrvMinLabelEx, g_lrvAlertEx
    global g_lrvAnnot, g_lrvNearby, g_lrvAlerted
    switch key
    {
        case "enabled":
            g_lrvEnabled := _LrvTruthy(val)
            if !g_lrvEnabled
            {
                g_lrvAnnot := Map(), g_lrvNearby := [], g_lrvAlerted := Map()
            }
        case "alertEnabled":
            g_lrvAlertEnabled := _LrvTruthy(val)
        case "minLabelEx":
            g_lrvMinLabelEx := _LrvNum(val)
        case "alertEx":
            g_lrvAlertEx := _LrvNum(val)
    }
    _LrvClamp()
}

; Builds the "lootRadarValue" JSON for the WebView header push.
BuildLootRadarValueHeaderJson()
{
    global g_lrvEnabled, g_lrvAlertEnabled, g_lrvMinLabelEx, g_lrvAlertEx
    j := "{"
    j .= '"enabled":'       (g_lrvEnabled ? "true" : "false")
    j .= ',"alertEnabled":' (g_lrvAlertEnabled ? "true" : "false")
    j .= ',"minLabelEx":'   (g_lrvMinLabelEx + 0.0)
    j .= ',"alertEx":'      (g_lrvAlertEx + 0.0)
    j .= "}"
    return j
}

; Reads a ground item's stack count (1 for non-stackables). Param: inner item ptr.
_LrvStackCount(innerPtr)
{
    global g_reader
    if !(IsObject(g_reader) && innerPtr)
        return 1
    try {
        sp := g_reader.FindEntityComponentAddress(innerPtr, "Stack")
        if g_reader.IsProbablyValidPointer(sp)
        {
            n := g_reader.Mem.ReadInt(sp + PoE2Offsets.Stack["Count"])
            if (n >= 1)
                return n
        }
    }
    return 1
}

; Annotates one ground WorldItem wrapper: resolves the inner item, prices it (× stack).
; ByRef valueEx (total Exalted), label (e.g. "20× Chaos Orb" / "Headhunter"), rarity.
; Returns true when a positive value was resolved.
_LrvAnnotateGround(wrapperAddr, &valueEx, &label, &rarity)
{
    global g_reader
    valueEx := 0.0, label := "", rarity := -1
    innerPtr := 0, innerPath := "", off := -1, compAddr := 0, compNames := ""
    if !_LrvResolveInnerItem(wrapperAddr, &innerPtr, &innerPath, &off, &compAddr, &compNames)
        return false
    try rarity := g_reader.ReadItemRarity(innerPtr)
    dds := "", renderArt := "", unit := 0.0, plabel := ""
    if !_LrvPriceInner(innerPtr, innerPath, rarity, &dds, &renderArt, &unit, &plabel)
        return false
    if (unit <= 0)
        return false
    count := _LrvStackCount(innerPtr)
    valueEx := unit * count
    label := (count > 1 ? count "× " : "") (plabel != "" ? plabel : renderArt)
    return true
}

; Per-tick driver (from UpdateRadarFast). Throttled ~4 Hz. Prices ground items, caches the
; annotation by wrapper addr (read cheaply by the radar/overlay), and fires a one-shot
; banner per area when a drop crosses the alert value. Self-gated, cheap when off.
TryLootRadarValue(radarSnap)
{
    global g_reader, g_lrvEnabled, g_lrvAlertEnabled, g_lrvMinLabelEx, g_lrvAlertEx
    global g_lrvAnnot, g_lrvNearby, g_lrvAlerted, g_lrvAreaHash, g_lrvLastTick, g_notifyOverlay
    if (!g_lrvEnabled || !IsObject(g_reader))
        return
    if ((A_TickCount - g_lrvLastTick) < 250)
        return
    g_lrvLastTick := A_TickCount

    inGs := (radarSnap && radarSnap is Map && radarSnap.Has("inGameState")) ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return
    hash := area.Has("currentAreaHash") ? area["currentAreaHash"] : 0
    if (hash != g_lrvAreaHash)
    {
        g_lrvAreaHash := hash
        g_lrvAnnot := Map(), g_lrvAlerted := Map(), g_lrvNearby := []
    }

    awake  := area.Has("awakeEntities") ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    now := A_TickCount
    seen := Map()
    if (sample && Type(sample) = "Array")
    {
        for _, entry in sample
        {
            if !(entry && IsObject(entry) && entry.Has("entity"))
                continue
            entity := entry["entity"]
            if !(entity && IsObject(entity))
                continue
            path := entity.Has("path") ? entity["path"] : ""
            if (path = "" || !_IsWorldItemPath(path))
                continue
            addr := entity.Has("address") ? entity["address"] : 0
            if !addr
                continue
            seen[addr] := true

            if g_lrvAnnot.Has(addr)
            {
                g_lrvAnnot[addr]["tick"] := now
                continue
            }

            valueEx := 0.0, label := "", rarity := -1
            if !_LrvAnnotateGround(addr, &valueEx, &label, &rarity)
                continue
            if (valueEx < g_lrvMinLabelEx)
                continue
            g_lrvAnnot[addr] := Map("valueEx", valueEx, "label", label, "rarity", rarity, "tick", now)

            if (g_lrvAlertEnabled && valueEx >= g_lrvAlertEx && !g_lrvAlerted.Has(addr))
            {
                g_lrvAlerted[addr] := 1
                if IsObject(g_notifyOverlay)
                    try g_notifyOverlay.SetBanner(label " — " _LrvFmtEx(valueEx), 2600)
            }
        }
    }

    ; Drop entries no longer in the sample (picked up / out of range).
    toDrop := []
    for addr, info in g_lrvAnnot
        if !seen.Has(addr)
            toDrop.Push(addr)
    for _, addr in toDrop
        g_lrvAnnot.Delete(addr)

    ; Rebuild the sorted "valuable nearby" list (consumed by the overlay in step 2).
    list := []
    for addr, info in g_lrvAnnot
        list.Push(info)
    g_lrvNearby := _LrvSortByValueDesc(list)
}

; Returns the cached value label for a ground wrapper addr (for the radar dot in step 3),
; or "" when the feature is off / the addr isn't a valued drop.
LrvLabelFor(addr)
{
    global g_lrvEnabled, g_lrvAnnot
    if (!g_lrvEnabled || !addr || !g_lrvAnnot.Has(addr))
        return ""
    return _LrvFmtEx(g_lrvAnnot[addr]["valueEx"])
}

; Formats an Exalted value compactly: "0.8 ex" / "12 ex" / "1.2k ex".
_LrvFmtEx(ex)
{
    if (ex >= 1000)
        return Round(ex / 1000, 1) "k ex"
    if (ex >= 10)
        return Round(ex) " ex"
    return Round(ex, 1) " ex"
}

; Insertion-sorts an array of annotation Maps by valueEx descending (tiny list).
_LrvSortByValueDesc(arr)
{
    n := arr.Length
    i := 2
    while (i <= n)
    {
        cur := arr[i]
        j := i - 1
        while (j >= 1 && arr[j]["valueEx"] < cur["valueEx"])
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := cur
        i += 1
    }
    return arr
}

; RE-verification diagnostic. For each ground WorldItem wrapper in the radar snapshot,
; resolves the inner item entity, then reports the discovered pointer offset + the inner
; path / rarity / render art / poe.ninja price. The decisive output is the WorldItem→item
; offset (so we can hard-wire it) and whether uniques then resolve an art id + price.
; Writes a full report to debug\ and shows a summary MsgBox.
LootValueDiagnose()
{
    global g_reader, g_radarLastSnap, g_ltPricesByArt

    if !IsObject(g_reader)
    {
        try MsgBox("Loot Value Diagnose: game not connected.", "Loot Value Diagnose", 0x40)
        return
    }

    priceCount := (IsSet(g_ltPricesByArt) && IsObject(g_ltPricesByArt)) ? g_ltPricesByArt.Count : 0

    out := "=== Loot Value Diagnose  (" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") ") ===`n`n"
    out .= "poe.ninja price-cache entries: " priceCount
    out .= (priceCount = 0 ? "   (no prices loaded — enable Loot pricing + pick a league to get values)" : "") "`n`n"

    snap   := (IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    inGs   := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    area   := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0

    total := 0, resolved := 0, priced := 0, uniques := 0, uniquesPriced := 0
    offCounts := Map()   ; discovered WorldItem->item offset -> hit count
    lines := ""
    if (sample && Type(sample) = "Array")
    {
        for _, entry in sample
        {
            if !(entry && IsObject(entry) && entry.Has("entity"))
                continue
            entity := entry["entity"]
            if !(entity && IsObject(entity))
                continue
            path := entity.Has("path") ? entity["path"] : ""
            if (path = "" || !_IsWorldItemPath(path))
                continue
            addr := entity.Has("address") ? entity["address"] : 0

            total += 1

            innerPtr := 0, innerPath := "", off := -1, compAddr := 0, compNames := ""
            ok := _LrvResolveInnerItem(addr, &innerPtr, &innerPath, &off, &compAddr, &compNames)

            if (total <= 12)
            {
                lines .= "  wrapper=" (addr ? Format("0x{:X}", addr) : "0") "`n"
                lines .= "    comps: " (compNames != "" ? compNames : "(none)") "`n"
            }

            if !ok
            {
                if (total <= 12)
                    lines .= "    -> inner item NOT resolved (WorldItem comp="
                           . (compAddr ? Format("0x{:X}", compAddr) : "0") ")`n"
                continue
            }

            resolved += 1
            offCounts[off] := (offCounts.Has(off) ? offCounts[off] : 0) + 1

            rid := -1
            try rid := g_reader.ReadItemRarity(innerPtr)
            if (rid = 3 || rid = 4)
                uniques += 1

            dds := "", renderArt := "", unit := 0.0, label := ""
            isP := _LrvPriceInner(innerPtr, innerPath, rid, &dds, &renderArt, &unit, &label)
            if isP
            {
                priced += 1
                if (rid = 3 || rid = 4)
                    uniquesPriced += 1
            }

            if (total <= 12)
            {
                lines .= "    -> inner=" Format("0x{:X}", innerPtr) "  @comp+" Format("0x{:X}", off)
                       . "  r" rid "`n"
                lines .= "       path=" innerPath "`n"
                lines .= "       art=" (renderArt != "" ? renderArt : "-")
                       . "  price=" (isP ? Round(unit, 2) " ex (" label ")" : "-") "`n"
            }
        }
    }
    else
        out .= "(no radar snapshot / not currently in an area)`n`n"

    ; Most-common discovered offset (what we'd hard-wire).
    bestOff := -1, bestCnt := 0
    for o, cnt in offCounts
        if (cnt > bestCnt)
            bestCnt := cnt, bestOff := o

    out .= "Ground wrappers: " total "   |   inner resolved: " resolved
         . "   |   priced: " priced "   |   uniques: " uniques " (priced " uniquesPriced ")`n"
    out .= "Discovered WorldItem->item offset: "
         . (bestOff >= 0 ? Format("0x{:X}", bestOff) " (" bestCnt "/" resolved " items)" : "(none)") "`n`n"
    out .= (lines != "" ? lines : "  (no ground items in range)`n")

    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        try DirCreate(outDir)
    outPath := outDir "\loot_value_diag_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try {
        FileAppend(out, outPath, "UTF-8")
        wrote := true
    }

    summary := "Ground wrappers: " total "    inner resolved: " resolved "    priced: " priced "`n"
             . "Uniques: " uniques " (priced " uniquesPriced ")    price cache: " priceCount "`n"
             . "WorldItem->item offset: " (bestOff >= 0 ? Format("0x{:X}", bestOff) : "(not found)") "`n`n"
    if (total = 0)
        summary .= "ℹ No ground items in range — stand near some loot and run again."
    else if (resolved = 0)
        summary .= "⚠ Could not resolve any inner item — the WorldItem component / offset probe missed. See the report's component list."
    else if (resolved = total)
        summary .= "✅ Resolved every ground item's inner entity — pricing path works. Send me the report and I'll wire the feature."
    else
        summary .= "⚠ Resolved " resolved "/" total " — partial. Send me the report so I can widen the probe."
    if wrote
        summary .= "`n`nFull report: " outPath

    try MsgBox(summary, "Loot Value Diagnose", 0x40)
}
