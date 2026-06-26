; UiHoverPrice.ahk
; Price-on-hover for inventory / stash items. The world-entity hover chains (HoverTracker /
; MouseOver) only resolve AreaInstance entities — they do NOT see UI items. This is the
; UI/inventory/stash analog: descend the UI tree to the hovered item-slot UiElement
; (UiTree_HitTest), read the item ENTITY pointer it holds at +0x4F8
; (UiElementBase.ItemPtr — confirmed in-game 2026-06-25), then reuse the existing value
; layer (_LrvPriceInner: poe.ninja + trade-API fallback) to price it and paint the value
; (currency orb + amount, via OverlayImage) as a small badge on the slot.
;
; RE help: coussiraty/CoreExile2 (GameHelper/Sdk/InventoryAdapters.cs, ItemPointerOffset
; = 0x4F8). Their Self/Children/Flags UiElement offsets match ours exactly, and the +0x4F8
; item pointer verified live (Rare gloves resolved correctly).
;
; Architecture mirrors LootRadarValue + LootValueOverlay: a self-throttled per-tick driver
; (TryUiHoverPrice, called from UpdateRadarFast) resolves + prices the hovered item into the
; runtime cache g_uhpHover; the registered UiHoverPriceOverlay renders it. Runs only while a
; UI panel is open and the game is focused. Self-persists [UiHoverPrice]. Default OFF.
; Included by InGameStateMonitor.ahk (the overlay subclass BEFORE OverlayManager).

; ── Config + state ─────────────────────────────────────────────────────────────

; Seeds all UiHoverPrice globals (defaults first), then overlays the persisted
; [UiHoverPrice] INI section. Called once at startup by the main script (init gotcha).
LoadUiHoverPrice()
{
    global g_uhpEnabled := false        ; master switch for price-on-hover
    global g_uhpMinEx := 0.0            ; only show the badge when total value >= this (ex); 0 = any priced item
    global g_uhpConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_uhpHover := 0              ; Map(ptr,valueEx,label,parts,sx,sy,sw,sh) of the hovered priced item, or 0
    global g_uhpLastPtr := 0           ; last hovered item entity ptr (re-price only on change / when still unpriced)
    global g_uhpLastPrice := 0         ; cached Map(valueEx,label,parts) for g_uhpLastPtr
    global g_uhpLastTick := 0          ; throttle stamp

    f := g_uhpConfigFile
    try {
        g_uhpEnabled := (IniRead(f, "UiHoverPrice", "enabled", g_uhpEnabled ? "1" : "0") = "1")
        g_uhpMinEx   := _LrvNum(IniRead(f, "UiHoverPrice", "minEx", g_uhpMinEx))
    } catch as ex {
        LogError("LoadUiHoverPrice", ex)
    }
    g_uhpMinEx := Max(0.0, g_uhpMinEx + 0.0)
}

; Persists the UiHoverPrice settings to [UiHoverPrice].
SaveUiHoverPrice()
{
    global g_uhpEnabled, g_uhpMinEx, g_uhpConfigFile
    f := g_uhpConfigFile
    try {
        IniWrite(g_uhpEnabled ? "1" : "0", f, "UiHoverPrice", "enabled")
        IniWrite(g_uhpMinEx, f, "UiHoverPrice", "minEx")
    } catch as ex {
        LogError("SaveUiHoverPrice", ex)
    }
}

; Applies one setting from the UI/bridge. Clears the live cache when disabled.
; Params: key (setting name), val (new value). No return.
_UhpApplySetting(key, val)
{
    global g_uhpEnabled, g_uhpMinEx, g_uhpHover, g_uhpLastPtr, g_uhpLastPrice
    switch key
    {
        case "enabled":
            g_uhpEnabled := _LrvTruthy(val)
            if !g_uhpEnabled
            {
                g_uhpHover := 0, g_uhpLastPtr := 0, g_uhpLastPrice := 0
            }
        case "minEx":
            g_uhpMinEx := Max(0.0, _LrvNum(val))
    }
}

; Builds the header JSON object (settings) for the WebView push. Caller prepends the key.
BuildUiHoverPriceHeaderJson()
{
    global g_uhpEnabled, g_uhpMinEx
    j := "{"
    j .= '"enabled":' (g_uhpEnabled ? "true" : "false")
    j .= ',"minEx":'  (g_uhpMinEx + 0.0)
    j .= "}"
    return j
}

; ── Per-tick driver ────────────────────────────────────────────────────────────

; True iff the snapshot reports any UI panel open (inventory / stash / etc.).
_UhpPanelOpen(snap)
{
    if !(IsObject(snap) && Type(snap) = "Map")
        return false
    pv := snap.Has("panelVisibility") ? snap["panelVisibility"] : 0
    return (pv && IsObject(pv) && pv.Has("anyPanelOpen") && pv["anyPanelOpen"]) ? true : false
}

