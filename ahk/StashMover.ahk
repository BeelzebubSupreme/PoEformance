; StashMover.ahk
; "Dump to stash" feature: simulates Ctrl+Click on every backpack item so the
; game moves them into the currently open container (stash tab, vendor sell
; window, trade window, gambling window, …). Triggered by a configurable hotkey
; AND/OR an on-screen button drawn next to the in-game inventory grid.
;
; Data sources (all already reverse-engineered elsewhere in the project):
;   - Backpack items + their grid cells  -> ReadAllPlayerInventories (id == 1).
;   - Inventory grid screen rectangle    -> UI tree element "InventoryPanel"
;     (UiTree_GetScreenPos + UnscaledSize), converted to absolute screen pixels
;     with NavClientRect, mirroring the conversion in UiBrowserHandler
;     (screenPx = uiPos * clientHeight / 1600).
;
; The actual clicking runs as a NON-BLOCKING sequencer (one item per timer tick)
; so the radar hot path is never frozen for the ~1-3 s a full backpack takes.
; Ctrl is held down for the whole run and released on completion / abort.
;
; Included by InGameStateMonitor.ahk. Initialise every global in LoadStashMover()
; (AHK v2 module-init gotcha: top-level initialisers in #Include'd modules don't
; run because they sit after the main script's auto-execute return).

; ── Config + persistence ────────────────────────────────────────────────────

; Seeds all StashMover globals unconditionally (defaults first), then overlays
; the persisted [StashMover] section. Called once at startup by the main script.
LoadStashMover()
{
    global g_smEnabled := false               ; master switch for the whole feature
    global g_smHotkey := ""                    ; AHK hotkey string, e.g. "F4" / "^d" (empty = none)
    global g_smShowButton := true              ; draw the clickable overlay button
    global g_smPerItemDelayMs := 35            ; pause between consecutive item clicks
    global g_smSettleDelayMs := 16             ; pause after moving the cursor, before the click
    global g_smOffsetX := 0                    ; manual screen-px calibration (X) of the grid origin
    global g_smOffsetY := 0                    ; manual screen-px calibration (Y) of the grid origin
    global g_smConfigFile := _ConfigPath()

    ; Runtime state (never persisted)
    global g_smGui := 0                        ; interactive overlay Gui (lazy-built)
    global g_smBtnCtrl := 0                    ; the button control inside g_smGui
    global g_smGuiShown := false
    global g_smRunning := false                ; a dump sequence is in progress
    global g_smQueue := []                     ; precomputed absolute click points for the run
    global g_smQueueIdx := 0
    global g_smMovedCount := 0
    global g_smRegisteredHotkey := ""          ; last hotkey actually bound (for clean re-register)

    f := g_smConfigFile
    try {
        g_smEnabled        := (IniRead(f, "StashMover", "enabled", g_smEnabled ? "1" : "0") = "1")
        g_smHotkey         := IniRead(f, "StashMover", "hotkey", g_smHotkey)
        g_smShowButton     := (IniRead(f, "StashMover", "showButton", g_smShowButton ? "1" : "0") = "1")
        g_smPerItemDelayMs := Integer(IniRead(f, "StashMover", "perItemDelayMs", g_smPerItemDelayMs))
        g_smSettleDelayMs  := Integer(IniRead(f, "StashMover", "settleDelayMs", g_smSettleDelayMs))
        g_smOffsetX        := Integer(IniRead(f, "StashMover", "offsetX", g_smOffsetX))
        g_smOffsetY        := Integer(IniRead(f, "StashMover", "offsetY", g_smOffsetY))
    } catch as ex {
        LogError("LoadStashMover", ex)
    }
    _SmClampConfig()
}

; Persists the current StashMover settings to the [StashMover] INI section.
SaveStashMover()
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY, g_smConfigFile
    f := g_smConfigFile
    try {
        IniWrite(g_smEnabled ? "1" : "0", f, "StashMover", "enabled")
        IniWrite(g_smHotkey, f, "StashMover", "hotkey")
        IniWrite(g_smShowButton ? "1" : "0", f, "StashMover", "showButton")
        IniWrite(g_smPerItemDelayMs, f, "StashMover", "perItemDelayMs")
        IniWrite(g_smSettleDelayMs, f, "StashMover", "settleDelayMs")
        IniWrite(g_smOffsetX, f, "StashMover", "offsetX")
        IniWrite(g_smOffsetY, f, "StashMover", "offsetY")
    } catch as ex {
        LogError("SaveStashMover", ex)
    }
}

