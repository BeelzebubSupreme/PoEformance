; SkillBarReader.ahk
; Reads the live skill-bar key bindings straight from the HUD UI tree, using the
; per-element Displayed Text (UiElementBase.TextPtr @ 0x390). This is the reliable
; source the poe2_production_Config.ini parse could not provide: each visible skill
; slot's hotkey label (e.g. "Q","R","E","T","F") is read from the rendered UI.
;
; skills_bar layout confirmed live 2026-06-21 against a subtree dump:
;   skills_bar (HUD > HUDRight > skills_bar)
;     -> per-slot icon containers (direct children of skills_bar)
;          visible container = an equipped, shown skill (its leaf label is the key)
;          hidden  container = the weapon-set-2 duplicate (label "Ctrl+<key>")
;        each container holds, a few levels deeper, exactly ONE visible leaf whose
;        Displayed Text is the bound key; icon-only slots (mouse binds) carry no
;        text and yield no key.
;
; Included by InGameStateMonitor.ahk

; Resolves the skills_bar UiElement under the active GameUi root.
; Param: reader - the PoE2MemoryReader. Returns the element address, or 0.
_SkillBarResolve(reader)
{
    if !IsObject(reader)
        return 0
    gameUi := _UiBrowser_GetGameUiPtr()
    if !reader.IsProbablyValidPointer(gameUi)
        return 0
    bar := UiTree_FindByPath(reader, gameUi, "HUD > HUDRight > skills_bar")
    if reader.IsProbablyValidPointer(bar)
        return bar
    ; Fallback: breadth-first search for the StringId, in case an intermediate
    ; StringId differs across UI modes / patches.
    return _SkillBarBfsFind(reader, gameUi, "skills_bar", 6)
}