; True iff the PoE2 window is the foreground window (cheap gate before the UI-tree walk).
_UhpForeground()
{
    hwnd := ResolvePoEWindow()
    return (hwnd && WinActive("ahk_id " hwnd)) ? true : false
}

; Per-tick entry (from UpdateRadarFast after TryLootRadarValue). Resolves the hovered
; inventory/stash item, prices it, and stores the renderable result in g_uhpHover (or 0).
; Self-throttled (~5 Hz) and gated on enabled + panel-open + game-foreground so it costs
; nothing during combat / mapping. Param: radarSnap (current radar snapshot Map).
TryUiHoverPrice(radarSnap)
{
    global g_uhpEnabled, g_uhpHover, g_uhpLastPtr, g_uhpLastPrice, g_uhpLastTick, g_uhpMinEx
    global g_reader
    if !(IsSet(g_uhpEnabled) && g_uhpEnabled)
        return
    if ((A_TickCount - g_uhpLastTick) < 180)
        return
    g_uhpLastTick := A_TickCount

    if !_UhpPanelOpen(radarSnap)
    {
        g_uhpHover := 0, g_uhpLastPtr := 0
        return
    }
    if !_UhpForeground()
    {
        g_uhpHover := 0
        return
    }
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return

    hit := _UhpResolveHoveredItem(g_reader)
    if !IsObject(hit)
    {
        g_uhpHover := 0, g_uhpLastPtr := 0
        return
    }

    ; Re-price only when the hovered item changed, or the cached price is still 0/unpriced
    ; (a unique may price later once its background trade query lands in the cache).
    itemPtr := hit["ptr"]
    needPrice := (itemPtr != g_uhpLastPtr) || !(IsObject(g_uhpLastPrice) && g_uhpLastPrice["valueEx"] > 0)
    if (needPrice)
    {
        g_uhpLastPtr := itemPtr
        g_uhpLastPrice := _UhpPriceItem(itemPtr, hit["path"], hit["rarity"], hit["stack"])
    }
    pr := g_uhpLastPrice

    ; Only surface PRICED items at/above the threshold — unpriceable items (most rares /
    ; magics: poe.ninja has no data) show no badge, matching the rest of the value layer.
    if !(IsObject(pr) && pr["valueEx"] > 0 && pr["valueEx"] >= g_uhpMinEx)
    {
        g_uhpHover := 0
        return
    }
    g_uhpHover := Map(
        "ptr", itemPtr, "valueEx", pr["valueEx"], "label", pr["label"], "parts", pr["parts"],
        "sx", hit["sx"], "sy", hit["sy"], "sw", hit["sw"], "sh", hit["sh"])
}

; Prices a resolved inventory/stash item entity (unit price × stack). Returns
; Map("valueEx","label","parts") — valueEx 0 when not priceable. Params: itemPtr, path,
; rarityId, stack count.
_UhpPriceItem(itemPtr, path, rarityId, stack)
{
    dds := "", renderArt := "", unit := 0.0, label := ""
    if !_LrvPriceInner(itemPtr, path, rarityId, &dds, &renderArt, &unit, &label)
        return Map("valueEx", 0.0, "label", "", "parts", 0)
    total := unit * (stack > 0 ? stack : 1)
    return Map("valueEx", total, "label", label, "parts", LrvValueParts(total))
}

