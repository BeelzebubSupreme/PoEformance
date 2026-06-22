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
    g_ltNextKillScanTick := now + 150

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return
    awake := area.Has("awakeEntities") ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(sample && Type(sample) = "Array")
        return

    kills := g_ltCurrent["kills"]
    mons := 0, deadCnt := 0
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
        ; Only real monsters (category "Monsters"); skips NPCs / chests / effects.
        if (ExtractMetaCategory(path) != "Monsters")
            continue
        id := entry.Has("id") ? entry["id"] : 0
        if (id = 0)
            continue
        mons += 1

        decoded := (entity.Has("decodedComponents") && entity["decodedComponents"]
            && Type(entity["decodedComponents"]) = "Map") ? entity["decodedComponents"] : Map()
        ; Death signal: a monster's HP can read stale > 0 for a moment after death, so the
        ; reliable flag is IsTargetable going to 0 — exactly what SnapshotSerializers uses
        ; for Enemy/Boss. Fall back to life.isAlive when targetable isn't decoded.
        life := decoded.Has("life") ? decoded["life"] : 0
        alive := (life && IsObject(life) && life.Has("isAlive")) ? life["isAlive"] : true
        if (decoded.Has("targetable"))
            alive := decoded["targetable"] ? true : false
        dead := !alive
        if dead
            deadCnt += 1

        if g_ltMonsterTallies.Has(id)
        {
            t := g_ltMonsterTallies[id]
            ; Upgrade the pinned rarity if the monster was first seen before its rarity
            ; component finished decoding (otherwise every kill counts as Normal).
            if (t["rarity"] = 0)
            {
                r2 := ReadEntityRarityId(decoded)
                if (r2 > 0)
                    t["rarity"] := (r2 > 3) ? 3 : r2
            }
            if t["tallied"]
                continue
            if !dead
                t["seenAlive"] := true
            else if t["seenAlive"]
            {
                kills[t["rarity"] + 1] := kills[t["rarity"] + 1] + 1
                t["tallied"] := true
            }
            continue
        }

        ; First sighting: pin the rarity (4 Unique / 5 Boss fold into the Unique slot).
        rar := ReadEntityRarityId(decoded)
        idx := (rar > 3) ? 3 : (rar < 0 ? 0 : rar)
        g_ltMonsterTallies[id] := Map("rarity", idx, "seenAlive", !dead, "tallied", false)
    }

    g_ltDiagKills := "mons=" mons " tal=" g_ltMonsterTallies.Count " dead=" deadCnt
}
