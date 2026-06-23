; LootRadarValue.ahk
; Value-aware loot radar — STEP 0: reverse-engineering verification.
;
; Goal of the feature (later): price ground loot via the existing poe.ninja layer and
; paint the value on the radar + a "valuable nearby" list + a threshold alert.
;
; The one open RE question is whether we can read a GROUND item's rendered art id (the
; key poe.ninja uses to price UNIQUES). Strong evidence says yes WITHOUT any new memory
; offset: ground items in PoE2 are full item-bearing entities (PoE2EntityReader reads
; their Mods/ObjectMagicProperties rarity directly), and ReadItemArtPath() resolves the
; RenderItem component BY NAME (offset-agnostic) — the same call the inventory uses. So
; calling g_reader.ReadItemArtPath(groundEntityAddr) should return "Art/2DItems/….dds".
;
; This module ships only the diagnostic that confirms that in-game. Once verified, the
; full pricing/label/overlay/alert layer is built on top, reusing _LrvPriceGround().
;
; Included by InGameStateMonitor.ahk.

; Prices one ground item by entity address. Reads its rendered art id via the existing
; offset-agnostic ReadItemArtPath(), builds the LootTracker item key and resolves the
; poe.ninja unit price. ByRef outputs: dds (raw art path), renderArt (art id), unit
; (Exalted), label (display). Returns true when a price was found.
_LrvPriceGround(addr, path, rarityId, &dds, &renderArt, &unit, &label)
{
    global g_reader
    dds := "", renderArt := "", unit := 0.0, label := ""
    if (IsObject(g_reader) && addr)
    {
        try dds := g_reader.ReadItemArtPath(addr)
        renderArt := _LtArtIdFromDds(dds . "")
    }
    return _LtTryPriceItem(_LtBuildItemKey(rarityId, path, renderArt), &unit, &label)
}

; RE-verification diagnostic. Walks the cached radar snapshot for ground items and
; reports, per item, path / rarity / entity address / rendered art / resolved price.
; The decisive question: does ReadItemArtPath() return a real art id for a UNIQUE on
; the ground (rarity 3/4)? If every ground unique resolves one, uniques are priceable
; with no extra reverse-engineering. Writes a full report to debug\ and shows a summary.
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

    total := 0, uniques := 0, uniquesWithArt := 0, priced := 0
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
            decoded  := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
            rarityId := (decoded && IsObject(decoded) && decoded.Has("rarityId")) ? decoded["rarityId"] : 0
            addr     := entity.Has("address") ? entity["address"] : 0

            dds := "", renderArt := "", unit := 0.0, label := ""
            isP := _LrvPriceGround(addr, path, rarityId, &dds, &renderArt, &unit, &label)

            total += 1
            if (rarityId = 3 || rarityId = 4)
            {
                uniques += 1
                if (renderArt != "")
                    uniquesWithArt += 1
            }
            if isP
                priced += 1

            if (total <= 30)
            {
                lines .= "  r" rarityId "  " path "`n"
                lines .= "        addr=" (addr ? Format("0x{:X}", addr) : "0")
                       . "  art=" (renderArt != "" ? renderArt : "-")
                       . "  price=" (isP ? Round(unit, 2) " ex (" label ")" : "-") "`n"
                if (dds != "")
                    lines .= "        dds=" dds "`n"
            }
        }
    }
    else
        out .= "(no radar snapshot / not currently in an area)`n`n"

    out .= "Ground items seen: " total "   |   uniques: " uniques
         . " (with art id: " uniquesWithArt ")   |   priced: " priced "`n`n"
    out .= (lines != "" ? lines : "  (no ground items in range)`n")

    ; Full report to debug\ (the MsgBox truncates long lists); short summary in the box.
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        try DirCreate(outDir)
    outPath := outDir "\loot_value_diag_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try {
        FileAppend(out, outPath, "UTF-8")
        wrote := true
    }

    summary := "Ground items: " total "    uniques: " uniques " (art: " uniquesWithArt ")    priced: " priced "`n"
             . "Price cache: " priceCount " entries`n`n"
    if (uniques = 0)
        summary .= "ℹ No uniques on the ground right now — drop/find a unique and run again."
    else if (uniquesWithArt = uniques)
        summary .= "✅ Every ground unique resolved an art id — uniques are priceable with NO extra RE."
    else
        summary .= "⚠ Some ground uniques had NO art id (ReadItemArtPath failed) — needs a closer look."
    if wrote
        summary .= "`n`nFull report: " outPath

    try MsgBox(summary, "Loot Value Diagnose", 0x40)
}
