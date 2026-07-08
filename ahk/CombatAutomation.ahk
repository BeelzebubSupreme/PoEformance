; CombatAutomation.ahk
; Automated skill rotation engine — detects combat from entity proximity,
; reads skill cooldowns, and fires skills in priority order.
;
; Architecture:
;   - Called from UpdateRadarFast() after entity data is available
;   - Uses entity cache from radar snapshot for combat detection
;   - Reads skill cooldowns via g_reader.ReadPlayerSkills()
;   - Sends keypresses via keybd_event (Win32 API, bypasses UIPI)
;
; Included by InGameStateMonitor.ahk

; ── Combat tick (called from AutoPilot) ───────────────────────────────────
; Decides whether the player is currently engaging an enemy and fires skills
; in priority order. Returns true if combat is active this tick, false otherwise —
; AutoPilot uses the return value to decide whether to run exploration instead.
;
; AutoPilot owns the shared guard chain (window focus, town/hideout, panel-open,
; player-dead) AND the master enable check. This is a trusted callee — when
; this function is invoked, we run combat unconditionally. The previous
; g_combatAutoEnabled gate was removed when combat + exploration were unified
; under a single AutoPilot toggle.
;
; Params: radarSnap - full radar snapshot
;         gameHwnd  - resolved PoE2 window handle (must be valid + active)
; Returns: true if combat engaged this tick, false if idle
TryCombatAutomation(radarSnap, gameHwnd)
{
    static _running := false
    if _running
        return false
    _running := true
    try
    {
        global g_reader, g_combatLastReason
        global g_combatState, g_combatSkillSlots, g_combatGlobalCooldownMs
        global g_lastSkillUseTime, g_combatRange, g_combatDisengageRange
        global g_combatSkillCooldowns
        global g_radarOverlay
        global g_combatNoPathBlacklist

        ; Default: no combat path on the overlay. Each tick clears the carrier
        ; first; the LoS-blocked branch later in the function overrides it back
        ; to the freshly-computed path when relevant. This way every early-return
        ; path (idle / disengage / aiming / GCD) leaves the overlay clean
        ; instead of stranding the previous tick's polyline.
        if (g_radarOverlay)
        {
            g_radarOverlay._combatPathCoords := []
            g_radarOverlay._combatTargetGX := -1
        }

        ; Tracks how long the aim has been continuously "no-path" — used to
        ; give up on unreachable enemies instead of claiming the tick forever.
        ; Declared up here so the reset below the no-path branch can run on
        ; every tick that reaches it. _noPathExhSeen remembers whether the
        ; current no-path streak included an EXHAUSTED A* result (genuinely cut
        ; off) — that shortens the give-up from 4 s to 1.5 s.
        static _noPathSince := 0
        static _noPathExhSeen := false

        ; ── Combat detection from entity cache ────────────────────────────
        combatInfo := _DetectCombat(radarSnap)
        hostileCount := combatInfo["hostileCount"]
        nearestDist  := combatInfo["nearestDist"]   ; Euclidean

        ; ── Terrain-aware distance (replaces Euclidean for engage/disengage) ──
        ; Uses line-of-sight check (fast) and falls back to A* path length
        ; when terrain blocks the straight line.
        static _combatPF := TerrainPathfinder()
        static _pfTerrainSz := 0
        terrain := 0
        inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
        areaForTerrain := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        if (areaForTerrain && IsObject(areaForTerrain) && areaForTerrain.Has("terrain") && areaForTerrain["terrain"])
        {
            terrain := areaForTerrain["terrain"]
            tsz := terrain["dataSize"]
            if (tsz != _pfTerrainSz)
            {
                _combatPF.SetTerrain(terrain)
                _pfTerrainSz := tsz
            }
            ; Height-aware pathing (multi-level zones): shared context with
            ; exploration; only active once it passed self-validation.
            hCtx := GetTerrainHeightContext(radarSnap)
            _combatPF.SetHeights(hCtx)
        }
        else
            hCtx := 0
        hzOk := (hCtx && IsObject(hCtx) && hCtx["val"] = "ok")

        terrainDist := nearestDist
        if (hostileCount > 0 && _combatPF.HasTerrain()
            && combatInfo["playerWorldX"] != 0 && combatInfo["nearestWorldX"] != 0)
        {
            td := _CachedTerrainDistance(_combatPF,
                combatInfo["playerWorldX"], combatInfo["playerWorldY"],
                combatInfo["nearestWorldX"], combatInfo["nearestWorldY"])
            if (td >= 0)
                terrainDist := td
        }
        combatInfo["terrainDist"] := terrainDist

        ; State machine: idle ↔ combat (uses terrain-aware distance).
        ; Proximity override: an enemy within CLOSE_RANGE Euclidean MUST
        ; engage no matter what the terrain estimate says — height noise
        ; near walls can kill LoS / inflate path lengths for an enemy
        ; standing right next to the character, which previously left the
        ; bot strolling through packs in explore mode.
        static CLOSE_RANGE := 300
        prevState := g_combatState
        if (g_combatState = "idle")
        {
            if (hostileCount > 0 && (nearestDist <= CLOSE_RANGE || terrainDist <= g_combatRange))
            {
                g_combatState := "combat"
            }
        }
        else if (g_combatState = "combat")
        {
            if (hostileCount = 0
                || (terrainDist > g_combatDisengageRange && nearestDist > CLOSE_RANGE))
            {
                g_combatState := "idle"
                g_combatLastReason := "disengage(dist=" Round(terrainDist) " n=" hostileCount ")"
                return false
            }
        }

        if (g_combatState != "combat")
        {
            ; No enemy in range — terrainDist is the 999999 sentinel, which
            ; reads like a bug in the overlay. Show "d=-" when there is
            ; nothing to measure distance to.
            distStr := (hostileCount > 0) ? Round(terrainDist) : "-"
            g_combatLastReason := "idle(n=" hostileCount " d=" distStr ")"
            return false
        }

        ; Publish the engaged enemy as the combat target marker on the radar
        ; (red ring + crosshair, drawn next to the red combat path polyline).
        if (g_radarOverlay && combatInfo["nearestWorldX"] != 0)
        {
            g_radarOverlay._combatTargetGX := Round(combatInfo["nearestWorldX"] / TerrainPathfinder.WORLD_TO_GRID_RATIO)
            g_radarOverlay._combatTargetGY := Round(combatInfo["nearestWorldY"] / TerrainPathfinder.WORLD_TO_GRID_RATIO)
        }

        ; ── Continuous-engagement watchdog (fixes the multi-tens-of-seconds hang) ──
        ; The per-target no-path give-up resets whenever a DIFFERENT packmate
        ; becomes the nearest enemy, so a mixed pack with off-floor / unreachable
        ; members (hd~90) could hold the combat tick for 30 s+ while exploration
        ; stayed frozen (observed: 34 s at one explore waypoint). This global cap
        ; starts a timer when combat is first entered and RESETS it on real
        ; progress (any drop in hostileCount = a kill / a mob leaving range). If
        ; combat holds the tick for MAX_ENGAGE_MS with NO progress AND it is a
        ; pack (>= 3 hostiles — solo rares/bosses are legitimately slow and must
        ; NOT be abandoned), blacklist the whole hostile cluster and yield to
        ; exploration. The lone-straggler case is already covered by the
        ; per-target no-path give-up above.
        static MAX_ENGAGE_MS := 28000
        static _engageStart := 0
        static _engageMinHostiles := 999999
        if (prevState = "idle")            ; just transitioned idle → combat this tick
        {
            _engageStart := A_TickCount
            _engageMinHostiles := hostileCount
        }
        if (hostileCount < _engageMinHostiles)   ; progress — a hostile died / left range
        {
            _engageMinHostiles := hostileCount
            _engageStart := A_TickCount
        }
        if (_engageStart && hostileCount >= 3 && (A_TickCount - _engageStart) > MAX_ENGAGE_MS)
        {
            blN := _CombatBlacklistPackNear(radarSnap
                , combatInfo["nearestWorldX"], combatInfo["nearestWorldY"], 1600, 25000)
            g_combatState := "idle"
            _engageStart := 0
            _engageMinHostiles := 999999
            g_combatLastReason := "engage-timeout(" MAX_ENGAGE_MS "ms n=" hostileCount " bl=" blN ")"
            return false
        }

        ; ── Camera anchor (shared projection sanity gate, see ClickNav) ───
        ; The player's own projection anchors the w-sign convention AND must
        ; land near the screen centre. Without it a far waypoint/enemy that
        ; sits behind the camera plane gets point-MIRRORED by the divide and
        ; the move-click walks the character in exactly the wrong direction
        ; (the "runs away from the enemy in stutter steps" bug).
        navRect := NavClientRect(gameHwnd)
        mat0 := combatInfo["w2sMatrix"]
        ; MANDATORY projection gate (issue #158). This gate USED to be conditional — it only ran
        ; NavAnchor when the matrix/rect/player were present, and otherwise fell through. With no
        ; matrix the code then reached _WorldToScreen's screen-CENTRE isometric approximation and
        ; the grace-fire path blind-spammed skills at the middle of the screen, un-aimed. Never do
        ; that: if we cannot project properly we hold the engagement but click/fire NOTHING. The
        ; reason string reports exactly which input is missing so the Debug Overlay localizes it.
        if !(navRect && IsObject(mat0) && Type(mat0) = "Array" && mat0.Length = 16
            && combatInfo["playerWorldX"] != 0)
        {
            g_combatLastReason := "cam-bad(no-proj rect=" (navRect ? 1 : 0)
                . " matLen=" (IsObject(mat0) ? mat0.Length : 0)
                . " pwx=" Round(combatInfo["playerWorldX"]) ")"
            return true   ; engaged but cannot aim — do NOT fall back to a screen-centre guess
        }
        camAnchor := NavAnchor(combatInfo["playerWorldX"], combatInfo["playerWorldY"]
            , combatInfo["playerWorldZ"], mat0, navRect)
        if !camAnchor["ok"]
        {
            g_combatLastReason := "cam-bad(" camAnchor["why"] ")"
            return true   ; engaged — skip the tick rather than click blind
        }

        ; ── Aim selection (LoS-aware) ──────────────────────────────────────
        ; Three possible aim modes:
        ;   "direct" — straight LoS from player to enemy. Cursor lands on the
        ;              enemy; we wait for isTargetedByPlayer and fire skills.
        ;   "walk"   — LoS blocked. Cursor lands a short way along the fresh
        ;              A* path (recomputed from the current player position
        ;              every tick); we issue an LMB (move command) only —
        ;              NO skill keys. The character walks until LoS opens,
        ;              then a later tick flips into "direct".
        ;   "no-path"— LoS blocked AND no traversable A* path. Nothing safe
        ;              to do; surface a status and idle this tick.
        WORLD_TO_GRID := 250.0 / 0x17
        aimWorldX := combatInfo["nearestWorldX"]
        aimWorldY := combatInfo["nearestWorldY"]
        aimWorldZ := combatInfo["nearestWorldZ"]
        aimMode   := "direct"
        aimTag    := "direct"

        ; Path-overlay carrier — written into g_radarOverlay so the radar can
        ; draw the route as a polyline. Empty by default and cleared explicitly
        ; below for the direct-LoS / no-path branches so the overlay never
        ; lingers on a stale path from a previous tick.
        combatPath := []

        ; CLOSE_RANGE enemies are aimed at directly without any LoS/path
        ; gating — they are visibly next to the character; terrain-height
        ; noise must not talk us out of fighting them.
        enemyHd := 0
        if (nearestDist > CLOSE_RANGE
            && _combatPF.HasTerrain()
            && combatInfo["playerWorldX"] != 0 && combatInfo["nearestWorldX"] != 0)
        {
            pGX := Round(combatInfo["playerWorldX"] / WORLD_TO_GRID)
            pGY := Round(combatInfo["playerWorldY"] / WORLD_TO_GRID)
            eGX := Round(combatInfo["nearestWorldX"] / WORLD_TO_GRID)
            eGY := Round(combatInfo["nearestWorldY"] / WORLD_TO_GRID)

            ; Enemy height delta vs the player. Cross-floor enemies are
            ; unreachable by click-to-move — blacklist immediately instead of
            ; burning the 4 s no-path timer (mirrors the exploration floor
            ; gate that finally made scouting work on multi-level zones).
            enemyHd := hzOk ? Round(TerrainHeightAt(hCtx, eGX, eGY) - combatInfo["playerWorldZ"]) : 0
            if (hzOk && Abs(enemyHd) > 200)
            {
                ; Pack-wide: its packmates stand on the same unreachable floor, so
                ; blacklisting one at a time just re-targets the neighbour next tick.
                blN := _CombatBlacklistPackNear(radarSnap
                    , combatInfo["nearestWorldX"], combatInfo["nearestWorldY"], 700, 30000)
                blAddr := combatInfo["nearestEntityAddr"]
                if (blAddr && IsSet(g_combatNoPathBlacklist))
                    g_combatNoPathBlacklist[blAddr] := A_TickCount + 30000
                g_combatState := "idle"
                g_combatLastReason := "off-floor(hd=" enemyHd " d=" Round(terrainDist) " bl=" blN ")"
                return false
            }

            if (!_combatPF.HasLineOfSight(pGX, pGY, eGX, eGY)
                && !(hzOk && _combatPF.HasLineOfSight(pGX, pGY, eGX, eGY, true)))
            {
                ; Truly wall-blocked (the second test ignores the height rule:
                ; a height-consistent enemy whose LoS only failed on height
                ; NOISE is aimed at directly instead of dropping to no-path —
                ; that noise was why combat "never found a path" to enemies
                ; standing on the same floor).
                ; Find a path and aim a short way along it. FindPath runs
                ; fresh from the CURRENT player position every tick, so the
                ; direction can never be stale. The aim point sits ~25 cells
                ; ahead (a click-to-move command — the game handles corners
                ; itself) and is projected with the PLAYER's Z: the old code
                ; aimed at the farthest LoS waypoint with the ENEMY's Z, and
                ; far waypoints behind the camera plane mirrored the click to
                ; the opposite screen edge (bot walked AWAY from the enemy).
                path := _combatPF.FindPath(pGX, pGY, eGX, eGY)
                if (path && Type(path) = "Array" && path.Length >= 2)
                {
                    aimPt := NavPointAlongPath(path, 25)
                    if (aimPt)
                    {
                        aimWorldX := aimPt[1] * WORLD_TO_GRID
                        aimWorldY := aimPt[2] * WORLD_TO_GRID
                        aimWorldZ := combatInfo["playerWorldZ"]
                        aimMode := "walk"
                        aimTag  := "walk(" path.Length "wp)"
                    }
                    else
                    {
                        aimMode := "no-path"
                        aimTag  := "path-degenerate"
                    }
                    ; Expose the full path for the radar overlay regardless of
                    ; which point we ended up aiming at — the user wants to
                    ; see the route the bot considered, not just the next hop.
                    combatPath := path
                }
                else
                {
                    ; Distinguish "search space exhausted" (genuinely cut off)
                    ; from "A* budget timeout" (far/expensive) in the status.
                    aimMode := "no-path"
                    aimTag  := "no-path:" (_combatPF.LastFailExhausted ? "exh" : "tmo")
                }
            }
        }

        ; Push the path (or empty array, when direct-LoS) onto the radar overlay
        ; so it can render the polyline on the next frame. The overlay was cleared
        ; at function entry, so direct-LoS cases (combatPath stays []) leave nothing.
        if (g_radarOverlay)
            g_radarOverlay._combatPathCoords := combatPath

        ; ── No-path branch ───────────────────────────────────────────────
        ; Enemy detected but no traversable route exists. Don't move the
        ; cursor (would just spam an unreachable corner) and don't fire
        ; skills (no LoS = wasted cooldown). Stay in "combat" state briefly —
        ; the enemy may come to us or a future tick may re-find the path.
        ; BUT: a genuinely unreachable enemy (across a chasm, behind sealed
        ; geometry) used to freeze the whole AutoPilot here forever, and the
        ; old give-up (ONE entity, 15 s) chained on packs: the next packmate
        ; became the nearest and burned its own 4 s, and by pack member #4 the
        ; first blacklist had already expired — the owner's status log showed
        ; a 17-strong ledge pack (hd=88) occupying combat for minutes. Now the
        ; give-up (a) fires after 1.5 s once A* reported the search space
        ; EXHAUSTED (genuinely cut off — waiting longer can't help; budget
        ; timeouts keep the patient 4 s), and (b) blacklists the WHOLE pack
        ; around the unreachable enemy for 30 s.
        if (aimMode = "no-path")
        {
            if InStr(aimTag, "exh")
                _noPathExhSeen := true
            if (_noPathSince = 0)
                _noPathSince := A_TickCount
            else if ((A_TickCount - _noPathSince) > (_noPathExhSeen ? 1500 : 4000))
            {
                blN := _CombatBlacklistPackNear(radarSnap
                    , combatInfo["nearestWorldX"], combatInfo["nearestWorldY"], 700, 30000)
                blAddr := combatInfo["nearestEntityAddr"]
                if (blAddr && IsSet(g_combatNoPathBlacklist))
                    g_combatNoPathBlacklist[blAddr] := A_TickCount + 30000
                g_combatState := "idle"
                _noPathSince := 0
                _noPathExhSeen := false
                g_combatLastReason := "no-path-giveup(d=" Round(terrainDist) " n=" hostileCount
                    . " hd=" enemyHd " bl=" blN ")"
                return false
            }
            g_combatLastReason := "no-path(d=" Round(terrainDist) " n=" hostileCount
                . " hd=" enemyHd " " aimTag ")"
            return true
        }
        _noPathSince := 0   ; any reachable aim resets the give-up timer
        _noPathExhSeen := false

        ; ── Move mouse toward aim point ────────────────────────────────────
        ; Build a thin info Map carrying just the projection-relevant fields so
        ; _WorldToScreen can stay agnostic to whether we're aiming at the enemy
        ; or at an A* waypoint.
        aimInfo := Map(
            "nearestWorldX", aimWorldX,
            "nearestWorldY", aimWorldY,
            "nearestWorldZ", aimWorldZ,
            "w2sMatrix",     combatInfo["w2sMatrix"],
            "playerWorldX",  combatInfo["playerWorldX"],
            "playerWorldY",  combatInfo["playerWorldY"]
        )
        targetScreenPos := _WorldToScreen(aimInfo, gameHwnd, camAnchor)
        if !targetScreenPos
        {
            g_combatLastReason := "no-screen-pos"
                . " aim=" aimTag
                . " pw=" Round(combatInfo["playerWorldX"]) "," Round(combatInfo["playerWorldY"])
                . " ew=" Round(combatInfo["nearestWorldX"]) "," Round(combatInfo["nearestWorldY"])
            return true   ; still engaged, just can't project this tick
        }

        ; ── Avoid-zone guard ─────────────────────────────────────────────
        ; If the projected screen position lands on a HUD element, minimap,
        ; or an interactable world entity (transition / portal / waypoint /
        ; NPC), DO NOT move the cursor there. Clicking those would either
        ; be swallowed by the UI or trigger a zone change / dialog that
        ; ends the combat tick badly. Skip the tick — next frame's
        ; projection geometry usually shifts the aim off the obstacle.
        avoidRects := GetAvoidZones(radarSnap, gameHwnd)
        if IsPointInAvoidZone(targetScreenPos["x"], targetScreenPos["y"], avoidRects)
        {
            g_combatLastReason := "avoid-zone(" targetScreenPos["x"] "," targetScreenPos["y"] " aim=" aimTag ")"
            return true   ; engaged, just skipping the click this tick
        }

        _MoveMouseToTarget(targetScreenPos)
        mat := combatInfo["w2sMatrix"]
        matTag := (mat && Type(mat) = "Array" && mat.Length = 16) ? "mat" : "approx"
        distTag := (terrainDist != nearestDist) ? " td=" Round(terrainDist) : ""
        g_combatLastReason := matTag "→" targetScreenPos["x"] "," targetScreenPos["y"]
            . " aim=" aimTag
            . " pw=" Round(combatInfo["playerWorldX"]) "," Round(combatInfo["playerWorldY"])
            . " ew=" Round(combatInfo["nearestWorldX"]) "," Round(combatInfo["nearestWorldY"])
            . distTag

        ; ── Walk-to-engage branch ─────────────────────────────────────────
        ; LoS blocked → cursor is on a path waypoint, not the enemy. Fire an
        ; LMB (move command) instead of any skill key. Throttled to avoid
        ; spamming click events. Skills resume the moment a future tick
        ; finds direct LoS and flips aimMode back to "direct".
        if (aimMode = "walk")
        {
            static _walkClickTick := 0
            now := A_TickCount
            ; Give up on a reachable-but-unwalkable enemy instead of clicking forever.
            if (_CombatMoveStuckGiveUp(now, radarSnap, combatInfo, aimTag))
                return false
            if ((now - _walkClickTick) > 250)
            {
                DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LDOWN
                Sleep(20)
                DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LUP
                _walkClickTick := now
            }
            g_combatLastReason := "walk-engage(d=" Round(terrainDist) " " aimTag ")"
            return true   ; engaged — block exploration; skills come back when LoS opens
        }

        ; ── Confirm cursor is on target (isTargetedByPlayer) ──────────────
        ; Only fire skills once the game confirms our cursor is on the enemy.
        ; Grace period: if not targeted within 1500ms, fire anyway — projection
        ; may be slightly off but close enough. Was 500ms before; bumped up
        ; because that wasn't enough on slower machines / higher latency to
        ; let the game's mouse-pick raycast settle on the target.
        static _aimStartTick := 0
        tgtAddr := combatInfo["nearestTargetableAddr"]
        isTargeted := false
        if (tgtAddr && g_reader.IsProbablyValidPointer(tgtAddr))
        {
            try
                isTargeted := g_reader.Mem.ReadUChar(tgtAddr + PoE2Offsets.Targetable["IsTargetedByPlayer"]) = 1
        }
        if (!isTargeted)
        {
            if (_aimStartTick = 0)
                _aimStartTick := A_TickCount
            aimElapsed := A_TickCount - _aimStartTick
            if (aimElapsed < 1500)
            {
                g_combatLastReason := "aiming(" aimElapsed "ms)"
                return true   ; still in combat — block exploration
            }
            ; Grace period expired — fire anyway
        }
        else
            _aimStartTick := 0

        ; ── Global cooldown check ─────────────────────────────────────────
        now := A_TickCount
        if (now - g_lastSkillUseTime < g_combatGlobalCooldownMs)
        {
            g_combatLastReason := "gcd(" (g_combatGlobalCooldownMs - (now - g_lastSkillUseTime)) "ms)"
            return true   ; still in combat — block exploration
        }

        ; ── Read skill cooldowns ──────────────────────────────────────────
        ; Use cached skill data, refresh every 200ms
        static _skillCache := 0
        static _skillCacheTick := 0
        if (!_skillCache || (now - _skillCacheTick) > 200)
        {
            inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
            area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
            localPlayerPtr := (area && IsObject(area) && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
            if localPlayerPtr
            {
                try _skillCache := g_reader.ReadPlayerSkills(localPlayerPtr)
                catch
                    _skillCache := 0
            }
            _skillCacheTick := now
        }

        if !_skillCache
        {
            g_combatLastReason := "no-skill-data"
            return true   ; still in combat — block exploration
        }

        ; ── Store cooldown state for UI ───────────────────────────────────
        skills := _skillCache.Has("skills") ? _skillCache["skills"] : []
        _UpdateCooldownState(skills)

        ; ── Auto-detect skill ranges from game data ───────────────────────
        ; When a slot matches a skill by name, infer range from castType if
        ; the user hasn't set one manually (skillRange = 0).
        _AutoPopulateSkillRanges(skills)

        ; ── Select and execute next skill ─────────────────────────────────
        selResult := _SelectNextSkill(skills, combatInfo)
        selectedSlot := selResult["slot"]
        if (selectedSlot)
        {
            slotCfg := g_combatSkillSlots[selectedSlot]
            sendKey := _CombatResolveSlotKey(slotCfg)

            if _SendSkillKey(sendKey, gameHwnd)
            {
                g_lastSkillUseTime := now
                slotCfg["lastUseTick"] := now
                g_combatLastReason := "cast-slot" selectedSlot "(" slotCfg["name"] " key=" sendKey " n=" hostileCount ")"
            }
            else
            {
                g_combatLastReason := "send-failed-slot" selectedSlot
            }
        }
        else if (selResult["outOfRange"])
        {
            ; Give up if we've been approaching an unreachable enemy without moving.
            if (_CombatMoveStuckGiveUp(now, radarSnap, combatInfo, "approach"))
                return false
            ; Direct LoS but every ready skill is out of range. Previously
            ; this branch only set a status ("approaching") without ever
            ; moving — the bot parked the cursor on the enemy and stood
            ; still until the mob happened to walk over. Now we issue a
            ; throttled move-click at a point ~60% toward the enemy so the
            ; character actually closes the gap; skills fire on a later
            ; tick once the distance drops below the slot range.
            static _approachClickTick := 0
            if ((now - _approachClickTick) > 300)
            {
                apX := combatInfo["playerWorldX"] + (combatInfo["nearestWorldX"] - combatInfo["playerWorldX"]) * 0.6
                apY := combatInfo["playerWorldY"] + (combatInfo["nearestWorldY"] - combatInfo["playerWorldY"]) * 0.6
                apInfo := Map(
                    "nearestWorldX", apX,
                    "nearestWorldY", apY,
                    "nearestWorldZ", combatInfo["nearestWorldZ"],
                    "w2sMatrix",     combatInfo["w2sMatrix"],
                    "playerWorldX",  combatInfo["playerWorldX"],
                    "playerWorldY",  combatInfo["playerWorldY"]
                )
                apPos := _WorldToScreen(apInfo, gameHwnd, camAnchor)
                if (apPos && !IsPointInAvoidZone(apPos["x"], apPos["y"], avoidRects))
                {
                    DllCall("SetCursorPos", "int", apPos["x"], "int", apPos["y"])
                    Sleep(20)
                    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LDOWN
                    Sleep(20)
                    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LUP
                    _approachClickTick := now
                }
            }
            g_combatLastReason := "approaching(d=" Round(nearestDist) ")"
        }
        else
        {
            g_combatLastReason := "no-ready-skill(n=" hostileCount " d=" Round(nearestDist) ")"
        }

        ; Fell through skill firing while g_combatState == "combat" — still engaged.
        return true
    }
    catch as ex
    {
        ; Surface the crash in the debug overlay — a swallowed exception
        ; leaves g_combatLastReason frozen on its last (stale) value while
        ; g_combatState may still be "combat", which silently pauses
        ; exploration ("combat-pause" with an idle-looking combat line).
        LogError("TryCombatAutomation", ex)
        try g_combatLastReason := "error(" ex.Message " @" ex.Line ")"
        return false
    }
    finally
    {
        _running := false
    }
}

; ── Combat Detection ──────────────────────────────────────────────────────
; Scans entity cache for hostile, alive, targetable monsters within range.
; Returns: Map with hostileCount, nearestDist, nearestPath
; Lightweight, always-available combat-presence check. Mirrors the bot's
; idle<->combat state machine but uses cheap Euclidean distance (no terrain
; pathfinding) so it can run every tick when the AutoPilot bot is off. Reuses
; the same g_combatRange / g_combatDisengageRange tuning for engage/disengage
; hysteresis and updates the shared g_combatState. No return value.
UpdateCombatPresence(radarSnap)
{
    global g_combatState, g_combatRange, g_combatDisengageRange
    info := _DetectCombat(radarSnap)
    n := info["hostileCount"]
    d := info["nearestDist"]   ; Euclidean (terrain distance is bot-only)
    if (g_combatState = "combat")
    {
        if (n = 0 || d > g_combatDisengageRange)
            g_combatState := "idle"
    }
    else
    {
        if (n > 0 && d <= g_combatRange)
            g_combatState := "combat"
    }
}

_DetectCombat(radarSnap)
{
    global g_combatRange, g_reader, g_combatNoPathBlacklist

    result := Map("hostileCount", 0, "nearestDist", 999999, "nearestPath", ""
        , "nearestWorldX", 0, "nearestWorldY", 0, "nearestWorldZ", 0
        , "playerWorldX", 0, "playerWorldY", 0, "playerWorldZ", 0
        , "nearestTargetableAddr", 0, "nearestEntityAddr", 0, "w2sMatrix", [])

    ; Unreachable-enemy blacklist (filled by the no-path give-up in
    ; TryCombatAutomation). Expired entries are pruned lazily on lookup.
    blacklist := IsSet(g_combatNoPathBlacklist) ? g_combatNoPathBlacklist : 0

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []

    ; Extract WorldToScreen matrix from inGameState
    if (inGs && IsObject(inGs) && inGs.Has("w2sMatrix"))
        result["w2sMatrix"] := inGs["w2sMatrix"]

    ; Extract player world position for screen projection
    prc := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if (prc && IsObject(prc) && prc.Has("worldPosition"))
    {
        pwp := prc["worldPosition"]
        result["playerWorldX"] := pwp.Has("x") ? pwp["x"] : 0
        result["playerWorldY"] := pwp.Has("y") ? pwp["y"] : 0
        result["playerWorldZ"] := pwp.Has("z") ? pwp["z"] : 0
    }

    hostileCount := 0
    nearestDist := 999999.0

    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue

        ; Must have entity basic data
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue

        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue

        ; Only monsters/characters (not player, not attachments)
        if !g_reader.IsNpcLikeEntityPath(path)
            continue

        ; Skip enemies we recently gave up on (no traversable path) so the
        ; idle→combat state machine doesn't immediately re-engage them.
        entityAddr := entity.Has("address") ? entity["address"] : 0
        if (blacklist && entityAddr && blacklist.Has(entityAddr))
        {
            if (A_TickCount < blacklist[entityAddr])
                continue
            blacklist.Delete(entityAddr)
        }

        ; Check decoded components for alive + targetable + hostile
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue

        ; Must be targetable (alive monsters are targetable; dead ones are not)
        ; Radar mode stores targetable as a bare boolean; full mode as a Map with isTargetable key.
        tgt := decoded.Has("targetable") ? decoded["targetable"] : 0
        if IsObject(tgt)
            isTargetable := (tgt.Has("isTargetable") && tgt["isTargetable"])
        else
            isTargetable := tgt ? true : false
        if !isTargetable
            continue

        ; Also check life component — dead entities have curHP <= 0 or isAlive = false
        lifeComp := decoded.Has("life") ? decoded["life"] : 0
        if (lifeComp && IsObject(lifeComp) && lifeComp.Has("isAlive") && !lifeComp["isAlive"])
            continue

        ; Live re-read of Targetable byte to catch recently-dead entities whose
        ; cached targetable status is stale (round-robin hasn't reached them yet).
        comps := entity.Has("components") ? entity["components"] : 0
        if (comps && Type(comps) = "Array")
        {
            liveTargetable := false
            for _, comp in comps
            {
                if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                    continue
                if (InStr(comp["name"], "Targetable"))
                {
                    tgtAddr := comp["address"]
                    if (tgtAddr && g_reader.IsProbablyValidPointer(tgtAddr))
                    {
                        raw := g_reader.Mem.ReadUChar(tgtAddr + PoE2Offsets.Targetable["IsTargetable"])
                        liveTargetable := (raw = 1)
                    }
                    break
                }
            }
            if !liveTargetable
                continue
        }

        ; Must NOT be friendly
        pos := decoded.Has("positioned") ? decoded["positioned"] : 0
        if (pos && IsObject(pos) && pos.Has("isFriendly") && pos["isFriendly"])
            continue

        ; Check distance
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0)
            continue

        hostileCount += 1
        if (dist < nearestDist)
        {
            nearestDist := dist
            result["nearestPath"] := path
            result["nearestEntityAddr"] := entityAddr

            ; Store Targetable component address for live isTargetedByPlayer check
            if (comps && Type(comps) = "Array")
            {
                for _, comp in comps
                {
                    if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                        continue
                    if (InStr(comp["name"], "Targetable"))
                    {
                        result["nearestTargetableAddr"] := comp["address"]
                        break
                    }
                }
            }

            ; Capture world position for mouse targeting
            render := decoded.Has("render") ? decoded["render"] : 0
            if (render && IsObject(render) && render.Has("worldPosition"))
            {
                ewp := render["worldPosition"]
                result["nearestWorldX"] := ewp.Has("x") ? ewp["x"] : 0
                result["nearestWorldY"] := ewp.Has("y") ? ewp["y"] : 0
                result["nearestWorldZ"] := ewp.Has("z") ? ewp["z"] : 0
            }
        }
    }

    result["hostileCount"] := hostileCount
    result["nearestDist"] := nearestDist
    return result
}

; Blacklists every NPC-like entity in the radar sample within `radius` world
; units of (cx, cy) for `ms` milliseconds. Used by the no-path / off-floor
; give-ups so an unreachable PACK is skipped as one unit — its members stand
; together, so blacklisting one at a time just re-targets the neighbour and
; chains the give-up timer across the whole pack. Returns the count blacklisted.
_CombatBlacklistPackNear(radarSnap, cx, cy, radius, ms)
{
    global g_reader, g_combatNoPathBlacklist
    if !(IsSet(g_combatNoPathBlacklist) && cx != 0)
        return 0
    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area   := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if !(sample && Type(sample) = "Array")
        return 0
    expiry := A_TickCount + ms
    r2 := radius * radius
    n := 0
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
        addr := entity.Has("address") ? entity["address"] : 0
        if !addr
            continue
        ; Position from the decoded render component; entities without one
        ; can't be distance-tested — leave them to the normal give-up.
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        render  := (decoded && IsObject(decoded) && decoded.Has("render")) ? decoded["render"] : 0
        if !(render && IsObject(render) && render.Has("worldPosition"))
            continue
        wp := render["worldPosition"]
        dx := (wp.Has("x") ? wp["x"] : 0) - cx
        dy := (wp.Has("y") ? wp["y"] : 0) - cy
        if (dx * dx + dy * dy > r2)
            continue
        g_combatNoPathBlacklist[addr] := expiry
        n += 1
    }
    return n
}

