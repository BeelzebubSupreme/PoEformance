; MemoryDissect.ahk
; Cheat-Engine-style memory dissector: navigate from a base address, view fields
; at 8-byte stride with multi-format decoding. Click pointer fields to jump.
; Back / Forward stacks support breadcrumb navigation.
;
; Globals declared in InGameStateMonitor.ahk:
;   g_memDissectAddress  — current base address (Int64), 0 = none
;   g_memDissectSize     — bytes to read (default 0x200 = 512 → 64 rows)
;   g_memDissectBuf      — Buffer holding current read, or 0
;   g_memDissectHistory  — Array of past addresses (back stack)
;   g_memDissectFwd      — Array of forward addresses (forward stack)
;   g_memDissectStatus   — short status string for the UI
;
; Included by InGameStateMonitor.ahk.

; ── Public API ────────────────────────────────────────────────────────────

; Jump to an absolute address: reads g_memDissectSize bytes, updates the buffer,
; pushes the old address onto the back stack, and clears the forward stack.
; addr is an Int64. Returns a status string.
MemDissectGoto(addr)
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus

    if (!addr || addr = 0)
    {
        g_memDissectStatus := "invalid-address"
        return g_memDissectStatus
    }

    ; Read FIRST — only mutate the navigation stacks if we actually landed on a
    ; new address. A failed pointer read used to push a dead history entry
    ; (old == current), which made the Back button appear to do nothing.
    oldAddr := g_memDissectAddress
    st := _MemDissectReadAt(addr)          ; sets g_memDissectAddress on success only
    if (g_memDissectAddress = addr && oldAddr && oldAddr != addr)
    {
        g_memDissectHistory.Push(oldAddr)
        while (g_memDissectHistory.Length > 64)
            g_memDissectHistory.RemoveAt(1)
        g_memDissectFwd := []              ; a successful new jump clears the forward stack
    }
    return st
}

; Resolve a named symbol (same set as MemDiff) and jump to it.
; customAddr is an Int64 only used when symbol = "Custom".
; Sets the root symbol + a matching PoE2Offsets struct template and starts a
; fresh offset chain (this address is the chain root).
MemDissectGotoSymbol(symbol, customAddr := 0)
{
    global g_memDissectStatus, g_memDissectStructName, g_memDissectRootSym, g_memDissectRootAddr, g_memDissectChain, g_memDissectSize
    addr := MemDiffResolveSymbol(symbol, customAddr)
    if (!addr)
    {
        g_memDissectStatus := "unresolved-symbol(" symbol ")"
        return g_memDissectStatus
    }
    g_memDissectStructName := _MemDissectStructForSymbol(symbol)
    g_memDissectRootSym    := symbol
    g_memDissectRootAddr   := addr
    g_memDissectChain      := []          ; new root — reset the followed-pointer path
    ; Auto-size to the struct so all its named fields are visible immediately
    ; (Go Symbol used to leave the size at 512 B, hiding e.g. PlayerInfo +0x598).
    asz := _MemDissectAutoSizeFor(g_memDissectStructName)
    if (asz)
        g_memDissectSize := asz
    return MemDissectGoto(addr)
}

; Map a dissector symbol to a same-named PoE2Offsets struct template, when one
; exists, so a symbol jump auto-annotates the view with known field names.
_MemDissectStructForSymbol(symbol)
{
    switch symbol
    {
        case "InGameState":         return "InGameState"
        case "AreaInstance":        return "AreaInstance"
        case "ServerDataStructure": return "ServerDataStructure"
        default:                    return ""
    }
}

