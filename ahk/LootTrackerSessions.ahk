; LootTrackerSessions.ahk
; On-disk session history for the LootTracker feature (ported from
; LootTrackerCore.Sessions.cs). A "session" is everything between two New-session
; presses. On New session the finished one is priced at the current rates and archived
; to its own JSON under sessions\ (timestamped filename => lexical == chronological
; order). The history UI lists every session and can open one for its per-map + per-item
; loot breakdown, or delete it. Older sessions are pruned past maxSessions.
;
; Serialization uses JsonFull (round-trips nested Map/Array). Included by
; InGameStateMonitor.ahk.

_LtSessionsDir() => A_ScriptDir "\sessions"

; ── Persistence ────────────────────────────────────────────────────────────────
; Snapshots the session being ended (the completed runs, with the active run banked
; first) and writes it to its own JSON. No-op when nothing was run.
_LtSaveCurrentSession()
{
    global g_ltCompleted, g_ltSessionStartStamp
    _LtBankActiveTime(A_TickCount)             ; include the active run's still-running time
    if (g_ltCompleted.Length = 0)
        return
    rec := _LtBuildSessionRecord(g_ltSessionStartStamp, A_Now)
    _LtWriteSession(rec)
    _LtTrimSessions()
}

; Prices every completed run's net gains at the current rates and assembles the record.
_LtBuildSessionRecord(startStamp, endStamp)
{
    global g_ltCompleted, g_ltDivToEx
    rec := Map(
        "startStamp", "" startStamp,
        "endStamp", "" endStamp,
        "divineRate", g_ltDivToEx,
        "maps", [])

    for _, r in g_ltCompleted
    {
        m := Map("name", r["name"], "activeSeconds", r["activeMs"] / 1000.0, "profitEx", 0.0, "loot", [])
        profit := 0.0
        for k, v in r["gained"]
        {
            if (v = 0)
                continue
            unit := 0.0, label := ""
            priced := _LtTryPriceItem(k, &unit, &label)
            ex := priced ? unit * v : 0.0
            m["loot"].Push(Map("label", label, "count", v, "ex", ex, "priced", priced ? 1 : 0))
            profit += ex
        }
        _LtSortLootDesc(m["loot"])
        m["profitEx"] := profit
        rec["maps"].Push(m)
    }
    return rec
}

_LtWriteSession(rec)
{
    dir := _LtSessionsDir()
    try
    {
        if !DirExist(dir)
            DirCreate(dir)
        fname := "session_" rec["startStamp"] ".json"
        path := dir "\" fname
        f := FileOpen(path, "w", "UTF-8")
        if !f
            return
        f.Write(JsonFull_Stringify(rec, true))
        f.Close()
    }
    catch
    {
        ; history is best-effort; a failed write just means this session isn't archived.
    }
}

