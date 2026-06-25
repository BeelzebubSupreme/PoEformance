; UiHoverProbe.ahk
; RE diagnostic to find the "UIHover" pointer — the InGameState / UIRoot slot that
; points at the UiElement under the cursor (the UI/inventory/stash analog of the
; world HoverTracker, which only resolves AreaInstance entities). SINGLE-STEP:
; hover an inventory / stash item (so the game tooltip shows) and press
; Ctrl+Alt+Shift+H. The probe wide-scans InGameState + UIRoot for slots pointing at
; a UiElement and ranks them by how well the element's rect matches the cursor: the
; slot whose element CONTAINS the cursor (smallest such = the item itself) is UIHover.
; A "closest elements" fallback list is also printed in case the screen->UI scale is
; slightly off. Triggered by hotkey (a button click would move the cursor off the
; item and drop the hover). Writes logs\InGameStateMonitor.uihover_probe.log.
; Included by InGameStateMonitor.ahk.

; True iff <f> is a finite, sanely-bounded float (NaN/inf comparisons are false).
_UiHoverFinite(f)
{
    return (f <= 1.0e12 && f >= -1.0e12)
}

; Cheap UiElement check: reads only the 0x2A0 header (no string fields) and returns
; Map("vtable","parent","childCount","relX","relY","sizeW","sizeH","vis") iff <ptr>
; looks like a real UiElement (valid vtable + parent, finite/bounded rel + size). Else 0.
_UiHoverQuick(reader, ptr)
{
    if !reader.IsProbablyValidPointer(ptr)
        return 0
    hdr := 0
    try hdr := reader.Mem.ReadBytes(ptr, 0x2A0)
    if !hdr
        return 0
    vtable := NumGet(hdr.Ptr, 0x000, "Ptr")
    if !reader.IsProbablyValidPointer(vtable)
        return 0
    parent := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ParentPtr"], "Ptr")
    if (parent != 0 && !reader.IsProbablyValidPointer(parent))
        return 0
    relX  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"], "Float")
    relY  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"] + 0x04, "Float")
    sizeW := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"], "Float")
    sizeH := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"] + 0x04, "Float")
    if !(_UiHoverFinite(relX) && _UiHoverFinite(relY) && _UiHoverFinite(sizeW) && _UiHoverFinite(sizeH))
        return 0
    if (sizeW < 0 || sizeH < 0 || sizeW > 100000 || sizeH > 100000)
        return 0
    cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    cc := (reader.IsProbablyValidPointer(cf) && cl > cf) ? Min((cl - cf) // A_PtrSize, 4096) : 0
    flags := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["Flags"], "UInt")
    return Map("vtable", vtable, "parent", parent, "childCount", cc,
        "relX", relX, "relY", relY, "sizeW", sizeW, "sizeH", sizeH,
        "vis", ((flags >> 11) & 1) ? 1 : 0)
}

; Scans <base> .. <base+span> (step 8) for slots pointing at a plausible UiElement;
; appends Map("label","addr","q"(quick geometry)) records to the <out> array.
_UiHoverScan(reader, base, span, tag, out)
{
    if !reader.IsProbablyValidPointer(base)
        return
    off := 0
    while (off <= span)
    {
        ptr := 0
        try ptr := reader.Mem.ReadPtr(base + off)
        if (ptr)
        {
            q := _UiHoverQuick(reader, ptr)
            if IsObject(q)
                out.Push(Map("label", tag "+0x" Format("{:X}", off), "addr", ptr, "q", q))
        }
        off += 0x8
    }
}