; Bounded breadth-first search for a descendant carrying a given StringId.
; Params: rootPtr - start element; targetId - StringId to match; maxDepth - cap.
; Returns the matching element address, or 0.
_SkillBarBfsFind(reader, rootPtr, targetId, maxDepth)
{
    queue := [{ptr: rootPtr, d: 0}]
    seen := Map()
    while (queue.Length > 0)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        sid := ""
        try sid := reader.ReadStdWStringAt(p + PoE2Offsets.UiElementBase["StringIdPtr"], 48)
        if (sid = targetId)
            return p
        if (it.d >= maxDepth)
            continue
        hdr := reader.Mem.ReadBytes(p, 0x20)
        if !hdr
            continue
        cf := NumGet(hdr.Ptr, 0x10, "Ptr")
        cl := NumGet(hdr.Ptr, 0x18, "Ptr")
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

; Depth-first search within a single skill-slot container for the first VISIBLE
; leaf carrying non-empty Displayed Text — that text is the bound key. Hidden
; subtrees are pruned (so a hidden weapon-set-2 container never leaks its "Ctrl+…"
; label). Params: ptr - subtree root; depth - recursion guard.
; Returns the trimmed key string, or "" when none is found.
_SkillBarFindLabel(reader, ptr, depth)
{
    if (depth > 7 || !reader.IsProbablyValidPointer(ptr))
        return ""
    flags := 0
    try flags := reader.Mem.ReadUInt(ptr + PoE2Offsets.UiElementBase["Flags"])
    if (((flags >> 11) & 1) = 0)          ; not visible -> prune this subtree
        return ""
    hdr := reader.Mem.ReadBytes(ptr, 0x20)
    if !hdr
        return ""
    cf := NumGet(hdr.Ptr, 0x10, "Ptr")
    cl := NumGet(hdr.Ptr, 0x18, "Ptr")
    isLeaf := !(reader.IsProbablyValidPointer(cf) && cl > cf)
    if (isLeaf)
    {
        t := ""
        try t := reader.ReadStdWStringAt(ptr + PoE2Offsets.UiElementBase["TextPtr"], 32)
        return Trim(t)
    }
    n := Min((cl - cf) // A_PtrSize, 64)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return ""
    Loop n
    {
        cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(cp)
            continue
        r := _SkillBarFindLabel(reader, cp, depth + 1)
        if (r != "")
            return r
    }
    return ""
}

; Normalizes a UI key label to an AHK send token. Single ASCII letters are
; lowercased (AHK Send expects "q", not "Q"); everything else (digits, named keys,
; "Ctrl+Q") is passed through trimmed. Param: t - raw label text.
_SkillBarNormalizeKey(t)
{
    t := Trim(t)
    if (StrLen(t) = 1 && RegExMatch(t, "^[A-Za-z]$"))
        return StrLower(t)
    return t
}

; Reads the skill-bar bindings. Param: reader - the PoE2MemoryReader.
; Returns an array of Maps, one per VISIBLE slot that carries a hotkey label, in
; row-major screen order (top->bottom, left->right):
;   { key, sendKey, screenX, screenY, addr }
; Empty when the bar isn't available / visible.
ReadSkillBarHotkeys(reader)
{
    out := []
    if !IsObject(reader)
        return out
    bar := _SkillBarResolve(reader)
    if !reader.IsProbablyValidPointer(bar)
        return out
    hdr := reader.Mem.ReadBytes(bar, 0x20)
    if !hdr
        return out
    cf := NumGet(hdr.Ptr, 0x10, "Ptr")
    cl := NumGet(hdr.Ptr, 0x18, "Ptr")
    if (!reader.IsProbablyValidPointer(cf) || cl <= cf)
        return out
    n := Min((cl - cf) // A_PtrSize, 64)
    buf := reader.Mem.ReadBytes(cf, n * A_PtrSize)
    if !buf
        return out
    Loop n
    {
        container := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(container)
            continue
        ; _SkillBarFindLabel prunes hidden containers (returns "") and icon-only
        ; slots with no text leaf, so the result already excludes the weapon-set-2
        ; "Ctrl+…" duplicates and the label-less top-row icons.
        key := _SkillBarFindLabel(reader, container, 0)
        if (key = "")
            continue
        pos := UiTree_GetScreenPos(reader, container)
        out.Push(Map(
            "key", key,
            "sendKey", _SkillBarNormalizeKey(key),
            "screenX", pos["x"],
            "screenY", pos["y"],
            "addr", container
        ))
    }
    _SkillBarSortRowMajor(out)
    return out
}

; In-place insertion sort of the slot array by (screenY, screenX). Small N.
_SkillBarSortRowMajor(arr)
{
    i := 2
    while (i <= arr.Length)
    {
        cur := arr[i]
        j := i - 1
        while (j >= 1 && _SkillBarRowMajorGreater(arr[j], cur))
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := cur
        i += 1
    }
}

; True if a sorts AFTER b in row-major order. A small Y tolerance keeps a single
; visual row together (compared left->right) despite tiny vertical jitter.
_SkillBarRowMajorGreater(a, b)
{
    dy := a["screenY"] - b["screenY"]
    if (Abs(dy) > 8)
        return dy > 0
    return a["screenX"] > b["screenX"]
}

; Reads the skill bar and (re)populates g_skillKeyBySlot in row-major visual order
; (slot 1 = first key, …). Non-destructive when the bar yields nothing (keeps the
; existing config-parsed map), so it never wipes binds while the bar is hidden or
; between areas. Does NOT push to the UI — callers do that. Returns the slot count.
RefreshSkillBarKeys()
{
    global g_reader, g_skillKeyBySlot, g_skillKeyLoadStatus
    if !IsObject(g_reader)
        return 0
    list := ReadSkillBarHotkeys(g_reader)
    if (list.Length = 0)
        return 0
    m := Map()
    for i, e in list
        m[i] := e["sendKey"]
    g_skillKeyBySlot := m
    g_skillKeyLoadStatus := "ui:" list.Length
    return list.Length
}

; Refreshes the skill-bar keys from the live UI and pushes the hotkey bindings to
; the WebView. Used as the area-change handler target so the Hotkeys tab auto-fills
; its skill slots whenever a new area is entered.
_SkillKeysRefreshAndPush()
{
    try RefreshSkillBarKeys()
    try PushHotkeyBindingsToWebView()
}

; Manual trigger (bridge "DetectSkillKeys"): refreshes from the bar, applies the
; result, and reports the detected slot->key mapping so the reader can be verified
; in-game. No parameters; shows a message box. No return value.
DetectSkillKeysAndReport()
{
    global g_reader
    if !IsObject(g_reader)
    {
        try MsgBox("Game not connected.", "Detect Skill Keys", 0x10)
        return
    }
    list := ReadSkillBarHotkeys(g_reader)
    if (list.Length = 0)
    {
        try MsgBox("No skill-bar keys detected.`n`nMake sure you are in a zone with the skill bar visible and skills equipped, then try again.", "Detect Skill Keys", 0x30)
        return
    }
    RefreshSkillBarKeys()
    try PushHotkeyBindingsToWebView()
    txt := "Detected " list.Length " skill-bar key(s) — row-major (top->bottom, left->right):`n`n"
    for i, e in list
        txt .= "  slot " i ":  " e["key"] "   (send: " e["sendKey"] ")`n"
    txt .= "`nApplied to the Hotkeys-tab skill slots."
    try MsgBox(txt, "Detect Skill Keys", 0x40)
}
