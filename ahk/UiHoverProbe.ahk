; UiHoverProbe.ahk
; RE diagnostic to find the "UIHover" pointer — the InGameState / UIRoot slot that
; points at the UiElement currently under the cursor. This is the UI/inventory/stash
; analog of the world HoverTracker (which only resolves AreaInstance entities, so it
; reads 0 for inventory items). Two-run hover-diff:
;   Step 1: cursor over EMPTY space (nothing hovered) -> click -> baseline captured.
;   Step 2: cursor over an inventory / stash ITEM     -> click -> diff + report.
; For every 8-byte slot in InGameState and in UIRoot (InGameState + UiRootStructPtr)
; we record those that point at a plausible UiElement. On step 2 we report slots that
; flipped null->element (or changed target) since the baseline, and — crucially —
; whether that element's screen rect contains the cursor. The slot that BOTH changed
; on hover AND is under the cursor is the UIHover pointer.
; Wired via BridgeDispatch "UiHoverProbeRun"; writes
; logs\InGameStateMonitor.uihover_probe.log. Included by InGameStateMonitor.ahk.

; True iff <f> is a finite, sanely-bounded float (NaN/inf comparisons are false, so
; they fail this and are treated as non-finite). Used to reject garbage UiElements.
_UiHoverFinite(f)
{
    return (f <= 1.0e12 && f >= -1.0e12)
}

; Reads <ptr> as a UiElement and returns the element Map iff it looks like a real one
; (valid vtable + parent, sane child count, finite/bounded rel + size). Else 0.
_UiHoverAsElement(reader, ptr)
{
    if !reader.IsProbablyValidPointer(ptr)
        return 0
    el := UiTree_ReadElement(reader, ptr)
    if !IsObject(el)
        return 0
    if !reader.IsProbablyValidPointer(el["vtable"])
        return 0
    par := el["parentPtr"]
    if (par != 0 && !reader.IsProbablyValidPointer(par))
        return 0
    if !(_UiHoverFinite(el["relX"]) && _UiHoverFinite(el["relY"])
        && _UiHoverFinite(el["sizeW"]) && _UiHoverFinite(el["sizeH"]))
        return 0
    if (el["sizeW"] < 0 || el["sizeH"] < 0 || el["sizeW"] > 100000 || el["sizeH"] > 100000)
        return 0
    return el
}

; Scans <base> .. <base+span> (step 8) for slots pointing at a plausible UiElement and
; records them into <out> as Map("<tag>+0x<off>" -> elementAddr). No-op on a bad base.
_UiHoverScan(reader, base, span, tag, out)
{
    if !reader.IsProbablyValidPointer(base)
        return
    off := 0
    while (off <= span)
    {
        ptr := 0
        try ptr := reader.Mem.ReadPtr(base + off)
        if (ptr && _UiHoverAsElement(reader, ptr))
            out[tag "+0x" Format("{:X}", off)] := ptr
        off += 0x8
    }
}

