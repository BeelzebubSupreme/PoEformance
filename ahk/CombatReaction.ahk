; CombatReaction.ahk
; Defensive combat reaction. When a nearby ENEMY plays an animation whose id is in
; the user's danger list, aim the cursor AWAY from that enemy and press a configured
; key (a dodge / guard / defensive skill the user has bound in-game). Works during
; MANUAL play too — it has its own toggle and does not depend on AutoPilot.
;
; Runs on the radar hot path (TryCombatReaction, from UpdateRadarFast after
; TryAutoPilot) but self-gates hard: when nothing dangerous is on screen the cost is
; only an in-memory scan of the awake sample reading CACHED decoded fields — the enemy
; animationId comes from the hot-path read in UpdateCachedEntityRadar
; (decodedComponents["actor"]["animationId"]). Input (SetCursorPos + keypress) and the
; projection only happen on a real match, cooldown-limited, and only while PoE is the
; foreground window.
;
; Reuses: _WorldToScreen + _SendSkillKey (CombatAutomation), NavClientRect (ClickNav),
; IsStrictInGameState (AutoFlask), ResolvePoEWindow, g_reader.IsNpcLikeEntityPath.
; Self-persists [CombatReaction]. Default OFF. Included by InGameStateMonitor.ahk.

; ── Config (init gotcha: seed ALL globals unconditionally, then overlay INI) ──
LoadCombatReaction()
{
    global g_crEnabled := false          ; master switch
    global g_crHotkey := ""              ; AHK send-key of the defensive action (e.g. "q", "space", "rbutton")
    global g_crAnimIdsStr := ""          ; comma-separated danger animation ids (raw, for UI/persist)
    global g_crAnimIds := Map()          ; parsed id -> true set (fast lookup on the hot path)
    global g_crRadius := 1200            ; only react to enemies within this world distance
    global g_crCooldownMs := 800         ; minimum time between reactions
    global g_crAimAway := true           ; aim the cursor away from the enemy before pressing
    global g_crRestoreCursor := true     ; restore the cursor to where it was after the keypress
    global g_crConfigFile := A_ScriptDir "\poeformance_config.ini"

    ; Runtime (never persisted)
    global g_crLastReactTick := 0

    f := g_crConfigFile
    try {
        g_crEnabled       := (IniRead(f, "CombatReaction", "enabled", g_crEnabled ? "1" : "0") = "1")
        g_crHotkey        := IniRead(f, "CombatReaction", "hotkey", g_crHotkey)
        g_crAnimIdsStr    := IniRead(f, "CombatReaction", "animIds", g_crAnimIdsStr)
        g_crRadius        := Integer(IniRead(f, "CombatReaction", "radius", g_crRadius))
        g_crCooldownMs    := Integer(IniRead(f, "CombatReaction", "cooldownMs", g_crCooldownMs))
        g_crAimAway       := (IniRead(f, "CombatReaction", "aimAway", g_crAimAway ? "1" : "0") = "1")
        g_crRestoreCursor := (IniRead(f, "CombatReaction", "restoreCursor", g_crRestoreCursor ? "1" : "0") = "1")
    } catch as ex {
        LogError("LoadCombatReaction", ex)
    }
    g_crRadius := Max(0, g_crRadius)
    g_crCooldownMs := Max(0, g_crCooldownMs)
    _CrRebuildAnimIds()
}

; Rebuilds the parsed id-set from the raw comma string. Cheap; called on load + edit.
_CrRebuildAnimIds()
{
    global g_crAnimIdsStr, g_crAnimIds
    g_crAnimIds := Map()
    for _, tok in StrSplit(g_crAnimIdsStr, ",", " `t")
    {
        t := Trim(tok)
        if (t != "" && IsInteger(t))
            g_crAnimIds[Integer(t)] := true
    }
}

