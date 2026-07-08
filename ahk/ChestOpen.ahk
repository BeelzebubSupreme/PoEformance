; ChestOpen.ahk
; AutoPilot chest auto-open. Slots into the AutoPilot priority chain with TWO
; passes (see AutoPilot._RunAutoPilot):
;   - "adjacent" pass, BEFORE combat: opens a chest within ADJACENT_RANGE even
;     while a hostile is near, so a chest the character is standing on gets
;     grabbed mid-fight instead of being deferred (owner-requested behaviour).
;   - "safe" pass, AFTER loot: walks to / opens the nearest eligible chest when
;     the area is clear (no hostile inside g_combatRange). Combat + loot have
;     already declined the tick by the time this pass runs.
;
; Chest detection: awake-entity sample, g_reader.IsChestLikeEntityPath(path).
; The radar hot path does NOT decode the Chest component, so isOpened /
; isStrongbox are resolved ON DEMAND from the entity's Chest component address
; (ReadEntityComponentLookupBasic -> DecodeChestComponent), cached per entity
; address with a short TTL. Eligibility:
;   - skip already-opened chests (isOpened)
;   - regular chests always eligible; strongboxes only when g_apOpenStrongboxes
;     (a strongbox spawns a monster pack the instant it opens).
;
; Action: reuses LootPickup's proven toolkit — _GetPlayerPos, _LootWorldToScreen,
; _LootFindLabelNear, _NearestHostileDistance, GetAvoidZones/AvoidZoneHitKind —
; and the same throttled raw LMB click. Clicking the chest LABEL (interactable,
; clear of the HUD) is preferred over the ground point; the game walks the
; character over and opens it. Only "ent" avoid-zone hits are blocked (matching
; loot), never the display-only HUD/map boxes.
;
; Globals seeded in LoadChestOpen() (AHK v2 init gotcha). Self-persists the
; [ChestOpen] section in poeformance_config.ini.
;
; Included by InGameStateMonitor.ahk.

; ── Config load / save ─────────────────────────────────────────────────────
; Seeds all module globals unconditionally (init gotcha) then overlays the INI.
LoadChestOpen()
{
    global g_apOpenChests := true          ; master: auto-open regular chests
    global g_apOpenStrongboxes := false    ; also open strongboxes (spawns a pack)
    global g_apChestRareOnly := true       ; only open Rare+ regular chests (skip the trivial Normal/Magic chests everywhere)
    global g_chestConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_chestLastReason := "idle"
    global g_chestState := Map()           ; entityAddr -> Map(opened,strongbox,tick)
    global g_chestBlacklist := Map()       ; entityAddr -> expiry tick (unreachable / no-progress chests, skipped until then)

    f := g_chestConfigFile
    try {
        g_apOpenChests      := (IniRead(f, "ChestOpen", "openChests", g_apOpenChests ? "1" : "0") = "1")
        g_apOpenStrongboxes := (IniRead(f, "ChestOpen", "openStrongboxes", g_apOpenStrongboxes ? "1" : "0") = "1")
        g_apChestRareOnly   := (IniRead(f, "ChestOpen", "rareOnly", g_apChestRareOnly ? "1" : "0") = "1")
    } catch as ex {
        LogError("LoadChestOpen", ex)
    }
}

; Persists the ChestOpen settings to [ChestOpen].
SaveChestOpen()
{
    global g_apOpenChests, g_apOpenStrongboxes, g_apChestRareOnly, g_chestConfigFile
    f := g_chestConfigFile
    try {
        IniWrite(g_apOpenChests ? "1" : "0", f, "ChestOpen", "openChests")
        IniWrite(g_apOpenStrongboxes ? "1" : "0", f, "ChestOpen", "openStrongboxes")
        IniWrite(g_apChestRareOnly ? "1" : "0", f, "ChestOpen", "rareOnly")
    } catch as ex {
        LogError("SaveChestOpen", ex)
    }
}