; ── Move-progress watchdog (walk-engage / approach) ────────────────────────
; The no-path give-up only covers enemies with NO A* route at all. A REACHABLE
; enemy the character still can't walk to (invisible collision, a mob circling
; just out of reach, a doorway it can't squeeze through) leaves combat issuing
; move-clicks forever with the character pinned in place — the single biggest
; "gets stuck all the time" source. This watchdog tracks the player's grid
; position while combat is walking/approaching; if it hasn't moved for
; MOVE_STUCK_MS of CONTINUOUS walking, it blacklists the pack (like the no-path
; give-up) and disengages so loot/explore can run.
; Params: now (A_TickCount), radarSnap, combatInfo, aimTag (status label).
; Returns true if it gave up (the caller must then return false), else false.
_CombatMoveStuckGiveUp(now, radarSnap, combatInfo, aimTag)
{
    global g_combatState, g_combatLastReason, g_combatNoPathBlacklist
    static MOVE_STUCK_MS := 3500     ; continuous no-move-while-walking before give-up
    static MOVE_CELLS    := 3        ; grid cells that count as "actually moved"
    static _mpGX := -999999, _mpGY := -999999, _mpBaseTick := 0, _mpLastCall := 0
    WGRID := 250.0 / 0x17
    pgx := Round(combatInfo["playerWorldX"] / WGRID)
    pgy := Round(combatInfo["playerWorldY"] / WGRID)

    ; Re-baseline whenever we RE-ENTER a move state after a gap (last tick was
    ; direct-fire / idle / another mode). The timer must only measure time spent
    ; CONTINUOUSLY trying to walk without progress, never carry over standing
    ; time from an unrelated combat phase.
    if (_mpLastCall = 0 || (now - _mpLastCall) > 600)
    {
        _mpGX := pgx, _mpGY := pgy, _mpBaseTick := now, _mpLastCall := now
        return false
    }
    _mpLastCall := now

    ; Meaningful movement resets the watchdog — a reachable enemy keeps the
    ; player moving toward it, so this only fires on a genuine pin.
    if (Abs(pgx - _mpGX) >= MOVE_CELLS || Abs(pgy - _mpGY) >= MOVE_CELLS)
    {
        _mpGX := pgx, _mpGY := pgy, _mpBaseTick := now
        return false
    }
    if ((now - _mpBaseTick) <= MOVE_STUCK_MS)
        return false

    ; Stuck: the enemy is effectively unreachable. Blacklist its pack and
    ; disengage so the rest of the AutoPilot chain can proceed.
    blN := _CombatBlacklistPackNear(radarSnap
        , combatInfo["nearestWorldX"], combatInfo["nearestWorldY"], 700, 30000)
    blAddr := combatInfo.Has("nearestEntityAddr") ? combatInfo["nearestEntityAddr"] : 0
    if (blAddr && IsSet(g_combatNoPathBlacklist))
        g_combatNoPathBlacklist[blAddr] := A_TickCount + 30000
    g_combatState := "idle"
    _mpGX := -999999, _mpGY := -999999, _mpBaseTick := 0, _mpLastCall := 0
    g_combatLastReason := "move-stuck(" aimTag " bl=" blN ")"
    return true
}