; Persists the CombatReaction settings to [CombatReaction].
SaveCombatReaction()
{
    global g_crConfigFile, g_crEnabled, g_crHotkey, g_crAnimIdsStr
    global g_crRadius, g_crCooldownMs, g_crAimAway, g_crRestoreCursor
    f := g_crConfigFile
    try {
        IniWrite(g_crEnabled ? "1" : "0", f, "CombatReaction", "enabled")
        IniWrite(g_crHotkey, f, "CombatReaction", "hotkey")
        IniWrite(g_crAnimIdsStr, f, "CombatReaction", "animIds")
        IniWrite(g_crRadius, f, "CombatReaction", "radius")
        IniWrite(g_crCooldownMs, f, "CombatReaction", "cooldownMs")
        IniWrite(g_crAimAway ? "1" : "0", f, "CombatReaction", "aimAway")
        IniWrite(g_crRestoreCursor ? "1" : "0", f, "CombatReaction", "restoreCursor")
    } catch as ex {
        LogError("SaveCombatReaction", ex)
    }
}

; Applies one setting from the UI/bridge. Params: key, val. No return.
_CrApplySetting(key, val)
{
    global g_crEnabled, g_crHotkey, g_crAnimIdsStr, g_crRadius, g_crCooldownMs, g_crAimAway, g_crRestoreCursor
    truthy := (val = 1 || val = "1" || val = true || val = "true")
    switch key
    {
        case "enabled":       g_crEnabled := truthy
        case "hotkey":        g_crHotkey := "" val
        case "animIds":       g_crAnimIdsStr := "" val, _CrRebuildAnimIds()
        case "radius":        g_crRadius := Max(0, Integer(val))
        case "cooldownMs":    g_crCooldownMs := Max(0, Integer(val))
        case "aimAway":       g_crAimAway := truthy
        case "restoreCursor": g_crRestoreCursor := truthy
    }
}

; Builds the header JSON (settings) for the WebView push. Caller prepends the key.
BuildCombatReactionHeaderJson()
{
    global g_crEnabled, g_crHotkey, g_crAnimIdsStr, g_crRadius, g_crCooldownMs, g_crAimAway, g_crRestoreCursor
    j := "{"
    j .= '"enabled":'       (g_crEnabled ? "true" : "false")
    j .= ',"hotkey":'       _JsStr(g_crHotkey)
    j .= ',"animIds":'      _JsStr(g_crAnimIdsStr)
    j .= ',"radius":'       g_crRadius
    j .= ',"cooldownMs":'   g_crCooldownMs
    j .= ',"aimAway":'      (g_crAimAway ? "true" : "false")
    j .= ',"restoreCursor":' (g_crRestoreCursor ? "true" : "false")
    j .= "}"
    return j
}

; ── Per-tick driver ────────────────────────────────────────────────────────────

