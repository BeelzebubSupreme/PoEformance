; OverlayImage.ahk
; Tiny persistent GDI+ image layer for the GDI overlays. GdiOverlayBase / RadarOverlay
; draw with plain GDI (pens / brushes / fonts) and have NO image blit — this module adds
; just enough GDI+ to load a handful of small PNG icons once at startup and blit them onto
; an overlay's back-buffer (memDC) per frame. Used by the value-aware loot radar to paint
; the corresponding currency orb (Exalted / Divine) instead of a "1ex / 1div" text label.
;
; Everything degrades gracefully: if GDI+ fails to start or an icon file is missing, the
; draw helpers become no-ops (return false) and callers fall back to a text label. The
; radar hot path stays cheap — one GDI+ Graphics is created per flush (not per icon), and
; nothing happens at all while g_oiReady is false.
;
; Globals are seeded in LoadOverlayIcons() (NOT via top-level initializers — see the AHK v2
; module-init gotcha in CLAUDE.md). Included by InGameStateMonitor.ahk before the overlays.

; ── State globals (seeded in LoadOverlayIcons) ─────────────────────────────────────
global g_oiToken   := 0       ; GDI+ startup token (0 = not started)
global g_oiBitmaps := Map()   ; icon key -> GpBitmap*
global g_oiReady   := false   ; true once GDI+ is up and at least one icon loaded

; Starts GDI+ and loads the shipped currency icons from img\currency\. Safe to call
; once at startup; on any failure g_oiReady stays false and the draw helpers no-op.
LoadOverlayIcons()
{
    global g_oiToken, g_oiBitmaps, g_oiReady
    g_oiToken   := 0
    g_oiBitmaps := Map()
    g_oiReady   := false

    ; GdiplusStartupInput: UINT version=1, ptr debugCallback, BOOL suppressBgThread,
    ; BOOL suppressExternalCodecs  (24 bytes, 8-byte aligned on x64).
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    tok := 0
    try {
        if (DllCall("gdiplus\GdiplusStartup", "Ptr*", &tok, "Ptr", si, "Ptr", 0) != 0 || !tok)
            return
    } catch as ex {
        LogError("LoadOverlayIcons", ex)
        return
    }
    g_oiToken := tok

    base := A_ScriptDir "\img\currency\"
    _OiLoadIcon("exalted", base "exalted.png")
    _OiLoadIcon("divine",  base "divine.png")

    g_oiReady := (g_oiBitmaps.Count > 0)
}

; Loads one PNG into a GpBitmap and caches it under key. Missing/garbled files are skipped.
_OiLoadIcon(key, path)
{
    global g_oiBitmaps
    if !FileExist(path)
        return
    pBmp := 0
    try {
        if (DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBmp) = 0 && pBmp)
            g_oiBitmaps[key] := pBmp
    }
}

; True when an icon with this key is loaded and GDI+ is ready (so callers can decide
; between an image label and the text fallback up front).
OverlayIconReady(key)
{
    global g_oiReady, g_oiBitmaps
    return g_oiReady && g_oiBitmaps.Has(key)
}

; Blits one cached icon onto an arbitrary GDI HDC, scaled to w x h at x,y (source-over
; alpha). Creates and frees its own GDI+ Graphics. Returns true on success. For many
; icons per frame prefer DrawOverlayIconsBatch (one Graphics for the whole batch).
DrawOverlayIcon(hdc, key, x, y, w, h)
{
    global g_oiReady, g_oiBitmaps
    if (!g_oiReady || !hdc || !g_oiBitmaps.Has(key))
        return false
    g := 0
    if (DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", &g) != 0 || !g)
        return false
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", g, "Int", 7)   ; HighQualityBicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode",   "Ptr", g, "Int", 2)   ; HighQuality (half-pixel)
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", g, "Ptr", g_oiBitmaps[key]
        , "Int", x, "Int", y, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    return true
}

; Blits a batch of icons onto one HDC with a single shared GDI+ Graphics (cheap for the
; radar flush). batch = Array of [key, x, y, w, h]. No-op when GDI+ isn't ready.
DrawOverlayIconsBatch(hdc, batch)
{
    global g_oiReady, g_oiBitmaps
    if (!g_oiReady || !hdc || !(IsObject(batch) && batch.Length > 0))
        return
    g := 0
    if (DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", &g) != 0 || !g)
        return
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", g, "Int", 7)
    DllCall("gdiplus\GdipSetPixelOffsetMode",   "Ptr", g, "Int", 2)
    for it in batch
    {
        if !(IsObject(it) && it.Length >= 5 && g_oiBitmaps.Has(it[1]))
            continue
        DllCall("gdiplus\GdipDrawImageRectI", "Ptr", g, "Ptr", g_oiBitmaps[it[1]]
            , "Int", it[2], "Int", it[3], "Int", it[4], "Int", it[5])
    }
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
}

; Frees the cached bitmaps and shuts GDI+ down. Wired to OnExit by the main script.
StopOverlayIcons()
{
    global g_oiToken, g_oiBitmaps, g_oiReady
    for _, b in g_oiBitmaps
        try DllCall("gdiplus\GdipDisposeImage", "Ptr", b)
    g_oiBitmaps := Map()
    g_oiReady := false
    if g_oiToken
        try DllCall("gdiplus\GdiplusShutdown", "Ptr", g_oiToken)
    g_oiToken := 0
}
