; LootTrackerOverlay.ahk
; The two on-screen LootTracker bars (ported from LootTrackerCore.Inventory.cs's
; ImGui DrawMapBar / DrawCompactBar). Both extend GdiOverlayBase and are registered
; with the OverlayManager (so they ride the uniform ShouldShow/Layout/Draw contract and
; the per-tick game-window context). Like NotificationOverlay they bypass the play
; overlay gate — they have their own visibility rules:
;   * LootMapStripOverlay  — a slim strip near the bottom, shown while ON a map.
;   * LootCompactBarOverlay — a wider session read-out, shown in hideout/town (and
;     hidden while a large panel like the Atlas is open).
; Both render from the cached g_ltLiveView (rebuilt ~4 Hz in LootTracker.ahk); the live
; run timer is recomputed fresh each frame so it ticks smoothly.
; Included by InGameStateMonitor.ahk BEFORE OverlayManager (which registers them).

; ── Map strip (shown on maps) ──────────────────────────────────────────────────
class LootMapStripOverlay extends GdiOverlayBase
{
    __New()
    {
        super.__New(255)
        this.Name  := "lootstrip"
        this._segs := []
        this._fontH := -20
        this._padX := 10, this._padY := 5, this._gap := 12
        this.Placeable := true   ; free-positionable (OverlayPlacement.ahk)
    }

    ShouldShow(ctx)
    {
        global g_ltEnabled, g_ltOnMap, g_ltCurrent
        if !g_ltEnabled
            return false
        if !ctx.gameActive
            return false
        if !(g_ltOnMap && g_ltCurrent && IsObject(g_ltCurrent))
            return false
        return (ctx.gwW >= 200 && ctx.gwH >= 100)
    }

    Layout(ctx)
    {
        global g_ltBarOpacity, g_ltBarOnRight, g_ltBarBottomOffset, g_ltUiScale
        scale := _LtBarScale(ctx.gwH, g_ltUiScale)
        this._fontH := -Round(20 * scale)
        this._segs  := _LtBuildStripSegments()

        font := this._GetFont(this._fontH, 600)
        padX := Round(10 * scale), padY := Round(5 * scale), gap := Round(12 * scale)
        totalW := 0, maxH := 0
        for i, s in this._segs
        {
            m := this._MeasureText(font, s["text"])
            totalW += m["w"] + (i > 1 ? gap : 0)
            maxH := Max(maxH, m["h"])
        }
        this._padX := padX, this._padY := padY, this._gap := gap
        barW := totalW + padX * 2
        barH := maxH + padY * 2

        a := _LtClampInt(Round(g_ltBarOpacity * 255), 40, 255)
        if (a != this._alpha)
            this.SetAlpha(a)

        ; Built-in default anchor: bottom edge, left/right per the legacy knobs (kept
        ; as the default only — the UI controls are gone). _Placed() applies a user
        ; override if set, which is the new way to position it.
        defY := ctx.gwY + ctx.gwH - Round(g_ltBarBottomOffset * scale) - barH
        defX := g_ltBarOnRight ? (ctx.gwX + ctx.gwW - Round(12 * scale) - barW) : (ctx.gwX + Round(12 * scale))
        return this._Placed(ctx, defX, defY, barW, barH)
    }

