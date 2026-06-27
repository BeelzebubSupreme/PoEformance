; LootLabelClear.ahk
; Keeps the game's ground-item ("loot") labels readable while the large-map maphack overlay
; is on. Our maphack wall bitmap is an always-on-top GDI layer, so it paints over the game's
; loot labels in loot-dense areas. RadarOverlay._RenderMapLayer already excludes the HUD
; rectangles from the maphack blit via ExcludeClipRect; this module supplies the on-screen
; LOOT-LABEL rectangles to exclude too, so the walls simply aren't drawn over the labels.
;
; RE finding (loot-label probe, 2026-06-27): a ground/loot label is a UI text element whose
; StringId is the world object's metadata PATH (e.g. "Metadata/MiscellaneousObjects/WorldItem")
; with the item name as displayed text; chat lines have an empty StringId. So the labels are
; the visible text elements whose StringId starts with "Metadata/". They live under one
; "ground labels" container (the parent of any such label) — we find it once, cache it, and
; rescan only its subtree (cheap) for the live label rects. Rects are produced in the radar
; overlay's coordinate space (overlay-local px = UI-space × scaleFactorY) so RadarOverlay can
; ExcludeClipRect them directly. Self-persists [LootLabelClear]. Default ON.
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
    global g_llcContainer := 0          ; cached ground-labels container element ptr
    global g_llcContainerTick := 0      ; last container (re)find stamp
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
    global g_llcEnabled, g_llcPad, g_llcRects, g_llcContainer
    switch key
    {
        case "enabled":
            g_llcEnabled := _LrvTruthy(val)
            if !g_llcEnabled
            {
                g_llcRects := [], g_llcContainer := 0
            }
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

; Finds the ground-labels container: a bounded BFS for the first VISIBLE text element whose
; StringId starts with "Metadata/", returning its parent (the shared label container). Capped
; by node count + time, short-circuits on match. Returns the container ptr or 0. Params:
; reader, root (GameUI root ptr).
_LlcFindContainer(reader, root)
{
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    parOff := PoE2Offsets.UiElementBase["ParentPtr"]
    txtOff := PoE2Offsets.UiElementBase["TextPtr"]
    queue := [root], visited := Map(), seen := 0
    deadline := A_TickCount + 1200
    while (queue.Length > 0 && seen < 4000)
    {
        if (A_TickCount > deadline)
            break
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        seen += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
        if (g["visible"])
        {
            sid := ""
            try sid := reader.ReadStdWStringAt(ptr + sidOff)
            if (_LlcIsLabelSid(sid))
            {
                txt := ""
                try txt := reader.ReadStdWStringAt(ptr + txtOff, 64)
                if (Trim(txt) != "")
                {
                    par := 0
                    try par := reader.Mem.ReadPtr(ptr + parOff)
                    if (par && reader.IsProbablyValidPointer(par))
                        return par
                }
            }
        }
        cf := g["childFirst"], cl := g["childLast"]
        if (reader.IsProbablyValidPointer(cf) && cl > cf)
        {
            n := Min((cl - cf) // A_PtrSize, 512)
            buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
            if buf
            {
                Loop n
                {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }
    return 0
}

; Refreshes g_llcRects with the current on-screen loot/world label rectangles (overlay-local
; px). Throttled ~5 Hz; ensures the cached container (re-find ≤ ~1.5 s when missing), then
; rescans only its subtree for visible "Metadata/" text labels and converts each to px via
; scaleFactorY. Called by RadarOverlay.Render while the large map is open. Params: reader,
; gw/gh (game-window size px). No return.
LootLabelRectsRefresh(reader, gw, gh)
{
    global g_llcEnabled, g_llcRects, g_llcContainer, g_llcContainerTick, g_llcLastTick
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

    ; Ensure a valid container; re-find at most every ~1.5 s when missing.
    cont := g_llcContainer
    if (!cont || !reader.IsProbablyValidPointer(cont))
    {
        if ((A_TickCount - g_llcContainerTick) > 1500)
        {
            g_llcContainer := _LlcFindContainer(reader, root)
            g_llcContainerTick := A_TickCount
            cont := g_llcContainer
        }
    }
    if !(cont && reader.IsProbablyValidPointer(cont))
    {
        g_llcRects := []
        return
    }

    sY  := gh / 1600.0
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    txtOff := PoE2Offsets.UiElementBase["TextPtr"]
    rects := []
    queue := [cont], visited := Map(), nodes := 0
    while (queue.Length > 0 && nodes < 400)
    {
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        nodes += 1
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
        if (g["visible"] && g["sizeW"] > 0 && g["sizeH"] > 0)
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
                    x := Round(sp["x"] * sY), y := Round(sp["y"] * sY)
                    w := Round(g["sizeW"] * sY), h := Round(g["sizeH"] * sY)
                    ; Keep only labels that land on screen.
                    if (w > 0 && h > 0 && x < gw && y < gh && x + w > 0 && y + h > 0)
                        rects.Push([x, y, w, h])
                }
            }
        }
        cf := g["childFirst"], cl := g["childLast"]
        if (reader.IsProbablyValidPointer(cf) && cl > cf)
        {
            n := Min((cl - cf) // A_PtrSize, 256)
            buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
            if buf
            {
                Loop n
                {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }
    g_llcRects := rects
}
