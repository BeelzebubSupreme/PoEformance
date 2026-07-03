; NpcIdentify.ahk
; TEST feature: one hotkey that, while the character is in the HIDEOUT, clicks the
; NPC "Doryani" via his floating hideout label and, once his NPC dialog window has
; opened, clicks its "Identify Items" entry — one-key bulk identification.
;
; UI paths (root-relative element indices from the UI Browser; INI-tunable):
;   labelsPath 8,0,0        -> container whose children are ALL hideout labels;
;                              the NPC label is found by its displayed TEXT (the
;                              child index shifts, e.g. [84], so never hardcoded)
;   windowPath 23           -> the NPC dialog window (visible only while open)
;   menuPath   1,0,2,1,0,0  -> from that window to the "Identify Items" row
;
; Flow: hotkey (or the RE-tools button) -> hideout gate -> find the label by
; text -> click it (the char walks to the NPC and the game opens the dialog) ->
; poll until the window is hierarchically visible -> resolve the menu row,
; verify its text, click it. Every gate aborts with a tooltip reason.
; Self-persists [NpcIdentify] in poeformance_config.ini (hotkey default F9,
; active only while PoE2 is focused). Included by InGameStateMonitor.ahk;
; LoadNpcIdentify() + RegisterNpcIdentifyHotkey() run at startup (module-init
; gotcha: every global is seeded in LoadNpcIdentify).

; Seeds all NpcIdentify globals (defaults first), overlays the persisted
; [NpcIdentify] INI section, and writes the section back once so the keys are
; discoverable for hand-tuning. Called once at startup by the main script.
LoadNpcIdentify()
{
    global g_npcIdHotkey := "F9"            ; hotkey (AHK syntax); "" disables
    global g_npcIdRegisteredHotkey := ""    ; currently bound hotkey (for re-bind)
    global g_npcIdNpcName := "Doryani"      ; hideout label text to click
    global g_npcIdMenuText := "Identify Items"  ; expected dialog-row text (sanity check)
    global g_npcIdLabelsPath := "8,0,0"     ; root -> hideout-labels container
    global g_npcIdWindowPath := "23"        ; root -> NPC dialog window
    global g_npcIdMenuPath := "1,0,2,1,0,0" ; window -> "Identify Items" row
    global g_npcIdBusy := false             ; state machine armed (waiting for the window)
    global g_npcIdDeadline := 0             ; A_TickCount limit for the window poll
    global g_npcIdConfigFile := _ConfigPath()

    f := g_npcIdConfigFile
    try {
        g_npcIdHotkey     := IniRead(f, "NpcIdentify", "hotkey", g_npcIdHotkey)
        g_npcIdNpcName    := IniRead(f, "NpcIdentify", "npcName", g_npcIdNpcName)
        g_npcIdMenuText   := IniRead(f, "NpcIdentify", "menuText", g_npcIdMenuText)
        g_npcIdLabelsPath := IniRead(f, "NpcIdentify", "labelsPath", g_npcIdLabelsPath)
        g_npcIdWindowPath := IniRead(f, "NpcIdentify", "windowPath", g_npcIdWindowPath)
        g_npcIdMenuPath   := IniRead(f, "NpcIdentify", "menuPath", g_npcIdMenuPath)
    } catch as ex {
        LogError("LoadNpcIdentify", ex)
    }
    SaveNpcIdentify()
}

; Persists the [NpcIdentify] settings (also seeds the section on first run).
SaveNpcIdentify()
{
    global g_npcIdHotkey, g_npcIdNpcName, g_npcIdMenuText
    global g_npcIdLabelsPath, g_npcIdWindowPath, g_npcIdMenuPath, g_npcIdConfigFile
    f := g_npcIdConfigFile
    try {
        IniWrite(g_npcIdHotkey, f, "NpcIdentify", "hotkey")
        IniWrite(g_npcIdNpcName, f, "NpcIdentify", "npcName")
        IniWrite(g_npcIdMenuText, f, "NpcIdentify", "menuText")
        IniWrite(g_npcIdLabelsPath, f, "NpcIdentify", "labelsPath")
        IniWrite(g_npcIdWindowPath, f, "NpcIdentify", "windowPath")
        IniWrite(g_npcIdMenuPath, f, "NpcIdentify", "menuPath")
    } catch as ex {
        LogError("SaveNpcIdentify", ex)
    }
}