; Apply (or clear with "" / "(none)") a PoE2Offsets struct template to the
; current view. Validates the name refers to a real struct Map.
MemDissectSetStruct(name)
{
    global g_memDissectStructName, g_memDissectStatus, g_memDissectSize, g_memDissectAddress
    name := Trim(String(name))
    if (name = "" || name = "(none)")
    {
        g_memDissectStructName := ""
        return g_memDissectStatus
    }
    ok := false
    try
    {
        v := PoE2Offsets.%name%
        if (Type(v) = "Map")
            ok := true
    }
    catch
    {
    }
    if !ok
    {
        g_memDissectStatus := "unknown-struct(" name ")"
        return g_memDissectStatus
    }
    g_memDissectStructName := name

    ; Auto-size the read window to cover the struct's largest field so the user
    ; never has to guess the size, then re-read so all named fields are visible.
    newSz := _MemDissectAutoSizeFor(name)
    if (newSz && newSz != g_memDissectSize)
    {
        g_memDissectSize := newSz
        if g_memDissectAddress
            return _MemDissectReadAt(g_memDissectAddress)
    }
    return g_memDissectStatus
}

; The read window size that covers a struct's largest field, snapped to a
; standard page size and capped at 4 KB for auto (a bigger struct can be enlarged
; manually) so applying a template never itself triggers the largest read.
; Returns 0 for an unknown/empty struct (leave the size as-is).
_MemDissectAutoSizeFor(structName)
{
    if (structName = "")
        return 0
    need := _MemDissectStructMaxOffset(structName) + 8
    if (need <= 0)
        return 0
    return Min(0x1000, _MemDissectSnapSize(need))
}

; Largest field byte-offset in a struct template (0 if unknown/empty).
_MemDissectStructMaxOffset(structName)
{
    maxOff := 0
    try
    {
        v := PoE2Offsets.%structName%
        if (Type(v) = "Map")
        {
            for _, foff in v
                if (IsInteger(foff) && foff > maxOff)
                    maxOff := foff
        }
    }
    catch
    {
    }
    return maxOff
}

; Snap a required byte count up to the smallest standard read window (matches
; the UI dropdown options), capped at 8 KB.
_MemDissectSnapSize(need)
{
    for _, sz in [0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000]
        if (need <= sz)
            return sz
    return 0x2000
}

; Enumerate every PoE2Offsets struct template (static Map property) by name.
; Used to populate the "Type as" dropdown so all 80+ known structs are pickable.
MemDissectStructNames()
{
    names := []
    for pname in PoE2Offsets.OwnProps()
    {
        try
        {
            v := PoE2Offsets.%pname%
            if (Type(v) = "Map")
                names.Push(pname)
        }
        catch
        {
        }
    }
    return names
}

