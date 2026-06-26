; GdiOverlayBase.ahk
; Shared base for lightweight, always-on-top, click-through GDI overlay windows.
; Provides the transparent window, double-buffer management, cached GDI objects
; (pens / brushes / fonts) and basic draw / blit / show / hide plumbing. Subclasses add
; their own state + render logic and call _EnsureShown()/_Blit() once per frame.
;
; NOTE: RadarOverlay and VitalsOverlay predate this base and remain standalone for now;
; migrating them onto GdiOverlayBase is a separate, in-game-testable step. New overlays
; (e.g. NotificationOverlay) should extend this class. Member naming mirrors VitalsOverlay
; (memDC / hwnd / bufW / bufH) as the canonical contract.
; Included by InGameStateMonitor.ahk (before any subclass).

class GdiOverlayBase
{
    ; Creates the transparent, click-through overlay window and initialises GDI state.
    ; transAlpha is the overall window opacity 0-255 (the 010101 colour-key stays transparent).
    __New(transAlpha := 255)
    {
        ; +ToolWindow keeps the overlay out of the taskbar / Alt-Tab list, so the
        ; per-tick Show()/Hide() cycle no longer flashes a taskbar button.
        this.overlayGui := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x80000")
        this.overlayGui.BackColor := "010101"
        this.hwnd        := this.overlayGui.Hwnd
        this.memDC       := 0
        this.bitmap      := 0
        this.bufW        := 0
        this.bufH        := 0
        this.isVisible   := false
        this._styled     := false
        this._alpha      := transAlpha
        this._lastX      := -1
        this._lastY      := -1
        this._lastW      := 0
        this._lastH      := 0
        this._penCache   := Map()
        this._brushCache := Map()
        this._fontCache  := Map()
        this._bgBrush    := 0          ; cached transparent-key fill brush (back-buffer clear)
        ; ── Overlay contract (driven by OverlayManager) ──────────────────────
        this.Name        := "overlay"  ; subclasses override with a stable id
        this.Enabled     := true       ; master on/off toggle (manager hides when false)
        this._hideSince  := 0          ; A_TickCount when ShouldShow first went false (hide debounce)
        this._lastTopmostTick := 0     ; A_TickCount of the last periodic topmost re-assert
        ; Reusable scratch objects so the per-frame draw path allocates nothing:
        ; one RECT buffer (fill/outline), one SIZE buffer (text measure), and the
        ; process-wide NULL_BRUSH handle (stock object — never freed). Cuts a
        ; Buffer()/GetStockObject churn on every overlay blit.
        this._rectBuf     := Buffer(16, 0)
        this._textSizeBuf := Buffer(8, 0)
        this._nullBrush   := DllCall("GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH (hollow)
        ; ── Free-placement / drag edit (OverlayPlacement.ahk) ────────────────
        ; Opt-in: subclasses set Placeable := true to gain a stored xPct/yPct anchor
        ; and a per-overlay drag "Move" mode. The game-window rect is cached each
        ; tick because the async drag handlers need it off the render path.
        this.Placeable          := false
        this._gwX := 0, this._gwY := 0, this._gwW := 0, this._gwH := 0
        this._ovEditInteractive := false
        this._ovMouseBound      := false
        this._ovDragging        := false
        this._ovFnDragTick      := 0
        this._ovFnDown          := 0
        this._ovDownSX := 0, this._ovDownSY := 0   ; cursor screen pos at mouse-down
        this._ovAnchorX := 0, this._ovAnchorY := 0  ; window screen pos at mouse-down
    }

    ; ── Overlay contract ─────────────────────────────────────────────────────
    ; Template method run once per tick by OverlayManager. Subclasses do NOT
    ; override Update(); they override the three hooks below. Update() owns the
    ; uniform Enabled → ShouldShow → Layout → draw → blit flow and is the single
    ; place that decides show vs. hide, which keeps every overlay flicker-free by
    ; construction.
    ;
    ; Hide-debounce: a single-tick ShouldShow=false (e.g. a gate condition like
    ; isAlive briefly mis-reading during the game's GC) must NOT blink the overlay.
    ; While already visible, a false result keeps the last frame on screen and only
    ; hides after HIDE_DEBOUNCE_MS of continuous false. Showing is always immediate.
    static HIDE_DEBOUNCE_MS := 250

    Update(ctx)
    {
        global Profiler
        ; Placeable overlays cache the game-window rect (the async drag handlers need
        ; it) and keep their click-through / mouse-hook state in sync with the
        ; per-overlay Move toggle. In edit mode the overlay force-shows so it can be
        ; grabbed even when its normal ShouldShow gate is false.
        editing := false
        if this.Placeable
        {
            this._gwX := ctx.gwX, this._gwY := ctx.gwY, this._gwW := ctx.gwW, this._gwH := ctx.gwH
            this._EnsureOverlayEditStyle()
            editing := _OvEditOn(this.Name) && (ctx.gwW > 100 && ctx.gwH > 100)
        }
        if (!this.Enabled || (!editing && !this.ShouldShow(ctx)))
        {
            this._RequestHide()
            return
        }
        rect := this.Layout(ctx)
        if (!rect || rect["w"] < 1 || rect["h"] < 1)
        {
            if !editing
            {
                this._RequestHide()
                return
            }
            rect := this._OvPlaceholderRect()   ; nothing to size against yet — show a grab box
        }
        this._hideSince := 0
        if !this._EnsureShown(rect["x"], rect["y"], rect["w"], rect["h"])
            return
        this._ClearBackBuffer(rect["w"], rect["h"])
        Profiler.Begin("ov." this.Name ".draw")
        this.Draw(ctx, rect)
        if editing
            this._OvDrawEditChrome(rect)
        Profiler.End("ov." this.Name ".draw")
        Profiler.Begin("ov." this.Name ".blit")
        this._Blit(rect["w"], rect["h"])
        Profiler.End("ov." this.Name ".blit")
    }

    ; Debounced hide: keeps the last drawn frame on screen for up to
    ; HIDE_DEBOUNCE_MS of continuous "should hide" before actually hiding, so a
    ; one-tick visibility blip never flickers the overlay.
    _RequestHide()
    {
        if !this.isVisible          ; never shown / already hidden — nothing to debounce
            return
        if (this._hideSince = 0)
            this._hideSince := A_TickCount
        if ((A_TickCount - this._hideSince) >= GdiOverlayBase.HIDE_DEBOUNCE_MS)
        {
            this.Hide()
            this._hideSince := 0
        }
        ; else: within the debounce window — leave the last frame up, do nothing.
    }

    ; ── Free placement (OverlayPlacement.ahk) ─────────────────────────────────
    ; Resolves the final screen rect for a placeable overlay. The subclass passes the
    ; screen x,y of its BUILT-IN default anchor (computed exactly as before) plus its
    ; own w,h; when the user has stored an override for this overlay it wins (top-left
    ; = xPct/yPct of the game window). The result is clamped inside the game window.
    _Placed(ctx, defX, defY, w, h)
    {
        global g_ovPlace
        x := defX, y := defY
        if (IsSet(g_ovPlace) && IsObject(g_ovPlace) && g_ovPlace.Has(this.Name))
        {
            p := g_ovPlace[this.Name]
            x := ctx.gwX + Round(p["xPct"] * ctx.gwW)
            y := ctx.gwY + Round(p["yPct"] * ctx.gwH)
        }
        x := Min(ctx.gwX + ctx.gwW - w, Max(ctx.gwX, x))
        y := Min(ctx.gwY + ctx.gwH - h, Max(ctx.gwY, y))
        return Map("x", x, "y", y, "w", w, "h", h)
    }

    ; Fallback rect while in edit mode but the overlay has no content to size itself
    ; (e.g. the loot list with nothing nearby): a small labeled grab box at the stored
    ; position (or the window centre when unmoved).
    _OvPlaceholderRect()
    {
        global g_ovPlace
        w := 240, h := 44
        x := this._gwX + (this._gwW - w) // 2
        y := this._gwY + (this._gwH - h) // 2
        if (IsSet(g_ovPlace) && IsObject(g_ovPlace) && g_ovPlace.Has(this.Name) && this._gwW > 1)
        {
            p := g_ovPlace[this.Name]
            x := this._gwX + Round(p["xPct"] * this._gwW)
            y := this._gwY + Round(p["yPct"] * this._gwH)
        }
        x := Min(this._gwX + this._gwW - w, Max(this._gwX, x))
        y := Min(this._gwY + this._gwH - h, Max(this._gwY, y))
        return Map("x", x, "y", y, "w", w, "h", h)
    }

    ; Draws the edit-mode chrome over the overlay: a bright grab frame + the overlay
    ; name, so the user can see and grab the otherwise content-shaped window.
    _OvDrawEditChrome(rect)
    {
        w := rect["w"], h := rect["h"]
        this._DrawRectOutline(0, 0, w, h, 0x66E0FF, 2)   ; bright cyan grab frame (BGR)
        font := this._GetFont(-13, 700)
        old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        this._DrawText(4, 1, "+ " this.Name, 0x66E0FF)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
    }

    ; Syncs the window's click-through + mouse hook with this overlay's Move toggle.
    ; Mirrors VitalsBarWindow._EnsureEditStyle but keyed off g_ovEdit[Name].
    _EnsureOverlayEditStyle()
    {
        want := _OvEditOn(this.Name)
        if (want = this._ovEditInteractive)
            return
        if !this._styled
            return
        if want
        {
            WinSetExStyle("-0x20", this.hwnd)   ; remove WS_EX_TRANSPARENT -> clickable
            this._OvRegisterMouse()
        }
        else
        {
            WinSetExStyle("+0x20", this.hwnd)   ; restore click-through
            this._OvUnregisterMouse()
        }
        this._ovEditInteractive := want
    }

    _OvRegisterMouse()
    {
        if this._ovMouseBound
            return
        this._ovFnDown := ObjBindMethod(this, "_OvOnLDown")
        OnMessage(0x201, this._ovFnDown)   ; WM_LBUTTONDOWN
        this._ovMouseBound := true
    }

    _OvUnregisterMouse()
    {
        if !this._ovMouseBound
            return
        OnMessage(0x201, this._ovFnDown, 0)
        this._ovMouseBound := false
        this._OvEndDrag()
    }

    _OvCursorScreen(&cx, &cy)
    {
        pt := Buffer(8, 0)
        DllCall("GetCursorPos", "Ptr", pt)
        cx := NumGet(pt, 0, "Int")
        cy := NumGet(pt, 4, "Int")
    }

    ; Mouse-down on the overlay starts a drag: capture + a 10 ms poll that follows the
    ; cursor while the left button is physically held (robust for tiny windows).
    _OvOnLDown(wParam, lParam, msg, hwnd)
    {
        if (hwnd != this.hwnd)
            return
        cx := 0, cy := 0
        this._OvCursorScreen(&cx, &cy)
        this._ovDownSX := cx, this._ovDownSY := cy
        this._ovAnchorX := this._lastX, this._ovAnchorY := this._lastY
        this._ovDragging := true
        DllCall("SetCapture", "Ptr", this.hwnd)
        if !this._ovFnDragTick
            this._ovFnDragTick := ObjBindMethod(this, "_OvDragTick")
        SetTimer(this._ovFnDragTick, 10)
    }

    ; Poll: reposition the window to follow the cursor; persist + push when the button
    ; is released. Updates g_ovPlace[Name] live so the stored anchor tracks the drag.
    _OvDragTick()
    {
        global g_ovPlace
        if !this._ovDragging
        {
            SetTimer(this._ovFnDragTick, 0)
            return
        }
        if !GetKeyState("LButton", "P")   ; released anywhere -> finish
        {
            this._OvEndDrag()
            SaveOverlayPlacement()
            SetTimer(PushHeaderToWebView, -30)
            return
        }
        cx := 0, cy := 0
        this._OvCursorScreen(&cx, &cy)
        gwX := this._gwX, gwY := this._gwY, gwW := this._gwW, gwH := this._gwH
        if (gwW < 1 || gwH < 1)
            return
        w := this._lastW, h := this._lastH
        nsx := this._ovAnchorX + (cx - this._ovDownSX)
        nsy := this._ovAnchorY + (cy - this._ovDownSY)
        nsx := Min(gwX + gwW - w, Max(gwX, nsx))   ; clamp inside the game window
        nsy := Min(gwY + gwH - h, Max(gwY, nsy))
        if !IsObject(g_ovPlace)
            return
        g_ovPlace[this.Name] := Map("xPct", (nsx - gwX) / gwW, "yPct", (nsy - gwY) / gwH)
        WinMove(nsx, nsy, , , this.hwnd)
        this._lastX := nsx, this._lastY := nsy   ; keep base move-tracking in sync
    }

    ; Ends the drag: stop the poll, release capture, clear the flag.
    _OvEndDrag()
    {
        if this._ovFnDragTick
            SetTimer(this._ovFnDragTick, 0)
        if this._ovDragging
            DllCall("ReleaseCapture")
        this._ovDragging := false
    }

    ; Visibility policy — return true to show this frame, false to hide.
    ; Default: always show. Override per overlay (e.g. foreground/gate checks).
    ShouldShow(ctx) => true

    ; Returns the screen rectangle as Map("x","y","w","h"), or 0 to hide.
    ; Must be overridden by drawing subclasses.
    Layout(ctx) => 0

    ; Draws the overlay content onto the back-buffer (memDC). rect is the Map
    ; returned by Layout(). Must be overridden by drawing subclasses.
    Draw(ctx, rect)
    {
    }

    ; Clears the back-buffer to the transparent colour key (010101) so the
    ; previous frame's pixels don't bleed through. Brush is cached once.
    _ClearBackBuffer(w, h)
    {
        if !this._bgBrush
            this._bgBrush := DllCall("CreateSolidBrush", "UInt", 0x010101, "Ptr")
        this._FillRectBrush(0, 0, w, h, this._bgBrush)
    }

    ; FillRect helper that takes a ready HBRUSH (used by _ClearBackBuffer).
    _FillRectBrush(x, y, w, h, hBrush)
    {
        if (w <= 0 || h <= 0)
            return
        r := this._rectBuf
        NumPut("Int", x, r, 0), NumPut("Int", y, r, 4)
        NumPut("Int", x + w, r, 8), NumPut("Int", y + h, r, 12)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", r, "Ptr", hBrush)
    }

    ; Sets overlay opacity (0-255). Applied on the next _EnsureShown styling pass.
    SetAlpha(alpha)
    {
        this._alpha := alpha
        if (this._styled && this.isVisible)
            WinSetTransColor("010101 " this._alpha, this.hwnd)
    }

    __Delete()
    {
        this._Cleanup()
    }

    ; Returns a cached HPEN for colorBGR/width (created once, freed in _Cleanup).
    _GetPen(colorBGR, width := 1)
    {
        key := colorBGR | (width << 24)
        if !this._penCache.Has(key)
            this._penCache[key] := DllCall("CreatePen", "Int", 0, "Int", width, "UInt", colorBGR, "Ptr")
        return this._penCache[key]
    }

    ; Returns a cached HBRUSH for colorBGR (created once, freed in _Cleanup).
    _GetBrush(colorBGR)
    {
        if !this._brushCache.Has(colorBGR)
            this._brushCache[colorBGR] := DllCall("CreateSolidBrush", "UInt", colorBGR, "Ptr")
        return this._brushCache[colorBGR]
    }

    ; Returns a cached HFONT for the given pixel height/weight/face (created once, freed in _Cleanup).
    ; Negative height = character height in pixels (GDI convention).
    _GetFont(height, weight := 400, face := "Segoe UI")
    {
        key := face "|" height "|" weight
        if !this._fontCache.Has(key)
            this._fontCache[key] := DllCall("CreateFontW", "Int", height, "Int", 0, "Int", 0, "Int", 0
                , "Int", weight, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0
                , "UInt", 5, "UInt", 0, "Str", face, "Ptr")
        return this._fontCache[key]
    }

    ; (Re)creates the back-buffer DC + bitmap sized to w x h. Called when the size changes.
    _InitBuffers(w, h)
    {
        if this.bitmap
        {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this.bitmap)
            DllCall("DeleteDC",     "Ptr", this.memDC)
        }
        scrDC       := DllCall("GetDC", "Ptr", this.hwnd, "Ptr")
        this.memDC  := DllCall("CreateCompatibleDC",     "Ptr", scrDC, "Ptr")
        this.bitmap := DllCall("CreateCompatibleBitmap", "Ptr", scrDC, "Int", w, "Int", h, "Ptr")
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this.bitmap)
        DllCall("ReleaseDC", "Ptr", this.hwnd, "Ptr", scrDC)
        this.bufW := w
        this.bufH := h
    }