; Called every radar tick from UpdateRadarFast. Scans the awake sample for the nearest
; hostile monster within radius whose live animationId is in the danger set; on a match
; (cooldown elapsed, game focused) aims away and presses the configured key. Cheap when
; idle (in-memory scan of cached fields only). Param: radarSnap (current snapshot Map).
TryCombatReaction(radarSnap)
{
    global g_crEnabled, g_crHotkey, g_crAnimIds, g_crRadius, g_crCooldownMs, g_crLastReactTick, g_reader

    if !g_crEnabled
        return
    ; Nothing to do without a key to press or any danger ids configured.
    if (g_crHotkey = "" || g_crAnimIds.Count = 0)
        return
    if !(IsObject(radarSnap) && Type(radarSnap) = "Map")
        return
    if (A_TickCount - g_crLastReactTick < g_crCooldownMs)
        return
    if !IsStrictInGameState(radarSnap)
        return
    ; We send input, so only act while the PoE window is in the foreground.
    gameHwnd := ResolvePoEWindow()
    if !(gameHwnd && WinActive("ahk_id " gameHwnd))
        return

    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area   := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(sample && Type(sample) = "Array")
        return

    matrix := (inGs && IsObject(inGs) && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    pwx := 0, pwy := 0, pwz := 0
    prc := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if (prc && IsObject(prc) && prc.Has("worldPosition"))
    {
        pwp := prc["worldPosition"]
        pwx := pwp.Has("x") ? pwp["x"] : 0
        pwy := pwp.Has("y") ? pwp["y"] : 0
        pwz := pwp.Has("z") ? pwp["z"] : 0
    }

    ; Find the nearest hostile monster whose current animation is dangerous.
    bestDist := 1.0e9, bestX := 0, bestY := 0, bestZ := 0, found := false
    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if (path = "" || !g_reader.IsNpcLikeEntityPath(path))
            continue
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue

        ; Dangerous animation? (hot-path animationId, cached per tick)
        actor := decoded.Has("actor") ? decoded["actor"] : 0
        if !(actor && IsObject(actor) && actor.Has("animationId"))
            continue
        if !g_crAnimIds.Has(actor["animationId"])
            continue

        ; Alive + not friendly.
        lifeComp := decoded.Has("life") ? decoded["life"] : 0
        if (lifeComp && IsObject(lifeComp) && lifeComp.Has("isAlive") && !lifeComp["isAlive"])
            continue
        pos := decoded.Has("positioned") ? decoded["positioned"] : 0
        if (pos && IsObject(pos) && pos.Has("isFriendly") && pos["isFriendly"])
            continue

        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0 || dist > g_crRadius)
            continue

        if (dist < bestDist)
        {
            rc := decoded.Has("render") ? decoded["render"] : 0
            wp := (rc && IsObject(rc) && rc.Has("worldPosition")) ? rc["worldPosition"] : 0
            bestDist := dist
            bestX := (wp && IsObject(wp) && wp.Has("x")) ? wp["x"] : 0
            bestY := (wp && IsObject(wp) && wp.Has("y")) ? wp["y"] : 0
            bestZ := (wp && IsObject(wp) && wp.Has("z")) ? wp["z"] : 0
            found := true
        }
    }
    if !found
        return

    _CrReact(gameHwnd, matrix, pwx, pwy, pwz, bestX, bestY, bestZ)
    g_crLastReactTick := A_TickCount
}

; Executes the reaction: optional aim-away (project player + enemy, push the cursor to
; the opposite side of the player) then the keypress; optional cursor restore.
; Params: gameHwnd; matrix (w2s, or 0); player world x/y/z; enemy world x/y/z. No return.
_CrReact(gameHwnd, matrix, pwx, pwy, pwz, ex, ey, ez)
{
    global g_crHotkey, g_crAimAway, g_crRestoreCursor

    savedX := 0, savedY := 0, haveSaved := false
    if g_crRestoreCursor
    {
        pt := Buffer(8, 0)
        if DllCall("GetCursorPos", "ptr", pt)
        {
            savedX := NumGet(pt, 0, "Int"), savedY := NumGet(pt, 4, "Int")
            haveSaved := true
        }
    }

    if g_crAimAway
    {
        ci := Map("nearestWorldX", pwx, "nearestWorldY", pwy, "nearestWorldZ", pwz
                , "playerWorldX", pwx, "playerWorldY", pwy, "w2sMatrix", matrix)
        pScreen := _WorldToScreen(ci, gameHwnd)
        ci["nearestWorldX"] := ex, ci["nearestWorldY"] := ey, ci["nearestWorldZ"] := ez
        eScreen := _WorldToScreen(ci, gameHwnd)
        if (IsObject(pScreen) && IsObject(eScreen))
        {
            dx := pScreen["x"] - eScreen["x"]
            dy := pScreen["y"] - eScreen["y"]
            len := Sqrt(dx*dx + dy*dy)
            if (len < 1)             ; enemy projects ~onto the player: pick an arbitrary away dir
                dx := 0, dy := -1, len := 1
            DIST := 260
            tx := Round(pScreen["x"] + dx / len * DIST)
            ty := Round(pScreen["y"] + dy / len * DIST)
            rect := NavClientRect(gameHwnd)
            if IsObject(rect)
            {
                m := 8
                tx := Max(rect["x"] + m, Min(tx, rect["x"] + rect["w"] - m))
                ty := Max(rect["y"] + m, Min(ty, rect["y"] + rect["h"] - m))
            }
            DllCall("SetCursorPos", "int", tx, "int", ty)
            Sleep(8)
        }
    }

    _SendSkillKey(g_crHotkey, gameHwnd)

    if (g_crRestoreCursor && haveSaved)
    {
        Sleep(8)
        DllCall("SetCursorPos", "int", savedX, "int", savedY)
    }
}