; Build a row-offset → "Field(+0xNN) …" annotation Map for a struct template.
; Each row (of `stride` bytes) aggregates every struct field whose offset falls
; inside it. Returns an empty Map when structName is unset/unknown.
_MemDissectFieldAnnotations(structName, stride := 8)
{
    ann := Map()
    if (structName = "")
        return ann
    if (stride != 4 && stride != 8)
        stride := 8
    fields := 0
    try
    {
        v := PoE2Offsets.%structName%
        if (Type(v) = "Map")
            fields := v
    }
    catch
    {
        fields := 0
    }
    if !fields
        return ann
    for fname, foff in fields
    {
        if !IsInteger(foff)
            continue
        rowOff := (foff // stride) * stride
        label  := fname "(+0x" Format("{:X}", foff) ")"
        ann[rowOff] := ann.Has(rowOff) ? (ann[rowOff] " " label) : label
    }
    return ann
}

; ── Offset-chain workflow ───────────────────────────────────────────────────

; Jump to a user-typed absolute address. This is a NEW root, so the followed
; pointer path resets and the root becomes this raw address (no struct template).
MemDissectGotoCustom(addr)
{
    global g_memDissectRootSym, g_memDissectRootAddr, g_memDissectChain, g_memDissectStructName
    g_memDissectRootSym    := ""
    g_memDissectRootAddr   := addr
    g_memDissectChain      := []
    g_memDissectStructName := ""
    return MemDissectGoto(addr)
}

; Follow a pointer found at byte `off` within the current view to `addr`,
; recording the hop so the offset-chain breadcrumb grows (root +0x.. +0x..).
; Following a pointer leaves the current struct, so its field template is
; cleared — the annotations only made sense for the struct we came from.
MemDissectFollowPointer(off, addr)
{
    global g_memDissectChain, g_memDissectRootAddr, g_memDissectAddress, g_memDissectStructName
    ; If we somehow have no root yet, seed it from the current base address.
    if (!g_memDissectRootAddr)
        g_memDissectRootAddr := g_memDissectAddress
    g_memDissectStructName := ""           ; the old template no longer applies here
    st := MemDissectGoto(addr)
    ; Record the hop only if we actually landed on the target (read succeeded).
    if (g_memDissectAddress = addr)
        g_memDissectChain.Push(Map("off", off, "addr", addr))
    return st
}

; After a Back/Forward the shown address may no longer match the followed path,
; so re-root the breadcrumb to that raw address with an empty chain.
_MemDissectRebaseRoot(addr)
{
    global g_memDissectRootSym, g_memDissectRootAddr, g_memDissectChain
    g_memDissectRootSym  := ""
    g_memDissectRootAddr := addr
    g_memDissectChain    := []
}

; Human-readable offset chain, e.g. "AreaInstance → +0x30 → +0x18" or
; "0x1F2A3B00 → +0x10". Empty when there's no root yet.
_MemDissectChainString()
{
    global g_memDissectRootSym, g_memDissectRootAddr, g_memDissectChain
    if (!g_memDissectRootAddr && g_memDissectChain.Length = 0)
        return ""
    root := (g_memDissectRootSym != "") ? g_memDissectRootSym
          : (g_memDissectRootAddr ? Format("0x{:X}", g_memDissectRootAddr) : "?")
    s := root
    for step in g_memDissectChain
        s .= " → +0x" Format("{:X}", step["off"])
    return s
}

; Resolve a typed pointer chain and jump to its end. Accepts a root token
; (a known symbol, or a hex/decimal address) followed by one or more "+0xNN"
; hops; arrows/spaces are ignored. Each hop reads a 64-bit pointer at
; current+off and follows it. Rebuilds the breadcrumb to match.
MemDissectResolveChain(str)
{
    global g_reader, g_memDissectStatus, g_memDissectRootSym, g_memDissectRootAddr
    global g_memDissectChain, g_memDissectStructName

    str := Trim(String(str))
    if (str = "")
    {
        g_memDissectStatus := "empty-chain"
        return g_memDissectStatus
    }

    ; Normalize separators: turn arrows into '+' and strip whitespace, then split.
    s := StrReplace(str, "→", "+")
    s := StrReplace(s, "->", "+")
    s := StrReplace(s, " ", "")
    s := StrReplace(s, "`t", "")
    parts := StrSplit(s, "+")

    ; First non-empty token is the root; the rest are offsets.
    rootTok := ""
    while (parts.Length > 0 && rootTok = "")
        rootTok := Trim(parts.RemoveAt(1))
    if (rootTok = "")
    {
        g_memDissectStatus := "chain-no-root"
        return g_memDissectStatus
    }

    sym      := ""
    rootAddr := 0
    if (rootTok ~= "i)^(InGameState|AreaInstance|ServerDataStructure|GameUI)$")
    {
        sym      := rootTok
        rootAddr := MemDiffResolveSymbol(rootTok, 0)
    }
    else
    {
        rootAddr := _ParseHexAddr(rootTok)
    }
    if (!rootAddr)
    {
        g_memDissectStatus := "chain-root-unresolved(" rootTok ")"
        return g_memDissectStatus
    }

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        g_memDissectStatus := "not-connected"
        return g_memDissectStatus
    }

    chain := []
    cur   := rootAddr
    for tok in parts
    {
        if (Trim(tok) = "")
            continue
        off := _ParseHexAddr(tok)
        nxt := 0
        try nxt := g_reader.Mem.ReadInt64(cur + off)
        if (!nxt || nxt < 0x10000)
        {
            g_memDissectStatus := "chain-null @ +0x" Format("{:X}", off)
            return g_memDissectStatus
        }
        chain.Push(Map("off", off, "addr", nxt))
        cur := nxt
    }

    g_memDissectRootSym    := sym
    g_memDissectRootAddr   := rootAddr
    g_memDissectChain      := chain
    g_memDissectStructName := (sym != "") ? _MemDissectStructForSymbol(sym) : ""
    return _MemDissectReadAt(cur)
}

