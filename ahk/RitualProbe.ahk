; RitualProbe.ahk
; RE diagnostic for item slots in non-inventory windows (Ritual "Favours" rewards in
; particular). The generic cursor hit-test dead-ends on the full-screen notification
; layer, and searching by a "ritual" StringId matches the wrong element (the
; RitualRuneInteractable tooltip), so this takes the robust route: a TREE-WIDE sweep of
; the whole GameUI that tests every element's +0x4F8 (UiElementBase.ItemPtr) and reports
; each one that resolves to a real Metadata/Items entity, with its screen position + size
; + StringId. The ritual reward cells (a left-of-centre cluster, ~78x78) are then obvious
; by position vs. the inventory/stash slots on the right. Output -> a log + a MsgBox.
; Open the Ritual (Favours) window first, then trigger (bridge: RitualProbeRun).
; Included by InGameStateMonitor.ahk.

; Returns "rarity=<id> path=<...>" when <entPtr> resolves to a Metadata/Items entity, else
; "". Params: reader (g_reader), entPtr (candidate item-entity pointer).
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

; Sweeps the whole UI tree under <root>, collecting every element that holds a Metadata/
; Items entity at +0x4F8. Cheap per node (one header read + one pointer read); the parent-
; walk for screen position only runs for hits. Capped by node count + time. Returns
; Map("hits", [ Map(addr,x,y,w,h,sid,item) … ], "nodes", scannedCount). Params: reader, root.
_RitualSweepItemSlots(reader, root)
{
    hits := []
    itemOff := PoE2Offsets.UiElementBase["ItemPtr"]
    sidOff  := PoE2Offsets.UiElementBase["StringIdPtr"]
    queue := [root], visited := Map(), nodes := 0
    deadline := A_TickCount + 8000
    while (queue.Length > 0 && nodes < 9000)
    {
        if (A_TickCount > deadline)
            break
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue

        ip := 0
        try ip := reader.Mem.ReadPtr(ptr + itemOff)
        if (ip && reader.IsProbablyValidPointer(ip))
        {
            pth := _RitualItemPathAt(reader, ip)
            if (pth != "")
            {
                sp  := UiTree_GetScreenPos(reader, ptr)
                sid := ""
                try sid := reader.ReadStdWStringAt(ptr + sidOff)
                hits.Push(Map("addr", ptr, "x", sp["x"], "y", sp["y"]
                            , "w", g["sizeW"], "h", g["sizeH"], "sid", sid, "item", pth))
            }
        }

        cf := g["childFirst"], cl := g["childLast"]
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
    return Map("hits", hits, "nodes", nodes)
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

; One-shot item-slot sweep (see file header). No params / no return; reports via a log file
; + MsgBox. Open the Favours window first so the reward cells are live.
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
    res := _RitualSweepItemSlots(reader, root)
    hits := res["hits"]

    ; Sort hits left-to-right then top-to-bottom so the ritual reward cluster (left of
    ; centre) groups together, away from the right-side inventory/stash slots.
    _RitualSortHits(hits)

    rpt := "=== Item-slot sweep (+0x4F8 across the whole GameUI) ===" nl
    rpt .= "GameUI root=0x" Format("{:X}", root) nl
    rpt .= "Nodes scanned=" res["nodes"] "   item-slots found=" hits.Length nl nl
    rpt .= "Open the Favours window before running. Reward cells are a left-of-centre" nl
    rpt .= "cluster (~78x78); inventory/stash slots sit far right. Identify by pos." nl nl
    rpt .= "--- ITEM SLOTS (sorted by x, then y) ---" nl
    cap := 200
    shown := 0
    for _, h in hits
    {
        if (shown >= cap)
        {
            rpt .= "  … (" (hits.Length - cap) " more omitted)" nl
            break
        }
        shown += 1
        rpt .= "  0x" Format("{:X}", h["addr"])
            . "  pos=" Round(h["x"]) "," Round(h["y"]) " size=" Round(h["w"]) "x" Round(h["h"])
            . "  id=" (h["sid"] != "" ? h["sid"] : "-")
            . "  " h["item"] nl
    }
    if (hits.Length = 0)
        rpt .= "  (none — no element in the tree holds a Metadata/Items entity at +0x4F8;" nl
            . "   ritual rewards may use a different reference. Tell me and I'll dig further.)" nl

    _RitualWriteLog(rpt)
    summary := "Item-slot sweep done." nl nl
        . "Nodes scanned: " res["nodes"] nl
        . "Item-slots (+0x4F8) found: " hits.Length nl nl
        . "Log: logs\InGameStateMonitor.ritual_probe.log" nl nl
        . (hits.Length > 0
            ? "→ Paste the log; I'll pick out the ritual reward cluster by position."
            : "→ No +0x4F8 item slots anywhere — ritual rewards use another mechanism; I'll dig deeper.")
    try MsgBox(summary, "Ritual Probe - result", "Iconi")
}

; In-place sort of the sweep hits by x (then y), so spatial clusters group together.
; Simple insertion sort (hit counts are small). Param: hits (Array of Maps). No return.
_RitualSortHits(hits)
{
    i := 2
    while (i <= hits.Length)
    {
        cur := hits[i]
        j := i - 1
        while (j >= 1 && _RitualHitAfter(hits[j], cur))
        {
            hits[j + 1] := hits[j]
            j -= 1
        }
        hits[j + 1] := cur
        i += 1
    }
}

; True when hit a should sort AFTER hit b (x major, y minor). Params: a, b (hit Maps).
_RitualHitAfter(a, b)
{
    if (Round(a["x"]) != Round(b["x"]))
        return (a["x"] > b["x"])
    return (a["y"] > b["y"])
}
