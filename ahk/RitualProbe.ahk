; RitualProbe.ahk
; RE diagnostic for the Ritual ("Favours") reward window. The generic cursor hit-test
; (UiTree_HitTest) follows only the single top-most child per level, so it dead-ends on the
; full-screen "notification_display" layer and never reaches the ritual reward slots. This
; probe takes a direct route instead: find the RitualWindow UiElement by StringId, BFS its
; subtree and report every node (StringId / rect / kids / item at +0x4F8), PLUS a raw
; pointer-scan of the window struct for any Metadata/Items entity pointers (in case the
; rewards are a struct item-list rather than child item slots). Output -> a log + a MsgBox.
; Open the Ritual (Favours) window first, then trigger (bridge: RitualProbeRun).
; Included by InGameStateMonitor.ahk.

; Finds the best "ritual"-named UiElement under the GameUI root (most children wins, so a
; container beats a label). Breadth-first, capped by node count + time. Returns the element
; ptr or 0. Params: reader (g_reader), root (GameUI root ptr).
_RitualFindWindow(reader, root)
{
    best := 0, bestKids := -1
    queue := [root], visited := Map(), seen := 0
    deadline := A_TickCount + 4000
    while (queue.Length > 0 && seen < 6000)
    {
        if (A_TickCount > deadline)
            break
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        seen += 1
        el := UiTree_ReadElement(reader, ptr)
        if !IsObject(el)
            continue
        sid := el["stringId"]
        if (sid != "" && InStr(sid, "ritual"))   ; InStr is case-insensitive by default
        {
            if (el["childCount"] > bestKids)
            {
                best := ptr
                bestKids := el["childCount"]
            }
        }
        cf := el["childFirst"], cl := el["childLast"]
        if (reader.IsProbablyValidPointer(cf) && cl > cf)
        {
            n := Min((cl - cf) // A_PtrSize, 512)
            buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
            if buf
            {
                Loop n
                {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }
    return best
}

; Returns "rarity=<id> path=<...>" when <entPtr> resolves to a Metadata/Items entity, else
; "". Params: reader, entPtr (candidate item-entity pointer).
_RitualItemPathAt(reader, entPtr)
{
    det := 0
    try det := reader.Mem.ReadPtr(entPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
    if !(det && reader.IsProbablyValidPointer(det))
        return ""
    p := ""
    try p := reader.ReadStdWStringAt(det + PoE2Offsets.EntityDetails["Path"])
    if (SubStr(p, 1, 14) != "Metadata/Items")
        return ""
    rar := -1
    try rar := reader.ReadItemRarity(entPtr)
    return "rarity=" rar " path=" p
}

; Writes the report to logs\InGameStateMonitor.ritual_probe.log (UTF-8, overwrite).
; Param: text (the full report string). No return.
_RitualWriteLog(text)
{
    p := A_ScriptDir "\logs\InGameStateMonitor.ritual_probe.log"
    try
    {
        f := FileOpen(p, "w", "UTF-8")
        if IsObject(f)
        {
            f.Write(text)
            f.Close()
        }
    }
}

; One-shot Ritual reward-window probe (see file header). No params / no return; reports via
; a log file + MsgBox. Open the Favours window first, then run.
RitualProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Ritual probe: not connected to PoE2.", "Ritual Probe", "Iconx")
        return
    }
    reader := g_reader
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — open the game / let the radar run, then retry.", "Ritual Probe", "Iconx")
        return
    }

    nl := "`r`n"
    rw := _RitualFindWindow(reader, root)
    rpt := "=== Ritual reward window probe ===" nl
    rpt .= "GameUI root=0x" Format("{:X}", root) nl
    if !rw
    {
        rpt .= nl "No UiElement with a 'ritual' StringId found under the root." nl
            . "Open the Ritual (Favours) window, then run again. If it IS open and still" nl
            . "not found, the StringId differs — tell me and I'll widen the search." nl
        _RitualWriteLog(rpt)
        try MsgBox("Ritual window not found by StringId. Is the Favours window open? See log.", "Ritual Probe", "Iconx")
        return
    }

    rwEl := UiTree_ReadElement(reader, rw)
    rpt .= "RitualWindow=0x" Format("{:X}", rw) "  id=" rwEl["stringId"]
        . "  vis=" (rwEl["isVisible"] ? 1 : 0) "  kids=" rwEl["childCount"] nl nl

    ; --- (A) subtree BFS: report nodes; mark any with an item entity at +0x4F8 ---
    rpt .= "--- SUBTREE (depth<=8) — slots with an item at +0x4F8 are marked <<ITEM ---" nl
    itemCount := 0
    queue := [{ptr: rw, depth: 0}], visited := Map(), nodes := 0
    deadline := A_TickCount + 6000
    while (queue.Length > 0 && nodes < 600)
    {
        if (A_TickCount > deadline)
            break
        cur := queue.RemoveAt(1)
        ptr := cur.ptr, depth := cur.depth
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        el := UiTree_ReadElement(reader, ptr)
        if !IsObject(el)
            continue
        sp := UiTree_GetScreenPos(reader, ptr)
        indent := ""
        Loop depth
            indent .= "  "
        rpt .= indent "[" depth "] 0x" Format("{:X}", ptr)
            . " id=" (el["stringId"] != "" ? el["stringId"] : "-")
            . " pos=" Round(sp["x"]) "," Round(sp["y"]) " size=" Round(el["sizeW"]) "x" Round(el["sizeH"])
            . " vis=" (el["isVisible"] ? 1 : 0) " kids=" el["childCount"]
        itemLine := _UiHoverItemAt(reader, ptr)   ; reuses the +0x4F8 reader from UiHoverProbe
        if (itemLine != "")
        {
            rpt .= "  <<ITEM " itemLine
            itemCount += 1
        }
        rpt .= nl
        if (depth < 8 && el["childCount"] > 0)
        {
            cf := el["childFirst"], cl := el["childLast"]
            if (reader.IsProbablyValidPointer(cf) && cl > cf)
            {
                n := Min((cl - cf) // A_PtrSize, 256)
                buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
                if buf
                {
                    Loop n
                    {
                        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                        if (reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                            queue.Push({ptr: cp, depth: depth + 1})
                    }
                }
            }
        }
    }
    rpt .= nl "Subtree item-slots (+0x4F8) found: " itemCount "  (nodes scanned: " nodes ")" nl

    ; --- (B) raw struct pointer scan: any Metadata/Items entity pointer in the window struct
    ; (covers the case where rewards are a struct item-list, not child item slots) ---
    rpt .= nl "--- STRUCT POINTER SCAN (RitualWindow +0x000..+0x800, 8-byte stride) ---" nl
    structHits := 0
    sbuf := 0
    try sbuf := reader.Mem.ReadBytes(rw, 0x800)
    if sbuf
    {
        off := 0
        while (off < 0x800)
        {
            cand := NumGet(sbuf.Ptr, off, "Ptr")
            if (reader.IsProbablyValidPointer(cand))
            {
                p := _RitualItemPathAt(reader, cand)
                if (p != "")
                {
                    rpt .= "  +0x" Format("{:X}", off) " -> " p nl
                    structHits += 1
                }
            }
            off += 0x08
        }
    }
    if (structHits = 0)
        rpt .= "  (no direct Metadata/Items entity pointer in the first 0x800 bytes)" nl
    rpt .= nl "Struct item-pointer hits: " structHits nl

    _RitualWriteLog(rpt)
    summary := "Ritual probe done." nl nl
        . "RitualWindow: 0x" Format("{:X}", rw) " (id=" rwEl["stringId"] ", kids=" rwEl["childCount"] ")" nl
        . "Subtree item-slots (+0x4F8): " itemCount nl
        . "Struct item-pointers: " structHits nl nl
        . "Log: logs\InGameStateMonitor.ritual_probe.log" nl nl
        . (itemCount > 0
            ? "-> Rewards are child item-slots; I can enumerate them for badges."
            : (structHits > 0
                ? "-> Rewards are a struct item-list; I'll read them from the window struct."
                : "-> Neither route hit; paste the log and I'll widen the search."))
    try MsgBox(summary, "Ritual Probe - result", "Iconi")
}