; ── Value scan (within the current view's buffer) ───────────────────────────

; Scans the current dissector buffer for `valueStr` interpreted as `typ`
; (i32 | u32 | f32 | i64 | hex | str) at EVERY byte offset. Returns a JSON
; array of matches [{off, at, addr}] where off = the 8-byte row the match
; starts in, at = the exact byte offset, addr = its absolute address. Sets the
; status to the match count. Empty array on no data / parse failure.
MemDissectScan(valueStr, typ)
{
    global g_memDissectBuf, g_memDissectAddress, g_memDissectStatus, g_memDissectStride

    stride := (g_memDissectStride = 4) ? 4 : 8   ; align matches to the visible rows
    valueStr := Trim(String(valueStr))
    typ := StrLower(Trim(String(typ)))
    if (valueStr = "")
    {
        g_memDissectStatus := "scan-empty"
        return "[]"
    }

    buf := g_memDissectBuf
    if !(IsObject(buf) && Type(buf) = "Buffer" && buf.Size >= 1)
    {
        g_memDissectStatus := "scan-no-data"
        return "[]"
    }
    p    := buf.Ptr
    n    := buf.Size
    base := g_memDissectAddress

    ; Build the target byte pattern (for hex/str) or numeric compare params.
    matches := []
    seen    := Map()

    if (typ = "hex" || typ = "str")
    {
        pat := (typ = "hex") ? _MemDissectParseHexBytes(valueStr) : _MemDissectStrBytes(valueStr)
        w := pat.Length
        if (w < 1)
        {
            g_memDissectStatus := "scan-bad-pattern"
            return "[]"
        }
        i := 0
        while (i + w <= n)
        {
            ok := true
            j := 0
            while (j < w)
            {
                if (NumGet(p, i + j, "UChar") != pat[j + 1])
                {
                    ok := false
                    break
                }
                j += 1
            }
            if ok
                _MemDissectPushMatch(matches, seen, i, base, stride)
            i += 1
        }
    }
    else
    {
        ; Numeric scan.
        ntype := ""
        w := 4
        target := 0
        ftarget := 0.0
        isFloat := false
        switch typ
        {
            case "i32": ntype := "Int",   w := 4
            case "u32": ntype := "UInt",  w := 4
            case "i64": ntype := "Int64", w := 8
            case "f32": ntype := "Float", w := 4, isFloat := true
            default:
                g_memDissectStatus := "scan-bad-type(" typ ")"
                return "[]"
        }
        if isFloat
            ftarget := valueStr + 0.0
        else
            target := _ParseHexOrDec(valueStr)

        i := 0
        while (i + w <= n)
        {
            v := NumGet(p, i, ntype)
            hit := isFloat ? (Abs(v - ftarget) < 0.0001) : (v = target)
            if hit
                _MemDissectPushMatch(matches, seen, i, base, stride)
            i += 1
        }
    }

    ; Build JSON.
    json  := "["
    first := true
    for m in matches
    {
        if !first
            json .= ","
        first := false
        json .= "{"
            . '"off":' m["off"] ","
            . '"at":' m["at"] ","
            . '"addr":"0x' Format("{:X}", m["addr"]) '"'
            . "}"
    }
    json .= "]"

    g_memDissectStatus := matches.Length " match(es) for " typ " '" valueStr "'"
    return json
}

; Records a match at byte offset `at`, deduped by the row it falls in. rowOff is
; aligned to the current stride (4 or 8) so the chip lands on the exact table row
; — in 4-byte mode a hit at +0xC4 stays +0xC4 (not floored to the 8-byte +0xC0).
_MemDissectPushMatch(matches, seen, at, base, stride := 8)
{
    rowOff := (at // stride) * stride
    if seen.Has(rowOff)
        return
    seen[rowOff] := 1
    matches.Push(Map("off", rowOff, "at", at, "addr", base + at))
}

; "AA BB 0xCC ..." → [0xAA, 0xBB, 0xCC]. Ignores separators/0x prefixes.
_MemDissectParseHexBytes(s)
{
    s := StrReplace(s, "0x", "")
    s := StrReplace(s, "0X", "")
    s := RegExReplace(s, "[^0-9A-Fa-f]", "")   ; keep hex digits only
    out := []
    i := 1
    n := StrLen(s)
    while (i + 1 <= n)
    {
        out.Push(Integer("0x" SubStr(s, i, 2)))
        i += 2
    }
    return out
}

; ASCII string → array of byte codes.
_MemDissectStrBytes(s)
{
    out := []
    for _, code in StrSplit(s)
        out.Push(Ord(code) & 0xFF)
    return out
}

; Accepts "0x1F", "-5", "42". Hex when it has a 0x prefix, else decimal.
_ParseHexOrDec(s)
{
    s := Trim(String(s))
    if (s = "")
        return 0
    try
        return Integer(s)
    catch
        return _ParseHexAddr(s)
}

; Navigate back to the previously visited address.
; Pushes the current address onto the forward stack.
MemDissectBack()
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus
    if (g_memDissectHistory.Length = 0)
    {
        g_memDissectStatus := "no-history"
        return g_memDissectStatus
    }
    if (g_memDissectAddress)
        g_memDissectFwd.Push(g_memDissectAddress)
    target := g_memDissectHistory.Pop()
    _MemDissectRebaseRoot(target)   ; Back/Forward re-root the chain to the shown address
    return _MemDissectReadAt(target)
}

; Navigate forward (undo a Back).
; Pushes the current address onto the back stack.
MemDissectForward()
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus
    if (g_memDissectFwd.Length = 0)
    {
        g_memDissectStatus := "no-forward"
        return g_memDissectStatus
    }
    if (g_memDissectAddress)
        g_memDissectHistory.Push(g_memDissectAddress)
    target := g_memDissectFwd.Pop()
    _MemDissectRebaseRoot(target)
    return _MemDissectReadAt(target)
}

