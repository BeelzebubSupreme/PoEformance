; ReaderProcess.ahk
; Main-side lifecycle for the PERSISTENT reader process (poef_reader.ahk) — reader-split stage 2
; (see docs/reader-split.md). Opt-in via [Diagnostics] readerProcess (default OFF), so it never
; burdens normal runtime — it exists to prove the persistent-reader lifecycle before stage 3 moves
; the radar snapshot into it. Main creates the shared block, spawns the reader, keeps its own
; heartbeat fresh, watchdogs the reader's heartbeat (respawns on a stall), and reads the reader's
; live status for the diagnostic readout.
;
; Verification (ReaderProcessDiagnose): the reader independently attaches to PoE and resolves the
; SAME inGameState address the main app resolved — a cross-process correctness check that the second
; process is reading the live game correctly, just like torn=0 proved the seqlock.

; Seeds globals (init gotcha), creates the shared block, and spawns the reader if enabled.
LoadReaderProcess()
{
    global g_rpEnabled := false
    global g_rpBlk := 0
    global g_rpLock := 0
    global g_rpPid := 0
    global g_rpLastSpawn := 0
    global g_rpStatus := Map("heart", 0, "connected", 0, "state", 0, "reads", 0, "ings", 0)
    ; Stage 3b: the radar snapshot block Main OWNS (creates + stamps) and the reader packs into.
    global g_rpRadarBlk := 0
    global g_rpRadarLock := 0

    try g_rpEnabled := (IniRead(_ConfigPath(), "Diagnostics", "readerProcess", "0") = "1")

    try
    {
        g_rpBlk := SharedMemBlock(PoefReaderProto.NAME, PoefReaderProto.SIZE)
        g_rpBlk.Clear()
        g_rpBlk.PutU32(PoefReaderProto.O_MAGIC, PoefReaderProto.MAGIC)
        g_rpBlk.PutU32(PoefReaderProto.O_VERSION, PoefReaderProto.VERSION)
        g_rpLock := SeqLock(g_rpBlk, PoefReaderProto.O_SEQ)
    }
    catch
        g_rpBlk := 0

    try
    {
        g_rpRadarBlk := SharedMemBlock(PoefRadarProto.NAME, PoefRadarProto.SIZE)
        g_rpRadarBlk.Clear()
        g_rpRadarBlk.PutU32(PoefRadarProto.O_MAGIC, PoefRadarProto.MAGIC)
        g_rpRadarBlk.PutU32(PoefRadarProto.O_VERSION, PoefRadarProto.VERSION)
        g_rpRadarLock := SeqLock(g_rpRadarBlk, PoefRadarProto.O_SEQ)
    }
    catch
        g_rpRadarBlk := 0

    try OnExit(_RpOnExit)

    if (g_rpEnabled && IsObject(g_rpBlk))
        _RpSpawn()
}

; Called each radar tick (no-op unless enabled): refresh Main's heartbeat, read the reader's status,
; and respawn the reader if its heartbeat has gone stale.
ReaderProcessTick()
{
    global g_rpEnabled, g_rpBlk, g_rpLock, g_rpStatus, g_rpLastSpawn
    if !(g_rpEnabled && IsObject(g_rpBlk))
        return
    now := A_TickCount
    g_rpBlk.PutU32(PoefReaderProto.O_MAIN_HEART, now)

    st := g_rpLock.Read(() => _RpReadStatus(g_rpBlk))
    if (st != "")
        g_rpStatus := st

    ; Watchdog: if the reader hasn't heartbeat in >5 s and we spawned it >8 s ago (giving the first
    ; base-scan tick time), respawn it. The reader itself exits if OUR heartbeat goes stale.
    rdHeart := g_rpStatus["heart"]
    if ((now - g_rpLastSpawn) > 8000 && (rdHeart = 0 || (now - rdHeart) > 5000))
        _RpSpawn()
}

; Seqlock copy-out of the reader's status block.
_RpReadStatus(blk)
{
    return Map(
        "heart",     blk.GetU32(PoefReaderProto.O_RD_HEART),
        "connected", blk.GetU32(PoefReaderProto.O_RD_CONNECTED),
        "state",     blk.GetU32(PoefReaderProto.O_RD_STATE),
        "reads",     blk.GetU32(PoefReaderProto.O_RD_READS),
        "ings",      blk.GetI64(PoefReaderProto.O_RD_INGS))
}

; Bridge SetReaderProcess: toggle the feature on/off at runtime and persist it.
SetReaderProcess(val)
{
    global g_rpEnabled, g_rpBlk
    g_rpEnabled := _LrvTruthy(val)
    try IniWrite(g_rpEnabled ? "1" : "0", _ConfigPath(), "Diagnostics", "readerProcess")
    if (g_rpEnabled && IsObject(g_rpBlk))
        _RpSpawn()
    else
        _RpStop()
}

