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
    ; Compare by character code (Ord) — a string vs numeric-literal comparison throws
    ; "Expected a Number but got a String" in AHK v2 when head isn't a digit.
    hc := (StrLen(head) = 1) ? Ord(head) : -1
    r := (hc >= 48 && hc <= 51) ? (hc - 48) : 0   ; '0'..'3'
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
    global g_reader
    snap := Map()

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

        ; Read ONLY MainInventory1 (id 1): walk the PlayerInventories vector to its
        ; pointer and decode just that one inventory — NOT ReadAllPlayerInventories,
        ; which also reads every stash tab and resolves their names (far too heavy for a
        ; per-500 ms hot-path diff). Mirrors the C# original's direct backpack read.
        pdVecFirst := g_reader.Mem.ReadInt64(sdPtr + PoE2Offsets.ServerData["PlayerServerData"])
        if (pdVecFirst <= 0)
            return false
        playerDataPtr := g_reader.Mem.ReadPtr(pdVecFirst)
        if !g_reader.IsProbablyValidPointer(playerDataPtr)
            return false
        invFirst := g_reader.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventories"])
        invLast  := g_reader.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventoriesLast"])
        if (invFirst <= 0 || invLast < invFirst)
            return false
        entrySize := PoE2Offsets.InventoryArray["EntrySize"]
        invCount := Min(Floor((invLast - invFirst) / entrySize), 128)
        backpackPtr := 0
        idx := 0
        while (idx < invCount)
        {
            entryAddr := invFirst + (idx * entrySize)
            if (g_reader.Mem.ReadInt(entryAddr + PoE2Offsets.InventoryArray["InventoryId"]) = 1)
            {
                backpackPtr := g_reader.Mem.ReadPtr(entryAddr + PoE2Offsets.InventoryArray["InventoryPtr0"])
                break
            }
            idx += 1
        }
        if !g_reader.IsProbablyValidPointer(backpackPtr)
            return false   ; backpack not resolvable this frame

        backpack := g_reader._ReadInventoryWithItems(backpackPtr)
        if !(backpack && IsObject(backpack) && backpack.Has("items"))
            return true   ; backpack present but empty is still a valid (empty) read

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
