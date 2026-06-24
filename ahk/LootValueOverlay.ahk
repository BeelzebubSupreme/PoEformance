; LootValueOverlay.ahk
; Step 2 of the value-aware loot radar: a ranked "valuable nearby" list painted on the
; play area. Extends GdiOverlayBase and is registered with the OverlayManager (so it rides
; the uniform Enabled -> ShouldShow -> Layout -> Draw -> Blit contract and the per-tick
; game-window context). Reads the sorted g_lrvNearby cache (rebuilt ~4 Hz in
; LootRadarValue.ahk) and renders each drop as the corresponding currency orb IMAGE
; (Exalted / Divine, via OverlayImage.ahk) + amount + item name — never a "1ex / 1div"
; text unit. Falls back to a small "ex"/"div" text tag only if the icons failed to load.
; Anchored to the left edge, mid-screen (typically clear in PoE2); hidden while a large
; blocking panel (Atlas / inventory / tree) is open.
; Included by InGameStateMonitor.ahk BEFORE OverlayManager (which registers it).

class LootValueOverlay extends GdiOverlayBase
{
    __New()
    {
        super.__New(255)
        this.Name   := "lootvalue"
        this._fontH := -16
        this._scale := 1.0
        this._rows  := []          ; cached [{parts, num, name, valueEx}] for the current frame
    }

    ShouldShow(ctx)
    {
        global g_lrvEnabled, g_lrvShowList, g_lrvNearby
        if !(IsSet(g_lrvEnabled) && g_lrvEnabled && IsSet(g_lrvShowList) && g_lrvShowList)
            return false
        if !ctx.gameActive
            return false
        if !(IsSet(g_lrvNearby) && IsObject(g_lrvNearby) && g_lrvNearby.Length > 0)
            return false
        ; Hide while a large blocking panel is open (Atlas / inventory / passive tree).
        if (ctx.snapshot && Type(ctx.snapshot) = "Map")
        {
            pv := ctx.snapshot.Has("panelVisibility") ? ctx.snapshot["panelVisibility"] : 0
            if (pv && IsObject(pv) && pv.Has("anyPanelOpen") && pv["anyPanelOpen"])
                return false
        }
        return (ctx.gwW >= 200 && ctx.gwH >= 100)
    }

    ; Builds the row model + measures the panel size from the longest row.
    Layout(ctx)
    {
        global g_lrvNearby, g_lrvListMax, g_ltUiScale, g_ltBarOpacity
        scale := _LtBarScale(ctx.gwH, IsSet(g_ltUiScale) ? g_ltUiScale : 1.0)
        this._scale := scale
        this._fontH := -Round(16 * scale)

        maxRows := (IsSet(g_lrvListMax) && g_lrvListMax > 0) ? g_lrvListMax : 8
        rows := []
        for _, info in g_lrvNearby
        {
            if (rows.Length >= maxRows)
                break
            if !(info && IsObject(info))
                continue
            ex := info.Has("valueEx") ? info["valueEx"] : 0
            nm := info.Has("label") ? info["label"] : ""
            if (StrLen(nm) > 24)
                nm := SubStr(nm, 1, 23) "…"
            rows.Push(Map("parts", LrvValueParts(ex), "name", nm, "dist", (info.Has("distM") ? info["distM"] : -1)))
        }
        this._rows := rows

        font := this._GetFont(this._fontH, 600)
        titleFont := this._GetFont(this._fontH, 700)
        padX := Round(9 * scale), padY := Round(6 * scale)
        this._padX := padX, this._padY := padY
        this._iconSz := Round(-this._fontH * 1.15)
        this._gap    := Round(6 * scale)
        this._lineH  := Max(this._iconSz, Round(-this._fontH * 1.25)) + Round(4 * scale)

        ; Width = widest of (title, every row: icon + num + name).
        tW := this._MeasureText(titleFont, "Valuable nearby")["w"]
        maxW := tW
        for _, r in rows
        {
            numW  := this._MeasureText(font, r["parts"]["num"])["w"]
            nameW := this._MeasureText(font, "  " r["name"])["w"]
            distW := (r["dist"] >= 0) ? this._MeasureText(font, "  " r["dist"] "m")["w"] : 0
            rowW  := this._iconSz + this._gap + numW + nameW + distW
            if (rowW > maxW)
                maxW := rowW
        }

        barW := maxW + padX * 2
        barH := padY * 2 + this._lineH * (rows.Length + 1)   ; +1 for the title line

        a := _LtClampInt(Round((IsSet(g_ltBarOpacity) ? g_ltBarOpacity : 0.9) * 255), 60, 255)
        if (a != this._alpha)
            this.SetAlpha(a)

        x := ctx.gwX + Round(16 * scale)
        y := ctx.gwY + Round(ctx.gwH * 0.30)
        return Map("x", x, "y", y, "w", barW, "h", barH)
    }

    Draw(ctx, rect)
    {
        w := rect["w"], h := rect["h"], scale := this._scale
        gold := 0x5AA8C8, textCol := 0xE0E0E0

        this._FillRect(0, 0, w, h, 0x101010)
        this._DrawRectOutline(0, 0, w, h, gold, 1)

        titleFont := this._GetFont(this._fontH, 700)
        font := this._GetFont(this._fontH, 600)
        padX := this._padX, padY := this._padY
        iconSz := this._iconSz, gap := this._gap, lineH := this._lineH

        ; Title
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", titleFont, "Ptr")
        this._DrawText(padX, padY, "Valuable nearby", gold)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)

        ; Rows: [orb image] amount  name
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        y := padY + lineH
        for _, r in this._rows
        {
            parts := r["parts"]
            iconY := y + (lineH - iconSz) // 2 - Round(2 * scale)
            drewIcon := this._DrawIcon(parts["icon"], padX, iconY, iconSz, iconSz)
            tx := padX + iconSz + gap
            this._DrawText(tx, y, parts["num"], gold)
            numW := this._MeasureText(font, parts["num"])["w"]
            ; If the orb image is unavailable, append a tiny unit tag so the value still reads.
            unitTag := drewIcon ? "" : (parts["icon"] = "divine" ? "div " : "ex ")
            nameStr := "  " unitTag r["name"]
            this._DrawText(tx + numW, y, nameStr, textCol)
            ; Distance to the drop, dim, at the row end.
            if (r["dist"] >= 0)
            {
                nameW := this._MeasureText(font, nameStr)["w"]
                this._DrawText(tx + numW + nameW, y, "  " r["dist"] "m", 0x808080)
            }
            y += lineH
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}