; Two-run hover-diff entry point (see file header). No parameters, no return value;
; reports via a log file + MsgBox. Lazy-inits its baseline global (AHK v2 init gotcha).
UiHoverProbeRun()
{
    global g_reader, g_radarLastSnap, g_uiHoverBaseline
    if !IsSet(g_uiHoverBaseline)
        g_uiHoverBaseline := Map()
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("UIHover probe: not connected to PoE2.", "UIHover Probe", "Iconx")
        return
    }
    reader := g_reader

    ; Resolve InGameState + UIRoot (the KB/M UI manager that also owns HoverTracker).
    inGs := (IsObject(g_radarLastSnap) && g_radarLastSnap.Has("inGameState")) ? g_radarLastSnap["inGameState"] : 0
    inGsAddr := (IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    if !(inGsAddr && reader.IsProbablyValidPointer(inGsAddr))
    {
        try MsgBox("No InGameState yet — let the radar run a moment, then retry.", "UIHover Probe", "Iconx")
        return
    }
    uiRoot := 0
    try uiRoot := reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["UiRootStructPtr"])

    ; Snapshot every slot that currently points at a UiElement.
    cur := Map()
    _UiHoverScan(reader, inGsAddr, 0x800,  "InGameState", cur)
    _UiHoverScan(reader, uiRoot,  0x1200, "UIRoot",      cur)

    ; Step 1: first click captures the baseline (cursor should be over EMPTY space).
    if (g_uiHoverBaseline.Count = 0)
    {
        g_uiHoverBaseline := cur
        try MsgBox("Baseline captured: " cur.Count " UiElement-pointer slots while NOTHING is hovered."
            . "`n`nNow move the cursor OVER an inventory / stash item (so the game's item tooltip shows)"
            . " and press Ctrl+Alt+Shift+H — do NOT click the tool button for step 2, that would move the"
            . " cursor off the item and drop the hover.",
            "UIHover Probe — step 1/2", "Iconi")
        return
    }

    ; Step 2: diff vs baseline (cursor should now be over an item).
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    hScale := (IsObject(cr) && cr["h"] > 0) ? (cr["h"] / 1600.0) : 1.0

    nl := "`r`n"
    rpt := "=== UIHover hover-diff (step 2/2) ===" nl
    rpt .= "Cursor (screen): " mx ", " my nl
    rpt .= "InGameState=0x" Format("{:X}", inGsAddr) "   UIRoot=0x" Format("{:X}", uiRoot)
        . "   (UiRootStructPtr=+0x" Format("{:X}", PoE2Offsets.InGameState["UiRootStructPtr"]) ")" nl
    rpt .= "Baseline element-slots: " g_uiHoverBaseline.Count "   now: " cur.Count nl nl

    underCursor := []
    changed := []
    for label, addr in cur
    {
        was := g_uiHoverBaseline.Has(label) ? g_uiHoverBaseline[label] : 0
        if (was = addr)
            continue
        el := _UiHoverAsElement(reader, addr)
        if !IsObject(el)
            continue
        uc := false
        if (IsObject(cr))
        {
            sp := UiTree_GetScreenPos(reader, addr)
            px := cr["x"] + sp["x"] * hScale
            py := cr["y"] + sp["y"] * hScale
            pw := el["sizeW"] * hScale
            ph := el["sizeH"] * hScale
            uc := (pw > 0 && ph > 0 && mx >= px && mx <= px + pw && my >= py && my <= py + ph)
        }
        txt := StrReplace(StrReplace(SubStr(el["text"], 1, 40), "`r", " "), "`n", " ")
        line := label "  -> 0x" Format("{:X}", addr)
            . "  id=" (el["stringId"] != "" ? el["stringId"] : "-")
            . "  size=" Round(el["sizeW"]) "x" Round(el["sizeH"])
            . "  vis=" (el["isVisible"] ? "1" : "0")
            . "  kids=" el["childCount"]
            . (was ? ("  (was 0x" Format("{:X}", was) ")") : "  (was null)")
            . (txt != "" ? ("  text=" txt) : "")
        if (uc)
            underCursor.Push(line)
        else
            changed.Push(line)
    }

    rpt .= "--- UNDER CURSOR (most likely the UIHover target) [" underCursor.Length "] ---" nl
    if (underCursor.Length = 0)
        rpt .= "(none — make sure step 2 has the cursor ON an item with the tooltip showing)" nl
    for _, line in underCursor
        rpt .= "  " line nl
    rpt .= nl "--- other element-slots that changed since baseline [" changed.Length "] ---" nl
    for _, line in changed
        rpt .= "  " line nl
    rpt .= nl "If nothing is under the cursor, the hover pointer may sit in a nested"
        . " sub-struct (next step: scan around HoverTracker uiRoot+0x" Format("{:X}", PoE2Offsets.HoverTracker["FromUiRoot"]) ")." nl

    ; Reset the baseline so the next run starts a fresh step-1 capture.
    g_uiHoverBaseline := Map()

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
    if (underCursor.Length)
    {
        summary .= "UNDER-CURSOR candidate(s) — the UIHover offset is most likely one of these:" nl
        n := 0
        for _, line in underCursor
        {
            summary .= "  " line nl
            if (++n >= 6)
                break
        }
    }
    else
    {
        summary .= "No under-cursor candidate; " changed.Length " other element-slots changed (see log)." nl
        summary .= "Tip: step 1 = cursor on EMPTY space, step 2 = cursor ON an item." nl
    }
    try MsgBox(summary, "UIHover Probe — result", "Iconi")
}