; Keeps the numeric settings inside sane bounds so a bad INI / UI value can't
; produce a multi-minute run or a zero-delay machine-gun click storm.
_SmClampConfig()
{
    global g_smPerItemDelayMs, g_smSettleDelayMs
    g_smPerItemDelayMs := Max(5, Min(500, g_smPerItemDelayMs + 0))
    g_smSettleDelayMs  := Max(0, Min(300, g_smSettleDelayMs + 0))
}

; Applies a single setting from the UI/bridge. Param: key, val (string/bool).
; Returns true when the value changed something that needs a hotkey re-register.
_SmApplySetting(key, val)
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY
    needRebind := false
    switch key
    {
        case "enabled":
            g_smEnabled := _SmTruthy(val)
            needRebind := true
        case "hotkey":
            g_smHotkey := Trim(val "")
            needRebind := true
        case "showButton":
            g_smShowButton := _SmTruthy(val)
        case "perItemDelayMs":
            g_smPerItemDelayMs := Integer(val)
        case "settleDelayMs":
            g_smSettleDelayMs := Integer(val)
        case "offsetX":
            g_smOffsetX := Integer(val)
        case "offsetY":
            g_smOffsetY := Integer(val)
    }
    _SmClampConfig()
    return needRebind
}

; Loose boolean coercion shared by the bridge (accepts true/1/"1"/"true").
_SmTruthy(v)
{
    if (v = true || v = 1)
        return true
    s := StrLower(Trim(v ""))
    return (s = "1" || s = "true" || s = "yes" || s = "on")
}

; Builds the "stashMover" JSON object embedded in the WebView header push.
BuildStashMoverHeaderJson()
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY
    j := "{"
    j .= '"enabled":'        (g_smEnabled ? "true" : "false")
    j .= ',"hotkey":'        _JsStr(g_smHotkey)
    j .= ',"showButton":'    (g_smShowButton ? "true" : "false")
    j .= ',"perItemDelayMs":' (g_smPerItemDelayMs + 0)
    j .= ',"settleDelayMs":'  (g_smSettleDelayMs + 0)
    j .= ',"offsetX":'        (g_smOffsetX + 0)
    j .= ',"offsetY":'        (g_smOffsetY + 0)
    j .= "}"
    return j
}

; ── Hotkey ───────────────────────────────────────────────────────────────────

; (Re)binds the configurable dump hotkey. Like RegisterCombatHotkey: turns the
; previous binding off, then binds the new one (gated to PoE2 being the active
; window via HotIf so the key passes through normally everywhere else).
RegisterStashMoverHotkey()
{
    global g_smEnabled, g_smHotkey, g_smRegisteredHotkey
    if (g_smRegisteredHotkey != "")
    {
        try {
            HotIf(_SmPoeActive)
            Hotkey(g_smRegisteredHotkey, , "Off")
            HotIf()
        }
        g_smRegisteredHotkey := ""
    }
    hk := Trim(g_smHotkey)
    if (!g_smEnabled || hk = "")
        return
    try {
        HotIf(_SmPoeActive)
        Hotkey(hk, _OnStashMoveHotkey, "On")
        HotIf()
        g_smRegisteredHotkey := hk
    } catch as ex {
        LogError("RegisterStashMoverHotkey(" hk ")", ex)
        try HotIf()
    }
}

; HotIf context: true only while a PoE2 window is the active foreground window.
_SmPoeActive(*)
{
    h := ResolvePoEWindow()
    return (h && WinActive("ahk_id " h)) ? true : false
}

; Hotkey handler — kicks off a dump from the hotkey path.
_OnStashMoveHotkey(*)
{
    StashMoverDump("hotkey")
}

; ── Memory / geometry resolution ─────────────────────────────────────────────

; Resolves the ServerData pointer from the cached radar snapshot (same chain
; LootPickup / WebViewBridge use). Returns the pointer, or 0 when unavailable.
_SmResolveServerData()
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
        return 0
    snap := (IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area) && area.Has("address"))
        return 0
    areaAddr := area["address"]
    if !areaAddr
        return 0
    try {
        playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        return g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
    } catch as ex {
        LogError("_SmResolveServerData", ex)
        return 0
    }
}

