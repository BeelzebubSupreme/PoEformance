; SharedMem.ahk
; Cross-process shared memory (a named, pagefile-backed file mapping) plus a single-writer /
; single-reader SEQLOCK — the transport primitive for the reader-split (see docs/reader-split.md).
;
; One process creates the block (SharedMemBlock(name, bytes)); other processes open the SAME name
; and map their own view of the same physical pages. Reads/writes go straight to the mapped memory
; via NumGet/NumPut, so it is zero-copy RAM shared between processes — the only transport fast
; enough for a per-frame snapshot.
;
; This module is pure DllCall (kernel32 / ntdll) with NO project dependencies, so it can be
; #Include'd by any entry point (main app, reader process, sampler processes) and unit-tested
; standalone. It defines only classes — no top-level global initialisers — so it is safe to
; #Include anywhere (AHK v2 init gotcha does not apply).

class SharedMemBlock
{
    hMap    := 0        ; file-mapping handle
    ptr     := 0        ; base address of the mapped view (raw pointer)
    size    := 0        ; block size in bytes
    name    := ""       ; mapping name
    isOwner := false    ; true if THIS process created the mapping (else it opened an existing one)

    static PAGE_READWRITE      := 0x04
    static FILE_MAP_ALL_ACCESS := 0xF001F   ; STANDARD_RIGHTS_REQUIRED | SECTION_* rights
    static ERROR_ALREADY_EXISTS := 183

    ; Create (or open, if the name already exists) a named mapping of `bytes` and map a view of it.
    ; name : mapping name; prefer a "Local\..." name for same-session sharing.
    ; bytes: block size (<= 4 GB; the high dword is 0 here).
    ; Throws on failure. isOwner is set so the creator can zero the block once.
    __New(name, bytes)
    {
        this.name := name
        this.size := bytes

        ; CreateFileMappingW(INVALID_HANDLE_VALUE=-1, NULL, PAGE_READWRITE, sizeHigh=0, sizeLow, name)
        ; A pagefile-backed mapping (hFile = -1) needs no file on disk. Creating with an existing
        ; name returns a handle to the SAME mapping and sets A_LastError = ERROR_ALREADY_EXISTS.
        this.hMap := DllCall("CreateFileMapping"
            , "Ptr",  -1
            , "Ptr",  0
            , "UInt", SharedMemBlock.PAGE_READWRITE
            , "UInt", 0
            , "UInt", bytes
            , "Str",  name
            , "Ptr")
        if !this.hMap
            throw Error("CreateFileMapping failed", , A_LastError)
        this.isOwner := (A_LastError != SharedMemBlock.ERROR_ALREADY_EXISTS)

        ; MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, offHigh=0, offLow=0, bytesToMap=0 => whole block)
        this.ptr := DllCall("MapViewOfFile"
            , "Ptr",  this.hMap
            , "UInt", SharedMemBlock.FILE_MAP_ALL_ACCESS
            , "UInt", 0
            , "UInt", 0
            , "UPtr", 0
            , "Ptr")
        if !this.ptr
        {
            err := A_LastError
            DllCall("CloseHandle", "Ptr", this.hMap)
            this.hMap := 0
            throw Error("MapViewOfFile failed", , err)
        }
    }

    ; Zero the whole block. The creating (owner) process should call this once, before any reader
    ; attaches, so the seqlock/header start from a clean even state.
    Clear()
    {
        if this.ptr
            DllCall("ntdll\RtlZeroMemory", "Ptr", this.ptr, "UPtr", this.size)
    }

    ; ── Scalar accessors (byte offset into the block) ────────────────────────────────────────────
    PutU8(offset, val)  => NumPut("UChar",  val, this.ptr, offset)
    GetU8(offset)       => NumGet(this.ptr, offset, "UChar")
    PutU16(offset, val) => NumPut("UShort", val, this.ptr, offset)
    GetU16(offset)      => NumGet(this.ptr, offset, "UShort")
    PutU32(offset, val) => NumPut("UInt",  val, this.ptr, offset)
    GetU32(offset)      => NumGet(this.ptr, offset, "UInt")
    PutI32(offset, val) => NumPut("Int",   val, this.ptr, offset)
    GetI32(offset)      => NumGet(this.ptr, offset, "Int")
    PutI64(offset, val) => NumPut("Int64", val, this.ptr, offset)
    GetI64(offset)      => NumGet(this.ptr, offset, "Int64")
    PutF32(offset, val) => NumPut("Float", val, this.ptr, offset)
    GetF32(offset)      => NumGet(this.ptr, offset, "Float")

    ; Bulk copy: `len` bytes from a source address/Buffer into the block at `offset`, and back out.
    ; (RtlMoveMemory = memmove; safe for any src/dst.)
    PutBytes(offset, srcPtr, len) => DllCall("ntdll\RtlMoveMemory", "Ptr", this.ptr + offset, "Ptr", srcPtr, "UPtr", len)
    GetBytes(offset, dstPtr, len) => DllCall("ntdll\RtlMoveMemory", "Ptr", dstPtr, "Ptr", this.ptr + offset, "UPtr", len)

    ; Unmap + close on destruction. The physical pages live until the LAST handle across all
    ; processes is closed, so one side exiting never pulls the memory out from under the other.
    __Delete()
    {
        if this.ptr
        {
            DllCall("UnmapViewOfFile", "Ptr", this.ptr)
            this.ptr := 0
        }
        if this.hMap
        {
            DllCall("CloseHandle", "Ptr", this.hMap)
            this.hMap := 0
        }
    }
}

; Single-writer / single-reader SEQLOCK over a SharedMemBlock. A u32 sequence counter (at seqOffset,
; default 0) is EVEN when the payload is consistent and ODD while the writer is mid-write:
;   writer : WriteBegin() -> mutate payload -> WriteEnd()
;   reader : Read(copyFn) retries until it observes the SAME even sequence before and after copyFn,
;            so it never returns a half-written (torn) payload.
; Correct for exactly one writer and one reader. On x86's strong memory model and AHK's coarse
; per-op granularity, no explicit memory fences are required for the pilot; revisit if a future
; sampler needs multiple concurrent readers (then a per-reader lock or a lock-free ring is better).
class SeqLock
{
    blk    := 0
    seqOff := 0

    __New(block, seqOffset := 0)
    {
        this.blk := block
        this.seqOff := seqOffset
    }

    ; Sequence goes odd — "write in progress". Call before mutating the payload.
    WriteBegin() => this.blk.PutU32(this.seqOff, this.blk.GetU32(this.seqOff) + 1)

    ; Sequence goes even again — "payload consistent". Call after the last mutation.
    WriteEnd()   => this.blk.PutU32(this.seqOff, this.blk.GetU32(this.seqOff) + 1)

    ; Stable read: calls copyFn() (which must copy the payload out and return it) between two reads
    ; of the sequence, retrying while the sequence is odd or changed. Returns copyFn's result on a
    ; clean read, or "" if it could not stabilise within maxTries (writer pathologically busy).
    Read(copyFn, maxTries := 32)
    {
        Loop maxTries
        {
            s1 := this.blk.GetU32(this.seqOff)
            if (s1 & 1)              ; odd → writer is mid-write, spin
                continue
            result := copyFn()
            s2 := this.blk.GetU32(this.seqOff)
            if (s1 = s2)             ; unchanged around the copy → consistent
                return result
        }
        return ""
    }
}
