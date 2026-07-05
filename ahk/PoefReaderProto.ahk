; PoefReaderProto.ahk
; Shared-memory header layout for the PERSISTENT reader process (poef_reader.ahk) — reader-split
; stage 2 (see docs/reader-split.md). #Include'd by both the main app and the reader process so the
; offsets never drift. Stage 2 only carries a lifecycle header + a small live status the reader
; publishes (to prove an independent attach); stage 3 extends the same block with the flat radar
; snapshot. Classes-only, no top-level init — safe to #Include anywhere.

class PoefReaderProto
{
    static NAME    := "Local\PoEformanceReader"
    static SIZE    := 4096
    static VERSION := 1
    static MAGIC   := 0x50524431          ; 'PRD1'

    ; ── Control (Main → Reader) ──────────────────────────────────────────────────────────────────
    static O_MAGIC     := 0               ; u32
    static O_VERSION   := 4               ; u32
    static O_MAIN_RUN  := 8               ; u32  1 = run, 0 = stop (reader self-exits)
    static O_MAIN_HEART:= 12              ; u32  Main heartbeat (A_TickCount); reader exits if stale

    ; ── Reader → Main status (seqlock at O_SEQ) ──────────────────────────────────────────────────
    static O_SEQ         := 32            ; u32  seqlock sequence
    static O_RD_HEART    := 36            ; u32  reader heartbeat (A_TickCount)
    static O_RD_CONNECTED:= 40            ; u32  0/1 — EnsureConnected() succeeded (own attach+scan)
    static O_RD_STATE    := 44            ; u32  1 = InGameState, 0 = other
    static O_RD_READS    := 48            ; u32  monotonic loop counter (proves liveness)
    static O_RD_EPOCH    := 52            ; u32  reserved: base-address generation (stage 3)
    static O_RD_INGS     := 56            ; i64  resolved inGameState address (cross-check vs Main)
}
