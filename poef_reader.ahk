; poef_reader.ahk
; PERSISTENT reader process — reader-split stage 2 scaffolding (see docs/reader-split.md). Unlike the
; transient anim-fishing sampler, this process lives for the whole session: the main app spawns it
; once (opt-in via [Diagnostics] readerProcess) and watchdogs it. Its job in stage 2 is only to prove
; the lifecycle end-to-end — it does its OWN attach (FindPoePid + reader.Connect(), same as the main
; app's EnsureConnected, including its own base-address scan) and publishes a small live status
; (heartbeat, connected, current state, a monotonic read counter, and the resolved inGameState
; address for cross-checking against the main app). Stage 3 will extend it to publish the full flat
; radar snapshot.
;
; Pulls the WHOLE reader stack via PoE2MemoryReader.ahk's own #Includes — but deliberately reads only
; the LIGHTWEIGHT ReadAutoFlaskSnapshot (no junk-filter / landmark / snapshot feature deps yet).

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
#Include ahk/SharedMem.ahk
#Include ahk/PoefReaderProto.ahk
#Include ahk/PoefRadarProto.ahk
#Include ahk/RadarSnapshotWire.ahk
#Include ahk/PoE2MemoryReader.ahk

g_blk := 0
try g_blk := SharedMemBlock(PoefReaderProto.NAME, PoefReaderProto.SIZE)
if !IsObject(g_blk)
    ExitApp
g_lock := SeqLock(g_blk, PoefReaderProto.O_SEQ)

; Radar snapshot block (stage 3b): opened by name (Main creates + stamps MAGIC/VERSION as owner). The
; reader packs the awake sample here each tick; Main cross-checks it against its own live snapshot.
g_radarBlk := 0
try g_radarBlk := SharedMemBlock(PoefRadarProto.NAME, PoefRadarProto.SIZE)
g_radarLock := IsObject(g_radarBlk) ? SeqLock(g_radarBlk, PoefRadarProto.O_SEQ) : 0

g_reader := PoE2GameStateReader()
g_connected := false
g_lastPid := 0
g_reads := 0
g_err := 0

SetTimer(ReaderTick, 50)   ; persistent ~20 Hz loop; keeps this process alive
return

; One reader tick: enforce the lifecycle, (re)attach if needed, read a lightweight live value, and
; publish the status under seqlock. Guarded so a transient read never pops a dialog on-screen.
ReaderTick()
{
    global g_blk, g_lock, g_reader, g_connected, g_lastPid, g_reads, g_err
    try
    {
        now := A_TickCount

        ; Lifecycle: stop when Main clears the run flag or Main's heartbeat goes stale (Main crashed).
        if (g_blk.GetU32(PoefReaderProto.O_MAIN_RUN) != 1)
            ExitApp
        mainHeart := g_blk.GetU32(PoefReaderProto.O_MAIN_HEART)
        if (mainHeart != 0 && (now - mainHeart) > 5000)
            ExitApp

        ; Own attach — mirrors the main app's EnsureConnected (FindPoePid + reader.Connect()).
        pid := FindPoePid()
        if (!pid)
            g_connected := false
        else if (!g_connected || g_lastPid != pid)
        {
            try g_reader.Mem.Close()
            g_connected := g_reader.Connect()
            if (g_connected)
                g_lastPid := pid
        }

        ; Lightweight live read (no snapshot feature deps): current state + inGameState address.
        stateCode := 0
        ings := 0
        if (g_connected)
        {
            snap := 0
            try snap := g_reader.ReadAutoFlaskSnapshot()
            if (snap is Map)
            {
                nm := snap.Has("currentStateName") ? snap["currentStateName"] : ""
                stateCode := (nm = "InGameState") ? 1 : 0
                ings := snap.Has("inGameStateAddress") ? snap["inGameStateAddress"] : 0
            }
        }
        g_reads += 1

        ; Stage 3b: when in-game, run the awake-entity scan and PUBLISH the flat snapshot. Guarded so a
        ; transient read failure can never crash the reader or block its status heartbeat above.
        if (g_connected && stateCode = 1 && IsObject(g_radarBlk) && ings != 0)
        {
            try
            {
                pub := g_reader.ReadAwakeFlatForPublish(ings)
                if (pub is Map)
                {
                    RadarWirePack(g_radarBlk, g_radarLock, pub["sample"],
                        pub["playerX"], pub["playerY"], pub["playerZ"], pub["areaHash"],
                        pub.Has("rawCount") ? pub["rawCount"] : -1)
                    g_radarBlk.PutU32(PoefRadarProto.O_RDHEART, now)
                }
            }
        }

        g_lock.WriteBegin()
        g_blk.PutU32(PoefReaderProto.O_RD_HEART, now)
        g_blk.PutU32(PoefReaderProto.O_RD_CONNECTED, g_connected ? 1 : 0)
        g_blk.PutU32(PoefReaderProto.O_RD_STATE, stateCode)
        g_blk.PutU32(PoefReaderProto.O_RD_READS, g_reads)
        g_blk.PutI64(PoefReaderProto.O_RD_INGS, ings)
        g_lock.WriteEnd()

        g_err := 0
    }
    catch
    {
        g_err += 1
        if (g_err > 100)          ; ~5 s of solid failure → give up quietly
            ExitApp
    }
}
