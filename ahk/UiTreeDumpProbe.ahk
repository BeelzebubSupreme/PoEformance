; UiTreeDumpProbe.ahk
; RE diagnostic: recursively walk the ENTIRE GameUI tree and dump every element
; (indented by depth) to a log. Unlike the hover probe — whose hit-test can be
; blocked by a full-screen overlay (e.g. notification_display) and never reach a
; panel — this enumerates every child of the root, so panels like the Vaal Ruins
; console can be located by inspection (find a container with a big kids= count).
;
; Read-only; no game input. Reuses UiTree_ReadElement / UiTree_GetChildByIndex /
; the GameUI root accessor from UiTreeBrowser.ahk + UiBrowserHandler.ahk.
; Bridge: UiTreeDumpRun. Writes logs\InGameStateMonitor.uitree_dump.log.
; Included by InGameStateMonitor.ahk.

; Recursively appends one element + its descendants to ctx["sb"]. Depth and node
; caps bound runaway/cyclic trees. Params: reader, addr, depth, ctx (Map with
; count, cap, maxDepth, sb array). No return value.
_UiTreeDumpNode(reader, addr, depth, ctx)
{
    if (ctx["count"] >= ctx["cap"] || depth > ctx["maxDepth"])
        return
    if !reader.IsProbablyValidPointer(addr)
        return
    el := UiTree_ReadElement(reader, addr)
    if !IsObject(el)
        return
    ctx["count"]++

    id   := (el["stringId"] != "") ? el["stringId"] : "-"
    txt  := StrReplace(StrReplace(SubStr(el["text"], 1, 48), "`r", " "), "`n", " ")
    kids := el["childCount"]
    vis  := el["isVisible"] ? 1 : 0
    indent := ""
    Loop depth
        indent .= "  "
    ctx["sb"].Push(indent "0x" Format("{:X}", addr)
        . " id=" id
        . " size=" Round(el["sizeW"]) "x" Round(el["sizeH"])
        . " vis=" vis " kids=" kids
        . (txt != "" ? " text=" txt : ""))

    i := 0
    while (i < kids)
    {
        child := UiTree_GetChildByIndex(reader, addr, i)
        if (child)
            _UiTreeDumpNode(reader, child, depth + 1, ctx)
        i++
        if (ctx["count"] >= ctx["cap"])
            break
    }
}

; Entry point (bridge: UiTreeDumpRun). Dumps the whole GameUI tree to a log plus
; a MsgBox summary. Open the target panel FIRST, then run this. No return value.
UiTreeDumpRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("UI-tree dump: not connected to PoE2.", "UI Tree Dump", "Iconx")
        return
    }
    reader := g_reader

    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — open the game / let the radar run a moment, then retry.", "UI Tree Dump", "Iconx")
        return
    }

    ctx := Map("count", 0, "cap", 20000, "maxDepth", 40, "sb", [])
    _UiTreeDumpNode(reader, root, 0, ctx)

    header := "=== GameUI tree dump ===`n"
        . "root=0x" Format("{:X}", root) "  elements=" ctx["count"]
        . (ctx["count"] >= ctx["cap"] ? "  (CAP HIT — tree truncated)" : "") "`n"
        . "Tip: open the Vaal Ruins console before dumping; find the grid as a"
        . " container with a large kids= count (~81 cells).`n`n"
    body := ""
    for _, ln in ctx["sb"]
        body .= ln "`n"

    logPath := A_ScriptDir "\logs\InGameStateMonitor.uitree_dump.log"
    writeMsg := "written"
    try
    {
        f := FileOpen(logPath, "w", "UTF-8")
        if IsObject(f)
        {
            f.Write(header body)
            f.Close()
        }
        else
            writeMsg := "FileOpen failed"
    }
    catch as e
        writeMsg := "write error: " e.Message

    try MsgBox("UI-tree dump done — " ctx["count"] " elements " writeMsg ":`n" logPath
        , "UI Tree Dump — result", "Iconi")
}
