; RitualValueBadges.ahk
; Persistent value badges on Ritual ("Favours") reward cells. The reward cells carry the
; item entity at +0x4F8 (UiElementBase.ItemPtr — confirmed in-game), exactly like inventory
; slots, but the cursor hit-test can't reach them (it dead-ends on the full-screen
; notification layer) so price-on-hover never fires there. This enumerates ALL reward cells
; while the Favours window is open and draws a currency-orb value badge on each valuable one,
; so every reward's worth is visible at a glance.
;
; Anchor: the Favours window itself has no StringId, but two of its child buttons do and are
; unique to it — "tribute_button" / "layby_pay_button". We find either, take its PARENT (the
; window), then BFS that subtree for +0x4F8 item cells. Reuses the value layer (_LrvPriceInner)
; and the orb-badge rendering (OverlayImage via GdiOverlayBase). Architecture mirrors
; UiHoverPrice: a throttled per-tick driver (TryRitualValueBadges, from UpdateRadarFast) fills
; the g_rvbBadges cache; the registered RitualValueBadgeOverlay draws them. Self-persists
; [RitualValueBadges]. Default OFF. Included BEFORE OverlayManager (which registers it).

; ── Config + state ─────────────────────────────────────────────────────────────

; Seeds all RitualValueBadges globals (defaults first), then overlays the persisted INI
; section. Called once at startup by the main script (AHK v2 init gotcha).
LoadRitualValueBadges()
{
    global g_rvbEnabled := false        ; master switch
    global g_rvbMinEx := 0.0            ; only badge cells worth >= this (ex); 0 = any priced
    global g_rvbConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_rvbBadges := []            ; [ Map(sx,sy,sw,sh,parts,valueEx) ] cells to badge
    global g_rvbWinPtr := 0             ; cached Favours window element ptr
    global g_rvbWinTick := 0            ; last window (re)find stamp
    global g_rvbLastTick := 0           ; driver throttle stamp
    global g_rvbPriceCache := Map()     ; itemPtr -> Map(valueEx, parts)

    f := g_rvbConfigFile
    try {
        g_rvbEnabled := (IniRead(f, "RitualValueBadges", "enabled", g_rvbEnabled ? "1" : "0") = "1")
        g_rvbMinEx   := _LrvNum(IniRead(f, "RitualValueBadges", "minEx", g_rvbMinEx))
    } catch as ex {
        LogError("LoadRitualValueBadges", ex)
    }
    g_rvbMinEx := Max(0.0, g_rvbMinEx + 0.0)
}

; Persists the RitualValueBadges settings to [RitualValueBadges].
SaveRitualValueBadges()
{
    global g_rvbEnabled, g_rvbMinEx, g_rvbConfigFile
    f := g_rvbConfigFile
    try {
        IniWrite(g_rvbEnabled ? "1" : "0", f, "RitualValueBadges", "enabled")
        IniWrite(g_rvbMinEx, f, "RitualValueBadges", "minEx")
    } catch as ex {
        LogError("SaveRitualValueBadges", ex)
    }
}

; Applies one setting from the UI/bridge; clears the live cache when disabled. No return.
_RvbApplySetting(key, val)
{
    global g_rvbEnabled, g_rvbMinEx, g_rvbBadges, g_rvbWinPtr, g_rvbPriceCache
    switch key
    {
        case "enabled":
            g_rvbEnabled := _LrvTruthy(val)
            if !g_rvbEnabled
            {
                g_rvbBadges := [], g_rvbWinPtr := 0, g_rvbPriceCache := Map()
            }
        case "minEx":
            g_rvbMinEx := Max(0.0, _LrvNum(val))
    }
}

; Builds the header JSON object (settings) for the WebView push. Caller prepends the key.
BuildRitualValueBadgesHeaderJson()
{
    global g_rvbEnabled, g_rvbMinEx
    return '{"enabled":' (g_rvbEnabled ? "true" : "false") ',"minEx":' (g_rvbMinEx + 0.0) '}'
}

; ── Per-tick driver ────────────────────────────────────────────────────────────

