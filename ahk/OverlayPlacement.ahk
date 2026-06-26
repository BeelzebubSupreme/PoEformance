; OverlayPlacement.ahk
; Generic free-positioning for the GDI info overlays (Debug, the Valuable-loot list,
; the two Loot bars, the Alert banner and the Focus readout). Each placeable overlay
; may store an OPTIONAL top-left anchor as a fraction of the game window (xPct/yPct).
; While no override is stored the overlay keeps its built-in default anchor, so nothing
; moves until the user drags it — free positioning is opt-in.
;
; Per-overlay drag "edit mode" (g_ovEdit[name]) reuses the Vitals drag machinery,
; lifted into GdiOverlayBase: turning Move on for one overlay makes just that window
; clickable + draggable; dragging updates its xPct/yPct; turning Move off (or releasing
; the button) persists. Self-persists [OverlayPlacement] in poeformance_config.ini.
; Included by InGameStateMonitor.ahk (after GdiOverlayBase, before OverlayManager builds
; the overlays). Globals g_ovPlace / g_ovEdit are declared in InGameStateMonitor.ahk and
; seeded here (AHK v2 module-init gotcha — top-level initializers in #Include'd modules
; do not run).

; Returns the ordered list of placeable overlays as Map("name","label"). The name MUST
; match the overlay's .Name (its OverlayManager id). Single source of truth for the
; header push + the UI panel.
OverlayPlaceableList()
{
    return [ Map("name", "debug",        "label", "Debug overlay")
           , Map("name", "lootvalue",    "label", "Valuable-loot list")
           , Map("name", "lootstrip",    "label", "Loot bar (on map)")
           , Map("name", "lootcompact",  "label", "Loot bar (hideout)")
           , Map("name", "notification", "label", "Alert banner")
           , Map("name", "focus",        "label", "Focus readout") ]
}

; True when name is a known placeable overlay.
_OvIsPlaceable(name)
{
    for it in OverlayPlaceableList()
        if (it["name"] = name)
            return true
    return false
}

; Clamps a fraction to [0,1].
_OvClampFrac(v) => (v < 0) ? 0.0 : (v > 1) ? 1.0 : v

; Seeds the placement globals (unconditionally, per the init gotcha) then overlays any
; persisted overrides + the Focus-overlay enabled flag from [OverlayPlacement].
LoadOverlayPlacement()
{
    global g_ovPlace, g_ovEdit, g_focusOverlayEnabled
    g_ovPlace := Map()
    g_ovEdit  := Map()
    f := _ConfigPath()
    if FileExist(f)
    {
        for it in OverlayPlaceableList()
        {
            nm := it["name"]
            xs := IniRead(f, "OverlayPlacement", nm "_xPct", "")
            ys := IniRead(f, "OverlayPlacement", nm "_yPct", "")
            if (xs != "" && ys != "")
                g_ovPlace[nm] := Map("xPct", _OvClampFrac(Float(xs)), "yPct", _OvClampFrac(Float(ys)))
        }
        ; Focus overlay enabled state now persists (default OFF — it was a stuck debug
        ; leftover); the toggle therefore survives a restart.
        g_focusOverlayEnabled := (IniRead(f, "OverlayPlacement", "focus_enabled", "0") = "1")
    }
    else
        g_focusOverlayEnabled := false
}

; Persists the current placement overrides (and the focus-enabled flag). Names with no
; override get their keys deleted so a reset is durable.
SaveOverlayPlacement()
{
    global g_ovPlace, g_focusOverlayEnabled
    f := _ConfigPath()
    for it in OverlayPlaceableList()
    {
        nm := it["name"]
        if (IsSet(g_ovPlace) && IsObject(g_ovPlace) && g_ovPlace.Has(nm))
        {
            IniWrite(Round(g_ovPlace[nm]["xPct"], 5), f, "OverlayPlacement", nm "_xPct")
            IniWrite(Round(g_ovPlace[nm]["yPct"], 5), f, "OverlayPlacement", nm "_yPct")
        }
        else
        {
            try IniDelete(f, "OverlayPlacement", nm "_xPct")
            try IniDelete(f, "OverlayPlacement", nm "_yPct")
        }
    }
    IniWrite((IsSet(g_focusOverlayEnabled) && g_focusOverlayEnabled) ? "1" : "0", f, "OverlayPlacement", "focus_enabled")
}

