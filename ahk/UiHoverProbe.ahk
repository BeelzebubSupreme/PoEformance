; UiHoverProbe.ahk
; RE diagnostic for UI / inventory / stash hover. Unlike world entities (which have a
; HoverTracker pointer straight to the hovered AreaInstance entity), PoE2 exposes NO flat
; "UIHover" slot pointing at the hovered UiElement — the v1/v2 wide scans proved only whole
; PANELS are flat-referenced, never the item leaf. So we hit-test DETERMINISTICALLY:
; descend the UI tree from the GameUI root, at each level following the deepest VISIBLE
; child whose absolute UI-space rect contains the cursor (UiTree_HitTest), until no child
; matches. The leaf is the element under the cursor (the hovered item / button / label).
; SINGLE-STEP: hover an item (so the game tooltip shows) and press Ctrl+Alt+Shift+H — a
; button click would move the cursor off the item and drop the hover. Writes the full
; root..leaf chain to logs\InGameStateMonitor.uihover_probe.log + a MsgBox.
; Included by InGameStateMonitor.ahk.

; Single-step UIHover probe (see file header). No params / no return; reports via a
; log file + MsgBox. Hover an item, press the hotkey.
UiHoverProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("UIHover probe: not connected to PoE2.", "UIHover Probe", "Iconx")
        return
    }
    reader := g_reader

    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — open the game / let the radar run a moment, then retry.", "UIHover Probe", "Iconx")
        return
    }

    ; Cursor in screen px; the hit test itself is scale-aware (UiTree_HitTest
    ; converts per element via ScaleIndex/LocalScaleMultiplier + cull).
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    gameHwnd := ResolvePoEWindow()
    sc := gameHwnd ? UiTree_ScaleCtx(reader, gameHwnd) : 0
    if !IsObject(sc)
    {
        try MsgBox("Could not resolve the PoE window client rect.", "UIHover Probe", "Iconx")
        return
    }

    ; Deterministic descent: deepest visible element under the cursor.
    path := UiTree_HitTest(reader, root, mx, my, sc)

    nl := "`r`n"
    rpt := "=== UIHover tree-descent probe ===" nl
    rpt .= "Cursor screen=" mx "," my
        . "   clientRect=" sc["x"] "," sc["y"] " " sc["w"] "x" sc["h"]
        . "   v1=" Round(sc["v1"], 4) " v2=" Round(sc["v2"], 4) " cull=" sc["cull"] nl
    rpt .= "GameUI root=0x" Format("{:X}", root) "   descent depth=" path.Length nl nl

    if (path.Length <= 1)
    {
        rpt .= "Descent did not enter any child — the cursor is outside the GameUI root"
            . " rect, or the root geometry is off. (Only the root is in the chain.)" nl
    }
    else
    {
        rpt .= "--- DESCENT CHAIN (root -> leaf; the LAST line is the hovered element) ---" nl
        for i, addr in path
            rpt .= "  [" (i - 1) "] " _UiHoverChainLine(reader, addr) nl
    }

    leaf := path.Length ? path[path.Length] : 0

    ; Item-pointer bridge: an item-slot UiElement holds a pointer to the item ENTITY at
    ; +0x4F8 (UiElementBase.ItemPtr — from coussiraty/CoreExile2 InventoryAdapters.cs).
    ; Try it on every chain element (leaf -> root, the slot may be an ancestor of the leaf)
    ; and report the first that resolves to a real "Metadata/Items/..." entity — that is
    ; the deterministic descent -> item-data link we want for the hover readout.
    rpt .= nl "--- ITEM POINTER (+0x4F8) per chain element (leaf -> root) ---" nl
    foundItem := ""
    idx := path.Length
    while (idx >= 1)
    {
        itemLine := _UiHoverItemAt(reader, path[idx])
        if (itemLine != "")
        {
            rpt .= "  [" (idx - 1) "] " itemLine nl
            if (foundItem = "")
                foundItem := itemLine
        }
        idx -= 1
    }
    if (foundItem = "")
        rpt .= "  (no chain element holds a Metadata/Items pointer at +0x4F8 — the offset"
            . " may differ this build, or the hovered element isn't an item slot)" nl

    path_log := A_ScriptDir "\logs\InGameStateMonitor.uihover_probe.log"
    writeMsg := "written"
    try
    {
        f := FileOpen(path_log, "w", "UTF-8")
        if IsObject(f)
        {
            f.Write(rpt)
            f.Close()
        }
        else
            writeMsg := "FileOpen failed"
    }
    catch as e
        writeMsg := "write error: " e.Message

    summary := "UIHover probe done — log " writeMsg ":" nl path_log nl nl
    if (leaf)
    {
        summary .= "Hovered (leaf) element:" nl "  " _UiHoverChainLine(reader, leaf) nl nl
        summary .= (foundItem != "" ? ("Resolved item (+0x4F8):" nl "  " foundItem nl nl)
            : ("No item at +0x4F8 on the chain (see log)." nl nl))
        if (path.Length > 1)
        {
            summary .= "Descent chain (" path.Length " levels):" nl
            for i, addr in path
                summary .= "  [" (i - 1) "] " _UiHoverChainLine(reader, addr) nl
        }
    }
    else
        summary .= "No element under the cursor — see the log for details." nl
    try MsgBox(summary, "UIHover Probe — result", "Iconi")
}