; Finds the Favours window element via its unique child buttons (tribute_button /
; layby_pay_button) and returns the button's PARENT (the window), or 0. Lean BFS reading
; only StringId + children, depth/-node capped, short-circuits on match (the window sits at
; depth ~1, the buttons at ~2, so this resolves early). Params: reader, root (GameUI root).
_RvbFindRitualWindow(reader, root)
{
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    parOff := PoE2Offsets.UiElementBase["ParentPtr"]
    queue := [{p: root, d: 0}], visited := Map(), seen := 0
    deadline := A_TickCount + 1500
    while (queue.Length > 0 && seen < 5000)
    {
        if (A_TickCount > deadline)
            break
        it := queue.RemoveAt(1)
        ptr := it.p, d := it.d
        if (visited.Has(ptr))
            continue
        visited[ptr] := true
        seen += 1
        sid := ""
        try sid := reader.ReadStdWStringAt(ptr + sidOff)
        if (sid = "tribute_button" || sid = "layby_pay_button")
        {
            par := 0
            try par := reader.Mem.ReadPtr(ptr + parOff)
            if (par && reader.IsProbablyValidPointer(par))
                return par
        }
        if (d >= 6)
            continue
        g := _UiHitGeom(reader, ptr)
        if !IsObject(g)
            continue
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
                        queue.Push({p: cp, d: d + 1})
                }
            }
        }
    }
    return 0
}