    ; How often to re-assert the topmost z-order while visible. Returning focus to a
    ; fullscreen game can leave the game window ABOVE the overlay in the topmost band
    ; without any event we could observe — a cheap periodic SetWindowPos heals that.
    static TOPMOST_REASSERT_MS := 2000

    ; Ensures the window is shown at x,y sized w x h, styled (transparent + click-through),
    ; and that the back-buffer matches w x h. Returns true when memDC is ready to draw.
    _EnsureShown(x, y, w, h)
    {
        ; Trust the OS, not just our flag: fullscreen/display transitions (e.g. a long
        ; alt-tab away and back) can hide the window WITHOUT our Hide() running. The
        ; stale isVisible=true would then skip Show() forever while every blit lands in
        ; an invisible window — gate says YES, render runs, nothing on screen.
        if (this.isVisible && !DllCall("IsWindowVisible", "Ptr", this.hwnd))
            this.isVisible := false

        if !this.isVisible
        {
            this.overlayGui.Show("x" x " y" y " w" w " h" h " NoActivate")
            this.isVisible := true
            this._lastX := x, this._lastY := y, this._lastW := w, this._lastH := h
            ; Re-apply the layered colour-key on EVERY show — a display-mode/DWM change
            ; while hidden can drop the layered attributes; without them the window
            ; would come back as an opaque near-black sheet (or not render at all).
            WinSetTransColor("010101 " this._alpha, this.hwnd)
            if !this._styled
            {
                WinSetExStyle("+0x20", this.hwnd)   ; WS_EX_TRANSPARENT -> click-through
                this._styled := true
            }
            this._AssertTopmost()
        }
        else if (x != this._lastX || y != this._lastY || w != this._lastW || h != this._lastH)
        {
            WinMove(x, y, w, h, this.hwnd)
            this._lastX := x, this._lastY := y, this._lastW := w, this._lastH := h
        }
        else if ((A_TickCount - this._lastTopmostTick) >= GdiOverlayBase.TOPMOST_REASSERT_MS)
        {
            ; Periodic heal while visible: keeps the overlay above the game even when
            ; the game got promoted within the topmost band (no hide/show transition).
            this._AssertTopmost()
        }
        if (this.bufW != w || this.bufH != h)
            this._InitBuffers(w, h)
        return this.memDC ? true : false
    }

