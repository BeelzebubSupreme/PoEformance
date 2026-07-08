; CameraZoom.ahk
; EXPERIMENTAL in-game camera zoom — the tool's ONLY memory-write feature.
;
; Writes a float in the game CameraStructure (WorldData -> CameraStructure, the
; same chain CameraZoomProbe dumps) to widen the view ("zoom out"). The exact
; field is NOT yet confirmed (the probe's two dumps were identical, so we can't
; diff which float is the zoom), so the OFFSET is user-configurable and the whole
; thing is FULLY REVERSIBLE:
;   - the original value at the chosen field is captured ONCE (before any write),
;   - each tick writes original * factor (re-applied in case the game rewrites it),
;   - on disable / offset change / exit the captured original is written back.
; Candidates from the probe (CameraStructure+off): 0x080 = 75.0 (FoV degrees,
; likely), 0x098 = 3000.0 (distance), 0x0B0 = 0.7854 (FoV radians). The multiply
; is offset-agnostic (bigger FoV OR bigger distance both zoom out), so the user
; can try each offset live and revert instantly.
;
; SAFETY: writes only when enabled AND the captured original is a sane float; the
; factor is clamped; nothing is written unless the user turns it on. Restores on
; OnExit via CameraZoomRestore().
;
; Globals seeded in LoadCameraZoom() (AHK v2 init gotcha). Self-persists [CameraZoom].
; Included by InGameStateMonitor.ahk.

LoadCameraZoom()
{
    global g_camZoomEnabled := false
    global g_camZoomOffset := 0x080        ; CameraStructure offset of the field to scale (FoV candidate)
    global g_camZoomFactor := 1.30         ; multiply the field by this (>1 = zoom out)
    global g_camZoomConfigFile := _ConfigPath()

    ; Runtime (never persisted)
    global g_camZoomAppliedAddr := 0       ; absolute addr we last wrote to (0 = nothing applied)
    global g_camZoomOrig := 0.0            ; the TRUE original value captured at that addr

    f := g_camZoomConfigFile
    try {
        g_camZoomEnabled := (IniRead(f, "CameraZoom", "enabled", "0") = "1")
        g_camZoomOffset  := Integer(IniRead(f, "CameraZoom", "offset", "128"))   ; 128 = 0x80
        g_camZoomFactor  := Float(IniRead(f, "CameraZoom", "factor", "1.30"))
    } catch as ex {
        LogError("LoadCameraZoom", ex)
    }
    _CamZoomClamp()
}

SaveCameraZoom()
{
    global g_camZoomEnabled, g_camZoomOffset, g_camZoomFactor, g_camZoomConfigFile
    f := g_camZoomConfigFile
    try {
        IniWrite(g_camZoomEnabled ? "1" : "0", f, "CameraZoom", "enabled")
        IniWrite(String(g_camZoomOffset), f, "CameraZoom", "offset")
        IniWrite(Format("{:.3f}", g_camZoomFactor), f, "CameraZoom", "factor")
    } catch as ex {
        LogError("SaveCameraZoom", ex)
    }
}

_CamZoomClamp()
{
    global g_camZoomOffset, g_camZoomFactor
    ; Offset must land inside the probed 0x000..0x1FC window and dodge the W2S
    ; matrix block (0x100..0x140) so a stray value can't corrupt the projection.
    if (g_camZoomOffset < 0)
        g_camZoomOffset := 0
    if (g_camZoomOffset > 0x1FC)
        g_camZoomOffset := 0x1FC
    ; Factor sane band (0.5 = zoom in, 3.0 = far out).
    if (g_camZoomFactor < 0.50)
        g_camZoomFactor := 0.50
    if (g_camZoomFactor > 3.00)
        g_camZoomFactor := 3.00
}

; Applies one bridge setting change, persists.
; key: "enabled" | "offset" | "factor".
_CamZoomApplySetting(key, val)
{
    global g_camZoomEnabled, g_camZoomOffset, g_camZoomFactor
    if (key = "enabled")
    {
        on := (val = true || val = 1 || val = "1" || val = "true")
        ; Turning OFF: restore immediately so the view snaps back without waiting
        ; for the next tick.
        if (!on)
            CameraZoomRestore()
        g_camZoomEnabled := on
    }
    else if (key = "offset")
    {
        ; Changing the target field: restore the OLD one first so we never leave a
        ; stale write behind, then the next tick captures + scales the new offset.
        CameraZoomRestore()
        try g_camZoomOffset := Integer(val)
    }
    else if (key = "factor")
        try g_camZoomFactor := Float(val)
    _CamZoomClamp()
    SaveCameraZoom()
}

