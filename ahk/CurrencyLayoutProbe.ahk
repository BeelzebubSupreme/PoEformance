; CurrencyLayoutProbe.ahk
; RE aid: extracts the PoE2 currency stash tab's exact slot layout straight from
; the game's UI element tree (the only place the real 2D positions live — the
; inventory struct only gives a linear slot index). Owner-found UI path to the
; slot container: [35][2][0][0][0][1][1][0][0][1][1][0][0][1] (74 children; each
; slot child holds its item at UiElementBase.ItemPtr +0x4F8 and its own
; Unscaled Pos + Size). Since the currency layout is game-fixed (identical for
; every player), reading it once is enough to bake it.
;
; Writes:
;   data/currency_tab_layout.json — {container:{x,y,w,h}, slots:[{path,x,y,w,h}]}
;   logs/InGameStateMonitor.currency_layout.log — readable dump
; Positions are ABSOLUTE unscaled UI coords (the "Unscaled Pos" the UI browser
; shows); the renderer normalizes them against the container to stay
; resolution-independent. OPEN THE CURRENCY TAB first, then click the button.
;
; Reuses UiTree_GetChildByIndex / UiTree_GetScreenPos / _UiHitGeom. Bridge
; case CurrencyLayoutProbeRun; UI button in Config → Debug. Included by
; InGameStateMonitor.ahk.

; The owner-verified index path from the GameUI root to the currency-slot
; container. Kept as a module array so it's easy to re-point if the UI shifts.
_CurrencyLayoutPath()
{
    return [35, 2, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1]
}

