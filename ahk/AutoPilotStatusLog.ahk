; AutoPilotStatusLog.ahk
; Opt-in FILE logger for the live AutoPilot status line (state + loot / combat /
; explore reasons). The WebView tool is rarely in the foreground during play, so
; this mirrors the Config -> AutoPilot -> Live Status readout into
; logs\InGameStateMonitor.autopilot_status.log for after-the-fact review
; (readable in Config -> Data & Logs, which has search + pagination).
;
; Off by default; PERSISTENT toggle ([Diagnostics] apStatusLog) — enable it once
; and it stays on across restarts. Cheap no-op when disabled (one global check).
; When enabled it appends only when the status line CHANGES (deduped) and no more
; than ~4x/second (throttled), and rotates the file at ~2 MB so it stays bounded.
; Included by InGameStateMonitor.ahk.

; Seeds all globals (defaults first), then overlays the persisted INI value and
; the current on-disk file size (so rotation accounts for an existing log).
; Called once at startup by the main script (AHK v2 init gotcha).
LoadAutoPilotStatusLog()
{
    global g_apLogEnabled  := false
    global g_apLogFile     := A_ScriptDir "\logs\InGameStateMonitor.autopilot_status.log"
    global g_apLogLast     := ""    ; last logged status line (dedup key)
    global g_apLogLastTick := 0     ; throttle stamp
    global g_apLogSize     := 0     ; approximate current file size (bytes) for rotation

    cfg := A_ScriptDir "\poeformance_config.ini"
    try g_apLogEnabled := (IniRead(cfg, "Diagnostics", "apStatusLog", "0") = "1")
    try g_apLogSize := FileGetSize(g_apLogFile)   ; throws if absent -> stays 0
}

; Persists the toggle to [Diagnostics] apStatusLog.
SaveAutoPilotStatusLog()
{
    global g_apLogEnabled
    cfg := A_ScriptDir "\poeformance_config.ini"
    try IniWrite(g_apLogEnabled ? "1" : "0", cfg, "Diagnostics", "apStatusLog")
}

; Applies the toggle from the UI/bridge; writes a session marker when turned on so
; the user can find where this run started in the log. Param: on (truthy). No return.
SetAutoPilotStatusLog(on)
{
    global g_apLogEnabled, g_apLogFile, g_apLogLast
    g_apLogEnabled := on ? true : false
    SaveAutoPilotStatusLog()
    if g_apLogEnabled
    {
        g_apLogLast := ""   ; force the next tick to log even if unchanged
        try FileAppend("===== AutoPilot status log enabled " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " ====="
            . "`r`n", g_apLogFile, "UTF-8")
    }
}

; Header JSON value (the toggle state) for the WebView push. Caller prepends the key.
BuildAutoPilotStatusLogHeaderJson()
{
    global g_apLogEnabled
    return (IsSet(g_apLogEnabled) && g_apLogEnabled) ? "true" : "false"
}

; Appends the current AutoPilot status to the log when enabled AND the line
; changed AND not throttled. Called each AutoPilot tick from TryAutoPilot. A
; single global check makes it free when disabled. No params / no return.
ApStatusLogTick()
{
    global g_apLogEnabled
    if !(IsSet(g_apLogEnabled) && g_apLogEnabled)
        return
    global g_autoPilotState, g_autoPilotReason
    global g_combatLastReason, g_exploreLastReason, g_lootLastReason
    global g_apLogLast, g_apLogLastTick, g_apLogFile, g_apLogSize

    st  := IsSet(g_autoPilotState)   ? g_autoPilotState   : "?"
    apR := IsSet(g_autoPilotReason)  ? g_autoPilotReason  : ""
    lt  := IsSet(g_lootLastReason)   ? g_lootLastReason   : ""
    cb  := IsSet(g_combatLastReason) ? g_combatLastReason : ""
    ex  := IsSet(g_exploreLastReason) ? g_exploreLastReason : ""
    line := "state=" st " | " apR " | loot: " lt " | combat: " cb " | explore: " ex

    ; Dedup: skip when nothing changed. Then throttle so a rapidly-changing
    ; distance value can't spam the file (<= ~4 writes/sec).
    if (line = g_apLogLast)
        return
    now := A_TickCount
    if ((now - g_apLogLastTick) < 250)
        return
    g_apLogLast     := line
    g_apLogLastTick := now

    ; Rotate when the file grows past ~2 MB (keep the log bounded).
    if (g_apLogSize > 2000000)
    {
        try FileDelete(g_apLogFile)
        g_apLogSize := 0
    }

    rec := FormatTime(A_Now, "HH:mm:ss") "." A_MSec " | " line "`r`n"
    try {
        FileAppend(rec, g_apLogFile, "UTF-8")
        g_apLogSize += StrLen(rec)
    }
}