; Header JSON value (bool) for the WebView push. Caller prepends the key.
BuildReaderProcessHeaderJson()
{
    global g_rpEnabled
    return (IsSet(g_rpEnabled) && g_rpEnabled) ? "true" : "false"
}

; Bridge ReaderProcessDiag: MsgBox the live reader status + the cross-check against the main app's
; own resolved inGameState address.
ReaderProcessDiagnose()
{
    global g_rpEnabled, g_rpBlk, g_rpStatus, g_rpPid, g_radarLastSnap
    if !IsObject(g_rpBlk)
    {
        try MsgBox("Reader process: shared block unavailable (creation failed).", "Reader status")
        return
    }
    now := A_TickCount
    heart := g_rpStatus["heart"]
    age := (heart > 0) ? (now - heart) : -1
    alive := (g_rpPid && ProcessExist(g_rpPid)) ? ("yes (pid " g_rpPid ")") : "no"

    ; Main's own resolved inGameState address for the cross-check.
    mainIngs := 0
    try
    {
        inGs := (g_radarLastSnap is Map && g_radarLastSnap.Has("inGameState")) ? g_radarLastSnap["inGameState"] : 0
        if (inGs is Map && inGs.Has("address"))
            mainIngs := inGs["address"]
    }
    rdIngs := g_rpStatus["ings"]
    match := (rdIngs != 0 && rdIngs = mainIngs) ? "MATCH" : ((rdIngs = 0) ? "(reader has none)" : "differ")

    msg := "Reader process (stage 2)`n`n"
        . "enabled:        " (g_rpEnabled ? "yes" : "no") "`n"
        . "process alive:  " alive "`n"
        . "heartbeat age:  " (age >= 0 ? age " ms" : "(never)") "`n"
        . "connected:      " (g_rpStatus["connected"] ? "yes" : "no") "`n"
        . "state:          " (g_rpStatus["state"] ? "InGameState" : "other/loading") "`n"
        . "reads:          " g_rpStatus["reads"] "  (click again — should increase)`n`n"
        . "inGameState (reader): " Format("0x{:X}", rdIngs) "`n"
        . "inGameState (main):   " Format("0x{:X}", mainIngs) "`n"
        . "cross-check:    " match
    try MsgBox(msg, "Reader status")
}

