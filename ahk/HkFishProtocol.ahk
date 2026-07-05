; HkFishProtocol.ahk
; Shared-memory wire layout for the anim-fishing sampler pilot — the first user of the reader-split
; infrastructure (see docs/reader-split.md, "the sampler pattern"). #Include'd by BOTH the main app
; (writer of the address list, reader of the counts) and poef_fisher.ahk (the sampler: reader of the
; address list, writer of the counts), so the byte offsets can never drift between the two sides.
;
; Two seqlock-guarded regions in one named block:
;   Region A  Main → Fisher : the monster Actor-component addresses to poll (published ~every 300 ms;
;                             Main already has the radar snapshot, so collecting them is free).
;   Region B  Fisher → Main : the accumulated animationId → {count,last,dist} rows (the fisher owns
;                             the 10 ms sampling + accumulation; Main just renders the digest).
; Plus a small control header (run flag, the AnimationId offset, both heartbeats).
;
; Classes-only, no top-level init — safe to #Include anywhere (AHK v2 init gotcha does not apply).

class HkFishProto
{
    static NAME      := "Local\PoEformanceHkFish"
    static SIZE      := 16384
    static VERSION   := 1
    static MAGIC     := 0x484B4631        ; 'HKF1'
    static MAX_ADDRS := 256               ; monster Actor components polled per tick
    static MAX_ROWS  := 256               ; distinct animationIds reported

    ; ── Control header ───────────────────────────────────────────────────────────────────────────
    static O_MAGIC     := 0               ; u32
    static O_VERSION   := 4               ; u32
    static O_RUN       := 8               ; u32  Main→Fisher: 1 = run, 0 = stop (fisher self-exits)
    static O_ANIMOFF   := 12              ; u32  Main→Fisher: PoE2Offsets.Actor["AnimationId"]
    static O_MAINHEART := 16              ; u32  Main→Fisher: A_TickCount (fisher exits if it goes stale)
    static O_FISHHEART := 20              ; u32  Fisher→Main: A_TickCount (Main can show reader status)

    ; ── Region A: Main → Fisher address list (seqlock at O_SEQA) ─────────────────────────────────
    static O_SEQA      := 32              ; u32  seqlock sequence
    static O_AREAGEN   := 36              ; u32  bumped on area change → fisher forgets old anims
    static O_ADDRCNT   := 40              ; u32  number of valid entries in the arrays below
    static O_ADDRS     := 48              ; i64[MAX_ADDRS]  Actor-component addresses  (48 .. 2096)
    static O_DISTS     := 2096            ; i32[MAX_ADDRS]  parallel distances          (2096 .. 3120)

    ; ── Region B: Fisher → Main counts (seqlock at O_SEQB) ───────────────────────────────────────
    static O_SEQB      := 3200            ; u32  seqlock sequence
    static O_AREAGEN2  := 3204            ; u32  areaGen the rows belong to (fisher echoes it back)
    static O_ROWCNT    := 3208            ; u32  number of rows
    static O_ROWS      := 3216            ; row[MAX_ROWS], ROW_SIZE bytes each          (3216 .. 7312)
    static ROW_SIZE    := 16
    static R_ANIM      := 0               ; u32  animationId
    static R_COUNT     := 4               ; u32  times seen
    static R_LAST      := 8               ; u32  A_TickCount of last sighting
    static R_DIST      := 12              ; i32  nearest distance seen
}
