; StashMover.ahk
; "Dump to stash" feature: simulates Ctrl+Click on every backpack item so the
; game moves them into whatever container is currently open (stash tab, vendor
; sell window, trade window, gambling window, …). Triggered by a configurable
; hotkey AND/OR an on-screen button drawn next to the in-game inventory grid.
;
; Data sources (all already reverse-engineered elsewhere in the project):
;   - Backpack items + their grid cells  -> ReadAllPlayerInventories (id == 1).
;   - Inventory grid screen rectangle    -> UI tree element "InventoryPanel"
;     (UiTree_GetScreenPos + UnscaledSize), converted to absolute screen pixels
;     with NavClientRect, mirroring the conversion in UiBrowserHandler
;     (screenPx = clientOrigin + uiPos * clientHeight/1600).
;
; Safety / quality of life:
;   - Ignore filter: a user-built set of item base-type paths that are never
;     moved (assembled from the live inventory in the UI).
;   - Quest items are auto-skipped (they can't be stashed).
;   - Post-run verification: items that didn't actually leave the backpack are
;     flagged "failed" for a short cooldown so a repeated trigger doesn't keep
;     re-clicking an un-stashable item (e.g. stash full). If NOTHING moved, the
;     user is warned instead of silently hammering.
;   - Randomness: each click lands at a small random offset inside its cell and
;     the inter-click delay is jittered, so the timing/positions aren't static.
;
; The clicking runs as a NON-BLOCKING sequencer (one item per timer tick) so the
; radar hot path is never frozen for the ~1-3 s a full backpack takes. Ctrl is
; held down for the whole run and released on completion / abort.
;
; Included by InGameStateMonitor.ahk. Initialise every global in LoadStashMover()
; (AHK v2 module-init gotcha: top-level initialisers in #Include'd modules don't
; run because they sit after the main script's auto-execute return).

; ── Config + persistence ────────────────────────────────────────────────────

; Seeds all StashMover globals unconditionally (defaults first), then overlays
; the persisted [StashMover] section. Called once at startup by the main script.
LoadStashMover()
{
    global g_smEnabled := false               ; master switch for the whole feature
    global g_smHotkey := ""                    ; AHK hotkey string, e.g. "F4" / "^d" (empty = none)
    global g_smShowButton := true              ; draw the clickable overlay button
    global g_smPerItemDelayMs := 35            ; base pause between consecutive item clicks
    global g_smSettleDelayMs := 16             ; base pause after moving the cursor, before the click
    global g_smOffsetX := 0                    ; manual screen-px calibration (X) of the grid origin
    global g_smOffsetY := 0                    ; manual screen-px calibration (Y) of the grid origin
    global g_smSkipQuest := true               ; never try to stash quest items (they can't be)
    global g_smJitter := true                  ; randomise click position + inter-click delay
    global g_smAllowSell := true               ; allow acting when the open container is a vendor (sells!)
    ; Vendor sell filter — which item categories to actually sell. Only applied
    ; when the destination is a vendor (or unrecognised); stashing dumps everything.
    global g_smSellGear := true                 ; normal/magic/rare gear (armour, weapons, jewellery …)
    global g_smSellUniques := false            ; unique / relic items
    global g_smSellCurrency := false           ; currency (rarityId 5)
    global g_smSellMaps := false               ; maps / waystones (Metadata/Items/Maps/)
    global g_smConfigFile := _ConfigPath()

    ; Ignore filter — path -> display name. Items whose base-type path is in here
    ; are never moved. Built by the user from the live inventory in the UI.
    global g_smIgnore := Map()

    ; Detected destination context: "stash" | "vendor" | "trade" | "unknown".
    ; Drives the overlay button label, the result tooltip verb and the sell guard.
    global g_smCtx := 0                         ; cached context Map (kind/verb/button)
    global g_smCtxKind := ""                    ; cached kind string (for the header)
    global g_smCtxTick := 0                     ; A_TickCount of the last context detect
    global g_smRunVerb := "Moved"              ; verb for the current run's result tooltip
    global g_smLastBtnText := ""               ; last text written to the overlay button

    ; Runtime state (never persisted)
    global g_smGui := 0                        ; interactive overlay Gui (lazy-built)
    global g_smBtnCtrl := 0                    ; the button control inside g_smGui
    global g_smGuiShown := false
    global g_smRunning := false                ; a dump sequence is in progress
    global g_smQueue := []                     ; precomputed click points for the run
    global g_smQueueIdx := 0
    global g_smMovedCount := 0                 ; clicks issued this run (not verified moves)
    global g_smQueuedPtrs := []                ; item ptrs we attempted (for post-run verify)
    global g_smFailed := Map()                 ; itemEntityPtr -> A_TickCount when it failed to move
    global g_smFailCooldownMs := 8000          ; how long a failed item is skipped before retry
    global g_smRegisteredHotkey := ""          ; last hotkey actually bound (for clean re-register)

    f := g_smConfigFile
    try {
        g_smEnabled        := (IniRead(f, "StashMover", "enabled", g_smEnabled ? "1" : "0") = "1")
        g_smHotkey         := IniRead(f, "StashMover", "hotkey", g_smHotkey)
        g_smShowButton     := (IniRead(f, "StashMover", "showButton", g_smShowButton ? "1" : "0") = "1")
        g_smPerItemDelayMs := Integer(IniRead(f, "StashMover", "perItemDelayMs", g_smPerItemDelayMs))
        g_smSettleDelayMs  := Integer(IniRead(f, "StashMover", "settleDelayMs", g_smSettleDelayMs))
        g_smOffsetX        := Integer(IniRead(f, "StashMover", "offsetX", g_smOffsetX))
        g_smOffsetY        := Integer(IniRead(f, "StashMover", "offsetY", g_smOffsetY))
        g_smSkipQuest      := (IniRead(f, "StashMover", "skipQuest", g_smSkipQuest ? "1" : "0") = "1")
        g_smJitter         := (IniRead(f, "StashMover", "jitter", g_smJitter ? "1" : "0") = "1")
        g_smAllowSell      := (IniRead(f, "StashMover", "allowSell", g_smAllowSell ? "1" : "0") = "1")
        g_smSellGear       := (IniRead(f, "StashMover", "sellGear", g_smSellGear ? "1" : "0") = "1")
        g_smSellUniques    := (IniRead(f, "StashMover", "sellUniques", g_smSellUniques ? "1" : "0") = "1")
        g_smSellCurrency   := (IniRead(f, "StashMover", "sellCurrency", g_smSellCurrency ? "1" : "0") = "1")
        g_smSellMaps       := (IniRead(f, "StashMover", "sellMaps", g_smSellMaps ? "1" : "0") = "1")
        g_smIgnore         := _SmIgnoreDeserialize(IniRead(f, "StashMover", "ignore", ""))
    } catch as ex {
        LogError("LoadStashMover", ex)
    }
    _SmClampConfig()
}

; Persists the current StashMover settings to the [StashMover] INI section.
SaveStashMover()
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY, g_smSkipQuest, g_smJitter, g_smAllowSell
    global g_smSellGear, g_smSellUniques, g_smSellCurrency, g_smSellMaps
    global g_smIgnore, g_smConfigFile
    f := g_smConfigFile
    try {
        IniWrite(g_smEnabled ? "1" : "0", f, "StashMover", "enabled")
        IniWrite(g_smHotkey, f, "StashMover", "hotkey")
        IniWrite(g_smShowButton ? "1" : "0", f, "StashMover", "showButton")
        IniWrite(g_smPerItemDelayMs, f, "StashMover", "perItemDelayMs")
        IniWrite(g_smSettleDelayMs, f, "StashMover", "settleDelayMs")
        IniWrite(g_smOffsetX, f, "StashMover", "offsetX")
        IniWrite(g_smOffsetY, f, "StashMover", "offsetY")
        IniWrite(g_smSkipQuest ? "1" : "0", f, "StashMover", "skipQuest")
        IniWrite(g_smJitter ? "1" : "0", f, "StashMover", "jitter")
        IniWrite(g_smAllowSell ? "1" : "0", f, "StashMover", "allowSell")
        IniWrite(g_smSellGear ? "1" : "0", f, "StashMover", "sellGear")
        IniWrite(g_smSellUniques ? "1" : "0", f, "StashMover", "sellUniques")
        IniWrite(g_smSellCurrency ? "1" : "0", f, "StashMover", "sellCurrency")
        IniWrite(g_smSellMaps ? "1" : "0", f, "StashMover", "sellMaps")
        IniWrite(_SmIgnoreSerialize(g_smIgnore), f, "StashMover", "ignore")
    } catch as ex {
        LogError("SaveStashMover", ex)
    }
}

; Keeps the numeric settings inside sane bounds so a bad INI / UI value can't
; produce a multi-minute run or a zero-delay machine-gun click storm.
_SmClampConfig()
{
    global g_smPerItemDelayMs, g_smSettleDelayMs
    g_smPerItemDelayMs := Max(5, Min(500, g_smPerItemDelayMs + 0))
    g_smSettleDelayMs  := Max(0, Min(300, g_smSettleDelayMs + 0))
}

; Serialises the ignore Map(path->name) to a single INI-safe string. Entries are
; joined by RS (Chr 30); path and name inside an entry by US (Chr 31). Neither
; control char appears in metadata paths or item names.
_SmIgnoreSerialize(ignoreMap)
{
    if !(IsObject(ignoreMap) && ignoreMap is Map)
        return ""
    us := Chr(31), rs := Chr(30)
    parts := []
    for path, name in ignoreMap
        parts.Push(path us name)
    out := ""
    for i, p in parts
        out .= (i > 1 ? rs : "") p
    return out
}

; Parses the serialised ignore string back into a Map(path->name).
_SmIgnoreDeserialize(s)
{
    m := Map()
    s := s ""
    if (s = "")
        return m
    us := Chr(31), rs := Chr(30)
    for _, entry in StrSplit(s, rs)
    {
        if (entry = "")
            continue
        kv := StrSplit(entry, us)
        path := kv.Length >= 1 ? kv[1] : ""
        name := kv.Length >= 2 ? kv[2] : ""
        if (path != "")
            m[path] := (name != "" ? name : path)
    }
    return m
}

; Applies a single setting from the UI/bridge. Param: key, val (string/bool).
; Returns true when the value changed something that needs a hotkey re-register.
_SmApplySetting(key, val)
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY, g_smSkipQuest, g_smJitter, g_smAllowSell
    global g_smSellGear, g_smSellUniques, g_smSellCurrency, g_smSellMaps
    needRebind := false
    switch key
    {
        case "sellGear":
            g_smSellGear := _SmTruthy(val)
        case "sellUniques":
            g_smSellUniques := _SmTruthy(val)
        case "sellCurrency":
            g_smSellCurrency := _SmTruthy(val)
        case "sellMaps":
            g_smSellMaps := _SmTruthy(val)
        case "enabled":
            g_smEnabled := _SmTruthy(val)
            needRebind := true
        case "hotkey":
            g_smHotkey := Trim(val "")
            needRebind := true
        case "showButton":
            g_smShowButton := _SmTruthy(val)
        case "skipQuest":
            g_smSkipQuest := _SmTruthy(val)
        case "jitter":
            g_smJitter := _SmTruthy(val)
        case "allowSell":
            g_smAllowSell := _SmTruthy(val)
        case "perItemDelayMs":
            g_smPerItemDelayMs := Integer(val)
        case "settleDelayMs":
            g_smSettleDelayMs := Integer(val)
        case "offsetX":
            g_smOffsetX := Integer(val)
        case "offsetY":
            g_smOffsetY := Integer(val)
    }
    _SmClampConfig()
    return needRebind
}

; Loose boolean coercion shared by the bridge (accepts true/1/"1"/"true").
_SmTruthy(v)
{
    if (v = true || v = 1)
        return true
    s := StrLower(Trim(v ""))
    return (s = "1" || s = "true" || s = "yes" || s = "on")
}

; Builds the "stashMover" JSON object embedded in the WebView header push,
; including the ignore list so the chips survive a UI refresh.
BuildStashMoverHeaderJson()
{
    global g_smEnabled, g_smHotkey, g_smShowButton, g_smPerItemDelayMs
    global g_smSettleDelayMs, g_smOffsetX, g_smOffsetY, g_smSkipQuest, g_smJitter
    global g_smAllowSell, g_smIgnore, g_smCtxKind
    global g_smSellGear, g_smSellUniques, g_smSellCurrency, g_smSellMaps
    j := "{"
    j .= '"enabled":'        (g_smEnabled ? "true" : "false")
    j .= ',"hotkey":'        _JsStr(g_smHotkey)
    j .= ',"showButton":'    (g_smShowButton ? "true" : "false")
    j .= ',"skipQuest":'     (g_smSkipQuest ? "true" : "false")
    j .= ',"jitter":'        (g_smJitter ? "true" : "false")
    j .= ',"allowSell":'     (g_smAllowSell ? "true" : "false")
    j .= ',"sellGear":'      (g_smSellGear ? "true" : "false")
    j .= ',"sellUniques":'   (g_smSellUniques ? "true" : "false")
    j .= ',"sellCurrency":'  (g_smSellCurrency ? "true" : "false")
    j .= ',"sellMaps":'      (g_smSellMaps ? "true" : "false")
    j .= ',"perItemDelayMs":' (g_smPerItemDelayMs + 0)
    j .= ',"settleDelayMs":'  (g_smSettleDelayMs + 0)
    j .= ',"offsetX":'        (g_smOffsetX + 0)
    j .= ',"offsetY":'        (g_smOffsetY + 0)
    j .= ',"context":'        _JsStr(g_smCtxKind)
    j .= ',"ignore":' _SmIgnoreJsonArray()
    j .= "}"
    return j
}

; Builds a JSON array of the ignore entries: [{"path":..,"name":..}, …].
_SmIgnoreJsonArray()
{
    global g_smIgnore
    out := "["
    first := true
    for path, name in g_smIgnore
    {
        out .= (first ? "" : ",") '{"path":' _JsStr(path) ',"name":' _JsStr(name) "}"
        first := false
    }
    return out "]"
}

; ── Ignore filter (built from the live inventory) ─────────────────────────────

; Adds or removes one base-type path from the ignore set, persists, and refreshes
; both the header (chips) and the inventory list (pill states).
; Params: path, name (display), on (truthy = add, falsy = remove).
SetStashIgnore(path, name := "", on := true)
{
    global g_smIgnore
    path := Trim(path "")
    if (path = "")
        return
    if _SmTruthy(on)
        g_smIgnore[path] := (Trim(name "") != "" ? Trim(name "") : path)
    else if g_smIgnore.Has(path)
        g_smIgnore.Delete(path)
    SaveStashMover()
    SetTimer(PushHeaderToWebView, -50)
    SetTimer(_SmPushInventory, -50)
}

; Clears the whole ignore set.
ClearStashIgnore()
{
    global g_smIgnore
    g_smIgnore := Map()
    SaveStashMover()
    SetTimer(PushHeaderToWebView, -50)
    SetTimer(_SmPushInventory, -50)
}

; Reads the live backpack and pushes a deduped (by base-type path) item list to
; the WebView (JS updateStashInventory) so the user can pick ignore entries.
; Each row: {path, name, rarity, count, ignored}.
_SmPushInventory()
{
    global g_smIgnore
    sdPtr := _SmResolveServerData()
    bp := sdPtr ? _SmReadBackpack(sdPtr) : 0
    rows := Map()   ; path -> Map(name,rarity,count)
    order := []
    if IsObject(bp)
    {
        seenPtr := Map()
        for _, it in bp["items"]
        {
            if !(it && IsObject(it) && it.Has("details"))
                continue
            ptr := it.Has("itemEntityPtr") ? it["itemEntityPtr"] : 0
            if (ptr && seenPtr.Has(ptr))   ; dedupe the per-cell repeats of a multi-cell item
                continue
            if ptr
                seenPtr[ptr] := true
            d := it["details"]
            path := d.Has("metadataPath") ? d["metadataPath"] : ""
            if (path = "")
                continue
            name := (d.Has("baseType") && d["baseType"] != "") ? d["baseType"]
                  : (d.Has("displayName") ? d["displayName"] : path)
            rarity := d.Has("rarity") ? d["rarity"] : ""
            if rows.Has(path)
                rows[path]["count"] += 1
            else
            {
                rows[path] := Map("name", name, "rarity", rarity, "count", 1)
                order.Push(path)
            }
        }
    }
    arr := "["
    first := true
    for _, path in order
    {
        r := rows[path]
        arr .= (first ? "" : ",") "{"
            . '"path":' _JsStr(path)
            . ',"name":' _JsStr(r["name"])
            . ',"rarity":' _JsStr(r["rarity"])
            . ',"count":' (r["count"] + 0)
            . ',"ignored":' (g_smIgnore.Has(path) ? "true" : "false")
            . "}"
        first := false
    }
    arr .= "]"
    payload := '{"items":' arr ',"connected":' (IsObject(bp) ? "true" : "false") "}"
    try WebViewExec("updateStashInventory(" payload ")")
}

; ── Hotkey ───────────────────────────────────────────────────────────────────

; (Re)binds the configurable dump hotkey. Like RegisterCombatHotkey: turns the
; previous binding off, then binds the new one (gated to PoE2 being the active
; window via HotIf so the key passes through normally everywhere else).
RegisterStashMoverHotkey()
{
    global g_smEnabled, g_smHotkey, g_smRegisteredHotkey
    if (g_smRegisteredHotkey != "")
    {
        try {
            HotIf(_SmPoeActive)
            Hotkey(g_smRegisteredHotkey, , "Off")
            HotIf()
        }
        g_smRegisteredHotkey := ""
    }
    hk := Trim(g_smHotkey)
    if (!g_smEnabled || hk = "")
        return
    try {
        HotIf(_SmPoeActive)
        Hotkey(hk, _OnStashMoveHotkey, "On")
        HotIf()
        g_smRegisteredHotkey := hk
    } catch as ex {
        LogError("RegisterStashMoverHotkey(" hk ")", ex)
        try HotIf()
    }
}

; HotIf context: true only while a PoE2 window is the active foreground window.
_SmPoeActive(*)
{
    h := ResolvePoEWindow()
    return (h && WinActive("ahk_id " h)) ? true : false
}

; Hotkey handler — kicks off a dump from the hotkey path.
_OnStashMoveHotkey(*)
{
    StashMoverDump("hotkey")
}

; ── Memory / geometry resolution ─────────────────────────────────────────────

; Resolves the ServerData pointer from the cached radar snapshot (same chain
; LootPickup / WebViewBridge use). Returns the pointer, or 0 when unavailable.
_SmResolveServerData()
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
        return 0
    snap := (IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area) && area.Has("address"))
        return 0
    areaAddr := area["address"]
    if !areaAddr
        return 0
    try {
        playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        return g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
    } catch as ex {
        LogError("_SmResolveServerData", ex)
        return 0
    }
}