; Applies one setting change from the bridge and persists.
; key: "openChests" | "openStrongboxes"; val: truthy/falsy from the UI.
_ChestApplySetting(key, val)
{
    global g_apOpenChests, g_apOpenStrongboxes, g_apChestRareOnly
    on := (val = true || val = 1 || val = "1" || val = "true")
    if (key = "openChests")
        g_apOpenChests := on
    else if (key = "openStrongboxes")
        g_apOpenStrongboxes := on
    else if (key = "rareOnly")
        g_apChestRareOnly := on
    SaveChestOpen()
}

; Header JSON object for the WebView push. Returns just the {...} — the
; "chestOpen": key is prepended by WebViewBridge (matching the other builders).
BuildChestOpenHeaderJson()
{
    global g_apOpenChests, g_apOpenStrongboxes, g_apChestRareOnly
    return '{'
        . '"openChests":' (g_apOpenChests ? "true" : "false")
        . ',"openStrongboxes":' (g_apOpenStrongboxes ? "true" : "false")
        . ',"rareOnly":' (g_apChestRareOnly ? "true" : "false")
        . '}'
}

; ── Public entry ───────────────────────────────────────────────────────────
; mode: "adjacent" (opens only a chest within ADJACENT_RANGE; runs before
;       combat so it can fire mid-fight) or "safe" (nearest eligible chest,
;       area-safe; runs after loot). Returns true if it acted this tick.
TryChestOpen(radarSnap, gameHwnd, mode)
{
    static _running := false
    if _running
        return false
    _running := true
    try
        return _RunChestOpen(radarSnap, gameHwnd, mode)
    catch as ex
    {
        LogError("TryChestOpen", ex)
        return false
    }
    finally
        _running := false
}

