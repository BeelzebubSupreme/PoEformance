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

    ; Probe the WorldItem component for a pointer to the inner item entity. The item
    ; entity is identified by a "Metadata/Items/…" path (strong, unambiguous filter).
    o := 0x08
    while (o <= 0xA0)
    {
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