; Bounded breadth-first search for a descendant UiElement carrying targetId.
; Params: reader, root, targetId, maxDepth. Returns the element address, or 0.
_SmBfsFindStringId(reader, root, targetId, maxDepth := 10)
{
    if !reader.IsProbablyValidPointer(root)
        return 0
    queue := [{ptr: root, d: 0}]
    seen := Map()
    idOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    while (queue.Length > 0)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        sid := ""
        try sid := reader.ReadStdWStringAt(p + idOff, 48)
        if (sid = targetId)
            return p
        if (it.d >= maxDepth)
            continue
        hdr := reader.Mem.ReadBytes(p, 0x20)
        if !hdr
            continue
        cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        n := Min((cl - cf) // A_PtrSize, 256)
        buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
        if !buf
            continue
        Loop n
        {
            cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cp)
                queue.Push({ptr: cp, d: it.d + 1})
        }
    }
    return 0
}

; Finds the player inventory side PANEL: the RIGHTMOST visible direct child of the
; GameUi root that's a half-screen-tall side panel. Confirmed in-game (2026-06-23):
; PoE2 keeps these as direct children of the root (e.g. the inventory side =
; ~986×1600 at uiPos x≈2837; the stash side = the same at x≈0). Returns ptr or 0.
_SmFindInventoryPanel(reader, gameUi)
{
    if !reader.IsProbablyValidPointer(gameUi)
        return 0
    hdr := reader.Mem.ReadBytes(gameUi, 0x20)
    if !hdr
        return 0
    cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
        return 0
    n := Min((cl - cf) // A_PtrSize, 256)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return 0
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    sizeOff  := PoE2Offsets.UiElementBase["UnscaledSize"]
    best := 0
    bestX := -99999.0
    Loop n
    {
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(cp)
            continue
        vis := false
        try vis := ((reader.Mem.ReadUInt(cp + flagsOff) >> 11) & 1) ? true : false
        if !vis
            continue
        szb := reader.Mem.ReadBytes(cp + sizeOff, 8)
        if !szb
            continue
        w := NumGet(szb.Ptr, 0, "Float")
        h := NumGet(szb.Ptr, 4, "Float")
        if (w < 700 || w > 1200 || h < 1400)   ; a half-screen-tall side panel
            continue
        sp := UiTree_GetScreenPos(reader, cp)
        if (sp["x"] > bestX)                    ; rightmost = the player's inventory
        {
            bestX := sp["x"]
            best := cp
        }
    }
    return best
}

; Finds the 12×5 backpack GRID inside the inventory panel: the visible descendant
; with a ~12:5 (2.4) aspect ratio (square cells) and the largest area. Bounded BFS,
; prunes hidden subtrees. Returns the grid element ptr, or 0.
_SmFindGridIn(reader, panel)
{
    if !reader.IsProbablyValidPointer(panel)
        return 0
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    sizeOff  := PoE2Offsets.UiElementBase["UnscaledSize"]
    queue := [{ptr: panel, d: 0}]
    seen := Map()
    nodes := 0
    best := 0
    bestArea := 0.0
    while (queue.Length > 0 && nodes < 600)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        nodes += 1
        if (p != panel)
        {
            fl := 0
            try fl := reader.Mem.ReadUInt(p + flagsOff)
            if (((fl >> 11) & 1) = 0)
                continue
        }
        szb := reader.Mem.ReadBytes(p + sizeOff, 8)
        if szb
        {
            w := NumGet(szb.Ptr, 0, "Float")
            h := NumGet(szb.Ptr, 4, "Float")
            if (h > 0 && w > 300)
            {
                aspect := w / h
                if (aspect >= 2.0 && aspect <= 2.9)
                {
                    area := w * h
                    if (area > bestArea)
                    {
                        bestArea := area
                        best := p
                    }
                }
            }
        }
        if (it.d >= 8)
            continue
        chdr := reader.Mem.ReadBytes(p, 0x20)
        if !chdr
            continue
        cf := NumGet(chdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(chdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        cn := Min((cl - cf) // A_PtrSize, 128)
        cbuf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
        if !cbuf
            continue
        Loop cn
        {
            cp := NumGet(cbuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cp)
                queue.Push({ptr: cp, d: it.d + 1})
        }
    }
    return best
}

; Resolves the backpack GRID's ABSOLUTE screen rectangle in pixels, or 0 when the
; inventory isn't open. Finds the inventory side panel, then the 12×5 grid inside
; it. The UI→pixel conversion mirrors the (working) UI-browser highlight:
; screenPx = uiPos * (clientHeight / 1600), origin = client-area top-left; plus the
; manual offsetX/offsetY fine-tune.
_SmInventoryGridRect()
{
    global g_reader, g_smOffsetX, g_smOffsetY
    if !IsObject(g_reader)
        return 0
    gameUi := _UiBrowser_GetGameUiPtr()
    if !g_reader.IsProbablyValidPointer(gameUi)
        return 0
    panel := _SmFindInventoryPanel(g_reader, gameUi)
    if !panel
        return 0
    grid := _SmFindGridIn(g_reader, panel)
    if !grid
        return 0
    elem := UiTree_ReadElement(g_reader, grid)
    if !elem
        return 0
    sp := UiTree_GetScreenPos(g_reader, grid)
    gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    if !IsObject(cr)
        return 0
    hScale := (cr["h"] > 0) ? (cr["h"] / 1600.0) : 1.0
    x := cr["x"] + sp["x"] * hScale + g_smOffsetX
    y := cr["y"] + sp["y"] * hScale + g_smOffsetY
    w := elem["sizeW"] * hScale
    h := elem["sizeH"] * hScale
    if (w < 20 || h < 20)
        return 0
    return Map("x", x, "y", y, "w", w, "h", h)
}

; Reads the backpack inventory (id == 1) from ServerData. Returns Map with
; "items" (array of item Maps with slot coords), "cols", "rows" — or 0.
_SmReadBackpack(sdPtr)
{
    global g_reader
    if (!IsObject(g_reader) || !sdPtr)
        return 0
    invs := 0
    try invs := g_reader.ReadAllPlayerInventories(sdPtr)
    if !(invs && Type(invs) = "Array")
        return 0
    for _, inv in invs
    {
        if !(inv && IsObject(inv) && inv.Has("inventoryId"))
            continue
        if (inv["inventoryId"] != 1)
            continue
        cols := inv.Has("totalBoxesX") ? inv["totalBoxesX"] : 0
        rows := inv.Has("totalBoxesY") ? inv["totalBoxesY"] : 0
        items := inv.Has("items") ? inv["items"] : []
        if (cols <= 0 || rows <= 0)
            return 0
        return Map("items", items, "cols", cols, "rows", rows)
    }
    return 0
}

; ── Destination context (stash vs vendor vs trade) ───────────────────────────

; Returns the context descriptor for a kind: Map(kind, verb, button). The verb is
; used in the result tooltip; button is the overlay-button label.
_SmCtxFor(kind)
{
    switch kind
    {
        case "stash":  return Map("kind", "stash",  "verb", "Stashed", "button", "Dump → Stash")
        case "vendor": return Map("kind", "vendor", "verb", "Sold",    "button", "Sell → Vendor")
        case "trade":  return Map("kind", "trade",  "verb", "Moved",   "button", "Move → Trade")
        default:       return Map("kind", "unknown","verb", "Moved",   "button", "Dump items")
    }
}

; Detects the current destination context from the UI tree (confirmed in-game
; 2026-06-23 via the diagnostic). The "NPCBuyWindow" top-level panel is visible
; only while trading with an NPC, so it cleanly identifies a VENDOR. The player's
; own stash / inventory panels are NOT children of this root — they're reachable
; via pointer fields on the root struct (like GameHelper2's RightPanel), which a
; child-traversal can't see; stash detection is pending the panel-pointer scan
; (see StashMoverDiagnose). Until then a non-vendor container reads "unknown" (the
; Ctrl+Click still works — only the label is generic). Returns a Map(kind,verb,button).
_SmDetectContext()
{
    global g_reader
    if !IsObject(g_reader)
        return _SmCtxFor("unknown")
    gameUi := _UiBrowser_GetGameUiPtr()
    if !g_reader.IsProbablyValidPointer(gameUi)
        return _SmCtxFor("unknown")
    buyWin := _SmBfsFindStringId(g_reader, gameUi, "NPCBuyWindow", 3)
    if (buyWin && UiTree_HierarchicallyVisible(g_reader, buyWin))
        return _SmCtxFor("vendor")
    return _SmCtxFor("unknown")
}

; Refreshes the detected-destination context for the live "Detected destination"
; readout — runs every tick (throttled ~1.4 Hz), regardless of game focus so the
; readout updates while the user glances at the always-on-top tool. Detection is
; UI-tree only (no inventory read), so it's cheap. Pushes the header on a kind
; change. Param: radarSnap - unused (kept for signature symmetry).
_SmRefreshContext(radarSnap)
{
    global g_smCtx, g_smCtxKind, g_smCtxTick
    if ((A_TickCount - g_smCtxTick) < 700)
        return
    g_smCtxTick := A_TickCount
    prev := g_smCtxKind
    g_smCtx := _SmDetectContext()
    g_smCtxKind := g_smCtx["kind"]
    if (g_smCtxKind != prev)
        SetTimer(PushHeaderToWebView, -50)
}

; Returns the current cached context Map (for the button label), or the "unknown"
; descriptor when nothing has been detected yet.
_SmCurrentCtx()
{
    global g_smCtx
    return IsObject(g_smCtx) ? g_smCtx : _SmCtxFor("unknown")
}

; ── Destination diagnostic (RE aid — find the real stash/vendor signals) ─────

; Lists the StringId + visibility of the direct children of the GameUi root (the
; top-level panels). This is the cleanest discriminator for which window is open.
; Returns a newline string like "  PurchasePanel  [visible]".
_SmDiagTopPanels(reader, gameUi)
{
    out := ""
    if !reader.IsProbablyValidPointer(gameUi)
        return "  (gameUi invalid)`n"
    hdr := reader.Mem.ReadBytes(gameUi, 0x20)
    if !hdr
        return "  (root unreadable)`n"
    cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
        return "  (no children)`n"
    n := Min((cl - cf) // A_PtrSize, 256)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return "  (children unreadable)`n"
    idOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    Loop n
    {
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(cp)
            continue
        sid := ""
        try sid := reader.ReadStdWStringAt(cp + idOff, 64)
        if (sid = "")
            continue
        vis := false
        try vis := ((reader.Mem.ReadUInt(cp + flagsOff) >> 11) & 1) ? true : false
        out .= "  " sid (vis ? "  [visible]" : "  [hidden]") "`n"
    }
    return (out != "" ? out : "  (no named children)`n")
}

; Collects VISIBLE element StringIds containing any destination-ish keyword, deep
; in the tree (pruning hidden subtrees). Deduped + capped. Returns a newline string.
_SmDiagVisibleMatches(reader, gameUi)
{
    if !reader.IsProbablyValidPointer(gameUi)
        return "  (gameUi invalid)`n"
    kws := ["buy", "sell", "vendor", "purchase", "merchant", "shop", "store", "wares"
          , "trade", "stash", "gamble", "haggle", "wager", "npc", "barter", "sale"]
    idOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    queue := [{ptr: gameUi, d: 0}]
    seen := Map()
    found := Map()
    nodes := 0
    while (queue.Length > 0 && nodes < 6000)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        nodes += 1
        if (p != gameUi)
        {
            fl := 0
            try fl := reader.Mem.ReadUInt(p + flagsOff)
            if (((fl >> 11) & 1) = 0)
                continue
        }
        sid := ""
        try sid := reader.ReadStdWStringAt(p + idOff, 64)
        if (sid != "")
        {
            low := StrLower(sid)
            for _, kw in kws
            {
                if InStr(low, kw)
                {
                    found[sid] := true
                    break
                }
            }
        }
        if (it.d >= 18)
            continue
        hdr := reader.Mem.ReadBytes(p, 0x20)
        if !hdr
            continue
        cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        cn := Min((cl - cf) // A_PtrSize, 256)
        cbuf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
        if !cbuf
            continue
        Loop cn
        {
            cpp := NumGet(cbuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cpp)
                queue.Push({ptr: cpp, d: it.d + 1})
        }
    }
    out := ""
    cnt := 0
    for sid in found
    {
        out .= "  " sid "`n"
        if (++cnt >= 40)
            break
    }
    return (out != "" ? out : "  (none matched)`n")
}

; Lists ALL visible, named StringIds down to maxDepth (regardless of keywords), so
; the open window's real StringId is captured even if it matches no keyword. Prunes
; hidden subtrees; deduped + capped. Returns a newline string.
_SmDiagShallowVisible(reader, gameUi, maxDepth := 3)
{
    if !reader.IsProbablyValidPointer(gameUi)
        return "  (gameUi invalid)`n"
    idOff := PoE2Offsets.UiElementBase["StringIdPtr"]
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    queue := [{ptr: gameUi, d: 0}]
    seen := Map()
    found := Map()
    order := []
    while (queue.Length > 0)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        if (p != gameUi)
        {
            fl := 0
            try fl := reader.Mem.ReadUInt(p + flagsOff)
            if (((fl >> 11) & 1) = 0)
                continue
            sid := ""
            try sid := reader.ReadStdWStringAt(p + idOff, 64)
            if (sid != "" && !found.Has(sid))
            {
                found[sid] := true
                order.Push("  d" it.d "  " sid)
            }
        }
        if (it.d >= maxDepth)
            continue
        hdr := reader.Mem.ReadBytes(p, 0x20)
        if !hdr
            continue
        cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        cn := Min((cl - cf) // A_PtrSize, 256)
        cbuf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
        if !cbuf
            continue
        Loop cn
        {
            cpp := NumGet(cbuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cpp)
                queue.Push({ptr: cpp, d: it.d + 1})
        }
    }
    out := ""
    cnt := 0
    for _, line in order
    {
        out .= line "`n"
        if (++cnt >= 120)
            break
    }
    return (out != "" ? out : "  (none)`n")
}

; Enumerates EVERY direct child of the GameUi root by index (named or not), with
; StringId, UnscaledSize, visibility and screen pos. This mirrors what the UI
; browser shows (e.g. Gordin's stash = GameUi child [36]); run with the inventory
; AND stash open to identify the inventory grid's child index. Returns a string.
_SmDiagAllChildren(reader, gameUi)
{
    if !reader.IsProbablyValidPointer(gameUi)
        return "  (gameUi invalid)`n"
    hdr := reader.Mem.ReadBytes(gameUi, 0x20)
    if !hdr
        return "  (root unreadable)`n"
    cf := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    cl := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
        return "  (no children)`n"
    n := Min((cl - cf) // A_PtrSize, 256)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return "  (children unreadable)`n"
    idOff    := PoE2Offsets.UiElementBase["StringIdPtr"]
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    sizeOff  := PoE2Offsets.UiElementBase["UnscaledSize"]
    out := ""
    Loop n
    {
        idx := A_Index - 1
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(cp)
            continue
        sid := ""
        try sid := reader.ReadStdWStringAt(cp + idOff, 64)
        w := 0.0, h := 0.0
        szb := reader.Mem.ReadBytes(cp + sizeOff, 8)
        if szb
        {
            w := NumGet(szb.Ptr, 0, "Float")
            h := NumGet(szb.Ptr, 4, "Float")
        }
        vis := false
        try vis := ((reader.Mem.ReadUInt(cp + flagsOff) >> 11) & 1) ? true : false
        sp := UiTree_GetScreenPos(reader, cp)
        out .= Format("  [{}]  '{}'  {:.0f}x{:.0f}  {}  uiPos({:.0f},{:.0f})`n"
            , idx, sid, w, h, (vis ? "[visible]" : "[hidden]"), sp["x"], sp["y"])
    }
    return (out != "" ? out : "  (none)`n")
}

; Scans the GameUi root STRUCT (not its children array) for UiElement pointer
; FIELDS — this is where PoE2 keeps panel pointers like the inventory / stash /
; vendor (à la GameHelper2's RightPanel), which a child-traversal can't reach.
; For each pointer that looks like a UiElement, reports the field offset, StringId,
; UnscaledSize, visibility and screen pos. Run with the inventory/stash OPEN to
; find the inventory grid's pointer + screen rect. Returns a newline string.
_SmDiagPanelPointers(reader, gameUi)
{
    if !reader.IsProbablyValidPointer(gameUi)
        return "  (gameUi invalid)`n"
    parentOff := PoE2Offsets.UiElementBase["ParentPtr"]
    idOff     := PoE2Offsets.UiElementBase["StringIdPtr"]
    flagsOff  := PoE2Offsets.UiElementBase["Flags"]
    sizeOff   := PoE2Offsets.UiElementBase["UnscaledSize"]
    out := ""
    cnt := 0
    off := 0x300
    while (off < 0x1200)
    {
        p := reader.Mem.ReadPtr(gameUi + off)
        cur := off
        off += 8
        if (!reader.IsProbablyValidPointer(p) || p >= 0x7FF000000000)
            continue
        ; UiElement-ish: a valid Parent pointer at +0xB8.
        par := reader.Mem.ReadPtr(p + parentOff)
        if !reader.IsProbablyValidPointer(par)
            continue
        sid := ""
        try sid := reader.ReadStdWStringAt(p + idOff, 64)
        w := 0.0, h := 0.0
        szb := reader.Mem.ReadBytes(p + sizeOff, 8)
        if szb
        {
            w := NumGet(szb.Ptr, 0, "Float")
            h := NumGet(szb.Ptr, 4, "Float")
        }
        ; Skip tiny, unnamed noise — keep named elements and panel-sized ones.
        if (sid = "" && (w < 150 || h < 150))
            continue
        vis := false
        try vis := ((reader.Mem.ReadUInt(p + flagsOff) >> 11) & 1) ? true : false
        sp := UiTree_GetScreenPos(reader, p)
        out .= Format("  +0x{:03X}  '{}'  {:.0f}x{:.0f}  {}  uiPos({:.0f},{:.0f})`n"
            , cur, sid, w, h, (vis ? "[visible]" : "[hidden]"), sp["x"], sp["y"])
        if (++cnt >= 90)
            break
    }
    return (out != "" ? out : "  (none)`n")
}

; Dumps the inventory side panel's subtree (StringId + size + aspect + uiPos +
; visible), flagging ~12:5-aspect elements and marking the one _SmFindGridIn
; currently auto-picks as the backpack grid. Lets us confirm/fix the grid pick.
_SmDiagInventorySubtree(reader, gameUi)
{
    panel := _SmFindInventoryPanel(reader, gameUi)
    if !panel
        return "  (inventory side panel not found — open your inventory)`n"
    picked := _SmFindGridIn(reader, panel)
    flagsOff := PoE2Offsets.UiElementBase["Flags"]
    sizeOff  := PoE2Offsets.UiElementBase["UnscaledSize"]
    idOff    := PoE2Offsets.UiElementBase["StringIdPtr"]
    out := Format("  PANEL @0x{:X}   auto-picked GRID @0x{:X}`n", panel, picked)
    queue := [{ptr: panel, d: 0}]
    seen := Map()
    nodes := 0
    while (queue.Length > 0 && nodes < 400)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        nodes += 1
        vis := false
        try vis := ((reader.Mem.ReadUInt(p + flagsOff) >> 11) & 1) ? true : false
        if (p != panel && !vis)
            continue
        sid := ""
        try sid := reader.ReadStdWStringAt(p + idOff, 48)
        w := 0.0, h := 0.0
        szb := reader.Mem.ReadBytes(p + sizeOff, 8)
        if szb
        {
            w := NumGet(szb.Ptr, 0, "Float")
            h := NumGet(szb.Ptr, 4, "Float")
        }
        if (sid != "" || (w > 200 && h > 100))
        {
            sp := UiTree_GetScreenPos(reader, p)
            asp := (h > 0) ? (w / h) : 0
            tag := (p = picked) ? "  <== PICKED"
                 : ((asp >= 2.0 && asp <= 2.9 && w > 300) ? "  <-- grid?" : "")
            out .= Format("  d{} '{}' {:.0f}x{:.0f} a{:.2f} {} uiPos({:.0f},{:.0f}){}`n"
                , it.d, sid, w, h, asp, (vis ? "V" : "h"), sp["x"], sp["y"], tag)
        }
        if (it.d >= 8)
            continue
        chdr := reader.Mem.ReadBytes(p, 0x20)
        if !chdr
            continue
        cf := NumGet(chdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cl := NumGet(chdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
            continue
        cn := Min((cl - cf) // A_PtrSize, 128)
        cbuf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
        if !cbuf
            continue
        Loop cn
        {
            cp := NumGet(cbuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if reader.IsProbablyValidPointer(cp)
                queue.Push({ptr: cp, d: it.d + 1})
        }
    }
    return out
}

; Shows a MsgBox report of the live destination signals: ServerData / GameUi
; resolution, every open inventory id (+ grid + item count), the top-level panel
; StringIds (visible/hidden), the keyword-matched visible StringIds, the panel
; POINTER FIELDS on the root struct (where inventory/stash live), and the current
; detected kind. Run this at a stash AND at a vendor to pin the signals.
StashMoverDiagnose()
{
    global g_reader
    if !IsObject(g_reader)
    {
        try MsgBox("Game not connected.", "Stash Mover Diagnostic", 0x10)
        return
    }
    out := "Stash Mover — destination diagnostic`n`n"
    try
    {
        sdPtr := _SmResolveServerData()
        out .= "ServerData: " (sdPtr ? Format("0x{:X}", sdPtr) : "0  (FAILED to resolve)") "`n`n"

        out .= "Open inventory IDs:`n"
        invLines := ""
        if sdPtr
        {
            invs := 0
            try invs := g_reader.ReadAllPlayerInventories(sdPtr)
            if (invs && Type(invs) = "Array")
            {
                for _, inv in invs
                {
                    if !(inv && IsObject(inv))
                        continue
                    id := inv.Has("inventoryId") ? inv["inventoryId"] : -1
                    x := inv.Has("totalBoxesX") ? inv["totalBoxesX"] : 0
                    y := inv.Has("totalBoxesY") ? inv["totalBoxesY"] : 0
                    cnt := (inv.Has("items") && inv["items"] is Array) ? inv["items"].Length : 0
                    invLines .= "  id=" id "   " x "x" y "   items=" cnt "`n"
                }
            }
        }
        out .= (invLines != "" ? invLines : "  (none)`n") "`n"

        gameUi := _UiBrowser_GetGameUiPtr()
        out .= "GameUi: " (g_reader.IsProbablyValidPointer(gameUi) ? Format("0x{:X}", gameUi) : "0  (FAILED)") "`n`n"
        out .= "Top-level panels (direct children of GameUi):`n" _SmDiagTopPanels(g_reader, gameUi) "`n"
        out .= "Visible keyword-matched StringIds (deep):`n" _SmDiagVisibleMatches(g_reader, gameUi) "`n"
        out .= "All visible named StringIds (depth <= 3):`n" _SmDiagShallowVisible(g_reader, gameUi, 3) "`n"
        out .= "Panel POINTER FIELDS on the root struct (inventory/stash live here):`n" _SmDiagPanelPointers(g_reader, gameUi) "`n"
        out .= "ALL direct GameUi children by index (stash = Gordin's [36]; find inventory here):`n" _SmDiagAllChildren(g_reader, gameUi) "`n"
        out .= "INVENTORY panel subtree (auto-picked backpack grid marked PICKED):`n" _SmDiagInventorySubtree(g_reader, gameUi) "`n"

        ctx := _SmDetectContext()
        out .= "Currently detected kind:  " ctx["kind"]
    }
    catch as ex
    {
        out .= "`n`nEXCEPTION: " (ex.HasOwnProp("Message") ? ex.Message : "?")
    }
    ; Write the full report to debug\ (the MsgBox truncates long lists) and show
    ; only the path + the detected kind.
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        try DirCreate(outDir)
    outPath := outDir "\stashmover_diag_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try {
        FileAppend(out, outPath, "UTF-8")
        wrote := true
    }
    kindNow := ""
    try kindNow := _SmDetectContext()["kind"]
    if wrote
    {
        try MsgBox("Diagnostic written to:`n" outPath "`n`nDetected kind: " kindNow, "Stash Mover Diagnostic", 0x40)
    }
    else
    {
        try MsgBox(out, "Stash Mover Diagnostic", 0x40)   ; fallback if the file write failed
    }
}

; True when the metadata path looks like a quest item (these can't be stashed).
_SmIsQuestItem(path)
{
    p := StrLower(path "")
    return (InStr(p, "questitem") || InStr(p, "/quests/")) ? true : false
}

; Classifies an item into one category for the vendor sell filter:
; "map" (Metadata/Items/Maps/ waystones) > "currency" (rarityId 5) >
; "unique" (rarityId 3/4) > "gear" (everything else: normal/magic/rare equipment).
; Maps win over rarity so a unique/rare waystone is still treated as a map.
_SmItemCategory(details)
{
    if !(details && IsObject(details))
        return "gear"
    path := details.Has("metadataPath") ? details["metadataPath"] : ""
    if (InStr(StrLower(path), "/maps/"))
        return "map"
    rid := details.Has("rarityId") ? details["rarityId"] : -1
    if (rid = 5)
        return "currency"
    if (rid = 3 || rid = 4)
        return "unique"
    return "gear"
}

; True when the given sell category is enabled for selling.
_SmSellCategoryEnabled(cat)
{
    global g_smSellGear, g_smSellUniques, g_smSellCurrency, g_smSellMaps
    switch cat
    {
        case "map":      return g_smSellMaps
        case "currency": return g_smSellCurrency
        case "unique":   return g_smSellUniques
        default:         return g_smSellGear   ; "gear"
    }
}

; True when the destination is a selling context the sell filter must apply to.
; Only the CONFIRMED vendor (NPCBuyWindow, reliably detected) — so the stash and
; the plain inventory ("unknown") dump everything (minus ignore / quest / failed),
; which is what the user wants when stashing.
_SmIsSellingKind(kind)
{
    return (kind = "vendor")
}

; Decides whether a backpack item should be skipped this run, and why.
; Returns "" (move it) or a reason: "ignore" | "quest" | "failed" | "filter".
; Params: item - one backpack item Map; nowTick - A_TickCount for cooldown checks;
; kind - the detected destination kind (drives the vendor sell filter).
_SmShouldSkip(item, nowTick, kind := "")
{
    global g_smIgnore, g_smSkipQuest, g_smFailed, g_smFailCooldownMs
    d := item.Has("details") ? item["details"] : 0
    path := (d && IsObject(d) && d.Has("metadataPath")) ? d["metadataPath"] : ""
    if (path != "" && g_smIgnore.Has(path))
        return "ignore"
    if (g_smSkipQuest && _SmIsQuestItem(path))
        return "quest"
    ptr := item.Has("itemEntityPtr") ? item["itemEntityPtr"] : 0
    if (ptr && g_smFailed.Has(ptr) && (nowTick - g_smFailed[ptr]) < g_smFailCooldownMs)
        return "failed"
    ; Vendor sell filter — only when selling. Keep the categories the user opted out of.
    if (_SmIsSellingKind(kind) && !_SmSellCategoryEnabled(_SmItemCategory(d)))
        return "filter"
    return ""
}

; ── Dump sequencer ───────────────────────────────────────────────────────────

; Public entry point. Builds the click queue (one point per eligible backpack
; item, deduped by item pointer) and starts the non-blocking sequencer.
; Param: source - "hotkey" | "button" | "ui" (for diagnostics only).
StashMoverDump(source := "")
{
    global g_reader, g_smEnabled, g_smRunning, g_smJitter, g_smAllowSell
    global g_smQueue, g_smQueueIdx, g_smMovedCount, g_smQueuedPtrs
    global g_smFailed, g_smFailCooldownMs
    global g_smCtx, g_smCtxKind, g_smCtxTick, g_smRunVerb
    if !g_smEnabled
        return
    if g_smRunning
        return
    if !IsObject(g_reader)
    {
        _SmTooltip("Stash Mover: game not connected.", 1500)
        return
    }

    ; The grid must be on screen to click its cells.
    rect := _SmInventoryGridRect()
    if !IsObject(rect)
    {
        _SmTooltip("Stash Mover: inventory not visible.", 1500)
        return
    }
    sdPtr := _SmResolveServerData()
    bp := _SmReadBackpack(sdPtr)
    if !IsObject(bp)
    {
        _SmTooltip("Stash Mover: can't read backpack.", 1500)
        return
    }

    ; Detect what's open (stash vs vendor vs trade) — drives the result verb and
    ; the optional sell guard. The Ctrl+Click action itself is identical.
    ctx := _SmDetectContext()
    g_smCtx := ctx, g_smCtxKind := ctx["kind"], g_smCtxTick := A_TickCount
    if (ctx["kind"] = "vendor" && !g_smAllowSell)
    {
        _SmTooltip("Stash Mover: a vendor is open and selling is disabled.", 2000)
        return
    }
    g_smRunVerb := ctx["verb"]

    cols := bp["cols"], rows := bp["rows"]
    cellW := rect["w"] / cols
    cellH := rect["h"] / rows
    ; Position jitter radius: keep clicks well inside the cell (~30% of the
    ; smaller half-cell), so a stray pixel can never spill into a neighbour.
    jr := g_smJitter ? Max(0, Round(Min(cellW, cellH) * 0.30)) : 0

    ; Prune stale failed entries so items become retry-able after the cooldown.
    now := A_TickCount
    for ptr, t in g_smFailed.Clone()
        if ((now - t) >= g_smFailCooldownMs)
            g_smFailed.Delete(ptr)

    ; Build the click list. Each item occupies cells [slotStartX, slotEndX) ×
    ; [slotStartY, slotEndY); its geometric centre in grid units is the midpoint,
    ; converted to a pixel inside the grid rectangle. Dedupe by item pointer so a
    ; multi-cell item (which the reader repeats per cell) is clicked only once;
    ; skip ignored / quest / recently-failed items.
    points := []
    queuedPtrs := []
    seen := Map()
    skipped := Map("ignore", 0, "quest", 0, "failed", 0, "filter", 0)
    for _, it in bp["items"]
    {
        if !(it && IsObject(it))
            continue
        ptr := it.Has("itemEntityPtr") ? it["itemEntityPtr"] : 0
        if (ptr && seen.Has(ptr))
            continue
        if ptr
            seen[ptr] := true
        reason := _SmShouldSkip(it, now, ctx["kind"])
        if (reason != "")
        {
            if skipped.Has(reason)
                skipped[reason] += 1
            continue
        }
        sx := it.Has("slotStartX") ? it["slotStartX"] : 0
        sy := it.Has("slotStartY") ? it["slotStartY"] : 0
        ex := it.Has("slotEndX") ? it["slotEndX"] : (sx + 1)
        ey := it.Has("slotEndY") ? it["slotEndY"] : (sy + 1)
        cgx := (sx + ex) / 2.0
        cgy := (sy + ey) / 2.0
        px := Round(rect["x"] + cgx * cellW)
        py := Round(rect["y"] + cgy * cellH)
        points.Push(Map("x", px, "y", py, "jr", jr))
        if ptr
            queuedPtrs.Push(ptr)
    }

    if (points.Length = 0)
    {
        msg := "Stash Mover: nothing to move"
        if (skipped["ignore"] || skipped["quest"] || skipped["failed"] || skipped["filter"])
            msg .= " (" skipped["ignore"] " ignored, " skipped["filter"] " filtered, " skipped["quest"] " quest, " skipped["failed"] " on cooldown)"
        _SmTooltip(msg ".", 1800)
        return
    }

    ; Make sure PoE2 is the foreground window so the synthetic clicks land on it.
    ; (The overlay button is NOACTIVATE, but a hotkey could fire from elsewhere.)
    gameHwnd := ResolvePoEWindow()
    if (gameHwnd && !WinActive("ahk_id " gameHwnd))
    {
        try WinActivate("ahk_id " gameHwnd)
        Sleep(60)
    }
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmTooltip("Stash Mover: PoE window not active.", 1500)
        return
    }

    g_smQueue := points
    g_smQueuedPtrs := queuedPtrs
    g_smQueueIdx := 0
    g_smMovedCount := 0
    g_smRunning := true
    _SmHideGui()   ; avoid a stray button click during the run

    ; Hold Ctrl down for the whole run (keybd_event = UIPI-bypass, like the rest).
    DllCall("keybd_event", "uchar", 0xA2, "uchar", 0, "uint", 0, "uptr", 0)   ; LCONTROL down
    Sleep(20)
    SetTimer(_SmStep, -1)   ; first step ASAP, then self-re-arms
}

; One sequencer step: clicks the next queued item, then re-arms after a (jittered)
; per-item delay. When the queue is exhausted it releases Ctrl and schedules the
; post-run verification. Aborts (releasing Ctrl) if PoE2 loses focus mid-run.
_SmStep()
{
    global g_smRunning, g_smQueue, g_smQueueIdx, g_smMovedCount
    global g_smPerItemDelayMs, g_smJitter
    if !g_smRunning
        return

    gameHwnd := ResolvePoEWindow()
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmReleaseCtrl()
        _SmFinish("Stash Mover: aborted (focus lost) — clicked " g_smMovedCount ".")
        return
    }

    if (g_smQueueIdx >= g_smQueue.Length)
    {
        ; Done clicking — release Ctrl and verify after a short settle so the
        ; server inventory has time to reflect the moves.
        _SmReleaseCtrl()
        SetTimer(_SmVerify, -Max(250, g_smPerItemDelayMs * 5))
        return
    }

    g_smQueueIdx += 1
    pt := g_smQueue[g_smQueueIdx]
    _SmClickAt(pt["x"], pt["y"], pt.Has("jr") ? pt["jr"] : 0)
    g_smMovedCount += 1

    ; Jittered inter-click delay so the cadence isn't perfectly static.
    delay := g_smPerItemDelayMs
    if g_smJitter
        delay := Round(g_smPerItemDelayMs * _SmRandF(0.75, 1.45))
    SetTimer(_SmStep, -Max(1, delay))
}

; Post-run verification: re-reads the backpack and flags every item we attempted
; that's still present as "failed" (cooldown skip on the next run). Warns when
; nothing moved at all (stash full / no valid destination). Clears run state.
_SmVerify()
{
    global g_smRunning, g_smQueuedPtrs, g_smFailed, g_smMovedCount, g_smRunVerb
    verb := g_smRunVerb                  ; "Stashed" | "Sold" | "Moved"
    verbLow := StrLower(verb)
    attempted := g_smQueuedPtrs.Length
    stillThere := Map()
    sdPtr := _SmResolveServerData()
    bp := sdPtr ? _SmReadBackpack(sdPtr) : 0
    if IsObject(bp)
    {
        for _, it in bp["items"]
        {
            ptr := (it && IsObject(it) && it.Has("itemEntityPtr")) ? it["itemEntityPtr"] : 0
            if ptr
                stillThere[ptr] := true
        }
        now := A_TickCount
        failed := 0
        for _, ptr in g_smQueuedPtrs
        {
            if stillThere.Has(ptr)
            {
                g_smFailed[ptr] := now    ; couldn't move — skip for the cooldown
                failed += 1
            }
        }
        moved := attempted - failed
        if (attempted > 0 && moved = 0)
            _SmTooltip("Stash Mover: nothing " verbLow " — destination full or item not movable?", 2200)
        else if (failed > 0)
            _SmTooltip("Stash Mover: " verbLow " " moved ", " failed " couldn't be moved.", 2000)
        else
            _SmTooltip("Stash Mover: " verbLow " " moved " item(s).", 1600)
    }
    else
    {
        ; Couldn't verify — just report the click count.
        _SmTooltip("Stash Mover: clicked " g_smMovedCount " item(s).", 1500)
    }
    _SmFinish("")
}

; Releases the held Ctrl key (idempotent enough to call on any exit path).
_SmReleaseCtrl()
{
    DllCall("keybd_event", "uchar", 0xA2, "uchar", 0, "uint", 0x0002, "uptr", 0)   ; LCONTROL up
}

; Clears run state and shows an optional status tooltip. Does NOT touch Ctrl —
; callers release it explicitly so the key state is correct on every path.
_SmFinish(msg := "")
{
    global g_smRunning, g_smQueue, g_smQueueIdx, g_smQueuedPtrs
    g_smRunning := false
    g_smQueue := []
    g_smQueuedPtrs := []
    g_smQueueIdx := 0
    if (msg != "")
        _SmTooltip(msg, 1600)
}

; Moves the cursor to (x,y) plus a small random offset (±jr px) and issues a
; single short left click. Ctrl is already held, so in an open container the game
; treats it as a move. Param: jr - max jitter radius in px (0 = none).
_SmClickAt(x, y, jr := 0)
{
    global g_smSettleDelayMs, g_smJitter
    cx := x, cy := y
    if (jr > 0)
    {
        cx += Random(-jr, jr)
        cy += Random(-jr, jr)
    }
    DllCall("SetCursorPos", "int", cx, "int", cy)
    settle := g_smSettleDelayMs
    if g_smJitter
        settle := Round(g_smSettleDelayMs * _SmRandF(0.6, 1.4))
    Sleep(Max(1, settle))
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0)   ; LEFTDOWN
    Sleep(g_smJitter ? Random(6, 14) : 8)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0)   ; LEFTUP
}

; Returns a random float in [lo, hi] (AHK v2 Random with float args).
_SmRandF(lo, hi)
{
    return Random(lo, hi)
}

; Shows a transient tooltip near the cursor that auto-clears after ms.
_SmTooltip(text, ms := 1500)
{
    try {
        ToolTip(text)
        SetTimer(() => ToolTip(), -Abs(ms))
    }
}

; ── Interactive overlay button ───────────────────────────────────────────────

; Lazily creates the always-on-top, NOACTIVATE button window. NOACTIVATE
; (WS_EX_NOACTIVATE 0x08000000) lets the button receive clicks WITHOUT stealing
; foreground from the game, so the synthetic Ctrl+Clicks still land on PoE2.
_SmEnsureGui()
{
    global g_smGui, g_smBtnCtrl
    if IsObject(g_smGui)
        return
    g_smGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
    g_smGui.MarginX := 0
    g_smGui.MarginY := 0
    g_smGui.BackColor := "1A1A1A"
    g_smBtnCtrl := g_smGui.AddButton("x0 y0 w120 h24", "Dump → Stash")
    g_smBtnCtrl.OnEvent("Click", _SmOnButtonClick)
}

; Button click handler — runs a dump from the button path.
_SmOnButtonClick(*)
{
    StashMoverDump("button")
}

; Hides the overlay button window (no-op when already hidden).
_SmHideGui()
{
    global g_smGui, g_smGuiShown
    if (IsObject(g_smGui) && g_smGuiShown)
    {
        try g_smGui.Hide()
        g_smGuiShown := false
    }
}

; Per-tick driver (called from UpdateRadarFast). Shows/positions the overlay
; button just above the inventory grid when the feature is on, the button is
; enabled, the game is focused and the grid is visible; hides it otherwise.
; Self-gated and cheap when disabled. Param: radarSnap (unused, kept for symmetry).
StashMoverTick(radarSnap := 0)
{
    global g_smEnabled, g_smShowButton, g_smRunning, g_smGui, g_smGuiShown
    static _lastBfsTick := 0
    if !g_smEnabled
    {
        _SmHideGui()
        return
    }
    ; Keep the "Detected destination" readout live even when the game isn't focused
    ; (the user is usually in the tool window while configuring). Cheap-gated inside.
    _SmRefreshContext(radarSnap)

    ; The overlay button needs the button enabled, no active run, and game focus.
    if (!g_smShowButton || g_smRunning)
    {
        _SmHideGui()
        return
    }
    gameHwnd := ResolvePoEWindow()
    if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
    {
        _SmHideGui()
        return
    }
    ; Throttle the (heavier) UI-tree resolve to ~4 Hz regardless of state; on
    ; skipped ticks leave the button as-is (≤250 ms latency to show/hide is fine).
    if ((A_TickCount - _lastBfsTick) < 250)
        return
    _lastBfsTick := A_TickCount
    rect := _SmInventoryGridRect()
    if !IsObject(rect)
    {
        _SmHideGui()
        return
    }

    _SmEnsureGui()
    _SmUpdateButtonText()
    btnW := 130, btnH := 24
    ; Anchor at the grid's top-right, just above the first row.
    bx := Round(rect["x"] + rect["w"] - btnW)
    by := Round(rect["y"] - btnH - 4)
    if (by < 0)
        by := Round(rect["y"] + 4)   ; fall back to inside the grid if off-screen
    try {
        g_smGui.Show("x" bx " y" by " w" btnW " h" btnH " NoActivate")
        g_smGuiShown := true
    }
}

; Updates the overlay button's caption from the (cached) detected context, so it
; reads "Sell → Vendor" at a vendor and "Dump → Stash" at the stash. Only writes
; when the text actually changed to avoid needless redraws.
_SmUpdateButtonText()
{
    global g_smBtnCtrl, g_smLastBtnText
    if !IsObject(g_smBtnCtrl)
        return
    ctx := _SmCurrentCtx()
    txt := ctx["button"]
    if (txt != g_smLastBtnText)
    {
        try g_smBtnCtrl.Text := txt
        g_smLastBtnText := txt
    }
}