; Drops the oldest session files past the keep-limit.
_LtTrimSessions()
{
    global g_ltMaxSessions
    dir := _LtSessionsDir()
    try
    {
        if !DirExist(dir)
            return
        files := []
        Loop Files, dir "\session_*.json"
            files.Push(A_LoopFileName)
        maxKeep := Max(1, g_ltMaxSessions)
        if (files.Length <= maxKeep)
            return
        _LtSortStringsAsc(files)                ; oldest first (lexical == chronological)
        del := files.Length - maxKeep
        i := 1
        while (i <= del)
        {
            try FileDelete(dir "\" files[i])
            i += 1
        }
    }
}

; ── History windows (pushed to the Loot tab) ───────────────────────────────────
; Pushes the saved-session summary list (newest first) to the UI.
PushLootSessionsToWebView()
{
    try WebViewExec("updateLootSessions(" _LtSessionSummaryJson() ")")
}

; Pushes one session's full detail (per-map aggregates + per-item loot) to the UI.
PushLootSessionDetailToWebView(file)
{
    try WebViewExec("updateLootSessionDetail(" _LtSessionDetailJson(file) ")")
}

; Deletes one archived session (filename-validated to block path traversal), then
; re-pushes the summary list.
_LtDeleteSession(file)
{
    if !RegExMatch(file, "^session_[0-9A-Za-z_]+\.json$")
        return
    try FileDelete(_LtSessionsDir() "\" file)
    PushLootSessionsToWebView()
}

; Builds a JSON array of session summaries (newest first): file, start, length, map
; count, total Exalted, total active seconds, Divine rate.
_LtSessionSummaryJson()
{
    dir := _LtSessionsDir()
    summaries := []
    if DirExist(dir)
    {
        files := []
        Loop Files, dir "\session_*.json"
            files.Push(A_LoopFileName)
        _LtSortStringsDesc(files)               ; newest first
        for _, fname in files
        {
            try
            {
                rec := JsonFull_Parse(FileRead(dir "\" fname, "UTF-8"))
                if !(rec && Type(rec) = "Map")
                    continue
                maps := rec.Has("maps") ? rec["maps"] : []
                totalEx := 0.0, totalSec := 0.0, mapCount := 0
                if (Type(maps) = "Array")
                {
                    mapCount := maps.Length
                    for _, m in maps
                    {
                        totalEx  += (m.Has("profitEx") ? m["profitEx"] : 0) + 0
                        totalSec += (m.Has("activeSeconds") ? m["activeSeconds"] : 0) + 0
                    }
                }
                startStamp := rec.Has("startStamp") ? rec["startStamp"] : ""
                endStamp   := rec.Has("endStamp") ? rec["endStamp"] : ""
                durSec := (startStamp != "" && endStamp != "") ? DateDiff(endStamp, startStamp, "Seconds") : 0
                summaries.Push(Map(
                    "file", fname, "start", startStamp, "durationSec", durSec,
                    "maps", mapCount, "totalEx", totalEx, "totalSec", totalSec,
                    "divRate", (rec.Has("divineRate") ? rec["divineRate"] : 0) + 0))
            }
        }
    }

    j := "["
    first := true
    for _, s in summaries
    {
        j .= (first ? "" : ",") "{"
            . '"file":' _JsStr(s["file"])
            . ',"start":' _JsStr(_LtFmtStamp(s["start"]))
            . ',"durationSec":' (s["durationSec"] + 0)
            . ',"maps":' (s["maps"] + 0)
            . ',"totalEx":' _LtNum(s["totalEx"])
            . ',"totalSec":' _LtNum(s["totalSec"])
            . ',"divRate":' _LtNum(s["divRate"])
            . "}"
        first := false
    }
    return j "]"
}

; Builds one session's full detail JSON, or "null" if the file is gone/garbled.
_LtSessionDetailJson(file)
{
    if !RegExMatch(file, "^session_[0-9A-Za-z_]+\.json$")
        return "null"
    path := _LtSessionsDir() "\" file
    if !FileExist(path)
        return "null"
    rec := JsonFull_Parse(FileRead(path, "UTF-8"))
    if !(rec && Type(rec) = "Map")
        return "null"

    maps := rec.Has("maps") ? rec["maps"] : []
    mapsJson := "["
    firstM := true
    if (Type(maps) = "Array")
    {
        for _, m in maps
        {
            loot := m.Has("loot") ? m["loot"] : []
            lootJson := "["
            firstL := true
            if (Type(loot) = "Array")
            {
                for _, l in loot
                {
                    pr := (l.Has("priced") && (l["priced"] = 1 || l["priced"] = true)) ? "true" : "false"
                    lootJson .= (firstL ? "" : ",") "{"
                        . '"label":' _JsStr(l.Has("label") ? l["label"] : "")
                        . ',"count":' ((l.Has("count") ? l["count"] : 0) + 0)
                        . ',"ex":' _LtNum(l.Has("ex") ? l["ex"] : 0)
                        . ',"priced":' pr
                        . "}"
                    firstL := false
                }
            }
            lootJson .= "]"
            mapsJson .= (firstM ? "" : ",") "{"
                . '"name":' _JsStr(m.Has("name") ? m["name"] : "")
                . ',"activeSeconds":' _LtNum(m.Has("activeSeconds") ? m["activeSeconds"] : 0)
                . ',"profitEx":' _LtNum(m.Has("profitEx") ? m["profitEx"] : 0)
                . ',"loot":' lootJson
                . "}"
            firstM := false
        }
    }
    mapsJson .= "]"

    startStamp := rec.Has("startStamp") ? rec["startStamp"] : ""
    endStamp   := rec.Has("endStamp") ? rec["endStamp"] : ""
    durSec := (startStamp != "" && endStamp != "") ? DateDiff(endStamp, startStamp, "Seconds") : 0

    return "{"
        . '"file":' _JsStr(file)
        . ',"start":' _JsStr(_LtFmtStamp(startStamp))
        . ',"durationSec":' (durSec + 0)
        . ',"divRate":' _LtNum((rec.Has("divineRate") ? rec["divineRate"] : 0) + 0)
        . ',"maps":' mapsJson
        . "}"
}

; ── Small helpers ──────────────────────────────────────────────────────────────
; A_Now-style stamp ("YYYYMMDDHHMISS") -> "yyyy-MM-dd HH:mm" (local), or "" if invalid.
_LtFmtStamp(stamp)
{
    if (stamp = "" || StrLen(stamp) < 8)
        return ""
    try return FormatTime(stamp, "yyyy-MM-dd HH:mm")
    catch
        return ""
}

; Insertion sorts a string Array ascending (in place).
_LtSortStringsAsc(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        key := arr[i]
        j := i - 1
        while (j >= 1 && StrCompare(arr[j], key) > 0)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}

; Insertion sorts a string Array descending (in place).
_LtSortStringsDesc(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        key := arr[i]
        j := i - 1
        while (j >= 1 && StrCompare(arr[j], key) < 0)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}

; Insertion sorts a loot-line Array by abs(ex) descending (in place).
_LtSortLootDesc(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        key := arr[i]
        kv := Abs(key.Has("ex") ? key["ex"] : 0)
        j := i - 1
        while (j >= 1 && Abs(arr[j].Has("ex") ? arr[j]["ex"] : 0) < kv)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }
}
