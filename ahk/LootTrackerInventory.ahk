; LootTrackerInventory.ahk
; Inventory snapshot + delta helpers for the LootTracker feature. Reuses the existing
; PoEformance inventory reader (ReadAllPlayerInventories) instead of re-reading memory:
; the per-item facts (metadataPath, rarityId, stackCount, artPath) are already decoded.
; A snapshot is an aggregated Map(itemKey -> total count) of the main backpack
; (inventoryId == 1); the loot of a map run is the diff of two snapshots.
;
; Item keys carry the rarity digit + path (+ the unique's rendered art id) so a Normal
; tablet stays distinct from a Rare one (poe.ninja prices them very differently under
; one shared icon). Ported from LootTrackerCore.Inventory.cs.
; Included by InGameStateMonitor.ahk.

; Composite key field separator: US (0x1F) — a control char, so user paths can never
; collide with it. Kept as a function-local (NOT a module global) because top-level
; initializers in #Include'd-after-return modules never run (AHK v2 init gotcha).

; Composite key: rarity digit + metadata path (+ rendered art id for uniques).
; Stackable currency is always Normal -> "0<sep><path>".
_LtBuildItemKey(rarity, path, renderArt)
{
    sep := Chr(31)
    d := Chr(48 + (rarity & 3))
    if (renderArt = "")
        return d sep path
    return d sep path sep renderArt
}

; Splits an item key back into [rarity(int), path, renderArt]. A key without the
; separator (shouldn't happen) is treated as Normal.
_LtSplitItemKey(key)
{
    us := Chr(31)
    sep := InStr(key, us)
    if (sep < 1)
        return [0, key, ""]
    head := SubStr(key, 1, sep - 1)
    r := (StrLen(head) = 1 && head >= "0" && head <= "3") ? (Ord(head) - 48) : 0
    rest := SubStr(key, sep + 1)
    sep2 := InStr(rest, us)
    if (sep2 < 1)
        return [r, rest, ""]
    return [r, SubStr(rest, 1, sep2 - 1), SubStr(rest, sep2 + 1)]
}

; "Art/2DItems/.../PrecursorTabletDeliriumUnique1.dds" -> "PrecursorTabletDeliriumUnique1"
; (the language-independent art id poe.ninja keys uniques by). "" for an empty/odd path.
_LtArtIdFromDds(ddsPath)
{
    if (ddsPath = "")
        return ""
    seg := _LtLastSegment(ddsPath)
    dot := InStr(seg, ".", false, -1)
    return (dot > 1) ? SubStr(seg, 1, dot - 1) : seg
}

; Aggregated main-inventory (backpack, inventoryId == 1) contents as
; Map(itemKey -> total count). ByRef snap is filled; returns false if unreadable
; (loading screen / no server data), in which case snap is left empty.
_LtSnapshotInventory(radarSnap, &snap)
{
    global g_reader, g_ltDiagBp, g_ltDiagInv, g_ltDiagCalls
    snap := Map()
    g_ltDiagBp := -1   ; assume read failed until proven otherwise (diagnostic)
    g_ltDiagCalls += 1

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return false
    if !(radarSnap && Type(radarSnap) = "Map")
        return false

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return false
    areaAddr := area.Has("address") ? area["address"] : 0
    if !areaAddr
        return false

    try
    {
        ; Same chain WebViewBridge / LootPickup use to reach the inventories.
        playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        sdPtr            := g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
        if !sdPtr
            return false

        invs := g_reader.ReadAllPlayerInventories(sdPtr)
        if !(invs && Type(invs) = "Array")
            return false

        ; Diagnostic: summarize every inventory (id(gridXxY)=rawItemCount) so we can see
        ; which id is the live backpack and whether the read reflects changes.
        dbg := ""
        for _, iv in invs
        {
            if !(iv && IsObject(iv) && iv.Has("inventoryId"))
                continue
            ic := (iv.Has("items") && Type(iv["items"]) = "Array") ? iv["items"].Length : 0
            gx := iv.Has("totalBoxesX") ? iv["totalBoxesX"] : 0
            gy := iv.Has("totalBoxesY") ? iv["totalBoxesY"] : 0
            dbg .= (dbg = "" ? "" : " ") "id" iv["inventoryId"] "(" gx "x" gy ")=" ic
        }
        g_ltDiagInv := dbg

        backpack := 0
        for _, inv in invs
        {
            if (inv && IsObject(inv) && inv.Has("inventoryId") && inv["inventoryId"] = 1)
            {
                backpack := inv
                break
            }
        }
        if !(backpack && IsObject(backpack) && backpack.Has("items"))
        {
            g_ltDiagBp := 0
            return true   ; backpack present but empty is still a valid (empty) read
        }

        ; The reader returns one entry PER occupied slot, so a multi-cell item appears
        ; multiple times — dedupe by item entity pointer before counting.
        seen := Map()
        for _, item in backpack["items"]
        {
            if !(item && IsObject(item))
                continue
            iep := item.Has("itemEntityPtr") ? item["itemEntityPtr"] : 0
            if (iep = 0 || seen.Has(iep))
                continue
            seen[iep] := true

            det := item.Has("details") ? item["details"] : 0
            if !(det && IsObject(det))
                continue
            path := det.Has("metadataPath") ? det["metadataPath"] : ""
            if (path = "")
                continue
            rarity := det.Has("rarityId") ? (det["rarityId"] + 0) : 0
            if (rarity < 0 || rarity > 3)
                rarity := (rarity >= 3) ? 3 : 0
            stack := det.Has("stackCount") ? (det["stackCount"] + 0) : 1
            if (stack <= 0)
                stack := 1
            renderArt := (rarity = 3 && det.Has("artPath")) ? _LtArtIdFromDds(det["artPath"]) : ""

            key := _LtBuildItemKey(rarity, path, renderArt)
            snap[key] := (snap.Has(key) ? snap[key] : 0) + stack
        }
        g_ltDiagBp := snap.Count
        return true
    }
    catch
        return false
}

; now - baseline, per item key; only non-zero deltas are kept.
_LtDiff(now, baseline)
{
    d := Map()
    for k, v in now
    {
        b := baseline.Has(k) ? baseline[k] : 0
        delta := v - b
        if (delta != 0)
            d[k] := delta
    }
    for k, v in baseline
    {
        if !now.Has(k)
            d[k] := -v
    }
    return d
}

; acc += delta, dropping keys that reach zero.
_LtMergeInto(acc, delta)
{
    for k, v in delta
    {
        nv := (acc.Has(k) ? acc[k] : 0) + v
        if (nv = 0)
            acc.Delete(k)
        else
            acc[k] := nv
    }
}

; Exalted value of a net delta: sum of Δcount * unit price. Items poe.ninja doesn't
; price contribute 0. ByRef priced/unpriced report how many distinct keys resolved.
_LtValueOf(delta, &priced, &unpriced)
{
    priced := 0
    unpriced := 0
    sum := 0.0
    for k, v in delta
    {
        if (v = 0)
            continue
        unit := 0.0, label := ""
        if _LtTryPriceItem(k, &unit, &label)
        {
            sum += unit * v
            priced += 1
        }
        else
            unpriced += 1
    }
    return sum
}