; Bridge RadarConsumeDiag: unpack the reader's latest published awake sample and cross-check it against
; the main app's own live snapshot (stage 3b parity check). This is the gate before stage 3c flips Main
; to CONSUME the reader's sample — it proves the reader independently builds the same awake sample Main
; builds, the way stage 2's inGameState cross-check proved the independent attach.
RadarConsumeDiagnose()
{
    global g_rpEnabled, g_rpRadarBlk, g_rpRadarLock, g_rpPid, g_radarLastSnap
    if !IsObject(g_rpRadarBlk)
    {
        try MsgBox("Radar snapshot block unavailable (creation failed).", "Radar consume")
        return
    }

    now := A_TickCount
    rdHeart := g_rpRadarBlk.GetU32(PoefRadarProto.O_RDHEART)
    heartAge := (rdHeart > 0) ? (now - rdHeart) : -1

    res := RadarWireUnpack(g_rpRadarBlk, g_rpRadarLock)
    if !(res is Map && res.Has("ok") && res["ok"])
    {
        try MsgBox("Reader radar snapshot not readable (seqlock busy / no publish yet).`n`n"
            . "enabled:       " (g_rpEnabled ? "yes" : "no") "`n"
            . "reader alive:  " ((g_rpPid && ProcessExist(g_rpPid)) ? "yes" : "no") "`n"
            . "heartbeat age: " (heartAge >= 0 ? heartAge " ms" : "(never)"), "Radar consume")
        return
    }

    ; Main's own live awake sample for the cross-check.
    mainSample := 0
    mainAreaHash := 0
    try
    {
        inGs := (g_radarLastSnap is Map && g_radarLastSnap.Has("inGameState")) ? g_radarLastSnap["inGameState"] : 0
        area := (inGs is Map && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        if (area is Map)
        {
            mainAreaHash := area.Has("currentAreaHash") ? area["currentAreaHash"] : 0
            aw := area.Has("awakeEntities") ? area["awakeEntities"] : 0
            if (aw is Map && aw.Has("sample"))
                mainSample := aw["sample"]
        }
    }
    mainCount := (mainSample is Array) ? mainSample.Length : 0

    ; Index Main's entities by id for a spot cross-check.
    mainById := Map()
    if (mainSample is Array)
    {
        for _, e in mainSample
        {
            eid := (e is Map && e.Has("id")) ? e["id"] : 0
            if (eid > 0)
                mainById[eid] := e
        }
    }

    ; Match reader entities against Main by id; compare path + world position.
    rdSample := res["sample"]
    matched := 0, pathMismatch := 0, posMismatch := 0, onlyReader := 0
    for _, re in rdSample
    {
        rid := re["id"]
        if !mainById.Has(rid)
        {
            onlyReader += 1
            continue
        }
        matched += 1
        me := mainById[rid]
        rpath := re["entity"]["path"]
        mpath := (me["entity"] is Map && me["entity"].Has("path")) ? me["entity"]["path"] : ""
        if (rpath != mpath)
            pathMismatch += 1
        ; Compare render world X (if both have it) within 1 unit.
        rwx := _RadarDiagWorldX(re)
        mwx := _RadarDiagWorldX(me)
        if (rwx != "" && mwx != "" && Abs(rwx - mwx) > 1.0)
            posMismatch += 1
    }
    onlyMain := 0
    rdIds := Map()
    for _, re in rdSample
        rdIds[re["id"]] := true
    for mid, _ in mainById
    {
        if !rdIds.Has(mid)
            onlyMain += 1
    }

    areaMatch := (res["areaHash"] = mainAreaHash) ? "MATCH" : "differ"

    msg := "Radar consume parity (stage 3b)`n`n"
        . "reader alive:   " ((g_rpPid && ProcessExist(g_rpPid)) ? ("yes (pid " g_rpPid ")") : "no") "`n"
        . "heartbeat age:  " (heartAge >= 0 ? heartAge " ms" : "(never)") "`n"
        . "frame:          " res["frame"] "  (click again — should increase)`n"
        . "truncated:      " (res["truncated"] ? "YES (>512)" : "no") "`n`n"
        . "areaHash reader/main: " Format("0x{:X}", res["areaHash"] & 0xFFFFFFFF)
            . " / " Format("0x{:X}", mainAreaHash & 0xFFFFFFFF) "  " areaMatch "`n`n"
        . "reader sample:  " rdSample.Length "`n"
        . "main sample:    " mainCount "  (Main junk-filters; reader publishes all → reader >= main)`n"
        . "matched by id:  " matched "`n"
        . "  path mismatch:  " pathMismatch "`n"
        . "  pos  mismatch:  " posMismatch "`n"
        . "only in reader: " onlyReader "  (expected: junk the reader doesn't filter)`n"
        . "only in main:   " onlyMain "  (want 0 — Main should never have an entity the reader lacks)"
    try MsgBox(msg, "Radar consume")
}

; Helper: pull render worldPosition.x off a sample entry, or "" if absent.
_RadarDiagWorldX(entry)
{
    try
    {
        dc := entry["entity"]["decodedComponents"]
        if (dc is Map && dc.Has("render"))
        {
            wp := dc["render"]["worldPosition"]
            if (wp is Map && wp.Has("x"))
                return wp["x"]
        }
    }
    return ""
}

; ── internals ────────────────────────────────────────────────────────────────────────────────────

; (Re)spawns poef_reader.ahk (hidden). Kills any prior instance and resets the handshake flags.
_RpSpawn()
{
    global g_rpPid, g_rpBlk, g_rpLastSpawn
    _RpKill()
    try
    {
        g_rpBlk.PutU32(PoefReaderProto.O_RD_HEART, 0)
        g_rpBlk.PutU32(PoefReaderProto.O_MAIN_HEART, A_TickCount)
        g_rpBlk.PutU32(PoefReaderProto.O_MAIN_RUN, 1)
    }
    script := A_ScriptDir "\poef_reader.ahk"
    if !FileExist(script)
        return
    pid := 0
    try Run(Format('"{1}" "{2}"', A_AhkPath, script), A_ScriptDir, "Hide", &pid)
    g_rpPid := pid
    g_rpLastSpawn := A_TickCount
}

; Stops the reader: clears the run flag (it self-exits) then kills as a fallback.
_RpStop()
{
    global g_rpBlk
    if IsObject(g_rpBlk)
        try g_rpBlk.PutU32(PoefReaderProto.O_MAIN_RUN, 0)
    _RpKill()
}

_RpKill()
{
    global g_rpPid
    if (g_rpPid && ProcessExist(g_rpPid))
        try ProcessClose(g_rpPid)
    g_rpPid := 0
}

_RpOnExit(*)
{
    _RpStop()
}