    Draw(ctx, rect)
    {
        this._FillRect(0, 0, rect["w"], rect["h"], 0x101010)
        font := this._GetFont(this._fontH, 600)
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        x := this._padX
        for i, s in this._segs
        {
            if (i > 1)
                x += this._gap
            this._DrawText(x, this._padY, s["text"], s["color"])
            m := this._MeasureText(font, s["text"])
            x += m["w"]
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}

; ── Compact hideout bar (shown in hideout/town) ────────────────────────────────
class LootCompactBarOverlay extends GdiOverlayBase
{
    __New()
    {
        super.__New(255)
        this.Name   := "lootcompact"
        this._fontH := -16
        this._scale := 1.0
        this.Placeable := true   ; free-positionable (OverlayPlacement.ahk)
    }

    ShouldShow(ctx)
    {
        global g_ltEnabled, g_ltOnMap, g_panelHideLootBars
        if !g_ltEnabled
            return false
        if !ctx.gameActive
            return false
        if g_ltOnMap
            return false
        ; Hide while a large blocking panel is open (Atlas / inventory / passive
        ; tree) — gated by g_panelHideLootBars.
        if (IsSet(g_panelHideLootBars) && g_panelHideLootBars && ctx.snapshot && Type(ctx.snapshot) = "Map")
        {
            pv := ctx.snapshot.Has("panelVisibility") ? ctx.snapshot["panelVisibility"] : 0
            if (pv && IsObject(pv) && pv.Has("anyPanelOpen") && pv["anyPanelOpen"])
                return false
        }
        return (ctx.gwW >= 200 && ctx.gwH >= 100)
    }

    Layout(ctx)
    {
        global g_ltBarOpacity, g_ltBarOnRight, g_ltBarBottomOffset, g_ltUiScale, g_ltCompactHeight
        scale := _LtBarScale(ctx.gwH, g_ltUiScale)
        this._scale := scale
        this._fontH := -Round(16 * scale)
        barH := Round(g_ltCompactHeight * scale)
        barW := Min(Round(560 * scale), ctx.gwW - Round(40 * scale))
        if (barW < 200)
            barW := 200

        a := _LtClampInt(Round(g_ltBarOpacity * 255), 40, 255)
        if (a != this._alpha)
            this.SetAlpha(a)

        ; Built-in default anchor: bottom edge, left/right per the legacy knobs (kept
        ; as the default only). _Placed() applies a user override if set.
        defY := ctx.gwY + ctx.gwH - Round(g_ltBarBottomOffset * scale) - barH
        defX := g_ltBarOnRight ? (ctx.gwX + ctx.gwW - Round(20 * scale) - barW) : (ctx.gwX + Round(20 * scale))
        return this._Placed(ctx, defX, defY, barW, barH)
    }

    Draw(ctx, rect)
    {
        global g_ltLiveView
        w := rect["w"], h := rect["h"], scale := this._scale
        this._FillRect(0, 0, w, h, 0x101010)
        this._DrawRectOutline(0, 0, w, h, 0x5AA8C8, 1)

        font := this._GetFont(this._fontH, 600)
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")

        v := g_ltLiveView
        textCol := 0xE0E0E0, green := 0x80E680, red := 0x8080E6, dim := 0x9A9A9A
        padX := Round(10 * scale), padY := Round(6 * scale)
        lineH := Round(-this._fontH * 1.4)

        maps  := _LtV(v, "maps", 0)
        avgT  := _LtFmtDurMs(_LtV(v, "avgTimeMs", 0))
        avgE  := Round(_LtV(v, "avgEx", 0))
        totEx := _LtV(v, "sessEx", 0)
        rate  := _LtV(v, "divRate", 0)
        perH  := _LtV(v, "sessPerHourEx", 0)
        totDiv  := (rate > 0) ? Format("{:.1f}", totEx / rate) : "—"
        perHDiv := (rate > 0) ? Format("{:.1f}", perH / rate) : "—"
        sessT := _LtFmtDurMs(_LtV(v, "sessTimeMs", 0))

        y := padY
        this._DrawText(padX, y, "Maps: " maps "    AVG: " avgT "    " avgE " ex/map", textCol)
        y += lineH
        this._DrawText(padX, y, "Total: " totDiv " div    " perHDiv " div/h    Session: " sessT, (totEx >= 0 ? green : textCol))
        y += lineH
        this._DrawText(padX, y, "Recent maps", dim)
        y += lineH

        runs := (v && IsObject(v) && v.Has("runs") && Type(v["runs"]) = "Array") ? v["runs"] : []
        col2 := padX + Round(230 * scale)
        col3 := padX + Round(320 * scale)
        maxRows := (lineH > 0) ? Max(0, (h - y - padY) // lineH) : 0
        r := 0
        for _, run in runs
        {
            if (r >= maxRows)
                break
            nm := run["name"]
            if (StrLen(nm) > 26)
                nm := SubStr(nm, 1, 25) "…"
            this._DrawText(padX, y, nm, textCol)
            this._DrawText(col2, y, _LtFmtDurMs(run["timeMs"]), dim)
            ex := run["ex"]
            this._DrawText(col3, y, _LtFmtSigned(ex, 1) " ex", (ex >= 0 ? green : red))
            y += lineH
            r += 1
        }

        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}

; ── Shared overlay helpers ─────────────────────────────────────────────────────
; Builds the [{text,color}] segment list for the map strip from g_ltLiveView. The live
; timer is recomputed here so it ticks smoothly even between view rebuilds.
_LtBuildStripSegments()
{
    global g_ltLiveView, g_ltShowKills
    v := g_ltLiveView
    textCol := 0xE0E0E0, green := 0x80E680, red := 0x8080E6, dim := 0x9A9A9A
    segs := []

    global g_exploreCurrentPercent
    name := _LtV(v, "name", "")
    nameText := (name = "" ? "—" : name)
    ; Append the live map-coverage percentage in parentheses. Reuses the AutoPilot
    ; ExplorationModule's measurement (g_exploreCurrentPercent), kept fresh every
    ; tick via TryExploration(..., measureOnly) when AutoPilot is off. Only once a
    ; coverage figure exists (> 0).
    if (IsSet(g_exploreCurrentPercent) && g_exploreCurrentPercent > 0)
        nameText .= " (explored: " Round(g_exploreCurrentPercent) "%)"
    segs.Push(Map("text", nameText, "color", textCol))
    segs.Push(Map("text", _LtFmtDurMs(_LtCurrentLiveTimeMs()), "color", textCol))

    ex := _LtV(v, "profitEx", 0)
    segs.Push(Map("text", _LtFmtSigned(ex, 0) " ex", "color", (ex >= 0 ? green : red)))

    rate := _LtV(v, "divRate", 0)
    if (rate > 0)
        segs.Push(Map("text", "(" _LtFmtSigned(ex / rate, 1) " div)", "color", (ex >= 0 ? green : red)))

    if (g_ltShowKills && v && IsObject(v) && v.Has("kills"))
    {
        k := v["kills"]
        ktext := (k.Has(1) ? k[1] : 0) "·" (k.Has(2) ? k[2] : 0) "·" (k.Has(3) ? k[3] : 0) "·" (k.Has(4) ? k[4] : 0)
        segs.Push(Map("text", ktext, "color", dim))
    }
    return segs
}

; Map-value-or-default reader.
_LtV(v, key, dflt)
{
    return (v && IsObject(v) && v.Has(key)) ? v[key] : dflt
}

; Game-UI scale factor for the bars: auto (gwH / 1600) times the manual knob, clamped.
_LtBarScale(gwH, uiScale)
{
    auto := (gwH > 0) ? (gwH / 1600.0) : 1.0
    s := auto * uiScale
    return (s < 0.5) ? 0.5 : (s > 3.0) ? 3.0 : s
}

; ms -> "mm:ss" (or "h:mm:ss" past an hour).
_LtFmtDurMs(ms)
{
    s := ms // 1000
    h := s // 3600
    m := Mod(s, 3600) // 60
    sec := Mod(s, 60)
    if (h >= 1)
        return h ":" Format("{:02}", m) ":" Format("{:02}", sec)
    return Format("{:02}", m) ":" Format("{:02}", sec)
}

; Signed numeric format: "+12" / "-3" / "0" (dec=0) or "+0.5" / "0.0" (dec>0).
_LtFmtSigned(x, dec)
{
    n := Round(x + 0, dec)
    body := (dec > 0) ? Format("{:." dec "f}", n) : (Round(n) "")
    if (n > 0)
        return "+" body
    return body
}
