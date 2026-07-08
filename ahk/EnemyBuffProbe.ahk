; EnemyBuffProbe.ahk — RE aid (read-only)
; Dumps the NEAREST hostile monster's active buffs/curses/debuffs using the
; verified pointer-array read (ReadEntityBuffEffects, the same walk that drives
; player-buff/flask detection). Confirms enemy-side buff reads work before the
; macro engine's enemyBuff condition is trusted. Stand near an enemy (ideally a
; cursed / debuffed / enraged one) and run it.
;
; Bridge: EnemyBuffProbeRun. UI: "🩸 Probe Enemy Buffs" in the RE-tools row.
; Writes logs\InGameStateMonitor.enemy_buff_probe.log.

EnemyBuffProbeRun()
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
    {
        MsgBox("Reader not ready.", "Enemy Buff Probe")
        return
    }
    snap := g_radarLastSnap
    if !(snap && snap is Map)
    {
        MsgBox("No radar snapshot yet — get in-game first.", "Enemy Buff Probe")
        return
    }
    inGs   := snap.Has("inGameState") ? snap["inGameState"] : 0
    area   := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(sample && sample is Array && sample.Length)
    {
        MsgBox("No awake entities — stand near enemies.", "Enemy Buff Probe")
        return
    }

    bestAddr := 0, bestDist := 999999999.0, bestPath := ""
    for entry in sample
    {
        if !(entry && entry is Map)
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        path := entity.Has("path") ? StrLower(entity["path"]) : ""
        if !InStr(path, "metadata/monsters/")
            continue
        addr := entity.Has("address") ? entity["address"] : 0
        if !addr
            continue
        d := entry.Has("distance") ? (entry["distance"] + 0.0) : 999999998.0
        if (d < bestDist)
        {
            bestDist := d
            bestAddr := addr
            bestPath := entity.Has("path") ? entity["path"] : ""
        }
    }
    if !bestAddr
    {
        MsgBox("No monster in the awake sample — stand next to an enemy.", "Enemy Buff Probe")
        return
    }

    effs := 0
    try effs := g_reader.ReadEntityBuffEffects(bestAddr)
    cnt := (effs && effs is Array) ? effs.Length : 0

    out := "Enemy Buff Probe`n=================`n"
        . "nearest monster : " bestPath "`n"
        . "addr            : " Format("0x{:X}", bestAddr) "`n"
        . "distance        : " Round(bestDist) "`n"
        . "buffs read      : " cnt "`n`n"
    if (cnt > 0)
    {
        for i, eff in effs
        {
            if !(eff is Map)
                continue
            out .= i ". " (eff.Has("name") ? eff["name"] : "?")
                . "   charges=" (eff.Has("charges") ? eff["charges"] : "?")
                . "   timeLeft=" (eff.Has("timeLeft") ? Round(eff["timeLeft"], 1) : "?")
                . "   total=" (eff.Has("totalTime") ? Round(eff["totalTime"], 1) : "?")
                . "   src=" (eff.Has("sourceEntityId") ? eff["sourceEntityId"] : "?") "`n"
        }
        out .= "`nRead OK — the enemyBuff macro condition can use these names.`n"
    }
    else
    {
        out .= "(no buffs returned — the enemy may simply have none; try a cursed/"
            . "enraged/on-fire enemy. If a clearly-buffed enemy still reads 0, the`n"
            . "Buffs offsets need a look.)`n"
    }

    logPath := A_ScriptDir "\logs\InGameStateMonitor.enemy_buff_probe.log"
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "`n" out "`n", logPath)
    MsgBox(out, "Enemy Buff Probe")
}