; ── Skill Selection ───────────────────────────────────────────────────────
; Resolves the actual send key for a combat slot. Prefers the LIVE skill-bar key
; for the slot's configured skill name (so the in-game keybind is always honored,
; even after a rebind), falling back to the manually-entered key. Param: slotCfg -
; the slot config Map. Returns the send-key string.
_CombatResolveSlotKey(slotCfg)
{
    global g_skillKeyBySkillName
    nm := slotCfg.Has("skillName") ? slotCfg["skillName"] : ""
    if (nm != "" && IsSet(g_skillKeyBySkillName) && g_skillKeyBySkillName is Map
        && g_skillKeyBySkillName.Has(StrLower(nm)))
        return g_skillKeyBySkillName[StrLower(nm)]
    return slotCfg.Has("key") ? slotCfg["key"] : ""
}

; Picks the highest-priority skill that is off cooldown and ready to use.
; Returns: Map("slot", N, "outOfRange", bool) — slot=0 if nothing ready
_SelectNextSkill(skills, combatInfo)
{
    global g_combatSkillSlots, g_combatSkillCooldowns
    static _rotCursor := 0   ; slotNum last fired — the round-robin advances past it

    ready := []              ; slot numbers that passed ALL gates this tick
    readyPrio := Map()       ; slotNum → priority (for the sort below)
    anyOutOfRange := false

    for slotNum, slotCfg in g_combatSkillSlots
    {
        if !(slotCfg["enabled"])
            continue

        key := slotCfg["key"]
        if (key = "")
            continue

        priority := slotCfg["priority"]
        skillName := slotCfg["skillName"]
        slotType := slotCfg["type"]
        skillRange := slotCfg.Has("skillRange") ? slotCfg["skillRange"] : 0

        ; Check per-slot cooldown
        now := A_TickCount
        lastUse := slotCfg.Has("lastUseTick") ? slotCfg["lastUseTick"] : 0
        slotCdMs := slotCfg.Has("cooldownMs") ? slotCfg["cooldownMs"] : 0
        if (slotCdMs > 0 && (now - lastUse) < slotCdMs)
            continue

        ; Match skill by name to check game cooldown state
        if (skillName != "")
        {
            skillReady := false
            nameMatched := false
            for _, skill in skills
            {
                sName := skill.Has("name") ? skill["name"] : ""
                sDisplay := skill.Has("displayName") ? skill["displayName"] : ""
                if (sName = skillName || sDisplay = skillName)
                {
                    nameMatched := true
                    canUse := skill.Has("canUse") ? skill["canUse"] : true
                    if canUse
                        skillReady := true
                    break
                }
            }
            ; Skip only when the name actually matched a skill AND that skill
            ; is on cooldown. A configured name that matches nothing in
            ; memory (typo, display-name vs internal-name mismatch, renamed
            ; gem) used to silently disable the slot forever — fire it by
            ; key instead and let the per-slot cooldown throttle it.
            if (nameMatched && !skillReady)
                continue
        }

        ; Type-based logic
        nearestDist := combatInfo.Has("terrainDist") ? combatInfo["terrainDist"] : combatInfo["nearestDist"]
        hostileCount := combatInfo["hostileCount"]

        ; "buff" type: only use when not recently used (long cooldown handled by slotCdMs)
        ; "aoe" type: prefer when multiple enemies nearby
        ; "single" type: default single-target
        if (slotType = "aoe" && hostileCount < 2)
            continue

        ; Range check: skillRange > 0 means limited range, 0 = unlimited
        if (skillRange > 0 && nearestDist > skillRange)
        {
            anyOutOfRange := true
            continue
        }

        ; Passed every gate — eligible to fire this tick.
        ready.Push(slotNum)
        readyPrio[slotNum] := priority
    }

    if (ready.Length = 0)
        return Map("slot", 0, "outOfRange", anyOutOfRange)

    ; Order the ready slots by priority (asc), slot number (asc) as a stable
    ; tiebreak. Insertion sort — the list is ≤ 8 entries.
    i := 2
    while (i <= ready.Length)
    {
        j := i
        while (j > 1)
        {
            a := ready[j - 1], b := ready[j]
            if (readyPrio[a] < readyPrio[b] || (readyPrio[a] = readyPrio[b] && a < b))
                break
            ready[j - 1] := b, ready[j] := a
            j--
        }
        i++
    }

    ; ── Rotation cursor ──────────────────────────────────────────────────
    ; The old selector always returned the SINGLE lowest-priority ready slot,
    ; so one skill monopolised casting and the others rarely fired ("rotation
    ; isn't the best"). Instead advance a round-robin cursor through the ready
    ; slots in priority order: after firing a slot, the next cast picks the
    ; next ready slot (wrapping), so every enabled+ready skill takes its turn.
    ; Per-slot cooldownMs still paces how often each re-enters the ready set,
    ; and priority still orders the cycle (a permanently-ready main skill fires
    ; once per lap). The cursor tracks a slot NUMBER, so it survives the ready
    ; set changing between ticks; when the last-fired slot isn't ready, the
    ; cycle restarts from the highest-priority ready slot.
    startIdx := 0
    for idx, s in ready
    {
        if (s = _rotCursor)
        {
            startIdx := idx
            break
        }
    }
    nextIdx := Mod(startIdx, ready.Length) + 1
    chosen := ready[nextIdx]
    _rotCursor := chosen
    return Map("slot", chosen, "outOfRange", anyOutOfRange)
}

; ── Update cooldown state for UI display ──────────────────────────────────
_UpdateCooldownState(skills)
{
    global g_combatSkillCooldowns

    g_combatSkillCooldowns := Map()
    for _, skill in skills
    {
        name := skill.Has("name") ? skill["name"] : ""
        if (name = "")
            continue
        g_combatSkillCooldowns[name] := Map(
            "name", name,
            "displayName", skill.Has("displayName") ? skill["displayName"] : name,
            "canUse", skill.Has("canUse") ? skill["canUse"] : true,
            "cooldownMs", skill.Has("cooldownMs") ? skill["cooldownMs"] : 0,
            "activeCooldowns", skill.Has("activeCooldowns") ? skill["activeCooldowns"] : 0,
            "maxUses", skill.Has("maxUses") ? skill["maxUses"] : 0,
            "castType", skill.Has("castType") ? skill["castType"] : 0
        )
    }
}

; ── Auto-populate skill ranges from game data ─────────────────────────────
; When a combat slot matches a skill by name and has skillRange=0 (unset),
; infers a default range from the skill's castType:
;   castType 0 (attack/melee) → 300 world units
;   castType 1 (spell)        → 1200 world units
;   anything else              → 800 world units (safe default)
_AutoPopulateSkillRanges(skills)
{
    global g_combatSkillSlots
    static _autoRangeApplied := Map()

    for slotNum, slotCfg in g_combatSkillSlots
    {
        if !(slotCfg["enabled"])
            continue
        skillName := slotCfg.Has("skillName") ? slotCfg["skillName"] : ""
        if (skillName = "")
            continue
        ; Only auto-fill if user hasn't set a range
        if (slotCfg.Has("skillRange") && slotCfg["skillRange"] > 0)
            continue
        ; Avoid re-applying every tick
        cacheKey := slotNum ":" skillName
        if _autoRangeApplied.Has(cacheKey)
            continue

        for _, skill in skills
        {
            sName := skill.Has("name") ? skill["name"] : ""
            sDisplay := skill.Has("displayName") ? skill["displayName"] : ""
            if (sName = skillName || sDisplay = skillName)
            {
                castType := skill.Has("castType") ? skill["castType"] : -1
                autoRange := 800
                if (castType = 0)
                    autoRange := 300    ; melee / attack
                else if (castType = 1)
                    autoRange := 1200   ; spell
                slotCfg["skillRange"] := autoRange
                _autoRangeApplied[cacheKey] := true
                break
            }
        }
    }
}

; ── Cached Terrain Distance ─────────────────────────────────────────────
; Computes terrain-aware distance between player and enemy, with caching.
; Returns: world-unit distance, or -1 if terrain unavailable / pathfinding fails.
_CachedTerrainDistance(pf, playerWX, playerWY, enemyWX, enemyWY)
{
    static _cachedDist := -1
    static _cachedPGX := -999999, _cachedPGY := -999999
    static _cachedEGX := -999999, _cachedEGY := -999999

    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    pGX := Round(playerWX / ratio)
    pGY := Round(playerWY / ratio)
    eGX := Round(enemyWX / ratio)
    eGY := Round(enemyWY / ratio)

    ; Reuse cached result if player and enemy haven't moved significantly (>3 grid cells)
    if (Abs(pGX - _cachedPGX) <= 3 && Abs(pGY - _cachedPGY) <= 3
        && Abs(eGX - _cachedEGX) <= 3 && Abs(eGY - _cachedEGY) <= 3
        && _cachedDist >= 0)
        return _cachedDist

    _cachedPGX := pGX, _cachedPGY := pGY
    _cachedEGX := eGX, _cachedEGY := eGY

    _cachedDist := pf.ComputeTerrainDistance(playerWX, playerWY, enemyWX, enemyWY)
    return _cachedDist
}

; ── World-to-Screen projection ─────────────────────────────────────────────
; Projects a world-space enemy position to game-viewport screen coordinates.
; Uses the game's own 4x4 WorldToScreen matrix (read from camera structure)
; for pixel-perfect projection. Falls back to isometric approximation if
; the matrix is unavailable.
; anchor: camera anchor from NavAnchor() — supplies the w-sign convention
; (behind-camera points are REJECTED instead of mirrored) and the player's
; projection for direction-true edge clamping.
; Returns: Map("x", screenX, "y", screenY) or 0 on failure.
_WorldToScreen(combatInfo, gameHwnd, anchor := 0)
{
    global g_combatW2SScale

    ex := combatInfo["nearestWorldX"]
    ey := combatInfo["nearestWorldY"]
    ez := combatInfo["nearestWorldZ"]

    ; Get game window position and dimensions
    try
    {
        WinGetPos(&winX, &winY, &winW, &winH, "ahk_id " gameHwnd)
    }
    catch
        return 0

    if (winW < 100 || winH < 100)
        return 0

    ; ── Try proper matrix projection (shared ClickNav toolkit) ────────
    mat := combatInfo["w2sMatrix"]
    if (mat && Type(mat) = "Array" && mat.Length = 16)
    {
        rect := NavClientRect(gameHwnd)
        if !rect
            return 0
        visSign := (anchor && anchor["ok"]) ? anchor["visSign"] : 0
        sp := NavProject(ex, ey, ez, mat, rect, visSign)
        if !sp
            return 0
        return NavRayClamp(sp, (anchor && anchor["ok"]) ? anchor["sp"] : 0, rect, 50)
    }

    ; ── Fallback: isometric approximation ─────────────────────────────
    px := combatInfo["playerWorldX"]
    py := combatInfo["playerWorldY"]
    dx := ex - px
    dy := ey - py

    static CAM_SIN := 0.62470   ; sin(38.7°)
    scaleFactor := g_combatW2SScale * (winW / 1920.0)

    screenOffsetX := (dx - dy) * scaleFactor
    screenOffsetY := -(dx + dy) * CAM_SIN * scaleFactor

    screenX := Round(winX + winW / 2 + screenOffsetX)
    screenY := Round(winY + winH / 2 + screenOffsetY)

    margin := 50
    screenX := Max(winX + margin, Min(screenX, winX + winW - margin))
    screenY := Max(winY + margin, Min(screenY, winY + winH - margin))

    return Map("x", screenX, "y", screenY)
}

; ── Move mouse to enemy screen position ───────────────────────────────────
; Uses DllCall("SetCursorPos") — a raw Win32 API that bypasses UIPI.
; MouseMove / SendInput are blocked when the game runs elevated (admin).
_MoveMouseToTarget(screenPos)
{
    if !(screenPos && IsObject(screenPos))
        return false

    x := screenPos["x"]
    y := screenPos["y"]

    return DllCall("SetCursorPos", "int", x, "int", y)
}

; ── Send skill keypress ───────────────────────────────────────────────────
; Uses keybd_event (Win32 API) — same privilege level as SetCursorPos/mouse_event.
; Bypasses UIPI when the game runs elevated, unlike ControlSend/SendInput.
_SendSkillKey(sendKey, gameHwnd)
{
    if (sendKey = "" || !gameHwnd)
        return false

    ; Handle mouse buttons separately via mouse_event
    keyLower := StrLower(sendKey)
    if (keyLower = "lbutton")
    {
        DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (keyLower = "rbutton")
    {
        DllCall("mouse_event", "uint", 0x0008, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0010, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (keyLower = "mbutton")
    {
        DllCall("mouse_event", "uint", 0x0020, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0040, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }

    ; Convert AHK key name → virtual key code
    vk := GetKeyVK(sendKey)
    if (!vk)
        return false

    ; keybd_event: key down then key up (bypasses UIPI)
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0, "uptr", 0)          ; KEYEVENTF_KEYDOWN
    Sleep(20)
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)     ; KEYEVENTF_KEYUP
    return true
}

; ── Config: Load/Save combat automation settings ──────────────────────────
LoadCombatAutoConfig()
{
    global g_combatAutoEnabled, g_combatRange, g_combatDisengageRange
    global g_combatGlobalCooldownMs, g_combatSkillSlots, g_combatToggleHotkey
    global g_combatW2SScale, g_combatNoPathBlacklist

    cfgPath := A_ScriptDir "\poeformance_config.ini"

    g_combatAutoEnabled := false
    g_combatRange := 1500
    g_combatDisengageRange := 2500
    g_combatGlobalCooldownMs := 120
    g_combatToggleHotkey := "F10"
    g_combatW2SScale := 0.20
    ; entityAddr → expiry tick for enemies the no-path give-up disengaged
    ; from (seeded here unconditionally — module-init gotcha, see CLAUDE.md)
    g_combatNoPathBlacklist := Map()

    try g_combatAutoEnabled := IniRead(cfgPath, "CombatAutomation", "enabled", "0") = "1"
    try g_combatRange := Integer(IniRead(cfgPath, "CombatAutomation", "combatRange", "1500"))
    try g_combatDisengageRange := Integer(IniRead(cfgPath, "CombatAutomation", "disengageRange", "2500"))
    try g_combatGlobalCooldownMs := Integer(IniRead(cfgPath, "CombatAutomation", "globalCooldownMs", "120"))
    try g_combatToggleHotkey := IniRead(cfgPath, "CombatAutomation", "toggleHotkey", "F10")
    try g_combatW2SScale := Float(IniRead(cfgPath, "CombatAutomation", "worldToScreenScale", "0.20"))

    ; Load up to 8 skill slots
    g_combatSkillSlots := Map()
    Loop 8
    {
        slotNum := A_Index
        prefix := "slot" slotNum
        enabled := false
        key := ""
        priority := slotNum
        skillName := ""
        slotType := "single"
        cooldownMs := 0
        skillRange := 0

        try enabled := IniRead(cfgPath, "CombatAutomation", prefix "Enabled", "0") = "1"
        try key := IniRead(cfgPath, "CombatAutomation", prefix "Key", "")
        try priority := Integer(IniRead(cfgPath, "CombatAutomation", prefix "Priority", String(slotNum)))
        try skillName := IniRead(cfgPath, "CombatAutomation", prefix "SkillName", "")
        try slotType := IniRead(cfgPath, "CombatAutomation", prefix "Type", "single")
        try cooldownMs := Integer(IniRead(cfgPath, "CombatAutomation", prefix "CooldownMs", "0"))
        try skillRange := Integer(IniRead(cfgPath, "CombatAutomation", prefix "Range", "0"))

        if (key != "" || enabled)
        {
            g_combatSkillSlots[slotNum] := Map(
                "enabled", enabled,
                "key", key,
                "priority", priority,
                "skillName", skillName,
                "name", skillName != "" ? skillName : "Slot" slotNum,
                "type", slotType,
                "cooldownMs", cooldownMs,
                "lastUseTick", 0,
                "skillRange", skillRange
            )
        }
    }
}

SaveCombatAutoConfig()
{
    global g_combatAutoEnabled, g_combatRange, g_combatDisengageRange
    global g_combatGlobalCooldownMs, g_combatSkillSlots, g_combatToggleHotkey
    global g_combatW2SScale

    cfgPath := A_ScriptDir "\poeformance_config.ini"

    try IniWrite(g_combatAutoEnabled ? "1" : "0", cfgPath, "CombatAutomation", "enabled")
    try IniWrite(String(g_combatRange), cfgPath, "CombatAutomation", "combatRange")
    try IniWrite(String(g_combatDisengageRange), cfgPath, "CombatAutomation", "disengageRange")
    try IniWrite(String(g_combatGlobalCooldownMs), cfgPath, "CombatAutomation", "globalCooldownMs")
    try IniWrite(g_combatToggleHotkey, cfgPath, "CombatAutomation", "toggleHotkey")
    try IniWrite(Format("{:.2f}", g_combatW2SScale), cfgPath, "CombatAutomation", "worldToScreenScale")

    Loop 8
    {
        slotNum := A_Index
        prefix := "slot" slotNum
        if g_combatSkillSlots.Has(slotNum)
        {
            slot := g_combatSkillSlots[slotNum]
            try IniWrite(slot["enabled"] ? "1" : "0", cfgPath, "CombatAutomation", prefix "Enabled")
            try IniWrite(slot["key"], cfgPath, "CombatAutomation", prefix "Key")
            try IniWrite(String(slot["priority"]), cfgPath, "CombatAutomation", prefix "Priority")
            try IniWrite(slot["skillName"], cfgPath, "CombatAutomation", prefix "SkillName")
            try IniWrite(slot["type"], cfgPath, "CombatAutomation", prefix "Type")
            try IniWrite(String(slot["cooldownMs"]), cfgPath, "CombatAutomation", prefix "CooldownMs")
            try IniWrite(String(slot.Has("skillRange") ? slot["skillRange"] : 0), cfgPath, "CombatAutomation", prefix "Range")
        }
    }
}

; ── Auto-configure combat slots from the equipped skill bar ────────────────
; Reads the player's LIVE skill bar (which skill sits on which key, via
; SkillBarReader) plus each skill's castType, and rewrites the 8 combat slots to
; match whatever build is currently equipped — real skill names bound to their
; real keys. Priority follows skill-bar order; range is inferred from castType
; (melee 300 / spell 1200); type defaults to "single" and cooldown pacing is left
; to the live game canUse gate (the name match reads the real cooldown each tick).
; Persists the result and returns a short status string ("ok:N" | reason).
AutoConfigureCombatSlots()
{
    global g_reader, g_combatSkillSlots
    if !IsObject(g_reader)
        return "no-reader"
    slots := 0
    try slots := ReadSkillBarSkills(g_reader)
    if !(slots && slots is Array && slots.Length)
        return "no-skillbar"     ; not in-game / skill bar not visible on the HUD

    ; internalName -> live skill map (for castType).
    skByInt := Map()
    lp := _SkillBarLocalPlayerPtr()
    if lp
    {
        sd := 0
        try sd := g_reader.ReadPlayerSkills(lp)
        if (sd && sd is Map && sd.Has("skills"))
        {
            for sk in sd["skills"]
            {
                if (sk is Map && sk.Has("name") && sk["name"] != "")
                    skByInt[StrLower(sk["name"])] := sk
            }
        }
    }

    newSlots := Map()
    n := 0
    for e in slots
    {
        if (n >= 8)
            break
        if !(e is Map)
            continue
        disp  := e.Has("skillName") ? e["skillName"] : ""
        intnm := e.Has("skillInternal") ? e["skillInternal"] : ""
        key   := e.Has("sendKey") ? e["sendKey"] : ""
        if (disp = "" && intnm = "")
            continue                            ; empty skill-bar slot
        low := StrLower(intnm)
        if (low = "move")                       ; the basic move action is never a rotation skill
            continue
        if (key = "")                           ; slot not bound to a usable key → can't be cast
            continue

        castType := -1
        if (intnm != "" && skByInt.Has(low))
        {
            sk := skByInt[low]
            castType := sk.Has("castType") ? sk["castType"] : -1
        }
        rng := 0
        if (castType = 0)
            rng := 300                          ; melee / attack
        else if (castType = 1)
            rng := 1200                         ; spell

        n += 1
        nm := (disp != "") ? disp : intnm
        newSlots[n] := Map(
            "enabled",     true,
            "key",         key,
            "priority",    n,
            "skillName",   nm,
            "name",        nm,
            "type",        "single",
            "cooldownMs",  0,
            "lastUseTick", 0,
            "skillRange",  rng
        )
    }
    if (n = 0)
        return "no-skills-resolved"
    g_combatSkillSlots := newSlots
    SaveCombatAutoConfig()
    return "ok:" n
}

; ── Import a build's rotation (ordered skill names) into the combat slots ──
; The UI decodes a Path of Building code (client-side) into an ORDERED list of
; active-skill names and passes them here (newline-joined). A PoB build lists
; EVERY active gem — auras / heralds / curses / triggered / auto-cast skills —
; not just the manually-spammed damage skills. Only a skill that is actually
; BOUND TO AN ACTION-BAR KEY can be manually cast, so build-listed skills that
; don't resolve to a live bar key (reserved / auto-cast / triggered / not yet
; socketed) are SKIPPED ENTIRELY — they no longer consume one of the 8 slots,
; which previously let them crowd out the real castable rotation (they were
; added disabled before). Each remaining name is matched against the player's
; live skills (by display OR internal name); the key comes from the live skill
; bar (g_skillKeyBySkillName). Priority follows the build's order. Persists +
; returns "ok:N/total" (N bound + placed of total listed) | reason.
ImportBuildRotation(namesText)
{
    global g_reader, g_combatSkillSlots, g_skillKeyBySkillName
    if !IsObject(g_reader)
        return "no-reader"
    names := StrSplit(Trim(namesText, " `t`r`n"), "`n")
    if (names.Length = 0)
        return "no-skills"

    ; live skills keyed by lowercased display AND internal name.
    skByName := Map()
    lp := _SkillBarLocalPlayerPtr()
    if lp
    {
        sd := 0
        try sd := g_reader.ReadPlayerSkills(lp)
        if (sd && sd is Map && sd.Has("skills"))
        {
            for sk in sd["skills"]
            {
                if !(sk is Map)
                    continue
                dn  := sk.Has("displayName") ? sk["displayName"] : ""
                inm := sk.Has("name") ? sk["name"] : ""
                if (dn != "")
                    skByName[StrLower(dn)] := sk
                if (inm != "")
                    skByName[StrLower(inm)] := sk
            }
        }
    }
    haveKeys := (IsSet(g_skillKeyBySkillName) && g_skillKeyBySkillName is Map)

    newSlots := Map()
    n := 0, total := 0
    for _, raw in names
    {
        nm := Trim(raw)
        if (nm = "")
            continue
        total += 1
        low := StrLower(nm)
        sk := skByName.Has(low) ? skByName[low] : 0

        key := ""
        if (haveKeys)
        {
            if (g_skillKeyBySkillName.Has(low))
                key := g_skillKeyBySkillName[low]
            else if (sk && sk.Has("name") && g_skillKeyBySkillName.Has(StrLower(sk["name"])))
                key := g_skillKeyBySkillName[StrLower(sk["name"])]
        }
        ; Only skills bound to an action-bar key can be manually cast. Auras /
        ; heralds / triggered / auto-cast / not-yet-socketed gems aren't on the
        ; bar, so they can never fire — skip them WITHOUT consuming a slot so the
        ; real castable skills (in build order) fill the 8 slots instead.
        if (key = "")
            continue
        if (n >= 8)
            continue

        castType := (sk && sk.Has("castType")) ? sk["castType"] : -1
        rng := 0
        if (castType = 0)
            rng := 300
        else if (castType = 1)
            rng := 1200

        n += 1
        newSlots[n] := Map(
            "enabled",     true,             ; only bound skills reach here
            "key",         key,
            "priority",    n,
            "skillName",   nm,
            "name",        nm,
            "type",        "single",
            "cooldownMs",  0,
            "lastUseTick", 0,
            "skillRange",  rng
        )
    }
    if (n = 0)
        return "no-bound-skills"   ; none of the build's skills are on your action bar
    g_combatSkillSlots := newSlots
    SaveCombatAutoConfig()
    return "ok:" n "/" total
}

; ── Hotkey registration ───────────────────────────────────────────────────
; Registers (or re-registers) the combat toggle hotkey.
; Call once after LoadCombatAutoConfig().
RegisterCombatHotkey()
{
    global g_combatToggleHotkey
    static _currentHotkey := ""

    ; Unregister previous hotkey if it changed
    if (_currentHotkey != "")
    {
        try Hotkey(_currentHotkey, , "Off")
    }

    hk := Trim(g_combatToggleHotkey)
    if (hk = "")
        return

    try
    {
        Hotkey(hk, _OnCombatHotkeyPressed, "On")
        _currentHotkey := hk
    }
    catch as ex
    {
        LogError("RegisterCombatHotkey", ex)
    }
}

; ── World-to-screen scale live-tuning hotkeys ─────────────────────────────
; Ctrl + Plus / Ctrl + Minus nudge g_combatW2SScale — the isometric world→screen
; scale shared by the auto-aim, the range rings and the monster-count gate — up
; or down by 0.01, so it can be calibrated in-game against the visible ring.
; Bound on both the main +/- keys (VK_OEM_PLUS/MINUS, layout-independent) and the
; numpad +/-. Active ONLY while the PoE2 window is focused, so they don't hijack
; Ctrl+Plus/Minus (browser zoom etc.) in other apps. Call once at startup.
RegisterW2STuneHotkeys()
{
    try
    {
        HotIf(_W2STuneActive)
        for hk in ["^vkBB", "^NumpadAdd"]
            try Hotkey(hk, (*) => _AdjustW2SScale(0.01), "On")
        for hk in ["^vkBD", "^NumpadSub"]
            try Hotkey(hk, (*) => _AdjustW2SScale(-0.01), "On")
        HotIf()   ; reset context so later Hotkey() calls stay global
    }
    catch as ex
    {
        LogError("RegisterW2STuneHotkeys", ex)
    }
}

; HotIf context for the tune hotkeys: true only when PoE2 is the active window.
_W2STuneActive(*)
{
    h := ResolvePoEWindow()
    return (h && WinActive("ahk_id " h)) ? true : false
}

; Nudges g_combatW2SScale by delta, clamped to [0.05, 1.0], then persists,
; refreshes the UI slider, and flashes the new value as an in-game tooltip.
_AdjustW2SScale(delta)
{
    global g_combatW2SScale
    g_combatW2SScale := Max(0.05, Min(1.0, Round(g_combatW2SScale + delta, 3)))
    SetTimer(() => SaveCombatAutoConfig(), -100)
    try PushHeaderToWebView()
    ToolTip("World→Screen scale: " Format("{:.2f}", g_combatW2SScale))
    SetTimer(() => ToolTip(), -1200)
}

; F10 (configurable) now toggles AutoPilot — combat+loot+explore as one unit.
; Previous behaviour toggled only combat; that toggle is gone since AutoPilot
; subsumed combat under a single user-facing switch.
_OnCombatHotkeyPressed(*)
{
    global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
    global g_combatAutoEnabled, g_exploreEnabled
    global g_combatState, g_combatLastReason, g_exploreLastReason
    g_autoPilotEnabled := !g_autoPilotEnabled
    g_combatAutoEnabled := g_autoPilotEnabled
    g_exploreEnabled    := g_autoPilotEnabled
    if !g_autoPilotEnabled
    {
        g_autoPilotState   := "idle"
        g_autoPilotReason  := "disabled"
        g_combatState      := "idle"
        g_combatLastReason := "disabled"
        g_exploreLastReason := "disabled"
    }
    else
    {
        ; Instant feedback; the per-tick reasons take over once the game
        ; loop actually runs (they stay "enabled" until then).
        g_autoPilotReason   := "enabled"
        g_combatLastReason  := "enabled"
        g_exploreLastReason := "enabled"
    }
    SetTimer(SaveConfig, -100)
    SetTimer(() => SaveCombatAutoConfig(), -100)
    SetTimer(() => SaveExplorationConfig(), -100)
    SetTimer(PushHeaderToWebView, -50)
}

; ── AutoPilot projection diagnostic (issue #158) ───────────────────────────
; One-shot RE/triage aid that dumps the entire world→screen projection chain so
; the "doesn't move / spams skills at screen centre" failure can be root-caused
; WITHOUT the user reading the live debug overlay. Both AutoPilot symptoms come
; from a bad camera matrix at the consumer: an empty matrix makes NavAnchor fail
; (exploration never clicks → no movement) and used to drop combat into the
; isometric screen-CENTRE fallback (the blind skill-spam). This reports whether
; the matrix is present/zeroed/garbage, whether the player projects near the
; screen centre, and the live combat/explore reasons. No params / no return;
; shows a MsgBox and writes the full report to debug\.
AutoPilotDiagnose()
{
    global g_reader, g_radarLastSnap
    global g_autoPilotEnabled, g_combatState, g_combatLastReason, g_exploreLastReason

    if !IsObject(g_reader)
    {
        try MsgBox("AutoPilot Diagnose: game not connected.", "AutoPilot Diagnose", 0x40)
        return
    }

    nl := "`n"
    out := "=== AutoPilot projection diagnostic  (" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") ") ===" nl nl
    out .= "AutoPilot enabled: " (g_autoPilotEnabled ? "yes" : "no")
        . "    combatState: " g_combatState nl
    out .= "live combat reason : " (g_combatLastReason  != "" ? g_combatLastReason  : "(none)") nl
    out .= "live explore reason: " (g_exploreLastReason != "" ? g_exploreLastReason : "(none)") nl nl

    snap := (IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
    {
        out .= "No radar snapshot yet — let the radar run (enter an area), then retry." nl
        _ApDiagFinish(out)
        return
    }

    ; Reuse the exact extraction the combat tick uses (matrix + player + nearest enemy).
    info := _DetectCombat(snap)
    mat  := info["w2sMatrix"]
    pwx  := info["playerWorldX"], pwy := info["playerWorldY"], pwz := info["playerWorldZ"]

    ; ── Camera matrix ──────────────────────────────────────────────────────
    matLen := (IsObject(mat) && Type(mat) = "Array") ? mat.Length : 0
    out .= "W2S matrix length: " matLen
    if (matLen != 16)
        out .= "   <<< NOT 16 — the reader returned NO matrix this tick."
            . nl . "      => InGameState.WorldData (0x" Format("{:X}", PoE2Offsets.InGameState["WorldData"])
            . ") or WorldData.W2SMatrix (0x" Format("{:X}", PoE2Offsets.WorldData["W2SMatrix"]) ") did not"
            . nl . "         resolve: bad pointer, a game-version offset shift, or the camera was"
            . nl . "         not ready. This is the cause of BOTH symptoms."
    out .= nl
    if (matLen = 16)
    {
        allZero := true
        Loop 16
            if (mat[A_Index] != 0)
                allZero := false
        out .= (allZero
            ? "   <<< all 16 values are ZERO — matrix memory is blank (wrong location / camera off)."
            : "   matrix (row-major 4x4):") nl
        if !allZero
        {
            Loop 4
            {
                r := A_Index
                out .= "     " Format("{:.3f}  {:.3f}  {:.3f}  {:.3f}"
                    , mat[(r-1)*4+1], mat[(r-1)*4+2], mat[(r-1)*4+3], mat[(r-1)*4+4]) nl
            }
        }
    }
    out .= nl

    ; ── Player world position ──────────────────────────────────────────────
    out .= "Player world pos: " Round(pwx) ", " Round(pwy) ", " Round(pwz)
    if (pwx = 0 && pwy = 0)
        out .= "   <<< origin (0,0) — player position not readable; projection cannot run."
    out .= nl nl

    ; ── Window / client rect ───────────────────────────────────────────────
    gHwnd := ResolvePoEWindow()
    rect := gHwnd ? NavClientRect(gHwnd) : 0
    if IsObject(rect)
        out .= "Client rect: x=" rect["x"] " y=" rect["y"] " w=" rect["w"] " h=" rect["h"] nl
    else
        out .= "Client rect: (unavailable — PoE window not resolved)" nl
    out .= nl

    ; ── Project the player + run the camera anchor ─────────────────────────
    if (matLen = 16 && IsObject(rect) && !(pwx = 0 && pwy = 0))
    {
        w := NavProjW(pwx, pwy, pwz, mat)
        out .= "Player NavProjW (camera w): " Format("{:.4f}", w)
            . "   (sign defines 'in front of camera')" nl
        psp := NavProject(pwx, pwy, pwz, mat, rect, 0)
        if psp
        {
            cxm := rect["x"] + rect["w"] / 2
            cym := rect["y"] + rect["h"] / 2
            pctX := Round(Abs(psp["x"] - cxm) / rect["w"] * 100)
            pctY := Round(Abs(psp["y"] - cym) / rect["h"] * 100)
            out .= "Player projects to: " psp["x"] ", " psp["y"]
                . "   (screen centre " Round(cxm) ", " Round(cym) ")" nl
            out .= "Offset from centre: " pctX "% x, " pctY "% y"
                . "   (anchor needs BOTH <= 30%)" nl
        }
        else
            out .= "Player projection FAILED (degenerate w) — matrix present but unusable." nl

        anchor := NavAnchor(pwx, pwy, pwz, mat, rect)
        out .= "NavAnchor: ok=" (anchor["ok"] ? "YES" : "no")
            . "   why=" (anchor["why"] != "" ? anchor["why"] : "(ok)")
            . "   visSign=" anchor["visSign"] nl

        ; Project the nearest enemy too, when one is in range.
        if (info["hostileCount"] > 0 && info["nearestWorldX"] != 0)
        {
            ; Project with the PLAYER's Z (grid heights unreliable), matching ClickNav.
            ex := info["nearestWorldX"], ey := info["nearestWorldY"]
            out .= nl . "Nearest enemy: " info["hostileCount"] " hostile(s), dist="
                . Round(info["nearestDist"]) "  world=" Round(ex) "," Round(ey) nl
            esp := NavProject(ex, ey, pwz, mat, rect, anchor["visSign"])
            out .= "Enemy projects to: " (esp ? esp["x"] "," esp["y"]
                : "REJECTED (behind camera / degenerate w)") nl
        }
        else
            out .= nl . "Nearest enemy: none in range (move next to a monster to test combat aim)." nl
    }
    else
        out .= "Projection skipped — need matrix(16) + client rect + non-origin player." nl

    _ApDiagFinish(out)
}

; Writes the AutoPilot diagnostic report to debug\ and shows a short MsgBox.
; Param: out (the full report text). No return.
_ApDiagFinish(out)
{
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        try DirCreate(outDir)
    outPath := outDir "\autopilot_diag_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try {
        FileAppend(out, outPath, "UTF-8")
        wrote := true
    }
    if wrote
    {
        msg := "AutoPilot diagnostic written to:`n" outPath
            . "`n`nOpen it in Config -> Data & Logs (or paste it) so the projection"
            . " chain can be read.`n`n--- summary ---`n" SubStr(out, 1, 600)
        try MsgBox(msg, "AutoPilot Diagnose", 0x40)
    }
    else
        try MsgBox(out, "AutoPilot Diagnose", 0x40)
}

; ── AutoPilot W2S-matrix offset scan (issue #158) ──────────────────────────
; When AutoPilotDiagnose shows the matrix is PRESENT but degenerate (the player
; projects to centre yet a far enemy collapses onto the SAME pixel — w hugely
; inflated), the matrix at the current offset is no longer the real camera
; matrix on this build (a game patch shifted the camera struct — see the +0x18
; AreaInstance drifts in PoE2Offsets). This sweeps candidate matrix offsets and
; reports which one projects the player near centre AND a 500-unit test point
; FAR from the player (the signature of a usable W2S matrix). It scans the
; WorldData struct directly and the camera pointer at WorldData+0xA0, in both
; row-major and transposed layouts. No params / no return; MsgBox + debug\ file.
AutoPilotMatrixScan()
{
    global g_reader, g_radarLastSnap

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("Matrix scan: game not connected.", "AutoPilot Matrix Scan", 0x40)
        return
    }

    nl := "`n"
    out := "=== AutoPilot W2S-matrix offset scan  (" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") ") ===" nl nl

    inGs := 0
    try inGs := g_reader._radarInGameStateCache
    if !g_reader.IsProbablyValidPointer(inGs)
    {
        out .= "InGameState not resolved yet — enter an area and let the radar run, then retry." nl
        _ApDiagFinish2(out)
        return
    }
    worldData := g_reader.Mem.ReadPtr(inGs + PoE2Offsets.InGameState["WorldData"])
    if !g_reader.IsProbablyValidPointer(worldData)
    {
        out .= "WorldData pointer invalid (InGameState+0x" Format("{:X}", PoE2Offsets.InGameState["WorldData"]) ")." nl
        _ApDiagFinish2(out)
        return
    }

    ; Need the live player + a far test point. Reuse the combat extraction.
    snap := (IsObject(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
    {
        out .= "No radar snapshot yet." nl
        _ApDiagFinish2(out)
        return
    }
    info := _DetectCombat(snap)
    pwx := info["playerWorldX"], pwy := info["playerWorldY"], pwz := info["playerWorldZ"]
    if (pwx = 0 && pwy = 0)
    {
        out .= "Player world pos is (0,0) — cannot test projection." nl
        _ApDiagFinish2(out)
        return
    }
    gHwnd := ResolvePoEWindow()
    rect := gHwnd ? NavClientRect(gHwnd) : 0
    if !IsObject(rect)
    {
        out .= "PoE window / client rect unavailable." nl
        _ApDiagFinish2(out)
        return
    }

    ; A far test point in front of the player (500 world units in +x and +y). A
    ; usable matrix moves it well away from the player on screen; the degenerate
    ; matrix keeps it on top of the player.
    haveEnemy := (info["hostileCount"] > 0 && info["nearestWorldX"] != 0)
    enX := haveEnemy ? info["nearestWorldX"] : (pwx + 500)
    enY := haveEnemy ? info["nearestWorldY"] : pwy

    out .= "WorldData=0x" Format("{:X}", worldData)
        . "   player=" Round(pwx) "," Round(pwy) "," Round(pwz)
        . "   testPt=" Round(enX) "," Round(enY) (haveEnemy ? " (enemy)" : " (+500)") nl
    out .= "client=" rect["w"] "x" rect["h"] "   scanning for: player near centre + testPt >50px away" nl nl

    cands := []
    curW2S := PoE2Offsets.WorldData["W2SMatrix"]   ; the offset currently in use (mark it below)
    ; Direct sweep of WorldData offsets around the current matrix offset.
    _ApScanRange(g_reader, worldData, 0x100, 0x300, "WorldData", pwx, pwy, pwz, enX, enY, rect, cands)
    ; Camera pointer at WorldData+0xA0 (in case the struct became a pointer on this build).
    camPtr := g_reader.Mem.ReadPtr(worldData + PoE2Offsets.WorldData["CameraStructure"])
    if g_reader.IsProbablyValidPointer(camPtr)
    {
        out .= "Camera pointer @WorldData+0xA0 = 0x" Format("{:X}", camPtr) " (also scanning it)" nl nl
        _ApScanRange(g_reader, camPtr, 0x00, 0x200, "CamPtr", pwx, pwy, pwz, enX, enY, rect, cands)
    }

    ; Sort candidates by screen-distance of the test point from the player (desc).
    _ApScanSort(cands)

    out .= "GOOD candidates (player <=30% off centre, testPt moved): " cands.Length nl
    out .= "fmt: base+0xOFF [layout]  player->(x,y)  testPt->(x,y)  sep=PX" nl
    shown := 0
    for _, c in cands
    {
        if (shown >= 24)
        {
            out .= "  … more omitted" nl
            break
        }
        shown += 1
        mark := (c["who"] = "WorldData" && c["off"] = curW2S) ? "  <== CURRENT (in use)" : ""
        out .= "  " c["who"] "+0x" Format("{:X}", c["off"]) " [" c["layout"] "]"
            . "  P->" c["px"] "," c["py"]
            . "  T->" c["tx"] "," c["ty"]
            . "  sep=" Round(c["sep"]) mark nl
    }
    if (cands.Length = 0)
        out .= "  (none — no offset in the scanned range yields a usable projection;"
            . " the camera struct may live elsewhere / behind another pointer)" nl

    _ApDiagFinish2(out)
}

; Scans byte offsets lo..hi from base in 4-byte steps, reading a 4x4 float
; matrix at each and testing whether it projects the player near screen centre
; and the test point away from the player (both row-major and transposed
; layouts). Appends GOOD hits to `cands`. Params as named; no return.
_ApScanRange(reader, base, lo, hi, who, pwx, pwy, pwz, enX, enY, rect, cands)
{
    cxm := rect["x"] + rect["w"] / 2
    cym := rect["y"] + rect["h"] / 2
    margX := rect["w"] * 0.30
    margY := rect["h"] * 0.30
    off := lo
    while (off < hi)
    {
        buf := reader.Mem.ReadBytes(base + off, 64)
        off += 4
        if !(buf && buf.Size >= 64)
            continue
        m := []
        bad := false
        Loop 16
        {
            v := NumGet(buf.Ptr, (A_Index - 1) * 4, "Float")
            if (v != v || Abs(v) > 1.0e12)   ; NaN or absurd magnitude
            {
                bad := true
                break
            }
            m.Push(v)
        }
        if bad
            continue
        ; Try both layouts; keep whichever projects the player nearest centre.
        for _, layout in ["row", "T"]
        {
            pSp := _ApMatProj(m, pwx, pwy, pwz, rect, layout)
            if !pSp
                continue
            if (Abs(pSp["x"] - cxm) > margX || Abs(pSp["y"] - cym) > margY)
                continue
            tSp := _ApMatProj(m, enX, enY, pwz, rect, layout)
            if !tSp
                continue
            dx := tSp["x"] - pSp["x"], dy := tSp["y"] - pSp["y"]
            sep := Sqrt(dx * dx + dy * dy)
            if (sep < 50)
                continue
            cands.Push(Map("who", who, "off", off - 4, "layout", layout
                , "px", pSp["x"], "py", pSp["y"], "tx", tSp["x"], "ty", tSp["y"], "sep", sep))
        }
    }
}

; Projects a world point through a 16-float matrix `m` (1-based Array). layout
; "row" = NavProject's column-dot convention; "T" = transposed (row-dot).
; Returns Map("x","y") or 0 (degenerate w). Param: m, wx, wy, wz, rect, layout.
_ApMatProj(m, wx, wy, wz, rect, layout)
{
    if (layout = "row")
    {
        r1 := m[1]*wx + m[5]*wy + m[9]*wz  + m[13]
        r2 := m[2]*wx + m[6]*wy + m[10]*wz + m[14]
        r4 := m[4]*wx + m[8]*wy + m[12]*wz + m[16]
    }
    else
    {
        r1 := m[1]*wx + m[2]*wy + m[3]*wz  + m[4]
        r2 := m[5]*wx + m[6]*wy + m[7]*wz  + m[8]
        r4 := m[13]*wx + m[14]*wy + m[15]*wz + m[16]
    }
    if (Abs(r4) < 0.0001)
        return 0
    return Map("x", Round(rect["x"] + (r1 / r4 + 1) * rect["w"] / 2)
             , "y", Round(rect["y"] + (1 - r2 / r4) * rect["h"] / 2))
}

; Insertion-sort cands by screen separation desc (best candidate first).
; Param: cands (Array of Maps). No return.
_ApScanSort(cands)
{
    i := 2
    while (i <= cands.Length)
    {
        cur := cands[i], j := i - 1
        while (j >= 1 && cands[j]["sep"] < cur["sep"])
        {
            cands[j + 1] := cands[j]
            j -= 1
        }
        cands[j + 1] := cur
        i += 1
    }
}

; Writes a matrix-scan report to debug\ and shows a short MsgBox. Param: out.
_ApDiagFinish2(out)
{
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        try DirCreate(outDir)
    outPath := outDir "\autopilot_matrixscan_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    wrote := false
    try {
        FileAppend(out, outPath, "UTF-8")
        wrote := true
    }
    if wrote
    {
        msg := "Matrix scan written to:`n" outPath
            . "`n`nOpen it in Config -> Data & Logs (or paste it).`n`n--- summary ---`n" SubStr(out, 1, 700)
        try MsgBox(msg, "AutoPilot Matrix Scan", 0x40)
    }
    else
        try MsgBox(out, "AutoPilot Matrix Scan", 0x40)
}