; (Re)binds the NpcIdentify hotkey, active only while PoE2 is focused.
; Mirrors RegisterStashMoverHotkey. Call after LoadNpcIdentify / a hotkey change.
RegisterNpcIdentifyHotkey()
{
    global g_npcIdHotkey, g_npcIdRegisteredHotkey
    if (g_npcIdRegisteredHotkey != "")
    {
        try {
            HotIf(_NpcIdPoeActive)
            Hotkey(g_npcIdRegisteredHotkey, , "Off")
            HotIf()
        }
        g_npcIdRegisteredHotkey := ""
    }
    hk := Trim(g_npcIdHotkey)
    if (hk = "")
        return
    try {
        HotIf(_NpcIdPoeActive)
        Hotkey(hk, _OnNpcIdentifyHotkey, "On")
        HotIf()
        g_npcIdRegisteredHotkey := hk
    } catch as ex {
        LogError("RegisterNpcIdentifyHotkey(" hk ")", ex)
        try HotIf()
    }
}

; HotIf context: true only while a PoE2 window is the active foreground window.
_NpcIdPoeActive(*)
{
    h := ResolvePoEWindow()
    return (h && WinActive("ahk_id " h)) ? true : false
}

; Hotkey handler — kicks off the click sequence from the hotkey path.
_OnNpcIdentifyHotkey(*)
{
    NpcIdentifyRun("hotkey")
}

; Short auto-clearing status tooltip. Param: msg (text after the fixed prefix).
_NpcIdTip(msg)
{
    try ToolTip("NPC Identify: " msg)
    SetTimer(() => ToolTip(), -2200)
}

; Walks a root-relative index path ("8,0,0"; "[8] -> [0]" style also accepted)
; from <fromPtr> via UiTree_GetChildByIndex. Returns the element ptr or 0.
_NpcIdResolvePath(reader, fromPtr, pathStr)
{
    s := StrReplace(StrReplace(StrReplace(StrReplace(pathStr, "[", ""), "]", ""), "->", ","), ">", ",")
    s := StrReplace(s, " ", ",")
    cur := fromPtr
    for _, part in StrSplit(s, ",")
    {
        if (Trim(part) = "")
            continue
        idx := -1
        try idx := Integer(Trim(part))
        if (idx < 0)
            return 0
        cur := UiTree_GetChildByIndex(reader, cur, idx)
        if !cur
            return 0
    }
    return cur
}