; Extract + bake the currency tab layout. No params, no return.
CurrencyLayoutProbeRun()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Currency-layout probe: not connected to PoE2.", "Currency Layout", "Iconx")
        return
    }
    reader := g_reader
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("Currency-layout probe: GameUI root not resolved (let the radar run a moment).", "Currency Layout", "Iconx")
        return
    }

    ; Navigate the index path to the slot container.
    cur := root
    steps := ""
    for _, idx in _CurrencyLayoutPath()
    {
        nxt := UiTree_GetChildByIndex(reader, cur, idx)
        steps .= "[" idx "]" (nxt ? "" : "(MISS)") " "
        if !nxt
        {
            try MsgBox("Currency-layout probe: path step failed at " steps "`n`nOpen the CURRENCY TAB first. If the UI path changed, re-browse it in the UI Browser and send me the new path.", "Currency Layout", "Iconx")
            return
        }
        cur := nxt
    }
    container := cur

    ; Container geometry (unscaled).
    cGeom := _UiHitGeom(reader, container)
    cPos := UiTree_GetScreenPos(reader, container)
    if !(IsObject(cGeom) && IsObject(cPos))
    {
        try MsgBox("Currency-layout probe: could not read the container geometry.", "Currency Layout", "Iconx")
        return
    }
    cx := cPos["x"], cy := cPos["y"], cw := cGeom["sizeW"], ch := cGeom["sizeH"]

    nl := "`r`n"
    log := "=== Currency tab layout probe ===" nl
    log .= "path: " steps nl
    log .= Format("container=0x{:X}  unscaledPos=({},{})  size=({},{})", container, Round(cx,1), Round(cy,1), Round(cw,1), Round(ch,1)) nl nl

    ; DFS the container subtree: a currency SLOT is any element holding a
    ; Metadata/Items/Currency item at +0x4F8. The item is NOT on the container's
    ; direct children — each child is a wrapper and the slot sits one level
    ; deeper (confirmed: the slot element's parent is a child of the container),
    ; so we walk a few levels down. Dedup by item pointer.
    itemOff := PoE2Offsets.UiElementBase["ItemPtr"]
    slots := []       ; array of Map(path,x,y,w,h)
    seenItem := Map()
    stack := [{ptr: container, depth: 0}]
    nodes := 0
    while (stack.Length > 0 && nodes < 4000)
    {
        it := stack.Pop()
        p := it.ptr, depth := it.depth
        if !(p && reader.IsProbablyValidPointer(p))
            continue
        nodes += 1

        ; Does THIS element carry a currency item?
        ip := 0
        try ip := reader.Mem.ReadPtr(p + itemOff)
        if (ip && reader.IsProbablyValidPointer(ip) && !seenItem.Has(ip))
        {
            path := ""
            try {
                det := reader.Mem.ReadPtr(ip + PoE2Offsets.Entity["EntityDetailsPtr"])
                if (det && reader.IsProbablyValidPointer(det))
                    path := reader.ReadStdWStringAt(det + PoE2Offsets.EntityDetails["Path"])
            }
            if (SubStr(path, 1, 22) = "Metadata/Items/Currenc")
            {
                seenItem[ip] := true
                g := _UiHitGeom(reader, p)
                sp := UiTree_GetScreenPos(reader, p)
                if (IsObject(g) && IsObject(sp))
                {
                    slots.Push(Map("path", path, "x", sp["x"], "y", sp["y"], "w", g["sizeW"], "h", g["sizeH"]))
                    log .= Format("  d{} ({},{}) {}x{}  {}", depth, Round(sp["x"],1), Round(sp["y"],1), Round(g["sizeW"],1), Round(g["sizeH"],1), path) nl
                }
            }
        }

        ; Descend a few levels (the slot nesting is shallow).
        if (depth < 4)
        {
            hdr := reader.Mem.ReadBytes(p, 0x20)
            if hdr
            {
                cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
                cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
                if (reader.IsProbablyValidPointer(cf) && cl > cf)
                {
                    cn := Min((cl - cf) // A_PtrSize, 256)
                    buf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
                    if buf
                    {
                        Loop cn
                        {
                            cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                            if (cp && reader.IsProbablyValidPointer(cp))
                                stack.Push({ptr: cp, depth: depth + 1})
                        }
                    }
                }
            }
        }
    }

    log .= nl "slots found: " slots.Length "   nodes walked: " nodes nl

    ; ── Emit the JSON layout file (absolute unscaled coords; renderer normalizes) ──
    js := '{' nl
    js .= '  "generated": "' FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") '",' nl
    js .= '  "container": {"x": ' _ClpF(cx) ', "y": ' _ClpF(cy) ', "w": ' _ClpF(cw) ', "h": ' _ClpF(ch) '},' nl
    js .= '  "slots": [' nl
    i := 0
    for _, s in slots
    {
        i += 1
        comma := (i < slots.Length) ? "," : ""
        pth := StrReplace(s["path"], "\", "\\")
        pth := StrReplace(pth, '"', '\"')
        js .= '    {"path": "' pth '", "x": ' _ClpF(s["x"]) ', "y": ' _ClpF(s["y"]) ', "w": ' _ClpF(s["w"]) ', "h": ' _ClpF(s["h"]) '}' comma nl
    }
    js .= '  ]' nl '}' nl

    dataDir := A_ScriptDir "\data"
    logDir  := A_ScriptDir "\logs"
    try DirCreate(dataDir)
    try DirCreate(logDir)
    jsonPath := dataDir "\currency_tab_layout.json"
    logPath  := logDir "\InGameStateMonitor.currency_layout.log"
    try FileOpen(jsonPath, "w", "UTF-8").Write(js).Close()
    try FileOpen(logPath, "w", "UTF-8").Write(log).Close()

    msg := "Currency layout: " slots.Length " slots captured." nl nl
        . "JSON: " jsonPath nl "Log:  " logPath
    if (slots.Length = 0)
        msg .= nl nl "No currency slots found — make sure the CURRENCY TAB is open, then retry."
    try MsgBox(msg, "Currency Layout", "Iconi")
}

; Formats a float with '.' decimals (locale-independent), 1 decimal place.
_ClpF(v)
{
    return Format("{:.1f}", v + 0.0)
}
