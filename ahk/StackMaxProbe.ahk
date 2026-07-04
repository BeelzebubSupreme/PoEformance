; StackMaxProbe.ahk
; TEMPORARY in-game diagnostic — NOT part of the per-frame hot path.
;
; Tests the hypothesis that a stackable item's MAXIMUM stack size lives on the
; Stack component at +0x20 (Count is the known field at +0x18). For every
; backpack item that HAS a Stack component it prints an interpreted int32 table
; around the component base (0x00..0x40), flagging +0x18 (Count) and +0x20 (the
; max-size candidate), plus a raw hex window; it also derefs the Stack
; component's UnknownPtr (+0x10) and dumps that region, since the max size might
; instead live in a referenced StackData / dat row.
;
; Owner test case: a single stack of 19 Scrolls of Wisdom (real max 40) — so a
; correct max-size field must read 40 for that item.
;
; Reuses _HPP_HexDump (PathfindingProbe.ahk) + _SmResolveServerData (StashMover.ahk)
; + _AIP_WriteProbeLog (AreaInstanceProbe.ahk). Trigger from Config → Debug →
; Diagnostic Actions. Included by InGameStateMonitor.ahk.

; Interpreted int32 table for the Stack component base region. Reads one 0x40
; block once and prints each 4-byte offset as signed/unsigned int, marking the
; known Count and the max-size candidate. Returns the text. Params: reader,
; base (component address).
_StkProbeInterpret(reader, base)
{
    b := reader.Mem.ReadBytes(base, 0x40, true)
    if !b
        return "    <read failed @0x" Format("{:X}", base) ">`r`n"
    out := ""
    off := 0x00
    while (off < 0x40)
    {
        if (off + 4 <= b.Size)
        {
            v := NumGet(b.Ptr, off, "Int")
            uv := NumGet(b.Ptr, off, "UInt")
            tag := ""
            if (off = 0x18)
                tag := "   <-- Count (known)"
            else if (off = 0x20)
                tag := "   <-- MAX-SIZE candidate"
            out .= Format("    +0x{:02X}: int={:<12} uint={:<12}{}`r`n", off, v, uv, tag)
        }
        off += 4
    }
    return out
}

; Stack max-size probe: enumerate backpack items, and for each with a Stack
; component dump the component region + the interpreted int table + the
; UnknownPtr(+0x10) target. Writes a probe log and shows a short summary.
; No params, no return.
StackMaxProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Stack-max probe: not connected to PoE2.", "Stack Max Probe", "Iconx")
        return
    }
    reader := g_reader

    sdPtr := 0
    try sdPtr := _SmResolveServerData()
    if !(sdPtr && reader.IsProbablyValidPointer(sdPtr))
    {
        try MsgBox("Stack-max probe: could not resolve ServerData (open the game / let the radar run a moment).", "Stack Max Probe", "Iconx")
        return
    }

    invs := 0
    try invs := reader.ReadAllPlayerInventories(sdPtr)
    if !(invs && Type(invs) = "Array")
    {
        try MsgBox("Stack-max probe: ReadAllPlayerInventories failed.", "Stack Max Probe", "Iconx")
        return
    }

    nl := "`r`n"
    rpt := "=== Stack max-size probe ===" nl
    rpt .= "Hypothesis: Stack component +0x20 = maximum stack size (Count is +0x18)." nl
    rpt .= "ServerData=0x" Format("{:X}", sdPtr) nl nl

    stackOff := PoE2Offsets.Stack["Count"]        ; 0x18
    unkOff   := PoE2Offsets.Stack["UnknownPtr"]   ; 0x10
    found := 0
    summary := ""

    for _, inv in invs
    {
        if !(inv && IsObject(inv) && inv.Has("inventoryId"))
            continue
        invId := inv["inventoryId"]
        items := inv.Has("items") ? inv["items"] : 0
        if !(items && Type(items) = "Array")
            continue

        for __, it in items
        {
            if !(it && IsObject(it) && it.Has("itemEntityPtr"))
                continue
            itemPtr := it["itemEntityPtr"]
            if !(itemPtr && reader.IsProbablyValidPointer(itemPtr))
                continue

            sp := 0
            try sp := reader.FindEntityComponentAddress(itemPtr, "Stack")
            if !(sp && reader.IsProbablyValidPointer(sp))
                continue    ; non-stackable — no Stack component

            found += 1
            ; Item label + reader-side count for cross-checking.
            det := it.Has("itemDetails") ? it["itemDetails"] : 0
            name := (det && IsObject(det) && det.Has("displayName")) ? det["displayName"] : "?"
            cnt := 0
            try cnt := reader.Mem.ReadInt(sp + stackOff)
            cand := 0
            try cand := reader.Mem.ReadInt(sp + 0x20)

            rpt .= "── inv " invId " item: " name nl
            rpt .= "   itemEntity=0x" Format("{:X}", itemPtr) "   Stack@0x" Format("{:X}", sp) nl
            rpt .= "   Count(+0x18)=" cnt "   candidate(+0x20)=" cand nl
            rpt .= "   interpreted int32 table:" nl
            rpt .= _StkProbeInterpret(reader, sp)
            rpt .= "   raw hex (Stack +0x00..0x40):" nl
            rpt .= _HPP_HexDump(reader, sp, 0x40, 0x00)

            ; Deref UnknownPtr (+0x10) — the max size might live in a referenced row.
            unk := 0
            try unk := reader.Mem.ReadPtr(sp + unkOff)
            if (unk && reader.IsProbablyValidPointer(unk))
            {
                rpt .= "   UnknownPtr(+0x10) -> 0x" Format("{:X}", unk) "  int32 table:" nl
                rpt .= _StkProbeInterpret(reader, unk)
                rpt .= "   UnknownPtr raw hex (+0x00..0x40):" nl
                rpt .= _HPP_HexDump(reader, unk, 0x40, 0x00)
            }
            else
                rpt .= "   UnknownPtr(+0x10) not a valid pointer (0x" Format("{:X}", unk) ")" nl

            rpt .= nl
            summary .= "• " name ": Count=" cnt "  +0x20=" cand nl
        }
    }

    if (found = 0)
    {
        rpt .= "No backpack item had a Stack component (stand with a stackable item in your inventory)." nl
        summary := "No stackable item found in the backpack."
    }

    path := A_ScriptDir "\logs\InGameStateMonitor.stack_max_probe.log"
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
        }
    }

    msg := "Stack max-size probe — " found " stackable item(s):" nl nl summary
    msg .= nl "Full dump (readable in Config → Data & Logs):" nl path
    try MsgBox(msg, "Stack Max Probe", "Iconi")
}