; Bounded breadth-first search for a descendant UiElement carrying targetId.
; Params: reader, root, targetId, maxDepth. Returns the element address, or 0.
_SmBfsFindStringId(reader, root, targetId, maxDepth := 10)
{
    if !reader.IsProbablyValidPointer(root)
        return 0
    queue := [{ptr: root, d: 0}]
    seen := Map()
    idOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    while (queue.Length > 0)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        sid := ""
        try sid := reader.ReadStdWStringAt(p + idOff, 48)
        if (sid = targetId)
            return p
        if (it.d >= maxDepth)
            continue
        hdr := reader.Mem.ReadBytes(p, 0x20)
        if !hdr
            continue
        cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        n := Min((cl - cf) // A_PtrSize, 256)
        buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
        if !buf
            continue
        Loop n
        {
            cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cp)
                queue.Push({ptr: cp, d: it.d + 1})
        }
    }
    return 0
}

; Resolves the inventory grid's ABSOLUTE screen rectangle in pixels.
; Returns Map("x","y","w","h") for the grid panel, or 0 when the inventory grid
; isn't found / not actually on screen. The conversion mirrors UiBrowserHandler:
; screen px = uiPos * (clientHeight / 1600), origin = client-area top-left.
_SmInventoryGridRect()
{
    global g_reader, g_smOffsetX, g_smOffsetY
    if !IsObject(g_reader)
        return 0
    gameUi := _UiBrowser_GetGameUiPtr()
    if !g_reader.IsProbablyValidPointer(gameUi)
        return 0
    panel := _SmBfsFindStringId(g_reader, gameUi, "InventoryPanel", 10)
    if !g_reader.IsProbablyValidPointer(panel)
        return 0
    ; Must be hierarchically visible — otherwise the grid isn't on screen and the
    ; cell pixels would be meaningless.
    if !UiTree_HierarchicallyVisible(g_reader, panel)
        return 0
    elem := UiTree_ReadElement(g_reader, panel)
    if !elem
        return 0
    sp := UiTree_GetScreenPos(g_reader, panel)
    gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    if !IsObject(cr)
        return 0
    hScale := (cr["h"] > 0) ? (cr["h"] / 1600.0) : 1.0
    x := cr["x"] + sp["x"] * hScale + g_smOffsetX
    y := cr["y"] + sp["y"] * hScale + g_smOffsetY
    w := elem["sizeW"] * hScale
    h := elem["sizeH"] * hScale
    if (w < 20 || h < 20)
        return 0
    return Map("x", x, "y", y, "w", w, "h", h)
}

; Reads the backpack inventory (id == 1) from ServerData. Returns Map with
; "items" (array of item Maps with slot coords), "cols", "rows" — or 0.
_SmReadBackpack(sdPtr)
{
    global g_reader
    if (!IsObject(g_reader) || !sdPtr)
        return 0
    invs := 0
    try invs := g_reader.ReadAllPlayerInventories(sdPtr)
    if !(invs && Type(invs) = "Array")
        return 0
    for _, inv in invs
    {
        if !(inv && IsObject(inv) && inv.Has("inventoryId"))
            continue
        if (inv["inventoryId"] != 1)
            continue
        cols := inv.Has("totalBoxesX") ? inv["totalBoxesX"] : 0
        rows := inv.Has("totalBoxesY") ? inv["totalBoxesY"] : 0
        items := inv.Has("items") ? inv["items"] : []
        if (cols <= 0 || rows <= 0)
            return 0
        return Map("items", items, "cols", cols, "rows", rows)
    }
    return 0
}

; True when the game server reports an open stash tab (inventoryId == 27). Used
; only as an informational hint; the dump itself doesn't hard-require it, because
; vendor / trade / gambling windows may not populate that slot.
_SmStashOpen(sdPtr)
{
    global g_reader
    if (!IsObject(g_reader) || !sdPtr)
        return false
    invs := 0
    try invs := g_reader.ReadAllPlayerInventories(sdPtr)
    if !(invs && Type(invs) = "Array")
        return false
    for _, inv in invs
        if (inv && IsObject(inv) && inv.Has("inventoryId") && inv["inventoryId"] = 27)
            return true
    return false
}

