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

    ; Iterate every child; a currency SLOT is one holding a Metadata/Items/Currency
    ; item pointer at +0x4F8. Record its absolute unscaled pos + size + path.
    itemOff := PoE2Offsets.UiElementBase["ItemPtr"]
    hdr := reader.Mem.ReadBytes(container, 0x20)
    cf := hdr ? NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr") : 0
    cl := hdr ? NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr") : 0
    n := (cf && cl > cf) ? ((cl - cf) // A_PtrSize) : 0
    n := Min(n, 256)

    slots := []       ; array of Map(path,x,y,w,h)
    nl := "`r`n"
    log := "=== Currency tab layout probe ===" nl
    log .= "path: " steps nl
    log .= Format("container=0x{:X}  unscaledPos=({},{})  size=({},{})  children={}", container, Round(cx,1), Round(cy,1), Round(cw,1), Round(ch,1), n) nl nl

    Loop n
    {
        childPtr := UiTree_GetChildByIndex(reader, container, A_Index - 1)
        if !(childPtr && reader.IsProbablyValidPointer(childPtr))
            continue
        ip := 0
        try ip := reader.Mem.ReadPtr(childPtr + itemOff)
        if !(ip && reader.IsProbablyValidPointer(ip))
            continue    ; empty slot / non-item child
        path := ""
        try {
            det := reader.Mem.ReadPtr(ip + PoE2Offsets.Entity["EntityDetailsPtr"])
            if (det && reader.IsProbablyValidPointer(det))
                path := reader.ReadStdWStringAt(det + PoE2Offsets.EntityDetails["Path"])
        }
        if (SubStr(path, 1, 22) != "Metadata/Items/Currenc")
            continue    ; not a currency slot

        g := _UiHitGeom(reader, childPtr)
        sp := UiTree_GetScreenPos(reader, childPtr)
        if !(IsObject(g) && IsObject(sp))
            continue
        sx := sp["x"], sy := sp["y"], sw := g["sizeW"], sh := g["sizeH"]
        slots.Push(Map("path", path, "x", sx, "y", sy, "w", sw, "h", sh))
        log .= Format("  child[{}]  ({},{}) {}x{}  {}", A_Index - 1, Round(sx,1), Round(sy,1), Round(sw,1), Round(sh,1), path) nl
    }

    log .= nl "slots found: " slots.Length nl

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
