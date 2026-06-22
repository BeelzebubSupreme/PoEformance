; LootTrackerKills.ahk
; Per-run monster kill tally for the LootTracker feature (ported from
; LootTrackerCore.Kills.cs). Kills are NOT derived from the live radar sample: the radar
; reader filters dead entities OUT of the sample before LootTracker ever sees it (corpses
; must not show on the radar), so a monster's death is never observable there. Instead we
; mirror the reader's own per-area death tally (g_reader._radarKillsByRarity), populated
; by its proven multi-signal dead-entity detection in _FilterStaleRadarEntities. That
; counter resets on every area change, so we accumulate per-area DELTAS into the run total.
;
; Globals (g_ltKillLastR / g_ltNextKillScanTick) are seeded in LoadLootTracker().
; Included by InGameStateMonitor.ahk.

; Last per-rarity reading of the reader's tally, used to turn its area-resetting
; cumulative counter into per-run deltas. Reset to zero on every zone transition (matching
; the reader's own reset) so each new area's kills are counted from scratch.
global g_ltKillLastR        := [0, 0, 0, 0]
global g_ltNextKillScanTick := 0

; Resets the kill-delta baseline. Called on every zone transition and on session reset.
_LtResetKillTally()
{
    global g_ltKillLastR
    g_ltKillLastR := [0, 0, 0, 0]
}

; Accumulate monster kills for the active run from the radar reader's per-area tally.
; Only runs while actively inside a map (timer running). Each scan adds the change in
; g_reader._radarKillsByRarity since the last reading; if any slot dropped below the last
; reading the reader reset on an area change, so the whole current reading is taken as new.
_LtScanKills(radarSnap)
{
    global g_reader, g_ltCurrent, g_ltRunStartTick, g_ltKillLastR, g_ltNextKillScanTick, g_ltDiagKills

    if !(g_ltCurrent && IsObject(g_ltCurrent) && g_ltRunStartTick > 0)
        return
    if !(IsObject(g_reader) && g_reader.HasProp("_radarKillsByRarity"))
        return

    now := A_TickCount
    if (now < g_ltNextKillScanTick)
        return
    g_ltNextKillScanTick := now + 150

    cur := g_reader._radarKillsByRarity
    if !(cur && Type(cur) = "Array" && cur.Length >= 4)
        return
    if !(g_ltKillLastR && Type(g_ltKillLastR) = "Array" && g_ltKillLastR.Length >= 4)
        g_ltKillLastR := [0, 0, 0, 0]

    ; Detect a reader reset between scans (area changed): any slot below the last reading
    ; means the cumulative counter restarted, so the whole current reading is new kills.
    reset := false
    i := 1
    while (i <= 4)
    {
        if (cur[i] < g_ltKillLastR[i])
        {
            reset := true
            break
        }
        i += 1
    }

    if !(g_ltCurrent.Has("kills") && Type(g_ltCurrent["kills"]) = "Array" && g_ltCurrent["kills"].Length >= 4)
        g_ltCurrent["kills"] := [0, 0, 0, 0]
    kills := g_ltCurrent["kills"]
    i := 1
    while (i <= 4)
    {
        delta := reset ? cur[i] : (cur[i] - g_ltKillLastR[i])
        if (delta > 0)
            kills[i] += delta
        g_ltKillLastR[i] := cur[i]
        i += 1
    }

    g_ltDiagKills := "N" kills[1] " M" kills[2] " R" kills[3] " U" kills[4] " r=" cur[1] "/" cur[2] "/" cur[3] "/" cur[4]
}
