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
; rect is converted to px via scaleFactorY and kept only if it lands on screen and is not
; absurdly large (a guard so an unexpected big container can never clear the whole map). Called
; by RadarOverlay.Render while the large map is open. Params: reader, gw/gh (game-window px).
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

    ; UI positions/sizes from UiTree_GetScreenPos are height-normalized: the base space is
    ; 1600 tall and its WIDTH grows with the aspect ratio (e.g. on a 3840×1600 ultrawide the
    ; right-edge UI x reaches ~3840, far past 2560). So BOTH axes convert to pixels with the
    ; same factor gh/1600 — verified against the probe (the Mana label at UI x=3519 only lands
    ; on screen with gh/1600; gw/2560 would push it off the right edge).
    sY  := gh / 1600.0
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
        if (g["sizeW"] > 0 && g["sizeH"] > 0 && g["sizeW"] * sY <= maxW && g["sizeH"] * sY <= maxH)
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
                    sp := UiTree_GetScreenPos(reader, ptr)
                    x := Round(sp["x"] * sY), y := Round(sp["y"] * sY)
                    w := Round(g["sizeW"] * sY), h := Round(g["sizeH"] * sY)
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