; ── Dump sequencer ───────────────────────────────────────────────────────────

; Public entry point. Builds the click queue (one absolute pixel per backpack
; item, deduped by item pointer) and starts the non-blocking sequencer.
; Param: source - "hotkey" | "button" | "ui" (for diagnostics only).
StashMoverDump(source := "")
{
    global g_reader, g_smEnabled, g_smRunning
    global g_smQueue, g_smQueueIdx, g_smMovedCount
    if !g_smEnabled
        return
    if g_smRunning
        return
    if !IsObject(g_reader)
    {
        _SmTooltip("Stash Mover: game not connected.", 1500)
        return
    }

    ; The grid must be on screen to click its cells.
    rect := _SmInventoryGridRect()
    if !IsObject(rect)
    {
        _SmTooltip("Stash Mover: inventory not visible.", 1500)
        return
    }
    sdPtr := _SmResolveServerData()
    bp := _SmReadBackpack(sdPtr)
    if !IsObject(bp)
    {
        _SmTooltip("Stash Mover: can't read backpack.", 1500)
        return
    }

    cols := bp["cols"], rows := bp["rows"]
    cellW := rect["w"] / cols
    cellH := rect["h"] / rows

    ; Build the click list. Each item occupies cells [slotStartX, slotEndX) ×
    ; [slotStartY, slotEndY); its geometric centre in grid units is the midpoint,
    ; converted to a pixel inside the grid rectangle. Dedupe by item pointer so a
    ; multi-cell item (which the reader repeats per cell) is clicked only once.
    points := []
    seen := Map()
    for _, it in bp["items"]
    {
        if !(it && IsObject(it))
            continue
        ptr := it.Has("itemEntityPtr") ? it["itemEntityPtr"] : 0
        if (ptr && seen.Has(ptr))
            continue
        if ptr
            seen[ptr] := true
        sx := it.Has("slotStartX") ? it["slotStartX"] : 0
        sy := it.Has("slotStartY") ? it["slotStartY"] : 0
        ex := it.Has("slotEndX") ? it["slotEndX"] : (sx + 1)
        ey := it.Has("slotEndY") ? it["slotEndY"] : (sy + 1)
        cgx := (sx + ex) / 2.0
        cgy := (sy + ey) / 2.0
        px := Round(rect["x"] + cgx * cellW)
        py := Round(rect["y"] + cgy * cellH)
        points.Push(Map("x", px, "y", py))
    }

    if (points.Length = 0)
    {
        _SmTooltip("Stash Mover: backpack empty.", 1500)
        return
    }

    ; Make sure PoE2 is the foreground window so the synthetic clicks land on it.
    ; (The overlay button is NOACTIVATE, but a hotkey could fire from elsewhere.)
    gameHwnd := ResolvePoEWindow()
    if (gameHwnd && !WinActive("ahk_id " gameHwnd))
    {
        try WinActivate("ahk_id " gameHwnd)
        Sleep(60)
    }
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmTooltip("Stash Mover: PoE window not active.", 1500)
        return
    }

    g_smQueue := points
    g_smQueueIdx := 0
    g_smMovedCount := 0
    g_smRunning := true
    _SmHideGui()   ; avoid a stray button click during the run

    ; Hold Ctrl down for the whole run (keybd_event = UIPI-bypass, like the rest).
    DllCall("keybd_event", "uchar", 0xA2, "uchar", 0, "uint", 0, "uptr", 0)   ; LCONTROL down
    Sleep(20)
    SetTimer(_SmStep, -1)   ; first step ASAP, then self-re-arms
}

; One sequencer step: clicks the next queued item, then re-arms after the
; per-item delay. Aborts (releasing Ctrl) if PoE2 loses focus mid-run.
_SmStep()
{
    global g_smRunning, g_smQueue, g_smQueueIdx, g_smMovedCount
    global g_smPerItemDelayMs, g_smSettleDelayMs
    if !g_smRunning
        return

    gameHwnd := ResolvePoEWindow()
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmFinish("Stash Mover: aborted (focus lost) — moved " g_smMovedCount ".")
        return
    }

    if (g_smQueueIdx >= g_smQueue.Length)
    {
        _SmFinish("Stash Mover: moved " g_smMovedCount " item(s).")
        return
    }

    g_smQueueIdx += 1
    pt := g_smQueue[g_smQueueIdx]
    _SmClickAt(pt["x"], pt["y"])
    g_smMovedCount += 1

    SetTimer(_SmStep, -Max(1, g_smPerItemDelayMs))
}

