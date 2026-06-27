; StartupTrace.ahk
; Optional startup-timing diagnostic. Most app starts are fast, but occasionally (~1 in 4) the
; tool takes many seconds to become responsive. To catch which step stalls, enable
; [Diagnostics] startupTrace=1: each major startup step is then timed with QueryPerformanceCounter
; and appended IMMEDIATELY (crash/hang-safe — a line survives even if the very next step hangs) to
; logs\InGameStateMonitor.startup_trace.log as "step | +Δms | totalMs". It is a PERSISTENT toggle
; (not one-shot) so it stays on across many restarts until a slow outlier is captured; then turn it
; off. Off by default; when off every StTrace() is a single global check + return (near-zero cost).
; Included by InGameStateMonitor.ahk; StTraceInit() runs early in the auto-exec, StTrace() marks
; punctuate the startup sequence.

; Returns the current QueryPerformanceCounter value (0 on failure).
_StQpc()
{
    c := 0
    try DllCall("QueryPerformanceCounter", "Int64*", &c)
    return c
}

; Seeds the StartupTrace globals (defaults first — AHK v2 init gotcha) and, when enabled, records
; the start time and writes a session header. Call once, as early in startup as possible (after the
; logs dir exists). No params / no return.
StTraceInit()
{
    global g_stEnabled := false
    global g_stFreq := 0
    global g_stT0 := 0
    global g_stLast := 0
    global g_stPath := A_ScriptDir "\logs\InGameStateMonitor.startup_trace.log"

    try g_stEnabled := (IniRead(_ConfigPath(), "Diagnostics", "startupTrace", "0") = "1")
    if !g_stEnabled
        return

    f := 0
    try DllCall("QueryPerformanceFrequency", "Int64*", &f)
    g_stFreq := f
    g_stT0 := _StQpc()
    g_stLast := g_stT0

    try {
        ver := IsSet(POEFORMANCE_VERSION) ? POEFORMANCE_VERSION : "?"
        pid := DllCall("GetCurrentProcessId", "UInt")
        h := FileOpen(g_stPath, "a", "UTF-8")
        if IsObject(h) {
            h.Write("`r`n===== Startup trace " FormatTime(, "yyyy-MM-dd HH:mm:ss")
                . " | PID=" pid " | v" ver " =====`r`n")
            h.Close()
        }
    }
}

; Appends one trace line for <label>: elapsed since the previous mark (+Δ) and cumulative since
; start. No-op (one global check) when the trace is disabled. No return.
StTrace(label)
{
    global g_stEnabled, g_stFreq, g_stT0, g_stLast, g_stPath
    if !(IsSet(g_stEnabled) && g_stEnabled)
        return
    now := _StQpc()
    if (g_stFreq <= 0)
        return
    dMs := (now - g_stLast) * 1000.0 / g_stFreq
    tMs := (now - g_stT0)   * 1000.0 / g_stFreq
    g_stLast := now
    try {
        h := FileOpen(g_stPath, "a", "UTF-8")
        if IsObject(h) {
            h.Write(Format("{:-38}", label) " | +" Format("{:8.1f}", dMs) " ms | "
                . Format("{:9.1f}", tMs) " ms`r`n")
            h.Close()
        }
    }
}

; Applies the toggle from the UI/bridge and persists it to [Diagnostics] startupTrace. Takes effect
; mainly on the NEXT start (this run's earlier marks already happened). No return.
SetStartupTrace(val)
{
    global g_stEnabled
    g_stEnabled := _LrvTruthy(val)
    try IniWrite(g_stEnabled ? "1" : "0", _ConfigPath(), "Diagnostics", "startupTrace")
}

; Header JSON value (bool) for the WebView push. Caller prepends the key.
BuildStartupTraceHeaderJson()
{
    global g_stEnabled
    return (IsSet(g_stEnabled) && g_stEnabled) ? "true" : "false"
}
