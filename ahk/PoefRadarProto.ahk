; PoefRadarProto.ahk
; Shared-memory WIRE LAYOUT for the radar snapshot — reader-split stage 3 (see docs/reader-split.md,
; "Stage 3 design"). #Include'd by BOTH the persistent reader process (writer of the snapshot) and the
; main app (reader of the snapshot), so the byte offsets can never drift between the two sides.
;
; The reader publishes a FLAT binary snapshot of the awake-entity sample; the main app reconstructs the
; exact nested-Map shape (`awakeEntities.sample`) from it — so NO downstream consumer changes (safety
; principle 1). Variable data (metadata paths) goes through an interned string heap; each record stores
; a byte offset into that heap. This is a SEPARATE named block from the stage-2 lifecycle/status block
; (PoefReaderProto) so the big snapshot buffer is isolated from the tiny status handshake.
;
; Consistency: ONE payload region guarded by a single-writer / single-reader SEQLOCK (the same
; primitive proven torn=0 by the anim-fishing pilot). The reader packs the whole region between
; WriteBegin/WriteEnd; the main app copies the region out between two seq reads (staleness on a
; mid-write collision → reuse last, never torn).
;
; Classes-only, no top-level init — safe to #Include anywhere (AHK v2 init gotcha does not apply).

class PoefRadarProto
{
    static NAME        := "Local\PoEformanceRadarSnap"
    static VERSION     := 1
    static MAGIC       := 0x50525331          ; 'PRS1'
    static MAX_RECORDS := 512                  ; cap; truncation flagged in O_TRUNC + logged by the reader
    static HEAP_BYTES  := 131072               ; 128 KB string heap (UTF-8, length-prefixed paths)

    ; ── Header ───────────────────────────────────────────────────────────────────────────────────
    static O_MAGIC     := 0                    ; u32
    static O_VERSION   := 4                    ; u32  snapshot wire version — mismatch ⇒ Main refuses
    static O_EPOCH     := 8                    ; u32  base-address generation (bumped on PoE re-resolve)

    ; ── Payload (seqlock at O_SEQ; the consistent region is O_FRAME .. end-of-heap) ────────────────
    static O_SEQ       := 32                   ; u32  seqlock sequence (odd = mid-write)
    static O_FRAME     := 36                   ; u32  frame counter (increments each publish)
    static O_AREAHASH  := 40                   ; i64  area hash the records belong to (Main gates on it)
    static O_PLAYERX   := 48                   ; f32  player world position (for Main's local checks)
    static O_PLAYERY   := 52                   ; f32
    static O_PLAYERZ   := 56                   ; f32
    static O_RECCOUNT  := 60                   ; u32  number of valid records
    static O_HEAPLEN   := 64                   ; u32  bytes used in the heap
    static O_TRUNC     := 68                   ; u32  1 if the sample exceeded MAX_RECORDS (records dropped)
    static O_RDHEART   := 72                   ; u32  reader heartbeat (A_TickCount) — Main watchdogs it
    static O_RAWCOUNT  := 76                   ; u32  reader's RAW awake-map BFS count (incl. undecoded
                                               ;      junk) — Main uses it for the isZoneLoading ratio,
                                               ;      since the published record set omits junk that
                                               ;      failed to decode
    static O_RECORDS   := 80                   ; record[MAX_RECORDS], RECORD_SIZE bytes each

    ; ── Per-entity record (RECORD_SIZE bytes, 8-byte fields first for alignment) ────────────────────
    static RECORD_SIZE := 120
    static R_ENTPTR    := 0                    ; i64  entity address (entry.entityPtr / entity.address)
    static R_RAWPTR    := 8                    ; i64  entity raw pointer (entry.entityRawPtr)
    static R_TGTADDR   := 16                   ; i64  Targetable component address (0 = none)
    static R_ACTADDR   := 24                   ; i64  Actor component address (0 = none)
    static R_RENDADDR  := 32                   ; i64  Render component address (0 = none)
    static R_LIFEADDR  := 40                   ; i64  Life component address (0 = none)
    static R_CHESTADDR := 48                   ; i64  Chest component address (0 = none)
    static R_ID        := 56                   ; u32  entity id (== entry.id)
    static R_PATHIDX   := 60                   ; u32  byte offset into the string heap (metadata path)
    static R_DISTANCE  := 64                   ; f32  entry.distance
    static R_PRIORITY  := 68                   ; i32  entry.priority
    static R_WORLDX    := 72                   ; f32  render worldPosition.x
    static R_WORLDY    := 76                   ; f32  render worldPosition.y
    static R_WORLDZ    := 80                   ; f32  render worldPosition.z
    static R_TERRAINH  := 84                   ; f32  render terrainHeight
    static R_RARITY    := 88                   ; i32  rarityId (valid only if hasRarity presence bit)
    static R_ANIMID    := 92                   ; i32  actor animationId (valid only if hasActor)
    static R_CURHP     := 96                   ; i32  life current HP
    static R_MAXHP     := 100                  ; i32  life max HP
    static R_LIFEPCT   := 104                  ; f32  life lifeCurrentPercentMax
    static R_PRESENCE  := 108                  ; u32  presence + boolean bitfield (see P_* below)
    static R_ENTFLAGS  := 112                  ; u8   raw entity flag byte (entity.flags; isValid derived)
    static R_REACTION  := 113                  ; u8   positioned reaction (isFriendly derived)
    static R_CHESTBITS := 114                  ; u8   chest bits (C_* below)
    ; 115..119 padding to RECORD_SIZE (8-byte alignment)

    ; Presence / boolean bitfield (R_PRESENCE)
    static P_RENDER    := 0x0001               ; render component present
    static P_LIFE      := 0x0002               ; life component present
    static P_POSITIONED:= 0x0004               ; positioned component present
    static P_RARITY    := 0x0008               ; rarityId present
    static P_CHEST     := 0x0010               ; chest component present
    static P_TARGETABLE:= 0x0020               ; targetable present (radar decode → bare bool)
    static P_ACTOR     := 0x0040               ; actor component present
    static P_TGTVAL    := 0x0080               ; the targetable bare-bool VALUE (isTargetable)
    static P_LIFEALIVE := 0x0100               ; life isAlive value

    ; Chest bitfield (R_CHESTBITS)
    static C_OPENED    := 0x01
    static C_LABELVIS  := 0x02
    static C_STRONGBOX := 0x04

    ; Total block size = header + records region + heap.
    static SIZE => PoefRadarProto.O_RECORDS
                 + PoefRadarProto.MAX_RECORDS * PoefRadarProto.RECORD_SIZE
                 + PoefRadarProto.HEAP_BYTES

    ; Byte offset of the string heap (immediately after the records region).
    static HEAP_OFF => PoefRadarProto.O_RECORDS
                     + PoefRadarProto.MAX_RECORDS * PoefRadarProto.RECORD_SIZE
}