    ; Re-asserts HWND_TOPMOST without moving, resizing or activating the window.
    ; Registration order in OverlayManager is preserved as the relative z-order,
    ; because every overlay re-asserts in draw order within the same tick window.
    _AssertTopmost()
    {
        ; SetWindowPos(hwnd, HWND_TOPMOST=-1, 0,0,0,0, SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE)
        DllCall("SetWindowPos", "Ptr", this.hwnd, "Ptr", -1
            , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
        this._lastTopmostTick := A_TickCount
    }

    ; Copies the back-buffer to the window's screen DC (SRCCOPY).
    _Blit(w, h)
    {
        scrDC := DllCall("GetDC", "Ptr", this.hwnd, "Ptr")
        DllCall("BitBlt", "Ptr", scrDC, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", this.memDC, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("ReleaseDC", "Ptr", this.hwnd, "Ptr", scrDC)
    }

    ; Hides the window (no blit happens while hidden).
    Hide()
    {
        if this.isVisible
        {
            this.overlayGui.Hide()
            this.isVisible := false
        }
    }

    ; Fills a rectangle on the back-buffer with colorBGR.
    _FillRect(x, y, w, h, colorBGR)
    {
        this._FillRectBrush(x, y, w, h, this._GetBrush(colorBGR))
    }

    ; Draws a rectangular outline (no fill) on the back-buffer with colorBGR/penWidth.
    _DrawRectOutline(x, y, w, h, colorBGR, penWidth := 1)
    {
        pen := this._GetPen(colorBGR, penWidth)
        op := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        ob := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this._nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memDC, "Int", x, "Int", y, "Int", x + w, "Int", y + h)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", op)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", ob)
    }