; Re-read the current address without touching the navigation stacks.
MemDissectReread()
{
    global g_memDissectAddress, g_memDissectStatus
    if (!g_memDissectAddress)
    {
        g_memDissectStatus := "no-address"
        return g_memDissectStatus
    }
    return _MemDissectReadAt(g_memDissectAddress)
}

; ── Internal ──────────────────────────────────────────────────────────────

; Reads g_memDissectSize bytes at addr and updates the global buffer + status.
; Does NOT touch the history or forward stacks — callers manage those.
_MemDissectReadAt(addr)
{
    global g_reader, g_memDissectAddress, g_memDissectSize, g_memDissectBuf, g_memDissectStatus

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        g_memDissectStatus := "not-connected"
        return g_memDissectStatus
    }

    sz  := g_memDissectSize

    ; Forensic breadcrumb for the non-reproducible 8 KB crash: log large reads
    ; (throttled) so if an uncatchable SEH ever kills the app mid-read, the LAST
    ; error-log line pins the size + address. Cheap + bounded (≤1 line / 2 s).
    static _lastBigReadLogTick := 0
    if (sz >= 0x800)
    {
        _nowTick := A_TickCount
        if (_nowTick - _lastBigReadLogTick > 2000)
        {
            _lastBigReadLogTick := _nowTick
            try LogError("MemDissect read start size=" sz " @ 0x" Format("{:X}", addr))
        }
    }

    buf := _MemDissectPageAwareRead(addr, sz)
    if !buf
    {
        g_memDissectStatus := "read-failed @ 0x" Format("{:X}", addr)
        return g_memDissectStatus
    }

    g_memDissectAddress := addr
    g_memDissectBuf     := buf
    g_memDissectStatus  := (buf.Size = sz) ? "ok" : ("ok partial " buf.Size " B / " sz)
    return g_memDissectStatus
}