; True when overlay <name> is in drag edit mode.
_OvEditOn(name)
{
    global g_ovEdit
    return (IsSet(g_ovEdit) && IsObject(g_ovEdit) && g_ovEdit.Has(name) && g_ovEdit[name]) ? true : false
}

; Sets (or clears) drag edit mode for one overlay, syncs that overlay's window
; interactivity immediately, and persists when leaving edit mode. Bridge: SetOverlayEdit.
SetOverlayEdit(name, on)
{
    global g_ovEdit, g_overlayManager
    if !_OvIsPlaceable(name)
        return
    g_ovEdit[name] := (on = true || on = 1 || on = "1" || on = "true")
    if (IsSet(g_overlayManager) && IsObject(g_overlayManager))
    {
        ov := g_overlayManager.Get(name)
        if IsObject(ov)
            try ov._EnsureOverlayEditStyle()
    }
    if !g_ovEdit[name]
        SaveOverlayPlacement()
}

; Sets one position axis ("x"/"y") for an overlay from a UI PERCENT value (0..100).
; Creates the override if needed, persists, refreshes the header. Bridge: SetOverlayPos.
SetOverlayPos(name, axis, pct)
{
    global g_ovPlace
    if !_OvIsPlaceable(name)
        return
    frac := _OvClampFrac((pct + 0) / 100.0)
    if !g_ovPlace.Has(name)
        g_ovPlace[name] := Map("xPct", 0.5, "yPct", 0.5)
    if (axis = "x" || axis = "xPct")
        g_ovPlace[name]["xPct"] := frac
    else if (axis = "y" || axis = "yPct")
        g_ovPlace[name]["yPct"] := frac
    SaveOverlayPlacement()
    SetTimer(PushHeaderToWebView, -50)
}

; Clears an overlay's override so it returns to its built-in default anchor. Bridge: ResetOverlayPos.
ResetOverlayPos(name)
{
    global g_ovPlace
    if (IsSet(g_ovPlace) && IsObject(g_ovPlace) && g_ovPlace.Has(name))
        g_ovPlace.Delete(name)
    SaveOverlayPlacement()
    SetTimer(PushHeaderToWebView, -50)
}

; Sets the Focus overlay enabled state (persisted). Bridge: SetFocusOverlay.
SetFocusOverlayEnabled(on)
{
    global g_focusOverlayEnabled, g_focusOverlay
    g_focusOverlayEnabled := (on = true || on = 1 || on = "1" || on = "true")
    if (!g_focusOverlayEnabled && IsSet(g_focusOverlay) && IsObject(g_focusOverlay))
        try g_focusOverlay.Hide()
    SaveOverlayPlacement()
    SetTimer(PushHeaderToWebView, -50)
}

; Serialises placement state for the header push: per overlay { moved, xPct, yPct, edit }
; plus the focus-enabled flag. xPct/yPct are the stored override (as PERCENT) and are
; omitted when unmoved (the UI shows them blank / "auto").
BuildOverlayPlacementHeaderJson()
{
    global g_ovPlace, g_focusOverlayEnabled
    items := Map()
    for it in OverlayPlaceableList()
    {
        nm := it["name"]
        moved := (IsSet(g_ovPlace) && IsObject(g_ovPlace) && g_ovPlace.Has(nm))
        m := Map("moved", moved, "edit", _OvEditOn(nm))
        if moved
        {
            m["xPct"] := Round(g_ovPlace[nm]["xPct"] * 100, 1)
            m["yPct"] := Round(g_ovPlace[nm]["yPct"] * 100, 1)
        }
        items[nm] := m
    }
    return JsonFull_Stringify(Map(
        "focusEnabled", (IsSet(g_focusOverlayEnabled) && g_focusOverlayEnabled) ? true : false,
        "items", items), false)
}