; Single-step UIHover probe (see file header). No params / no return; reports via a
; log file + MsgBox. Hover an item, press the hotkey.
UiHoverProbeRun()
{
    global g_reader, g_radarLastSnap
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("UIHover probe: not connected to PoE2.", "UIHover Probe", "Iconx")
        return
    }
    reader := g_reader

    inGs := (IsObject(g_radarLastSnap) && g_radarLastSnap.Has("inGameState")) ? g_radarLastSnap["inGameState"] : 0
    inGsAddr := (IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    if !(inGsAddr && reader.IsProbablyValidPointer(inGsAddr))
    {
        try MsgBox("No InGameState yet — let the radar run a moment, then retry.", "UIHover Probe", "Iconx")
        return
    }
    uiRoot := 0
    try uiRoot := reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["UiRootStructPtr"])

    ; Cursor in screen px, converted to UI-space (the space UiTree_GetScreenPos uses).
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    hScale := (IsObject(cr) && cr["h"] > 0) ? (cr["h"] / 1600.0) : 1.0
    haveCur := IsObject(cr)
    uiCx := haveCur ? (mx - cr["x"]) / hScale : 0
    uiCy := haveCur ? (my - cr["y"]) / hScale : 0

    ; Wide scan of both structs for element-pointing slots.
    cand := []
    _UiHoverScan(reader, inGsAddr, 0x2000, "InGameState", cand)
    _UiHoverScan(reader, uiRoot,  0xC000, "UIRoot",      cand)

    ; Score each candidate by cursor match (UI-space rect containment + center distance).
    for _, c in cand
    {
        q := c["q"]
        sp := UiTree_GetScreenPos(reader, c["addr"])
        x := sp["x"], y := sp["y"], w := q["sizeW"], h := q["sizeH"]
        c["x"] := x, c["y"] := y
        c["under"] := (haveCur && w > 0 && h > 0 && uiCx >= x && uiCx <= x + w && uiCy >= y && uiCy <= y + h) ? 1 : 0
        c["area"] := w * h
        cxC := x + w / 2, cyC := y + h / 2
        dx := uiCx - cxC, dy := uiCy - cyC
        c["dist"] := Sqrt(dx * dx + dy * dy)
    }

    ; Under-cursor elements, smallest (most specific) first; then nearest by distance.
    under := []
    for _, c in cand
        if (c["under"])
            under.Push(c)
    _UiHoverSortBy(under, "area", false)
    near := cand.Clone()
    _UiHoverSortBy(near, "dist", false)

    nl := "`r`n"
    rpt := "=== UIHover single-step probe ===" nl
    rpt .= "Cursor screen=" mx "," my "   UI-space=" Round(uiCx) "," Round(uiCy)
        . "   clientRect=" (haveCur ? (cr["x"] "," cr["y"] " " cr["w"] "x" cr["h"]) : "n/a")
        . "   hScale=" Round(hScale, 4) nl
    rpt .= "InGameState=0x" Format("{:X}", inGsAddr) "   UIRoot=0x" Format("{:X}", uiRoot) nl
    rpt .= "Element-pointing slots found: " cand.Length nl nl

    rpt .= "--- UNDER CURSOR (smallest first = most likely the hovered item) [" under.Length "] ---" nl
    if (under.Length = 0)
        rpt .= "(none contained the cursor — see the nearest-elements list below)" nl
    for _, c in under
        rpt .= "  " _UiHoverLine(reader, c) nl
    rpt .= nl "--- NEAREST elements to the cursor (fallback if the scale is slightly off) [top 12] ---" nl
    i := 0
    for _, c in near
    {
        rpt .= "  " _UiHoverLine(reader, c) nl
        if (++i >= 12)
            break
    }
    rpt .= nl "If neither list points at the hovered item, the pointer is nested in a"
        . " sub-struct — next step: scan one level deep off the UIRoot slots." nl

    path := A_ScriptDir "\logs\InGameStateMonitor.uihover_probe.log"
    writeMsg := "written"
    try
    {
        f := FileOpen(path, "w", "UTF-8")
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

    summary := "UIHover probe done — log " writeMsg ":" nl path nl nl
    src := under.Length ? under : near
    summary .= (under.Length ? "UNDER-CURSOR candidate(s):" : "No under-cursor hit; NEAREST elements:") nl
    n := 0
    for _, c in src
    {
        summary .= "  " _UiHoverLine(reader, c) nl
        if (++n >= 8)
            break
    }
    try MsgBox(summary, "UIHover Probe — result", "Iconi")
}

; Sorts an array of candidate Maps in place by numeric key <key> (ascending unless
; <desc>). Tiny insertion sort — candidate counts are small. No return value.
_UiHoverSortBy(arr, key, desc)
{
    Loop arr.Length
    {
        i := A_Index
        j := i
        while (j > 1 && ((desc && arr[j][key] > arr[j - 1][key]) || (!desc && arr[j][key] < arr[j - 1][key])))
        {
            tmp := arr[j], arr[j] := arr[j - 1], arr[j - 1] := tmp
            j -= 1
        }
    }
}

; Formats one candidate line (full UiTree read for stringId/text) for the report.
_UiHoverLine(reader, c)
{
    el := UiTree_ReadElement(reader, c["addr"])
    id := (IsObject(el) && el["stringId"] != "") ? el["stringId"] : "-"
    txt := IsObject(el) ? StrReplace(StrReplace(SubStr(el["text"], 1, 32), "`r", " "), "`n", " ") : ""
    return c["label"] " -> 0x" Format("{:X}", c["addr"])
        . "  pos=" Round(c["x"]) "," Round(c["y"]) " size=" Round(c["q"]["sizeW"]) "x" Round(c["q"]["sizeH"])
        . " vis=" c["q"]["vis"] " kids=" c["q"]["childCount"] " dist=" Round(c["dist"])
        . " id=" id (txt != "" ? " text=" txt : "")
}