BuildCameraZoomHeaderJson()
{
    global g_camZoomEnabled, g_camZoomOffset, g_camZoomFactor
    return '{'
        . '"enabled":' (g_camZoomEnabled ? "true" : "false")
        . ',"offset":' g_camZoomOffset
        . ',"factor":' Format("{:.3f}", g_camZoomFactor)
        . '}'
}

; Resolves the absolute address of the zoom field (CameraStructure + offset), or
; 0 when not in-game / unresolvable. Mirrors CameraZoomProbe's resolution chain.
_CamZoomFieldAddr()
{
    global g_reader, g_camZoomOffset
    if !(IsObject(g_reader) && g_reader.HasOwnProp("Mem") && g_reader.Mem && g_reader.Mem.Handle)
        return 0
    inGs := 0
    try inGs := g_reader._radarInGameStateCache
    if !(inGs && inGs > 0x10000)
        return 0
    worldData := 0
    try worldData := g_reader.Mem.ReadPtr(inGs + PoE2Offsets.InGameState["WorldData"])
    if !(worldData && worldData > 0x10000)
        return 0
    camPtr := 0
    try camPtr := g_reader.Mem.ReadPtr(worldData + PoE2Offsets.WorldData["CameraStructure"])
    if !(camPtr && camPtr > 0x10000)
        return 0
    return camPtr + g_camZoomOffset
}

; Per-tick apply. Called from UpdateRadarFast. Cheap no-op when disabled and
; nothing is applied. Captures the original ONCE per field address (before any
; write), then re-writes original*factor each tick (the game may rewrite the
; field, so a one-shot write wouldn't stick). On a field-address change the old
; field is restored first. See the header for the reversibility contract.
CameraZoomTick()
{
    global g_reader, g_camZoomEnabled, g_camZoomFactor
    global g_camZoomAppliedAddr, g_camZoomOrig

    if !g_camZoomEnabled
    {
        ; Disabled: if we still have a live write, restore it once.
        if (g_camZoomAppliedAddr)
            CameraZoomRestore()
        return
    }

    addr := _CamZoomFieldAddr()
    if !addr
    {
        ; Not in-game (camera gone). The field resets to the game default on the
        ; next load, so just forget our applied state — nothing to restore.
        g_camZoomAppliedAddr := 0
        return
    }

    ; New / changed target field → restore the old one, then capture this field's
    ; TRUE original (read BEFORE we ever write it).
    if (g_camZoomAppliedAddr != addr)
    {
        if (g_camZoomAppliedAddr)
            try g_reader.Mem.WriteFloat(g_camZoomAppliedAddr, g_camZoomOrig)
        orig := 0.0
        try orig := g_reader.Mem.ReadFloat(addr)
        ; Only accept a sane, positive original — never scale garbage.
        if !(orig > 0.001 && orig < 1000000.0)
        {
            g_camZoomAppliedAddr := 0
            return
        }
        g_camZoomOrig := orig
        g_camZoomAppliedAddr := addr
    }

    ; Re-apply the scaled value (idempotent; overrides the game if it rewrites).
    try g_reader.Mem.WriteFloat(addr, g_camZoomOrig * g_camZoomFactor)
}

; Writes the captured original back and clears the applied state. Safe to call
; any time (no-op when nothing is applied). Called on disable / offset change /
; OnExit.
CameraZoomRestore()
{
    global g_reader, g_camZoomAppliedAddr, g_camZoomOrig
    if (g_camZoomAppliedAddr && IsObject(g_reader) && g_reader.HasOwnProp("Mem") && g_reader.Mem && g_reader.Mem.Handle)
    {
        try g_reader.Mem.WriteFloat(g_camZoomAppliedAddr, g_camZoomOrig)
    }
    g_camZoomAppliedAddr := 0
}