; Resolves the inventory/stash item currently under the cursor via deterministic UI
; tree-descent + the +0x4F8 item-slot pointer. Returns Map("ptr","path","rarity","stack",
; "sx","sy","sw","sh") (the slot's screen rect) or 0 when nothing item-like is hovered.
; Param: reader (g_reader).
_UhpResolveHoveredItem(reader)
{
    root := _UiBrowser_GetGameUiPtr()
    if !(root && reader.IsProbablyValidPointer(root))
        return 0

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    if !IsObject(cr)
        return 0
    hScale := (cr["h"] > 0) ? (cr["h"] / 1600.0) : 1.0
    uiCx := (mx - cr["x"]) / hScale
    uiCy := (my - cr["y"]) / hScale

    chain := UiTree_HitTest(reader, root, uiCx, uiCy)
    if !(IsObject(chain) && chain.Length > 1)
        return 0

    ; Leaf -> root: the first element that holds a "Metadata/Items/..." pointer at +0x4F8
    ; is the item slot (the slot may be an ancestor of the deepest leaf).
    itemOff := PoE2Offsets.UiElementBase["ItemPtr"]
    idx := chain.Length
    while (idx >= 1)
    {
        slotAddr := chain[idx]
        idx -= 1
        ip := 0
        try ip := reader.Mem.ReadPtr(slotAddr + itemOff)
        if !(ip && reader.IsProbablyValidPointer(ip))
            continue
        det := 0
        try det := reader.Mem.ReadPtr(ip + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !(det && reader.IsProbablyValidPointer(det))
            continue
        p := ""
        try p := reader.ReadStdWStringAt(det + PoE2Offsets.EntityDetails["Path"])
        if (SubStr(p, 1, 14) != "Metadata/Items")
            continue

        rarityId := -1
        try rarityId := reader.ReadItemRarity(ip)
        stack := _UhpStackCount(reader, ip)

        el := UiTree_ReadElement(reader, slotAddr)
        sp := UiTree_GetScreenPos(reader, slotAddr)
        if !(IsObject(el) && IsObject(sp))
            return 0
        return Map(
            "ptr", ip, "path", p, "rarity", rarityId, "stack", stack,
            "sx", cr["x"] + sp["x"] * hScale, "sy", cr["y"] + sp["y"] * hScale,
            "sw", el["sizeW"] * hScale, "sh", el["sizeH"] * hScale)
    }
    return 0
}

; Reads an item entity's stack count via its Stack component (Count @ +0x18). Returns the
; count when > 1, else 1 (non-stackable items have no Stack component). Params: reader, itemPtr.
_UhpStackCount(reader, itemPtr)
{
    n := 1
    try {
        sp := reader.FindEntityComponentAddress(itemPtr, "Stack")
        if (sp && reader.IsProbablyValidPointer(sp))
        {
            c := reader.Mem.ReadInt(sp + PoE2Offsets.Stack["Count"])
            if (c > 1)
                n := c
        }
    }
    return n
}

; ── Overlay ──────────────────────────────────────────────────────────────────

; Renders the hovered item's value as a small currency-orb + amount badge anchored to the
; item slot's top-right corner. Reads the g_uhpHover cache (filled by TryUiHoverPrice).
; Registered with the OverlayManager. Included BEFORE OverlayManager (which registers it).
class UiHoverPriceOverlay extends GdiOverlayBase
{
    __New()
    {
        super.__New(255)
        this.Name   := "uihoverprice"
        this._fontH := -16
    }

    ShouldShow(ctx)
    {
        global g_uhpEnabled, g_uhpHover
        if !(IsSet(g_uhpEnabled) && g_uhpEnabled)
            return false
        if !ctx.gameActive
            return false
        return (IsSet(g_uhpHover) && IsObject(g_uhpHover) && g_uhpHover.Has("parts")
            && IsObject(g_uhpHover["parts"]))
    }

    Layout(ctx)
    {
        global g_uhpHover
        h := g_uhpHover
        if !(IsObject(h) && h.Has("parts") && IsObject(h["parts"]))
            return 0
        parts := h["parts"]

        ; Font scales gently with the slot height so it fits big stash & small inventory cells.
        slotH := h.Has("sh") ? h["sh"] : 64
        this._fontH := -Max(12, Min(20, Round(slotH * 0.16)))
        font := this._GetFont(this._fontH, 700)

        numStr := parts["num"]
        numW   := this._MeasureText(font, numStr)["w"]
        iconSz := Round(-this._fontH * 1.1)
        gap    := 3
        padX   := 4, padY := 2
        badgeW := padX * 2 + iconSz + gap + numW
        badgeH := padY * 2 + Max(iconSz, Round(-this._fontH * 1.2))

        this._parts := parts, this._numStr := numStr, this._iconSz := iconSz
        this._gap := gap, this._padX := padX, this._padY := padY

        ; Top-right corner of the slot (clamped to the slot's left edge for tiny cells).
        x := Round(h["sx"] + h["sw"] - badgeW)
        if (x < Round(h["sx"]))
            x := Round(h["sx"])
        y := Round(h["sy"])
        return Map("x", x, "y", y, "w", badgeW, "h", badgeH)
    }

    Draw(ctx, rect)
    {
        w := rect["w"], hh := rect["h"]
        gold := 0x5AA8C8   ; BGR for #C8A85A

        ; Dark backdrop + gold border so the value stays legible on bright item art.
        this._FillRect(0, 0, w, hh, 0x101010)
        this._DrawRectOutline(0, 0, w, hh, gold, 1)

        font := this._GetFont(this._fontH, 700)
        padX := this._padX, iconSz := this._iconSz, gap := this._gap
        iconY := (hh - iconSz) // 2
        drew := this._DrawIcon(this._parts["icon"], padX, iconY, iconSz, iconSz)
        tx := padX + iconSz + gap
        ty := (hh - (-this._fontH)) // 2 - 1

        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        ; If the orb image is unavailable, append a tiny unit tag so the value still reads.
        unitTag := drew ? "" : (this._parts["icon"] = "divine" ? "d" : "e")
        this._DrawText(tx, ty, this._numStr unitTag, gold)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}