; Tries to resolve an inventory/stash item from a UI item-slot element: reads the item-
; entity pointer at <addr>+UiElementBase.ItemPtr (0x4F8) and, if it points at a real
; "Metadata/Items/..." entity, returns a short "itemPtr / rarity / path" line. Returns ""
; when the element holds no item (the normal case for non-slot elements). Params: reader, addr.
_UiHoverItemAt(reader, addr)
{
    itemPtr := 0
    try itemPtr := reader.Mem.ReadPtr(addr + PoE2Offsets.UiElementBase["ItemPtr"])
    if !(itemPtr && reader.IsProbablyValidPointer(itemPtr))
        return ""
    detPtr := 0
    try detPtr := reader.Mem.ReadPtr(itemPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
    if !(detPtr && reader.IsProbablyValidPointer(detPtr))
        return ""
    path := ""
    try path := reader.ReadStdWStringAt(detPtr + PoE2Offsets.EntityDetails["Path"])
    if (SubStr(path, 1, 14) != "Metadata/Items")
        return ""
    rarId := -1
    try rarId := reader.ReadItemRarity(itemPtr)
    rar := ""
    try rar := reader.RarityNameFromId(rarId)
    return "itemPtr=0x" Format("{:X}", itemPtr) "  rarity=" (rar != "" ? rar : rarId) "  path=" path
}

; Formats one descent-chain element line (full UiTree read for stringId/text/size + the
; canonical absolute UI-space position) for the report. Params: reader, addr.
_UiHoverChainLine(reader, addr)
{
    el := UiTree_ReadElement(reader, addr)
    sp := UiTree_GetScreenPos(reader, addr)
    id := (IsObject(el) && el["stringId"] != "") ? el["stringId"] : "-"
    txt := IsObject(el) ? StrReplace(StrReplace(SubStr(el["text"], 1, 40), "`r", " "), "`n", " ") : ""
    w := IsObject(el) ? el["sizeW"] : 0
    h := IsObject(el) ? el["sizeH"] : 0
    kids := IsObject(el) ? el["childCount"] : 0
    vis := (IsObject(el) && el["isVisible"]) ? 1 : 0
    scIdx := IsObject(el) ? el["scaleIndex"] : -1
    lMult := IsObject(el) ? el["localMult"] : 0
    return "0x" Format("{:X}", addr)
        . "  pos=" Round(sp["x"]) "," Round(sp["y"]) " size=" Round(w) "x" Round(h)
        . " vis=" vis " kids=" kids " scIdx=" scIdx " lMult=" Round(lMult, 3)
        . " id=" id (txt != "" ? " text=" txt : "")
}
