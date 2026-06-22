; LootTrackerKills.ahk
; Per-run monster kill tally for the LootTracker feature (ported from
; LootTrackerCore.Kills.cs). Counts monster alive->dead transitions off the radar
; snapshot, classified by rarity (0 Normal · 1 Magic · 2 Rare · 3 Unique). Polled on a
; throttle (a kill is a rare event and the awake-entity walk isn't free) and read once
; per monster: an entry already counted is skipped with a bare Map lookup.
;
; Globals (g_ltMonsterTallies / g_ltNextKillScanTick) are seeded in LoadLootTracker().
; Included by InGameStateMonitor.ahk.

; entity id -> Map("rarity", 0..3, "seenAlive", bool, "tallied", bool). Lives only for
; the active map instance (cleared on every (re)entry via _LtResetKillTally).
global g_ltMonsterTallies   := Map()
global g_ltNextKillScanTick := 0

_LtResetKillTally()
{
    global g_ltMonsterTallies
    g_ltMonsterTallies := Map()
}

; Tally monster deaths for the active run. Only runs while actively inside a map (timer
; running). Rarity is pinned the first time an entity is seen; death is taken from the
; decoded life component (isAlive). A monster must be seen alive at least once before a
; dead reading counts, so corpses present on (re)entry aren't mistaken for fresh kills.
_LtScanKills(radarSnap)
{
    global g_ltCurrent, g_ltRunStartTick, g_ltMonsterTallies, g_ltNextKillScanTick, g_ltDiagKills

    if !(g_ltCurrent && IsObject(g_ltCurrent) && g_ltRunStartTick > 0)
        return

    now := A_TickCount
    if (now < g_ltNextKillScanTick)
        return
    g_ltNextKillScanTick := now + 200

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return
    awake := area.Has("awakeEntities") ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(sample && Type(sample) = "Array")
        return

    kills := g_ltCurrent["kills"]
    seenNow := Map()
    mons := 0, monAny := 0, aliveCnt := 0, deadCnt := 0
    for _, entry in sample
    {
        if !(entry && Type(entry) = "Map" && entry.Has("entity"))
            continue
        entity := entry["entity"]
        if !(entity && Type(entity) = "Map")
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue
        if InStr(path, "Monster")
            monAny += 1
        ; Only real monsters (category "Monsters"); skips NPCs / chests / effects.
        if (ExtractMetaCategory(path) != "Monsters")
            continue
        id := entry.Has("id") ? entry["id"] : 0
        if (id = 0)
            continue
        mons += 1
        seenNow[id] := true
        dist := entry.Has("distance") ? entry["distance"] : 99999

        decoded := (entity.Has("decodedComponents") && entity["decodedComponents"]
            && Type(entity["decodedComponents"]) = "Map") ? entity["decodedComponents"] : Map()
        life := decoded.Has("life") ? decoded["life"] : 0
        alive := (life && IsObject(life) && life.Has("isAlive")) ? life["isAlive"] : true
        dead := !alive
        if dead
            deadCnt += 1
        else
            aliveCnt += 1

        if g_ltMonsterTallies.Has(id)
        {
            t := g_ltMonsterTallies[id]
            t["lastDist"] := dist
            if t["tallied"]
                continue
            if !dead
                t["seenAlive"] := true
            else if t["seenAlive"]
            {
                kills[t["rarity"] + 1] := kills[t["rarity"] + 1] + 1   ; rare: caught the dead state
                t["tallied"] := true
            }
            continue
        }

        ; First sighting: pin the rarity once (4 Unique / 5 Boss fold into the Unique slot).
        rar := ReadEntityRarityId(decoded)
        idx := (rar > 3) ? 3 : (rar < 0 ? 0 : rar)
        g_ltMonsterTallies[id] := Map("rarity", idx, "seenAlive", !dead, "tallied", false, "lastDist", dist)
    }

    ; Despawn-based kills: the radar sample almost never surfaces the brief dead state, so
    ; a monster that was seen alive and then vanished from the awake sample while close to
    ; the player was almost certainly killed. The distance gate keeps monsters that merely
    ; fell out of the awake range (as the player moved on) from being miscounted.
    despawnKills := 0
    for mid, mt in g_ltMonsterTallies
    {
        if (mt["tallied"] || !mt["seenAlive"])
            continue
        if (!seenNow.Has(mid) && mt["lastDist"] <= 100)
        {
            kills[mt["rarity"] + 1] := kills[mt["rarity"] + 1] + 1
            mt["tallied"] := true
            despawnKills += 1
        }
    }

    g_ltDiagKills := "mons=" mons " tal=" g_ltMonsterTallies.Count " alive=" aliveCnt " dead=" deadCnt " desp=" despawnKills
}