; Prices an item entity (unit price × stack), cached by itemPtr (a 0-result is cached too,
; but re-tried so a unique can price later once its background trade query lands). Returns
; Map("valueEx","parts"). Params: reader, itemPtr.
_RvbPrice(reader, itemPtr)
{
    global g_rvbPriceCache
    if (g_rvbPriceCache.Has(itemPtr) && g_rvbPriceCache[itemPtr]["valueEx"] > 0)
        return g_rvbPriceCache[itemPtr]

    path := ""
    det := 0
    try det := reader.Mem.ReadPtr(itemPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
    if (det && reader.IsProbablyValidPointer(det))
        try path := reader.ReadStdWStringAt(det + PoE2Offsets.EntityDetails["Path"])
    if (SubStr(path, 1, 14) != "Metadata/Items")
        return Map("valueEx", 0.0, "parts", 0)

    rarId := -1
    try rarId := reader.ReadItemRarity(itemPtr)
    stack := _UhpStackCount(reader, itemPtr)
    dds := "", renderArt := "", unit := 0.0, label := ""
    if !_LrvPriceInner(itemPtr, path, rarId, &dds, &renderArt, &unit, &label)
    {
        r := Map("valueEx", 0.0, "parts", 0)
        g_rvbPriceCache[itemPtr] := r
        return r
    }
    total := unit * (stack > 0 ? stack : 1)
    r := Map("valueEx", total, "parts", LrvValueParts(total))
    g_rvbPriceCache[itemPtr] := r
    return r
}

; Per-tick entry (from UpdateRadarFast, after TryUiHoverPrice). When the Favours window is
; open and the feature is enabled, enumerates its reward cells (+0x4F8), prices each, and
; fills g_rvbBadges for the overlay. Throttled (~4.5 Hz) and gated on enabled + panel-open +
; game-foreground so it costs nothing while mapping. Param: radarSnap (current snapshot Map).
TryRitualValueBadges(radarSnap)
{
    global g_rvbEnabled, g_rvbBadges, g_rvbWinPtr, g_rvbWinTick, g_rvbLastTick, g_rvbMinEx
    global g_rvbPriceCache, g_reader
    if !(IsSet(g_rvbEnabled) && g_rvbEnabled)
        return
    if ((A_TickCount - g_rvbLastTick) < 220)
        return
    g_rvbLastTick := A_TickCount

    if !_UhpPanelOpen(radarSnap)        ; reuse the cheap anyPanelOpen check
    {
        g_rvbBadges := [], g_rvbWinPtr := 0, g_rvbPriceCache := Map()
        return
    }
    if !_UhpForeground()
    {
        g_rvbBadges := []
        return
    }
    reader := g_reader
    if !(IsObject(reader) && IsObject(reader.Mem) && reader.Mem.Handle)
        return
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
    {
        g_rvbBadges := [], g_rvbWinPtr := 0
        return
    }

    ; (Re)find the Favours window: reuse the cached ptr, re-find at most ~1/s or when stale.
    win := g_rvbWinPtr
    if (!win || !reader.IsProbablyValidPointer(win) || (A_TickCount - g_rvbWinTick) > 1000)
    {
        win := _RvbFindRitualWindow(reader, root)
        g_rvbWinPtr := win, g_rvbWinTick := A_TickCount
    }
    if !(win && reader.IsProbablyValidPointer(win) && UiTree_HierarchicallyVisible(reader, win, root))
    {
        g_rvbBadges := [], g_rvbWinPtr := 0, g_rvbPriceCache := Map()
        return
    }

    gameHwnd := ResolvePoEWindow()
    sc := gameHwnd ? UiTree_ScaleCtx(reader, gameHwnd) : 0
    if !IsObject(sc)
    {
        g_rvbBadges := []
        return
    }

    ; BFS the window subtree for +0x4F8 item cells; price + collect the valuable ones.
    badges := []
    itemOff := PoE2Offsets.UiElementBase["ItemPtr"]
    queue := [win], visited := Map(), nodes := 0
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

        ip := 0
        try ip := reader.Mem.ReadPtr(ptr + itemOff)
        if (ip && reader.IsProbablyValidPointer(ip))
        {
            pr := _RvbPrice(reader, ip)
            if (IsObject(pr) && pr["valueEx"] > 0 && pr["valueEx"] >= g_rvbMinEx && IsObject(pr["parts"]))
            {
                r := UiTree_ScreenRectOf(reader, ptr, sc, g["sizeW"], g["sizeH"])
                if IsObject(r)
                    badges.Push(Map(
                        "sx", r["x"], "sy", r["y"], "sw", r["w"], "sh", r["h"],
                        "parts", pr["parts"], "valueEx", pr["valueEx"]))
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
    g_rvbBadges := badges
}

; ── Overlay ──────────────────────────────────────────────────────────────────

; Draws a currency-orb + amount badge at the top-right of every valuable Ritual reward cell
; (from the g_rvbBadges cache). One overlay window spanning the badges' bounding box; each
; badge is painted at its position relative to that box. Registered with the OverlayManager.
class RitualValueBadgeOverlay extends GdiOverlayBase
{
    __New()
    {
        super.__New(255)
        this.Name  := "ritualvalue"
        this._draw := []
        this._ox := 0, this._oy := 0
    }

    ShouldShow(ctx)
    {
        global g_rvbEnabled, g_rvbBadges
        if !(IsSet(g_rvbEnabled) && g_rvbEnabled)
            return false
        if !ctx.gameActive
            return false
        return (IsSet(g_rvbBadges) && IsObject(g_rvbBadges) && g_rvbBadges.Length > 0)
    }

    ; Computes each badge's screen rect (top-right of its cell) and the covering bounding box.
    Layout(ctx)
    {
        global g_rvbBadges
        if !(IsObject(g_rvbBadges) && g_rvbBadges.Length > 0)
            return 0
        this._draw := []
        minX := 0x7FFFFFFF, minY := 0x7FFFFFFF, maxX := -0x7FFFFFFF, maxY := -0x7FFFFFFF
        for _, b in g_rvbBadges
        {
            parts := b["parts"]
            if !(IsObject(parts) && parts.Has("num"))
                continue
            fontH  := -Max(12, Min(20, Round(b["sh"] * 0.14)))
            font   := this._GetFont(fontH, 700)
            numStr := parts["num"]
            numW   := this._MeasureText(font, numStr)["w"]
            iconSz := Round(-fontH * 1.1)
            gap := 3, padX := 4, padY := 2
            bw := padX * 2 + iconSz + gap + numW
            bh := padY * 2 + Max(iconSz, Round(-fontH * 1.2))
            bx := Round(b["sx"] + b["sw"] - bw)
            if (bx < Round(b["sx"]))
                bx := Round(b["sx"])
            by := Round(b["sy"])
            this._draw.Push(Map("x", bx, "y", by, "w", bw, "h", bh, "parts", parts
                , "num", numStr, "fontH", fontH, "iconSz", iconSz, "gap", gap, "padX", padX))
            minX := Min(minX, bx), minY := Min(minY, by)
            maxX := Max(maxX, bx + bw), maxY := Max(maxY, by + bh)
        }
        if (this._draw.Length = 0)
            return 0
        this._ox := minX, this._oy := minY
        return Map("x", minX, "y", minY, "w", maxX - minX, "h", maxY - minY)
    }

    Draw(ctx, rect)
    {
        gold := 0x5AA8C8
        for _, d in this._draw
        {
            lx := d["x"] - this._ox, ly := d["y"] - this._oy
            this._FillRect(lx, ly, d["w"], d["h"], 0x101010)
            this._DrawRectOutline(lx, ly, d["w"], d["h"], gold, 1)

            iconY := ly + (d["h"] - d["iconSz"]) // 2
            drew := this._DrawIcon(d["parts"]["icon"], lx + d["padX"], iconY, d["iconSz"], d["iconSz"])
            tx := lx + d["padX"] + d["iconSz"] + d["gap"]
            ty := ly + (d["h"] - (-d["fontH"])) // 2 - 1
            font := this._GetFont(d["fontH"], 700)
            old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
            unitTag := drew ? "" : (d["parts"]["icon"] = "divine" ? "d" : "e")
            this._DrawText(tx, ty, d["num"] unitTag, gold)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
        }
    }
}
