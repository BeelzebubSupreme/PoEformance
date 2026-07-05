; ActorProbe.ahk
; TEMPORARY in-game diagnostic — NOT part of the per-frame hot path.
;
; The Actor component's animationId (offset PoE2Offsets.Actor["AnimationId"], the
; current 0x8A0) stopped tracking the character's actions after a game patch —
; the value reads a plausible-but-frozen number, the classic sign of an offset
; drift (same class as the W2S-matrix -8 and the AreaInstance +0x18 drifts).
;
; This probe TIME-SAMPLES a wide int32 window from the local player's Actor
; component base over a few seconds while the user moves / casts, then reports
; which 4-byte offsets CHANGED. The animationId is the offset whose value cycles
; through small ints (0 = Idle, 4 = Run, plus skill CastType ids) as the
; character acts — so the changing offset in the low-integer band IS the new
; animationId location.
;
; Reuses _AIP_ResolveAreaInstance + _AIP_WriteProbeLog (AreaInstanceProbe.ahk)
; and the reader's component lookup. Trigger from Config → Debug → Diagnostic
; Actions ("🎭 Probe Actor"). Included by InGameStateMonitor.ahk.

; Resolves the local player entity pointer from the AreaInstance, mirroring
; ComponentProbeRun. Returns the entity pointer (0 if not in-game / unresolved).
_ActorProbeLocalPlayer()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
        return 0
    piOff := PoE2Offsets.AreaInstance["PlayerInfo"]
    lpRaw := g_reader.Mem.ReadPtr(base + piOff + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
    return g_reader.ResolveEntityPointer(lpRaw)
}

