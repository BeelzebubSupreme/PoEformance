; LootLabelProbe.ahk
; RE diagnostic to locate the on-screen ground-item ("loot") LABEL elements in the UI tree.
; Goal: the large-map maphack overlay paints its wall bitmap over the game's loot labels in
; loot-dense areas. The maphack blit already excludes HUD rectangles via ExcludeClipRect
; (RadarOverlay._RenderMapLayer) — so if we know the loot-label screen rects we can exclude
; those too and the walls stop covering loot. The labels aren't read anywhere yet, so this
; sweeps the GameUI for effectively-visible elements that carry displayed TEXT (item names)
; and dumps StringId / parent StringId / text / screen rect, plus whether the element or a
; near ancestor holds an item entity at +0x4F8 (which positively marks a loot label). Open a
; spot with several drops on the ground, then trigger (bridge: LootLabelProbeRun).
; Included by InGameStateMonitor.ahk.

; Reads an element's StringId (or "" on failure). Param: reader, ptr.
_LlpStringId(reader, ptr)
{
    s := ""
    try s := reader.ReadStdWStringAt(ptr + PoE2Offsets.UiElementBase["StringIdPtr"])
    return s
}

; Writes the report to logs\InGameStateMonitor.lootlabel_probe.log (UTF-8, overwrite).
_LlpWriteLog(text)
{
    p := A_ScriptDir "\logs\InGameStateMonitor.lootlabel_probe.log"
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

; One-shot loot-label sweep (see file header). No params / no return; reports via a log file
; + MsgBox. Stand near several ground drops so their labels are on screen, then run.
LootLabelProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Loot-label probe: not connected to PoE2.", "Loot Label Probe", "Iconx")
        return
    }
    reader := g_reader
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — open the game / let the radar run, then retry.", "Loot Label Probe", "Iconx")
        return
    }

    nl := "`r`n"
    rows := []
    ; Index-based queue (qIdx) — avoids O(n) array shifting that queue.RemoveAt(1) costs per pop.
    queue := [root], qIdx := 1, visited := Map(), nodes := 0
    deadline := A_TickCount + 9000
    while (qIdx <= queue.Length && nodes < 12000)
    {
        if (A_TickCount > deadline)
            break
        ptr := queue[qIdx]
        qIdx += 1
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        el := UiTree_ReadElement(reader, ptr)
        if !IsObject(el)
            continue

        ; Record effectively-visible elements that carry displayed text (the item name on a
        ; loot label). Skip empties to keep the dump focused.
        txt := el.Has("text") ? Trim(el["text"]) : ""
        if (txt != "" && el["isVisible"] && UiTree_HierarchicallyVisible(reader, ptr, root))
        {
            sp  := UiTree_GetScreenPos(reader, ptr)
            par := el["parentPtr"]
            ; Item link: try +0x4F8 on this element and its parent/grandparent.
            itemLine := _UiHoverItemAt(reader, ptr)
            if (itemLine = "" && par && reader.IsProbablyValidPointer(par))
                itemLine := _UiHoverItemAt(reader, par)
            rows.Push(Map(
                "addr", ptr, "sid", el["stringId"],
                "psid", (par && reader.IsProbablyValidPointer(par)) ? _LlpStringId(reader, par) : "",
                "x", sp["x"], "y", sp["y"], "w", el["sizeW"], "h", el["sizeH"],
                "text", SubStr(StrReplace(StrReplace(txt, "`r", " "), "`n", " "), 1, 46),
                "item", itemLine))
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

    ; Sort by y then x so a loot-label cluster groups together.
    _LlpSort(rows)

    rpt := "=== Loot-label sweep (effectively-visible text elements) ===" nl
    rpt .= "GameUI root=0x" Format("{:X}", root) "   nodes scanned=" nodes "   text elements=" rows.Length nl nl
    rpt .= "Look for the item-name rows (e.g. a weapon/armour name); lines tagged <<ITEM hold" nl
    rpt .= "an item at +0x4F8 (on the element or its parent) = a loot label for sure. Note the" nl
    rpt .= "StringId / parent StringId of those rows — that's the container I exclude from the" nl
    rpt .= "maphack." nl nl
    cap := 160, shown := 0
    for _, r in rows
    {
        if (shown >= cap)
        {
            rpt .= "  … (" (rows.Length - cap) " more omitted)" nl
            break
        }
        shown += 1
        rpt .= "  pos=" Round(r["x"]) "," Round(r["y"]) " size=" Round(r["w"]) "x" Round(r["h"])
            . "  id=" (r["sid"] != "" ? r["sid"] : "-")
            . "  pid=" (r["psid"] != "" ? r["psid"] : "-")
            . "  text=" r["text"]
            . (r["item"] != "" ? "  <<ITEM " r["item"] : "") nl
    }

    _LlpWriteLog(rpt)
    summary := "Loot-label sweep done." nl nl
        . "Text elements found: " rows.Length "  (nodes " nodes ")" nl
        . "Log: logs\InGameStateMonitor.lootlabel_probe.log" nl nl
        . "Paste the log — I'll pick out the loot-label container (the rows with item names /"
        . " <<ITEM) and exclude it from the large-map maphack."
    try MsgBox(summary, "Loot Label Probe - result", "Iconi")
}

; In-place insertion sort of the rows by y (then x). Param: rows (Array of Maps). No return.
_LlpSort(rows)
{
    i := 2
    while (i <= rows.Length)
    {
        cur := rows[i], j := i - 1
        while (j >= 1 && _LlpAfter(rows[j], cur))
        {
            rows[j + 1] := rows[j]
            j -= 1
        }
        rows[j + 1] := cur
        i += 1
    }
}

; True when row a should sort AFTER row b (y major, x minor). Params: a, b (row Maps).
_LlpAfter(a, b)
{
    if (Round(a["y"]) != Round(b["y"]))
        return (a["y"] > b["y"])
    return (a["x"] > b["x"])
}
