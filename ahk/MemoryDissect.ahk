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

    ; Push old address to history before the jump (skip if same address — refresh)
    if (g_memDissectAddress && g_memDissectAddress != addr)
    {
        g_memDissectHistory.Push(g_memDissectAddress)
        ; Cap history at 64 entries
        while (g_memDissectHistory.Length > 64)
            g_memDissectHistory.RemoveAt(1)
        g_memDissectFwd := []   ; new jump clears forward stack
    }

    return _MemDissectReadAt(addr)
}

; Resolve a named symbol (same set as MemDiff) and jump to it.
; customAddr is an Int64 only used when symbol = "Custom".
; Sets the root symbol + a matching PoE2Offsets struct template and starts a
; fresh offset chain (this address is the chain root).
MemDissectGotoSymbol(symbol, customAddr := 0)
{
    global g_memDissectStatus, g_memDissectStructName, g_memDissectRootSym, g_memDissectRootAddr, g_memDissectChain
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
    global g_memDissectStructName, g_memDissectStatus
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
    return g_memDissectStatus
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
; Each 8-byte row aggregates every struct field whose offset falls inside it.
; Returns an empty Map when structName is unset/unknown.
_MemDissectFieldAnnotations(structName)
{
    ann := Map()
    if (structName = "")
        return ann
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
        rowOff := (foff // 8) * 8
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
MemDissectFollowPointer(off, addr)
{
    global g_memDissectChain, g_memDissectRootAddr, g_memDissectAddress
    ; If we somehow have no root yet, seed it from the current base address.
    if (!g_memDissectRootAddr)
        g_memDissectRootAddr := g_memDissectAddress
    g_memDissectChain.Push(Map("off", off, "addr", addr))
    return MemDissectGoto(addr)
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
    global g_memDissectBuf, g_memDissectAddress, g_memDissectStatus

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
                _MemDissectPushMatch(matches, seen, i, base)
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
                _MemDissectPushMatch(matches, seen, i, base)
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

; Records a match at byte offset `at`, deduped by its 8-byte row.
_MemDissectPushMatch(matches, seen, at, base)
{
    rowOff := (at // 8) * 8
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