; Reads up to `maxSize` bytes starting at `addr` while gracefully handling
; the case where the requested range straddles an uncommitted memory page.
; Strategy: read the first chunk only up to the next 4 KB boundary, then
; extend page-by-page until the requested size is met or a read fails.
;
; ReadProcessMemory's behaviour when a range crosses a committed →
; uncommitted boundary is version-dependent — on some Windows versions it
; returns the partial bytes, on others it fails the whole call with
; bytesRead=0. By splitting the request along page boundaries we get
; deterministic "largest contiguous prefix" semantics regardless.
;
; Returns: Buffer of size ≤ maxSize (≥ 1) on success, 0 if even the first
; byte at `addr` is unreadable.
_MemDissectPageAwareRead(addr, maxSize)
{
    global g_reader
    if (!addr || maxSize <= 0)
        return 0

    pageSize := 0x1000

    ; First chunk = bytes from addr to the next page boundary, capped at maxSize.
    firstChunkSize := pageSize - Mod(addr, pageSize)
    if (firstChunkSize > maxSize)
        firstChunkSize := maxSize

    firstBuf := g_reader.Mem.ReadBytes(addr, firstChunkSize, true)
    if !firstBuf
        return 0   ; even the first page slice unreadable

    totalRead := firstBuf.Size
    ; If we already have everything, done.
    if (totalRead >= maxSize)
        return firstBuf
    ; If the first chunk was short, no point continuing — boundary hit.
    if (totalRead < firstChunkSize)
        return firstBuf

    ; Allocate result buffer at the full requested size and copy the prefix.
    ; We'll trim it down at the end if we couldn't fill it.
    result := Buffer(maxSize, 0)
    DllCall("RtlMoveMemory", "Ptr", result.Ptr, "Ptr", firstBuf.Ptr, "UPtr", totalRead)

    nextAddr := addr + totalRead
    while (totalRead < maxSize)
    {
        chunkSize := pageSize
        if (totalRead + chunkSize > maxSize)
            chunkSize := maxSize - totalRead

        chunkBuf := g_reader.Mem.ReadBytes(nextAddr, chunkSize, true)
        if !chunkBuf
            break   ; hit unmapped page

        DllCall("RtlMoveMemory", "Ptr", result.Ptr + totalRead, "Ptr", chunkBuf.Ptr, "UPtr", chunkBuf.Size)
        totalRead += chunkBuf.Size
        nextAddr  += chunkBuf.Size

        ; Short read inside the chunk also means we hit a boundary.
        if (chunkBuf.Size < chunkSize)
            break
    }

    ; If we filled the full request, return the result buffer as-is.
    if (totalRead >= maxSize)
        return result

    ; Otherwise return a tightly-sized buffer containing what we did read.
    trimmed := Buffer(totalRead, 0)
    DllCall("RtlMoveMemory", "Ptr", trimmed.Ptr, "Ptr", result.Ptr, "UPtr", totalRead)
    return trimmed
}

