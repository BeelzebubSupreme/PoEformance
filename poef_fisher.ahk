; poef_fisher.ahk
; Anim-fishing SAMPLER process — the pilot user of the reader-split infrastructure
; (see docs/reader-split.md). Spawned by the main app (HkAnimCapture.StartHkAnimCapture) while the
; live enemy-animation capture is armed, killed when it disarms.
;
; It owns the RAW high-frequency reads: every ~10 ms it reads the monster Actor-component addresses
; the main app published into shared memory (Region A) and reads each one's animationId directly
; (one RPM per monster) via its OWN handle to the PoE process, accumulating an animationId →
; {count,last,dist} table, which it publishes back into shared memory (Region B). The main app
; renders that digest. This is what lets the main tick keep rendering the overlays at its normal
; cadence instead of hijacking itself into a 10 ms turbo loop.
;
; Lean by design: only SharedMem + the wire protocol + ProcessMemory — NOT the whole reader stack.
; The absolute addresses the main app publishes are valid in this process's handle too (same target
; process, different handle). Exits when Main clears the run flag or Main's heartbeat goes stale.

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
#Include ahk/SharedMem.ahk
#Include ahk/HkFishProtocol.ahk
#Include ahk/ProcessMemory.ahk

; ── Attach to the shared block the main app created ──────────────────────────────────────────────
g_blk := 0
try g_blk := SharedMemBlock(HkFishProto.NAME, HkFishProto.SIZE)
if !IsObject(g_blk)
    ExitApp
g_lockA := SeqLock(g_blk, HkFishProto.O_SEQA)   ; read the address list
g_lockB := SeqLock(g_blk, HkFishProto.O_SEQB)   ; write the counts

; ── Open our own handle to the PoE process (retry briefly while it starts / we attach) ───────────
g_pm := ProcessMemory()
g_tries := 0
while (!g_pm.Open() && g_tries < 25)
{
    Sleep(200)
    g_tries += 1
}

; ── Local accumulation state (owned entirely by this process) ────────────────────────────────────
g_seen := Map()          ; animationId -> Map(count, last, dist)
g_lastAreaGen := -1
g_lastPublish := 0
g_errStreak := 0

SetTimer(FishTick, 10)    ; the high-rate sampling loop; keeps this process alive
return

; One 10 ms sampling tick. Guarded so a transient read error never pops a dialog on the user's
; screen; a long error streak exits (something is fundamentally wrong / PoE closed).
FishTick()
{
    global g_blk, g_lockA, g_lockB, g_pm, g_seen, g_lastAreaGen, g_lastPublish, g_errStreak
    try
    {
        now := A_TickCount

        ; Stop conditions: Main cleared the run flag, or Main's heartbeat went stale (Main crashed).
        if (g_blk.GetU32(HkFishProto.O_RUN) != 1)
            ExitApp
        mainHeart := g_blk.GetU32(HkFishProto.O_MAINHEART)
        if (mainHeart != 0 && (now - mainHeart) > 3000)
            ExitApp

        g_blk.PutU32(HkFishProto.O_FISHHEART, now)   ; our liveness

        animOff := g_blk.GetU32(HkFishProto.O_ANIMOFF)
        if (animOff = 0 || !g_pm.Handle)
            return                                    ; not configured / not attached yet

        ; Read the current monster address list (seqlock A). "" = Main was mid-write → try next tick.
        data := g_lockA.Read(() => _FishReadAddrs(g_blk))
        if (data = "")
            return

        if (data.gen != g_lastAreaGen)                ; area change → forget old animations
        {
            g_seen := Map()
            g_lastAreaGen := data.gen
        }

        for _, m in data.list
        {
            addr := m.addr
            if (addr < 0x10000)                       ; obviously-bad pointer
                continue
            animId := -1
            try animId := g_pm.ReadInt(addr + animOff)
            if (animId < 0 || animId > 5000)          ; sanity bound (the anim table is well under 5000)
                continue
            rec := g_seen.Has(animId) ? g_seen[animId] : Map("count", 0, "last", 0, "dist", 999999)
            rec["count"] += 1
            rec["last"] := now
            if (m.dist >= 0 && m.dist < rec["dist"])
                rec["dist"] := m.dist
            g_seen[animId] := rec
        }

        ; Publish the accumulated table (seqlock B), throttled — Main reads at ~45 ms.
        if ((now - g_lastPublish) >= 30)
        {
            g_lastPublish := now
            _FishPublish(g_blk, g_lockB, g_seen, data.gen, now)
        }

        g_errStreak := 0
    }
    catch
    {
        g_errStreak += 1
        if (g_errStreak > 200)                        ; ~2 s of solid failure → give up quietly
            ExitApp
    }
}

; Seqlock copy-out for the address list: returns {gen, list:[{addr,dist}, ...]}.
_FishReadAddrs(blk)
{
    gen := blk.GetU32(HkFishProto.O_AREAGEN)
    cnt := blk.GetU32(HkFishProto.O_ADDRCNT)
    if (cnt > HkFishProto.MAX_ADDRS)
        cnt := HkFishProto.MAX_ADDRS
    list := []
    Loop cnt
    {
        i := A_Index - 1
        list.Push({ addr: blk.GetI64(HkFishProto.O_ADDRS + i * 8)
                  , dist: blk.GetI32(HkFishProto.O_DISTS + i * 4) })
    }
    return { gen: gen, list: list }
}

; Prunes entries older than 8 s and writes the surviving rows into Region B under seqlock B.
_FishPublish(blk, lockB, seen, areaGen, now)
{
    rows := []
    stale := []
    for id, rec in seen
    {
        if (now - rec["last"] > 8000)
            stale.Push(id)
        else
            rows.Push({ id: id, count: rec["count"], last: rec["last"], dist: rec["dist"] })
    }
    for _, id in stale
        seen.Delete(id)

    n := Min(rows.Length, HkFishProto.MAX_ROWS)
    lockB.WriteBegin()
    blk.PutU32(HkFishProto.O_AREAGEN2, areaGen)
    blk.PutU32(HkFishProto.O_ROWCNT, n)
    Loop n
    {
        r := rows[A_Index]
        base := HkFishProto.O_ROWS + (A_Index - 1) * HkFishProto.ROW_SIZE
        blk.PutU32(base + HkFishProto.R_ANIM,  r.id)
        blk.PutU32(base + HkFishProto.R_COUNT, r.count)
        blk.PutU32(base + HkFishProto.R_LAST,  r.last)
        d := (r.dist >= 2000000000) ? 2000000000 : Round(r.dist)
        blk.PutI32(base + HkFishProto.R_DIST, d)
    }
    lockB.WriteEnd()
}
