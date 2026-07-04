; LootLabelClear.ahk
; Keeps the game's ground-item ("loot") labels readable while the large-map maphack overlay
; is on. Our maphack wall bitmap is an always-on-top GDI layer, so it paints over the game's
; loot labels in loot-dense areas. RadarOverlay._RenderMapLayer already excludes the HUD
; rectangles from the maphack blit via ExcludeClipRect; this module supplies the on-screen
; LOOT-LABEL rectangles to exclude too, so the walls simply aren't drawn over the labels.
;
; RE finding (loot-label probe, 2026-06-27): a ground/loot label is a UI element whose StringId
; is the world object's metadata PATH (e.g. "Metadata/MiscellaneousObjects/WorldItem"); chat
; lines have an empty StringId. ALL world labels share this — item drops, gold, checkpoints,
; chests, monoliths, and the ritual/interaction banners. They do NOT share a single parent:
; each drop label sits in its own wrapper and the checkpoint / ritual banner live in separate
; UI subtrees. So instead of scoping to one container we do a single visibility-pruned BFS from
; the GameUI root each refresh and collect EVERY visible "Metadata/" label wherever it lives.
; Pruning hidden subtrees (most of the HUD is hidden) keeps it cheap. Rects are produced in the
; radar overlay's coordinate space (overlay-local px = UI-space × scaleFactorY) so RadarOverlay
; can ExcludeClipRect them directly. Self-persists [LootLabelClear]. Default ON.
; Included by InGameStateMonitor.ahk (before OverlayManager / RadarOverlay use g_llcRects).

; Seeds all LootLabelClear globals (defaults first), then overlays the persisted INI section.
; Called once at startup by the main script (AHK v2 init gotcha).
LoadLootLabelClear()
{
    global g_llcEnabled := true         ; keep loot labels clear of the large-map maphack
    global g_llcPad := 5                ; px padding around each label rect (overlay space)
    global g_llcConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_llcRects := []             ; [ [x,y,w,h] ] overlay-local px rects to exclude
    global g_llcLastTick := 0           ; refresh throttle stamp

    f := g_llcConfigFile
    try {
        g_llcEnabled := (IniRead(f, "LootLabelClear", "enabled", g_llcEnabled ? "1" : "0") = "1")
        g_llcPad     := Integer(IniRead(f, "LootLabelClear", "pad", g_llcPad))
    } catch as ex {
        LogError("LoadLootLabelClear", ex)
    }
    g_llcPad := Min(40, Max(0, g_llcPad))
}

; Persists the LootLabelClear settings to [LootLabelClear].
SaveLootLabelClear()
{
    global g_llcEnabled, g_llcPad, g_llcConfigFile
    f := g_llcConfigFile
    try {
        IniWrite(g_llcEnabled ? "1" : "0", f, "LootLabelClear", "enabled")
        IniWrite(g_llcPad, f, "LootLabelClear", "pad")
    } catch as ex {
        LogError("SaveLootLabelClear", ex)
    }
}

; Applies one setting from the UI/bridge; clears the cache when disabled. No return.
_LlcApplySetting(key, val)
{
    global g_llcEnabled, g_llcPad, g_llcRects
    switch key
    {
        case "enabled":
            g_llcEnabled := _LrvTruthy(val)
            if !g_llcEnabled
                g_llcRects := []
        case "pad":
            g_llcPad := Min(40, Max(0, Integer(val)))
    }
}

; Builds the header JSON object (settings) for the WebView push. Caller prepends the key.
BuildLootLabelClearHeaderJson()
{
    global g_llcEnabled, g_llcPad
    return '{"enabled":' (g_llcEnabled ? "true" : "false") ',"pad":' (g_llcPad + 0) '}'
}

; True when a UI element's StringId marks a world/ground label (its StringId is a metadata
; path). Param: sid (StringId string).
_LlcIsLabelSid(sid)
{
    return (StrLen(sid) > 9 && SubStr(sid, 1, 9) = "Metadata/")
}