; Releases Ctrl, clears run state, restores the button and shows a short status
; tooltip. Param: msg - the status text (empty = silent).
_SmFinish(msg := "")
{
    global g_smRunning, g_smQueue, g_smQueueIdx
    DllCall("keybd_event", "uchar", 0xA2, "uchar", 0, "uint", 0x0002, "uptr", 0)   ; LCONTROL up
    g_smRunning := false
    g_smQueue := []
    g_smQueueIdx := 0
    if (msg != "")
        _SmTooltip(msg, 1600)
}

; Moves the cursor to (x,y) and issues a single short left click. Ctrl is already
; held by the caller, so in an open container the game treats it as a move.
_SmClickAt(x, y)
{
    global g_smSettleDelayMs
    DllCall("SetCursorPos", "int", x, "int", y)
    Sleep(Max(1, g_smSettleDelayMs))
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0)   ; LEFTDOWN
    Sleep(8)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0)   ; LEFTUP
}

; Shows a transient tooltip near the cursor that auto-clears after ms.
_SmTooltip(text, ms := 1500)
{
    try {
        ToolTip(text)
        SetTimer(() => ToolTip(), -Abs(ms))
    }
}

; ── Interactive overlay button ───────────────────────────────────────────────

; Lazily creates the always-on-top, NOACTIVATE button window. NOACTIVATE
; (WS_EX_NOACTIVATE 0x08000000) lets the button receive clicks WITHOUT stealing
; foreground from the game, so the synthetic Ctrl+Clicks still land on PoE2.
_SmEnsureGui()
{
    global g_smGui, g_smBtnCtrl
    if IsObject(g_smGui)
        return
    g_smGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
    g_smGui.MarginX := 0
    g_smGui.MarginY := 0
    g_smGui.BackColor := "1A1A1A"
    g_smBtnCtrl := g_smGui.AddButton("x0 y0 w120 h24", "Dump → Stash")
    g_smBtnCtrl.OnEvent("Click", _SmOnButtonClick)
}

; Button click handler — runs a dump from the button path.
_SmOnButtonClick(*)
{
    StashMoverDump("button")
}

; Hides the overlay button window (no-op when already hidden).
_SmHideGui()
{
    global g_smGui, g_smGuiShown
    if (IsObject(g_smGui) && g_smGuiShown)
    {
        try g_smGui.Hide()
        g_smGuiShown := false
    }
}

; Per-tick driver (called from UpdateRadarFast). Shows/positions the overlay
; button just above the inventory grid when the feature is on, the button is
; enabled, the game is focused and the grid is visible; hides it otherwise.
; Self-gated and cheap when disabled. Param: radarSnap (unused, kept for symmetry).
StashMoverTick(radarSnap := 0)
{
    global g_smEnabled, g_smShowButton, g_smRunning, g_smGui, g_smGuiShown
    static _lastBfsTick := 0
    ; Cheap gates every tick so the button hides promptly.
    if (!g_smEnabled || !g_smShowButton || g_smRunning)
    {
        _SmHideGui()
        return
    }
    gameHwnd := ResolvePoEWindow()
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmHideGui()
        return
    }
    ; Throttle the (heavier) UI-tree resolve to ~4 Hz regardless of state; on
    ; skipped ticks leave the button as-is (≤250 ms latency to show/hide is fine).
    if ((A_TickCount - _lastBfsTick) < 250)
        return
    _lastBfsTick := A_TickCount
    rect := _SmInventoryGridRect()
    if !IsObject(rect)
    {
        _SmHideGui()
        return
    }

    _SmEnsureGui()
    btnW := 120, btnH := 24
    ; Anchor at the grid's top-right, just above the first row.
    bx := Round(rect["x"] + rect["w"] - btnW)
    by := Round(rect["y"] - btnH - 4)
    if (by < 0)
        by := Round(rect["y"] + 4)   ; fall back to inside the grid if off-screen
    try {
        g_smGui.Show("x" bx " y" by " w" btnW " h" btnH " NoActivate")
        g_smGuiShown := true
    }
}