_RunChestOpen(radarSnap, gameHwnd, mode)
{
    global g_reader, g_chestLastReason, g_combatRange
    global g_apOpenChests, g_chestState, g_chestBlacklist

    static ADJACENT_RANGE   := 250      ; world units — "standing on it"
    static MAX_SAFE_DIST    := 1600     ; safe pass: don't walk cross-map for a chest — let exploration approach first
    static CLICK_THROTTLE_MS := 450     ; one click per this while walking to a chest
    static PURSUE_TIMEOUT_MS := 6000    ; give up on a chest we can't get closer to (unreachable / behind terrain)
    static PROGRESS_EPS     := 80       ; a real "getting closer" step (world units)
    static _lastClickTick   := 0
    ; Pursuit tracker — detects a chest whose distance won't drop (the log showed
    ; a chest oscillating at d~1300-1800 hogging the tick for 15 s+). Blacklists it
    ; and yields, exactly like combat's no-path give-up + LootPickup's attempt budget.
    static _pursueAddr    := 0
    static _pursueMinDist := 0.0
    static _pursueSince   := 0

    if !g_apOpenChests
        return false

    playerPos := _GetPlayerPos(radarSnap)
    if !playerPos
        return false
    now := A_TickCount

    target := _ChestNearestEligible(radarSnap, playerPos["x"], playerPos["y"])
    if !target
    {
        ; Only the safe pass owns the reason line — the adjacent pass stays silent
        ; when idle so it doesn't stomp the combat/explore status when there is
        ; no chest underfoot.
        if (mode = "safe")
            g_chestLastReason := "no-chest"
        _pursueAddr := 0
        return false
    }

    ; ── Per-pass range / safety gate ─────────────────────────────────────
    if (mode = "adjacent")
    {
        if (target["dist"] > ADJACENT_RANGE)
            return false   ; not underfoot — leave it for the safe pass / combat
    }
    else   ; "safe"
    {
        if (target["dist"] > MAX_SAFE_DIST)
        {
            ; Too far to walk to directly — don't hog the tick. Exploration moves us
            ; around; once we're within range the chest gets pursued. Do NOT reset the
            ; pursuit tracker here: a chest oscillating around the cap would otherwise
            ; restart the give-up timer every out-of-range tick and never give up.
            g_chestLastReason := "too-far(" target["kind"] " d=" Round(target["dist"]) ")"
            return false
        }
        if (_NearestHostileDistance(radarSnap) < g_combatRange)
        {
            g_chestLastReason := "hostile-nearby"
            return false   ; defer to combat
        }
    }

    ; ── No-progress give-up ──────────────────────────────────────────────
    ; Track the chest we're pursuing. Resetting on a real distance drop, we give up
    ; (blacklist ~60 s + yield) when we can't get closer for PURSUE_TIMEOUT_MS —
    ; the unreachable-chest case that previously looped forever.
    if (target["addr"] != _pursueAddr)
    {
        _pursueAddr    := target["addr"]
        _pursueMinDist := target["dist"]
        _pursueSince   := now
    }
    else if (target["dist"] < _pursueMinDist - PROGRESS_EPS)
    {
        _pursueMinDist := target["dist"]
        _pursueSince   := now                 ; progress → reset the give-up timer
    }
    else if ((now - _pursueSince) > PURSUE_TIMEOUT_MS)
    {
        g_chestBlacklist[target["addr"]] := now + 60000
        _pursueAddr := 0
        g_chestLastReason := "giveup(" target["kind"] " d=" Round(target["dist"]) " unreachable)"
        return false
    }

    ; ── Project the chest world position to screen ───────────────────────
    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    w2sMat := (inGs && IsObject(inGs) && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    if !(w2sMat && Type(w2sMat) = "Array" && w2sMat.Length = 16)
    {
        g_chestLastReason := "no-w2s-matrix"
        return false
    }
    sp := _LootWorldToScreen(target["worldX"], target["worldY"], target["worldZ"], w2sMat, gameHwnd)
    if !sp
    {
        g_chestLastReason := "no-screen-pos"
        return false
    }

    ; Throttle FIRST so the label DFS runs ~once per click, not every tick while
    ; the character walks toward the chest. (now was captured at function entry.)
    if ((now - _lastClickTick) < CLICK_THROTTLE_MS)
    {
        g_chestLastReason := "walking(" target["kind"] " d=" Round(target["dist"]) ")"
        return true
    }

    ; Prefer the chest's floating LABEL (interactable, above the chest, clear of
    ; the bottom HUD); fall back to the ground point when no label is found.
    labelPt  := _LootFindLabelNear(g_reader, sp["x"], sp["y"], gameHwnd)
    clickPt  := labelPt ? labelPt : sp
    clickTag := labelPt ? "lbl" : "grnd"

    ; Block only interactables ("ent": transitions / portals / waypoints / NPCs /
    ; checkpoints). HUD/map boxes are display-only — clicking them is harmless in
    ; PoE2 and vetoing them just makes the bot skip a good click (same rule loot
    ; uses). A chest next to a waypoint waits for a clearer camera angle.
    avoidRects := GetAvoidZones(radarSnap, gameHwnd)
    azKind := AvoidZoneHitKind(clickPt["x"], clickPt["y"], avoidRects)
    if (azKind = "ent")
    {
        g_chestLastReason := "avoid-zone(" target["kind"] " " clickTag "/" azKind ")"
        return false
    }

    ; Aim + click (raw Win32 — SetCursorPos + mouse_event bypass UIPI when the
    ; game runs elevated, identical to LootPickup's click).
    DllCall("SetCursorPos", "int", clickPt["x"], "int", clickPt["y"])
    Sleep(20)
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LDOWN
    Sleep(20)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LUP
    _lastClickTick := now
    ; Force a state re-resolve next scan so an opened chest drops out of the
    ; eligible set promptly (the game flips isOpened once the char arrives).
    if g_chestState.Has(target["addr"])
        g_chestState[target["addr"]]["tick"] := 0

    g_chestLastReason := "open(" target["kind"] " " clickTag " d=" Round(target["dist"]) ")"
    return true
}

