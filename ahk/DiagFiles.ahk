; DiagFiles.ahk
; In-tool diagnostic-file browser for the Debug tab. PoEformance scatters diagnostic output across
; logs\ (error log, probes, the startup trace), debug\ (dumps, RE diagnostics) and data\ (generated
; price/size TSVs). This enumerates them all in one place and serves a file's content to the WebView
; so the user can read them without hunting through folders. Read-only by default plus an explicit
; delete; all access is constrained to those three folders (no traversal / absolute paths).
; Included by InGameStateMonitor.ahk. JS side: updateDiagFiles(...) / updateDiagFile(...).

; Folders + glob patterns scanned for diagnostic files. logs/debug = everything; data = the
; generated TSV/TXT diagnostics (shipped .json data is intentionally not listed).
_DiagScanList()
{
    return [ ["logs", "*"], ["debug", "*"], ["data", "*.tsv"], ["data", "*.txt"] ]
}

; Resolves a relative path (folder\name) to an absolute path, but ONLY inside logs/debug/data and
; only if it exists. Rejects traversal (".."), drive-absolute (":") and unknown folders. Returns the
; absolute path or "" when invalid. Param: rel.
_DiagResolve(rel)
{
    if (rel = "" || InStr(rel, "..") || InStr(rel, ":"))
        return ""
    rel := StrReplace(rel, "/", "\")
    ok := false
    for _, d in ["logs\", "debug\", "data\"]
        if (SubStr(rel, 1, StrLen(d)) = d)
            ok := true
    if !ok
        return ""
    abs := A_ScriptDir "\" rel
    return FileExist(abs) ? abs : ""
}

; Builds the JSON array of diagnostic files: {name, rel, folder, size, mtime}. The JS side sorts.
BuildDiagFilesJson()
{
    seen := Map()
    json := "["
    first := true
    for _, fe in _DiagScanList()
    {
        dir := A_ScriptDir "\" fe[1]
        Loop Files, dir "\" fe[2], "F"
        {
            rel := fe[1] "\" A_LoopFileName
            if seen.Has(rel)
                continue
            seen[rel] := true
            mt := ""
            try mt := FormatTime(A_LoopFileTimeModified, "yyyy-MM-dd HH:mm:ss")
            json .= (first ? "" : ",") "{"
                . '"name":' _JsStr(A_LoopFileName) ','
                . '"rel":' _JsStr(rel) ','
                . '"folder":' _JsStr(fe[1]) ','
                . '"size":' (A_LoopFileSize + 0) ','
                . '"mtime":' _JsStr(mt) "}"
            first := false
        }
    }
    json .= "]"
    return json
}

; Pushes the diagnostic-file list to the WebView (JS updateDiagFiles).
PushDiagFilesToWebView()
{
    try WebViewExec("updateDiagFiles(" BuildDiagFilesJson() ")")
}

; Reads one diagnostic file (tail-capped) and returns a result Map. Binary files (images) report
; their size only. Param: rel (folder\name).
ReadDiagFile(rel)
{
    abs := _DiagResolve(rel)
    if (abs = "")
        return Map("ok", false, "err", "invalid or missing path")
    ext := ""
    SplitPath(abs, , , &ext)
    ext := StrLower(ext)
    if (ext = "png" || ext = "ico" || ext = "jpg" || ext = "jpeg" || ext = "bin")
    {
        sz := 0
        try sz := FileGetSize(abs)
        return Map("ok", true, "binary", true, "size", sz, "truncated", false, "content", "")
    }
    MAX := 256 * 1024   ; show at most the last 256 KB (logs: the recent tail is what matters)
    content := "", truncated := false, total := 0
    try
    {
        f := FileOpen(abs, "r", "UTF-8")
        if !IsObject(f)
            return Map("ok", false, "err", "open failed")
        total := f.Length
        if (total > MAX)
        {
            f.Pos := total - MAX
            truncated := true
        }
        content := f.Read()
        f.Close()
    }
    catch
        return Map("ok", false, "err", "read error")
    return Map("ok", true, "binary", false, "size", total, "truncated", truncated, "content", content)
}

; Reads a diagnostic file and pushes its content to the WebView (JS updateDiagFile). Param: rel.
PushDiagFileToWebView(rel)
{
    r := ReadDiagFile(rel)
    json := "{"
        . '"rel":' _JsStr(rel) ','
        . '"ok":' (r["ok"] ? "true" : "false") ','
        . '"binary":' ((r.Has("binary") && r["binary"]) ? "true" : "false") ','
        . '"truncated":' ((r.Has("truncated") && r["truncated"]) ? "true" : "false") ','
        . '"size":' ((r.Has("size") ? r["size"] : 0) + 0) ','
        . '"err":' _JsStr(r.Has("err") ? r["err"] : "") ','
        . '"content":' _JsStr(r.Has("content") ? r["content"] : "")
        . "}"
    try WebViewExec("updateDiagFile(" json ")")
}

; Opens a diagnostic folder in Explorer. Param: folder (logs/debug/data; defaults to logs).
DiagOpenFolder(folder)
{
    if (folder != "logs" && folder != "debug" && folder != "data")
        folder := "logs"
    dir := A_ScriptDir "\" folder
    try DirCreate(dir)
    try Run('explorer.exe "' dir '"')
}

; Deletes one diagnostic file (validated) and refreshes the list. Param: rel.
DiagDeleteFile(rel)
{
    abs := _DiagResolve(rel)
    if (abs != "")
        try FileDelete(abs)
    PushDiagFilesToWebView()
}