; Actor offset-drift probe. Samples a WINSIZE int32 window at the Actor base
; ~SAMPLES times over ~(SAMPLES*INTERVAL) ms while the user acts, tracks the
; distinct values per offset, and reports the changing offsets (animationId
; candidates first). No params, no return; writes a log + summary MsgBox.
ActorProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Actor probe: not connected to PoE2.", "Actor Probe", "Iconx")
        return
    }
    reader := g_reader

    localPlayer := _ActorProbeLocalPlayer()
    if !(localPlayer && reader.IsPlausibleEntityPointer(localPlayer))
    {
        try MsgBox("Actor probe: could not resolve the local player (be in-game, let the radar run a moment).", "Actor Probe", "Iconx")
        return
    }

    actorAddr := 0
    try actorAddr := reader.FindEntityComponentAddress(localPlayer, "Actor")
    if !(actorAddr && reader.IsProbablyValidPointer(actorAddr))
    {
        try MsgBox("Actor probe: the player has no resolvable Actor component (component lookup drifted?).", "Actor Probe", "Iconx")
        return
    }

    animOff := PoE2Offsets.Actor["AnimationId"]   ; the current (suspect) offset

    ; Let the user control the sampling window: they click OK, then act for the
    ; duration so the animation actually changes while we sample.
    SAMPLES  := 60
    INTERVAL := 80                                ; ms  → ~4.8 s total
    WINSIZE  := 0x1000                            ; 4 KB → offsets 0x000..0xFFC
    secs := Round(SAMPLES * INTERVAL / 1000, 1)
    pre := "Actor probe ready.`r`n`r`n"
        . "localPlayer=0x" Format("{:X}", localPlayer) "`r`n"
        . "Actor=0x" Format("{:X}", actorAddr) "  (current animId offset +0x" Format("{:X}", animOff) ")`r`n`r`n"
        . "After you click OK, RUN AROUND and CAST several different skills for ~" secs " s.`r`n"
        . "The probe samples the whole Actor struct and finds which offset tracks the animation."
    res := "OK"
    try res := MsgBox(pre, "Actor Probe", "OKCancel Iconi")
    if (res = "Cancel")
        return

    ; Per-offset distinct-value tracking. distinct[off] = Map(value -> hitCount);
    ; order[off] = the distinct values in first-seen order (display, capped).
    distinct := Map()
    order := Map()
    reads := 0
    Loop SAMPLES
    {
        buf := reader.Mem.ReadBytes(actorAddr, WINSIZE, true)
        if buf
        {
            reads += 1
            off := 0
            while (off + 4 <= buf.Size)
            {
                v := NumGet(buf.Ptr, off, "Int")
                if !distinct.Has(off)
                {
                    distinct[off] := Map()
                    order[off] := []
                }
                dm := distinct[off]
                if !dm.Has(v)
                {
                    dm[v] := 0
                    if (order[off].Length < 20)
                        order[off].Push(v)
                }
                dm[v] += 1
                off += 4
            }
        }
        Sleep INTERVAL
    }

    if (reads = 0)
    {
        try MsgBox("Actor probe: every memory read failed (Actor pointer went stale?).", "Actor Probe", "Iconx")
        return
    }

    ; ── Build the report ─────────────────────────────────────────────────────
    nl := "`r`n"
    rpt := "=== Actor offset-drift probe ===" nl
    rpt .= "localPlayer=0x" Format("{:X}", localPlayer) "  Actor=0x" Format("{:X}", actorAddr) nl
    rpt .= "samples=" reads "/" SAMPLES "  interval=" INTERVAL "ms  window=0x" Format("{:X}", WINSIZE) nl
    rpt .= "current animId offset = +0x" Format("{:X}", animOff) nl nl

    ; The known/suspect animationId offset — did it move at all?
    rpt .= "-- current animId field +0x" Format("{:X}", animOff) " --" nl
    if (distinct.Has(animOff))
    {
        dc := distinct[animOff].Count
        rpt .= "  distinct values: " dc "  ->  " _ActorProbeValList(order[animOff]) nl
        rpt .= (dc <= 1 ? "  FROZEN — this offset did NOT change while acting (drifted)." : "  (changed — may still be correct)") nl
    }
    else
        rpt .= "  (not sampled — window too small?)" nl
    rpt .= nl

    ; Collect every offset that changed (distinct >= 2), split into a low-int
    ; animation-id band and everything else.
    changedOffs := []
    for off, dm in distinct
    {
        if (dm.Count >= 2)
            changedOffs.Push(off)
    }
    _ActorProbeSortAsc(changedOffs)

    animCands := []
    otherChanged := []
    for _, off in changedOffs
    {
        info := _ActorProbeStats(distinct[off])
        ; Animation-id heuristic: a small non-negative int that changes but is
        ; not a free-running counter (few distinct values, bounded range).
        isAnim := (info["min"] >= 0 && info["max"] <= 8192 && distinct[off].Count <= 32)
        if (isAnim)
            animCands.Push(off)
        else
            otherChanged.Push(off)
    }

    rpt .= "-- ANIMATION-ID CANDIDATES (changed, values 0..8192, <=32 distinct) --" nl
    if (animCands.Length = 0)
        rpt .= "  (none — did you move/cast during the sample? if yes, the Actor component itself may be mis-resolved)" nl
    else
    {
        for _, off in animCands
        {
            info := _ActorProbeStats(distinct[off])
            mark := (off = animOff) ? "  <== current offset" : ""
            rpt .= Format("  +0x{:03X}: {} distinct  range[{}..{}]  seq={}{}", off, distinct[off].Count, info["min"], info["max"], _ActorProbeValList(order[off]), mark) nl
        }
    }
    rpt .= nl

    rpt .= "-- OTHER CHANGED OFFSETS (counters/timers/pointwhen) --" nl
    if (otherChanged.Length = 0)
        rpt .= "  (none)" nl
    else
    {
        for _, off in otherChanged
        {
            info := _ActorProbeStats(distinct[off])
            rpt .= Format("  +0x{:03X}: {} distinct  range[{}..{}]", off, distinct[off].Count, info["min"], info["max"]) nl
        }
    }
    rpt .= nl

    ; Cross-check the known vector-count offsets so we can tell whether the
    ; whole struct drifted or just the animationId.
    rpt .= "-- known Actor vector offsets (live counts) --" nl
    rpt .= "  ActiveSkills   +0x" Format("{:X}", PoE2Offsets.Actor["ActiveSkills"]) "  count=" _ActorProbeVecCount(reader, actorAddr + PoE2Offsets.Actor["ActiveSkills"], 0x10) nl
    rpt .= "  Cooldowns      +0x" Format("{:X}", PoE2Offsets.Actor["Cooldowns"]) "  count=" _ActorProbeVecCount(reader, actorAddr + PoE2Offsets.Actor["Cooldowns"], 0x48) nl
    rpt .= "  DeployedEnts   +0x" Format("{:X}", PoE2Offsets.Actor["DeployedEntities"]) "  count=" _ActorProbeVecCount(reader, actorAddr + PoE2Offsets.Actor["DeployedEntities"], 0x14) nl

    _AIP_WriteProbeLog("actor_probe", rpt)
}

; Formats an array of ints as a compact comma list (caps length). Param: arr.
_ActorProbeValList(arr)
{
    if !(IsObject(arr) && arr.Length)
        return "(none)"
    s := ""
    for i, v in arr
    {
        s .= (i > 1 ? "," : "") v
        if (i >= 20)
        {
            s .= ",…"
            break
        }
    }
    return s
}

; Returns Map("min", "max") over the keys (values) of a distinct-value Map.
_ActorProbeStats(dm)
{
    mn := 0, mx := 0, first := true
    for v, _ in dm
    {
        if (first)
        {
            mn := v, mx := v, first := false
            continue
        }
        if (v < mn)
            mn := v
        if (v > mx)
            mx := v
    }
    return Map("min", mn, "max", mx)
}

; In-place ascending sort of an integer array (small arrays — insertion sort).
_ActorProbeSortAsc(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        key := arr[i]
        j := i - 1
        while (j >= 1 && arr[j] > key)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}

; Reads a std::vector element count as (last-first)/elemSize, clamped/guarded.
; Params: reader, vecStartAddr (address of the vector's first-ptr), elemSize.
_ActorProbeVecCount(reader, vecStartAddr, elemSize)
{
    try
    {
        first := reader.Mem.ReadPtr(vecStartAddr)
        last  := reader.Mem.ReadPtr(vecStartAddr + 0x8)
        if !(first && last && last >= first && elemSize > 0)
            return "?"
        n := (last - first) // elemSize
        return (n >= 0 && n <= 100000) ? n : "?"
    }
    return "?"
}