; Parses a hex/decimal address string into an Int64. Returns 0 on failure.
; Accepts: "0x1A2B3C", "1A2B3C" (assumed hex if hex chars present), or decimal.
; AHK v2's Integer() understands the "0x..." prefix natively, but throws on
; invalid input — we swallow that and fall back to a manual hex walk so the
; bridge never propagates a parse failure that wedges the dispatcher.
_ParseHexAddr(s)
{
    s := Trim(String(s))
    if (s = "")
        return 0
    ; Try AHK's native Integer() first — handles "0x..." and decimals directly.
    try
    {
        v := Integer(s)
        if (v != 0 || s = "0")
            return v
    }
    catch
    {
        ; fall through to manual hex parse below
    }
    ; Manual hex parse for safety: strip optional 0x, then walk digits.
    hex := s
    if (SubStr(hex, 1, 2) = "0x" || SubStr(hex, 1, 2) = "0X")
        hex := SubStr(hex, 3)
    hex := StrUpper(hex)
    out := 0
    i := 1
    n := StrLen(hex)
    while (i <= n)
    {
        c  := SubStr(hex, i, 1)
        cc := Ord(c)
        if (cc >= 48 && cc <= 57)
            d := cc - 48
        else if (cc >= 65 && cc <= 70)
            d := cc - 55
        else
            return 0   ; unknown char: bail
        out := out * 16 + d
        i += 1
    }
    return out
}

; Wrapper used by the bridge dispatcher: runs the supplied operation, catches
; any exception (logging it to error.log), then always pushes the latest
; dissector state to the WebView so the UI reflects any status change — even
; when the read failed.
_SafeDissect(opFn, label)
{
    global g_memDissectStatus
    try
    {
        opFn.Call()
    }
    catch as ex
    {
        msg := ex.HasOwnProp("Message") ? ex.Message : "?"
        g_memDissectStatus := label "-exception: " msg
        try LogError(label " exception: " msg)
    }
    ; Final push wrapped with explicit catch — `try Foo()` (no catch) is OK
    ; in AHK v2 but a paired try/catch makes the intent unambiguous and lets
    ; us log any push-side failure rather than silently swallowing it.
    try
    {
        PushMemDissectToWebView()
    }
    catch as ex2
    {
        try LogError(label " push exception: " (ex2.HasOwnProp("Message") ? ex2.Message : "?"))
    }
}