; Finds the VISIBLE child of <containerPtr> whose displayed text equals <name>
; (case-insensitive, trimmed). Returns the child element ptr or 0.
_NpcIdFindLabelByText(reader, containerPtr, name)
{
    hdr := reader.Mem.ReadBytes(containerPtr, 0x20)
    if !hdr
        return 0
    cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
        return 0
    n := Min((cl - cf) // A_PtrSize, 512)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return 0
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    txtOff   := PoE2Offsets.UiElementBase["TextPtr"]
    want := StrLower(Trim(name))
    Loop n
    {
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(cp)
            continue
        fl := 0
        try fl := reader.Mem.ReadUInt(cp + flagsOff)
        if (((fl >> 11) & 1) = 0)   ; hidden label → not clickable
            continue
        txt := ""
        try txt := reader.ReadStdWStringAt(cp + txtOff, 64)
        if (StrLower(Trim(txt)) = want)
            return cp
    }
    return 0
}

; Entry point (hotkey / bridge button): in the hideout, click the NPC label and
; arm the poll that waits for the dialog window. Param: source (log label only).
NpcIdentifyRun(source := "hotkey")
{
    global g_reader, g_npcIdBusy, g_npcIdDeadline
    global g_npcIdNpcName, g_npcIdLabelsPath
    if g_npcIdBusy
    {
        _NpcIdTip("already running — waiting for the NPC window.")
        return
    }
    reader := g_reader
    if !(IsObject(reader) && IsObject(reader.Mem) && reader.Mem.Handle)
    {
        _NpcIdTip("not connected to PoE2.")
        return
    }
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
    {
        _NpcIdTip("PoE2 window not found.")
        return
    }
    ; Bridge-button path: bring the game to the foreground first (clicks need it).
    if !WinActive("ahk_id " gameHwnd)
    {
        try WinActivate("ahk_id " gameHwnd)
        try WinWaitActive("ahk_id " gameHwnd, , 1)
        if !WinActive("ahk_id " gameHwnd)
        {
            _NpcIdTip("could not focus the game window.")
            return
        }
    }
    ; Hideout gate — the label paths only exist there.
    wad := (reader.HasOwnProp("_radarWorldAreaCache")) ? reader._radarWorldAreaCache : 0
    if !(wad && IsObject(wad) && wad.Has("isHideout") && wad["isHideout"])
    {
        _NpcIdTip("not in the hideout (area: " ((wad && IsObject(wad) && wad.Has("name")) ? wad["name"] : "?") ").")
        return
    }
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        _NpcIdTip("GameUI root not resolved yet.")
        return
    }
    labels := _NpcIdResolvePath(reader, root, g_npcIdLabelsPath)
    if !labels
    {
        _NpcIdTip("labels container not found (path " g_npcIdLabelsPath ").")
        return
    }
    npc := _NpcIdFindLabelByText(reader, labels, g_npcIdNpcName)
    if !npc
    {
        _NpcIdTip("no visible label '" g_npcIdNpcName "' — stand closer / labels on?")
        return
    }
    r := UiTree_ScreenRectOf(reader, npc)
    if !(IsObject(r) && r["w"] > 2 && r["h"] > 2)
    {
        _NpcIdTip("label rect not resolved.")
        return
    }
    NavClickAt(Round(r["x"] + r["w"] / 2), Round(r["y"] + r["h"] / 2))
    g_npcIdBusy := true
    g_npcIdDeadline := A_TickCount + 9000
    SetTimer(_NpcIdPoll, 150)
    _NpcIdTip("clicked '" g_npcIdNpcName "' — waiting for the NPC window…")
}

; Stops the poll state machine and shows the final status tooltip.
_NpcIdStop(msg)
{
    global g_npcIdBusy
    g_npcIdBusy := false
    SetTimer(_NpcIdPoll, 0)
    _NpcIdTip(msg)
}

; Poll timer: waits for the NPC dialog window to become hierarchically visible,
; then resolves the menu row, sanity-checks its text and clicks it.
_NpcIdPoll()
{
    global g_reader, g_npcIdBusy, g_npcIdDeadline
    global g_npcIdWindowPath, g_npcIdMenuPath, g_npcIdMenuText
    if !g_npcIdBusy
    {
        SetTimer(_NpcIdPoll, 0)
        return
    }
    if (A_TickCount > g_npcIdDeadline)
    {
        _NpcIdStop("NPC window did not open (timeout).")
        return
    }
    reader := g_reader
    if !(IsObject(reader) && IsObject(reader.Mem) && reader.Mem.Handle)
    {
        _NpcIdStop("lost the game connection.")
        return
    }
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
        return   ; transient — keep polling until the deadline
    win := _NpcIdResolvePath(reader, root, g_npcIdWindowPath)
    if !(win && UiTree_HierarchicallyVisible(reader, win, root))
        return   ; window not open yet — keep polling
    target := _NpcIdResolvePath(reader, win, g_npcIdMenuPath)
    if !target
        return   ; window still building its children — keep polling
    txt := ""
    try txt := Trim(reader.ReadStdWStringAt(target + PoE2Offsets.UiElementBase["TextPtr"], 64))
    if (txt = "")
        return   ; text not populated yet — keep polling
    if !InStr(txt, Trim(g_npcIdMenuText))
    {
        _NpcIdStop("menu row reads '" txt "' — expected '" g_npcIdMenuText "' (path drift?).")
        return
    }
    gameHwnd := ResolvePoEWindow()
    if !(gameHwnd && WinActive("ahk_id " gameHwnd))
    {
        _NpcIdStop("game lost focus — aborted before the menu click.")
        return
    }
    r := UiTree_ScreenRectOf(reader, target)
    if !(IsObject(r) && r["w"] > 2 && r["h"] > 2)
    {
        _NpcIdStop("menu row rect not resolved.")
        return
    }
    NavClickAt(Round(r["x"] + r["w"] / 2), Round(r["y"] + r["h"] / 2))
    _NpcIdStop("clicked '" txt "'.")
}