    ; Draws text at sx,sy with the given colour (transparent background). The caller must have
    ; selected the desired font onto memDC beforehand.
    _DrawText(sx, sy, text, colorBGR)
    {
        DllCall("SetBkMode",    "Ptr", this.memDC, "Int", 1)   ; TRANSPARENT
        DllCall("SetTextColor", "Ptr", this.memDC, "UInt", colorBGR)
        DllCall("TextOutW", "Ptr", this.memDC, "Int", sx, "Int", sy, "Str", text, "Int", StrLen(text))
    }

    ; Blits a cached overlay icon (see OverlayImage.ahk) onto the back-buffer, scaled to
    ; w x h at x,y (source-over alpha). Returns true when the icon was drawn, false when
    ; GDI+/the asset is unavailable so the caller can fall back to a text label.
    _DrawIcon(key, x, y, w, h)
    {
        return DrawOverlayIcon(this.memDC, key, x, y, w, h)
    }

    ; Measures text extent (px) for a font handle without needing the back-buffer.
    ; Returns Map("w", cx, "h", cy).
    _MeasureText(font, text)
    {
        scrDC := DllCall("GetDC", "Ptr", 0, "Ptr")
        oldFont := DllCall("SelectObject", "Ptr", scrDC, "Ptr", font, "Ptr")
        sz := this._textSizeBuf
        DllCall("GetTextExtentPoint32W", "Ptr", scrDC, "Str", text, "Int", StrLen(text), "Ptr", sz)
        DllCall("SelectObject", "Ptr", scrDC, "Ptr", oldFont)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", scrDC)
        return Map("w", NumGet(sz, 0, "Int"), "h", NumGet(sz, 4, "Int"))
    }

    ; Frees all cached GDI objects and the back-buffer. Called from __Delete.
    _Cleanup()
    {
        for _, pen in this._penCache
            DllCall("DeleteObject", "Ptr", pen)
        for _, brush in this._brushCache
            DllCall("DeleteObject", "Ptr", brush)
        for _, font in this._fontCache
            DllCall("DeleteObject", "Ptr", font)
        if this._bgBrush
            DllCall("DeleteObject", "Ptr", this._bgBrush)
        if this.bitmap
        {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this.bitmap)
            DllCall("DeleteDC",     "Ptr", this.memDC)
        }
    }
}