; Scans the awake sample for the nearest eligible (unopened, type-allowed) chest.
; Returns Map(addr, worldX/Y/Z, dist, kind="chest"|"strongbox") or 0.
_ChestNearestEligible(radarSnap, px, py)
{
    global g_reader, g_apOpenStrongboxes, g_apChestRareOnly, g_chestBlacklist

    ; Prune expired blacklist entries (a chest we gave up on becomes eligible again
    ; after its cooldown — the player may have moved to a spot it's reachable from).
    now := A_TickCount
    for a in g_chestBlacklist.Clone()
        if (g_chestBlacklist[a] <= now)
            g_chestBlacklist.Delete(a)

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if !(sample && Type(sample) = "Array")
        return 0

    best := 0
    bestDist := 999999.0
    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if (path = "" || !g_reader.IsChestLikeEntityPath(path))
            continue
        addr := entity.Has("address") ? entity["address"] : 0
        if !addr
            continue
        if (g_chestBlacklist.Has(addr) && g_chestBlacklist[addr] > now)
            continue   ; gave up on this one recently (unreachable) — skip until it expires

        ; World position (chests carry a Render component on the radar path).
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue
        render := decoded.Has("render") ? decoded["render"] : 0
        if !(render && IsObject(render) && render.Has("worldPosition"))
            continue
        wp := render["worldPosition"]
        wx := wp.Has("x") ? wp["x"] : 0
        wy := wp.Has("y") ? wp["y"] : 0
        wz := wp.Has("z") ? wp["z"] : 0
        if (wx = 0 && wy = 0)
            continue

        st := _ChestResolveState(addr)
        if !st
            continue
        if st["opened"]
            continue
        if (st["strongbox"] && !g_apOpenStrongboxes)
            continue
        ; Rare+ filter: regular chests come in huge numbers (trivial Normal ones
        ; everywhere), so by default only pursue Rare+ (rarityId >= 2) — that stops
        ; the bot walking to every little chest. Strongboxes are exempt (own toggle,
        ; always worth opening). Rarity from the radar-decoded Mods/ObjectMagicProperties;
        ; Normal chests have no such component so ReadEntityRarityId returns 0.
        if (g_apChestRareOnly && !st["strongbox"] && ReadEntityRarityId(decoded) < 2)
            continue

        dx := wx - px, dy := wy - py
        dist := Sqrt(dx * dx + dy * dy)
        if (dist < bestDist)
        {
            bestDist := dist
            best := Map("addr", addr, "worldX", wx, "worldY", wy, "worldZ", wz
                , "dist", dist, "kind", st["strongbox"] ? "strongbox" : "chest")
        }
    }
    return best
}

; Resolves + caches a chest's opened/strongbox state from its Chest component.
; Cached per entity address; re-resolved after TTL and immediately after a click
; forced tick:=0. An opened chest re-resolves as opened (the flag never reverts),
; so the cache is purely a read-throttle. Capped so a long session can't grow it
; unbounded. Returns Map(opened,strongbox,tick) or 0 when unreadable.
_ChestResolveState(addr)
{
    global g_reader, g_chestState
    static TTL_MS := 700
    static CAP := 400

    now := A_TickCount
    if g_chestState.Has(addr)
    {
        c := g_chestState[addr]
        if (c["opened"] || (now - c["tick"]) < TTL_MS)
            return c
    }

    compAddr := 0
    try {
        comps := g_reader.ReadEntityComponentLookupBasic(addr, 64)
        for _, comp in comps
        {
            if (StrLower(comp["name"]) = "chest")
            {
                compAddr := comp["address"]
                break
            }
        }
    } catch {
        return (g_chestState.Has(addr) ? g_chestState[addr] : 0)
    }
    if !compAddr
        return 0

    dec := 0
    try dec := g_reader.DecodeChestComponent(compAddr)
    if !(dec && IsObject(dec))
        return 0

    if (g_chestState.Count > CAP)
        g_chestState.Clear()   ; opened chests simply re-resolve as opened; safe to drop
    st := Map(
        "opened",    (dec.Has("isOpened") && dec["isOpened"]) ? true : false,
        "strongbox", (dec.Has("isStrongbox") && dec["isStrongbox"]) ? true : false,
        "tick",      now
    )
    g_chestState[addr] := st
    return st
}