; Refreshes g_llcRects with the current on-screen loot/world label rectangles (overlay-local
; px). Throttled ~5 Hz. Does ONE visibility-pruned DFS from the GameUI root: a hidden element's
; subtree is skipped entirely (so a node we reach is effectively visible — all ancestors were
; visible too), and every visible "Metadata/"-StringId element of label size is collected. Each
; rect is converted to overlay-local px with the client-rect convention (same as Price-on-Hover
; / Ritual badges) and kept only if it lands on screen and is not absurdly large (a guard so an
; unexpected big container can never clear the whole map). Called by RadarOverlay.Render while
; the large map is open. Params: reader, gw/gh (game-window px, for the on-screen bound check).
LootLabelRectsRefresh(reader, gw, gh)
{
    global g_llcEnabled, g_llcRects, g_llcLastTick
    if !(IsSet(g_llcEnabled) && g_llcEnabled)
    {
        g_llcRects := []
        return
    }
    if ((A_TickCount - g_llcLastTick) < 200)
        return
    g_llcLastTick := A_TickCount
    if !(IsObject(reader) && IsObject(reader.Mem) && reader.Mem.Handle && gh > 0)
        return
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
        return

    ; Convert UI coords → overlay-local px via the shared scale-aware helper
    ; (UiTree_ScreenRectOf: per-element ScaleIndex/LocalScaleMultiplier + cull +
    ; client origin, the C#-reference math). RadarOverlay's memDC is
    ; window-local, so subtract the WINDOW origin (WinGetPos) from the absolute
    ; screen-px rect to land in the same space as the maphack blit.
    gameHwnd := ResolvePoEWindow()
    sc := gameHwnd ? UiTree_ScaleCtx(reader, gameHwnd) : 0
    if !IsObject(sc)
    {
        g_llcRects := []
        return
    }
    hScale := sc["v2"]   ; height scale, for the cheap pre-filter size cap only
    wx := 0, wy := 0, ww := 0, wh := 0
    try WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " gameHwnd)
    maxW := gw * 0.6, maxH := gh * 0.5   ; a label is never this big → skip (anti whole-map clear)
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    txtOff := PoE2Offsets.UiElementBase["TextPtr"]
    rects := []

    ; Seed the stack with the root's children so the root's own visible flag never blocks us.
    stack := []
    rg := _UiHitGeom(reader, root)
    if !IsObject(rg)
    {
        g_llcRects := []
        return
    }
    _LlcPushChildren(reader, rg, stack)

    visited := Map(), nodes := 0
    ; Safety net only — visibility pruning keeps the real cost a few ms. Must be well above
    ; A_TickCount's ~15 ms granularity, or the check trips before the scan reaches any label
    ; (that bug made the whole feature a no-op).
    deadline := A_TickCount + 50
    while (stack.Length > 0 && nodes < 6000)
    {
        if (A_TickCount > deadline)
            break
        ptr := stack.Pop()
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
        if !g["visible"]            ; hidden → skip this node AND its whole subtree
            continue
        if (g["sizeW"] > 0 && g["sizeH"] > 0 && g["sizeW"] * hScale <= maxW && g["sizeH"] * hScale <= maxH)
        {
            sid := ""
            try sid := reader.ReadStdWStringAt(ptr + sidOff)
            if (_LlcIsLabelSid(sid))
            {
                ; Require displayed text so we only punch holes for the actual on-screen labels
                ; (item names, gold, checkpoint, monolith) — not the empty Metadata/ wrappers /
                ; sub-elements that otherwise scatter stray holes across the map.
                txt := ""
                try txt := reader.ReadStdWStringAt(ptr + txtOff, 64)
                if (Trim(txt) != "")
                {
                    r := UiTree_ScreenRectOf(reader, ptr, sc, g["sizeW"], g["sizeH"])
                    x := Round(r["x"] - wx), y := Round(r["y"] - wy)
                    w := Round(r["w"]), h := Round(r["h"])
                    ; Keep only labels that land on screen.
                    if (w > 0 && h > 0 && x < gw && y < gh && x + w > 0 && y + h > 0)
                        rects.Push([x, y, w, h])
                }
            }
        }
        _LlcPushChildren(reader, g, stack)
    }
    g_llcRects := rects
}

; One-shot diagnostic: logs the live window/client geometry and, for every matched loot label,
; its raw UI position/size plus the overlay-local px rect computed two ways — the current method
; (window rect from WinGetPos, the same source RadarOverlay uses) and a client-rect method
; (NavClientRect origin + client-height scale, the convention the verified hover badge uses).
; Comparing the two against where the labels actually are pins the correct conversion. Writes
; logs\InGameStateMonitor.lootlabelclear_diag.log. Bridge: LootLabelClearDiag. No params/return.
LootLabelClearDiag()
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Loot-label diag: not connected to PoE2.", "Loot Label Clear Diag", "Iconx")
        return
    }
    reader := g_reader
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        try MsgBox("No GameUI root yet — open the game / let the radar run, then retry.", "Loot Label Clear Diag", "Iconx")
        return
    }

    ; Window rect (what the overlay context uses via WinGetPos) and client rect (UI-coord basis).
    hwnd := 0
    try hwnd := ResolvePoEWindow()
    wx := 0, wy := 0, ww := 0, wh := 0
    if hwnd
        try WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    cr := hwnd ? NavClientRect(hwnd) : 0
    crx := IsObject(cr) ? cr["x"] : 0,  cry := IsObject(cr) ? cr["y"] : 0
    crw := IsObject(cr) ? cr["w"] : 0,  crh := IsObject(cr) ? cr["h"] : 0

    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    txtOff := PoE2Offsets.UiElementBase["TextPtr"]
    rows := []
    stack := []
    rg := _UiHitGeom(reader, root)
    if IsObject(rg)
        _LlcPushChildren(reader, rg, stack)
    visited := Map(), nodes := 0
    deadline := A_TickCount + 2000
    while (stack.Length > 0 && nodes < 12000)
    {
        if (A_TickCount > deadline)
            break
        ptr := stack.Pop()
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
        if !g["visible"]
            continue
        if (g["sizeW"] > 0 && g["sizeH"] > 0)
        {
            sid := ""
            try sid := reader.ReadStdWStringAt(ptr + sidOff)
            if (_LlcIsLabelSid(sid))
            {
                txt := ""
                try txt := reader.ReadStdWStringAt(ptr + txtOff, 64)
                if (Trim(txt) != "")
                {
                    sp := UiTree_GetScreenPos(reader, ptr)
                    rows.Push(Map("t", SubStr(Trim(txt), 1, 32), "sx", sp["x"], "sy", sp["y"],
                        "w", g["sizeW"], "h", g["sizeH"], "sid", sid))
                }
            }
        }
        _LlcPushChildren(reader, g, stack)
    }

    nl := "`r`n"
    sYwin := (wh > 0) ? (wh / 1600.0) : 0.0     ; current method scale (window height)
    sYcli := (crh > 0) ? (crh / 1600.0) : 0.0   ; client-height scale
    offX := crx - wx, offY := cry - wy          ; client origin relative to the window top-left
    rpt := "=== Loot-label-clear conversion diag ===" nl
    rpt .= "WinGetPos (overlay basis): x=" wx " y=" wy " w=" ww " h=" wh nl
    rpt .= "NavClientRect:             x=" crx " y=" cry " w=" crw " h=" crh nl
    rpt .= "client-origin offset in window: dx=" offX " dy=" offY
        . "   sY(win)=" Round(sYwin, 4) "  sY(client)=" Round(sYcli, 4) nl
    rpt .= "matched labels=" rows.Length "  (nodes " nodes ")" nl nl
    rpt .= "For each: raw UI (sx,sy,w,h) | CUR=overlay px now (sx*sYwin,...) | CLI=client-corrected"
        . " ((sx*sYcli)+offX, (sy*sYcli)+offY, w*sYcli, h*sYcli)" nl nl
    cap := 40, shown := 0
    for _, r in rows
    {
        if (shown >= cap)
        {
            rpt .= "  … (" (rows.Length - cap) " more)" nl
            break
        }
        shown += 1
        curX := Round(r["sx"] * sYwin), curY := Round(r["sy"] * sYwin)
        curW := Round(r["w"] * sYwin),  curH := Round(r["h"] * sYwin)
        cliX := Round(r["sx"] * sYcli + offX), cliY := Round(r["sy"] * sYcli + offY)
        cliW := Round(r["w"] * sYcli),  cliH := Round(r["h"] * sYcli)
        rpt .= "  " r["t"] nl
        rpt .= "      raw=" Round(r["sx"]) "," Round(r["sy"]) " " Round(r["w"]) "x" Round(r["h"])
            . "  CUR=" curX "," curY " " curW "x" curH
            . "  CLI=" cliX "," cliY " " cliW "x" cliH nl
    }

    p := A_ScriptDir "\logs\InGameStateMonitor.lootlabelclear_diag.log"
    try
    {
        f := FileOpen(p, "w", "UTF-8")
        if IsObject(f)
        {
            f.Write(rpt)
            f.Close()
        }
    }
    try MsgBox("Loot-label-clear diag done." nl nl
        . "Window " ww "x" wh "  Client " crw "x" crh "  (offset dx=" offX " dy=" offY ")" nl
        . "Matched labels: " rows.Length nl nl
        . "Log: logs\InGameStateMonitor.lootlabelclear_diag.log" nl nl
        . "Open the large map over loot first, then paste the log.", "Loot Label Clear Diag", "Iconi")
}

; Pushes a node's child element pointers onto <stack> (capped). Params: reader, g (the node's
; _UiHitGeom map), stack (array). No return.
_LlcPushChildren(reader, g, stack)
{
    cf := g["childFirst"], cl := g["childLast"]
    if !(reader.IsProbablyValidPointer(cf) && cl > cf)
        return
    n := Min((cl - cf) // A_PtrSize, 512)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return
    Loop n
    {
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if (reader.IsProbablyValidPointer(cp))
            stack.Push(cp)
    }
}