; ── Stage 5: on-demand pointer-target decode ("peek") ───────────────────────
; Resolve what a SINGLE pointer points to, only when the user clicks its 🔍
; button. Exactly ONE small read per invocation — never in the build loop, never
; on the live-refresh path (the safe _DecodeComponentOnDemand pattern). Classifies
; the target as entity / wstring / string / vector-guess / raw data and pushes the
; result to updateMemDissectPeek in the WebView.
MemDissectPeek(addr)
{
    global g_reader
    result := Map("addr", Format("0x{:X}", addr), "kind", "", "text", "", "hex", "")

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        result["kind"] := "not-connected"
        _MemDissectPushPeek(result)
        return
    }
    if (!addr || addr < 0x10000)
    {
        result["kind"] := "null"
        _MemDissectPushPeek(result)
        return
    }

    ; A canonical (module-range) address is code / a vtable, not data.
    if (addr >= 0x00007FF000000000)
    {
        result["kind"] := "code"
        result["text"] := "code / vtable pointer"
        _MemDissectPeekHex(result, addr)
        _MemDissectPushPeek(result)
        return
    }

    ; 1) Entity? (the most valuable + specific — real paths start with "Metadata/")
    try
    {
        idm := g_reader.ReadEntityIdentityBasic(addr)
        if (IsObject(idm) && idm.Has("path") && idm["path"] != "" && InStr(idm["path"], "Metadata/"))
        {
            result["kind"] := "entity"
            result["text"] := idm["path"]
            _MemDissectPushPeek(result)
            return
        }
    }
    catch
    {
    }

    ; 2) std::wstring struct (handles SSO)?
    try
    {
        ws := g_reader.ReadStdWStringAt(addr, 200)
        if (ws != "" && _MemDissectLooksText(ws))
        {
            result["kind"] := "wstr"
            result["text"] := ws
            _MemDissectPushPeek(result)
            return
        }
    }
    catch
    {
    }

    ; 3) raw UTF-16 buffer at the target?
    try
    {
        us := g_reader.Mem.ReadUnicodeString(addr, 160)
        if (StrLen(us) >= 2 && _MemDissectLooksText(us))
        {
            result["kind"] := "wstr(raw)"
            result["text"] := us
            _MemDissectPushPeek(result)
            return
        }
    }
    catch
    {
    }

    ; 4) std::string (UTF-8) struct?
    try
    {
        ss := g_reader.ReadStdStringAt(addr, 200)
        if (ss != "" && _MemDissectLooksText(ss))
        {
            result["kind"] := "str"
            result["text"] := ss
            _MemDissectPushPeek(result)
            return
        }
    }
    catch
    {
    }

    ; 5) std::vector guess — begin/end pointers at +0x00/+0x08 with a sane span.
    try
    {
        beginP := g_reader.Mem.ReadInt64(addr)
        endP   := g_reader.Mem.ReadInt64(addr + 8)
        if (g_reader.IsProbablyValidPointer(beginP) && g_reader.IsProbablyValidPointer(endP) && endP > beginP)
        {
            span := endP - beginP
            if (span > 0 && span <= 0x4000000)
            {
                result["kind"] := "vector?"
                result["text"] := "span=" span " B  (÷8=" (span // 8) "  ÷4=" (span // 4) "  ÷0x38=" (span // 0x38) ")"
                _MemDissectPushPeek(result)
                return
            }
        }
    }
    catch
    {
    }

    ; 6) Fallback: raw hex preview of the first bytes.
    result["kind"] := "data"
    _MemDissectPeekHex(result, addr)
    _MemDissectPushPeek(result)
}

; Reads 32 bytes at addr into result["hex"]; if the first qword is itself a
; plausible pointer, notes it in result["text"] (a nested-pointer hint).
_MemDissectPeekHex(result, addr)
{
    global g_reader
    buf := g_reader.Mem.ReadBytes(addr, 32, true)
    if (buf && Type(buf) = "Buffer" && buf.Size >= 1)
    {
        hex := ""
        i := 0
        n := Min(buf.Size, 32)
        while (i < n)
        {
            hex .= Format("{:02X} ", NumGet(buf.Ptr, i, "UChar"))
            i += 1
        }
        result["hex"] := RTrim(hex)
        if (buf.Size >= 8)
        {
            q := NumGet(buf.Ptr, 0, "Int64")
            if (g_reader.IsProbablyValidPointer(q))
                result["text"] := (result["text"] != "" ? result["text"] " · " : "") "first qword → 0x" Format("{:X}", q)
        }
    }
}

; Heuristic: is `s` plausibly human-readable text (no control chars, length ≥ 2)?
; Rejects the garbage a struct-shaped-but-not-a-string read can occasionally yield.
_MemDissectLooksText(s)
{
    if (StrLen(s) < 2)
        return false
    for _, ch in StrSplit(s)
    {
        c := Ord(ch)
        if (c < 32 || (c >= 127 && c <= 159))   ; C0 / C1 control ranges
            return false
    }
    return true
}

; Serializes a peek result and pushes it to updateMemDissectPeek in the WebView.
_MemDissectPushPeek(result)
{
    global g_webViewReady
    if !g_webViewReady
        return
    json := "{"
        . '"addr":' _JsStr(result["addr"]) ","
        . '"kind":' _JsStr(result["kind"]) ","
        . '"text":' _JsStr(result["text"]) ","
        . '"hex":' _JsStr(result["hex"])
        . "}"
    try WebViewExec("updateMemDissectPeek(" _JsStr(json) ")")
}
