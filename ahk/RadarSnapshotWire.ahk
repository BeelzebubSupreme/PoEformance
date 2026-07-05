; RadarSnapshotWire.ahk
; Pack / unpack for the flat radar snapshot — reader-split stage 3 (see docs/reader-split.md).
; The PERSISTENT reader process calls RadarWirePack() to serialise its awake-entity sample into the
; shared block; the MAIN app calls RadarWireUnpack() to reconstruct the exact nested-Map shape
; (`awakeEntities.sample`) so NO downstream consumer changes (safety principle 1).
;
; The record contract (which leaf fields each record carries) was derived from a full consumer audit
; of the ~21 files that read `decodedComponents` off radar sample entries — see PoefRadarProto.ahk for
; the byte layout. Notable shape decisions the audit pinned down:
;   • targetable is reconstructed as a BARE BOOL (the radar decode's shape), not a Map.
;   • life is reconstructed with BOTH the flat curHP/maxHP/isAlive/lifeCurrentPercentMax AND the nested
;     life["life"]["current"/"max"] form (EntityFocus reads the nested form; others the flat).
;   • a MINIMAL entity["components"] array holding only {name:"Targetable"|"Actor", address:…} is
;     rebuilt, because a few hot consumers walk that array to get a component ADDRESS for a live
;     re-read (CombatAutomation / ExplorationModule / HkAnimCapture / EntityFocus / PoE2MemoryReader).
;
; The inspector / Entities-browser deep fields (full `components`, `mods`, deep component dumps) are
; deliberately NOT in the record — they are not hot-path and stay on Main's own on-demand read
; (stage 4). Reconstruction fills componentCount / namedComponentCount / decodedComponentCount with a
; best-effort value so those consumers never error, but the numbers are minimal, not the full decode.
;
; Depends only on PoefRadarProto + SharedMem (a SharedMemBlock + its SeqLock). Pure functions, no
; other project deps — so the pack/unpack round-trip can be unit-tested off a synthetic buffer
; (scratchpad harness) before any in-game wiring.

; ── PACK (reader side) ─────────────────────────────────────────────────────────────────────────────
; Serialise `sample` (an array of nested-Map entries, exactly as ReadRadarSnapshot builds it) into the
; block under the seqlock. playerX/Y/Z + areaHash are small facts Main uses to gate the snapshot.
; Returns the number of records written (<= MAX_RECORDS; truncation is flagged in O_TRUNC).
RadarWirePack(blk, lock, sample, playerX, playerY, playerZ, areaHash, rawCount := -1)
{
    if (rawCount < 0)
        rawCount := (sample is Array) ? sample.Length : 0
    intern := Map()            ; frame-local path -> heap byte offset (dedup within this publish)
    cursor := 0                ; heap write cursor (relative to HEAP_OFF)
    count  := 0
    trunc  := 0

    lock.WriteBegin()
    if (sample is Array)
    {
        for _, entry in sample
        {
            if (count >= PoefRadarProto.MAX_RECORDS)
            {
                trunc := 1
                break
            }
            if !(entry is Map) || !entry.Has("entity")
                continue
            entity := entry["entity"]
            if !(entity is Map)
                continue
            if _RadarPackEntry(blk, entry, entity, count, intern, &cursor)
                count += 1
        }
    }

    ; Header (all inside the seqlock so the reader observes a consistent frame).
    frame := blk.GetU32(PoefRadarProto.O_FRAME) + 1
    blk.PutU32(PoefRadarProto.O_FRAME, frame)
    blk.PutI64(PoefRadarProto.O_AREAHASH, areaHash + 0)
    blk.PutF32(PoefRadarProto.O_PLAYERX, playerX + 0.0)
    blk.PutF32(PoefRadarProto.O_PLAYERY, playerY + 0.0)
    blk.PutF32(PoefRadarProto.O_PLAYERZ, playerZ + 0.0)
    blk.PutU32(PoefRadarProto.O_RECCOUNT, count)
    blk.PutU32(PoefRadarProto.O_HEAPLEN, cursor)
    blk.PutU32(PoefRadarProto.O_TRUNC, trunc)
    blk.PutU32(PoefRadarProto.O_RAWCOUNT, rawCount)
    lock.WriteEnd()
    return count
}

; Writes ONE record at slot `idx`. Returns true if written. Pulls every carried leaf off the nested
; maps with Has-guards so a partially-decoded entity never throws.
_RadarPackEntry(blk, entry, entity, idx, intern, &cursor)
{
    recOff := PoefRadarProto.O_RECORDS + idx * PoefRadarProto.RECORD_SIZE

    entityPtr  := entity.Has("address") ? entity["address"] : (entry.Has("entityPtr") ? entry["entityPtr"] : 0)
    rawPtr     := entry.Has("entityRawPtr") ? entry["entityRawPtr"] : 0
    id         := entry.Has("id") ? entry["id"] : (entity.Has("entityId") ? entity["entityId"] : 0)
    distance   := entry.Has("distance") ? entry["distance"] : 0
    priority   := entry.Has("priority") ? entry["priority"] : 0
    entFlags   := entity.Has("flags") ? entity["flags"] : 0
    path       := entity.Has("path") ? entity["path"] : ""

    presence  := 0
    chestBits := 0
    reaction  := 0
    worldX := 0.0, worldY := 0.0, worldZ := 0.0, terrainH := 0.0
    rarity := 0, animId := 0, curHP := 0, maxHP := 0, lifePct := 0.0
    renderAddr := 0, lifeAddr := 0, chestAddr := 0

    dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
    if (dc is Map)
    {
        ; render
        r := dc.Has("render") ? dc["render"] : 0
        if (r is Map)
        {
            presence |= PoefRadarProto.P_RENDER
            renderAddr := r.Has("address") ? r["address"] : 0
            wp := r.Has("worldPosition") ? r["worldPosition"] : 0
            if (wp is Map)
            {
                worldX := wp.Has("x") ? wp["x"] : 0.0
                worldY := wp.Has("y") ? wp["y"] : 0.0
                worldZ := wp.Has("z") ? wp["z"] : 0.0
            }
            terrainH := r.Has("terrainHeight") ? r["terrainHeight"] : 0.0
        }
        ; life
        lf := dc.Has("life") ? dc["life"] : 0
        if (lf is Map)
        {
            presence |= PoefRadarProto.P_LIFE
            lifeAddr := lf.Has("address") ? lf["address"] : 0
            if (lf.Has("isAlive") && lf["isAlive"])
                presence |= PoefRadarProto.P_LIFEALIVE
            ; curHP/maxHP come from the flat cheap-update keys, else the nested vital map.
            nested := lf.Has("life") ? lf["life"] : 0
            if (lf.Has("curHP"))
                curHP := lf["curHP"]
            else if (nested is Map && nested.Has("current"))
                curHP := nested["current"]
            if (lf.Has("maxHP"))
                maxHP := lf["maxHP"]
            else if (nested is Map && nested.Has("max"))
                maxHP := nested["max"]
            lifePct := lf.Has("lifeCurrentPercentMax") ? lf["lifeCurrentPercentMax"] : 0.0
        }
        ; positioned
        po := dc.Has("positioned") ? dc["positioned"] : 0
        if (po is Map)
        {
            presence |= PoefRadarProto.P_POSITIONED
            reaction := po.Has("reaction") ? po["reaction"] : 0
        }
        ; rarityId (bare int)
        if (dc.Has("rarityId"))
        {
            presence |= PoefRadarProto.P_RARITY
            rarity := dc["rarityId"]
        }
        ; chest
        ch := dc.Has("chest") ? dc["chest"] : 0
        if (ch is Map)
        {
            presence |= PoefRadarProto.P_CHEST
            chestAddr := ch.Has("address") ? ch["address"] : 0
            if (ch.Has("isOpened") && ch["isOpened"])
                chestBits |= PoefRadarProto.C_OPENED
            if (ch.Has("isLabelVisible") && ch["isLabelVisible"])
                chestBits |= PoefRadarProto.C_LABELVIS
            if (ch.Has("isStrongbox") && ch["isStrongbox"])
                chestBits |= PoefRadarProto.C_STRONGBOX
        }
        ; targetable — radar decode is a BARE BOOL; be defensive about a Map form too.
        if (dc.Has("targetable"))
        {
            presence |= PoefRadarProto.P_TARGETABLE
            tv := dc["targetable"]
            tval := (tv is Map) ? (tv.Has("isTargetable") && tv["isTargetable"]) : (tv ? true : false)
            if (tval)
                presence |= PoefRadarProto.P_TGTVAL
        }
        ; actor
        ac := dc.Has("actor") ? dc["actor"] : 0
        if (ac is Map)
        {
            presence |= PoefRadarProto.P_ACTOR
            animId := ac.Has("animationId") ? ac["animationId"] : 0
        }
    }

    ; Component addresses for LIVE re-reads come from the raw components array, not decodedComponents
    ; (the cheap-update actor map carries no address; consumers walk components for Targetable/Actor).
    comps := entity.Has("components") ? entity["components"] : 0
    tgtAddr := _RadarFindCompAddr(comps, "Targetable")
    actAddr := _RadarFindCompAddr(comps, "Actor")

    pathIdx := _RadarInternPath(blk, path, intern, &cursor)

    blk.PutI64(recOff + PoefRadarProto.R_ENTPTR,   entityPtr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_RAWPTR,   rawPtr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_TGTADDR,  tgtAddr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_ACTADDR,  actAddr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_RENDADDR, renderAddr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_LIFEADDR, lifeAddr + 0)
    blk.PutI64(recOff + PoefRadarProto.R_CHESTADDR, chestAddr + 0)
    blk.PutU32(recOff + PoefRadarProto.R_ID,       id + 0)
    blk.PutU32(recOff + PoefRadarProto.R_PATHIDX,  pathIdx)
    blk.PutF32(recOff + PoefRadarProto.R_DISTANCE, distance + 0.0)
    blk.PutI32(recOff + PoefRadarProto.R_PRIORITY, priority + 0)
    blk.PutF32(recOff + PoefRadarProto.R_WORLDX,   worldX + 0.0)
    blk.PutF32(recOff + PoefRadarProto.R_WORLDY,   worldY + 0.0)
    blk.PutF32(recOff + PoefRadarProto.R_WORLDZ,   worldZ + 0.0)
    blk.PutF32(recOff + PoefRadarProto.R_TERRAINH, terrainH + 0.0)
    blk.PutI32(recOff + PoefRadarProto.R_RARITY,   rarity + 0)
    blk.PutI32(recOff + PoefRadarProto.R_ANIMID,   animId + 0)
    blk.PutI32(recOff + PoefRadarProto.R_CURHP,    curHP + 0)
    blk.PutI32(recOff + PoefRadarProto.R_MAXHP,    maxHP + 0)
    blk.PutF32(recOff + PoefRadarProto.R_LIFEPCT,  lifePct + 0.0)
    blk.PutU32(recOff + PoefRadarProto.R_PRESENCE, presence)
    blk.PutU8(recOff + PoefRadarProto.R_ENTFLAGS,  entFlags & 0xFF)
    blk.PutU8(recOff + PoefRadarProto.R_REACTION,  reaction & 0xFF)
    blk.PutU8(recOff + PoefRadarProto.R_CHESTBITS, chestBits & 0xFF)
    return true
}

; Walks a components array for the first entry whose name matches `name` (substring or exact, like the
; live consumers) and returns its address, else 0.
_RadarFindCompAddr(comps, name)
{
    if !(comps is Array)
        return 0
    for _, comp in comps
    {
        if !(comp is Map) || !comp.Has("name") || !comp.Has("address")
            continue
        cn := comp["name"]
        if (cn = name || InStr(cn, name))
            return comp["address"]
    }
    return 0
}

; Interns a path into the heap (frame-local dedup). Stores u16 byte-length (incl. null) then the
; null-terminated UTF-8 bytes; returns the heap byte offset, or the 0xFFFFFFFF sentinel for the empty
; string / heap overflow (unpack maps the sentinel back to "").
_RadarInternPath(blk, path, intern, &cursor)
{
    if (path = "")
        return 0xFFFFFFFF
    if intern.Has(path)
        return intern[path]

    needed := StrPut(path, "UTF-8")            ; bytes incl. null terminator
    if (cursor + 2 + needed > PoefRadarProto.HEAP_BYTES)
        return 0xFFFFFFFF                       ; heap full (rare; paths are bounded per area)

    tmp := Buffer(needed)
    StrPut(path, tmp, "UTF-8")
    absOff := PoefRadarProto.HEAP_OFF + cursor
    blk.PutU16(absOff, needed)
    blk.PutBytes(absOff + 2, tmp.Ptr, needed)

    thisOff := cursor
    cursor += 2 + needed
    intern[path] := thisOff
    return thisOff
}

; ── UNPACK (main side) ─────────────────────────────────────────────────────────────────────────────
; Copies the block out under the seqlock, then rebuilds the awake sample. Returns a Map:
;   Map("ok", true, "frame", .., "areaHash", .., "playerX/Y/Z", .., "truncated", .., "sample", [entries])
; or Map("ok", false) if the seqlock could not stabilise (writer mid-write) — Main then reuses its last
; snapshot (staleness, never a torn read).
RadarWireUnpack(blk, lock)
{
    buf := lock.Read(() => _RadarCopyBlock(blk))
    if (buf = "")
        return Map("ok", false)

    p := buf.Ptr
    ; Wire-version guard: a stale reader from before an update must be refused.
    if (NumGet(p + PoefRadarProto.O_MAGIC, "UInt") != PoefRadarProto.MAGIC
        || NumGet(p + PoefRadarProto.O_VERSION, "UInt") != PoefRadarProto.VERSION)
        return Map("ok", false)

    count := NumGet(p + PoefRadarProto.O_RECCOUNT, "UInt")
    if (count > PoefRadarProto.MAX_RECORDS)
        count := PoefRadarProto.MAX_RECORDS

    sample := []
    idx := 0
    while (idx < count)
    {
        entry := _RadarUnpackEntry(p, idx)
        if (entry)
            sample.Push(entry)
        idx += 1
    }

    return Map(
        "ok", true,
        "frame", NumGet(p + PoefRadarProto.O_FRAME, "UInt"),
        "areaHash", NumGet(p + PoefRadarProto.O_AREAHASH, "Int64"),
        "playerX", NumGet(p + PoefRadarProto.O_PLAYERX, "Float"),
        "playerY", NumGet(p + PoefRadarProto.O_PLAYERY, "Float"),
        "playerZ", NumGet(p + PoefRadarProto.O_PLAYERZ, "Float"),
        "truncated", NumGet(p + PoefRadarProto.O_TRUNC, "UInt"),
        "rawCount", NumGet(p + PoefRadarProto.O_RAWCOUNT, "UInt"),
        "sample", sample)
}

; Copies the whole block into a stable Buffer (the seqlock retry re-runs THIS only; the expensive
; Map rebuild happens after Read() returns, off the retry path).
_RadarCopyBlock(blk)
{
    buf := Buffer(blk.size)
    blk.GetBytes(0, buf.Ptr, blk.size)
    return buf
}

; Rebuilds ONE nested-Map sample entry from record slot `idx` in the copied block at pointer `p`.
_RadarUnpackEntry(p, idx)
{
    recOff := PoefRadarProto.O_RECORDS + idx * PoefRadarProto.RECORD_SIZE
    presence := NumGet(p + recOff + PoefRadarProto.R_PRESENCE, "UInt")

    entityPtr := NumGet(p + recOff + PoefRadarProto.R_ENTPTR, "Int64")
    rawPtr    := NumGet(p + recOff + PoefRadarProto.R_RAWPTR, "Int64")
    id        := NumGet(p + recOff + PoefRadarProto.R_ID, "UInt")
    distance  := NumGet(p + recOff + PoefRadarProto.R_DISTANCE, "Float")
    priority  := NumGet(p + recOff + PoefRadarProto.R_PRIORITY, "Int")
    entFlags  := NumGet(p + recOff + PoefRadarProto.R_ENTFLAGS, "UChar")
    pathIdx   := NumGet(p + recOff + PoefRadarProto.R_PATHIDX, "UInt")
    path      := _RadarReadPath(p, pathIdx)

    dc := Map()

    if (presence & PoefRadarProto.P_RENDER)
    {
        worldX := NumGet(p + recOff + PoefRadarProto.R_WORLDX, "Float")
        worldY := NumGet(p + recOff + PoefRadarProto.R_WORLDY, "Float")
        worldZ := NumGet(p + recOff + PoefRadarProto.R_WORLDZ, "Float")
        terrainH := NumGet(p + recOff + PoefRadarProto.R_TERRAINH, "Float")
        worldToGridRatio := 250.0 / 0x17
        dc["render"] := Map(
            "address", NumGet(p + recOff + PoefRadarProto.R_RENDADDR, "Int64"),
            "worldPosition", Map("x", worldX, "y", worldY, "z", worldZ),
            "gridPosition", Map("x", worldX / worldToGridRatio, "y", worldY / worldToGridRatio),
            "terrainHeight", terrainH)
    }

    if (presence & PoefRadarProto.P_LIFE)
    {
        curHP := NumGet(p + recOff + PoefRadarProto.R_CURHP, "Int")
        maxHP := NumGet(p + recOff + PoefRadarProto.R_MAXHP, "Int")
        dc["life"] := Map(
            "address", NumGet(p + recOff + PoefRadarProto.R_LIFEADDR, "Int64"),
            "isAlive", (presence & PoefRadarProto.P_LIFEALIVE) ? true : false,
            "lifeCurrentPercentMax", NumGet(p + recOff + PoefRadarProto.R_LIFEPCT, "Float"),
            "curHP", curHP,
            "maxHP", maxHP,
            "life", Map("current", curHP, "max", maxHP))
    }

    if (presence & PoefRadarProto.P_POSITIONED)
    {
        reaction := NumGet(p + recOff + PoefRadarProto.R_REACTION, "UChar")
        dc["positioned"] := Map("reaction", reaction, "isFriendly", (reaction & 0x7F) = 0x01 ? true : false)
    }

    if (presence & PoefRadarProto.P_RARITY)
        dc["rarityId"] := NumGet(p + recOff + PoefRadarProto.R_RARITY, "Int")

    if (presence & PoefRadarProto.P_CHEST)
    {
        cb := NumGet(p + recOff + PoefRadarProto.R_CHESTBITS, "UChar")
        dc["chest"] := Map(
            "address", NumGet(p + recOff + PoefRadarProto.R_CHESTADDR, "Int64"),
            "isOpened", (cb & PoefRadarProto.C_OPENED) ? true : false,
            "isLabelVisible", (cb & PoefRadarProto.C_LABELVIS) ? true : false,
            "isStrongbox", (cb & PoefRadarProto.C_STRONGBOX) ? true : false)
    }

    if (presence & PoefRadarProto.P_TARGETABLE)
        dc["targetable"] := (presence & PoefRadarProto.P_TGTVAL) ? true : false

    if (presence & PoefRadarProto.P_ACTOR)
        dc["actor"] := Map("animationId", NumGet(p + recOff + PoefRadarProto.R_ANIMID, "Int"))

    ; Minimal components array for the live-re-read consumers (Targetable / Actor by name → address).
    components := []
    tgtAddr := NumGet(p + recOff + PoefRadarProto.R_TGTADDR, "Int64")
    actAddr := NumGet(p + recOff + PoefRadarProto.R_ACTADDR, "Int64")
    if (tgtAddr != 0)
        components.Push(Map("name", "Targetable", "address", tgtAddr))
    if (actAddr != 0)
        components.Push(Map("name", "Actor", "address", actAddr))

    entity := Map(
        "address", entityPtr,
        "entityId", id,
        "flags", entFlags,
        "isValid", (entFlags & 0x01) = 0 ? true : false,
        "path", path,
        "components", components,
        "decodedComponents", dc,
        "componentCount", components.Length,
        "namedComponentCount", components.Length,
        "decodedComponentCount", dc.Count)

    return Map(
        "id", id,
        "entityPtr", entityPtr,
        "entityRawPtr", rawPtr,
        "distance", distance,
        "priority", priority,
        "entity", entity)
}

; Reads an interned path back out of the copied block (null-terminated UTF-8 at HEAP_OFF + pathIdx).
_RadarReadPath(p, pathIdx)
{
    if (pathIdx = 0xFFFFFFFF)
        return ""
    absOff := PoefRadarProto.HEAP_OFF + pathIdx
    byteLen := NumGet(p + absOff, "UShort")
    if (byteLen <= 1)
        return ""
    return StrGet(p + absOff + 2, "UTF-8")
}
